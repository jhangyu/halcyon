import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_embedded_jpeg_extractor.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_source.dart';

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
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sampleDir = Directory('local_data/photo_samples/DNG');
  const withPreviewSample = '2026-02-15-19-37-38.dng';
  const noPreviewSample = 'IMG_20251112_092839.dng';

  test('sample directory has both required fixtures', () {
    expect(
      File('${sampleDir.path}/$withPreviewSample').existsSync(),
      isTrue,
    );
    expect(File('${sampleDir.path}/$noPreviewSample').existsSync(), isTrue);
  });

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
        imageLoader: (requestedPath, {required purpose}) async {
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

      final gotBytes = controller.imageBytesFor('dng-1');
      expect(gotBytes, isNotNull);
      expect(gotBytes, equals(expectedBytes));
      expect(controller.hasFailed('dng-1'), isFalse);
    },
  );

  test(
    'a .dng with no embedded preview still falls through to hasFailed, '
    'not a crash, when the native preview channel fails',
    () async {
      final path = '${sampleDir.path}/$noPreviewSample';

      final controller = ImagePreloadController(
        imageLoader: (requestedPath, {required purpose}) async {
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
      addTearDown(() => tmpDir.delete(recursive: true));
      final fakeJpgFile = File('${tmpDir.path}/not-a-dng.jpg');
      await fakeJpgFile.writeAsBytes(dngBytes);

      final controller = ImagePreloadController(
        imageLoader: (requestedPath, {required purpose}) async {
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

      expect(controller.imageBytesFor('jpg-1'), equals(expectedBytes));
      expect(controller.hasFailed('jpg-1'), isFalse);
    },
  );

  test(
    'non-TIFF garbage saved under a .jpg extension is still a permanent '
    'miss when the native preview channel fails (proves the magic check, '
    'not the extension, is what discriminates)',
    () async {
      final tmpDir = await Directory.systemTemp.createTemp(
        'halcyon_photo_source_gate_negative_',
      );
      addTearDown(() => tmpDir.delete(recursive: true));
      final garbageJpgFile = File('${tmpDir.path}/not-an-image.jpg');
      await garbageJpgFile.writeAsBytes(
        List<int>.generate(64, (i) => i % 256),
      );

      final controller = ImagePreloadController(
        imageLoader: (requestedPath, {required purpose}) async {
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

      expect(controller.imageBytesFor('jpg-2'), isNull);
      expect(controller.hasFailed('jpg-2'), isTrue);
    },
  );

  test(
    'fallbackAfterNativeFailure recovers a non-DNG RAW with an embedded '
    'preview (extension gate removed)',
    () async {
      final dir = await Directory.systemTemp.createTemp('photo_source_f08');
      addTearDown(() => dir.delete(recursive: true));
      final samples = Directory('local_data/photo_samples/DNG')
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
        loader: (path, {required purpose}) async => NativeImageNeedsRawDecode(
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
        loader: (path, {required purpose}) async => const
            NativeImageNeedsRawDecode(
          exifOrientation: kDefaultExifOrientation,
          declaredPreviewsUnreadable: true,
        ),
        dngDecoder: (path) async => DecodedRgba(
          rgba: Uint8List(4 * 4 * 4),
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
        loader: (path, {required purpose}) async =>
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
        loader: (path, {required purpose}) async =>
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
}
