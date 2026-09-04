import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import '../../models/supported_photo_formats.dart';
import '../../perf/perf_log.dart'; // PERF-INSTRUMENTATION (D1)
import 'bitmap_container_probe.dart';
import 'dng_decode_contract.dart';
import 'dng_embedded_jpeg_extractor.dart';
import 'image_source_types.dart';

/// Memo key for the sidebar embedded-JPEG walk: the canonical file path plus
/// the requested long edge (2026-09-04 W4b). `path` stands in for "photo id"
/// here -- this file has no `PhotoItem`/id type of its own (contract C-3/the
/// pure-Dart posture), and the path IS the walk's actual input, so it is the
/// correct identity for "would this walk produce the same answer again".
/// `longEdge` is part of the key for the same reason `PrefetchScheduler`
/// keys its cost memo by long edge (F5/AC7, `prefetch_scheduler.dart`): a
/// verdict measured against one requested size says nothing about a
/// differently-sized request, and this loader's sidebar branch already always
/// asks for the same `purpose.targetSize`, but keying on it rather than
/// hard-coding that assumption keeps this memo correct if that ever changes.
class _SidebarWalkKey {
  const _SidebarWalkKey(this.path, this.longEdge);
  final String path;
  final int longEdge;

  @override
  bool operator ==(Object other) =>
      other is _SidebarWalkKey &&
      other.path == path &&
      other.longEdge == longEdge;

  @override
  int get hashCode => Object.hash(path, longEdge);
}

/// Cap on how many (path, longEdge) walks the sidebar memo retains at once.
///
/// "Folder-sized is fine" (task instruction): a single photo folder rarely
/// exceeds a few thousand items, and this memo -- like `_FileSource`'s page
/// LRU in `dng_embedded_jpeg_extractor.dart` -- evicts the OLDEST entry once
/// full rather than growing without bound across a long multi-folder session.
/// Safe to size purely by ENTRY COUNT now (round-2 fix below): every entry is
/// a handful of ints, not a byte buffer.
const int _sidebarWalkMemoCap = 4096;

/// A memoized walk's VERDICT ONLY -- never the decoded/extracted bytes.
///
/// 2026-09-04 W4b round-2 (BLOCKER-2 fix): the first cut of this memo stored
/// the whole [DngEmbeddedJpeg], which carries the selected candidate's
/// multi-MB JPEG bitstream in [DngEmbeddedJpeg.bytes]. An entry-count cap is
/// blind to bytes, so a big folder full of large-preview RAWs could retain
/// hundreds of MB outside `kPayloadByteBudget` and the `ImageCache` budget
/// for the whole folder session -- the `PrefetchScheduler` analogy this memo
/// was built on does not hold, because THAT memo stores a scalar cost
/// verdict, not a payload. This record is the fix: `(offset, byteCount,
/// orientation)` is everything [DngEmbeddedJpegExtractor.readKnownStrip]
/// needs to cheaply REPLAY the exact same bytes without repeating the
/// expensive part (the IFD0/SubIFD walk -- dozens of cold 8KiB page reads).
/// `null` fields on the record itself are not used; `null` is instead
/// represented as an ABSENT `bytes` marker below.
typedef _SidebarWalkVerdict = ({int offset, int byteCount, int orientation});

/// `null` value in the memo map below means "walked and confirmed: no
/// qualifying embedded candidate" -- a genuine, memoizable miss, distinct
/// from "not yet walked" (an absent key). Mirrors [DngEmbeddedJpeg]? being
/// nullable for the same reason in the extractor itself.
///
/// id/path+longEdge -> the walk's verdict, first-writer-wins within a key
/// (mirrors [PrefetchScheduler]'s `_cost` memo: the sidebar's IFD/SubIFD walk
/// is deterministic for a given file and long edge, so a second sidebar
/// decode of the same item must not repeat it). `LinkedHashMap` so the oldest
/// entry can be evicted in insertion order when [_sidebarWalkMemoCap] is
/// exceeded.
final LinkedHashMap<_SidebarWalkKey, _SidebarWalkVerdict?> _sidebarWalkMemo =
    LinkedHashMap<_SidebarWalkKey, _SidebarWalkVerdict?>();

