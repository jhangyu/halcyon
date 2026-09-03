import 'dart:async';
import 'dart:collection';

/// A counted concurrency gate for the JPEG re-encode.
///
/// Deliberately NOT `DecodeLane`. The lane's key dedup, in-place priority
/// replacement and near-to-far ordering exist to schedule DECODES: an encode
/// has no key space and no distance, and giving it one would invite exactly
/// the G-027 class of bug where two callers share a key space with different
/// intents. This is a FIFO counted gate and nothing else, so the near-to-far
/// order the lane already established upstream survives into this stage.
///
/// Unlike `DecodeLane._runOne`, [run] does NOT swallow exceptions: an encode
/// failure must reach `reencodePayload`'s fallback logic, not vanish.
class EncodeStage {
  EncodeStage({int width = 2}) : _width = width < 1 ? 1 : width;

  final Queue<_Job<Object?>> _pending = Queue<_Job<Object?>>();
  int _width;
  int _running = 0;
  bool _pumpScheduled = false;

  int get width => _width;

  /// Widening takes effect on the next microtask. NARROWING never pre-empts:
  /// nothing here can cancel a native encode, so surplus capacity is simply
  /// not re-used once a body finishes.
  set width(int value) {
    _width = value < 1 ? 1 : value;
    if (_pending.isNotEmpty) _schedulePump();
  }

  int get runningCount => _running;
  int get pendingCount => _pending.length;

  Future<T> run<T>(Future<T> Function() body) {
    final job = _Job<T>(body);
    _pending.add(job as _Job<Object?>);
    _schedulePump();
    return job.completer.future;
  }

  /// Drops every queued-but-not-started body, failing its future. Running
  /// bodies are unaffected.
  void clear() {
    while (_pending.isNotEmpty) {
      _pending
          .removeFirst()
          .completer
          .completeError(StateError('EncodeStage was cleared'));
    }
  }

  void _schedulePump() {
    if (_pumpScheduled) return;
    _pumpScheduled = true;
    scheduleMicrotask(() {
      _pumpScheduled = false;
      while (_running < _width && _pending.isNotEmpty) {
        unawaited(_runOne(_pending.removeFirst()));
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
  _Job(this.body);
  final Future<T> Function() body;
  final Completer<T> completer = Completer<T>();
}
