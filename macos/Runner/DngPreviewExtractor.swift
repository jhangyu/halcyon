import Foundation
import ImageIO

// MARK: - DNG embedded full-size JPEG extraction (Round 3a)
//
// Many DNGs (Lightroom Classic, DxO PureRAW) carry a full-resolution JPEG
// rendition inside one of the TIFF SubIFDs, alongside the actual RAW mosaic.
// Reading it is a bounds-checked seek+slice -- no image decode at all -- and
// makes DNG preview requests behave exactly like the existing JPEG fast path.
// Returns nil for DNGs with no such embedded JPEG (e.g. bare CFA captures),
// in which case callers must fall back to the existing CIRAWFilter path.
//
// Deliberately Foundation-only (no FlutterMacOS import) so it can be compiled
// and exercised standalone by scripts/tmp/probe_extract.swift.

func extractFullSizeEmbeddedJpeg(url: URL) -> Data? {
  guard let data = try? Data(contentsOf: url), data.count >= 8 else { return nil }

  let start = data.startIndex
  let b0 = data[start]
  let b1 = data[start + 1]
  let littleEndian: Bool
  if b0 == 0x49 && b1 == 0x49 {
    littleEndian = true
  } else if b0 == 0x4D && b1 == 0x4D {
    littleEndian = false
  } else {
    return nil
  }

  let reader = TIFFReader(data: data, littleEndian: littleEndian)
  guard let magic = reader.u16(2), magic == 42 else { return nil }
  guard let ifd0Offset = reader.u32(4) else { return nil }
  guard let (ifd0, _) = reader.readIFD(at: Int(ifd0Offset)) else { return nil }

  // Orientation lives in IFD0.
  var orientation: UInt32 = 1
  if let entry = ifd0[0x0112], let vals = reader.values(entry), let v = vals.first {
    orientation = v
  }

  func cropSize(from entries: [UInt16: TIFFReader.IFDEntry]) -> (UInt32, UInt32)? {
    guard let entry = entries[0xC620], let vals = reader.values(entry), vals.count >= 2 else {
      return nil
    }
    return (vals[0], vals[1])
  }

  // Gather IFD0 plus every SubIFD (tag 0x014A) as candidates.
  var candidateIFDs: [[UInt16: TIFFReader.IFDEntry]] = [ifd0]
  if let subEntry = ifd0[0x014A], let subOffsets = reader.values(subEntry) {
    for off in subOffsets {
      if let (subIFD, _) = reader.readIFD(at: Int(off)) {
        candidateIFDs.append(subIFD)
      }
    }
  }

  // DefaultCropSize (0xC620) may live in IFD0 or in one of the SubIFDs.
  var defaultCrop: (UInt32, UInt32)? = cropSize(from: ifd0)
  if defaultCrop == nil {
    for ifd in candidateIFDs {
      if let c = cropSize(from: ifd) {
        defaultCrop = c
        break
      }
    }
  }
  guard let crop = defaultCrop else { return nil }
  let cropMax = Double(max(crop.0, crop.1))
  guard cropMax > 0 else { return nil }

  struct Candidate {
    let width: UInt32
    let height: UInt32
    let offset: UInt32
    let byteCount: UInt32
  }
  var best: Candidate?

  for ifd in candidateIFDs {
    guard let compEntry = ifd[0x0103], let compVals = reader.values(compEntry),
          compVals.first == 7 else { continue }
    guard let photoEntry = ifd[0x0106], let photoVals = reader.values(photoEntry),
          photoVals.first == 6 else { continue }
    guard let widthEntry = ifd[0x0100], let widthVals = reader.values(widthEntry),
          let width = widthVals.first else { continue }
    guard let heightEntry = ifd[0x0101], let heightVals = reader.values(heightEntry),
          let height = heightVals.first else { continue }
    guard let stripOffEntry = ifd[0x0111], let stripOffVals = reader.values(stripOffEntry),
          stripOffVals.count == 1 else { continue }
    guard let stripCountEntry = ifd[0x0117], let stripCountVals = reader.values(stripCountEntry),
          stripCountVals.count == 1 else { continue }

    let maxDim = Double(max(width, height))
    guard maxDim >= 0.90 * cropMax else { continue }

    let offset = stripOffVals[0]
    let byteCount = stripCountVals[0]
    guard UInt64(offset) < UInt64(data.count),
          UInt64(offset) + UInt64(byteCount) <= UInt64(data.count) else { continue }

    let area = UInt64(width) * UInt64(height)
    if best == nil || area > UInt64(best!.width) * UInt64(best!.height) {
      best = Candidate(width: width, height: height, offset: offset, byteCount: byteCount)
    }
  }

  guard let candidate = best else { return nil }
  let sliceStart = start + Int(candidate.offset)
  let sliceEnd = sliceStart + Int(candidate.byteCount)
  guard sliceStart >= start, sliceEnd <= data.endIndex, sliceStart < sliceEnd else { return nil }
  let jpegBytes = data.subdata(in: sliceStart..<sliceEnd)

  if orientation != 1, let oriented = injectExifOrientation(
    jpeg: jpegBytes, orientation: UInt16(truncatingIfNeeded: orientation)) {
    return oriented
  }
  return jpegBytes
}

