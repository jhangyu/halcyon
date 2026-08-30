import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/raw_pixels_image.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// A loader that never produces bytes for the SIDEBAR purpose, so every item
/// falls to the sidebar's own RAW-decode branch -- the preview-less RAW case.
/// For the PREVIEW purpose it signals "needs a RAW decode" instead of a flat
/// failure: `AppState.selectItem`'s `_preloadImages()` fires a preview load
/// for the same id as an unrelated side effect of `loadFolder`, and a flat
/// `NativeImageFailure` there would land in the PREVIEW permanent-miss set
/// (read by `hasFailed`) regardless of how the sidebar sweep behaves --
/// confounding this file's assertions with a failure they do not exercise.
Future<NativeImageResult> _alwaysFailLoader(
  String path, {
  required ImageRequestPurpose purpose,
}) async {
  if (purpose == ImageRequestPurpose.preview) {
    return const NativeImageNeedsRawDecode(exifOrientation: 1);
  }
  return const NativeImageFailure('NO_THUMBNAIL', 'no thumbnail for test');
}

DecodedRgba _rawFixture({int width = 400, int height = 300}) {
  final bytes = Uint8List(width * height * 4);
  for (var i = 3; i < bytes.length; i += 4) {
    bytes[i] = 255; // opaque
  }
  return DecodedRgba(rgba: bytes, width: width, height: height);
}

Future<Directory> _tempDirWith(List<String> names) async {
  final dir = await Directory.systemTemp.createTemp('halcyon_sidebar_pixels_');
  for (final name in names) {
    await File(p.join(dir.path, name)).writeAsBytes([1, 2, 3]);
  }
  return dir;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // TC-370 and TC-373 are RETIRED (2026-08-30, plan Task 6 / amendment
  // E-C1): both asserted that the SIDEBAR ran its own sized RAW decode and
  // stored the resulting PixelPayload. That producer is deleted -- the sidebar
  // derives every tile from the shared q70 payload now. Their replacements are
  // TC-430/TC-431 in sidebar_shared_payload_test.dart (a tile appears, and one
  // decode serves both tiers) and TC-434 in sidebar_lane_production_test.dart
  // (a far row's payload is produced on the shared lane).

  test('TC-374 INV-MEM: the sidebar cache stays viewport-bound', () async {
    final names = [for (var i = 0; i < 200; i++) 'f${i.toString().padLeft(3, "0")}.dng'];
    final dir = await _tempDirWith(names);
    addTearDown(() => dir.delete(recursive: true));

    final controller = ImagePreloadController(
      imageLoader: _alwaysFailLoader,
      // Tiles now come from the shared payload, so the payload producer is
      // what this bound has to survive.
      dngDecoder: (path) async => _rawFixture(),
      payloadEncoder: null,
    );
    final state = AppState(preloadController: controller);
    await state.loadFolder(dir);
    await state.preloadThumbnails(0, 19);
    await Future<void>.delayed(const Duration(milliseconds: 800));

    final maxEntries = 20 + 2 * thumbnailPrefetchMargin;
    // Non-vacuity: a bound that nothing ever approaches proves nothing. With
    // the sidebar now driving payload production, tiles must actually appear.
    expect(controller.debugThumbnailCacheLength, greaterThan(0));
    expect(controller.debugThumbnailCacheLength, lessThanOrEqualTo(maxEntries));
    expect(
      controller.debugThumbnailCacheByteCost,
      lessThanOrEqualTo(controller.debugThumbnailCacheLength * 160000),
    );
  });

  test('TC-375 RawPixelsImage keys on payload identity', () {
    final payload = PixelPayload(rgba: Uint8List(4), width: 1, height: 1);
    final other = PixelPayload(rgba: Uint8List(4), width: 1, height: 1);
    expect(RawPixelsImage(payload) == RawPixelsImage(payload), isTrue);
    expect(RawPixelsImage(payload).hashCode, RawPixelsImage(payload).hashCode);
    expect(RawPixelsImage(payload) == RawPixelsImage(other), isFalse);
  });

  test('TC-378 a stale generation writes nothing into the sidebar cache',
      () async {
    final dir = await _tempDirWith(['c.dng']);
    addTearDown(() => dir.delete(recursive: true));

    final gate = Completer<void>();
    final controller = ImagePreloadController(
      imageLoader: _alwaysFailLoader,
      dngDecoder: (path) async {
        await gate.future; // still in flight when the generation is bumped
        return _rawFixture();
      },
      payloadEncoder: null,
    );
    final state = AppState(preloadController: controller);
    await state.loadFolder(dir);
    await state.preloadThumbnails(0, 0);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    controller.reset(); // bumps _thumbBatchGeneration
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(controller.debugThumbnailCacheLength, 0);
  });
}
