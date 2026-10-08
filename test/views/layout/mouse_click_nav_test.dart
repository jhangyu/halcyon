import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:halcyon_flutter/providers/app_settings.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/views/layout/common/mouse_click_nav.dart';
import '../../support/mouse_nav_fixtures.dart';

MouseNavAction? click({
  PointerDeviceKind kind = PointerDeviceKind.mouse,
  int buttons = kPrimaryButton,
  double travel = 0,
  int ms = 50,
  bool inside = true,
  MouseNavMapping mapping = MouseNavMapping.leftNext,
}) =>
    resolveClick(
        kind: kind,
        downButtons: buttons,
        maxTravel: travel,
        pressDuration: Duration(milliseconds: ms),
        releasedInside: inside,
        mapping: mapping);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('TC-1497 resolveClick truth table', () {
    test('2 buttons x 2 mappings', () {
      expect(click(), MouseNavAction.next);
      expect(click(buttons: kSecondaryButton), MouseNavAction.previous);
      expect(click(mapping: MouseNavMapping.leftPrevious),
          MouseNavAction.previous);
      expect(
          click(
              buttons: kSecondaryButton,
              mapping: MouseNavMapping.leftPrevious),
          MouseNavAction.next);
    });
    test('slop edge: 4.0 counts, 4.01 does not', () {
      expect(click(travel: 4.0), MouseNavAction.next);
      expect(click(travel: 4.01), isNull);
    });
    test('duration: 499 ms counts, 500 ms does not', () {
      expect(click(ms: 499), MouseNavAction.next);
      expect(click(ms: 500), isNull);
    });
    test('release outside, non-mouse kinds, chord, middle button', () {
      expect(click(inside: false), isNull);
      expect(click(kind: PointerDeviceKind.touch), isNull);
      expect(click(kind: PointerDeviceKind.stylus), isNull);
      expect(click(kind: PointerDeviceKind.trackpad), isNull);
      expect(click(buttons: kPrimaryButton | kSecondaryButton), isNull);
      expect(click(buttons: kMiddleMouseButton), isNull);
    });
  });

  Future<AppState> pumpNav(WidgetTester tester) async {
    final state = await loadMouseNavState(tester);
    state.setMouseNavEnabled(true);
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
            child: SizedBox(
                width: 400,
                height: 300,
                child: MouseClickNav(child: SizedBox.expand()))),
      ),
    ));
    return state;
  }

  Offset centre(WidgetTester t) => t.getCenter(find.byType(MouseClickNav));

  // nextPhoto/previousPhoto arm AppState's selection timers (250 ms EXIF
  // debounce, 5 s timer in selectItem); flush them so none is pending at
  // teardown -- same 6 s flush as main_screen_shortcuts_test.dart.
  Future<void> flushNavTimers(WidgetTester t) =>
      t.pump(const Duration(seconds: 6));

  testWidgets('TC-1498 a cancelled press does not navigate', (tester) async {
    final state = await pumpNav(tester);
    final g = await tester.startGesture(centre(tester),
        kind: PointerDeviceKind.mouse);
    await g.cancel();
    await tester.pump();
    expect(state.selectedItemID, 'IMG_0002');
    await mouseClick(tester, centre(tester));
    expect(state.selectedItemID, 'IMG_0003',
        reason: 'control: a clean click navigates');
    await flushNavTimers(tester);
  });

  testWidgets('TC-1499 a button change mid-press does not navigate',
      (tester) async {
    final state = await pumpNav(tester);
    final g =
        await tester.createGesture(pointer: 7, kind: PointerDeviceKind.mouse);
    await g.down(centre(tester));
    await g.updateWithCustomEvent(PointerMoveEvent(
        pointer: 7,
        position: centre(tester),
        buttons: kPrimaryButton | kSecondaryButton,
        kind: PointerDeviceKind.mouse,
        timeStamp: const Duration(milliseconds: 20)));
    await g.up(timeStamp: const Duration(milliseconds: 40));
    await tester.pump();
    expect(state.selectedItemID, 'IMG_0002');
    await mouseClick(tester, centre(tester));
    expect(state.selectedItemID, 'IMG_0003');
    await flushNavTimers(tester);
  });

  testWidgets('TC-1500 a drag that returns to its start is still a drag',
      (tester) async {
    final state = await pumpNav(tester);
    final g = await tester.startGesture(centre(tester),
        kind: PointerDeviceKind.mouse);
    await g.moveBy(const Offset(10, 0),
        timeStamp: const Duration(milliseconds: 20));
    await g.moveBy(const Offset(-10, 0),
        timeStamp: const Duration(milliseconds: 40));
    await g.up(timeStamp: const Duration(milliseconds: 60));
    await tester.pump();
    expect(state.selectedItemID, 'IMG_0002');
    await mouseClick(tester, centre(tester));
    expect(state.selectedItemID, 'IMG_0003');
    await flushNavTimers(tester);
  });

  testWidgets(
      'TC-1501 a release outside the area does not navigate; a clean '
      'right click goes back', (tester) async {
    final state = await pumpNav(tester);
    // 3 px travel stays under the slop, but the release lands outside:
    // start 2 px inside the right edge, move 3 px right.
    final nearEdge =
        tester.getTopRight(find.byType(MouseClickNav)) + const Offset(-2, 150);
    await mouseClick(tester, nearEdge, travel: const Offset(3, 0));
    expect(state.selectedItemID, 'IMG_0002');
    await mouseClick(tester, centre(tester), buttons: kSecondaryButton);
    expect(state.selectedItemID, 'IMG_0001');
    await flushNavTimers(tester);
  });
}
