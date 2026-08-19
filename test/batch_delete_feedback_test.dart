import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/views/batch_delete_feedback.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppState> pumpTrigger(
    WidgetTester tester,
    BatchDeleteResult result,
  ) async {
    final state = AppState();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showBatchDeleteFeedback(context, result),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    );
    return state;
  }

  testWidgets('recycle success posts a status message with the trash path', (
    tester,
  ) async {
    final state = await pumpTrigger(
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

    expect(state.status?.text, '已回收 *4* 個檔案到 .trash（未直接刪除，請自行清理）');
    expect(state.status?.revealPath, '/cards/DCIM/.trash');
  });

  testWidgets('failures show a blocking dialog listing each file', (
    tester,
  ) async {
    final state = await pumpTrigger(
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
    expect(state.status, isNull, reason: 'the dialog is the only feedback');
  });

  testWidgets('direct-delete success stays silent', (tester) async {
    final state = await pumpTrigger(
      tester,
      const BatchDeleteResult(recycled: false, movedCount: 0, failures: []),
    );
    await tester.tap(find.text('go'));
    await tester.pump();

    expect(state.status, isNull);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