/// Injects a minimal EXIF APP1 segment carrying `orientation` right after the JPEG
/// SOI marker, unless the JPEG already carries its own EXIF Orientation tag.
func injectExifOrientation(jpeg: Data, orientation: UInt16) -> Data? {
  guard jpeg.count >= 2 else { return jpeg }
  let start = jpeg.startIndex
  guard jpeg[start] == 0xFF, jpeg[start + 1] == 0xD8 else { return jpeg }

  if jpegHasExifOrientation(jpeg) {
    return jpeg
  }

  var tiff = Data()
  tiff.append(contentsOf: [0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00]) // II, 42, IFD @8
  tiff.append(contentsOf: [0x01, 0x00]) // 1 entry
  tiff.append(contentsOf: [0x12, 0x01]) // tag 0x0112 Orientation
  tiff.append(contentsOf: [0x03, 0x00]) // type SHORT
  tiff.append(contentsOf: [0x01, 0x00, 0x00, 0x00]) // count 1
  let oriLE = orientation.littleEndian
  tiff.append(UInt8(oriLE & 0xFF))
  tiff.append(UInt8((oriLE >> 8) & 0xFF))
  tiff.append(contentsOf: [0x00, 0x00]) // pad value field to 4 bytes
  tiff.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // next IFD offset = none

  var exifPayload = Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) // "Exif\0\0"
  exifPayload.append(tiff)

  let segmentLength = UInt16(exifPayload.count + 2)
  var app1 = Data([0xFF, 0xE1])
  app1.append(UInt8((segmentLength >> 8) & 0xFF))
  app1.append(UInt8(segmentLength & 0xFF))
  app1.append(exifPayload)

  var result = Data()
  result.append(jpeg[start..<(start + 2)]) // SOI
  result.append(app1)
  result.append(jpeg[(start + 2)...])
  return result
}

/// Scans JPEG marker segments for an APP1/Exif block that already declares Orientation.
func jpegHasExifOrientation(_ jpeg: Data) -> Bool {
  var pos = jpeg.startIndex + 2
  let end = jpeg.endIndex
  while pos + 2 <= end {
    guard jpeg[pos] == 0xFF else { break }
    let marker = jpeg[pos + 1]
    if marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) {
      pos += 2
      continue
    }
    if marker == 0xDA || marker == 0xD9 { break } // start-of-scan / EOI: no more markers
    guard pos + 4 <= end else { break }
    let lenHi = Int(jpeg[pos + 2])
    let lenLo = Int(jpeg[pos + 3])
    let segLen = (lenHi << 8) | lenLo
    guard segLen >= 2, pos + 2 + segLen <= end else { break }

    if marker == 0xE1 {
      let payloadStart = pos + 4
      let payloadEnd = pos + 2 + segLen
      if payloadEnd - payloadStart >= 6 {
        let header = jpeg[payloadStart..<(payloadStart + 6)]
        if header.elementsEqual([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) {
          let tiffData = jpeg.subdata(in: (payloadStart + 6)..<payloadEnd)
          if tiffDataHasOrientation(tiffData) {
            return true
          }
        }
      }
    }
    pos += 2 + segLen
  }
  return false
}

func tiffDataHasOrientation(_ tiffData: Data) -> Bool {
  guard tiffData.count >= 8 else { return false }
  let s = tiffData.startIndex
  let b0 = tiffData[s]
  let b1 = tiffData[s + 1]
  let le: Bool
  if b0 == 0x49 && b1 == 0x49 {
    le = true
  } else if b0 == 0x4D && b1 == 0x4D {
    le = false
  } else {
    return false
  }
  let reader = TIFFReader(data: tiffData, littleEndian: le)
  guard let magic = reader.u16(2), magic == 42, let ifdOff = reader.u32(4) else { return false }
  guard let (ifd, _) = reader.readIFD(at: Int(ifdOff)) else { return false }
  return ifd[0x0112] != nil
}

