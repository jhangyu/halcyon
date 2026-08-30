import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/views/settings_dialog.dart';

Future<void> pumpDialog(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: Scaffold(body: SettingsDialog())),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('TC-354 the width slider is enabled and writes through '
      'when the machine allows parallel decodes', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(laneCeiling: 5);
    addTearDown(state.dispose);
    await pumpDialog(tester, state);

    final slider = tester.widget<Slider>(
      find.byKey(const Key('decodeLaneWidthSlider')),
    );
    expect(slider.onChanged, isNotNull);
    expect(slider.min, 1);
    expect(slider.max, 5);
    slider.onChanged!(4);
    await tester.pump();
    expect(state.decodeLaneWidth, 4);
  });

  testWidgets('TC-355 the row is shown but DISABLED on a machine whose '
      'ceiling is 1 (never hidden)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(laneCeiling: 1);
    addTearDown(state.dispose);
    await pumpDialog(tester, state);

    final finder = find.byKey(const Key('decodeLaneWidthSlider'));
    expect(finder, findsOneWidget, reason: 'a hidden control reads as a '
        'missing feature when the user compares two machines');
    expect(tester.widget<Slider>(finder).onChanged, isNull);
  });
}
