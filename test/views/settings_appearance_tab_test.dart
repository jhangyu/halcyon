// TC-806..TC-816 — the Appearance tab, widget level.
//
// Frozen spec: docs/logs/2026-09-02/theme-switcher-spec.md, acceptance list in
// section 10. The state-level half (persistence, snapshot, reset) is in
// test/providers/app_state_appearance_test.dart.
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:halcyon_flutter/main.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/retention_policy.dart';
import 'package:halcyon_flutter/views/layout/layout_theme.dart';
import 'package:halcyon_flutter/views/settings_dialog.dart';
import 'package:halcyon_flutter/views/settings_dialog/appearance_tab.dart';
import 'package:halcyon_flutter/views/settings_dialog/settings_primitives.dart';
import 'package:halcyon_flutter/views/theme_tokens.dart';

/// Hydration must run OUTSIDE the fake-async zone. `AppState._initPrefs` is a
/// real async chain over the SharedPreferences platform channel; awaiting it
/// directly inside `testWidgets` hangs forever, because fake-async never
/// advances a timer nobody pumped (this cost one 150s timeout before it was
/// diagnosed).
Future<AppState> _hydrated(
  WidgetTester tester, {
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  late final AppState state;
  await tester.runAsync(() async {
    state = AppState(retention: const RetentionPolicy.floor());
    await Future<void>.delayed(Duration.zero);
  });
  addTearDown(state.dispose);
  return state;
}

/// Same reason: reading the store back is a real channel round trip.
Future<Map<String, Object?>> _storedPrefs(WidgetTester tester) async {
  late final Map<String, Object?> values;
  await tester.runAsync(() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    values = {for (final k in prefs.getKeys()) k: prefs.get(k)};
  });
  return values;
}

/// The dialog is 920x560; the default 800x600 test surface would squeeze the
/// Appearance tab's fixed-width left column against its Expanded stage and
/// report overflow that the real dialog never has.
Future<void> _pump(WidgetTester tester, AppState state) async {
  await tester.binding.setSurfaceSize(const Size(1200, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: Scaffold(body: SettingsDialog())),
    ),
  );
  await tester.pump();
}

/// Opens through `showDialog` so Cancel / Done really pop a route and the
/// dialog's dispose-time revert actually runs — the whole point of TC-812.
Future<void> _pumpViaRoute(WidgetTester tester, AppState state) async {
  await tester.binding.setSurfaceSize(const Size(1200, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
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

Future<void> _openAppearance(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('settingsTab.appearance')));
  await tester.pump();
}

/// The Reset section sits below the fold: the tab is 500px tall inside a 381px
/// scroll viewport, so it must be scrolled to before it can be tapped. See the
/// round-4 report — the frozen spec section 2 claims the design fits without
/// scrolling, which its own metrics plus `settingsBlock`'s padding do not
/// allow. Measured, not assumed; this helper is what keeps the assertion
/// honest instead of silently tapping thin air.
Future<void> _revealReset(WidgetTester tester) async {
  await _tapRevealed(tester, const Key('appearance.resetAll'));
}

/// Scrolls a control into view, then taps it. Expanding the inline confirm
/// grows the tab further, so each of its buttons needs the same treatment.
Future<void> _tapRevealed(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(key));
  await tester.pump();
}

/// The border colour the selection treatment paints (spec §3): accent when
/// selected, borderSoft otherwise.
Color _borderColourOf(WidgetTester tester, Key key) {
  final container = tester.widget<Container>(
    find
        .descendant(of: find.byKey(key), matching: find.byType(Container))
        .first,
  );
  final decoration = container.decoration as BoxDecoration;
  return (decoration.border as Border).top.color;
}

