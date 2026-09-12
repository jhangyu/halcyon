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
    expect(WorkingSetTrim.onPoolShrink, returnsNormally);
  });

  // TC-490 (surviving half, re-homed from the deleted rate-limit case)
  test('trimNow reaches the platform branch and its return tracks isSupported',
      () {
    // The return value is a different thing from "the trim was attempted":
    // it says whether the platform call was reached AND reported success.
    // Off Windows the call is a no-op and returns false; on a real Windows
    // host `SetProcessWorkingSetSize` legitimately returns true, so the
    // expectation must track `isSupported` rather than hard-coding the
    // non-Windows answer (same reason as TC-488's carve-out).
    final trimResult = WorkingSetTrim.trimNow();
    expect(trimResult, WorkingSetTrim.isSupported ? isTrue : isFalse);
    expect(WorkingSetTrim.debugTrimNowCalls, 1);
    expect(WorkingSetTrim.debugTrimAttempts, 1);
  });

  // TC-491
  test('debugReset clears the counters and restores the platform predicate',
      () {
    WorkingSetTrim.debugPlatformIsWindows = () => true;
    WorkingSetTrim.trimNow();
    WorkingSetTrim.onPoolShrink();

    WorkingSetTrim.debugReset();

    expect(WorkingSetTrim.debugTrimNowCalls, 0);
    expect(WorkingSetTrim.debugTrimAttempts, 0);
    expect(WorkingSetTrim.debugShrinkTrimCalls, 0);
    expect(WorkingSetTrim.debugPlatformIsWindows(), Platform.isWindows);
  });
}
