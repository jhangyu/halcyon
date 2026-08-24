import 'package:flutter/services.dart';

/// Receives files the OS hands to Halcyon ("Open With" in Finder, shell
/// association on Windows, ACTION_VIEW on Android).
///
/// Push-only, on purpose: a cold start races the Flutter engine, and asking
/// the native side for a pending file (Dart -> platform) loses that race --
/// the native handler is not registered yet and the call dies as a
/// MissingPluginException. Platform -> Dart is the direction Flutter buffers
/// (channel buffers hold the message until a handler is registered), so the
/// launch-time file arrives whenever Dart is ready.
///
/// Platform status: macOS, Windows, Android and iOS all push on this
/// channel now (see macos/Runner/AppDelegate.swift,
/// windows/runner/flutter_window.cpp, the Android MainActivity, and
/// ios/Runner/AppDelegate.swift). What is still parked is the mobile
/// end-to-end flow beyond delivering the path: Android/iOS both need the
/// enclosing folder to land via the folder-scan pipeline (F-02) before
/// [onPath] actually opens something useful.
class OpenWithChannel {
  static const MethodChannel _channel = MethodChannel('halcyon/open_with');

  /// Wires [onPath] to `openFile` calls from the native side. A no-op on
  /// platforms that never send them.
  static void listen(void Function(String path) onPath) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openFile') {
        final path = call.arguments;
        if (path is String && path.isNotEmpty) onPath(path);
      }
    });
  }
}
