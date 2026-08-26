import 'dart:typed_data';

import 'decoded_rgba_image_provider.dart';
import 'dng_decode_contract.dart';
import 'dng_embedded_jpeg_extractor.dart';
import 'image_source_types.dart';
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
  /// (measured 61-406ms, and it saturates cores). Eligible across the whole
  /// retention window exactly like a cheap item, but produced ONE AT A TIME on
  /// the shared serial decode lane (user ruling 2026-08-26).
  expensive,
}

/// What one attempt to produce a payload actually observed.
///
/// [deferred] separates the two ways a payload can come back null, which the
/// caller MUST NOT confuse: `deferred: true` means "the bridge says this needs
/// a real RAW decode and this call was not allowed to run one -- re-enqueue it
/// on the serial decode lane" (a bounded spinner, and a LANE HANDOFF, never a
/// radius), while `deferred: false` with a null payload means every source
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
  // D3 (docs/logs/2026-08-26/raw-support-contract.md): a failure CODE, not a
  // rendered message -- whoever displays it owns the wording. NULLABLE and
  // null at every existing call site: null means "no failure reason to
  // report" (the success and deferred paths, and every miss that predates
  // this field), so no existing meaning changes. Currently only ever set to
  // [kNoNativeDecoderCode], decided BEFORE the decoder is invoked (the
  // `dngDecoder == null` branches below), never inferred from a caught
  // exception -- a missing native library is a static platform property, not
  // a decode failure to detect after the fact.
  String? failureCode,
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

// `NativeImageLoad` is declared in `image_source_types.dart`; it used to be
// re-declared here structurally to avoid importing the preload controller.
// That workaround is gone -- the canonical typedef now lives in a file with
// no dependencies of its own, so there is no cycle to dodge.

/// The ONE place in the Dart pipeline that knows about file types.
///
/// Everything above it -- the scheduler, the payload cache, the two tier
/// providers -- is type-blind by construction (user decision D3/D4). Design
/// authority: `docs/logs/2026-08-23/image-pipeline-redesign-handover.md` §3.1.
class PhotoSource {
  const PhotoSource({required this.loader, this.dngDecoder});

  final NativeImageLoad loader;

