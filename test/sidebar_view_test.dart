import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/native_thumbnail_service.dart';
import 'package:halcyon_flutter/views/sidebar_view.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// A minimal valid 1x1 transparent PNG (same fixture as
// image_preload_controller_test.dart) — the sidebar renders thumbnail bytes
// through Image.memory, and this test's later assertion needs a real
// engine decode of the reloaded folder's items to actually resolve, unlike
// other widget tests here that never let a thumbnail decode complete.
final _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAA'
  'AAYAAjCB0C8AAAAASUVORK5CYII=',
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // ponytail: sidebar_view.dart's pre-existing selected-row Container wraps
  // ListTile in a ColoredBox, which trips a Flutter-framework debug
  // assertion ("ListTile background color or ink splashes may be
  // invisible") — purely cosmetic, unrelated to recycle mode, and fires on
  // every frame a selected row paints. flutter_test fails a test that has
  // an un-acknowledged framework exception, so drain it via
  // tester.takeException() after each pump that could have triggered it.
  // One warning per painted row, so drain until empty rather than once.
  void drainListTileWarning(WidgetTester tester) {
    for (var exception = tester.takeException(); exception != null; ) {
      if (!exception.toString().contains(
        'ListTile background color or ink splashes may be invisible',
      )) {
        throw exception;
      }
      exception = tester.takeException();
    }
  }

  // ponytail: testWidgets bodies run inside a FakeAsync zone, so real
  // dart:io work (temp dir + file writes + AppState.loadFolder's real
  // Directory scan) never completes unless it runs via tester.runAsync —
  // otherwise the test hangs until the suite timeout. Matches the pattern
  // established in test/photo_action_bar_test.dart.
  Future<AppState> stateForFolder(
    WidgetTester tester, {
    required bool withSibling,
  }) async {
    late AppState state;
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('halcyon_sidebar_');
      addTearDown(() => dir.delete(recursive: true));
      await File(p.join(dir.path, 'IMG_0001.jpg')).writeAsBytes([1, 2, 3]);
      if (withSibling) {
        await File(p.join(dir.path, 'IMG_0001.dng')).writeAsBytes([1, 2, 3]);
      }
      state = AppState(
        thumbnailLoader: (path, {required purpose}) async {
          return NativeImageBytes(Uint8List.fromList(_tinyPngBytes));
        },
      );
      await state.loadFolder(dir);
    });
    return state;
  }

  Future<void> pumpSidebar(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(
          home: Scaffold(body: SizedBox(width: 320, child: SidebarView())),
        ),
      ),
    );
    await tester.pump();
    drainListTileWarning(tester);
  }

  testWidgets('trashed status icon follows the mode', (tester) async {
    final state = await stateForFolder(tester, withSibling: true);
    state.markCurrent(PhotoStatus.trashed);
    await pumpSidebar(tester, state);

    expect(find.byIcon(Icons.restore_from_trash), findsOneWidget);

    state.toggleRecycleMode();
    await tester.pump();
    drainListTileWarning(tester);

    expect(find.byIcon(Icons.delete), findsOneWidget);
    expect(find.byIcon(Icons.restore_from_trash), findsNothing);
  });

  testWidgets(
    'invoking onSelected with the shared constant reaches the export path',
    (tester) async {
      // getDirectoryPath (file_selector) goes through
      // 'plugins.flutter.io/file_selector' — mock it to return a real temp
      // dir so the whole onSelected -> exportStarredThumbnails routing runs
      // for real and is observable via the status line.
      late Directory exportDest;
      const channel = MethodChannel('plugins.flutter.io/file_selector');
      // AppState's default ThumbnailExportService fetches bytes through the
      // real 'halcyon/thumbnail' platform channel (it is not wired to the
      // stateForFolder helper's injected thumbnailLoader, which only feeds
      // ImagePreloadController) — mock it too so exportStarredThumbnails
      // actually writes a file instead of recording a failure.
      const thumbnailChannel = MethodChannel('halcyon/thumbnail');
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(thumbnailChannel, null);
      });

      final state = await stateForFolder(tester, withSibling: false);
      state.markCurrent(PhotoStatus.starred);
      await pumpSidebar(tester, state);

      await tester.runAsync(() async {
        exportDest = await Directory.systemTemp.createTemp(
          'halcyon_sidebar_export_',
        );
      });
      addTearDown(() => exportDest.delete(recursive: true));

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getDirectoryPath') return exportDest.path;
            return null;
          });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(thumbnailChannel, (call) async {
            if (call.method == 'getThumbnail') {
              return Uint8List.fromList(_tinyPngBytes);
            }
            return null;
          });

      // ponytail: tapping the menu item hangs under FakeAsync in this
      // codebase (see the recycle test above) — invoke the real, already
      // wired-up onSelected callback directly instead.
      final button = tester.widget<PopupMenuButton<String>>(
        find.byType(PopupMenuButton<String>),
      );

      await tester.runAsync(() async {
        button.onSelected!(kThumbnailStarredMenuValue);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
      drainListTileWarning(tester);

      expect(state.status?.text, contains('已匯出'));
      expect(state.status?.revealPath, exportDest.path);
      final outFile = File(p.join(exportDest.path, 'IMG_0001.jpg'));
      expect(outFile.existsSync(), isTrue);
    },
  );
}