void main() {
  testWidgets(
      'TC-806 the tab bar renders four labels with Appearance at index 1, and '
      'selecting it swaps the body', (tester) async {
    final state = await _hydrated(tester);
    await _pump(tester, state);

    final bar = tester.widget<SettingsTabBar>(find.byType(SettingsTabBar));
    expect(bar.labels, const [
      'Performance & Memory',
      'Appearance',
      'Export',
      'Shortcuts',
    ]);
    expect(bar.labels[1], 'Appearance');
    expect(bar.keys[1], const Key('settingsTab.appearance'));

    // Performance & Memory is tab 0 and shows first.
    expect(find.text('Concurrent RAW decodes'), findsOneWidget);
    await _openAppearance(tester);
    expect(find.text('Concurrent RAW decodes'), findsNothing);
    expect(find.byKey(const Key('appearance.stage')), findsOneWidget);
  });

  testWidgets(
      'TC-807 the mode control offers exactly Dark / Light / System and '
      'tapping Light sets AppState.themeMode', (tester) async {
    final state = await _hydrated(tester);
    await _pump(tester, state);
    await _openAppearance(tester);

    for (final mode in ThemeMode.values) {
      expect(find.byKey(Key('appearance.mode.${mode.name}')), findsOneWidget);
    }
    expect(find.text('Dark'), findsOneWidget);
    expect(find.text('Light'), findsOneWidget);
    expect(find.text('System'), findsOneWidget);

    expect(state.themeMode, ThemeMode.system);
    await tester.tap(find.byKey(const Key('appearance.mode.light')));
    await tester.pump();
    expect(state.themeMode, ThemeMode.light);
  });

  testWidgets(
      'TC-808 the resolved-brightness caption appears for System only',
      (tester) async {
    final state = await _hydrated(tester);
    await _pump(tester, state);
    await _openAppearance(tester);

    const noteKey = Key('appearance.systemBrightnessNote');
    expect(find.byKey(noteKey), findsOneWidget,
        reason: 'System is the default mode');
    expect(
      tester.widget<Text>(find.byKey(noteKey)).data,
      'macOS · currently light',
    );

    await tester.tap(find.byKey(const Key('appearance.mode.dark')));
    await tester.pump();
    expect(find.byKey(noteKey), findsNothing);

    await tester.tap(find.byKey(const Key('appearance.mode.light')));
    await tester.pump();
    expect(find.byKey(noteKey), findsNothing);
  });

  testWidgets(
      'TC-809 one row per LayoutThemeId in declaration order; tapping Paper '
      'sets AppState.layoutThemeId', (tester) async {
    final state = await _hydrated(tester);
    await _pump(tester, state);
    await _openAppearance(tester);

    for (final id in LayoutThemeId.values) {
      expect(find.byKey(Key('appearance.layout.${id.name}')), findsOneWidget);
    }
    // Declaration order, read off the rendered geometry rather than assumed.
    final ys = [
      for (final id in LayoutThemeId.values)
        tester.getTopLeft(find.byKey(Key('appearance.layout.${id.name}'))).dy,
    ];
    expect(ys[0] < ys[1] && ys[1] < ys[2], isTrue, reason: 'ys=$ys');

    await tester.tap(find.byKey(const Key('appearance.layout.paper')));
    await tester.pump();
    expect(state.layoutThemeId, LayoutThemeId.paper);
  });

  testWidgets(
      'TC-810 exactly one layout row and one mode cell carry the accent '
      'selection border at a time', (tester) async {
    final state = await _hydrated(tester);
    await _pump(tester, state);
    await _openAppearance(tester);

    final t = HalcyonTokens.of(
      tester.element(find.byKey(const Key('appearance.stage'))),
    );

    List<LayoutThemeId> selectedLayouts() => [
      for (final id in LayoutThemeId.values)
        if (_borderColourOf(tester, Key('appearance.layout.${id.name}')) ==
            t.accent)
          id,
    ];

    expect(selectedLayouts(), [LayoutThemeId.gallery]);
    await tester.tap(find.byKey(const Key('appearance.layout.darkroom')));
    await tester.pump();
    expect(selectedLayouts(), [LayoutThemeId.darkroom]);

    final selectedModes = [
      for (final m in ThemeMode.values)
        if (_borderColourOf(tester, Key('appearance.mode.${m.name}')) ==
            t.accent)
          m,
    ];
    expect(selectedModes, [ThemeMode.system]);
  });

  testWidgets(
      'TC-811 hovering a layout row previews it on the stage WITHOUT '
      'committing, and leaving restores the selection', (tester) async {
    final state = await _hydrated(tester);
    await _pump(tester, state);
    await _openAppearance(tester);

    String tagText() => tester
        .widget<Text>(find.byKey(const Key('appearance.stage.tag')))
        .data!;

    expect(tagText(), startsWith('Gallery · '));
    expect(tagText(), isNot(contains('preview only')));

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(
      tester.getCenter(find.byKey(const Key('appearance.layout.paper'))),
    );
    await tester.pump();

    expect(tagText(), startsWith('Paper · '));
    expect(tagText(), endsWith('preview only'),
        reason: 'the stage must say it is showing a hover, not a choice');
    expect(state.layoutThemeId, LayoutThemeId.gallery,
        reason: 'hover must never reach AppState');

    // Off the rows entirely.
    await gesture.moveTo(const Offset(5, 5));
    await tester.pump();
    expect(tagText(), startsWith('Gallery · '));
    expect(tagText(), isNot(contains('preview only')));
  });

  testWidgets(
      'TC-812 Cancel reverts both appearance settings; Done commits them',
      (tester) async {
    final state = await _hydrated(tester);
    await _pumpViaRoute(tester, state);
    await _openAppearance(tester);

    await tester.tap(find.byKey(const Key('appearance.mode.dark')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('appearance.layout.darkroom')));
    await tester.pump();
    expect(state.themeMode, ThemeMode.dark, reason: 'applies live');
    expect(state.layoutThemeId, LayoutThemeId.darkroom);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    // The revert is deferred to a post-frame callback by design.
    await tester.pump();
    expect(state.themeMode, ThemeMode.system);
    expect(state.layoutThemeId, LayoutThemeId.gallery);
    expect((await _storedPrefs(tester))['layoutThemeId'], 'gallery');

    // Same change again, dismissed with Done.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await _openAppearance(tester);
    await tester.tap(find.byKey(const Key('appearance.mode.dark')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('appearance.layout.darkroom')));
    await tester.pump();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.pump();
    expect(state.themeMode, ThemeMode.dark);
    expect(state.layoutThemeId, LayoutThemeId.darkroom);
    expect((await _storedPrefs(tester))['layoutThemeId'], 'darkroom');
  });

  testWidgets(
      'TC-813 confirming Reset everything clears prefs, restores defaults, '
      'closes the dialog, and SURVIVES the dialog dismissal', (tester) async {
    final state = await _hydrated(tester, prefs: {
      'themeMode': 'dark',
      'layoutThemeId': 'paper',
      'autoAdvance': true,
    });
    await _pumpViaRoute(tester, state);
    await _openAppearance(tester);
    expect(state.layoutThemeId, LayoutThemeId.paper);

    // Resting state first: the confirm must not be pre-expanded.
    expect(find.byKey(const Key('appearance.resetConfirm')), findsNothing);
    await _revealReset(tester);
    expect(find.byKey(const Key('appearance.resetConfirm')), findsOneWidget);
    expect(find.byType(SettingsDialog), findsOneWidget,
        reason: 'the confirm is inline; nothing stacks on the dialog');

    // The user-approved copy, pinned. The previous frozen wording named three
    // settings this app does not persist (recycle mode, sidebar width, the
    // reopened folder); a destructive confirm that overstates its scope is a
    // correctness problem, not a style one, so the sentence is asserted.
    final confirmCopy = tester
        .widget<Text>(find.byKey(const Key('appearance.resetConfirmCopy')))
        .data!;
    // Written out as a LITERAL, deliberately. Comparing the rendered text to
    // `kResetConfirmCopy` would only prove the widget renders whatever that
    // constant happens to say — the constant and the widget would drift
    // together and the assertion would stay green. The test has to carry an
    // independent copy of the sentence the user approved.
    expect(
      confirmCopy,
      'This resets every Halcyon preference — appearance and layout theme, '
      'auto-advance, overwrite-on-export, decode concurrency, export '
      'quality/long-edge/format, memory retention tier, and keyboard '
      'shortcuts. Photo folders and their star/trash marks are not touched. '
      'This cannot be undone. Reset applies at once and closes Settings.',
    );
    expect(confirmCopy, kResetConfirmCopy,
        reason: 'the widget must render the exported constant, so any other '
            'reader of it sees the same sentence');
    expect(confirmCopy, contains('star/trash marks are not touched'));
    // User ruling 2026-09-03: the behavioural consequence must be stated. It
    // was dropped when the frozen paragraph was replaced wholesale, and the
    // user asked for it back explicitly.
    expect(confirmCopy, endsWith('Reset applies at once and closes Settings.'));
    for (final absent in ['recycle mode', 'sidebar width', 'reopens']) {
      expect(confirmCopy, isNot(contains(absent)),
          reason: 'the confirm must not promise to clear "$absent", which '
              'is not a persisted preference');
    }

    await _tapRevealed(tester, const Key('appearance.resetConfirmButton'));
    await tester.pumpAndSettle();
    // The dispose-time revert, if it were going to run, runs here.
    await tester.pump();
    await tester.pump();

    expect(find.byType(SettingsDialog), findsNothing,
        reason: 'reset applies at once and closes Settings');
    expect(state.themeMode, ThemeMode.system,
        reason: 'if this is dark again, the snapshot silently undid the reset');
    expect(state.layoutThemeId, LayoutThemeId.gallery);
    expect(state.autoAdvance, isFalse);
    expect(await _storedPrefs(tester), isEmpty);
  });

  testWidgets('TC-814 Keep settings dismisses the confirm and changes nothing',
      (tester) async {
    final state = await _hydrated(tester, prefs: {'layoutThemeId': 'paper'});
    await _pump(tester, state);
    await _openAppearance(tester);

    await _revealReset(tester);
    await _tapRevealed(tester, const Key('appearance.resetKeep'));

    expect(find.byKey(const Key('appearance.resetConfirm')), findsNothing);
    expect(state.layoutThemeId, LayoutThemeId.paper);
    expect((await _storedPrefs(tester))['layoutThemeId'], 'paper');
  });

  testWidgets('TC-815 the summary rail tracks appearance and layout theme',
      (tester) async {
    final state = await _hydrated(tester);
    await _pump(tester, state);

    expect(find.text('Appearance'), findsWidgets);
    expect(find.text('Layout theme'), findsOneWidget);
    String railTheme() => tester
        .widget<Text>(find.byKey(const Key('summaryRail.layoutTheme')))
        .data!;
    expect(railTheme(), 'Gallery');
    expect(find.text('System · light'), findsOneWidget);

    await _openAppearance(tester);
    await tester.tap(find.byKey(const Key('appearance.layout.darkroom')));
    await tester.pump();
    expect(railTheme(), 'Darkroom');

    await tester.tap(find.byKey(const Key('appearance.mode.dark')));
    await tester.pump();
    expect(find.text('Dark'), findsWidgets);
    expect(find.text('System · light'), findsNothing);
  });

  testWidgets(
      'TC-816 MaterialApp.themeMode and the ThemeData follow AppState, not a '
      'constant', (tester) async {
    final state = await _hydrated(tester);
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const HalcyonApp(),
      ),
    );
    await tester.pump();

    MaterialApp app() => tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app().themeMode, ThemeMode.system);
    // Gallery's --canvas, from gallery_palette.dart.
    expect(app().theme!.scaffoldBackgroundColor, const Color(0xFFFAF9F7));

    state.setThemeMode(ThemeMode.dark);
    state.setLayoutThemeId(LayoutThemeId.darkroom);
    await tester.pump();

    expect(app().themeMode, ThemeMode.dark);
    // Darkroom's --ground: proves the palette followed, not just the mode.
    expect(app().theme!.scaffoldBackgroundColor, const Color(0xFFE7E9E4));
    expect(app().darkTheme!.scaffoldBackgroundColor, const Color(0xFF0C0D0C));
  });

  test('TC-817 kActiveLayoutThemeId and activeLayoutTheme are gone from lib/',
      () {
    // Mechanical: the spec forbids a compatibility shim, and a shim would be
    // invisible to every behavioural test above (they would all still pass
    // while a stale global kept serving the old constant).
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // Comment lines are stripped first: this asks whether the IDENTIFIER
      // still exists, not whether the words appear in prose. A doc comment
      // that says "replaced the kActiveLayoutThemeId constant" is a correct
      // historical note, not a shim.
      final code = entity
          .readAsLinesSync()
          .where((line) {
            final trimmed = line.trimLeft();
            return !trimmed.startsWith('//') && !trimmed.startsWith('///');
          })
          .join('\n');
      if (code.contains('kActiveLayoutThemeId') ||
          code.contains('activeLayoutTheme')) {
        offenders.add(entity.path);
      }
    }
    expect(offenders, isEmpty);
  });
}
