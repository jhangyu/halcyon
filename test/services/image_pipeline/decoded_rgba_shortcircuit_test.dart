import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/decoded_rgba_image_provider.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';

/// A 2x3 opaque source: R carries a per-pixel marker so a wrong permutation
/// cannot pass by accident, and A is 0xFF everywhere so the premultiplied
/// (readback) and straight (short-circuit) encodings are byte-identical.
DecodedRgba _source() {
  const markers = <int>[10, 50, 90, 130, 170, 210];
  final bytes = Uint8List(2 * 3 * 4);
  for (var i = 0; i < markers.length; i++) {
    bytes[i * 4] = markers[i];
    bytes[i * 4 + 3] = 255;
  }
  return DecodedRgba(rgba: bytes, width: 2, height: 3);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // TC-819
  test('identity orientation at longEdge 0 returns the decoder buffer itself',
      () async {
    final src = _source();
    final payload =
        await decodedRgbaToPixelPayload(src, exifOrientation: 1, longEdge: 0);
    expect(identical(payload.rgba, src.rgba), isTrue);
    expect(payload.width, 2);
    expect(payload.height, 3);
  });

  // TC-820
  test('identity orientation with no downscale required short-circuits too',
      () async {
    final src = _source();
    final payload = await decodedRgbaToPixelPayload(
      src,
      exifOrientation: 1,
      longEdge: 4096,
    );
    expect(identical(payload.rgba, src.rgba), isTrue);
  });

  // TC-821 -- the short-circuit must be byte-equal to the GPU round trip it
  // replaces. `decodedRgbaToImage` is the same upload+orient path the old
  // implementation used, so its readback is the reference output.
  test('short-circuit bytes equal the GPU round trip for an opaque frame',
      () async {
    final src = _source();
    final image = await decodedRgbaToImage(src, exifOrientation: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    final reference = data!.buffer.asUint8List();

    final payload =
        await decodedRgbaToPixelPayload(src, exifOrientation: 1, longEdge: 0);
    expect(payload.rgba, orderedEquals(reference));
  });

  // TC-822 -- the out-of-bounds guard must survive the short-circuit.
  test('buffer/dimension mismatch still throws on the short-circuit path',
      () async {
    final bad = DecodedRgba(rgba: Uint8List(4), width: 2, height: 3);
    expect(
      () => decodedRgbaToPixelPayload(bad, exifOrientation: 1, longEdge: 0),
      throwsArgumentError,
    );
  });

  // TC-823 -- the non-identity path is untouched: orientation 6 still rotates.
  test('orientation 6 still rotates and does not short-circuit', () async {
    final src = _source();
    final payload =
        await decodedRgbaToPixelPayload(src, exifOrientation: 6, longEdge: 0);
    expect(identical(payload.rgba, src.rgba), isFalse);
    expect(payload.width, 3);
    expect(payload.height, 2);
  });

  // TC-824a
  test('oriented full-res carries no handle for orientation 1', () async {
    final src = _source();
    final full = await decodedRgbaToOrientedFullRes(src, exifOrientation: 1);
    expect(full.image, isNull);
    expect(identical(full.rgba, src.rgba), isTrue);
    expect(full.width, 2);
    expect(full.height, 3);
  });

  // TC-824b
  test('oriented full-res carries the rendered handle for orientation 6',
      () async {
    final src = _source();
    final full = await decodedRgbaToOrientedFullRes(src, exifOrientation: 6);
    expect(full.image, isNotNull);
    expect(full.image!.width, 3);
    expect(full.image!.height, 2);
    expect(full.width, 3);
    expect(full.height, 2);
    // The bytes and the handle must describe the same frame.
    final data =
        await full.image!.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(full.rgba, orderedEquals(data!.buffer.asUint8List()));
    full.image!.dispose();
  });

  // TC-824c -- the handle is handed out live, not already disposed.
  test('the returned handle is the caller\'s to dispose', () async {
    final src = _source();
    final full = await decodedRgbaToOrientedFullRes(src, exifOrientation: 6);
    expect(full.image!.debugDisposed, isFalse);
    full.image!.dispose();
    expect(full.image!.debugDisposed, isTrue);
  });
}
