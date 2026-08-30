import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/thumbnail_derivation.dart';

Future<Uint8List> _encodedOf(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF3366AA),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<({int width, int height})> _dimsOf(Uint8List encoded) async {
  final codec = await ui.instantiateImageCodec(encoded);
  final frame = await codec.getNextFrame();
  final dims = (width: frame.image.width, height: frame.image.height);
  frame.image.dispose();
  return dims;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // TC-424
  test('an encoded payload derives to at most 200px on the long edge',
      () async {
    final payload = EncodedPayload(await _encodedOf(1200, 800));
    final derived = await deriveThumbnailPayload(payload);
    final dims = await _dimsOf((derived! as EncodedPayload).bytes);
    expect(dims.width, 200);
    expect(dims.height, lessThanOrEqualTo(200));
  });

  // TC-425
  test('a pixel payload resamples without any decoder call', () async {
    final payload = PixelPayload(
      rgba: Uint8List(1200 * 800 * 4),
      width: 1200,
      height: 800,
    );
    final derived = await deriveThumbnailPayload(payload) as PixelPayload;
    expect(derived.width, 200);
    expect(derived.height, lessThanOrEqualTo(200));
    expect(derived.rgba.lengthInBytes, derived.width * derived.height * 4);
  });

  // TC-426
  test('undecodable bytes return without throwing', () async {
    final payload = EncodedPayload(Uint8List.fromList(<int>[0, 1, 2, 3]));
    final derived = await deriveThumbnailPayload(payload);
    // Either null, or the passthrough `sidebarCacheBytes` performs on
    // undecodable input. Both are acceptable; throwing is not.
    expect(derived == null || derived is EncodedPayload, isTrue);
  });
}
