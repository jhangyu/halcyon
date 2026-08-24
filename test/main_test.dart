import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/main.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_source_types.dart';
import 'package:halcyon_flutter/views/main_screen.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Drives the real desktop_drop platform channel (ported from the reviewer
// probe at scripts/tmp/m6-r2-verify/drop_enable_probe_test.dart, task #6 of
// the M6 P4 round) so drop tests assert on BEHAVIOUR -- a file actually
// reaching AppState -- not just that DropTarget.onDragDone is non-null or
// that its `enable` flag flips.
const _dropCodec = StandardMethodCodec();

Future<void> _pushDropEvent(String method, Object? args) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    'desktop_drop',
    _dropCodec.encodeMethodCall(MethodCall(method, args)),
    (_) {},
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'configureImageCache raises ImageCache.maximumSizeBytes to 768 MiB '
    '(default 100MB only fits ~1 full-frame decode)',
    (tester) async {
      configureImageCache();
      expect(
        PaintingBinding.instance.imageCache.maximumSizeBytes,
        805306368,
        reason:
            '768 MiB pinned as a RAW BYTE COUNT on purpose: the round-1 record '
            'lost time to MB-vs-MiB drift, and 768 decimal MB (768000000) is a '
            'different number that would still look right in a review',
      );
    },
  );

  // ponytail: same FakeAsync-hang avoidance as photo_action_bar_test.dart —
  // real dart:io folder scan must run via tester.runAsync.
  Future<AppState> stateForFolder(WidgetTester tester) async {
    late AppState state;
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('halcyon_main_');
      addTearDown(() => dir.delete(recursive: true));
      await File(p.join(dir.path, 'IMG_0001.jpg')).writeAsBytes([1, 2, 3]);
      state = AppState(
        thumbnailLoader: (path, {required purpose}) async {
          return NativeImageBytes(Uint8List.fromList([1, 2, 3]));
        },
      );
      await state.loadFolder(dir);
    });
    return state;
  }

  Widget harness(AppState state) {
    return ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: MainScreen()),
    );
  }

  testWidgets(
    'main screen accepts file drops through DropTarget and loads the '
    "dropped file's folder",
    (tester) async {
      final state = await stateForFolder(tester);
      await tester.pumpWidget(harness(state));

      final drop = find.byType(DropTarget);
      expect(drop, findsOneWidget);
      final widget = tester.widget<DropTarget>(drop);
      expect(widget.onDragDone, isNotNull);

      late Directory dropSrc;
      await tester.runAsync(() async {
        dropSrc = await Directory.systemTemp.createTemp('halcyon_maindrop_');
        addTearDown(() => dropSrc.delete(recursive: true));
        await File(
          p.join(dropSrc.path, 'IMG_0042.jpg'),
        ).writeAsBytes([1, 2, 3]);
      });
      final droppedPath = p.join(dropSrc.path, 'IMG_0042.jpg');

      // Fire a real drop through the desktop_drop platform channel, not a
      // direct call to onDragDone -- this is the path an actual OS-level
      // drag-and-drop exercises.
      await tester.runAsync(() async {
        await _pushDropEvent('entered', <double>[10, 10]);
        await _pushDropEvent('performOperation', <String>[droppedPath]);
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pump();

      expect(state.currentDir?.path, dropSrc.path);
      expect(state.selectedItemID, 'IMG_0042');
    },
  );

  testWidgets('R key toggles recycle mode', (tester) async {
    final state = await stateForFolder(tester);
    await tester.pumpWidget(harness(state));
    await tester.pump();

    final before = state.recycleMode;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pump();

    expect(state.recycleMode, !before);
  });

  testWidgets(
    'DropTarget is disabled while a dialog route is on top, and a real '
    'drop is ignored -- then re-armed once the dialog closes',
    (tester) async {
      late AppState state;
      late Directory originalEmptyDir;
      late Directory dropSrc;
      await tester.runAsync(() async {
        originalEmptyDir = await Directory.systemTemp.createTemp(
          'halcyon_maindrop_modal_empty_',
        );
        dropSrc = await Directory.systemTemp.createTemp(
          'halcyon_maindrop_modal_src_',
        );
        addTearDown(() => originalEmptyDir.delete(recursive: true));
        addTearDown(() => dropSrc.delete(recursive: true));
        await File(
          p.join(dropSrc.path, 'IMG_0099.jpg'),
        ).writeAsBytes([1, 2, 3]);
        state = AppState(
          thumbnailLoader: (path, {required purpose}) async =>
              NativeImageBytes(Uint8List.fromList([1, 2, 3])),
        );
        await state.loadFolder(originalEmptyDir);
      });
      final originalDir = state.currentDir?.path;
      await tester.pumpWidget(harness(state));
      await tester.pump();

      expect(
        tester.widget<DropTarget>(find.byType(DropTarget)).enable,
        isTrue,
      );

      final droppedPath = p.join(dropSrc.path, 'IMG_0099.jpg');

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push(
          DialogRoute<void>(
            context: navigator.context,
            builder: (_) => const AlertDialog(title: Text('Rename')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        tester.widget<DropTarget>(find.byType(DropTarget)).enable,
        isFalse,
      );

      // Drive a real drop while the dialog is on top: it must be ignored --
      // the folder must NOT change.
      await tester.runAsync(() async {
        await _pushDropEvent('entered', <double>[10, 10]);
        await _pushDropEvent('performOperation', <String>[droppedPath]);
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pump();
      expect(state.currentDir?.path, originalDir);

      // Close the dialog: the drop target must be re-armed and a fresh drop
      // must now succeed.
      navigator.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.runAsync(() async {
        await _pushDropEvent('entered', <double>[10, 10]);
        await _pushDropEvent('performOperation', <String>[droppedPath]);
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pump();

      expect(state.currentDir?.path, dropSrc.path);
      expect(state.selectedItemID, 'IMG_0099');
    },
  );
}
