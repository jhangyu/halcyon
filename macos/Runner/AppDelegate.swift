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
        
        self.getFastThumbnail(path: path, targetSize: targetSize, purpose: purpose, result: result)
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
  
  private func getFastThumbnail(path: String, targetSize: Int, purpose: String, result: @escaping FlutterResult) {
    let url = URL(fileURLWithPath: path)
    
    DispatchQueue.global(qos: .userInteractive).async {
        let lowerPath = path.lowercased()
        let isRaw = lowerPath.hasSuffix(".dng") ||
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
        if isPreviewRequest && isJpeg {
            do {
                let data = try Data(contentsOf: url)
                DispatchQueue.main.async {
                    result(FlutterStandardTypedData(bytes: data))
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "LOAD_FAILED", message: "Cannot read image", details: nil))
                }
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
                kCGImageSourceThumbnailMaxPixelSize: max(targetSize, 8000),
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
        
        // Convert to NSImage then to JPEG Data
        let bitmapRep = NSBitmapImageRep(cgImage: finalCGImage)
        let data = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        
        DispatchQueue.main.async {
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
