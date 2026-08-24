import 'dart:io';

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
    Future<String?> Function(String path)? revealInFinder,
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

  test('reveal builds the right command per OS and surfaces failure',
      () async {
    final calls = <(String, List<String>)>[];
    Future<ProcessResult> fake(String cmd, List<String> args) async {
      calls.add((cmd, args));
      return ProcessResult(1, 1, '', 'boom'); // nonzero: must be surfaced
    }

    final failed = await revealInFileManager('/p/photo.jpg',
        os: 'macos', runProcess: fake);
    // NOTE (deviation from m6-execution-plan.md P4.2 Step 1 snippet):
    // record equality (`expect(calls.single, (cmd, args))`) is field-wise
    // `==`, and List doesn't override `==` (identity-based) — two distinct
    // List instances with equal contents are never `==`. Split into
    // per-field assertions (matching the plan's own Windows-case pattern,
    // which already does this) so the test actually exercises deep
    // equality on the args list.
    expect(calls.single.$1, 'open');
    expect(calls.single.$2, ['-R', '/p/photo.jpg']);
    expect(failed, isNotNull); // human-readable failure string
    calls.clear();
    await revealInFileManager(r'C:\p\photo.jpg', os: 'windows', runProcess: fake);
    expect(calls.single.$1, 'explorer');
    expect(calls.single.$2, ['/select,', r'C:\p\photo.jpg']);
    calls.clear();
    await revealInFileManager('/p/photo.jpg', os: 'linux', runProcess: fake);
    expect(calls.single.$1, 'xdg-open');
    expect(calls.single.$2, ['/p']); // folder-open only, per ruling
  });
}
