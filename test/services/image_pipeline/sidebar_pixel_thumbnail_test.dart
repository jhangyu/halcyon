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

  test(
    'TC-370 a preview-less RAW yields a PixelPayload and is NOT a permanent '
    'miss (the Windows blank-tile regression)',
    () async {
      final dir = await _tempDirWith(['a.dng']);
      addTearDown(() => dir.delete(recursive: true));

      final controller = ImagePreloadController(
        imageLoader: _alwaysFailLoader,
        sidebarRawDecoder: (path, {required int maxDim}) async => _rawFixture(),
        // A full decoder is wired too, so the DETAIL (preview) path -- which
        // AppState.selectItem's _preloadImages() triggers for the SAME id as
        // an unrelated side effect of loadFolder -- also succeeds. Without
        // this, `hasFailed` (which reads the PREVIEW permanent-miss set) goes
        // true purely because no dngDecoder was configured, confounding this
        // assertion with a failure this test is not exercising.
        dngDecoder: (path) async => _rawFixture(),
      );
      final state = AppState(preloadController: controller);
      await state.loadFolder(dir);
      await state.preloadThumbnails(0, state.items.length - 1);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final id = state.items.single.id;
      final payload = state.thumbnailPayloadFor(id);
      expect(payload, isA<PixelPayload>());
      expect(controller.hasFailed(id), isFalse);
    },
  );

  test('TC-373 the stored payload is capped at 200px and self-consistent',
      () async {
    final dir = await _tempDirWith(['b.dng']);
    addTearDown(() => dir.delete(recursive: true));

    final controller = ImagePreloadController(
      imageLoader: _alwaysFailLoader,
      sidebarRawDecoder: (path, {required int maxDim}) async => _rawFixture(),
    );
    final state = AppState(preloadController: controller);
    await state.loadFolder(dir);
    await state.preloadThumbnails(0, state.items.length - 1);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final payload =
        state.thumbnailPayloadFor(state.items.single.id)! as PixelPayload;
    expect(payload.width <= 200 && payload.height <= 200, isTrue,
        reason: '${payload.width}x${payload.height} exceeds the 200px cap');
    expect(payload.rgba.length, payload.width * payload.height * 4);
  });

  test('TC-374 INV-MEM: the sidebar cache stays viewport-bound', () async {
    final names = [for (var i = 0; i < 200; i++) 'f${i.toString().padLeft(3, "0")}.dng'];
    final dir = await _tempDirWith(names);
    addTearDown(() => dir.delete(recursive: true));

    final controller = ImagePreloadController(
      imageLoader: _alwaysFailLoader,
      sidebarRawDecoder: (path, {required int maxDim}) async => _rawFixture(),
    );
    final state = AppState(preloadController: controller);
    await state.loadFolder(dir);
    await state.preloadThumbnails(0, 19);
    await Future<void>.delayed(const Duration(milliseconds: 800));

    final maxEntries = 20 + 2 * thumbnailPrefetchMargin;
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
      sidebarRawDecoder: (path, {required int maxDim}) async {
        await gate.future; // still in flight when the generation is bumped
        return _rawFixture();
      },
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
