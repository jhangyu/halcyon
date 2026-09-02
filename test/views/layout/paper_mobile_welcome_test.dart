// TC-625..TC-630: PaperMobileEmptyState per mockup frame 4 ("Welcome — no
// folder open"), c1-mobile-{light,dark}.html:363-364, NOTES.md.
//
// NOT WIRED into photo_viewport.dart's empty-state gate yet (that gate is
// keyed on theme id only, not platform — see task #16 handoff to
// team-lead). These tests pump PaperMobileEmptyState directly, same pattern
// as paper_welcome_test.dart used for the desktop PaperEmptyState.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/views/layout/paper/paper_mobile.dart';
import 'package:halcyon_flutter/views/layout/paper/paper_palette.dart';

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final appState = AppState();
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: appState,
      child: MaterialApp(
        theme: paperThemeData(Brightness.light),
        home: const Scaffold(body: PaperMobileEmptyState()),
      ),
    ),
  );
}

void main() {
  testWidgets('TC-625 empty mount is 300x200 (photo\'s own 3:2, mobile scale)',
      (tester) async {
    await _pump(tester);
    final size = tester.getSize(find.byKey(PaperMobileEmptyState.mountKey));
    expect(size, const Size(300, 200));
    expect(size.width / size.height, closeTo(1.5, 0.001));
  });

  testWidgets('TC-626 headline reads "No folder open"', (tester) async {
    await _pump(tester);
    expect(find.text('No folder open'), findsOneWidget);
  });

  testWidgets('TC-627 button and hint sit on the same centre axis (mobile scale)',
      (tester) async {
    await _pump(tester);
    final content =
        tester.getCenter(find.byKey(PaperMobileEmptyState.mountKey)).dx;
    final button =
        tester.getCenter(find.byKey(PaperMobileEmptyState.buttonKey)).dx;
    final hint = tester.getCenter(find.byKey(PaperMobileEmptyState.hintKey)).dx;
    expect(button, closeTo(content, 1.0));
    expect(hint, closeTo(content, 1.0));
  });

  testWidgets('TC-628 the drop hint carries NO keyboard-shortcut prefix '
      '(mobile has no chord to show, unlike desktop\'s "⌘O or…")',
      (tester) async {
    await _pump(tester);
    final hint = tester.widget<Text>(find.byKey(PaperMobileEmptyState.hintKey));
    expect(hint.data, 'or drop a folder onto the window');
    expect(hint.data, isNot(contains('⌘')));
  });

  testWidgets('TC-629 the Open Folder button meets the 44pt mobile touch-target '
      'floor (mockup: height bumped 36->44 after the darkroom mobile-button '
      'user rejection)', (tester) async {
    await _pump(tester);
    final size = tester.getSize(find.byKey(PaperMobileEmptyState.buttonKey));
    expect(size.height, greaterThanOrEqualTo(44));
  });

  testWidgets('TC-630 fills the phone viewport without overflow', (tester) async {
    await _pump(tester);
    expect(tester.takeException(), isNull);
    final size = tester.getSize(find.byType(PaperMobileEmptyState));
    expect(size, const Size(390, 844));
  });
}
