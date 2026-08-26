// M5 dual-window RAW full-resolution tier-2 tests.
//
// Contract: docs/logs/2026-08-24/m5-dual-window-design.md, AC-M5-2..6, AC-M5-9.
// Test names below are byte-exact per the frozen team contract; do not rename.
//
// Interface freeze this file builds against (do not invent beyond it):
//   * ImagePreloadController.debugTierTwoKeyIds (@visibleForTesting Set<String>)
//     -- the ids that currently hold a resident tier-2 ImageCache entry.
//   * PhotoSource's SourceOutcome carries a nullable `fullRes` record, produced
//     ONLY by the same FFI decode that produced the payload (piggyback,
//     design Sec 2.2) -- exercised indirectly here via decoder-call counting,
//     since this file owns no photo_source.dart internals.
//   * RawFullResImage (lib/services/raw_full_res_image.dart), keyed on
//     identical(payloadIdentity) + width + height, never holds a retained
//     buffer (AC-M5-9).
//
// A pixel-backed (expensive/RAW) item only ever gets a payload within
// +/-kExpensiveStartupRadius (1) of SOME selection it has passed through
// (AD-018, unaffected by M5). To observe the full +/-kTierTwoRadius (2) band
// populated for a pixel payload, the pixel sub-case below walks the selection
// through neighbouring positions before settling, exactly as
// image_preload_controller_probe_first_navigation_test.dart's P2/P4 do -- this is not a workaround, it
// is what "for pixel payloads alike" actually requires given AD-018.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/prefetch_scheduler.dart';
import 'package:halcyon_flutter/services/image_pipeline/raw_full_res_image.dart';

