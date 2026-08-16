// Tests for the SHIPPED DNG embedded-JPEG selection logic.
//
// Compiled together with macos/Runner/DngPreviewExtractor.swift by
// scripts/tmp/run_dng_extractor_tests.sh -- there is no copy of the logic
// here, so nothing can drift. Run by `flutter test` via
// test/dng_extractor_swift_test.dart so it cannot be forgotten.
//
// Two kinds of material:
//   * the real samples in local_data/photo_samples/DNG (SubIFD2 Lightroom
//     shape, SubIFD1 DxO shape, CFA-only vivo shape)
//   * synthetic fixtures from scripts/tmp/make_synth_dng.py, which exist only
//     to make the Compression/PhotometricInterpretation guards observable --
//     no real sample can do that (see that script's header).
//
// Exit code 0 = all assertions held; 1 = at least one failed.

import Foundation
import ImageIO
import CoreGraphics

var failures = 0
var checks = 0

func check(_ label: String, _ ok: Bool, _ detail: String) {
  checks += 1
  if ok {
    print("PASS \(label): \(detail)")
  } else {
    print("FAIL \(label): \(detail)")
    failures += 1
  }
}

// MARK: - test-side helpers (deliberately independent of the code under test)

func pixelDimensions(of jpegData: Data) -> (Int, Int)? {
  guard let src = CGImageSourceCreateWithData(jpegData as CFData, nil),
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
        let w = props[kCGImagePropertyPixelWidth] as? Int,
        let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
  return (w, h)
}

func imageIOOrientation(of jpegData: Data) -> Int? {
  guard let src = CGImageSourceCreateWithData(jpegData as CFData, nil),
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
        let o = props[kCGImagePropertyOrientation] as? Int else { return nil }
  return o
}

/// Minimal, independent APP1/EXIF reader: returns (segmentLength, orientation)
/// for an EXIF APP1 sitting immediately after SOI. Little-endian only, which
/// is what the injector writes and what the fixtures contain.
func firstApp1Orientation(_ jpeg: Data) -> (segLen: Int, orientation: Int)? {
  let s = jpeg.startIndex
  guard jpeg.count > 4, jpeg[s] == 0xFF, jpeg[s + 1] == 0xD8,
        jpeg[s + 2] == 0xFF, jpeg[s + 3] == 0xE1 else { return nil }
  let segLen = (Int(jpeg[s + 4]) << 8) | Int(jpeg[s + 5])
  let payload = s + 6
  guard jpeg.count >= 6 + segLen else { return nil }
  guard jpeg[payload..<(payload + 6)].elementsEqual([0x45, 0x78, 0x69, 0x66, 0x00, 0x00])
  else { return nil }
  let tiff = payload + 6
  guard jpeg[tiff] == 0x49, jpeg[tiff + 1] == 0x49 else { return nil }
  // IFD at offset 8 within the TIFF block; 1 entry; value in the value field.
  let ifd = tiff + 8
  let entries = Int(jpeg[ifd]) | (Int(jpeg[ifd + 1]) << 8)
  var p = ifd + 2
  for _ in 0..<entries {
    let tag = Int(jpeg[p]) | (Int(jpeg[p + 1]) << 8)
    if tag == 0x0112 {
      let value = Int(jpeg[p + 8]) | (Int(jpeg[p + 9]) << 8)
      return (segLen + 2, value)
    }
    p += 12
  }
  return nil
}

/// Removes an EXIF APP1 that sits immediately after SOI.
func strippingFirstApp1(_ jpeg: Data) -> Data? {
  guard let (segLen, _) = firstApp1Orientation(jpeg) else { return nil }
  let s = jpeg.startIndex
  var out = Data()
  out.append(jpeg[s..<(s + 2)])
  out.append(jpeg[(s + 2 + segLen)...])
  return out
}

/// Mirrors make_synth_dng.py's `payload()`: SOI + repeated tag + EOI.
func synthPayload(_ tag: String, _ n: Int) -> Data {
  let t = Array(tag.utf8)
  var body = [UInt8]()
  while body.count < n { body.append(contentsOf: t) }
  return Data([0xFF, 0xD8] + body[0..<n] + [0xFF, 0xD9])
}

func describe(_ d: Data?) -> String {
  guard let d = d else { return "nil" }
  let head = d.prefix(12).map { String(format: "%02x", $0) }.joined()
  return "\(d.count) bytes, head=\(head)"
}

