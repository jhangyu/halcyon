import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:halcyon_flutter/services/image_pipeline/decoded_rgba_image_provider.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/sidebar_thumbnail_codec.dart';

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

  test(
    'TC-172 a payload at exactly reencodeThreshold passes through byte-identical',
    () async {
      // Boundary: the branch is `<=`, so the threshold value itself must NOT
      // be re-encoded. Content is a PNG so that a mistaken re-encode would
      // succeed and change the bytes rather than fall into the catch.
      final src = await bigPng();
      final out = await sidebarCacheBytes(src, reencodeThreshold: src.length);
      expect(out, same(src), reason: 'no copy, no re-encode at the threshold');
      expect(out, orderedEquals(src));
    },
  );

  test(
    'TC-173 oversized payloads are re-encoded as JPEG, long edge capped at 200',
    () async {
      final src = await bigPng();
      final out = await sidebarCacheBytes(src, reencodeThreshold: 1024);

      // JPEG SOI marker: the bytes really are JPEG, not PNG (0x89 0x50).
      expect([out[0], out[1]], [0xFF, 0xD8]);

      // Deliberately NOT asserting out.length < src.length here. This fixture
      // is flat vertical stripes, which is pathologically good for PNG's
      // filter+deflate (5.7KB) and pathologically bad for JPEG's DCT (14.6KB),
      // so the synthetic case genuinely inverts. The size win being claimed is
      // for photographic content and is evidenced on real DNG samples in
      // scripts/tmp/m7-t5/size-comparison.md, not here.

      // Decode-back must actually succeed. JPEG cannot carry alpha, so this
      // asserts the alpha-dropping encode still produces something the
      // sidebar can display, rather than assuming it.
      final codec = await ui.instantiateImageCodec(out);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 200); // landscape: width is the long edge
      expect(frame.image.height, 133); // 800 * 200 / 1200 rounded
      expect(
        frame.image.width <= 200 && frame.image.height <= 200,
        isTrue,
        reason: 'long edge capped at 200',
      );
      frame.image.dispose();
    },
  );

  test('TC-174 undecodable oversized input falls back to the original bytes',
      () async {
    // Over the threshold so the re-encode branch is entered, but not a
    // decodable bitstream: the catch must cache the original rather than
    // drop the row.
    final junk = Uint8List.fromList(List.generate(4096, (i) => i % 256));
    final out = await sidebarCacheBytes(junk, reencodeThreshold: 1024);
    expect(out, same(junk));
  });

  test(
    'TC-175 (retargeted) the sidebar pixel path bakes EXIF orientation 6 '
    '(90 CW) into the stored payload',
    () async {
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

      final payload = await decodedRgbaToPixelPayload(
        decoded,
        exifOrientation: 6,
        longEdge: 200,
      );

      expect(payload.width, 2);
      expect(payload.height, 4);
      List<int> rowMarkers(int y) =>
          [for (var x = 0; x < 2; x++) payload.rgba[(y * 2 + x) * 4]];
      // rotate 90 CW: output[y'][x'] = input[h-1-x'][y'] (h=2)
      expect(rowMarkers(0), [q0, p0]);
      expect(rowMarkers(1), [q1, p1]);
      expect(rowMarkers(2), [q2, p2]);
      expect(rowMarkers(3), [q3, p3]);
    },
  );

  test('TC-176 jpegQuality is tunable and changes the encoded size', () async {
    final src = await bigPng();
    final low = await sidebarCacheBytes(
      src,
      reencodeThreshold: 1024,
      jpegQuality: 30,
    );
    final high = await sidebarCacheBytes(
      src,
      reencodeThreshold: 1024,
      jpegQuality: 95,
    );
    expect(low.length, lessThan(high.length));
  });

  test('TC-217 sidebarCacheBytes still returns decodable JPEG', () async {
    // A 900x600 PNG is over the 512 KiB passthrough threshold once raw, so
    // build a large encoded input that forces the decode/re-encode branch.
    final big = img.Image(width: 900, height: 600, numChannels: 4);
    // Pseudo-random per-pixel noise: PNG's filter+deflate cannot compress
    // this away the way flat/striped content would, so the encoded size
    // reliably clears the 512 KiB passthrough threshold.
    var seed = 12345;
    int nextByte() {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      // Low-order bits of a linear congruential generator cycle with a much
      // shorter period than the generator itself (classic LCG flaw) -- use
      // the high bits instead, or the "noise" compresses like a repeating
      // pattern and never clears the threshold.
      return (seed >> 16) & 0xff;
    }

    for (final pixel in big) {
      pixel.setRgba(nextByte(), nextByte(), nextByte(), 255);
    }
    final encoded = Uint8List.fromList(img.encodePng(big));
    expect(encoded.length, greaterThan(512 * 1024));

    final out = await sidebarCacheBytes(encoded);

    expect(out.length, lessThan(encoded.length));
    final decoded = img.decodeJpg(out);
    expect(decoded, isNotNull);
    expect(decoded!.width <= 200 && decoded.height <= 200, isTrue);
  });
}
