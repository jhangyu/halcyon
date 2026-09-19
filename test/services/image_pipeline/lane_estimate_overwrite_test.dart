// T10 follow-up (Task #12, 2026-09-20): the estimate-OVERWRITE hazard on
// `DecodeLane.enqueue`'s re-enqueue path.
//
// Two producers share the `(LaneTaskKind.payload, id)` key space:
//   * `image_preload_controller.dart:2752` enqueues CHARGED
//     (`estimatedBytes: kNominalFullFrameBytes`), and
//   * `tier_two_scheduler.dart:705` (`_enqueueLoad`) enqueues UNCHARGED (the
//     parameter's default 0), even though its body decodes a full frame inline
//     (`_ensurePayload(..., onSerialLane: true)`).
//
// Before the fix, the second one rewrote the first one's pending estimate to 0,
// so the task was admitted charging nothing and the byte gate stopped bounding
// a full frame it was about to hold. SR-8 calls those paths "charged"; a charge
// that a later re-enqueue can silently zero is not one.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/decode_lane.dart';
import 'package:halcyon_flutter/services/image_pipeline/inflight_bytes_budget.dart';

void main() {
  group('DecodeLane re-enqueue estimate', () {
    // TC-1297 -- the pin. The ledger is read WHILE the body is parked on a
    // Completer: reading after completion would see the release-to-zero and
    // pass against any charge at all.
    test(
      'an UNCHARGED re-enqueue does not zero a pending charged estimate',
      () async {
        final budget = InflightBytesBudget(maxBytes: 100);
        final lane = DecodeLane(width: 1, budget: budget);
        final blockerGate = Completer<void>();
        final victimGate = Completer<void>();

        // Holds the only slot, so the charged entry below stays PENDING (an
        // estimate can only be overwritten while it is pending).
        lane.enqueue(
          (LaneTaskKind.payload, 'blocker'),
          priority: 0,
          estimatedBytes: 0,
          body: () => blockerGate.future,
        );
        await Future<void>.delayed(Duration.zero);
        expect(lane.runningCount, 1);

        // The controller's charged production enqueue.
        lane.enqueue(
          (LaneTaskKind.payload, 'victim'),
          priority: 5,
          estimatedBytes: 60,
          body: () => victimGate.future,
        );
        expect(lane.debugPendingKeys, [(LaneTaskKind.payload, 'victim')]);

        // The tier-2 catch-up enqueue: same key, richer body, NO estimate.
        lane.enqueue(
          (LaneTaskKind.payload, 'victim'),
          priority: 5,
          body: () => victimGate.future,
        );

        blockerGate.complete();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(
          lane.runningCount,
          1,
          reason: 'the victim body is running and its charge is live',
        );
        expect(
          budget.inFlightBytes,
          60,
          reason: 'the uncharged re-enqueue must not have zeroed the estimate',
        );

        victimGate.complete();
        while (lane.pendingCount > 0 || lane.isBusy) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        expect(budget.inFlightBytes, 0);
      },
    );

    // TC-1298 -- the guard against over-fixing: an EXPLICIT re-estimate is
    // still authoritative, in BOTH directions. A fix that froze the first
    // non-zero estimate would pass TC-1297 and break this.
    test(
      'an explicit non-zero re-enqueue estimate still replaces the old one',
      () async {
        final budget = InflightBytesBudget(maxBytes: 100);
        final lane = DecodeLane(width: 1, budget: budget);
        final blockerGate = Completer<void>();
        final victimGate = Completer<void>();

        lane.enqueue(
          (LaneTaskKind.payload, 'blocker'),
          priority: 0,
          estimatedBytes: 0,
          body: () => blockerGate.future,
        );
        await Future<void>.delayed(Duration.zero);

        lane.enqueue(
          (LaneTaskKind.payload, 'victim'),
          priority: 5,
          estimatedBytes: 60,
          body: () => victimGate.future,
        );
        lane.enqueue(
          (LaneTaskKind.payload, 'victim'),
          priority: 5,
          estimatedBytes: 20,
          body: () => victimGate.future,
        );

        blockerGate.complete();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(lane.runningCount, 1);
        expect(
          budget.inFlightBytes,
          20,
          reason: 'the later explicit estimate wins, downwards included',
        );

        victimGate.complete();
        while (lane.pendingCount > 0 || lane.isBusy) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      },
    );
  });
}
