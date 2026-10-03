// Memory-reclamation campaign M2.2: the image-cache budget is sized from the
// LARGEST full resolution seen this session instead of a fixed 24 MP item.
// Pinned in raw bytes, like TC-1183 (MB-vs-MiB drift cost a round before).
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/cache_budget.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_registry.dart';

import '../../support/preload_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late int originalMaximumSizeBytes;

  setUp(() {
    originalMaximumSizeBytes =
        PaintingBinding.instance.imageCache.maximumSizeBytes;
    ImageCacheBudget.debugReset();
  });

  tearDown(() {
    ImageCacheBudget.debugReset();
    PaintingBinding.instance.imageCache.maximumSizeBytes =
        originalMaximumSizeBytes;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  test('TC-1444 the budget holds the +/-1 band at 24, 40 and 60 MP', () {
    const sizes = [(6000, 4000), (7752, 5178), (9520, 6336)];
    const expected = [400556032, 623902720, 901775360];
    for (var i = 0; i < sizes.length; i++) {
      final (w, h) = sizes[i];
      final budget = imageCacheBudgetBytes(largestFullResolutionPixels: w * h);
      expect(budget, expected[i], reason: '${w}x$h pinned in bytes');
      expect(budget, greaterThanOrEqualTo(3 * w * h * kDecodedBytesPerPixel),
          reason: 'the three band slots fit, so the band is not thrashed');
    }
    expect(imageCacheBudgetBytes(largestFullResolutionPixels: 12000000),
        400556032,
        reason: 'never sized below the 24 MP reference item');
  });

  test('TC-1445 machine memory stays a downward ceiling only', () {
    const pixels = 9520 * 6336;
    expect(
        imageCacheBudgetBytes(
            physicalMemoryBytes: 2 << 30, largestFullResolutionPixels: pixels),
        536870912);
    expect(
        imageCacheBudgetBytes(
            physicalMemoryBytes: 3 << 30, largestFullResolutionPixels: pixels),
        805306368);
    expect(
        imageCacheBudgetBytes(
            physicalMemoryBytes: 32 << 30, largestFullResolutionPixels: pixels),
        901775360,
        reason: 'the user machine (32 GiB): the ceiling does not bind');
  });

  test('TC-1446 ImageCacheBudget grows monotonically and only once configured',
      () {
    final cache = PaintingBinding.instance.imageCache;
    cache.maximumSizeBytes = 1234;
    ImageCacheBudget.observeFullResolution(7752, 5178);
    expect(cache.maximumSizeBytes, 1234,
        reason: 'unconfigured (every unit test): never touches the cache');
    expect(ImageCacheBudget.debugLastObserved, (7752, 5178));

    ImageCacheBudget.configure(physicalMemoryBytes: 32 << 30);
    expect(cache.maximumSizeBytes, 400556032);
    ImageCacheBudget.observeFullResolution(7752, 5178);
    expect(cache.maximumSizeBytes, 623902720);
    ImageCacheBudget.observeFullResolution(6000, 4000);
    expect(cache.maximumSizeBytes, 623902720, reason: 'never lowered');
    ImageCacheBudget.observeFullResolution(9520, 6336);
    expect(cache.maximumSizeBytes, 901775360);
    expect(ImageCacheBudget.largestFullResolutionPixels, 9520 * 6336);
  });

  test('TC-1447 both tier-2 publish paths report the decoded dimensions',
      () async {
    final SourcePayload payload = freshEncodedPayload();
    final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);
    addTearDown(registry.clear);

    registry.publishFullRes('a', payload, await tinyImage(), () {});
    expect(ImageCacheBudget.debugLastObserved, (1, 1),
        reason: 'pixel path observes BEFORE the resolve');

    ImageCacheBudget.debugReset();
    final encoded = freshEncodedPayload();
    registry.publishEncoded(
        'b', encoded, fullSizeProviderFor(encoded.bytes), () {});
    await until(() => ImageCacheBudget.debugLastObserved != null,
        reason: 'encoded path observes in the decode listener');
    expect(ImageCacheBudget.debugLastObserved, (1, 1));
  });
}
