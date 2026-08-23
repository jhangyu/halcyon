import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

// Pure-Dart port of macos/Runner/DngPreviewExtractor.swift (Round 3a/3b),
// extended in M0 with byte-range disk reads and long-edge candidate selection.
//
// Many DNGs (Lightroom Classic, DxO PureRAW) carry one or more JPEG
// renditions inside the TIFF SubIFDs, alongside the actual RAW mosaic.
// Reading one is a bounds-checked seek+slice -- no image decode at all.
// Returns null for DNGs with no such embedded JPEG (e.g. bare CFA captures),
// in which case callers must fall back to a real RAW decode.
//
// The file-path entry points never slurp the whole file: the TIFF header, the
// IFD structures actually walked and finally the single selected JPEG strip
// are read through a small paged random-access reader.
//
// Deliberately free of dart:ffi, MethodChannel and platform-branching
// checks, so it can run on any platform/isolate that has no native
// thumbnail bridge.

/// Result of a single IFD walk: the selected embedded JPEG plus the metadata
/// that walk already had in hand.
class DngEmbeddedJpeg {
  const DngEmbeddedJpeg({
    required this.bytes,
    required this.width,
    required this.height,
    required this.orientation,
  });

  /// JPEG bitstream, with EXIF orientation injected when `orientation != 1`
  /// and the bitstream does not already declare one.
  final Uint8List bytes;

  final int width;
  final int height;

  /// IFD0 tag 0x0112 as read; 1 when absent.
  final int orientation;
}

/// Reads and extracts DNG embedded JPEG previews, mirroring the Swift
/// TIFF/IFD walker byte-for-byte. Every read is bounds-checked against the
/// source length; malformed/truncated/non-DNG input degrades to `null`, never
/// an uncaught exception.
class DngPreviewExtractor {
  const DngPreviewExtractor._();

  /// Selects an embedded JPEG from [path] using bounded byte-range reads.
  ///
  /// [longEdge] == null -> full-size request: the candidate must satisfy
  /// `maxDim >= 0.90 * cropMax` and the largest area wins.
  /// [longEdge] != null -> the smallest candidate whose `max(width, height)`
  /// is `>= longEdge`; the `0.90 * cropMax` floor does not apply, and when no
  /// candidate reaches [longEdge] the largest available candidate is returned.
  ///
  /// [onDiskRead] is invoked once per physical read with the byte count read.
  /// Never throws.
  static Future<DngEmbeddedJpeg?> extractEmbeddedJpeg(
    String path, {
    int? longEdge,
    void Function(int byteCount)? onDiskRead,
  }) async {
    RandomAccessFile? raf;
    try {
      final file = File(path);
      raf = await file.open();
      final length = await raf.length();
      if (length < 8) return null;
      final source = _FileSource(raf, length, onDiskRead);
      return _walk(source, longEdge);
    } catch (_) {
      return null;
    } finally {
      try {
        await raf?.close();
      } catch (_) {
        // Closing a handle we already failed on is not actionable.
      }
    }
  }

  /// Reads [path] from disk and returns the largest embedded full-size JPEG
  /// preview's bytes, or `null` when the file cannot be read/parsed or has
  /// no qualifying embedded preview. Never throws.
  static Future<Uint8List?> extractFullSizeEmbeddedJpegFromFile(
    String path,
  ) async {
    final result = await extractEmbeddedJpeg(path, longEdge: null);
    return result?.bytes;
  }

