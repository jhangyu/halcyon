import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import '../../support/temp_dirs.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_embedded_jpeg_extractor.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_source.dart';
import '../../support/preload_fixtures.dart';
import '../../support/sample_photos.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_reencoder.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'dart:async';
import 'package:halcyon_flutter/services/image_pipeline/payload_normalizer.dart';
import 'package:halcyon_flutter/perf/perf_log.dart';

// --- top-level helpers from photo_source_test.dart ---
/// M2: source-selection was moved from an inline check in
/// `image_preload_controller.dart` into `photo_source.dart`, behind the
/// existing `ImageBytesLoader` seam. Most of these tests deliberately do NOT
/// import `photo_source.dart` or assert on its internals (design-doc
/// round-1 handoff warning: an observer that moves with the behavior is a
/// false green); they drive the CONTROLLER through the same public
/// API/fakes the pre-existing suite uses, and assert on what the controller
/// hands back — i.e. they observe from outside the seam. M6 P2.2 (F-08)
/// adds one direct `PhotoSource.fallbackAfterNativeFailure` case, matching
/// the sibling probe test files (photo_source_probe_test.dart et al.) that
/// already import photo_source.dart directly for a static method's own
/// contract rather than its wiring.
///
/// Real samples only, per repo convention (see dng_embedded_jpeg_extractor_test.dart):
/// local_data/photo_samples/DNG/.
/// An opaque (alpha 0xFF) RGBA8 fixture of [pixelCount] pixels: the
/// identity-transform short-circuit in decoded_rgba_image_provider.dart
/// asserts every RAW decode is opaque, so a zero-filled buffer would trip it.
Uint8List _opaqueRgba(int pixelCount) {
  final bytes = Uint8List(pixelCount * 4);
  for (var p = 0; p < pixelCount; p++) {
    bytes[p * 4 + 3] = 0xFF;
  }
  return bytes;
}

// --- top-level helpers from photo_source_two_phase_test.dart ---
NativeImageLoad _loaderReturning(NativeImageResult result) =>
    (path, {required purpose, targetLongEdge}) async => result;

Future<DecodedRgba> _decoderTwoPhase(String path) async {
  final bytes = Uint8List(8 * 6 * 4);
  for (var p = 0; p < 8 * 6; p++) {
    bytes[p * 4 + 3] = 255;
  }
  return DecodedRgba(rgba: bytes, width: 8, height: 6);
}

Future<DecodedRgba> _throwingDecoderTwoPhase(String path) async =>
    throw StateError('boom');

Future<Uint8List> _encoderTwoPhase(
  Uint8List rgba, {
  required int width,
  required int height,
  required int quality,
}) async => Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);

Future<Uint8List> _throwingEncoder(
  Uint8List rgba, {
  required int width,
  required int height,
  required int quality,
}) async => throw StateError('encode failed');

/// Compares every field the pipeline reads, `fullRes` by presence only (the
/// two runs decode separately, so their buffers are different objects).
void expectSameOutcome(SourceOutcome split, SourceOutcome oneShot) {
  expect(split.payload.runtimeType, oneShot.payload.runtimeType);
  expect(split.observedCost, oneShot.observedCost);
  expect(split.deferred, oneShot.deferred);
  expect(split.exifOrientation, oneShot.exifOrientation);
  expect(split.failureCode, oneShot.failureCode);
  expect(split.fullRes == null, oneShot.fullRes == null);
  if (split.payload is EncodedPayload) {
    expect(
      (split.payload! as EncodedPayload).bytes,
      orderedEquals((oneShot.payload! as EncodedPayload).bytes),
    );
  }
}

// --- top-level helpers from photo_source_probe_test.dart ---
// Real samples only, per repo red line: local_data/photo_samples/.
// The whole point of the probe is that it reads CONTENT, so a synthetic
// fixture would only test the parser, not the claim.

// --- top-level helpers from photo_source_single_probe_test.dart ---
// The user's single-probe ruling, made mechanical.
//
// The rejected seam asked one question per call: probe() for the rung, then
// probeOrientation() for the orientation. Two opens, two header+IFD0 walks,
// and -- worse -- a debounced RAW decode that went back to the native bridge
// for a value the first walk already had in its hand. These tests pin the
// three properties that make a re-split fail here rather than in review:
//
//   TC-090  ONE file open per probe, counted
//   TC-091  the fused orientation equals the dedicated reader's answer
//   TC-092  AC14's <=300 KB budget measured over the COMBINED probe
//   TC-093  an expensive item reaches its RAW decode with ZERO loader calls
//
// Real samples only (repo red line, local_data/photo_samples/): the probe's
// whole claim is about content, so a synthetic fixture would only exercise the
// parser.




/// Counts `open()` calls on files created inside an [IOOverrides] zone.
///
/// Only `open()` is implemented: every other member throws, which is the
/// point. If the probe ever reaches for the filesystem another way, this test
/// fails loudly instead of quietly under-counting.
class _CountingFile implements File {
  _CountingFile(this._inner, this._onOpen);

