import 'package:flutter/foundation.dart';

/// How far along one item's payload is, as a view can observe it.
///
/// The declaration order IS the progression order: [ImagePreloadController]
/// only ever moves an item FORWARD along this list (plan §3 Phase 5, "observed
/// transitions are a prefix of absent -> decoding -> tierOneReady ->
/// tierTwoReady"), and [failed] is terminal until the folder reloads.
///
/// Deliberately NOT a second source of truth: every value here is written from
/// the same landing sites that already call `notifyLoaded`, so a stage can
/// never disagree with the cache -- it is the same event, addressed to one
/// item instead of to the whole app.
enum PayloadStage {
  /// Nothing retained for this item, and no production in flight that this
  /// controller knows about. Also the state an id returns to after it leaves
  /// the retention union and its notifier is re-created on demand.
  absent,

  /// A producer has claimed this id (the detail path's `_loadingKeys` claim,
  /// or a serial-lane enqueue). The view may show a spinner.
  decoding,

  /// A payload is retained: there is something to paint at window resolution.
  tierOneReady,

  /// The full-size (tier-2) ImageCache entry for this item's CURRENT payload
  /// is resident, i.e. `ImagePreloadController.isFullSizeReady(id)` is true.
  tierTwoReady,

  /// Every source failed for this item and no later pass will re-ask
  /// (`_permanentMisses`). Terminal until `reset()`.
  failed,
}

/// One item's payload readiness, as handed to a view through
/// `ImagePreloadController.stateFor(id)`.
///
/// Immutable with value equality, which is load-bearing: the backing
/// [ValueNotifier] only notifies when the new value differs, so a landing that
/// changes nothing observable does not rebuild anybody.
///
/// [thumbnailReady] is a second, INDEPENDENT axis rather than another
/// [PayloadStage] value, because the sidebar tile is derived from the payload
/// and lands after it: an item can be `tierOneReady` with no tile yet (the
/// derive queue has not reached it) and the sidebar tile must still learn when
/// its own tile is written. Folding it into the stage ladder would either
/// order two events that are not ordered, or make the ladder non-monotonic.
@immutable
class PayloadState {
  const PayloadState({required this.stage, this.thumbnailReady = false});

  /// The state every id starts in and returns to after eviction.
  const PayloadState.absent() : stage = PayloadStage.absent, thumbnailReady = false;

  final PayloadStage stage;

  /// True once the sidebar has written a derived tile for this item.
  final bool thumbnailReady;

  /// There is something to paint at some resolution.
  bool get hasPayload =>
      stage == PayloadStage.tierOneReady || stage == PayloadStage.tierTwoReady;

  bool get hasFullSize => stage == PayloadStage.tierTwoReady;

  bool get hasFailed => stage == PayloadStage.failed;

  PayloadState copyWith({PayloadStage? stage, bool? thumbnailReady}) =>
      PayloadState(
        stage: stage ?? this.stage,
        thumbnailReady: thumbnailReady ?? this.thumbnailReady,
      );

  @override
  bool operator ==(Object other) =>
      other is PayloadState &&
      other.stage == stage &&
      other.thumbnailReady == thumbnailReady;

  @override
  int get hashCode => Object.hash(stage, thumbnailReady);

  @override
  String toString() =>
      'PayloadState(${stage.name}, thumbnailReady: $thumbnailReady)';
}

/// The map's value type. Two things a plain [ValueNotifier] does not give:
///
///  * a lifetime the controller can end (the retention sweep disposes it) while
///    a widget may still hold the object and, one frame later, remove its
///    listener. `ChangeNotifier` asserts on that; here it is a no-op, which is
///    exactly the `_disposed` guard shape `AppState` already uses for the
///    callbacks it hands out (app_state.dart:1081-1083).
///  * a write path that silently drops a post-dispose transition instead of
///    tripping `debugAssertNotDisposed` from an unawaited continuation.
class PayloadStateNotifier extends ValueNotifier<PayloadState> {
  PayloadStateNotifier(super.value);

  bool _disposed = false;

  @visibleForTesting
  bool get isDisposed => _disposed;

  /// Writes [next] unless this notifier has been disposed. Returns true when
  /// the value actually changed.
  bool trySetValue(PayloadState next) {
    if (_disposed) return false;
    if (value == next) return false;
    value = next;
    return true;
  }

  @override
  void addListener(VoidCallback listener) {
    if (_disposed) return;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    if (_disposed) return;
    super.removeListener(listener);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}