/// Cap on how many paths [_fileProbeMemo] retains at once. Same "folder-sized
/// is fine" reasoning as [_sidebarWalkMemoCap] (2026-09-05 P1b): every entry
/// is a [DngFileProbe] -- ints plus a small candidate list, never bytes.
const int _fileProbeMemoCap = 4096;

/// The ONE-WALK probe record per path (2026-09-05, P1b,
/// `pipeline-architecture-v2.md` §2.2a): [DngEmbeddedJpegExtractor.probeFile]
/// performs a single IFD0/SubIFD walk answering every question this loader
/// used to ask the extractor separately (orientation, dimensions, and every
/// embedded-JPEG candidate for both the sidebar and full-size/preview
/// selection). This memo is what lets a second question about the same path
/// -- regardless of which of the four call sites asks it -- cost zero
/// additional disk reads for the walk itself; only the final strip read (via
/// [DngEmbeddedJpegExtractor.selectAndRead]) still touches disk, and that is
/// unavoidable per selected candidate. `null` means "walked and confirmed:
/// not a parseable TIFF/DNG container" -- a genuine memoizable miss, distinct
/// from "not yet walked" (an absent key), mirroring [_sidebarWalkMemo]'s own
/// convention.
final LinkedHashMap<String, DngFileProbe?> _fileProbeMemo =
    LinkedHashMap<String, DngFileProbe?>();

/// In-flight probe walks keyed by path, so two concurrent questions about a
/// not-yet-memoized path (e.g. a preview load and a sidebar load racing for
/// the same file) share the same walk rather than each starting their own.
final Map<String, Future<({DngFileProbe? probe, bool transientFault})>>
_fileProbeInFlight = <String, Future<({DngFileProbe? probe, bool transientFault})>>{};

/// Test-only: how many times [DngEmbeddedJpegExtractor.probeFile] actually
/// ran (as opposed to a memo/in-flight hit). Not reset automatically -- same
/// convention as [debugSidebarWalkCount].
int debugFileProbeWalkCount = 0;

/// Returns the memoized [DngFileProbe] for [path], walking exactly once per
/// path until [resetSidebarWalkMemo] clears the memo.
///
/// Round review BLOCKER-3 fix (2026-09-05): a walk that never got a clean
/// read -- every retry attempt inside [DngEmbeddedJpegExtractor.probeFile]
/// still faulted (`transientFault: true`) -- is deliberately NOT memoized.
/// Pre-fix, this cached `null` for the rest of the folder session on the
/// strength of a transient I/O hiccup on the external volume the user's
/// photos live on; downstream `_permanentMisses`-style bookkeeping then
/// upgraded that cached `null` into "confirmed unreadable" for the whole
/// session, exactly the failure mode `_readFileWithRetry`'s retry/backoff
/// exists to avoid. A structural `null` (genuinely not a parseable TIFF/DNG,
/// or the container has no candidates) stays memoized exactly as before --
/// only the FAULT-DERIVED case now falls through to a fresh walk on the next
/// question about the same path.
///
/// Also reports [transientFault] on the returned record so a CALLER that
/// maintains its own downstream cache derived from this probe -- as the
/// sidebar branch below does with `_sidebarWalkMemo` -- can apply the same
/// "never cache a fault-derived answer" rule to ITS cache too. Without this,
/// the per-path probe memo would correctly avoid caching the fault, but the
/// sidebar's own (path, longEdge) verdict memo would still cache the `null`
/// candidate that followed from it, reintroducing the exact bug one layer
/// down (caught by TC-947 while developing this fix).
Future<({DngFileProbe? probe, bool transientFault})> _fileProbeFor(
  String path,
) {
  if (_fileProbeMemo.containsKey(path)) {
    return Future<({DngFileProbe? probe, bool transientFault})>.value((
      probe: _fileProbeMemo[path],
      transientFault: false,
    ));
  }
  final inFlight = _fileProbeInFlight[path];
  if (inFlight != null) return inFlight;
  final future = DngEmbeddedJpegExtractor.probeFileResult(path).then((
    result,
  ) {
    debugFileProbeWalkCount++;
    if (!result.transientFault) {
      _fileProbeMemo[path] = result.probe;
      if (_fileProbeMemo.length > _fileProbeMemoCap) {
        _fileProbeMemo.remove(_fileProbeMemo.keys.first);
      }
    }
    _fileProbeInFlight.remove(path);
    return result;
  });
  _fileProbeInFlight[path] = future;
  return future;
}

