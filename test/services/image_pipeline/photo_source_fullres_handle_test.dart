import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_source.dart';

Future<NativeImageResult> _needsRawDecode(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

Future<NativeImageResult> _needsRawDecodeRotated(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => const NativeImageNeedsRawDecode(exifOrientation: 6);

/// 8x6 opaque RGBA so the premultiplied/straight equivalence holds.
DecodedRgba _decoded() {
  final bytes = Uint8List(8 * 6 * 4);
  for (var p = 0; p < 8 * 6; p++) {
    bytes[p * 4] = p % 256;
    bytes[p * 4 + 3] = 255;
  }
  return DecodedRgba(rgba: bytes, width: 8, height: 6);
}

late DecodedRgba lastDecoded;
Future<DecodedRgba> _decoder(String path) async {
  lastDecoded = _decoded();
  return lastDecoded;
}

Future<DecodedRgba> _throwingDecoder(String path) async =>
    throw StateError('decode failed');

Future<Uint8List> _encoder(
  Uint8List rgba, {
  required int width,
  required int height,
  required int quality,
}) async => Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // TC-827a
  test('orientation 1 hands back the decoder buffer and no handle', () async {
    const source = PhotoSource(
      loader: _needsRawDecode,
      dngDecoder: _decoder,
      payloadEncoder: _encoder,
    );
    final outcome = await source.load('x.dng', longEdge: 0);
    expect(outcome.fullRes, isNotNull);
    expect(outcome.fullRes!.image, isNull);
    expect(identical(outcome.fullRes!.rgba, lastDecoded.rgba), isTrue);
  });

  // TC-827b
  test('orientation 6 hands back a live oriented handle', () async {
    const source = PhotoSource(
      loader: _needsRawDecodeRotated,
      dngDecoder: _decoder,
      payloadEncoder: _encoder,
    );
    final outcome = await source.load('x.dng', longEdge: 0);
    expect(outcome.fullRes!.image, isNotNull);
    expect(outcome.fullRes!.image!.debugDisposed, isFalse);
    expect(outcome.fullRes!.width, 6);
    expect(outcome.fullRes!.height, 8);
    outcome.fullRes!.image!.dispose();
  });

  // TC-827c -- a decode that fails leaves no handle and no fullRes.
  test('a throwing decoder returns no handle to leak', () async {
    const source = PhotoSource(
      loader: _needsRawDecodeRotated,
      dngDecoder: _throwingDecoder,
      payloadEncoder: _encoder,
    );
    final outcome = await source.load('x.dng', longEdge: 0);
    expect(outcome.payload, isNull);
    expect(outcome.fullRes, isNull);
  });
}
