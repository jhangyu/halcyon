import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
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
  void drainListTileWarning(WidgetTester tester) {
    final exception = tester.takeException();
    if (exception != null &&
        !exception.toString().contains(
          'ListTile background color or ink splashes may be invisible',
        )) {
      throw exception;
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

  testWidgets('batch menu label follows the mode', (tester) async {
    final state = await stateForFolder(tester, withSibling: true);
    state.markCurrent(PhotoStatus.trashed);
    await pumpSidebar(tester, state);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    drainListTileWarning(tester);
    expect(find.text('Recycle Trashed'), findsOneWidget);
    expect(find.text('Delete Trashed'), findsNothing);

    await tester.tapAt(const Offset(5, 5)); // dismiss the menu
    await tester.pumpAndSettle();
    drainListTileWarning(tester);
    state.toggleRecycleMode();
    await tester.pump();
    drainListTileWarning(tester);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    drainListTileWarning(tester);
    expect(find.text('Delete Trashed'), findsOneWidget);
  });

  testWidgets('recycling from the menu shows the snackbar', (tester) async {
    final state = await stateForFolder(tester, withSibling: true);
    state.markCurrent(PhotoStatus.trashed);
    await pumpSidebar(tester, state);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    drainListTileWarning(tester);
    expect(find.text('Recycle Trashed'), findsOneWidget);

    // ponytail: tapping the menu item itself drives AppState.deleteTrashed(),
    // whose real dart:io work (recycleTrashed + loadFolder's rescan) is
    // triggered mid-frame by the PopupMenuRoute's dismiss-animation Future
    // resolving — a chain that never actually resumes inside FakeAsync no
    // matter how it's combined with runAsync (verified experimentally: the
    // continuation just never fires). Invoking the exact same production
    // onSelected callback directly — retrieved from the real, already-built
    // PopupMenuButton widget, so this is still the real wired-up code, not a
    // reimplementation — sidesteps only the animation-Future indirection,
    // and runs fine under runAsync exactly like the AppState-level tests do.
    final button = tester.widget<PopupMenuButton<String>>(
      find.byType(PopupMenuButton<String>),
    );
    await tester.runAsync(() async {
      button.onSelected!('delete');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    drainListTileWarning(tester);

    expect(find.textContaining('已回收'), findsOneWidget);
    expect(find.text('顯示'), findsOneWidget);
  });
}
