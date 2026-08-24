import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Finder "Open With" delivery. Push-only: Flutter's channel buffers hold a
  // platform->Dart message until Dart registers its handler, so we never have
  // to know whether Dart is up yet. The one case buffers cannot cover is an
  // open event arriving before the channel object exists at all (cold start,
  // odoc lands before applicationDidFinishLaunching) -- that one waits in
  // pendingOpenFile and is flushed the moment the channel is created.
  private var openWithChannel: FlutterMethodChannel?
  private var pendingOpenFile: String?

  override func applicationDidFinishLaunching(_ aNotification: Notification) {
    // Never force-cast: a nil/unexpected content view controller must not abort
    // the process. Without the controller there is no messenger to register
    // channels on, so we log and leave the app running instead of trapping.
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController else {
      NSLog("Halcyon: FlutterViewController unavailable; platform channels not registered")
      return
    }
    let trashChannel = FlutterMethodChannel(name: "halcyon/trash",
                                            binaryMessenger: controller.engine.binaryMessenger)

    trashChannel.setMethodCallHandler({
      (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
      if call.method == "trashFile" {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String,
              !path.isEmpty else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing path", details: nil))
          return
        }

        self.trashFile(path: path, result: result)
      } else {
        result(FlutterMethodNotImplemented)
      }
    })

    let openWithChannel = FlutterMethodChannel(name: "halcyon/open_with",
                                               binaryMessenger: controller.engine.binaryMessenger)
    self.openWithChannel = openWithChannel
    if let pending = pendingOpenFile {
      pendingOpenFile = nil
      openWithChannel.invokeMethod("openFile", arguments: pending)
    }
  }

  // Both entry points macOS uses for document-open; older systems call
  // openFile:, current ones call open urls:.
  override func application(_ sender: NSApplication, openFile filename: String) -> Bool {
    handleOpen(path: filename)
    return true
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    guard let url = urls.first(where: { $0.isFileURL }) else { return }
    handleOpen(path: url.path)
  }

  private func handleOpen(path: String) {
    if let channel = openWithChannel {
      channel.invokeMethod("openFile", arguments: path)
    } else {
      pendingOpenFile = path
    }
  }

  private func trashFile(path: String, result: @escaping FlutterResult) {
    let url = URL(fileURLWithPath: path)

    DispatchQueue.global(qos: .userInitiated).async {
      guard FileManager.default.fileExists(atPath: url.path) else {
        DispatchQueue.main.async {
          result(FlutterError(code: "NOT_FOUND", message: "File does not exist", details: path))
        }
        return
      }

      do {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        DispatchQueue.main.async {
          result(nil)
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "TRASH_FAILED", message: error.localizedDescription, details: path))
        }
      }
    }
  }
  
  // PERF-INSTRUMENTATION (permanent, contract: docs/logs/2026-08-16/round-3-implementation-plan.md §3).
  // Gated on HALCYON_PERF_DIR: unset means perfEnabled is false and every perfLog()
  // call below is a single bool check, no I/O -- a structural no-op when disabled.
  // Event names/fields are consumed by scripts/tmp/perf/parse_r2.py -- do not
  // rename/reshape without checking that parser first.
  private static let perfEnabled = ProcessInfo.processInfo.environment["HALCYON_PERF_DIR"] != nil
  private static func perfLog(_ s: String) {
    if perfEnabled { print("PERFNATIVE|\(Int(ProcessInfo.processInfo.systemUptime * 1_000_000))|\(s)") }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
