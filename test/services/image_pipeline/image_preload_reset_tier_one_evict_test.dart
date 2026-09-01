import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';

// A 1x1 PNG. Real bytes matter: the tier-1 provider is a ResizeImage over a
// MemoryImage, and the entry only becomes tracked in the ImageCache once the
// codec actually decodes something.
final Uint8List _png1x1 = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

List<PhotoItem> _items(int n) => <PhotoItem>[
  for (var i = 0; i < n; i++)
    PhotoItem(id: 'p$i', files: <File>[File('/x/p$i.jpg')]),
];

Future<NativeImageResult> _pngLoader(
  String path, {
  required ImageRequestPurpose purpose,
}) async => NativeImageBytes(Uint8List.fromList(_png1x1));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  // TC-487
  test('reset evicts the tier-1 ImageCache entries it recorded', () async {
    final controller = ImagePreloadController(
      imageLoader: _pngLoader,
      payloadEncoder: null,
    );
    addTearDown(controller.dispose);

    // Tier-1 precache is a no-op until the viewport size is known; without
    // this the assertions below would pass vacuously.
    controller.updateTargetSize(800, 600);
    final items = _items(8);
    await controller.preloadImages(
      items: items,
      selectedItemId: 'p0',
      notifyLoaded: () {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(
      controller.debugTierOneKeyIds,
      isNotEmpty,
      reason: 'no tier-1 keys recorded: the test would be vacuous',
    );

    // Rebuild the SAME cache key the controller used: tierOneProviderFor is
    // keyed on (bytes identity, width, height), and imageBytesFor hands back
    // the very buffer the retained payload holds.
    final bytes = controller.imageBytesFor('p0');
    expect(bytes, isNotNull, reason: 'p0 payload must be retained');
    final key = await tierOneProviderFor(bytes!, width: 800, height: 600)
        .obtainKey(const ImageConfiguration());

    expect(
      PaintingBinding.instance.imageCache.statusForKey(key).untracked,
      isFalse,
      reason: 'precondition: p0 tier-1 entry is tracked before reset',
    );

    controller.reset();

    expect(
      PaintingBinding.instance.imageCache.statusForKey(key).untracked,
      isTrue,
      reason: 'reset must evict tier-1 entries, not just drop their keys',
    );
  });
}
