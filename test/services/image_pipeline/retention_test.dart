// Merged (round 4 M2 consolidation) from:
//   'retention policy' group
//   'retention tier' group
//   'cache budget' group
//   'inflight bytes budget' group
// Each source file's tests are wrapped in a group() named after its stem
// to keep setUp/tearDown scoping and test names intact. No top-level helper
// name collisions were found across these four files; no test behavior was
// changed.
// (Group names are the former file stems with underscores as spaces.)

import 'dart:async';
import 'dart:io';
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
// Helpers for the 'retention tier' group
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
  group('retention policy', () {
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

  group('retention tier', () {
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

  group('cache budget', () {
    // TC-1182 (S3.1, 2026-09-11; re-derived under spec v2 the same day;
    // machine-memory ceiling and floor removed 2026-10-04, INV-4): the budget
    // is WORKING-SET derived and takes no machine-memory input, so every
    // machine gets the 423 MiB band budget.
    test('TC-1182: budget is the band working set, no machine-memory input',
        () {
      expect(imageCacheBudgetBytes(), 443547648); // 423 MiB
    });

    // TC-1482b: source-level pin (no injection point exists without adding
    // production plumbing): a RAM ceiling re-introduced anywhere in
    // cache_budget.dart, including ImageCacheBudget.configure(), needs a
    // memory reading, so the file must never mention one.
    test('TC-1482b: cache_budget.dart never references physical memory', () {
      final src = File('lib/services/image_pipeline/cache_budget.dart')
          .readAsStringSync();
      expect(src.contains(RegExp('physicalMemory', caseSensitive: false)),
          isFalse);
      // A renamed or aliased reading would dodge the name check, but not the
      // import: the device-RAM reading lives in `package:ceyx`
      // (`ceyxPhysicalMemoryBytes`, see lib/main.dart) and the platform
      // memory module is memory_pressure_monitor.dart.
      expect(src, isNot(contains('package:ceyx')));
      expect(src, isNot(contains('memory_pressure_monitor')));
    });

    // TC-1482 (P-4, 2026-10-04): the budget is never below what the
    // -1..+2 band needs, so a back-navigation never re-decodes an evicted
    // neighbour (the old RAM/4 ceiling gave 384 MiB at 1.5 GiB, 256 MiB at 1).
    test('TC-1482: budget >= band need with headroom', () {
      const need = kFullResolutionBandSlotCount * kFullResolutionImageByteCost +
          kSidebarThumbnailPoolByteCost;
      expect(imageCacheBudgetBytes(),
          greaterThanOrEqualTo((need * kImageCacheSafetyFactor).ceil()));
    });

    // TC-1183: the derivation formula itself, pinned input-by-input so a
    // future reader can see WHY the number is what it is.
    //
    // SPEC V2 (2026-09-11, ruling R-B): the window-resolution RETENTION
    // term is gone. 2026-10-04 (memory.md AD-072): the band's viewport-
    // resolution entries are gone too. What remains is DECODED PIXELS ONLY --
    // the -1..+2 band's four full-size entries, and the thumbnail pool.
    test('TC-1183: working-set formula, every input named', () {
      // 4*96,000,000 + 1,677,722 = 385,677,722 B,
      //   * 1.15 = 443,529,380.3 -> ceil 443,529,381 -> 423 MiB.
      expect(
        imageCacheBudgetBytesFromWorkingSet(
          fullResolutionBandSlotCount: 4,
          fullResolutionImageByteCost: kFullResolutionImageByteCost,
          sidebarThumbnailPoolByteCost: kSidebarThumbnailPoolByteCost,
          safetyFactor: kImageCacheSafetyFactor,
        ),
        443547648,
        reason: '423 MiB exactly, pinned as a RAW BYTE COUNT: the round-1 '
            'record lost time to MB-vs-MiB drift',
      );
      expect(443547648, 423 * 1024 * 1024);
      // RUNG INDEPENDENCE, asserted rather than assumed. The two rung
      // rows TC-1183 used to carry (balanced -> 574 MiB, generous -> 638
      // MiB) pinned a COUPLING BETWEEN RETENTION AND THE IMAGE-CACHE
      // BUDGET THAT NO LONGER EXISTS; they are deleted, not re-valued,
      // and this is their replacement. `imageCacheBudgetBytes` no longer
      // takes a retention argument at all, so the independence is
      // structural -- this assertion pins the consequence.
      expect(imageCacheBudgetBytes(), 443547648);
      // The safety factor is a multiplier on the requirement, not a
      // constant addition: doubling it doubles the headroom above the
      // same row.
      expect(
        imageCacheBudgetBytesFromWorkingSet(
          fullResolutionBandSlotCount: 1,
          fullResolutionImageByteCost: 600 << 20,
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
      expect(
        kFullResolutionBandSlotCount,
        kFullResolutionBandBefore + kFullResolutionBandAfter + 1,
      );
      expect(kFullResolutionBandSlotCount, 4,
          reason: 'the band is selected -1..+2 (AD-072)');
    });
  });

  group('inflight bytes budget', () {
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
