import 'providers/app_state.dart';
import 'services/image_pipeline/memory_pressure_responder.dart';
import 'services/platform/memory_pressure_monitor.dart';

/// Composition-layer wiring for the operating-system memory-pressure response
/// (WP4.4 / spec S3.4).
///
/// Lives at the `lib/` root, above `views/ -> providers/ -> services/`, because
/// it is the one piece that has to know about BOTH a provider (`AppState`) and
/// a service (`MemoryPressureResponder`). Putting the adapter in the service
/// layer would have made a service import a provider and inverted the layering;
/// putting it in `main.dart` would have grown a file several packages are
/// editing at once. Neither is worth it for twenty lines.
class AppStateMemoryPressureTarget implements MemoryPressureTarget {
  AppStateMemoryPressureTarget(this._appState);

  final AppState _appState;

  @override
  int get calmPayloadByteBudget => _appState.derivedPayloadByteBudget;

  @override
  void setPayloadByteBudget(int bytes) =>
      _appState.setPayloadByteBudgetOverride(bytes);

  @override
  void restorePayloadByteBudget() =>
      _appState.setPayloadByteBudgetOverride(null);

  @override
  void dropFarBandTierTwoPixels() => _appState.dropBeyondBandTierTwoPixels();
}

/// Starts listening for pressure and wires the response to [appState].
///
/// Returns the responder so a caller that outlives the app (tests) can dispose
/// it; `main` deliberately drops it, because its lifetime IS the process's.
MemoryPressureResponder startMemoryPressureResponse(AppState appState) {
  final monitor = MemoryPressureMonitor()..startListening();
  final responder = MemoryPressureResponder(
    monitor: monitor,
    target: AppStateMemoryPressureTarget(appState),
  )..start();
  return responder;
}
