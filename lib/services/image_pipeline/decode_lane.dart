import 'dart:async';

/// What a lane task is FOR. Part of the lane key, so payload production and a
/// full-resolution upgrade for the same item are two distinct entries.
///
/// A key shape, not a prefix: [PhotoItem.id] is a user-controlled filename, so
/// a `'fullres_$id'` string key would make one string mean two things for a
/// folder that happens to hold `fullres_IMG_01.dng` (the same collision class
/// `ImagePreloadController._thumbPermanentMisses` documents). A record key of
/// (kind, id) has value equality and no id-space overlap at all.
enum LaneTaskKind {
  /// Producing an item's retained payload (the real RAW decode).
  payload,

  /// Upgrading an already-retained pixel payload to a full-resolution tier-2
  /// ImageCache entry.
  fullRes,
}

typedef LaneKey = (LaneTaskKind kind, String id);

/// Priority base for [LaneTaskKind.fullRes] work.
///
/// User ruling (open question 4, unchanged by the 2026-08-26 unification): the
/// blank slots the user can SEE go first. Any payload production pending on the
/// lane therefore outranks every full-resolution upgrade, whatever their
/// distances; within each class the near-to-far rank decides.
const int kFullResPriorityBase = 1000;

/// THE ONE place an expensive (real RAW) decode may run.
///
/// Up to [width] task bodies execute at once, ordered near-to-far by priority.
/// Width 1 is the historical single-flight lane, bit-for-bit.
///
/// User ruling 2026-08-30 (docs/logs/2026-08-30/spec-parallel-decode-lane.md)
/// supersedes ONLY the single-flight clause of the 2026-08-26 ruling
/// (docs/logs/2026-08-26/serial-lane-unification-contract.md): one ceyx decode
/// measures ~4.7 cores of a 28-core machine
/// (docs/logs/2026-08-30/decode-cpu-parallelism.txt:113), so a single slot left
/// most of a large machine idle. Everything else from that ruling stands:
///
///   * the only permitted difference between a cheap and an expensive item is
///     the payload-production CONCURRENCY MODE -- cheap loads run in parallel,
///     expensive ones queue on this lane, ordered near-to-far from the selected
///     index. There is no radius: every slot of the retention window is
///     eligible, it just has to queue.
///   * **Counted slots.** At most [width] task bodies execute at once. A RAW
///     decode is multi-core but does not saturate a high-core machine, so a
///     bounded number in parallel raises throughput without starving the item
///     the user is looking at.
///   * **Reprioritisation.** Pending (not yet started) entries are re-ordered by
///     a later [enqueue] of the same key, so a navigation event does not have to
///     drain a queue built for the position the user has left. Entries whose
///     item is no longer wanted are not removed here: their bodies re-check the
///     retention window / cache / in-flight state themselves and return without
///     doing any work (invariant I4), which keeps window policy in exactly one
///     owner instead of being duplicated into the queue.
///
/// A failing task never wedges any runner: every body is run inside a guard.
class DecodeLane {
  DecodeLane({int width = 1}) : _width = width < 1 ? 1 : width;

  final Map<LaneKey, _LaneTask> _pending = {};
  int _running = 0;
  bool _pumpScheduled = false;
  int _seq = 0;
  int _width;

  /// How many task bodies may execute at once.
  int get width => _width;

  /// Widening takes effect on the next microtask. NARROWING never pre-empts:
  /// nothing can cancel an in-flight FFI decode, so surplus runners retire when
  /// their current body finishes.
  set width(int value) {
    _width = value < 1 ? 1 : value;
    if (_pending.isNotEmpty) _schedulePump();
  }

  /// Whether any task body is currently executing.
  bool get isBusy => _running > 0;

  /// How many task bodies are currently executing.
  int get runningCount => _running;

  /// Number of tasks queued and not yet started.
  int get pendingCount => _pending.length;

  /// Whether [key] is queued and not yet started.
  bool isPending(LaneKey key) => _pending.containsKey(key);

  /// Queues [body] under [key] at [priority] (lower runs earlier).
  ///
  /// Re-enqueuing a key that is still pending REPLACES its priority and body
  /// rather than adding a second entry: that is the reprioritisation a
  /// navigation event needs, and it is also what keeps a burst of nine
  /// navigation events from queueing nine copies of the same decode. A key
  /// already IN FLIGHT is not pending, so a re-enqueue of it is a new entry --
  /// its body's own cache/in-flight re-checks make that a cheap no-op.
  void enqueue(
    LaneKey key, {
    required int priority,
    required Future<void> Function() body,
  }) {
    final existing = _pending[key];
    if (existing != null) {
      existing.priority = priority;
      existing.seq = ++_seq;
      existing.body = body;
    } else {
      _pending[key] = _LaneTask(
        key: key,
        priority: priority,
        seq: ++_seq,
        body: body,
      );
    }
    _schedulePump();
  }

  /// Starts the pump on a MICROTASK, never synchronously inside [enqueue].
  ///
  /// Load-bearing for the start order: a window pass enqueues its whole
  /// near-to-far batch in one synchronous burst, and running the first body
  /// inline would commit the lane to whatever happened to be enqueued FIRST --
  /// which, for the tier-2 sweep's index-ordered loop, is the far end of the
  /// window rather than the item the user is looking at. Deferring by one
  /// microtask lets the batch finish so the priority comparison sees all of it.
  void _schedulePump() {
    if (_pumpScheduled) return;
    _pumpScheduled = true;
    scheduleMicrotask(() {
      _pumpScheduled = false;
      while (_running < _width && _pending.isNotEmpty) {
        unawaited(_runOne());
      }
    });
  }

  /// Drops every pending entry. Does not affect a task already in flight --
  /// nothing here can cancel an FFI decode; its body re-checks state on
  /// completion instead. Used by `reset()`/`dispose()`.
  void clearPending() => _pending.clear();

  Future<void> _runOne() async {
    _running++;
    try {
      // `_running <= _width` retires surplus runners after a width reduction:
      // never mid-body (no FFI decode is cancellable), only between bodies.
      while (_pending.isNotEmpty && _running <= _width) {
        final next = _takeNext();
        try {
          await next.body();
        } catch (_) {
          // One item's failure must not wedge this runner for the rest of the
          // session. Real failures are recorded by the body's own owner
          // (permanent misses, full-res failure memos); this only keeps the
          // lane runnable.
        }
      }
    } finally {
      _running--;
    }
  }

  // ponytail: O(n) scan is fine — pending is bounded by window size (~9) +
  // full-res upgrades; switch to a heap if that ever grows.
  _LaneTask _takeNext() {
    _LaneTask? best;
    for (final task in _pending.values) {
      if (best == null ||
          task.priority < best.priority ||
          (task.priority == best.priority && task.seq < best.seq)) {
        best = task;
      }
    }
    _pending.remove(best!.key);
    return best;
  }
}

class _LaneTask {
  _LaneTask({
    required this.key,
    required this.priority,
    required this.seq,
    required this.body,
  });

  final LaneKey key;
  int priority;
  int seq;
  Future<void> Function() body;
}

/// The lane rank for an item [signedDistance] slots away from the selection.
///
/// Produces exactly the user-ruled start order 0, +1, -1, +2, -2, +3, -3, +4,
/// +5 (2026-08-26 ruling): forward before backward at equal absolute distance,
/// because browsing is overwhelmingly forwards -- the same asymmetry the
/// retention window (-3..+5) already encodes.
int laneRankFor(int signedDistance) {
  final d = signedDistance.abs();
  if (d == 0) return 0;
  return signedDistance > 0 ? 2 * d - 1 : 2 * d;
}
