import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:halcyon_flutter/services/image_pipeline/dng_embedded_jpeg_extractor.dart';

/// Round-2 D4 (2026-08-30 pipeline-followup-contract.md, per
/// docs/logs/2026-08-30/payload-bench-report.md §3): Sony ARW carries its
/// full-resolution JPEG in IFD2, reachable only via the ordinary TIFF
/// `nextIFD` chain (IFD0 -> IFD1 -> IFD2), tagged with
/// JPEGInterchangeFormat/Length (0x0201/0x0202) rather than
/// StripOffsets/StripByteCounts (0x0111/0x0117), and marked Compression 6 or
/// 7 rather than only 7.
///
/// This builder is deliberately local to this file, mirroring the existing
/// local Panasonic builder in dng_embedded_jpeg_extractor_test.dart: the
/// shared test/support/synthetic_dng.dart generator is frozen (memory.md
/// AD-022) and models only the Adobe SubIFD/strip layout.
///
/// Layout produced (little-endian only):
///   0   `II`, magic 42, IFD0 offset = 8
///   8   IFD0: optional Compression(6)+Photometric(6)+JPEGInterchangeFormat/
///       Length (0x0201/0x0202) "PreviewImage" candidate, DefaultCropSize
///       (0xC620), next-IFD offset -> IFD1
///   ..  IFD1: minimal, no candidate tags, next-IFD offset -> IFD2
///   ..  IFD2: ImageWidth/Length, Compression(7), Photometric(6),
///       JPEGInterchangeFormat/Length (0x0201/0x0202) "full-res" candidate,
///       next-IFD offset = 0
///   ..  JPEG payload(s)
void main() {
  group('Sony-style IFD chain + JPEGInterchangeFormat (round-2 D4)', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('halcyon_sony_chain_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    });

    Future<String> write(Uint8List bytes, String name) async {
      final file = File('${tmp.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(bytes, flush: true);
      return file.absolute.path;
    }

    test(
      'RED (pre-fix behaviour documented): a container whose ONLY candidate '
      'sits in IFD2 (reached via nextIFD, not SubIFD) is found -- proves the '
      'chain walk, not just tag recognition',
      () async {
        final bytes = _buildSonyChain(
          ifd2Candidate: const _InterchangeCandidate(
            width: 7008,
            height: 4672,
          ),
        );
        final path = await write(bytes, 'ifd2_only.arw');

        final full = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
          path,
          longEdge: null,
        );
        expect(
          full,
          isNotNull,
          reason: 'IFD2, reachable only via the nextIFD chain, must be seen',
        );
        expect(full!.width, 7008);
        expect(full.height, 4672);
      },
    );

    test(
      'JPEGInterchangeFormat/Length (0x0201/0x0202) is recognised as a '
      'candidate strip when StripOffsets/StripByteCounts are absent',
      () async {
        final bytes = _buildSonyChain(
          ifd0Preview: const _InterchangeCandidate(width: 640, height: 424),
        );
        final path = await write(bytes, 'ifd0_preview_only.arw');

        final full = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
          path,
          longEdge: null,
        );
        expect(full, isNotNull);
        expect(full!.width, 640);
        expect(full.height, 424);
      },
    );

    test(
      'Compression 6 (old-style JPEG) is accepted, not just 7',
      () async {
        // ifd0Preview is always written with Compression 6 by the builder
        // (matching the real Sony header exiftool reported); this test's
        // job is only to confirm that value is not silently dropped.
        final bytes = _buildSonyChain(
          ifd0Preview: const _InterchangeCandidate(width: 320, height: 212),
        );
        final path = await write(bytes, 'compression6.arw');

        final full = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
          path,
          longEdge: null,
        );
        expect(full, isNotNull, reason: 'Compression 6 must be accepted');
      },
    );

    test(
      'full-size request (longEdge: null) prefers the larger IFD2 full-res '
      'candidate over the smaller IFD0 preview, mirroring the real file',
      () async {
        final bytes = _buildSonyChain(
          ifd0Preview: const _InterchangeCandidate(width: 640, height: 424),
          ifd2Candidate: const _InterchangeCandidate(
            width: 7008,
            height: 4672,
          ),
        );
        final path = await write(bytes, 'both_candidates.arw');

        final full = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
          path,
          longEdge: null,
        );
        expect(full, isNotNull);
        expect(full!.width, 7008);
        expect(full.height, 4672);

        // Sidebar-sized request should find the smaller IFD0 preview.
        final sidebar = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
          path,
          longEdge: 200,
        );
        expect(sidebar, isNotNull);
        expect(sidebar!.width, 640);
        expect(sidebar.height, 424);
      },
    );

    test(
      'no candidate anywhere in the chain -> null, not a crash '
      '(the valid-miss case must keep routing to a real RAW decode)',
      () async {
        final bytes = _buildSonyChain();
        final path = await write(bytes, 'no_candidates.arw');

        final result = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
          path,
          longEdge: null,
        );
        expect(result, isNull);
        final probe = await DngEmbeddedJpegExtractor.probeEmbeddedJpeg(
          path,
          longEdge: null,
        );
        expect(probe.jpeg, isNull);
        expect(
          probe.malformed,
          isFalse,
          reason: 'no declared candidate is a miss, not damage',
        );
      },
    );

    test(
      'an interchange candidate whose declared range runs past EOF is '
      'unreadable, not silently accepted (bounds check holds for the new '
      'tag pair too)',
      () async {
        final bytes = _buildSonyChain(
          ifd2Candidate: const _InterchangeCandidate(
            width: 7008,
            height: 4672,
            corruptOffset: true,
          ),
        );
        final path = await write(bytes, 'ifd2_offset_past_eof.arw');

        final result = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
          path,
          longEdge: null,
        );
        expect(result, isNull);
        final probe = await DngEmbeddedJpegExtractor.probeEmbeddedJpeg(
          path,
          longEdge: null,
        );
        expect(probe.jpeg, isNull);
        expect(
          probe.malformed,
          isTrue,
          reason: 'a declared-but-unreadable candidate is a broken container',
        );
      },
    );

    test(
      'a self-referential nextIFD chain terminates instead of looping '
      'forever (cycle guard)',
      () async {
        final bytes = _buildSonyChain(selfReferentialChain: true);
        final path = await write(bytes, 'self_ref_chain.arw');

        final result = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
          path,
          longEdge: null,
        ).timeout(const Duration(seconds: 5));
        expect(result, isNull);
      },
    );

    test(
      'existing DNG SubIFD/strip behaviour is unaffected: a standard '
      'Compression 7 + StripOffsets/StripByteCounts SubIFD is still found '
      'through the SubIFD path, unrelated to the new chain walk',
      () async {
        final bytes = _buildSonyChain(
          subIfdCandidate: const _InterchangeCandidate(width: 4000, height: 3000),
        );
        final path = await write(bytes, 'standard_subifd.arw');

        final full = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
          path,
          longEdge: null,
        );
        expect(full, isNotNull);
        expect(full!.width, 4000);
        expect(full.height, 3000);
      },
    );
  });
}

