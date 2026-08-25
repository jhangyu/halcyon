import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

// Pure-Dart port of the upstream macOS Swift extractor that used to live
// under macos/Runner/ and has since been removed (Round 3a/3b),
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

/// Outcome of a malformed-aware walk: the selected embedded JPEG (when one was
/// found) plus whether the container is structurally broken.
///
/// [malformed] is `true` only when the container PARSED but every candidate it
/// declared is unreadable -- a strip offset or byte count past EOF, a byte
/// count that does not match what the read returned, or bytes that are not a
/// JPEG bitstream. It is `false` when the container simply declares no
/// candidate at all (the valid-miss case, which must keep routing to a real RAW
/// decode), when the candidate was rejected for being undersized (M7 ruling
/// G-2 -- that is a deliberate miss, not a defect), and when the file is not a
/// parseable TIFF/DNG at all (a truncation that fails before IFD0 is readable
/// walks to `null` exactly as it did before M7 Task 3).
class DngEmbeddedJpegProbe {
  const DngEmbeddedJpegProbe({required this.jpeg, required this.malformed});

  final DngEmbeddedJpeg? jpeg;
  final bool malformed;
}

/// Reads and extracts DNG embedded JPEG previews, mirroring the Swift
/// TIFF/IFD walker byte-for-byte. Every read is bounds-checked against the
/// source length; malformed/truncated/non-DNG input degrades to `null`, never
/// an uncaught exception.
class DngEmbeddedJpegExtractor {
  const DngEmbeddedJpegExtractor._();

