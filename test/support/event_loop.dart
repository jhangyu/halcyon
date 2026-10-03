import 'package:flutter_test/flutter_test.dart';

/// [rounds] zero-delay event-loop turns (microtasks + zero-duration timers).
/// NO default on purpose: every call site states its round count, so the
/// historic 24 / 40 / 8 drift between the old local copies stays visible.
Future<void> pumpEventLoop(int rounds) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Polls (10 ms real-time steps, up to [timeout]) until [condition] holds.
/// Never fails by itself: on timeout it returns false and the caller's own
/// `expect` reports the failure with its original reason. A fixed
/// [pumpEventLoop] count cannot wait for real I/O, so under CPU load it ends
/// before the work does.
Future<bool> pumpUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return true;
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
