import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/memory_pressure_wiring.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/retention_policy.dart';
import 'package:halcyon_flutter/services/platform/memory_pressure_monitor.dart';

/// TC-1172..TC-1174 (WP4.4 / S3.4): the PRODUCTION wiring, not the interface.
///
/// The responder tests prove the policy against a hand-built target. These
/// prove the target the app actually runs: a real [AppState] with a real
/// `ImagePreloadController` and a real payload cache behind it. Without this
/// file, an adapter that delegated to the wrong member — or a passthrough that
/// silently did nothing — would pass every other test in the suite.
///
/// The in-force budget is read from `debugMemoryLedgerSnapshot`, whose
/// `retainedPayloadByteBudget` is the cache's LIVE ceiling
/// (`image_preload_controller.dart:642`), not the retention tier's nominal
/// number. Asserting on the nominal one would be an assertion that cannot fail.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AppState buildAppState() => AppState.forTesting(runtimeCapabilities: const {});

  int inForceBudget(AppState appState) =>
      // ignore: invalid_use_of_visible_for_testing_member
      appState.debugMemoryLedgerSnapshot.retainedPayloadByteBudget;

  test('TC-1172 the adapter reads the derived budget the pipeline owns', () {
    final appState = buildAppState();
    final target = AppStateMemoryPressureTarget(appState);
    expect(target.calmPayloadByteBudget, appState.derivedPayloadByteBudget);
    expect(target.calmPayloadByteBudget, greaterThan(0));
    // Calm: derived and in-force agree, so a later divergence means an override.
    expect(inForceBudget(appState), target.calmPayloadByteBudget);
  });

  test('TC-1173 shrink then restore moves the REAL in-force budget', () {
    final appState = buildAppState();
    final target = AppStateMemoryPressureTarget(appState);
    final derived = target.calmPayloadByteBudget;

    target.setPayloadByteBudget(derived ~/ 2);
    expect(inForceBudget(appState), derived ~/ 2);
    // The derived number must NOT move when an override is installed: if it
    // did, the next shrink would halve an already-halved value.
    expect(appState.derivedPayloadByteBudget, derived);

    target.restorePayloadByteBudget();
    expect(inForceBudget(appState), derived);
  });

  test('TC-1174 a pressure push halves the real pipeline budget end to end',
      () async {
    final appState = buildAppState();
    final derived = appState.derivedPayloadByteBudget;
    startMemoryPressureResponse(appState);
    expect(inForceBudget(appState), derived, reason: 'calm before the push');

    // Exactly what the native side sends, over the real channel.
    const codec = StandardMethodCodec();
    Future<void> push(String level) async {
      await TestDefaultBinaryMessengerBinding
          .instance
          .defaultBinaryMessenger
          .handlePlatformMessage(
            MemoryPressureMonitor.channelName,
            codec.encodeMethodCall(
              MethodCall(MemoryPressureMonitor.methodName, level),
            ),
            (_) {},
          );
      await Future<void>.delayed(Duration.zero);
    }

    // channel -> monitor -> responder -> adapter -> AppState -> controller.
    await push('warning');
    expect(inForceBudget(appState), derived ~/ 2);

    await push('normal');
    expect(inForceBudget(appState), derived);
  });

  test('TC-1175 a retention tier change under pressure keeps the override',
      () async {
    // Written against the tree BEFORE the fix exists, and expected to FAIL on
    // the live defect: `setRetention` (image_preload_controller.dart:272-276)
    // pushes the tier's budget to the cache unconditionally, wiping an active
    // pressure override. Nothing re-applies it -- MemoryPressureResponder acts
    // on level CHANGES, and the level has not changed -- so the app would sit
    // at the full budget while the machine is still under memory pressure,
    // silently, which is the exact failure S3.4 exists to prevent.
    final appState = buildAppState();
    startMemoryPressureResponse(appState);

    const codec = StandardMethodCodec();
    await TestDefaultBinaryMessengerBinding
        .instance
        .defaultBinaryMessenger
        .handlePlatformMessage(
          MemoryPressureMonitor.channelName,
          codec.encodeMethodCall(
            const MethodCall(MemoryPressureMonitor.methodName, 'warning'),
          ),
          (_) {},
        );
    await Future<void>.delayed(Duration.zero);

    final shrunk = inForceBudget(appState);
    expect(shrunk, appState.derivedPayloadByteBudget ~/ 2,
        reason: 'precondition: the pressure override is installed');

    // The user steps the retention tier while pressure is still active. The
    // tier MAY change what is derived; it must not cancel the override.
    appState.setRetentionTier(RetentionTier.generous);

    // Deliberately NOT asserting an exact number. Two fix shapes are both
    // defensible -- keep the installed byte value, or re-derive half of the NEW
    // tier -- and pinning one here would dictate the fix's shape from a test
    // that exists to pin its EFFECT. What must hold either way: pressure is
    // still in force, i.e. the budget is below what the new tier would give.
    expect(
      inForceBudget(appState),
      lessThan(appState.derivedPayloadByteBudget),
      reason: 'the override must survive a retention change; the full tier '
          'budget while still under pressure is the defect',
    );
  });
}
