import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

// BOOL SetProcessWorkingSetSize(HANDLE, SIZE_T, SIZE_T)
typedef _SetProcessWorkingSetSizeNative =
    ffi.Int32 Function(ffi.IntPtr, ffi.IntPtr, ffi.IntPtr);
typedef _SetProcessWorkingSetSizeDart = int Function(int, int, int);

// HANDLE GetCurrentProcess(void)
typedef _GetCurrentProcessNative = ffi.IntPtr Function();
typedef _GetCurrentProcessDart = int Function();

/// Asks the host OS to release this process's resident working set.
///
/// On Windows this calls `SetProcessWorkingSetSize(GetCurrentProcess(), -1,
/// -1)` from `kernel32.dll`, which Microsoft documents as equivalent to
/// `EmptyWorkingSet`. It was chosen over `EmptyWorkingSet` because
/// `SetProcessWorkingSetSize` has always lived in `kernel32.dll` under one
/// name, whereas the empty-working-set call is `EmptyWorkingSet` in
/// `psapi.dll` and `K32EmptyWorkingSet` in `kernel32.dll` -- and a wrong pick
/// there is a runtime `ArgumentError` from `lookupFunction`, not a compile
/// error. Both require the same privilege (`PROCESS_SET_QUOTA` on the
/// current-process pseudo-handle, always held).
///
/// The handle returned by `GetCurrentProcess()` is a PSEUDO-handle and must
/// NOT be closed; there is deliberately no handle-close binding here.
///
/// What this does and does not buy: the trim moves pages to the standby /
/// pagefile list, so the working-set READING drops. It is not a reduction in
/// allocation, and must never be reported as one.
///
/// This intentionally branches on `Platform.isWindows` (a deviation from this
/// repo's C-3 "no platform-conditional branches in lib/" convention) --
/// isolated to this single file, as C-3's own carve-out allows, exactly like
/// `device_memory.dart`. Nothing else in `lib/` names Windows, kernel32 or the
/// foreign-function interface: `working_set_trim.dart` is a facade holding one
/// conditional export, and `working_set_trim_stub.dart` is its inert web
/// counterpart. Every call site (see `AppState.loadFolder` and
/// `AppState.selectItem`) calls an unconditional, platform-neutral method and
/// contains no `Platform.isX`, no `dart:ffi` import and no Windows-specific
/// naming. On every non-Windows platform the methods return immediately and
/// report "not supported"; on the web build the stub does the same.
///
/// Never throws. Any failure -- library missing, symbol missing, unexpected
/// exception -- permanently disables the mechanism for the rest of the
/// process; a `false` return FROM Windows means only "the trim was declined"
/// and leaves the mechanism enabled.
class WorkingSetTrim {
  WorkingSetTrim._();

  /// Quiet period a [request] waits out before trimming. Deliberately far
  /// longer than the 250 ms tier-2 navigation debounce and on its OWN timer:
  /// trimming at 250 ms of quiet would page out buffers the tier-2 sweep is
  /// about to touch.
  static const Duration defaultIdleDelay = Duration(seconds: 2);

  /// Floor between two [request]-driven trims. A guard against pathological
  /// repeat cost, not a scheduling policy -- the call sites decide when a trim
  /// is wanted. [trimNow] bypasses it.
  static const Duration defaultMinTrimInterval = Duration(seconds: 10);

  @visibleForTesting
  static Duration idleDelay = defaultIdleDelay;

  @visibleForTesting
  static Duration minTrimInterval = defaultMinTrimInterval;

  /// Injectable clock so the rate limit is testable without real time.
  @visibleForTesting
  static DateTime Function() debugClock = DateTime.now;

  @visibleForTesting
  static int debugRequestCalls = 0;

  @visibleForTesting
  static int debugTrimNowCalls = 0;

  /// Trims that got past the rate limit -- i.e. the platform call was reached.
  /// Counted on every platform, so the debounce/rate-limit logic is testable
  /// off Windows where the platform call itself is a no-op.
  @visibleForTesting
  static int debugTrimAttempts = 0;

  static Timer? _idleTimer;
  static DateTime? _lastTrimAt;
  static bool _resolved = false;
  static bool _disabled = false;
  static _SetProcessWorkingSetSizeDart? _setProcessWorkingSetSize;
  static _GetCurrentProcessDart? _getCurrentProcess;

  /// True on Windows when the kernel32 bindings resolved. False everywhere
  /// else, and false once a failure has permanently disabled the mechanism.
  static bool get isSupported {
    if (!Platform.isWindows || _disabled) return false;
    _resolveBindings();
    return !_disabled &&
        _setProcessWorkingSetSize != null &&
        _getCurrentProcess != null;
  }

  /// Fire-and-forget. Rate-limited and idle-debounced internally; safe to call
  /// on any platform, at any frequency. Never throws.
  static void request() {
    debugRequestCalls++;
    _idleTimer?.cancel();
    _idleTimer = Timer(idleDelay, () {
      _idleTimer = null;
      _performTrim(bypassRateLimit: false);
    });
  }

  /// Performs the trim NOW, bypassing the rate limit. Returns true only when
  /// the platform call was made and reported success.
  static bool trimNow() {
    debugTrimNowCalls++;
    return _performTrim(bypassRateLimit: true);
  }

  @visibleForTesting
  static void debugReset() {
    _idleTimer?.cancel();
    _idleTimer = null;
    _lastTrimAt = null;
    _resolved = false;
    _disabled = false;
    _setProcessWorkingSetSize = null;
    _getCurrentProcess = null;
    idleDelay = defaultIdleDelay;
    minTrimInterval = defaultMinTrimInterval;
    debugClock = DateTime.now;
    debugRequestCalls = 0;
    debugTrimNowCalls = 0;
    debugTrimAttempts = 0;
  }

  static bool _performTrim({required bool bypassRateLimit}) {
    final now = debugClock();
    final last = _lastTrimAt;
    if (!bypassRateLimit &&
        last != null &&
        now.difference(last) < minTrimInterval) {
      return false;
    }
    _lastTrimAt = now;
    debugTrimAttempts++;

    if (!Platform.isWindows || _disabled) return false;
    try {
      _resolveBindings();
      final setSize = _setProcessWorkingSetSize;
      final currentProcess = _getCurrentProcess;
      if (setSize == null || currentProcess == null) return false;
      // (SIZE_T)-1 for both limits is the documented "empty the working set"
      // request. A zero (FALSE) return means Windows declined it -- that is
      // not an error and must NOT disable the mechanism.
      return setSize(currentProcess(), -1, -1) != 0;
    } catch (_) {
      _disabled = true;
      return false;
    }
  }

  /// At most one `DynamicLibrary.open` + two `lookupFunction` calls per
  /// process. No retry loop: a failure here is permanent by design.
  static void _resolveBindings() {
    if (_resolved || _disabled) return;
    _resolved = true;
    try {
      final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
      _setProcessWorkingSetSize = kernel32.lookupFunction<
          _SetProcessWorkingSetSizeNative,
          _SetProcessWorkingSetSizeDart>('SetProcessWorkingSetSize');
      _getCurrentProcess = kernel32
          .lookupFunction<_GetCurrentProcessNative, _GetCurrentProcessDart>(
            'GetCurrentProcess',
          );
    } catch (_) {
      _disabled = true;
      _setProcessWorkingSetSize = null;
      _getCurrentProcess = null;
    }
  }
}