/// Clears the per-path probe walk memo AND the sidebar verdict memo.
///
/// Extended 2026-09-05 (P1b) to also cover [_fileProbeMemo]: the sidebar
/// memo it originally covered is now itself downstream of the shared
/// per-path probe, so a folder reload must clear both for a stale probe not
/// to keep answering questions about a file that no longer applies. The name
/// is UNCHANGED on purpose -- `image_preload_controller.dart`'s `reset()`
/// (owned by a different task, #16) calls this function by name, and this
/// keeps that call site working with zero edits there.
///
/// Called wherever `PrefetchScheduler.reset()` is called (currently
/// `ImagePreloadController.reset()`, on a folder reload) -- this file has no
/// class instance of its own for a folder-reload hook to call through, so
/// that wiring lives in the caller (image_preload_controller.dart), not here.
void resetSidebarWalkMemo() {
  _sidebarWalkMemo.clear();
  _fileProbeMemo.clear();
  _fileProbeInFlight.clear();
}

/// Test-only: the raw verdict stored for `(path, longEdge)`, or a sentinel
/// when no entry exists yet. Exists so a test can assert the memo's stored
/// VALUE holds no [Uint8List]/[DngEmbeddedJpeg] -- i.e. prove BLOCKER-2 stays
/// fixed -- without this file exposing its private key/value types.
const Object debugSidebarWalkMemoNoEntry = Object();
Object? debugSidebarWalkMemoRawValueFor(String path, int longEdge) {
  final key = _SidebarWalkKey(path, longEdge);
  if (!_sidebarWalkMemo.containsKey(key)) return debugSidebarWalkMemoNoEntry;
  return _sidebarWalkMemo[key];
}

/// Test-only: how many times the sidebar branch actually performed a fresh
/// walk (as opposed to short-circuiting from [_sidebarWalkMemo]). Mirrors
/// `CeyxEncodeService.debugIsolateSpawnCount`'s convention. Not reset
/// automatically -- callers should read the delta across a test case.
///
/// Not `@visibleForTesting` (`package:meta` is not a declared dependency of
/// this package -- adding it would touch `pubspec.yaml`, outside this task's
/// file ownership): production code has no reason to read this, but nothing
/// stops it from doing so, same as an ordinary top-level counter would.
int debugSidebarWalkCount = 0;

