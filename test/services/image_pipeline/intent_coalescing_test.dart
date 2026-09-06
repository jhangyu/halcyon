// Phase 6 — intent coalescing at the scheduler entrance
// (async-pipeline-refactor-plan.md §3 Phase 6).
//
//   TC-992  nine synchronous selections produce ONE pass, for the ninth
//   TC-993  a superseded selection buys no lane work at all
//   TC-994  `await preloadImages(...)` still resumes with the pass issued
//           (the Phase 3 entrance contract survives the microtask)
//   TC-995  the navigation and viewport halves coalesce into one pass
//   TC-996  reset() drops a queued intent: no pass runs for the old folder
//   TC-997  the lane's top-priority entry after a nine-event burst is the
//           ninth selection itself
//
// Red-proof: docs/logs/2026-09-06/phase6-redproof.txt.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/lane_priority.dart';

import '../../support/preload_fixtures.dart';

void _microtaskFrame(void Function() callback) => callback();

ImagePreloadController _cheapController() => ImagePreloadController(
  scheduleFrameCallback: _microtaskFrame,
  imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
      NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
  dngDecoder: (path) async => fail('cheap rung must not RAW-decode'),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(clearImageCacheSetUp);

  test(
    'TC-992: nine synchronous selections produce exactly ONE scheduling pass, '
    'and it is the NINTH selection that is scheduled',
    () async {
      final controller = _cheapController();
      addTearDown(controller.dispose);
      controller.updateTargetSize(800, 600);

      // Spaced 10 apart: no selection's window overlaps another's, so "whose
      // window was issued" is answerable from the retention set alone.
      final items = paddedItems(120);
      final selections = [for (var k = 0; k < 9; k++) items[k * 10]];

      // NINE CALLS, ONE TURN OF THE EVENT LOOP. Deliberately not awaited:
      // this is the arrow-key burst the phase exists for.
      for (final item in selections) {
        unawaited(
          controller.preloadImages(
            items: items,
            selectedItemId: item.id,
            notifyLoaded: () {},
          ),
        );
      }
      expect(
        controller.debugSchedulingPassCount,
        0,
        reason: 'nothing may run synchronously inside the burst',
      );
      expect(controller.debugHasPendingIntent, isTrue);

      // Let the microtask queue drain.
      await Future<void>.delayed(Duration.zero);

      expect(
        controller.debugSchedulingPassCount,
        1,
        reason:
            'nine superseding events are ONE intent; nine passes is the '
            'defect this phase removes',
      );
      final ninth = selections.last.id;
      expect(
        controller.debugRetentionIds,
        contains(ninth),
        reason: 'the pass must be the LAST selection, not the first',
      );
      // The eight superseded selections are each 10+ apart, i.e. far outside
      // the -3..+5 window of the ninth.
      for (final superseded in selections.take(8)) {
        expect(
          controller.debugRetentionIds,
          isNot(contains(superseded.id)),
          reason:
              '${superseded.id} belonged to a superseded intent and must not '
              'be retained by the coalesced pass',
        );
      }
    },
  );

  test(
    'TC-993: a superseded selection buys NO lane work (the expensive rung)',
    () async {
      // Every item is expensive, so every issued slot lands on the lane and
      // "was this window issued at all" is readable off the lane itself.
      final controller = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        decodeLaneWidth: 1,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        // Never completes: the lane's single slot stays occupied for the whole
        // test, so nothing drains and every enqueued entry stays observable.
        dngDecoder: (path) => Completer<DecodedRgba>().future,
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(800, 600);

      final items = paddedItems(120, extension: 'dng');
      final first = items[0];
      final ninth = items[80];

      unawaited(
        controller.preloadImages(
          items: items,
          selectedItemId: first.id,
          notifyLoaded: () {},
        ),
      );
      unawaited(
        controller.preloadImages(
          items: items,
          selectedItemId: ninth.id,
          notifyLoaded: () {},
        ),
      );

      await until(
        () => controller.debugLanePendingPriorityFor(items[81].id) != null,
        reason: 'the ninth selection\'s window to reach the lane',
      );

      expect(
        controller.debugSchedulingPassCount,
        1,
        reason: 'anti-hollow: exactly one pass really ran',
      );
      // items[81] is +1 from the surviving selection: P2 band, rank 1.
      expect(
        controller.debugLanePendingPriorityFor(items[81].id),
        navigationPriorityFor(1),
        reason: 'the surviving window is ranked by the CURRENT selection',
      );
      // The superseded selection's own neighbours never reach the lane.
      //
      // HONEST LABEL (red-proof M9, phase6-redproof.txt): this half is
      // CO-GUARDED. It stays green even with coalescing removed, because
      // Phase 3's `_previewGeneration` check inside `_issueWindowItem` already
      // rejects a superseded slot after its probe returns. It is kept as a
      // regression net for that guard, NOT as evidence for this phase — the
      // assertions that discriminate coalescing are the pass count above and
      // TC-992's retention set. What Phase 6 actually saves here is the work
      // BEFORE that guard (a full retention/eviction/tier-2 window recompute
      // per event, plus one probe chain per slot per superseded window), and
      // the probe count has no test seam, so it is not claimed as an assertion.
      for (final index in <int>[1, 2, 3]) {
        expect(
          controller.debugLanePendingPriorityFor(items[index].id),
          isNull,
          reason:
              'items[$index] belonged to the superseded window and must not '
              'hold a lane slot',
        );
      }
    },
  );

  test(
    'TC-997: the lane\'s TOP-PRIORITY entry after a nine-event burst is the '
    'NINTH selection itself',
    () async {
      // The plan's acceptance names this property literally, so it is asserted
      // literally rather than through a neighbour's rank (TC-993's proxy).
      //
      // The lane's single slot is OCCUPIED FIRST by a decode that never
      // completes, so the burst's own distance-0 task cannot start and is
      // therefore observable as a PENDING entry. Without this the winner runs
      // immediately and `debugLanePendingPriorityFor` reports null for it --
      // the assertion would be reading the wrong side of the lane.
      final controller = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        decodeLaneWidth: 1,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        dngDecoder: (path) => Completer<DecodedRgba>().future,
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(800, 600);

      final items = paddedItems(120, extension: 'dng');

      // Occupy the slot with an unrelated far selection and WAIT for it to be
      // running -- the precondition the assertion below depends on.
      await controller.preloadImages(
        items: items,
        selectedItemId: items[110].id,
        notifyLoaded: () {},
      );
      await until(
        () => controller.debugDecodeLaneRunningCount == 1,
        reason: 'the blocking decode to occupy the lane',
      );

      final selections = [for (var k = 0; k < 9; k++) items[k * 5]];
      for (final item in selections) {
        unawaited(
          controller.preloadImages(
            items: items,
            selectedItemId: item.id,
            notifyLoaded: () {},
          ),
        );
      }
      final ninth = selections.last.id;
      await until(
        () => controller.debugLanePendingPriorityFor(ninth) != null,
        reason: 'the ninth selection to reach the lane',
      );

      expect(
        controller.debugSchedulingPassCount,
        2,
        reason:
            'one pass for the blocking selection, one for the whole burst '
            '(anti-hollow: the burst really was coalesced)',
      );
      // HONEST LABEL (red-proof M9b + its diagnostic, phase6-redproof.txt):
      // the two rank assertions below are CO-GUARDED, exactly like TC-993's
      // second half. With coalescing removed they stay green, because the
      // superseded passes' slots are rejected after their probes by
      // `_previewGeneration` and the surviving pass re-ranks the same key at
      // 0 either way. They are asserted because the plan's acceptance names
      // this property literally, and they are a real regression net for the
      // BAND (a P2/P3 rank here would be a genuine defect) -- but the
      // assertion that discriminates THIS phase is the pass count above.
      //
      // The useful corollary, stated rather than left implicit: coalescing
      // leaves the lane's resulting state IDENTICAL. That is the evidence
      // that this phase removes wasted work without reordering anything.
      expect(
        controller.debugLanePendingPriorityFor(ninth),
        navigationPriorityFor(0),
        reason:
            'the NINTH selection holds the lane\'s best rank -- P1, the '
            'selected-slot band',
      );
      // Nothing else in the lane outranks it, and the eight superseded
      // selections hold no entry of their own.
      for (final superseded in selections.take(8)) {
        final priority = controller.debugLanePendingPriorityFor(superseded.id);
        expect(
          priority == null || priority > navigationPriorityFor(0),
          isTrue,
          reason:
              '${superseded.id} was superseded: it may appear only as a '
              'NEIGHBOUR of the ninth (a worse rank), never at rank 0',
        );
      }
    },
  );

  test(
    'TC-994: `await preloadImages(...)` still resumes with the pass ISSUED',
    () async {
      final controller = _cheapController();
      addTearDown(controller.dispose);
      controller.updateTargetSize(800, 600);

      final items = paddedItems(40);
      await controller.preloadImages(
        items: items,
        selectedItemId: items[20].id,
        notifyLoaded: () {},
      );

      // The Phase 3 contract: the entrance returns once work has been issued,
      // never once it has landed. The pass microtask is queued before this
      // continuation, so awaiting callers see no behaviour change at all.
      expect(controller.debugSchedulingPassCount, 1);
      expect(controller.debugRetentionIds, contains(items[20].id));
      expect(controller.debugHasPendingIntent, isFalse);
    },
  );

  test('TC-995: the navigation and viewport halves share one pass', () async {
    final controller = _cheapController();
    addTearDown(controller.dispose);
    controller.updateTargetSize(800, 600);

    final items = paddedItems(60);
    unawaited(
      controller.preloadImages(
        items: items,
        selectedItemId: items[30].id,
        notifyLoaded: () {},
      ),
    );
    unawaited(controller.preloadThumbnails(items: items, startIdx: 0, endIdx: 4));

    await Future<void>.delayed(Duration.zero);

    expect(
      controller.debugSchedulingPassCount,
      1,
      reason: 'one frame reporting both a selection and a range = one pass',
    );
    expect(controller.debugRetentionIds, contains(items[30].id));
    // The sidebar half is behind its own untouched 100ms debounce, so the
    // observable here is that the pass DELIVERED the range, not that tiles
    // exist yet.
    await until(
      () => controller.debugRetentionIds.contains(items[0].id),
      reason: 'the sidebar sweep to widen the retention union',
    );
  });

  test(
    'TC-998: a nine-event synchronous burst probes each window slot of the '
    'surviving pass exactly once (parking-lot item 3, '
    'phase5-6-baton-for-next-worker.md §6) -- a probe-count seam for the '
    'saving TC-992..997 cannot assert because it sits above the lane layer',
    () async {
      final controller = _cheapController();
      addTearDown(controller.dispose);
      controller.updateTargetSize(800, 600);

      // Spaced 10 apart, same shape as TC-992: no selection's window overlaps
      // another's.
      final items = paddedItems(120);
      final selections = [for (var k = 0; k < 9; k++) items[k * 10]];

      for (final item in selections) {
        unawaited(
          controller.preloadImages(
            items: items,
            selectedItemId: item.id,
            notifyLoaded: () {},
          ),
        );
      }
      await Future<void>.delayed(Duration.zero);

      expect(
        controller.debugSchedulingPassCount,
        1,
        reason: 'precondition: the burst coalesced into one pass',
      );
      // THE BOUND: with a fresh controller (nothing cached, no sidebar
      // activity), every content probe launched belongs to the ONE surviving
      // pass's window, and that pass probes each of its window slots exactly
      // once. If any of the eight superseded events had launched its own
      // probe chain (the defect this phase removes), this count would exceed
      // the surviving window's size -- eight superseded passes at up to 9
      // slots each is the magnitude of what coalescing is saving.
      expect(
        controller.debugProbeInvocationCount,
        controller.debugRetentionIds.length,
        reason:
            'probe count must equal exactly one pass worth of window slots; '
            'a probe launched for a superseded event would inflate this past '
            'the surviving retention set',
      );
    },
  );

  test('TC-996: reset() drops a queued intent', () async {
    final controller = _cheapController();
    addTearDown(controller.dispose);
    controller.updateTargetSize(800, 600);

    final items = paddedItems(40);
    unawaited(
      controller.preloadImages(
        items: items,
        selectedItemId: items[10].id,
        notifyLoaded: () {},
      ),
    );
    // The folder switch happens before the queued pass runs -- the exact
    // window Phase 6 introduces.
    controller.reset();

    await Future<void>.delayed(Duration.zero);

    expect(
      controller.debugSchedulingPassCount,
      0,
      reason: 'a pass for the folder we just left must not run',
    );
    expect(controller.debugRetentionIds, isEmpty);
    expect(controller.payloadFor(items[10].id), isNull);
  });
}
