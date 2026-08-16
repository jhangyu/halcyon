// dng_processor has no barrel export, so importing its `src/` is the only
// option available — not an oversight to tidy up. This import becomes clean
// the moment the decoder project ships `lib/dng_processor.dart`; that is
// request B in docs/logs/2026-08-16/round-3b-decoder-project-interface-requests.md
// ignore: implementation_imports
import 'package:dng_processor/src/dng_decoder_service.dart';

import 'dng_decode_contract.dart';

/// Round-3b adapter: wraps `dng_processor`'s [DngDecoderService.decodeOnWorker]
/// to satisfy the frozen [DngFullDecoder] seam.
///
/// Kept production-clean: no dylib-preload workaround, no dev-only path
/// hacks. In a release .app the dylib is embedded next to the executable
/// (see the Xcode "Embed DNG Native Dylib" run script phase) and resolved
/// via `dng_bindings.dart`'s own search order.
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
