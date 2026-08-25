import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/services/image_pipeline/dart_image_loader.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_embedded_jpeg_extractor.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';

import 'support/synthetic_dng.dart';

void main() {
  final sampleDir = Directory('local_data/photo_samples/DNG');
  List<File> dngs() => sampleDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.dng'))
      .toList();

  test('jpeg returns its exact bytes without decoding', () async {
    final dir = await Directory.systemTemp.createTemp('dart_image_loader');
    addTearDown(() => dir.delete(recursive: true));
    final jpeg = File('${dir.path}/a.jpg');
    await jpeg.writeAsBytes(const [0xFF, 0xD8, 0xFF, 0xD9]); // SOI+EOI only
    final result = await dartImageLoad(
      jpeg.path,
      purpose: ImageRequestPurpose.preview,
    );
    expect(result, isA<NativeImageBytes>());
    expect((result as NativeImageBytes).bytes, const [0xFF, 0xD8, 0xFF, 0xD9]);
  });

  test('preview-bearing DNGs return exactly the extractor bytes', () async {
    var covered = 0;
    for (final f in dngs()) {
      final expected =
          await DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpegFromFile(f.path);
      if (expected == null) continue;
      covered++;
      final result = await dartImageLoad(
        f.path,
        purpose: ImageRequestPurpose.preview,
      );
      expect(result, isA<NativeImageBytes>(), reason: f.path);
      expect((result as NativeImageBytes).bytes, expected, reason: f.path);
    }
    expect(
      covered,
      greaterThan(0),
      reason: 'sample set must exercise the hit path',
    );
  });

  test(
    'no-preview DNGs yield NeedsRawDecode with the walked orientation',
    () async {
      var covered = 0;
      for (final f in dngs()) {
        final full =
            await DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpegFromFile(
              f.path,
            );
        if (full != null) continue;
        covered++;
        final result = await dartImageLoad(
          f.path,
          purpose: ImageRequestPurpose.preview,
        );
        expect(result, isA<NativeImageNeedsRawDecode>(), reason: f.path);
        final walked = await DngEmbeddedJpegExtractor.readOrientation(f.path);
        expect(
          (result as NativeImageNeedsRawDecode).exifOrientation,
          walked ?? kDefaultExifOrientation,
          reason: f.path,
        );
      }
      expect(
        covered,
        greaterThan(0),
        reason: 'sample set must exercise the miss path',
      );
    },
  );

  test('sidebar purpose never returns the raw-decode signal', () async {
    for (final f in dngs()) {
      final result = await dartImageLoad(
        f.path,
        purpose: ImageRequestPurpose.sidebarThumbnail,
      );
      expect(result is! NativeImageNeedsRawDecode, isTrue, reason: f.path);
    }
  });

  test('missing file is a failure, not a throw', () async {
    final result = await dartImageLoad(
      '/nonexistent/x.dng',
      purpose: ImageRequestPurpose.preview,
    );
    expect(result, isA<NativeImageFailure>());
  });

  test('non-DNG RAW: embedded preview is served, no-preview is an explicit'
      ' unsupported state (never the raw-decode signal)', () async {
    final dir = await Directory.systemTemp.createTemp('dart_image_loader_raw');
    addTearDown(() => dir.delete(recursive: true));
    var hits = 0, misses = 0;
    for (final f in dngs()) {
      final full =
          await DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpegFromFile(f.path);
      final asArw = File('${dir.path}/${f.uri.pathSegments.last}.arw');
      await f.copy(asArw.path);
      final result = await dartImageLoad(
        asArw.path,
        purpose: ImageRequestPurpose.preview,
      );
      if (full != null) {
        hits++;
        expect(result, isA<NativeImageBytes>(), reason: asArw.path);
      } else {
        misses++;
        expect(result, isA<NativeImageFailure>(), reason: asArw.path);
        expect((result as NativeImageFailure).code, 'RAW_NO_EMBEDDED_PREVIEW');
      }
    }
    expect(hits, greaterThan(0));
    expect(misses, greaterThan(0));
  });

  // M6 P3.7 (F-20): oversized-image guard — same 1.5GB decoded-pixel budget
  // the deleted native guard (AppDelegate.swift renderCGImage) enforced.
  Uint8List handcraftedOversizedTiff() {
    // Minimal little-endian TIFF: header + IFD0 with two SHORT tags,
    // ImageWidth (0x0100) and ImageLength (0x0101), both claiming 40000 —
    // 40000*40000*4 = 6.4e9 bytes, far past the 1.5e9 budget. No strips.
    final bytes = ByteData(38);
    // Header: "II", magic 42, IFD0 offset 8.
    bytes.setUint8(0, 0x49); // 'I'
    bytes.setUint8(1, 0x49); // 'I'
    bytes.setUint16(2, 42, Endian.little);
    bytes.setUint32(4, 8, Endian.little);
    // IFD0 @ offset 8: 2 entries.
    bytes.setUint16(8, 2, Endian.little);
    // Entry 0: tag 0x0100 (ImageWidth), type 3 (SHORT), count 1, value 40000.
    bytes.setUint16(10, 0x0100, Endian.little);
    bytes.setUint16(12, 3, Endian.little);
    bytes.setUint32(14, 1, Endian.little);
    bytes.setUint16(18, 40000, Endian.little);
    // Entry 1: tag 0x0101 (ImageLength), type 3 (SHORT), count 1, value 40000.
    bytes.setUint16(22, 0x0101, Endian.little);
    bytes.setUint16(24, 3, Endian.little);
    bytes.setUint32(26, 1, Endian.little);
    bytes.setUint16(30, 40000, Endian.little);
    // Next IFD offset: none.
    bytes.setUint32(34, 0, Endian.little);
    return bytes.buffer.asUint8List();
  }

  test('F-20: a header claiming a 40000x40000 decode is refused, never'
      ' handed to a raw decode', () async {
    final dir = await Directory.systemTemp.createTemp(
      'dart_image_loader_oversized',
    );
    addTearDown(() => dir.delete(recursive: true));
    final huge = File('${dir.path}/huge.dng');
    await huge.writeAsBytes(handcraftedOversizedTiff());
    final result = await dartImageLoad(
      huge.path,
      purpose: ImageRequestPurpose.preview,
    );
    expect(result, isA<NativeImageFailure>());
    expect((result as NativeImageFailure).code, 'IMAGE_TOO_LARGE');
  });

  test(
    'F-20: the guard does not fire on real, ordinary-sized samples',
    () async {
      expect(dngs(), isNotEmpty);
      for (final f in dngs()) {
        final result = await dartImageLoad(
          f.path,
          purpose: ImageRequestPurpose.preview,
        );
        if (result is NativeImageFailure) {
          expect(result.code, isNot('IMAGE_TOO_LARGE'), reason: f.path);
        }
      }
    },
  );

  // -------------------------------------------------------------------
  // M7 ruling G-2 / Decision Log A-6: an undersized embedded candidate sends
  // a DNG into RAW decode on the preview path, and ONLY there.
  //
  // These use a synthetic container rather than a real sample on purpose.
  // Measured over local_data/photo_samples/DNG (26 files,
  // scripts/tmp/m7-t2/newly-routed.txt): ZERO samples are newly routed by this
  // rule -- 13 already have no qualifying candidate, 13 have one that already
  // clears 2800. So no real file in the corpus can exercise this behaviour,
  // and a test built on the corpus would pass without testing anything.
  // -------------------------------------------------------------------
  group('G-2 undersized-candidate rule', () {
    late Directory tmp;
    late String dngPath;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('dart_image_loader_g2_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      // Largest (only) candidate is 160x120, far under preview's 2800.
      dngPath = await writeSyntheticDng(
        buildSyntheticDng(
          candidates: const [SyntheticCandidate(width: 160, height: 120)],
        ),
        dir: tmp,
        name: 'undersized.dng',
      );
    });

    test('(a) preview on an undersized .dng enters RAW decode instead of '
        'returning the undersized bytes', () async {
      final result = await dartImageLoad(
        dngPath,
        purpose: ImageRequestPurpose.preview,
      );
      expect(
        result,
        isA<NativeImageNeedsRawDecode>(),
        reason:
            'previously this returned NativeImageBytes with a 160x120 '
            'rendition; G-2 makes it a decode request',
      );
    });

    test('(b) the sidebar stays lenient (P-11/P-13)', () async {
      final result = await dartImageLoad(
        dngPath,
        purpose: ImageRequestPurpose.sidebarThumbnail,
      );
      expect(result, isA<NativeImageBytes>());
      expect((result as NativeImageBytes).bytes, isNotEmpty);
    });

    test('(b) export stays lenient — strictness there would turn "export a '
        'smaller image" into "export fails"', () async {
      final result = await dartImageLoad(
        dngPath,
        purpose: ImageRequestPurpose.export,
      );
      expect(result, isA<NativeImageBytes>());
      expect((result as NativeImageBytes).bytes, isNotEmpty);
    });

    test('A-6: non-DNG RAW stays lenient — the .dng-gated RAW-decode escape '
        'hatch does not exist for it, so strictness would only delete an '
        'image the user can currently see', () async {
      final asArw = File('${tmp.path}/undersized.arw');
      await File(dngPath).copy(asArw.path);
      final result = await dartImageLoad(
        asArw.path,
        purpose: ImageRequestPurpose.preview,
      );
      expect(
        result,
        isA<NativeImageBytes>(),
        reason:
            'a rejection here would fall through to '
            'RAW_NO_EMBEDDED_PREVIEW, not to a decode',
      );
    });

    test('a DNG whose candidate DOES clear 2800 is unaffected on the preview '
        'path', () async {
      final bigPath = await writeSyntheticDng(
        buildSyntheticDng(
          candidates: const [SyntheticCandidate(width: 3000, height: 2250)],
        ),
        dir: tmp,
        name: 'large.dng',
      );
      final result = await dartImageLoad(
        bigPath,
        purpose: ImageRequestPurpose.preview,
      );
      expect(result, isA<NativeImageBytes>());
    });
  });

  // -------------------------------------------------------------------
  // M7 Task 3 (audit gaps 2+3): a container that parsed but declares only
  // unreadable candidates is BROKEN, not preview-less. Before this it was
  // handed to the RAW decoder as though it were merely preview-less.
  //
  // `corruptOffsets: true` is exactly that input: IFD0 stays walkable (the
  // orientation still reads) while every StripOffsets points past EOF.
  // -------------------------------------------------------------------
  group('malformed-DNG parse-failure state', () {
    late Directory tmp;
    late String corruptPath;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('dart_image_loader_t3_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      corruptPath = await writeSyntheticDng(
        buildSyntheticDng(
          candidates: const [SyntheticCandidate(width: 3000, height: 2250)],
          corruptOffsets: true,
        ),
        dir: tmp,
        name: 'corrupt.dng',
      );
    });

    test('(a) preview on a container whose every declared candidate is '
        'unreadable fails fast instead of entering RAW decode', () async {
      final result = await dartImageLoad(
        corruptPath,
        purpose: ImageRequestPurpose.preview,
      );
      expect(
        result,
        isA<NativeImageFailure>(),
        reason: 'previously this returned NativeImageNeedsRawDecode',
      );
      expect((result as NativeImageFailure).code, 'DNG_PARSE_FAILED');
    });

    test('(c) the sidebar branch is unchanged: still NO_THUMBNAIL', () async {
      final result = await dartImageLoad(
        corruptPath,
        purpose: ImageRequestPurpose.sidebarThumbnail,
      );
      expect(result, isA<NativeImageFailure>());
      expect((result as NativeImageFailure).code, 'NO_THUMBNAIL');
    });

    test('(b) a real preview-less DNG still yields NeedsRawDecode — the '
        'valid-miss path did not regress', () async {
      var covered = 0;
      for (final f in dngs()) {
        final full =
            await DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpegFromFile(
              f.path,
            );
        if (full != null) continue;
        covered++;
        final result = await dartImageLoad(
          f.path,
          purpose: ImageRequestPurpose.preview,
        );
        expect(result, isA<NativeImageNeedsRawDecode>(), reason: f.path);
      }
      expect(
        covered,
        greaterThan(0),
        reason: 'sample set must exercise the valid-miss path',
      );
    });

    test('the G-2 undersized rejection is NOT malformed — an intact but small '
        'candidate keeps routing to RAW decode', () async {
      final smallPath = await writeSyntheticDng(
        buildSyntheticDng(
          candidates: const [SyntheticCandidate(width: 160, height: 120)],
        ),
        dir: tmp,
        name: 'small.dng',
      );
      final probe = await DngEmbeddedJpegExtractor.probeEmbeddedJpeg(
        smallPath,
        longEdge: null,
        minLongEdge: ImageRequestPurpose.preview.targetSize,
      );
      expect(probe.jpeg, isNull);
      expect(probe.malformed, isFalse);
    });

    test('probe: a corrupt container reports malformed, an intact one does '
        'not, and a non-TIFF file is not malformed either', () async {
      final corrupt = await DngEmbeddedJpegExtractor.probeEmbeddedJpeg(corruptPath);
      expect(corrupt.jpeg, isNull);
      expect(corrupt.malformed, isTrue);

      final intactPath = await writeSyntheticDng(
        buildSyntheticDng(
          candidates: const [SyntheticCandidate(width: 3000, height: 2250)],
        ),
        dir: tmp,
        name: 'intact.dng',
      );
      final intact = await DngEmbeddedJpegExtractor.probeEmbeddedJpeg(intactPath);
      expect(intact.jpeg, isNotNull);
      expect(intact.malformed, isFalse);

      // Fails before IFD0 is readable: walks to null as it always did, and is
      // explicitly NOT malformed-with-candidates.
      final junk = File('${tmp.path}/junk.dng');
      await junk.writeAsBytes(Uint8List.fromList(List<int>.filled(64, 0x5A)));
      final notTiff = await DngEmbeddedJpegExtractor.probeEmbeddedJpeg(junk.path);
      expect(notTiff.jpeg, isNull);
      expect(notTiff.malformed, isFalse);
    });

    test('extractEmbeddedJpeg keeps its contract on the same corrupt input '
        '(added API, not a migration)', () async {
      expect(
        await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(corruptPath),
        isNull,
      );
      expect(
        await DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpegFromFile(
          corruptPath,
        ),
        isNull,
      );
    });
  });
}
