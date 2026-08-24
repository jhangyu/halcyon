// Round-2 precache-span guarantees (AC2, AC3, AC6).
//
// What round 2 changes, and why these tests exist:
//   * tier-1 (screen resolution) precache widens from a hardcoded +/-2 to the
//     WHOLE -3..+5 retention window, so every retained slot also holds a
//     decoded screen-resolution entry;
//   * tier-2 (full size) widens from +/-1 to +/-2 via the NEW `kTierTwoRadius`;
//   * expensive-RAW STARTUP eligibility stays at +/-1 (`kExpensiveStartupRadius`).
//
// The third bullet is the one a future reader will be tempted to "simplify"
// away, because before round 2 a single constant served both meanings. Merging
// them back would put five items on the sequential RAW rung instead of three
// (~42 s cold settle instead of ~25 s at the measured 8.5 s per expensive
// settle) while looking like a faithful one-line change. TC-098 is the
// mechanical guard against exactly that, so the split is enforced by a failing
// test rather than by a comment nobody is obliged to read.
//
// Fixture note: the nine-slot tier-1 guarantee is demonstrated with a CHEAP
// (preview-bearing) fixture, and that is not a convenience. Cheap items are
// loaded across the entire retention window with no debounce, so all nine slots
// genuinely hold payloads. An EXPENSIVE item never acquires a payload beyond
// +/-1 by design, so on a no-preview RAW folder the outer slots hold neither a
// tier-1 nor a tier-2 entry. That is a real, recorded limitation of the
// shipping behaviour -- not something these tests paper over.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/cache_budget.dart';
import 'package:halcyon_flutter/services/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_source_types.dart';
import 'package:halcyon_flutter/services/photo_payload_cache.dart';
import 'package:halcyon_flutter/services/prefetch_scheduler.dart';

