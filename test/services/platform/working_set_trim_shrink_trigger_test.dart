import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/platform/working_set_trim.dart';

/// P5 (win-parity campaign): the working-set trim is coupled to POOL SHRINK
/// COMPLETION, never to idleness.
///
/// Every assertion here is counter-based. On a POSIX host with the platform
/// predicate forced true, `_resolveBindings()` reaches
/// `DynamicLibrary.open('kernel32.dll')`, which throws and permanently
/// disables the mechanism — so the boolean return is false even though the
/// entry point and the platform branch were both reached. The counters are
/// what carry meaning off Windows; the boolean is deliberately never asserted.
void main() {
  setUp(WorkingSetTrim.debugReset);
  tearDown(WorkingSetTrim.debugReset);

  // TC-1266
  test('onPoolShrink on a simulated Windows platform trims exactly once', () {
    WorkingSetTrim.debugPlatformIsWindows = () => true;

    WorkingSetTrim.onPoolShrink();

    expect(WorkingSetTrim.debugShrinkTrimCalls, 1);
    expect(WorkingSetTrim.debugTrimAttempts, 1);
  });

  // TC-1267
  test('onPoolShrink is inert off Windows', () {
    if (Platform.isWindows) {
      // On a real Windows host the default predicate is true, so there is no
      // "off Windows" to observe here (mirrors TC-488's carve-out).
      return;
    }

    WorkingSetTrim.onPoolShrink();

    expect(
      WorkingSetTrim.debugShrinkTrimCalls,
      1,
      reason: 'the entry point is reached on every platform',
    );
    // `debugTrimAttempts` is bumped BEFORE the platform branch by design
    // (D-P5-5 ordering), so it counts entries into the trim, not platform
    // calls. "Inert" is therefore expressed as: the mechanism reports
    // unsupported and the trim declines, while nothing throws.
    expect(WorkingSetTrim.debugTrimAttempts, 1);
    expect(
      WorkingSetTrim.isSupported,
      isFalse,
      reason: 'there is no working set to trim off Windows',
    );
    expect(WorkingSetTrim.trimNow(), isFalse);
  });

  // TC-1268
  test('two shrink completions trim twice', () {
    WorkingSetTrim.debugPlatformIsWindows = () => true;

    WorkingSetTrim.onPoolShrink();
    WorkingSetTrim.onPoolShrink();

    // No clock movement between the two: shrink completion is already the
    // rare event, so there is no rate limit to swallow the second trim.
    expect(WorkingSetTrim.debugTrimAttempts, 2);
    expect(WorkingSetTrim.debugShrinkTrimCalls, 2);
  });

  // TC-1269
  test('onPoolShrink never throws when kernel32 cannot be opened', () {
    if (Platform.isWindows) {
      return;
    }
    WorkingSetTrim.debugPlatformIsWindows = () => true;

    expect(WorkingSetTrim.onPoolShrink, returnsNormally);
    // The binding failure is swallowed and permanently disables the
    // mechanism; a second completion must still be safe, and `isSupported`
    // reports the disabled state without re-attempting the open.
    expect(WorkingSetTrim.onPoolShrink, returnsNormally);
    expect(WorkingSetTrim.isSupported, isFalse);
    expect(WorkingSetTrim.debugShrinkTrimCalls, 2);
    expect(WorkingSetTrim.debugTrimAttempts, 2);
  });
}
