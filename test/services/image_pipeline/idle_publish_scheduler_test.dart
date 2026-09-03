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

import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/idle_publish_scheduler.dart';
import 'package:halcyon_flutter/services/image_pipeline/publication_pacer.dart'
    show FrameHook;

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
}
