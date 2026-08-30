import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/models/shortcut_bindings.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/views/main_screen.dart';

import '../support/temp_dirs.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// Seeds a real two-item folder (mirrors `main_detail_view_test.dart`'s
  /// TC-230 pattern: real I/O runs inside `tester.runAsync`, a never-completing
  /// loader keeps the pipeline from racing a real decode into the picture).
  Future<AppState> seededState(WidgetTester tester) async {
    late AppState state;
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('halcyon_mss_');
      addTempDirTeardown(dir);
      await File('${dir.path}/IMG_0001.jpg').writeAsBytes(<int>[1, 2, 3]);
      await File('${dir.path}/IMG_0002.jpg').writeAsBytes(<int>[4, 5, 6]);

      state = AppState(
        imageLoader: (path, {required purpose}) =>
            Completer<NativeImageResult>().future,
      );
      addTearDown(state.dispose);
      await state.loadFolder(dir);
    });
    return state;
  }

  Future<void> pumpMainScreen(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const MainScreen(),
        ),
      ),
    );
    // Flush the sidebar's thumbnail-preload timer and the tier-2 navigation
    // debounce (250ms) so no FakeAsync timer is left pending at teardown --
    // the imageLoader never resolves (Completer that's never completed), so
    // these timers fire and no-op rather than looping.
    await tester.pump(const Duration(seconds: 6));
  }

  testWidgets(
      'TC-453 the seven default bindings drive the same actions as before',
      (tester) async {
    final state = await seededState(tester);
    await pumpMainScreen(tester, state);

    final firstId = state.selectedItemID;
    expect(firstId, isNotNull);

    // nextPhoto (arrowRight)
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(seconds: 6));
    final secondId = state.selectedItemID;
    expect(secondId, isNot(firstId));

    // previousPhoto (arrowLeft)
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(const Duration(seconds: 6));
    expect(state.selectedItemID, firstId);

    // starPhoto (keyS)
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.pump(const Duration(seconds: 6));
    expect(state.currentItem?.status, PhotoStatus.starred);

    // trashMarkPhoto (keyX) -- toggles unmarked -> trashed since it was
    // starred, not trashed, so this is a genuine transition.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pump(const Duration(seconds: 6));
    expect(state.currentItem?.status, PhotoStatus.trashed);

    // toggleRecycleMode (keyR)
    final recycleBefore = state.recycleMode;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pump(const Duration(seconds: 6));
    expect(state.recycleMode, !recycleBefore);

    // zoomIn / zoomOut (arrowUp / arrowDown) -- MainScreen owns the
    // ZoomController privately, so assert only that the keys are consumed
    // (handled) rather than falling through to the next photo/mark actions.
    final beforeZoomId = state.selectedItemID;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump(const Duration(seconds: 6));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(seconds: 6));
    expect(state.selectedItemID, beforeZoomId,
        reason: 'zoom keys must not also navigate');
  });

  testWidgets('TC-454 a rebound key wins and the old key goes dead',
      (tester) async {
    final state = await seededState(tester);
    state.setShortcutBinding(ShortcutAction.nextPhoto, LogicalKeyboardKey.keyD);
    await pumpMainScreen(tester, state);

    final before = state.selectedItemID;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(seconds: 6));
    expect(state.selectedItemID, before, reason: 'old binding is dead');

    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    await tester.pump(const Duration(seconds: 6));
    expect(state.selectedItemID, isNot(before));
  });

  testWidgets('TC-455 a duplicated key fires only the earlier-declared action',
      (tester) async {
    final state = await seededState(tester);
    state.setShortcutBinding(
        ShortcutAction.toggleRecycleMode, LogicalKeyboardKey.keyX);
    await pumpMainScreen(tester, state);

    final recycleBefore = state.recycleMode;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pump(const Duration(seconds: 6));

    expect(state.currentItem?.status, PhotoStatus.trashed);
    expect(state.recycleMode, recycleBefore,
        reason: 'later action must not also fire');
  });
}
