import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:halcyon_flutter/services/image_pipeline/dng_embedded_jpeg_extractor.dart';

import '../../support/sample_photos.dart';
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
  final sampleDir = sampleDngDir;

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
  }, skip: samplePhotosSkipReason);

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
    skip: samplePhotosSkipReason,
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
    skip: samplePhotosSkipReason,
  );

  test(
    'orientation tag: sample with EXIF orientation 6 is read and injected',
    () async {
      final path = '${sampleDir.path}/2026-08-07-17-52-54.dng';
      final data = await File(path).readAsBytes();
      final orientation = await DngEmbeddedJpegExtractor.readDngOrientation(
        data,
      );
      expect(orientation, 6);

      final bytes = await DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpeg(
        data,
      );
      expect(bytes, isNotNull);
      // Orientation != 1 means the extractor must have injected an APP1/Exif
      // segment right after SOI (0xFFE1 marker at offset 2).
      expect(bytes![2], 0xFF);
      expect(bytes[3], 0xE1);
    },
    skip: samplePhotosSkipReason,
  );

  group('malformed/truncated/non-DNG input degrades to null, never throws', () {
    test('empty bytes', () async {
      expect(
        await DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpeg(
          Uint8List(0),
        ),
        isNull,
      );
    });

    test('too short to contain a TIFF header', () async {
      expect(
        await DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpeg(
          Uint8List.fromList([1, 2, 3]),
        ),
        isNull,
      );
    });

    test('wrong byte-order marker (not II/MM)', () async {
      final data = Uint8List.fromList(List.filled(16, 0));
      data[0] = 0x00;
      data[1] = 0x00;
      expect(
        await DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpeg(data),
        isNull,
      );
    });

    test('valid byte-order marker but garbage magic/IFD offset', () async {
      final data = Uint8List.fromList(List.filled(16, 0xAB));
      data[0] = 0x49;
      data[1] = 0x49; // "II"
      expect(
        await DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpeg(data),
        isNull,
      );
    });

    test(
      'a real DNG truncated mid-file (IFD offsets now point past EOF)',
      () async {
        final path = '${sampleDir.path}/2026-02-15-19-37-38.dng';
        final full = await File(path).readAsBytes();
        final truncated = Uint8List.sublistView(full, 0, full.length ~/ 4);
        expect(
          await DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpeg(
            truncated,
          ),
          isNull,
        );
      },
      skip: samplePhotosSkipReason,
    );

    test('a plain JPEG (non-DNG) file is rejected without throwing', () async {
      // Not a TIFF container at all: no II/MM marker.
      final data = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0]);
      expect(
        await DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpeg(data),
        isNull,
      );
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

    test('readDngOrientation degrades to 1 for malformed input', () async {
      expect(
        await DngEmbeddedJpegExtractor.readDngOrientation(
          Uint8List.fromList([1, 2]),
        ),
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
          await DngEmbeddedJpegExtractor.readDngOrientation(
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
        await DngEmbeddedJpegExtractor.readDngOrientation(
          Uint8List.fromList([1, 2]),
        ),
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

  // -------------------------------------------------------------------
  // 2026-08-26 RAW-support contract, item 3: the Panasonic RW2 container.
  //
  // Its header is `49 49 55 00` -- little-endian `II` plus TIFF version word
  // 85, not 42 -- and, crucially, its previews are NOT strip-tagged: IFD0
  // carries neither Compression (0x0103) nor PhotometricInterpretation (0x0106)
  // nor StripOffsets/StripByteCounts nor SubIFDs, and instead holds whole JPEG
  // bitstreams inline in vendor tags 0x002E (JpgFromRaw) and 0x0127
  // (JpgFromRaw2). Accepting version 85 without teaching the walker those tags
  // would have been a no-op; that is measured, not assumed
  // (`scripts/tmp/rw2_ifd_probe.py`, output under `tmp/verify/`).
  //
  // The real sample lives outside the repo and is untracked, so the real-file
  // check stays in `scripts/tmp/rw2_walker_check.dart`. Everything below runs
  // on synthetic containers so this suite passes on a machine that has never
  // seen a Panasonic file.
  // -------------------------------------------------------------------
  group('Panasonic container (TIFF version word 85)', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('halcyon_panasonic_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    });

    Future<String> write(Uint8List bytes, String name) =>
        writeSyntheticDng(bytes, dir: tmp, name: name);

    test('full-size request selects the JpgFromRaw2 (0x0127) blob', () async {
      final path = await write(
        buildSyntheticPanasonic(
          blobs: const [
            PanasonicBlob(tag: 0x002E, width: 640, height: 480),
            PanasonicBlob(tag: 0x0127, width: 3000, height: 2000),
          ],
        ),
        'pana_two_blobs.rw2',
      );

      final full = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
        path,
        longEdge: null,
      );
      expect(full, isNotNull, reason: 'the container declares a full preview');
      expect(full!.width, 3000);
      expect(full.height, 2000);
      expect(full.bytes[0], 0xFF);
      expect(full.bytes[1], 0xD8);
      // The declared byte length is the blob's, verbatim.
      expect(full.bytes.length, greaterThan(4));

      // The image really decodes -- the frame header the walker read was the
      // bitstream's own, not a number the test handed it.
      final codec = await ui.instantiateImageCodec(full.bytes);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 3000);
      expect(frame.image.height, 2000);
      frame.image.dispose();
      codec.dispose();
    });

    test('sidebar request (longEdge 200) picks the smaller 0x002E blob',
        () async {
      final path = await write(
        buildSyntheticPanasonic(
          blobs: const [
            PanasonicBlob(tag: 0x002E, width: 640, height: 480),
            PanasonicBlob(tag: 0x0127, width: 3000, height: 2000),
          ],
        ),
        'pana_sidebar.rw2',
      );
      final sidebar = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
        path,
        longEdge: 200,
      );
      expect(sidebar, isNotNull);
      expect(sidebar!.width, 640);
      expect(sidebar.height, 480);
    });

    test('the same container with version word 42 keeps the old behaviour: '
        'vendor tags are not honoured outside the Panasonic flavour', () async {
      final asPanasonic = buildSyntheticPanasonic(
        blobs: const [PanasonicBlob(tag: 0x0127, width: 3000, height: 2000)],
      );
      final asStandard = buildSyntheticPanasonic(
        blobs: const [PanasonicBlob(tag: 0x0127, width: 3000, height: 2000)],
        versionWord: 42,
      );
      // Byte-for-byte the same container apart from the version word.
      expect(asStandard.length, asPanasonic.length);
      for (var i = 0; i < asStandard.length; i++) {
        if (i == 2 || i == 3) continue;
        expect(asStandard[i], asPanasonic[i], reason: 'byte $i');
      }

      final panaPath = await write(asPanasonic, 'flavour_85.rw2');
      final stdPath = await write(asStandard, 'flavour_42.dng');
      expect(
        await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
          panaPath,
          longEdge: null,
        ),
        isNotNull,
      );
      expect(
        await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
          stdPath,
          longEdge: null,
        ),
        isNull,
        reason: 'a version-42 container has no vendor-tag preview path',
      );
    });

    test('an unknown version word is still rejected: the gate opened for 85, '
        'not for everything', () async {
      for (final version in const [0, 41, 43, 84, 86, 0xFFFF]) {
        final path = await write(
          buildSyntheticPanasonic(
            blobs: const [PanasonicBlob(tag: 0x0127, width: 3000, height: 2000)],
            versionWord: version,
          ),
          'version_$version.rw2',
        );
        expect(
          await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
            path,
            longEdge: null,
          ),
          isNull,
          reason: 'version word $version must not parse',
        );
        expect(
          await DngEmbeddedJpegExtractor.readOrientation(path),
          isNull,
          reason: 'version word $version must not parse',
        );
      }
    });

    test('orientation is read from IFD0 and injected into the blob', () async {
      final path = await write(
        buildSyntheticPanasonic(
          blobs: const [PanasonicBlob(tag: 0x0127, width: 3000, height: 2000)],
          orientation: 6,
        ),
        'pana_orientation.rw2',
      );
      expect(await DngEmbeddedJpegExtractor.readOrientation(path), 6);
      final full = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
        path,
        longEdge: null,
      );
      expect(full, isNotNull);
      expect(full!.orientation, 6);
      expect(full.bytes[2], 0xFF, reason: 'injected APP1 marker');
      expect(full.bytes[3], 0xE1, reason: 'injected APP1 marker');
    });

    test('readImageDimensions falls back to the vendor extent tags', () async {
      final path = await write(
        buildSyntheticPanasonic(
          blobs: const [PanasonicBlob(tag: 0x0127, width: 3000, height: 2000)],
          imageWidth: 6004,
          imageHeight: 4004,
        ),
        'pana_dims.rw2',
      );
      final dims = await DngEmbeddedJpegExtractor.readImageDimensions(path);
      expect(dims, isNotNull);
      expect(dims!.width, 6004);
      expect(dims.height, 4004);
    });

    test('probeContent measures the largest blob without reading a strip',
        () async {
      final path = await write(
        buildSyntheticPanasonic(
          blobs: const [
            PanasonicBlob(tag: 0x002E, width: 640, height: 480),
            PanasonicBlob(tag: 0x0127, width: 3000, height: 2000),
          ],
        ),
        'pana_probe_content.rw2',
      );
      final probe = await DngEmbeddedJpegExtractor.probeContent(path);
      expect(probe, isNotNull);
      expect(probe!.jpegBitstream, isFalse);
      expect(probe.largestLongEdge, 3000);
      expect(probe.orientation, 1);
    });

    // AC4: the two "no preview" terminal states stay distinguishable on a
    // Panasonic container exactly as they do on a DNG (memory.md AD-022).
    group('AC4 — the two "no preview" states stay distinguishable', () {
      test('declares no preview tag at all -> miss, malformed FALSE '
          '(routes to a real RAW decode)', () async {
        final path = await write(
          buildSyntheticPanasonic(blobs: const []),
          'pana_no_preview.rw2',
        );
        final probe = await DngEmbeddedJpegExtractor.probeEmbeddedJpeg(
          path,
          longEdge: null,
        );
        expect(probe.jpeg, isNull);
        expect(probe.malformed, isFalse);
      });

      test('declares a preview whose every blob is unreadable -> malformed TRUE',
          () async {
        final path = await write(
          buildSyntheticPanasonic(
            blobs: const [
              PanasonicBlob(
                tag: 0x0127,
                width: 3000,
                height: 2000,
                corruption: PanasonicCorruption.offsetPastEof,
              ),
            ],
          ),
          'pana_offset_past_eof.rw2',
        );
        final probe = await DngEmbeddedJpegExtractor.probeEmbeddedJpeg(
          path,
          longEdge: null,
        );
        expect(probe.jpeg, isNull);
        expect(probe.malformed, isTrue);
      });

      test('an intact but undersized blob is a deliberate miss, not damage',
          () async {
        final path = await write(
          buildSyntheticPanasonic(
            blobs: const [PanasonicBlob(tag: 0x0127, width: 640, height: 480)],
            imageWidth: 640,
            imageHeight: 480,
          ),
          'pana_undersized.rw2',
        );
        final probe = await DngEmbeddedJpegExtractor.probeEmbeddedJpeg(
          path,
          longEdge: null,
          minLongEdge: 2800,
        );
        expect(probe.jpeg, isNull);
        expect(probe.malformed, isFalse, reason: 'M7 ruling G-2: intact');
      });
    });

    // Bounds: each malformed shape must return null / the malformed verdict,
    // never an out-of-range read and never a throw.
    group('bounds checking is not weakened', () {
      test('blob offset points past EOF', () async {
        final path = await write(
          buildSyntheticPanasonic(
            blobs: const [
              PanasonicBlob(
                tag: 0x0127,
                width: 3000,
                height: 2000,
                corruption: PanasonicCorruption.offsetPastEof,
              ),
            ],
          ),
          'bounds_offset.rw2',
        );
        expect(
          await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
            path,
            longEdge: null,
          ),
          isNull,
        );
      });

      test('blob byte count runs off the end of the file', () async {
        final path = await write(
          buildSyntheticPanasonic(
            blobs: const [
              PanasonicBlob(
                tag: 0x0127,
                width: 3000,
                height: 2000,
                corruption: PanasonicCorruption.countPastEof,
              ),
            ],
          ),
          'bounds_count.rw2',
        );
        expect(
          await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
            path,
            longEdge: null,
          ),
          isNull,
        );
        final probe = await DngEmbeddedJpegExtractor.probeEmbeddedJpeg(
          path,
          longEdge: null,
        );
        expect(probe.jpeg, isNull);
        expect(probe.malformed, isTrue);
      });

      test('blob is in range but carries no SOI -> declared and broken',
          () async {
        final path = await write(
          buildSyntheticPanasonic(
            blobs: const [
              PanasonicBlob(
                tag: 0x0127,
                width: 3000,
                height: 2000,
                corruption: PanasonicCorruption.notJpeg,
              ),
            ],
          ),
          'bounds_not_jpeg.rw2',
        );
        final probe = await DngEmbeddedJpegExtractor.probeEmbeddedJpeg(
          path,
          longEdge: null,
        );
        expect(probe.jpeg, isNull);
        expect(probe.malformed, isTrue);
      });

      test('blob has an SOI but no reachable frame header -> dropped as '
          'unmeasurable, NOT reported as damage', () async {
        final path = await write(
          buildSyntheticPanasonic(
            blobs: const [
              PanasonicBlob(
                tag: 0x0127,
                width: 3000,
                height: 2000,
                corruption: PanasonicCorruption.soiOnly,
              ),
            ],
          ),
          'bounds_soi_only.rw2',
        );
        final probe = await DngEmbeddedJpegExtractor.probeEmbeddedJpeg(
          path,
          longEdge: null,
        );
        expect(probe.jpeg, isNull);
        expect(
          probe.malformed,
          isFalse,
          reason: 'a reader limit is not proof of a broken container',
        );
      });

      test('a header claiming version 85 whose IFD0 offset is past EOF walks '
          'to null, malformed FALSE (AD-022 third case)', () async {
        final data = Uint8List.fromList([
          0x49, 0x49, 0x55, 0x00, // II, version 85
          0xFF, 0xFF, 0xFF, 0x7F, // IFD0 offset far past EOF
          0, 0, 0, 0, 0, 0, 0, 0,
        ]);
        final path = await write(data, 'header_ifd_past_eof.rw2');
        final probe = await DngEmbeddedJpegExtractor.probeEmbeddedJpeg(
          path,
          longEdge: null,
        );
        expect(probe.jpeg, isNull);
        expect(probe.malformed, isFalse);
        expect(await DngEmbeddedJpegExtractor.readOrientation(path), isNull);
      });

      test('a self-referential IFD0 offset terminates', () async {
        final data = Uint8List.fromList([
          0x49, 0x49, 0x55, 0x00, // II, version 85
          0x00, 0x00, 0x00, 0x00, // IFD0 offset -> the header itself
          0, 0, 0, 0, 0, 0, 0, 0,
        ]);
        final path = await write(data, 'header_self_ref.rw2');
        expect(
          await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
            path,
            longEdge: null,
          ),
          isNull,
        );
        final probe = await DngEmbeddedJpegExtractor.probeEmbeddedJpeg(
          path,
          longEdge: null,
        );
        expect(probe.jpeg, isNull);
      });

      test('a Panasonic-magic file truncated to the bare header does not throw',
          () async {
        for (var len = 8; len <= 16; len++) {
          final data = Uint8List(len);
          data[0] = 0x49;
          data[1] = 0x49;
          data[2] = 0x55;
          data[3] = 0x00;
          data[4] = 0x08; // IFD0 at offset 8, which is at/near EOF
          final path = await write(data, 'trunc_$len.rw2');
          expect(
            await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
              path,
              longEdge: null,
            ),
            isNull,
            reason: 'length $len',
          );
          final probe = await DngEmbeddedJpegExtractor.probeEmbeddedJpeg(
            path,
            longEdge: null,
          );
          expect(probe.jpeg, isNull, reason: 'length $len');
        }
      });
    });
  });

  group('readKnownStrip (W4b round-2, S2/S3)', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('halcyon_known_strip_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    });

    test(
      'TC-925: orientation != 1 -- readKnownStrip reproduces the SAME '
      'EXIF-injected bytes extractEmbeddedJpeg selected, byte-for-byte',
      () async {
        // Local sample DNGs are all orientation 1 (per the reviewer finding
        // that motivated this test), so the injection branch needs a
        // synthetic fixture to exercise at all.
        final path = await writeSyntheticDng(
          buildSyntheticDng(
            candidates: const [SyntheticCandidate(width: 400, height: 300)],
            orientation: 6,
          ),
          dir: tmp,
          name: 'oriented.dng',
        );

        final extracted = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
          path,
          longEdge: null,
        );
        expect(extracted, isNotNull);
        expect(extracted!.orientation, 6);

        final replayed = await DngEmbeddedJpegExtractor.readKnownStrip(
          path,
          offset: extracted.offset,
          byteCount: extracted.byteCount,
          orientation: extracted.orientation,
          strictBitstream: false,
        );
        expect(replayed, isNotNull);
        expect(
          replayed,
          extracted.bytes,
          reason:
              'readKnownStrip must reproduce the exact same '
              'EXIF-orientation-injected bytes the recording walk selected',
        );
      },
    );

    test(
      'TC-926: a stale (offset, byteCount) beyond the current file length '
      'returns null, not a throw or a short read',
      () async {
        final path = await writeSyntheticDng(
          buildSyntheticDng(
            candidates: const [SyntheticCandidate(width: 400, height: 300)],
          ),
          dir: tmp,
          name: 'shrunk.dng',
        );
        final fullLength = await File(path).length();

        final result = await DngEmbeddedJpegExtractor.readKnownStrip(
          path,
          offset: fullLength, // starts exactly at EOF: nothing to read
          byteCount: 4096,
          orientation: 1,
          strictBitstream: false,
        );
        expect(result, isNull);
      },
    );

    test(
      'TC-927: strictBitstream mirrors the recording walk -- a no-SOI strip '
      'is accepted when strictBitstream: false (matching extractEmbeddedJpeg\'s '
      'sidebar-facing _walk) and rejected when strictBitstream: true '
      '(matching probeEmbeddedJpeg\'s _probeWalk)',
      () async {
        // Build a container whose candidate strip does NOT start with a JPEG
        // SOI marker -- corruptOffsets keeps the container structurally
        // walkable while pointing the strip somewhere that is in-bounds but
        // not a JPEG, by writing the candidate then overwriting its first two
        // bytes after the fact.
        final bytes = buildSyntheticDng(
          candidates: const [SyntheticCandidate(width: 400, height: 300)],
        );
        // The extractor's own leniency test elsewhere locates candidates by
        // walking the container rather than assuming a fixed layout, so do
        // the same here: extract once (non-strict) to learn where the strip
        // actually landed, THEN corrupt just those two bytes and reopen.
        final path = await writeSyntheticDng(bytes, dir: tmp, name: 'soi.dng');
        final located = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
          path,
          longEdge: null,
        );
        expect(located, isNotNull);

        final corrupted = Uint8List.fromList(bytes);
        corrupted[located!.offset] = 0x00;
        corrupted[located.offset + 1] = 0x00;
        final corruptPath = await writeSyntheticDng(
          corrupted,
          dir: tmp,
          name: 'no_soi.dng',
        );

        final lenient = await DngEmbeddedJpegExtractor.readKnownStrip(
          corruptPath,
          offset: located.offset,
          byteCount: located.byteCount,
          orientation: 1,
          strictBitstream: false,
        );
        expect(
          lenient,
          isNotNull,
          reason:
              'strictBitstream: false must accept a no-SOI strip, matching '
              'extractEmbeddedJpeg / the sidebar memo\'s recording walk',
        );

        final strict = await DngEmbeddedJpegExtractor.readKnownStrip(
          corruptPath,
          offset: located.offset,
          byteCount: located.byteCount,
          orientation: 1,
          strictBitstream: true,
        );
        expect(
          strict,
          isNull,
          reason:
              'strictBitstream: true must reject the same no-SOI strip, '
              'matching probeEmbeddedJpeg\'s _probeWalk',
        );
      },
    );
  });
}

