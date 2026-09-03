import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_reencoder.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_source.dart';

NativeImageLoad _loaderReturning(NativeImageResult result) =>
    (path, {required purpose, targetLongEdge}) async => result;

Future<DecodedRgba> _decoder(String path) async {
  final bytes = Uint8List(8 * 6 * 4);
  for (var p = 0; p < 8 * 6; p++) {
    bytes[p * 4 + 3] = 255;
  }
  return DecodedRgba(rgba: bytes, width: 8, height: 6);
}

Future<DecodedRgba> _throwingDecoder(String path) async =>
    throw StateError('boom');

Future<Uint8List> _encoder(
  Uint8List rgba, {
  required int width,
  required int height,
  required int quality,
}) async => Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);

Future<Uint8List> _throwingEncoder(
  Uint8List rgba, {
  required int width,
  required int height,
  required int quality,
}) async => throw StateError('encode failed');

/// Compares every field the pipeline reads, `fullRes` by presence only (the
/// two runs decode separately, so their buffers are different objects).
void expectSameOutcome(SourceOutcome split, SourceOutcome oneShot) {
  expect(split.payload.runtimeType, oneShot.payload.runtimeType);
  expect(split.observedCost, oneShot.observedCost);
  expect(split.deferred, oneShot.deferred);
  expect(split.exifOrientation, oneShot.exifOrientation);
  expect(split.failureCode, oneShot.failureCode);
  expect(split.fullRes == null, oneShot.fullRes == null);
  if (split.payload is EncodedPayload) {
    expect(
      (split.payload! as EncodedPayload).bytes,
      orderedEquals((oneShot.payload! as EncodedPayload).bytes),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final cases = <String, PhotoSource>{
    'cheap jpeg': PhotoSource(
      loader: _loaderReturning(
        NativeImageBytes(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9])),
      ),
      dngDecoder: _decoder,
    ),
    'raw success': PhotoSource(
      loader: _loaderReturning(
        const NativeImageNeedsRawDecode(exifOrientation: 1),
      ),
      dngDecoder: _decoder,
      payloadEncoder: _encoder,
    ),
    'no decoder': PhotoSource(
      loader: _loaderReturning(
        const NativeImageNeedsRawDecode(exifOrientation: 1),
      ),
    ),
    'throwing decoder': PhotoSource(
      loader: _loaderReturning(
        const NativeImageNeedsRawDecode(exifOrientation: 1),
      ),
      dngDecoder: _throwingDecoder,
      payloadEncoder: _encoder,
    ),
  };

  // TC-831a
  cases.forEach((name, source) {
    test('two-phase equals one-shot: $name', () async {
      final oneShot = await source.load('x.dng', longEdge: 64);
      final split = await source.encodePhase(
        await source.decodePhase('x.dng', longEdge: 64),
      );
      expectSameOutcome(split, oneShot);
      oneShot.fullRes?.image?.dispose();
      split.fullRes?.image?.dispose();
    });
  });

  // TC-831a (deferred arm needs allowExpensive: false)
  test('two-phase equals one-shot: deferred', () async {
    final source = PhotoSource(
      loader: _loaderReturning(
        const NativeImageNeedsRawDecode(exifOrientation: 6),
      ),
      dngDecoder: _decoder,
      payloadEncoder: _encoder,
    );
    final oneShot =
        await source.load('x.dng', longEdge: 64, allowExpensive: false);
    final split = await source.encodePhase(
      await source.decodePhase('x.dng', longEdge: 64, allowExpensive: false),
    );
    expectSameOutcome(split, oneShot);
    expect(split.deferred, isTrue);
    expect(split.exifOrientation, 6);
  });

  // TC-831b
  test('an encoder that throws degrades to the pixel fallback', () async {
    resetReencodeCounters();
    final source = PhotoSource(
      loader: _loaderReturning(
        const NativeImageNeedsRawDecode(exifOrientation: 1),
      ),
      dngDecoder: _decoder,
      payloadEncoder: _throwingEncoder,
    );
    final outcome = await source.encodePhase(
      await source.decodePhase('x.dng', longEdge: 64),
    );
    expect(outcome.payload, isA<PixelPayload>());
    expect(reencodeFallbacks, 1);
  });
}
