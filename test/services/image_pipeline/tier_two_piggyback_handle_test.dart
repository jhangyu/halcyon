import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/decode_lane.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_registry.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_scheduler.dart';

PhotoItem _photoItem(String id) =>
    PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);

Future<ui.Image> _image(int w, int h) {
  final completer = Completer<ui.Image>();
  final bytes = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 255);
  ui.decodeImageFromPixels(
    bytes,
    w,
    h,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

({TierTwoScheduler scheduler, TierTwoRegistry registry}) _harness(
  SourcePayload? Function(String) payloadFor,
) {
  final registry = TierTwoRegistry(currentPayloadFor: payloadFor);
  final scheduler = TierTwoScheduler(
    registry: registry,
    lane: DecodeLane(width: 1),
    currentPayloadFor: payloadFor,
    fullSizeProviderFor: (p) => throw StateError('not reached'),
    ensurePayload:
        (item, {required distance, required notifyLoaded, onSerialLane = false}) async {},
    dngDecoder: () => null,
    exifOrientationFor: (id) => 1,
    navigationDebounce: Duration.zero,
  );
  return (scheduler: scheduler, registry: registry);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // TC-825 -- a supplied handle is published with ZERO uploads.
  test('a supplied handle is published without decodeImageFromPixels',
      () async {
    final payload = EncodedPayload(Uint8List(4));
    final h = _harness((id) => id == 'a' ? payload : null);
    h.scheduler.updateWindow([_photoItem('a')], 0);
    final image = await _image(4, 4);
    await h.scheduler.publishPiggybackFullRes(
      'a',
      payload,
      (rgba: Uint8List(0), width: 4, height: 4, image: image),
      () {},
      distance: 0,
    );
    expect(h.registry.keyIds, contains('a'));
    // The published entry IS the supplied handle: an upload would have
    // produced a different image and left this one to be disposed.
    expect(image.debugDisposed, isFalse);
  });

  // TC-826 -- out of the tier-2 window: dispose, publish nothing.
  test('a stale window disposes the supplied handle', () async {
    final payload = EncodedPayload(Uint8List(4));
    final h = _harness((id) => payload);
    h.scheduler.updateWindow(const [], 0);
    final image = await _image(4, 4);
    await h.scheduler.publishPiggybackFullRes(
      'a',
      payload,
      (rgba: Uint8List(0), width: 4, height: 4, image: image),
      () {},
      distance: 0,
    );
    expect(image.debugDisposed, isTrue);
    expect(h.registry.keyIds, isNot(contains('a')));
  });

  // TC-826b -- payload replaced under us.
  test('a replaced payload disposes the supplied handle', () async {
    final published = EncodedPayload(Uint8List(4));
    final current = EncodedPayload(Uint8List(4));
    final h = _harness((id) => current);
    h.scheduler.updateWindow([_photoItem('a')], 0);
    final image = await _image(4, 4);
    await h.scheduler.publishPiggybackFullRes(
      'a',
      published,
      (rgba: Uint8List(0), width: 4, height: 4, image: image),
      () {},
      distance: 0,
    );
    expect(image.debugDisposed, isTrue);
    expect(h.registry.keyIds, isNot(contains('a')));
  });

  // TC-825b -- no handle: today's upload path, unchanged.
  test('a null handle still uploads and publishes', () async {
    final payload = EncodedPayload(Uint8List(4));
    final h = _harness((id) => payload);
    h.scheduler.updateWindow([_photoItem('a')], 0);
    await h.scheduler.publishPiggybackFullRes(
      'a',
      payload,
      (rgba: Uint8List(4 * 4 * 4), width: 4, height: 4, image: null),
      () {},
      distance: 0,
    );
    expect(h.registry.keyIds, contains('a'));
  });
}
