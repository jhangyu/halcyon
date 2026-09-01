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

  static const Duration defaultIdleDelay = Duration(seconds: 2);
  static const Duration defaultMinTrimInterval = Duration(seconds: 10);

  @visibleForTesting
  static Duration idleDelay = defaultIdleDelay;

  @visibleForTesting
  static Duration minTrimInterval = defaultMinTrimInterval;

  @visibleForTesting
  static DateTime Function() debugClock = DateTime.now;

  /// Present for surface parity only; this build never trims, so the counters
  /// stay at zero.
  @visibleForTesting
  static int debugRequestCalls = 0;

  @visibleForTesting
  static int debugTrimNowCalls = 0;

  @visibleForTesting
  static int debugTrimAttempts = 0;

  static bool get isSupported => false;

  static void request() {}

  static bool trimNow() => false;

  @visibleForTesting
  static void debugReset() {
    idleDelay = defaultIdleDelay;
    minTrimInterval = defaultMinTrimInterval;
    debugClock = DateTime.now;
    debugRequestCalls = 0;
    debugTrimNowCalls = 0;
    debugTrimAttempts = 0;
  }
}
