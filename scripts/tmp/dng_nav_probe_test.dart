// THROWAWAY DIAGNOSTIC PROBE -- not part of the test suite, lives outside
// test/ on purpose. Run:
//   flutter test -j 1 scripts/tmp/dng_nav_probe_test.dart
//
// Question under investigation: why does a DNG that goes through the FFI RAW
// decode path (NativeImageNeedsRawDecode) re-load when you navigate away and
// come back, while ordinary byte-backed photos are instant?
//
// Plain test(), never testWidgets(): the raw path awaits real engine futures
// (decodeImageFromPixels / Picture.toImage) which hang forever inside
// testWidgets' FakeAsync zone.

import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_source_types.dart';

final _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAA'
  'AAYAAjCB0C8AAAAASUVORK5CYII=',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<PhotoItem> rawItems(int count) => List.generate(count, (index) {
        final id = 'IMG_${index.toString().padLeft(4, '0')}';
        return PhotoItem(id: id, files: [File('/tmp/$id.dng')]);
      });

  List<PhotoItem> jpgItems(int count) => List.generate(count, (index) {
        final id = 'IMG_${index.toString().padLeft(4, '0')}';
        return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
      });

  DecodedRgba fakeDecoded() => DecodedRgba(
        rgba: Uint8List.fromList(List<int>.generate(2 * 2 * 4, (i) => i)),
        width: 2,
        height: 2,
      );

  Future<void> until(bool Function() condition, {String? reason}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out waiting for: ${reason ?? 'condition'}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  // Quiet cache between probes so currentSize readings mean something.
  setUp(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  // -------------------------------------------------------------------
  // P1. Is the raw path structurally excluded from the tier-1 precache?
  // -------------------------------------------------------------------
  test('P1 raw items produce ZERO tier-1 precache entries; jpg items do not',
      () async {
    // (a) byte-backed control
    final jpgController = ImagePreloadController(
      imageLoader: (path, {required purpose}) async =>
          NativeImageBytes(Uint8List.fromList(_tinyPngBytes)),
    );
    addTearDown(jpgController.dispose);
    jpgController.updateTargetSize(800, 600);

    final jpgs = jpgItems(14);
    await jpgController.preloadImages(
      items: jpgs,
      selectedItemId: jpgs[5].id,
      notifyLoaded: () {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // A neighbour the user has NEVER selected must already have a tier-1
    // ImageCache entry -- that is what makes ordinary photos instant.
    final neighbourBytes = jpgController.imageBytesFor(jpgs[7].id);
    expect(neighbourBytes, isNotNull, reason: 'sanity: neighbour has bytes');
    final tierOneKey = await tierOneProviderFor(
      neighbourBytes!,
      width: 800,
      height: 600,
    ).obtainKey(const ImageConfiguration());
    expect(
      PaintingBinding.instance.imageCache.containsKey(tierOneKey),
      isTrue,
      reason: 'jpg neighbour +2 was NOT tier-1 precached',
    );
    final jpgCacheSize = PaintingBinding.instance.imageCache.currentSize;

    // (b) raw path
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    final rawController = ImagePreloadController(
      imageLoader: (path, {required purpose}) async =>
          const NativeImageNeedsRawDecode(exifOrientation: 1),
      dngDecoder: (path) async => fakeDecoded(),
    );
    addTearDown(rawController.dispose);
    rawController.updateTargetSize(800, 600);

    final raws = rawItems(14);
    await rawController.preloadImages(
      items: raws,
      selectedItemId: raws[5].id,
      notifyLoaded: () {},
    );
    // Deliberately BEFORE the 250ms tier-2 debounce fires: this is the state
    // the user is in the instant they arrive at the photo.
    final atArrivalProvider = rawController.decodedProviderFor(raws[5].id);
    final atArrivalCacheSize = PaintingBinding.instance.imageCache.currentSize;

    print('P1: jpg tier-1 cache entries after one preload pass = '
        '$jpgCacheSize');
    print('P1: raw cache entries at the moment of arrival = '
        '$atArrivalCacheSize; decodedProvider = $atArrivalProvider');
    for (var i = 2; i <= 10; i++) {
      expect(rawController.imageBytesFor(raws[i].id), isNull,
          reason: 'raw items must never have bytes');
    }
    expect(jpgCacheSize, greaterThan(0));
    expect(atArrivalCacheSize, 0,
        reason: 'a raw item has no tier-1 entry at arrival time');
    expect(atArrivalProvider, isNull,
        reason: 'the view has nothing to paint -> spinner');
  });

  // -------------------------------------------------------------------
  // P2. Continuous navigation faster than tierTwoNavigationDebounce.
  // -------------------------------------------------------------------
  test('P2 navigation bursts under 250ms start ZERO raw decodes, while the '
      'byte path precaches during the same burst', () async {
    final decodeCalls = <String>[];
    final rawController = ImagePreloadController(
      imageLoader: (path, {required purpose}) async =>
          const NativeImageNeedsRawDecode(exifOrientation: 1),
      dngDecoder: (path) async {
        decodeCalls.add(path);
        return fakeDecoded();
      },
    );
    addTearDown(rawController.dispose);
    rawController.updateTargetSize(800, 600);
    final raws = rawItems(20);

    for (final idx in [5, 6, 7, 8, 9, 8, 7, 6, 5]) {
      await rawController.preloadImages(
        items: raws,
        selectedItemId: raws[idx].id,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    print('P2: raw decodes started during a 9-step burst = '
        '${decodeCalls.length}');
    expect(decodeCalls, isEmpty,
        reason: 'the debounce cancels every scheduling attempt');
    expect(rawController.decodedProviderFor(raws[5].id), isNull,
        reason: 'back at the start of the burst, still nothing to paint');

    // Byte-backed control over the identical burst.
    final jpgController = ImagePreloadController(
      imageLoader: (path, {required purpose}) async =>
          NativeImageBytes(Uint8List.fromList(_tinyPngBytes)),
    );
    addTearDown(jpgController.dispose);
    jpgController.updateTargetSize(800, 600);
    final jpgs = jpgItems(20);
    for (final idx in [5, 6, 7, 8, 9, 8, 7, 6, 5]) {
      await jpgController.preloadImages(
        items: jpgs,
        selectedItemId: jpgs[idx].id,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    final bytes5 = jpgController.imageBytesFor(jpgs[5].id)!;
    final key5 = await tierOneProviderFor(bytes5, width: 800, height: 600)
        .obtainKey(const ImageConfiguration());
    print('P2: jpg tier-1 entry present after the same burst = '
        '${PaintingBinding.instance.imageCache.containsKey(key5)}');
    expect(PaintingBinding.instance.imageCache.containsKey(key5), isTrue,
        reason: 'tier-1 precache is not debounced; it runs every pass');
  });

  // -------------------------------------------------------------------
  // P3. One-step round trip i -> i+1 -> i.
  // -------------------------------------------------------------------
  test('P3 one-step round trip keeps the decoded image (control)', () async {
    final decodeCalls = <String>[];
    final controller = ImagePreloadController(
      imageLoader: (path, {required purpose}) async =>
          const NativeImageNeedsRawDecode(exifOrientation: 1),
      dngDecoder: (path) async {
        decodeCalls.add(path);
        return fakeDecoded();
      },
    );
    addTearDown(controller.dispose);
    final items = rawItems(20);
    final target = items[8].files.single.path;
    int decodesOfTarget() => decodeCalls.where((p) => p == target).length;

    await controller.preloadImages(
      items: items, selectedItemId: items[8].id, notifyLoaded: () {});
    await until(() => controller.decodedImageFor(items[8].id) != null,
        reason: 'first decode of item 8');
    final first = controller.decodedImageFor(items[8].id)!;
    expect(decodesOfTarget(), 1);

    for (final idx in [9, 8]) {
      await controller.preloadImages(
        items: items, selectedItemId: items[idx].id, notifyLoaded: () {});
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
    print('P3: decodes of item 8 after 8->9->8 = ${decodesOfTarget()}; '
        'first image disposed = ${first.debugDisposed}');
    expect(first.debugDisposed, isFalse);
    expect(decodesOfTarget(), 1);
    expect(controller.decodedProviderFor(items[8].id), isNotNull);
  });

  // -------------------------------------------------------------------
  // P4. Two-step excursion i -> i+1 -> i+2 -> i+1 -> i.
  //     Same excursion is FREE for a byte-backed item.
  // -------------------------------------------------------------------
  test('P4 a TWO-step excursion disposes the decoded image and forces a full '
      're-decode on return, while the byte path keeps its bytes', () async {
    final decodeCalls = <String>[];
    final controller = ImagePreloadController(
      imageLoader: (path, {required purpose}) async =>
          const NativeImageNeedsRawDecode(exifOrientation: 1),
      dngDecoder: (path) async {
        decodeCalls.add(path);
        return fakeDecoded();
      },
    );
    addTearDown(controller.dispose);
    final items = rawItems(20);
    final target = items[8].files.single.path;
    int decodesOfTarget() => decodeCalls.where((p) => p == target).length;

    await controller.preloadImages(
      items: items, selectedItemId: items[8].id, notifyLoaded: () {});
    await until(() => controller.decodedImageFor(items[8].id) != null);
    final first = controller.decodedImageFor(items[8].id)!;
    expect(decodesOfTarget(), 1);

    // Two steps forward, with a pause at each so the debounced sweep runs.
    for (final idx in [9, 10]) {
      await controller.preloadImages(
        items: items, selectedItemId: items[idx].id, notifyLoaded: () {});
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
    print('P4: after 8->9->10, item 8 provider = '
        '${controller.decodedProviderFor(items[8].id)}; '
        'image disposed = ${first.debugDisposed}');
    expect(first.debugDisposed, isTrue,
        reason: 'the ~50MB ui.Image is GONE and is unrecoverable');
    expect(controller.decodedProviderFor(items[8].id), isNull);

    // Come back.
    for (final idx in [9, 8]) {
      await controller.preloadImages(
        items: items, selectedItemId: items[idx].id, notifyLoaded: () {});
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
    print('P4: decodes of item 8 after 8->9->10->9->8 = ${decodesOfTarget()}');
    expect(decodesOfTarget(), 2,
        reason: 'returning to a photo two steps away costs a FULL raw decode');

    // Byte-backed control: the identical excursion.
    final jpgController = ImagePreloadController(
      imageLoader: (path, {required purpose}) async =>
          NativeImageBytes(Uint8List.fromList(_tinyPngBytes)),
    );
    addTearDown(jpgController.dispose);
    jpgController.updateTargetSize(800, 600);
    final jpgs = jpgItems(20);
    await jpgController.preloadImages(
      items: jpgs, selectedItemId: jpgs[8].id, notifyLoaded: () {});
    final bytesBefore = jpgController.imageBytesFor(jpgs[8].id);
    for (final idx in [9, 10, 9, 8]) {
      await jpgController.preloadImages(
        items: jpgs, selectedItemId: jpgs[idx].id, notifyLoaded: () {});
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
    final bytesAfter = jpgController.imageBytesFor(jpgs[8].id);
    print('P4: jpg item 8 bytes survived the same excursion (identical) = '
        '${identical(bytesBefore, bytesAfter)}');
    expect(identical(bytesBefore, bytesAfter), isTrue,
        reason: 'byte-backed items keep their bytes across -3..+5, so a '
            'return visit is a local re-decode, never a native round trip');
  });

  // -------------------------------------------------------------------
  // P5. How far can you go before a raw item is lost?
  // -------------------------------------------------------------------
  test('P5 distance at which a decoded raw image is lost', () async {
    for (final distance in [1, 2, 3]) {
      final controller = ImagePreloadController(
        imageLoader: (path, {required purpose}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        dngDecoder: (path) async => fakeDecoded(),
      );
      final items = rawItems(20);
      await controller.preloadImages(
        items: items, selectedItemId: items[8].id, notifyLoaded: () {});
      await until(() => controller.decodedImageFor(items[8].id) != null);
      final img = controller.decodedImageFor(items[8].id)!;
      for (var step = 1; step <= distance; step++) {
        await controller.preloadImages(
          items: items,
          selectedItemId: items[8 + step].id,
          notifyLoaded: () {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
      print('P5: distance $distance -> item 8 image disposed = '
          '${img.debugDisposed}');
      controller.dispose();
    }
  });

  // -------------------------------------------------------------------
  // P6. WHICH sweep disposes it? Same two-step excursion, but every hop is
  //     faster than the 250ms debounce, so _decodeTierTwoWindow's stale sweep
  //     never runs at index 10. If the image survives, the disposal seen in
  //     P4/P5 comes from the tier-2 +/-1 sweep (image_preload_controller.dart
  //     :421-428), NOT from preloadImages' -3..+5 sweep (:294-296).
  // -------------------------------------------------------------------
  test('P6 the +/-1 tier-2 sweep is the disposer, not the -3..+5 sweep',
      () async {
    final controller = ImagePreloadController(
      imageLoader: (path, {required purpose}) async =>
          const NativeImageNeedsRawDecode(exifOrientation: 1),
      dngDecoder: (path) async => fakeDecoded(),
    );
    addTearDown(controller.dispose);
    final items = rawItems(20);
    await controller.preloadImages(
      items: items, selectedItemId: items[8].id, notifyLoaded: () {});
    await until(() => controller.decodedImageFor(items[8].id) != null);
    final img = controller.decodedImageFor(items[8].id)!;

    // 8 -> 9 -> 10 with 60ms hops: no sweep fires at 9 or 10.
    for (final idx in [9, 10]) {
      await controller.preloadImages(
        items: items, selectedItemId: items[idx].id, notifyLoaded: () {});
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    print('P6: at index 10, BEFORE the debounce fires -> disposed = '
        '${img.debugDisposed}  (item 8 is still inside -3..+5)');
    expect(img.debugDisposed, isFalse);

    // Now let the debounced sweep for index 10 run.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    print('P6: same position, AFTER the debounce fires -> disposed = '
        '${img.debugDisposed}');
    expect(img.debugDisposed, isTrue,
        reason: 'the +/-1 stale-union sweep disposed it');
  });
}
