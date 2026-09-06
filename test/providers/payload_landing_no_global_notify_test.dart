import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/preload_fixtures.dart';
import '../support/temp_dirs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'TC-1014: a payload landing wakes the item, not the whole app',
    () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_notify_');
      addTempDirTeardown(dir);
      await File('${dir.path}/IMG_0001.jpg').writeAsBytes([0]);
      await File('${dir.path}/IMG_0002.jpg').writeAsBytes([0]);

      // ARMING-WINDOW HARDENING (2026-09-06, task #12). The old version armed
      // its counters and then RACED the landing against three unrelated
      // whole-app notifies that were already in flight or scheduled:
      // AppState._initPrefs (app_state.dart:400), resolveExportCapabilities
      // (:559) and — the decisive one — _readSelectionExif (:1323), which
      // `selectItem` schedules on a FIXED 250ms debounce. Under full-suite CPU
      // contention the landing outlasted that 250ms, the EXIF caption notify
      // fell inside the window, and this test reported "Expected <0> Actual
      // <1>" against a landing path that had not notified at all. Evidence:
      // docs/logs/2026-09-06/tc1014-rootcause.txt.
      //
      // The fix removes the race instead of tolerating it: IMG_0002's bytes
      // are held behind `landingGate`, so the landing CANNOT happen until this
      // test releases it. That lets the test first wait for every unrelated
      // notify source to go quiet, and only then arm the counters — so the
      // measured window contains the landing and nothing else. The assertion
      // itself is unchanged: zero global notifies across the landing.
      final landingGate = Completer<void>();
      final state = AppState(
        imageLoader: (path, {required purpose, int? targetLongEdge}) async {
          if (path.contains('IMG_0002')) await landingGate.future;
          return NativeImageBytes(Uint8List.fromList(tinyPngBytes));
        },
      );
      addTearDown(state.dispose);
      // A gate that is never released would hang the run at the `until`
      // deadline rather than failing cleanly; release it unconditionally at
      // teardown.
      addTearDown(() {
        if (!landingGate.isCompleted) landingGate.complete();
      });

      await state.loadFolder(dir);
      expect(state.selectedItemID, 'IMG_0001');

      // Settle the initial selection's own landing before arming the
      // counters, so the test measures the SECOND item's landing, not the
      // first item's or the selection itself.
      await until(
        () => state.payloadStateFor('IMG_0001').value.stage !=
            PayloadStage.absent,
        reason: 'the initial preload pass to land',
      );

      // Select the second item first, so its OWN synchronous
      // `notifyListeners()` (an unrelated selection-change notify, not a
      // landing notify) fires before the counters below are armed. Only then
      // does its payload land asynchronously.
      state.selectItem('IMG_0002');

      // Wait for every unrelated whole-app notify source to go quiet before
      // arming. The quiet period must exceed kSelectionExifDebounce (250ms),
      // which `selectItem` above has just armed; the loop also covers the
      // startup hydration notifies, whose latency is unbounded under load.
      var lastNotifyAt = DateTime.now();
      void settleWatcher() => lastNotifyAt = DateTime.now();
      state.addListener(settleWatcher);
      await until(
        () =>
            DateTime.now().difference(lastNotifyAt) >
            const Duration(milliseconds: 600),
        reason: 'unrelated whole-app notifies (selection EXIF, prefs '
            'hydration, capability probe) to go quiet before arming',
      );
      state.removeListener(settleWatcher);

      var appNotifications = 0;
      state.addListener(() => appNotifications++);
      var itemNotifications = 0;
      state.payloadStateFor('IMG_0002').addListener(() {
        itemNotifications++;
      });

      // Only now is the landing allowed to happen, entirely inside the armed
      // window.
      landingGate.complete();

      await until(
        () => itemNotifications > 0,
        reason: 'the item to be woken by its own payload landing',
      );

      expect(
        appNotifications,
        0,
        reason:
            'the payload-landing path must no longer notify every '
            'context.watch<AppState>() consumer in the app',
      );
    },
  );
}
