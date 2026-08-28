import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/temp_dirs.dart';
import 'package:halcyon_flutter/main.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/views/main_screen.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  testWidgets(
    'TC-320: configureImageCache derives the budget from a supplied reading',
    (tester) async {
      configureImageCache(physicalMemoryBytes: 2 * 1024 * 1024 * 1024);
      expect(
        PaintingBinding.instance.imageCache.maximumSizeBytes,
        536870912,
        reason: '2 GiB / 4 = 512 MiB, above the 256 MiB floor',
      );

      configureImageCache();
      expect(
        PaintingBinding.instance.imageCache.maximumSizeBytes,
        805306368,
        reason: 'no reading still means the 768 MiB ceiling',
      );
    },
  );

  // ponytail: same FakeAsync-hang avoidance as photo_action_bar_test.dart —
  // real dart:io folder scan must run via tester.runAsync.
  Future<AppState> stateForFolder(WidgetTester tester) async {
    late AppState state;
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('halcyon_main_');
      addTempDirTeardown(dir);
      await File(p.join(dir.path, 'IMG_0001.jpg')).writeAsBytes([1, 2, 3]);
      state = AppState(
        imageLoader: (path, {required purpose}) async {
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

  testWidgets('main screen accepts file drops through DropTarget', (
    tester,
  ) async {
    final state = await stateForFolder(tester);
    await tester.pumpWidget(harness(state));

    final drop = find.byType(DropTarget);
    expect(drop, findsOneWidget);
    final widget = tester.widget<DropTarget>(drop);
    expect(widget.onDragDone, isNotNull);
  });

  testWidgets('R key toggles recycle mode', (tester) async {
    final state = await stateForFolder(tester);
    await tester.pumpWidget(harness(state));
    await tester.pump();

    final before = state.recycleMode;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pump();

    expect(state.recycleMode, !before);
  });

  testWidgets('HalcyonApp renders empty-folder prompt', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState(),
        child: const HalcyonApp(),
      ),
    );

    expect(find.text('Select a folder to begin'), findsOneWidget);
    expect(find.text('Open Folder'), findsOneWidget);
  });

  testWidgets('DropTarget is disabled while a dialog route is on top', (
    tester,
  ) async {
    final state = await stateForFolder(tester);
    await tester.pumpWidget(harness(state));
    await tester.pump();

    expect(tester.widget<DropTarget>(find.byType(DropTarget)).enable, isTrue);

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
  });
}
