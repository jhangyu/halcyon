import 'dart:typed_data';

import 'package:ceyx/ceyx.dart';

import '../../models/supported_photo_formats.dart';
import 'dng_decode_contract.dart';

/// Adapter from `ceyx`'s generic still-decode surface to the frozen
/// [DngFullDecoder] seam, for every container the native still route decodes
/// (HEIC, HEIF, AVIF and JPEG XL). Mirrors `dng_decode_service.dart`
/// deliberately: same length check, same StateError shape.
///
/// Kept production-clean: no dylib-preload workaround and no dev-only path
/// hacks. The native dylibs land in `<App>.app/Contents/Frameworks/` because
/// `ceyx` is a Flutter FFI plugin whose pod vendors them, and the package's
/// own search order finds them there.

/// True for the containers the `ceyx` still route decodes. Checked BEFORE
/// `isBitmapDecodePath` by every router: `.heic`/`.avif`/`.jxl` are also in
/// `bitmapDecodeExtensions`, and `package:image` cannot read them.
bool isStillRoutePath(String path) =>
    SupportedPhotoFormats.isLibheifPath(path) ||
    SupportedPhotoFormats.isJxlPath(path);

/// The single place the RGBA geometry invariant is enforced on the still path.
///
/// `PixelPayload`'s assert and `_imageFromPixels`' invariant both depend on
/// `rgba.length == width * height * 4`. Native checks it too; checking again
/// here means a future ABI drift surfaces as a named error instead of as an
/// assert deep inside the image provider, where the message names neither the
/// file nor the decoder.
Future<DecodedRgba> stillImageToDecodedRgba({
  required Uint8List rgba,
  required int width,
  required int height,
}) async {
  final expectedLength = width * height * 4;
  if (rgba.length != expectedLength) {
    throw StateError(
      'ceyx still decode length mismatch: rgba.length=${rgba.length} but '
      'width*height*4=$expectedLength (width=$width, height=$height)',
    );
  }
  return DecodedRgba(rgba: rgba, width: width, height: height);
}

/// [DngFullDecoder]-shaped still arm.
///
/// `decodeOnWorker` returns null -- never throws -- when this build of the
/// native library has no still-decode route or the decode itself fails; that
/// becomes the named [StateError] below, an ordinary decoder throw
/// downstream: `photo_source.dart`'s step-3b catch converts it into the
/// uniform permanent miss, and the D3 `kNoNativeDecoderCode` state stays
/// reserved for a null decoder.
Future<DecodedRgba> decodeStillFull(String path) async {
  final image = await CeyxStillDecoderService().decodeOnWorker(path);
  if (image == null) {
    throw StateError('STILL_DECODE_FAILED: ceyx returned no image for $path');
  }
  return stillImageToDecodedRgba(
    rgba: image.rgba,
    width: image.width,
    height: image.height,
  );
}

const DngFullDecoder halcyonStillFullDecoder = decodeStillFull;