// ---------------------------------------------------------------------
// Synthetic Panasonic RW2 container builder.
//
// Deliberately local to this file rather than added to
// test/support/synthetic_dng.dart: that generator is frozen (memory.md AD-022)
// and models the Adobe strip-tagged layout, which is precisely the layout a
// Panasonic file does NOT use.
//
// Layout produced (little-endian only -- every RW2 observed is `II`):
//
//   0   `II`, version word (85 by default), IFD0 offset = 8
//   8   IFD0: 0x0002/0x0003 sensor w/h, 0x0006/0x0007 image h/w,
//       0x002E and/or 0x0127 JPEG blobs (UNDEFINED, count == byte length),
//       0x0112 Orientation -- written in ascending tag order
//   ..  the JPEG payloads themselves
// ---------------------------------------------------------------------

/// How a blob should be broken, if at all.
enum PanasonicCorruption {
  /// Well-formed.
  none,

  /// The tag's value field points past EOF.
  offsetPastEof,

  /// The tag's declared byte count runs off the end of the file.
  countPastEof,

  /// In-range bytes that are not a JPEG bitstream at all.
  notJpeg,

  /// In-range bytes that start with SOI but carry no frame header.
  soiOnly,
}

/// One vendor-tag JPEG blob to place in the synthetic Panasonic container.
class PanasonicBlob {
  const PanasonicBlob({
    required this.tag,
    required this.width,
    required this.height,
    this.corruption = PanasonicCorruption.none,
  });

