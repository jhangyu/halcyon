import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Wraps RGBA8 [rgba] in an [img.Image] and JPEG-encodes it on a worker
/// isolate. `numChannels: 4` + [img.ChannelOrder.rgba] match `dart:ui`'s
/// `rawRgba` byte order exactly, so no channel shuffle happens here; the
/// encoder drops alpha, which JPEG cannot represent.
///
/// `Isolate.run` because JPEG encoding is pure CPU and would otherwise run on
/// the UI isolate. This is the ONE encoder in the pipeline: the sidebar
/// thumbnail codec and the Phase 13 payload re-encoder both call it, so their
/// channel-order and isolate decisions cannot drift apart.
///
/// Throws whatever the encoder throws. Callers own the fallback policy.
Future<Uint8List> encodeJpegFromRgba(
  Uint8List rgba, {
  required int width,
  required int height,
  required int quality,
}) {
  return Isolate.run(() {
    final image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: rgba.buffer,
      bytesOffset: rgba.offsetInBytes,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    return Uint8List.fromList(img.encodeJpg(image, quality: quality));
  });
}
