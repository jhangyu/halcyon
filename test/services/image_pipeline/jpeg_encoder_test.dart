import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/jpeg_encoder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // TC-360
  test('encodes RGBA8 to a JPEG bitstream of the same dimensions', () async {
    const w = 16, h = 16;
    final rgba = Uint8List(w * h * 4);
    for (var i = 0; i < rgba.length; i += 4) {
      rgba[i] = 0xFF; // R
      rgba[i + 3] = 0xFF; // A
    }

    final jpeg = await encodeJpegFromRgba(rgba, width: w, height: h, quality: 80);

    expect(jpeg.length, greaterThan(2));
    expect(jpeg[0], 0xFF, reason: 'JPEG SOI byte 0');
    expect(jpeg[1], 0xD8, reason: 'JPEG SOI byte 1');

    final codec = await ui.instantiateImageCodec(jpeg);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, w);
    expect(frame.image.height, h);
    frame.image.dispose();
  });
}
