import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/platform/working_set_trim.dart';

void main() {
  setUp(WorkingSetTrim.debugReset);
  tearDown(WorkingSetTrim.debugReset);

  // TC-488
  test('is unsupported and inert off Windows, and never throws', () {
    if (Platform.isWindows) {
      // On a Windows host this assertion is meaningless; the Windows-side
      // evidence is the manual run recorded under docs/logs/.
      return;
    }
    expect(WorkingSetTrim.isSupported, isFalse);
    expect(WorkingSetTrim.trimNow(), isFalse);
    expect(WorkingSetTrim.request, returnsNormally);
  });

  // TC-489
  test('a burst of request() calls coalesces into exactly one trim', () async {
    WorkingSetTrim.idleDelay = const Duration(milliseconds: 20);
    WorkingSetTrim.request();
    WorkingSetTrim.request();
    WorkingSetTrim.request();
    WorkingSetTrim.request();
    expect(WorkingSetTrim.debugRequestCalls, 4);
    expect(
      WorkingSetTrim.debugTrimAttempts,
      0,
      reason: 'nothing may trim before the idle delay elapses',
    );

    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(WorkingSetTrim.debugTrimAttempts, 1);
  });

  // TC-490
  test('request() is rate-limited but trimNow() bypasses the limit', () async {
    WorkingSetTrim.idleDelay = const Duration(milliseconds: 20);
    WorkingSetTrim.minTrimInterval = const Duration(seconds: 10);
    var now = DateTime(2026, 9, 1, 12, 0, 0);
    WorkingSetTrim.debugClock = () => now;

    WorkingSetTrim.request();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(WorkingSetTrim.debugTrimAttempts, 1);

    // 3 virtual seconds later -- still inside the 10 s window.
    now = now.add(const Duration(seconds: 3));
    WorkingSetTrim.request();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(
      WorkingSetTrim.debugTrimAttempts,
      1,
      reason: 'a second request inside the rate-limit window is suppressed',
    );

    // trimNow() is the folder-switch trigger and deliberately ignores the
    // rate limit above -- that is what debugTrimAttempts below proves. Its
    // own return value is a different thing: whether the underlying
    // platform call was reached AND reported success. Off Windows (and on
    // Windows if kernel32 binding somehow failed) the call is a no-op and
    // returns false; on a real Windows host `SetProcessWorkingSetSize`
    // legitimately returns true, so the expectation must track
    // `isSupported` rather than hard-coding the non-Windows answer (see
    // TC-488's own `Platform.isWindows` carve-out for the same reason).
    final trimResult = WorkingSetTrim.trimNow();
    expect(trimResult, WorkingSetTrim.isSupported ? isTrue : isFalse);
    expect(WorkingSetTrim.debugTrimNowCalls, 1);
    expect(WorkingSetTrim.debugTrimAttempts, 2);

    // Past the window, request() is allowed through again.
    now = now.add(const Duration(seconds: 11));
    WorkingSetTrim.request();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(WorkingSetTrim.debugTrimAttempts, 3);
  });

  // TC-491
  test('debugReset cancels an armed idle timer and clears the counters', () async {
    WorkingSetTrim.idleDelay = const Duration(milliseconds: 20);
    WorkingSetTrim.request();
    WorkingSetTrim.debugReset();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(WorkingSetTrim.debugRequestCalls, 0);
    expect(WorkingSetTrim.debugTrimAttempts, 0);
    expect(WorkingSetTrim.idleDelay, WorkingSetTrim.defaultIdleDelay);
    expect(
      WorkingSetTrim.minTrimInterval,
      WorkingSetTrim.defaultMinTrimInterval,
    );
  });
}
