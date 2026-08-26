// Amendment-3 scheduling controls. This historical-lane file is committed on
// top of untouched production 0e6407e so its RED is a genuine pre-fix result.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<PhotoItem> items(int count) => List.generate(count, (index) {
    final id = 'IMG_${index.toString().padLeft(4, '0')}';
    return PhotoItem(id: id, files: [File('/tmp/$id.dng')]);
  });

  DecodedRgba decoded() =>
      DecodedRgba(rgba: Uint8List(2 * 2 * 4), width: 2, height: 2);

  Future<void> until(bool Function() condition, {String? reason}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out waiting for: ${reason ?? 'condition'}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  // This is the scheduling killer: all three +/-1 items become eligible after
  // the frozen 250ms debounce, but no-preview RAW execution must be SERIAL.
  // At 0e6407e the tier-two loop uses unawaited(_ensurePayload(...).then(...))
  // for every item, so the 120ms decoder futures overlap and this assertion is
  // a real red pre-fix observation, not a timeout or setup failure.
  test('TC-086 expensive post-debounce RAW execution is sequential', () async {
    var concurrent = 0;
    var maxConcurrent = 0;
    var started = 0;
    final controller = ImagePreloadController(
      imageLoader: (path, {required purpose}) async =>
          const NativeImageNeedsRawDecode(exifOrientation: 1),
      dngDecoder: (path) async {
        started++;
        concurrent++;
        if (concurrent > maxConcurrent) maxConcurrent = concurrent;
        await Future<void>.delayed(const Duration(milliseconds: 120));
        concurrent--;
        return decoded();
      },
    );
    addTearDown(controller.dispose);

    final photos = items(14);
    await controller.preloadImages(
      items: photos,
      selectedItemId: photos[5].id,
      notifyLoaded: () {},
    );
    await until(() => started == 3, reason: 'all +/-1 expensive decodes began');
    await until(() => concurrent == 0, reason: 'all expensive decodes settled');

    expect(
      maxConcurrent,
      1,
      reason:
          'all three eligible RAW items may retain under -3..+5, but only '
          'one native RAW decode may execute after the frozen debounce',
    );
  });

  // Cheap work retains the opposite scheduling rule: the full retention-window
  // loads launch in parallel rather than being serialised behind the selected
  // item. The selected call is completed first so the test observes the later
  // eight-window fan-out, not merely the deliberate priority phase.
  test('TC-088 cheap and expensive payloads retain identically at -3 and '
      'evict identically at -4', () async {
    Future<ImagePreloadController> make(bool expensive) async {
      return ImagePreloadController(
        imageLoader: (path, {required purpose}) async => expensive
            ? const NativeImageNeedsRawDecode(exifOrientation: 1)
            : NativeImageBytes(Uint8List.fromList([137, 80, 78, 71])),
        dngDecoder: expensive ? (path) async => decoded() : null,
      );
    }

    final photos = items(20);
    for (final expensive in [false, true]) {
      final controller = await make(expensive);
      addTearDown(controller.dispose);
      await controller.preloadImages(
        items: photos,
        selectedItemId: photos[2].id,
        notifyLoaded: () {},
      );
      await until(
        () => controller.payloadFor(photos[2].id) != null,
        reason: '${expensive ? 'expensive' : 'cheap'} source landed',
      );
      final payload = controller.payloadFor(photos[2].id);

      await controller.preloadImages(
        items: photos,
        selectedItemId: photos[5].id,
        notifyLoaded: () {},
      );
      expect(
        identical(controller.payloadFor(photos[2].id), payload),
        isTrue,
        reason: '${expensive ? 'expensive' : 'cheap'} survives exactly at -3',
      );

      await controller.preloadImages(
        items: photos,
        selectedItemId: photos[6].id,
        notifyLoaded: () {},
      );
      expect(
        controller.payloadFor(photos[2].id),
        isNull,
        reason: '${expensive ? 'expensive' : 'cheap'} evicts immediately at -4',
      );
    }
  });

  test('TC-089 cheap full retention-window source loads overlap', () async {
    var concurrent = 0;
    var maxConcurrent = 0;
    final first = Completer<NativeImageResult>();
    var isFirst = true;
    final controller = ImagePreloadController(
      imageLoader: (path, {required purpose}) {
        if (isFirst) {
          isFirst = false;
          return first.future;
        }
        concurrent++;
        if (concurrent > maxConcurrent) maxConcurrent = concurrent;
        return Future<NativeImageResult>.delayed(
          const Duration(milliseconds: 80),
          () {
            concurrent--;
            return NativeImageBytes(Uint8List.fromList([137, 80, 78, 71]));
          },
        );
      },
    );
    addTearDown(controller.dispose);
    final photos = items(14);
    final preload = controller.preloadImages(
      items: photos,
      selectedItemId: photos[5].id,
      notifyLoaded: () {},
    );
    await Future<void>.delayed(Duration.zero);
    first.complete(NativeImageBytes(Uint8List.fromList([137, 80, 78, 71])));
    await preload;
    expect(
      maxConcurrent,
      greaterThan(1),
      reason: 'cheap payload acquisition across -3..+5 must overlap',
    );
  });
}
