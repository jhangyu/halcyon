import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_state.dart';

import '../../support/preload_fixtures.dart';

/// Race B (P1, `docs/logs/2026-09-06/p3-plan-P1.md` Task 2): the sidebar's
/// wanted set is rewritten ONLY inside its 100ms debounce timer
/// (`sidebar_thumbnail_controller.dart:448-483`). A row built during that
/// window calls `stateFor(id)` and materialises a notifier for an id that is
/// in neither `_navRetentionIds` nor `_wantedIds`. Any navigation-side
/// `_republishEvictionPriority` (`image_preload_controller.dart:554-560`,
/// reached from the navigation pass at :1085) runs `_sweepPayloadStates`,
/// which disposes exactly that notifier -- silently, with no tombstone, so
/// every later `_markStage`/`_markThumbnailReady` for the id early-returns and
/// the row never paints.
///
/// The ordering is forced by CONSTRUCTION, not by sleeping: the entrance
/// coalesces intents onto a microtask that is queued BEFORE the awaiting
/// caller's continuation (`image_preload_controller.dart:898-901`), so
/// `await preloadThumbnails(...)` resumes with the sidebar's 100ms timer armed
/// and not yet fired, and `await preloadImages(...)` resumes with the
/// navigation pass -- and therefore the sweep -- already run.
///
/// Plain `test()` with real timing: FakeAsync plus a real engine future hangs
/// forever (G-020/G-021).
/// Same shape as `async_baseline_pins_test.dart:22`: the publication pacer's
/// frame hook, run inline so a test never waits on a real engine frame.
void _microtaskFrame(void Function() callback) => callback();

void main() {
  test(
    'TC-1012: a notifier materialised inside the 100ms sidebar debounce window '
    'survives a concurrent navigation sweep',
    () async {
      final controller = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
        dngDecoder: (path) async => fail('cheap rung must not RAW-decode'),
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(800, 600);

      final items = paddedItems(60, extension: 'jpg');
      final farId = items[40].id;

      // The sidebar scrolled to rows 40..44. `_wantedIds` is NOT updated yet:
      // the rewrite happens only inside the 100ms debounce timer, which has
      // been armed by this call but has not fired.
      await controller.preloadThumbnails(items: items, startIdx: 40, endIdx: 44);
      expect(
        controller.debugRetentionIds.contains(farId),
        isFalse,
        reason:
            'precondition: we are inside the debounce window, so the row is '
            'not in the retention union yet -- if this fails the test is no '
            'longer exercising the window',
      );

      // A row builds and asks for its state: this materialises the notifier.
      final state = controller.stateFor(farId) as PayloadStateNotifier;

      // A navigation pass fires mid-window and republishes eviction priority,
      // which sweeps notifiers outside the retention union.
      await controller.preloadImages(
        items: items,
        selectedItemId: items[0].id,
        notifyLoaded: () {},
      );
      expect(
        controller.debugRetentionIds.contains(items[0].id),
        isTrue,
        reason:
            'precondition: the navigation pass must actually have run before '
            'the assertion below, otherwise no sweep happened and a green '
            'result would prove nothing',
      );
      expect(
        controller.debugRetentionIds.contains(farId),
        isFalse,
        reason:
            'precondition: the debounce timer still has not fired, so the far '
            'row is outside the union the sweep keeps',
      );

      // Read the notifier OBJECT captured before the sweep. A re-read through
      // `stateFor(farId)` would silently create a FRESH notifier and be a
      // false green (same shape as the rejected `removeListener` guard,
      // handover §9).
      expect(
        state.isDisposed,
        isFalse,
        reason:
            'the freshly requested row lost its notifier to a navigation-side '
            'sweep: no tombstone, so every later _markStage for this id early-'
            'returns and the tile never paints',
      );
    },
  );

  test(
    'TC-1013: the disposal grace expires -- the next sweep collects the '
    'deferred notifier',
    () async {
      // The grace is a DELAY, not a leak. Driving it through the injected
      // clock instead of sleeping keeps this deterministic and keeps FakeAsync
      // (which would hang on a real engine future, G-020/G-021) out.
      var now = DateTime(2026, 9, 6, 12);
      ImagePreloadController.payloadStateClock = () => now;
      addTearDown(
        () => ImagePreloadController.payloadStateClock = DateTime.now,
      );

      final controller = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
        dngDecoder: (path) async => fail('cheap rung must not RAW-decode'),
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(800, 600);

      final items = paddedItems(60, extension: 'jpg');
      final farId = items[40].id;
      await controller.preloadThumbnails(items: items, startIdx: 40, endIdx: 44);
      final state = controller.stateFor(farId) as PayloadStateNotifier;

      await controller.preloadImages(
        items: items,
        selectedItemId: items[0].id,
        notifyLoaded: () {},
      );
      expect(state.isDisposed, isFalse, reason: 'deferred by the grace period');
      expect(controller.debugPayloadStateDeferredCount, greaterThan(0));

      // Past the grace, with the row still outside the retention union.
      now = now.add(kPayloadStateDisposalGrace * 2);
      await controller.preloadImages(
        items: items,
        selectedItemId: items[1].id,
        notifyLoaded: () {},
      );
      expect(
        controller.debugRetentionIds.contains(farId),
        isFalse,
        reason:
            'precondition: the row must still be outside the union, otherwise '
            'the sweep has no grounds to collect it and a red result would be '
            'about retention, not about the grace',
      );

      expect(
        state.isDisposed,
        isTrue,
        reason:
            'the grace is a delay, not a leak: once it expires the ordinary '
            'retention sweep must collect the notifier',
      );
    },
  );
}
