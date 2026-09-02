import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/platform/working_set_trim.dart';
import 'package:shared_preferences/shared_preferences.dart';

AppState _testState() {
  return AppState(
    imageLoader: (path, {required purpose, int? targetLongEdge}) async {
      return NativeImageBytes(Uint8List.fromList(<int>[1, 2, 3]));
    },
  );
}

Future<void> _touch(Directory dir, String name) async {
  await File('${dir.path}${Platform.pathSeparator}$name').writeAsBytes(
    Uint8List.fromList(<int>[1, 2, 3]),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WorkingSetTrim.debugReset();
    // Long enough that no armed timer can fire during a test and leak into
    // the next one; debugReset() in tearDown cancels it regardless.
    WorkingSetTrim.idleDelay = const Duration(minutes: 5);
  });
  tearDown(WorkingSetTrim.debugReset);

  // TC-492
  test('loadFolder trims immediately, exactly once', () async {
    final dir = await Directory.systemTemp.createTemp('halcyon_wst_load_');
    addTearDown(() async => dir.delete(recursive: true));
    await _touch(dir, 'IMG_0001.jpg');
    await _touch(dir, 'IMG_0002.jpg');

    final state = _testState();
    addTearDown(state.dispose);
    await state.loadFolder(dir);

    expect(WorkingSetTrim.debugTrimNowCalls, 1);
  });

  // TC-493
  test('selectItem defers its trim instead of running it inline', () async {
    final dir = await Directory.systemTemp.createTemp('halcyon_wst_select_');
    addTearDown(() async => dir.delete(recursive: true));
    await _touch(dir, 'IMG_0001.jpg');
    await _touch(dir, 'IMG_0002.jpg');

    final state = _testState();
    addTearDown(state.dispose);
    await state.loadFolder(dir);

    final requestsAfterLoad = WorkingSetTrim.debugRequestCalls;
    final attemptsAfterLoad = WorkingSetTrim.debugTrimAttempts;
    state.selectItem('IMG_0002');

    expect(
      WorkingSetTrim.debugRequestCalls,
      requestsAfterLoad + 1,
      reason: 'selectItem must arm a deferred trim',
    );
    expect(
      WorkingSetTrim.debugTrimAttempts,
      attemptsAfterLoad,
      reason: 'nothing may trim on the navigation hot path',
    );
  });
}