@main
struct DngExtractorTests {
  static let sampleDir = "local_data/photo_samples/DNG"
  static let fixtureDir = "scripts/tmp/fixtures"

  static func main() {
    realSamples()
    syntheticGuards()
    syntheticTwoValid()
    syntheticMultiStrip()
    syntheticThreshold()
    syntheticOrientation()

    print("--- summary ---")
    print("checks run: \(checks)")
    if failures == 0 {
      print("ALL PASS")
      exit(0)
    }
    print("\(failures) FAILURE(S)")
    exit(1)
  }

  // ---- real material -----------------------------------------------------

  static func realSamples() {
    let fm = FileManager.default
    let all = (try? fm.contentsOfDirectory(atPath: sampleDir)) ?? []
    let lightroom = all.filter { $0.hasPrefix("2026-02-15-") && $0.hasSuffix(".dng") }.sorted()

    print("--- R1: Lightroom shape (JpgFromRaw in SubIFD2) ---")
    check("R1 samples-present", lightroom.count >= 12,
          "found \(lightroom.count) Lightroom samples in \(sampleDir) (expect >= 12)")
    for f in lightroom {
      let url = URL(fileURLWithPath: "\(sampleDir)/\(f)")
      guard let jpeg = extractFullSizeEmbeddedJpeg(url: url) else {
        check("R1 \(f)", false, "returned nil, expected full-size JPEG bytes")
        continue
      }
      let dim = pixelDimensions(of: jpeg)
      let s = jpeg.startIndex
      let framed = jpeg.count > 4 && jpeg[s] == 0xFF && jpeg[s + 1] == 0xD8
        && jpeg[jpeg.endIndex - 2] == 0xFF && jpeg[jpeg.endIndex - 1] == 0xD9
      check("R1 \(f)", dim?.0 == 6000 && dim?.1 == 4000 && framed,
            "dim=\(String(describing: dim)) bytes=\(jpeg.count) soi/eoi=\(framed)")
    }

    print("--- R2: DxO shape (PreviewImage in SubIFD1) + orientation injection ---")
    let dxo = URL(fileURLWithPath: "\(sampleDir)/2026-08-07-17-52-54.dng")
    if let jpeg = extractFullSizeEmbeddedJpeg(url: dxo) {
      let dim = pixelDimensions(of: jpeg)
      check("R2 dxo-fullsize", dim?.0 == 6000 && dim?.1 == 4000,
            "dim=\(String(describing: dim)) bytes=\(jpeg.count)")
      check("R2 dxo-orientation-visible-to-imageio", imageIOOrientation(of: jpeg) == 6,
            "ImageIO orientation=\(String(describing: imageIOOrientation(of: jpeg))) (expect 6)")
      // The injection must be what put it there: the segment sits right after
      // SOI, and the bytes underneath carry no orientation of their own.
      if let (_, ori) = firstApp1Orientation(jpeg) {
        check("R2 dxo-app1-injected", ori == 6, "APP1 immediately after SOI declares orientation \(ori)")
        if let stripped = strippingFirstApp1(jpeg) {
          check("R2 dxo-source-had-no-orientation",
                imageIOOrientation(of: stripped) == nil,
                "with the injected APP1 removed, ImageIO reports "
                  + "\(String(describing: imageIOOrientation(of: stripped))) (expect nil)")
        } else {
          check("R2 dxo-source-had-no-orientation", false, "could not strip APP1")
        }
      } else {
        check("R2 dxo-app1-injected", false,
              "no EXIF APP1 immediately after SOI -- orientation was not injected")
      }
    } else {
      check("R2 dxo-fullsize", false, "returned nil, expected full-size JPEG bytes")
    }

    print("--- R3: CFA-only shape (vivo) must fall back ---")
    let cfa = URL(fileURLWithPath: "\(sampleDir)/IMG_20251112_092839.dng")
    let out = extractFullSizeEmbeddedJpeg(url: cfa)
    check("R3 cfa-negative", out == nil,
          "returned \(describe(out)) (expect nil so the caller falls back)")
  }

  // ---- synthetic material: makes the format guards observable ------------

