import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/decode_lane.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';

import '../../support/preload_fixtures.dart';

/// Task 7 (plan `docs/logs/2026-08-30/shared-payload-cache-plan.md`):
/// "scrolling fills the payload cache" (D5 decision 4). A visible row with no
/// payload asks the SHARED lane to make one, at the sidebar's own low
/// priority -- so the second, unthrottled decoder the old sidebar owned (F5's
/// `laneWidth + 1` overshoot) is gone.
///
/// Helpers are copied rather than imported from the Task 6 file: test files do
/// not export to one another.
Future<NativeImageResult> _rawLoader(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

DecodedRgba _tiny() =>
    DecodedRgba(rgba: Uint8List(8 * 8 * 4), width: 8, height: 8);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // TC-434
  test('a far visible row gets a tile via lane-produced payload', () async {
    var calls = 0;
    final controller = ImagePreloadController(
      imageLoader: _rawLoader,
      dngDecoder: (path) async {
        calls++;
        return _tiny();
      },
      payloadEncoder: null,
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
    await Future<void>.delayed(const Duration(milliseconds: 900));

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
      return _tiny();
    }

    final controller = ImagePreloadController(
      imageLoader: _rawLoader,
      dngDecoder: slowDecoder,
      payloadEncoder: null,
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
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(
      maxLive,
      lessThanOrEqualTo(2),
      reason: 'six far rows must not decode more than the lane width at once',
    );
    expect(maxLive, greaterThan(0), reason: 'the ceiling must be approached');
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    controller.dispose();
  });

  // TC-436 (amendment E-H1(b): the "already owned" test is the LANE's pending
  // set, and the assertion is that the navigation entry keeps its near-to-far
  // rank instead of being demoted to the sidebar's 2000+ class -- G-027.)
  test('a row inside the navigation window is not demoted by the sweep', () async {
    final gate = Completer<void>();
    final controller = ImagePreloadController(
      imageLoader: _rawLoader,
      dngDecoder: (path) async {
        await gate.future;
        return _tiny();
      },
      payloadEncoder: null,
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
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await controller.preloadThumbnails(
      items: items,
      startIdx: 0,
      endIdx: 5,
      notifyLoaded: () {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));

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
    await Future<void>.delayed(const Duration(milliseconds: 200));
    controller.dispose();
  });

  // TC-437
  test('scrolling away before the turn comes runs no decode', () async {
    final decoded = <String>[];
    final gate = Completer<void>();
    Future<DecodedRgba> slowDecoder(String path) async {
      decoded.add(path);
      await gate.future;
      return _tiny();
    }

    final controller = ImagePreloadController(
      imageLoader: _rawLoader,
      dngDecoder: slowDecoder,
      payloadEncoder: null,
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
    await Future<void>.delayed(const Duration(milliseconds: 600));

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
}
