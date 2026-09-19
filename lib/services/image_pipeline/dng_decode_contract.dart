import 'dart:typed_data';

/// Round-3b integration seam between the `dng_processor` package (which owns
/// the native RAW decode) and Halcyon's image pipeline.
///
/// It exists so the pipeline can be unit-tested with a fake decoder instead of
/// loading a 50MB-per-image native dylib, mirroring the existing
/// `ImageBytesLoader` injection in `image_preload_controller.dart`.
///
/// ponytail: deliberately dumber than `DngImage` — no timing fields, no
/// package import. Widen it only when a consumer actually needs more.
class DecodedRgba {
  const DecodedRgba({
    required this.rgba,
    required this.width,
    required this.height,
    this.nativeAddress = 0,
    this.nativeKeepAlive,
    this.releaseNative,
    this.appliedOrientation = 1,
  });

  /// RGBA8 interleaved, length == width * height * 4.
  final Uint8List rgba;

  /// Already cropped to DefaultCropSize by the decoder; do not crop again.
  final int width;
  final int height;

  /// WP3/R2b (gc-remediation, 2026-09-06). The address of the native buffer
  /// [rgba] views, or 0 when [rgba] is Dart-heap-owned (the legacy arm, and
  /// every existing fake decoder in the test suite -- both default this to
  /// 0, so every existing construction is unaffected). Mirrors
  /// `DngImage.nativeAddress` (ceyx, landed eec995b): non-zero only on the
  /// pointer-transfer decode path.
  final int nativeAddress;

  /// The object that must stay reachable for as long as [nativeAddress] is
  /// used (typically the `DngImage` ceyx handed back) -- the native buffer's
  /// lifetime is tied to it via a `NativeFinalizer`, and this repo does not
  /// import `dart:ffi`'s `Finalizable` here to keep this class decoder-
  /// package-agnostic (class dartdoc above: "no package import"). Null
  /// whenever [nativeAddress] is 0.
  final Object? nativeKeepAlive;

  /// WP6 (gc-remediation, 2026-09-06). Returns this frame's native buffer to
  /// `CeyxNativeBufferPool` at end-of-consumption; typically
  /// `DngImage.releaseToPool` (idempotent on the ceyx side). Null means
  /// "nothing to release", NEVER "leak": every Dart-heap-backed decode and
  /// every fake decoder in the test suite leaves it null.
  ///
  /// CALL SITES (four, kept in sync deliberately -- an earlier version of this
  /// paragraph named ONE site while the code had three, which is the
  /// 2026-09-06 "document updated in one place, its consumer not" failure
  /// mode). Each releases at the LAST READ of the pooled bytes:
  ///   * `decodedRgbaToOrientedFullRes` (rotated path) -- after the
  ///     materialize; the record it returns then carries a null handle (T7).
  ///   * `decodedRgbaToImage` -- after the materialize, covering the catch-up
  ///     upgrade in `TierTwoScheduler._upgradeFullRes`, which had NO release
  ///     site at all before T8.
  ///   * `_finishOffLane`'s identity-path callback -- fired by the piggyback
  ///     materialize, the last read of the transiently aliased buffer (T7).
  ///   * `DeferredFullSizeEncoder._run`'s `finally`.
  /// `_finishOffLane`'s terminal `finally` is a NET, not a fifth owner: it
  /// covers the paths reaching none of the above (window-moved skip, encode
  /// throw, refused publish, null payload) and is suppressed by a flag when
  /// the callback already fired.
  ///
  /// RELYING ON THE GARBAGE COLLECTOR IS A DEFECT, not a fallback. Pool-owned
  /// buffers get no `NativeFinalizer` -- freeing one would take it away from
  /// the pool -- so ceyx arms a Dart `Finalizer` safety net per checkout and
  /// counts its reclaims separately in
  /// `CeyxNativeBufferPool.debugFinalizerReleases`. That counter exists to be
  /// asserted ZERO (mem8 SR-4, T8): a non-zero value means some path above
  /// stopped releasing and the slot stayed out of circulation until a
  /// collection that is not scheduled by anything the pipeline controls.
  final void Function()? releaseNative;

  /// The EXIF orientation the DECODER has already applied to [rgba], or 1
  /// when it applied none. Never a request; always a report. Halcyon applies
  /// only the RESIDUAL (`residualExifOrientation` in `exif_orientation.dart`),
  /// so a decoder that ignores the request, a build whose dylib predates the
  /// oriented entry, and the pure-Dart TIFF arm are all correct without a
  /// feature flag. Defaults to 1 so every existing construction site
  /// (production and every fake decoder in the test suite) is unaffected.
  final int appliedOrientation;
}

/// Decodes a DNG that carries no embedded full-size JPEG preview.
///
/// Throws on failure; callers treat any throw as "fall back to the old path".
typedef DngFullDecoder = Future<DecodedRgba> Function(String path);

/// Orientation-aware sibling of [DngFullDecoder].
///
/// A SECOND typedef, not a widened [DngFullDecoder] -- Dart's function-type
/// subtyping means adding even an OPTIONAL named parameter to a typedef
/// breaks every existing closure assigned to it (see the erratum recorded at
/// `payload_reencoder.dart:13-22`, where `Enc e = fakeOld;` is a compile
/// error after such a widening). [DngFullDecoder]'s declaration therefore
/// stays byte-identical, and this is a separate, additional seam -- exactly
/// as `PointerPayloadEncoder` is the separate sibling of `PayloadEncoder`.
///
/// [exifOrientation] is the DECLARED orientation (from Halcyon's own IFD0
/// walk); the returned [DecodedRgba.appliedOrientation] reports what the
/// decoder actually did with it, which may be less than requested (or
/// nothing at all, on an older dylib or a non-RAW arm).
typedef DngOrientingFullDecoder = Future<DecodedRgba> Function(
  String path, {
  required int exifOrientation,
});

/// The app's only defence against an OOM from a container header that claims
/// an absurd extent: refuse when `width * height * 4` exceeds this many bytes.
///
/// It lives here, next to the decoder seam, because TWO layers must agree on
/// it: `dart_image_loader.dart` checks it before returning
/// [NativeImageNeedsRawDecode] on the preview path, and the TIFF arm of
/// `full_decoder_dispatch.dart` checks it again for callers that invoke the
/// decoder directly (`PhotoExportService.exportBytesFor`), which the loader's
/// check never reaches. Two spellings of the same number is how one of them
/// silently drifts.
const int kDecodedPixelBudgetBytes = 1500000000;
