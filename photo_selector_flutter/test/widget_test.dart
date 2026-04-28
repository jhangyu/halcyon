import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:photo_selector_flutter/main.dart';
import 'package:photo_selector_flutter/providers/app_state.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('PhotoSelectorApp renders empty-folder prompt', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState(),
        child: const PhotoSelectorApp(),
      ),
    );

    expect(find.text('Select a folder to begin'), findsOneWidget);
    expect(find.text('Open Folder'), findsOneWidget);
  });
}
