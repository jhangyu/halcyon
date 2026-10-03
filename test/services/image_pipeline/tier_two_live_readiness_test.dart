// Memory-reclamation campaign M2.1
// (docs/plans/2026-10-03-memory-reclamation-unification.md): readiness must
// count a tier-2 entry that the ImageCache LRU dropped while a widget is still
// PAINTING it. The SDK keeps such an entry as a LIVE image (image_cache.dart
// `_liveImages`), and `containsKey` does not see live images, so a
// containsKey-only readiness check re-decoded the displayed image into a
// second GPU texture (tmp/memprofile/i3/findings.md root cause 4).
//
// LRU eviction is simulated with `ImageCache.clear()`, which drops keepAlive
// entries and KEEPS live ones -- exactly what `_checkCacheSize` does.
// `ImageCache.evict(key)` is NOT a substitute: its default `includeLive: true`
// also drops the live reference (that is the registry's own eviction).
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/decode_lane.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_registry.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_scheduler.dart';

import '../../support/preload_fixtures.dart';

/// Listens to [provider] the way a painting `Image` widget does, so the
/// ImageCache tracks the entry as LIVE. Returns the detach.
VoidCallback _display(ImageProvider provider) {
  final stream = provider.resolve(ImageConfiguration.empty);
  final listener = ImageStreamListener((info, _) => info.dispose());
  stream.addListener(listener);
  return () => stream.removeListener(listener);
}

