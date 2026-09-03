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

  /// An epoch value that can never be current, handed to a caller whose
  /// admission was granted by [clear] rather than by [_admit] -- its bytes were
  /// never counted, so its release must not decrement anything.
  static const int invalidEpoch = -1;

  final Queue<_Waiter> _waiting = Queue<_Waiter>();
  int _maxBytes;
  int _inFlight = 0;
  int _epoch = 0;

  /// Bumped by every [clear]. An acquisition is only releasable against the
  /// epoch it was admitted in.
  int get epoch => _epoch;

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
  /// Resolves to the epoch the admission was granted in; pass it back to
  /// [release] so a teardown that happened in between cannot be double-counted.
  Future<int> acquire(int bytes) {
    final want = bytes < 0 ? 0 : bytes;
    if (_waiting.isEmpty && _fits(want)) {
      _inFlight += want;
      return Future<int>.value(_epoch);
    }
    final waiter = _Waiter(want);
    _waiting.add(waiter);
    return waiter.completer.future;
  }

  /// [epoch] is the value [acquire] resolved to. A release carrying an epoch
  /// older than the current one is a NO-OP, not an error: the pipeline's
  /// off-lane encode continuation is deliberately unawaited, so `dispose()` ->
  /// [clear] can legitimately land between its acquire and its release. Without
  /// this the counter had already been zeroed and the release drove it
  /// negative, tripping the assertion below inside whichever test ran next.
  ///
  /// Omitting [epoch] keeps the pre-epoch behaviour (always applied), for
  /// callers that acquire and release without any teardown in between.
  void release(int bytes, {int? epoch}) {
    if (epoch != null && epoch != _epoch) return;
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
    _epoch++;
    while (_waiting.isNotEmpty) {
      // Released, not admitted: these bytes were never added to `_inFlight`, so
      // the epoch they carry must not match any future one either.
      _waiting.removeFirst().completer.complete(invalidEpoch);
    }
  }

  bool _fits(int bytes) => _inFlight == 0 || _inFlight + bytes <= _maxBytes;

  void _admit() {
    // Head-of-queue only: a stream of small requests must not starve a large
    // one that arrived first.
    while (_waiting.isNotEmpty && _fits(_waiting.first.bytes)) {
      final waiter = _waiting.removeFirst();
      _inFlight += waiter.bytes;
      waiter.completer.complete(_epoch);
    }
  }
}

class _Waiter {
  _Waiter(this.bytes);
  final int bytes;
  final Completer<int> completer = Completer<int>();
}