  static func syntheticGuards() {
    print("--- S1: guards (single-strip decoys larger than the valid preview) ---")
    let url = URL(fileURLWithPath: "\(fixtureDir)/synth_guards.dng")
    let good = synthPayload("GOOD", 100)
    let out = extractFullSizeEmbeddedJpeg(url: url)
    check("S1 selects-the-guarded-candidate", out == good,
          "got \(describe(out)); expected the 5600x3733 YCbCr/JPEG payload "
            + "(\(good.count) bytes). Decoys present: 6000x4000 CFA+LossyJPEG main, "
            + "6000x4000 LinearRaw+JPEG, 6000x4000 YCbCr+LossyJPEG -- all single-strip "
            + "and larger, so any dropped guard changes this answer.")
  }

  static func syntheticTwoValid() {
    print("--- S5: two fully valid candidates -> the larger wins ---")
    let url = URL(fileURLWithPath: "\(fixtureDir)/synth_two_valid.dng")
    let bigger = synthPayload("BIGG", 300)
    let out = extractFullSizeEmbeddedJpeg(url: url)
    check("S5 picks-largest-candidate", out == bigger,
          "got \(describe(out)); expected the 6000x4000 payload "
            + "(\(bigger.count) bytes), not the 5600x3733 one which is listed first")
  }

  static func syntheticMultiStrip() {
    print("--- S6: multi-strip candidate must be skipped, not half-sliced ---")
    let url = URL(fileURLWithPath: "\(fixtureDir)/synth_multistrip.dng")
    let good = synthPayload("GOOD", 100)
    let out = extractFullSizeEmbeddedJpeg(url: url)
    check("S6 skips-multi-strip", out == good,
          "got \(describe(out)); the 6000x4000 YCbCr/JPEG candidate is stored in two "
            + "strips, so taking it would return only the first strip. Expected the "
            + "single-strip 5600x3733 preview (\(good.count) bytes).")
  }

  static func syntheticThreshold() {
    print("--- S2: 90% DefaultCropSize threshold ---")
    let url = URL(fileURLWithPath: "\(fixtureDir)/synth_too_small.dng")
    let out = extractFullSizeEmbeddedJpeg(url: url)
    check("S2 rejects-half-size-preview", out == nil,
          "got \(describe(out)); the only YCbCr/JPEG candidate is 3000x2000 = 50% of "
            + "DefaultCropSize 6000x4000, below the 0.90 threshold")
  }

  static func syntheticOrientation() {
    print("--- S3/S4: EXIF orientation injection ---")
    let plain = synthPayload("GOOD", 100)

    let url8 = URL(fileURLWithPath: "\(fixtureDir)/synth_orient8.dng")
    if let out = extractFullSizeEmbeddedJpeg(url: url8) {
      check("S3 injects-ifd0-orientation", firstApp1Orientation(out)?.orientation == 8,
            "APP1 orientation=\(String(describing: firstApp1Orientation(out)?.orientation)) "
              + "(IFD0 says 8)")
      check("S3 payload-otherwise-untouched", strippingFirstApp1(out) == plain,
            "removing the injected APP1 must give back the embedded bytes exactly; "
              + "got \(describe(strippingFirstApp1(out)))")
    } else {
      check("S3 injects-ifd0-orientation", false, "extractor returned nil")
      check("S3 payload-otherwise-untouched", false, "extractor returned nil")
    }

    let urlPre = URL(fileURLWithPath: "\(fixtureDir)/synth_preexisting_exif.dng")
    let expected = { () -> Data in
      // payload_with_exif("GOOD", 100, orientation: 3) from make_synth_dng.py
      var d = Data([0xFF, 0xD8])
      d.append(app1(orientation: 3))
      d.append(plain[(plain.startIndex + 2)...])
      return d
    }()
    let out = extractFullSizeEmbeddedJpeg(url: urlPre)
    check("S4 does-not-overwrite-existing-exif", out == expected,
          "the embedded JPEG already declares orientation 3 while IFD0 says 8; "
            + "the extractor must return it untouched. got \(describe(out)), "
            + "expected \(describe(expected))")
  }

  /// Mirrors make_synth_dng.py's exif_app1().
  static func app1(orientation: UInt16) -> Data {
    var tiff = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
    tiff.append(contentsOf: [0x01, 0x00])
    tiff.append(contentsOf: [0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00])
    tiff.append(UInt8(orientation & 0xFF))
    tiff.append(UInt8((orientation >> 8) & 0xFF))
    tiff.append(contentsOf: [0x00, 0x00])
    tiff.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
    var seg = Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00])
    seg.append(tiff)
    let len = UInt16(seg.count + 2)
    var app = Data([0xFF, 0xE1, UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)])
    app.append(seg)
    return app
  }
}
