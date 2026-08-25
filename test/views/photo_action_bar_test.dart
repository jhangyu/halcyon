import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/views/photo_action_bar.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // ponytail: testWidgets bodies run inside a FakeAsync zone, so real
  // dart:io work (temp dir + file writes + AppState.loadFolder's real
  // Directory scan) never completes unless it runs via tester.runAsync —
  // otherwise the test hangs until the suite timeout. See
  // docs/logs/2026-08-16 handoff note "FakeAsync 掛死" for the same class
  // of bug. Wrapping here keeps every assertion identical to the plan.
  Future<AppState> stateForFolder(
    WidgetTester tester, {
    required bool withSibling,
  }) async {
    late AppState state;
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('halcyon_bar_');
      addTearDown(() => dir.delete(recursive: true));
      await File(p.join(dir.path, 'IMG_0001.jpg')).writeAsBytes([1, 2, 3]);
      if (withSibling) {
        await File(p.join(dir.path, 'IMG_0001.dng')).writeAsBytes([1, 2, 3]);
      }
      state = AppState(
        imageLoader: (path, {required purpose}) async {
          return NativeImageBytes(Uint8List.fromList([1, 2, 3]));
        },
      );
      await state.loadFolder(dir);
    });
    return state;
  }

  Future<void> pumpBar(WidgetTester tester, AppState state) {
    return tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(
            body: Consumer<AppState>(
              builder: (context, s, _) =>
                  PhotoActionBar(item: s.currentItem!),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('direct mode shows the trash can icons', (tester) async {
    final state = await stateForFolder(tester, withSibling: false);
    await pumpBar(tester, state);

    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    expect(find.byIcon(Icons.restore_from_trash_outlined), findsNothing);

    state.markCurrent(PhotoStatus.trashed);
    await tester.pump();

    expect(find.byIcon(Icons.delete), findsOneWidget);
  });

  testWidgets('recycle mode shows the restore-from-trash icons',
      (tester) async {
    final state = await stateForFolder(tester, withSibling: true);
    expect(state.recycleMode, isTrue);
    await pumpBar(tester, state);

    expect(find.byIcon(Icons.restore_from_trash_outlined), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsNothing);

    state.markCurrent(PhotoStatus.trashed);
    await tester.pump();

    expect(find.byIcon(Icons.restore_from_trash), findsOneWidget);
  });

}
