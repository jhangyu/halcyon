import 'dart:async';

import 'inflight_bytes_budget.dart';
import 'lane_priority.dart';

// PHASE 4 (2026-09-06): the priority BASES no longer live here.
//
// They moved to `lane_priority.dart`, which owns the whole band table and the
// classifier that maps a piece of work onto it -- see that file's library doc
// for the band order and for why the full-res band sits between navigation
// and sidebar work (user ruling, contract override S4). This lane is now a
// pure min-priority queue: it orders by the number it is handed and has no
// opinion about where that number came from.
//
// The two historical names are re-exported rather than deleted because the
// sidebar ordering tests (TC-963/TC-964) assert RELATIVE order through those
// symbols, and rebasing must not require rewriting the tests that prove the
// rebasing preserved order. Their VALUES changed with the new band table;
// nothing in `lib/` computes a priority from them any more.
export 'lane_priority.dart'
    show kFullResPriorityBase, kSidebarPayloadPriorityBase;

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

  /// Producing the full-size JPEG for a slot still holding a TEMPORARY pixel
  /// payload (compressed-residency v2 Task 3). A distinct kind, not a reuse of
  /// [payload]: the slot already HAS a payload, so a navigation re-enqueue of
  /// `(payload, id)` must not replace or be replaced by this job.
  deferredEncode,
}

typedef LaneKey = (LaneTaskKind kind, String id);

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
///
/// UNIFIED ADMISSION (WP2, 2026-09-06). When an [InflightBytesBudget] is
/// supplied this lane is also the ONE admission point for transient full-frame
/// BYTES: a task takes its lane slot and its bytes TOGETHER, all-or-nothing,
/// at dispatch. It therefore never holds one resource while waiting for the
/// other -- Coffman condition 2 is removed by construction, which is what the
/// old post-decode `acquire` avoided by not bounding decode-time bytes at all.
/// A task whose bytes do not fit stays in `_pending` holding NOTHING, and the
/// next release re-pumps.
class DecodeLane {
  DecodeLane({int width = 1, InflightBytesBudget? budget})
      : _width = width < 1 ? 1 : width,
        _budget = budget;

  final Map<LaneKey, _LaneTask> _pending = {};
  final InflightBytesBudget? _budget;
  final Map<LaneKey, _Admission> _admitted = {};
  int _running = 0;
  bool _pumpScheduled = false;
  int _seq = 0;
  int _width;

  /// How many dispatch attempts were refused by the BYTE budget rather than by
  /// the lane width. Test seam for the deadlock regression (TC-1044): it is the
  /// only way to tell "the gate refused an admission and the queue still
  /// drained" from "the gate never engaged". Not `@visibleForTesting`: the
  /// controller re-exposes it as `debugByteBlockedPumps`, same shape as its
  /// other debug counters.
  int debugByteBlockedPumps = 0;

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

  /// The priority [key] is currently queued at, or null when it is not
  /// pending. Read-only observation of existing bookkeeping; exists so
  /// "the sidebar sweep did not DEMOTE a navigation entry" (G-027) is an
  /// asserted condition rather than an inference from a call count.
  int? pendingPriorityOf(LaneKey key) => _pending[key]?.priority;

  /// Queues [body] under [key] at [priority] (lower runs earlier).
  ///
  /// Re-enqueuing a key that is still pending REPLACES its priority and body
  /// rather than adding a second entry: that is the reprioritisation a
  /// navigation event needs, and it is also what keeps a burst of nine
  /// navigation events from queueing nine copies of the same decode. A key
  /// already IN FLIGHT is not pending, so a re-enqueue of it is a new entry --
  /// its body's own cache/in-flight re-checks make that a cheap no-op.
  ///
  /// [estimatedBytes] is what this task is expected to hold in flight (0 for a
  /// task that allocates no full frame -- charging those would make the gate
  /// refuse work it does not bound). It is only an ESTIMATE: the real size is
  /// unknown until the decode returns, and [adjustAdmission] reconciles it.
  /// A re-enqueue that REPLACES a pending entry also replaces its estimate --
  /// nothing has been charged yet, because a pending entry holds no resources.
  void enqueue(
    LaneKey key, {
    required int priority,
    required Future<void> Function() body,
    int estimatedBytes = 0,
  }) {
    final existing = _pending[key];
    if (existing != null) {
      existing.priority = priority;
      existing.seq = ++_seq;
      existing.body = body;
      existing.estimatedBytes = estimatedBytes;
    } else {
      _pending[key] = _LaneTask(
        key: key,
        priority: priority,
        seq: ++_seq,
        body: body,
        estimatedBytes: estimatedBytes,
      );
    }
    _schedulePump();
  }

