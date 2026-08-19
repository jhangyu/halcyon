import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_preload_controller.dart';
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

  // Regression: recycling/deleting reloads the folder, which resets the
  // thumbnail cache. The sidebar used to re-request thumbnails only from its
  // scroll listener, so a list scrolled away from the top came back blank and
  // stayed blank until the user scrolled. Requests are now driven by
  // itemBuilder, so every row that paints must have been asked for.
  testWidgets('every visible row is requested again after a folder reload', (
    tester,
  ) async {
    late Directory dir;
    late AppState state;
    final requested = <String>[];

    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('halcyon_sidebar_reload_');
      addTearDown(() => dir.delete(recursive: true));
      for (var i = 1; i <= 60; i++) {
        final name = 'IMG_${i.toString().padLeft(4, '0')}.jpg';
        await File(p.join(dir.path, name)).writeAsBytes([1, 2, 3]);
      }
      state = AppState(
        thumbnailLoader: (path, {required purpose}) async {
          if (purpose == ImageRequestPurpose.sidebarThumbnail) {
            requested.add(p.basenameWithoutExtension(path));
          }
          return NativeImageBytes(Uint8List.fromList(_tinyPngBytes));
        },
      );
      await state.loadFolder(dir);
    });

    await pumpSidebar(tester, state);
    // Scroll well away from the top — the old bug only showed up here.
    await tester.drag(find.byType(ListView), const Offset(0, -1500));
    await tester.pump(const Duration(milliseconds: 200));
    drainListTileWarning(tester);

    requested.clear();
    await tester.runAsync(() => state.loadFolder(dir));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    drainListTileWarning(tester);

    final visibleNames = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((tile) => (tile.title! as Text).data!)
        .toList();
    expect(visibleNames, isNotEmpty);
    expect(requested, containsAll(visibleNames));
  });

  // Regression: a tall sidebar shows more rows than the prefetch margin. While
  // scrolling, itemBuilder runs only for the rows that just came into range,
  // so reporting "what was built this frame" as the visible range shrank it to
  // the leading edge — and the controller then evicted, and immediately
  // re-fetched, thumbnails still on screen at the trailing edge. Visible as a
  // flicker of the last few rows; mechanically visible as a second request for
  // an id that was already cached.
  testWidgets('scrolling never re-requests a thumbnail it already fetched', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppState state;
    final requested = <String>[];

    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('halcyon_sidebar_scr_');
      addTearDown(() => dir.delete(recursive: true));
      for (var i = 1; i <= 80; i++) {
        final name = 'IMG_${i.toString().padLeft(4, '0')}.jpg';
        await File(p.join(dir.path, name)).writeAsBytes([1, 2, 3]);
      }
      state = AppState(
        thumbnailLoader: (path, {required purpose}) async {
          if (purpose == ImageRequestPurpose.sidebarThumbnail) {
            requested.add(p.basenameWithoutExtension(path));
          }
          return NativeImageBytes(Uint8List.fromList(_tinyPngBytes));
        },
      );
      await state.loadFolder(dir);
    });

    await pumpSidebar(tester, state);
    await tester.pump(const Duration(milliseconds: 200));
    drainListTileWarning(tester);
    // More rows on screen than the controller's prefetch margin — otherwise
    // the shrunken range still covered everything and nothing was evicted.
    expect(find.byType(ListTile), findsAtLeast(thumbnailPrefetchMargin + 1));

    // A nudge, not a jump: only a row or two enters the list this frame.
    for (var i = 0; i < 4; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -60));
      await tester.pump(const Duration(milliseconds: 200));
    }
    // Settle the last scheduled debounce so no timer outlives the tree.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    drainListTileWarning(tester);

    expect(
      requested.length,
      requested.toSet().length,
      reason: 'a cached thumbnail was evicted and fetched again: $requested',
    );
  });

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

  testWidgets('recycling from the menu posts the status line message', (
    tester,
  ) async {
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
    final menuItem = tester.widget<PopupMenuItem<String>>(
      find.ancestor(
        of: find.text('Recycle Trashed'),
        matching: find.byType(PopupMenuItem<String>),
      ),
    );
    final button = tester.widget<PopupMenuButton<String>>(
      find.byType(PopupMenuButton<String>),
    );
    await tester.runAsync(() async {
      button.onSelected!(menuItem.value!);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    drainListTileWarning(tester);

    expect(state.status?.text, contains('已回收'));
    expect(state.status?.revealPath, endsWith('.trash'));
  });
}