/// Pure-Dart production implementation of the `NativeImageLoad` seam
/// (photo_source.dart:76-80). Replaces the deleted native thumbnail
/// MethodChannel as the production byte producer (M6 C-1/C-2). Free of
/// Platform checks by construction (C-3).
///
/// Invariants:
/// - [NativeImageNeedsRawDecode] is emitted ONLY for
///   `purpose == ImageRequestPurpose.preview` on a path the engine can decode
///   (`SupportedPhotoFormats.isDecodablePath`, derived from the engine's own
///   `kSupportedDecodeExtensions`). It was `.dng`-only until the 2026-08-26
///   RAW-coverage contract generalised the route; the part the sidebar's
///   permanent-miss logic depends on — that it is NEVER emitted for
///   `sidebarThumbnail`, nor for `export` — is unchanged and must stay so.
///   Browse-only RAW (`.cr2`/`.iiq`/`.mrw`, contract decision D2) has no
///   decode route and therefore never yields this variant either.
///   CAVEAT (F4): "never emitted for `export`" is a statement about this
///   function's `export` ARGUMENT, not about the export feature. The export
///   service enters through `purpose: preview`
///   (`photo_export_service.dart:57-58`) precisely so that it DOES receive
///   this signal and can decode a preview-less RAW; nothing in `lib/` passes
///   `ImageRequestPurpose.export` to this loader at all.
/// - This file stays free of `Platform` checks by construction (C-3). "No
///   native decoder on this platform" (contract decision D3) is therefore NOT
///   decided here: the loader still reports [NativeImageNeedsRawDecode], and
///   the caller that owns the decoder seam converts an absent decoder into
///   [kNoNativeDecoderCode].
/// - Never throws: every failure is a [NativeImageFailure].
Future<NativeImageResult> dartImageLoad(
  String path, {
  required ImageRequestPurpose purpose,
  // F4/AC6: the LIVE viewport long edge, or null for "use purpose.targetSize".
  // See [NativeImageLoad]'s doc — this is the one number the preview floor and
  // the routing verdict must share. Only the PREVIEW floor consults it; the
  // sidebar branch keeps `purpose.targetSize` because AD-021's uneven floor
  // (strict preview, lenient sidebar) is deliberate and stays.
  int? targetLongEdge,
  // Injected so this file needs no format knowledge beyond the registry
  // predicate and stays free of Platform checks (contract C-3): HEIC's extent
  // and orientation live in ISO-BMFF boxes that the TIFF IFD0 walker cannot
  // read, and reaching them means an FFI call that must not exist in a unit
  // test.
  BitmapContainerProbe probe = probeBitmapContainer,
}) async {
  // Derived, never restated: the SAME set the folder-scan whitelist uses
  // (`SupportedPhotoFormats.engineBitstreamExtensions`), so a format added to
  // the scan cannot silently miss this branch and fall through to the RAW
  // path. `.webp` joins here in phase 1 — the Flutter engine's codec reads it
  // natively on every platform.
  final isEncodedBitstream = SupportedPhotoFormats.isEncodedBitstreamPath(path);
  try {
    if (!await File(path).exists()) {
      // Deviation from the plan's verbatim listing (reported to the lead):
      // the walker degrades a missing file to the same "no candidate" null
      // as a genuine no-preview DNG, which would otherwise misclassify a
      // missing file as NeedsRawDecode instead of an explicit failure — the
      // exact case test/dart_image_loader_test.dart's "missing file is a
      // failure, not a throw" pins. Checked before BOTH branches so a
      // missing .jpg reports NOT_FOUND too, not DART_LOADER_ERROR
      // (round-review nit, 2026-08-24).
      return const NativeImageFailure('NOT_FOUND', 'file does not exist');
    }
    if (isEncodedBitstream) {
      // PERF-INSTRUMENTATION (D1 AC3 marker): which decode branch fired.
      PerfLog.log('decode|phase=encodedBitstream|path=$path');
      return NativeImageBytes(await File(path).readAsBytes());
    }
    // Already-rendered bitmap containers (phase 1: TIFF). No embedded-preview
    // walk runs for these at all: `DngEmbeddedJpegExtractor` is a RAW-preview
    // walker, and a scanner TIFF's IFD0 IS the image, so "extract the embedded
    // preview" is meaningless here. Placing the branch above the walk is what
    // makes that structural rather than a comment — and it is also why
    // `declaredPreviewsUnreadable` is always false for a TIFF, leaving
    // AD-022's two RAW-specific end states untouched.
    if (SupportedPhotoFormats.isBitmapDecodePath(path)) {
      if (purpose != ImageRequestPurpose.preview) {
        // The AD-010 invariant, preserved verbatim: NeedsRawDecode is emitted
        // for the preview purpose ONLY. The sidebar's own sized-decode
        // fallback (image_preload_controller.dart) is the only thumbnail
        // route for these files.
        return const NativeImageFailure(
          'NO_THUMBNAIL',
          'no embedded candidate',
        );
      }
      final extent = await probe(path);
      if (extent != null &&
          extent.width * extent.height * 4 > kDecodedPixelBudgetBytes) {
        // The budget moves WITH the escape hatch, so it covers TIFF and HEIC.
        // This is stricter than JPEG/WebP on purpose: these decodes happen on
        // the Dart heap or in the native decoder, where the failure mode is a
        // process OOM rather than an engine-side decode error. A null extent
        // (unreadable IFD0, or a HEIF probe that could not answer) waves
        // through, exactly as on the RAW path below.
        return const NativeImageFailure(
          'IMAGE_TOO_LARGE',
          'decode exceeds the decoded-pixel budget',
        );
      }
      // PERF-INSTRUMENTATION (D1 AC3 marker).
      PerfLog.log('decode|phase=bitmapNeedsRawDecode|path=$path');
      return NativeImageNeedsRawDecode(
        exifOrientation: extent?.orientation ?? kDefaultExifOrientation,
        // Structurally false: no preview probe ran, so the container cannot
        // have "declared previews that were all unreadable" (AD-022).
      );
    }
    if (purpose == ImageRequestPurpose.sidebarThumbnail) {
      // Smallest embedded candidate reaching the sidebar edge (G3 finding:
      // the full-size entry point wrongly refuses small-thumbnail DNGs).
      //
      // Memoized per (path, longEdge) (2026-09-04 W4b, round-2 BLOCKER-2
      // fix): the sidebar can ask for the same item's thumbnail more than
      // once per folder session (a re-render, a scroll back into view), and
      // each ask used to repeat the full IFD0/SubIFD walk from scratch. The
      // memo stores ONLY the walk's verdict -- `(offset, byteCount,
      // orientation)` -- never the decoded bytes, so a folder full of
      // large-preview RAWs cannot balloon this memo into hundreds of MB
      // sitting outside `kPayloadByteBudget`/the `ImageCache` budget. A memo
      // HIT still costs one bounded strip read via [readKnownStrip] -- cheap,
      // because the walk's expense was the dozens of cold IFD/SubIFD page
      // reads that selected the candidate, not this one final read.
      final key = _SidebarWalkKey(path, purpose.targetSize);
      Uint8List? bytes;
      var memoHit = true;
      if (_sidebarWalkMemo.containsKey(key)) {
        final verdict = _sidebarWalkMemo[key];
        bytes = verdict == null
            ? null
            : await DngEmbeddedJpegExtractor.readKnownStrip(
                path,
                offset: verdict.offset,
                byteCount: verdict.byteCount,
                orientation: verdict.orientation,
                // extractEmbeddedJpeg/selectAndRead (below, the recording
                // path) select and read with strictBitstream: false -- so a
                // memo hit must be exactly as lenient (round-2 S3 fix), or a
                // no-SOI candidate would serve fine on first load and then
                // fail on every subsequent one.
                strictBitstream: false,
              );
      } else {
        memoHit = false;
        // P1b (2026-09-05): the sidebar no longer walks the IFD/SubIFDs on
        // its own -- it asks the shared per-path probe (_fileProbeFor), which
        // performs the walk exactly once regardless of which of this file's
        // four questions asks first. `debugSidebarWalkCount` only increments
        // when THIS call is the one that actually triggered a fresh walk
        // (probe.walkCount changed across the await), preserving its old
        // meaning ("the sidebar branch performed a fresh walk") even though
        // the walk itself may now be shared with another consumer.
        final walksBefore = debugFileProbeWalkCount;
        final probeResult = await _fileProbeFor(path);
        if (debugFileProbeWalkCount != walksBefore) debugSidebarWalkCount++;
        final fileProbe = probeResult.probe;
        final fileProbed = fileProbe == null
            ? const DngEmbeddedJpegProbe(jpeg: null, malformed: false)
            : await DngEmbeddedJpegExtractor.selectAndRead(
                fileProbe,
                path: path,
                longEdge: purpose.targetSize,
                strictBitstream: false,
              );
        final candidate = fileProbed.jpeg;
        bytes = candidate?.bytes;
        // BLOCKER-3 fix: a fault-derived miss (the underlying probe walk
        // never got a clean read) must not be cached here either -- this
        // sidebar verdict memo is a SEPARATE cache from `_fileProbeMemo`, so
        // skipping the probe memo alone is not enough; this one has to skip
        // too, or the exact same bug reappears one layer down (TC-947).
        if (!probeResult.transientFault) {
          _sidebarWalkMemo[key] = candidate == null
              ? null
              : (
                  offset: candidate.offset,
                  byteCount: candidate.byteCount,
                  orientation: candidate.orientation,
                );
          if (_sidebarWalkMemo.length > _sidebarWalkMemoCap) {
            _sidebarWalkMemo.remove(_sidebarWalkMemo.keys.first);
          }
        }
      }
      // PERF-INSTRUMENTATION (D1 AC3 marker).
      PerfLog.log(
        'decode|phase=sidebarEmbeddedJpeg|path=$path|found=${bytes != null}'
        '|memoHit=$memoHit',
      );
      return bytes == null
          ? const NativeImageFailure('NO_THUMBNAIL', 'no embedded candidate')
          : NativeImageBytes(bytes);
    }
    // M7 ruling G-2: when no embedded candidate reaches the requested long
    // edge, the file enters RAW decode instead of being served an undersized
    // rendition. `minLongEdge` is a post-selection REJECTION in the extractor,
    // not a different choice, so this branch still gets the largest qualifying
    // candidate when one exists.
    //
    // The guard's PRINCIPLE (M7 Decision Log A-6), not its old spelling: be
    // strict exactly where a rejection lands in a real RAW decode, and lenient
    // everywhere a rejection would instead delete an image the user can
    // currently see. The 2026-08-26 contract widened the escape hatch from
    // `.dng` to every engine-decodable extension, so re-deriving the same
    // principle over the new hatch gives:
    //  - `purpose == sidebarThumbnail` never reaches here; the sidebar branch
    //    above stays lenient under rulings P-11/P-13.
    //  - `purpose == export` is excluded HERE, but read the next paragraph
    //    before relying on that: the shipped export feature does not use it.
    //  - browse-only RAW (`.cr2`/`.iiq`/`.mrw`, contract decision D2) stays
    //    excluded for exactly the old reason: the engine cannot decode those
    //    containers, so a rejection would fall through to
    //    RAW_NO_EMBEDDED_PREVIEW rather than to a decode.
    //  - engine-decodable non-DNG RAW (`.arw`/`.nef`/`.rw2`/...) is now
    //    INCLUDED, because the premise that excluded it -- "that escape hatch
    //    is gated on `.dng`" -- is precisely what the contract removed.
    //
    // CORRECTION (round-1 reviewer finding F4). An earlier version of this
    // comment claimed the export FEATURE stays lenient. It does not, and never
    // did: `photo_export_service.dart:57-58` calls this loader with
    // `purpose: preview`, so the strict floor applies to exports too. Nothing
    // in `lib/` ever passes `ImageRequestPurpose.export` to the loader -- that
    // enum value is used only for its `targetSize`
    // (`photo_export_service.dart:82`). The false claim predates the RAW
    // generalisation: A-6's original "export is excluded because the escape
    // hatch is unreachable for it" was already wrong about the shipped path,
    // and this round faithfully carried the wrong premise forward.
    //
    // The BEHAVIOUR is deliberately left alone; only the claim is corrected.
    // Making export pass `ImageRequestPurpose.export` would look like it
    // restores leniency, but it would kill `photo_export_service.dart:68`'s
    // `NativeImageNeedsRawDecode` branch, and exporting a preview-less RAW
    // would start returning null. The export service documents its
    // preview-purpose choice as deliberate for exactly that reason
    // (`photo_export_service.dart:43-46`). Consequences of the floor applying
    // to export, stated rather than papered over:
    //  - with a decoder available, the result is BETTER: a real decode
    //    downsized to 2048 beats an undersized embedded preview.
    //  - with no decoder (contract decision D3), the export fails where it
    //    would previously have produced an undersized image. That window is
    //    narrow -- it needs a sensor long edge under roughly 3111px, since a
    //    full-size candidate must clear `0.90 * cropMax` to qualify -- but it
    //    is not empty. It is also not new: this exposure already existed for
    //    `.dng` before this round, because export has always entered through
    //    the preview purpose. This round widened an accepted condition; it did
    //    not invent one. Recorded as parking-lot, not silently accepted.
    // AD-021's uneven floor is preserved -- strict on preview, lenient on
    // sidebar -- and is not unified. The `export` ARM of this guard is
    // currently unreachable in production; the tests that pin it pin the
    // loader's purpose semantics, not the export feature's behaviour.
    final strictPreview =
        purpose == ImageRequestPurpose.preview &&
        SupportedPhotoFormats.isDecodablePath(path);
    // F4/AC6: ONE threshold. `targetLongEdge` is the same live viewport long
    // edge `PhotoSource.probeSource` compared against when it decided this
    // item's rung, so the floor enforced here can no longer contradict the
    // routing verdict. Null (a caller with no viewport) keeps the old constant.
    final previewFloor = targetLongEdge ?? purpose.targetSize;
    // P1b (2026-09-05): shares the single per-path fileProbe walk with every
    // other question this file asks about [path] -- see [_fileProbeFor] and
    // [DngEmbeddedJpegExtractor.selectAndRead]. `fileProbe` is also reused below
    // for the dimensions/orientation questions on the RAW-decode-signal
    // branch, at zero extra walk cost (memo hit).
    final fileProbe = (await _fileProbeFor(path)).probe;
    final embeddedProbe = fileProbe == null
        ? const DngEmbeddedJpegProbe(jpeg: null, malformed: false)
        : await DngEmbeddedJpegExtractor.selectAndRead(
            fileProbe,
            path: path,
            longEdge: null,
            minLongEdge: strictPreview ? previewFloor : null,
            // Matches [DngEmbeddedJpegExtractor.probeEmbeddedJpeg]'s own
            // `strictBitstream: true`: the
            // preview route requires a genuine JPEG SOI marker on the
            // selected candidate.
            strictBitstream: true,
          );
    final full = embeddedProbe.jpeg?.bytes;
    // PERF-INSTRUMENTATION (D1 AC3 marker): the embedded-preview vs
    // full-RAW-decode fork -- the split memory.md/D1 asks this file's
    // instrumentation to make observable.
    PerfLog.log(
      'decode|phase=embeddedPreviewProbe|path=$path|found=${full != null}',
    );
    if (full != null) return NativeImageBytes(full);
    // DIAGNOSTIC (2026-09-02). THE decision point of the reported bug: from
    // here a decodable file routes to a full RAW decode, and the preload
    // controller memoises that verdict for the whole folder session. The
    // headless repro could never make this branch fire on the user's files
    // (docs/logs/2026-09-02/repro-experiment.md §4-5, page-cache-bound), so the
    // only remaining instrument is a real app run.
    //
    // One line per occurrence, off the hot path: a file with a usable preview
    // has already returned above. Pair it with any `halcyon.read.fault` line
    // for the same file -- fault present means the volume hiccuped (the
    // transient-read hypothesis), fault absent with `malformed=false` means the
    // container genuinely offered nothing and the cause is elsewhere. That
    // pairing is the discriminator the team currently lacks.
    if (strictPreview) {
      stderr.writeln(
        'halcyon.preview.miss|file=${path.split(Platform.pathSeparator).last}'
        '|malformed=${embeddedProbe.malformed}'
        '|floor=$previewFloor'
        '|len=${await File(path).length()}'
        '|-> RAW decode',
      );
      // PERF-INSTRUMENTATION (D1 round-2, per team-lead instruction): the
      // same fact, also into the perf log so round-2 analysis has it in one
      // file instead of having to cross-reference stderr separately.
      PerfLog.log(
        'preview_miss|path=$path|malformed=${embeddedProbe.malformed}'
        '|floor=$previewFloor',
      );
    }
    // USER RULING 2026-08-26 — the malformed PRE-EMPT is gone.
    //
    // M7 Task 3 used to return a `DNG_PARSE_FAILED` failure right here when
    // `fileProbe.malformed` was true on an engine-decodable path: a container that
    // PARSED but declares only unreadable candidates was called broken before
    // any decode was attempted. Measurement retired that: a container with
    // unreadable previews but intact sensor data was being reported broken
    // while the engine decodes the very same file in 383ms. The user therefore
    // overrode AD-022's pre-empt — unreadable previews route to the full
    // decoder FIRST, and the file is only reported broken if that decode ALSO
    // fails.
    //
    // What the override did NOT do: AD-022's requirement that the two "no
    // preview" end states stay TELLABLE APART still holds. What it removed is
    // the pre-empt, not the distinction. The distinction is carried forward on
    // [NativeImageNeedsRawDecode.declaredPreviewsUnreadable] and re-formed
    // after the decode by the layer that owns the decoder seam
    // (`photo_source.dart`) — which is the only layer that knows whether the
    // decode failed. This loader never performs a decode, so it cannot and
    // must not form that verdict itself.
    //
    // `fileProbe.malformed` can only be true when the walker actually parsed the
    // container and found every DECLARED candidate unreadable (AD-022). Three
    // things are deliberately NOT malformed and therefore keep flowing through
    // with the flag false: a genuinely preview-less container, a G-2 undersized
    // but intact candidate, and a non-TIFF RAW (CR3/RAF/X3F) that bails before
    // IFD0 is readable.
    //
    // Browse-only RAW (D2: `.cr2`/`.iiq`/`.mrw`) is unaffected in both
    // directions: it never reached the pre-empt (that gate was already
    // `isDecodablePath`-gated) and it still falls through to the uniform
    // RAW_NO_EMBEDDED_PREVIEW state below, because there is no decode for it to
    // be routed to (matrix F-08).
    if (purpose == ImageRequestPurpose.preview &&
        SupportedPhotoFormats.isDecodablePath(path)) {
      // P1b: reuses the same [fileProbe] fetched above -- a memo hit, not a
      // second walk. `fileProbe.dimensions`/`fileProbe.orientation` are bit-for-bit
      // what [readImageDimensions]/[readOrientation] would have returned:
      // both are read from the SAME already-parsed IFD0 inside
      // [DngEmbeddedJpegExtractor.probeFile], and `fileProbe.orientation` is
      // already run through [DngEmbeddedJpegExtractor]'s own sanitize step,
      // so `fileProbe?.orientation ?? kDefaultExifOrientation` below folds to the
      // identical value `readOrientation(path) ?? kDefaultExifOrientation`
      // did in every case (`kDefaultExifOrientation == 1 ==` the sanitizer's
      // own fallback).
      final dims = fileProbe?.dimensions;
      if (dims != null &&
          dims.width * dims.height * 4 > kDecodedPixelBudgetBytes) {
        // F-20: same budget the deleted native guard enforced
        // (formerly AppDelegate.swift renderCGImage). A header claiming an
        // absurd extent must be an error result, never an OOM.
        return const NativeImageFailure(
          'IMAGE_TOO_LARGE',
          'decode exceeds the decoded-pixel budget',
        );
      }
      // Ruling (b): the raw-decode signal is constructed in Dart from an
      // extraction miss + the walker's own orientation read.
      final orientation = fileProbe?.orientation;
      // PERF-INSTRUMENTATION (D1 AC3 marker): full RAW decode was signalled.
      PerfLog.log('decode|phase=fullRawDecode|path=$path');
      return NativeImageNeedsRawDecode(
        exifOrientation: orientation ?? kDefaultExifOrientation,
        // Carried, not acted on. False here is the ordinary miss ("this
        // container declares no preview"); true is "it declared previews and
        // none were readable". Both route to the decoder identically — the
        // only thing this changes is which failure code surfaces if that
        // decode fails.
        declaredPreviewsUnreadable: embeddedProbe.malformed,
      );
    }
    // Browse-only RAW (D2: `.cr2`/`.iiq`/`.mrw`) with no embedded preview, and
    // any non-preview purpose on a RAW: the explicit uniform unsupported state
    // (matrix F-08, accepted loss U-11). The engine has no decode route for
    // these containers, so there is nothing to fall through to.
    return const NativeImageFailure(
      'RAW_NO_EMBEDDED_PREVIEW',
      'no embedded preview and no decoder for this format',
    );
  } catch (e) {
    return NativeImageFailure('DART_LOADER_ERROR', '$e');
  }
}
