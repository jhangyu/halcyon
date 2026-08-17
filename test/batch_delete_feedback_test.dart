import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/views/batch_delete_feedback.dart';

void main() {
  // ponytail: matches the convention in test/widget_test.dart — the default
  // 800x600 test surface clips the SnackBarAction below the visible area,
  // making tester.tap on it miss. Not a code bug, an env sizing gap.
  Future<void> pumpTrigger(
    WidgetTester tester,
    BatchDeleteResult result, {
    void Function(String path)? revealInFinder,
  }) {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showBatchDeleteFeedback(
                context,
                result,
                revealInFinder: revealInFinder,
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('recycle success shows a 2.5s snackbar with a reveal action',
      (tester) async {
    await pumpTrigger(
      tester,
      const BatchDeleteResult(
        recycled: true,
        movedCount: 4,
        failures: [],
        trashDirPath: '/cards/DCIM/.trash',
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump();

    expect(
      find.text('已回收 4 個檔案到 .trash（未直接刪除，請自行清理）'),
      findsOneWidget,
    );
    expect(find.text('顯示'), findsOneWidget);
    expect(
      tester.widget<SnackBar>(find.byType(SnackBar)).duration,
      const Duration(milliseconds: 2500),
    );
  });

  testWidgets('reveal action calls the injected opener with the trash path',
      (tester) async {
    final opened = <String>[];
    await pumpTrigger(
      tester,
      const BatchDeleteResult(
        recycled: true,
        movedCount: 1,
        failures: [],
        trashDirPath: '/cards/DCIM/.trash',
      ),
      revealInFinder: opened.add,
    );
    await tester.tap(find.text('go'));
    // ponytail: SnackBar slides in over ~250ms; a single pump() leaves the
    // action button mid-transition and off the hit-test bounds, and a single
    // large pump(duration) jump doesn't settle the ticker either — only
    // several smaller pumps reliably drain the entrance animation. Advance
    // past it in steps before tapping.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('顯示'));
    await tester.pump();

    expect(opened, ['/cards/DCIM/.trash']);
  });

  testWidgets('failures show a blocking dialog listing each file',
      (tester) async {
    await pumpTrigger(
      tester,
      const BatchDeleteResult(
        recycled: true,
        movedCount: 1,
        failures: ['IMG_0001.jpg: Read-only file system'],
        trashDirPath: '/cards/DCIM/.trash',
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('IMG_0001.jpg'), findsOneWidget);
    expect(find.textContaining('Read-only file system'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('direct-delete success stays silent', (tester) async {
    await pumpTrigger(
      tester,
      const BatchDeleteResult(recycled: false, movedCount: 0, failures: []),
    );
    await tester.tap(find.text('go'));
    await tester.pump();

    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
