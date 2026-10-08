// Shared fixtures for the mouse-click navigation tests: a loaded AppState
// over IMG_0001..IMG_000<count>.jpg, and a mouse click with explicit
// time stamps (TestGesture defaults every stamp to zero).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';

import 'preload_fixtures.dart' show tinyPngBytes, until;
import 'temp_dirs.dart';

/// Loads a folder of [count] decodable photos and selects [select].
Future<AppState> loadMouseNavState(
  WidgetTester tester, {
  int count = 4,
  String select = 'IMG_0002',
  NativeImageLoad? imageLoader,
  bool waitForFullSize = true,
}) async {
  assert(count <= 9, 'single-digit file names');
  late AppState state;
  await tester.runAsync(() async {
    final dir = await makeTempDir('halcyon_mousenav_');
    for (var i = 1; i <= count; i++) {
      await File('${dir.path}/IMG_000$i.jpg').writeAsBytes(tinyPngBytes);
    }
    state = AppState(
      imageLoader: imageLoader ??
          (path, {required purpose, int? targetLongEdge}) async =>
              NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
    );
    addTearDown(state.dispose);
    await state.loadFolder(dir);
    state.selectItem(select);
    if (waitForFullSize) {
      await until(() => state.currentItemHasFullSize,
          reason: 'the selected photo to reach full resolution');
    }
  });
  return state;
}

/// One press at [at] held for [hold]; [travel] is applied half-way through
/// the hold and the release happens there.
Future<void> mouseClick(
  WidgetTester tester,
  Offset at, {
  int buttons = kPrimaryButton,
  PointerDeviceKind kind = PointerDeviceKind.mouse,
  Duration hold = const Duration(milliseconds: 50),
  Offset travel = Offset.zero,
}) async {
  final g = await tester.startGesture(at, kind: kind, buttons: buttons);
  if (travel != Offset.zero) {
    await g.moveBy(travel, timeStamp: hold ~/ 2);
  }
  await g.up(timeStamp: hold);
  await tester.pump();
}
