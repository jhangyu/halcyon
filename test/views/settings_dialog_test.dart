import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:halcyon_flutter/models/shortcut_bindings.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/retention_policy.dart';
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
  testWidgets('TC-458 the dialog renders the three tabs and the rail on every tab',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(laneCeiling: 5);
    addTearDown(state.dispose);
    await pumpDialog(tester, state);

    expect(find.text('Performance'), findsOneWidget);
    expect(find.text('Memory'), findsOneWidget);
    expect(find.text('Shortcuts'), findsOneWidget);
    expect(find.text('AT A GLANCE'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settingsTab.memory')));
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
      'TC-461 the export-quality slider is 70..100 step 5 and rounds to '
      'the nearest stop', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(laneCeiling: 5);
    addTearDown(state.dispose);
    await pumpDialog(tester, state);

    final slider = tester.widget<Slider>(
      find.byKey(const Key('exportQualitySlider')),
    );
    expect(slider.min, 70);
    expect(slider.max, 100);
    expect(slider.divisions, 6);
    slider.onChanged!(73);
    await tester.pump();
    expect(state.exportJpegQuality, 75);
  });

  testWidgets(
      'TC-462 tapping a tier card sets the retention tier; the reset '
      'button appears only after an override and clears it', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(laneCeiling: 5);
    addTearDown(state.dispose);
    await pumpDialog(tester, state);

    await tester.tap(find.byKey(const Key('settingsTab.memory')));
    await tester.pump();

    expect(find.byKey(const Key('retentionResetToAuto')), findsNothing);

    await tester.tap(find.byKey(const Key('retentionTier.generous')));
    await tester.pump();

    expect(state.retentionTier, RetentionTier.generous);
    expect(state.retentionPolicy.after, 11);
    expect(find.byKey(const Key('retentionResetToAuto')), findsOneWidget);

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
    expect(find.text('90'), findsWidgets); // rail value + export caption
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
}

/// Grabs a [BuildContext] currently in the tree, so the test can drive
/// [AppState] the same way the dialog's own widgets would (context.read).
BuildContext context(WidgetTester tester) =>
    tester.element(find.byType(SettingsDialog));
