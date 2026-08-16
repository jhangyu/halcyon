// Standalone verification probe for Round 3a: extractFullSizeEmbeddedJpeg selection logic.
//
// Compiled together with the REAL shipped file (macos/Runner/DngPreviewExtractor.swift) --
// no duplicated logic here, so there is nothing to drift out of sync. See
// scripts/tmp/run_probe_extract.sh for the exact compile+run invocation.
//
// Exercises A1 (full-size extraction across sample classes), A4a (negative case falls
// back to nil), A4b (orientation injection). Exits non-zero if any assertion fails.

import Foundation
import ImageIO
import CoreGraphics

// `swiftc` only allows top-level statements in a file literally named `main.swift`
// when compiling multiple files together. Since this file keeps its descriptive
// name, the driver logic below lives in an `@main` entry point instead.

var failures = 0

func pixelDimensions(of jpegData: Data) -> (Int, Int)? {
  guard let src = CGImageSourceCreateWithData(jpegData as CFData, nil),
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
        let w = props[kCGImagePropertyPixelWidth] as? Int,
        let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
  return (w, h)
}

func exifOrientation(of jpegData: Data) -> Int? {
  guard let src = CGImageSourceCreateWithData(jpegData as CFData, nil),
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
        let o = props[kCGImagePropertyOrientation] as? Int else { return nil }
  return o
}

func check(_ label: String, _ ok: Bool, _ detail: String) {
  if ok {
    print("PASS \(label): \(detail)")
  } else {
    print("FAIL \(label): \(detail)")
    failures += 1
  }
}

@main
struct ProbeExtractMain {
  static func main() {
    let sampleDir = "local_data/photo_samples/DNG"
    let fm = FileManager.default
    let allFiles = (try? fm.contentsOfDirectory(atPath: sampleDir)) ?? []
    let lightroomFiles = allFiles.filter { $0.hasPrefix("2026-02-15-") && $0.hasSuffix(".dng") }.sorted()

    print("--- A1: Lightroom samples (expect 6000x4000, non-nil) ---")
    for f in lightroomFiles {
      let url = URL(fileURLWithPath: "\(sampleDir)/\(f)")
      guard let jpeg = extractFullSizeEmbeddedJpeg(url: url) else {
        check("A1 \(f)", false, "extractor returned nil, expected bytes")
        continue
      }
      let dim = pixelDimensions(of: jpeg)
      check("A1 \(f)", dim?.0 == 6000 && dim?.1 == 4000, "dim=\(String(describing: dim)) bytes=\(jpeg.count)")
    }

    print("--- A1/A4b: DxO sample (expect 6000x4000, non-nil, orientation=6) ---")
    let dxoURL = URL(fileURLWithPath: "\(sampleDir)/2026-08-07-17-52-54.dng")
    if let dxoJpeg = extractFullSizeEmbeddedJpeg(url: dxoURL) {
      let dim = pixelDimensions(of: dxoJpeg)
      check("A1 dxo", dim?.0 == 6000 && dim?.1 == 4000, "dim=\(String(describing: dim)) bytes=\(dxoJpeg.count)")
      let ori = exifOrientation(of: dxoJpeg)
      check("A4b dxo-orientation", ori == 6, "exif orientation=\(String(describing: ori)) (expect 6 = Rotate 90 CW)")
    } else {
      check("A1 dxo", false, "extractor returned nil, expected bytes")
      check("A4b dxo-orientation", false, "extractor returned nil, cannot check orientation")
    }

    print("--- A4a: CFA sample with no embedded JPEG (expect nil -> fallback path) ---")
    let cfaURL = URL(fileURLWithPath: "\(sampleDir)/IMG_20251112_092839.dng")
    let cfaResult = extractFullSizeEmbeddedJpeg(url: cfaURL)
    check("A4a cfa-negative", cfaResult == nil, "extractor returned \(cfaResult == nil ? "nil (fallback triggered)" : "\(cfaResult!.count) bytes (WRONG, should fall back)")")

    print("--- summary ---")
    print("Lightroom samples tested: \(lightroomFiles.count)")
    if failures == 0 {
      print("ALL PASS")
      exit(0)
    } else {
      print("\(failures) FAILURE(S)")
      exit(1)
    }
  }
}
