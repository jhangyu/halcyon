import 'package:flutter_test/flutter_test.dart';

/// [rounds] zero-delay event-loop turns (microtasks + zero-duration timers).
/// NO default on purpose: every call site states its round count, so the
/// historic 24 / 40 / 8 drift between the old local copies stays visible.
Future<void> pumpEventLoop(int rounds) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Runs a scheduled frame callback immediately (synchronously) instead of
/// waiting for a real frame, which a headless test binding never produces.
void immediateFrameCallback(void Function() callback) => callback();

/// Bounded stand-in for `pumpAndSettle()`: one pump, then 20 frames of 16 ms —
/// enough for dialog/menu/scroll animations without polling for full rest.
Future<void> settleFrames(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}
