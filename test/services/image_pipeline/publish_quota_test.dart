// R3-WP8 (docs/logs/2026-09-06/gc-remediation-plan.md Task 9).
//
// Per-frame publish BYTE quota (`PublicationPacer.perFrameBytes` /
// `submit`'s `byteCost`), alongside the pre-existing per-frame COUNT budget,
// and the batched-drain assertion (AC9.5): several entries queued in the same
// turn drain in ONE `_drain` call.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/publication_pacer.dart';

void main() {
  // TC-1056
  test('a frame publishes at most perFrameBytes', () {
    final published = <String>[];
    late VoidCallback drain;
    final pacer = PublicationPacer(
      scheduleFrameCallback: (cb) => drain = cb,
      perFrame: 10, // count is deliberately NOT the constraint
      perFrameBytes: 100 * 1024 * 1024,
      isSelected: (_) => false,
    );
    for (final id in ['a', 'b', 'c']) {
      pacer.submit(
        id: id,
        rank: 0,
        byteCost: 50 * 1024 * 1024,
        exempt: false,
        stillValid: () => true,
        publish: () => published.add(id),
      );
    }
    drain();
    expect(published.length, 2, reason: '2 x 50MB fits, the third does not');
    expect(
      pacer.debugBytesPublishedLastFrame,
      lessThanOrEqualTo(100 * 1024 * 1024),
    );
    drain();
    expect(published.length, 3);
  });

  // Positive control: a single entry bigger than the WHOLE per-frame byte
  // quota still publishes when it is first this frame -- otherwise a ~97MB
  // upload would never publish at all (plan Step 9.3's stated rule, mirrored
  // from InflightBytesBudget's empty-budget clause).
  test('an oversized entry publishes anyway when it is first this frame', () {
    final published = <String>[];
    late VoidCallback drain;
    final pacer = PublicationPacer(
      scheduleFrameCallback: (cb) => drain = cb,
      perFrame: 10,
      perFrameBytes: 10,
      isSelected: (_) => false,
    );
    pacer.submit(
      id: 'huge',
      rank: 0,
      byteCost: 1000,
      exempt: false,
      stillValid: () => true,
      publish: () => published.add('huge'),
    );
    drain();
    expect(published, ['huge']);
    expect(pacer.debugBytesPublishedLastFrame, 1000);
  });

  // AC9.5 -- batched drain: four entries submitted in the SAME turn (before
  // the frame hook fires) must drain in ONE `_drain` call, not four.
  test('four simultaneous completions drain in a single batch', () {
    final published = <String>[];
    late VoidCallback drain;
    final pacer = PublicationPacer(
      scheduleFrameCallback: (cb) => drain = cb,
      perFrame: 10,
      perFrameBytes: 100 * 1024 * 1024,
      isSelected: (_) => false,
    );
    for (final id in ['a', 'b', 'c', 'd']) {
      pacer.submit(
        id: id,
        rank: 0,
        byteCost: 1024,
        exempt: false,
        stillValid: () => true,
        publish: () => published.add(id),
      );
    }
    drain();
    expect(published.length, 4);
    expect(pacer.debugBatchesDrained, 1);
    expect(pacer.debugMaxBatchSize, 4);
  });
}
