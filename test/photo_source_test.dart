import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/dng_preview_extractor.dart';
import 'package:halcyon_flutter/services/image_preload_controller.dart';
import 'package:halcyon_flutter/services/native_thumbnail_service.dart';

/// M2: source-selection was moved from an inline check in
/// `image_preload_controller.dart` into `photo_source.dart`, behind the
/// existing `ImageBytesLoader` seam. Behavior-preserving, so these tests
/// deliberately do NOT import `photo_source.dart` or assert on its
/// internals (design-doc round-1 handoff warning: an observer that moves
/// with the behavior is a false green). Instead they drive the CONTROLLER
/// through the same public API/fakes the pre-existing suite uses, and
/// assert on what the controller hands back — i.e. they observe from
/// outside the seam, exactly like the 19 pre-existing raw assertions they
/// sit next to.
///
/// Real samples only, per repo convention (see dng_preview_extractor_test.dart):
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
          await DngPreviewExtractor.extractFullSizeEmbeddedJpegFromFile(path);
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

      expect(controller.imageBytesFor('dng-2'), isNull);
      expect(controller.hasFailed('dng-2'), isTrue);
    },
  );

  test(
    'a non-.dng file that fails the native preview channel does not '
    'attempt embedded-JPEG recovery (extension gate holds through the seam)',
    () async {
      final controller = ImagePreloadController(
        imageLoader: (requestedPath, {required purpose}) async {
          return const NativeImageFailure(
            'NULL_RESULT',
            'simulated native failure',
          );
        },
      );
      addTearDown(controller.dispose);

      final items = [
        PhotoItem(id: 'jpg-1', files: [File('/tmp/not-real.jpg')]),
      ];

      await controller.preloadImages(
        items: items,
        selectedItemId: 'jpg-1',
        notifyLoaded: () {},
      );

      expect(controller.imageBytesFor('jpg-1'), isNull);
      expect(controller.hasFailed('jpg-1'), isTrue);
    },
  );
}
