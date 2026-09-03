import 'package:ceyx/ceyx.dart';

import 'dng_decode_contract.dart';

/// Adapter from `ceyx`'s generic still-decode surface to the frozen
/// [DngFullDecoder] seam, for JPEG XL. Mirrors `heif_decode_service.dart`
/// deliberately: same length check, same StateError shape.

/// The single place the RGBA geometry invariant is enforced on the JXL path,
/// mirroring `heif_decode_service.dart:17` for the HEIC path.
///
/// `PixelPayload`'s assert and `_imageFromPixels`' invariant both depend on
/// `rgba.length == width * height * 4`.
Future<DecodedRgba> _decodeJxl(String path, {int? maxDim}) async {
  final image = await CeyxStillDecoderService()
      .decodeOnWorker(path, maxDim: maxDim ?? 0);
  if (image == null) {
    throw StateError('JXL_DECODE_FAILED: ceyx returned no image for $path');
  }
  final expected = image.width * image.height * 4;
  if (image.rgba.length != expected) {
    throw StateError(
      'JXL length mismatch: rgba.length=${image.rgba.length} but '
      'width*height*4=$expected (${image.width}x${image.height})',
    );
  }
  return DecodedRgba(
      rgba: image.rgba, width: image.width, height: image.height);
}

/// [DngFullDecoder]-shaped JXL arm.
///
/// `decodeOnWorker` returns null -- never throws -- when this build of the
/// native library has no still-decode route or the decode itself fails; that
/// becomes the named [StateError] above, an ordinary decoder throw
/// downstream: `photo_source.dart`'s step-3b catch converts it into the
/// uniform permanent miss.
Future<DecodedRgba> decodeJxlFull(String path) => _decodeJxl(path);

const DngFullDecoder halcyonJxlFullDecoder = decodeJxlFull;
