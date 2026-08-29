import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_source.dart';

Future<NativeImageResult> _needsRawDecode(
  String path, {
  required ImageRequestPurpose purpose,
}) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

Future<DecodedRgba> _fakeDecoder(String path) async =>
    DecodedRgba(rgba: Uint8List(64 * 48 * 4), width: 64, height: 48);

Future<Uint8List> _fakeEncoder(
  Uint8List rgba, {
  required int width,
  required int height,
  required int quality,
}) async => Uint8List.fromList([0xFF, 0xD8, width & 0xFF, height & 0xFF]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // TC-364
  test('load() re-encodes a decoded RAW into a plain EncodedPayload', () async {
    const source = PhotoSource(
      loader: _needsRawDecode,
      dngDecoder: _fakeDecoder,
      payloadEncoder: _fakeEncoder,
    );
    final outcome = await source.load('x.dng', longEdge: 32);
    expect(outcome.payload, isA<EncodedPayload>());
    expect((outcome.payload! as EncodedPayload).bytes.first, 0xFF);
    // The piggyback RGBA must SURVIVE the re-encode: it is a free tier-2 upload.
    expect(outcome.fullRes, isNotNull);
  });

  // TC-364b — the two decode paths must not diverge
  test('loadExpensive() re-encodes identically', () async {
    const source = PhotoSource(
      loader: _needsRawDecode,
      dngDecoder: _fakeDecoder,
      payloadEncoder: _fakeEncoder,
    );
    final outcome =
        await source.loadExpensive('x.dng', longEdge: 32, exifOrientation: 1);
    expect(outcome.payload, isA<EncodedPayload>());
  });

  // TC-365
  test('no encoder configured -> unchanged PixelPayload behaviour', () async {
    const source = PhotoSource(loader: _needsRawDecode, dngDecoder: _fakeDecoder);
    final outcome = await source.load('x.dng', longEdge: 32);
    expect(outcome.payload, isA<PixelPayload>());
  });
}
