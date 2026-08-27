import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/services/image_pipeline/dart_image_loader.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_embedded_jpeg_extractor.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';

import '../../support/synthetic_dng.dart';

void main() {
  final sampleDir = Directory('local_data/photo_samples/DNG');
  List<File> dngs() => sampleDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.dng'))
      .toList();

  // AC3: `NativeImageResult` still has exactly three variants (AD-010/AD-011).
  // The switch is exhaustive over the sealed class WITHOUT a default clause,
  // so adding a fourth variant makes this file stop compiling — the assertion
  // is enforced by the analyzer, and the counter proves all three arms are
  // live rather than the switch being vacuously satisfiable.
  test('AC3: NativeImageResult has exactly three variants and the D3 platform '
      'state is a failure CODE, not a fourth variant', () {
    final results = <NativeImageResult>[
      NativeImageBytes(Uint8List(0)),
      const NativeImageNeedsRawDecode(
        exifOrientation: kDefaultExifOrientation,
      ),
      const NativeImageFailure(kNoNativeDecoderCode, 'no native decoder'),
    ];
    final seen = <String>{};
    for (final r in results) {
      switch (r) {
        case NativeImageBytes():
          seen.add('bytes');
        case NativeImageNeedsRawDecode():
          seen.add('needsRawDecode');
        case NativeImageFailure():
          seen.add('failure');
      }
    }
    expect(seen, {'bytes', 'needsRawDecode', 'failure'});
    // D3 rides on the failure arm, distinct from RAW_NO_EMBEDDED_PREVIEW.
    expect(kNoNativeDecoderCode, 'NO_NATIVE_DECODER');
    expect(kNoNativeDecoderCode, isNot('RAW_NO_EMBEDDED_PREVIEW'));
  });

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

  // Was one test using `.arw` as the stand-in for "a RAW with no decode escape
  // hatch". The 2026-08-26 RAW-coverage contract moved `.arw` OUT of that class
  // (it is in the engine's capability list), so the stand-in became factually
  // wrong while the assertion stayed correct. The assertion therefore moves to
  // `.cr2`, where the original premise still holds, and the `.arw` twin below
  // pins the new behaviour. Nothing was relaxed to make the change pass.
  test('browse-only RAW (.cr2): embedded preview is served, no-preview is an'
      ' explicit unsupported state (never the raw-decode signal)', () async {
    final dir = await Directory.systemTemp.createTemp('dart_image_loader_raw');
    addTearDown(() => dir.delete(recursive: true));
    var hits = 0, misses = 0;
    for (final f in dngs()) {
      final full =
          await DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpegFromFile(f.path);
      final asCr2 = File('${dir.path}/${f.uri.pathSegments.last}.cr2');
      await f.copy(asCr2.path);
      final result = await dartImageLoad(
        asCr2.path,
        purpose: ImageRequestPurpose.preview,
      );
      if (full != null) {
        hits++;
        expect(result, isA<NativeImageBytes>(), reason: asCr2.path);
      } else {
        misses++;
        expect(result, isA<NativeImageFailure>(), reason: asCr2.path);
        expect((result as NativeImageFailure).code, 'RAW_NO_EMBEDDED_PREVIEW');
      }
    }
    expect(hits, greaterThan(0));
    expect(misses, greaterThan(0));
  });

  test('engine-decodable non-DNG RAW (.arw): embedded preview is served,'
      ' no-preview now routes to RAW decode', () async {
    final dir = await Directory.systemTemp.createTemp('dart_image_loader_arw');
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
        expect(
          result,
          isA<NativeImageNeedsRawDecode>(),
          reason:
              'before the contract this was RAW_NO_EMBEDDED_PREVIEW; the '
              'engine can decode .arw, so it must reach the decoder: '
              '${asArw.path}',
        );
      }
    }
    expect(hits, greaterThan(0));
    expect(misses, greaterThan(0));
  });

  test('the sidebar still never returns the raw-decode signal for an'
      ' engine-decodable non-DNG RAW', () async {
    // The permanent-miss logic in image_preload_controller depends on this;
    // generalising the preview route must not leak into the sidebar branch.
    // The `export` purpose is included for completeness of the guard, but note
    // (F4) the shipped export path never passes it — see
    // `photo_export_service.dart:57-58`.
    final dir = await Directory.systemTemp.createTemp('dart_image_loader_sb');
    addTearDown(() => dir.delete(recursive: true));
    for (final f in dngs()) {
      final asArw = File('${dir.path}/${f.uri.pathSegments.last}.arw');
      await f.copy(asArw.path);
      for (final purpose in const [
        ImageRequestPurpose.sidebarThumbnail,
        ImageRequestPurpose.export,
      ]) {
        final result = await dartImageLoad(asArw.path, purpose: purpose);
        expect(
          result is! NativeImageNeedsRawDecode,
          isTrue,
          reason: '${asArw.path} @ ${purpose.name}',
        );
      }
    }
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

    // F4 (round-1 reviewer): this pins the loader's `export` PURPOSE, not the
    // export FEATURE. `photo_export_service.dart:57-58` enters the loader with
    // `purpose: preview`, so a real export gets the strict floor, not this
    // lenient arm. Nothing in lib/ passes `ImageRequestPurpose.export` to the
    // loader, so this arm is currently unreachable in production. Kept because
    // the purpose exists and its semantics should stay pinned — but do not
    // read a green here as "exports are lenient".
    test('(b) the loader\'s export PURPOSE stays lenient (unreachable from the '
        'shipped export path — see F4 note above)', () async {
      final result = await dartImageLoad(
        dngPath,
        purpose: ImageRequestPurpose.export,
      );
      expect(result, isA<NativeImageBytes>());
      expect((result as NativeImageBytes).bytes, isNotEmpty);
    });

    // Was asserted on `.arw`. A-6's principle is "stay lenient where a
    // rejection lands in a failure rather than a decode"; `.arw` left that
    // class when the contract made it engine-decodable, so the assertion moves
    // to `.cr2`, which is still in it (contract decision D2 — browse-only).
    // The principle is unchanged; only its example moved.
    test('A-6: browse-only RAW (.cr2) stays lenient — the engine cannot decode '
        'it, so strictness would only delete an image the user can '
        'currently see', () async {
      final asCr2 = File('${tmp.path}/undersized.cr2');
      await File(dngPath).copy(asCr2.path);
      final result = await dartImageLoad(
        asCr2.path,
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

    test('A-6 re-derived: an undersized candidate in an engine-decodable '
        'non-DNG RAW (.arw) now enters RAW decode, because the escape hatch '
        'is no longer .dng-gated', () async {
      final asArw = File('${tmp.path}/undersized.arw');
      await File(dngPath).copy(asArw.path);
      final result = await dartImageLoad(
        asArw.path,
        purpose: ImageRequestPurpose.preview,
      );
      expect(
        result,
        isA<NativeImageNeedsRawDecode>(),
        reason:
            'strictness is now correct here: the rejection lands in a real '
            'decode instead of deleting the image',
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

    // ACCEPTANCE #1 (user ruling 2026-08-26). This test previously asserted the
    // OPPOSITE — a fail-fast DNG_PARSE_FAILED — and it was not weakened to make
    // new behaviour pass: the user overrode the pre-empt it pinned, after
    // measuring a container with unreadable previews and intact sensor data
    // that decodes in 383ms while being reported broken. The assertion is
    // inverted deliberately and on the record, not relaxed.
    test('(a) preview on a container whose every declared candidate is '
        'unreadable now REACHES the decoder instead of failing fast', () async {
      final result = await dartImageLoad(
        corruptPath,
        purpose: ImageRequestPurpose.preview,
      );
      expect(
        result,
        isA<NativeImageNeedsRawDecode>(),
        reason:
            'the pre-empt is gone: unreadable previews must not pre-judge the '
            'sensor data, which may decode perfectly well',
      );
      // The finding is carried, not lost — this is the mechanism that keeps
      // the two "no preview" states tellable apart after the decode. The
      // requirement itself (two DIFFERENT failure codes surfacing) is pinned
      // in photo_source_test.dart's "the two no-preview states stay
      // distinguishable" group, where the decode outcome is known.
      expect(
        (result as NativeImageNeedsRawDecode).declaredPreviewsUnreadable,
        isTrue,
      );
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

    // ACCEPTANCE #3. The override moved the malformed case; it must not have
    // moved this one. A container that declares NO preview at all still routes
    // to the decoder exactly as before, and — the part that keeps the two
    // states from collapsing — carries the flag FALSE, so a later decode
    // failure surfaces the uniform miss rather than calling the file broken.
    test('a container that declares no preview at all is unchanged: '
        'NeedsRawDecode with declaredPreviewsUnreadable false', () async {
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
        expect(
          (result as NativeImageNeedsRawDecode).declaredPreviewsUnreadable,
          isFalse,
          reason:
              'a genuinely preview-less container declared nothing, so nothing '
              'was unreadable: ${f.path}',
        );
      }
      expect(
        covered,
        greaterThan(0),
        reason: 'sample set must exercise the no-preview-declared path',
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

    // --- 2026-08-26 contract, as amended by the user ruling the same day. The
    // generalisation from `.dng` to every engine-decodable extension survives;
    // what changed is WHAT happens to a malformed container — it routes to the
    // decoder rather than being pre-judged broken. Same inversion as (a) above,
    // for the same reason: the assertion was overridden, not relaxed.
    test('AD-022 generalised: an engine-decodable non-DNG RAW whose every '
        'declared candidate is unreadable also reaches the decoder, carrying '
        'the finding', () async {
      final asArw = File('${tmp.path}/corrupt.arw');
      await File(corruptPath).copy(asArw.path);
      final result = await dartImageLoad(
        asArw.path,
        purpose: ImageRequestPurpose.preview,
      );
      expect(result, isA<NativeImageNeedsRawDecode>());
      expect(
        (result as NativeImageNeedsRawDecode).declaredPreviewsUnreadable,
        isTrue,
      );
    });

    test('AD-022 NOT generalised to browse-only RAW: a corrupt .cr2 keeps the '
        'uniform unsupported state, because there is no decode to pre-empt',
        () async {
      final asCr2 = File('${tmp.path}/corrupt.cr2');
      await File(corruptPath).copy(asCr2.path);
      final result = await dartImageLoad(
        asCr2.path,
        purpose: ImageRequestPurpose.preview,
      );
      expect(result, isA<NativeImageFailure>());
      expect((result as NativeImageFailure).code, 'RAW_NO_EMBEDDED_PREVIEW');
    });

    // LOAD-BEARING: widening the malformed gate is only safe because a
    // container the walker cannot parse at all reports `malformed == false`
    // (AD-022, memory.md:200) and therefore falls through to the decoder
    // rather than being reported as a broken file. If the walker ever starts
    // parsing these containers, that argument expires and this test is where
    // it must be re-examined — do not "fix" it by widening the expectation.
    test('a non-TIFF engine-decodable RAW (.cr3/.raf/.x3f) is never reported '
        'as a parse failure; it reaches the decoder', () async {
      final junk = Uint8List.fromList(List<int>.filled(4096, 0x5A));
      for (final ext in const ['.cr3', '.raf', '.x3f']) {
        final f = File('${tmp.path}/nontiff$ext');
        await f.writeAsBytes(junk);

        final probe = await DngEmbeddedJpegExtractor.probeEmbeddedJpeg(f.path);
        expect(probe.jpeg, isNull, reason: ext);
        expect(
          probe.malformed,
          isFalse,
          reason: 'the safety argument for the widened gate rests on this: $ext',
        );

        final result = await dartImageLoad(
          f.path,
          purpose: ImageRequestPurpose.preview,
        );
        expect(result, isA<NativeImageNeedsRawDecode>(), reason: ext);
      }
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

  group('phase-1 bitmap formats', () {
    late Directory tmp;

    setUpAll(() {
      tmp = Directory.systemTemp.createTempSync('halcyon_bitmap_loader');
    });
    tearDownAll(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    Future<String> writeBytes(String name, Uint8List bytes) async {
      final file = File('${tmp.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    }

    test('TC-303: a .webp takes the encoded-bitstream branch for all three '
        'purposes and returns the file\'s own bytes', () async {
      // Content need not be a valid WebP: this branch never decodes, it only
      // hands the bytes to the engine. Using a marker payload proves the
      // returned buffer is the FILE's bytes, not something re-encoded.
      final marker = Uint8List.fromList([
        0x52, 0x49, 0x46, 0x46, 0xDE, 0xAD, 0xBE, 0xEF,
      ]);
      final path = await writeBytes('a.webp', marker);
      for (final purpose in ImageRequestPurpose.values) {
        final result = await dartImageLoad(path, purpose: purpose);
        expect(result, isA<NativeImageBytes>(), reason: 'purpose $purpose');
        expect((result as NativeImageBytes).bytes, marker);
      }
    });

    test('TC-305: a .tif at preview returns NeedsRawDecode with the IFD0 '
        'orientation and declaredPreviewsUnreadable == false', () async {
      final path = await writeBytes(
        'b.tif',
        buildSyntheticTiffHeader(width: 800, height: 600, orientation: 6),
      );
      final result =
          await dartImageLoad(path, purpose: ImageRequestPurpose.preview);
      expect(result, isA<NativeImageNeedsRawDecode>());
      final signal = result as NativeImageNeedsRawDecode;
      expect(signal.exifOrientation, 6);
      expect(
        signal.declaredPreviewsUnreadable,
        isFalse,
        reason: 'a bitmap container is never preview-probed, so AD-022 '
            'cannot apply to it',
      );
    });

    test('TC-305: a .tif with no Orientation tag falls back to 1', () async {
      final path = await writeBytes(
        'b_noorient.tif',
        buildSyntheticTiffHeader(width: 800, height: 600),
      );
      final result =
          await dartImageLoad(path, purpose: ImageRequestPurpose.preview);
      expect(
        (result as NativeImageNeedsRawDecode).exifOrientation,
        kDefaultExifOrientation,
      );
    });

    test('TC-306: a .tif at sidebarThumbnail is a failure and NEVER '
        'NeedsRawDecode', () async {
      final path = await writeBytes(
        'c.tiff',
        buildSyntheticTiffHeader(width: 800, height: 600, orientation: 6),
      );
      final result = await dartImageLoad(
        path,
        purpose: ImageRequestPurpose.sidebarThumbnail,
      );
      expect(result, isNot(isA<NativeImageNeedsRawDecode>()));
      expect(result, isA<NativeImageFailure>());
      expect((result as NativeImageFailure).code, 'NO_THUMBNAIL');
    });

    test('TC-307: a TIFF header declaring 30000x30000 is IMAGE_TOO_LARGE',
        () async {
      final path = await writeBytes(
        'huge.tif',
        buildSyntheticTiffHeader(width: 30000, height: 30000),
      );
      // 30000 * 30000 * 4 == 3.6e9 > 1.5e9. The file is 26 bytes long, so a
      // result other than IMAGE_TOO_LARGE would prove the check ran after a
      // decode attempt rather than before one.
      final result =
          await dartImageLoad(path, purpose: ImageRequestPurpose.preview);
      expect(result, isA<NativeImageFailure>());
      expect((result as NativeImageFailure).code, 'IMAGE_TOO_LARGE');
    });

    test('TC-307: a TIFF just under the budget still routes to the decoder',
        () async {
      // 19364 * 19364 * 4 == 1_499_857_984 < 1_500_000_000. Pins that the
      // comparison is a strict `>` on the budget, not an off-by-one refusal.
      final path = await writeBytes(
        'nearlimit.tif',
        buildSyntheticTiffHeader(width: 19364, height: 19364),
      );
      final result =
          await dartImageLoad(path, purpose: ImageRequestPurpose.preview);
      expect(result, isA<NativeImageNeedsRawDecode>());
    });

    test('TC-324: NativeImageResult still has exactly three variants after '
        'the bitmap-format widening', () {
      // Exhaustive switch with NO default clause: a fourth variant makes this
      // file stop compiling. The counter proves all three arms are live.
      final results = <NativeImageResult>[
        NativeImageBytes(Uint8List(0)),
        const NativeImageNeedsRawDecode(
          exifOrientation: kDefaultExifOrientation,
        ),
        const NativeImageFailure('NO_THUMBNAIL', 'no embedded candidate'),
      ];
      final seen = <String>{};
      for (final r in results) {
        switch (r) {
          case NativeImageBytes():
            seen.add('bytes');
          case NativeImageNeedsRawDecode():
            seen.add('needsRawDecode');
          case NativeImageFailure():
            seen.add('failure');
        }
      }
      expect(seen, {'bytes', 'needsRawDecode', 'failure'});
    });
  });

  group('phase-2 HEIC', () {
    late Directory heicTmp;

    setUpAll(() {
      heicTmp = Directory.systemTemp.createTempSync('halcyon_heic_loader');
    });
    tearDownAll(() {
      if (heicTmp.existsSync()) heicTmp.deleteSync(recursive: true);
    });

    Future<String> writeHeic(String name) async {
      final file = File('${heicTmp.path}${Platform.pathSeparator}$name');
      // A stub ISO-BMFF-looking header is enough: the loader never decodes,
      // and the probe is injected, so no byte of this file is parsed.
      await file.writeAsBytes(
        Uint8List.fromList([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70]),
        flush: true,
      );
      return file.path;
    }

    test('TC-325: a .heic at preview returns NeedsRawDecode carrying the '
        'orientation the probe supplied', () async {
      final path = await writeHeic('a.heic');
      final result = await dartImageLoad(
        path,
        purpose: ImageRequestPurpose.preview,
        probe: (_) async => (width: 4032, height: 3024, orientation: 6),
      );
      expect(result, isA<NativeImageNeedsRawDecode>());
      final signal = result as NativeImageNeedsRawDecode;
      expect(signal.exifOrientation, 6);
      expect(
        signal.declaredPreviewsUnreadable,
        isFalse,
        reason: 'a bitmap container is never preview-probed, so AD-022 cannot '
            'apply to it',
      );
    });

    test('TC-325: a null probe answer waves through with orientation 1',
        () async {
      // The degradation path: no dylib, no symbol, or a native error. It must
      // still reach the decoder, which is what produces the permanent miss —
      // refusing here would lose the distinction TC-327 depends on.
      final path = await writeHeic('b.heif');
      final result = await dartImageLoad(
        path,
        purpose: ImageRequestPurpose.preview,
        probe: (_) async => null,
      );
      expect(result, isA<NativeImageNeedsRawDecode>());
      expect(
        (result as NativeImageNeedsRawDecode).exifOrientation,
        kDefaultExifOrientation,
      );
    });

    test('TC-326: a .heic at sidebarThumbnail is a failure and NEVER '
        'NeedsRawDecode', () async {
      final path = await writeHeic('c.heic');
      var probeCalls = 0;
      final result = await dartImageLoad(
        path,
        purpose: ImageRequestPurpose.sidebarThumbnail,
        probe: (_) async {
          probeCalls++;
          return (width: 4032, height: 3024, orientation: 1);
        },
      );
      expect(result, isNot(isA<NativeImageNeedsRawDecode>()));
      expect(result, isA<NativeImageFailure>());
      expect((result as NativeImageFailure).code, 'NO_THUMBNAIL');
      expect(
        probeCalls,
        0,
        reason: 'the sidebar bails before the probe: an FFI round trip per '
            'thumbnail would be paid for an answer that is discarded',
      );
    });

    test('TC-331: a HEIC declaring 30000x30000 is IMAGE_TOO_LARGE', () async {
      final path = await writeHeic('huge.heic');
      // 30000 * 30000 * 4 == 3.6e9 > 1.5e9. The file is 8 bytes long, so any
      // other result would prove the check ran after a decode attempt.
      final result = await dartImageLoad(
        path,
        purpose: ImageRequestPurpose.preview,
        probe: (_) async => (width: 30000, height: 30000, orientation: 1),
      );
      expect(result, isA<NativeImageFailure>());
      expect((result as NativeImageFailure).code, 'IMAGE_TOO_LARGE');
    });
  });
}