  /// How many admissions were actually CORRECTED from their pre-decode
  /// estimate to a real frame size by [adjustAdmission].
  ///
  /// Counts only the calls that found a live admission with a budget wired, so
  /// it distinguishes "the re-accounting seam ran" from "the seam was a no-op"
  /// -- which is exactly what AC2 asks to be pinned, and what an assertion on
  /// `inFlightBytes` alone cannot tell apart. Not `@visibleForTesting`: the
  /// controller re-exposes it as `debugAdmissionAdjustmentCount`, same shape as
  /// [debugByteBlockedPumps].
  int debugAdmissionAdjustmentCount = 0;

  /// Corrects [key]'s admission from its pre-decode estimate to the real size,
  /// once the decode has produced the frame. No-op when [key] holds no
  /// admission (no budget wired, or the admission was already handed off).
  void adjustAdmission(LaneKey key, {required int to}) {
    final admission = _admitted[key];
    final budget = _budget;
    if (admission == null || budget == null) return;
    assert(to >= 0, 'a real frame size cannot be negative');
    budget.adjust(admission.bytes, to, epoch: admission.epoch);
    admission.bytes = to < 0 ? 0 : to;
    assert(
      _admitted[key]!.bytes == (to < 0 ? 0 : to),
      'the ledger write-back must match the value charged against the budget',
    );
    debugAdmissionAdjustmentCount++;
    _schedulePump();
  }

