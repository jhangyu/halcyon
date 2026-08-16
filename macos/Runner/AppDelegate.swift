import Cocoa
import CoreImage
import FlutterMacOS
import ImageIO

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationDidFinishLaunching(_ aNotification: Notification) {
    let controller = mainFlutterWindow?.contentViewController as! FlutterViewController
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
                let orientation = readDngOrientation(url: url)
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
            
            // 2. If no suitable embedded thumbnail was found, decode the RAW using CIRAWFilter
            if cgImage == nil && isPreviewRequest {
                if let filter = CIFilter(imageURL: url, options: nil),
                   var ciImage = filter.outputImage {
                    
                    // Attempt to read orientation and apply it to CIImage
                    if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                       let orientation = properties[kCGImagePropertyOrientation] as? Int32 {
                         // Apply EXIF orientation
                         ciImage = ciImage.oriented(forExifOrientation: orientation)
                    }
                    
                    let context = CIContext(options: [.useSoftwareRenderer: false])
                    let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
                    
                    cgImage = context.createCGImage(ciImage, 
                                                    from: ciImage.extent, 
                                                    format: .RGBA8, 
                                                    colorSpace: srgbSpace)
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

    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let orientation = properties[kCGImagePropertyOrientation] as? Int32,
          orientation != 1 else {
      return image
    }

    let ciImage = CIImage(cgImage: image).oriented(forExifOrientation: orientation)
    let context = CIContext(options: [.useSoftwareRenderer: false])
    let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    return context.createCGImage(
      ciImage,
      from: ciImage.extent,
      format: .RGBA8,
      colorSpace: srgbSpace
    )
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
