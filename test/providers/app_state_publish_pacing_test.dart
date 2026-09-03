// AC1 (docs/logs/2026-09-03/decode-jank-remediation-contract.md): the
// production construction of ImagePreloadController injects an idle-priority
// frame hook AND the compositing gate, both from one app-owned scheduler.
// TC-904 / TC-905 / TC-906.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // TC-904
  test('the production controller is built with idle publish pacing', () {
    final state = AppState();
    addTearDown(state.dispose);

    expect(
      state.debugPublishPacingWired,
      isTrue,
      reason: 'AC1: production must inject both the frame hook and the gate',
    );
  });

  // TC-905 -- an injected controller already chose its own seams.
  test('an injected controller is left un-rewired', () {
    final injected = ImagePreloadController(
      imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
          NativeImageBytes(Uint8List.fromList([137, 80, 78, 71])),
    );
    final state = AppState(preloadController: injected);
    addTearDown(state.dispose);

    expect(injected.debugPacerHasFrameHook, isFalse);
    expect(injected.debugCompositeGateIsPaced, isFalse);
  });

  // TC-906 -- ordering matters: the controller tears down first, then the
  // scheduler flushes whatever is left. The reverse would flush publishes
  // into a disposed controller.
  test('dispose disposes the publish scheduler after the controller', () {
    final state = AppState();
    final scheduler = state.debugPublishScheduler;

    var ran = 0;
    scheduler.schedule(() => ran++);
    expect(ran, 0);

    state.dispose();
    expect(ran, 1, reason: 'dispose flushes pending slots, it does not drop them');
    expect(scheduler.debugPendingCount, 0);
  });
}