  final File _inner;
  final void Function() _onOpen;

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) {
    _onOpen();
    return _inner.open(mode: mode);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Runs [body] with every `File(...)` construction counted.
Future<int> countingOpens(Future<void> Function() body) async {
  var opens = 0;
  await IOOverrides.runZoned(
    body,
    // Zone.root escapes this very override, so the wrapped File is a real one
    // rather than an infinite regress through the factory.
    createFile: (path) =>
        _CountingFile(Zone.root.run(() => File(path)), () => opens++),
  );
  return opens;
}

// --- top-level helpers from photo_source_composite_gate_test.dart ---
// Deliverable 2, plumbing half: the gate injected at the composition root
// actually reaches every compositing call on the decode-completion path.
// TC-902 / TC-903.



/// Counts slot requests and opens them immediately, so a test can assert
/// "the gate was consulted" without also having to drive completion order.
class CountingGate {
  int requests = 0;
  Future<void> call() {
    requests++;
    return Future<void>.value();
  }
}

/// 2x2, orientation 6 (a real GPU pass), OPAQUE.
DecodedRgba _decodedCompositeGate() {
  final bytes = Uint8List(2 * 2 * 4);
  for (var p = 0; p < 4; p++) {
    bytes[p * 4] = 10 + p * 20;
    bytes[p * 4 + 3] = 0xFF;
  }
  return DecodedRgba(rgba: bytes, width: 2, height: 2);
}

// --- top-level helpers from photo_source_fullres_handle_test.dart ---
Future<NativeImageResult> _needsRawDecodeFullres(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

Future<NativeImageResult> _needsRawDecodeRotated(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => const NativeImageNeedsRawDecode(exifOrientation: 6);

/// 8x6 opaque RGBA so the premultiplied/straight equivalence holds.
DecodedRgba _decodedFullres() {
  final bytes = Uint8List(8 * 6 * 4);
  for (var p = 0; p < 8 * 6; p++) {
    bytes[p * 4] = p % 256;
    bytes[p * 4 + 3] = 255;
  }
  return DecodedRgba(rgba: bytes, width: 8, height: 6);
}

late DecodedRgba lastDecoded;
Future<DecodedRgba> _decoderFullres(String path) async {
  lastDecoded = _decodedFullres();
  return lastDecoded;
}

Future<DecodedRgba> _throwingDecoderFullres(String path) async =>
    throw StateError('decode failed');

Future<Uint8List> _encoderFullres(
  Uint8List rgba, {
  required int width,
  required int height,
  required int quality,
}) async => Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);

// --- top-level helpers from photo_source_reencode_test.dart ---
Future<T> withStubDecoder<T>(
  EncodedRgbaDecoder stub,
  Future<T> Function() body,
) async {
  final previous = debugEncodedRgbaDecoderOverride;
  debugEncodedRgbaDecoderOverride = stub;
  try {
    return await body();
  } finally {
    debugEncodedRgbaDecoderOverride = previous;
  }
}

Future<NativeImageResult> _needsRawDecodeReencode(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

/// Opaque (alpha 0xFF): the identity-transform short-circuit in
/// decoded_rgba_image_provider.dart asserts every RAW decode is opaque, so a
/// zero-filled buffer would trip it.
Uint8List _opaqueRgbaReencode(int pixelCount) {
  final bytes = Uint8List(pixelCount * 4);
  for (var p = 0; p < pixelCount; p++) {
    bytes[p * 4 + 3] = 0xFF;
  }
  return bytes;
}

Future<DecodedRgba> _fakeDecoder(String path) async =>
    DecodedRgba(rgba: _opaqueRgbaReencode(64 * 48), width: 64, height: 48);

Future<Uint8List> _fakeEncoder(
  Uint8List rgba, {
  required int width,
  required int height,
  required int quality,
}) async => Uint8List.fromList([0xFF, 0xD8, width & 0xFF, height & 0xFF]);

// --- top-level helpers from photo_source_single_materialize_test.dart ---
/// T2 (docs/logs/2026-09-06/h1h2-plan.md, spec §1.6/§3 AC-H1-2): independent
/// red->green proof that [PhotoSource.decodePhase] /
/// [PhotoSource.decodePhaseExpensive] materialize the decoded RGBA buffer
/// into a `ui.Image` EXACTLY ONCE per decode, for a non-identity EXIF
/// orientation (orientation 6 forces the GPU pass -- see
/// p0_perf_instrumentation_test.dart's `_needsRawDecodeRotated` convention).
///
/// Observation seam: `PerfLog.testSink` (lib/perf/perf_log.dart:245),
/// deliberately NOT `debugPrint` capture (lessons-learned 2026-08-17:
/// debugPrint is process-wide and order-dependent across the suite).
/// `testSink` fires BEFORE the `PerfLog.enabled` gate, so no file I/O or
/// `PerfLog.init` is needed to observe emitted lines.
///
/// TC-1001 (grepped for collision against the whole tree, incl. untracked,
/// at paste time -- highest prior in docs/sop/unit_test.md was TC-997).
///
/// PRE-REGISTRATION / expected RED (before T1 landed): the pre-change
/// `decodePhase`/`decodePhaseExpensive` body called BOTH
/// `decodedRgbaToOrientedFullRes` AND `decodedRgbaToPixelPayload` on the same
/// `decoded` buffer for a non-identity orientation -- two separate
/// `_imageFromPixels` calls, hence two `materialize|` events with two
/// DIFFERENT `id=` values (id = `identityHashCode(decoded.rgba)`, which is
/// stable across both calls since it is the SAME buffer -- so the red
/// signature is "two events, same id", not "two different ids"). The fixed
/// shape derives the window payload from the already-materialized oriented
/// image via `pixelPayloadFromOrientedImage`, which performs zero additional
/// `_imageFromPixels` calls -- so exactly one `materialize|` event should
/// appear post-fix.
///
/// TIMELINE NOTE: T1 landed mid-round, in this shared tree, before this
/// file's tests could be run against a genuinely pre-T1 state -- both
/// twinned call sites (`decodePhase` and `decodePhaseExpensive`) were
/// already committed (commit `c10e9c5`) by the time this test harness was
/// correctly wired (an earlier harness bug -- `PerfLog.testSink` alone does
/// not bypass the emit sites' own `if (PerfLog.enabled)` guard -- produced a
/// false "0 events" reading first; fixed by also setting
/// `PerfLog.enabled = true`, still with no `PerfLog.init()` call so no file
/// I/O is introduced). Both tests are GREEN against this tree from the
/// first correctly-wired run.
///
/// Per "do not fabricate red evidence": RED was NOT invented by mutating
/// this test. Instead, the actual pre-T1 commit (`0b08152`, T1's parent) was
/// materialized read-only via `git show 0b08152:<path>`, `cp`-swapped into
/// place (never `git checkout --`/`stash`/`reset`, per the shared-tree red
/// lines), the suite run, and the swap `cp`-restored from a backup
/// immediately after -- `git status --porcelain` confirmed a clean restore
/// (byte-identical `diff -q` against the pre-swap backup) before this file
/// was finalized. Both TC-1001 and TC-1001b went RED exactly as predicted:
/// two `materialize|` events sharing the same `id=` (the SAME
/// `decoded.rgba` buffer materialized twice). Full run, with the
/// prediction written above the output, filed at
/// `docs/logs/2026-09-06/t2-redproof-single-materialize.txt`.

void main() {
  group('photo_source_test.dart', () {
      TestWidgetsFlutterBinding.ensureInitialized();

      final sampleDir = sampleDngDir;
      const withPreviewSample = '2026-02-15-19-37-38.dng';
      const noPreviewSample = 'IMG_20251112_092839.dng';

      test('sample directory has both required fixtures', () {
        expect(
          File('${sampleDir.path}/$withPreviewSample').existsSync(),
          isTrue,
        );
        expect(File('${sampleDir.path}/$noPreviewSample').existsSync(), isTrue);
      }, skip: samplePhotosSkipReason);

      test(
        // Killer assertion: if delegation to PhotoSource is wired wrong (e.g.
        // the controller stops calling the fallback, or calls it but drops the
        // bytes), this is the assertion that goes red -- imageBytesFor would
        // stay null instead of holding the embedded JPEG.
        'a .dng that fails the native preview channel recovers the embedded '
        'JPEG through the controller, byte-identical to the extractor',
        () async {
          final path = '${sampleDir.path}/$withPreviewSample';
          final expectedBytes =
              await DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpegFromFile(path);
          expect(
            expectedBytes,
            isNotNull,
            reason: 'fixture must have an embedded preview for this test to '
                'discriminate anything',
          );

          final controller = ImagePreloadController(
            imageLoader: (requestedPath, {required purpose, int? targetLongEdge}) async {
              return const NativeImageFailure(
                'NULL_RESULT',
                'simulated native failure',
              );
            },
          );
          addTearDown(controller.dispose);

          final items = [PhotoItem(id: 'dng-1', files: [File(path)])];

          await controller.preloadImages(
            items: items,
            selectedItemId: 'dng-1',
            notifyLoaded: () {},
          );

          // PHASE 3 settle (settle-only instrument repair): preloadImages returns
          // once the window is issued, so the payload lands a few event-loop turns
          // later. Assertions unchanged.
          await until(
            () => controller.imageBytesFor('dng-1') != null,
            reason: 'the recovered payload to land',
          );
          final gotBytes = controller.imageBytesFor('dng-1');
          expect(gotBytes, isNotNull);
          expect(gotBytes, equals(expectedBytes));
          expect(controller.hasFailed('dng-1'), isFalse);
        },
        skip: samplePhotosSkipReason,
      );

      test(
        'a .dng with no embedded preview still falls through to hasFailed, '
        'not a crash, when the native preview channel fails',
        () async {
          final path = '${sampleDir.path}/$noPreviewSample';

          final controller = ImagePreloadController(
            imageLoader: (requestedPath, {required purpose, int? targetLongEdge}) async {
              return const NativeImageFailure(
                'NULL_RESULT',
                'simulated native failure',
              );
            },
          );
          addTearDown(controller.dispose);

          final items = [PhotoItem(id: 'dng-2', files: [File(path)])];

          await controller.preloadImages(
            items: items,
            selectedItemId: 'dng-2',
            notifyLoaded: () {},
          );

          // The OBSERVATION POINT moved, not the behaviour under test. Under the
          // user's probe-first ruling (Amendment 3 clause 2) the content probe
          // measures this no-preview .dng as expensive BEFORE any loader call, so
          // the immediate pass defers it -- frozen TC-088 requires exactly zero
          // loader calls for it at distance 0. The fall-through to hasFailed now
          // happens on the debounced pass instead of inline, so the assertions
          // below have to be read after that pass, not the instant preloadImages
          // returns. Both assertions and this test's intent are unchanged.
          //
          // A plain test() harness, so these are real timers -- awaiting a real
          // engine future under FakeAsync would hang forever.
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (!controller.hasFailed('dng-2')) {
            if (DateTime.now().isAfter(deadline)) {
              fail('timed out waiting for the debounced pass to mark dng-2');
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }

          expect(controller.imageBytesFor('dng-2'), isNull);
          expect(controller.hasFailed('dng-2'), isTrue);
        },
        skip: samplePhotosSkipReason,
      );

      // Rewritten under C-4: this pair used to assert the pre-M6 `.dng`-only
      // extension gate held through the seam; matrix ruling F-08 deliberately
      // reverses that (the walker keys on the TIFF magic, never the extension),
      // so the old single assertion is inverted into a mutation-killer for the
      // NEW behaviour, keeping the fixture idea that made it a killer assertion
      // in the first place.
      test(
        'a real DNG saved under a .jpg extension is recovered through the seam '
        'once the native preview channel fails (F-08: the walker keys on magic, '
        'not extension)',
        () async {
          // Killer assertion (inverted): a MUTANT that reinstates the `.dng`
          // extension gate in photo_source.dart would fail to recover this --
          // the fixture is a real DNG file's raw bytes (which do contain an
          // embedded JPEG preview), just saved under a `.jpg` extension. A
          // fixture pointing at a nonexistent path can't discriminate that: it
          // fails identically whether the gate holds or not.
          final srcPath = '${sampleDir.path}/$withPreviewSample';
          final dngBytes = await File(srcPath).readAsBytes();
          final expectedBytes =
              await DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpegFromFile(
            srcPath,
          );
          expect(expectedBytes, isNotNull);
          final tmpDir = await Directory.systemTemp.createTemp(
            'halcyon_photo_source_gate_',
          );
          addTempDirTeardown(tmpDir);
          final fakeJpgFile = File('${tmpDir.path}/not-a-dng.jpg');
          await fakeJpgFile.writeAsBytes(dngBytes);

          final controller = ImagePreloadController(
            imageLoader: (requestedPath, {required purpose, int? targetLongEdge}) async {
              return const NativeImageFailure(
                'NULL_RESULT',
                'simulated native failure',
              );
            },
          );
          addTearDown(controller.dispose);

          final items = [PhotoItem(id: 'jpg-1', files: [fakeJpgFile])];

          await controller.preloadImages(
            items: items,
            selectedItemId: 'jpg-1',
            notifyLoaded: () {},
          );

          // PHASE 3 settle (see above). Assertions unchanged.
          await until(
            () => controller.imageBytesFor('jpg-1') != null,
            reason: 'the recovered payload to land',
          );
          expect(controller.imageBytesFor('jpg-1'), equals(expectedBytes));
          expect(controller.hasFailed('jpg-1'), isFalse);
        },
        skip: samplePhotosSkipReason,
      );

      test(
        'non-TIFF garbage saved under a .jpg extension is still a permanent '
        'miss when the native preview channel fails (proves the magic check, '
        'not the extension, is what discriminates)',
        () async {
          final tmpDir = await Directory.systemTemp.createTemp(
            'halcyon_photo_source_gate_negative_',
          );
          addTempDirTeardown(tmpDir);
          final garbageJpgFile = File('${tmpDir.path}/not-an-image.jpg');
          await garbageJpgFile.writeAsBytes(
            List<int>.generate(64, (i) => i % 256),
          );

          final controller = ImagePreloadController(
            imageLoader: (requestedPath, {required purpose, int? targetLongEdge}) async {
              return const NativeImageFailure(
                'NULL_RESULT',
                'simulated native failure',
              );
            },
          );
          addTearDown(controller.dispose);

          final items = [PhotoItem(id: 'jpg-2', files: [garbageJpgFile])];

          await controller.preloadImages(
            items: items,
            selectedItemId: 'jpg-2',
            notifyLoaded: () {},
          );

          // PHASE 3 settle: the permanent-miss latch is now recorded after the
          // pass returns, so wait for the LATCH (not for a payload -- there never
          // is one here). Both assertions are unchanged, and the isNull one is
          // strictly harder to satisfy after this wait than before it.
          await until(
            () => controller.hasFailed('jpg-2'),
            reason: 'the permanent-miss latch to be recorded',
          );
          expect(controller.imageBytesFor('jpg-2'), isNull);
          expect(controller.hasFailed('jpg-2'), isTrue);
        },
      );

      test(
        'fallbackAfterNativeFailure recovers a non-DNG RAW with an embedded '
        'preview (extension gate removed)',
        () async {
          final dir = await Directory.systemTemp.createTemp('photo_source_f08');
          addTempDirTeardown(dir);
          final samples = sampleDir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.toLowerCase().endsWith('.dng'));
          File? withPreview;
          for (final f in samples) {
            if (await DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpegFromFile(
                  f.path,
                ) !=
                null) {
              withPreview = f;
              break;
            }
          }
          expect(withPreview, isNotNull);
          final asNef = File('${dir.path}/sample.nef');
          await withPreview!.copy(asNef.path);
          expect(await PhotoSource.fallbackAfterNativeFailure(asNef.path), isNotNull);
        },
        skip: samplePhotosSkipReason,
      );

      // -------------------------------------------------------------------
      // ACCEPTANCE #2 (user ruling 2026-08-26). The loader no longer pre-empts a
      // container whose declared previews are all unreadable — it routes it to the
      // decoder. AD-022's requirement that the two "no preview" end states stay
      // TELLABLE APART survives that override, and THIS is where it is proven:
      // at the point the failure surfaces, with the decode outcome known.
      //
      // Asserted on the surfaced failure CODES, not on the loader's flag. The flag
      // is the mechanism; two different codes reaching the caller is the
      // requirement. A test that only checked the flag would still pass if this
      // layer dropped it on the floor.
      //
      // Direct against PhotoSource.load with fakes, deliberately: driving a real
      // decode failure through the controller would need a genuinely broken
      // container AND a real decoder, and would prove less.
      // -------------------------------------------------------------------
      group('AD-022 after the pre-empt override: the two no-preview states stay '
          'distinguishable once the decode outcome is known', () {
        Future<String?> failureCodeWhenDecodeFails({
          required bool declaredPreviewsUnreadable,
        }) async {
          final source = PhotoSource(
            loader: (path, {required purpose, int? targetLongEdge}) async => NativeImageNeedsRawDecode(
              exifOrientation: kDefaultExifOrientation,
              declaredPreviewsUnreadable: declaredPreviewsUnreadable,
            ),
            dngDecoder: (path) async => throw StateError('decode failed'),
          );
          final outcome = await source.load('/fake/x.dng', longEdge: 2800);
          expect(outcome.payload, isNull);
          return outcome.failureCode;
        }

        test('previews declared but unreadable AND the decode also failed '
            'surfaces the broken-file code', () async {
          expect(
            await failureCodeWhenDecodeFails(declaredPreviewsUnreadable: true),
            'DNG_PARSE_FAILED',
          );
        });

        test('no preview declared and the decode failed stays the uniform miss, '
            'NOT the broken-file code', () async {
          expect(
            await failureCodeWhenDecodeFails(declaredPreviewsUnreadable: false),
            isNull,
          );
        });

        test('the two codes actually differ — the states are not collapsed',
            () async {
          final broken =
              await failureCodeWhenDecodeFails(declaredPreviewsUnreadable: true);
          final ordinary =
              await failureCodeWhenDecodeFails(declaredPreviewsUnreadable: false);
          expect(broken, isNot(ordinary));
        });

        test('a container with unreadable previews whose decode SUCCEEDS is not '
            'reported broken at all — the point of the override', () async {
          final source = PhotoSource(
            loader: (path, {required purpose, int? targetLongEdge}) async => const
                NativeImageNeedsRawDecode(
              exifOrientation: kDefaultExifOrientation,
              declaredPreviewsUnreadable: true,
            ),
            dngDecoder: (path) async => DecodedRgba(
              // Opaque fixture (alpha 0xFF): the identity-transform short-circuit
              // (decoded_rgba_image_provider.dart) asserts every RAW decode is
              // opaque; a zero-filled buffer trips that assert and turns this
              // decode-succeeds case into a caught exception.
              rgba: _opaqueRgba(4 * 4),
              width: 4,
              height: 4,
            ),
          );
          final outcome = await source.load('/fake/x.dng', longEdge: 2800);
          expect(outcome.failureCode, isNull);
          expect(outcome.payload, isNotNull);
        });

        test('the broken-file code is NOT the D3 no-native-decoder state', () {
          expect('DNG_PARSE_FAILED', isNot(kNoNativeDecoderCode));
        });
      });

      group('TC-321: a corrupt TIFF is an ordinary permanent miss', () {
        test('a throwing decoder on a TIFF yields failureCode null, NOT '
            'DNG_PARSE_FAILED', () async {
          final source = PhotoSource(
            // What Task 2's loader branch returns for a .tif at preview:
            // declaredPreviewsUnreadable is structurally false because no preview
            // probe ever runs for a bitmap container.
            loader: (path, {required purpose, int? targetLongEdge}) async =>
                const NativeImageNeedsRawDecode(exifOrientation: 1),
            dngDecoder: (path) async =>
                throw StateError('TIFF_DECODE_FAILED: package:image returned null'),
          );
          final outcome = await source.load('/tmp/broken.tif', longEdge: 2800);
          expect(outcome.payload, isNull);
          expect(outcome.deferred, isFalse);
          expect(
            outcome.failureCode,
            isNull,
            reason: 'DNG_PARSE_FAILED is reserved for a RAW container whose '
                'declared previews were all unreadable (AD-022)',
          );
          expect(outcome.observedCost, SourceCost.expensive);
        });

        test('the DNG_PARSE_FAILED arm is still reachable for a RAW container '
            'with unreadable declared previews', () async {
          // Negative control: without this, the test above would also pass if the
          // DNG_PARSE_FAILED arm had simply been deleted.
          final source = PhotoSource(
            loader: (path, {required purpose, int? targetLongEdge}) async =>
                const NativeImageNeedsRawDecode(
                  exifOrientation: 1,
                  declaredPreviewsUnreadable: true,
                ),
            dngDecoder: (path) async => throw StateError('decode failed'),
          );
          final outcome = await source.load('/tmp/broken.dng', longEdge: 2800);
          expect(outcome.failureCode, 'DNG_PARSE_FAILED');
        });
      });

  });

  group('photo_source_two_phase_test.dart', () {
      TestWidgetsFlutterBinding.ensureInitialized();

      final cases = <String, PhotoSource>{
        'cheap jpeg': PhotoSource(
          loader: _loaderReturning(
            NativeImageBytes(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9])),
          ),
          dngDecoder: _decoderTwoPhase,
        ),
        'raw success': PhotoSource(
          loader: _loaderReturning(
            const NativeImageNeedsRawDecode(exifOrientation: 1),
          ),
          dngDecoder: _decoderTwoPhase,
          payloadEncoder: _encoderTwoPhase,
        ),
        'no decoder': PhotoSource(
          loader: _loaderReturning(
            const NativeImageNeedsRawDecode(exifOrientation: 1),
          ),
        ),
        'throwing decoder': PhotoSource(
          loader: _loaderReturning(
            const NativeImageNeedsRawDecode(exifOrientation: 1),
          ),
          dngDecoder: _throwingDecoderTwoPhase,
          payloadEncoder: _encoderTwoPhase,
        ),
      };

      // TC-831a
      cases.forEach((name, source) {
        test('two-phase equals one-shot: $name', () async {
          final oneShot = await source.load('x.dng', longEdge: 64);
          final split = await source.encodePhase(
            await source.decodePhase('x.dng', longEdge: 64),
          );
          expectSameOutcome(split, oneShot);
          oneShot.fullRes?.image?.dispose();
          split.fullRes?.image?.dispose();
        });
      });

      // TC-831a (deferred arm needs allowExpensive: false)
      test('two-phase equals one-shot: deferred', () async {
        final source = PhotoSource(
          loader: _loaderReturning(
            const NativeImageNeedsRawDecode(exifOrientation: 6),
          ),
          dngDecoder: _decoderTwoPhase,
          payloadEncoder: _encoderTwoPhase,
        );
        final oneShot =
            await source.load('x.dng', longEdge: 64, allowExpensive: false);
        final split = await source.encodePhase(
          await source.decodePhase('x.dng', longEdge: 64, allowExpensive: false),
        );
        expectSameOutcome(split, oneShot);
        expect(split.deferred, isTrue);
        expect(split.exifOrientation, 6);
      });

      // TC-831b
      test('an encoder that throws degrades to the pixel fallback', () async {
        resetReencodeCounters();
        final source = PhotoSource(
          loader: _loaderReturning(
            const NativeImageNeedsRawDecode(exifOrientation: 1),
          ),
          dngDecoder: _decoderTwoPhase,
          payloadEncoder: _throwingEncoder,
        );
        final outcome = await source.encodePhase(
          await source.decodePhase('x.dng', longEdge: 64),
        );
        expect(outcome.payload, isA<PixelPayload>());
        expect(reencodeFallbacks, 1);
      });

  });

  group('photo_source_probe_test.dart', () {
      final dngDir = sampleDngDir;
      final jpgDir = sampleJpgDir;
      final hasSamples = samplePhotosAvailable;

      List<File> dngs() =>
          dngDir.listSync().whereType<File>().where(
            (f) => f.path.toLowerCase().endsWith('.dng'),
          ).toList()..sort((a, b) => a.path.compareTo(b.path));

      // The display window this pipeline actually asks for.
      const windowLongEdge = 2800;

      group('PhotoSource.probeSource (cost gate)', () {
        // THE KILLER for the entire cost-gate premise. The pre-M3 rule was "a
        // .dng needs an expensive RAW decode", and the design's central
        // measurement is that this is wrong 13 times in 14. Both halves are
        // asserted by NAME, so neither a probe that answers `expensive` for
        // everything (the old behaviour, which would still "work") nor one that
        // answers `cheap` for everything (which would strand the no-preview file
        // in a 9-wide decode storm) can pass.
        test('TC-072 content, not the extension, decides the rung: the SAME '
            'extension yields both answers', () async {
          final withPreview = File('${dngDir.path}/2026-02-15-19-37-38.dng');
          final withoutPreview = File('${dngDir.path}/IMG_20251112_092839.dng');
          expect(withPreview.existsSync(), isTrue, reason: 'sample missing');
          expect(withoutPreview.existsSync(), isTrue, reason: 'sample missing');

          expect(
            (await PhotoSource.probeSource(
              withPreview.path,
              longEdge: windowLongEdge,
            )).cost,
            SourceCost.cheap,
            reason: 'this .dng carries a full-size embedded JPEG; charging it a '
                'RAW decode is the 13-in-14 error M3 exists to fix',
          );
          expect(
            (await PhotoSource.probeSource(
              withoutPreview.path,
              longEdge: windowLongEdge,
            )).cost,
            SourceCost.expensive,
            reason: 'this .dng has no usable embedded JPEG -- promoting it to the '
                'cheap rung puts nine FFI decodes in flight at once',
          );
        }, skip: hasSamples ? null : 'no local samples');

        test('TC-073 every sample DNG is measured, and exactly the known '
            'preview-less ones are expensive', () async {
          // The expected set is written out in full rather than derived. Deriving
          // it from the probe's own answers would be circular and assert nothing;
          // a count alone would not notice one expensive sample being swapped for
          // another. These fixtures exist to make sample-set drift fail LOUDLY,
          // and the literal is the loudest shape available.
          //
          // The thirteen below were each measured to have NO usable embedded JPEG:
          // largestLongEdge 0 (not merely under the window) and a full extraction
          // returning nothing. Corroborated OUTSIDE our own walker by exiftool:
          // the 2024-07-* dozen are Xiaomi 2304FPN6DC phone DNGs whose IFD0 is a
          // JPEG-compressed Color Filter Array -- a Bayer mosaic, not a
          // displayable preview -- with no preview/thumbnail/JpgFromRaw tag
          // anywhere. They are the [U-3]/AC8 samples the user supplied.
          //
          // Do NOT re-derive this list from file mtimes: several of the 2024-07-*
          // files carry 2024 timestamps despite being the newest additions.
          const knownPreviewLess = [
            '2024-07-03-18-52-26.dng',
            '2024-07-03-18-52-41.dng',
            '2024-07-03-18-52-49.dng',
            '2024-07-03-18-54-44.dng',
            '2024-07-03-18-54-49.dng',
            '2024-07-03-18-55-14.dng',
            '2024-07-03-18-55-35.dng',
            '2024-07-03-18-56-59.dng',
            '2024-07-03-18-58-42.dng',
            '2024-07-03-19-03-09.dng',
            '2024-07-06-19-09-52.dng',
            '2024-07-06-19-09-55.dng',
            'IMG_20251112_092839.dng',
          ];

          final all = dngs();
          expect(
            all.length,
            26,
            reason: 'a sample appearing or vanishing must fail here first, before '
                'it silently changes what every other probe test measures',
          );

          final expensive = <String>[];
          for (final file in all) {
            final cost = (await PhotoSource.probeSource(
              file.path,
              longEdge: windowLongEdge,
            )).cost;
            expect(cost, isNotNull, reason: '${file.path} could not be measured');
            if (cost == SourceCost.expensive) {
              expensive.add(file.uri.pathSegments.last);
            }
          }
          expect(expensive, knownPreviewLess);
          expect(
            expensive.length,
            13,
            reason: 'AC8 needs at least 9 real no-preview DNGs; this is the '
                'measurement that says how many we actually have',
          );
        }, skip: hasSamples ? null : 'no local samples');

        test('TC-074 the SAME file changes rung when the requested size changes',
            () async {
          // The rung is a function of (content, requested size), not of the file
          // alone. This sample's largest embedded candidate is 6000px, so it
          // satisfies a window request and cannot satisfy a bigger one. A probe
          // that ignored longEdge -- an easy simplification, since 13 of 14
          // samples answer `cheap` either way -- gives the same answer twice and
          // dies here.
          final file = File('${dngDir.path}/2026-02-15-19-37-38.dng');
          expect(
            (await PhotoSource.probeSource(file.path, longEdge: 2800)).cost,
            SourceCost.cheap,
          );
          expect(
            (await PhotoSource.probeSource(file.path, longEdge: 8000)).cost,
            SourceCost.expensive,
            reason: 'no embedded candidate reaches 8000px, so producing one means '
                'a real decode -- regardless of the file carrying a preview',
          );
        }, skip: hasSamples ? null : 'no local samples');

        test('TC-075 probing costs at most 300KB of reads, and a JPEG costs 2 '
            'bytes', () async {
          for (final file in dngs()) {
            var read = 0;
            await PhotoSource.probeSource(
              file.path,
              longEdge: windowLongEdge,
              onDiskRead: (n) => read += n,
            );
            expect(
              read,
              lessThan(300 * 1024),
              reason: '${file.path}: the probe must never fall back to reading '
                  'the whole file -- at 7.5MB average that is the exact hazard '
                  'M0 removed',
            );
          }

          final jpg = jpgDir
              .listSync()
              .whereType<File>()
              .firstWhere((f) => f.path.toLowerCase().endsWith('.jpg'));
          var jpgRead = 0;
          final cost = (await PhotoSource.probeSource(
            jpg.path,
            longEdge: windowLongEdge,
            onDiskRead: (n) => jpgRead += n,
          )).cost;
          expect(cost, SourceCost.cheap);
          expect(
            jpgRead,
            2,
            reason: 'the JPEG hot path must stay free: two bytes of magic and out '
                '(design section 5). Any IFD walk here is Dart CPU on the '
                "app's most-used path",
          );
        }, skip: hasSamples ? null : 'no local samples');

        test('TC-076 an unmeasurable file is UNDETERMINED, not expensive', () async {
          expect(
            (await PhotoSource.probeSource(
              '/tmp/halcyon-no-such-file.dng',
              longEdge: windowLongEdge,
            )).cost,
            isNull,
            reason: 'null and expensive must stay distinct: the caller resolves '
                'the undetermined case from the first bridge answer instead of '
                'guessing a rung (frozen contract A-section-2)',
          );
        });
      });

  });

  group('photo_source_single_probe_test.dart', () {
      TestWidgetsFlutterBinding.ensureInitialized();

      final dngDir = sampleDngDir;
      final jpgDir = sampleJpgDir;
      final hasSamples = samplePhotosAvailable;

      List<File> dngs() =>
          dngDir.listSync().whereType<File>().where(
            (f) => f.path.toLowerCase().endsWith('.dng'),
          ).toList()..sort((a, b) => a.path.compareTo(b.path));

      // The no-preview witness: the one sample in fourteen that genuinely needs a
      // RAW decode, and therefore the only one whose orientation the pipeline must
      // carry across the debounce.
      final noPreviewDng = File('${dngDir.path}/IMG_20251112_092839.dng');

      const windowLongEdge = 2800;

      group('single-probe seam', () {
        // THE KILLER for the ruling. A two-call seam opens the file twice however
        // it is spelled, so this counts opens rather than trusting the shape of
        // the API.
        test('TC-090 the whole probe is ONE file open', () async {
          for (final file in dngs()) {
            late ProbeResult probed;
            final opens = await countingOpens(() async {
              probed = await PhotoSource.probeSource(
                file.path,
                longEdge: windowLongEdge,
              );
            });
            expect(
              opens,
              1,
              reason: '${file.path}: the rung and the orientation must come out of '
                  'ONE bounded walk. $opens opens means the second walk is back',
            );
            expect(
              probed.cost,
              isNotNull,
              reason: '${file.path}: one open must still answer both questions -- '
                  'a cheaper probe that stopped measuring is not the fix',
            );
            expect(probed.exifOrientation, isNotNull, reason: file.path);
          }
        }, skip: hasSamples ? null : 'no local samples');

        // A single walk must not be a DEGRADED walk. If the fused version ever
        // guessed -- folding an unreadable tag to 1, say -- the RAW decode would
        // silently orient pixels wrongly and nothing downstream would notice.
        test('TC-091 the fused orientation equals the dedicated reader',
            () async {
          for (final file in dngs()) {
            expect(
              (await PhotoSource.probeSource(
                file.path,
                longEdge: windowLongEdge,
              )).exifOrientation,
              await DngEmbeddedJpegExtractor.readOrientation(file.path),
              reason: file.path,
            );
          }
        }, skip: hasSamples ? null : 'no local samples');

        // AC14, over the COMBINED probe. The discarded WIP left its orientation
        // reads outside onDiskRead entirely, so its budget gate could not see half
        // of what it spent; summing the fused probe is what closes that hole.
        test('TC-092 the combined probe reads at most 300KB, and a JPEG still '
            'costs 2 bytes', () async {
          for (final file in dngs()) {
            var read = 0;
            final probed = await PhotoSource.probeSource(
              file.path,
              longEdge: windowLongEdge,
              onDiskRead: (n) => read += n,
            );
            expect(probed.exifOrientation, isNotNull, reason: file.path);
            expect(
              read,
              lessThan(300 * 1024),
              reason: '${file.path}: read $read bytes. The budget covers the '
                  'orientation half too -- reads that skip onDiskRead are '
                  'unmeasured spend, not free spend',
            );
            expect(read, greaterThan(0), reason: '${file.path}: reads must be '
                'reported through onDiskRead at all, or the gate measures nothing');
          }

          final jpg = jpgDir
              .listSync()
              .whereType<File>()
              .firstWhere((f) => f.path.toLowerCase().endsWith('.jpg'));
          var jpgRead = 0;
          final probed = await PhotoSource.probeSource(
            jpg.path,
            longEdge: windowLongEdge,
            onDiskRead: (n) => jpgRead += n,
          );
          expect(probed.cost, SourceCost.cheap);
          expect(
            jpgRead,
            2,
            reason: 'fusing orientation into the probe must not cost the JPEG hot '
                'path an IFD walk (design section 5). A JPEG carries its '
                'orientation inside the bitstream the decoder already reads',
          );
          expect(probed.exifOrientation, isNull);
        }, skip: hasSamples ? null : 'no local samples');
      });

      // The caller's list is LIVE. AppState hands the controller its own photo
      // list and clears it on a folder reload, which can land in the middle of one
      // of preloadImages' awaits -- after which `items.length - 1` is -1 and the
      // retention-window clamp throws ArgumentError from inside an async gap.
      //
      // The aliasing always existed; probe-first made it reachable on the ordinary
      // path by adding an await before the clamp. The fix is a snapshot at entry,
      // and this is the assertion that fails if anyone removes it: the list is
      // emptied while the first probe is still in flight, which is precisely the
      // window the crash lived in.
      test('TC-094 emptying the caller list mid-load does not crash preloadImages',
          () async {
        expect(noPreviewDng.existsSync(), isTrue, reason: 'sample missing');
        final controller = ImagePreloadController(
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              const NativeImageFailure('NULL_RESULT', 'not the subject'),
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(800, 600);

        final live = [PhotoItem(id: 'live-0', files: [noPreviewDng])];
        final pending = controller.preloadImages(
          items: live,
          selectedItemId: 'live-0',
          notifyLoaded: () {},
        );
        // Mid-flight, exactly as a folder reload does it.
        live.clear();

        await expectLater(
          pending,
          completes,
          reason: 'preloadImages must not index a list the caller mutated under '
              'it -- before the snapshot this threw ArgumentError from the '
              'window clamp',
        );
      }, skip: hasSamples ? null : 'no local samples');

      // The end-to-end consequence, and the reason the ruling exists: invariant I6.
      // The loader here is the native bridge seam. A no-preview DNG used to reach
      // its RAW decode only after asking the bridge -- that call was where the
      // orientation came from. With the fused probe it must reach the decoder
      // having asked NOBODY: the probe classified it AND supplied the orientation.
      //
      // The zero is asserted twice on purpose. Before the debounce it proves the
      // probe decided the rung; after the decode it proves the decode did not need
      // the bridge either. Only the second one dies if orientation quietly goes
      // back to being a bridge product.
      test('TC-093 an expensive item reaches its RAW decode with ZERO loader '
          'calls', () async {
        expect(noPreviewDng.existsSync(), isTrue, reason: 'sample missing');
        var loaderCalls = 0;
        var decodes = 0;
        final controller = ImagePreloadController(
          imageLoader: (path, {required purpose, int? targetLongEdge}) async {
            loaderCalls++;
            return const NativeImageFailure('UNEXPECTED', 'must not be asked');
          },
          dngDecoder: (path) async {
            decodes++;
            // Opaque fixture (alpha 0xFF): the identity-transform short-circuit
            // in decoded_rgba_image_provider.dart asserts every RAW decode is
            // opaque; a zero-filled buffer would trip it.
            final rgba = Uint8List(2 * 2 * 4);
            for (var p = 0; p < 4; p++) {
              rgba[p * 4 + 3] = 0xFF;
            }
            return DecodedRgba(rgba: rgba, width: 2, height: 2);
          },
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(800, 600);

        final item = PhotoItem(id: 'no-preview', files: [noPreviewDng]);
        await controller.preloadImages(
          items: [item],
          selectedItemId: item.id,
          notifyLoaded: () {},
        );
        expect(
          loaderCalls,
          0,
          reason: 'the content probe classified this file, so the immediate pass '
              'has nothing to ask the bridge',
        );

        await until(() => decodes == 1, reason: 'the debounced RAW decode ran');
        expect(
          loaderCalls,
          0,
          reason: 'the decode got its EXIF orientation from the probe walk. A '
              'bridge call here means the second lookup is back (invariant I6)',
        );
      }, skip: hasSamples ? null : 'no local samples');

  });

  group('photo_source_composite_gate_test.dart', () {
      TestWidgetsFlutterBinding.ensureInitialized();

      // TC-902
      test('PhotoSource forwards its gate to both provider calls', () async {
        final gate = CountingGate();
        final source = PhotoSource(
          loader: (path, {required purpose, int? targetLongEdge}) async =>
              const NativeImageNeedsRawDecode(exifOrientation: 6),
          dngDecoder: (path) async => _decodedCompositeGate(),
          compositeGate: gate.call,
        );

        final decode = await source.decodePhaseExpensive(
          '/tmp/whatever.dng',
          longEdge: 1, // forces the pixel path past its short-circuit too
          exifOrientation: 6,
        );

        expect(decode.pixels, isNotNull);
        expect(
          gate.requests,
          2,
          reason: 'one slot for the pixel payload pass, one for the full-res pass',
        );
        decode.fullRes?.image?.dispose();
      });

      // TC-903
      test('ImagePreloadController forwards its gate to PhotoSource', () async {
        final tmpDir = await Directory.systemTemp.createTemp('gate_test');
        addTearDown(() => tmpDir.delete(recursive: true));
        final file = File('${tmpDir.path}/x.dng');
        await file.writeAsBytes(<int>[0, 1, 2, 3]);

        final gate = CountingGate();
        final controller = ImagePreloadController(
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              const NativeImageNeedsRawDecode(exifOrientation: 6),
          dngDecoder: (path) async => _decodedCompositeGate(),
          payloadEncoder: null,
          compositeGate: gate.call,
        );
        addTearDown(controller.dispose);
        expect(controller.debugCompositeGateIsPaced, isTrue);

        await controller.preloadImages(
          items: [PhotoItem(id: 'x', files: [file])],
          selectedItemId: 'x',
          notifyLoaded: () {},
        );
        for (var i = 0; i < 24; i++) {
          await Future<void>.delayed(Duration.zero);
        }

        expect(
          gate.requests,
          greaterThan(0),
          reason: 'the injected gate must reach the decode-completion path',
        );
      });

  });

  group('photo_source_fullres_handle_test.dart', () {
      TestWidgetsFlutterBinding.ensureInitialized();

      // TC-827a
      test('orientation 1 hands back the decoder buffer and no handle', () async {
        const source = PhotoSource(
          loader: _needsRawDecodeFullres,
          dngDecoder: _decoderFullres,
          payloadEncoder: _encoderFullres,
        );
        final outcome = await source.load('x.dng', longEdge: 0);
        expect(outcome.fullRes, isNotNull);
        expect(outcome.fullRes!.image, isNull);
        expect(identical(outcome.fullRes!.rgba, lastDecoded.rgba), isTrue);
      });

      // TC-827b
      test('orientation 6 hands back a live oriented handle', () async {
        const source = PhotoSource(
          loader: _needsRawDecodeRotated,
          dngDecoder: _decoderFullres,
          payloadEncoder: _encoderFullres,
        );
        final outcome = await source.load('x.dng', longEdge: 0);
        expect(outcome.fullRes!.image, isNotNull);
        expect(outcome.fullRes!.image!.debugDisposed, isFalse);
        expect(outcome.fullRes!.width, 6);
        expect(outcome.fullRes!.height, 8);
        outcome.fullRes!.image!.dispose();
      });

      // TC-827c -- a decode that fails leaves no handle and no fullRes.
      test('a throwing decoder returns no handle to leak', () async {
        const source = PhotoSource(
          loader: _needsRawDecodeRotated,
          dngDecoder: _throwingDecoderFullres,
          payloadEncoder: _encoderFullres,
        );
        final outcome = await source.load('x.dng', longEdge: 0);
        expect(outcome.payload, isNull);
        expect(outcome.fullRes, isNull);
      });

  });

  group('photo_source_reencode_test.dart', () {
      TestWidgetsFlutterBinding.ensureInitialized();

      // TC-364
      test('load() re-encodes a decoded RAW into a plain EncodedPayload', () async {
        const source = PhotoSource(
          loader: _needsRawDecodeReencode,
          dngDecoder: _fakeDecoder,
          payloadEncoder: _fakeEncoder,
        );
        final outcome = await source.load('x.dng', longEdge: 32);
        expect(outcome.payload, isA<EncodedPayload>());
        expect((outcome.payload! as EncodedPayload).bytes.first, 0xFF);
        // The piggyback RGBA must SURVIVE the re-encode: it is a free tier-2 upload.
        expect(outcome.fullRes, isNotNull);
      });

      // TC-364b — the two decode paths must not diverge
      test('loadExpensive() re-encodes identically', () async {
        const source = PhotoSource(
          loader: _needsRawDecodeReencode,
          dngDecoder: _fakeDecoder,
          payloadEncoder: _fakeEncoder,
        );
        final outcome =
            await source.loadExpensive('x.dng', longEdge: 32, exifOrientation: 1);
        expect(outcome.payload, isA<EncodedPayload>());
      });

      // TC-365
      test('no encoder configured -> unchanged PixelPayload behaviour', () async {
        const source = PhotoSource(loader: _needsRawDecodeReencode, dngDecoder: _fakeDecoder);
        final outcome = await source.load('x.dng', longEdge: 32);
        expect(outcome.payload, isA<PixelPayload>());
      });

      // TC-420
      test('a JPG payload is the encoder q70 output, not the file bytes', () async {
        resetNormalizeCounters();
        final fileBytes = Uint8List.fromList(
          List<int>.filled(kNormalizePassthroughMaxBytes + 1, 9),
        );
        final calls = <({int width, int height, int quality})>[];
        final source = PhotoSource(
          loader: (path, {required purpose, int? targetLongEdge}) async => NativeImageBytes(fileBytes),
          payloadEncoder:
              (rgba, {required width, required height, required quality}) async {
            calls.add((width: width, height: height, quality: quality));
            return Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF]);
          },
        );

        final outcome = await withStubDecoder(
          (bytes) async => (rgba: Uint8List(40 * 30 * 4), width: 40, height: 30),
          () => source.load('/x/a.jpg', longEdge: 2800),
        );

        expect(calls, <({int width, int height, int quality})>[
          (width: 40, height: 30, quality: 70),
        ]);
        expect((outcome.payload! as EncodedPayload).bytes.length, 3);
        expect(outcome.observedCost, SourceCost.cheap);
        expect(outcome.fullRes, isNull);
      });

      // TC-421
      test('payloadEncoder null keeps the loader bytes identical', () async {
        final fileBytes = Uint8List.fromList(
          List<int>.filled(kNormalizePassthroughMaxBytes + 1, 9),
        );
        var decodes = 0;
        final source = PhotoSource(
          loader: (path, {required purpose, int? targetLongEdge}) async => NativeImageBytes(fileBytes),
        );
        final outcome = await withStubDecoder(
          (bytes) async {
            decodes++;
            return (rgba: Uint8List(4), width: 1, height: 1);
          },
          () => source.load('/x/a.jpg', longEdge: 2800),
        );
        expect(
          identical((outcome.payload! as EncodedPayload).bytes, fileBytes),
          isTrue,
        );
        expect(decodes, 0);
      });

      // TC-422
      test('bytes recovered after a native failure go through the normaliser',
          () async {
        // The recovery arm reads a real file through the pure-Dart walker, so this
        // asserts the WIRING: an unreadable path yields a null payload and, since
        // the normaliser was never reached, no fallback is counted. If the arm
        // were wired to normalise BEFORE the null check, the counter would move.
        resetNormalizeCounters();
        final source = PhotoSource(
          loader: (path, {required purpose, int? targetLongEdge}) async =>
              const NativeImageFailure('X', 'no bridge'),
          payloadEncoder:
              (rgba, {required width, required height, required quality}) async =>
                  Uint8List.fromList(<int>[1]),
        );
        final outcome = await source.load('/x/missing.arw', longEdge: 2800);
        expect(outcome.payload, isNull);
        expect(normalizeFallbacks, 0);
      });

      // TC-423
      test('the discovery pass never normalises', () async {
        resetNormalizeCounters();
        var decodes = 0;
        final source = PhotoSource(
          loader: (path, {required purpose, int? targetLongEdge}) async =>
              const NativeImageNeedsRawDecode(exifOrientation: 1),
          dngDecoder: (path) async =>
              DecodedRgba(rgba: Uint8List(4), width: 1, height: 1),
          payloadEncoder:
              (rgba, {required width, required height, required quality}) async =>
                  Uint8List.fromList(<int>[1]),
        );
        final outcome = await withStubDecoder(
          (bytes) async {
            decodes++;
            return (rgba: Uint8List(4), width: 1, height: 1);
          },
          () => source.load('/x/a.arw', longEdge: 2800, allowExpensive: false),
        );
        expect(outcome.deferred, isTrue);
        expect(outcome.payload, isNull);
        expect(decodes, 0);
      });

  });

  group('photo_source_single_materialize_test.dart', () {
      TestWidgetsFlutterBinding.ensureInitialized();

      final collected = <String>[];

      setUp(() {
        collected.clear();
        PerfLog.testSink = collected.add;
        // Emit call sites gate on `PerfLog.enabled` themselves (e.g.
        // decoded_rgba_image_provider.dart's `if (PerfLog.enabled) { PerfLog.log(...) }`
        // around the materialize event) -- `testSink` alone does not bypass that
        // gate, only PerfLog.log()'s own file-write path. `enabled = true` with
        // no `PerfLog.init()` call means no file/timer is ever created (init()
        // is the only thing that opens the sink), so this stays structurally
        // free of file I/O; testSink is still what this test asserts against.
        PerfLog.enabled = true;
      });

      tearDown(() {
        PerfLog.testSink = null;
        PerfLog.enabled = false;
      });

      /// 8x6 opaque RGBA, matching the convention in
      /// photo_source_fullres_handle_test.dart / p0_perf_instrumentation_test.dart.
      DecodedRgba decodedFixture() {
        final bytes = Uint8List(8 * 6 * 4);
        for (var p = 0; p < 8 * 6; p++) {
          bytes[p * 4 + 3] = 255;
        }
        return DecodedRgba(rgba: bytes, width: 8, height: 6);
      }

      List<String> materializeEvents() =>
          collected.where((l) => l.startsWith('materialize|')).toList();

      List<String> materializeIds(List<String> events) => events
          .map((l) => RegExp(r'id=(-?\d+)').firstMatch(l)!.group(1)!)
          .toList();

      // TC-1001
      test(
        'decodePhase: non-identity orientation materializes the decoded buffer '
        'exactly once (single materialize|, no repeated id)',
        () async {
          lastDecodedFixture = decodedFixture();
          const source = PhotoSource(
            loader: _needsRawDecodeOrientation6,
            dngDecoder: _fixtureDecoder,
          );

          final decode = await source.decodePhase('sample.dng', longEdge: 0);

          expect(decode.pixels, isNotNull);
          expect(decode.fullRes, isNotNull);
          decode.fullRes!.image?.dispose();

          final events = materializeEvents();
          expect(
            events,
            hasLength(1),
            reason:
                'expected exactly one materialize| event for one decode; got '
                '${events.length}: $events',
          );
          final ids = materializeIds(events);
          expect(
            ids.toSet(),
            hasLength(ids.length),
            reason: 'no id= value may repeat across materialize| events',
          );
        },
      );

      // TC-1001b (twin assertion for decodePhaseExpensive, per plan T2 step 3)
      test(
        'decodePhaseExpensive: non-identity orientation materializes the '
        'decoded buffer exactly once (single materialize|, no repeated id)',
        () async {
          lastDecodedFixture = decodedFixture();
          const source = PhotoSource(
            loader: _unusedLoader,
            dngDecoder: _fixtureDecoder,
          );

          final decode = await source.decodePhaseExpensive(
            'sample.dng',
            longEdge: 0,
            exifOrientation: 6,
          );

          expect(decode.pixels, isNotNull);
          expect(decode.fullRes, isNotNull);
          decode.fullRes!.image?.dispose();

          final events = materializeEvents();
          expect(
            events,
            hasLength(1),
            reason:
                'expected exactly one materialize| event for one decode; got '
                '${events.length}: $events',
          );
          final ids = materializeIds(events);
          expect(
            ids.toSet(),
            hasLength(ids.length),
            reason: 'no id= value may repeat across materialize| events',
          );
        },
      );

  });
}

// --- top-level helpers from photo_source_single_materialize_test.dart (trailing) ---
Future<NativeImageResult> _unusedLoader(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => throw StateError('decodePhaseExpensive must not call loader');

Future<NativeImageResult> _needsRawDecodeOrientation6(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => const NativeImageNeedsRawDecode(exifOrientation: 6);

/// Set immediately before each `PhotoSource` call in this file -- `const`
/// `PhotoSource` construction requires top-level function references, so the
/// fixture itself is threaded through this mutable top-level instead of a
/// closure.
late DecodedRgba lastDecodedFixture;

Future<DecodedRgba> _fixtureDecoder(String path) async => lastDecodedFixture;
