import 'dart:typed_data';

import 'decoded_rgba_image_provider.dart';
import 'dng_decode_contract.dart';
import 'dng_preview_extractor.dart';
import 'native_thumbnail_service.dart';
import 'photo_payload.dart';

/// How expensive it is to produce this file's payload, MEASURED from content.
///
/// The scheduler is the only thing that reads it (design §3.3). It is declared
/// here rather than in `prefetch_scheduler.dart` because [PhotoSource.probe]
/// is what produces it and the scheduler imports this file -- the other
/// direction would be an import cycle. The scheduler re-exports it, so
/// `SourceCost` is still spelled the way the design doc spells it.
enum SourceCost {
  /// An encoded bitstream is already sitting in the file: the JPEG itself, or
  /// an embedded preview big enough for the window. Cheap enough to prefetch
  /// across the whole retention window with no debounce.
  cheap,

  /// No usable embedded JPEG -- producing pixels means a real RAW decode
  /// (measured 61-406ms, and it saturates cores). Confined to +/-1 behind the
  /// navigation debounce.
  expensive,
}

/// What one attempt to produce a payload actually observed.
///
/// [deferred] separates the two ways a payload can come back null, which the
/// caller MUST NOT confuse: `deferred: true` means "measured as expensive and
/// intentionally not done yet, come back from the +/-1 pass" (a bounded
/// spinner), while `deferred: false` with a null payload means every source
/// including the legacy fallback failed and the item is a PERMANENT MISS. Fold
/// those together and a decoder failure becomes a spinner that never resolves
/// -- the single stranding risk design §3.4 names.
///
/// [fullRes] is the M5 piggyback output (design §2.2): full-resolution,
/// orientation-ALREADY-applied RGBA8 pixels from the SAME FFI decode that
/// produced [payload], non-null ONLY when a real RAW decode ran in this call
/// (never for the cheap/encoded paths, and never for the step-3b legacy
/// fallback). This is a transient handoff -- [PhotoSource] keeps no reference
/// to the buffer once it returns it; the caller (the tier-2 upload path) owns
/// disposal/upload from here.
typedef SourceOutcome = ({
  SourcePayload? payload,
  SourceCost? observedCost,
  bool deferred,
  int? exifOrientation,
  ({Uint8List rgba, int width, int height})? fullRes,
});

/// What ONE bounded content probe learned about a file.
///
/// The two fields are deliberately produced by a SINGLE IFD walk (user
/// ruling): [cost] decides the rung, and [orientation] is what the expensive
/// rung will need after the debounce elapses. A separate orientation probe
/// would re-open the file and re-walk the header and IFD0 for a value the cost
/// walk already had in its hand, and -- worse -- tempts the debounced pass into
/// a second native-loader round trip just to get it (invariant I6).
///
/// [cost] is null for "could not measure" (missing/unreadable/not a TIFF or
/// JPEG at all), which is deliberately distinct from [SourceCost.expensive]:
/// the caller resolves the undetermined case from the first bridge answer
/// rather than guessing a rung (frozen contract A-§2 rung 2).
///
/// [exifOrientation] is null whenever the probe could not establish one -- an
/// unmeasurable file, or a JPEG (whose orientation rides inside the bitstream
/// the decoder already reads, and which must not cost the hot path a walk).
typedef ProbeResult = ({SourceCost? cost, int? exifOrientation});

/// The seam through which the native (or faked) preview bridge is called.
/// Written structurally rather than importing `ImagePreloadController`'s
/// typedef, which would be an import cycle; Dart function types are
/// structural, so every existing test fake satisfies this unchanged.
typedef NativeImageLoad =
    Future<NativeImageResult> Function(
      String path, {
      required ImageRequestPurpose purpose,
    });

/// The ONE place in the Dart pipeline that knows about file types.
///
/// Everything above it -- the scheduler, the payload cache, the two tier
/// providers -- is type-blind by construction (user decision D3/D4). Design
/// authority: `docs/logs/2026-08-23/image-pipeline-redesign-handover.md` §3.1.
class PhotoSource {
  const PhotoSource({required this.loader, this.dngDecoder});

  final NativeImageLoad loader;

  /// Null when no RAW decoder is available. Every use is guarded by step 3b:
  /// no decoder (or a throwing one) re-requests through
  /// `NativeThumbnailService.getThumbnail`, which forces
  /// `allowRawDecodeSignal: false` and so reproduces the pre-round-3b
  /// CIRAWFilter path byte-for-byte. Degraded, never blank.
  final DngFullDecoder? dngDecoder;

