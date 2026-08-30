import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';

/// Task 6 (plan `docs/logs/2026-08-30/shared-payload-cache-plan.md`): the
/// sidebar is a CONSUMER of the shared q70 payload, never a second producer of
/// pixels. Every test here asserts the consumer property from the outside --
/// through the decoder call count -- rather than through the sweep's internals.
List<PhotoItem> _items(int n) => <PhotoItem>[
  for (var i = 0; i < n; i++) PhotoItem(id: 'p$i', files: <File>[File('/x/p$i.arw')]),
];

class CountingDecoder {
  final List<String> paths = <String>[];
  int get calls => paths.length;
  int callsFor(String id) => paths.where((p) => p.endsWith('/$id.arw')).length;
  Future<DecodedRgba> call(String path) async {
    paths.add(path);
    return DecodedRgba(rgba: Uint8List(8 * 8 * 4), width: 8, height: 8);
  }
}

Future<NativeImageResult> _rawLoader(
  String path, {
  required ImageRequestPurpose purpose,
}) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

Future<void> _settle([int ms = 400]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // TC-430
  test('a cached payload yields a tile with no further decoder call', () async {
    final decoder = CountingDecoder();
    final controller = ImagePreloadController(
      imageLoader: _rawLoader,
      dngDecoder: decoder.call,
      payloadEncoder: null,
    );
    final items = _items(10);
    controller.updateTargetSize(800, 600);
    await controller.preloadImages(
      items: items,
      selectedItemId: 'p0',
      notifyLoaded: () {},
    );
    await _settle();
    expect(controller.payloadFor('p0'), isNotNull);
    // The navigation window is -3..+5, so p0..p5 are decoded exactly once each
    // and are the rows this test's sweep asks about.
    for (var i = 0; i <= 5; i++) {
      expect(decoder.callsFor('p$i'), 1, reason: 'p$i decoded once for preview');
    }

    await controller.preloadThumbnails(
      items: items,
      startIdx: 0,
      endIdx: 3,
      notifyLoaded: () {},
    );
    await _settle();

    // Every row whose payload was already resident got a tile, and NONE of
    // them bought a second decode. (Rows outside the navigation window DO get
    // decoded by the sweep -- that is Task 7's "scrolling fills the payload
    // cache" and is asserted in sidebar_lane_production_test.dart.)
    for (var i = 0; i <= 5; i++) {
      expect(controller.thumbnailPayloadFor('p$i'), isNotNull, reason: 'tile p$i');
      expect(
        decoder.callsFor('p$i'),
        1,
        reason: 'deriving p$i\'s tile must run no second decoder call',
      );
    }
    controller.dispose();
  });

  // TC-431
  test('one decode serves both the preview and the sidebar tile', () async {
    final decoder = CountingDecoder();
    final controller = ImagePreloadController(
      imageLoader: _rawLoader,
      dngDecoder: decoder.call,
      payloadEncoder: null,
    );
    final items = _items(1);
    controller.updateTargetSize(800, 600);

    // Sidebar asks FIRST, so the row is a waiter when the payload lands.
    await controller.preloadThumbnails(
      items: items,
      startIdx: 0,
      endIdx: 0,
      notifyLoaded: () {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await controller.preloadImages(
      items: items,
      selectedItemId: 'p0',
      notifyLoaded: () {},
    );
    await _settle();

    expect(controller.payloadFor('p0'), isNotNull);
    expect(controller.thumbnailPayloadFor('p0'), isNotNull);
    expect(
      decoder.calls,
      1,
      reason: 'the sidebar must not buy a second decode of the same file',
    );
    controller.dispose();
  });

  // TC-432
  test('a viewport move before derivation lands writes nothing stale', () async {
    final decoder = CountingDecoder();
    final controller = ImagePreloadController(
      imageLoader: _rawLoader,
      dngDecoder: decoder.call,
      payloadEncoder: null,
    );
    final items = _items(200);
    controller.updateTargetSize(800, 600);
    await controller.preloadThumbnails(
      items: items,
      startIdx: 0,
      endIdx: 4,
      notifyLoaded: () {},
    );
    await controller.preloadThumbnails(
      items: items,
      startIdx: 150,
      endIdx: 154,
      notifyLoaded: () {},
    );
    await _settle(600);

    expect(controller.thumbnailPayloadFor('p0'), isNull);
    expect(
      controller.debugThumbnailCacheLength,
      lessThanOrEqualTo(5 + 2 * thumbnailPrefetchMargin),
    );
    controller.dispose();
  });

  // TC-433
  test('a permanent-miss item becomes a sidebar permanent miss', () async {
    final controller = ImagePreloadController(
      imageLoader: _rawLoader,
      dngDecoder: null, // no decoder => permanent miss
      payloadEncoder: null,
    );
    final items = _items(5);
    controller.updateTargetSize(800, 600);
    await controller.preloadImages(
      items: items,
      selectedItemId: 'p0',
      notifyLoaded: () {},
    );
    await controller.preloadThumbnails(
      items: items,
      startIdx: 0,
      endIdx: 4,
      notifyLoaded: () {},
    );
    await _settle();

    expect(controller.hasFailed('p0'), isTrue);
    expect(controller.thumbnailPayloadFor('p0'), isNull);
    expect(controller.debugThumbPermanentMisses.contains('p0'), isTrue);
    controller.dispose();
  });
}
