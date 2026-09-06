import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/decode_lane.dart';
import 'package:halcyon_flutter/services/image_pipeline/derive_queue.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/sidebar_thumbnail_controller.dart';

import '../../support/preload_fixtures.dart';

/// Phase 2 (`docs/logs/2026-09-06/async-pipeline-refactor-plan.md` §3):
/// `onPayloadLanded` fires `_deriveTile` through a bounded, priority-ordered
/// [DeriveQueue] instead of an unbounded `unawaited` per landing. The SWEEP
/// path (`preloadThumbnails` RULE 1) is untouched and not exercised here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeriveQueue (generic gate)', () {
    test(
      'at most `width` derivations run concurrently under a burst of 10 submissions',
      () async {
        final queue = DeriveQueue(width: 2);
        var peakRunning = 0;
        final gates = List.generate(10, (_) => Completer<void>());
        final futures = <Future<void>>[];
        for (var i = 0; i < 10; i++) {
          futures.add(
            queue.submit(i, () async {
              if (queue.runningCount > peakRunning) {
                peakRunning = queue.runningCount;
              }
              await gates[i].future;
            }),
          );
        }
        // Let the pump admit as many as `width` allows.
        await Future<void>.delayed(Duration.zero);
        expect(queue.runningCount, 2);

        for (final gate in gates) {
          gate.complete();
          await Future<void>.delayed(Duration.zero);
        }
        await Future.wait(futures);

        expect(peakRunning, lessThanOrEqualTo(2));
      },
    );

    test(
      'completion order follows priority (center, edge, margin), not submission order',
      () async {
        final queue = DeriveQueue(width: 2);
        final order = <String>[];
        final gateCenter = Completer<void>();
        final gateEdge = Completer<void>();
        final gateMargin = Completer<void>();

        // Submitted margin-first, edge-second, center-last -- the reverse of
        // priority order -- exactly the "landed in arbitrary order" case
        // Phase 2 exists for.
        final marginFuture = queue.submit(50, () async {
          await gateMargin.future;
          order.add('margin');
        });
        final edgeFuture = queue.submit(5, () async {
          await gateEdge.future;
          order.add('edge');
        });
        final centerFuture = queue.submit(0, () async {
          await gateCenter.future;
          order.add('center');
        });

        // With width 2, only the two LOWEST priorities (center, edge) are
        // admitted; margin stays queued despite having submitted first.
        await Future<void>.delayed(Duration.zero);
        expect(queue.runningCount, 2);
        expect(queue.pendingCount, 1);
        expect(queue.debugPendingPriorities, [50]);

        gateCenter.complete();
        await centerFuture;
        expect(order, ['center']);

        gateEdge.complete();
        await edgeFuture;
        expect(order, ['center', 'edge']);

        gateMargin.complete();
        await marginFuture;
        expect(order, ['center', 'edge', 'margin']);
      },
    );
  });

  group('SidebarThumbnailController wiring', () {
    // The real caller (`ImagePreloadController`) writes a landed payload into
    // its own cache BEFORE calling `onPayloadLanded`, so `peekPayload(id)`
    // returns the SAME object -- that identity match is what
    // `checkPayloadIdentity` in `_deriveTile` requires. This fake mirrors
    // that: tests write into `landed` first, then call `onPayloadLanded`.
    final landed = <String, SourcePayload>{};
    SidebarThumbnailController buildController({
      Set<String> retention = const {},
    }) => SidebarThumbnailController(
      peekPayload: (id) => landed[id],
      hasPayload: (id) => false,
      isPreviewPermanentMiss: (id) => false,
      decodeLane: DecodeLane(width: 1),
      ensurePayload: (item) async {},
      retentionIds: () => retention,
      republishEvictionPriority: () {},
    );

    test(
      'landed priority mirrors the sweep _rowDistance: center < edge < margin',
      () async {
        landed.clear();
        final controller = buildController();
        final items = photoItems(41); // p0..p40
        const safeStart = 10;
        const safeEnd = 30; // visible center is p20

        await controller.preloadThumbnails(
          items: items,
          startIdx: safeStart,
          endIdx: safeEnd,
          notifyLoaded: () {},
        );
        // Poll rather than a fixed sleep (preload_fixtures.dart `until`
        // convention): a fixed 150ms wait is a documented flake source under
        // CI/full-suite CPU contention (lessons-learned 2026-08-17/2026-09-03).
        await until(
          () => controller.debugRowDistanceFor('p20') != null,
          reason: 'sweep debounce to populate _rowDistanceById',
        );

        final centerDist = controller.debugRowDistanceFor('p20');
        final edgeDist = controller.debugRowDistanceFor('p30');
        final marginDist = controller.debugRowDistanceFor('p31');
        expect(centerDist, 0, reason: 'p20 is the exact center of [10,30]');
        expect(edgeDist, 10, reason: 'p30 is the far visible edge');
        expect(
          marginDist,
          22,
          reason: 'p31 is 1 past the edge: marginBase(21) + 1',
        );

        // Landings arrive in the WRONG order: margin, then edge, then center.
        // The real caller writes the landed payload into its cache BEFORE
        // calling onPayloadLanded (see `landed` doc above).
        landed['p31'] = freshEncodedPayload();
        landed['p30'] = freshEncodedPayload();
        landed['p20'] = freshEncodedPayload();
        controller.onPayloadLanded('p31', landed['p31']!);
        controller.onPayloadLanded('p30', landed['p30']!);
        controller.onPayloadLanded('p20', landed['p20']!);

        // Before the queue's microtask pump runs, all three submissions are
        // still visible in arrival order, but each carries the priority the
        // SWEEP computed for its row -- proving onPayloadLanded routes
        // through _rowDistanceById rather than treating landings as FIFO.
        expect(
          controller.debugDeriveQueue.debugPendingPriorities,
          [marginDist, edgeDist, centerDist],
        );

        await until(
          () =>
              controller.thumbnailPayloadFor('p20') != null &&
              controller.thumbnailPayloadFor('p30') != null &&
              controller.thumbnailPayloadFor('p31') != null,
          reason: 'all three queued derivations to land a tile',
        );
      },
    );

    test(
      'advancing the batch generation while a derivation is queued writes no tile',
      () async {
        landed.clear();
        final controller = buildController();
        final items = photoItems(200);

        await controller.preloadThumbnails(
          items: items,
          startIdx: 0,
          endIdx: 4,
          notifyLoaded: () {},
        );
        await until(
          () => controller.debugRowDistanceFor('p2') != null,
          reason: 'sweep debounce to populate _rowDistanceById',
        );

        landed['p2'] = freshEncodedPayload();
        controller.onPayloadLanded('p2', landed['p2']!);

        // Advance the generation (a new sweep, e.g. a folder reload or a
        // scroll) BEFORE the queued derivation's queue-wait -- let alone its
        // await inside _deriveTile -- has resolved. `preloadThumbnails` bumps
        // `_batchGeneration` synchronously on this call, ahead of its own
        // debounce.
        await controller.preloadThumbnails(
          items: items,
          startIdx: 100,
          endIdx: 104,
          notifyLoaded: () {},
        );

        // Wait for the queued derivation to actually finish running (drained
        // from the queue), not a fixed sleep -- this is what makes the
        // negative assertion below trustworthy rather than a race.
        await until(
          () =>
              controller.debugDeriveQueue.pendingCount == 0 &&
              controller.debugDeriveQueue.runningCount == 0,
          reason: 'the queued p2 derivation to drain',
        );

        expect(
          controller.thumbnailPayloadFor('p2'),
          isNull,
          reason:
              'the post-await generation guard inside _deriveTile must still '
              'trip even though the derivation additionally waited on the '
              'DeriveQueue before its await ever ran',
        );
      },
    );
  });
}
