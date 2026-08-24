import Cocoa
import FlutterMacOS
import ImageIO

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

    let exifChannel = FlutterMethodChannel(name: "halcyon/exif",
                                           binaryMessenger: controller.engine.binaryMessenger)

    exifChannel.setMethodCallHandler({ (call, result) -> Void in
      guard call.method == "readBatch",
            let args = call.arguments as? [String: Any],
            let paths = args["paths"] as? [String] else {
        result(FlutterMethodNotImplemented)
        return
      }
      AppDelegate.readExifBatch(paths: paths, result: result)
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

  // MARK: - EXIF batch reader (halcyon/exif channel, feature: EXIF rename)

  /// Reads EXIF for every path in parallel. Header only — no pixel decode —
  /// so 10,000 files cost seconds, not minutes. Order is preserved because
  /// each slot is written by index.
  static func readExifBatch(paths: [String], result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      var slots = [Any?](repeating: nil, count: paths.count)
      let lock = NSLock()

      DispatchQueue.concurrentPerform(iterations: paths.count) { index in
        let entry = AppDelegate.exifDictionary(path: paths[index])
        lock.lock()
        slots[index] = entry
        lock.unlock()
      }

      let payload: [Any] = slots.map { $0 ?? NSNull() }
      DispatchQueue.main.async { result(payload) }
    }
  }

  static func exifDictionary(path: String) -> [String: Any]? {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any] else {
      return nil
    }

    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    let aux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
    let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

    var out: [String: Any] = [:]
    out["captureDate"] = exif[kCGImagePropertyExifDateTimeOriginal] as? String
      ?? tiff[kCGImagePropertyTIFFDateTime] as? String
    out["camera"] = tiff[kCGImagePropertyTIFFModel] as? String
    out["make"] = tiff[kCGImagePropertyTIFFMake] as? String
    out["artist"] = tiff[kCGImagePropertyTIFFArtist] as? String
    // LensModel is the standard tag; LensModel in the Aux dictionary is where
    // several vendors (and Apple's own RAW pipeline) actually put it.
    out["lens"] = exif[kCGImagePropertyExifLensModel] as? String
      ?? aux[kCGImagePropertyExifAuxLensModel] as? String
    out["aperture"] = exif[kCGImagePropertyExifFNumber] as? Double
    out["focalLength"] = exif[kCGImagePropertyExifFocalLength] as? Double
    out["iso"] = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
    out["direction"] = gps[kCGImagePropertyGPSImgDirection] as? Double
    out["shutter"] = AppDelegate.shutterString(
      exif[kCGImagePropertyExifExposureTime] as? Double
    )

    // Drop nils so the Dart side sees "absent", not "present but null".
    return out.compactMapValues { $0 }
  }

  /// 0.004 -> "1/250", 2.0 -> "2s". Slashes are stripped on the Dart side by
  /// RenameRule.sanitise, so this stays human-readable here.
  static func shutterString(_ seconds: Double?) -> String? {
    guard let seconds = seconds, seconds > 0 else { return nil }
    if seconds >= 1 { return "\(Int(seconds.rounded()))s" }
    return "1/\(Int((1.0 / seconds).rounded()))"
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
