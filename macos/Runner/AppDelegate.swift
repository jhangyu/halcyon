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

  // Memory-pressure delivery (WP4.4 / spec S3.4). Push-only, native->Dart,
  // with NO method-call handler -- structurally identical to openWithChannel
  // above, and for the same reason: Flutter's channel buffers hold the message
  // until Dart registers its handler, so a pressure event that fires during
  // startup is delivered rather than lost.
  //
  // Why a channel at all, when halcyon/device_memory was deleted (see the note
  // further down): total RAM is a value Dart CAN read for itself, so that
  // channel bought nothing. Memory pressure is a PUSH EVENT from the operating
  // system -- there is nothing to poll, so the Dart-side-read replacement is
  // not available here. And the cold-start race that motivated that deletion
  // was a Dart->native call; this is native->Dart, the direction buffers cover.
  private var memoryPressureChannel: FlutterMethodChannel?
  // RETAINED DELIBERATELY: a DispatchSource that goes out of scope stops
  // firing, and its silence is indistinguishable from a machine that simply
  // never came under pressure. Holding it in a property is what makes the
  // "never fires" failure mode impossible-by-construction rather than
  // invisible.
  private var memoryPressureSource: DispatchSourceMemoryPressure?
  private var lastMemoryPressureLevel: String?

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

    // Total physical RAM for machine-adaptive cache sizing used to be a
    // macOS-only MethodChannel here (halcyon/device_memory). It is gone:
    // Dart side (lib/services/platform/device_memory.dart) now reads RAM
    // itself via `sysctl`/`/proc/meminfo`/PowerShell per platform, which
    // works on Linux and Windows too and has no cold-start registration
    // race with Dart's `main()`.

    let openWithChannel = FlutterMethodChannel(name: "halcyon/open_with",
                                               binaryMessenger: controller.engine.binaryMessenger)
    self.openWithChannel = openWithChannel
    if let pending = pendingOpenFile {
      pendingOpenFile = nil
      openWithChannel.invokeMethod("openFile", arguments: pending)
    }

    startMemoryPressureMonitoring(messenger: controller.engine.binaryMessenger)
  }

  // MARK: - Memory pressure (WP4.4 / spec S3.4)

  /// Registers `halcyon/memory_pressure` and starts the dispatch source that
  /// pushes level changes to Dart.
  ///
  /// macOS is the platform that distinguishes `warning` from `critical`;
  /// Windows' notification mechanism is two-state and has no third level to
  /// map (lead ruling (e), 2026-09-11 -- that absence is a platform
  /// CAPABILITY difference, not an unfinished implementation).
  private func startMemoryPressureMonitoring(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "halcyon/memory_pressure",
                                       binaryMessenger: messenger)
    memoryPressureChannel = channel

    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.normal, .warning, .critical],
      queue: DispatchQueue.global(qos: .utility)
    )
    source.setEventHandler { [weak self] in
      guard let self = self, let source = self.memoryPressureSource else { return }
      let event = source.data
      // Highest severity wins: the mask can report more than one bit, and a
      // set of bits that includes .critical is not a "normal" moment.
      let level: String
      if event.contains(.critical) {
        level = "critical"
      } else if event.contains(.warning) {
        level = "warning"
      } else {
        level = "normal"
      }
      // Channel invocation must happen on the platform (main) thread; the
      // dispatch source fires on the background queue above.
      DispatchQueue.main.async {
        // Only on an actual change. The source coalesces and can re-fire the
        // same state; Dart de-duplicates too, but not sending is cheaper and
        // keeps the two sides' contracts identical.
        guard self.lastMemoryPressureLevel != level else { return }
        self.lastMemoryPressureLevel = level
        self.memoryPressureChannel?.invokeMethod("memoryPressureLevelChanged",
                                                 arguments: level)
      }
    }
    memoryPressureSource = source
    source.resume()
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

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
