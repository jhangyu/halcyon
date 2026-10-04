// `TierTwoRegistry.onStateChanged` -- the per-item readiness exit the
// controller re-derives its notifiers from (memory.md AD-072; it replaced the
// tier-1 dedup hook `onReadyForDisplay`). Pinned direct against the registry,
// no controller fixture, no race with a navigation debounce or a RAW decode:
//   * on a LANDING it fires after `notifyLoaded` (TC-1244/TC-1245);
//   * it ALSO fires on eviction and on both failure exits (TC-1471), which is
//     what lets a watched item fall back off full resolution instead of
//     keeping a stale ready stage.
//
// There was no dedicated unit-test file for TierTwoRegistry before this one
// (confirmed absent by test-runner-haiku during the AC-P2a gate).

import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_registry.dart';

import '../../support/preload_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  test(
    'TC-1244 publishFullRes calls notifyLoaded BEFORE onStateChanged',
    () async {
      final order = <String>[];
      final payload = freshEncodedPayload();
      late final TierTwoRegistry registry;
      registry = TierTwoRegistry(
        currentPayloadFor: (id) => payload,
        onStateChanged: (id) => order.add('ready:$id'),
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
        reason: 'the state exit fires once per landing, after the '
            'landing callback',
      );
    },
  );

  test(
    'TC-1245 publishEncoded calls notifyLoaded BEFORE onStateChanged',
    () async {
      final order = <String>[];
      final payload = freshEncodedPayload();
      late final TierTwoRegistry registry;
      registry = TierTwoRegistry(
        currentPayloadFor: (id) => payload,
        onStateChanged: (id) => order.add('ready:$id'),
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
        reason: 'the state exit fires once per landing, after the '
            'landing callback',
      );
    },
  );

  test(
    'TC-1246 keyFor exposes the SAME object registered as the ImageCache '
    'key',
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

  test(
    'TC-1471 onStateChanged also fires on eviction and on a cache-refused '
    'publish, and isReady agrees with it at each call',
    () async {
      final payload = freshEncodedPayload();
      final calls = <(String, bool)>[];
      late final TierTwoRegistry registry;
      registry = TierTwoRegistry(
        currentPayloadFor: (id) => payload,
        onStateChanged: (id) => calls.add((id, registry.isReady(id))),
      );

      registry.publishFullRes('e', payload, await tinyImage(), () {});
      await until(() => registry.isReady('e'));
      expect(calls, [('e', true)], reason: 'landing');

      registry.evict('e');
      expect(calls.last, ('e', false), reason: 'eviction must be reported');
      final afterEvict = calls.length;
      registry.evict('e');
      expect(calls.length, afterEvict,
          reason: 'evicting nothing reports nothing');

      // Failure exit: a frame larger than the whole cache is refused, which
      // the registry records as a failure and evicts -- and must report.
      final cache = PaintingBinding.instance.imageCache;
      final saved = cache.maximumSizeBytes;
      addTearDown(() => cache.maximumSizeBytes = saved);
      cache.maximumSizeBytes = 1;
      calls.clear();
      registry.publishFullRes('f', payload, await tinyImage(), () {});
      expect(registry.hasFullResFailure('f', payload), isTrue,
          reason: 'precondition: the publish was refused');
      expect(calls, contains(('f', false)),
          reason: 'a failure must reach the notifier too');
    },
  );

  test(
    'TC-1472 a publishEncoded decode failure is memoised and the same '
    'payload is not decoded again',
    () async {
      final payload = EncodedPayload(Uint8List.fromList([1, 2, 3]));
      final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);

      registry.publishEncoded(
        'x',
        payload,
        MemoryImage(payload.bytes),
        () {},
      );
      await until(
        () => registry.hasEncodedFailure('x', payload),
        reason: 'the failed decode to be recorded',
      );
      expect(registry.isReady('x'), isFalse);

      final obtainCalls = <int>[];
      final again = _CountingMemoryImage(payload.bytes, obtainCalls);
      registry.publishEncoded('x', payload, again, () {});
      expect(obtainCalls, isEmpty,
          reason: 'a payload that already failed must not be resubmitted');
    },
  );
}

class _CountingMemoryImage extends MemoryImage {
  const _CountingMemoryImage(super.bytes, this.calls);
  final List<int> calls;

  @override
  Future<MemoryImage> obtainKey(ImageConfiguration configuration) {
    calls.add(1);
    return super.obtainKey(configuration);
  }
}
