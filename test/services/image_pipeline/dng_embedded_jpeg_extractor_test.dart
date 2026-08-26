import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/services/image_pipeline/dng_embedded_jpeg_extractor.dart';

import '../../support/synthetic_dng.dart';

/// Task #1 (dng-dart-preview, AC1/AC2): pure-Dart port of the upstream macOS
/// Swift extractor that used to live under macos/Runner/ (removed upstream).
///
/// Every non-trivial-input assertion below runs against REAL DNG samples
/// under local_data/photo_samples/DNG/ (per repo red line: real photos only
/// from that directory, never a user's own library). Byte counts were
/// cross-checked against the shipped Swift extractor compiled standalone via
/// a one-off scratch harness, and matched exactly for all 14 samples in that
/// directory before this test was written.
void main() {
  final sampleDir = Directory('local_data/photo_samples/DNG');

  test('sample directory exists with at least one DNG', () {
    expect(
      sampleDir.existsSync(),
      isTrue,
      reason: 'missing ${sampleDir.path}; cannot run real-sample tests',
    );
    final dngFiles = sampleDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.dng'))
        .toList();
    expect(dngFiles, isNotEmpty);
  });

  group(
    'extractFullSizeEmbeddedJpeg — real DNG samples with embedded preview',
    () {
      // These 13 samples are known (from the Swift reference cross-check) to
      // carry a qualifying embedded full-size JPEG preview.
      const withPreview = <String>[
        '2026-02-15-19-37-38.dng',
        '2026-02-15-20-53-24.dng',
        '2026-02-15-20-53-31.dng',
        '2026-02-15-20-57-15.dng',
        '2026-02-15-20-57-23-2.dng',
        '2026-02-15-20-57-23.dng',
        '2026-02-15-20-57-26.dng',
        '2026-02-15-20-57-28.dng',
        '2026-02-15-21-53-33.dng',
        '2026-02-15-21-53-41.dng',
        '2026-02-15-21-53-42.dng',
        '2026-02-15-21-53-43.dng',
        '2026-08-07-17-52-54.dng',
      ];

      for (final name in withPreview) {
        test('$name: extracts a decodable SOI/EOI-bounded JPEG', () async {
          final path = '${sampleDir.path}/$name';
          expect(File(path).existsSync(), isTrue, reason: 'missing $path');

          final bytes =
              await DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpegFromFile(
                path,
              );
          expect(
            bytes,
            isNotNull,
            reason: '$name expected an embedded preview',
          );
          expect(bytes!.length, greaterThan(4));
          expect(bytes[0], 0xFF, reason: 'SOI marker byte 0');
          expect(bytes[1], 0xD8, reason: 'SOI marker byte 1');
          expect(bytes[bytes.length - 2], 0xFF, reason: 'EOI marker byte 0');
          expect(bytes[bytes.length - 1], 0xD9, reason: 'EOI marker byte 1');

          final codec = await ui.instantiateImageCodec(bytes);
          final frame = await codec.getNextFrame();
          expect(frame.image.width, greaterThan(0));
          expect(frame.image.height, greaterThan(0));
          frame.image.dispose();
          codec.dispose();
        });
      }
    },
  );

  test(
    'IMG_20251112_092839.dng (no qualifying embedded preview) returns null, not a crash',
    () async {
      final path = '${sampleDir.path}/IMG_20251112_092839.dng';
      expect(File(path).existsSync(), isTrue, reason: 'missing $path');
      final bytes =
          await DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpegFromFile(path);
      expect(bytes, isNull);
    },
  );

  test(
    'orientation tag: sample with EXIF orientation 6 is read and injected',
    () async {
      final path = '${sampleDir.path}/2026-08-07-17-52-54.dng';
      final data = await File(path).readAsBytes();
      final orientation = DngEmbeddedJpegExtractor.readDngOrientation(data);
      expect(orientation, 6);

      final bytes = DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpeg(data);
      expect(bytes, isNotNull);
      // Orientation != 1 means the extractor must have injected an APP1/Exif
      // segment right after SOI (0xFFE1 marker at offset 2).
      expect(bytes![2], 0xFF);
      expect(bytes[3], 0xE1);
    },
  );

  group('malformed/truncated/non-DNG input degrades to null, never throws', () {
    test('empty bytes', () {
      expect(
        DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpeg(Uint8List(0)),
        isNull,
      );
    });

    test('too short to contain a TIFF header', () {
      expect(
        DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpeg(
          Uint8List.fromList([1, 2, 3]),
        ),
        isNull,
      );
    });

    test('wrong byte-order marker (not II/MM)', () {
      final data = Uint8List.fromList(List.filled(16, 0));
      data[0] = 0x00;
      data[1] = 0x00;
      expect(DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpeg(data), isNull);
    });

    test('valid byte-order marker but garbage magic/IFD offset', () {
      final data = Uint8List.fromList(List.filled(16, 0xAB));
      data[0] = 0x49;
      data[1] = 0x49; // "II"
      expect(DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpeg(data), isNull);
    });

    test(
      'a real DNG truncated mid-file (IFD offsets now point past EOF)',
      () async {
        final path = '${sampleDir.path}/2026-02-15-19-37-38.dng';
        final full = await File(path).readAsBytes();
        final truncated = Uint8List.sublistView(full, 0, full.length ~/ 4);
        expect(
          DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpeg(truncated),
          isNull,
        );
      },
    );

    test('a plain JPEG (non-DNG) file is rejected without throwing', () {
      // Not a TIFF container at all: no II/MM marker.
      final data = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0]);
      expect(DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpeg(data), isNull);
    });

    test(
      'extractFullSizeEmbeddedJpegFromFile on a nonexistent path returns null',
      () async {
        final bytes =
            await DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpegFromFile(
              '${sampleDir.path}/does_not_exist.dng',
            );
        expect(bytes, isNull);
      },
    );

    test('readDngOrientation degrades to 1 for malformed input', () {
      expect(
        DngEmbeddedJpegExtractor.readDngOrientation(Uint8List.fromList([1, 2])),
        1,
      );
    });
  });

  // -------------------------------------------------------------------
  // M7 Task 2. Synthetic containers (test/support/synthetic_dng.dart), not
  // committed fixtures -- plan ruling G-3.
  // -------------------------------------------------------------------

  group('M7 ruling E: orientation is clamped to the EXIF-legal range 1..8', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('halcyon_orientation_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    });

    // raw tag value -> what every orientation read in the file must report.
    // 0 and 9 straddle the legal range's two boundaries; 1 and 8 are the
    // boundaries themselves and must survive untouched.
    const cases = <int, int>{0: 1, 1: 1, 8: 8, 9: 1};

    cases.forEach((raw, expected) {
      test('raw orientation $raw is reported as $expected', () async {
        final path = await writeSyntheticDng(
          buildSyntheticDng(
            candidates: const [SyntheticCandidate(width: 400, height: 300)],
            orientation: raw,
          ),
          dir: tmp,
          name: 'orientation_$raw.dng',
        );

        expect(
          await DngEmbeddedJpegExtractor.readOrientation(path),
          expected,
          reason: 'readOrientation',
        );
        expect(
          DngEmbeddedJpegExtractor.readDngOrientation(
            await File(path).readAsBytes(),
          ),
          expected,
          reason: 'readDngOrientation',
        );
        final extracted = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
          path,
          longEdge: null,
        );
        expect(extracted, isNotNull);
        expect(extracted!.orientation, expected, reason: 'extractEmbeddedJpeg');
        final probe = await DngEmbeddedJpegExtractor.probeContent(path);
        expect(probe, isNotNull);
        expect(probe!.orientation, expected, reason: 'probeContent');
      });
    });

    test('the null row: undetermined stays 1 where the contract folds it, '
        'and stays null where the contract preserves it', () async {
      // Folded: readDngOrientation cannot express "undetermined".
      expect(
        DngEmbeddedJpegExtractor.readDngOrientation(Uint8List.fromList([1, 2])),
        1,
      );
      // Preserved: readOrientation's documented three-way contract must NOT
      // have been flattened by the clamp. This is the regression that a
      // careless `_sanitizeOrientation` everywhere would cause.
      expect(
        await DngEmbeddedJpegExtractor.readOrientation('${tmp.path}/absent.dng'),
        isNull,
      );
    });
  });

  group(
    'M7 ruling G-2: minLongEdge rejects an undersized selected candidate',
    () {
      late Directory tmp;
      late String path;

      setUp(() async {
        tmp = await Directory.systemTemp.createTemp('halcyon_minlongedge_');
        addTearDown(() async {
          if (await tmp.exists()) await tmp.delete(recursive: true);
        });
        path = await writeSyntheticDng(
          buildSyntheticDng(
            candidates: const [SyntheticCandidate(width: 160, height: 120)],
          ),
          dir: tmp,
          name: 'small_only.dng',
        );
      });

      test(
        'longEdge: null — rejected with minLongEdge, returned without',
        () async {
          expect(
            await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
              path,
              longEdge: null,
              minLongEdge: 2800,
            ),
            isNull,
          );
          final lenient = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
            path,
            longEdge: null,
          );
          expect(lenient, isNotNull);
          expect(lenient!.width, 160);
          expect(lenient.height, 120);
        },
      );

      test('longEdge: 200 — same pair, proving it applies in both selection '
          'modes and not just the full-size one', () async {
        expect(
          await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
            path,
            longEdge: 200,
            minLongEdge: 2800,
          ),
          isNull,
        );
        final lenient = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
          path,
          longEdge: 200,
        );
        expect(lenient, isNotNull);
        expect(lenient!.width, 160);
        expect(lenient.height, 120);
      });

      test('minLongEdge rejects rather than re-selects: a container that HAS a '
          'qualifying candidate still returns the largest, not the smallest '
          'one clearing the bar', () async {
        final multi = await writeSyntheticDng(
          buildSyntheticDng(
            candidates: const [
              SyntheticCandidate(width: 400, height: 300),
              SyntheticCandidate(width: 3000, height: 2250),
            ],
          ),
          dir: tmp,
          name: 'multi.dng',
        );
        final result = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
          multi,
          longEdge: null,
          minLongEdge: 2800,
        );
        expect(result, isNotNull);
        expect(result!.width, 3000);
      });

      test(
        'the default is null, i.e. every existing caller is unchanged',
        () async {
          final withDefault = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
            path,
            longEdge: null,
          );
          final explicitNull = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
            path,
            longEdge: null,
            minLongEdge: null,
          );
          expect(withDefault, isNotNull);
          expect(explicitNull, isNotNull);
          expect(explicitNull!.bytes, withDefault!.bytes);
          // And the lenient wrapper the sidebar/export callers use is untouched.
          expect(
            await DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpegFromFile(path),
            withDefault.bytes,
          );
        },
      );
    },
  );
}