/// One JPEGInterchangeFormat/Length (0x0201/0x0202) candidate to place in a
/// synthetic IFD.
class _InterchangeCandidate {
  const _InterchangeCandidate({
    required this.width,
    required this.height,
    this.corruptOffset = false,
  });

  final int width;
  final int height;
  final bool corruptOffset;
}

Uint8List _syntheticJpeg(int width, int height) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(x, y, (x * 7) & 0xFF, (y * 11) & 0xFF, (x + y) & 0xFF);
    }
  }
  return img.encodeJpg(image, quality: 85);
}

class _W {
  _W(this._out);
  final Uint8List _out;

  void u16(int offset, int value) {
    final v = value & 0xFFFF;
    _out[offset] = v & 0xFF;
    _out[offset + 1] = (v >> 8) & 0xFF;
  }

  void u32(int offset, int value) {
    final v = value & 0xFFFFFFFF;
    _out[offset] = v & 0xFF;
    _out[offset + 1] = (v >> 8) & 0xFF;
    _out[offset + 2] = (v >> 16) & 0xFF;
    _out[offset + 3] = (v >> 24) & 0xFF;
  }

  int entryShortInline(int offset, int tag, List<int> values) {
    u16(offset, tag);
    u16(offset + 2, 3); // SHORT
    u32(offset + 4, values.length);
    for (var i = 0; i < values.length; i++) {
      u16(offset + 8 + i * 2, values[i]);
    }
    return offset + 12;
  }