  /// Moves [key]'s byte charge off the DECODE ledger and onto [tail], the
  /// encode/publish tail ledger, returning the charge the new holder must
  /// release exactly once.
  ///
  /// S1.3: the decode ledger is what bounds DECODE concurrency, so it must be
  /// free the moment the frame leaves the lane -- otherwise a `W+1`-frame
  /// budget still caps decode concurrency below `W` whenever encodes are slow.
  /// The frame itself is demonstrably still alive through the off-lane encode,
  /// so the bytes are not forgotten, they are re-attributed.
  ///
  /// ORDER IS LOAD-BEARING and is why this is ONE method rather than two calls
  /// at the call site: the tail is charged BEFORE the decode ledger is
  /// released, so the accounted total never dips below the live byte count and
  /// no decode is ever admitted against capacity a frame in encode still
  /// occupies. Expressing it here makes the wrong order unrepresentable
  /// instead of merely commented.
  ///
  /// The charge is the REAL post-decode size (lead ruling 2026-09-11), read off
  /// the admission [adjustAdmission] already corrected -- never
  /// `kNominalFullFrameBytes`, which would double the accounted tail on every
  /// frame smaller than the nominal.
  ///
  /// Returns null when [key] holds no admission (no budget wired, or nothing
  /// was admitted for it).
  EncodePublishTailCharge? handOffAdmissionToTail(
    LaneKey key,
    InflightBytesBudget tail,
  ) {
    final admission = _admitted.remove(key);
    if (admission == null) return null;
    final charge = EncodePublishTailCharge(
      admission.bytes,
      tail.chargeWithoutAdmission(admission.bytes),
    );
    _budget?.release(admission.bytes, epoch: admission.epoch);
    if (_pending.isNotEmpty) _schedulePump();
    return charge;
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
      // Two dispatch points exist (here, and `_runOne`'s own loop), so BOTH go
      // through `_takeNextAdmitted` -- the byte resource must be taken with the
      // slot wherever a body starts, not only where a runner is created.
      while (_running < _width && _pending.isNotEmpty) {
        final task = _takeNextAdmitted();
        if (task == null) break; // byte-blocked: hold nothing, wait for a release
        unawaited(_runOne(task));
      }
    });
  }

  /// Drops every pending entry. Does not affect a task already in flight --
  /// nothing here can cancel an FFI decode; its body re-checks state on
  /// completion instead. Used by `reset()`/`dispose()`.
  void clearPending() => _pending.clear();

  /// Drops every PENDING (not yet dispatched) task whose key [keep] rejects,
  /// running [onDropped] for each so the caller can release whatever the
  /// dropped body would have resolved (parked notify callbacks).
  ///
  /// Operates on `_pending` ONLY (N2). A dispatched task is already out of
  /// that map -- it holds a lane slot and/or a byte admission -- so this can
  /// never drop work that holds either resource, and it never calls
  /// `_budget.release`: a pending entry was never charged, so releasing would
  /// under-count `_inFlight`.
  int prunePending(
    bool Function(LaneKey key) keep, {
    void Function(LaneKey key)? onDropped,
  }) {
    final toDrop = <LaneKey>[];
    for (final key in _pending.keys) {
      if (!keep(key)) toDrop.add(key);
    }
    for (final key in toDrop) {
      _pending.remove(key);
      onDropped?.call(key);
    }
    return toDrop.length;
  }

  /// The "queue roster" a pruning test asserts before/after a window move.
  /// Not `@visibleForTesting`: the controller re-exposes it under that
  /// annotation, same pattern as [debugByteBlockedPumps].
  List<LaneKey> get debugPendingKeys => _pending.keys.toList();

  Future<void> _runOne(_LaneTask first) async {
    _running++;
    var next = first;
    try {
      while (true) {
        try {
          await next.body();
        } catch (_) {
          // One item's failure must not wedge this runner for the rest of the
          // session. Real failures are recorded by the body's own owner
          // (permanent misses, full-res failure memos); this only keeps the
          // lane runnable.
        } finally {
          // Both resources are given back here, unless the byte admission was
          // HANDED OFF to the encode/publish tail ledger, whose holder outlives
          // this body (see [handOffAdmissionToTail]). Releasing bytes re-pumps,
          // because a
          // pending task may have been refused for exactly these bytes; without
          // that restart the queue would stall forever once the last runner
          // exits.
          _releaseAdmissionFor(next.key);
        }
        // `_running <= _width` retires surplus runners after a width reduction:
        // never mid-body (no FFI decode is cancellable), only between bodies.
        if (_pending.isEmpty || _running > _width) break;
        final following = _takeNextAdmitted();
        if (following == null) break; // byte-blocked: retire, do not spin
        next = following;
      }
    } finally {
      _running--;
    }
  }

  /// Takes the highest-priority pending task AND its bytes, or nothing at all.
  ///
  /// Returning null is NOT a wait: the task stays pending and holds neither
  /// resource, so no cycle can form between the two.
  _LaneTask? _takeNextAdmitted() {
    final best = _peekNext();
    if (best == null) return null;
    final budget = _budget;
    if (budget != null) {
      final epoch = budget.tryAcquire(best.estimatedBytes);
      if (epoch == null) {
        debugByteBlockedPumps++;
        return null;
      }
      _admitted[best.key] = _Admission(best.estimatedBytes, epoch);
    }
    _pending.remove(best.key);
    return best;
  }

  void _releaseAdmissionFor(LaneKey key) {
    final admission = _admitted.remove(key);
    if (admission == null) return;
    _budget?.release(admission.bytes, epoch: admission.epoch);
    if (_pending.isNotEmpty) _schedulePump();
  }

  // ponytail: O(n) scan is fine — pending is bounded by window size (~9) +
  // full-res upgrades; switch to a heap if that ever grows.
  _LaneTask? _peekNext() {
    _LaneTask? best;
    for (final task in _pending.values) {
      if (best == null ||
          task.priority < best.priority ||
          (task.priority == best.priority && task.seq < best.seq)) {
        best = task;
      }
    }
    return best;
  }
}

class _Admission {
  _Admission(this.bytes, this.epoch);
  int bytes;
  final int epoch;
}

class _LaneTask {
  _LaneTask({
    required this.key,
    required this.priority,
    required this.seq,
    required this.body,
    required this.estimatedBytes,
  });

  final LaneKey key;
  int priority;
  int seq;
  Future<void> Function() body;
  int estimatedBytes;
}

/// The lane rank for an item [signedDistance] slots away from the selection.
///
/// Produces exactly the user-ruled start order 0, +1, -1, +2, -2, +3, -3, +4,
/// +5 (2026-08-26 ruling): forward before backward at equal absolute distance,
/// because browsing is overwhelmingly forwards -- the same asymmetry the
/// retention window (-3..+5) already encodes.
/// PHASE 4: the implementation moved to `lane_priority.dart`
/// ([laneRankForDistance]) so that every input to a lane priority is decided
/// in one file. This alias stays for the call sites that only need the rank
/// itself (the tier-1 ImageCache submit rank, the perf log), which are not
/// lane priorities at all.
int laneRankFor(int signedDistance) => laneRankForDistance(signedDistance);
