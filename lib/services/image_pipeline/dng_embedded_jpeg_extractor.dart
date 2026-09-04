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
// Two container flavours are understood, and only two (2026-08-26 RAW-support
// contract, item 3): the standard TIFF/DNG one (version word 42) and the
// Panasonic RW2 one (version word 85), which is an ordinary IFD chain with
// vendor tag numbering for its previews. Containers that are not TIFF at all --
// Fujifilm RAF, Sigma X3F, Canon CR3 -- are deliberately NOT handled here; they
// reach the RAW decoder instead.
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
    required this.offset,
    required this.byteCount,
  });

  /// JPEG bitstream, with EXIF orientation injected when `orientation != 1`
  /// and the bitstream does not already declare one.
  final Uint8List bytes;

  final int width;
  final int height;

  /// IFD0 tag 0x0112 as read; 1 when absent.
  final int orientation;

  /// Byte range of the SELECTED candidate's strip within the source file --
  /// i.e. exactly what [DngEmbeddedJpegExtractor.readKnownStrip] needs to
  /// re-read this same JPEG bitstream (add-only, 2026-09-04 W4b round-2 fix
  /// for BLOCKER-2: a caller that only needs to REPLAY a previously-selected
  /// candidate, not repeat the IFD/SubIFD walk that selected it, can memoise
  /// these two ints plus [orientation] instead of retaining [bytes]).
  /// [byteCount] is the RAW strip length on disk, before any EXIF-injection
  /// rebuild -- `readKnownStrip` reproduces the injection from [orientation],
  /// so the byte-for-byte result matches what this field's own [bytes] holds.
  final int offset;
  final int byteCount;
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

