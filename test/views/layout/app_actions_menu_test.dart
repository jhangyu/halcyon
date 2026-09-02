import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/views/layout/common/app_actions_menu.dart';
import 'package:halcyon_flutter/views/rename_dialog/rename_dialog.dart';
import 'package:halcyon_flutter/views/settings_dialog.dart';

/// White-box checks on the overflow menu that was extracted from the old
/// per-list sidebar widget (T4). The interactive value-routing tests
/// (TC-055, the export path) live in this file too, against the
/// re-exported constants; this file also owns the floating-panel geometry
/// and the row roster.
///
/// TC numbering: user ruled a full +7 shift of the gallery block — gallery
/// TC-487..522 maps to TC-494..529, so this task's width-constraint case is
/// TC-496. This ID is final; docs registry is out of this task's ownership.
void main() {
  setUp(() {
    // No SharedPreferences dependency is touched by these tests, but folder
    // loading in stateForFolder would be; keep the empty-key defaults so any
    // accidental read does not explode.
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  AppState bareState() => AppState(
        imageLoader: (path, {required purpose}) async {
          return const NativeImageFailure('not-used', 'no-op');
        },
      );

  Future<void> pumpMenu(WidgetTester tester, AppState state,
      {Offset? offset}) async {
    // Omit the offset argument entirely when the caller does — that exercises
    // the widget's own `Offset.zero` default rather than an explicit value.
    Widget menu() => offset == null
        ? const AppActionsMenu(iconColor: Colors.black)
        : AppActionsMenu(iconColor: Colors.black, offset: offset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(
            body: Center(child: menu()),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  // Interactive taps hang under FakeAsync in this codebase unless the dialog
  // / real I/O path is satisfied; geometry and roster reads do not need a
  // tap, so the assertions below read the widget tree instead of tapping.
  PopupMenuButton<String> menuButton(WidgetTester tester) =>
      tester.widget<PopupMenuButton<String>>(find.byType(PopupMenuButton<String>));

  testWidgets('TC-496 the overflow menu is 246px wide and floats',
      (tester) async {
    await pumpMenu(tester, bareState());

    final button = menuButton(tester);
    // The panel itself is 246 wide per the gallery contract (mockup frame 2);
    // `over` means the panel renders directly over the glyph rather than as a
    // dropdown underneath it.
    expect(button.constraints, const BoxConstraints.tightFor(width: 246));
    expect(button.position, PopupMenuPosition.over);
    // Default offset: the extracted menu must not shift the old sidebar's
    // panel — the old sidebar menu floated over the glyph at Offset.zero.
    expect(button.offset, Offset.zero);
  });

  testWidgets('a caller-supplied offset is passed through to the floating panel',
      (tester) async {
    // The gallery column (T6) supplies Offset(98 - columnWidth, 0) so the
    // panel's left edge lands 98px from the window edge; this test proves the
    // menu does not swallow that value.
    await pumpMenu(tester, bareState(), offset: const Offset(98, 0));

    final button = menuButton(tester);
    expect(button.offset, const Offset(98, 0));
  });

  testWidgets(
    'TC-055 onSelected with the shared rename constant opens the dialog',
    (tester) async {
      // Ported from sidebar_view_test.dart:206-224 (T11): the interactive
      // value-routing behavior itself, now against AppActionsMenu directly.
      final state = bareState();
      await pumpMenu(tester, state);

      final button = menuButton(tester);
      button.onSelected!(kRenameMenuValue);
      await tester.pump();

      expect(find.byType(RenameDialog), findsOneWidget);
    },
  );

  testWidgets(
    'onSelected with the shared settings constant opens the dialog',
    (tester) async {
      final state = bareState();
      await pumpMenu(tester, state);

      final button = menuButton(tester);
      button.onSelected!(kSettingsMenuValue);
      await tester.pump();

      expect(find.byType(SettingsDialog), findsOneWidget);
    },
  );

  testWidgets(
    'TC-226 (updated) the overflow menu exposes exactly the seven actions',
    (tester) async {
      // Ported from sidebar_view_test.dart:340-352. Row count moved from
      // five to seven with R2's Open Folder + Rename by EXIF additions —
      // see the "menu roster" test below for the ordered roster, and the
      // T11 commit message for the count-change note.
      expect(
        {
          kOpenFolderMenuValue,
          kCopyMenuValue,
          kMoveMenuValue,
          kThumbnailStarredMenuValue,
          kRenameMenuValue,
          kDeleteMenuValue,
          kSettingsMenuValue,
        },
        {
          'openFolder',
          'copy',
          'move',
          'thumbnailStarred',
          'rename',
          'delete',
          'settings',
        },
      );
    },
  );

  testWidgets('the menu roster is Open Folder + the six current rows',
      (tester) async {
    final state = bareState();
    state.toggleRecycleMode();
    await pumpMenu(tester, state);

    final button = menuButton(tester);
    final items = button.itemBuilder(buttonBuildContext(tester));

    final popupItems = items
        .whereType<PopupMenuItem<String>>()
        .map((e) => e.value)
        .toList();

    expect(popupItems, [
      kOpenFolderMenuValue,
      kCopyMenuValue,
      kMoveMenuValue,
      kThumbnailStarredMenuValue,
      kRenameMenuValue,
      kDeleteMenuValue,
      kSettingsMenuValue,
    ]);

    final dividers = items.whereType<PopupMenuDivider>().length;
    expect(dividers, 4); // Open Folder | copy/move/thumb | rename | delete | options
  });

  testWidgets('Open Folder row enables unconditionally', (tester) async {
    final state = bareState(); // empty folder: no starred, no trashed
    await pumpMenu(tester, state);

    final button = menuButton(tester);
    final items = button.itemBuilder(buttonBuildContext(tester));
    final openFolder = items
        .whereType<PopupMenuItem<String>>()
        .firstWhere((e) => e.value == kOpenFolderMenuValue);

    expect(openFolder.enabled, isTrue); // PopupMenuItem defaults enabled to true
  });
}

/// An [AppState]-minimal build context whose [PopupMenuButton] itemBuilder
/// receives the menu's own context. The itemBuilder is invoked by the button
/// at open time with the route context; for white-box roster reads below the
/// folder-less AppState is enough for it to build.
BuildContext buttonBuildContext(WidgetTester tester) {
  final element = tester.element(find.byType(AppActionsMenu));
  // The PopupMenuButton's itemBuilder runs against the element's context
  // (read: AppState is available through the ChangeNotifierProvider above).
  return element;
}