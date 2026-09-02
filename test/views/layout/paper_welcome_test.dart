// TC-571..TC-575: PaperEmptyState geometry/alignment per
// docs/logs/2026-09-01/mockup/paper/NOTES.md "Frame 8 — welcome, no folder
// open" and the "Alignment is the part that was specified rather than left
// to taste" section (the gallery-borrowed defect: nothing may share a row
// with the Open Folder button).
//
// NOT WIRED into photo_viewport.dart yet (see task #12 handoff to
// team-lead) — these tests pump PaperEmptyState directly.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/views/layout/paper/paper_palette.dart';
import 'package:halcyon_flutter/views/layout/paper/paper_welcome.dart';

Future<void> _pump(WidgetTester tester) async {
  final appState = AppState();
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: appState,
      child: MaterialApp(
        theme: paperThemeData(Brightness.light),
        home: const Scaffold(body: PaperEmptyState()),
      ),
    ),
  );
}

void main() {
  testWidgets('TC-571 empty mount is 432x288 (photo\'s own 3:2)', (tester) async {
    await _pump(tester);
    final size = tester.getSize(find.byKey(PaperEmptyState.mountKey));
    expect(size, const Size(432, 288));
    expect(size.width / size.height, closeTo(1.5, 0.001));
  });

  testWidgets('TC-572 headline reads "No folder open"', (tester) async {
    await _pump(tester);
    expect(find.text('No folder open'), findsOneWidget);
  });

  testWidgets('TC-573 Open Folder button and hint sit on the same centre axis',
      (tester) async {
    await _pump(tester);
    final content = tester.getCenter(find.byKey(PaperEmptyState.mountKey)).dx;
    final button = tester.getCenter(find.byKey(PaperEmptyState.buttonKey)).dx;
    final hint = tester.getCenter(find.byKey(PaperEmptyState.hintKey)).dx;
    expect(button, closeTo(content, 1.0));
    expect(hint, closeTo(content, 1.0));
  });

  testWidgets(
      'TC-574 the Open Folder button is alone on its row (no sibling shares '
      'its Row — the gallery-borrowed off-axis defect)', (tester) async {
    await _pump(tester);
    final buttonFinder = find.byKey(PaperEmptyState.buttonKey);
    final hintCenter = tester.getCenter(find.byKey(PaperEmptyState.hintKey));
    final buttonRect = tester.getRect(buttonFinder);
    // The hint must not be on the same horizontal band as the button (i.e.
    // it is a separate line below it, not sharing its row).
    expect(hintCenter.dy, greaterThan(buttonRect.bottom));
  });

  testWidgets('TC-575 drop hint mentions the folder shortcut', (tester) async {
    await _pump(tester);
    final hint = tester.widget<Text>(find.byKey(PaperEmptyState.hintKey));
    final text = hint.textSpan?.toPlainText() ?? '';
    expect(text, contains('O'));
    expect(text, contains('drop a folder'));
  });
}
