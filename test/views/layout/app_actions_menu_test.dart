import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/views/layout/common/app_actions_menu.dart';
import 'package:halcyon_flutter/views/rename_dialog/rename_dialog.dart';

/// White-box checks on the overflow menu that was extracted from
/// SidebarView (T4). The interactive value-routing tests (TC-055, the export
/// path) stay in sidebar_view_test.dart against the re-exported constants;
/// this file owns the floating-panel geometry and the row roster.
///
/// TC numbering: user ruled a full +7 shift of the gallery block — gallery
/// TC-487..522 maps to TC-494..529, so this task's width-constraint case is
/// TC-496 (was TC-489). This ID is final; docs registry is out of this task's
/// ownership.
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

  Future<void> pumpMenu(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: AppActionsMenu(iconColor: Colors.black),
            ),
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
  });

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