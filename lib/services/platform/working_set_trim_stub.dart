import 'package:flutter/foundation.dart';

/// Inert stand-in used on build targets without a foreign-function interface
/// (the web build).
///
/// Every member mirrors the real implementation's surface exactly, so the
/// conditional selection in `working_set_trim.dart` is invisible to callers and
/// any drift between the two is a compile error rather than a runtime
/// surprise. Nothing here ever trims: there is no process working set to
/// release in a browser tab.
class WorkingSetTrim {
  WorkingSetTrim._();

  /// Surface parity with the real implementation's platform seam; there is no
  /// Windows on this target, so it is a constant false.
  @visibleForTesting
  static bool Function() debugPlatformIsWindows = () => false;

  /// Present for surface parity only; this build never trims, so the counters
  /// stay at zero.
  @visibleForTesting
  static int debugTrimNowCalls = 0;

  @visibleForTesting
  static int debugTrimAttempts = 0;

  @visibleForTesting
  static int debugShrinkTrimCalls = 0;

  static bool get isSupported => false;

  static void onPoolShrink() {}

  static bool trimNow() => false;

  @visibleForTesting
  static void debugReset() {
    debugPlatformIsWindows = () => false;
    debugTrimNowCalls = 0;
    debugTrimAttempts = 0;
    debugShrinkTrimCalls = 0;
  }
}
