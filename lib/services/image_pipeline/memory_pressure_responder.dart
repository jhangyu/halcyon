import 'dart:async';

import '../platform/memory_pressure_monitor.dart';

/// What [MemoryPressureResponder] is allowed to do to the pipeline.
///
/// Deliberately NARROW and deliberately an interface: the responder owns the
/// POLICY (when to shrink, by how much, when to restore) in one place, and the
/// pipeline owns the MECHANISM. Nothing here is new machinery --
/// [setPayloadByteBudget] is the existing `PhotoPayloadCache.setByteBudget`
/// (`photo_payload_cache.dart:94-97`, which already sweeps immediately), and
/// [dropFarBandTierTwoPixels] is the existing beyond-band tier-2 eviction path
/// (`tier_two_registry.dart:335-343`). WP4.4 adds a TRIGGER, not a mechanism:
/// the ORDER in which items are dropped is unchanged, only the moment at which
/// the existing budget enforcement runs and the number it enforces against.
abstract class MemoryPressureTarget {
  // Deliberately NO "budget currently in force" member. The responder never
  // reads it -- it halves the DERIVED value -- and an interface member that
  // production does not use is a member an implementation can get quietly
  // wrong: the app-side adapter would have had to answer it with the derived
  // number, which is a different quantity whenever an override is active.

  /// The pressure-free, derived budget -- the number [restorePayloadByteBudget]
  /// returns to. Read live at SHRINK time, never cached across an episode: if
  /// the derived value changes while the machine is under pressure (the user
  /// steps the retention tier), the responder must halve the current derived
  /// value, not a stale snapshot.
  int get calmPayloadByteBudget;

  /// Overrides the payload budget. The implementation sweeps immediately.
  void setPayloadByteBudget(int bytes);

  /// Clears the override, returning to the derived budget.
  ///
  /// Deliberately NOT expressed as `setPayloadByteBudget(calmPayloadByteBudget)`:
  /// the pipeline primitive this maps to takes a NULLABLE override where null
  /// means "restore whatever you now derive", which keeps the pipeline the
  /// single owner of the derived number. A responder that wrote the number back
  /// would be a second owner, and the two would drift the first time the
  /// derivation changed.
  void restorePayloadByteBudget();

  /// Drops full-resolution tier-2 pixels for items outside the tier-2 band.
  void dropFarBandTierTwoPixels();
}

/// Halves the payload cache and drops far-band tier-2 pixels under operating
/// system memory pressure; restores the derived budget when pressure clears.
///
/// "Generous in calm, shrink under pressure" (spec S3.4). In the absence of a
/// pressure event this class does NOTHING, which is what keeps calm-state
/// preload speed untouched -- there is no periodic tick, no polling and no
/// proactive shrink.
///
/// ## Correct on a platform that only ever reports normal and warning
///
/// [MemoryPressureLevel.critical] is macOS-only by platform capability (see the
/// enum's doc). This responder therefore treats warning and critical as the
/// SAME state -- "under pressure" -- rather than as two rungs with two
/// different budgets. A Windows session that only ever sees normal/warning gets
/// the complete, intended behaviour; nothing is gated behind a level that
/// platform cannot produce.
///
/// ## Idempotence and the restore path
///
/// Shrink happens ONCE per pressure episode, from the calm budget. A platform
/// re-announcing pressure (or escalating warning -> critical) must not halve a
/// halved budget into uselessness, so the second signal only repeats the
/// far-band tier-2 drop -- the cheap, always-safe half of the response. And a
/// responder that halves but never restores would turn a transient spike into a
/// permanently degraded session, so the [MemoryPressureLevel.normal] transition
/// restores unconditionally.
class MemoryPressureResponder {
  MemoryPressureResponder({
    required MemoryPressureMonitor monitor,
    required MemoryPressureTarget target,
  }) : _monitor = monitor,
       _target = target;

  final MemoryPressureMonitor _monitor;
  final MemoryPressureTarget _target;

  StreamSubscription<MemoryPressureLevel>? _subscription;

  bool _underPressure = false;

  /// True while the budget is being held at its halved value.
  bool get isUnderPressure => _underPressure;

  /// Subscribes to the monitor and applies whatever level it is already
  /// reporting. Applying the current level is not redundant: the platform may
  /// have pushed before this object existed (Flutter's channel buffers deliver
  /// it to the monitor as soon as the monitor registers), in which case the
  /// stream event is already spent.
  void start() {
    _subscription ??= _monitor.pressureLevelChanges.listen(applyLevel);
    applyLevel(_monitor.currentPressureLevel);
  }

  /// The whole policy, in one function.
  void applyLevel(MemoryPressureLevel level) {
    switch (level) {
      case MemoryPressureLevel.warning:
      case MemoryPressureLevel.critical:
        if (!_underPressure) {
          _underPressure = true;
          final halved = _target.calmPayloadByteBudget ~/ 2;
          _target.setPayloadByteBudget(halved < 1 ? 1 : halved);
        }
        // Repeated on every pressure signal, including escalation: far-band
        // tier-2 pixels are pure re-derivable cache, so dropping them again is
        // free insurance and cannot compound like a repeated halving would.
        _target.dropFarBandTierTwoPixels();
      case MemoryPressureLevel.normal:
        if (!_underPressure) return;
        _underPressure = false;
        _target.restorePayloadByteBudget();
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}
