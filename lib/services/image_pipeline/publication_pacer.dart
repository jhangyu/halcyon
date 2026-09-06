import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// How the pacer asks to be woken once per frame. Injected so every test is
/// deterministic and no assertion depends on wall-clock timing.
typedef FrameHook = void Function(VoidCallback callback);

/// Paces publication into Flutter's own pipeline: at most [perFrame]
/// `ImageCache` registrations or GPU uploads per frame, nearest-first, with
/// the selected item exempt.
///
/// The pipeline had no notion of a frame budget anywhere: `_precacheTierOneWindow`
/// walks the whole retention window in one synchronous loop on every navigation
/// pass, so codec-completion and upload work arrive as one clump behind a
/// single navigation event.
///
/// This class knows nothing about images. It holds closures and a rank; the
/// caller decides what a publication IS and what makes one stale.
class PublicationPacer {
  PublicationPacer({
    FrameHook? scheduleFrameCallback,
    int perFrame = 1,
    // R3-WP8: the byte-quota half of the per-frame budget, alongside the
    // pre-existing count budget ([perFrame]). Defaults effectively unbounded
    // so every existing construction (and every pre-existing test) keeps its
    // count-only behaviour byte for byte.
    int perFrameBytes = 1 << 62,
    int maxQueued = 4,
    bool Function(String id)? isSelected,
  })  : _frameHook = scheduleFrameCallback,
        _perFrame = perFrame < 1 ? 1 : perFrame,
        _perFrameBytes = perFrameBytes < 1 ? 1 : perFrameBytes,
        _maxQueued = maxQueued < 1 ? 1 : maxQueued,
        _isSelected = isSelected;

  final FrameHook? _frameHook;
  final int _perFrame;
  final int _perFrameBytes;
  final int _maxQueued;

  /// Bytes actually published by the most recently completed [_drain] call.
  /// Exists purely for the quota test (TC-1056): the budget itself is
  /// consumed internally by [_drain] and never otherwise observable.
  @visibleForTesting
  int debugBytesPublishedLastFrame = 0;

  /// Number of [_drain] calls that published at least one entry. Together
  /// with [debugMaxBatchSize] this is what a batched-drain test asserts
  /// against (AC9.5): several entries queued in the SAME turn (before the
  /// frame hook fires) drain in ONE `_drain` call, because [_arm] is
  /// idempotent while `_armed` is true -- multiple `submit` calls in one turn
  /// collapse onto the single scheduled drain rather than each requesting its
  /// own.
  @visibleForTesting
  int debugBatchesDrained = 0;

  /// The largest number of entries a single [_drain] call has published.
  @visibleForTesting
  int debugMaxBatchSize = 0;

  /// Enforces the [submit] `exempt` claim (contract deliverable 3): only the
  /// id this predicate accepts may publish synchronously. Null means "trust
  /// the caller", which is what every existing test and every non-production
  /// construction does.
  final bool Function(String id)? _isSelected;

  int _downgradedExempt = 0;

  final Map<String, _Entry> _queued = <String, _Entry>{};
  int _seq = 0;
  bool _armed = false;

  int get queuedCount => _queued.length;

  @visibleForTesting
  bool get debugHasFrameHook => _frameHook != null;

  /// How many exempt claims were refused and queued instead. A production
  /// value above zero means some caller thinks a non-selected item deserves a
  /// synchronous publish -- the exact drift this predicate exists to catch.
  @visibleForTesting
  int get debugDowngradedExemptCount => _downgradedExempt;

