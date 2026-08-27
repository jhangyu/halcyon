// Precache-span guarantees (AC2, AC3) and the SERIAL LANE law (TC-098a..d).
//
// The spans under test:
//   * tier-1 (screen resolution) precache covers the WHOLE -3..+5 retention
//     window, so every retained slot also holds a decoded screen-resolution
//     entry;
//   * tier-2 (full size) covers -1..+3 via `kTierTwoBefore`/`kTierTwoAfter`,
//     behind the frozen 250ms navigation debounce. Forward-biased for the
//     same reason retention is (-3..+5): browsing is overwhelmingly forwards.
//
// What changed on 2026-08-26 (user ruling; contract at
// docs/logs/2026-08-26/serial-lane-unification-contract.md): the +/-1
// "expensive startup radius" is GONE. An expensive (no-preview RAW) item is
// eligible in exactly the same slots as a cheap one; the only difference left
// is the concurrency mode of payload production -- cheap in parallel, expensive
// one at a time on the shared serial lane, near-to-far from the selection.
// TC-098 used to be the mechanical guard for the opposite claim ("no payload
// and no decode beyond +/-1"); it is replaced below by TC-098a..d, which pin
// the four properties of the new law: full-window fill, single flight, start
// order, and mid-queue reprioritisation.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/cache_budget.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload_cache.dart';
import 'package:halcyon_flutter/services/image_pipeline/prefetch_scheduler.dart';

// A minimal valid 1x1 transparent PNG: exercises a REAL engine decode, so the
// ImageCache assertions below are about entries that actually landed rather
// than about bookkeeping.
final _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAA'
  'AAYAAjCB0C8AAAAASUVORK5CYII=',
);

