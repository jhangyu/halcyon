import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

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
  IdlePublishScheduler({Duration safeguard = kIdlePublishSafeguard})
      : _safeguard = safeguard;

  final Duration _safeguard;
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

  /// `FrameHook`-compatible: `void Function(VoidCallback)`.
  ///
  /// [callback] runs exactly once, at the earliest of the idle task being
  /// serviced or the safeguard firing -- never synchronously, unless this
  /// scheduler is already disposed (see [dispose]).
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
    SchedulerBinding.instance.scheduleTask<void>(
      () => _run(slot, viaSafeguard: false),
      Priority.idle,
      debugLabel: 'halcyon.publishSlot',
    );
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
    slot.callback();
  }
}

class _PendingSlot {
  _PendingSlot(this.callback);

  final VoidCallback callback;
  Timer? timer;
}
