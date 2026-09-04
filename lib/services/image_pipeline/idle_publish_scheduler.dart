import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../../perf/perf_log.dart'; // PERF-INSTRUMENTATION (D1 round-2, H3)

/// The seam a decode-completion step awaits before doing UI-isolate work
/// (pixel upload, EXIF-orientation compositing).
///
/// Shaped exactly like `FrameHook`'s async twin so the production binding and
/// every test fake are interchangeable, and so no assertion anywhere depends
/// on wall-clock timing.
typedef CompositeGate = Future<void> Function();

/// The default binding: no pacing at all.
///
/// Every entry point that takes a [CompositeGate] defaults to this, so adding
/// the parameter changed no existing call site's behaviour.
Future<void> immediateCompositeGate() => Future<void>.value();

/// How long a slot may wait for an idle task before the safeguard runs it
/// anyway. Two 60Hz frames: long enough that a genuinely idle app takes the
/// idle path, short enough that an animating app is not visibly starved.
const Duration kIdlePublishSafeguard = Duration(milliseconds: 32);

/// How recently a keyboard/pointer/scroll input must have occurred for the
/// app to be considered "not idle" (residual-jank-diagnosis.md fix #6).
///
/// `transientCallbackCount > 0` (a spinner mid-animation) used to be treated
/// as "busy" even when the user has not touched the app in seconds, which is
/// exactly backwards: a loading spinner animates precisely when publishes
/// queue, so that signal starved every publish onto the 32ms safeguard. Input
/// recency is the correct proxy for "the user is actively interacting" --
/// active scrolling counts, per user ruling, because scroll delivers pointer
/// events continuously.
const Duration kIdleInputSettleWindow = Duration(milliseconds: 150);

/// Grants UI-isolate publish slots at idle scheduler priority, with a
/// safeguard so a slot can never stall indefinitely.
///
/// WHY THE SAFEGUARD IS NOT OPTIONAL: `defaultSchedulingStrategy`
/// (flutter/lib/src/scheduler/binding.dart:1465-1470) returns
/// `priority >= Priority.animation.value` whenever
/// `scheduler.transientCallbackCount > 0` -- so while ANY animation runs (a
/// page transition, a `ProgressIndicator`), an idle task is skipped for as
/// long as the animation lasts. A queued tier-1 registration would merely be
/// late; a queued [CompositeGate] slot is AWAITED by a decode-completion step
/// that holds an `ImagePreloadController._loadingKeys` claim, so a stalled
/// slot is a permanent spinner. The safeguard timer is not subject to the
/// scheduling strategy, so it always eventually runs.
///
/// This class knows nothing about images or the pipeline: it hands out slots.
class IdlePublishScheduler {
  IdlePublishScheduler({
    Duration safeguard = kIdlePublishSafeguard,
    Duration settleWindow = kIdleInputSettleWindow,
    DateTime Function() now = DateTime.now,
  }) : _safeguard = safeguard,
       _settleWindow = settleWindow,
       _now = now;

  final Duration _safeguard;
  final Duration _settleWindow;

  /// Injectable clock (test seam) -- exactly the same shape as every other
  /// fake-clock seam in this pipeline, so tests never depend on wall time.
  final DateTime Function() _now;

  /// `null` means "no input observed yet since construction", which this
  /// class treats as idle (a cold-started app has nothing to be busy with).
  DateTime? _lastInputAt;

  final Set<_PendingSlot> _pending = <_PendingSlot>{};
  bool _disposed = false;
  int _idleRuns = 0;
  int _safeguardRuns = 0;

  @visibleForTesting
  int get debugIdleRuns => _idleRuns;

  @visibleForTesting
  int get debugSafeguardRuns => _safeguardRuns;

  @visibleForTesting
  int get debugPendingCount => _pending.length;

  /// `true` when no keyboard/pointer/scroll input has landed within
  /// [_settleWindow]. Exposed for tests; production code never needs to poll
  /// it directly -- [schedule]'s idle-priority attempt already checks it.
  @visibleForTesting
  bool get debugIsIdle => _isIdle;

  bool get _isIdle {
    final last = _lastInputAt;
    if (last == null) return true;
    return _now().difference(last) >= _settleWindow;
  }

  /// Called from wherever input already flows (keyboard nav, pointer/scroll
  /// handlers) to record "the user is actively interacting right now".
  ///
  /// This replaces `transientCallbackCount > 0` as the busy signal: that
  /// check is true for the ENTIRE lifetime of any running animation,
  /// including a loading spinner that animates for exactly as long as
  /// publishes are queued -- so it starved every idle slot onto the 32ms
  /// safeguard regardless of whether the user had touched anything recently.
  void noteInputActivity() {
    _lastInputAt = _now();
  }