// A 1x1 image used only to satisfy RawFullResImage's constructor for the
// PROBE key built in M5-DW2 -- see the comment at that test. The probe's
// image is never actually delivered: resolving the probe hits the REAL
// already-resident tier-2 entry (same key by identity+dimensions), and this
// placeholder is disposed unused once that happens.
Future<ui.Image> _decodeTinyImage() {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    Uint8List.fromList([0, 0, 0, 0]),
    1,
    1,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

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

  Future<bool> tierOneResident(
    ImagePreloadController controller,
    String id, {
    required int width,
    required int height,
  }) async {
    final bytes = controller.imageBytesFor(id);
    if (bytes != null) {
      final key = await tierOneProviderFor(
        bytes,
        width: width,
        height: height,
      ).obtainKey(const ImageConfiguration());
      return PaintingBinding.instance.imageCache.containsKey(key);
    }
    // Pixel-backed items share their tier-1 entry with RawPixelsImage, keyed
    // on the retained buffer's identity (invariant I1) -- there is no
    // separate encoded-bytes key to build for that kind.
    final provider = controller.pixelsProviderFor(id);
    if (provider == null) return false;
    final key = await provider.obtainKey(const ImageConfiguration());
    return PaintingBinding.instance.imageCache.containsKey(key);
  }

  Future<void> until(bool Function() condition, {String? reason}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out waiting for: ${reason ?? 'condition'}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  setUp(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  // ------------------------------------------------------------- AC-M5-2

  test(
    'M5-DW1 tier-2 keys equal the +/-2 band after settle, for encoded and '
    'pixel payloads alike',
    () async {
      // --- cheap (encoded) sub-case: whole window is populated in one pass.
      final cheap = ImagePreloadController(
        imageLoader: (path, {required purpose}) async =>
            NativeImageBytes(Uint8List.fromList(_tinyPngBytes)),
        dngDecoder: (path) async => fail('a cheap rung must never RAW-decode'),
      );
      addTearDown(cheap.dispose);
      cheap.updateTargetSize(10, 10);
      final cheapItems = jpgItems(14);
      const cheapSelected = 5;
      await cheap.preloadImages(
        items: cheapItems,
        selectedItemId: cheapItems[cheapSelected].id,
        notifyLoaded: () {},
      );
      await until(
        () => cheap.debugTierTwoKeyIds.length == 2 * kTierTwoRadius + 1,
        reason: 'cheap tier-2 band to settle to +/-2',
      );

      final cheapExpectedBand = <String>{
        for (var d = -kTierTwoRadius; d <= kTierTwoRadius; d++)
          cheapItems[cheapSelected + d].id,
      };
      expect(
        cheap.debugTierTwoKeyIds.toSet(),
        cheapExpectedBand,
        reason:
            'encoded payloads: the tier-2 key id set must equal exactly the '
            '+/-2 band after settle',
      );
      for (final d in [-3, 3, 4, 5]) {
        final id = cheapItems[cheapSelected + d].id;
        expect(
          await tierOneResident(cheap, id, width: 10, height: 10),
          isTrue,
          reason: 'distance $d (encoded) must still hold a tier-1 entry',
        );
        expect(
          cheap.debugTierTwoKeyIds.contains(id),
          isFalse,
          reason: 'distance $d (encoded) must NOT hold a tier-2 entry',
        );
      }

      // --- pixel (expensive/RAW) sub-case: walk through neighbouring
      // selections first so every id in -2..+2 has, at some point, been
      // within +/-kExpensiveStartupRadius of a selection and therefore
      // acquired a payload (AD-018) -- then settle on the middle position.
      // --- core claim: the +/-2 band, once every id in it has passed
      // through its own +/-kExpensiveStartupRadius window at some point,
      // ends up with EXACTLY that band in debugTierTwoKeyIds.
      //
      // Retention (-3..+5, width 9) and the target band (-2..+2, width 5)
      // are close enough in width that this walk can hold every band id's
      // payload alive simultaneously through to the final settle: 5 seeds
      // 4/5/6, 7 seeds 6/7/8 (retention range [4,12] keeps 4 alive too), 3
      // seeds 2/3/4 (retention range [0,8] keeps everything from the first
      // two stops alive), and the final settle at 5 re-widens retention to
      // [2,10] -- a superset of everything acquired -- while its own
      // tier-2 window [3,7] triggers the catch-up upgrade for every band id
      // that does not already carry a live tier-2 entry.
      ImagePreloadController buildPixelController() => ImagePreloadController(
        imageLoader: (path, {required purpose}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        dngDecoder: (path) async => fakeDecoded(),
      );

      final pixel = buildPixelController();
      addTearDown(pixel.dispose);
      pixel.updateTargetSize(10, 10);
      final pixelItems = rawItems(14);
      const pixelSelected = 5;

      for (final idx in [5, 7, 3, 5]) {
        await pixel.preloadImages(
          items: pixelItems,
          selectedItemId: pixelItems[idx].id,
          notifyLoaded: () {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      await until(
        () => pixel.debugTierTwoKeyIds.length == 2 * kTierTwoRadius + 1,
        reason: 'pixel tier-2 band to settle to +/-2 after the walk',
      );

      final pixelExpectedBand = <String>{
        for (var d = -kTierTwoRadius; d <= kTierTwoRadius; d++)
          pixelItems[pixelSelected + d].id,
      };
      expect(
        pixel.debugTierTwoKeyIds.toSet(),
        pixelExpectedBand,
        reason:
            'pixel payloads: the tier-2 key id set must equal exactly the '
            '+/-2 band after settle, same as encoded payloads',
      );

      // --- boundary claim: -3, +3, +4, +5 have a tier-1 entry (once a
      // payload was ever produced for them) and NEVER a tier-2 entry.
      //
      // Each boundary is checked with its OWN short walk rather than inside
      // the combined walk above: retention (width 9) and the full -3..+5
      // span (also width 9) coincide only exactly AT the final selection, so
      // any walk that swings out to acquire one extreme's payload evicts the
      // other extreme's payload before the final settle -- a structural
      // consequence of the frozen retention/tier-2 window sizes, not a test
      // artefact. Isolating each boundary sidesteps that without weakening
      // what is actually asserted per position.
      //
      // distance -3 is free: item at pixelSelected-3 (index 2) already
      // received a payload from the "3" stop of the walk above and survives
      // into the final retention window [2,10], but loses its tier-2 entry
      // because distance 3 is outside the tier-2 window [3,7].
      final minus3Id = pixelItems[pixelSelected - 3].id;
      expect(
        await tierOneResident(pixel, minus3Id, width: 10, height: 10),
        isTrue,
        reason: 'distance -3 (pixel) must still hold a tier-1 entry',
      );
      expect(
        pixel.debugTierTwoKeyIds.contains(minus3Id),
        isFalse,
        reason: 'distance -3 (pixel) must NOT hold a tier-2 entry',
      );

      for (final d in [3, 4, 5]) {
        final boundary = buildPixelController();
        addTearDown(boundary.dispose);
        boundary.updateTargetSize(10, 10);
        final boundaryItems = rawItems(14);
        final targetIndex = pixelSelected + d;

        // Seed the boundary id's payload by selecting it directly (distance
        // 0 to itself), then settle on the real selection: retention [2,10]
        // keeps the payload (distance d <= 5), but the tier-2 window [3,7]
        // does not include it, so its tier-2 entry is evicted.
        await boundary.preloadImages(
          items: boundaryItems,
          selectedItemId: boundaryItems[targetIndex].id,
          notifyLoaded: () {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await boundary.preloadImages(
          items: boundaryItems,
          selectedItemId: boundaryItems[pixelSelected].id,
          notifyLoaded: () {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 400));

        final id = boundaryItems[targetIndex].id;
        expect(
          await tierOneResident(boundary, id, width: 10, height: 10),
          isTrue,
          reason: 'distance $d (pixel) must still hold a tier-1 entry',
        );
        expect(
          boundary.debugTierTwoKeyIds.contains(id),
          isFalse,
          reason: 'distance $d (pixel) must NOT hold a tier-2 entry',
        );
      }
    },
  );

  // ------------------------------------------------------------- AC-M5-3

  test(
    'M5-DW2 a pixel-backed item at distance 0 gets a FULL-resolution tier-2 '
    'entry distinct from its window-resolution tier-1 entry',
    () async {
      final controller = ImagePreloadController(
        imageLoader: (path, {required purpose}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        dngDecoder: (path) async => DecodedRgba(
          rgba: Uint8List.fromList(
            List<int>.generate(400 * 300 * 4, (i) => i % 256),
          ),
          width: 400,
          height: 300,
        ),
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(200, 150);
      final items = rawItems(14);
      await controller.preloadImages(
        items: items,
        selectedItemId: items[5].id,
        notifyLoaded: () {},
      );
      await until(
        () => controller.isFullSizeReady(items[5].id),
        reason: 'distance-0 pixel item to gain a full-size tier-2 entry',
      );
      expect(controller.isFullSizeReady(items[5].id), isTrue);
      expect(controller.debugTierTwoKeyIds.contains(items[5].id), isTrue);

      final payload = controller.payloadFor(items[5].id);
      expect(payload, isA<PixelPayload>());

      // No frozen accessor exposes the resolved tier-2 image or its key
      // object directly, so this reconstructs a PROBE RawFullResImage from
      // the same identity + dimensions the controller must have used
      // (payloadIdentity=payload, 400x300 -- the fake decoder's fixed
      // output). RawFullResImage's operator== is identical(payloadIdentity)
      // + width + height only (raw_full_res_image.dart, frozen), so this
      // probe's key is EQUAL to the controller's real tier-2 key without
      // needing to see it: resolving it hits the ALREADY-RESIDENT ImageCache
      // entry rather than decoding anything new, letting the actual
      // dimensions be read back.
      final dummyImage = await _decodeTinyImage();
      final probe = RawFullResImage(
        payloadIdentity: payload!,
        width: 400,
        height: 300,
        image: dummyImage,
      );
      final probeCompleter = Completer<ImageInfo>();
      late ImageStreamListener probeListener;
      final probeStream = probe.resolve(const ImageConfiguration());
      probeListener = ImageStreamListener((image, synchronousCall) {
        probeStream.removeListener(probeListener);
        probeCompleter.complete(image);
      }, onError: (error, stackTrace) => probeCompleter.completeError(error));
      probeStream.addListener(probeListener);
      final tierTwoInfo = await probeCompleter.future;
      addTearDown(() => dummyImage.dispose());
      expect(
        (tierTwoInfo.image.width, tierTwoInfo.image.height),
        (400, 300),
        reason:
            'the resolved tier-2 entry must be the FULL 400x300 decode, not '
            'a window-resolution one',
      );

      final tierOneProvider = controller.pixelsProviderFor(items[5].id)!;
      final tierOneCompleter = Completer<ImageInfo>();
      late ImageStreamListener tierOneListener;
      final tierOneStream = tierOneProvider.resolve(const ImageConfiguration());
      tierOneListener = ImageStreamListener((image, synchronousCall) {
        tierOneStream.removeListener(tierOneListener);
        tierOneCompleter.complete(image);
      }, onError: (error, stackTrace) => tierOneCompleter.completeError(error));
      tierOneStream.addListener(tierOneListener);
      final tierOneInfo = await tierOneCompleter.future;
      expect(
        (tierOneInfo.image.width, tierOneInfo.image.height),
        (200, 150),
        reason:
            'the tier-1 entry must stay at the WINDOW target size (200x150), '
            'distinct from the full-resolution tier-2 entry',
      );

      final tierOneKey = await tierOneProvider.obtainKey(
        const ImageConfiguration(),
      );
      final tierTwoKey = await probe.obtainKey(const ImageConfiguration());
      expect(
        tierOneKey.runtimeType,
        isNot(tierTwoKey.runtimeType),
        reason: 'the tier-1 and tier-2 ImageCache keys must be distinct '
            '(different provider kinds -> unequal by construction)',
      );
    },
  );

  // ------------------------------------------------------------- AC-M5-4

  test(
    'M5-DW3 payload production and full-res tier-2 for a RAW item inside '
    '+/-1 cost exactly ONE decoder call',
    () async {
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
      controller.updateTargetSize(10, 10);
      final items = rawItems(14);
      final target = items[5].files.single.path;

      await controller.preloadImages(
        items: items,
        selectedItemId: items[5].id,
        notifyLoaded: () {},
      );
      await until(
        () => controller.isFullSizeReady(items[5].id),
        reason: 'distance-0 pixel item to gain a full-size tier-2 entry',
      );
      expect(
        decodeCalls.where((p) => p == target).length,
        1,
        reason:
            'single-decode dual-output (piggyback): payload production and '
            'the full-res tier-2 upload must share ONE FFI decode call',
      );
    },
  );

  // ------------------------------------------------------------- AC-M5-5

  test(
    'M5-DW4 leaving +/-2 evicts the full-res entry; re-entering re-upgrades '
    'with exactly one extra decoder call and an identical retained payload',
    () async {
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
      controller.updateTargetSize(10, 10);
      final items = rawItems(20);
      final target = items[8].files.single.path;
      int targetCalls() => decodeCalls.where((p) => p == target).length;

      await controller.preloadImages(
        items: items,
        selectedItemId: items[8].id,
        notifyLoaded: () {},
      );
      await until(() => controller.isFullSizeReady(items[8].id));
      expect(targetCalls(), 1);
      final firstPayload = controller.payloadFor(items[8].id);
      expect(firstPayload, isNotNull);

      // Distance 3 from item 8: outside the +/-2 tier-2 window but still
      // inside the -3..+5 retention window, so the payload survives while
      // the tier-2 entry must be evicted.
      await controller.preloadImages(
        items: items,
        selectedItemId: items[11].id,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
        controller.debugTierTwoKeyIds.contains(items[8].id),
        isFalse,
        reason: 'containsKey == false: the full-res entry is gone once '
            'outside +/-2',
      );
      expect(
        controller.payloadFor(items[8].id),
        isNotNull,
        reason: 'the payload itself is still retained (distance 3 <= 5)',
      );

      // Re-enter distance 2: the catch-up upgrade path must re-decode ONCE
      // more (payload already exists, only the full-res entry is missing).
      await controller.preloadImages(
        items: items,
        selectedItemId: items[10].id,
        notifyLoaded: () {},
      );
      await until(() => controller.isFullSizeReady(items[8].id));
      expect(
        targetCalls(),
        2,
        reason: 'exactly one extra decoder call for the re-upgrade',
      );
      expect(
        identical(controller.payloadFor(items[8].id), firstPayload),
        isTrue,
        reason: 'the retained payload object is unchanged by the re-upgrade',
      );
    },
  );

  // ------------------------------------------------------------- AC-M5-6

  test(
    'M5-DW5 a failing full-res decode keeps tier-1 display, writes NO '
    'permanent miss, and is not retried for the same payload',
    () async {
      final decodeCalls = <String>[];
      final items = rawItems(20);
      final target = items[8].files.single.path;
      final perPathCalls = <String, int>{};
      final controller = ImagePreloadController(
        imageLoader: (path, {required purpose}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        dngDecoder: (path) async {
          decodeCalls.add(path);
          final n = (perPathCalls[path] ?? 0) + 1;
          perPathCalls[path] = n;
          // Every item decodes fine EXCEPT the target's SECOND-and-later
          // attempt: its first (piggyback) call must still succeed, so the
          // failure under test is specifically the catch-up re-upgrade, not
          // payload production.
          if (path == target && n > 1) {
            throw StateError('simulated full-res decode failure');
          }
          return fakeDecoded();
        },
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(10, 10);
      int targetCalls() => decodeCalls.where((p) => p == target).length;

      await controller.preloadImages(
        items: items,
        selectedItemId: items[8].id,
        notifyLoaded: () {},
      );
      await until(() => controller.isFullSizeReady(items[8].id));
      expect(targetCalls(), 1);

      // Distance 3: evicts the full-res entry, retains the payload.
      await controller.preloadImages(
        items: items,
        selectedItemId: items[11].id,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(controller.payloadFor(items[8].id), isNotNull);

      // Re-enter distance 2: the catch-up decode runs and THROWS.
      await controller.preloadImages(
        items: items,
        selectedItemId: items[10].id,
        notifyLoaded: () {},
      );
      await until(
        () => targetCalls() == 2,
        reason: 'the failing catch-up attempt to run',
      );
      // Give the failed attempt's bookkeeping a moment to settle before
      // asserting the negative (no tier-2, no permanent miss).
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        controller.hasFailed(items[8].id),
        isFalse,
        reason: 'a full-res-only failure must NOT become a permanent miss: '
            'payload production already succeeded, so the item is still '
            'fully displayable at tier-1',
      );
      expect(
        controller.isFullSizeReady(items[8].id),
        isFalse,
        reason: 'no tier-2 entry after the failed upgrade; tier-1 display '
            'is retained instead',
      );

      // Two further debounce triggers while still in-window: must NOT retry
      // the failing decode for the same (unchanged) payload.
      await controller.preloadImages(
        items: items,
        selectedItemId: items[9].id,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await controller.preloadImages(
        items: items,
        selectedItemId: items[10].id,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
        targetCalls(),
        2,
        reason:
            'the failing full-res attempt count must stay at 1 (2 total: '
            '1 successful piggyback + 1 failing catch-up) after two more '
            'debounce settles for the same payload',
      );
    },
  );

  // ------------------------------------------------------------- AC-M5-9

  test('M5-DW6 a full-res upgrade adds ZERO bytes to the payload cache', () async {
    final controller = ImagePreloadController(
      imageLoader: (path, {required purpose}) async =>
          const NativeImageNeedsRawDecode(exifOrientation: 1),
      dngDecoder: (path) async => fakeDecoded(),
    );
    addTearDown(controller.dispose);
    controller.updateTargetSize(10, 10);
    final items = rawItems(14);

    final beforeDecode = controller.retainedByteCost;
    expect(
      beforeDecode,
      0,
      reason: 'nothing decoded yet; the load-bearing comparison is the '
          'AFTER check below',
    );

    await controller.preloadImages(
      items: items,
      selectedItemId: items[5].id,
      notifyLoaded: () {},
    );
    await until(() => controller.isFullSizeReady(items[5].id));

    // The +/-kExpensiveStartupRadius band (4, 5, 6) is the only one that can
    // hold a payload at this point (AD-018). retainedByteCost must equal
    // EXACTLY the sum of those payloads' own byteCost -- if the full-res
    // upgrade added its ~payload-sized buffer to the payload cache instead of
    // going straight to the ImageCache-owned ui.Image, this sum would be
    // short of the real total.
    var expectedTotal = 0;
    for (final i in [4, 5, 6]) {
      final payload = controller.payloadFor(items[i].id);
      expect(payload, isNotNull, reason: 'distance <=1 items must have a '
          'retained payload');
      expectedTotal += payload!.byteCost;
    }
    expect(
      controller.retainedByteCost,
      expectedTotal,
      reason:
          'the full-res tier-2 upgrade must add ZERO bytes to the payload '
          'cache (AC-M5-9): retainedByteCost accounts only for '
          'PixelPayload.byteCost, never for the full-resolution ImageCache '
          'entry',
    );
  });
}
