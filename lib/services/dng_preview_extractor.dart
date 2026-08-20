import 'dart:io';
import 'dart:typed_data';

// Pure-Dart port of macos/Runner/DngPreviewExtractor.swift (Round 3a/3b).
//
// Many DNGs (Lightroom Classic, DxO PureRAW) carry a full-resolution JPEG
// rendition inside one of the TIFF SubIFDs, alongside the actual RAW mosaic.
// Reading it is a bounds-checked seek+slice -- no image decode at all.
// Returns null for DNGs with no such embedded JPEG (e.g. bare CFA captures),
// in which case callers must fall back to a real RAW decode.
//
// Deliberately free of dart:ffi, MethodChannel and platform-branching
// checks, so it can run on any platform/isolate that has no native
// thumbnail bridge.

/// Reads and extracts DNG embedded full-size JPEG previews from raw bytes,
/// mirroring the Swift TIFF/IFD walker byte-for-byte. Every read is
/// bounds-checked against the buffer length; malformed/truncated/non-DNG
/// input degrades to `null`, never an uncaught exception.
class DngPreviewExtractor {
  const DngPreviewExtractor._();

  /// Reads [path] from disk and returns the largest embedded full-size JPEG
  /// preview's bytes, or `null` when the file cannot be read/parsed or has
  /// no qualifying embedded preview. Never throws.
  static Future<Uint8List?> extractFullSizeEmbeddedJpegFromFile(
    String path,
  ) async {
    try {
      final data = await File(path).readAsBytes();
      return extractFullSizeEmbeddedJpeg(data);
    } catch (_) {
      return null;
    }
  }

  /// Reads the IFD0 Orientation tag (0x0112) from [path] without performing
  /// any extraction judgment. Returns 1 (no transform) when the file cannot
  /// be parsed or the tag is absent -- mirrors the default used inside
  /// [extractFullSizeEmbeddedJpeg]. Never throws.
  static Future<int> readOrientationFromFile(String path) async {
    try {
      final data = await File(path).readAsBytes();
      return readDngOrientation(data);
    } catch (_) {
      return 1;
    }
  }

  /// Pure in-memory variant of [readOrientationFromFile], for testing and for
  /// callers that already hold the bytes.
  static int readDngOrientation(Uint8List data) {
    if (data.length < 8) return 1;

    final littleEndian = _detectByteOrder(data);
    if (littleEndian == null) return 1;

    final reader = _TIFFReader(data, littleEndian);
    final magic = reader.u16(2);
    if (magic != 42) return 1;
    final ifd0Offset = reader.u32(4);
    if (ifd0Offset == null) return 1;
    final ifd0Result = reader.readIFD(ifd0Offset);
    if (ifd0Result == null) return 1;
    final ifd0 = ifd0Result.$1;

    final entry = ifd0[0x0112];
    if (entry != null) {
      final vals = reader.values(entry);
      if (vals != null && vals.isNotEmpty) return vals.first;
    }
    return 1;
  }

  /// Pure in-memory variant of [extractFullSizeEmbeddedJpegFromFile]. Returns
  /// `null` on malformed/non-DNG input or when no qualifying embedded JPEG is
  /// found; never throws.
  static Uint8List? extractFullSizeEmbeddedJpeg(Uint8List data) {
    if (data.length < 8) return null;

    final littleEndian = _detectByteOrder(data);
    if (littleEndian == null) return null;

    final reader = _TIFFReader(data, littleEndian);
    final magic = reader.u16(2);
    if (magic != 42) return null;
    final ifd0Offset = reader.u32(4);
    if (ifd0Offset == null) return null;
    final ifd0Result = reader.readIFD(ifd0Offset);
    if (ifd0Result == null) return null;
    final ifd0 = ifd0Result.$1;

    // Orientation lives in IFD0.
    var orientation = 1;
    final orientEntry = ifd0[0x0112];
    if (orientEntry != null) {
      final vals = reader.values(orientEntry);
      if (vals != null && vals.isNotEmpty) orientation = vals.first;
    }

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
    if (defaultCrop == null) return null;
    final cropMax = defaultCrop.$1 > defaultCrop.$2
        ? defaultCrop.$1
        : defaultCrop.$2;
    if (cropMax <= 0) return null;

    _Candidate? best;

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
      if (maxDim < 0.90 * cropMax) continue;

      final offset = stripOffVals[0];
      final byteCount = stripCountVals[0];
      if (offset < 0 ||
          offset >= data.length ||
          offset + byteCount > data.length) {
        continue;
      }

      final area = width * height;
      if (best == null || area > best.width * best.height) {
        best = _Candidate(
          width: width,
          height: height,
          offset: offset,
          byteCount: byteCount,
        );
      }
    }

    if (best == null) return null;
    final sliceStart = best.offset;
    final sliceEnd = sliceStart + best.byteCount;
    if (sliceStart < 0 || sliceEnd > data.length || sliceStart >= sliceEnd) {
      return null;
    }
    final jpegBytes = data.sublist(sliceStart, sliceEnd);

    if (orientation != 1) {
      final oriented = _injectExifOrientation(jpegBytes, orientation);
      if (oriented != null) return oriented;
    }
    return jpegBytes;
  }

  /// Returns `true` for little-endian ("II"), `false` for big-endian ("MM"),
  /// `null` when neither byte-order marker is present.
  static bool? _detectByteOrder(Uint8List data) {
    if (data.length < 2) return null;
    final b0 = data[0];
    final b1 = data[1];
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
    final littleEndian = _detectByteOrder(tiffData);
    if (littleEndian == null) return false;
    final reader = _TIFFReader(tiffData, littleEndian);
    final magic = reader.u16(2);
    if (magic != 42) return false;
    final ifdOff = reader.u32(4);
    if (ifdOff == null) return false;
    final ifdResult = reader.readIFD(ifdOff);
    if (ifdResult == null) return false;
    return ifdResult.$1[0x0112] != null;
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

/// Minimal bounds-checked TIFF/IFD reader used to walk DNG structure without
/// pulling in a full TIFF library. Operates on untrusted file data: every
/// read is bounds-checked against `data.length` and returns `null` rather
/// than throwing.
class _TIFFReader {
  _TIFFReader(this.data, this.littleEndian) : _view = ByteData.sublistView(data);

  final Uint8List data;
  final bool littleEndian;
  final ByteData _view;

  Endian get _endian => littleEndian ? Endian.little : Endian.big;

  int? u16(int offset) {
    if (offset < 0 || offset + 2 > data.length) return null;
    return _view.getUint16(offset, _endian);
  }

  int? u32(int offset) {
    if (offset < 0 || offset + 4 > data.length) return null;
    return _view.getUint32(offset, _endian);
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
  /// Bounds-checked against `data.length`; returns `null` on any
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
          if (elemOffset < 0 || elemOffset >= data.length) return null;
          result.add(data[elemOffset]);
          break;
        default:
          return null;
      }
    }
    return result;
  }
}