  /// Submits one publication.
  ///
  /// [exempt] publishes SYNCHRONOUSLY, in this turn: the item the user is
  /// looking at must never wait a frame for its own pixels (the same rationale
  /// as the full-res band's "blank slots the user can SEE go first").
  ///
  /// [stillValid] is the load-bearing check and is evaluated at DRAIN time, not
  /// here (G-023): between submit and drain the payload may have been replaced
  /// or the id may have left the window, and publishing then would build a
  /// provider for a payload that is no longer current -- a silent double
  /// decode, per invariant I1.
  ///
  /// [discard] releases whatever the entry was holding (e.g. a `ui.Image`) when
  /// it is dropped instead of published. It runs exactly once per dropped
  /// entry and never for a published one.
  void submit({
    required String id,
    required int rank,
    required bool exempt,
    required bool Function() stillValid,
    required void Function() publish,
    void Function()? discard,
    // R3-WP8: REQUIRED (plan Step 9.5), not defaulted -- every call site is
    // fixed explicitly rather than silently opting out of the byte budget.
    // Charged against [_perFrameBytes] at drain time, the same way [rank]
    // charges against [_perFrame]'s count. A caller with no separately
    // measurable bytes (e.g. a test with no byte budget in play) passes 0,
    // which is a no-op against the byte side of the quota.
    required int byteCost,
  }) {
    // ENFORCED, not trusted. `exempt` used to be a caller assertion, and the
    // only thing keeping the exempt set down to one item was one `==` at the
    // single call site. A second call site (or an edit to that one) could
    // silently reintroduce the burst this class exists to prevent, and no test
    // would notice -- so the pacer now checks the claim itself and DOWNGRADES
    // a false one to the ordinary queue. Downgraded, never dropped: pacing
    // decides WHEN a publication lands, never WHETHER.
    if (exempt && (_isSelected?.call(id) ?? true)) {
      if (stillValid()) {
        publish();
      } else {
        discard?.call();
      }
      return;
    }
    if (exempt) _downgradedExempt++;
    // A re-submission supersedes the queued entry: the old one's holdings must
    // be released or they leak.
    _queued.remove(id)?.discard?.call();
    _queued[id] = _Entry(
      rank: rank,
      seq: _seq++,
      stillValid: stillValid,
      publish: publish,
      discard: discard,
      byteCost: byteCost,
    );
    _enforceCapacity();
    _arm();
  }

  /// Drops every queued entry, releasing what each holds.
  void clear() {
    for (final entry in _queued.values) {
      entry.discard?.call();
    }
    _queued.clear();
  }

  @visibleForTesting
  void drainOnce() => _drain();

  void _enforceCapacity() {
    while (_queued.length > _maxQueued) {
      // Farthest from the selection loses, mirroring the beyond-band-first
      // eviction rule. That may be the entry just submitted.
      String? worstId;
      _Entry? worst;
      _queued.forEach((id, entry) {
        if (worst == null ||
            entry.rank > worst!.rank ||
            (entry.rank == worst!.rank && entry.seq < worst!.seq)) {
          worstId = id;
          worst = entry;
        }
      });
      _queued.remove(worstId)?.discard?.call();
    }
  }

  void _arm() {
    if (_armed || _queued.isEmpty) return;
    _armed = true;
    final hook = _frameHook;
    if (hook != null) {
      hook(_drain);
      return;
    }
    // Resolved lazily so constructing a pacer before the binding exists is
    // harmless. `addPostFrameCallback` alone only fires when SOMETHING ELSE
    // schedules a frame; on an idle app (nothing pumping the scheduler) a
    // queued registration can stall indefinitely. `scheduleFrame()` requests
    // the frame this pacer itself needs to drain.
    SchedulerBinding.instance.addPostFrameCallback((_) => _drain());
    SchedulerBinding.instance.scheduleFrame();
  }

  void _drain() {
    _armed = false;
    var budget = _perFrame;
    var byteBudget = _perFrameBytes;
    var bytesThisFrame = 0;
    var batch = 0;
    while (budget > 0 && _queued.isNotEmpty) {
      final id = _nearestId()!;
      final entry = _queued[id]!;
      // A single entry larger than the whole quota publishes anyway when it
      // is FIRST this frame -- the same "one oversized item must make
      // progress" rule as InflightBytesBudget's empty-budget clause, and for
      // the same reason: a ~97MB upload would otherwise never publish at all.
      if (bytesThisFrame > 0 && entry.byteCost > byteBudget) break;
      _queued.remove(id);
      if (!entry.stillValid()) {
        // A dropped stale entry does NOT consume either budget: it did no
        // work, so charging for it would starve a valid entry behind it.
        entry.discard?.call();
        continue;
      }
      entry.publish();
      budget--;
      byteBudget -= entry.byteCost;
      bytesThisFrame += entry.byteCost;
      batch++;
    }
    debugBytesPublishedLastFrame = bytesThisFrame;
    if (batch > 0) {
      debugBatchesDrained++;
      if (batch > debugMaxBatchSize) debugMaxBatchSize = batch;
    }
    _arm();
  }

  String? _nearestId() {
    String? bestId;
    _Entry? best;
    _queued.forEach((id, entry) {
      if (best == null ||
          entry.rank < best!.rank ||
          (entry.rank == best!.rank && entry.seq < best!.seq)) {
        bestId = id;
        best = entry;
      }
    });
    return bestId;
  }
}

class _Entry {
  _Entry({
    required this.rank,
    required this.seq,
    required this.stillValid,
    required this.publish,
    required this.discard,
    required this.byteCost,
  });

  final int rank;
  final int seq;
  final bool Function() stillValid;
  final void Function() publish;
  final void Function()? discard;
  final int byteCost;
}