  /// `FrameHook`-compatible: `void Function(VoidCallback)`.
  ///
  /// [callback] runs exactly once, at the earliest of the idle task being
  /// serviced (once the input settle window has passed) or the safeguard
  /// firing -- never synchronously, unless this scheduler is already
  /// disposed (see [dispose]).
  void schedule(VoidCallback callback) {
    if (_disposed) {
      // Nothing left to pace, and dropping the callback would strand whoever
      // is awaiting the slot.
      callback();
      return;
    }
    final slot = _PendingSlot(callback);
    _pending.add(slot);
    slot.timer = Timer(_safeguard, () => _run(slot, viaSafeguard: true));
    _scheduleIdleAttempt(slot);
  }

  /// Hands a slot to `SchedulerBinding` at idle priority. When the scheduler
  /// actually grants the slot, [_attemptIdleRun] additionally checks input
  /// recency: if the user interacted within the settle window, the callback
  /// is NOT run yet -- another idle-priority attempt is queued for the next
  /// opportunity, so the slot keeps retrying (bounded by the safeguard timer
  /// already running from [schedule]) until either input goes quiet or the
  /// safeguard fires.
  ///
  /// `SchedulerBinding.instance` throws a [FlutterError] ("Binding has not
  /// yet been initialized") when no Flutter binding exists at all -- e.g. a
  /// plain `test()` (not `testWidgets()`) unit test that constructs an
  /// `AppState` and never touches the widget tree. That is a real, reachable
  /// caller shape (`app_state_test.dart`'s `loadFolder`/selection groups),
  /// not a caller bug: this class's whole job is to hand out slots without
  /// knowing or caring who is asking, so it degrades structurally instead of
  /// crashing the caller. `_run`'s already-armed [_safeguard] `Timer` (which
  /// needs no binding) is what actually completes the slot in that case --
  /// exactly the same "never stall the caller" guarantee the safeguard was
  /// built for, just triggered by "no idle scheduler exists" instead of "an
  /// animation is hogging idle priority".
  void _scheduleIdleAttempt(_PendingSlot slot) {
    try {
      SchedulerBinding.instance.scheduleTask<void>(
        () => _attemptIdleRun(slot),
        Priority.idle,
        debugLabel: 'halcyon.publishSlot',
      );
    } on FlutterError {
      // No binding to retry against -- the safeguard timer already armed in
      // [schedule] is this slot's only path to completion now.
      return;
    }
  }

  void _attemptIdleRun(_PendingSlot slot) {
    // The safeguard may have already run this slot while this attempt was
    // queued; the pending-set membership check in `_run` also guards this,
    // but checking here too avoids scheduling a pointless further retry.
    if (!_pending.contains(slot)) return;
    if (!_isIdle) {
      _scheduleIdleAttempt(slot);
      return;
    }
    _run(slot, viaSafeguard: false);
  }

  /// [CompositeGate]-compatible: awaited by compositing steps BEFORE they
  /// allocate any `ui.Image`, which is what keeps the ownership contract in
  /// `decoded_rgba_image_provider.dart` untouched -- a pending gate owns
  /// nothing, so it cannot leak a ~50MB handle.
  Future<void> awaitSlot() {
    final completer = Completer<void>();
    schedule(completer.complete);
    return completer.future;
  }

  /// Flushes every pending slot -- it does NOT drop them.
  ///
  /// A dropped slot means an `awaitSlot` future that never completes, i.e. a
  /// decode-completion step parked forever holding its in-flight claim.
  void dispose() {
    _disposed = true;
    for (final slot in _pending.toList()) {
      _run(slot, viaSafeguard: true);
    }
  }

  void _run(_PendingSlot slot, {required bool viaSafeguard}) {
    // The set membership IS the "has not run yet" flag: whichever of the two
    // paths gets here first removes the slot and the other one no-ops.
    if (!_pending.remove(slot)) return;
    slot.timer?.cancel();
    if (viaSafeguard) {
      _safeguardRuns++;
    } else {
      _idleRuns++;
    }
    // PERF-INSTRUMENTATION (D1 gap #4, H3): sampled at every slot run (id-blind
    // by this class's own design -- see the class doc), so round-2 analysis can
    // see idleRuns vs safeguardRuns drift over a session without a per-id key.
    PerfLog.log(
      'idle_publish_counters|idleRuns=$_idleRuns|safeguardRuns=$_safeguardRuns'
      '|viaSafeguard=$viaSafeguard',
    );
    slot.callback();
  }
}

class _PendingSlot {
  _PendingSlot(this.callback);

  final VoidCallback callback;
  Timer? timer;
}
