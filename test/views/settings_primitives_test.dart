import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/library/photo_export_service.dart';
import 'package:halcyon_flutter/views/settings_dialog.dart';
import 'package:halcyon_flutter/views/settings_dialog/settings_primitives.dart';
import 'package:halcyon_flutter/views/theme_tokens.dart';

const t =
    HalcyonTokens.dark; // HalcyonTokens.of() fallback, theme_tokens.dart:88-89

Future<AppState> pumpDialog(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  await tester.binding.setSurfaceSize(const Size(1200, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  // flutter test cannot load the ceyx dylib, so the export capability set
  // is injected (same as settings_dialog_test.dart TC-477).
  final state = AppState.forTesting(
    runtimeCapabilities: {ExportFiletype.jpeg, ExportFiletype.webpLossy},
  );
  addTearDown(state.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: Scaffold(body: SettingsDialog())),
    ),
  );
  await tester.pump();
  return state;
}

void main() {
  testWidgets('TC-1496 migrated tier cards and export segments keep their '
      'size and their unselected fill', (tester) async {
    await pumpDialog(tester);
    await tester.ensureVisible(find.byKey(const Key('retentionTier.generous')));
    await tester.pump();
    final tier = tester.getSize(
      find.byKey(const Key('retentionTier.generous')),
    );
    await tester.tap(find.byKey(const Key('settingsTab.export')));
    await tester.pump();
    final jpeg = tester.getSize(find.byKey(const Key('exportFiletype.jpeg')));
    final webp = tester.getSize(
      find.byKey(const Key('exportFiletype.webpLossy')),
    );
    // Pre-migration values (printed on the unchanged lib code 2026-10-08:
    // tier=Size(112.7, 64.0) jpeg=Size(308.0, 32.0) webp=Size(308.0, 32.0)).
    expect(tier.width, moreOrLessEquals(112.7, epsilon: 0.05));
    expect(tier.height, 64.0);
    expect(jpeg, const Size(308.0, 32.0));
    expect(webp, const Size(308.0, 32.0));
    // Default state: jpeg selected, webpLossy unselected.
    expect(
      tester
          .widget<Material>(find.byKey(const Key('exportFiletype.webpLossy')))
          .color,
      t.surface,
    );
    expect(
      tester
          .widget<Material>(find.byKey(const Key('exportFiletype.jpeg')))
          .color,
      t.accent.withValues(alpha: 0.18),
    );
  });

  Widget host(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets('TC-1494 settingsSwitch: 34x20 r10 track, on/off colours, '
      'thumb side, toggled semantics, tap flips the value', (tester) async {
    for (final value in [true, false]) {
      bool? got;
      const k = Key('sw');
      await tester.pumpWidget(
        host(
          settingsSwitch(t, key: k, value: value, onChanged: (v) => got = v),
        ),
      );
      expect(tester.getSize(find.byKey(k)), const Size(34, 20));
      final containers = find.descendant(
        of: find.byKey(k),
        matching: find.byType(Container),
      );
      final boxes = tester.widgetList<Container>(containers).toList();
      final track = boxes[0].decoration! as BoxDecoration;
      final thumb = boxes[1].decoration! as BoxDecoration;
      expect(track.color, value ? t.accent : t.input);
      expect((track.border! as Border).top.color, value ? t.accent : t.border);
      expect(track.borderRadius, BorderRadius.circular(10));
      expect(thumb.color, value ? Colors.white : t.textDim);
      expect(tester.getSize(containers.last), const Size(12, 12));
      final trackRect = tester.getRect(find.byKey(k));
      final thumbRect = tester.getRect(containers.last);
      expect(
        value
            ? trackRect.right - thumbRect.right
            : thumbRect.left - trackRect.left,
        moreOrLessEquals(4, epsilon: 0.01),
      ); // 1 px border + 3 px inset
      expect(
        tester.getSemantics(find.byKey(k)),
        isSemantics(hasToggledState: true, isToggled: value),
      );
      await tester.tap(find.byKey(k));
      expect(got, !value);
    }
  });

  testWidgets('TC-1495 settingsSelectable fills: selected accent 18% + accent '
      'border; unselected none, or unselectedColor', (tester) async {
    Future<(Color?, Color)> probe({
      required bool selected,
      Color? unselected,
    }) async {
      const k = Key('sel');
      await tester.pumpWidget(
        host(
          settingsSelectable(
            t,
            key: k,
            selected: selected,
            unselectedColor: unselected,
            onTap: () {},
            child: const Text('x'),
          ),
        ),
      );
      final fill = tester.widget<Material>(find.byKey(k)).color;
      final box = tester.widget<Container>(
        find
            .descendant(of: find.byKey(k), matching: find.byType(Container))
            .first,
      );
      final border =
          ((box.decoration! as BoxDecoration).border! as Border).top.color;
      return (fill, border);
    }

    expect(await probe(selected: true), (
      t.accent.withValues(alpha: 0.18),
      t.accent,
    ));
    expect(await probe(selected: true, unselected: t.surface), (
      t.accent.withValues(alpha: 0.18),
      t.accent,
    ));
    expect(await probe(selected: false), (null, t.borderSoft));
    expect(await probe(selected: false, unselected: t.surface), (
      t.surface,
      t.borderSoft,
    ));
  });
}
