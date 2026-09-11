// Merged (round 4 M2 consolidation) from:
//   retention_policy_test.dart
//   retention_tier_test.dart
//   cache_budget_test.dart
//   inflight_bytes_budget_test.dart
// Each source file's tests are wrapped in a group() named after its basename
// to keep setUp/tearDown scoping and test names intact. No top-level helper
// name collisions were found across these four files; no test behavior was
// changed.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/cache_budget.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/inflight_bytes_budget.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload_cache.dart';
import 'package:halcyon_flutter/services/image_pipeline/prefetch_scheduler.dart';
import 'package:halcyon_flutter/services/image_pipeline/retention_policy.dart';

import '../../support/preload_fixtures.dart';

// ---------------------------------------------------------------------------
// Helpers from retention_tier_test.dart
// ---------------------------------------------------------------------------

const int _gib = 1024 * 1024 * 1024;

/// Same shape as the existing payload-cache tests' `encoded()` helper: the
/// cache reads [SourcePayload.byteCost] and nothing else.
EncodedPayload _payload({required int bytes}) => EncodedPayload(
  Uint8List(bytes),
);

Future<NativeImageResult> _bytesLoader(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => NativeImageBytes(Uint8List.fromList(<int>[1, 2, 3, 4]));

void main() {
  group('retention_policy_test.dart', () {
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
  });

  group('retention_tier_test.dart', () {
    test('TC-441 each tier maps to its shipped rung, and RAM selection agrees', () {
      expect(
        retentionPolicyForTier(RetentionTier.conservative),
        const RetentionPolicy(
          before: 3,
          after: 5,
          payloadByteBudget: 256 * 1024 * 1024,
        ),
      );
      expect(
        retentionPolicyForTier(RetentionTier.balanced),
        const RetentionPolicy(
          before: 3,
          after: 8,
          payloadByteBudget: 384 * 1024 * 1024,
        ),
      );
      expect(
        retentionPolicyForTier(RetentionTier.generous),
        const RetentionPolicy(
          before: 3,
          after: 11,
          payloadByteBudget: 512 * 1024 * 1024,
        ),
      );

      expect(
        retentionPolicyFor(physicalMemoryBytes: null),
        retentionPolicyForTier(RetentionTier.conservative),
      );
      expect(
        retentionPolicyFor(physicalMemoryBytes: 8 * _gib),
        retentionPolicyForTier(RetentionTier.conservative),
      );
      expect(
        retentionPolicyFor(physicalMemoryBytes: 16 * _gib),
        retentionPolicyForTier(RetentionTier.balanced),
      );
      expect(
        retentionPolicyFor(physicalMemoryBytes: 64 * _gib),
        retentionPolicyForTier(RetentionTier.generous),
      );
    });

    test('TC-442 tierForPolicy round-trips, and unknown policies fall back', () {
      for (final tier in RetentionTier.values) {
        expect(tierForPolicy(retentionPolicyForTier(tier)), tier);
      }
      expect(
        tierForPolicy(
          const RetentionPolicy(before: 1, after: 1, payloadByteBudget: 1),
        ),
        RetentionTier.conservative,
      );
      expect(retentionTierFromId('balanced'), RetentionTier.balanced);
      expect(retentionTierFromId('nonsense'), isNull);
      expect(RetentionTier.generous.id, 'generous');
      expect(RetentionTier.generous.label, 'Generous');
    });

    test('TC-443 shrinking the byte budget evicts immediately, without a put', () {
      final cache = PhotoPayloadCache(byteBudget: 300);
      cache.put('a', _payload(bytes: 100));
      cache.put('b', _payload(bytes: 100));
      cache.put('c', _payload(bytes: 100));
      cache.setEvictionPriority(['c', 'b', 'a']); // c nearest, a farthest
      expect(cache.length, 3);

      cache.setByteBudget(150);

      expect(cache.byteBudget, 150);
      expect(cache.totalByteCost, lessThanOrEqualTo(150));
      expect(cache.contains('c'), isTrue, reason: 'nearest survives');
    });

    test('TC-444 setRetention updates the window and the cache budget', () {
      final controller = ImagePreloadController(
        imageLoader: _bytesLoader,
        payloadEncoder: throwingPayloadEncoder,
      );
      expect(controller.retention, const RetentionPolicy.floor());

      controller.setRetention(retentionPolicyForTier(RetentionTier.generous));

      expect(controller.retention.after, 11);
      expect(controller.debugPayloadCacheByteBudget, 512 * 1024 * 1024);
    });
  });

  group('cache_budget_test.dart', () {
    const gib = 1 << 30;

    // TC-1182 (S3.1, 2026-09-11): the budget is WORKING-SET derived. Machine
    // memory is a downward safety ceiling only, so the same retention window
    // yields the same budget on a 4 GiB and a 64 GiB machine.
    test('TC-1182: budget is working-set derived, not RAM-proportional', () {
      const floorBudget = 510 << 20; // 534,773,760 B
      expect(imageCacheBudgetBytes(physicalMemoryBytes: null), floorBudget);
      expect(imageCacheBudgetBytes(physicalMemoryBytes: 4 * gib), floorBudget);
      expect(imageCacheBudgetBytes(physicalMemoryBytes: 64 * gib), floorBudget);
      expect(imageCacheBudgetBytes(physicalMemoryBytes: 256 * gib), floorBudget,
          reason: 'surplus RAM is left to the OS file cache, not claimed');
      // Downward safety ceiling: a quarter of a small machine's memory.
      expect(imageCacheBudgetBytes(physicalMemoryBytes: 1536 << 20), 384 << 20);
      expect(imageCacheBudgetBytes(physicalMemoryBytes: 512 << 20),
          kImageCacheFloorBytes); // never below the M5 guarantee floor
    });

    // TC-1183: the derivation formula itself, pinned input-by-input so a
    // future reader can see WHY the number is what it is.
    test('TC-1183: working-set formula, every input named', () {
      // Floor rung: 9 retention slots, 3 of them also full-resolution
      // (S3.2's selected +/-1 band).
      // 3*(96,000,000 + 19,440,000) + 6*19,440,000 + 1,677,722
      //   = 464,637,722 B, * 1.15 = 534,333,381 B, rounded up to 510 MiB.
      expect(
        imageCacheBudgetBytesFromWorkingSet(
          fullResolutionBandSlotCount: 3,
          windowResolutionOnlySlotCount: 6,
          fullResolutionImageByteCost: kFullResolutionImageByteCost,
          windowResolutionImageByteCost: kWindowResolutionImageByteCost,
          sidebarThumbnailPoolByteCost: kSidebarThumbnailPoolByteCost,
          safetyFactor: kImageCacheSafetyFactor,
        ),
        510 << 20,
      );
      // Wider retention windows raise the budget through the SLOT COUNT.
      expect(
        imageCacheBudgetBytes(
          retention: retentionPolicyForTier(RetentionTier.balanced),
        ),
        574 << 20, // 12 slots
      );
      expect(
        imageCacheBudgetBytes(
          retention: retentionPolicyForTier(RetentionTier.generous),
        ),
        638 << 20, // 15 slots
      );
      // The safety factor is a multiplier on the requirement, not a constant
      // addition: doubling it doubles the headroom above the same row.
      expect(
        imageCacheBudgetBytesFromWorkingSet(
          fullResolutionBandSlotCount: 1,
          windowResolutionOnlySlotCount: 0,
          fullResolutionImageByteCost: 600 << 20,
          windowResolutionImageByteCost: 0,
          sidebarThumbnailPoolByteCost: 0,
          safetyFactor: 1.5,
        ),
        900 << 20,
      );
    });

    // TC-1184: the full-resolution band slot count declared for sizing must
    // equal the band the tier-2 scheduler actually precaches, or the budget is
    // sized for a window the app does not hold.
    test('TC-1184: sizing band count equals the shipped tier-2 band', () {
      expect(kFullResolutionBandSlotCount, kFullResolutionBandRadius * 2 + 1);
      expect(kFullResolutionBandSlotCount, 3,
          reason: 'S3.2 band is selected +/-1');
    });
  });

  group('inflight_bytes_budget_test.dart', () {
    // TC-839
    test('acquire blocks past maxBytes and admits on release', () async {
      final budget = InflightBytesBudget(maxBytes: 100);
      await budget.acquire(60);
      await budget.acquire(30);
      expect(budget.inFlightBytes, 90);

      var third = false;
      unawaited(budget.acquire(30).then((_) => third = true));
      await Future<void>.delayed(Duration.zero);
      expect(third, isFalse, reason: '90 + 30 exceeds 100');
      expect(budget.waitingCount, 1);

      budget.release(60);
      await Future<void>.delayed(Duration.zero);
      expect(third, isTrue);
      expect(budget.inFlightBytes, 60);
    });

    // TC-840
    test('an oversized request is admitted when the budget is empty', () async {
      final budget = InflightBytesBudget(maxBytes: 100);
      await budget.acquire(500).timeout(const Duration(seconds: 1));
      expect(budget.inFlightBytes, 500);
    });

    // TC-840b
    test('an oversized request still waits for an occupied budget', () async {
      final budget = InflightBytesBudget(maxBytes: 100);
      await budget.acquire(60);
      var admitted = false;
      unawaited(budget.acquire(500).then((_) => admitted = true));
      await Future<void>.delayed(Duration.zero);
      expect(admitted, isFalse);
      budget.release(60);
      await Future<void>.delayed(Duration.zero);
      expect(admitted, isTrue);
    });

    test('FIFO: a large head blocks the small waiter behind it', () async {
      final budget = InflightBytesBudget(maxBytes: 100);
      await budget.acquire(100);
      var big = false;
      var small = false;
      unawaited(budget.acquire(80).then((_) => big = true));
      unawaited(budget.acquire(10).then((_) => small = true));
      budget.release(20);
      await Future<void>.delayed(Duration.zero);
      expect(big, isFalse);
      expect(small, isFalse, reason: 'the head of the queue blocks the tail');
      budget.release(80);
      await Future<void>.delayed(Duration.zero);
      expect(big, isTrue);
      expect(small, isTrue);
    });

    test('clear completes every waiter and zeroes the counter', () async {
      final budget = InflightBytesBudget(maxBytes: 10);
      await budget.acquire(10);
      var a = false;
      var b = false;
      unawaited(budget.acquire(5).then((_) => a = true));
      unawaited(budget.acquire(5).then((_) => b = true));
      budget.clear();
      await Future<void>.delayed(Duration.zero);
      expect(a, isTrue);
      expect(b, isTrue);
      expect(budget.inFlightBytes, 0);
      expect(budget.waitingCount, 0);
    });
  });
}
