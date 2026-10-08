import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:halcyon_flutter/providers/app_settings.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/views/settings_dialog/settings_summary_rail.dart';

// Separate from settings_dialog_test.dart so the rail item (Round 2 T8) and
// the Mouse Control tab (Round 2 T6) never edit the same file in parallel.
Future<AppState> pumpRail(WidgetTester tester, void Function(AppState) setUpState) async {
  SharedPreferences.setMockInitialValues({});
  await tester.binding.setSurfaceSize(const Size(400, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final state = AppState();
  addTearDown(state.dispose);
  setUpState(state);
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: state,
    child: const MaterialApp(home: Scaffold(body: SettingsSummaryRail())),
  ));
  await tester.pump();
  return state;
}
String railValue(WidgetTester t) =>
    t.widget<Text>(find.byKey(const Key('summaryRail.mouseNav'))).data!;

void main() {
  testWidgets('TC-1520 the rail shows "Off" when mouse navigation is off', (tester) async {
    await pumpRail(tester, (_) {});
    expect(find.text('Mouse navigation'), findsOneWidget);
    expect(railValue(tester), 'Off');
  },
      skip: true, // mousenav-R2 T8
  );

  testWidgets('TC-1521 the rail shows "On · L = Next" for the default direction', (tester) async {
    await pumpRail(tester, (s) => s.setMouseNavEnabled(true));
    expect(railValue(tester), 'On · L = Next');
  },
      skip: true, // mousenav-R2 T8
  );

  testWidgets('TC-1522 the rail shows "On · L = Previous" for the reversed '
      'direction', (tester) async {
    await pumpRail(tester, (s) {
      s.setMouseNavEnabled(true);
      s.setMouseNavMapping(MouseNavMapping.leftPrevious);
    });
    expect(railValue(tester), 'On · L = Previous');
  },
      skip: true, // mousenav-R2 T8
  );

  testWidgets('TC-1526 off shows "Off" even with the reversed direction stored',
      (tester) async {
    await pumpRail(tester, (s) => s.setMouseNavMapping(MouseNavMapping.leftPrevious));
    expect(railValue(tester), 'Off');
  },
      skip: true, // mousenav-R2 T8
  );
}
