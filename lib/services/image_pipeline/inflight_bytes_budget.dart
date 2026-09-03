import 'dart:async';
import 'dart:collection';

/// A byte-denominated admission gate spanning every pipeline stage that holds
/// a transient full-frame buffer.
///
/// Why bytes and not task counts: a 12 MP and a 60 MP file are not one unit of
/// work each, and stage pipelining multiplies the number of full-frame buffers
/// alive at once. `kPayloadByteBudget` (`photo_payload_cache.dart`) counts
/// RETAINED payloads only -- every buffer this class bounds is IN FLIGHT and
/// invisible to that budget. A queue depth measured in tasks is not a memory
/// bound when task sizes vary by 5x across a mixed folder.
///
/// FIFO by design. Ordering is `DecodeLane`'s job (near-to-far, priority
/// classes, key dedup); duplicating any of that here would be a second
/// scheduler.
class InflightBytesBudget {
  InflightBytesBudget({required int maxBytes})
      : _maxBytes = maxBytes < 1 ? 1 : maxBytes;

  final Queue<_Waiter> _waiting = Queue<_Waiter>();
  int _maxBytes;
  int _inFlight = 0;

  int get maxBytes => _maxBytes;

  /// Lowering never pre-empts an admitted caller -- nothing here can cancel a
  /// decode or an encode in flight. It only delays the next admission.
  set maxBytes(int value) {
    _maxBytes = value < 1 ? 1 : value;
    _admit();
  }

  int get inFlightBytes => _inFlight;
  int get waitingCount => _waiting.length;

  /// Completes when [bytes] fits, or immediately when nothing is in flight.
  ///
  /// The empty-budget escape hatch is load-bearing: a single frame larger than
  /// the whole budget would otherwise wait forever for a release that can only
  /// come from itself.
  Future<void> acquire(int bytes) {
    final want = bytes < 0 ? 0 : bytes;
    if (_waiting.isEmpty && _fits(want)) {
      _inFlight += want;
      return Future<void>.value();
    }
    final waiter = _Waiter(want);
    _waiting.add(waiter);
    return waiter.completer.future;
  }

  void release(int bytes) {
    final gave = bytes < 0 ? 0 : bytes;
    assert(_inFlight >= gave, 'released more bytes than were acquired');
    _inFlight -= gave;
    if (_inFlight < 0) _inFlight = 0;
    _admit();
  }

  /// Completes every parked waiter and zeroes the counter. Called from
  /// `reset()`/`dispose()`, so a teardown cannot strand an awaiting task.
  void clear() {
    _inFlight = 0;
    while (_waiting.isNotEmpty) {
      _waiting.removeFirst().completer.complete();
    }
  }

  bool _fits(int bytes) => _inFlight == 0 || _inFlight + bytes <= _maxBytes;

  void _admit() {
    // Head-of-queue only: a stream of small requests must not starve a large
    // one that arrived first.
    while (_waiting.isNotEmpty && _fits(_waiting.first.bytes)) {
      final waiter = _waiting.removeFirst();
      _inFlight += waiter.bytes;
      waiter.completer.complete();
    }
  }
}

class _Waiter {
  _Waiter(this.bytes);
  final int bytes;
  final Completer<void> completer = Completer<void>();
}
