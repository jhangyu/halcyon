import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/views/status_line.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppState> pumpLine(
    WidgetTester tester, {
    void Function(String path)? revealInFinder,
  }) async {
    final state = AppState();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(
            body: Stack(
              alignment: Alignment.bottomCenter,
              children: [StatusLine(revealInFinder: revealInFinder)],
            ),
          ),
        ),
      ),
    );
    return state;
  }

  double opacityOf(WidgetTester tester) =>
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;

  testWidgets('holds for 2.5s, fades over 0.5s, gone at 3.0s', (tester) async {
    final state = await pumpLine(tester);
    state.showStatus(const StatusMessage('此卷宗為*唯讀*，標記不會被儲存'));
    await tester.pump();

    expect(find.textContaining('唯讀'), findsOneWidget);
    expect(opacityOf(tester), 1.0);

    // Still fully opaque just before the hold expires.
    await tester.pump(const Duration(milliseconds: 2400));
    expect(opacityOf(tester), 1.0);

    // Fade starts at 2.5s and takes 500ms.
    await tester.pump(const Duration(milliseconds: 200));
    expect(opacityOf(tester), 0.0, reason: 'target opacity flipped');
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(AnimatedOpacity), findsOneWidget, reason: 'mid-fade');

    await tester.pumpAndSettle();
    expect(find.textContaining('唯讀'), findsNothing);
  });

  testWidgets('a second message restarts the timer', (tester) async {
    final state = await pumpLine(tester);
    state.showStatus(const StatusMessage('第一則'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2400));

    state.showStatus(const StatusMessage('第二則'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2000));

    expect(find.text('第二則'), findsOneWidget);
    expect(opacityOf(tester), 1.0, reason: 'old timer must not fire');
    await tester.pumpAndSettle();
  });

  test('emphasisSpans colours only the starred runs', () {
    const accent = Color(0xFFFFD34D);
    final spans = emphasisSpans('此卷宗為*唯讀*，不會儲存', accent);

    expect(spans.map((s) => s.text), ['此卷宗為', '唯讀', '，不會儲存']);
    expect(spans[0].style, isNull);
    expect(spans[1].style?.color, accent);
    expect(spans[2].style, isNull);
  });

  testWidgets('TC-056 an action message renders a button that fires once',
      (tester) async {
    var taps = 0;
    final state = AppState();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: StatusLine())),
      ),
    );

    state.showStatus(
      StatusMessage('已重新命名 *3* 個項目',
          actionLabel: '還原', onAction: () => taps++),
    );
    await tester.pump();

    expect(find.text('還原'), findsOneWidget);
    await tester.tap(find.text('還原'));
    expect(taps, 1);
  });
}
