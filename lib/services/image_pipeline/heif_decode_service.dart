import 'dart:typed_data';

import 'package:ceyx/ceyx.dart';

import 'dng_decode_contract.dart';

/// Adapter from `ceyx`'s HEIF surface to the frozen [DngFullDecoder] seam.
/// Mirrors `dng_decode_service.dart` deliberately: same length check, same
/// StateError shape.
///
/// Kept production-clean: no dylib-preload workaround and no dev-only path
/// hacks. The two LGPL dylibs land in `<App>.app/Contents/Frameworks/` because
/// `ceyx` is a Flutter FFI plugin whose pod vendors them, and the package's
/// own search order finds them there.

/// The single place the RGBA geometry invariant is enforced on the HEIC path.
///
/// `PixelPayload`'s assert and `_imageFromPixels`' invariant both depend on
/// `rgba.length == width * height * 4`. Native checks it too; checking again
/// here means a future ABI drift surfaces as a named error instead of as an
/// assert deep inside the image provider, where the message names neither the
/// file nor the decoder.
Future<DecodedRgba> heifImageToDecodedRgba({
  required Uint8List rgba,
  required int width,
  required int height,
}) async {
  final expectedLength = width * height * 4;
  if (rgba.length != expectedLength) {
    throw StateError(
      'ceyx HEIF decode length mismatch: rgba.length=${rgba.length} but '
      'width*height*4=$expectedLength (width=$width, height=$height)',
    );
  }
  return DecodedRgba(rgba: rgba, width: width, height: height);
}

/// [DngFullDecoder]-shaped HEIC arm.
///
/// Throws [HeifUnavailableException] when this build of the native library has
/// no HEIF route, and [HeifDecodeException] when the decode itself fails.
/// Both are ordinary decoder throws downstream: `photo_source.dart`'s step-3b
/// catch converts them into the uniform permanent miss, and the D3
/// `kNoNativeDecoderCode` state stays reserved for a null decoder.
Future<DecodedRgba> decodeHeifFull(String path) async {
  final image = await HeifDecoderService().decodeOnWorker(path);
  return heifImageToDecodedRgba(
    rgba: image.rgba,
    width: image.width,
    height: image.height,
  );
}

const DngFullDecoder halcyonHeifFullDecoder = decodeHeifFull;
