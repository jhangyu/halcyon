import Cocoa
import CoreImage
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
    let thumbnailChannel = FlutterMethodChannel(name: "halcyon/thumbnail",
                                                binaryMessenger: controller.engine.binaryMessenger)
    let trashChannel = FlutterMethodChannel(name: "halcyon/trash",
                                            binaryMessenger: controller.engine.binaryMessenger)
    
    thumbnailChannel.setMethodCallHandler({
      (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
      if call.method == "getThumbnail" {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing path", details: nil))
          return
        }
        
        let targetSize = args["targetSize"] as? Int ?? 4000
        let purpose = args["purpose"] as? String ?? "preview"
        // allowRawDecodeSignal defaults to true when absent (see
        // kAllowRawDecodeSignalArg in lib/services/native_thumbnail_service.dart).
        let allowRawDecodeSignal = args["allowRawDecodeSignal"] as? Bool ?? true

        self.getFastThumbnail(path: path, targetSize: targetSize, purpose: purpose, allowRawDecodeSignal: allowRawDecodeSignal, result: result)
      } else {
        result(FlutterMethodNotImplemented)
      }
    })

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

  // MARK: - Untrusted-input hardening (Task 17)
  //
  // Everything below runs on files the user picked off a memory card, so a
  // truncated/corrupt/mislabelled file is a normal input, not an exceptional
  // one. The rules here: no force unwraps, no unchecked casts, and every
  // failure surfaces as a FlutterError the Dart side already knows how to
  // degrade on (NativeImageFailure in lib/services/native_thumbnail_service.dart).

  /// EXIF Orientation is defined only for 1...8. A corrupt tag can hold any
  /// 32-bit value, and CoreImage's `oriented(forExifOrientation:)` is undefined
  /// outside that range, so anything else degrades to 1 (no transform). Mirrors
  /// `NativeThumbnailService._parseOrientation` on the Dart side, which applies
  /// the same clamp to the value we send with NO_EMBEDDED_PREVIEW.
  static func sanitizedExifOrientation(_ raw: Int?) -> Int32 {
    guard let raw = raw, raw >= 1, raw <= 8 else { return 1 }
    return Int32(raw)
  }

  /// Reads IFD0 Orientation from an image source, already sanitized. Uses
  /// NSNumber rather than `as? Int32`: ImageIO hands back a CFNumber whose
  /// concrete Swift type is not guaranteed, and a failed bridge would silently
  /// drop a valid orientation.
  private static func exifOrientation(from source: CGImageSource) -> Int32 {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let raw = properties[kCGImagePropertyOrientation] as? NSNumber else {
      return 1
    }
    return sanitizedExifOrientation(raw.intValue)
  }

  /// Upper bound on the RGBA8 buffer a CIContext is asked to materialise
  /// (width * height * 4 bytes). 1.5 GB is ~375 megapixels, far above any
  /// shipping camera, so no genuine RAW is rejected; what it stops is a corrupt
  /// header that claims an absurd extent, which would otherwise turn into a
  /// multi-gigabyte allocation and an OOM kill instead of an error result.
  private static let maxDecodedPixelBytes: Double = 1_500_000_000

  enum RenderOutcome {
    case image(CGImage)
    /// Extent was null/infinite/empty/non-finite, or CIContext returned nil.
    case invalid
    /// Extent is plausible-looking but larger than we are willing to allocate.
    case tooLarge
  }

  /// Renders a CIImage to a CGImage with every precondition checked first.
  /// `createCGImage(_:from:)` traps or allocates unboundedly on an infinite or
  /// absurd extent, and CIImage extents are attacker-controlled here (they come
  /// from the RAW header), so the extent is validated before CoreImage sees it.
  static func renderCGImage(from ciImage: CIImage) -> RenderOutcome {
    let extent = ciImage.extent
    guard !extent.isNull, !extent.isInfinite, !extent.isEmpty,
          extent.width.isFinite, extent.height.isFinite,
          extent.width >= 1, extent.height >= 1 else {
      return .invalid
    }
    // Double arithmetic on purpose: converting an out-of-range Double to an
    // integer type traps, which is the crash this guard exists to prevent.
    guard Double(extent.width) * Double(extent.height) * 4 <= maxDecodedPixelBytes else {
      return .tooLarge
    }

    let context = CIContext(options: [.useSoftwareRenderer: false])
    let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let rendered = context.createCGImage(ciImage,
                                               from: extent,
                                               format: .RGBA8,
                                               colorSpace: srgbSpace) else {
      return .invalid
    }
    return .image(rendered)
  }

  private func getFastThumbnail(path: String, targetSize: Int, purpose: String, allowRawDecodeSignal: Bool, result: @escaping FlutterResult) {
    let url = URL(fileURLWithPath: path)
    let perfName = (path as NSString).lastPathComponent // PERF-INSTRUMENTATION
    let perfEnqueue = ProcessInfo.processInfo.systemUptime // PERF-INSTRUMENTATION
    AppDelegate.perfLog("handler.enter|\(perfName)|\(purpose)") // PERF-INSTRUMENTATION

    DispatchQueue.global(qos: .userInteractive).async {
        let perfStart = ProcessInfo.processInfo.systemUptime // PERF-INSTRUMENTATION
        AppDelegate.perfLog("bg.start|\(perfName)|queueWait=\(Int((perfStart - perfEnqueue) * 1_000_000))") // PERF-INSTRUMENTATION
        let lowerPath = path.lowercased()
        let isDng = lowerPath.hasSuffix(".dng")
        let isRaw = isDng ||
                    lowerPath.hasSuffix(".arw") ||
                    lowerPath.hasSuffix(".cr2") ||
                    lowerPath.hasSuffix(".nef") ||
                    lowerPath.hasSuffix(".orf") ||
                    lowerPath.hasSuffix(".rw2")
        let isPreviewRequest = purpose == "preview"
        let isJpeg = lowerPath.hasSuffix(".jpg") || lowerPath.hasSuffix(".jpeg")

        // Fast path: for JPEG preview requests, return the raw file bytes directly,
        // skipping full-resolution decode + JPEG re-encode. Flutter's Image.memory
        // honors EXIF orientation for JPEG, so no orientation processing is needed here.
        //
        // For DNG preview requests, try to locate a full-size embedded JPEG (many DNGs
        // from Lightroom/DxO carry one in a SubIFD) and return its bytes the same way --
        // no RAW decode, no re-encode. Unlike the JPEG case, finding no embedded JPEG is
        // NOT an error: it falls through to the existing CGImageSource / CIRAWFilter path
        // below, unchanged.
        //
        // Both cases share a single dispatch/return site below so perf instrumentation
        // anchored on this exit point covers both passthrough kinds.
        var passthroughData: Data?
        if isPreviewRequest && isJpeg {
            let perfReadStart = ProcessInfo.processInfo.systemUptime // PERF-INSTRUMENTATION
            guard let data = try? Data(contentsOf: url) else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "LOAD_FAILED", message: "Cannot read image", details: nil))
                }
                return
            }
            // PERF-INSTRUMENTATION
            AppDelegate.perfLog("jpegPassthrough.read|\(perfName)|bytes=\(data.count)|dur=\(Int((ProcessInfo.processInfo.systemUptime - perfReadStart) * 1_000_000))")
            passthroughData = data
        } else if isPreviewRequest && isDng {
            let perfReadStart = ProcessInfo.processInfo.systemUptime // PERF-INSTRUMENTATION
            let extracted = extractFullSizeEmbeddedJpeg(url: url) // nil => no embedded preview, not an error
            // PERF-INSTRUMENTATION
            if let extracted = extracted {
                AppDelegate.perfLog("dngPassthrough.read|\(perfName)|bytes=\(extracted.count)|dur=\(Int((ProcessInfo.processInfo.systemUptime - perfReadStart) * 1_000_000))")
            } else {
                AppDelegate.perfLog("dngPassthrough.miss|\(perfName)|dur=\(Int((ProcessInfo.processInfo.systemUptime - perfReadStart) * 1_000_000))")
            }

            // Round 3b: when extraction misses on a preview-purpose DNG and the
            // caller has not opted out (allowRawDecodeSignal), surface an explicit
            // NO_EMBEDDED_PREVIEW error carrying EXIF orientation instead of
            // silently falling through to the slow CIRAWFilter path below. Callers
            // that need the pre-round-3b fallback behaviour (e.g. the legacy
            // NativeThumbnailService.getThumbnail) send allowRawDecodeSignal=false,
            // which keeps this branch a no-op and preserves the old fall-through.
            if extracted == nil && allowRawDecodeSignal {
                // readDngOrientation returns the raw IFD0 tag value (any UInt32 on a
                // corrupt file); clamp to 1...8 before it crosses the channel so the
                // Dart side never has to fall back (see kDefaultExifOrientation).
                let orientation = AppDelegate.sanitizedExifOrientation(Int(readDngOrientation(url: url)))
                DispatchQueue.main.async {
                    // PERF-INSTRUMENTATION
                    AppDelegate.perfLog("result.dispatch|\(perfName)|nativeTotal=\(Int((ProcessInfo.processInfo.systemUptime - perfEnqueue) * 1_000_000))|noEmbeddedPreview")
                    result(FlutterError(code: "NO_EMBEDDED_PREVIEW",
                                         message: "DNG has no embedded full-size JPEG preview",
                                         details: Int(orientation)))
                }
                return
            }
            passthroughData = extracted
        }

        if let data = passthroughData {
            DispatchQueue.main.async {
                // PERF-INSTRUMENTATION: unified dispatch site for BOTH JPEG and DNG
                // passthrough, so nativeTotal covers both passthrough kinds.
                AppDelegate.perfLog("result.dispatch|\(perfName)|nativeTotal=\(Int((ProcessInfo.processInfo.systemUptime - perfEnqueue) * 1_000_000))")
                result(FlutterStandardTypedData(bytes: data))
            }
            return
        }

        var cgImage: CGImage?

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            DispatchQueue.main.async {
                result(FlutterError(code: "LOAD_FAILED", message: "Cannot read source", details: nil))
            }
            return
        }
        
        // 1. First, try to extract the embedded thumbnail WITHOUT decoding the RAW image.
        // ImageIO will only return the existing embedded JPEG/thumbnail.
        if isRaw {
            // Request the size of the original embedded preview (usually 1920px, 4K or full size).
            // We pass kCGImageSourceCreateThumbnailWithTransform to automatically apply Exif rotation.
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceThumbnailMaxPixelSize: targetSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ]
            
            if let embedded = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
                // If we got an embedded thumbnail, double check it's not a tiny 160x120 icon.
                let maxDimension = max(embedded.width, embedded.height)
                if maxDimension >= 1024 || targetSize <= 256 {
                    cgImage = embedded
                }
            }
            
            // 2. If no suitable embedded thumbnail was found, decode the RAW using CIRAWFilter.
            // A nil filter or nil outputImage (unreadable / not actually a RAW / corrupt)
            // is not fatal: cgImage stays nil and the ImageIO fallback below gets a turn,
            // ending in an explicit LOAD_FAILED if that fails too.
            if cgImage == nil && isPreviewRequest {
                if let filter = CIFilter(imageURL: url, options: nil),
                   let rawImage = filter.outputImage {
                    let orientation = AppDelegate.exifOrientation(from: source)
                    let ciImage = orientation == 1
                        ? rawImage
                        : rawImage.oriented(forExifOrientation: orientation)

                    switch AppDelegate.renderCGImage(from: ciImage) {
                    case .image(let rendered):
                        cgImage = rendered
                    case .tooLarge:
                        DispatchQueue.main.async {
                            result(FlutterError(code: "IMAGE_TOO_LARGE",
                                                message: "RAW decode exceeds the decoded-pixel budget",
                                                details: path))
                        }
                        return
                    case .invalid:
                        break // fall through to the ImageIO path below
                    }
                }
            }
        }
        
        // 3. Fallback to standard ImageIO extraction. Large non-RAW requests are the main viewer,
        // so use the original image instead of an embedded thumbnail.
        if cgImage == nil {
            if !isRaw && isPreviewRequest {
                cgImage = self.createFullSizeImage(source: source)
            } else {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                    kCGImageSourceThumbnailMaxPixelSize: targetSize,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                ]
                cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }
        }

        guard let finalCGImage = cgImage else {
            DispatchQueue.main.async {
                result(FlutterError(code: "LOAD_FAILED", message: "Cannot read image", details: nil))
            }
            return
        }

        // PERF-INSTRUMENTATION
        AppDelegate.perfLog("decoded|\(perfName)|\(finalCGImage.width)x\(finalCGImage.height)|dur=\(Int((ProcessInfo.processInfo.systemUptime - perfStart) * 1_000_000))")

        // Convert to NSImage then to JPEG Data
        let perfEncodeStart = ProcessInfo.processInfo.systemUptime // PERF-INSTRUMENTATION
        let bitmapRep = NSBitmapImageRep(cgImage: finalCGImage)
        let data = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        // PERF-INSTRUMENTATION
        AppDelegate.perfLog("reencode|\(perfName)|bytes=\(data?.count ?? -1)|dur=\(Int((ProcessInfo.processInfo.systemUptime - perfEncodeStart) * 1_000_000))")

        DispatchQueue.main.async {
            // PERF-INSTRUMENTATION
            AppDelegate.perfLog("result.dispatch|\(perfName)|nativeTotal=\(Int((ProcessInfo.processInfo.systemUptime - perfEnqueue) * 1_000_000))")
            if let data = data {
                result(FlutterStandardTypedData(bytes: data))
            } else {
                result(FlutterError(code: "CONVERT_FAILED", message: "Cannot convert to typed data", details: nil))
            }
        }
    }
  }

  private func createFullSizeImage(source: CGImageSource) -> CGImage? {
    let options: [CFString: Any] = [
      kCGImageSourceShouldCache: true,
      kCGImageSourceShouldCacheImmediately: true
    ]

    guard let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
      return nil
    }

    let orientation = AppDelegate.exifOrientation(from: source)
    guard orientation != 1 else { return image }

    let ciImage = CIImage(cgImage: image).oriented(forExifOrientation: orientation)
    // If the oriented render is impossible (bad extent) or too big to allocate,
    // hand back the unrotated original rather than nil: a mis-rotated preview
    // beats no preview, and the caller's only alternative is LOAD_FAILED.
    switch AppDelegate.renderCGImage(from: ciImage) {
    case .image(let rendered):
      return rendered
    case .invalid, .tooLarge:
      return image
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
