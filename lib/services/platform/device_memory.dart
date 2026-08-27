import 'package:flutter/services.dart';

/// Total physical RAM of the host machine, over a platform channel.
///
/// There is no platform-neutral total-memory API in `dart:io` (`ProcessInfo`
/// reports this process's RSS, not the machine's RAM) and C-3 forbids
/// platform-conditional branches in `lib/`, so the only C-3-safe source is a
/// channel: this file names no platform, and WHICH platform answers is
/// decided by which runner registered a handler.
///
/// Only macOS ships a handler today. Everywhere else the call raises
/// [MissingPluginException] and this returns null, which every consumer
/// reads as "use the floor sizing" -- i.e. exactly today's behavior.
class DeviceMemory {
  static const MethodChannel channel = MethodChannel('halcyon/device_memory');

  /// Total physical memory in bytes, or null when no platform answers.
  ///
  /// Never throws. A non-positive reply is treated as absent: a zero or
  /// negative RAM figure is a broken platform, not a small machine, and
  /// must not be fed to the sizing ladder.
  static Future<int?> totalPhysicalBytes() async {
    try {
      final bytes = await channel.invokeMethod<int>('totalPhysicalBytes');
      if (bytes == null || bytes <= 0) return null;
      return bytes;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