/// LRU eviction as the SDK performs it: keepAlive entries go, live ones stay.
void _lruEvictAll() => PaintingBinding.instance.imageCache.clear();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  test(
    'TC-1440 a full-res entry LRU-evicted while still displayed stays READY, '
    'and a second publishFullRes for the same payload is dropped and disposed '
    '-- no second texture',
    () async {
      final SourcePayload payload = freshEncodedPayload();
      final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);
      addTearDown(registry.clear);

      var notifications = 0;
      registry.publishFullRes(
          'IMG_00', payload, await tinyImage(), () => notifications++);
      await until(() => registry.isReady('IMG_00'),
          reason: 'the first full-res publish lands');
      final provider = registry.providerFor('IMG_00')!;
      addTearDown(_display(provider));

      _lruEvictAll();
      final ic = PaintingBinding.instance.imageCache;
      expect(ic.containsKey(provider), isFalse,
          reason: 'vacuity: the LRU really dropped the keepAlive entry');
      expect(ic.statusForKey(provider).live, isTrue,
          reason: 'vacuity: the displayed image is still in memory');

      expect(registry.isReady('IMG_00'), isTrue,
          reason: 'THE DEFECT: a displayed image is resident; reporting it '
              'absent makes the sweep re-decode it into a second texture');
      expect(registry.hasFullResEntryFor('IMG_00', payload), isTrue);
      expect(registry.fullResProviderFor('IMG_00'), same(provider));

      final duplicate = await tinyImage();
      registry.publishFullRes(
          'IMG_00', payload, duplicate, () => notifications++);
      expect(duplicate.debugDisposed, isTrue,
          reason: 'first-writer-wins must dispose the would-be second texture');
      expect(notifications, 1);
      expect(registry.providerFor('IMG_00'), same(provider));
      expect(registry.displayedRedecodeCount, 0,
          reason: 'D5 tripwire: no second texture for a displayed image');
    },
  );

  test(
    'TC-1441 an encoded entry LRU-evicted while still displayed stays READY, '
    'and a same-payload publishEncoded is deduped instead of re-inserted',
    () async {
      final payload = freshEncodedPayload();
      final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);
      addTearDown(registry.clear);

      final first = fullSizeProviderFor(payload.bytes);
      var notifications = 0;
      registry.publishEncoded('IMG_00', payload, first, () => notifications++);
      await until(() => registry.isReady('IMG_00'),
          reason: 'the first encoded publish lands');
      addTearDown(_display(first));

      _lruEvictAll();
      expect(PaintingBinding.instance.imageCache.containsKey(first), isFalse,
          reason: 'vacuity: the LRU really dropped the keepAlive entry');

      expect(registry.isReady('IMG_00'), isTrue);
      registry.publishEncoded('IMG_00', payload,
          fullSizeProviderFor(payload.bytes), () => notifications++);
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(notifications, 1,
          reason: 'the resident (live) entry must dedupe the re-publish');
      expect(registry.providerFor('IMG_00'), same(first));
    },
  );

  test(
    'TC-1442 control: once the display detaches, the LRU-evicted entry is '
    'gone and the eviction-recovery publish still lands (TC-1190 must not '
    'regress)',
    () async {
      final SourcePayload payload = freshEncodedPayload();
      final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);
      addTearDown(registry.clear);

      var notifications = 0;
      registry.publishFullRes(
          'IMG_00', payload, await tinyImage(), () => notifications++);
      await until(() => registry.isReady('IMG_00'));
      final detach = _display(registry.providerFor('IMG_00')!);
      _lruEvictAll();
      detach();

      expect(registry.isReady('IMG_00'), isFalse,
          reason: 'no listener and no keepAlive entry: really gone');
      expect(registry.hasFullResEntryFor('IMG_00', payload), isFalse);

      registry.publishFullRes(
          'IMG_00', payload, await tinyImage(), () => notifications++);
      await until(() => notifications == 2,
          reason: 'the recovery publish for the SAME payload object lands');
      expect(registry.isReady('IMG_00'), isTrue);
    },
  );

  test(
    'TC-1443 the debounced sweep buys NO second FFI decode for a band item '
    'that is displayed but was LRU-evicted',
    () async {
      final calls = <String, int>{};
      final payloads = <String, SourcePayload>{};
      final registry = TierTwoRegistry(currentPayloadFor: (id) => payloads[id]);
      final scheduler = TierTwoScheduler(
        registry: registry,
        lane: DecodeLane(width: 5),
        currentPayloadFor: (id) => payloads[id],
        fullSizeProviderFor: (payload) => switch (payload) {
          EncodedPayload(:final bytes) => fullSizeProviderFor(bytes),
          PixelPayload() => throw StateError('not exercised here'),
        },
        ensurePayload:
            (
              item, {
              required int distance,
              required VoidCallback? notifyLoaded,
              bool onSerialLane = false,
            }) async {},
        // Identity orientation: without it _upgradeFullRes marks a failure
        // before the decoder call (same reason as TC-1221).
        exifOrientationFor: (id) => 1,
        dngDecoder: () => (path) async {
          final id = path.split('/').last.split('.').first;
          calls[id] = (calls[id] ?? 0) + 1;
          final rgba = Uint8List(2 * 2 * 4);
          for (var i = 3; i < rgba.length; i += 4) {
            rgba[i] = 0xFF;
          }
          return DecodedRgba(rgba: rgba, width: 2, height: 2);
        },
        // Zero: the debounced sweep (_decodeWindow -> _dispatchBandItems,
        // tier_two_scheduler.dart:685) is the path under test.
        navigationDebounce: Duration.zero,
      );
      addTearDown(scheduler.cancelDebounce);
      addTearDown(registry.clear);

      final items = photoItems(6, idPrefix: 'a', dir: '/tmp');
      for (final item in items) {
        // a3 keeps a TEMPORARY PixelPayload, so its full-res entry costs an
        // FFI decode (TC-1221's mechanism).
        payloads[item.id] = item.id == 'a3'
            ? PixelPayload(rgba: Uint8List(2 * 2 * 4), width: 2, height: 2)
            : freshEncodedPayload();
      }

      scheduler.schedule(items, 2, () {});
      await until(() => registry.isReady('a3'),
          reason: "a3's catch-up upgrade lands");
      expect(calls['a3'], 1, reason: 'vacuity: one FFI decode bought it');

      addTearDown(_display(registry.providerFor('a3')!));
      _lruEvictAll();

      // Same position: no band entrant, so only the debounced sweep runs.
      scheduler.schedule(items, 2, () {});
      // Real time, plain test(): in the pre-fix tree the second decode is
      // issued within a few event-loop turns; 200 ms is two orders of
      // magnitude of margin.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(calls['a3'], 1,
          reason: 'THE DEFECT: a displayed, LRU-evicted item must not be '
              'decoded again into a duplicate texture');
      expect(registry.isReady('a3'), isTrue);
    },
  );
}
