import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  // F-16 Open With delivery, same push-only pattern as macOS
  // (macos/Runner/AppDelegate.swift): native pushes "openFile" on
  // halcyon/open_with, Dart's channel buffer holds it if
  // OpenWithChannel.listen() hasn't registered yet (cold start).
  // pendingOpenFile covers the gap buffers can't: a launch URL arriving
  // before the FlutterViewController/channel exists at all.
  //
  // Inspection-only on this host: no iOS device/simulator build was run to
  // exercise this at runtime (M6 P4.5 ticket scope). End-to-end mobile flow
  // stays parked on folder-scan (F-02) landing on iOS.
  private var openWithChannel: FlutterMethodChannel?
  private var pendingOpenFile: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    guard let controller = window?.rootViewController as? FlutterViewController else {
      NSLog("Halcyon: FlutterViewController unavailable; open_with channel not registered")
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    let channel = FlutterMethodChannel(name: "halcyon/open_with",
                                        binaryMessenger: controller.binaryMessenger)
    self.openWithChannel = channel
    if let pending = pendingOpenFile {
      pendingOpenFile = nil
      channel.invokeMethod("openFile", arguments: pending)
    }

    if let url = launchOptions?[.url] as? URL {
      handleOpen(url: url)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(_ app: UIApplication, open url: URL,
                             options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    handleOpen(url: url)
    return super.application(app, open: url, options: options)
  }

  private func handleOpen(url: URL) {
    guard url.isFileURL else { return }
    let path = url.path
    if let channel = openWithChannel {
      channel.invokeMethod("openFile", arguments: path)
    } else {
      pendingOpenFile = path
    }
  }
}