/// Polls [condition] to a deadline. The serial lane hands work to the event
/// loop, so "how long the whole window takes" is a sum of decodes rather than a
/// single await -- a fixed sleep would either be flaky or slow.
Future<void> _until(bool Function() condition, {String? reason}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for: ${reason ?? 'condition'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Whether every slot of the -3..+5 retention window around [selected] holds a
/// payload. Derived from the retention constants, never hand-written.
bool controllerWindowFilled(
  ImagePreloadController controller,
  List<PhotoItem> items,
  int selected,
) {
  for (var d = -kRetentionBefore; d <= kRetentionAfter; d++) {
    final index = selected + d;
    if (index < 0 || index >= items.length) continue;
    if (controller.payloadFor(items[index].id) == null) return false;
  }
  return true;
}

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

  testWidgets('TC-097 tier-2 full-size entries cover -1..+3 after the '
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
      // The frozen 250 ms debounce is UNCHANGED by the forward-bias change;
      // this waits it out rather than altering it.
      await Future<void>.delayed(const Duration(milliseconds: 400));

      for (var d = -kTierTwoBefore; d <= kTierTwoAfter; d++) {
        expect(
          controller.isFullSizeReady(photos[selected + d].id),
          isTrue,
          reason:
              'distance $d is inside the tier-2 window and must hold a '
              'full-size entry; the window is forward-biased -1..+3 so that '
              'the next forward step lands on a ready entry instead of a '
              'catch-up decode',
        );
      }

      // The span is -1..+3, not "everything": both boundaries must still
      // bite, or the test would pass just as well against an unbounded
      // window. -2 is the slot the forward bias GAVE UP; +4 is the slot it
      // still does not reach.
      expect(
        controller.isFullSizeReady(photos[selected - kTierTwoBefore - 1].id),
        isFalse,
        reason: 'distance -2 is outside the forward-biased tier-2 window',
      );
      expect(
        controller.isFullSizeReady(photos[selected + kTierTwoAfter + 1].id),
        isFalse,
        reason: 'distance +4 is outside the tier-2 window',
      );
    });
  });

  // ---------------------------------------------------------------- AC6

  // TC-098 (the old "+/-1 startup radius" killer) is retired: the radius it
  // guarded was struck out by the 2026-08-26 user ruling. TC-098a..d below
  // pin the law that replaced it.

  test('TC-098a an all-expensive folder fills the WHOLE -3..+5 payload '
      'window, not just +/-1 (criterion 2)', () async {
    final decodeCalls = <String>[];
    final controller = ImagePreloadController(
      imageLoader: (path, {required purpose}) async =>
          const NativeImageNeedsRawDecode(exifOrientation: 1),
      dngDecoder: (path) async {
        decodeCalls.add(path);
        await Future<void>.delayed(const Duration(milliseconds: 5));
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
    await _until(
      () => List.generate(
        kRetentionBefore + kRetentionAfter + 1,
        (i) => photos[selected - kRetentionBefore + i].id,
      ).every((id) => controller.payloadFor(id) != null),
      reason: 'every slot of the retention window to acquire a payload',
    );

    for (var d = -kRetentionBefore; d <= kRetentionAfter; d++) {
      expect(
        controller.payloadFor(photos[selected + d].id),
        isNotNull,
        reason:
            'distance $d is inside -3..+5, so an EXPENSIVE item must acquire '
            'a payload there exactly as a cheap one does. Before the '
            '2026-08-26 ruling only -1..+1 ever did, which is why stepping +1 '
            'then +2 in an all-RAW folder always stalled',
      );
    }
    expect(
      decodeCalls.toSet(),
      hasLength(kRetentionBefore + kRetentionAfter + 1),
      reason: 'one decode per window slot, and no slot decoded twice',
    );
  });

  test('TC-098b at most ONE expensive decode is ever in flight, while cheap '
      'window loads still issue in parallel (criterion 3)', () async {
    var inFlight = 0;
    var maxInFlight = 0;
    final expensive = ImagePreloadController(
      imageLoader: (path, {required purpose}) async =>
          const NativeImageNeedsRawDecode(exifOrientation: 1),
      dngDecoder: (path) async {
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        inFlight--;
        return fakeDecoded();
      },
    );
    addTearDown(expensive.dispose);
    expensive.updateTargetSize(10, 10);
    final raws = rawItems(14);
    await expensive.preloadImages(
      items: raws,
      selectedItemId: raws[5].id,
      notifyLoaded: () {},
    );
    await _until(
      () => controllerWindowFilled(expensive, raws, 5),
      reason: 'the whole expensive window to land',
    );
    expect(
      maxInFlight,
      1,
      reason:
          'a RAW decode saturates cores; nine of them in parallel is exactly '
          'what the serial lane exists to prevent',
    );

    // The cheap half of the same claim: parallelism is retained for items
    // that do not need a decode at all.
    var cheapInFlight = 0;
    var cheapMaxInFlight = 0;
    final cheap = ImagePreloadController(
      imageLoader: (path, {required purpose}) async {
        cheapInFlight++;
        if (cheapInFlight > cheapMaxInFlight) {
          cheapMaxInFlight = cheapInFlight;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
        cheapInFlight--;
        return NativeImageBytes(Uint8List.fromList(_tinyPngBytes));
      },
    );
    addTearDown(cheap.dispose);
    cheap.updateTargetSize(10, 10);
    final jpgs = jpgItems(14);
    await cheap.preloadImages(
      items: jpgs,
      selectedItemId: jpgs[5].id,
      notifyLoaded: () {},
    );
    // The window pass runs 8 items in parallel (9 minus the selected item
    // which was loaded as a priority load and is a cache hit on the second
    // pass). With a 10ms delay in the loader, all 8 should be in flight
    // concurrently. This exact bound catches a regression from full
    // parallelism to partial (e.g. accidental serial batching).
    expect(
      cheapMaxInFlight,
      equals(8),
      reason:
          'cheap payload acquisition across -3..+5 must overlap fully: all 8 '
          'non-selected window items should be in flight concurrently; the '
          'ruling changed the expensive lane only',
    );
  });

  test('TC-098c fresh settle decode START order is 0, +1, -1, +2, -2, +3, '
      '-3, +4, +5 (criterion 4)', () async {
    final starts = <String>[];
    final controller = ImagePreloadController(
      imageLoader: (path, {required purpose}) async =>
          const NativeImageNeedsRawDecode(exifOrientation: 1),
      dngDecoder: (path) async {
        starts.add(path);
        await Future<void>.delayed(const Duration(milliseconds: 10));
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
    await _until(
      () => controllerWindowFilled(controller, photos, selected),
      reason: 'the whole expensive window to land',
    );

    // The user-ruled order, written as signed distances so the intent is
    // legible: nearest first, forward before backward at equal distance
    // (browsing is overwhelmingly forwards, the same asymmetry -3..+5 has).
    const ruledOrder = [0, 1, -1, 2, -2, 3, -3, 4, 5];
    expect(
      starts,
      [for (final d in ruledOrder) photos[selected + d].files.single.path],
      reason:
          'the serial lane must start decodes near-to-far from the selection; '
          'any other order means the item the user is looking at can be stuck '
          'behind one they are not',
    );
  });

  test('TC-098d navigating mid-queue reprioritises the lane: no decode starts '
      'outside the new window, and the next one is its nearest missing item '
      '(criterion 5)', () async {
    final starts = <String>[];
    final gates = <Completer<void>>[];
    final controller = ImagePreloadController(
      imageLoader: (path, {required purpose}) async =>
          const NativeImageNeedsRawDecode(exifOrientation: 1),
      dngDecoder: (path) async {
        starts.add(path);
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future;
        return fakeDecoded();
      },
    );
    addTearDown(controller.dispose);
    controller.updateTargetSize(10, 10);

    final photos = rawItems(30);
    await controller.preloadImages(
      items: photos,
      selectedItemId: photos[5].id,
      notifyLoaded: () {},
    );
    // The first decode (index 5) is parked on its gate, so the other eight
    // window items are queued behind it and nothing else has started.
    await _until(() => starts.length == 1, reason: 'the first decode to start');
    expect(starts.single, photos[5].files.single.path);

    // The user jumps to index 20. Its retention window (17..25) is disjoint
    // from the queue built for index 5 (2..10).
    await controller.preloadImages(
      items: photos,
      selectedItemId: photos[20].id,
      notifyLoaded: () {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      starts,
      hasLength(1),
      reason: 'the parked decode still holds the lane; nothing may overtake it',
    );

    // Release the in-flight decode. What runs NEXT is the load-bearing claim.
    gates.single.complete();
    await _until(() => starts.length == 2, reason: 'the next decode to start');
    expect(
      starts[1],
      photos[20].files.single.path,
      reason:
          'the next decode after the in-flight one is the NEW selection, not '
          'the +1 item of the window the user has left',
    );

    // Drain enough of the new window to prove the stale entries never decode.
    for (var i = 0; i < 6; i++) {
      await _until(
        () => gates.length == starts.length,
        reason: 'the running decode to reach its gate',
      );
      gates.last.complete();
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final stale = photos
        .sublist(2, 11)
        .map((item) => item.files.single.path)
        .toSet();
    expect(
      starts.skip(1).where(stale.contains),
      isEmpty,
      reason:
          'not one item of the abandoned window may start a decode after the '
          'navigation: they are outside the retention window, and the lane '
          'body re-checks that when its turn comes',
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
