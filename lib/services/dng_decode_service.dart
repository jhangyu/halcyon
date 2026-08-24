import 'package:dng_processor_ffi/dng_processor_ffi.dart';

import 'dng_decode_contract.dart';

/// Round-3b adapter: wraps `dng_processor_ffi`'s [DngDecoderService.decodeOnWorker]
/// to satisfy the frozen [DngFullDecoder] seam.
///
/// Kept production-clean: no dylib-preload workaround, no dev-only path
/// hacks. The dylib lands in `<App>.app/Contents/Frameworks/` because
/// `dng_processor_ffi` is a Flutter FFI plugin whose pod vendors it, and
/// `dng_bindings.dart`'s own search order finds it there.
Future<DecodedRgba> decodeDngFull(String path) async {
  final service = DngDecoderService();
  final image = await service.decodeOnWorker(path);

  final expectedLength = image.width * image.height * 4;
  if (image.rgbaData.length != expectedLength) {
    throw StateError(
      'dng_processor returned rgbaData.length=${image.rgbaData.length} '
      'but width*height*4=$expectedLength (width=${image.width}, '
      'height=${image.height})',
    );
  }

  return DecodedRgba(
    rgba: image.rgbaData,
    width: image.width,
    height: image.height,
  );
}

/// Single obvious entry point for the pipe squad to wire into
/// `image_preload_controller.dart`.
const DngFullDecoder halcyonDngFullDecoder = decodeDngFull;

/// M6 P2.5b: sized variant for the sidebar RAW-decode fallback (bare-CFA
/// DNGs with no embedded JPEG at any size). Mirrors [decodeDngFull]'s
/// length-check pattern exactly; [maxDim] is silently ignored by dylibs that
/// don't export the sized-decode symbol, so the returned dims are read back
/// rather than assumed (see [DngSizedDecoder]).
Future<DecodedRgba> decodeDngSized(String path, {required int maxDim}) async {
  final service = DngDecoderService();
  final image = await service.decodeOnWorker(path, maxDim: maxDim);

  final expectedLength = image.width * image.height * 4;
  if (image.rgbaData.length != expectedLength) {
    throw StateError(
      'dng_processor sized decode length mismatch: '
      'rgbaData.length=${image.rgbaData.length} but '
      'width*height*4=$expectedLength (width=${image.width}, '
      'height=${image.height})',
    );
  }

  return DecodedRgba(
    rgba: image.rgbaData,
    width: image.width,
    height: image.height,
  );
}

const DngSizedDecoder halcyonDngSizedDecoder = decodeDngSized;
