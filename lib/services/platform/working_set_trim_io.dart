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
/// counterpart. Every call site (see `AppState.loadFolder` and the
/// pool shrink→trim hook installed by `ensureHalcyonDecodePoolConfigured`)
/// calls an unconditional, platform-neutral method and contains no
/// `Platform.isX`, no `dart:ffi` import and no Windows-specific naming. On every non-Windows platform the methods return immediately and
/// report "not supported"; on the web build the stub does the same.
///
/// Never throws. Any failure -- library missing, symbol missing, unexpected
/// exception -- permanently disables the mechanism for the rest of the
/// process; a `false` return FROM Windows means only "the trim was declined"
/// and leaves the mechanism enabled.
class WorkingSetTrim {
  WorkingSetTrim._();

  /// Injectable platform predicate, so the Windows-only branches are testable
  /// on a POSIX host. Mirrors the injectable-seam convention the pool uses for
  /// its clock.
  @visibleForTesting
  static bool Function() debugPlatformIsWindows = () => Platform.isWindows;

  @visibleForTesting
  static int debugTrimNowCalls = 0;

  /// Trims that reached the platform branch. Counted on every platform, so
  /// the wiring is testable off Windows where the platform call itself is a
  /// no-op.
  @visibleForTesting
  static int debugTrimAttempts = 0;

  /// [onPoolShrink] entries, counted on every platform — so "the hook is
  /// installed and fired" is assertable separately from "the platform call
  /// was reached" ([debugTrimAttempts]).
  @visibleForTesting
  static int debugShrinkTrimCalls = 0;

  static bool _resolved = false;
  static bool _disabled = false;
  static _SetProcessWorkingSetSizeDart? _setProcessWorkingSetSize;
  static _GetCurrentProcessDart? _getCurrentProcess;

  /// True on Windows when the kernel32 bindings resolved. False everywhere
  /// else, and false once a failure has permanently disabled the mechanism.
  static bool get isSupported {
    if (!debugPlatformIsWindows() || _disabled) return false;
    _resolveBindings();
    return !_disabled &&
        _setProcessWorkingSetSize != null &&
        _getCurrentProcess != null;
  }

  /// Called when the ceyx native buffer pool has COMPLETED an idle shrink and
  /// really freed buffers (`CeyxNativeBufferPool.onShrink`). Never throws.
  ///
  /// The trim is coupled to shrink completion rather than to idleness, and
  /// there is deliberately no idle-delayed entry point any more. The pool
  /// keeps a fixed set of ~100MB RGBA slots resident precisely so a returned
  /// buffer is reusable IMMEDIATELY; an idle-coupled trim pages out exactly
  /// those slots and turns the pool's whole reason for existing into a
  /// page-fault storm on the next decode. After a shrink the opposite holds:
  /// those slots have just been freed, so nothing is about to re-touch them
  /// and returning their pages to the OS is unambiguously right.
  ///
  /// No debounce and no rate limit: the caller is already the rare event (a
  /// shrink needs 5 s of continuous decode quiescence plus a 1 s grow
  /// lockout), and the contract is exactly one trim per shrink completion.
  static void onPoolShrink() {
    debugShrinkTrimCalls++;
    _performTrim();
  }

  /// Performs the trim NOW. Returns true only when the platform call was made
  /// and reported success.
  static bool trimNow() {
    debugTrimNowCalls++;
    return _performTrim();
  }

  @visibleForTesting
  static void debugReset() {
    _resolved = false;
    _disabled = false;
    _setProcessWorkingSetSize = null;
    _getCurrentProcess = null;
    debugPlatformIsWindows = () => Platform.isWindows;
    debugTrimNowCalls = 0;
    debugTrimAttempts = 0;
    debugShrinkTrimCalls = 0;
  }

  static bool _performTrim() {
    // Bumped BEFORE the platform branch, which is what makes the counter
    // meaningful off Windows (and on a POSIX host with the predicate forced
    // true, where the kernel32 binding necessarily fails). Preserve this
    // ordering.
    debugTrimAttempts++;

    if (!debugPlatformIsWindows() || _disabled) return false;
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
