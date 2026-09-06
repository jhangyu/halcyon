import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:halcyon_flutter/services/image_pipeline/dng_embedded_jpeg_extractor.dart';
import '../../support/sample_photos.dart';
import '../../support/synthetic_dng.dart';
import '../../support/flaky_io.dart';
import 'package:flutter/foundation.dart' show listEquals;

void main() {
  group('dng_embedded_jpeg_extractor_test.dart', () {
      final sampleDir = sampleDngDir;

      // Perf note (test-speedup campaign, 2026-09-06): a handful of cases below
      // read a real sample's raw bytes directly (rather than going through
      // extractFullSizeEmbeddedJpegFromFile, which does its own internal file
      // read as part of the coverage it's testing -- that path is deliberately
      // left untouched here). Where the SAME sample is also read directly by a
      // second case (e.g. for readDngOrientation / a truncation test), share one
      // disk read instead of paying it twice.
      final Map<String, Uint8List> directReadCache = {};
      Future<Uint8List> readSampleOnce(String path) async {
        final cached = directReadCache[path];
        if (cached != null) return cached;
        final bytes = await File(path).readAsBytes();
        directReadCache[path] = bytes;
        return bytes;
      }

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
          final data = await readSampleOnce(path);
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
            final full = await readSampleOnce(path);
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

  });

  group('dng_embedded_jpeg_extractor_endian_test.dart', () {
      const candidates = <SyntheticCandidate>[
        SyntheticCandidate(width: 400, height: 300),
        SyntheticCandidate(width: 1600, height: 1200),
      ];
      const orientation = 6;

      late Directory tmp;

      setUp(() async {
        tmp = await Directory.systemTemp.createTemp('halcyon_endian_');
        addTearDown(() async {
          if (await tmp.exists()) await tmp.delete(recursive: true);
        });
      });

      // Perf note (test-speedup campaign, 2026-09-06): every call to writePair()
      // below builds and disk-writes the SAME two DNG containers (same
      // candidates/orientation, both II and MM) -- confirmed deterministic by
      // this file's own "is deterministic" test above. Several read-only tests
      // (the "II build is readable" sanity check and the whole "MM equals II"
      // group) share one build+write in a suite-scoped setUpAll instead of
      // repeating the (candidate-image JPEG encode + file write) work per test.
      // A dedicated persistent-tmp directory is used (not the per-test `tmp`
      // above, which is torn down after each test) so the cached files survive
      // the whole suite.
      late Directory sharedTmp;
      late ({String little, String big}) sharedPair;

      Future<({String little, String big})> buildPair(Directory dir) async {
        final little = await writeSyntheticDng(
          buildSyntheticDng(candidates: candidates, orientation: orientation),
          dir: dir,
          name: 'little.dng',
        );
        final big = await writeSyntheticDng(
          buildSyntheticDng(
            candidates: candidates,
            orientation: orientation,
            bigEndian: true,
          ),
          dir: dir,
          name: 'big.dng',
        );
        return (little: little, big: big);
      }

      setUpAll(() async {
        sharedTmp = await Directory.systemTemp.createTemp('halcyon_endian_shared_');
        sharedPair = await buildPair(sharedTmp);
      });

      tearDownAll(() async {
        if (await sharedTmp.exists()) await sharedTmp.delete(recursive: true);
      });

      Future<({String little, String big})> writePair() async => sharedPair;

      group('synthetic_dng helper', () {
        test('is deterministic: identical arguments give identical bytes', () {
          final a = buildSyntheticDng(
            candidates: candidates,
            orientation: orientation,
          );
          final b = buildSyntheticDng(
            candidates: candidates,
            orientation: orientation,
          );
          expect(a, equals(b));

          final bigA = buildSyntheticDng(candidates: candidates, bigEndian: true);
          final bigB = buildSyntheticDng(candidates: candidates, bigEndian: true);
          expect(bigA, equals(bigB));
        });

        test('writes the requested byte-order marker', () {
          final little = buildSyntheticDng(candidates: candidates);
          final big = buildSyntheticDng(candidates: candidates, bigEndian: true);
          expect([little[0], little[1]], equals([0x49, 0x49]));
          expect([big[0], big[1]], equals([0x4D, 0x4D]));
          // Same logical content, different encoding: the containers must not be
          // byte-identical, otherwise the differential test below proves nothing.
          expect(little, isNot(equals(big)));
          expect(little.length, equals(big.length));
        });

        test(
          'the II build is readable at all (differential sanity floor)',
          () async {
            final paths = await writePair();
            final result = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
              paths.little,
              longEdge: null,
            );
            expect(
              result,
              isNotNull,
              reason:
                  'the helper must produce a container the extractor accepts, '
                  'or MM == II would hold trivially by both being null',
            );
          },
        );
      });

      group('MM equals II', () {
        test('selected dims at longEdge: 200', () async {
          final paths = await writePair();
          final little = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
            paths.little,
            longEdge: 200,
          );
          final big = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
            paths.big,
            longEdge: 200,
          );
          expect(little, isNotNull);
          expect(big, isNotNull);
          expect(big!.width, equals(little!.width));
          expect(big.height, equals(little.height));
        });

        test('selected dims at longEdge: null', () async {
          final paths = await writePair();
          final little = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
            paths.little,
            longEdge: null,
          );
          final big = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
            paths.big,
            longEdge: null,
          );
          expect(little, isNotNull);
          expect(big, isNotNull);
          expect(big!.width, equals(little!.width));
          expect(big.height, equals(little.height));
          // The two selection modes must disagree, otherwise the longEdge: 200
          // assertion above is a duplicate of this one.
          expect(big.width, isNot(equals(400)));
        });

        test('extracted bytes are byte-identical', () async {
          final paths = await writePair();
          final little = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
            paths.little,
            longEdge: null,
          );
          final big = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
            paths.big,
            longEdge: null,
          );
          expect(little, isNotNull);
          expect(big, isNotNull);
          expect(big!.bytes, isA<Uint8List>());
          expect(big.bytes, equals(little!.bytes));
        });

        test('orientation matches', () async {
          final paths = await writePair();
          final little = await DngEmbeddedJpegExtractor.readOrientation(paths.little);
          final big = await DngEmbeddedJpegExtractor.readOrientation(paths.big);
          expect(little, equals(orientation));
          expect(big, equals(little));
        });
      });

      group('corruptOffsets', () {
        test('stays walkable but yields no extractable candidate', () async {
          final little = await writeSyntheticDng(
            buildSyntheticDng(
              candidates: candidates,
              orientation: orientation,
              corruptOffsets: true,
            ),
            dir: tmp,
            name: 'corrupt_little.dng',
          );
          final big = await writeSyntheticDng(
            buildSyntheticDng(
              candidates: candidates,
              orientation: orientation,
              bigEndian: true,
              corruptOffsets: true,
            ),
            dir: tmp,
            name: 'corrupt_big.dng',
          );
          // Structurally walkable: IFD0 still parses, so orientation still reads.
          expect(
            await DngEmbeddedJpegExtractor.readOrientation(little),
            equals(orientation),
          );
          expect(
            await DngEmbeddedJpegExtractor.readOrientation(big),
            equals(orientation),
          );
          // ...but every declared candidate points past EOF. This is Task 3's
          // malformed input; today both byte orders agree on "nothing extractable".
          expect(
            await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(little, longEdge: null),
            isNull,
          );
          expect(
            await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(big, longEdge: null),
            isNull,
          );
        });
      });

  });

  group('dng_embedded_jpeg_extractor_sony_ifd_chain_test.dart', () {
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
                width: 2900,
                height: 1936,
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
            expect(full!.width, 2900);
            expect(full.height, 1936);
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
                width: 2900,
                height: 1936,
              ),
            );
            final path = await write(bytes, 'both_candidates.arw');

            final full = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
              path,
              longEdge: null,
            );
            expect(full, isNotNull);
            expect(full!.width, 2900);
            expect(full.height, 1936);

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
                width: 2900,
                height: 1936,
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

        test(
          'TC-717e: a short read of the IFD2 full-res strip is retried rather '
          'than reported as an unreadable container (the ARW branch of TC-717)',
          () async {
            // The user's folder is Sony ARW, not DNG
            // (docs/logs/2026-09-02/repro-experiment.md §1), so the transient-read
            // fix has to be exercised on THIS branch -- the nextIFD chain walk plus
            // JPEGInterchangeFormat -- not only on the Adobe SubIFD/strip layout
            // the shared synthetic generator models. The candidate size was
            // originally h2's real-file measurement (7008x4672); shrunk to
            // 2900x1936 for the 2026-09-06 test-speedup campaign (root cause:
            // _syntheticJpeg does a real per-pixel fill + JPEG encode at whatever
            // size is requested, and 7008x4672 = ~32.7MP was needlessly full-res
            // for a structural IFD-chain test) -- 2900 still clears the 2800
            // minLongEdge floor with the same comfortable margin the original
            // value did, so the threshold-effect guarantee below is unchanged.
            final bytes = _buildSonyChain(
              ifd2Candidate: const _InterchangeCandidate(width: 2900, height: 1936),
            );
            final path = await write(bytes, 'ifd2_short_read.arw');

            final run = await withInjectedReadFaults(
              failFirstOpens: 1,
              shape: ReadFaultShape.short,
              body: () => DngEmbeddedJpegExtractor.probeEmbeddedJpeg(
                path,
                longEdge: null,
                // The production preview floor, passed unchanged: 2900 clears it
                // comfortably, so this case cannot be mistaken for a threshold
                // effect (AD-033 untouched).
                minLongEdge: 2800,
              ),
            );

            expect(
              run.value.jpeg,
              isNotNull,
              reason: 'a short read of the interchange strip is an I/O fault, not '
                  'evidence that the ARW has no usable preview',
            );
            expect(run.value.jpeg!.width, 2900);
            expect(run.value.malformed, isFalse);
            expect(run.opens, greaterThan(1), reason: 'the retry must re-open');
          },
        );
      });

  });

  group('dng_embedded_jpeg_extractor_long_edge_selection_test.dart', () {
      final sampleDir = sampleDngDir;

      // Kept in lockstep with the frozen oracle's `withPreview` list (read, not
      // retyped from memory) — test/dng_embedded_jpeg_extractor_test.dart lines 39-53.
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

      const noPreviewFile = 'IMG_20251112_092839.dng';
      const noPreviewFileDiskBytes = 25192232;

      test('AC2: smallest candidate >= longEdge 200 is the 256x171 preview', () async {
        final path = '${sampleDir.path}/2026-02-15-19-37-38.dng';
        expect(File(path).existsSync(), isTrue, reason: 'missing $path');

        final result = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
          path,
          longEdge: 200,
        );

        expect(result, isNotNull);
        expect(result!.width, 256);
        expect(result.height, 171);
        expect(result.bytes.length, 9525);
        expect(result.orientation, 1);
      }, skip: samplePhotosSkipReason);

      group('AC3: longEdge 2800 is byte-identical to today\'s full-size extraction', () {
        for (final name in withPreview) {
          test(name, () async {
            final path = '${sampleDir.path}/$name';
            expect(File(path).existsSync(), isTrue, reason: 'missing $path');

            final selected = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
              path,
              longEdge: 2800,
            );
            expect(selected, isNotNull, reason: '$name expected a candidate at longEdge 2800');

            final fullSize = await DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpegFromFile(
              path,
            );
            expect(fullSize, isNotNull, reason: '$name expected a full-size embedded preview');

            expect(
              selected!.bytes.length,
              fullSize!.length,
              reason: '$name: longEdge=2800 selection length differs from full-size length',
            );
            expect(
              listEquals(selected.bytes, fullSize),
              isTrue,
              reason: '$name: longEdge=2800 selection is not byte-identical to full-size '
                  '(element-wise comparison)',
            );
          });
        }
      }, skip: samplePhotosSkipReason);

      test(
        'AC4: byte-range read budget stays bounded across every .dng sample',
        () async {
          final dngFiles = sampleDir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.toLowerCase().endsWith('.dng'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));

          expect(
            dngFiles.length,
            26,
            reason:
                'expected exactly 26 .dng files in ${sampleDir.path}; a sample '
                'vanishing/appearing must fail loudly',
          );

          for (final file in dngFiles) {
            var totalOnDiskRead = 0;
            final result = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
              file.path,
              longEdge: 200,
              onDiskRead: (byteCount) => totalOnDiskRead += byteCount,
            );

            final selectedCandidateByteCount = result?.bytes.length ?? 0;

            expect(
              totalOnDiskRead,
              lessThanOrEqualTo(selectedCandidateByteCount + 300000),
              reason:
                  '${file.path}: on-disk read budget exceeded (read=$totalOnDiskRead, '
                  'candidate=$selectedCandidateByteCount)',
            );

            if (file.path.endsWith(noPreviewFile)) {
              expect(
                File(file.path).lengthSync(),
                noPreviewFileDiskBytes,
                reason: 'ground-truth on-disk size for $noPreviewFile has changed',
              );
              expect(
                result,
                isNull,
                reason: '$noPreviewFile has no qualifying candidate and must return null',
              );
              expect(
                totalOnDiskRead,
                lessThan(300000),
                reason:
                    '$noPreviewFile: with no candidate, total on-disk read must stay '
                    'under 300000 bytes (got $totalOnDiskRead), not scan the whole '
                    '25MB file',
              );
            }
          }
        },
        skip: samplePhotosSkipReason,
      );

      test(
        'AC5: sole 6000x4000 candidate is selected, orientation 6, APP1 injected',
        () async {
          final path = '${sampleDir.path}/2026-08-07-17-52-54.dng';
          expect(File(path).existsSync(), isTrue, reason: 'missing $path');

          final result = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
            path,
            longEdge: 200,
          );

          expect(result, isNotNull);
          expect(result!.width, 6000);
          expect(result.height, 4000);
          expect(result.orientation, 6);
          expect(result.bytes.length, greaterThan(4));
          expect(
            result.bytes[2],
            0xFF,
            reason: 'expected injected APP1 segment marker byte 0 at offset 2',
          );
          expect(
            result.bytes[3],
            0xE1,
            reason: 'expected injected APP1 segment marker byte 1 at offset 3',
          );
        },
        skip: samplePhotosSkipReason,
      );

      group('AC6: no-candidate/missing/non-DNG inputs return null, never throw', () {
        test('DNG with no qualifying candidate returns null', () async {
          final path = '${sampleDir.path}/$noPreviewFile';
          expect(File(path).existsSync(), isTrue, reason: 'missing $path');

          final result = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
            path,
            longEdge: 200,
          );
          expect(result, isNull);
        }, skip: samplePhotosSkipReason);

        test('nonexistent path returns null', () async {
          final result = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
            '${sampleDir.path}/does_not_exist.dng',
            longEdge: 200,
          );
          expect(result, isNull);
        });

        test('plain-JPEG file (not a DNG/TIFF container) returns null', () async {
          final tempFile = await File(
            '${Directory.systemTemp.path}/dng_embedded_jpeg_extractor_m0_plain_jpeg.jpg',
          ).create(recursive: true);
          await tempFile.writeAsBytes(
            Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0xFF, 0xD9]),
          );
          addTearDown(() async {
            if (await tempFile.exists()) {
              await tempFile.delete();
            }
          });

          final result = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
            tempFile.path,
            longEdge: 200,
          );
          expect(result, isNull);
        });
      });

      test(
        'AC11a: readOrientation reads IFD0 tag 0x0112 via the bounded walk (discriminating case)',
        () async {
          final path = '${sampleDir.path}/2026-08-07-17-52-54.dng';
          expect(File(path).existsSync(), isTrue, reason: 'missing $path');

          final orientation = await DngEmbeddedJpegExtractor.readOrientation(path);
          expect(orientation, 6);
        },
        skip: samplePhotosSkipReason,
      );

      test(
        'AC11b: readOrientation on a no-preview DNG stays under the disk-read budget',
        () async {
          final path = '${sampleDir.path}/$noPreviewFile';
          expect(File(path).existsSync(), isTrue, reason: 'missing $path');
          expect(
            File(path).lengthSync(),
            noPreviewFileDiskBytes,
            reason: 'ground-truth on-disk size for $noPreviewFile has changed',
          );

          var totalOnDiskRead = 0;
          final orientation = await DngEmbeddedJpegExtractor.readOrientation(
            path,
            onDiskRead: (byteCount) => totalOnDiskRead += byteCount,
          );

          expect(orientation, 1);
          expect(
            totalOnDiskRead,
            lessThan(300000),
            reason:
                '$noPreviewFile: readOrientation must not scan the whole 25MB file '
                '(got $totalOnDiskRead)',
          );
        },
        skip: samplePhotosSkipReason,
      );

      // AC11c is REPLACED by AC12a (a nonexistent path now returns null, not 1)
      // per the AC12 contract amendment: readOrientation's return value split
      // "1" (tag absent) from "null" (unparseable/missing), because a single
      // "1" could not distinguish a working implementation from one that gives
      // up on files it cannot read.

      test('AC12a: readOrientation on a nonexistent path returns null, never throws', () async {
        final orientation = await DngEmbeddedJpegExtractor.readOrientation(
          '${sampleDir.path}/does_not_exist.dng',
        );
        expect(orientation, isNull);
      });

      test('AC12b: a file that parses but carries no 0x0112 tag returns 1', () async {
        // Minimal, hand-crafted little-endian TIFF: valid header + an IFD0 with
        // one SHORT entry (tag 0x0100 ImageWidth, deliberately NOT 0x0112) and no
        // next IFD. This must genuinely parse -- if it returned null because it
        // were malformed rather than 1 because the tag is absent, this test
        // would prove nothing.
        final bytes = BytesBuilder()
          ..add([0x49, 0x49]) // 'II' byte-order marker (little-endian)
          ..add([0x2A, 0x00]) // TIFF magic 42
          ..add([0x08, 0x00, 0x00, 0x00]) // IFD0 offset = 8
          ..add([0x01, 0x00]) // IFD0 entry count = 1
          ..add([0x00, 0x01]) // tag 0x0100 (ImageWidth), not 0x0112
          ..add([0x03, 0x00]) // type = 3 (SHORT)
          ..add([0x01, 0x00, 0x00, 0x00]) // count = 1
          ..add([0x64, 0x00, 0x00, 0x00]) // value = 100, left-justified in the 4-byte field
          ..add([0x00, 0x00, 0x00, 0x00]); // next IFD offset = 0 (no more IFDs)

        final tempFile = await File(
          '${Directory.systemTemp.path}/dng_embedded_jpeg_extractor_m0_ac12b_no_orientation_tag.tiff',
        ).create(recursive: true);
        await tempFile.writeAsBytes(bytes.toBytes());
        addTearDown(() async {
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
        });

        final orientation = await DngEmbeddedJpegExtractor.readOrientation(tempFile.path);
        expect(orientation, 1);
      });

      test('AC12c: non-TIFF/garbage input returns null, never throws', () async {
        final plainJpeg = await File(
          '${Directory.systemTemp.path}/dng_embedded_jpeg_extractor_m0_ac12c_plain_jpeg.jpg',
        ).create(recursive: true);
        await plainJpeg.writeAsBytes(
          Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0xFF, 0xD9]),
        );
        addTearDown(() async {
          if (await plainJpeg.exists()) {
            await plainJpeg.delete();
          }
        });

        final zeroByteFile = await File(
          '${Directory.systemTemp.path}/dng_embedded_jpeg_extractor_m0_ac12c_zero_byte.dng',
        ).create(recursive: true);
        await zeroByteFile.writeAsBytes(Uint8List(0));
        addTearDown(() async {
          if (await zeroByteFile.exists()) {
            await zeroByteFile.delete();
          }
        });

        expect(await DngEmbeddedJpegExtractor.readOrientation(plainJpeg.path), isNull);
        expect(await DngEmbeddedJpegExtractor.readOrientation(zeroByteFile.path), isNull);
      });

      test(
        'AC12h: 0x0112 tag PRESENT but unreadable -> readOrientation null, '
        'readDngOrientation 1 (distinct from AC12b\'s tag-ABSENT case)',
        () async {
          // Unlike AC12b (no 0x0112 entry at all), this file DOES have a 0x0112
          // entry, but its value cannot be resolved: type SHORT, count 3 (6
          // bytes, so the value does not fit inline and must live at an external
          // offset), and that offset points past EOF. "Found it, could not read
          // it" must be null, not the tag-absent value 1.
          final bytes = BytesBuilder()
            ..add([0x49, 0x49]) // 'II' byte-order marker (little-endian)
            ..add([0x2A, 0x00]) // TIFF magic 42
            ..add([0x08, 0x00, 0x00, 0x00]) // IFD0 offset = 8
            ..add([0x01, 0x00]) // IFD0 entry count = 1
            ..add([0x12, 0x01]) // tag 0x0112 (Orientation)
            ..add([0x03, 0x00]) // type = 3 (SHORT)
            ..add([0x03, 0x00, 0x00, 0x00]) // count = 3 (6 bytes -> needs an offset)
            ..add([0xF0, 0xFF, 0xFF, 0xFF]) // value offset = 0xFFFFFFF0, far past EOF
            ..add([0x00, 0x00, 0x00, 0x00]); // next IFD offset = 0 (no more IFDs)
          final fileBytes = bytes.toBytes();

          final tempFile = await File(
            '${Directory.systemTemp.path}/dng_embedded_jpeg_extractor_m0_ac12h_unreadable_tag.tiff',
          ).create(recursive: true);
          await tempFile.writeAsBytes(fileBytes);
          addTearDown(() async {
            if (await tempFile.exists()) {
              await tempFile.delete();
            }
          });

          final pathResult = await DngEmbeddedJpegExtractor.readOrientation(tempFile.path);
          final bytesResult = await DngEmbeddedJpegExtractor.readDngOrientation(
            fileBytes,
          );

          expect(pathResult, isNull, reason: 'unreadable-but-present tag must be null, not 1');
          expect(
            bytesResult,
            1,
            reason: 'legacy readDngOrientation must still degrade to 1 (?? 1 unchanged)',
          );
        },
      );

      test(
        'AC12d: N1 fixture — large file with a patched non-default orientation tag',
        () async {
          final sourcePath = '${sampleDir.path}/$noPreviewFile';
          expect(File(sourcePath).existsSync(), isTrue, reason: 'missing $sourcePath');

          final tempPath =
              '${Directory.systemTemp.path}/dng_embedded_jpeg_extractor_m0_ac12d_n1_fixture.dng';
          final tempFile = File(tempPath);
          addTearDown(() async {
            if (await tempFile.exists()) {
              await tempFile.delete();
            }
          });

          await _patchOrientationTag(sourcePath, tempPath, 6);
          expect(
            await tempFile.length(),
            noPreviewFileDiskBytes,
            reason: 'in-place tag patch must not change the file size',
          );

          var totalOnDiskRead = 0;
          final orientation = await DngEmbeddedJpegExtractor.readOrientation(
            tempPath,
            onDiskRead: (byteCount) => totalOnDiskRead += byteCount,
          );

          expect(orientation, 6);
          expect(
            totalOnDiskRead,
            lessThan(300000),
            reason:
                'N1 fixture: readOrientation must not scan the whole 25MB file '
                '(got $totalOnDiskRead)',
          );
        },
        skip: samplePhotosSkipReason,
      );

  });

  group('dng_extractor_transient_read_retry_test.dart', () {
      TestWidgetsFlutterBinding.ensureInitialized();

      late Directory dir;

      setUp(() async {
        dir = await Directory.systemTemp.createTemp('tc540_');
      });

      tearDown(() async {
        if (dir.existsSync()) await dir.delete(recursive: true);
      });

      // A container that DOES carry a preview clearing the frozen 2800 floor:
      // without an injected fault every assertion below must find it.
      Future<String> writePreviewBearingDng() async => writeSyntheticDng(
        buildSyntheticDng(
          candidates: const [SyntheticCandidate(width: 3200, height: 2133)],
        ),
        dir: dir,
        name: 'preview_bearing.dng',
      );

      Future<FaultRun<DngEmbeddedJpegProbe>> probeWithFaults(
        String path, {
        required int failFirstOpens,
        required ReadFaultShape shape,
      }) => withInjectedReadFaults(
        failFirstOpens: failFirstOpens,
        shape: shape,
        body: () => DngEmbeddedJpegExtractor.probeEmbeddedJpeg(
          path,
          longEdge: null,
          minLongEdge: 2800,
        ),
      );

      test('control: an intact container yields its preview in exactly one open',
          () async {
        final run = await probeWithFaults(
          await writePreviewBearingDng(),
          failFirstOpens: 0,
          shape: ReadFaultShape.thrown,
        );
        expect(run.value.jpeg, isNotNull, reason: 'fixture must carry a preview');
        expect(run.opens, 1, reason: 'the happy path must stay a single open');
      });

      test('TC-717a: a THROWN read error is retried, not reported as "no preview"',
          () async {
        final run = await probeWithFaults(
          await writePreviewBearingDng(),
          failFirstOpens: 1,
          shape: ReadFaultShape.thrown,
        );
        expect(
          run.value.jpeg,
          isNotNull,
          reason: 'a transient read error must be retried, not reported as "this '
              'container has no embedded preview"',
        );
        expect(run.value.jpeg!.width, 3200);
        expect(run.opens, greaterThan(1), reason: 'the retry must re-open the file');
      });

      test('TC-717d: a SHORT read (no exception) on the preview strip is retried',
          () async {
        // The exact shape h2 measured on the user's volume: the multi-MB strip
        // comes back short, nothing throws, and the walker calls the container's
        // previews unreadable.
        final run = await probeWithFaults(
          await writePreviewBearingDng(),
          failFirstOpens: 1,
          shape: ReadFaultShape.short,
        );
        expect(
          run.value.jpeg,
          isNotNull,
          reason: 'a short read is an I/O fault, not evidence that the declared '
              'preview is unreadable',
        );
        expect(
          run.value.malformed,
          isFalse,
          reason: 'the container is intact; only the read failed',
        );
        expect(run.opens, greaterThan(1));
      });

      test('TC-717b: probeContent measurement survives a transient read failure',
          () async {
        // probeContent feeds PrefetchScheduler.classify, i.e. the cheap-vs-RAW
        // verdict memoised first-writer-wins for the whole folder. A candidate
        // whose strip read faults is skipped by the gather, which silently SHRINKS
        // this measurement — the second way a hiccup becomes a session-long RAW
        // fallback.
        final path = await writePreviewBearingDng();
        final run = await withInjectedReadFaults(
          failFirstOpens: 1,
          shape: ReadFaultShape.short,
          body: () => DngEmbeddedJpegExtractor.probeContent(path),
        );
        expect(run.value, isNotNull, reason: 'must not report "unmeasurable"');
        expect(
          run.value!.largestLongEdge,
          3200,
          reason: 'a shrunken measurement is what flips the item to the expensive '
              '(RAW decode) lane for the rest of the session',
        );
      });

      test('TC-717c: a genuinely preview-less container is NOT retried', () async {
        // The negative half. AD-033 is untouched: a 320px preview stays rejected
        // against the frozen 2800 floor, and that rejection is FINAL rather than
        // retried three times.
        final path = await writeSyntheticDng(
          buildSyntheticDng(
            candidates: const [SyntheticCandidate(width: 320, height: 213)],
          ),
          dir: dir,
          name: 'undersized.dng',
        );
        final run = await probeWithFaults(
          path,
          failFirstOpens: 0,
          shape: ReadFaultShape.thrown,
        );
        expect(run.value.jpeg, isNull);
        expect(run.opens, 1, reason: 'no I/O fault occurred, so nothing to retry');
      });

  });

  group('dng_embedded_jpeg_extractor_buffer_copy_semantics_test.dart', () {
      final sampleDir = sampleDngDir;

      // Orientation 1 (per dng_embedded_jpeg_extractor_long_edge_selection_test.dart AC2), so the
      // returned bytes are exactly the `_MemorySource.read` slice with no
      // `_injectExifOrientation` rebuild in the way.
      const sampleName = '2026-02-15-19-37-38.dng';

      test(
        'AC-B1: extractFullSizeEmbeddedJpeg result is unaffected by mutating '
        'the source buffer after the call',
        () async {
          final path = '${sampleDir.path}/$sampleName';
          expect(File(path).existsSync(), isTrue, reason: 'missing $path');

          final original = await File(path).readAsBytes();
          // Mutable copy: File.readAsBytes may already return a fresh buffer,
          // but we need one we are free to mutate in place regardless.
          final data = Uint8List.fromList(original);

          final result = await DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpeg(
            data,
          );
          expect(result, isNotNull, reason: '$sampleName expected a full-size embedded preview');

          // Snapshot the expected content BEFORE mutating the source.
          final expectedBytes = Uint8List.fromList(result!);

          // Mutate the entire source buffer in place.
          data.fillRange(0, data.length, 0xAA);

          expect(
            result.length,
            expectedBytes.length,
            reason: 'result length must not change after source mutation',
          );
          expect(
            result,
            expectedBytes,
            reason:
                'returned bytes changed after the source buffer was mutated -- '
                'the extractor is returning a VIEW into the caller\'s buffer '
                'instead of an independent copy',
          );
        },
        skip: samplePhotosSkipReason,
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

// Perf note (test-speedup campaign, 2026-09-06): the three "real pixel data"
// corruption modes below (none/offsetPastEof/countPastEof) only differ in the
// IFD offset/count metadata written elsewhere in buildSyntheticPanasonic --
// the encoded JPEG payload bytes for a given (width, height) are identical no
// matter which of those three modes is requested, and no test in this file
// asserts on specific pixel values (only decoded width/height and marker
// bytes). Caching the encode by (width, height) avoids re-running the
// per-pixel fill + img.encodeJpg for every test that happens to reuse a
// common size (3000x2000 / 640x480 recur across ~a dozen cases in the
// "Panasonic container" group).
final Map<String, Uint8List> _panasonicPayloadCache = {};

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
      final key = '${blob.width}x${blob.height}';
      final cached = _panasonicPayloadCache[key];
      if (cached != null) return cached;
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
      final encoded = img.encodeJpg(image, quality: 85);
      _panasonicPayloadCache[key] = encoded;
      return encoded;
  }
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

// Perf note (test-speedup campaign, 2026-09-06): several tests reuse the
// same (width, height) pair (e.g. 2900x1936 for the IFD2 full-res candidate).
// No test in this file asserts on specific pixel values -- only decoded
// width/height and marker bytes -- so caching the encode by size avoids
// redundant per-pixel fill + JPEG encode work across cases.
final Map<String, Uint8List> _syntheticJpegCache = {};

Uint8List _syntheticJpeg(int width, int height) {
  final key = '${width}x$height';
  final cached = _syntheticJpegCache[key];
  if (cached != null) return cached;
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(x, y, (x * 7) & 0xFF, (y * 11) & 0xFF, (x + y) & 0xFF);
    }
  }
  final encoded = img.encodeJpg(image, quality: 85);
  _syntheticJpegCache[key] = encoded;
  return encoded;
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

/// Patches an on-disk copy of [sourcePath] (written to [destPath]) so IFD0's
/// orientation tag 0x0112 reads [value].
///
/// `IMG_20251112_092839.dng` already carries an explicit 0x0112 SHORT/count-1
/// entry with value 1 (verified by direct inspection: it is not that the tag
/// is absent, it is present and declares "no rotation"). This overwrites that
/// existing entry's inline value only -- it does not touch the tag id, type,
/// count, or any other byte in the file. An earlier version of this helper
/// hijacked a *different* SHORT/count-1 entry to fabricate a second 0x0112
/// tag, which produced two orientation entries in one IFD0 and made the
/// result implementation-defined (observed: the reader returned the
/// original's value, not the fabricated one). Patching the sole existing
/// entry avoids that ambiguity entirely, and keeps every other absolute
/// offset in the DNG (raw image strips, SubIFDs, thumbnail IFDs, etc.)
/// untouched.
Future<void> _patchOrientationTag(String sourcePath, String destPath, int value) async {
  final bytes = Uint8List.fromList(await File(sourcePath).readAsBytes());
  final data = ByteData.sublistView(bytes);
  final byteOrder = String.fromCharCodes(bytes.sublist(0, 2));
  final endian = byteOrder == 'II' ? Endian.little : Endian.big;

  final ifd0Offset = data.getUint32(4, endian);
  final entryCount = data.getUint16(ifd0Offset, endian);

  int? targetEntryOffset;
  for (var i = 0; i < entryCount; i++) {
    final entryOffset = ifd0Offset + 2 + i * 12;
    final tag = data.getUint16(entryOffset, endian);
    final type = data.getUint16(entryOffset + 2, endian);
    final count = data.getUint32(entryOffset + 4, endian);
    if (tag == 0x0112 && type == 3 && count == 1) {
      targetEntryOffset = entryOffset;
      break;
    }
  }

  if (targetEntryOffset == null) {
    throw StateError(
      'no existing SHORT/count==1 IFD0 orientation (0x0112) entry found in '
      '$sourcePath to patch for the N1 fixture',
    );
  }

  data.setUint16(targetEntryOffset, 0x0112, endian);
  data.setUint16(targetEntryOffset + 8, value, endian);
  data.setUint16(targetEntryOffset + 10, 0, endian);

  await File(destPath).writeAsBytes(bytes);
}