  /// IFD0 tag 0x0112 for [path], read through the same bounded byte-range walk
  /// used by [extractEmbeddedJpeg]. Never throws. Works whether or not the
  /// file carries an embedded JPEG -- only the TIFF header and IFD0 are read,
  /// so a preview-less DNG costs a few kilobytes rather than its whole length.
  ///
  /// Returns `null` when the orientation could not be determined at all: the
  /// file is missing, unopenable, shorter than 8 bytes, carries no `II`/`MM`
  /// marker, has a bad magic or an unreadable/malformed IFD0. Returns 1 only
  /// when IFD0 parsed and tag 0x0112 is genuinely absent (the EXIF default),
  /// and otherwise the tag's value. "Could not read" and "no rotation" are
  /// deliberately distinct, so a caller -- and a test -- can tell an
  /// implementation that worked from one that gave up.
  ///
  /// Note the deliberate asymmetry with [readDngOrientation], which keeps its
  /// `int` return and its 1-on-failure contract.
  static Future<int?> readOrientation(
    String path, {
    void Function(int byteCount)? onDiskRead,
  }) async {
    RandomAccessFile? raf;
    try {
      raf = await File(path).open();
      final length = await raf.length();
      if (length < 8) return null;
      final reader = _readerFor(_FileSource(raf, length, onDiskRead));
      if (reader == null) return null;
      final ifd0 = _readIFD0(reader);
      if (ifd0 == null) return null;
      return _orientationOf(reader, ifd0);
    } catch (_) {
      return null;
    } finally {
      try {
        await raf?.close();
      } catch (_) {
        // Closing a handle we already failed on is not actionable.
      }
    }
  }

  /// Pure in-memory variant reading the IFD0 Orientation tag (0x0112) without
  /// performing any extraction judgment. Returns 1 (no transform) when the
  /// data cannot be parsed or the tag is absent.
  static int readDngOrientation(Uint8List data) {
    if (data.length < 8) return 1;
    final source = _MemorySource(data);
    final reader = _readerFor(source);
    if (reader == null) return 1;
    final ifd0 = _readIFD0(reader);
    if (ifd0 == null) return 1;
    // `?? 1` keeps this method's observable behaviour identical by
    // construction: every input that yielded 1 before still yields 1.
    return _orientationOf(reader, ifd0) ?? 1;
  }

