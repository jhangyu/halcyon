import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/rename_rule.dart';
import 'package:halcyon_flutter/views/rename_dialog.dart';
import 'package:provider/provider.dart';

void main() {
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) =>
            AppState(
              exifReader: (paths, {onProgress}) async =>
                  [for (final _ in paths) null],
            ),
        child: const MaterialApp(home: Scaffold(body: RenameDialog())),
      ),
    );
    await tester.pump();
  }

  testWidgets('TC-052 every preset and every variable chip is rendered', (
    tester,
  ) async {
    await pump(tester);

    for (final preset in RenameRule.presets) {
      expect(find.text(preset.label), findsOneWidget);
    }
    expect(find.text(kCustomPresetLabel), findsOneWidget);

    for (final group in RenameRule.variableGroups) {
      for (final token in group.tokens) {
        expect(find.text(token), findsOneWidget, reason: token);
      }
    }
  });

  testWidgets('TC-053 an invalid rule disables Rename and shows the reason', (
    tester,
  ) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField), '{fstop}');
    await tester.pump();

    expect(find.textContaining('Unknown variable'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('TC-054 tapping a chip appends its token to the rule', (
    tester,
  ) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField), '{YYYY}');
    await tester.pump();
    // The chip groups sit below the fold of the editor pane's scroll view on
    // the 800x600 test surface; without this the tap lands outside the render
    // tree and silently does nothing.
    await tester.ensureVisible(find.text('{camera}'));
    await tester.pump();
    await tester.tap(find.text('{camera}'));
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '{YYYY}{camera}');
  });
}
