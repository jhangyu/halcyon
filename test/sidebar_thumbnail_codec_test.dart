import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/services/sidebar_thumbnail_codec.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Uint8List> bigPng() async {
    // Synthesize a 1200x800 image and PNG-encode it: a >512KB-ish encoded
    // payload with known dims, no sample-file dependency.
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final paint = ui.Paint();
    for (var x = 0; x < 1200; x += 10) {
      paint.color = ui.Color.fromARGB(255, x % 256, (x * 7) % 256, 99);
      canvas.drawRect(ui.Rect.fromLTWH(x.toDouble(), 0, 10, 800), paint);
    }
    final img = await recorder.endRecording().toImage(1200, 800);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  test('small payloads pass through untouched (identity, same object)', () async {
    final small = Uint8List.fromList(List.filled(1024, 7));
    expect(identical(await sidebarCacheBytes(small), small), isTrue);
  });

  test('oversized payloads are re-encoded with the long edge capped at 200',
      () async {
    final src = await bigPng();
    final out = await sidebarCacheBytes(src, reencodeThreshold: 1024);
    expect(out.length, lessThan(src.length));
    final codec = await ui.instantiateImageCodec(out);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 200);   // landscape: width is the long edge
    expect(frame.image.height, 133);  // 800 * 200 / 1200 rounded
  });
}