  /// Produces the payload for [path] at [longEdge], plus what that attempt
  /// revealed about the file's cost.
  ///
  /// Steps, per §3.1:
  ///   1/2. the native bridge answers with an encoded bitstream (the file
  ///        itself for a JPEG, or the embedded preview it selected)
  ///   3.   no usable embedded JPEG -> RAW decode, immediately reduced to
  ///        window-resolution oriented pixels
  ///   3b.  no decoder, or the decoder threw -> legacy CIRAWFilter bytes
  ///   4.   nothing worked -> null payload, which the caller MUST record as a
  ///        permanent miss (see §3.4: this is the one path where a spinner
  ///        could otherwise strand forever)
  ///
  /// [allowExpensive] false stops at the discovery: the bridge is asked (which
  /// is how the cost is learned at all, and is the same single round trip the
  /// pre-M3 code made for every item in the window), but no RAW decode and no
  /// legacy fallback runs. The caller gets `observedCost: expensive` with a
  /// null payload and re-enters later from the debounced +/-1 pass. Without
  /// this split, discovering an item's cost would itself perform the work the
  /// cost gate exists to defer, and a 9-step navigation burst would fire nine
  /// FFI decodes -- the exact D2 violation.
  Future<SourceOutcome> load(
    String path, {
    required int longEdge,
    bool allowExpensive = true,
  }) async {
    final result = await loader(path, purpose: ImageRequestPurpose.preview);
    switch (result) {
      case NativeImageBytes(:final bytes):
        return (
          payload: EncodedPayload(bytes),
          observedCost: SourceCost.cheap,
          deferred: false,
          exifOrientation: null,
          fullRes: null,
        );

      case NativeImageNeedsRawDecode(:final exifOrientation):
        final decoder = dngDecoder;
        if (decoder == null) {
          // No FFI work exists to defer. Preserve the frozen "slow but
          // working" behaviour immediately: legacy CIRAWFilter bytes, not a
          // spinner waiting for a decoder the app does not have.
          return (
            payload: await _legacyBytes(path),
            observedCost: SourceCost.expensive,
            deferred: false,
            exifOrientation: null,
            fullRes: null,
          );
        }
        if (!allowExpensive) {
          return (
            payload: null,
            observedCost: SourceCost.expensive,
            deferred: true,
            exifOrientation: exifOrientation,
            fullRes: null,
          );
        }
        try {
          final decoded = await decoder(path);
          final pixels = await decodedRgbaToPixelPayload(
            decoded,
            exifOrientation: exifOrientation,
            longEdge: longEdge,
          );
          final fullRes = await _fullResFrom(
            decoded,
            exifOrientation: exifOrientation,
          );
          return (
            payload: pixels,
            observedCost: SourceCost.expensive,
            deferred: false,
            exifOrientation: null,
            fullRes: fullRes,
          );
        } catch (_) {
          // Step 3b. A throwing decoder must degrade to the old slow path,
          // never to a blank screen (frozen design §2, oracle-protected at
          // test/image_preload_controller_test.dart:1118-1120).
          return (
            payload: await _legacyBytes(path),
            observedCost: SourceCost.expensive,
            deferred: false,
            exifOrientation: null,
            fullRes: null,
          );
        }

      case NativeImageFailure():
        // No native bridge succeeded (including MISSING_PLUGIN on a platform
        // with no bridge at all). The pure-Dart embedded-JPEG walker is the
        // last resort; a null here is a genuine "unreadable".
        final recovered = await fallbackAfterNativeFailure(path);
        return (
          payload: recovered == null ? null : EncodedPayload(recovered),
          observedCost: recovered == null ? null : SourceCost.cheap,
          deferred: false,
          exifOrientation: null,
          fullRes: null,
        );
    }
  }

  /// Runs the expensive half after an earlier immediate pass already received
  /// `NativeImageNeedsRawDecode` and carried [exifOrientation] forward. This
  /// is the I6-preserving path: the debounced pass must not re-ask the native
  /// bridge for the same answer just to get the orientation back.
  Future<SourceOutcome> loadExpensive(
    String path, {
    required int longEdge,
    required int exifOrientation,
  }) async {
    final decoder = dngDecoder;
    if (decoder == null) {
      return (
        payload: await _legacyBytes(path),
        observedCost: SourceCost.expensive,
        deferred: false,
        exifOrientation: null,
        fullRes: null,
      );
    }
    try {
      final decoded = await decoder(path);
      final pixels = await decodedRgbaToPixelPayload(
        decoded,
        exifOrientation: exifOrientation,
        longEdge: longEdge,
      );
      final fullRes = await _fullResFrom(
        decoded,
        exifOrientation: exifOrientation,
      );
      return (
        payload: pixels,
        observedCost: SourceCost.expensive,
        deferred: false,
        exifOrientation: null,
        fullRes: fullRes,
      );
    } catch (_) {
      return (
        payload: await _legacyBytes(path),
        observedCost: SourceCost.expensive,
        deferred: false,
        exifOrientation: null,
        fullRes: null,
      );
    }
  }

