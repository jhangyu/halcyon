import 'dart:async';

/// A bounded, priority-ordered concurrency gate.
///
/// Same "counted gate" shape as [EncodeStage] (`encode_stage.dart`) -- a FIFO
/// queue plus a running-count ceiling, no key space, no cancellation of a
/// body already started -- but ordered by an explicit priority instead of
/// arrival order. [EncodeStage] cannot be reused verbatim for sidebar
/// thumbnail derivation because plain FIFO is exactly the defect Phase 2
/// fixes: a burst of ten landings must service the visible-centre row before
/// a margin row that happened to land first (`async-pipeline-refactor-plan.md`
/// §3 Phase 2).
///
/// Lower [submit] priority values run sooner. Ties break by submission order
/// (stable), so two jobs at equal priority still complete in arrival order.
class DeriveQueue {
  DeriveQueue({int width = 2}) : _width = width < 1 ? 1 : width;

  final List<_Job<Object?>> _pending = <_Job<Object?>>[];
  int _width;
  int _running = 0;
  bool _pumpScheduled = false;
  int _sequence = 0;

  int get width => _width;

  /// Widening takes effect on the next microtask. NARROWING never pre-empts:
  /// nothing here can cancel a running body, so surplus capacity is simply
  /// not re-used once a body finishes.
  set width(int value) {
    _width = value < 1 ? 1 : value;
    if (_pending.isNotEmpty) _schedulePump();
  }

  int get runningCount => _running;
  int get pendingCount => _pending.length;

  /// Priorities currently queued (not yet started), in submission order.
  /// Debug-only: lets a test assert what would run next without racing the
  /// microtask pump.
  List<int> get debugPendingPriorities =>
      List.unmodifiable(_pending.map((job) => job.priority));

  Future<T> submit<T>(int priority, Future<T> Function() body) {
    final job = _Job<T>(priority, _sequence++, body);
    _pending.add(job as _Job<Object?>);
    _schedulePump();
    return job.completer.future;
  }

  /// Drops every queued-but-not-started body, failing its future. Running
  /// bodies are unaffected.
  void clear() {
    for (final job in _pending) {
      job.completer.completeError(StateError('DeriveQueue was cleared'));
    }
    _pending.clear();
  }

  void _schedulePump() {
    if (_pumpScheduled) return;
    _pumpScheduled = true;
    scheduleMicrotask(() {
      _pumpScheduled = false;
      while (_running < _width && _pending.isNotEmpty) {
        _pending.sort((a, b) {
          final byPriority = a.priority.compareTo(b.priority);
          if (byPriority != 0) return byPriority;
          return a.sequence.compareTo(b.sequence);
        });
        unawaited(_runOne(_pending.removeAt(0)));
      }
    });
  }

  Future<void> _runOne(_Job<Object?> job) async {
    _running++;
    try {
      job.completer.complete(await job.body());
    } catch (error, stack) {
      job.completer.completeError(error, stack);
    } finally {
      _running--;
      if (_pending.isNotEmpty) _schedulePump();
    }
  }
}

class _Job<T> {
  _Job(this.priority, this.sequence, this.body);
  final int priority;
  final int sequence;
  final Future<T> Function() body;
  final Completer<T> completer = Completer<T>();
}
