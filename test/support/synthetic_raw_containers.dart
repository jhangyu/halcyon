import 'dart:typed_data';

import 'package:image/image.dart' as img;

// Code-built synthetic RAW containers (NEF-like TIFF without DefaultCropSize,
// Fujifilm RAF, Sigma X3F) mirroring the byte layouts measured on the real
// corpus files. Small JPEGs stand in for the real previews; only the ratios
// between preview and sensor extent matter to the extractor. Nothing in `lib/`
// may import this file.

/// A real JPEG of [width]x[height], optionally carrying Exif [orientation].
Uint8List syntheticJpeg(int width, int height, {int? orientation}) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(x, y, (x * 7) % 256, (y * 11) % 256, (x + y) % 256);
    }
  }
  if (orientation != null) image.exif.imageIfd.orientation = orientation;
  return img.encodeJpg(image, quality: 85);
}

void _le16(ByteData d, int o, int v) => d.setUint16(o, v, Endian.little);
void _le32(ByteData d, int o, int v) => d.setUint32(o, v, Endian.little);

void _entry(ByteData d, int o, int tag, int type, int count, int value) {
  _le16(d, o, tag);
  _le16(d, o + 2, type);
  _le32(d, o + 4, count);
  if (type == 3) {
    _le16(d, o + 8, value);
  } else {
    _le32(d, o + 8, value);
  }
}

/// Little-endian TIFF shaped like a Nikon NEF: IFD0 -> two SubIFDs, one JPEG
/// (Compression 7) and one raw mosaic (Compression 1, no strip). Deliberately
/// carries NO DefaultCropSize (0xC620), which is what real NEFs lack.
Uint8List buildSyntheticNefLike({
  required int jpegWidth,
  required int jpegHeight,
  required int rawWidth,
  required int rawHeight,
}) {
  final jpeg = syntheticJpeg(jpegWidth, jpegHeight);
  const ifd0Len = 2 + 12 + 4;
  const subLen = 2 + 6 * 12 + 4;
  const subArray = 8 + ifd0Len; // two LONG offsets
  const subA = subArray + 8;
  const subB = subA + subLen;
  const jpegOffset = subB + subLen;
  final out = Uint8List(jpegOffset + jpeg.length);
  final d = ByteData.sublistView(out);
  out[0] = 0x49;
  out[1] = 0x49;
  _le16(d, 2, 42);
  _le32(d, 4, 8);
  // IFD0: SubIFDs only.
  _le16(d, 8, 1);
  _entry(d, 10, 0x014A, 4, 2, subArray);
  _le32(d, subArray, subA);
  _le32(d, subArray + 4, subB);
  // SubIFD A: JPEG.
  _le16(d, subA, 6);
  var p = subA + 2;
  _entry(d, p, 0x0100, 4, 1, jpegWidth);
  _entry(d, p += 12, 0x0101, 4, 1, jpegHeight);
  _entry(d, p += 12, 0x0103, 3, 1, 7);
  _entry(d, p += 12, 0x0106, 3, 1, 6);
  _entry(d, p += 12, 0x0111, 4, 1, jpegOffset);
  _entry(d, p += 12, 0x0117, 4, 1, jpeg.length);
  // SubIFD B: raw mosaic, extent only.
  _le16(d, subB, 3);
  p = subB + 2;
  _entry(d, p, 0x0100, 4, 1, rawWidth);
  _entry(d, p += 12, 0x0101, 4, 1, rawHeight);
  _entry(d, p += 12, 0x0103, 3, 1, 1);
  out.setRange(jpegOffset, jpegOffset + jpeg.length, jpeg);
  return out;
}

/// Fujifilm RAF: 16-byte magic, BE JPEG offset/length at 84/88, CFA header
/// offset/length at 92/96, CFA header with tag 0x100 = (height, width) u16.
/// [jpegLengthOverride] writes a lie into the header.
Uint8List buildSyntheticRaf({
  required int jpegWidth,
  required int jpegHeight,
  required int sensorWidth,
  required int sensorHeight,
  int? orientation,
  int? jpegLengthOverride,
}) {
  final jpeg = syntheticJpeg(jpegWidth, jpegHeight, orientation: orientation);
  const jpegOffset = 148;
  final cfaOffset = jpegOffset + jpeg.length;
  const cfaLen = 4 + 4 + 4;
  final out = Uint8List(cfaOffset + cfaLen);
  final d = ByteData.sublistView(out);
  out.setRange(0, 16, 'FUJIFILMCCD-RAW '.codeUnits);
  d.setUint32(84, jpegOffset);
  d.setUint32(88, jpegLengthOverride ?? jpeg.length);
  d.setUint32(92, cfaOffset);
  d.setUint32(96, cfaLen);
  out.setRange(jpegOffset, jpegOffset + jpeg.length, jpeg);
  d.setUint32(cfaOffset, 1); // one tag
  d.setUint16(cfaOffset + 4, 0x100);
  d.setUint16(cfaOffset + 6, 4);
  d.setUint16(cfaOffset + 8, sensorHeight);
  d.setUint16(cfaOffset + 10, sensorWidth);
  return out;
}

/// Sigma X3F: FOVb header, a JPEG `IMA2` section (format 0x12), a raw `IMA2`
/// section (format 0x27, header only) and a trailing `SECd` directory whose
/// offset sits in the last 4 bytes. [directoryOffsetOverride] writes a lie.
Uint8List buildSyntheticX3f({
  required int jpegWidth,
  required int jpegHeight,
  required int rawCols,
  required int rawRows,
  int? directoryOffsetOverride,
}) {
  final jpeg = syntheticJpeg(jpegWidth, jpegHeight);
  const jpegSec = 64;
  final jpegSecLen = 28 + jpeg.length;
  final rawSec = jpegSec + jpegSecLen;
  const rawSecLen = 28 + 16; // header + a little payload
  final dir = rawSec + rawSecLen;
  final total = dir + 12 + 2 * 12 + 4;
  final out = Uint8List(total);
  final d = ByteData.sublistView(out);
  out.setRange(0, 4, 'FOVb'.codeUnits);
  void section(int o, int format, int cols, int rows) {
    out.setRange(o, o + 4, 'SECi'.codeUnits);
    _le32(d, o + 12, format);
    _le32(d, o + 16, cols);
    _le32(d, o + 20, rows);
  }

  section(jpegSec, 0x12, jpegWidth, jpegHeight);
  out.setRange(jpegSec + 28, jpegSec + jpegSecLen, jpeg);
  section(rawSec, 0x27, rawCols, rawRows);
  out.setRange(dir, dir + 4, 'SECd'.codeUnits);
  _le32(d, dir + 8, 2);
  var p = dir + 12;
  for (final (off, len) in [(jpegSec, jpegSecLen), (rawSec, rawSecLen)]) {
    _le32(d, p, off);
    _le32(d, p + 4, len);
    out.setRange(p + 8, p + 12, 'IMA2'.codeUnits);
    p += 12;
  }
  _le32(d, total - 4, directoryOffsetOverride ?? dir);
  return out;
}