// A minimal valid 1x1 transparent PNG: exercises a REAL engine decode, so the
// ImageCache assertions below are about entries that actually landed rather
// than about bookkeeping.
final _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAA'
  'AAYAAjCB0C8AAAAASUVORK5CYII=',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<PhotoItem> jpgItems(int count) => List.generate(count, (index) {
    final id = 'IMG_${index.toString().padLeft(4, '0')}';
    return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
  });

  List<PhotoItem> rawItems(int count) => List.generate(count, (index) {
    final id = 'IMG_${index.toString().padLeft(4, '0')}';
    return PhotoItem(id: id, files: [File('/tmp/$id.dng')]);
  });

  DecodedRgba fakeDecoded() => DecodedRgba(
    rgba: Uint8List.fromList(List<int>.generate(2 * 2 * 4, (i) => i)),
    width: 2,
    height: 2,
  );

  ImagePreloadController cheapController() => ImagePreloadController(
    imageLoader: (path, {required purpose}) async =>
        NativeImageBytes(Uint8List.fromList(_tinyPngBytes)),
    dngDecoder: (path) async => fail('a cheap rung must never RAW-decode'),
  );

  Future<bool> tierOneResident(
    ImagePreloadController controller,
    String id, {
    required int width,
    required int height,
  }) async {
    final bytes = controller.imageBytesFor(id);
    if (bytes == null) return false;
    final key = await tierOneProviderFor(
      bytes,
      width: width,
      height: height,
    ).obtainKey(const ImageConfiguration());
    return PaintingBinding.instance.imageCache.containsKey(key);
  }

  setUp(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  // ---------------------------------------------------------------- AC2

  testWidgets('TC-095 every slot of the -3..+5 retention window holds a '
      'tier-1 entry (AC2)', (tester) async {
    await tester.runAsync(() async {
      final controller = cheapController();
      addTearDown(controller.dispose);
      controller.updateTargetSize(10, 10);

      final photos = jpgItems(14);
      const selected = 5;
      await controller.preloadImages(
        items: photos,
        selectedItemId: photos[selected].id,
        notifyLoaded: () {},
      );

      // Derived from the retention constants, never hand-written: if the
      // retention window ever moves, this test must move with it rather than
      // silently keep checking the old span.
      final first = selected - kRetentionBefore;
      final last = selected + kRetentionAfter;
      expect(last - first + 1, 9, reason: 'the window under test is nine slots');

      for (var i = first; i <= last; i++) {
        expect(
          await tierOneResident(controller, photos[i].id, width: 10, height: 10),
          isTrue,
          reason:
              'slot $i (distance ${i - selected}) is inside -3..+5 and must '
              'hold a tier-1 entry; before round 2 the span was +/-2, so '
              'slots 2, 8, 9 and 10 had no ImageCache entry at all',
        );
      }
    });
  });

  testWidgets('TC-096 an item at -3 and one at +5 keep their tier-1 entries '
      'while in-window, and lose them on leaving (AC2 killer)', (tester) async {
    await tester.runAsync(() async {
      final controller = cheapController();
      addTearDown(controller.dispose);
      controller.updateTargetSize(10, 10);

      final photos = jpgItems(20);
      await controller.preloadImages(
        items: photos,
        selectedItemId: photos[5].id,
        notifyLoaded: () {},
      );

      // The two extreme slots named by AC2's killer: -3 is index 2, +5 is
      // index 10. Both are exactly ON the boundary, which is where an
      // off-by-one in the span would show up.
      expect(
        await tierOneResident(controller, photos[2].id, width: 10, height: 10),
        isTrue,
        reason: 'the -3 boundary slot must hold a tier-1 entry',
      );
      expect(
        await tierOneResident(controller, photos[10].id, width: 10, height: 10),
        isTrue,
        reason: 'the +5 boundary slot must hold a tier-1 entry',
      );

      // Step forward one. Index 2 becomes -4: outside retention entirely, so
      // its payload AND its tier-1 entry must go. This is the other half of
      // the guarantee -- "not evicted while in-window" is only meaningful if
      // something IS evicted once out of window.
      await controller.preloadImages(
        items: photos,
        selectedItemId: photos[6].id,
        notifyLoaded: () {},
      );
      expect(
        controller.payloadFor(photos[2].id),
        isNull,
        reason: 'index 2 is now -4 and must have left the retention window',
      );
      expect(
        await tierOneResident(controller, photos[3].id, width: 10, height: 10),
        isTrue,
        reason: 'index 3 is now -3 and is still in-window',
      );
      expect(
        await tierOneResident(controller, photos[11].id, width: 10, height: 10),
        isTrue,
        reason: 'index 11 is now +5 and must have gained a tier-1 entry',
      );
    });
  });

  // ---------------------------------------------------------------- AC3

  testWidgets('TC-097 tier-2 full-size entries cover -2..+2 after the '
      'debounce settles (AC3)', (tester) async {
    await tester.runAsync(() async {
      final controller = cheapController();
      addTearDown(controller.dispose);
      controller.updateTargetSize(10, 10);

      final photos = jpgItems(14);
      const selected = 5;
      await controller.preloadImages(
        items: photos,
        selectedItemId: photos[selected].id,
        notifyLoaded: () {},
      );
      // The frozen 250 ms debounce is UNCHANGED by round 2; this waits it out
      // rather than altering it.
      await Future<void>.delayed(const Duration(milliseconds: 400));

      for (var d = -kTierTwoRadius; d <= kTierTwoRadius; d++) {
        expect(
          controller.isFullSizeReady(photos[selected + d].id),
          isTrue,
          reason:
              'distance $d is inside the tier-2 window and must hold a '
              'full-size entry; before round 2 the span was +/-1, so -2 and '
              '+2 re-decoded on every visit',
        );
      }

      // The span is +/-2, not "everything": the boundary must still bite, or
      // the test would pass just as well against an unbounded window.
      expect(
        controller.isFullSizeReady(photos[selected - kTierTwoRadius - 1].id),
        isFalse,
        reason: 'distance -3 is outside the tier-2 window',
      );
      expect(
        controller.isFullSizeReady(photos[selected + kTierTwoRadius + 1].id),
        isFalse,
        reason: 'distance +3 is outside the tier-2 window',
      );
    });
  });

  // ---------------------------------------------------------------- AC6

  test('TC-098 widening tier-2 does NOT widen expensive-RAW startup: no '
      'payload and no decode beyond +/-1 (AC6 killer)', () async {
    var decodeCalls = 0;
    final controller = ImagePreloadController(
      imageLoader: (path, {required purpose}) async =>
          const NativeImageNeedsRawDecode(exifOrientation: 1),
      dngDecoder: (path) async {
        decodeCalls++;
        return fakeDecoded();
      },
    );
    addTearDown(controller.dispose);
    controller.updateTargetSize(10, 10);

    final photos = rawItems(14);
    const selected = 5;
    await controller.preloadImages(
      items: photos,
      selectedItemId: photos[selected].id,
      notifyLoaded: () {},
    );
    // Well past the debounce, and past the time five sequential decodes would
    // need, so a widened startup radius would have been observed by now.
    await Future<void>.delayed(const Duration(milliseconds: 600));

    for (var d = -kExpensiveStartupRadius; d <= kExpensiveStartupRadius; d++) {
      expect(
        controller.payloadFor(photos[selected + d].id),
        isNotNull,
        reason: 'distance $d is inside the expensive startup radius',
      );
    }
    for (final d in [-kTierTwoRadius, kTierTwoRadius, -3, 5]) {
      expect(
        controller.payloadFor(photos[selected + d].id),
        isNull,
        reason:
            'distance $d is beyond +/-1: an EXPENSIVE item must not be '
            'started there. If this fails, kTierTwoRadius and '
            'kExpensiveStartupRadius have been merged back into one constant, '
            'which puts five items on the sequential RAW rung instead of '
            'three -- the exact regression the split exists to prevent',
      );
    }
    expect(
      decodeCalls,
      2 * kExpensiveStartupRadius + 1,
      reason:
          'exactly the +/-1 items may RAW-decode; widening the tier-2 span '
          'must not add decodes',
    );
  });

  test('TC-099 widening tier-1 creates no payloads of its own', () async {
    // The negative clause: tier-1 precache is a CONSUMER of payloads, never a
    // producer. It skips slots with no payload rather than fetching one, so
    // widening its span cannot smuggle work outside the startup rules. If this
    // inverts, the nine-slot tier-1 guarantee would be silently paying for
    // itself with RAW decodes outside +/-1.
    var loaderCalls = 0;
    final controller = ImagePreloadController(
      imageLoader: (path, {required purpose}) async {
        loaderCalls++;
        return const NativeImageNeedsRawDecode(exifOrientation: 1);
      },
      dngDecoder: (path) async => fakeDecoded(),
    );
    addTearDown(controller.dispose);
    controller.updateTargetSize(10, 10);

    final photos = rawItems(14);
    await controller.preloadImages(
      items: photos,
      selectedItemId: photos[5].id,
      notifyLoaded: () {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final callsAfterSettle = loaderCalls;

    // A second preload at the SAME position: tier-1 precache runs again over
    // all nine slots. If it produced payloads, it would call the loader again
    // for the six slots that have none.
    await controller.preloadImages(
      items: photos,
      selectedItemId: photos[5].id,
      notifyLoaded: () {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(
      loaderCalls,
      callsAfterSettle,
      reason:
          'a repeat pass over the widened tier-1 span must not fetch anything '
          'new; payload creation belongs to preloadImages and the debounced '
          'tier-2 pass alone',
    );
  });

  // ------------------------------------------------------------- AC1 pin

  test('TC-100 the two budget constants are pinned as raw byte counts', () {
    // Pinned in BYTES on purpose. The round-1 record lost time to MB-vs-MiB
    // drift, and 768 decimal MB (768,000,000) or 224 decimal MB (224,000,000)
    // would both still read as "768"/"224" in a review.
    expect(kImageCacheCeilingBytes, 805306368, reason: '768 MiB exactly');
    expect(kPayloadByteBudget, 234881024, reason: '224 MiB exactly');
    // The two are sized against OPPOSITE corpora -- the cache figure by the
    // cheap mix (two entries per item, full-size decode), the payload figure by
    // the expensive mix (window-resolution RGBA retained per slot). Neither can
    // sanity-check the other, so both are asserted independently.
    expect(kImageCacheCeilingBytes, 768 * 1024 * 1024);
    expect(kPayloadByteBudget, 224 * 1024 * 1024);
  });
}
