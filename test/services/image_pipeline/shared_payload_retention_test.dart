import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';

List<PhotoItem> _items(int n) => <PhotoItem>[
  for (var i = 0; i < n; i++)
    PhotoItem(id: 'p$i', files: <File>[File('/x/p$i.jpg')]),
];

Future<NativeImageResult> _bytesLoader(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => NativeImageBytes(Uint8List.fromList(<int>[1, 2, 3, 4]));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // TC-427
  test(
    'retention is the union of the navigation window and the sidebar set',
    () async {
      final controller = ImagePreloadController(
        imageLoader: _bytesLoader,
        payloadEncoder: null,
      );
      final items = _items(60);

      await controller.preloadImages(
        items: items,
        selectedItemId: 'p0',
        notifyLoaded: () {},
      );
      await controller.preloadThumbnails(
        items: items,
        startIdx: 40,
        endIdx: 44,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));

      final ids = controller.debugRetentionIds;
      expect(ids.contains('p0'), isTrue, reason: 'navigation window');
      expect(ids.contains('p42'), isTrue, reason: 'sidebar viewport');
      controller.dispose();
    },
  );

  // TC-428
  test('eviction priority puts every navigation id before every sidebar id', () async {
    final controller = ImagePreloadController(
      imageLoader: _bytesLoader,
      payloadEncoder: null,
    );
    final items = _items(60);
    await controller.preloadThumbnails(
      items: items,
      startIdx: 40,
      endIdx: 44,
      notifyLoaded: () {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await controller.preloadImages(
      items: items,
      selectedItemId: 'p0',
      notifyLoaded: () {},
    );

    final order = controller.debugEvictionPriority;
    expect(order.first, 'p0');
    final lastNav = order.indexOf('p5'); // inside -3..+5 of p0
    final firstSidebarOnly = order.indexOf('p42');
    expect(lastNav, greaterThanOrEqualTo(0));
    expect(firstSidebarOnly, greaterThan(lastNav));
    controller.dispose();
  });

  // TC-429
  test('sidebar-only ids never get a tier-1 or tier-2 ImageCache entry', () async {
    final controller = ImagePreloadController(
      imageLoader: _bytesLoader,
      payloadEncoder: null,
    );
    final items = _items(60);
    // Tier-1 precache is a no-op until the viewport size is known, so without
    // this the tier-1 assertion below would pass vacuously.
    controller.updateTargetSize(800, 600);
    await controller.preloadImages(
      items: items,
      selectedItemId: 'p0',
      notifyLoaded: () {},
    );
    await controller.preloadThumbnails(
      items: items,
      startIdx: 40,
      endIdx: 44,
      notifyLoaded: () {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 400));
    // The sidebar's own ids (p40..p44 plus the prefetch margin) are retained
    // for their PAYLOAD only; neither ImageCache tier may hold a key for them.
    for (final id in <String>['p40', 'p41', 'p42', 'p43', 'p44']) {
      expect(controller.debugTierTwoKeyIds.contains(id), isFalse, reason: id);
      expect(controller.debugTierOneKeyIds.contains(id), isFalse, reason: id);
    }
    // Sanity: the assertion above is not vacuous because the tiers are empty --
    // the selected navigation item DOES hold a tier-1 key.
    expect(controller.debugTierOneKeyIds, isNotEmpty);
    controller.dispose();
  });
}
