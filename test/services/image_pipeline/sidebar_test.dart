import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/decode_lane.dart';
import 'package:halcyon_flutter/services/image_pipeline/decoded_rgba_image_provider.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/jpeg_encoder.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/raw_pixels_image.dart';
import 'package:halcyon_flutter/services/image_pipeline/sidebar_thumbnail_codec.dart';
import 'package:halcyon_flutter/services/image_pipeline/thumbnail_derivation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/preload_fixtures.dart';

/// Task 7 (plan `docs/logs/2026-08-30/shared-payload-cache-plan.md`):
/// "scrolling fills the payload cache" (D5 decision 4). A visible row with no
/// payload asks the SHARED lane to make one, at the sidebar's own low
/// priority -- so the second, unthrottled decoder the old sidebar owned (F5's
/// `laneWidth + 1` overshoot) is gone.
///
/// Helpers are copied rather than imported from the Task 6 file: test files do
/// not export to one another.
Future<NativeImageResult> _rawLoaderLane(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

// Alpha must be opaque (0xFF): decoded_rgba_image_provider.dart's
// debug-only identity short-circuit asserts sampled alpha is opaque.
// Same repair as commits 253b89f / d43c2a1.
DecodedRgba _tinyLane() {
  final rgba = Uint8List(8 * 8 * 4);
  for (var i = 3; i < rgba.length; i += 4) {
    rgba[i] = 0xFF;
  }
  return DecodedRgba(rgba: rgba, width: 8, height: 8);
}

/// Polls [cond] until it is true or [timeout] elapses, whichever is first --
/// a real debounce/async-drain still gets its full budget if it needs it, but
/// the common case (condition already true) returns almost immediately
/// instead of paying a fixed sleep every time.
Future<void> _pollUntilLane(
  bool Function() cond,
  Duration timeout, {
  Duration step = const Duration(milliseconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(step);
  }
}

/// Task 6 (plan `docs/logs/2026-08-30/shared-payload-cache-plan.md`): the
/// sidebar is a CONSUMER of the shared q70 payload, never a second producer of
/// pixels. Every test here asserts the consumer property from the outside --
/// through the decoder call count -- rather than through the sweep's internals.
class CountingDecoder {
  final List<String> paths = <String>[];
  int get calls => paths.length;
  int callsFor(String id) => paths.where((p) => p.endsWith('/$id.arw')).length;
  Future<DecodedRgba> call(String path) async {
    paths.add(path);
    // Alpha must be opaque (0xFF): decoded_rgba_image_provider.dart's
    // debug-only identity short-circuit asserts sampled alpha is opaque.
    // Same repair as commits 253b89f / d43c2a1.
    final rgba = Uint8List(8 * 8 * 4);
    for (var i = 3; i < rgba.length; i += 4) {
      rgba[i] = 0xFF;
    }
    return DecodedRgba(rgba: rgba, width: 8, height: 8);
  }
}

Future<NativeImageResult> _rawLoaderShared(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

Future<void> _settleShared([int ms = 400]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// A loader that never produces bytes for the SIDEBAR purpose, so every item
/// falls to the sidebar's own RAW-decode branch -- the preview-less RAW case.
/// For the PREVIEW purpose it signals "needs a RAW decode" instead of a flat
/// failure: `AppState.selectItem`'s `_preloadImages()` fires a preview load
/// for the same id as an unrelated side effect of `loadFolder`, and a flat
/// `NativeImageFailure` there would land in the PREVIEW permanent-miss set
/// (read by `hasFailed`) regardless of how the sidebar sweep behaves --
/// confounding this file's assertions with a failure they do not exercise.
Future<NativeImageResult> _alwaysFailLoaderPixel(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async {
  if (purpose == ImageRequestPurpose.preview) {
    return const NativeImageNeedsRawDecode(exifOrientation: 1);
  }
  return const NativeImageFailure('NO_THUMBNAIL', 'no thumbnail for test');
}

DecodedRgba _rawFixturePixel({int width = 400, int height = 300}) {
  final bytes = Uint8List(width * height * 4);
  for (var i = 3; i < bytes.length; i += 4) {
    bytes[i] = 255; // opaque
  }
  return DecodedRgba(rgba: bytes, width: width, height: height);
}

Future<Directory> _tempDirWithPixel(List<String> names) async {
  final dir = await Directory.systemTemp.createTemp('halcyon_sidebar_pixels_');
  for (final name in names) {
    await File(p.join(dir.path, name)).writeAsBytes([1, 2, 3]);
  }
  return dir;
}

/// TC-374's temp-dir teardown (errno-32 on Windows): each test already gets
/// its OWN uniquely-suffixed dir from `createTemp`, so this is not a shared
/// path -- but a transient handle (AV scanner, a still-draining async decode
/// holding the file open a beat longer under load) can still make a single
/// `delete(recursive: true)` fail. Retry a few times with a short backoff and
/// only then give up, so cleanup never fails the test itself.
Future<void> _deleteDirTolerant(Directory dir) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      return;
    } on FileSystemException {
      if (attempt == 4) return; // best-effort cleanup, not a test assertion
      await Future<void>.delayed(Duration(milliseconds: 50 * (attempt + 1)));
    }
  }
}

/// Polls [cond] until it is true or [timeout] elapses, whichever is first --
/// a real debounce/async-drain still gets its full budget if it needs it, but
/// the common case (condition already true) returns almost immediately
/// instead of paying a fixed sleep every time.
Future<void> _pollUntilPixel(
  bool Function() cond,
  Duration timeout, {
  Duration step = const Duration(milliseconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(step);
  }
}

/// Contract `docs/logs/2026-09-06/sidebar-fix-and-async-plan-contract.md` D1:
/// AC1 (visible-before-margin) and AC2 (priority-freeze fix).
///
/// Both tests gate the decoder so lane entries stay PENDING after the sweep's
/// 100ms debounce fires, letting [ImagePreloadController.debugLanePendingPriorityFor]
/// observe the priority DecodeLane actually queued each key at.
Future<NativeImageResult> _rawLoaderPriority(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

DecodedRgba _tinyPriority() {
  final rgba = Uint8List(8 * 8 * 4);
  for (var i = 3; i < rgba.length; i += 4) {
    rgba[i] = 0xFF;
  }
  return DecodedRgba(rgba: rgba, width: 8, height: 8);
}

Future<Uint8List> _encodedOfDerivation(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF3366AA),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<({int width, int height})> _dimsOfDerivation(Uint8List encoded) async {
  final codec = await ui.instantiateImageCodec(encoded);
  final frame = await codec.getNextFrame();
  final dims = (width: frame.image.width, height: frame.image.height);
  frame.image.dispose();
  return dims;
}

void main() {
  group('sidebar_lane_production_test.dart', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    // TC-434
    test('a far visible row gets a tile via lane-produced payload', () async {
      var calls = 0;
      final controller = ImagePreloadController(
        imageLoader: _rawLoaderLane,
        dngDecoder: (path) async {
          calls++;
          return _tinyLane();
        },
        payloadEncoder: throwingPayloadEncoder,
        decodeLaneWidth: 2,
      );
      final items = photoItems(200, extension: 'arw');
      controller.updateTargetSize(800, 600);
      await controller.preloadImages(
        items: items,
        selectedItemId: 'p0',
        notifyLoaded: () {},
      );
      await controller.preloadThumbnails(
        items: items,
        startIdx: 150,
        endIdx: 152,
        notifyLoaded: () {},
      );
      await _pollUntilLane(
        () =>
            controller.payloadFor('p150') != null &&
            controller.thumbnailPayloadFor('p150') != null,
        const Duration(milliseconds: 900),
      );

      expect(
        controller.payloadFor('p150'),
        isNotNull,
        reason: 'scrolling fills the payload cache',
      );
      expect(controller.thumbnailPayloadFor('p150'), isNotNull);
      expect(
        controller.debugSidebarEnqueuedIds.contains('p150'),
        isTrue,
        reason: 'the sidebar, not navigation, is what asked for this payload',
      );
      expect(calls, greaterThan(0));
      controller.dispose();
    });

    // TC-435
    test('far-row production is lane-throttled', () async {
      var live = 0;
      var maxLive = 0;
      final gate = Completer<void>();
      Future<DecodedRgba> slowDecoder(String path) async {
        live++;
        maxLive = live > maxLive ? live : maxLive;
        await gate.future;
        live--;
        return _tinyLane();
      }

      final controller = ImagePreloadController(
        imageLoader: _rawLoaderLane,
        dngDecoder: slowDecoder,
        payloadEncoder: throwingPayloadEncoder,
        decodeLaneWidth: 2,
      );
      final items = photoItems(200, extension: 'arw');
      controller.updateTargetSize(800, 600);
      await controller.preloadThumbnails(
        items: items,
        startIdx: 150,
        endIdx: 155,
        notifyLoaded: () {},
      );
      await _pollUntilLane(() => maxLive >= 2, const Duration(milliseconds: 400));

      expect(
        maxLive,
        lessThanOrEqualTo(2),
        reason: 'six far rows must not decode more than the lane width at once',
      );
      expect(maxLive, greaterThan(0), reason: 'the ceiling must be approached');
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      controller.dispose();
    });

    // TC-436 (amendment E-H1(b): the "already owned" test is the LANE's pending
    // set, and the assertion is that the navigation entry keeps its near-to-far
    // rank instead of being demoted to the sidebar's 2000+ class -- G-027.)
    test('a row inside the navigation window is not demoted by the sweep', () async {
      final gate = Completer<void>();
      final controller = ImagePreloadController(
        imageLoader: _rawLoaderLane,
        dngDecoder: (path) async {
          await gate.future;
          return _tinyLane();
        },
        payloadEncoder: throwingPayloadEncoder,
        decodeLaneWidth: 1,
      );
      final items = photoItems(200, extension: 'arw');
      controller.updateTargetSize(800, 600);
      // Not awaited: the whole point is to inspect the lane while the navigation
      // window's entries are still pending behind the gated decode.
      unawaited(
        controller.preloadImages(
          items: items,
          selectedItemId: 'p0',
          notifyLoaded: () {},
        ),
      );
      // Let the navigation pass finish enqueueing its whole window FIRST, so the
      // sweep that follows is unambiguously the later writer -- otherwise a
      // demotion could be masked by navigation re-enqueueing afterwards.
      await _pollUntilLane(
        () => controller.debugLanePendingPriorityFor('p1') != null,
        const Duration(milliseconds: 200),
      );
      await controller.preloadThumbnails(
        items: items,
        startIdx: 0,
        endIdx: 5,
        notifyLoaded: () {},
      );
      // CONDITION-DRIVEN, not a fixed 250ms sleep: wait for the sweep's
      // debounce to actually enqueue the ids under test rather than a sleep
      // sized off "the debounce plus margin", which is the same flaky shape
      // fixed above in this file.
      await _pollUntilLane(
        () => <String>['p1', 'p2', 'p3', 'p4', 'p5']
            .every((id) => controller.debugLanePendingPriorityFor(id) != null),
        const Duration(milliseconds: 5000),
      );

      for (final id in <String>['p1', 'p2', 'p3', 'p4', 'p5']) {
        final priority = controller.debugLanePendingPriorityFor(id);
        expect(
          priority,
          isNotNull,
          reason: '$id should still be queued behind the gated decode',
        );
        expect(
          priority,
          lessThan(kSidebarPayloadPriorityBase),
          reason: 'the sweep must not demote a navigation-window entry ($id)',
        );
        expect(controller.debugSidebarEnqueuedIds.contains(id), isFalse);
      }
      gate.complete();
      // Pure cleanup drain before dispose; nothing is asserted after this, so
      // a short fixed pause (not tied to any debounce) is enough.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      controller.dispose();
    });

    // TC-437
    test('scrolling away before the turn comes runs no decode', () async {
      final decoded = <String>[];
      final gate = Completer<void>();
      Future<DecodedRgba> slowDecoder(String path) async {
        decoded.add(path);
        await gate.future;
        return _tinyLane();
      }

      final controller = ImagePreloadController(
        imageLoader: _rawLoaderLane,
        dngDecoder: slowDecoder,
        payloadEncoder: throwingPayloadEncoder,
        decodeLaneWidth: 1,
      );
      final items = photoItems(200, extension: 'arw');
      controller.updateTargetSize(800, 600);
      await controller.preloadThumbnails(
        items: items,
        startIdx: 150,
        endIdx: 158,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      // Lane width 1 and the one running body is gated, so the whole first
      // range (130..178 with the margin) is sitting PENDING behind it.
      final duringFirstRange = List<String>.of(decoded);
      expect(duringFirstRange, isNotEmpty);
      expect(controller.debugSidebarEnqueuedIds.length, greaterThan(20));

      await controller.preloadThumbnails(
        items: items,
        startIdx: 0,
        endIdx: 2,
        notifyLoaded: () {},
      );
      // Let the sweep's 100ms debounce fire so `_thumbWantedIds` has actually
      // MOVED before the queue is allowed to drain. Releasing the gate first
      // would let every pending body run while the old viewport was still the
      // live one, which tests nothing about the turn-time re-check.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      gate.complete();
      await _pollUntilLane(
        () => controller.payloadFor('p0') != null,
        const Duration(milliseconds: 600),
      );

      // The new range's union is 0..22 (3 visible + the 20-row margin). Every
      // abandoned row from the first range must have returned from its body
      // without touching the decoder.
      final abandoned = decoded.skip(duringFirstRange.length).where((path) {
        final index =
            int.parse(RegExp(r'p(\d+)\.arw$').firstMatch(path)!.group(1)!);
        return index > 22;
      }).toList();
      expect(
        abandoned,
        isEmpty,
        reason: 'rows scrolled out of the union before their turn must not decode',
      );
      for (var i = 155; i <= 158; i++) {
        expect(
          controller.payloadFor('p$i'),
          isNull,
          reason: 'p$i scrolled out of the union before its turn came',
        );
      }
      controller.dispose();
    });
  });

  group('sidebar_shared_payload_test.dart', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    // TC-430
    test('a cached payload yields a tile with no further decoder call', () async {
      final decoder = CountingDecoder();
      final controller = ImagePreloadController(
        imageLoader: _rawLoaderShared,
        dngDecoder: decoder.call,
        payloadEncoder: throwingPayloadEncoder,
      );
      final items = photoItems(10, extension: 'arw');
      controller.updateTargetSize(800, 600);
      await controller.preloadImages(
        items: items,
        selectedItemId: 'p0',
        notifyLoaded: () {},
      );
      await _settleShared();
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
      await _settleShared();

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
        imageLoader: _rawLoaderShared,
        dngDecoder: decoder.call,
        payloadEncoder: throwingPayloadEncoder,
      );
      final items = photoItems(1, extension: 'arw');
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
      await _settleShared();

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
        imageLoader: _rawLoaderShared,
        dngDecoder: decoder.call,
        payloadEncoder: throwingPayloadEncoder,
      );
      final items = photoItems(200, extension: 'arw');
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
      await _settleShared(600);

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
        imageLoader: _rawLoaderShared,
        dngDecoder: null, // no decoder => permanent miss
        payloadEncoder: throwingPayloadEncoder,
      );
      final items = photoItems(5, extension: 'arw');
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
      await _settleShared();

      expect(controller.hasFailed('p0'), isTrue);
      expect(controller.thumbnailPayloadFor('p0'), isNull);
      expect(controller.debugThumbPermanentMisses.contains('p0'), isTrue);
      controller.dispose();
    });
  });

  group('sidebar_pixel_thumbnail_test.dart', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    // TC-370 and TC-373 are RETIRED (2026-08-30, plan Task 6 / amendment
    // E-C1): both asserted that the SIDEBAR ran its own sized RAW decode and
    // stored the resulting PixelPayload. That producer is deleted -- the sidebar
    // derives every tile from the shared q70 payload now. Their replacements are
    // TC-430/TC-431 in sidebar_shared_payload_test.dart (a tile appears, and one
    // decode serves both tiers) and TC-434 in sidebar_lane_production_test.dart
    // (a far row's payload is produced on the shared lane).

    test('TC-374 INV-MEM: the sidebar cache stays viewport-bound', () async {
      final names = [for (var i = 0; i < 200; i++) 'f${i.toString().padLeft(3, "0")}.dng'];
      final dir = await _tempDirWithPixel(names);
      addTearDown(() => _deleteDirTolerant(dir));

      final controller = ImagePreloadController(
        imageLoader: _alwaysFailLoaderPixel,
        // Tiles now come from the shared payload, so the payload producer is
        // what this bound has to survive.
        dngDecoder: (path) async => _rawFixturePixel(),
        payloadEncoder: throwingPayloadEncoder,
      );
      final state = AppState(preloadController: controller);
      await state.loadFolder(dir);
      await state.preloadThumbnails(0, 19);
      await _pollUntilPixel(
        () => controller.debugThumbnailCacheLength > 0,
        const Duration(milliseconds: 800),
      );

      final maxEntries = 20 + 2 * thumbnailPrefetchMargin;
      // Non-vacuity: a bound that nothing ever approaches proves nothing. With
      // the sidebar now driving payload production, tiles must actually appear.
      expect(controller.debugThumbnailCacheLength, greaterThan(0));
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
      final dir = await _tempDirWithPixel(['c.dng']);
      addTearDown(() => _deleteDirTolerant(dir));

      final gate = Completer<void>();
      final controller = ImagePreloadController(
        imageLoader: _alwaysFailLoaderPixel,
        dngDecoder: (path) async {
          await gate.future; // still in flight when the generation is bumped
          return _rawFixturePixel();
        },
        payloadEncoder: throwingPayloadEncoder,
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
  });

  group('sidebar_priority_ordering_test.dart', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    // TC-963 (AC1): every visible row's lane priority must strictly outrank
    // every margin row's. Old formula `(index - safeStart).abs()` measured from
    // the TOP of the range with no floor for margin rows, so with a 41-row
    // visible range [100, 140] a margin row just 10 slots above the top
    // (index 90, old rowDistance 10) outranked the visible range's OWN far end
    // (index 140, old rowDistance 40) -- exactly the bug this AC proves fixed.
    test(
      'every visible row outranks every margin row (D1 two-part rowDistance)',
      () async {
        final gate = Completer<void>();
        final controller = ImagePreloadController(
          imageLoader: _rawLoaderPriority,
          dngDecoder: (path) async {
            await gate.future;
            return _tinyPriority();
          },
          payloadEncoder: throwingPayloadEncoder,
          decodeLaneWidth: 1,
        );
        final items = photoItems(400, extension: 'arw');
        controller.updateTargetSize(800, 600);

        const safeStart = 100;
        const safeEnd = 140; // 41-row visible range; margin is 20 rows each side.
        await controller.preloadThumbnails(
          items: items,
          startIdx: safeStart,
          endIdx: safeEnd,
          notifyLoaded: () {},
        );
        final visibleIds = [
          for (var i = safeStart; i <= safeEnd; i++) 'p$i',
        ];
        final marginIds = [
          for (var i = safeStart - 20; i < safeStart; i++) 'p$i',
          for (var i = safeEnd + 1; i <= safeEnd + 20; i++) 'p$i',
        ];
        // CONDITION-DRIVEN, not a fixed 250ms sleep: the assertions below
        // hard-require every margin id to be pending, so wait for that
        // directly instead of a sleep sized off "the 100ms debounce plus
        // margin", which flaked under load when the debounce's real timer
        // was delayed past the fixed budget.
        await until(
          () => marginIds
              .every((id) => controller.debugLanePendingPriorityFor(id) != null),
          reason: "the sweep's debounce to fire and enqueue every margin row",
        );

        // decodeLaneWidth is clamped to a minimum of 1 (decode_lane.dart:75), so
        // exactly one task is always IN FLIGHT (removed from the pending map,
        // not merely queued) rather than pending. Whichever row the scheduler
        // picked first is the globally lowest-priority row, so a visible id
        // reading null here is EXPECTED and only strengthens the claim (it
        // ranked ahead of everything, including every other visible row); a
        // margin id reading null would mean a margin row started ahead of some
        // visible row, which is the bug itself, so that stays a hard failure.
        final visiblePriorities = <int>[
          for (final id in visibleIds)
            if (controller.debugLanePendingPriorityFor(id) != null)
              controller.debugLanePendingPriorityFor(id)!,
        ];
        final marginPriorities = <int>[];
        for (final id in marginIds) {
          final priority = controller.debugLanePendingPriorityFor(id);
          expect(
            priority,
            isNotNull,
            reason: '$id must still be pending, never the row picked to run first',
          );
          marginPriorities.add(priority!);
        }
        expect(
          visiblePriorities,
          isNotEmpty,
          reason: 'at least one visible row must still be observably pending',
        );

        final worstVisible = visiblePriorities.reduce((a, b) => a > b ? a : b);
        final bestMargin = marginPriorities.reduce((a, b) => a < b ? a : b);
        expect(
          worstVisible,
          lessThan(bestMargin),
          reason:
              'every visible row must strictly outrank every margin row; '
              'worst visible priority=$worstVisible, best margin priority=$bestMargin',
        );

        gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        controller.dispose();
      },
    );

    // TC-964 (AC2): once a sidebar row is already pending, a later sweep whose
    // visible range has moved must UPDATE (not freeze) its priority to reflect
    // the new range. The old `if (!isPending(key))` guard skipped re-enqueueing
    // any key already pending, so a row's priority stayed pinned to whatever
    // distance-from-old-range it first queued at.
    test(
      'an already-pending sidebar row is reprioritised when the visible range moves',
      () async {
        final gate = Completer<void>();
        final controller = ImagePreloadController(
          imageLoader: _rawLoaderPriority,
          dngDecoder: (path) async {
            await gate.future;
            return _tinyPriority();
          },
          payloadEncoder: throwingPayloadEncoder,
          decodeLaneWidth: 1,
        );
        final items = photoItems(400, extension: 'arw');
        controller.updateTargetSize(800, 600);

        // First sweep: p150 sits at the far edge of a wide visible range, so it
        // is queued at a large distance-from-center.
        await controller.preloadThumbnails(
          items: items,
          startIdx: 100,
          endIdx: 150,
          notifyLoaded: () {},
        );
        await until(
          () => controller.debugLanePendingPriorityFor('p150') != null,
          reason: "the sweep's debounce to fire and enqueue p150",
        );
        final firstPriority = controller.debugLanePendingPriorityFor('p150');
        expect(firstPriority, isNotNull, reason: 'p150 should be pending after sweep 1');
        expect(
          firstPriority,
          greaterThan(kSidebarPayloadPriorityBase),
          reason: 'p150 is not at the exact center of [100,150]',
        );

        // Second sweep: the visible range moves so p150 is now dead center.
        // Its priority must improve (become numerically smaller), proving the
        // pending entry was re-enqueued rather than left frozen.
        await controller.preloadThumbnails(
          items: items,
          startIdx: 148,
          endIdx: 152,
          notifyLoaded: () {},
        );
        await until(
          () =>
              controller.debugLanePendingPriorityFor('p150') ==
              kSidebarPayloadPriorityBase,
          reason: 'the second sweep to re-enqueue p150 at its new, improved '
              'priority',
        );
        final secondPriority = controller.debugLanePendingPriorityFor('p150');
        expect(
          secondPriority,
          isNotNull,
          reason: 'p150 should still be pending (decoder gated) after sweep 2',
        );
        expect(
          secondPriority,
          equals(kSidebarPayloadPriorityBase),
          reason:
              'p150 is now the exact center of [148,152] so its rowDistance '
              'must be 0 -- proves the priority was updated, not frozen at '
              '$firstPriority',
        );
        expect(
          secondPriority,
          lessThan(firstPriority!),
          reason: 'priority must improve (numerically decrease) once p150 '
              'becomes the visible center instead of a far edge',
        );

        gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        controller.dispose();
      },
    );
  });

  group('sidebar_thumbnail_codec_test.dart', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    Future<Uint8List> bigPng() async {
      // Synthesize a 1200x800 image and PNG-encode it: a >512KB-ish encoded
      // payload with known dims, no sample-file dependency.
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final paint = ui.Paint();
      for (var x = 0; x < 1200; x += 10) {
        paint.color = ui.Color.fromARGB(255, x % 256, (x * 7) % 256, 99);
        canvas.drawRect(ui.Rect.fromLTWH(x.toDouble(), 0, 10, 800), paint);
      }
      final image = await recorder.endRecording().toImage(1200, 800);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    }

    test('small payloads pass through untouched (identity, same object)', () async {
      final small = Uint8List.fromList(List.filled(1024, 7));
      expect(identical(await sidebarCacheBytes(small), small), isTrue);
    });

    test(
      'TC-172 a payload at exactly reencodeThreshold passes through byte-identical',
      () async {
        // Boundary: the branch is `<=`, so the threshold value itself must NOT
        // be re-encoded. Content is a PNG so that a mistaken re-encode would
        // succeed and change the bytes rather than fall into the catch.
        final src = await bigPng();
        final out = await sidebarCacheBytes(src, reencodeThreshold: src.length);
        expect(out, same(src), reason: 'no copy, no re-encode at the threshold');
        expect(out, orderedEquals(src));
      },
    );

    test(
      'TC-173 oversized payloads are re-encoded as JPEG, long edge capped at 200',
      () async {
        final src = await bigPng();
        final out = await sidebarCacheBytes(src, reencodeThreshold: 1024);

        // JPEG SOI marker: the bytes really are JPEG, not PNG (0x89 0x50).
        expect([out[0], out[1]], [0xFF, 0xD8]);

        // Deliberately NOT asserting out.length < src.length here. This fixture
        // is flat vertical stripes, which is pathologically good for PNG's
        // filter+deflate (5.7KB) and pathologically bad for JPEG's DCT (14.6KB),
        // so the synthetic case genuinely inverts. The size win being claimed is
        // for photographic content and is evidenced on real DNG samples in
        // scripts/tmp/m7-t5/size-comparison.md, not here.

        // Decode-back must actually succeed. JPEG cannot carry alpha, so this
        // asserts the alpha-dropping encode still produces something the
        // sidebar can display, rather than assuming it.
        final codec = await ui.instantiateImageCodec(out);
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 200); // landscape: width is the long edge
        expect(frame.image.height, 133); // 800 * 200 / 1200 rounded
        expect(
          frame.image.width <= 200 && frame.image.height <= 200,
          isTrue,
          reason: 'long edge capped at 200',
        );
        frame.image.dispose();
      },
    );

    test('TC-174 undecodable oversized input falls back to the original bytes',
        () async {
      // Over the threshold so the re-encode branch is entered, but not a
      // decodable bitstream: the catch must cache the original rather than
      // drop the row.
      final junk = Uint8List.fromList(List.generate(4096, (i) => i % 256));
      final out = await sidebarCacheBytes(junk, reencodeThreshold: 1024);
      expect(out, same(junk));
    });

    test(
      'TC-175 (retargeted) the sidebar pixel path bakes EXIF orientation 6 '
      '(90 CW) into the stored payload',
      () async {
        const p0 = 10, p1 = 40, p2 = 70, p3 = 100;
        const q0 = 130, q1 = 160, q2 = 190, q3 = 220;
        final markers = [
          [p0, p1, p2, p3],
          [q0, q1, q2, q3],
        ];
        final bytes = Uint8List(4 * 2 * 4);
        var i = 0;
        for (final row in markers) {
          for (final marker in row) {
            bytes[i++] = marker; // R carries the marker
            bytes[i++] = 0;
            bytes[i++] = 0;
            bytes[i++] = 255; // opaque
          }
        }
        final decoded = DecodedRgba(rgba: bytes, width: 4, height: 2);

        final payload = await decodedRgbaToPixelPayload(
          decoded,
          exifOrientation: 6,
          longEdge: 200,
        );

        expect(payload.width, 2);
        expect(payload.height, 4);
        List<int> rowMarkers(int y) =>
            [for (var x = 0; x < 2; x++) payload.rgba[(y * 2 + x) * 4]];
        // rotate 90 CW: output[y'][x'] = input[h-1-x'][y'] (h=2)
        expect(rowMarkers(0), [q0, p0]);
        expect(rowMarkers(1), [q1, p1]);
        expect(rowMarkers(2), [q2, p2]);
        expect(rowMarkers(3), [q3, p3]);
      },
    );

    test('TC-176 jpegQuality is tunable and changes the encoded size', () async {
      final src = await bigPng();
      final low = await sidebarCacheBytes(
        src,
        reencodeThreshold: 1024,
        jpegQuality: 30,
      );
      final high = await sidebarCacheBytes(
        src,
        reencodeThreshold: 1024,
        jpegQuality: 95,
      );
      expect(low.length, lessThan(high.length));
    });

    test('TC-217 sidebarCacheBytes still returns decodable JPEG', () async {
      // A 900x600 PNG is over the 512 KiB passthrough threshold once raw, so
      // build a large encoded input that forces the decode/re-encode branch.
      final big = img.Image(width: 900, height: 600, numChannels: 4);
      // Pseudo-random per-pixel noise: PNG's filter+deflate cannot compress
      // this away the way flat/striped content would, so the encoded size
      // reliably clears the 512 KiB passthrough threshold.
      var seed = 12345;
      int nextByte() {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        // Low-order bits of a linear congruential generator cycle with a much
        // shorter period than the generator itself (classic LCG flaw) -- use
        // the high bits instead, or the "noise" compresses like a repeating
        // pattern and never clears the threshold.
        return (seed >> 16) & 0xff;
      }

      for (final pixel in big) {
        pixel.setRgba(nextByte(), nextByte(), nextByte(), 255);
      }
      final encoded = Uint8List.fromList(img.encodePng(big));
      expect(encoded.length, greaterThan(512 * 1024));

      final out = await sidebarCacheBytes(encoded);

      expect(out.length, lessThan(encoded.length));
      final decoded = img.decodeJpg(out);
      expect(decoded, isNotNull);
      expect(decoded!.width <= 200 && decoded.height <= 200, isTrue);
    });
  });

  group('thumbnail_derivation_test.dart', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    // TC-424
    test('an encoded payload derives to at most 200px on the long edge',
        () async {
      final payload = EncodedPayload(await _encodedOfDerivation(1200, 800));
      final derived = await deriveThumbnailPayload(payload);
      final dims = await _dimsOfDerivation((derived! as EncodedPayload).bytes);
      expect(dims.width, 200);
      expect(dims.height, lessThanOrEqualTo(200));
    });

    // TC-425
    test('a pixel payload resamples without any decoder call', () async {
      final payload = PixelPayload(
        rgba: Uint8List(1200 * 800 * 4),
        width: 1200,
        height: 800,
      );
      final derived = await deriveThumbnailPayload(payload) as PixelPayload;
      expect(derived.width, 200);
      expect(derived.height, lessThanOrEqualTo(200));
      expect(derived.rgba.lengthInBytes, derived.width * derived.height * 4);
    });

    // TC-426
    test('undecodable bytes return without throwing', () async {
      final payload = EncodedPayload(Uint8List.fromList(<int>[0, 1, 2, 3]));
      final derived = await deriveThumbnailPayload(payload);
      // Either null, or the passthrough `sidebarCacheBytes` performs on
      // undecodable input. Both are acceptable; throwing is not.
      expect(derived == null || derived is EncodedPayload, isTrue);
    });
  });

  group('jpeg_encoder_pool_test.dart', () {
    // Plan Task 6 (WP5): the sidebar used to spawn one `Isolate.run` per tile
    // encode (170 spawns/20.8s, allocation lens site #5). This group pins the
    // spawn-count bound (AC6.1), byte-identical output vs the pre-change
    // `Isolate.run` implementation (AC6.2, positive control), and the
    // catch-path passthrough that depends on this encoder (AC6.3).
    tearDown(() => disposeJpegEncoderPool());

    Uint8List goldenRgba() =>
        base64Decode(
          'xn6m/36w5/+B5JT/a5s9/0vfMv/7dIP/4rYA//uuOf9UvH7/9tXf/70yLP/f9PX/fCKK/xzw'
          '+//hRRj/h+tx/wHdVv+/odf/MZrE/97Nrf9WeOL/coRz/w+fMP9Hl6n/Z0Eu/2b0z/+Hflz/'
          'WQVl/6pCOv+IDuv/PCRI/1mS4f/qSAb/Vq7H/xM89P97fB3/0t6S/4VwY/+hNGD/2L0Z/zxR'
          '3v9Ur7//VTaM/y8R1f83rer/rojb/2UveP9b9lH/2r62/wLXt/95yyT/mKaN/8wQQv/jOFP/'
          'GnWQ/3Yeif+O7o7/Xwav/9lavP+ZGkX/j2Wa/x9ey/8/Zqj/NhXB/w==',
        );

    // AC6.2 golden bytes: `img.encodeJpg` at quality 70 for the 8x8 input
    // above, captured against the UNCHANGED (pre-pool) `Isolate.run`
    // implementation. This is the mandatory positive control (plan Step
    // 6.2) -- it is asserted to still pass after the pool swap, proving the
    // pool produces byte-identical output.
    Uint8List goldenJpeg() =>
        base64Decode(
          '/9j/4AAQSkZJRgABAQAAAQABAAD/2wCEAAoHBwgHBgoICAgLCgoLDhgQDg0NDh0VFhEYIx8l'
          'JCIfIiEmKzcvJik0KSEiMEExNDk7Pj4+JS5ESUM8SDc9PjsBCgsLDg0OHBAQHDsoIig7Ozs7'
          'Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7O//AABEIAAgA'
          'CAMBEQACEQEDEQH/xAGiAAABBQEBAQEBAQAAAAAAAAAAAQIDBAUGBwgJCgsQAAIBAwMCBAMF'
          'BQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYn'
          'KCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SV'
          'lpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz'
          '9PX29/j5+gEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoLEQACAQIEBAMEBwUEBAABAncA'
          'AQIDEQQFITEGEkFRB2FxEyIygQgUQpGhscEJIzNS8BVictEKFiQ04SXxFxgZGiYnKCkqNTY3'
          'ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqCg4SFhoeIiYqSk5SVlpeYmZqi'
          'o6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2dri4+Tl5ufo6ery8/T19vf4+fr/'
          '2gAMAwEAAhEDEQA/AFudTuIZx5s8dt5LRhiqh8gYEnRuMFDgY/v8nJrSWFjVhy8qm2l3TbVm'
          'rNx2emumttFbWacWqbndrdKWib6LTTmb3bTaXxXVo2//2Q==',
        );

    // AC6.2
    test(
      'the pooled encoder is byte-identical to the pre-pool Isolate.run '
      'result for a fixed 8x8 input',
      () async {
        final out = await encodeJpegFromRgba(
          goldenRgba(),
          width: 8,
          height: 8,
          quality: kDisplayJpegQuality,
        );
        expect(out, orderedEquals(goldenJpeg()));
      },
    );

    // AC6.1
    test('sidebar tile encodes reuse workers', () async {
      final before = debugJpegEncoderSpawnCount;
      final rgba = Uint8List(8 * 8 * 4);
      for (var i = 3; i < rgba.length; i += 4) {
        rgba[i] = 0xFF;
      }
      for (var i = 0; i < 10; i++) {
        await encodeJpegFromRgba(rgba, width: 8, height: 8, quality: 70);
      }
      final spawned = debugJpegEncoderSpawnCount - before;
      expect(
        spawned,
        lessThanOrEqualTo(2),
        reason: 'pool width is 2; spawns must not exceed it after warmup',
      );
      expect(
        spawned,
        lessThan(10),
        reason: '10 encodes must not cost 10 spawns (the per-tile-spawn bug)',
      );
    });

    // AC6.3
    test(
      'sidebarCacheBytes still returns the original bytes for undecodable '
      'input with the pooled encoder installed',
      () async {
        final junk = Uint8List.fromList(List.generate(4096, (i) => i % 256));
        final out = await sidebarCacheBytes(junk, reencodeThreshold: 1024);
        expect(out, same(junk));
      },
    );
  });
}
