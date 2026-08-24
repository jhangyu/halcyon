import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

// Code-built synthetic TIFF/DNG containers for tests (M7 Task 1, plan ruling
// G-3: the user declined a committed binary fixture corpus, so every synthetic
// input this plan needs is constructed in memory here and written to a temp
// directory by the test that needs a path).
//
// Deliberately free of `dart:ui` so it runs under plain `flutter test` with no
// engine surface. Nothing in `lib/` may import this file.
//
// Layout produced (offsets are computed, never hard-coded past the header):
//
//   0   byte-order marker (`II` or `MM`), magic 42, IFD0 offset
//   8   IFD0: Orientation (0x0112), SubIFDs (0x014A), DefaultCropSize (0xC620)
//   ..  out-of-line value blocks (DefaultCropSize; SubIFDs when > 1 entry)
//   ..  one SubIFD per candidate: ImageWidth/ImageLength/Compression(7)/
//       PhotometricInterpretation(6)/StripOffsets/StripByteCounts
//   ..  one real JPEG bitstream per candidate
//
// IFD0 itself carries no Compression tag, so the extractor's candidate walk
// skips it and only the SubIFDs are considered -- which is what real DNGs do.

/// One embedded-JPEG candidate to place in the synthetic container.
class SyntheticCandidate {
  const SyntheticCandidate({required this.width, required this.height});

  final int width;
  final int height;
}

/// Builds a complete in-memory TIFF/DNG container.
///
/// [candidates] become one SubIFD each, pointing at a real minimal JPEG
/// bitstream of the stated dimensions. [orientation] is written verbatim into
/// IFD0 tag 0x0112 (out-of-range values are allowed on purpose -- that is what
/// the orientation-clamp tests need). [bigEndian] selects the `MM` byte-order
/// marker and big-endian field encoding. [corruptOffsets] leaves the container
/// structurally walkable but points every candidate's `StripOffsets` past EOF.
///
/// Deterministic: two calls with identical arguments return byte-identical
/// output, which is what lets a differential `II` vs `MM` test attribute any
/// difference to the reader rather than to the input.
Uint8List buildSyntheticDng({
  required List<SyntheticCandidate> candidates,
  int orientation = 1,
  bool bigEndian = false,
  bool corruptOffsets = false,
}) {
  if (candidates.isEmpty) {
    throw ArgumentError.value(candidates, 'candidates', 'must not be empty');
  }

  final jpegs = candidates.map(_syntheticJpeg).toList(growable: false);

  // DefaultCropSize is the extractor's `0.90 * cropMax` reference for the
  // full-size (longEdge == null) request, so it tracks the largest candidate.
  var cropWidth = 0;
  var cropHeight = 0;
  for (final c in candidates) {
    if (c.width > cropWidth) cropWidth = c.width;
    if (c.height > cropHeight) cropHeight = c.height;
  }

  const headerLength = 8;
  const ifd0EntryCount = 3;
  const ifd0Length = 2 + ifd0EntryCount * 12 + 4;
  const subIfdEntryCount = 6;
  const subIfdLength = 2 + subIfdEntryCount * 12 + 4;

  var cursor = headerLength + ifd0Length;

  final cropValueOffset = cursor;
  cursor += 8; // two LONGs

  var subOffsetsArrayOffset = -1;
  if (candidates.length > 1) {
    subOffsetsArrayOffset = cursor;
    cursor += 4 * candidates.length;
  }

  final subIfdOffsets = <int>[];
  for (var i = 0; i < candidates.length; i++) {
    subIfdOffsets.add(cursor);
    cursor += subIfdLength;
  }

  final jpegOffsets = <int>[];
  for (final jpeg in jpegs) {
    jpegOffsets.add(cursor);
    cursor += jpeg.length;
  }

  final total = cursor;
  final out = Uint8List(total);
  final w = _Writer(out, bigEndian);

  // --- header ---
  final marker = bigEndian ? 0x4D : 0x49;
  out[0] = marker;
  out[1] = marker;
  w.u16(2, 42);
  w.u32(4, headerLength);

  // --- IFD0 --- (tags must be written in ascending order)
  w.u16(headerLength, ifd0EntryCount);
  var entryPos = headerLength + 2;
  entryPos = w.entryShortInline(entryPos, 0x0112, [orientation]);
  if (candidates.length == 1) {
    entryPos = w.entryLongInline(entryPos, 0x014A, subIfdOffsets.single);
  } else {
    entryPos = w.entryLongExternal(
      entryPos,
      0x014A,
      candidates.length,
      subOffsetsArrayOffset,
    );
    for (var i = 0; i < subIfdOffsets.length; i++) {
      w.u32(subOffsetsArrayOffset + i * 4, subIfdOffsets[i]);
    }
  }
  entryPos = w.entryLongExternal(entryPos, 0xC620, 2, cropValueOffset);
  w.u32(cropValueOffset, cropWidth);
  w.u32(cropValueOffset + 4, cropHeight);
  w.u32(entryPos, 0); // next-IFD offset: none

  // --- SubIFDs ---
  for (var i = 0; i < candidates.length; i++) {
    final c = candidates[i];
    final base = subIfdOffsets[i];
    final stripOffset = corruptOffsets ? total + 4096 : jpegOffsets[i];
    w.u16(base, subIfdEntryCount);
    var p = base + 2;
    p = w.entryLongInline(p, 0x0100, c.width); // ImageWidth
    p = w.entryLongInline(p, 0x0101, c.height); // ImageLength
    p = w.entryShortInline(p, 0x0103, const [7]); // Compression: old-style JPEG
    p = w.entryShortInline(p, 0x0106, const [6]); // Photometric: YCbCr
    p = w.entryLongInline(p, 0x0111, stripOffset); // StripOffsets
    p = w.entryLongInline(p, 0x0117, jpegs[i].length); // StripByteCounts
    w.u32(p, 0); // next-IFD offset: none
  }

  // --- JPEG payloads ---
  for (var i = 0; i < jpegs.length; i++) {
    out.setRange(jpegOffsets[i], jpegOffsets[i] + jpegs[i].length, jpegs[i]);
  }

  return out;
}

