// AC-P2a ordering pin (docs/logs/2026-09-12/gpu-texture-contract.md,
// impl-p2-dedup-opus spec): `TierTwoRegistry.onReadyForDisplay` MUST fire
// AFTER `notifyLoaded`, never before. This is the cheapest possible pin for
// that ordering -- direct against the registry, no controller fixture, no
// race with a navigation debounce or a RAW decode.
//
// There was no dedicated unit-test file for TierTwoRegistry before this one
// (confirmed absent by test-runner-haiku during the AC-P2a gate).

import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_registry.dart';

import '../../support/preload_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  test(
    'TC-1244 publishFullRes calls notifyLoaded BEFORE onReadyForDisplay',
    () async {
      final order = <String>[];
      final payload = freshEncodedPayload();
      late final TierTwoRegistry registry;
      registry = TierTwoRegistry(
        currentPayloadFor: (id) => payload,
        onReadyForDisplay: (id) => order.add('ready:$id'),
      );
      final image = await tinyImage();

      registry.publishFullRes('a', payload, image, () => order.add('notify:a'));

      await until(
        () => registry.isReady('a'),
        reason: 'publishFullRes to complete its decode listener',
      );

      expect(
        order,
        ['notify:a', 'ready:a'],
        reason: 'AC-P2a: the dedup hook must never fire before the '
            'notification that makes the view switch to tier-2',
      );
    },
  );

  test(
    'TC-1245 publishEncoded calls notifyLoaded BEFORE onReadyForDisplay',
    () async {
      final order = <String>[];
      final payload = freshEncodedPayload();
      late final TierTwoRegistry registry;
      registry = TierTwoRegistry(
        currentPayloadFor: (id) => payload,
        onReadyForDisplay: (id) => order.add('ready:b'),
      );
      final provider = MemoryImage(Uint8List.fromList(tinyPngBytes));

      registry.publishEncoded(
        'b',
        payload,
        provider,
        () => order.add('notify:b'),
      );

      await until(
        () => registry.isReady('b'),
        reason: 'publishEncoded to complete its decode listener',
      );

      expect(
        order,
        ['notify:b', 'ready:b'],
        reason: 'AC-P2a: the dedup hook must never fire before the '
            'notification that makes the view switch to tier-2',
      );
    },
  );

  test(
    'TC-1246 keyFor exposes the SAME object registered as the ImageCache '
    'key, which is what lets the controller compare it against a tier-1 '
    'key for equality (the shared-entry guard)',
    () async {
      final payload = freshEncodedPayload();
      final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);
      final image = await tinyImage();

      registry.publishFullRes('c', payload, image, () {});
      await until(() => registry.isReady('c'));

      final key = registry.keyFor('c');
      expect(key, isNotNull);
      expect(
        PaintingBinding.instance.imageCache.containsKey(key!),
        isTrue,
        reason: 'keyFor must return the actual resident ImageCache key, '
            'not a reconstruction',
      );
    },
  );
}
