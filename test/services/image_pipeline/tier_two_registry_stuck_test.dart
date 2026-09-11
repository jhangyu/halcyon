// WP5 regression tests for the "rapid nav -> stuck blurry, never sharpens"
// defect (task #2, 2026-09-11).
//
// Root cause, evidence in docs/logs/2026-09-11/wp5-registry-stuck-diagnosis.txt:
// `TierTwoRegistry.hasFullResEntryFor` answered from payload identity ALONE,
// so once the ImageCache evicted a PIXEL-path (RawFullResImage) tier-2 entry
// underneath the registry, `publishFullRes`'s first-writer-wins guard swallowed
// every recovery publish for that payload object permanently -- the item stayed
// on its blurry tier-1 provider until it left the retention window and returned
// with a NEW payload object. The user's own report carries that exact
// signature: the blur clears after navigating away and back, and their frames
// are ordinary 24MP (i.e. ordinary LRU pressure, not an oversize refusal).
//
// The ENCODED path had already been fixed for precisely this (TC-923, and the
// `stillResident` comment at tier_two_registry.dart:190-209); the residency
// term was simply never carried over to the pixel path's guard.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_registry.dart';

import '../../support/preload_fixtures.dart';

Future<ui.Image> _image(int w, int h) {
  final completer = Completer<ui.Image>();
  final bytes = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 255);
  ui.decodeImageFromPixels(
    bytes,
    w,
    h,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

void main() {
  late ImageCache imageCache;
  late int originalMaximumSizeBytes;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    imageCache = PaintingBinding.instance.imageCache;
    originalMaximumSizeBytes = imageCache.maximumSizeBytes;
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  tearDown(() {
    imageCache.maximumSizeBytes = originalMaximumSizeBytes;
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  group('tier_two_registry_stuck_test.dart', () {
    test(
      'TC-1190 a pixel-path tier-2 entry evicted by the ImageCache underneath '
      'the registry can be RE-PUBLISHED for the SAME payload object -- the '
      'first-writer-wins guard must not block eviction recovery permanently',
      () async {
        // The payload is only ever an identity token here (publishFullRes
        // never reads its contents), so the cheapest fixture is the right one.
        final SourcePayload payload = freshEncodedPayload();
        final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);
        addTearDown(registry.clear);

        var notifications = 0;
        registry.publishFullRes(
          'IMG_00',
          payload,
          await _image(8, 8),
          () => notifications++,
        );
        await until(() => registry.isReady('IMG_00'),
            reason: 'the first full-res publish lands');
        final firstKey = registry.providerFor('IMG_00');
        expect(firstKey, isNotNull);

        // ORDINARY LRU PRESSURE: the ImageCache drops the entry and does not
        // tell the registry. `_sources['IMG_00']` still holds `payload`.
        imageCache.evict(firstKey!);

        expect(registry.isReady('IMG_00'), isFalse,
            reason: 'sanity: isReady is correct -- the entry really is gone. '
                'This test does NOT weaken isReady; it fixes recoverability.');
        expect(
          registry.hasFullResEntryFor('IMG_00', payload),
          isFalse,
          reason: 'THE DEFECT: an identity-only answer here reports an entry '
              'that no longer exists, and every re-publish for this payload is '
              'then dropped by publishFullRes\'s first-writer-wins guard',
        );

        // The recovery publish: same id, same payload OBJECT, a fresh decode.
        registry.publishFullRes(
          'IMG_00',
          payload,
          await _image(8, 8),
          () => notifications++,
        );
        await until(() => registry.isReady('IMG_00'),
            reason: 'the recovery publish for the SAME payload object must '
                'land once the earlier entry is no longer resident');

        expect(notifications, 2,
            reason: 'the recovery publish must notify its own listener');
        expect(registry.fullResProviderFor('IMG_00'), isNotNull,
            reason: 'the item is sharp again, not stranded on tier-1');
      },
    );

    test(
      'TC-1191 while the entry IS resident, a second publishFullRes for the '
      'same payload is still dropped and its image disposed -- adding the '
      'residency term must not reopen the first-writer-wins hole',
      () async {
        final SourcePayload payload = freshEncodedPayload();
        final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);
        addTearDown(registry.clear);

        var notifications = 0;
        registry.publishFullRes(
          'IMG_00',
          payload,
          await _image(8, 8),
          () => notifications++,
        );
        await until(() => registry.isReady('IMG_00'));
        final winner = registry.providerFor('IMG_00');

        expect(registry.hasFullResEntryFor('IMG_00', payload), isTrue,
            reason: 'resident entries still report as in hand');

        final loser = await _image(8, 8);
        registry.publishFullRes('IMG_00', payload, loser, () => notifications++);
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(Duration.zero);
        }

        expect(notifications, 1,
            reason: 'the losing publish must not notify');
        expect(registry.providerFor('IMG_00'), same(winner),
            reason: 'the resident entry must not be overwritten');
        expect(loser.debugDisposed, isTrue,
            reason: 'the loser\'s full-resolution image must be disposed, not '
                'orphaned (verdict 2026-08-30 fix B)');
      },
    );

    test(
      'TC-1192 a frame the ImageCache REFUSES (larger than maximumSizeBytes, '
      'which the SDK disposes instead of caching) is memoised as a full-res '
      'failure, so the new residency term cannot drive an unbounded re-decode '
      'loop -- defensive containment, not a field-observed case',
      () async {
        final SourcePayload payload = freshEncodedPayload();
        final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);
        addTearDown(registry.clear);

        // 64x64 RGBA = 16,384 B; a budget of 1,024 B guarantees the refusal
        // path without allocating a real full-resolution frame.
        imageCache.maximumSizeBytes = 1024;

        registry.publishFullRes('IMG_00', payload, await _image(64, 64), () {});
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(Duration.zero);
        }

        expect(registry.isReady('IMG_00'), isFalse,
            reason: 'a refused frame is not a ready tier-2 entry');
        expect(registry.keyIds, isNot(contains('IMG_00')),
            reason: 'the bookkeeping for a refused frame must not linger');
        expect(
          registry.hasFullResFailure('IMG_00', payload),
          isTrue,
          reason: 'WITHOUT this memo, hasFullResEntryFor would answer "no '
              'entry" on every sweep and each one would buy another decode of '
              'a frame this cache can never hold',
        );
      },
    );
  });
}
