import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/services/dng_decode_contract.dart';
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

  test(
    'pngFromOrientedPixels bakes EXIF orientation 6 (90 CW) into a decodable'
    ' PNG, pixel-exact',
    () async {
      // Source 4x2 (w=4, h=2), every pixel a distinct marker in the R
      // channel, so a wrong orientation cannot pass by accident (pattern of
      // decoded_rgba_image_provider_test.dart's _expected fixture).
      //   row0 (y=0): P0 P1 P2 P3
      //   row1 (y=1): Q0 Q1 Q2 Q3
      const p0 = 10, p1 = 40, p2 = 70, p3 = 100;
      const q0 = 130, q1 = 160, q2 = 190, q3 = 220;
      final markers = [
        [p0, p1, p2, p3],
        [q0, q1, q2, q3],
      ];
      final bytes = Uint8List(4 * 2 * 4);
      var i = 0;
      for (final row in markers) {
        for (final marker in row) {
          bytes[i++] = marker; // R carries the marker
          bytes[i++] = 0;
          bytes[i++] = 0;
          bytes[i++] = 255; // opaque
        }
      }
      final decoded = DecodedRgba(rgba: bytes, width: 4, height: 2);

      final png = await pngFromOrientedPixels(decoded, exifOrientation: 6);

      final codec = await ui.instantiateImageCodec(png);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 2);
      expect(frame.image.height, 4);

      final data = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      final out = data!.buffer.asUint8List();
      List<int> rowMarkers(int y) =>
          [for (var x = 0; x < 2; x++) out[(y * 2 + x) * 4]];

      // rotate 90 CW: output[y'][x'] = input[h-1-x'][y'] (h=2) --
      // row0: Q0,P0 · row1: Q1,P1 · row2: Q2,P2 · row3: Q3,P3
      expect(rowMarkers(0), [q0, p0]);
      expect(rowMarkers(1), [q1, p1]);
      expect(rowMarkers(2), [q2, p2]);
      expect(rowMarkers(3), [q3, p3]);
    },
  );
}