  int entryLongInline(int offset, int tag, int value) {
    u16(offset, tag);
    u16(offset + 2, 4); // LONG
    u32(offset + 4, 1);
    u32(offset + 8, value);
    return offset + 12;
  }
}

/// Builds a Sony-style ARW: IFD0 (optional interchange preview candidate) ->
/// IFD1 (empty, no candidate tags) -> IFD2 (optional interchange full-res
/// candidate), connected purely through nextIFD offsets, plus an optional
/// legacy SubIFD (0x014A) candidate to prove the pre-existing path still
/// works unchanged.
Uint8List _buildSonyChain({
  _InterchangeCandidate? ifd0Preview,
  _InterchangeCandidate? ifd2Candidate,
  _InterchangeCandidate? subIfdCandidate,
  bool selfReferentialChain = false,
}) {
  final ifd0Jpeg = ifd0Preview == null
      ? null
      : _syntheticJpeg(ifd0Preview.width, ifd0Preview.height);
  final ifd2Jpeg = ifd2Candidate == null
      ? null
      : _syntheticJpeg(ifd2Candidate.width, ifd2Candidate.height);
  final subJpeg = subIfdCandidate == null
      ? null
      : _syntheticJpeg(subIfdCandidate.width, subIfdCandidate.height);

  // DefaultCropSize tracks the largest declared candidate so the full-size
  // 0.90*cropMax floor never itself becomes the reason a candidate is
  // rejected in these tests.
  var cropW = 1, cropH = 1;
  for (final c in [ifd0Preview, ifd2Candidate, subIfdCandidate]) {
    if (c == null) continue;
    if (c.width > cropW) cropW = c.width;
    if (c.height > cropH) cropH = c.height;
  }

  const headerLength = 8;

  // IFD0 entries: DefaultCropSize (0xC620) always; SubIFDs (0x014A) if a
  // sub-candidate is requested; Compression(0x0103)/Photometric(0x0106)/
  // JPEGInterchangeFormat(0x0201)/Length(0x0202) if an IFD0 preview is
  // requested. Written in ascending tag order.
  final ifd0HasPreview = ifd0Preview != null;
  final ifd0HasSub = subIfdCandidate != null;
  var ifd0EntryCount = 1; // DefaultCropSize
  if (ifd0HasSub) ifd0EntryCount += 1; // 0x014A
  if (ifd0HasPreview) ifd0EntryCount += 4; // 0x0103,0x0106,0x0201,0x0202
  final ifd0Length = 2 + ifd0EntryCount * 12 + 4;

  const ifd1EntryCount = 1; // a single harmless Orientation entry
  final ifd1Length = 2 + ifd1EntryCount * 12 + 4;

  final ifd2HasCandidate = ifd2Candidate != null;
  // 0x0100, 0x0101, 0x0103, 0x0106, 0x0201, 0x0202.
  const ifd2EntryCount = 6;
  final ifd2Length = ifd2HasCandidate ? 2 + ifd2EntryCount * 12 + 4 : 0;

  const subIfdEntryCount = 6;
  final subIfdLength = ifd0HasSub ? 2 + subIfdEntryCount * 12 + 4 : 0;

  var cursor = headerLength + ifd0Length;
  final cropValueOffset = cursor;
  cursor += 8;

  var subIfdOffset = -1;
  if (ifd0HasSub) {
    subIfdOffset = cursor;
    cursor += subIfdLength;
  }

  final ifd1Offset = cursor;
  cursor += ifd1Length;

  var ifd2Offset = -1;
  if (ifd2HasCandidate) {
    ifd2Offset = cursor;
    cursor += ifd2Length;
  }

  var ifd0JpegOffset = -1;
  if (ifd0Jpeg != null) {
    ifd0JpegOffset = cursor;
    cursor += ifd0Jpeg.length;
  }
  var ifd2JpegOffset = -1;
  if (ifd2Jpeg != null) {
    ifd2JpegOffset = cursor;
    cursor += ifd2Jpeg.length;
  }
  var subJpegOffset = -1;
  if (subJpeg != null) {
    subJpegOffset = cursor;
    cursor += subJpeg.length;
  }

  final total = cursor;
  final out = Uint8List(total);
  final w = _W(out);

  out[0] = 0x49;
  out[1] = 0x49;
  w.u16(2, 42);
  w.u32(4, headerLength);

  // --- IFD0 ---
  w.u16(headerLength, ifd0EntryCount);
  var pos = headerLength + 2;
  if (ifd0HasSub) {
    pos = w.entryLongInline(pos, 0x014A, subIfdOffset);
  }
  if (ifd0HasPreview) {
    pos = w.entryShortInline(pos, 0x0103, const [6]); // old-style JPEG
    pos = w.entryShortInline(pos, 0x0106, const [6]); // YCbCr
    final offset = ifd0Preview.corruptOffset ? total + 4096 : ifd0JpegOffset;
    pos = w.entryLongInline(pos, 0x0201, offset);
    pos = w.entryLongInline(pos, 0x0202, ifd0Jpeg!.length);
  }
  // DefaultCropSize (0xC620): 2 LONGs, stored out-of-line at cropValueOffset.
  w.u16(pos, 0xC620);
  w.u16(pos + 2, 4); // LONG
  w.u32(pos + 4, 2); // count 2
  w.u32(pos + 8, cropValueOffset);
  pos += 12;
  w.u32(cropValueOffset, cropW);
  w.u32(cropValueOffset + 4, cropH);
  // next-IFD offset -> IFD1, or a self-reference to IFD0 for the cycle test.
  w.u32(pos, selfReferentialChain ? headerLength : ifd1Offset);

  // --- IFD1 (empty, no candidate tags -- just a harmless Orientation) ---
  w.u16(ifd1Offset, ifd1EntryCount);
  var p1 = ifd1Offset + 2;
  p1 = w.entryShortInline(p1, 0x0112, const [1]);
  // next-IFD offset -> IFD2 (or back to IFD1 itself for the cycle test, or 0
  // when there is no IFD2 to visit).
  final ifd1Next = selfReferentialChain
      ? ifd1Offset
      : (ifd2HasCandidate ? ifd2Offset : 0);
  w.u32(p1, ifd1Next);

  // --- IFD2 (Sony's full-res JPEG lives here) ---
  if (ifd2HasCandidate) {
    w.u16(ifd2Offset, ifd2EntryCount);
    var p2 = ifd2Offset + 2;
    p2 = w.entryLongInline(p2, 0x0100, ifd2Candidate.width);
    p2 = w.entryLongInline(p2, 0x0101, ifd2Candidate.height);
    p2 = w.entryShortInline(p2, 0x0103, const [7]); // new-style JPEG
    p2 = w.entryShortInline(p2, 0x0106, const [6]); // YCbCr
    final offset = ifd2Candidate.corruptOffset ? total + 4096 : ifd2JpegOffset;
    p2 = w.entryLongInline(p2, 0x0201, offset);
    p2 = w.entryLongInline(p2, 0x0202, ifd2Jpeg!.length);
    w.u32(p2, 0); // next-IFD offset: none
  }

  // --- legacy SubIFD (0x014A), unrelated to the chain walk ---
  if (ifd0HasSub) {
    w.u16(subIfdOffset, subIfdEntryCount);
    var ps = subIfdOffset + 2;
    ps = w.entryLongInline(ps, 0x0100, subIfdCandidate.width);
    ps = w.entryLongInline(ps, 0x0101, subIfdCandidate.height);
    ps = w.entryShortInline(ps, 0x0103, const [7]);
    ps = w.entryShortInline(ps, 0x0106, const [6]);
    ps = w.entryLongInline(ps, 0x0111, subJpegOffset);
    ps = w.entryLongInline(ps, 0x0117, subJpeg!.length);
    w.u32(ps, 0);
  }

  if (ifd0Jpeg != null) {
    out.setRange(ifd0JpegOffset, ifd0JpegOffset + ifd0Jpeg.length, ifd0Jpeg);
  }
  if (ifd2Jpeg != null) {
    out.setRange(ifd2JpegOffset, ifd2JpegOffset + ifd2Jpeg.length, ifd2Jpeg);
  }
  if (subJpeg != null) {
    out.setRange(subJpegOffset, subJpegOffset + subJpeg.length, subJpeg);
  }

  return out;
}
