// Merged (round 4 M2 consolidation) from:
//   publication_pacer_test.dart
//   idle_publish_scheduler_test.dart
//   intent_coalescing_test.dart
//   image_preload_pacer_test.dart
// Each source file's tests are wrapped in a group() named after its basename
// to keep setUp/tearDown scoping and test names intact. Top-level helper name
// collisions across files were resolved with a private `_<shortname>` suffix
// (Rule 2); no test behavior was changed.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/idle_publish_scheduler.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/lane_priority.dart';
import 'package:halcyon_flutter/services/image_pipeline/publication_pacer.dart';

import '../../support/preload_fixtures.dart';

// ---------------------------------------------------------------------------
// Helpers from publication_pacer_test.dart
// ---------------------------------------------------------------------------

/// A fake frame clock: `arm` records the drain callback, `frame()` runs it.
class FakeFramesPublicationPacer {
  final List<VoidCallback> _armed = [];
  void arm(VoidCallback callback) => _armed.add(callback);
  int get armedCount => _armed.length;
  void frame() {
    final due = List<VoidCallback>.of(_armed);
    _armed.clear();
    for (final callback in due) {
      callback();
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers from idle_publish_scheduler_test.dart
// ---------------------------------------------------------------------------

/// Refuses every task below `Priority.animation`, exactly as
/// `defaultSchedulingStrategy` does while an animation is running.
bool _idleRefusingStrategy({
  required int priority,
  required SchedulerBinding scheduler,
}) => priority >= Priority.animation.value;

/// Pumps the event loop (which is what services a `Priority.idle` task) and
/// real zero-duration timers. NOT a wall-clock wait.
Future<void> pumpEventLoop([int rounds = 8]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Longer than any test here lives, so the safeguard cannot be the runner.
const Duration kNeverFires = Duration(hours: 1);

// ---------------------------------------------------------------------------
// Helpers from intent_coalescing_test.dart
// ---------------------------------------------------------------------------

void _microtaskFrame(void Function() callback) => callback();

ImagePreloadController _cheapController() => ImagePreloadController(
  scheduleFrameCallback: _microtaskFrame,
  imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
      NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
  dngDecoder: (path) async => fail('cheap rung must not RAW-decode'),
);

// ---------------------------------------------------------------------------
// Helpers from image_preload_pacer_test.dart
// ---------------------------------------------------------------------------

/// Collects the pacer's armed drains and runs them only when the test says so.
class FakeFramesImagePreloadPacer {
  final List<void Function()> _armed = [];

  void arm(void Function() callback) => _armed.add(callback);

  int get armedCount => _armed.length;

  void frame() {
    final due = List<void Function()>.of(_armed);
    _armed.clear();
    for (final callback in due) {
      callback();
    }
  }
}

/// 26 CHEAP items: the loader answers with real PNG-ish bytes, so no decode
/// lane, no encode stage and no RAW path is involved -- this file is only
/// about WHEN a tier-1 key is registered.
List<PhotoItem> manyCheapItems() => [
  for (var c = 0; c < 26; c++)
    PhotoItem(
      id: String.fromCharCode(0x61 + c),
      files: [File('/tmp/${String.fromCharCode(0x61 + c)}.jpg')],
    ),
];

ImagePreloadController buildController({FrameHook? scheduleFrameCallback}) {
  return ImagePreloadController(
    imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
        // A FRESH bytes object per call, so payload identity is meaningful.
        NativeImageBytes(Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10])),
    scheduleFrameCallback: scheduleFrameCallback,
  );
}

Future<void> pumpMicrotasks([int rounds = 24]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('publication_pacer_test.dart', () {
    // TC-835
    test('at most one publication per frame', () {
      final frames = FakeFramesPublicationPacer();
      final published = <String>[];
      final pacer =
          PublicationPacer(scheduleFrameCallback: frames.arm, perFrame: 1);
      for (final id in ['a', 'b', 'c']) {
        pacer.submit(
        byteCost: 0,
          id: id,
          rank: 1,
          exempt: false,
          stillValid: () => true,
          publish: () => published.add(id),
        );
      }
      frames.frame();
      expect(published.length, 1);
      frames.frame();
      expect(published.length, 2);
      frames.frame();
      expect(published.length, 3);
    });

    // TC-836
    test('an exempt entry publishes inside submit', () {
      final frames = FakeFramesPublicationPacer();
      final published = <String>[];
      final pacer = PublicationPacer(scheduleFrameCallback: frames.arm);
      pacer.submit(
        byteCost: 0,
        id: 'sel',
        rank: 0,
        exempt: true,
        stillValid: () => true,
        publish: () => published.add('sel'),
      );
      expect(published, ['sel']);
      expect(frames.armedCount, 0);
      expect(pacer.queuedCount, 0);
    });

    // TC-837
    test('an entry invalidated between submit and drain is discarded', () {
      final frames = FakeFramesPublicationPacer();
      var valid = true;
      var published = 0;
      var discarded = 0;
      final pacer = PublicationPacer(scheduleFrameCallback: frames.arm);
      pacer.submit(
        byteCost: 0,
        id: 'a',
        rank: 1,
        exempt: false,
        stillValid: () => valid,
        publish: () => published++,
        discard: () => discarded++,
      );
      valid = false;
      frames.frame();
      expect(published, 0);
      expect(discarded, 1);
      expect(pacer.queuedCount, 0);
    });

    // TC-838
    test('overflow drops the farthest-ranked entry', () {
      final frames = FakeFramesPublicationPacer();
      final dropped = <String>[];
      final pacer = PublicationPacer(
        scheduleFrameCallback: frames.arm,
        maxQueued: 2,
      );
      for (final entry in [('near', 1), ('far', 5), ('mid', 3)]) {
        pacer.submit(
        byteCost: 0,
          id: entry.$1,
          rank: entry.$2,
          exempt: false,
          stillValid: () => true,
          publish: () {},
          discard: () => dropped.add(entry.$1),
        );
      }
      expect(dropped, ['far']);
      expect(pacer.queuedCount, 2);
    });

    test('drain order is ascending rank, not submit order', () {
      final frames = FakeFramesPublicationPacer();
      final published = <String>[];
      final pacer = PublicationPacer(scheduleFrameCallback: frames.arm);
      for (final entry in [('far', 9), ('near', 1), ('mid', 4)]) {
        pacer.submit(
        byteCost: 0,
          id: entry.$1,
          rank: entry.$2,
          exempt: false,
          stillValid: () => true,
          publish: () => published.add(entry.$1),
        );
      }
      frames.frame();
      frames.frame();
      frames.frame();
      expect(published, ['near', 'mid', 'far']);
    });

    test('re-submitting a queued id replaces it and discards the old entry', () {
      final frames = FakeFramesPublicationPacer();
      final dropped = <String>[];
      final published = <int>[];
      final pacer = PublicationPacer(scheduleFrameCallback: frames.arm);
      pacer.submit(
        byteCost: 0,
        id: 'a',
        rank: 5,
        exempt: false,
        stillValid: () => true,
        publish: () => published.add(1),
        discard: () => dropped.add('first'),
      );
      pacer.submit(
        byteCost: 0,
        id: 'a',
        rank: 1,
        exempt: false,
        stillValid: () => true,
        publish: () => published.add(2),
        discard: () => dropped.add('second'),
      );
      expect(dropped, ['first']);
      expect(pacer.queuedCount, 1);
      frames.frame();
      expect(published, [2]);
    });

    // Regression: on an idle app, nothing else is pumping the scheduler, so
    // the default frame hook (bare addPostFrameCallback) must itself request
    // a frame -- otherwise a submitted, non-exempt entry queues forever and
    // never drains. `hasScheduledFrame` only reflects reality once frames are
    // enabled, which requires a real widget tree (pumpWidget), not a bare
    // `test()` -- AutomatedTestWidgetsFlutterBinding starts with frames
    // disabled until something attaches a root widget.
    testWidgets(
      'the default (no injected hook) frame path requests a frame so an idle '
      'app does not stall a queued publication',
      (tester) async {
        await tester.pumpWidget(const SizedBox());
        expect(
          SchedulerBinding.instance.hasScheduledFrame,
          isFalse,
          reason: 'test setup: no frame should be pending before submit',
        );
        final pacer = PublicationPacer();
        var published = false;
        pacer.submit(
        byteCost: 0,
          id: 'idle',
          rank: 1,
          exempt: false,
          stillValid: () => true,
          publish: () => published = true,
        );
        expect(
          SchedulerBinding.instance.hasScheduledFrame,
          isTrue,
          reason:
              'submitting a non-exempt entry must itself request a frame; '
              'relying solely on addPostFrameCallback leaves an idle app '
              'stalled forever',
        );
        expect(published, isFalse, reason: 'nothing has drained it yet');
        // Let the pending frame actually run so the test does not leave a
        // dangling scheduled frame / pending callback behind.
        await tester.pump();
        expect(published, isTrue);
      },
    );

    test('clear discards every queued entry', () {
      final frames = FakeFramesPublicationPacer();
      var discarded = 0;
      final pacer = PublicationPacer(scheduleFrameCallback: frames.arm);
      for (final id in ['a', 'b']) {
        pacer.submit(
        byteCost: 0,
          id: id,
          rank: 1,
          exempt: false,
          stillValid: () => true,
          publish: () {},
          discard: () => discarded++,
        );
      }
      pacer.clear();
      expect(discarded, 2);
      expect(pacer.queuedCount, 0);
    });

    // TC-894 -- deliverable 3: the exempt claim is enforced, not trusted.
    test('an exempt submission for a non-selected id is downgraded to the queue',
        () {
      final frames = FakeFramesPublicationPacer();
      final published = <String>[];
      final pacer = PublicationPacer(
        scheduleFrameCallback: frames.arm,
        isSelected: (id) => id == 'sel',
      );

      pacer.submit(
        byteCost: 0,
        id: 'other',
        rank: 3,
        exempt: true,
        stillValid: () => true,
        publish: () => published.add('other'),
      );

      expect(published, isEmpty, reason: 'only the selected item may go inline');
      expect(pacer.queuedCount, 1, reason: 'downgraded, never dropped');
      expect(pacer.debugDowngradedExemptCount, 1);

      frames.frame();
      expect(published, ['other'], reason: 'pacing decides WHEN, not WHETHER');
    });

    // TC-895 -- the selected item still never waits a frame for its own pixels.
    test('an exempt submission for the selected id still publishes synchronously',
        () {
      final frames = FakeFramesPublicationPacer();
      final published = <String>[];
      final pacer = PublicationPacer(
        scheduleFrameCallback: frames.arm,
        isSelected: (id) => id == 'sel',
      );

      pacer.submit(
        byteCost: 0,
        id: 'sel',
        rank: 0,
        exempt: true,
        stillValid: () => true,
        publish: () => published.add('sel'),
      );

      expect(published, ['sel']);
      expect(pacer.queuedCount, 0);
      expect(frames.armedCount, 0);
      expect(pacer.debugDowngradedExemptCount, 0);
    });

    // TC-896 -- no predicate injected == today's behaviour, byte for byte.
    test('with no isSelected predicate the exempt path is unchanged', () {
      final frames = FakeFramesPublicationPacer();
      final published = <String>[];
      final pacer = PublicationPacer(scheduleFrameCallback: frames.arm);

      pacer.submit(
        byteCost: 0,
        id: 'anything',
        rank: 9,
        exempt: true,
        stillValid: () => true,
        publish: () => published.add('anything'),
      );

      expect(published, ['anything']);
      expect(pacer.debugDowngradedExemptCount, 0);
      expect(pacer.debugHasFrameHook, isTrue);
    });
  });

  group('idle_publish_scheduler_test.dart', () {
    // Deliverable 1 (docs/logs/2026-09-03/decode-jank-remediation-contract.md):
    // idle-priority scheduling for pacer publishes, with a safeguard so publishes
    // cannot stall indefinitely on an app that is animating.
    //
    // TC-888 .. TC-893.
    //
    // No assertion here depends on wall-clock timing. Which of the two paths runs
    // a slot is forced deterministically: either `schedulingStrategy` refuses idle
    // tasks (only the safeguard can fire) or the safeguard is set beyond the
    // test's lifetime (only the idle path can fire).

    setUp(() {
      SchedulerBinding.instance.schedulingStrategy = defaultSchedulingStrategy;
    });
    tearDown(() {
      SchedulerBinding.instance.schedulingStrategy = defaultSchedulingStrategy;
    });

    // TC-888
    test('the callback runs exactly once and never synchronously', () async {
      final scheduler = IdlePublishScheduler();
      addTearDown(scheduler.dispose);
      var runs = 0;

      scheduler.schedule(() => runs++);
      expect(runs, 0, reason: 'a slot must never be granted synchronously');
      expect(scheduler.debugPendingCount, 1);

      await pumpEventLoop();
      expect(runs, 1);
      expect(scheduler.debugPendingCount, 0);

      await pumpEventLoop();
      expect(runs, 1, reason: 'exactly once per schedule call');
    });

    // TC-889 -- the safeguard is the whole reason this class is not a one-liner.
    test('an idle-refusing strategy still runs the callback, via the safeguard',
        () async {
      SchedulerBinding.instance.schedulingStrategy = _idleRefusingStrategy;
      final scheduler = IdlePublishScheduler(safeguard: Duration.zero);
      addTearDown(scheduler.dispose);
      var runs = 0;

      scheduler.schedule(() => runs++);
      await pumpEventLoop();

      expect(runs, 1, reason: 'an animating app must not stall a publish');
      expect(scheduler.debugSafeguardRuns, 1);
      expect(scheduler.debugIdleRuns, 0);
    });

    // TC-890 -- the positive control for TC-889: with nothing animating, the
    // idle path is the one that runs, so idle priority is really in effect.
    test('with the default strategy the idle path runs it and the safeguard does not',
        () async {
      final scheduler = IdlePublishScheduler(safeguard: kNeverFires);
      addTearDown(scheduler.dispose);
      var runs = 0;

      scheduler.schedule(() => runs++);
      await pumpEventLoop();

      expect(runs, 1);
      expect(scheduler.debugIdleRuns, 1);
      expect(scheduler.debugSafeguardRuns, 0);
    });

    // TC-891
    test('awaitSlot completes only once a slot is granted', () async {
      final scheduler = IdlePublishScheduler(safeguard: kNeverFires);
      addTearDown(scheduler.dispose);

      var completed = false;
      final slot = scheduler.awaitSlot().then((_) => completed = true);
      expect(completed, false, reason: 'the gate must not open synchronously');

      await slot;
      expect(completed, true);
      expect(scheduler.debugIdleRuns, 1);
    });

    // TC-892 -- dropping a pending slot would strand a `_loadingKeys` claim.
    test('dispose flushes pending slots instead of dropping them', () async {
      SchedulerBinding.instance.schedulingStrategy = _idleRefusingStrategy;
      final scheduler = IdlePublishScheduler(safeguard: kNeverFires);
      var runs = 0;

      scheduler.schedule(() => runs++);
      var gateOpened = false;
      final gate = scheduler.awaitSlot().then((_) => gateOpened = true);
      expect(runs, 0);
      expect(scheduler.debugPendingCount, 2);

      scheduler.dispose();
      expect(runs, 1, reason: 'dispose flushes, it does not drop');
      expect(scheduler.debugPendingCount, 0);
      await gate;
      expect(gateOpened, true);

      // After dispose there is nothing left to pace: run inline rather than
      // hand out a future nobody will ever complete.
      var afterDispose = 0;
      scheduler.schedule(() => afterDispose++);
      expect(afterDispose, 1);
      await scheduler.awaitSlot();
    });

    // TC-911 (W3, residual-jank-diagnosis.md fix #6): input within the settle
    // window defers the idle-priority run -- only the safeguard fires.
    test('recent input defers the idle-priority run until settle window elapses',
        () async {
      var fakeNow = DateTime(2026, 1, 1);
      final scheduler = IdlePublishScheduler(
        safeguard: kNeverFires,
        settleWindow: const Duration(milliseconds: 150),
        now: () => fakeNow,
      );
      addTearDown(scheduler.dispose);

      scheduler.noteInputActivity();
      var runs = 0;
      scheduler.schedule(() => runs++);

      // Still well within the settle window: repeated idle attempts must keep
      // deferring, never running the callback.
      await pumpEventLoop();
      expect(runs, 0, reason: 'recent input means the app is not idle yet');
      expect(scheduler.debugIsIdle, false);

      // Advance the fake clock past the settle window with no further input.
      fakeNow = fakeNow.add(const Duration(milliseconds: 151));
      expect(scheduler.debugIsIdle, true);
      await pumpEventLoop();
      expect(runs, 1, reason: 'once quiet, the idle path must run it');
      expect(scheduler.debugIdleRuns, 1);
      expect(scheduler.debugSafeguardRuns, 0);
    });

    // TC-912 -- the positive control: with no input ever recorded, the app is
    // idle from construction and the idle slot runs without waiting on the
    // safeguard at all.
    test('no input activity means idle from the start', () async {
      final scheduler = IdlePublishScheduler(safeguard: kNeverFires);
      addTearDown(scheduler.dispose);

      expect(scheduler.debugIsIdle, true);
      var runs = 0;
      scheduler.schedule(() => runs++);
      await pumpEventLoop();

      expect(runs, 1);
      expect(scheduler.debugIdleRuns, 1);
      expect(scheduler.debugSafeguardRuns, 0);
    });

    // TC-913 -- input recency alone must not defeat the safeguard: an
    // animating (idle-refusing) app with continuous input still eventually
    // publishes via the safeguard rather than stalling forever.
    test('continuous input still cannot defeat the safeguard', () async {
      SchedulerBinding.instance.schedulingStrategy = _idleRefusingStrategy;
      var fakeNow = DateTime(2026, 1, 1);
      final scheduler = IdlePublishScheduler(
        safeguard: Duration.zero,
        now: () => fakeNow,
      );
      addTearDown(scheduler.dispose);

      scheduler.noteInputActivity();
      var runs = 0;
      scheduler.schedule(() => runs++);
      await pumpEventLoop();

      expect(runs, 1, reason: 'the safeguard must still be unconditional');
      expect(scheduler.debugSafeguardRuns, 1);
      expect(scheduler.debugIdleRuns, 0);
    });

    // TC-893 -- structural conformance to both seams, checked by assignment.
    test('schedule is FrameHook-shaped and awaitSlot is CompositeGate-shaped',
        () async {
      final scheduler = IdlePublishScheduler(safeguard: Duration.zero);
      addTearDown(scheduler.dispose);

      final FrameHook hook = scheduler.schedule;
      final CompositeGate gate = scheduler.awaitSlot;

      var hookRuns = 0;
      hook(() => hookRuns++);
      await pumpEventLoop();
      expect(hookRuns, 1);

      await gate();
      expect(scheduler.debugPendingCount, 0);
    });
  });

  group('intent_coalescing_test.dart', () {
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
  });

  group('image_preload_pacer_test.dart', () {
    // Plan Task 11 (S4): tier-1 ImageCache registration is paced into the frame.
    //
    // TC-835b / TC-836b / TC-837b
    // (docs/logs/2026-09-03/plan-decode-optimizations.md).
    //
    // `_precacheTierOneWindow` walked the whole retention window in one
    // synchronous loop on every navigation pass, so codec-completion work arrived
    // as one clump behind one navigation event. After this task every non-selected
    // registration goes through `PublicationPacer`, one per frame, nearest first,
    // with the selected item exempt.
    //
    // The frame hook is a FAKE: no assertion here depends on wall-clock timing or
    // on a real `SchedulerBinding` frame.

    // TC-836b -- the selected item never waits for a frame.
    test('the selected id registers its tier-1 key without a frame', () async {
      final frames = FakeFramesImagePreloadPacer();
      final controller = buildController(scheduleFrameCallback: frames.arm);
      addTearDown(controller.dispose);
      controller.updateTargetSize(800, 600);

      await controller.preloadImages(
        items: manyCheapItems(),
        selectedItemId: 'c',
        notifyLoaded: () {},
      );
      await pumpMicrotasks();

      expect(
        controller.debugTierOneKeyIds,
        contains('c'),
        reason: 'the exempt (selected) registration must not wait for a frame',
      );
    });

    // TC-835b -- neighbours are paced, one per frame.
    test('non-selected tier-1 registrations are paced one per frame', () async {
      final frames = FakeFramesImagePreloadPacer();
      final controller = buildController(scheduleFrameCallback: frames.arm);
      addTearDown(controller.dispose);
      controller.updateTargetSize(800, 600);

      await controller.preloadImages(
        items: manyCheapItems(),
        selectedItemId: 'c',
        notifyLoaded: () {},
      );
      await pumpMicrotasks();
      final afterSelection = controller.debugTierOneKeyIds.length;

      frames.frame();
      await pumpMicrotasks();
      expect(controller.debugTierOneKeyIds.length, afterSelection + 1);

      frames.frame();
      await pumpMicrotasks();
      expect(controller.debugTierOneKeyIds.length, afterSelection + 2);
    });

    // TC-837b -- a payload dropped between submit and drain is not registered.
    test('a dropped payload is not registered at drain time', () async {
      final frames = FakeFramesImagePreloadPacer();
      final controller = buildController(scheduleFrameCallback: frames.arm);
      addTearDown(controller.dispose);
      controller.updateTargetSize(800, 600);

      await controller.preloadImages(
        items: manyCheapItems(),
        selectedItemId: 'c',
        notifyLoaded: () {},
      );
      await pumpMicrotasks();
      // Navigate away so the far neighbours leave the window before their drain.
      await controller.preloadImages(
        items: manyCheapItems(),
        selectedItemId: 'z',
        notifyLoaded: () {},
      );
      await pumpMicrotasks();
      frames.frame();
      await pumpMicrotasks();

      for (final id in controller.debugTierOneKeyIds) {
        expect(
          controller.payloadFor(id),
          isNotNull,
          reason: 'no key may be registered for a dropped payload',
        );
      }
    });

    // "every retained window slot eventually gets a tier-1 key" DELETED
    // (spec v2 R-B, 2026-09-11, lead ruling round 3): its premise was that
    // tier-1 precache spans the whole -3..+5 retention window. Window-
    // resolution retention is abolished -- tier-1 now covers only the +/-1
    // full-resolution band, so most retained slots never get a tier-1 key
    // at all, by design. See resolution_band_test.dart TC-1223/1224/1225 for
    // the band's replacement coverage.

    // TC-897 -- the controller-level twin of TC-894: with the pacer's exempt
    // claim enforced against the controller's selected id, a NON-selected window
    // slot cannot register a tier-1 key before a frame is granted, no matter
    // what the caller asks for.
    test('non-selected window items never register a tier-1 key before a frame',
        () async {
      final frames = FakeFramesImagePreloadPacer();
      final controller = buildController(scheduleFrameCallback: frames.arm);
      addTearDown(controller.dispose);
      controller.updateTargetSize(800, 600);

      await controller.preloadImages(
        items: manyCheapItems(),
        selectedItemId: 'c',
        notifyLoaded: () {},
      );
      await pumpMicrotasks();

      expect(
        controller.debugTierOneKeyIds,
        {'c'},
        reason: 'before any frame, exactly the selected id may be registered',
      );
      expect(controller.debugPacerHasFrameHook, isTrue);
    });
  });
}
