import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:halcyon_flutter/models/shortcut_bindings.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/retention_policy.dart';
import 'package:halcyon_flutter/services/library/photo_export_service.dart';
import 'package:halcyon_flutter/views/settings_dialog.dart';

Future<void> pumpDialog(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: Scaffold(body: SettingsDialog())),
    ),
  );
  await tester.pump();
}

Future<void> pumpDialogViaShowDialog(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const SettingsDialog(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'TC-458 (round 2: supersedes tab labels) the dialog renders the '
      'three restructured tabs and the rail on every tab', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(laneCeiling: 5);
    addTearDown(state.dispose);
    await pumpDialog(tester, state);

    expect(find.text('Performance & Memory'), findsOneWidget);
    expect(find.text('Export'), findsOneWidget);
    expect(find.text('Shortcuts'), findsOneWidget);
    expect(find.text('AT A GLANCE'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settingsTab.export')));
    await tester.pump();
    expect(find.text('AT A GLANCE'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settingsTab.shortcuts')));
    await tester.pump();
    expect(find.text('AT A GLANCE'), findsOneWidget);
  });

  testWidgets(
      'TC-459 (supersedes TC-354) the width slider is enabled, writes '
      'through, is labelled "Concurrent RAW decodes", and no "lane" copy '
      'is visible', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(laneCeiling: 5);
    addTearDown(state.dispose);
    await pumpDialog(tester, state);

    final slider = tester.widget<Slider>(
      find.byKey(const Key('decodeLaneWidthSlider')),
    );
    expect(slider.onChanged, isNotNull);
    expect(slider.min, 1);
    expect(slider.max, 5);
    slider.onChanged!(4);
    await tester.pump();
    expect(state.decodeLaneWidth, 4);

    expect(find.text('Concurrent RAW decodes'), findsOneWidget);
    expect(find.textContaining('lane'), findsNothing);
  });

  testWidgets(
      'TC-460 (supersedes TC-355) the row is shown but DISABLED on a '
      'machine whose ceiling is 1 (never hidden)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(laneCeiling: 1);
    addTearDown(state.dispose);
    await pumpDialog(tester, state);

    final finder = find.byKey(const Key('decodeLaneWidthSlider'));
    expect(finder, findsOneWidget, reason: 'a hidden control reads as a '
        'missing feature when the user compares two machines');
    expect(tester.widget<Slider>(finder).onChanged, isNull);
    expect(
      find.text('This machine can only decode one RAW at a time'),
      findsOneWidget,
    );
  });

  testWidgets(
      'TC-461 (round 2: supersedes 70..100) the export-quality slider is '
      '50..100 step 5 and rounds to the nearest stop', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(laneCeiling: 5);
    addTearDown(state.dispose);
    await pumpDialog(tester, state);

    await tester.tap(find.byKey(const Key('settingsTab.export')));
    await tester.pump();

    final slider = tester.widget<Slider>(
      find.byKey(const Key('exportQualitySlider')),
    );
    expect(slider.min, 50);
    expect(slider.max, 100);
    expect(slider.divisions, 10);
    slider.onChanged!(73);
    await tester.pump();
    expect(state.exportJpegQuality, 75);
  });

  testWidgets(
      'TC-469 the export-size slider offers the 8 named stops, rounds to '
      'the nearest one, and Original is reachable', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(laneCeiling: 5);
    addTearDown(state.dispose);
    await pumpDialog(tester, state);

    await tester.tap(find.byKey(const Key('settingsTab.export')));
    await tester.pump();

    final slider = tester.widget<Slider>(
      find.byKey(const Key('exportSizeSlider')),
    );
    expect(slider.min, 0);
    expect(slider.max, 7);
    expect(slider.divisions, 7);

    // Index 4 is the default stop (2048).
    expect(state.exportLongEdge, 2048);
    expect(slider.value, 4);

    slider.onChanged!(0);
    await tester.pump();
    expect(state.exportLongEdge, 480);

    slider.onChanged!(7);
    await tester.pump();
    expect(state.exportLongEdge, 0, reason: 'last stop is the Original sentinel');
    expect(find.text('Original'), findsWidgets);
  });

  testWidgets(
      'TC-477 (round 2c: supersedes disabled-segment assertions) the '
      'filetype segmented control shows exactly JPEG and WebP (lossy) -- '
      'HEIF/WebP(lossless) are not rendered at all -- and selecting WebP '
      '(lossy) updates the rail', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(laneCeiling: 5);
    addTearDown(state.dispose);
    await pumpDialog(tester, state);

    await tester.tap(find.byKey(const Key('settingsTab.export')));
    await tester.pump();

    expect(state.exportFiletype, ExportFiletype.jpeg);
    expect(find.byKey(const Key('exportFiletype.jpeg')), findsOneWidget);
    expect(find.byKey(const Key('exportFiletype.webpLossy')), findsOneWidget);
    expect(find.byKey(const Key('exportFiletype.heif')), findsNothing,
        reason: 'unavailable filetypes are dropped entirely, not shown '
            'disabled (user ruling, round 2c)');
    expect(find.byKey(const Key('exportFiletype.webpLossless')), findsNothing);

    await tester.tap(find.byKey(const Key('exportFiletype.webpLossy')));
    await tester.pump();
    expect(state.exportFiletype, ExportFiletype.webpLossy);

    // Rail reflects the live selection on every tab.
    expect(find.text('WebP (lossy)'), findsWidgets); // segment + rail

    // Quality slider stays enabled for WebP-lossy too (no disabled state
    // this round -- both available filetypes are quality-driven).
    final slider =
        tester.widget<Slider>(find.byKey(const Key('exportQualitySlider')));
    expect(slider.onChanged, isNotNull);
  });

  testWidgets(
      'TC-462 tapping a tier card sets the retention tier; the reset '
      'button appears only after an override and clears it', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(laneCeiling: 5);
    addTearDown(state.dispose);
    await pumpDialog(tester, state);

    expect(find.byKey(const Key('retentionResetToAuto')), findsNothing);

    // The merged Performance & Memory tab (round 2) is taller than the
    // dialog's viewport, so Memory Retention needs scrolling into view.
    await tester.ensureVisible(find.byKey(const Key('retentionTier.generous')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('retentionTier.generous')));
    await tester.pump();

    expect(state.retentionTier, RetentionTier.generous);
    expect(state.retentionPolicy.after, 11);
    expect(find.byKey(const Key('retentionResetToAuto')), findsOneWidget);

    // Round-3 layout (Parallelism | Memory Retention side by side) makes
    // the reset button wrap onto its own line under the caption, which can
    // land outside the scrolled viewport -- ensure it's visible before tap.
    await tester.ensureVisible(find.byKey(const Key('retentionResetToAuto')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('retentionResetToAuto')));
    await tester.pump();
    expect(state.isRetentionTierOverridden, isFalse);
    expect(find.byKey(const Key('retentionResetToAuto')), findsNothing);
  });

  testWidgets(
      'TC-463 the rail shows concurrent decodes, quality, tier and a '
      'clean conflicts value', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(laneCeiling: 5);
    addTearDown(state.dispose);
    await pumpDialog(tester, state);

    expect(find.text('3 / 5'), findsOneWidget);
    expect(find.text('90'), findsOneWidget); // rail value only -- Export
    // quality's own caption lives on the Export tab now, not this one.
    expect(find.text('2048px'), findsOneWidget); // rail's Export size value
    expect(
      find.text(
        '${state.retentionTier.label} · '
        '${state.retentionPolicy.payloadByteBudget ~/ (1024 * 1024)} MiB',
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('summaryRail.conflicts'))).data,
      'None',
    );
  });

  testWidgets('TC-464 recording flow binds a new key and leaves recording mode',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(laneCeiling: 5);
    addTearDown(state.dispose);
    await pumpDialog(tester, state);

    await tester.tap(find.byKey(const Key('settingsTab.shortcuts')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('shortcutRecord.starPhoto')));
    await tester.pump();
    expect(find.text('Press a key…'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pump();

    expect(
      state.shortcutBindings.keyFor(ShortcutAction.starPhoto),
      LogicalKeyboardKey.keyF,
    );
    expect(find.text('Press a key…'), findsNothing);
  });

  testWidgets(
      'TC-465 recording rejects a reserved key and Escape cancels without '
      'changing the binding', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(laneCeiling: 5);
    addTearDown(state.dispose);
    await pumpDialog(tester, state);

    await tester.tap(find.byKey(const Key('settingsTab.shortcuts')));
    await tester.pump();

    final before = state.shortcutBindings.keyFor(ShortcutAction.starPhoto);

    await tester.tap(find.byKey(const Key('shortcutRecord.starPhoto')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(state.shortcutBindings.keyFor(ShortcutAction.starPhoto), before);
    expect(find.textContaining("can't be used as a shortcut"), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(state.shortcutBindings.keyFor(ShortcutAction.starPhoto), before);
    expect(find.text('Press a key…'), findsNothing);
  });

  testWidgets(
      'TC-466 conflict surfacing: binding recycle-mode to X names both '
      'conflicting actions and updates the rail', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(laneCeiling: 5);
    addTearDown(state.dispose);
    // AppState's prefs hydration is async (_initPrefs); let it settle before
    // binding, otherwise the hydration completes afterwards and overwrites
    // our synchronous binding back to the persisted (default) state.
    await tester.pump();
    state.setShortcutBinding(
      ShortcutAction.toggleRecycleMode,
      LogicalKeyboardKey.keyX,
    );
    await pumpDialog(tester, state);

    await tester.tap(find.byKey(const Key('settingsTab.shortcuts')));
    await tester.pump();

    expect(find.byKey(const Key('settingsConflictNote')), findsOneWidget);
    final noteText = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(const Key('settingsConflictNote')),
            matching: find.byType(Text),
          ),
        )
        .map((t) => t.data ?? '')
        .join(' ');
    expect(noteText, contains('Trash-mark photo'));
    expect(noteText, contains('Toggle recycle mode'));

    expect(
      tester.widget<Text>(find.byKey(const Key('summaryRail.conflicts'))).data,
      '1 conflict (X)',
    );
  });

  testWidgets(
      'TC-467 Cancel reverts every changed field; Done persists them',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(laneCeiling: 5);
    addTearDown(state.dispose);

    final openingLaneWidth = state.decodeLaneWidth;
    final openingQuality = state.exportJpegQuality;
    final openingTier = state.retentionTier;
    final openingBinding = state.shortcutBindings.keyFor(ShortcutAction.starPhoto);

    await pumpDialogViaShowDialog(tester, state);

    context(tester).read<AppState>().setDecodeLaneWidth(openingLaneWidth + 1);
    context(tester).read<AppState>().setExportJpegQuality(openingQuality == 100
        ? 90
        : 100);
    context(tester)
        .read<AppState>()
        .setRetentionTier(RetentionTier.generous);
    context(tester).read<AppState>().setShortcutBinding(
          ShortcutAction.starPhoto,
          LogicalKeyboardKey.keyF,
        );
    await tester.pump();

    await tester.tap(find.byKey(const Key('settingsCancel')));
    await tester.pumpAndSettle();

    expect(state.decodeLaneWidth, openingLaneWidth);
    expect(state.exportJpegQuality, openingQuality);
    expect(state.retentionTier, openingTier);
    expect(
      state.shortcutBindings.keyFor(ShortcutAction.starPhoto),
      openingBinding,
    );

    // Repeat, this time committing with Done.
    await pumpDialogViaShowDialog(tester, state);
    context(tester).read<AppState>().setDecodeLaneWidth(openingLaneWidth + 1);
    await tester.pump();
    await tester.tap(find.byKey(const Key('settingsDone')));
    await tester.pumpAndSettle();

    expect(state.decodeLaneWidth, openingLaneWidth + 1);
  });

  testWidgets(
      'TC-482 round-4: Export tab renamed section labels and row labels for '
      'Quality, Size and File Type', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(laneCeiling: 5);
    addTearDown(state.dispose);
    await pumpDialog(tester, state);

    await tester.tap(find.byKey(const Key('settingsTab.export')));
    await tester.pump();

    // File Type block (was "Export" section-label / "Export Filetype" row).
    // The tab bar's own "Export" tab label is a separate Text and stays --
    // only the section-label inside the tab content is renamed.
    expect(find.text('FILE TYPE'), findsOneWidget);
    expect(find.text('Filetype of the export image'), findsOneWidget);

    // Quality block gained a section-label it didn't have before.
    expect(find.text('QUALITY'), findsOneWidget);
    expect(find.text('Quality setting of the encoder'), findsOneWidget);

    // Size block renamed section-label + row-label.
    expect(find.text('SIZE'), findsOneWidget);
    expect(find.text('Size of the export image'), findsOneWidget);
    expect(find.text('Export Size'), findsNothing);
    expect(find.text('Export Quality'), findsNothing);
    expect(find.text('Export Filetype'), findsNothing);
  });

  testWidgets(
      'TC-483 round-4: Performance & Memory tab pairs Parallelism and Memory '
      'Retention at a 2:3 flex ratio', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(laneCeiling: 5);
    addTearDown(state.dispose);
    await pumpDialog(tester, state);

    final row = tester.widgetList<Expanded>(find.byType(Expanded)).where(
        (w) => w.flex == 2 || w.flex == 3);
    final flexes = row.map((w) => w.flex).toList()..sort();
    expect(flexes, [2, 3],
        reason: 'Parallelism is flex:2, Memory Retention is flex:3 '
            '(round-4 user ruling, was 50/50)');
  });

  // TC-484 (round-4) pinned the IntrinsicWidth+Wrap Workflow layout's
  // single-line-label guarantee. Round-5 (real-build review) reverted the
  // Workflow section to its pre-round-4 (297d6c3) two-Expanded-
  // CheckboxListTile Row -- which can legitimately wrap the longer label
  // to a second line at narrower widths, the exact behaviour TC-484 was
  // written to forbid -- so TC-484 is removed rather than re-pinned.

  testWidgets(
      'TC-486 round-5: Parallelism and Memory Retention blocks in the paired '
      'row render at equal height', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(laneCeiling: 5);
    addTearDown(state.dispose);
    await pumpDialog(tester, state);

    // The Parallelism block is flex:2, Memory Retention is flex:3 (see
    // TC-483). Measure each Expanded's own render box height directly --
    // this sidesteps matching sub-widgets like the tier-card Containers
    // that also live inside the IntrinsicHeight row.
    final expandedRow = tester
        .widgetList<Expanded>(find.byType(Expanded))
        .where((w) => w.flex == 2 || w.flex == 3);
    expect(expandedRow.length, 2,
        reason: 'expected exactly the Parallelism (flex:2) and Memory '
            'Retention (flex:3) Expanded widgets');

    final heights = expandedRow
        .map((w) => tester.renderObject<RenderBox>(find.byWidget(w)).size.height)
        .toList();

    expect(heights[0], closeTo(heights[1], 0.5),
        reason: 'Parallelism and Memory Retention blocks must stretch to '
            'the same height so their top/bottom edges line up');
  });

  testWidgets(
      'TC-485 F1 fidelity: every settings slider uses a SliderTheme with '
      'trackHeight 4 and a radius-7 thumb (F1.html:70-71)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(laneCeiling: 5);
    addTearDown(state.dispose);
    await pumpDialog(tester, state);

    // Performance & Memory tab: decodeLaneWidthSlider.
    final laneSliderTheme = tester.widget<SliderTheme>(
      find.ancestor(
        of: find.byKey(const Key('decodeLaneWidthSlider')),
        matching: find.byType(SliderTheme),
      ),
    );
    expect(laneSliderTheme.data.trackHeight, 4);
    expect(laneSliderTheme.data.thumbShape, isA<RoundSliderThumbShape>());

    await tester.tap(find.byKey(const Key('settingsTab.export')));
    await tester.pump();

    for (final key in ['exportQualitySlider', 'exportSizeSlider']) {
      final theme = tester.widget<SliderTheme>(
        find.ancestor(
          of: find.byKey(Key(key)),
          matching: find.byType(SliderTheme),
        ),
      );
      expect(theme.data.trackHeight, 4, reason: '$key trackHeight');
      expect(theme.data.thumbShape, isA<RoundSliderThumbShape>(),
          reason: '$key thumbShape');
    }
  });
}

/// Grabs a [BuildContext] currently in the tree, so the test can drive
/// [AppState] the same way the dialog's own widgets would (context.read).
BuildContext context(WidgetTester tester) =>
    tester.element(find.byType(SettingsDialog));