  final int tag;
  final int width;
  final int height;
  final PanasonicCorruption corruption;
}

/// Builds a complete in-memory Panasonic-flavoured container.
///
/// [versionWord] is written verbatim so a test can hold the whole container
/// constant and vary only the two bytes the walker gates on.
Uint8List buildSyntheticPanasonic({
  required List<PanasonicBlob> blobs,
  int versionWord = 85,
  int orientation = 1,
  int? imageWidth,
  int? imageHeight,
}) {
  final payloads = blobs.map(_panasonicPayload).toList(growable: false);

  var frameWidth = 0;
  var frameHeight = 0;
  for (final b in blobs) {
    if (b.width > frameWidth) frameWidth = b.width;
    if (b.height > frameHeight) frameHeight = b.height;
  }
  final width = imageWidth ?? (frameWidth == 0 ? 4000 : frameWidth);
  final height = imageHeight ?? (frameHeight == 0 ? 3000 : frameHeight);

  const headerLength = 8;
  final entryCount = 5 + blobs.length; // 4 extent tags + orientation + blobs
  final ifdLength = 2 + entryCount * 12 + 4;
  var cursor = headerLength + ifdLength;

  final payloadOffsets = <int>[];
  for (final payload in payloads) {
    payloadOffsets.add(cursor);
    cursor += payload.length;
  }
  final total = cursor;

  final out = Uint8List(total);
  void u16(int offset, int value) {
    out[offset] = value & 0xFF;
    out[offset + 1] = (value >> 8) & 0xFF;
  }

  void u32(int offset, int value) {
    out[offset] = value & 0xFF;
    out[offset + 1] = (value >> 8) & 0xFF;
    out[offset + 2] = (value >> 16) & 0xFF;
    out[offset + 3] = (value >> 24) & 0xFF;
  }

  out[0] = 0x49;
  out[1] = 0x49;
  u16(2, versionWord);
  u32(4, headerLength);

  // Entries are collected then sorted, because a real IFD is tag-ordered and
  // the blob tags straddle Orientation (0x002E < 0x0112 < 0x0127).
  final entries = <(int, void Function(int))>[];

  void shortEntry(int tag, int value) {
    entries.add((
      tag,
      (pos) {
        u16(pos, tag);
        u16(pos + 2, 3); // SHORT
        u32(pos + 4, 1);
        u16(pos + 8, value);
        u16(pos + 10, 0);
      },
    ));
  }

  shortEntry(0x0002, width); // sensor width
  shortEntry(0x0003, height); // sensor height
  shortEntry(0x0006, height); // image height
  shortEntry(0x0007, width); // image width
  shortEntry(0x0112, orientation);

  for (var i = 0; i < blobs.length; i++) {
    final blob = blobs[i];
    final payload = payloads[i];
    final offset = blob.corruption == PanasonicCorruption.offsetPastEof
        ? total + 4096
        : payloadOffsets[i];
    final count = blob.corruption == PanasonicCorruption.countPastEof
        ? payload.length + total
        : payload.length;
    entries.add((
      blob.tag,
      (pos) {
        u16(pos, blob.tag);
        u16(pos + 2, 7); // UNDEFINED
        u32(pos + 4, count);
        u32(pos + 8, offset);
      },
    ));
  }

  entries.sort((a, b) => a.$1.compareTo(b.$1));
  u16(headerLength, entryCount);
  var pos = headerLength + 2;
  for (final entry in entries) {
    entry.$2(pos);
    pos += 12;
  }
  u32(pos, 0); // next-IFD offset: none

  for (var i = 0; i < payloads.length; i++) {
    out.setRange(
      payloadOffsets[i],
      payloadOffsets[i] + payloads[i].length,
      payloads[i],
    );
  }
  return out;
}

/// The bytes a blob should contain, honouring its corruption mode.
Uint8List _panasonicPayload(PanasonicBlob blob) {
  switch (blob.corruption) {
    case PanasonicCorruption.notJpeg:
      return Uint8List.fromList(List.filled(2048, 0xAB));
    case PanasonicCorruption.soiOnly:
      final bytes = Uint8List.fromList(List.filled(2048, 0xAB));
      bytes[0] = 0xFF;
      bytes[1] = 0xD8;
      return bytes;
    case PanasonicCorruption.none:
    case PanasonicCorruption.offsetPastEof:
    case PanasonicCorruption.countPastEof:
      final image = img.Image(width: blob.width, height: blob.height);
      for (var y = 0; y < blob.height; y++) {
        for (var x = 0; x < blob.width; x++) {
          image.setPixelRgb(
            x,
            y,
            (x * 7) & 0xFF,
            (y * 11) & 0xFF,
            (x + y) & 0xFF,
          );
        }
      }
      return img.encodeJpg(image, quality: 85);
  }
}
