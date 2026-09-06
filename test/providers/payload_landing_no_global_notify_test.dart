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

      final state = AppState(
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
      );
      addTearDown(state.dispose);

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

      var appNotifications = 0;
      state.addListener(() => appNotifications++);
      var itemNotifications = 0;
      state.payloadStateFor('IMG_0002').addListener(() {
        itemNotifications++;
      });

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