  /// Selects an embedded JPEG from [path] using bounded byte-range reads.
  ///
  /// [longEdge] == null -> full-size request: the candidate must satisfy
  /// `maxDim >= 0.90 * cropMax` and the largest area wins.
  /// [longEdge] != null -> the smallest candidate whose `max(width, height)`
  /// is `>= longEdge`; the `0.90 * cropMax` floor does not apply, and when no
  /// candidate reaches [longEdge] the largest available candidate is returned.
  ///
  /// [minLongEdge] is a REJECTION applied after selection, in both selection
  /// modes: when the selected candidate's `max(width, height)` is below it,
  /// this returns `null` instead of the candidate. It does not change which
  /// candidate is chosen -- the full-size request still yields the largest
  /// qualifying candidate rather than a merely-adequate one. `null` (the
  /// default) is the historical behaviour exactly, which is what leaves every
  /// existing caller untouched.
  ///
  /// The fallback-to-largest described above is therefore NO LONGER
  /// UNCONDITIONAL (M7 ruling G-2): the preview/full-size route passes
  /// `minLongEdge: ImageRequestPurpose.preview.targetSize`, so a DNG whose
  /// best embedded candidate is smaller than a preview needs enters a real RAW
  /// decode instead of being served an undersized rendition. **The sidebar
  /// route deliberately does NOT pass [minLongEdge] and stays lenient**,
  /// keeping its smallest-then-largest-candidate behaviour under rulings P-11
  /// and P-13. Both halves of that are load-bearing; neither is an oversight.
  ///
  /// [onDiskRead] is invoked once per physical read with the byte count read.
  /// Never throws.
  static Future<DngEmbeddedJpeg?> extractEmbeddedJpeg(
    String path, {
    int? longEdge,
    int? minLongEdge,
    void Function(int byteCount)? onDiskRead,
  }) async {
    RandomAccessFile? raf;
    try {
      final file = File(path);
      raf = await file.open();
      final length = await raf.length();
      if (length < 8) return null;
      final source = _FileSource(raf, length, onDiskRead);
      return _walk(source, longEdge, minLongEdge: minLongEdge);
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

  /// Malformed-aware sibling of [extractEmbeddedJpeg]: same selection rules,
  /// same [longEdge]/[minLongEdge] semantics, but it also reports whether the
  /// container is structurally broken (see [DngEmbeddedJpegProbe.malformed]).
  ///
  /// This is an ADDED API, not a migration: [extractEmbeddedJpeg] keeps its
  /// exact signature and return type, and every existing caller stays on it.
  /// The distinction exists because `_gatherCandidates` skips a candidate whose
  /// strip lies past EOF, which made "the container declared no candidate" and
  /// "the container declared only unreadable candidates" indistinguishable at
  /// the call site -- so a corrupt file was handed to the RAW decoder as though
  /// it were merely preview-less (M7 Task 3, audit gaps 2+3).
  ///
  /// One extra difference from [extractEmbeddedJpeg]: the selected candidate's
  /// bytes must actually start with a JPEG SOI marker here. That check is
  /// confined to this entry point on purpose, so the older API's behaviour on
  /// non-bitstream bytes is untouched.
  ///
  /// Never throws.
  static Future<DngEmbeddedJpegProbe> probeEmbeddedJpeg(
    String path, {
    int? longEdge,
    int? minLongEdge,
    void Function(int byteCount)? onDiskRead,
  }) async {
    const miss = DngEmbeddedJpegProbe(jpeg: null, malformed: false);
    RandomAccessFile? raf;
    try {
      final file = File(path);
      raf = await file.open();
      final length = await raf.length();
      if (length < 8) return miss;
      final source = _FileSource(raf, length, onDiskRead);
      return _probeWalk(
        source,
        longEdge,
        minLongEdge: minLongEdge,
        strictBitstream: true,
      );
    } catch (_) {
      return miss;
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
      // Null is preserved (it means "could not determine", per this method's
      // documented three-way contract); only a value that WAS read is clamped
      // to the EXIF-legal range.
      final raw = _orientationOf(reader, ifd0);
      return raw == null ? null : _sanitizeOrientation(raw);
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

  /// IFD0 tags 0x0100 (ImageWidth) / 0x0101 (ImageLength) for [path], read
  /// through the same bounded byte-range walk used by [readOrientation]
  /// (M6 F-20: the oversized-image guard needs the claimed extent without
  /// paying for a full decode). SHORT- or LONG-typed values only, matching
  /// what TIFF/DNG files actually carry for these tags. Never throws.
  ///
  /// Returns `null` when the dimensions could not be determined: the file is
  /// missing, unopenable, shorter than 8 bytes, carries no `II`/`MM` marker,
  /// has a bad magic, an unreadable/malformed IFD0, or either tag is absent
  /// or unparseable. Unlike [readOrientation] there is no EXIF default to
  /// fall back to for a missing width/height, so absence is folded into the
  /// same `null` "could not read" result.
  static Future<({int width, int height})?> readImageDimensions(
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
      final widthEntry = ifd0[0x0100];
      final heightEntry = ifd0[0x0101];
      if (widthEntry == null || heightEntry == null) return null;
      final widthVals = reader.values(widthEntry);
      final heightVals = reader.values(heightEntry);
      if (widthVals == null || widthVals.isEmpty) return null;
      if (heightVals == null || heightVals.isEmpty) return null;
      return (width: widthVals.first, height: heightVals.first);
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
    // Folding null to 1 keeps this method's observable behaviour identical by
    // construction: every input that yielded 1 before still yields 1. M7
    // ruling E additionally folds an out-of-range value to 1.
    return _sanitizeOrientation(_orientationOf(reader, ifd0));
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
  /// the two fold the null back through [_sanitizeOrientation], which also
  /// clamps a present-but-out-of-range value; no caller in this file applies a
  /// bare `?? 1` any more (M7 ruling E).
  ///
  /// Note this reports the tag's value VERBATIM when it was read -- range
  /// validation is [_sanitizeOrientation]'s job, deliberately kept separate so
  /// "what the file claims" and "what we act on" stay distinguishable.
  static int? _orientationOf(_TIFFReader reader, Map<int, _IFDEntry> ifd0) {
    final entry = ifd0[0x0112];
    if (entry == null) return 1;
    final vals = reader.values(entry);
    if (vals == null || vals.isEmpty) return null;
    return vals.first;
  }

  /// Clamps a raw IFD0 0x0112 value to the EXIF-legal range (M7 ruling E).
  ///
  /// Returns [raw] when it is non-null and within 1..8 inclusive, and 1 ("no
  /// transform", the value `kDefaultExifOrientation` names in
  /// `image_source_types.dart` -- spelled literally here to keep this file's
  /// deliberate zero-import posture) for null and for every out-of-range
  /// value. `_orientationOf` already null-defaults an ABSENT tag
  /// to 1, but it faithfully reports whatever integer a PRESENT tag carries --
  /// so before this, a file declaring orientation 0 or 9 propagated that value
  /// into pixel-orientation baking downstream. Callers that must preserve the
  /// three-way "could not read" contract (`readOrientation`, `probeContent`)
  /// keep their own null and route only the non-null value through here.
  static int _sanitizeOrientation(int? raw) {
    if (raw == null || raw < 1 || raw > 8) return 1;
    return raw;
  }

  /// Everything ONE bounded content probe can learn about [path]: the largest
  /// embedded-JPEG candidate's long edge, and IFD0's EXIF orientation.
  ///
  /// Both come out of the SAME walk on purpose. They are the two facts M3's
  /// scheduler needs before it may touch a file -- which rung the item is on,
  /// and (for an expensive one) how to orient the RAW pixels once the debounce
  /// elapses -- and they live within bytes of each other in IFD0. Asking for
  /// them separately would open the file twice, walk the header and IFD0
  /// twice, and double the probe's read budget for an answer already in hand
  /// (user ruling; invariant I6: the debounced pass must reach the decoder
  /// with ZERO extra native-loader calls).
  ///
  /// No strip is ever read -- header, IFD0 and the SubIFD table only.
  ///
  /// `jpegBitstream` is true when the file simply IS a JPEG (SOI magic). That
  /// question is answered here, off the same open, rather than by the caller
  /// peeking at the first two bytes through a file handle of its own: the
  /// probe is specified as ONE open per file, and a caller-side magic check
  /// silently made it two. Such a file has no IFDs to walk, so it returns
  /// immediately with `largestLongEdge` 0 and a null orientation -- a JPEG's
  /// orientation travels inside the bitstream its decoder already reads, and
  /// parsing for it here would cost the app's hottest path a walk for nothing.
  ///
  /// Returns `null` when the file is not a parseable TIFF/DNG at all (which is
  /// NOT the same as "parsed fine, has no candidates" -> `largestLongEdge` 0),
  /// so the caller can tell "measured" from "could not measure".
  /// `orientation` is null when IFD0 parsed but its 0x0112 value did not, and
  /// 1 when the tag is genuinely absent -- the same three-way contract
  /// [readOrientation] states. [onDiskRead] fires once per physical read with
  /// its byte count, which is how the <=300KB budget is asserted rather than
  /// assumed. Never throws.
  static Future<({bool jpegBitstream, int largestLongEdge, int? orientation})?>
  probeContent(String path, {void Function(int byteCount)? onDiskRead}) async {
    RandomAccessFile? raf;
    try {
      final file = File(path);
      raf = await file.open();
      final length = await raf.length();
      if (length < 8) return null;

      // Deliberately a raw 2-byte read rather than the paged source below: a
      // JPEG must cost two bytes and stop, and _FileSource's first page read
      // would report 8KB for the same answer.
      final head = await raf.read(2);
      onDiskRead?.call(head.length);
      if (head.length >= 2 && head[0] == 0xFF && head[1] == 0xD8) {
        return (jpegBitstream: true, largestLongEdge: 0, orientation: null);
      }

      // Positional reads from here on (_readDirect uses setPositionSync), so
      // the two bytes already consumed above do not shift what follows.
      final source = _FileSource(raf, length, onDiskRead);
      final reader = _readerFor(source);
      if (reader == null) return null;
      final ifd0 = _readIFD0(reader);
      if (ifd0 == null) return null;
      // Free at this point: IFD0 is already parsed and in memory. This is the
      // whole reason the two questions share one walk.
      // Same three-way contract as [readOrientation]: null survives, a value
      // that WAS read is clamped to the EXIF-legal range (M7 ruling E).
      final rawOrientation = _orientationOf(reader, ifd0);
      final orientation = rawOrientation == null
          ? null
          : _sanitizeOrientation(rawOrientation);
      // longEdge: 0 keeps every structurally valid candidate (the 0.90*cropMax
      // full-size floor is a selection rule, not a validity rule), so the
      // answer describes the FILE rather than one request's taste.
      final scan = _gatherCandidates(reader, source, ifd0, 0);
      if (scan == null) return null;
      var best = 0;
      for (final c in scan.candidates) {
        if (c.maxDim > best) best = c.maxDim;
      }
      return (
        jpegBitstream: false,
        largestLongEdge: best,
        orientation: orientation,
      );
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

  /// Walks IFD0 + SubIFDs once, selects a candidate per [longEdge] and reads
  /// the selected strip. Returns `null` when nothing qualifies, including when
  /// the selected candidate is rejected by [minLongEdge].
  static DngEmbeddedJpeg? _walk(
    _ByteSource source,
    int? longEdge, {
    int? minLongEdge,
  }) => _probeWalk(
    source,
    longEdge,
    minLongEdge: minLongEdge,
    strictBitstream: false,
  ).jpeg;

  /// The one implementation behind both [_walk] and [probeEmbeddedJpeg]. With
  /// [strictBitstream] false its `jpeg` field is bit-for-bit what [_walk]
  /// returned before M7 Task 3; the `malformed` field is new information
  /// computed alongside, never a change of selection.
  ///
  /// Reading a strip to decide `malformed` costs nothing on the hot paths: the
  /// selected candidate's read is the one [_walk] already performs, and the
  /// other candidates are only touched when that read fails.
  static DngEmbeddedJpegProbe _probeWalk(
    _ByteSource source,
    int? longEdge, {
    int? minLongEdge,
    required bool strictBitstream,
  }) {
    const miss = DngEmbeddedJpegProbe(jpeg: null, malformed: false);
    final reader = _readerFor(source);
    if (reader == null) return miss;
    final ifd0 = _readIFD0(reader);
    if (ifd0 == null) return miss;

    // Orientation lives in IFD0. The extraction path cannot express
    // "undetermined" -- it injects EXIF only for a known non-1 value -- so an
    // unreadable tag folds to 1 exactly as it did before AC12h. An
    // out-of-range value folds to 1 too (M7 ruling E): a file claiming
    // orientation 0 or 9 must not propagate that into pixel-orientation
    // baking downstream.
    final orientation = _sanitizeOrientation(_orientationOf(reader, ifd0));

    final scan = _gatherCandidates(reader, source, ifd0, longEdge);
    if (scan == null) return miss;

    final best = _select(scan.candidates, longEdge);
    if (best == null) {
      // No selectable candidate. If the container nevertheless DECLARED
      // candidates and every one of them was dropped as out of bounds, the file
      // is broken rather than preview-less -- that is the whole distinction
      // this walk exists to surface.
      return DngEmbeddedJpegProbe(jpeg: null, malformed: scan.unreadable > 0);
    }

    // Applied AFTER selection and in BOTH selection modes: this is a
    // rejection, not a different choice (M7 ruling G-2). Deliberately NOT
    // malformed: the candidate is intact, just too small, and that case must
    // keep routing to a real RAW decode.
    if (minLongEdge != null && best.maxDim < minLongEdge) return miss;

    final jpegBytes = _readStrip(source, best, strictBitstream);
    if (jpegBytes == null) {
      // The selected strip did not read back. Malformed only if NO declared
      // candidate is readable -- one bad strip beside a good one is not a
      // broken container.
      final anyReadable = scan.candidates.any(
        (c) =>
            !identical(c, best) && _readStrip(source, c, strictBitstream) != null,
      );
      return DngEmbeddedJpegProbe(jpeg: null, malformed: !anyReadable);
    }

    var bytes = jpegBytes;
    if (orientation != 1) {
      final oriented = _injectExifOrientation(jpegBytes, orientation);
      if (oriented != null) bytes = oriented;
    }
    return DngEmbeddedJpegProbe(
      jpeg: DngEmbeddedJpeg(
        bytes: bytes,
        width: best.width,
        height: best.height,
        orientation: orientation,
      ),
      malformed: false,
    );
  }

  /// Reads one candidate's strip, returning `null` when it is unreadable:
  /// out of bounds, short of its declared byte count, or -- when
  /// [strictBitstream] -- not starting with a JPEG SOI marker.
  static Uint8List? _readStrip(
    _ByteSource source,
    _Candidate candidate,
    bool strictBitstream,
  ) {
    final bytes = source.read(candidate.offset, candidate.byteCount);
    if (bytes == null || bytes.length != candidate.byteCount) return null;
    if (strictBitstream &&
        (bytes.length < 2 || bytes[0] != 0xFF || bytes[1] != 0xD8)) {
      return null;
    }
    return bytes;
  }

  /// Collects every structurally valid embedded-JPEG candidate in IFD0 and its
  /// SubIFDs. No strip is read here -- this is the part [_walk] and
  /// [probeContent] share, so the probe and the extraction can
  /// never disagree about what is in a file.
  ///
  /// Returns `null` when the full-size request cannot be judged at all
  /// (`longEdge == null` and no usable DefaultCropSize).
  ///
  /// The returned scan separates the two reasons a declared IFD produces no
  /// candidate. "Not a candidate" (no Compression/Photometric/dimension/strip
  /// tags, wrong compression, or below the `0.90 * cropMax` full-size floor) is
  /// simply absence. "Unreadable candidate" -- a fully-tagged JPEG candidate
  /// whose strip lies outside the file -- is counted in [_CandidateScan
  /// .unreadable], because a container whose every declared candidate is
  /// unreadable is broken, not preview-less (M7 Task 3, audit gaps 2+3).
  static _CandidateScan? _gatherCandidates(
    _TIFFReader reader,
    _ByteSource source,
    Map<int, _IFDEntry> ifd0,
    int? longEdge,
  ) {
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
    var unreadable = 0;

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
        // A DECLARED candidate that cannot be read. Distinct from the
        // `continue`s above, which mean "this IFD is not a candidate at all".
        unreadable++;
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

    return _CandidateScan(candidates: candidates, unreadable: unreadable);
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
      if (marker == 0xD8 ||
          marker == 0x01 ||
          (marker >= 0xD0 && marker <= 0xD7)) {
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

/// What one candidate gather found: the usable candidates, plus how many
/// fully-declared candidates had to be dropped because their strip lies outside
/// the file. Zero usable candidates with a non-zero [unreadable] is the
/// malformed-container signal.
class _CandidateScan {
  const _CandidateScan({required this.candidates, required this.unreadable});

  final List<_Candidate> candidates;
  final int unreadable;
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
    // Independent copy, not a view: the returned bytes must not stay pinned
    // to (or mutate alongside) the caller's source buffer. See
    // test/dng_embedded_jpeg_extractor_f3_test.dart (F3).
    return _data.sublist(offset, offset + count);
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