/// Writes [bytes] to `<dir>/<name>` and returns the absolute path.
Future<String> writeSyntheticDng(
  Uint8List bytes, {
  required Directory dir,
  required String name,
}) async {
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes, flush: true);
  return file.absolute.path;
}

/// A real JPEG bitstream of exactly the candidate's dimensions. The pixel
/// content is a deterministic gradient (a flat fill would let a wrong
/// width/height still round-trip visually identical).
Uint8List _syntheticJpeg(SyntheticCandidate c) {
  final image = img.Image(width: c.width, height: c.height);
  for (var y = 0; y < c.height; y++) {
    for (var x = 0; x < c.width; x++) {
      image.setPixelRgb(x, y, (x * 7) & 0xFF, (y * 11) & 0xFF, (x + y) & 0xFF);
    }
  }
  return img.encodeJpg(image, quality: 85);
}

/// Endian-aware field writer over a fixed-size buffer.
class _Writer {
  _Writer(this._out, this._bigEndian);

  final Uint8List _out;
  final bool _bigEndian;

  void u16(int offset, int value) {
    final v = value & 0xFFFF;
    if (_bigEndian) {
      _out[offset] = (v >> 8) & 0xFF;
      _out[offset + 1] = v & 0xFF;
    } else {
      _out[offset] = v & 0xFF;
      _out[offset + 1] = (v >> 8) & 0xFF;
    }
  }

  void u32(int offset, int value) {
    final v = value & 0xFFFFFFFF;
    if (_bigEndian) {
      _out[offset] = (v >> 24) & 0xFF;
      _out[offset + 1] = (v >> 16) & 0xFF;
      _out[offset + 2] = (v >> 8) & 0xFF;
      _out[offset + 3] = v & 0xFF;
    } else {
      _out[offset] = v & 0xFF;
      _out[offset + 1] = (v >> 8) & 0xFF;
      _out[offset + 2] = (v >> 16) & 0xFF;
      _out[offset + 3] = (v >> 24) & 0xFF;
    }
  }

  /// 12-byte IFD entry, SHORT type, values held inline in the value field.
  /// Returns the offset of the next entry.
  int entryShortInline(int offset, int tag, List<int> values) {
    assert(values.length <= 2);
    u16(offset, tag);
    u16(offset + 2, 3); // SHORT
    u32(offset + 4, values.length);
    for (var i = 0; i < values.length; i++) {
      u16(offset + 8 + i * 2, values[i]);
    }
    return offset + 12;
  }

  /// 12-byte IFD entry, LONG type, single value held inline.
  int entryLongInline(int offset, int tag, int value) {
    u16(offset, tag);
    u16(offset + 2, 4); // LONG
    u32(offset + 4, 1);
    u32(offset + 8, value);
    return offset + 12;
  }

  /// 12-byte IFD entry, LONG type, [count] values stored out of line at
  /// [valueOffset]. The caller writes the value block itself.
  int entryLongExternal(int offset, int tag, int count, int valueOffset) {
    u16(offset, tag);
    u16(offset + 2, 4); // LONG
    u32(offset + 4, count);
    u32(offset + 8, valueOffset);
    return offset + 12;
  }
}
