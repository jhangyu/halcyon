// R3-WP7 (docs/logs/2026-09-06/gc-remediation-plan.md, Task 8): navigation-time
// cancellation of stale queued decode requests.
//
// Two independent halves, per the spec sentence:
//   1. Queued-but-unstarted DecodeLane entries are pruned at window-move time
//      (`DecodeLane.prunePending`, wired at the controller's window-move site).
//   2. An in-flight decode whose window has moved past it has its downstream
//      stages (encode + publish) skipped once it returns, disposing the frame
//      and flushing parked notifies instead of publishing.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/decode_lane.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/inflight_bytes_budget.dart';
import 'package:halcyon_flutter/services/image_pipeline/retention_policy.dart';

import '../../support/preload_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DecodeLane.prunePending (unit)', () {
    test(
      'drops only the entries the keep predicate rejects, returns the count, '
      'and runs onDropped for exactly those keys',
      () async {
        final lane = DecodeLane(width: 1);
        final blockerGate = Completer<void>();
        final started = <String>[];

        // 'blocker' is dispatched immediately (width 1) and holds the only
        // running slot; 'keep'/'drop-a'/'drop-b' stay pending behind it.
        lane.enqueue(
          (LaneTaskKind.payload, 'blocker'),
          priority: 0,
          body: () async {
            started.add('blocker');
            await blockerGate.future;
          },
        );
        await Future<void>.delayed(Duration.zero);
        expect(started, ['blocker']);

        for (final id in ['keep', 'drop-a', 'drop-b']) {
          lane.enqueue(
            (LaneTaskKind.payload, id),
            priority: 5,
            body: () async => started.add(id),
          );
        }
        expect(
          lane.debugPendingKeys.toSet(),
          {
            (LaneTaskKind.payload, 'keep'),
            (LaneTaskKind.payload, 'drop-a'),
            (LaneTaskKind.payload, 'drop-b'),
          },
        );

        final dropped = <LaneKey>[];
        final count = lane.prunePending(
          (key) => key.$2 == 'keep',
          onDropped: dropped.add,
        );

        expect(count, 2);
        expect(
          dropped.toSet(),
          {(LaneTaskKind.payload, 'drop-a'), (LaneTaskKind.payload, 'drop-b')},
        );
        expect(
          lane.debugPendingKeys,
          [(LaneTaskKind.payload, 'keep')],
          reason: 'roster comparison, not just a count',
        );

        blockerGate.complete();
        await Future<void>.delayed(Duration.zero);
        while (lane.pendingCount > 0 || lane.isBusy) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        expect(
          started,
          ['blocker', 'keep'],
          reason: 'the dropped entries never ran their bodies',
        );
      },
    );

    test(
      'never touches a dispatched (running) task, even when the predicate '
      'would reject its key',
      () async {
        final lane = DecodeLane(width: 1);
        final gate = Completer<void>();
        var ran = false;
        lane.enqueue(
          (LaneTaskKind.payload, 'running'),
          priority: 0,
          body: () async {
            ran = true;
            await gate.future;
          },
        );
        await Future<void>.delayed(Duration.zero);
        expect(ran, isTrue);

        // Predicate rejects everything, including the running key -- prune
        // must find nothing to drop because a dispatched task is already out
        // of `_pending`.
        final count = lane.prunePending((_) => false);
        expect(count, 0);
        expect(lane.debugPendingKeys, isEmpty);

        gate.complete();
        while (lane.pendingCount > 0 || lane.isBusy) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      },
    );

    test(
      'N2: pruning a pending entry releases NO byte budget -- a pending task '
      'was never charged',
      () async {
        final budget = InflightBytesBudget(maxBytes: 100);
        final lane = DecodeLane(width: 1, budget: budget);
        final gate = Completer<void>();

        // Dispatched immediately: charges 60 bytes and holds the only slot.
        lane.enqueue(
          (LaneTaskKind.payload, 'running'),
          priority: 0,
          estimatedBytes: 60,
          body: () async => gate.future,
        );
        await Future<void>.delayed(Duration.zero);
        final usedBeforePrune = budget.inFlightBytes;
        expect(usedBeforePrune, 60);

        // Stays pending: the budget only has 40 bytes left, not enough for
        // another 60-byte task, but that is irrelevant here -- prunePending
        // must not touch the budget at all regardless of estimate.
        lane.enqueue(
          (LaneTaskKind.payload, 'pending'),
          priority: 5,
          estimatedBytes: 60,
          body: () async {},
        );
        expect(lane.debugPendingKeys, [(LaneTaskKind.payload, 'pending')]);

        final count = lane.prunePending((_) => false);
        expect(count, 1);
        expect(
          budget.inFlightBytes,
          usedBeforePrune,
          reason: 'a pruned pending entry held no charge to release',
        );

        gate.complete();
        while (lane.pendingCount > 0 || lane.isBusy) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      },
    );
  });

  group('ImagePreloadController window-move cancellation (integration)', () {
    // Every item routes onto the serial lane: the loader always answers
    // NeedsRawDecode (as in payload_claim_double_hold_test.dart's harness),
    // which makes `_ensurePayload` treat the outcome as `deferred` and hand
    // the whole load to `DecodeLane` regardless of distance.
    ({
      ImagePreloadController controller,
      Map<String, Completer<DecodedRgba>> gates,
      List<String> encoderCalls,
    })
    buildHarness(List<PhotoItem> items, {required RetentionPolicy retention}) {
      final gates = <String, Completer<DecodedRgba>>{};
      final encoderCalls = <String>[];
      final controller = ImagePreloadController(
        decodeLaneWidth: 1,
        retention: retention,
        payloadEncoder: (rgba, {required width, required height, required quality}) async {
          encoderCalls.add('encode');
          return Uint8List.fromList(tinyPngBytes);
        },
        pointerPayloadEncoder: null,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 6),
        dngDecoder: (path) async {
          final id = path.split('/').last.split('.').first;
          final gate = gates.putIfAbsent(id, () => Completer<DecodedRgba>());
          return gate.future;
        },
      );
      return (controller: controller, gates: gates, encoderCalls: encoderCalls);
    }

    DecodedRgba tinyDecoded() => DecodedRgba(
      rgba: Uint8List.fromList(
        List<int>.generate(2 * 2 * 4, (i) => i % 4 == 3 ? 255 : 0),
      ),
      width: 2,
      height: 2,
    );

    test(
      'AC8.1/AC8.2: a window move drops stale queued requests (roster '
      'comparison) and still fires the pruned item\'s parked notifyLoaded',
      () async {
        final items = paddedItems(4, extension: 'dng');
        // before:3/after:3 keeps the WHOLE 4-item list in the window no
        // matter which of them is selected below, so shrinking the window
        // is driven entirely by the later `setRetention`, not by which item
        // happens to be selected.
        final harness = buildHarness(
          items,
          retention: const RetentionPolicy(
            before: 3,
            after: 3,
            payloadByteBudget: 1 << 30,
          ),
        );
        final controller = harness.controller;
        addTearDown(controller.dispose);

        controller.preloadImages(
          items: items,
          selectedItemId: items[0].id,
          notifyLoaded: () {},
        );
        await until(
          () => harness.gates.containsKey(items[0].id),
          reason: 'item 0 to be dispatched onto the lane (running, not '
              'pending)',
        );
        // Items 1..3 are now pending behind item 0, all with a NULL parked
        // notify (non-selected). Re-select item 1 so IT parks a real
        // notifyLoaded (only the selected slot's notify is ever parked) --
        // this is the callback AC8.2 asserts still fires after item 1 is
        // later pruned.
        var flushedItem1 = false;
        controller.preloadImages(
          items: items,
          selectedItemId: items[1].id,
          notifyLoaded: () => flushedItem1 = true,
        );
        await Future<void>.delayed(Duration.zero);

        final beforeRoster = controller.debugPendingKeys.toSet();
        expect(
          beforeRoster,
          containsAll([
            (LaneTaskKind.payload, items[1].id),
            (LaneTaskKind.payload, items[2].id),
            (LaneTaskKind.payload, items[3].id),
          ]),
          reason: 'items 1..3 must still be queued behind the running item 0',
        );

        // Shrink the window to item 0 only -- this is the move that must
        // prune every OTHER pending entry, including item 1's (which now
        // holds a real parked notify).
        controller.setRetention(
          const RetentionPolicy(before: 0, after: 0, payloadByteBudget: 1 << 30),
        );
        controller.preloadImages(
          items: items,
          selectedItemId: items[0].id,
          notifyLoaded: () {},
        );
        await Future<void>.delayed(Duration.zero);

        final afterRoster = controller.debugPendingKeys.toSet();
        expect(
          afterRoster,
          isNot(equals(beforeRoster)),
          reason: 'roster comparison, not just a count',
        );
        expect(
          afterRoster,
          isEmpty,
          reason: 'items 1..3 all left the retention window',
        );
        expect(controller.debugPrunedQueuedCount, 3);
        expect(
          flushedItem1,
          isTrue,
          reason: 'item 1\'s pruned entry must still fire its parked '
              'notifyLoaded (no stranded spinner)',
        );

        harness.gates[items[0].id]!.complete(tinyDecoded());
        await Future<void>.delayed(const Duration(milliseconds: 20));
      },
    );

    test(
      'AC8.3/AC8.4: an in-flight decode\'s downstream stages are skipped when '
      'the window has moved past it, and its resources are released',
      () async {
        final items = paddedItems(2, extension: 'dng');
        final harness = buildHarness(
          items,
          retention: const RetentionPolicy(
            before: 0,
            after: 1,
            payloadByteBudget: 1 << 30,
          ),
        );
        final controller = harness.controller;
        addTearDown(controller.dispose);

        controller.preloadImages(
          items: items,
          selectedItemId: items[0].id,
          notifyLoaded: () {},
        );
        await until(
          () => harness.gates.containsKey(items[0].id),
          reason: 'item 0\'s decode to start',
        );
        expect(controller.isLoadingForTest(items[0].id), isTrue);

        // Move the window so item 0 leaves retention entirely (only item 1 is
        // wanted now), THEN release the parked decoder.
        controller.setRetention(
          const RetentionPolicy(before: 0, after: 0, payloadByteBudget: 1 << 30),
        );
        controller.preloadImages(
          items: items,
          selectedItemId: items[1].id,
          notifyLoaded: () {},
        );
        await Future<void>.delayed(Duration.zero);

        final beforeGeneration = controller.debugWindowGeneration;
        expect(beforeGeneration, greaterThan(0));

        harness.gates[items[0].id]!.complete(tinyDecoded());
        await until(
          () => controller.debugCancelledDownstreamCount == 1,
          reason: 'the stale in-flight decode\'s downstream skip to run',
        );

        expect(
          harness.encoderCalls,
          isEmpty,
          reason: 'the encoder must never be called for a cancelled item',
        );
        expect(
          controller.isLoadingForTest(items[0].id),
          isFalse,
          reason: 'the production claim must still be released on the skip '
              'path (finally runs unconditionally)',
        );
        expect(
          controller.payloadFor(items[0].id),
          isNull,
          reason: 'a skipped decode publishes nothing',
        );
        // N3, pinned directly: the real `ui.Image.debugDisposed` read back
        // off the handle the skip path disposed. Mutation-probe verified:
        // the assertions above alone stay green even if the `dispose()` call
        // is deleted (a skip publishes nothing either way), so this is the
        // one that actually catches that mutation.
        expect(
          controller.debugLastSkippedImageDisposed,
          isTrue,
          reason: 'N3: the skip path must dispose fullRes.image or a ~50MB '
              'handle leaks per cancelled item',
        );
      },
    );

    test(
      'AC8.5 (negative control): an item still in the window is NOT skipped',
      () async {
        final items = paddedItems(2, extension: 'dng');
        final harness = buildHarness(
          items,
          retention: const RetentionPolicy(
            before: 0,
            after: 1,
            payloadByteBudget: 1 << 30,
          ),
        );
        final controller = harness.controller;
        addTearDown(controller.dispose);

        controller.preloadImages(
          items: items,
          selectedItemId: items[0].id,
          notifyLoaded: () {},
        );
        await until(
          () => harness.gates.containsKey(items[0].id),
          reason: 'item 0\'s decode to start',
        );

        // A second window pass over the SAME selection: the window "moves"
        // (the generation bumps) but item 0 is still inside retention.
        controller.preloadImages(
          items: items,
          selectedItemId: items[0].id,
          notifyLoaded: () {},
        );
        await Future<void>.delayed(Duration.zero);

        harness.gates[items[0].id]!.complete(tinyDecoded());
        await until(
          () => controller.payloadFor(items[0].id) != null,
          reason: 'item 0 to publish normally -- the gate must be able to '
              'say yes',
        );

        expect(controller.debugCancelledDownstreamCount, 0);
        expect(harness.encoderCalls, isNotEmpty);
      },
    );
  });

  // File-existence sanity check for `paddedItems`: guards against a future
  // refactor of the fixture silently changing the file naming this suite's
  // `dngDecoder` parses paths from (`<id>.<ext>`).
  test('paddedItems ids match the dngDecoder path-parsing assumption', () {
    final items = paddedItems(2, extension: 'dng');
    for (final item in items) {
      final path = item.bestFileToLoad!.path;
      expect(path.split('/').last.split('.').first, item.id);
      expect(File(path).path, path);
    }
  });
}