  /// Pure in-memory variant of [extractFullSizeEmbeddedJpegFromFile]. Returns
  /// `null` on malformed/non-DNG input or when no qualifying embedded JPEG is
  /// found; never throws.
  static Uint8List? extractFullSizeEmbeddedJpeg(Uint8List data) {
    if (data.length < 8) return null;
    try {
      return _walk(_MemorySource(data), null)?.bytes;
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------
  // The single walk
  // ---------------------------------------------------------------------

  static _TIFFReader? _readerFor(_ByteSource source) {
    final littleEndian = _detectByteOrder(source);
    if (littleEndian == null) return null;
    final reader = _TIFFReader(source, littleEndian);
    final magic = reader.u16(2);
    if (magic != 42) return null;
    return reader;
  }

  static Map<int, _IFDEntry>? _readIFD0(_TIFFReader reader) {
    final ifd0Offset = reader.u32(4);
    if (ifd0Offset == null) return null;
    final ifd0Result = reader.readIFD(ifd0Offset);
    if (ifd0Result == null) return null;
    return ifd0Result.$1;
  }

  /// IFD0 tag 0x0112, or 1 when the tag is genuinely absent (the EXIF
  /// default). Returns `null` for "found the tag, could not read it" -- a
  /// value field with a bad type, a zero count or an offset past EOF -- which
  /// is undetermined, not "no rotation". Callers that must not distinguish
  /// the two fold the null back with `?? 1`.
  static int? _orientationOf(_TIFFReader reader, Map<int, _IFDEntry> ifd0) {
    final entry = ifd0[0x0112];
    if (entry == null) return 1;
    final vals = reader.values(entry);
    if (vals == null || vals.isEmpty) return null;
    return vals.first;
  }

  /// Walks IFD0 + SubIFDs once, selects a candidate per [longEdge] and reads
  /// the selected strip. Returns `null` when nothing qualifies.
  static DngEmbeddedJpeg? _walk(_ByteSource source, int? longEdge) {
    final reader = _readerFor(source);
    if (reader == null) return null;
    final ifd0 = _readIFD0(reader);
    if (ifd0 == null) return null;

    // Orientation lives in IFD0. The extraction path cannot express
    // "undetermined" -- it injects EXIF only for a known non-1 value -- so an
    // unreadable tag folds to 1 exactly as it did before AC12h.
    final orientation = _orientationOf(reader, ifd0) ?? 1;

    (int, int)? cropSize(Map<int, _IFDEntry> entries) {
      final entry = entries[0xC620];
      if (entry == null) return null;
      final vals = reader.values(entry);
      if (vals == null || vals.length < 2) return null;
      return (vals[0], vals[1]);
    }

    // Gather IFD0 plus every SubIFD (tag 0x014A) as candidates.
    final candidateIFDs = <Map<int, _IFDEntry>>[ifd0];
    final subEntry = ifd0[0x014A];
    if (subEntry != null) {
      final subOffsets = reader.values(subEntry);
      if (subOffsets != null) {
        for (final off in subOffsets) {
          final sub = reader.readIFD(off);
          if (sub != null) candidateIFDs.add(sub.$1);
        }
      }
    }

    // DefaultCropSize (0xC620) may live in IFD0 or in one of the SubIFDs.
    var defaultCrop = cropSize(ifd0);
    if (defaultCrop == null) {
      for (final ifd in candidateIFDs) {
        final c = cropSize(ifd);
        if (c != null) {
          defaultCrop = c;
          break;
        }
      }
    }
    var cropMax = 0;
    if (defaultCrop != null) {
      cropMax = defaultCrop.$1 > defaultCrop.$2
          ? defaultCrop.$1
          : defaultCrop.$2;
    }
    // The 0.90 * cropMax floor only guards the full-size request; without a
    // usable DefaultCropSize that request cannot be judged at all.
    if (longEdge == null && cropMax <= 0) return null;

    final candidates = <_Candidate>[];

    for (final ifd in candidateIFDs) {
      final compEntry = ifd[0x0103];
      if (compEntry == null) continue;
      final compVals = reader.values(compEntry);
      if (compVals == null || compVals.isEmpty || compVals.first != 7) {
        continue;
      }

      final photoEntry = ifd[0x0106];
      if (photoEntry == null) continue;
      final photoVals = reader.values(photoEntry);
      if (photoVals == null || photoVals.isEmpty || photoVals.first != 6) {
        continue;
      }

      final widthEntry = ifd[0x0100];
      if (widthEntry == null) continue;
      final widthVals = reader.values(widthEntry);
      if (widthVals == null || widthVals.isEmpty) continue;
      final width = widthVals.first;

      final heightEntry = ifd[0x0101];
      if (heightEntry == null) continue;
      final heightVals = reader.values(heightEntry);
      if (heightVals == null || heightVals.isEmpty) continue;
      final height = heightVals.first;

      final stripOffEntry = ifd[0x0111];
      if (stripOffEntry == null) continue;
      final stripOffVals = reader.values(stripOffEntry);
      if (stripOffVals == null || stripOffVals.length != 1) continue;

      final stripCountEntry = ifd[0x0117];
      if (stripCountEntry == null) continue;
      final stripCountVals = reader.values(stripCountEntry);
      if (stripCountVals == null || stripCountVals.length != 1) continue;

      final maxDim = width > height ? width : height;
      if (longEdge == null && maxDim < 0.90 * cropMax) continue;

      final offset = stripOffVals[0];
      final byteCount = stripCountVals[0];
      if (offset < 0 ||
          byteCount <= 0 ||
          offset >= source.length ||
          offset + byteCount > source.length) {
        continue;
      }

      candidates.add(
        _Candidate(
          width: width,
          height: height,
          offset: offset,
          byteCount: byteCount,
        ),
      );
    }

    final best = _select(candidates, longEdge);
    if (best == null) return null;

    final jpegBytes = source.read(best.offset, best.byteCount);
    if (jpegBytes == null || jpegBytes.length != best.byteCount) return null;

    var bytes = jpegBytes;
    if (orientation != 1) {
      final oriented = _injectExifOrientation(jpegBytes, orientation);
      if (oriented != null) bytes = oriented;
    }
    return DngEmbeddedJpeg(
      bytes: bytes,
      width: best.width,
      height: best.height,
      orientation: orientation,
    );
  }

  /// Candidate selection. `longEdge == null` keeps today's rule (largest area
  /// wins, first one wins ties). Otherwise the smallest candidate reaching
  /// [longEdge] wins, falling back to the largest when none reaches it.
  static _Candidate? _select(List<_Candidate> candidates, int? longEdge) {
    if (candidates.isEmpty) return null;

    _Candidate? largest;
    for (final c in candidates) {
      if (largest == null || c.area > largest.area) largest = c;
    }
    if (longEdge == null) return largest;

    _Candidate? smallestReaching;
    for (final c in candidates) {
      if (c.maxDim < longEdge) continue;
      if (smallestReaching == null || c.area < smallestReaching.area) {
        smallestReaching = c;
      }
    }
    return smallestReaching ?? largest;
  }

  /// Returns `true` for little-endian ("II"), `false` for big-endian ("MM"),
  /// `null` when neither byte-order marker is present.
  static bool? _detectByteOrder(_ByteSource source) {
    final head = source.read(0, 2);
    if (head == null || head.length < 2) return null;
    final b0 = head[0];
    final b1 = head[1];
    if (b0 == 0x49 && b1 == 0x49) return true;
    if (b0 == 0x4D && b1 == 0x4D) return false;
    return null;
  }

  /// Injects a minimal EXIF APP1 segment carrying [orientation] right after
  /// the JPEG SOI marker, unless the JPEG already carries its own EXIF
  /// Orientation tag. Returns the original bytes when [jpeg] does not start
  /// with a valid SOI marker or already declares Orientation; returns `null`
  /// only if construction is impossible (never happens in practice, kept for
  /// parity with the Swift optional return).
  static Uint8List? _injectExifOrientation(Uint8List jpeg, int orientation) {
    if (jpeg.length < 2) return jpeg;
    if (jpeg[0] != 0xFF || jpeg[1] != 0xD8) return jpeg;

    if (_jpegHasExifOrientation(jpeg)) return jpeg;

    final tiff = BytesBuilder();
    tiff.add([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00]); // II,42,IFD@8
    tiff.add([0x01, 0x00]); // 1 entry
    tiff.add([0x12, 0x01]); // tag 0x0112 Orientation
    tiff.add([0x03, 0x00]); // type SHORT
    tiff.add([0x01, 0x00, 0x00, 0x00]); // count 1
    final oriLE = orientation & 0xFFFF;
    tiff.add([oriLE & 0xFF, (oriLE >> 8) & 0xFF]);
    tiff.add([0x00, 0x00]); // pad value field to 4 bytes
    tiff.add([0x00, 0x00, 0x00, 0x00]); // next IFD offset = none

    final exifPayload = BytesBuilder();
    exifPayload.add([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]); // "Exif\0\0"
    exifPayload.add(tiff.toBytes());
    final exifBytes = exifPayload.toBytes();

    final segmentLength = exifBytes.length + 2;
    final app1 = BytesBuilder();
    app1.add([0xFF, 0xE1]);
    app1.add([(segmentLength >> 8) & 0xFF, segmentLength & 0xFF]);
    app1.add(exifBytes);

    final result = BytesBuilder();
    result.add(jpeg.sublist(0, 2)); // SOI
    result.add(app1.toBytes());
    result.add(jpeg.sublist(2));
    return result.toBytes();
  }

  /// Scans JPEG marker segments for an APP1/Exif block that already declares
  /// Orientation.
  static bool _jpegHasExifOrientation(Uint8List jpeg) {
    var pos = 2;
    final end = jpeg.length;
    while (pos + 2 <= end) {
      if (jpeg[pos] != 0xFF) break;
      final marker = jpeg[pos + 1];
      if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        pos += 2;
        continue;
      }
      if (marker == 0xDA || marker == 0xD9) break; // SOS / EOI: no more markers
      if (pos + 4 > end) break;
      final lenHi = jpeg[pos + 2];
      final lenLo = jpeg[pos + 3];
      final segLen = (lenHi << 8) | lenLo;
      if (segLen < 2 || pos + 2 + segLen > end) break;

      if (marker == 0xE1) {
        final payloadStart = pos + 4;
        final payloadEnd = pos + 2 + segLen;
        if (payloadEnd - payloadStart >= 6) {
          final header = jpeg.sublist(payloadStart, payloadStart + 6);
          if (_bytesEqual(header, const [0x45, 0x78, 0x69, 0x66, 0x00, 0x00])) {
            final tiffData = jpeg.sublist(payloadStart + 6, payloadEnd);
            if (_tiffDataHasOrientation(tiffData)) return true;
          }
        }
      }
      pos += 2 + segLen;
    }
    return false;
  }

  static bool _tiffDataHasOrientation(Uint8List tiffData) {
    if (tiffData.length < 8) return false;
    final reader = _readerFor(_MemorySource(tiffData));
    if (reader == null) return false;
    final ifd0 = _readIFD0(reader);
    if (ifd0 == null) return false;
    return ifd0[0x0112] != null;
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _Candidate {
  const _Candidate({
    required this.width,
    required this.height,
    required this.offset,
    required this.byteCount,
  });

  final int width;
  final int height;
  final int offset;
  final int byteCount;

  int get area => width * height;
  int get maxDim => width > height ? width : height;
}

class _IFDEntry {
  const _IFDEntry({
    required this.tag,
    required this.type,
    required this.count,
    required this.valueFieldOffset,
  });

  final int tag;
  final int type;
  final int count;
  final int valueFieldOffset;
}

/// Random-access byte provider behind the TIFF reader. Implementations are
/// either a fully-resident buffer or a paged view over an open file.
abstract class _ByteSource {
  /// Total number of bytes addressable.
  int get length;

  /// Returns exactly [count] bytes starting at [offset], or `null` when the
  /// range is out of bounds or unreadable. Never throws.
  Uint8List? read(int offset, int count);
}

class _MemorySource implements _ByteSource {
  _MemorySource(this._data);

  final Uint8List _data;

  @override
  int get length => _data.length;

  @override
  Uint8List? read(int offset, int count) {
    if (offset < 0 || count < 0 || offset + count > _data.length) return null;
    return Uint8List.sublistView(_data, offset, offset + count);
  }
}

/// Paged random-access view over an open file with a small LRU of fixed-size
/// pages. Physical reads are reported through `onDiskRead`; large ranges (the
/// selected JPEG strip) bypass the cache and are read in one go.
class _FileSource implements _ByteSource {
  _FileSource(this._raf, this.length, this._onDiskRead);

  static const int _pageSize = 8192;
  static const int _maxPages = 48;
  static const int _directReadThreshold = 64 * 1024;

  final RandomAccessFile _raf;
  final void Function(int byteCount)? _onDiskRead;
  final LinkedHashMap<int, Uint8List> _pages = LinkedHashMap<int, Uint8List>();

  @override
  final int length;

  @override
  Uint8List? read(int offset, int count) {
    if (offset < 0 || count < 0 || offset + count > length) return null;
    if (count == 0) return Uint8List(0);
    if (count >= _directReadThreshold) return _readDirect(offset, count);

    final out = Uint8List(count);
    var written = 0;
    var cursor = offset;
    while (written < count) {
      final pageIndex = cursor ~/ _pageSize;
      final page = _page(pageIndex);
      if (page == null) return null;
      final within = cursor - pageIndex * _pageSize;
      if (within >= page.length) return null;
      final take = (page.length - within) < (count - written)
          ? (page.length - within)
          : (count - written);
      out.setRange(written, written + take, page, within);
      written += take;
      cursor += take;
    }
    return out;
  }

  Uint8List? _page(int pageIndex) {
    final cached = _pages.remove(pageIndex);
    if (cached != null) {
      _pages[pageIndex] = cached; // refresh LRU position
      return cached;
    }
    final start = pageIndex * _pageSize;
    if (start >= length) return null;
    final want = (length - start) < _pageSize ? (length - start) : _pageSize;
    final bytes = _readDirect(start, want);
    if (bytes == null) return null;
    _pages[pageIndex] = bytes;
    if (_pages.length > _maxPages) _pages.remove(_pages.keys.first);
    return bytes;
  }

  Uint8List? _readDirect(int offset, int count) {
    try {
      _raf.setPositionSync(offset);
      final bytes = _raf.readSync(count);
      _onDiskRead?.call(bytes.length);
      if (bytes.length != count) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }
}

/// Minimal bounds-checked TIFF/IFD reader used to walk DNG structure without
/// pulling in a full TIFF library. Operates on untrusted data: every read is
/// bounds-checked against the source length and returns `null` rather than
/// throwing.
class _TIFFReader {
  _TIFFReader(this.source, this.littleEndian);

  final _ByteSource source;
  final bool littleEndian;

  int? u16(int offset) {
    final b = source.read(offset, 2);
    if (b == null) return null;
    return littleEndian ? (b[0] | (b[1] << 8)) : ((b[0] << 8) | b[1]);
  }

  int? u32(int offset) {
    final b = source.read(offset, 4);
    if (b == null) return null;
    return littleEndian
        ? (b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24))
        : ((b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]);
  }

  int? u8(int offset) {
    final b = source.read(offset, 1);
    if (b == null) return null;
    return b[0];
  }

  int _typeSize(int type) {
    switch (type) {
      case 1:
      case 2:
      case 6:
      case 7:
        return 1; // BYTE, ASCII, SBYTE, UNDEFINED
      case 3:
      case 8:
        return 2; // SHORT, SSHORT
      case 4:
      case 9:
      case 11:
        return 4; // LONG, SLONG, FLOAT
      case 5:
      case 10:
      case 12:
        return 8; // RATIONAL, SRATIONAL, DOUBLE
      default:
        return 0;
    }
  }

  /// Reads an IFD at [offset]: entry count (2 bytes) + count*12-byte entries
  /// + next-IFD offset (4 bytes).
  (Map<int, _IFDEntry>, int)? readIFD(int offset) {
    final entryCount = u16(offset);
    if (entryCount == null) return null;
    final entries = <int, _IFDEntry>{};
    var pos = offset + 2;
    for (var i = 0; i < entryCount; i++) {
      final tag = u16(pos);
      final type = u16(pos + 2);
      final count = u32(pos + 4);
      if (tag == null || type == null || count == null) return null;
      entries[tag] = _IFDEntry(
        tag: tag,
        type: type,
        count: count,
        valueFieldOffset: pos + 8,
      );
      pos += 12;
    }
    final next = u32(pos);
    if (next == null) return null;
    return (entries, next);
  }

  /// Resolves an entry's values as ints. SHORT/LONG pass through directly;
  /// RATIONAL is reduced to a rounded quotient; BYTE is widened.
  /// Bounds-checked against the source length; returns `null` on any
  /// malformed/out-of-range field.
  List<int>? values(_IFDEntry entry) {
    final size = _typeSize(entry.type);
    if (size <= 0 || entry.count <= 0 || entry.count >= 100000) return null;
    final totalBytes = entry.count * size;
    int base;
    if (totalBytes <= 4) {
      base = entry.valueFieldOffset;
    } else {
      final off = u32(entry.valueFieldOffset);
      if (off == null) return null;
      base = off;
    }

    final result = <int>[];
    for (var i = 0; i < entry.count; i++) {
      final elemOffset = base + i * size;
      switch (entry.type) {
        case 3: // SHORT
        case 8: // SSHORT
          final v = u16(elemOffset);
          if (v == null) return null;
          result.add(v);
          break;
        case 4: // LONG
        case 9: // SLONG
          final v = u32(elemOffset);
          if (v == null) return null;
          result.add(v);
          break;
        case 5: // RATIONAL
        case 10: // SRATIONAL
          final numerator = u32(elemOffset);
          final denominator = u32(elemOffset + 4);
          if (numerator == null || denominator == null || denominator == 0) {
            return null;
          }
          final quotient = numerator / denominator;
          result.add(quotient < 0 ? 0 : quotient.round());
          break;
        case 1: // BYTE
        case 6: // SBYTE
        case 7: // UNDEFINED
          final v = u8(elemOffset);
          if (v == null) return null;
          result.add(v);
          break;
        default:
          return null;
      }
    }
    return result;
  }
}