/// Minimal bounds-checked TIFF/IFD reader used to walk DNG structure without
/// linking a full TIFF library. Operates on untrusted file data: every read is
/// bounds-checked against `data.count` and returns nil rather than trapping.
struct TIFFReader {
  struct IFDEntry {
    let tag: UInt16
    let type: UInt16
    let count: UInt32
    let valueFieldOffset: Int
  }

  let data: Data
  let littleEndian: Bool

  func u16(_ offset: Int) -> UInt16? {
    guard offset >= 0, offset + 2 <= data.count else { return nil }
    let base = data.startIndex + offset
    let b0 = data[base]
    let b1 = data[base + 1]
    return littleEndian ? (UInt16(b0) | (UInt16(b1) << 8)) : (UInt16(b1) | (UInt16(b0) << 8))
  }

  func u32(_ offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    let base = data.startIndex + offset
    let b0 = UInt32(data[base])
    let b1 = UInt32(data[base + 1])
    let b2 = UInt32(data[base + 2])
    let b3 = UInt32(data[base + 3])
    return littleEndian ? (b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
                         : (b3 | (b2 << 8) | (b1 << 16) | (b0 << 24))
  }

  private func typeSize(_ type: UInt16) -> Int {
    switch type {
    case 1, 2, 6, 7: return 1 // BYTE, ASCII, SBYTE, UNDEFINED
    case 3, 8: return 2 // SHORT, SSHORT
    case 4, 9, 11: return 4 // LONG, SLONG, FLOAT
    case 5, 10, 12: return 8 // RATIONAL, SRATIONAL, DOUBLE
    default: return 0
    }
  }

  /// Reads an IFD at `offset`: entry count (2 bytes) + count*12-byte entries + next-IFD offset (4 bytes).
  func readIFD(at offset: Int) -> ([UInt16: IFDEntry], UInt32)? {
    guard let entryCount = u16(offset) else { return nil }
    var entries: [UInt16: IFDEntry] = [:]
    var pos = offset + 2
    for _ in 0..<Int(entryCount) {
      guard let tag = u16(pos), let type = u16(pos + 2), let count = u32(pos + 4) else {
        return nil
      }
      entries[tag] = IFDEntry(tag: tag, type: type, count: count, valueFieldOffset: pos + 8)
      pos += 12
    }
    guard let next = u32(pos) else { return nil }
    return (entries, next)
  }

  /// Resolves an entry's values as UInt32s. SHORT/LONG pass through directly;
  /// RATIONAL is reduced to a rounded quotient; BYTE is widened. Bounds-checked
  /// against `data.count`; returns nil on any malformed/out-of-range field.
  func values(_ entry: IFDEntry) -> [UInt32]? {
    let size = typeSize(entry.type)
    guard size > 0, entry.count > 0, entry.count < 100_000 else { return nil }
    let totalBytes = Int(entry.count) * size
    let base: Int
    if totalBytes <= 4 {
      base = entry.valueFieldOffset
    } else {
      guard let off = u32(entry.valueFieldOffset) else { return nil }
      base = Int(off)
    }

    var result: [UInt32] = []
    result.reserveCapacity(Int(entry.count))
    for i in 0..<Int(entry.count) {
      let elemOffset = base + i * size
      switch entry.type {
      case 3, 8: // SHORT / SSHORT
        guard let v = u16(elemOffset) else { return nil }
        result.append(UInt32(v))
      case 4, 9: // LONG / SLONG
        guard let v = u32(elemOffset) else { return nil }
        result.append(v)
      case 5, 10: // RATIONAL / SRATIONAL
        guard let num = u32(elemOffset), let den = u32(elemOffset + 4), den != 0 else {
          return nil
        }
        result.append(UInt32(max(0, (Double(num) / Double(den)).rounded())))
      case 1, 6, 7: // BYTE / SBYTE / UNDEFINED
        guard elemOffset >= 0, elemOffset < data.count else { return nil }
        result.append(UInt32(data[data.startIndex + elemOffset]))
      default:
        return nil
      }
    }
    return result
  }
}
