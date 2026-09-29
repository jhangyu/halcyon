// l1l2 eviction-timing campaign (docs/logs/2026-09-30/l1l2-eviction-timing-spec.md).
//   TC-1401  AC2/R3: a jump >= 2 evicts the PAINTED selected entry without
//            destroying the image the widget still holds.
//   TC-1403  AC4/R2: an R1 evict batch requests a frame; that frame releases it.
//   TC-1404  AC4/R2: a settle-sweep evict batch requests a frame too.
//   TC-1405..TC-1407  R7: pipeline listeners dispose the clone they are handed.
//
// L1 is observed through `hasScheduledFrame` and `ui.Image.debugDisposed`, never
// through `imageCache.currentSizeBytes`: the SDK subtracts the evicted entry's
// bytes synchronously inside `evict()`, so that number cannot tell whether the
// deferred handle dispose ever ran (lead ruling OQ-2, 2026-09-30).
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/decode_lane.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_registry.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_scheduler.dart';

import '../../support/preload_fixtures.dart';

/// A scheduler + registry with NO payloads: every band entrant is skipped
/// (`currentPayloadFor` answers null and the immediate path never loads), so
/// the only registry entries are the ones a test publishes by hand. That makes
/// every eviction a test observes attributable to exactly one site.
class _Rig {
  _Rig({Duration debounce = const Duration(seconds: 10)}) {
    registry = TierTwoRegistry(currentPayloadFor: (_) => null);
    scheduler = TierTwoScheduler(
      registry: registry,
      lane: DecodeLane(width: 1),
      currentPayloadFor: (_) => null,
      fullSizeProviderFor: (_) =>
          throw StateError('no payloads in this rig: entrants are skipped'),
      ensurePayload:
          (item, {required distance, required notifyLoaded, onSerialLane = false}) async {},
      dngDecoder: () => null,
      exifOrientationFor: (_) => null,
      navigationDebounce: debounce,
    );
  }

  late final TierTwoRegistry registry;
  late final TierTwoScheduler scheduler;

  void dispose() {
    scheduler.cancelDebounce();
    registry.clear();
  }
}

void main() {
  setUp(clearImageCacheSetUp);

  testWidgets(
      'TC-1401 (AC2) a jump >= 2 evicts the painted selected entry without '
      'destroying the image the widget still holds', (tester) async {
    final rig = _Rig();
    final items = photoItems(12, idPrefix: 'a', dir: '/tmp');
    final image = (await tester.runAsync(tinyImage))!;

    rig.scheduler.schedule(items, 2, () {}); // band a1..a3, a2 selected
    rig.registry.publishFullRes('a2', freshEncodedPayload(), image, () {});
    final provider = rig.registry.providerFor('a2')!;
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Image(image: provider),
    ));
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull,
        reason: 'vacuity: a2 is actually painted');

    rig.scheduler.schedule(items, 8, () {}); // jump of 6: a2 leaves the band
    expect(rig.registry.keyIds, isNot(contains('a2')),
        reason: 'R1: the painted id was evicted at the band-leave instant');
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(image.debugDisposed, isFalse,
        reason: 'R3: the live reference survives eviction while painted');
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);

    // Positive control: once the last listener detaches, the image IS
    // released -- so the isFalse above observed the right handle.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(image.debugDisposed, isTrue);
    rig.dispose();
  });

  testWidgets(
      'TC-1403 (AC4) an R1 evict batch requests a frame, and that frame '
      'releases the evicted image', (tester) async {
    final rig = _Rig();
    final items = photoItems(12, idPrefix: 'a', dir: '/tmp');
    final image = (await tester.runAsync(tinyImage))!;

    rig.scheduler.schedule(items, 2, () {}); // band a1..a3
    rig.registry.publishFullRes('a2', freshEncodedPayload(), image, () {});
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse,
        reason: 'vacuity: no frame is pending before the evict');

    rig.scheduler.schedule(items, 8, () {}); // a1..a3 all leave (R1 site)
    expect(rig.registry.keyIds, isEmpty);
    expect(tester.binding.hasScheduledFrame, isTrue,
        reason: 'L1: the evict batch asked for the frame the deferred '
            'dispose needs');
    expect(image.debugDisposed, isFalse,
        reason: 'the SDK defers the handle dispose to the end of a frame');

    await tester.pump();
    expect(image.debugDisposed, isTrue,
        reason: 'one frame later the evicted image is released');
    rig.dispose();
  });

  testWidgets(
      'TC-1404 (AC4) a settle-sweep evict batch requests a frame too',
      (tester) async {
    // Zero debounce, and the sweep is ARMED inside runAsync so its Timer is a
    // real one: a fake-async pump would fire the timer AND run a frame in the
    // same call, hiding whether the sweep itself asked for that frame.
    final rig = _Rig(debounce: Duration.zero);
    final items = photoItems(12, idPrefix: 'a', dir: '/tmp');
    final image = (await tester.runAsync(tinyImage))!;

    rig.scheduler.schedule(items, 2, () {}); // band a1..a3
    await tester.pump(); // fires this pass's (fake) zero debounce: nothing stale
    // a9 is registered by hand and was NEVER in the band, so it is not an R1
    // leaver: only the settle sweep can evict it.
    rig.registry.publishFullRes('a9', freshEncodedPayload(), image, () {});
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse,
        reason: 'vacuity: no frame is pending before the sweep');

    await tester.runAsync(() async {
      rig.scheduler.schedule(items, 2, () {}); // same position: no leavers
      expect(rig.registry.keyIds, contains('a9'),
          reason: 'R1 did not touch a9 -- the sweep has not run yet');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    expect(rig.registry.keyIds, isNot(contains('a9')),
        reason: 'the settle sweep evicted the out-of-band entry');
    expect(tester.binding.hasScheduledFrame, isTrue,
        reason: 'L1: the sweep batch asked for a frame');
    expect(image.debugDisposed, isFalse);

    await tester.pump();
    expect(image.debugDisposed, isTrue);
    rig.dispose();
  });
}
