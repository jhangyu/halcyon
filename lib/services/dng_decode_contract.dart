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
