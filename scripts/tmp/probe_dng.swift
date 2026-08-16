import Foundation
import ImageIO
import CoreGraphics

let path = CommandLine.arguments[1]
let url = URL(fileURLWithPath: path)
let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
print("count=\(CGImageSourceGetCount(src)) topW=\(props[kCGImagePropertyPixelWidth] ?? "?") topH=\(props[kCGImagePropertyPixelHeight] ?? "?")")
if let dng = props[kCGImagePropertyDNGDictionary] as? [CFString: Any] {
  print("dngDefaultCropSize=\(dng[kCGImagePropertyDNGDefaultCropSize] ?? "nil")")
}
for cap in [2800, 6000, 8000, 12000] {
  let t0 = Date()
  let o: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                            kCGImageSourceThumbnailMaxPixelSize: cap,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceShouldCacheImmediately: true]
  if let img = CGImageSourceCreateThumbnailAtIndex(src, 0, o as CFDictionary) {
    print("cap=\(cap) -> \(img.width)x\(img.height) in \(Int(Date().timeIntervalSince(t0)*1000))ms")
  } else { print("cap=\(cap) -> nil") }
}
