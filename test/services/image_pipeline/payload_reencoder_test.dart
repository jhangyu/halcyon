import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_reencoder.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';

PixelPayload _pixels(int w, int h) =>
    PixelPayload(rgba: Uint8List(w * h * 4), width: w, height: h);

Future<Uint8List> _okEncoder(
  Uint8List rgba, {
  required int width,
  required int height,
  required int quality,
}) async => Uint8List(width * height); // 1 byte/pixel stand-in

void main() {
  setUp(resetReencodeCounters);

  // TC-361
  test('encodes the FULL-RESOLUTION pixels into a plain EncodedPayload', () async {
    final result = await reencodePayload(
      encoder: _okEncoder,
      fallback: _pixels(10, 10),
      fullRes: (rgba: Uint8List(40 * 40 * 4), width: 40, height: 40),
    );
    expect(result, isA<EncodedPayload>());
    final encoded = result as EncodedPayload;
    expect(encoded.bytes.length, 1600, reason: 'full-res 40x40, not window 10x10');
    expect(encoded.byteCost, 1600);
    expect(reencodeFallbacks, 0);
  });

  // TC-362
  test('encoder failure falls back to the SAME PixelPayload', () async {
    final fallback = _pixels(10, 10);
    final result = await reencodePayload(
      encoder: (rgba, {required width, required height, required quality}) =>
          throw StateError('boom'),
      fallback: fallback,
      fullRes: (rgba: Uint8List(16), width: 2, height: 2),
    );
    expect(identical(result, fallback), isTrue);
    expect(reencodeFallbacks, 1);
  });

  // TC-363
  test('absent full-resolution pixels fall back rather than encoding the window',
      () async {
    final fallback = _pixels(10, 10);
    final result = await reencodePayload(
      encoder: _okEncoder,
      fallback: fallback,
      fullRes: null,
    );
    expect(identical(result, fallback), isTrue,
        reason: 'never ship window-res pixels into the full-size tier');
    expect(reencodeFallbacks, 1);
  });
}