/// One structurally valid, in-range embedded-JPEG candidate as recorded by
/// [DngEmbeddedJpegExtractor.probeFile]. Deliberately holds no bytes -- see
/// [DngEmbeddedJpeg]'s BLOCKER-2 note; the same reasoning applies here, one
/// walk stronger: a whole FOLDER's worth of these must stay cheap to retain.
class DngProbeCandidate {
  const DngProbeCandidate({
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

/// Everything [DngEmbeddedJpegExtractor.probeFile]'s single IFD0/SubIFD walk
/// learns about a file: its EXIF orientation, its IFD0 dimensions (or the
/// Panasonic stand-in), every structurally valid candidate the container
/// declares (unfiltered by any long-edge floor), how many DECLARED candidates
/// were unreadable, and the crop-size ceiling ([cropMax]) the full-size
/// `0.90 * cropMax` floor is measured against. [DngEmbeddedJpegExtractor
/// .selectAndRead] turns this record plus a specific request into the same
/// answer [probeEmbeddedJpeg]/[extractEmbeddedJpeg] would give, without
/// repeating the walk.
class DngFileProbe {
  const DngFileProbe({
    required this.orientation,
    required this.dimensions,
    required this.cropMax,
    required this.candidates,
    required this.unreadableCount,
  });

  /// Already sanitized to the EXIF-legal range (M7 ruling E); 1 when the file
  /// could not be read at all, the tag is absent, or its value did not parse.
  final int orientation;

  /// IFD0's own width/height (or the Panasonic extent stand-in), or `null`
  /// when neither could be determined -- the same three-way-folded contract
  /// [DngEmbeddedJpegExtractor.readImageDimensions] documents.
  final ({int width, int height})? dimensions;

  /// See [_CandidateScan.cropMax]. 0 when unavailable.
  final int cropMax;

  final List<DngProbeCandidate> candidates;
  final int unreadableCount;
}

/// Reads and extracts DNG embedded JPEG previews, mirroring the Swift
/// TIFF/IFD walker byte-for-byte. Every read is bounds-checked against the
/// source length; malformed/truncated/non-DNG input degrades to `null`, never
/// an uncaught exception.
class DngEmbeddedJpegExtractor {
  const DngEmbeddedJpegExtractor._();

  /// How many EXTRA attempts a walk gets after one that hit an I/O fault.
  ///
  /// Two, not "until it works": a failing volume must not turn every read into
  /// an unbounded stall, and a genuinely damaged file must still reach its
  /// verdict promptly. The retry only ever fires on the fault path, so an
  /// intact file and an honestly preview-less file both still cost exactly one
  /// open (pinned by TC-540c).
  static const int _maxTransientReadRetries = 2;

  /// Diagnostic sink for read faults.
  ///
  /// `stderr`, not `debugPrint`: this file is pure Dart on purpose (the
  /// headless repro harness runs it under `dart run`, where a
  /// `package:flutter/foundation` import would not resolve), and a fault line
  /// must survive in both worlds. Fires only on the fault path, so a healthy
  /// folder prints nothing at all.
  static void _logFault(
    String path, {
    required int attempt,
    required String detail,
    required bool exhausted,
  }) {
    final name = path.split(Platform.pathSeparator).last;
    stderr.writeln(
      'halcyon.read.fault|file=$name|attempt=${attempt + 1}'
      '|of=${_maxTransientReadRetries + 1}|$detail'
      '|${exhausted ? 'GAVE_UP' : 'retrying'}',
    );
  }

  /// Backoff before retry N (1-based), so the two attempts are ~20ms and ~40ms
  /// after the fault. Small enough to stay invisible next to a RAW decode
  /// (61-406ms measured), long enough to outlast the momentary stall this
  /// exists for.
  static const Duration _retryBackoff = Duration(milliseconds: 20);

  /// Opens [path], runs [body] over a paged source, and RETRIES the whole
  /// attempt when that attempt hit an I/O fault.
  ///
  /// This is the single place the transient/absent distinction is acted on.
  /// Every file-backed entry point below routes through it, so none of them can
  /// report "no embedded preview" on the strength of a read that never
  /// happened. What it deliberately does NOT do is retry a structural answer:
  /// an intact container with no qualifying candidate, an undersized preview
  /// rejected by the frozen AD-033 floor, or a file that is not a TIFF at all
  /// all set no fault flag and return on the first attempt.
  ///
  /// [miss] is returned when the file cannot be opened or is too short, which
  /// is each caller's own pre-existing "nothing here" value -- the retry adds
  /// no new end state.
  static Future<T> _readFileWithRetry<T>(
    String path, {
    required T miss,
    required void Function(int byteCount)? onDiskRead,
    required Future<T> Function(RandomAccessFile raf, _FileSource source) body,
    // Round review BLOCKER-3 fix (2026-09-05): fired exactly once, right
    // before a final return caused by EXHAUSTING every retry while still
    // faulted -- i.e. the returned [result] (usually [miss]) reflects "the
    // volume never gave a clean read", not "this container was genuinely
    // parsed and found wanting". A caller that memoises this method's return
    // value (`probeFile`'s per-path cache in `dart_image_loader.dart`) MUST
    // NOT cache that result, or a transient I/O hiccup on the external
    // volume the user's photos live on gets permanently misreported as a
    // structural miss for the rest of the folder session. Never fired on the
    // structural-miss path (an intact, parseable-but-empty container, or a
    // non-TIFF file) -- those return with `faulted == false` on the first
    // attempt and are exactly as safe to memoise as before this fix.
    void Function()? onExhaustedFault,
  }) async {
    for (var attempt = 0; ; attempt++) {
      var faulted = false;
      var result = miss;
      String detail = 'unknown';
      RandomAccessFile? raf;
      try {
        final file = File(path);
        raf = await file.open();
        final length = await raf.length();
        if (length >= 8) {
          final source = _FileSource(raf, length, onDiskRead);
          result = await body(raf, source);
          faulted = source.ioError;
          if (faulted) detail = source.faultDetail ?? 'unknown';
        }
      } on PathNotFoundException {
        // An absent file is a settled fact, not a hiccup: returning
        // immediately keeps a missing-file miss as cheap as it was before.
        return miss;
      } catch (e) {
        // The open, the length query or an async read inside the body threw.
        // Same class of fault as a failed page read, so it earns the same
        // retry rather than being reported as an unreadable container.
        faulted = true;
        result = miss;
        detail = 'threw:entry,err=${e.runtimeType}';
      } finally {
        try {
          await raf?.close();
        } catch (_) {
          // Closing a handle we already failed on is not actionable.
        }
      }
      if (!faulted) return result;
      // ONE line per fault, on the fault path only -- the hot path (no fault)
      // never reaches here. This is the field instrument: the headless harness
      // could not reproduce a fault at all (docs/logs/2026-09-02/
      // repro-experiment.md §4-5, page-cache-bound), so the only place the
      // answer can come from is a real app run over the real volume. A line
      // here means "the transient-read hypothesis is live"; silence over a
      // session with visible RAW fallbacks means it is dead and the cause is
      // elsewhere.
      final exhausted = attempt >= _maxTransientReadRetries;
      _logFault(path, attempt: attempt, detail: detail, exhausted: exhausted);
      if (exhausted) {
        onExhaustedFault?.call();
        return result;
      }
      await Future<void>.delayed(_retryBackoff * (attempt + 1));
    }
  }

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
    return _readFileWithRetry<DngEmbeddedJpeg?>(
      path,
      miss: null,
      onDiskRead: onDiskRead,
      body: (raf, source) async =>
          _walk(source, longEdge, minLongEdge: minLongEdge),
    );
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
    return _readFileWithRetry<DngEmbeddedJpegProbe>(
      path,
      miss: miss,
      onDiskRead: onDiskRead,
      body: (raf, source) async => _probeWalk(
        source,
        longEdge,
        minLongEdge: minLongEdge,
        strictBitstream: true,
      ),
    );
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

  /// Re-reads a PREVIOUSLY-SELECTED candidate's strip directly, given the
  /// `(offset, byteCount, orientation)` a prior [extractEmbeddedJpeg] /
  /// [probeEmbeddedJpeg] call already reported on [DngEmbeddedJpeg].
  ///
  /// Added 2026-09-04 (W4b round-2, BLOCKER-2 fix): a caller that wants to
  /// REPLAY a walk's answer -- e.g. a memo keyed by (path, longEdge) -- must
  /// not retain the multi-MB [DngEmbeddedJpeg.bytes] to do so. This is the
  /// cheap replay path the diagnosis actually motivates: the walk's expense
  /// is the IFD0/SubIFD traversal (dozens of cold 8KiB page reads), NOT the
  /// final strip read, which this performs alone -- one open, one bounded
  /// read, the same EXIF-orientation injection [extractEmbeddedJpeg] already
  /// applies. Returns bit-for-bit the same bytes [DngEmbeddedJpeg.bytes] held
  /// at selection time, or `null` if the file has since changed underneath
  /// the caller (shrunk below the recorded range) -- callers must treat that
  /// exactly like any other extraction miss, not retry the full walk from
  /// here. Never throws.
  ///
  /// [strictBitstream] MUST mirror the strictness of whichever entry point
  /// recorded the `(offset, byteCount)` this call replays (round-2 S3 fix):
  /// [extractEmbeddedJpeg] (and therefore the sidebar's memo) selects and
  /// reads a candidate through [_walk], which passes `strictBitstream: false`
  /// -- so a candidate with no JPEG SOI marker is still returned there. This
  /// method used to check for the SOI marker UNCONDITIONALLY, so a strip that
  /// [extractEmbeddedJpeg] happily returned on first load would come back
  /// `null` on a memo hit -- a caller relying on both paths agreeing (exactly
  /// what a memo needs) would see a live regression the first time a no-SOI
  /// candidate reached the sidebar. Only [probeEmbeddedJpeg] (`strictBitstream:
  /// true`, via [_probeWalk]) needs the SOI check enforced here. This exactly
  /// mirrors [_readStrip]'s own conditional check.
  static Future<Uint8List?> readKnownStrip(
    String path, {
    required int offset,
    required int byteCount,
    required int orientation,
    required bool strictBitstream,
  }) async {
    return _readFileWithRetry<Uint8List?>(
      path,
      miss: null,
      onDiskRead: null,
      body: (raf, source) async {
        final bytes = await source.read(offset, byteCount);
        if (bytes == null || bytes.length != byteCount) return null;
        if (strictBitstream &&
            (bytes.length < 2 || bytes[0] != 0xFF || bytes[1] != 0xD8)) {
          return null;
        }
        if (orientation == 1) return bytes;
        final oriented = await _injectExifOrientation(bytes, orientation);
        return oriented ?? bytes;
      },
    );
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
    return _readFileWithRetry<int?>(
      path,
      miss: null,
      onDiskRead: onDiskRead,
      body: (raf, source) async {
        final reader = await _readerFor(source);
        if (reader == null) return null;
        final ifd0 = await _readIFD0(reader);
        if (ifd0 == null) return null;
        // Null is preserved (it means "could not determine", per this method's
        // documented three-way contract); only a value that WAS read is clamped
        // to the EXIF-legal range.
        final raw = await _orientationOf(reader, ifd0);
        return raw == null ? null : _sanitizeOrientation(raw);
      },
    );
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
    return _readFileWithRetry<({int width, int height})?>(
      path,
      miss: null,
      onDiskRead: onDiskRead,
      body: (raf, source) async {
        final reader = await _readerFor(source);
        if (reader == null) return null;
        final ifd0 = await _readIFD0(reader);
        if (ifd0 == null) return null;
        final widthEntry = ifd0[0x0100];
        final heightEntry = ifd0[0x0101];
        if (widthEntry == null || heightEntry == null) {
          // A Panasonic container carries neither 0x0100 nor 0x0101; its extent
          // lives in vendor tags. Without this the decoded-pixel budget guard
          // (F-20) would measure every RW2 as "unknown" and wave it through.
          if (reader.isPanasonic) return _panasonicExtent(reader, ifd0);
          return null;
        }
        final widthVals = await reader.values(widthEntry);
        final heightVals = await reader.values(heightEntry);
        if (widthVals == null || widthVals.isEmpty) return null;
        if (heightVals == null || heightVals.isEmpty) return null;
        return (width: widthVals.first, height: heightVals.first);
      },
    );
  }

  /// ONE-WALK probe record covering every question [dartImageLoad] used to ask
  /// this extractor separately (orientation, image dimensions, and every
  /// long-edge candidate for both the sidebar and full-size selection). Added
  /// 2026-09-05 (P1b, `pipeline-architecture-v2.md` §2.2a): the IFD0/SubIFD
  /// walk (`_gatherCandidates`) is deterministic for a given file regardless
  /// of which `longEdge` a caller eventually selects against, so a caller that
  /// needs several of these answers for the same [path] can perform the walk
  /// ONCE via [probeFile] and answer them all from this record -- selecting a
  /// specific candidate afterward (a cheap in-memory operation) via
  /// [selectAndRead], which only pays for a bounded strip read, not another
  /// walk.
  static Future<DngFileProbe?> probeFile(
    String path, {
    void Function(int byteCount)? onDiskRead,
  }) async {
    return (await probeFileResult(path, onDiskRead: onDiskRead)).probe;
  }

  /// [probeFile]'s full result, additionally distinguishing WHY a `null`
  /// probe came back (round review BLOCKER-3 fix, 2026-09-05): [transientFault]
  /// is true only when every retry attempt still hit an I/O fault (see
  /// [_readFileWithRetry]'s `onExhaustedFault`) -- the container was NEVER
  /// actually read cleanly, so `null` here means "could not determine, try
  /// again", not "confirmed: not a parseable container". A caller that
  /// memoises the probe (`dart_image_loader.dart`'s per-path cache) MUST
  /// treat `transientFault: true` as un-memoizable, or a transient hiccup on
  /// a flaky external volume becomes a permanent false "no preview" for the
  /// rest of the folder session. [probeFile] is kept as a thin wrapper over
  /// this for every caller that does not need the distinction.
  static Future<({DngFileProbe? probe, bool transientFault})> probeFileResult(
    String path, {
    void Function(int byteCount)? onDiskRead,
  }) async {
    var transientFault = false;
    final probe = await _readFileWithRetry<DngFileProbe?>(
      path,
      miss: null,
      onDiskRead: onDiskRead,
      onExhaustedFault: () => transientFault = true,
      body: (raf, source) async {
        final reader = await _readerFor(source);
        if (reader == null) return null;
        final ifd0 = await _readIFD0(reader);
        if (ifd0 == null) return null;
        final orientation = _sanitizeOrientation(
          await _orientationOf(reader, ifd0),
        );
        // Mirrors [readImageDimensions]'s body exactly (including the
        // Panasonic fallback), sharing this walk's already-parsed IFD0.
        ({int width, int height})? dims;
        final widthEntry = ifd0[0x0100];
        final heightEntry = ifd0[0x0101];
        if (widthEntry != null && heightEntry != null) {
          final widthVals = await reader.values(widthEntry);
          final heightVals = await reader.values(heightEntry);
          if (widthVals != null &&
              widthVals.isNotEmpty &&
              heightVals != null &&
              heightVals.isNotEmpty) {
            dims = (width: widthVals.first, height: heightVals.first);
          }
        }
        if (dims == null && reader.isPanasonic) {
          dims = await _panasonicExtent(reader, ifd0);
        }
        // `longEdge: 0` (a non-null sentinel, never a real caller request --
        // real long edges are display pixel sizes) deliberately bypasses BOTH
        // of [_gatherCandidates]'s `longEdge == null` branches: the
        // full-size 0.90*cropMax floor is not applied at gather time, and the
        // "no usable DefaultCropSize" bail-out does not fire. The record
        // therefore holds every structurally valid, in-range candidate the
        // container declares; [selectAndRead] re-applies the floor itself
        // when the CALLER'S request is actually full-size, using [cropMax]
        // from the same scan.
        final scan = await _gatherCandidates(reader, source, ifd0, 0);
        if (scan == null) {
          return DngFileProbe(
            orientation: orientation,
            dimensions: dims,
            cropMax: 0,
            candidates: const <DngProbeCandidate>[],
            unreadableCount: 0,
          );
        }
        return DngFileProbe(
          orientation: orientation,
          dimensions: dims,
          cropMax: scan.cropMax,
          candidates: [
            for (final c in scan.candidates)
              DngProbeCandidate(
                width: c.width,
                height: c.height,
                offset: c.offset,
                byteCount: c.byteCount,
              ),
          ],
          unreadableCount: scan.unreadable,
        );
      },
    );
    return (probe: probe, transientFault: transientFault);
  }

  /// Selects a candidate from a previously-computed [probe] and reads its
  /// strip -- the read-only half of [_probeWalk], factored out so a caller
  /// holding a memoised [DngFileProbe] (from [probeFile]) never repeats the
  /// walk that produced it. Selection semantics are IDENTICAL to
  /// [probeEmbeddedJpeg]/[extractEmbeddedJpeg]: `longEdge == null` applies the
  /// `0.90 * cropMax` floor before picking the largest-area candidate;
  /// `longEdge != null` picks the smallest candidate reaching it, falling back
  /// to the largest; [minLongEdge] is a post-selection rejection in both
  /// modes (M7 ruling G-2). On a failed strip read it falls back through the
  /// other candidates to decide [DngEmbeddedJpegProbe.malformed], exactly as
  /// [_probeWalk] does.
  static Future<DngEmbeddedJpegProbe> selectAndRead(
    DngFileProbe probe, {
    required String path,
    int? longEdge,
    int? minLongEdge,
    bool strictBitstream = false,
  }) async {
    const miss = DngEmbeddedJpegProbe(jpeg: null, malformed: false);
    var candidates = probe.candidates;
    if (longEdge == null) {
      if (probe.cropMax <= 0) return miss;
      candidates = [
        for (final c in candidates)
          if (c.maxDim >= 0.90 * probe.cropMax) c,
      ];
    }
    final best = _selectProbeCandidate(candidates, longEdge);
    if (best == null) {
      return DngEmbeddedJpegProbe(
        jpeg: null,
        malformed: probe.unreadableCount > 0,
      );
    }
    if (minLongEdge != null && best.maxDim < minLongEdge) return miss;

    final bytes = await readKnownStrip(
      path,
      offset: best.offset,
      byteCount: best.byteCount,
      orientation: probe.orientation,
      strictBitstream: strictBitstream,
    );
    if (bytes == null) {
      var anyReadable = false;
      for (final c in candidates) {
        if (identical(c, best)) continue;
        final alt = await readKnownStrip(
          path,
          offset: c.offset,
          byteCount: c.byteCount,
          orientation: probe.orientation,
          strictBitstream: strictBitstream,
        );
        if (alt != null) {
          anyReadable = true;
          break;
        }
      }
      return DngEmbeddedJpegProbe(jpeg: null, malformed: !anyReadable);
    }
    return DngEmbeddedJpegProbe(
      jpeg: DngEmbeddedJpeg(
        bytes: bytes,
        width: best.width,
        height: best.height,
        orientation: probe.orientation,
        offset: best.offset,
        byteCount: best.byteCount,
      ),
      malformed: false,
    );
  }

  /// [_select]'s twin over the public [DngProbeCandidate] shape.
  static DngProbeCandidate? _selectProbeCandidate(
    List<DngProbeCandidate> candidates,
    int? longEdge,
  ) {
    if (candidates.isEmpty) return null;
    DngProbeCandidate? largest;
    for (final c in candidates) {
      if (largest == null || c.area > largest.area) largest = c;
    }
    if (longEdge == null) return largest;
    DngProbeCandidate? smallestReaching;
    for (final c in candidates) {
      if (c.maxDim < longEdge) continue;
      if (smallestReaching == null || c.area < smallestReaching.area) {
        smallestReaching = c;
      }
    }
    return smallestReaching ?? largest;
  }

  /// Pure in-memory variant reading the IFD0 Orientation tag (0x0112) without
  /// performing any extraction judgment. Returns 1 (no transform) when the
  /// data cannot be parsed or the tag is absent.
  ///
  /// `Future`-returning (2026-09-04 W4): [_ByteSource.read] became async so
  /// the file-backed walk could use real async disk I/O, and this method
  /// shares that one walk implementation with the file-backed entry points
  /// rather than duplicating ~600 lines of TIFF parsing. `data` is already
  /// resident in memory, so no real asynchronous gap occurs -- this purely
  /// widens the return type to `Future<int>`.
  static Future<int> readDngOrientation(Uint8List data) async {
    if (data.length < 8) return 1;
    final source = _MemorySource(data);
    final reader = await _readerFor(source);
    if (reader == null) return 1;
    final ifd0 = await _readIFD0(reader);
    if (ifd0 == null) return 1;
    // Folding null to 1 keeps this method's observable behaviour identical by
    // construction: every input that yielded 1 before still yields 1. M7
    // ruling E additionally folds an out-of-range value to 1.
    return _sanitizeOrientation(await _orientationOf(reader, ifd0));
  }

  /// Pure in-memory variant of [extractFullSizeEmbeddedJpegFromFile]. Returns
  /// `null` on malformed/non-DNG input or when no qualifying embedded JPEG is
  /// found; never throws.
  ///
  /// `Future`-returning for the same reason as [readDngOrientation] (2026-09-04
  /// W4): shares the one walk implementation instead of a duplicate.
  static Future<Uint8List?> extractFullSizeEmbeddedJpeg(Uint8List data) async {
    if (data.length < 8) return null;
    try {
      final walked = await _walk(_MemorySource(data), null);
      return walked?.bytes;
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------
  // The single walk
  // ---------------------------------------------------------------------

  /// TIFF version word of a standard Adobe DNG / TIFF container.
  static const int _tiffVersionStandard = 42;

  /// TIFF version word of the Panasonic RW2 container: its header is
  /// `49 49 55 00`, i.e. little-endian `II` followed by 85 (0x0055). Everything
  /// after those two bytes is an ordinary TIFF IFD chain -- verified against
  /// `/Users/jhangyu/project/ceyx/image_samples/raw_corpus/2026-08-10-17-47-27.rw2`,
  /// whose IFD0 sits at offset 24 and parses entry-for-entry with the reader
  /// below (`scripts/tmp/rw2_ifd_probe.py`). What is NOT ordinary is the tag
  /// numbering: RW2 IFD0 carries no Compression (0x0103), no
  /// PhotometricInterpretation (0x0106), no StripOffsets/StripByteCounts and no
  /// SubIFDs (0x014A) at all, so accepting this version word on its own finds
  /// nothing. See [_panasonicPreviewTags].
  static const int _tiffVersionPanasonic = 85;

  static Future<_TIFFReader?> _readerFor(_ByteSource source) async {
    final littleEndian = await _detectByteOrder(source);
    if (littleEndian == null) return null;
    // The version word is read through a throwaway reader because the real one
    // is constructed WITH that version -- the container flavour decides which
    // candidate tags the gather step is allowed to look at, and nothing else.
    final version = await _TIFFReader(source, littleEndian, 0).u16(2);
    if (version == null) return null;
    if (version != _tiffVersionStandard && version != _tiffVersionPanasonic) {
      return null;
    }
    return _TIFFReader(source, littleEndian, version);
  }

  static Future<Map<int, _IFDEntry>?> _readIFD0(_TIFFReader reader) async {
    final ifd0Offset = await reader.u32(4);
    if (ifd0Offset == null) return null;
    final ifd0Result = await reader.readIFD(ifd0Offset);
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
  static Future<int?> _orientationOf(
    _TIFFReader reader,
    Map<int, _IFDEntry> ifd0,
  ) async {
    final entry = ifd0[0x0112];
    if (entry == null) return 1;
    final vals = await reader.values(entry);
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
    return _readFileWithRetry<
      ({bool jpegBitstream, int largestLongEdge, int? orientation})?
    >(
      path,
      miss: null,
      onDiskRead: onDiskRead,
      body: (raf, source) async {
        // Deliberately a raw 2-byte read rather than the paged source: a JPEG
        // must cost two bytes and stop, and _FileSource's first page read would
        // report 8KB for the same answer. A throw here reaches the retry
        // wrapper's fault path, exactly like a failed page read.
        final head = await raf.read(2);
        onDiskRead?.call(head.length);
        if (head.length >= 2 && head[0] == 0xFF && head[1] == 0xD8) {
          return (jpegBitstream: true, largestLongEdge: 0, orientation: null);
        }

        // Positional reads from here on (_readDirect uses the async
        // setPosition/read pair), so the two bytes already consumed above do
        // not shift what follows.
        final reader = await _readerFor(source);
        if (reader == null) return null;
        final ifd0 = await _readIFD0(reader);
        if (ifd0 == null) return null;
        // Free at this point: IFD0 is already parsed and in memory. This is the
        // whole reason the two questions share one walk.
        // Same three-way contract as [readOrientation]: null survives, a value
        // that WAS read is clamped to the EXIF-legal range (M7 ruling E).
        final rawOrientation = await _orientationOf(reader, ifd0);
        final orientation = rawOrientation == null
            ? null
            : _sanitizeOrientation(rawOrientation);
        // longEdge: 0 keeps every structurally valid candidate (the
        // 0.90*cropMax full-size floor is a selection rule, not a validity
        // rule), so the answer describes the FILE rather than one request's
        // taste.
        //
        // NOTE (2026-09-02): this is the measurement `PrefetchScheduler`
        // memoises first-writer-wins for the whole folder. A candidate whose
        // strip read FAULTS is skipped by the gather, which used to shrink this
        // number silently and flip the item onto the expensive (RAW decode)
        // lane for the rest of the session. The retry wrapper now re-runs the
        // whole walk in that case, so a shrunken measurement can no longer be
        // published on the strength of a read that failed.
        final scan = await _gatherCandidates(reader, source, ifd0, 0);
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
      },
    );
  }

  /// Walks IFD0 + SubIFDs once, selects a candidate per [longEdge] and reads
  /// the selected strip. Returns `null` when nothing qualifies, including when
  /// the selected candidate is rejected by [minLongEdge].
  static Future<DngEmbeddedJpeg?> _walk(
    _ByteSource source,
    int? longEdge, {
    int? minLongEdge,
  }) async {
    final probe = await _probeWalk(
      source,
      longEdge,
      minLongEdge: minLongEdge,
      strictBitstream: false,
    );
    return probe.jpeg;
  }

  /// The one implementation behind both [_walk] and [probeEmbeddedJpeg]. With
  /// [strictBitstream] false its `jpeg` field is bit-for-bit what [_walk]
  /// returned before M7 Task 3; the `malformed` field is new information
  /// computed alongside, never a change of selection.
  ///
  /// Reading a strip to decide `malformed` costs nothing on the hot paths: the
  /// selected candidate's read is the one [_walk] already performs, and the
  /// other candidates are only touched when that read fails.
  static Future<DngEmbeddedJpegProbe> _probeWalk(
    _ByteSource source,
    int? longEdge, {
    int? minLongEdge,
    required bool strictBitstream,
  }) async {
    const miss = DngEmbeddedJpegProbe(jpeg: null, malformed: false);
    final reader = await _readerFor(source);
    if (reader == null) return miss;
    final ifd0 = await _readIFD0(reader);
    if (ifd0 == null) return miss;

    // Orientation lives in IFD0. The extraction path cannot express
    // "undetermined" -- it injects EXIF only for a known non-1 value -- so an
    // unreadable tag folds to 1 exactly as it did before AC12h. An
    // out-of-range value folds to 1 too (M7 ruling E): a file claiming
    // orientation 0 or 9 must not propagate that into pixel-orientation
    // baking downstream.
    final orientation = _sanitizeOrientation(
      await _orientationOf(reader, ifd0),
    );

    final scan = await _gatherCandidates(reader, source, ifd0, longEdge);
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

    final jpegBytes = await _readStrip(source, best, strictBitstream);
    if (jpegBytes == null) {
      // The selected strip did not read back. Malformed only if NO declared
      // candidate is readable -- one bad strip beside a good one is not a
      // broken container. `.any()` can't take an async predicate, so this is
      // an explicit loop rather than the original one-liner.
      var anyReadable = false;
      for (final c in scan.candidates) {
        if (identical(c, best)) continue;
        if (await _readStrip(source, c, strictBitstream) != null) {
          anyReadable = true;
          break;
        }
      }
      return DngEmbeddedJpegProbe(jpeg: null, malformed: !anyReadable);
    }

    var bytes = jpegBytes;
    if (orientation != 1) {
      final oriented = await _injectExifOrientation(jpegBytes, orientation);
      if (oriented != null) bytes = oriented;
    }
    return DngEmbeddedJpegProbe(
      jpeg: DngEmbeddedJpeg(
        bytes: bytes,
        width: best.width,
        height: best.height,
        orientation: orientation,
        offset: best.offset,
        byteCount: best.byteCount,
      ),
      malformed: false,
    );
  }

  /// Reads one candidate's strip, returning `null` when it is unreadable:
  /// out of bounds, short of its declared byte count, or -- when
  /// [strictBitstream] -- not starting with a JPEG SOI marker.
  static Future<Uint8List?> _readStrip(
    _ByteSource source,
    _Candidate candidate,
    bool strictBitstream,
  ) async {
    final bytes = await source.read(candidate.offset, candidate.byteCount);
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
  static Future<_CandidateScan?> _gatherCandidates(
    _TIFFReader reader,
    _ByteSource source,
    Map<int, _IFDEntry> ifd0,
    int? longEdge,
  ) async {
    Future<(int, int)?> cropSize(Map<int, _IFDEntry> entries) async {
      final entry = entries[0xC620];
      if (entry == null) return null;
      final vals = await reader.values(entry);
      if (vals == null || vals.length < 2) return null;
      return (vals[0], vals[1]);
    }

    // Gather IFD0 plus every SubIFD (tag 0x014A) as candidates.
    final candidateIFDs = <Map<int, _IFDEntry>>[ifd0];
    final subEntry = ifd0[0x014A];
    if (subEntry != null) {
      final subOffsets = await reader.values(subEntry);
      if (subOffsets != null) {
        for (final off in subOffsets) {
          final sub = await reader.readIFD(off);
          if (sub != null) candidateIFDs.add(sub.$1);
        }
      }
    }

    // Also follow the ordinary TIFF `nextIFD` chain (IFD0 -> IFD1 -> IFD2 ->
    // ...), which the SubIFD-only gather above never visits. Sony ARW keeps
    // its full-resolution JPEG in IFD2, reachable only this way (2026-08-30
    // payload-bench-report.md §3). Cycle- and depth-bounded: `visited` stops
    // a maliciously/corruptly self-referencing chain, and the depth cap keeps
    // a hostile file from turning this into an unbounded walk.
    final ifd0Offset = await reader.u32(4);
    if (ifd0Offset != null) {
      final visited = <int>{ifd0Offset};
      var nextOffset = (await reader.readIFD(ifd0Offset))?.$2;
      var depth = 0;
      while (nextOffset != null &&
          nextOffset != 0 &&
          depth < 16 &&
          !visited.contains(nextOffset)) {
        visited.add(nextOffset);
        final result = await reader.readIFD(nextOffset);
        if (result == null) break;
        candidateIFDs.add(result.$1);
        nextOffset = result.$2;
        depth++;
      }
    }

    // DefaultCropSize (0xC620) may live in IFD0 or in one of the SubIFDs.
    var defaultCrop = await cropSize(ifd0);
    if (defaultCrop == null) {
      for (final ifd in candidateIFDs) {
        final c = await cropSize(ifd);
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
    // A Panasonic container has no DefaultCropSize (0xC620) at all, so without
    // this the full-size request below would bail before looking at a single
    // candidate. Its own width/height tags stand in for the same quantity: the
    // sensor extent the full-size floor is measured against.
    if (cropMax <= 0 && reader.isPanasonic) {
      cropMax = await _panasonicSensorMax(reader, ifd0);
    }
    // The 0.90 * cropMax floor only guards the full-size request; without a
    // usable DefaultCropSize that request cannot be judged at all.
    if (longEdge == null && cropMax <= 0) return null;

    final candidates = <_Candidate>[];
    var unreadable = 0;

    for (final ifd in candidateIFDs) {
      final compEntry = ifd[0x0103];
      if (compEntry == null) continue;
      final compVals = await reader.values(compEntry);
      if (compVals == null || compVals.isEmpty) continue;
      // 7 is the "new-style JPEG" TIFF compression value; Sony additionally
      // ships JPEG-bearing IFDs (IFD0 PreviewImage, IFD2 full-res) tagged 6
      // ("old-style JPEG") -- payload-bench-report.md §3. 32766 (Sony ARW
      // sensor data) and every other value stay excluded.
      final compression = compVals.first;
      if (compression != 6 && compression != 7) continue;

      // PhotometricInterpretation is REQUIRED to be 6 (YCbCr) when present,
      // but not required to be present: Sony's IFD1 (the standard EXIF
      // thumbnail IFD -- ThumbnailOffset/Length live at 0x0201/0x0202 there)
      // carries Compression 6 and a real JPEG thumbnail with no
      // PhotometricInterpretation tag at all (verified via exiftool against
      // a real A7M5 ARW, live-proof run in
      // docs/logs/2026-08-30/pipeline-followup-contract.md round-2 D4).
      // Demanding the tag would silently drop every legacy thumbnail IFD of
      // this shape, which is exactly the small candidate the longEdge-driven
      // sidebar/preview selection needs.
      final photoEntry = ifd[0x0106];
      if (photoEntry != null) {
        final photoVals = await reader.values(photoEntry);
        if (photoVals == null || photoVals.isEmpty || photoVals.first != 6) {
          continue;
        }
      }

      // Locate the strip: either the standard StripOffsets/StripByteCounts
      // pair (0x0111/0x0117) or the JPEGInterchangeFormat/Length pair
      // (0x0201/0x0202) Sony uses for both IFD0's PreviewImage and IFD2's
      // full-res JPEG. Strip tags are tried first (existing DNG behaviour
      // unchanged); interchange tags are the fallback.
      int? offset;
      int? byteCount;
      var isInterchange = false;
      final stripOffEntry = ifd[0x0111];
      final stripCountEntry = ifd[0x0117];
      if (stripOffEntry != null && stripCountEntry != null) {
        final stripOffVals = await reader.values(stripOffEntry);
        final stripCountVals = await reader.values(stripCountEntry);
        if (stripOffVals != null &&
            stripOffVals.length == 1 &&
            stripCountVals != null &&
            stripCountVals.length == 1) {
          offset = stripOffVals[0];
          byteCount = stripCountVals[0];
        }
      }
      if (offset == null || byteCount == null) {
        final jifOffEntry = ifd[0x0201];
        final jifLenEntry = ifd[0x0202];
        if (jifOffEntry != null && jifLenEntry != null) {
          final jifOffVals = await reader.values(jifOffEntry);
          final jifLenVals = await reader.values(jifLenEntry);
          if (jifOffVals != null &&
              jifOffVals.length == 1 &&
              jifLenVals != null &&
              jifLenVals.length == 1) {
            offset = jifOffVals[0];
            byteCount = jifLenVals[0];
            isInterchange = true;
          }
        }
      }
      if (offset == null || byteCount == null) continue;

      // Width/height. For the strip pair (0x0111/0x0117) this stays exactly
      // what it was: the IFD's own ImageWidth/ImageLength (both DNG SubIFDs
      // and Sony's IFD2 carry these describing THAT strip). The interchange
      // pair (0x0201/0x0202) does not get the same trust: on Sony, IFD0's
      // 0x0100/0x0101 (when present) describe the sensor/thumbnail extent,
      // not the PreviewImage blob those tags point at, so an interchange
      // candidate's dimensions are always read from the JPEG bitstream's own
      // SOFn frame header instead -- the same bounds-checked technique
      // already used for Panasonic blob candidates below.
      int? width;
      int? height;
      if (!isInterchange) {
        final widthEntry = ifd[0x0100];
        final heightEntry = ifd[0x0101];
        if (widthEntry == null || heightEntry == null) continue;
        final widthVals = await reader.values(widthEntry);
        final heightVals = await reader.values(heightEntry);
        if (widthVals == null || widthVals.isEmpty) continue;
        if (heightVals == null || heightVals.isEmpty) continue;
        width = widthVals.first;
        height = heightVals.first;
      } else {
        // Bounds-check BEFORE reading, and count an out-of-range interchange
        // offset as `unreadable` (a declared-but-broken candidate) rather
        // than silently `continue`ing as "not a candidate" -- this pair is
        // just as much a declaration as StripOffsets/StripByteCounts, so it
        // gets the same AD-022 malformed-container signal.
        if (offset < 0 ||
            byteCount <= 0 ||
            offset >= source.length ||
            offset + byteCount > source.length) {
          unreadable++;
          continue;
        }
        final soi = await source.read(offset, 2);
        if (soi != null &&
            soi.length >= 2 &&
            soi[0] == 0xFF &&
            soi[1] == 0xD8) {
          final size = await _jpegFrameSize(source, offset, byteCount);
          if (size != null) {
            width = size.$1;
            height = size.$2;
          }
        }
        // In range but no readable frame header (not a JPEG, or the SOFn
        // marker is unreachable within the scan limit) is a reader
        // limitation, not proven damage -- same ruling as the Panasonic
        // blob path -- so this is a plain miss, not `unreadable`.
        if (width == null || height == null) continue;
      }

      final maxDim = width > height ? width : height;
      if (longEdge == null && maxDim < 0.90 * cropMax) continue;

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

    if (reader.isPanasonic) {
      await _gatherPanasonicCandidates(
        reader,
        source,
        ifd0,
        longEdge,
        cropMax,
        candidates,
        () => unreadable++,
      );
    }

    return _CandidateScan(
      candidates: candidates,
      unreadable: unreadable,
      cropMax: cropMax,
    );
  }

  /// IFD0 tags holding a whole JPEG bitstream in a Panasonic RW2, in the order
  /// they appear in the file. Both are UNDEFINED-typed blobs whose `count` IS
  /// the byte length -- there is no StripOffsets/StripByteCounts pair, and no
  /// SubIFD, so the loop above cannot see them:
  ///
  ///  - 0x002E "JpgFromRaw": the small rendition (1920x1280 in the reference
  ///    sample, 446,960 bytes at offset 6144).
  ///  - 0x0127 "JpgFromRaw2": the full-size rendition (6000x4000, 3,593,728
  ///    bytes at offset 453,120).
  ///
  /// Measured with `scripts/tmp/rw2_ifd_probe.py` /
  /// `scripts/tmp/rw2_blob_dims.py`; output kept under `tmp/verify/`.
  static const List<int> _panasonicPreviewTags = <int>[0x002E, 0x0127];

  /// Panasonic IFD0 extent tags, most specific first: (width, height) pairs of
  /// image size (0x0007/0x0006) then sensor size (0x0002/0x0003).
  static const List<(int, int)> _panasonicExtentTags = <(int, int)>[
    (0x0007, 0x0006),
    (0x0002, 0x0003),
  ];

  /// Ceiling on how far into a Panasonic blob the frame-header walk may read
  /// before giving up. A JPEG's SOFn sits within the first few kilobytes in
  /// practice; the cap is what keeps a hostile bitstream from turning candidate
  /// gathering into a full-file scan.
  static const int _jpegFrameScanLimit = 64 * 1024;
  static const int _jpegFrameScanMaxSegments = 64;

  /// Appends the Panasonic blob candidates found in [ifd0].
  ///
  /// The bounds checks are the same ones the strip path applies, in the same
  /// order, and a blob that fails them counts as unreadable via [onUnreadable]
  /// -- the container declared a preview it cannot deliver (AD-022). Two
  /// rejections are deliberately NOT unreadable: a tag whose type is not a byte
  /// blob is "not a candidate" (absence, exactly like a missing Compression
  /// tag), and a blob whose SOI is present but whose frame header is not found
  /// within [_jpegFrameScanLimit] is dropped as unmeasurable rather than
  /// declared broken -- that is a limit of this bounded reader, not proven
  /// damage, and reporting it as damage would replace a working RAW decode with
  /// a broken-file error.
  static Future<void> _gatherPanasonicCandidates(
    _TIFFReader reader,
    _ByteSource source,
    Map<int, _IFDEntry> ifd0,
    int? longEdge,
    int cropMax,
    List<_Candidate> candidates,
    void Function() onUnreadable,
  ) async {
    for (final tag in _panasonicPreviewTags) {
      final entry = ifd0[tag];
      if (entry == null) continue;
      // UNDEFINED / BYTE only: one element per byte, so `count` is the length.
      if (entry.type != 7 && entry.type != 1) continue;
      final byteCount = entry.count;
      if (byteCount <= 0) continue;

      // Same inline-vs-out-of-line rule `values()` uses: a value field holds up
      // to 4 bytes, anything longer is an offset.
      int offset;
      if (byteCount <= 4) {
        offset = entry.valueFieldOffset;
      } else {
        final resolved = await reader.u32(entry.valueFieldOffset);
        if (resolved == null) {
          onUnreadable();
          continue;
        }
        offset = resolved;
      }

      if (offset < 0 ||
          offset >= source.length ||
          offset + byteCount > source.length) {
        onUnreadable();
        continue;
      }

      final soi = await source.read(offset, 2);
      if (soi == null || soi.length < 2 || soi[0] != 0xFF || soi[1] != 0xD8) {
        onUnreadable();
        continue;
      }

      // Panasonic states the preview's extent nowhere in the IFD, so the only
      // honest source for it is the bitstream's own frame header.
      final size = await _jpegFrameSize(source, offset, byteCount);
      if (size == null) continue;
      final width = size.$1;
      final height = size.$2;

      final maxDim = width > height ? width : height;
      if (longEdge == null && maxDim < 0.90 * cropMax) continue;

      candidates.add(
        _Candidate(
          width: width,
          height: height,
          offset: offset,
          byteCount: byteCount,
        ),
      );
    }
  }

  /// Largest edge Panasonic IFD0 claims for the frame, or 0 when neither tag
  /// pair is readable. Stands in for DefaultCropSize's role in the full-size
  /// `0.90 * cropMax` floor.
  static Future<int> _panasonicSensorMax(
    _TIFFReader reader,
    Map<int, _IFDEntry> ifd0,
  ) async {
    final extent = await _panasonicExtent(reader, ifd0);
    if (extent == null) return 0;
    return extent.width > extent.height ? extent.width : extent.height;
  }

  /// Panasonic IFD0's own width/height, or `null` when neither pair is present
  /// and readable.
  static Future<({int width, int height})?> _panasonicExtent(
    _TIFFReader reader,
    Map<int, _IFDEntry> ifd0,
  ) async {
    for (final pair in _panasonicExtentTags) {
      final widthEntry = ifd0[pair.$1];
      final heightEntry = ifd0[pair.$2];
      if (widthEntry == null || heightEntry == null) continue;
      final widthVals = await reader.values(widthEntry);
      final heightVals = await reader.values(heightEntry);
      if (widthVals == null || widthVals.isEmpty) continue;
      if (heightVals == null || heightVals.isEmpty) continue;
      final width = widthVals.first;
      final height = heightVals.first;
      if (width <= 0 || height <= 0) continue;
      return (width: width, height: height);
    }
    return null;
  }

  /// `(width, height)` from the first SOFn frame header inside the JPEG that
  /// starts at [offset], or `null` when no frame header is reachable within the
  /// scan limits. Assumes the SOI marker has already been verified.
  ///
  /// Every read goes through the bounds-checked [source]; a segment length that
  /// would walk past the blob simply ends the scan.
  static Future<(int, int)?> _jpegFrameSize(
    _ByteSource source,
    int offset,
    int byteCount,
  ) async {
    final limit = byteCount < _jpegFrameScanLimit
        ? byteCount
        : _jpegFrameScanLimit;
    var pos = 2; // just past SOI
    var segments = 0;
    while (pos + 4 <= limit && segments < _jpegFrameScanMaxSegments) {
      final head = await source.read(offset + pos, 4);
      if (head == null) return null;
      if (head[0] != 0xFF) return null;
      final marker = head[1];
      if (marker == 0xFF) {
        pos += 1; // fill byte before the real marker
        continue;
      }
      if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        pos += 2; // standalone marker, no length field
        segments++;
        continue;
      }
      if (marker == 0xD9 || marker == 0xDA) return null; // EOI / SOS
      final segLen = (head[2] << 8) | head[3];
      if (segLen < 2) return null;
      if (_isStartOfFrame(marker)) {
        // SOFn payload: precision(1) height(2) width(2).
        if (segLen < 7) return null;
        final frame = await source.read(offset + pos + 4, 5);
        if (frame == null || frame.length < 5) return null;
        final height = (frame[1] << 8) | frame[2];
        final width = (frame[3] << 8) | frame[4];
        if (width <= 0 || height <= 0) return null;
        return (width, height);
      }
      pos += 2 + segLen;
      segments++;
    }
    return null;
  }

  /// True for the SOFn markers that carry a frame header. 0xC4 (DHT), 0xC8
  /// (JPG extension) and 0xCC (DAC) share the range but are not frame headers.
  static bool _isStartOfFrame(int marker) =>
      marker >= 0xC0 &&
      marker <= 0xCF &&
      marker != 0xC4 &&
      marker != 0xC8 &&
      marker != 0xCC;

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
  static Future<bool?> _detectByteOrder(_ByteSource source) async {
    final head = await source.read(0, 2);
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
  static Future<Uint8List?> _injectExifOrientation(
    Uint8List jpeg,
    int orientation,
  ) async {
    if (jpeg.length < 2) return jpeg;
    if (jpeg[0] != 0xFF || jpeg[1] != 0xD8) return jpeg;

    if (await _jpegHasExifOrientation(jpeg)) return jpeg;

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
  static Future<bool> _jpegHasExifOrientation(Uint8List jpeg) async {
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
            if (await _tiffDataHasOrientation(tiffData)) return true;
          }
        }
      }
      pos += 2 + segLen;
    }
    return false;
  }

  static Future<bool> _tiffDataHasOrientation(Uint8List tiffData) async {
    if (tiffData.length < 8) return false;
    final reader = await _readerFor(_MemorySource(tiffData));
    if (reader == null) return false;
    final ifd0 = await _readIFD0(reader);
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
  const _CandidateScan({
    required this.candidates,
    required this.unreadable,
    required this.cropMax,
  });

  final List<_Candidate> candidates;
  final int unreadable;

  /// The largest edge of DefaultCropSize (0xC620), or the Panasonic
  /// sensor-extent stand-in when that tag is absent (see [_panasonicSensorMax]).
  /// 0 when neither is available. Carried out of the gather step (2026-09-05
  /// P1b) so a caller performing exactly one walk (see
  /// [DngEmbeddedJpegExtractor.probeFile]) can apply the full-size `0.90 *
  /// cropMax` floor itself, after the fact, without re-walking to recompute
  /// it -- the same number [_gatherCandidates] already derives internally to
  /// apply that same floor when `longEdge == null`.
  final int cropMax;
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
  ///
  /// `Future`-returning uniformly (even for the fully-resident
  /// [_MemorySource], where it resolves without any real asynchronous gap):
  /// this lets the whole IFD walk below be written once and shared by both
  /// the in-memory and file-backed sources, rather than maintaining two
  /// copies of ~600 lines of bounds-checked TIFF parsing (2026-09-04 W4 --
  /// see class dartdoc note on [_FileSource]).
  Future<Uint8List?> read(int offset, int count);

  /// Whether any read against this source failed for an I/O reason (the read
  /// threw, or came back short) as opposed to being refused by the bounds
  /// check.
  ///
  /// THE distinction the walk could not previously express. Every `read`
  /// returns `null` for both cases and the whole walk is built on that null,
  /// so "this container declares no preview" and "the volume hiccuped while we
  /// were reading its preview" reached the caller as the same answer -- and the
  /// caller latches that answer for the session (the cost memo in
  /// `prefetch_scheduler.dart` and `_permanentMisses` in the preload
  /// controller). Recording the reason on the SOURCE, rather than threading a
  /// result type through several hundred lines of bounds-checked walk, keeps
  /// the fix to one flag plus one retry.
  bool get ioError;

  /// Human-readable detail of the FIRST fault, for the diagnostic line. Null
  /// when [ioError] is false.
  String? get faultDetail;
}

class _MemorySource implements _ByteSource {
  _MemorySource(this._data);

  final Uint8List _data;

  /// Always false: a resident `Uint8List` cannot fail to be read. Only an
  /// out-of-bounds request returns null here, and that is a structural answer
  /// about the data, not a fault.
  @override
  bool get ioError => false;

  @override
  String? get faultDetail => null;

  @override
  int get length => _data.length;

  @override
  Future<Uint8List?> read(int offset, int count) async {
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

  bool _ioError = false;

  /// First fault only, as `offset=..,want=..,got=..,len=..` (or the thrown
  /// error). Diagnostics carry it because the interesting question in the field
  /// is WHERE the read stopped -- a strip read that returns a few bytes short
  /// of an 8MB request looks nothing like one that returns zero.
  String? _faultDetail;

  @override
  bool get ioError => _ioError;

  @override
  String? get faultDetail => _faultDetail;

  @override
  final int length;

  @override
  Future<Uint8List?> read(int offset, int count) async {
    if (offset < 0 || count < 0 || offset + count > length) return null;
    if (count == 0) return Uint8List(0);
    if (count >= _directReadThreshold) return _readDirect(offset, count);

    final out = Uint8List(count);
    var written = 0;
    var cursor = offset;
    while (written < count) {
      final pageIndex = cursor ~/ _pageSize;
      final page = await _page(pageIndex);
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

  Future<Uint8List?> _page(int pageIndex) async {
    final cached = _pages.remove(pageIndex);
    if (cached != null) {
      _pages[pageIndex] = cached; // refresh LRU position
      return cached;
    }
    final start = pageIndex * _pageSize;
    if (start >= length) return null;
    final want = (length - start) < _pageSize ? (length - start) : _pageSize;
    final bytes = await _readDirect(start, want);
    if (bytes == null) return null;
    _pages[pageIndex] = bytes;
    if (_pages.length > _maxPages) _pages.remove(_pages.keys.first);
    return bytes;
  }

  /// The one place that actually touches the disk. `await`s the async
  /// [RandomAccessFile.setPosition]/[RandomAccessFile.read] pair instead of
  /// their `Sync` counterparts (2026-09-04 W4): the previous `setPositionSync`
  /// + `readSync` pair issued a blocking syscall directly on the calling
  /// isolate -- the UI isolate for every sidebar/preview probe -- which
  /// showed up as 40.9% of its busy time during the loading phase (dozens of
  /// cold 8KiB preads per file on an external volume; see
  /// docs/logs/2026-09-04/residual-jank-diagnosis.md addendum "recapture2").
  /// The async variants hand the read off to the VM's I/O thread pool and let
  /// the isolate's event loop keep servicing frames while the syscall is in
  /// flight. Page size, direct-read threshold and every bounds/fault-detail
  /// rule below are unchanged -- this is an I/O-mode change, not a parser or
  /// budget change.
  Future<Uint8List?> _readDirect(int offset, int count) async {
    try {
      await _raf.setPosition(offset);
      final bytes = await _raf.read(count);
      _onDiskRead?.call(bytes.length);
      if (bytes.length != count) {
        // A SHORT read of an in-bounds range. The caller already proved the
        // range fits inside `length`, so the only explanations are a file that
        // changed under us or a failing read -- both are faults, neither means
        // "no preview here".
        _ioError = true;
        _faultDetail ??=
            'short:offset=$offset,want=$count,got=${bytes.length},len=$length';
        return null;
      }
      return bytes;
    } catch (e) {
      _ioError = true;
      _faultDetail ??=
          'threw:offset=$offset,want=$count,len=$length,err=${e.runtimeType}';
      return null;
    }
  }
}

/// Minimal bounds-checked TIFF/IFD reader used to walk DNG structure without
/// pulling in a full TIFF library. Operates on untrusted data: every read is
/// bounds-checked against the source length and returns `null` rather than
/// throwing.
class _TIFFReader {
  _TIFFReader(this.source, this.littleEndian, this.version);

  final _ByteSource source;
  final bool littleEndian;

  /// The container's TIFF version word (byte offset 2), carried so the
  /// candidate gather can tell an Adobe-tagged container from a Panasonic one
  /// without re-reading the header. Never used for anything else.
  final int version;

  bool get isPanasonic =>
      version == DngEmbeddedJpegExtractor._tiffVersionPanasonic;

  Future<int?> u16(int offset) async {
    final b = await source.read(offset, 2);
    if (b == null) return null;
    return littleEndian ? (b[0] | (b[1] << 8)) : ((b[0] << 8) | b[1]);
  }

  Future<int?> u32(int offset) async {
    final b = await source.read(offset, 4);
    if (b == null) return null;
    return littleEndian
        ? (b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24))
        : ((b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]);
  }

  Future<int?> u8(int offset) async {
    final b = await source.read(offset, 1);
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
  Future<(Map<int, _IFDEntry>, int)?> readIFD(int offset) async {
    final entryCount = await u16(offset);
    if (entryCount == null) return null;
    final entries = <int, _IFDEntry>{};
    var pos = offset + 2;
    for (var i = 0; i < entryCount; i++) {
      final tag = await u16(pos);
      final type = await u16(pos + 2);
      final count = await u32(pos + 4);
      if (tag == null || type == null || count == null) return null;
      entries[tag] = _IFDEntry(
        tag: tag,
        type: type,
        count: count,
        valueFieldOffset: pos + 8,
      );
      pos += 12;
    }
    final next = await u32(pos);
    if (next == null) return null;
    return (entries, next);
  }

  /// Resolves an entry's values as ints. SHORT/LONG pass through directly;
  /// RATIONAL is reduced to a rounded quotient; BYTE is widened.
  /// Bounds-checked against the source length; returns `null` on any
  /// malformed/out-of-range field.
  Future<List<int>?> values(_IFDEntry entry) async {
    final size = _typeSize(entry.type);
    if (size <= 0 || entry.count <= 0 || entry.count >= 100000) return null;
    final totalBytes = entry.count * size;
    int base;
    if (totalBytes <= 4) {
      base = entry.valueFieldOffset;
    } else {
      final off = await u32(entry.valueFieldOffset);
      if (off == null) return null;
      base = off;
    }

    final result = <int>[];
    for (var i = 0; i < entry.count; i++) {
      final elemOffset = base + i * size;
      switch (entry.type) {
        case 3: // SHORT
        case 8: // SSHORT
          final v = await u16(elemOffset);
          if (v == null) return null;
          result.add(v);
          break;
        case 4: // LONG
        case 9: // SLONG
          final v = await u32(elemOffset);
          if (v == null) return null;
          result.add(v);
          break;
        case 5: // RATIONAL
        case 10: // SRATIONAL
          final numerator = await u32(elemOffset);
          final denominator = await u32(elemOffset + 4);
          if (numerator == null || denominator == null || denominator == 0) {
            return null;
          }
          final quotient = numerator / denominator;
          result.add(quotient < 0 ? 0 : quotient.round());
          break;
        case 1: // BYTE
        case 6: // SBYTE
        case 7: // UNDEFINED
          final v = await u8(elemOffset);
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