  /// Null when no RAW decoder is available. Every use is guarded by step 3b:
  /// no decoder (or a throwing one) is a genuine permanent miss (M6 U-12
  /// ruling) -- the native CIRAWFilter re-request this used to fall back to
  /// no longer exists on any platform, so there is nothing left to degrade
  /// to; the caller records `payload: null, deferred: false` exactly as any
  /// other unrecoverable file.
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
  /// null payload and re-enqueues the item on the serial decode lane, whose
  /// task body is the only caller that passes true. Without this split, a
  /// probe-unmeasurable file would perform its FFI decode inline on whichever
  /// parallel window load happened to discover it, and a 9-step navigation
  /// burst would fire nine concurrent decodes -- which is what the lane, not a
  /// radius, now prevents.
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
          failureCode: null,
        );

      case NativeImageNeedsRawDecode(
        :final exifOrientation,
        :final declaredPreviewsUnreadable,
      ):
        final decoder = dngDecoder;
        if (decoder == null) {
          // D3 (docs/logs/2026-08-26/raw-support-contract.md): a missing
          // native library is a static platform property, decided HERE,
          // before any decoder is invoked -- never inferred from a caught
          // exception. No FFI work exists to defer, and no legacy channel
          // exists to fall back to any more (M6 U-12): a genuine permanent
          // miss, recorded immediately rather than left as a spinner.
          return (
            payload: null,
            observedCost: SourceCost.expensive,
            deferred: false,
            exifOrientation: null,
            fullRes: null,
            failureCode: kNoNativeDecoderCode,
          );
        }
        if (!allowExpensive) {
          return (
            payload: null,
            observedCost: SourceCost.expensive,
            deferred: true,
            exifOrientation: exifOrientation,
            fullRes: null,
            failureCode: null,
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
            failureCode: null,
          );
        } catch (_) {
          // Step 3b. A throwing decoder is a genuine permanent miss (M6
          // U-12), NOT the D3 no-native-decoder state (a decoder that exists
          // and threw is a real decode failure): there is no legacy channel
          // path left to degrade to, so the caller records the uniform
          // null-payload miss (oracle-protected at
          // test/image_preload_controller_test.dart, the "no decoder"/
          // "throwing decoder" cases).
          //
          // This is the point where the AD-022 verdict is finally FORMED
          // (user ruling 2026-08-26). The loader no longer pre-empts a
          // container whose declared previews are all unreadable; it routes it
          // here and carries the finding on `declaredPreviewsUnreadable`. Only
          // now, with the decode outcome known, can the two states be told
          // apart:
          //   - previews unreadable AND the decode also failed -> the
          //     container really is broken: DNG_PARSE_FAILED.
          //   - anything else that failed to decode -> the uniform miss, code
          //     null, exactly as before.
          // A file whose previews are unreadable but whose sensor data decodes
          // never reaches this catch at all, which is the whole point of the
          // override: it renders instead of being called broken.
          return (
            payload: null,
            observedCost: SourceCost.expensive,
            deferred: false,
            exifOrientation: null,
            fullRes: null,
            failureCode: declaredPreviewsUnreadable ? 'DNG_PARSE_FAILED' : null,
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
          failureCode: null,
        );
    }
  }

  /// Runs the expensive half after an earlier pass already received
  /// `NativeImageNeedsRawDecode` and carried [exifOrientation] forward. This
  /// is the I6-preserving path: the serial lane's retry must not re-ask the
  /// native bridge for the same answer just to get the orientation back.
  Future<SourceOutcome> loadExpensive(
    String path, {
    required int longEdge,
    required int exifOrientation,
  }) async {
    final decoder = dngDecoder;
    if (decoder == null) {
      // D3: decided before invoking anything, same as the [load] arm above
      // -- see its comment. In practice this arm is unreachable today (a
      // null decoder never defers in [load], so there is nothing for this
      // resumed pass to reach), but it is kept symmetric with [load] rather
      // than left to silently diverge if that invariant ever changes.
      return (
        payload: null,
        observedCost: SourceCost.expensive,
        deferred: false,
        exifOrientation: null,
        fullRes: null,
        failureCode: kNoNativeDecoderCode,
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
        failureCode: null,
      );
    } catch (_) {
      // M6 U-12: a throwing decoder is a genuine permanent miss, not D3.
      return (
        payload: null,
        observedCost: SourceCost.expensive,
        deferred: false,
        exifOrientation: null,
        fullRes: null,
        failureCode: null,
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
    final content = await DngEmbeddedJpegExtractor.probeContent(
      path,
      onDiskRead: onDiskRead,
    );
    if (content == null) return (cost: null, exifOrientation: null);
    if (content.jpegBitstream) {
      return (cost: SourceCost.cheap, exifOrientation: null);
    }
    // FROZEN threshold (user ruling 2026-08-27, recorded in memory.md AD-033):
    // any embedded preview smaller than the viewport's physical pixels means a
    // full RAW decode. This must never be loosened — no tolerance factor, no
    // "close enough". A sub-viewport preview scaled up is visibly blurry;
    // waiting for the decode is better.
    return (
      cost: content.largestLongEdge >= longEdge
          ? SourceCost.cheap
          : SourceCost.expensive,
      exifOrientation: content.orientation,
    );
  }

  /// Last-resort preview recovery after the native preview channel has already
  /// failed entirely (`NativeImageFailure`), via the pure-Dart embedded-JPEG
  /// extractor -- additive, and only reachable when native extraction already
  /// failed, so it never fires on a platform where native extraction
  /// succeeded (macOS unaffected).
  ///
  /// Extension gate removed (M6 F-08): the walker keys on the TIFF magic and
  /// self-rejects anything else, so .arw/.cr2/.nef/.orf/.rw2 embedded
  /// previews are recoverable on every platform. Non-TIFF input returns
  /// null exactly as before.
  static Future<Uint8List?> fallbackAfterNativeFailure(String path) async {
    return DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpegFromFile(path);
  }
}
