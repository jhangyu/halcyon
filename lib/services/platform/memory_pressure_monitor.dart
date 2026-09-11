import 'dart:async';

import 'package:flutter/services.dart';

/// Operating-system memory-pressure level, as reported by the host platform.
///
/// [critical] is **macOS-only by PLATFORM CAPABILITY, not by omission**
/// (lead ruling (e), 2026-09-11). macOS's `DispatchSource` memory-pressure
/// source distinguishes warning from critical; Windows'
/// `CreateMemoryResourceNotification(LowMemoryResourceNotification)` exposes a
/// TWO-STATE signal (low memory / its complement) and has no third level to
/// map. A future reader must NOT read the absent Windows [critical] as an
/// unfinished implementation and "complete" it by inventing a threshold the
/// operating system does not provide.
///
/// Consequence for consumers: a [critical] that never arrives is ordinary
/// platform variation, not an error. Any responder must be correct when only
/// [normal] and [warning] are ever observed.
enum MemoryPressureLevel {
  normal,
  warning,
  critical;

  /// Parses the bare-string argument the native side pushes. Returns null for
  /// anything unrecognised, which the monitor ignores rather than throwing --
  /// an unknown level from the platform must not take the app down.
  static MemoryPressureLevel? fromWireName(Object? wireName) {
    if (wireName is! String) return null;
    for (final level in MemoryPressureLevel.values) {
      if (level.name == wireName) return level;
    }
    return null;
  }
}

/// Receives operating-system memory-pressure notifications.
///
/// **Push-only, native to Dart, no method-call handler on the native side** --
/// structurally identical to `halcyon/open_with`
/// (`lib/services/platform/open_with_channel.dart:29-42`,
/// `macos/Runner/AppDelegate.swift:6-11`).
///
/// ## Why a channel is correct here, when `halcyon/device_memory` was deleted
///
/// `macos/Runner/AppDelegate.swift:42-47` records that a previous macOS-only
/// channel (`halcyon/device_memory`) was DELETED in favour of a Dart-side read
/// (`lib/services/platform/device_memory.dart`), for two reasons: it only ever
/// answered on macOS, and it had a cold-start registration race with Dart's
/// `main()`. **Neither reason applies to this channel**, and the difference is
/// the direction of travel:
///
/// 1. Total physical RAM is a VALUE THAT CAN BE POLLED -- Dart can read it
///    itself, so a channel bought nothing. Memory pressure is a PUSH EVENT
///    from the operating system: there is no equivalent Dart-side reading, and
///    nothing to poll. The `device_memory` replacement strategy is simply not
///    available for it.
/// 2. The cold-start race that motivated that deletion was a Dart -> platform
///    call arriving before the native handler existed. This channel is
///    platform -> Dart, which is the direction Flutter's channel buffers
///    cover: a level pushed before Dart registers its handler is HELD and
///    delivered once [startListening] runs. The race is structurally absent.
///
/// See the architecture-decision entry for WP4.4.
class MemoryPressureMonitor {
  /// [channel] is injectable purely as a TEST SEAM: unit tests drive
  /// [handleMethodCall] (or push through a fake channel) without a platform.
  /// Production passes nothing and gets `halcyon/memory_pressure`.
  MemoryPressureMonitor({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  /// The channel the native side pushes on. Must match
  /// `macos/Runner/AppDelegate.swift` and `windows/runner/halcyon_channels.cpp`.
  static const String channelName = 'halcyon/memory_pressure';

  /// The one method the native side invokes. Argument is a bare String, one of
  /// the [MemoryPressureLevel] names -- bare rather than a map, matching
  /// `open_with`'s convention.
  static const String methodName = 'memoryPressureLevelChanged';

  final MethodChannel _channel;

  final StreamController<MemoryPressureLevel> _levelChanges =
      StreamController<MemoryPressureLevel>.broadcast();

  MemoryPressureLevel _currentPressureLevel = MemoryPressureLevel.normal;

  bool _listening = false;

  /// The last level reported by the platform. [MemoryPressureLevel.normal]
  /// until the platform says otherwise -- a machine that never pushes (Linux,
  /// web, a calm macOS session) is indistinguishable from a calm one, and calm
  /// is the correct assumption.
  MemoryPressureLevel get currentPressureLevel => _currentPressureLevel;

  /// Emits ONLY on an actual change of level. A platform that re-announces the
  /// same level (macOS's source coalesces, Windows' notification can re-signal
  /// while still low) must not make the responder halve the budget twice.
  Stream<MemoryPressureLevel> get pressureLevelChanges => _levelChanges.stream;

  /// Registers the method-call handler. Idempotent.
  ///
  /// Safe to call at any point in startup: anything the platform pushed before
  /// this ran is buffered by Flutter and delivered here (see the class doc).
  void startListening() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler(handleMethodCall);
  }

  /// The handler itself, exposed so tests can drive it directly without a
  /// platform. Not private for that reason alone.
  Future<Object?> handleMethodCall(MethodCall call) async {
    if (call.method != methodName) return null;
    final level = MemoryPressureLevel.fromWireName(call.arguments);
    if (level == null) return null;
    if (level == _currentPressureLevel) return null;
    _currentPressureLevel = level;
    _levelChanges.add(level);
    return null;
  }

  /// Drops the handler and closes the stream. The channel is process-wide, so
  /// the handler is explicitly cleared rather than left dangling.
  Future<void> dispose() async {
    if (_listening) {
      _listening = false;
      _channel.setMethodCallHandler(null);
    }
    await _levelChanges.close();
  }
}
