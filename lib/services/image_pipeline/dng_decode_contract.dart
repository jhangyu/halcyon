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
}

/// Decodes a DNG that carries no embedded full-size JPEG preview.
///
/// Throws on failure; callers treat any throw as "fall back to the old path".
typedef DngFullDecoder = Future<DecodedRgba> Function(String path);

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
