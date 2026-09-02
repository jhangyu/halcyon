import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/views/layout/common/app_actions_menu.dart';
import 'package:halcyon_flutter/views/layout/gallery/gallery_palette.dart';
import 'package:halcyon_flutter/views/rename_dialog/rename_dialog.dart';
import 'package:halcyon_flutter/views/settings_dialog.dart';

import '../../support/temp_dirs.dart';

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
    SharedPreferences.setMockInitialValues({});
  });

  AppState bareState() => AppState(
        imageLoader: (path, {required purpose}) async {
          return const NativeImageFailure('not-used', 'no-op');
        },
      );

  Future<AppState> stateWithTrashedItem(WidgetTester tester) async {
    late AppState state;
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('halcyon_menu_danger_');
      addTempDirTeardown(dir);
      await File(p.join(dir.path, 'IMG_0001.jpg')).writeAsBytes([1, 2, 3]);
      state = AppState(
        imageLoader: (path, {required purpose}) async {
          return const NativeImageFailure('not-used', 'no-op');
        },
      );
      await state.loadFolder(dir);
      state.markCurrent(PhotoStatus.trashed);
    });
    return state;
  }

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

  testWidgets(
      'TC-549 the built-in PopupMenuItem ink is suppressed above the button '
      'so it cannot double-paint over the custom row well',
      (tester) async {
    await pumpMenu(tester, bareState());

    // AppActionsMenu wraps PopupMenuButton in a Theme with splash/highlight
    // zeroed — otherwise PopupMenuItem's own InkWell paints a ripple on top
    // of _MenuRow's hand-drawn hover/press background.
    final theme = tester.widget<Theme>(
      find.ancestor(
        of: find.byType(PopupMenuButton<String>),
        matching: find.byType(Theme),
      ).first,
    );
    expect(theme.data.splashColor, Colors.transparent);
    expect(theme.data.highlightColor, Colors.transparent);
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

    // `.mrule{margin:5px 8px}` — inset from both panel edges, not full-bleed.
    for (final d in items.whereType<PopupMenuDivider>()) {
      expect(d.indent, 8);
      expect(d.endIndent, 8);
    }

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

  testWidgets('TC-539 every row is a fixed 32px slot with zero own padding',
      (tester) async {
    // Mockup `.menu .mi{height:32px}` — fixed, not minimum: the point of
    // fixing it is that the separators land on a rhythm instead of wherever
    // each label's own line box left them.
    final state = bareState();
    await pumpMenu(tester, state);

    final items = menuButton(tester)
        .itemBuilder(buttonBuildContext(tester))
        .whereType<PopupMenuItem<String>>();

    expect(items, isNotEmpty);
    for (final item in items) {
      // Literal 32, not the production constant: comparing the widget against
      // the same symbol it is built from would pass at any value.
      expect(item.height, 32);
      // The row paints its own 10px padding and radius-4 well, so the
      // PopupMenuItem must not add a second inset around it.
      expect(item.padding, EdgeInsets.zero);
    }
  });

  testWidgets('TC-539 rows carry a 14px leading glyph at half emphasis',
      (tester) async {
    final state = bareState();
    await pumpMenu(tester, state);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();

    final icons = tester.widgetList<Icon>(
      find.descendant(
        of: find.text('Open Folder').hitTestable(),
        matching: find.byType(Icon),
      ),
    );
    // The label's own row: find the icon that shares it.
    final rowIcon = tester.widget<Icon>(
      find
          .descendant(
            of: find.ancestor(
              of: find.text('Open Folder'),
              matching: find.byType(Row),
            ),
            matching: find.byType(Icon),
          )
          .first,
    );
    expect(icons, isEmpty); // sanity: the icon is a sibling, not a child
    expect(rowIcon.size, 14);
    expect(rowIcon.color?.a, closeTo(0.5, 0.01));

    // And the painted row really is 32px tall, not merely declared so.
    final row = tester.getSize(
      find.ancestor(
        of: find.text('Open Folder'),
        matching: find.byType(Row),
      ).first,
    );
    expect(row.height, 32);

    // The shortcut hint rides the same row as its label (mockup `.mi .k`),
    // written for the host platform: the test asserts the same helper the
    // widget uses AND that the macOS glyph is not shown off-macOS, so the
    // platform branch cannot silently collapse to one arm.
    expect(find.text(openFolderShortcutLabel()), findsOneWidget);
    if (defaultTargetPlatform != TargetPlatform.macOS) {
      expect(find.text('⌘O'), findsNothing);
    }
  });

  testWidgets('TC-539 disabled and danger rows carry their own ink',
      (tester) async {
    // Empty folder: nothing starred, nothing trashed, so every conditional
    // row is disabled and the danger row is disabled AND red.
    final state = bareState();
    await pumpMenu(tester, state);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();

    final palette = GalleryPalette.of(
      tester.element(find.text('Copy Starred…')),
    );
    final disabled = tester.widget<Text>(find.text('Copy Starred…'));
    expect(disabled.style?.color, palette.textFaint); // .mi.dim

    // Precedence: a danger row with nothing to delete is DIM, not red —
    // `.mi.dim` sets the colour and `.mi.danger` does not override it.
    final dimDanger = tester.widget<Text>(find.text('Delete Trashed'));
    expect(dimDanger.style?.color, palette.textFaint);
    expect(dimDanger.style?.fontSize, 12.5);
  });

  testWidgets('TC-539 an enabled danger row keeps the error hue',
      (tester) async {
    // Something IS trashed, so the danger row is live and shows its own
    // colour (`.mi.danger{color:var(--danger)}`).
    final state = await stateWithTrashedItem(tester);
    addTearDown(state.dispose);
    await pumpMenu(tester, state);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();

    final danger = tester.widget<Text>(find.text('Delete Trashed'));
    final errorColor = Theme.of(
      tester.element(find.text('Delete Trashed')),
    ).colorScheme.error;
    expect(danger.style?.color, errorColor);
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