  /// The M5 piggyback's second output half (design §2.2): the SAME decoded
  /// RAW frame, oriented but NOT downscaled, reduced to plain RGBA8 bytes.
  ///
  /// This does not call [dngDecoder] again -- it re-runs
  /// `decodedRgbaToPixelPayload` on the buffer already sitting in [decoded],
  /// with `longEdge: 0` selecting the existing no-upscale/no-downscale path
  /// (`decoded_rgba_image_provider.dart`'s `longEdge <= 0` branch). The FFI
  /// decode count this contributes is zero; the only cost is one more
  /// GPU raster pass over pixels already resident in memory.
  static Future<({Uint8List rgba, int width, int height})> _fullResFrom(
    DecodedRgba decoded, {
    required int exifOrientation,
  }) async {
    final fullRes = await decodedRgbaToPixelPayload(
      decoded,
      exifOrientation: exifOrientation,
      longEdge: 0,
    );
    return (rgba: fullRes.rgba, width: fullRes.width, height: fullRes.height);
  }

  /// Step 3b: re-request with `allowRawDecodeSignal` forced false, which is
  /// what `NativeThumbnailService.getThumbnail` always sends. Reproduces the
  /// pre-round-3b native behaviour byte-for-byte: CIRAWFilter, 2800px cap,
  /// slow -- but a picture.
  ///
  /// A null return means BOTH the decode and the legacy path failed. The
  /// caller must mark a permanent miss on it; that is the load-bearing edge
  /// §3.4 names as the only new stranding risk in M3.
  static Future<EncodedPayload?> _legacyBytes(String path) async {
    final bytes = await NativeThumbnailService.getThumbnail(
      path,
      purpose: ImageRequestPurpose.preview,
    );
    return bytes == null ? null : EncodedPayload(bytes);
  }

  /// Measures [path] from its CONTENT in ONE bounded walk, reading at most a
  /// few tens of KB and never a JPEG strip.
  ///
  /// This is THE probe seam: the single call that answers both of the pipeline's
  /// pre-load questions (see [ProbeResult]). There is deliberately no second
  /// entry point for orientation -- one walk, both answers, so an expensive
  /// item can reach the decoder after the debounce without any further loader
  /// or channel call (invariant I6).
  ///
  /// The cost half replaces the `.dng` extension test that decided the rung
  /// before M3 and was wrong 13 times in 14. It also gets non-DNG raw formats
  /// for free: the walker only checks the TIFF magic, never the extension.
  static Future<ProbeResult> probeSource(
    String path, {
    required int longEdge,
    void Function(int byteCount)? onDiskRead,
  }) async {
    // ONE open, ONE walk, both answers. Steps 1 and 2 of §3.1 both happen
    // inside this single call: the JPEG magic check (two bytes and out, so the
    // hot path stays free -- design §5) and, for a TIFF/DNG, the IFD walk that
    // finds the biggest embedded JPEG without reading it AND picks up IFD0's
    // orientation on the way past.
    //
    // The magic check deliberately does NOT live here any more. Peeking at the
    // first two bytes through a handle of this layer's own turned a one-open
    // probe into a two-open one, which is what test TC-090 counts.
    //
    // Every read goes through [onDiskRead], so the AC14 budget covers the
    // combined probe rather than only its cost half.
    final content = await DngPreviewExtractor.probeContent(
      path,
      onDiskRead: onDiskRead,
    );
    if (content == null) return (cost: null, exifOrientation: null);
    if (content.jpegBitstream) {
      return (cost: SourceCost.cheap, exifOrientation: null);
    }
    return (
      cost: content.largestLongEdge >= longEdge
          ? SourceCost.cheap
          : SourceCost.expensive,
      exifOrientation: content.orientation,
    );
  }

  /// The cost half of [probeSource], and nothing else.
  ///
  // ponytail: this exists ONLY for the hash-frozen test blob
  // test/dng_nav_probe_m3_test.dart:147/:180 (sha256 be3a595d...), which
  // compares `PhotoSource.probe(...)` directly against a `SourceCost` and may
  // not be edited. Deleting it in M5/M6 breaks that byte-identity gate.
  ///
  /// It is a PURE DELEGATION on purpose: no walk logic, no branch, no file
  /// open of its own. That is what keeps the user's one-walk ruling structural
  /// rather than conventional -- there is no second implementation here that
  /// could drift from [probeSource] or be composed with it into two walks.
  /// Production code must call [probeSource]; this projection has no callers
  /// in `lib/`.
  static Future<SourceCost?> probe(
    String path, {
    required int longEdge,
    void Function(int byteCount)? onDiskRead,
  }) async =>
      (await probeSource(path, longEdge: longEdge, onDiskRead: onDiskRead))
          .cost;

  /// Last-resort preview recovery after the native preview channel has already
  /// failed entirely (`NativeImageFailure`). Only a `.dng` gets a second try,
  /// via the pure-Dart embedded-JPEG extractor -- additive, and only reachable
  /// when native extraction already failed, so it never fires on a platform
  /// where native extraction succeeded (macOS unaffected).
  ///
  /// Returns the extracted bytes, or null if [path] is not a `.dng` (or
  /// extraction found nothing).
  static Future<Uint8List?> fallbackAfterNativeFailure(String path) async {
    if (!path.toLowerCase().endsWith('.dng')) return null;
    return DngPreviewExtractor.extractFullSizeEmbeddedJpegFromFile(path);
  }
}
