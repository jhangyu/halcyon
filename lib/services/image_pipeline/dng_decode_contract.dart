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
  });

  /// RGBA8 interleaved, length == width * height * 4.
  final Uint8List rgba;

  /// Already cropped to DefaultCropSize by the decoder; do not crop again.
  final int width;
  final int height;
}

/// Decodes a DNG that carries no embedded full-size JPEG preview.
///
/// Throws on failure; callers treat any throw as "fall back to the old path".
typedef DngFullDecoder = Future<DecodedRgba> Function(String path);

/// Decodes a DNG requesting a decode whose longest output edge is
/// approximately [maxDim] pixels (M6 P2.5b, sidebar RAW-decode fallback for
/// bare-CFA DNGs with no embedded JPEG at any size). [maxDim] is a request,
/// not a guarantee -- callers must read the returned [DecodedRgba]'s actual
/// dimensions rather than assume them. Throws on failure; callers treat any
/// throw as "no thumbnail available".
typedef DngSizedDecoder =
    Future<DecodedRgba> Function(String path, {required int maxDim});

/// The app's only defence against an OOM from a container header that claims
/// an absurd extent: refuse when `width * height * 4` exceeds this many bytes.
///
/// It lives here, next to the decoder seam, because TWO layers must agree on
/// it: `dart_image_loader.dart` checks it before returning
/// [NativeImageNeedsRawDecode] on the preview path, and the TIFF arm of
/// `full_decoder_dispatch.dart` checks it again on the sized sidebar path,
/// which the loader's check never reaches. Two spellings of the same number
/// is how one of them silently drifts.
const int kDecodedPixelBudgetBytes = 1500000000;
