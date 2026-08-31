import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload_cache.dart';
import 'package:halcyon_flutter/services/image_pipeline/retention_policy.dart';

void main() {
  const gib = 1024 * 1024 * 1024;
  const floor = RetentionPolicy.floor();
  const mid = RetentionPolicy(
    before: 3,
    after: 8,
    payloadByteBudget: 402653184, // 384 MiB
  );
  const high = RetentionPolicy(
    before: 3,
    after: 11,
    payloadByteBudget: 536870912, // 512 MiB
  );

  test('TC-315: no reading and low-RAM machines get today shipped floor', () {
    expect(retentionPolicyFor(physicalMemoryBytes: null), floor);
    expect(retentionPolicyFor(physicalMemoryBytes: 1 * gib), floor);
    expect(retentionPolicyFor(physicalMemoryBytes: 11 * gib), floor);
    // The floor IS the shipped constants, not a second copy of them.
    expect(floor.before, kRetentionBefore);
    expect(floor.after, kRetentionAfter);
    expect(floor.payloadByteBudget, kPayloadByteBudget);
    expect(floor.payloadByteBudget, 268435456, reason: '256 MiB exactly');
  });

  test('TC-316: the mid and high rungs trigger at 12 GiB and 32 GiB', () {
    expect(retentionPolicyFor(physicalMemoryBytes: 12 * gib), mid);
    expect(retentionPolicyFor(physicalMemoryBytes: 16 * gib), mid);
    expect(retentionPolicyFor(physicalMemoryBytes: 24 * gib), mid);
    expect(retentionPolicyFor(physicalMemoryBytes: 32 * gib), high);
    expect(retentionPolicyFor(physicalMemoryBytes: 64 * gib), high);
  });

  test('TC-317: every rung holds its own RAW window and stays modest', () {
    // 22.4 MiB = measured window-resolution RGBA per no-preview RAW item
    // (photo_payload_cache.dart:19-30). A rung must hold one full window...
    const perSlotBytes = 22.4 * 1024 * 1024;
    // ...and must never claim more than 1/32 of the RAM that triggered it.
    final rungs = <RetentionPolicy, int>{
      floor: kMidRungTriggerBytes,
      mid: kMidRungTriggerBytes,
      high: kHighRungTriggerBytes,
    };
    rungs.forEach((policy, triggerBytes) {
      final slots = policy.before + policy.after + 1;
      expect(
        policy.payloadByteBudget,
        greaterThanOrEqualTo((slots * perSlotBytes).ceil()),
        reason: 'rung $policy cannot hold one full RAW window',
      );
      expect(
        policy.payloadByteBudget,
        lessThanOrEqualTo(triggerBytes ~/ 32),
        reason: 'rung $policy claims more than 1/32 of its trigger RAM',
      );
    });
    // Guard the ladder shape itself: budgets grow with slots.
    expect(
      <int>[floor.after, mid.after, high.after],
      orderedEquals(<int>[5, 8, 11]),
    );
    expect(
      math.min(mid.payloadByteBudget, high.payloadByteBudget),
      greaterThan(floor.payloadByteBudget),
    );
  });

  test(
    'TC-347 (revised, AD-044) decode lane width has a fixed 1..8 range, '
    'no CPU/memory-derived ceiling',
    () {
      expect(kMaxDecodeLaneWidth, 8);
      expect(kDefaultDecodeLaneWidth, 2);
    },
  );
}
