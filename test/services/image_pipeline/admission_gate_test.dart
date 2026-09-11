import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/frame_bytes.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/inflight_bytes_budget.dart';
import 'package:halcyon_flutter/services/image_pipeline/retention_policy.dart';

import '../../support/preload_fixtures.dart' show until;

void main() {
  // S1.1/S1.4 (2026-09-11). Replaces the `inflightByteBudgetFor` group, which
  // pinned the DELETED retention-derived rule (TC-1042/TC-1042b): the decode
  // budget no longer takes a RetentionPolicy at all, so those two cases cannot
  // be migrated, only replaced.
  group('decodeInflightByteBudget', () {
    // TC-1120
    test('sizes the budget from lane width, not from any retention policy', () {
      expect(
        decodeInflightByteBudget(decodeLaneWidth: 4),
        5 * kNominalFullFrameBytes,
      );
      expect(
        decodeInflightByteBudget(decodeLaneWidth: 8),
        9 * kNominalFullFrameBytes,
      );
    });

    // TC-1121
    test('keeps the historical two-frame floor at the narrowest width', () {
      expect(
        decodeInflightByteBudget(decodeLaneWidth: 1),
        2 * kNominalFullFrameBytes,
      );
    });

    // TC-1122
    test('clamps to the measured-safe maximum lane width', () {
      expect(
        decodeInflightByteBudget(decodeLaneWidth: 16),
        decodeInflightByteBudget(decodeLaneWidth: kMaxDecodeLaneWidth),
      );
      expect(
        decodeInflightByteBudget(decodeLaneWidth: 16),
        (kMaxDecodeLaneWidth + 1) * kNominalFullFrameBytes,
      );
    });

    // TC-1123
    test('treats machine memory as a ceiling and never as the driver', () {
      const bigMachine = 256 * 1024 * 1024 * 1024; // 256 GiB
      for (var width = 1; width <= kMaxDecodeLaneWidth; width++) {
        expect(
          decodeInflightByteBudget(
            decodeLaneWidth: width,
            physicalMemoryBytes: bigMachine,
          ),
          decodeInflightByteBudget(decodeLaneWidth: width),
          reason: 'the RAM reading must not move the budget at width $width',
        );
      }
    });

    // TC-1124
    test('re-floors at two frames when the memory ceiling is lower', () {
      // 2 nominal frames = 193,924,608 B, so the ceiling has to sit BELOW
      // that for the floor to be the thing under test: 512 MiB * 25% =
      // 134,217,728 B. (1 GiB does not qualify -- its 25% is 256 MiB, which
      // is already above two frames.)
      const smallMachine = 512 * 1024 * 1024;
      expect(
        smallMachine * decodeInflightBudgetMemoryCeilingPercent ~/ 100,
        lessThan(2 * kNominalFullFrameBytes),
        reason: 'the premise: the ceiling alone would go below the floor',
      );
      expect(
        decodeInflightByteBudget(
          decodeLaneWidth: 8,
          physicalMemoryBytes: smallMachine,
        ),
        2 * kNominalFullFrameBytes,
      );
    });

    // TC-1125
    test('ignores a non-positive memory reading', () {
      expect(
        decodeInflightByteBudget(decodeLaneWidth: 4, physicalMemoryBytes: 0),
        decodeInflightByteBudget(decodeLaneWidth: 4),
      );
      expect(
        decodeInflightByteBudget(decodeLaneWidth: 4, physicalMemoryBytes: -1),
        decodeInflightByteBudget(decodeLaneWidth: 4),
      );
    });
  });

  group('InflightBytesBudget.tryAcquire', () {
    // TC-1042c
    test('admits what fits and refuses what does not, without blocking', () {
      final budget = InflightBytesBudget(maxBytes: 100);
      expect(budget.tryAcquire(60), isNotNull);
      expect(budget.tryAcquire(60), isNull);
      expect(budget.inFlightBytes, 60);
      expect(budget.tryAcquire(40), isNotNull);
      expect(budget.inFlightBytes, 100);
    });

    // TC-1042d
    test('an oversized request is admitted only when nothing is in flight', () {
      final budget = InflightBytesBudget(maxBytes: 100);
      expect(budget.tryAcquire(500), isNotNull);
      expect(budget.inFlightBytes, 500);
      expect(budget.tryAcquire(500), isNull);
    });

    // TC-1042e
    test('a parked blocking waiter is not overtaken by tryAcquire', () async {
      final budget = InflightBytesBudget(maxBytes: 100);
      expect(budget.tryAcquire(100), isNotNull);
      // ignore: unawaited_futures
      budget.acquire(100);
      expect(budget.waitingCount, 1);
      expect(budget.tryAcquire(1), isNull,
          reason: 'head-of-queue fairness must hold for tryAcquire too');
    });
  });

  group('InflightBytesBudget.adjust', () {
    // TC-1042f
    test('corrects an estimate up and down against the live epoch', () {
      final budget = InflightBytesBudget(maxBytes: 1000);
      final epoch = budget.tryAcquire(500)!;
      budget.adjust(500, 700, epoch: epoch);
      expect(budget.inFlightBytes, 700);
      budget.adjust(700, 100, epoch: epoch);
      expect(budget.inFlightBytes, 100);
    });

    // TC-1042g
    test('is a no-op against a stale epoch (TC-886 rule)', () {
      final budget = InflightBytesBudget(maxBytes: 1000);
      final epoch = budget.tryAcquire(500)!;
      budget.clear();
      budget.adjust(500, 900, epoch: epoch);
      expect(budget.inFlightBytes, 0);
    });

    // TC-1042h
    test('a downward adjustment admits a parked waiter', () async {
      final budget = InflightBytesBudget(maxBytes: 100);
      final epoch = budget.tryAcquire(100)!;
      var admitted = false;
      // ignore: unawaited_futures
      budget.acquire(50).then((_) => admitted = true);
      await Future<void>.delayed(Duration.zero);
      expect(admitted, isFalse);
      budget.adjust(100, 10, epoch: epoch);
      await Future<void>.delayed(Duration.zero);
      expect(admitted, isTrue);
    });
  });

  group('admission_gate_test.dart (controller)', () {
    /// A 4x4 OPAQUE RGBA frame, orientation 1 -- identity short-circuit, so no
    /// `ui.Image` handle is created. Same fixture shape as `encode_test.dart`.
    DecodedRgba decodedFixture() {
      final rgba = Uint8List(4 * 4 * 4);
      for (var i = 0; i < rgba.length; i += 4) {
        rgba[i] = 0x40;
        rgba[i + 1] = 0x80;
        rgba[i + 2] = 0xC0;
        rgba[i + 3] = 0xFF;
      }
      return DecodedRgba(rgba: rgba, width: 4, height: 4);
    }

    List<PhotoItem> rawItems(List<String> ids) => [
          for (final id in ids) PhotoItem(id: id, files: [File('/tmp/$id.dng')]),
        ];

    Future<NativeImageResult> needsRawDecodeLoader(
      String path, {
      required ImageRequestPurpose purpose,
      int? targetLongEdge,
    }) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

    ImagePreloadController buildController({
      required Future<DecodedRgba> Function(String path) decoder,
      Future<Uint8List> Function(
        Uint8List rgba, {
        required int width,
        required int height,
        required int quality,
      })? encoder,
      int decodeLaneWidth = 1,
      int? inflightByteBudget,
      RetentionPolicy retention = const RetentionPolicy.floor(),
    }) {
      return ImagePreloadController(
        imageLoader: needsRawDecodeLoader,
        dngDecoder: (path) => decoder(path),
        payloadEncoder:
            encoder ??
            (rgba, {required width, required height, required quality}) async =>
                Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]),
        decodeLaneWidth: decodeLaneWidth,
        inflightByteBudget: inflightByteBudget,
        retention: retention,
      );
    }

    Future<void> pumpMicrotasks([int rounds = 24]) async {
      for (var i = 0; i < rounds; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    TestWidgetsFlutterBinding.ensureInitialized();

    // TC-1043
    test('admission is charged before the decode runs', () async {
      final gate = Completer<void>();
      final controller = buildController(
        decoder: (path) async {
          await gate.future;
          return decodedFixture();
        },
        decodeLaneWidth: 1,
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(32, 32);
      unawaited(
        controller.preloadImages(
          items: rawItems(['a', 'b']),
          selectedItemId: 'a',
          notifyLoaded: () {},
        ),
      );
      await pumpMicrotasks();
      expect(
        controller.debugInflightBytes,
        greaterThan(0),
        reason: 'bytes must be charged before the decoder returns',
      );
      gate.complete();
      await pumpMicrotasks();
    });

    // TC-1044 -- deadlock regression: the byte gate REFUSES an admission and
    // the queue still drains completely.
    //
    // S1.3 MIGRATION (2026-09-11). The refusal used to fall out of the script
    // for free: the first item's post-adjustment charge (64 B, this fixture)
    // stayed on the DECODE ledger for the whole off-lane encode, and
    // `64 + kNominalFullFrameBytes > kNominalFullFrameBytes` blocked every
    // later dispatch. After S1.3 that charge moves to the encode/publish tail
    // ledger at the stage boundary, so the decode ledger is empty by then and
    // the oversize-single-item hatch admits the next item -- the gate would
    // never engage and this test would pass VACUOUSLY, proving nothing about
    // the deadlock it exists to catch. (Observed: `debugByteBlockedPumps == 0`
    // against the unmodified script after S1.3.)
    //
    // The refusal is therefore made explicit instead: the first decode is held
    // open at its full NOMINAL charge while the other items try to dispatch,
    // which is the only state in which the gate can legitimately refuse now.
    test('a full lane never blocks on bytes', () async {
      final firstDecodeGate = Completer<void>();
      var decoderEntries = 0;
      final controller = buildController(
        decoder: (path) async {
          decoderEntries++;
          if (decoderEntries == 1) await firstDecodeGate.future;
          return decodedFixture();
        },
        decodeLaneWidth: 2,
        inflightByteBudget: kNominalFullFrameBytes, // room for ONE frame
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(32, 32);
      unawaited(
        controller.preloadImages(
          items: rawItems(['a', 'b', 'c', 'd']),
          selectedItemId: 'a',
          notifyLoaded: () {},
        ),
      );
      await until(
        () => controller.debugByteBlockedPumps > 0,
        reason: 'the byte gate to actually refuse an admission',
      );
      firstDecodeGate.complete();
      // BOUNDED WAIT, not a fixed pump count: preloadImages resolving doesn't
      // guarantee every off-lane continuation has landed its payload yet, so
      // a fixed 64-pump budget flaked under load ("X never completed").
      const ids = ['a', 'b', 'c', 'd'];
      await until(
        () => ids.every((id) => controller.payloadFor(id) != null),
        reason: 'every item to land a payload once the byte gate frees up',
      );
      for (final id in ids) {
        expect(controller.payloadFor(id), isNotNull, reason: '$id never completed');
      }
    });

    // TC-1045
    test('encode stage runs wider than one frame', () async {
      final encodeGate = Completer<void>();
      var peakEncodes = 0;
      final controller = buildController(
        decoder: (path) async => decodedFixture(),
        encoder:
            (rgba, {required width, required height, required quality}) async {
          await encodeGate.future;
          return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
        },
        decodeLaneWidth: 2,
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(32, 32);
      unawaited(
        controller.preloadImages(
          items: rawItems(['a', 'b', 'c', 'd']),
          selectedItemId: 'a',
          notifyLoaded: () {},
        ),
      );
      // CONDITION-DRIVEN sampling, not a fixed 64-microtask budget: this
      // still needs to *sample* the running count each tick (there's no
      // single event to await for "peak concurrency"), but the sampling
      // window is now wall-clock bounded so scheduler contention that slows
      // down the ticks can't cut the sample off before the peak is reached.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (peakEncodes < 2 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(Duration.zero);
        final running = controller.debugEncodeStageRunningCount;
        if (running > peakEncodes) peakEncodes = running;
      }
      expect(
        peakEncodes,
        greaterThanOrEqualTo(2),
        reason: 'two full frames must be admitted concurrently',
      );
      encodeGate.complete();
      await pumpMicrotasks();
    });

    // TC-1046 -- erratum E-WP2-C2: the charge spans the OFF-LANE ENCODE, not
    // just the decode. Releasing at lane-body return would leave the full-res
    // frame (still alive for the whole encode) uncharged.
    test('the byte admission is held across the off-lane encode', () async {
      final encodeGate = Completer<void>();
      final controller = buildController(
        decoder: (path) async => decodedFixture(),
        encoder:
            (rgba, {required width, required height, required quality}) async {
          await encodeGate.future;
          return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
        },
        decodeLaneWidth: 1,
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(32, 32);
      unawaited(
        controller.preloadImages(
          items: rawItems(['a', 'b']),
          selectedItemId: 'a',
          notifyLoaded: () {},
        ),
      );
      await pumpMicrotasks();
      expect(
        controller.debugInflightBytes,
        greaterThan(0),
        reason: 'the decode is done but its frame is still alive in the encode',
      );
      encodeGate.complete();
      await pumpMicrotasks(64);
      expect(
        controller.debugInflightBytes,
        0,
        reason: 'the transferred admission must be released after the encode',
      );
    });

    // TC-1047 -- the NO-TRANSFER path (a cheap item, no off-lane encode) still
    // releases in the lane's own `finally`, and the release re-pumps: without
    // the restart the queue stalls forever once the last runner exits, which is
    // exactly what makes TC-1044 red.
    test('a lane task with no off-lane encode releases its own admission',
        () async {
      final attempts = <String>[];
      final controller = buildController(
        decoder: (path) async {
          attempts.add(path);
          throw StateError('decode down');
        },
        decodeLaneWidth: 1,
        inflightByteBudget: kNominalFullFrameBytes,
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(32, 32);
      await controller
          .preloadImages(
            items: rawItems(['a', 'b', 'c']),
            selectedItemId: 'a',
            notifyLoaded: () {},
          )
          .timeout(const Duration(seconds: 5));
      await pumpMicrotasks(64);
      expect(
        controller.debugInflightBytes,
        0,
        reason: 'a failing body must not strand its admission',
      );
      // The release must also RE-PUMP: with room for a single frame, items b
      // and c are byte-blocked at dispatch and hold nothing, so the only thing
      // that can restart them is a's release. Without that restart the queue
      // stalls forever once the last runner exits.
      expect(
        attempts.length,
        3,
        reason: 'every queued item must still get its turn after a release',
      );
    });

    // ---- WP1.1: the budget follows the lane width, not the retention tier ---

    // TC-1126
    test('the budget follows the lane-width setting', () async {
      final controller = buildController(
        decoder: (path) async => decodedFixture(),
        decodeLaneWidth: 2,
      );
      addTearDown(controller.dispose);
      expect(
        controller.debugDecodeInflightByteBudget,
        3 * kNominalFullFrameBytes,
      );
      controller.setDecodeLaneWidth(8);
      expect(
        controller.debugDecodeInflightByteBudget,
        9 * kNominalFullFrameBytes,
      );
    });

    // TC-1127 -- decision D1-c. Without this precedence the width push would
    // silently raise the deliberately tiny budgets TC-1044/TC-1047 pin, and
    // those tests would pass for the wrong reason rather than fail.
    test('an explicit budget override survives a width push', () async {
      final controller = buildController(
        decoder: (path) async => decodedFixture(),
        decodeLaneWidth: 1,
        inflightByteBudget: kNominalFullFrameBytes,
      );
      addTearDown(controller.dispose);
      expect(controller.debugDecodeInflightByteBudget, kNominalFullFrameBytes);
      controller.setDecodeLaneWidth(8);
      expect(
        controller.debugDecodeInflightByteBudget,
        kNominalFullFrameBytes,
        reason: 'an explicit override wins for the controller lifetime',
      );
    });

    // TC-1128
    test('changing the retention tier does not move the decode budget',
        () async {
      final controller = buildController(
        decoder: (path) async => decodedFixture(),
        decodeLaneWidth: 4,
        retention: retentionPolicyForTier(RetentionTier.conservative),
      );
      addTearDown(controller.dispose);
      final budgetBefore = controller.debugDecodeInflightByteBudget;
      final cacheBefore = controller.debugPayloadCacheByteBudget;
      controller.setRetention(retentionPolicyForTier(RetentionTier.generous));
      expect(
        controller.debugDecodeInflightByteBudget,
        budgetBefore,
        reason: 'S1.4: retention no longer drives the decode byte budget',
      );
      expect(
        controller.debugPayloadCacheByteBudget,
        isNot(cacheBefore),
        reason: 'the premise: the tier switch really did change retention',
      );
    });

    // ---- WP1.2: real-size re-accounting (AC2) -----------------------------

    // TC-1129 (AC2)
    test('the admission ledger drops to the real frame size after decode',
        () async {
      final encodeGate = Completer<void>();
      final controller = buildController(
        decoder: (path) async => decodedFixture(),
        encoder:
            (rgba, {required width, required height, required quality}) async {
          await encodeGate.future;
          return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
        },
        decodeLaneWidth: 1,
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(32, 32);
      unawaited(
        controller.preloadImages(
          items: rawItems(['a']),
          selectedItemId: 'a',
          notifyLoaded: () {},
        ),
      );
      await until(
        () => controller.debugAdmissionAdjustmentCount > 0,
        reason: 'the re-accounting seam to run',
      );
      // 4x4 RGBA = 64 B. The ledger must hold the REAL size, not the nominal
      // ~97MB estimate it was admitted on.
      expect(controller.debugInflightBytes, 64);
      expect(controller.debugInflightBytes, lessThan(kNominalFullFrameBytes));
      expect(controller.debugAdmissionAdjustmentCount, 1);
      encodeGate.complete();
      await until(
        () => controller.debugInflightBytes == 0,
        reason: 'both ledgers to drain after publication',
      );
    });

    // TC-1130 (AC2) -- PLAN DEVIATION, reported to lead. The plan predicted
    // `debugAdmissionAdjustmentCount == 0` here on the theory that a throwing
    // decode never reaches the re-accounting seam. It does: `PhotoSource`'s
    // decode phase SWALLOWS the decoder failure and returns a decode carrying
    // no frame, so the seam runs and settles the charge to 0 (observed count
    // 1, ledger 0). The invariant that matters -- no bytes stranded -- is
    // asserted as written; the count assertion is expressed against the
    // observed behaviour rather than the prediction.
    test('a failing decode settles its admission to zero and strands nothing',
        () async {
      final controller = buildController(
        decoder: (path) async => throw StateError('decode down'),
        decodeLaneWidth: 1,
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(32, 32);
      await controller
          .preloadImages(
            items: rawItems(['a']),
            selectedItemId: 'a',
            notifyLoaded: () {},
          )
          .timeout(const Duration(seconds: 5));
      await pumpMicrotasks(64);
      expect(controller.debugInflightBytes, 0);
      expect(
        controller.debugAdmissionAdjustmentCount,
        1,
        reason: 'the seam runs and settles the failed decode\'s charge to 0',
      );
    });

    // ---- WP1.3: the decode ledger is freed at the stage boundary ----------

    // TC-1131 (AC1)
    test('the decode ledger is free once the frame reaches the encode stage',
        () async {
      final encodeGate = Completer<void>();
      final controller = buildController(
        decoder: (path) async => decodedFixture(),
        encoder:
            (rgba, {required width, required height, required quality}) async {
          await encodeGate.future;
          return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
        },
        decodeLaneWidth: 1,
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(32, 32);
      unawaited(
        controller.preloadImages(
          items: rawItems(['a']),
          selectedItemId: 'a',
          notifyLoaded: () {},
        ),
      );
      await until(
        () => controller.debugEncodePublishTailBytes > 0,
        reason: 'the frame to reach the encode stage',
      );
      expect(
        controller.debugDecodeInflightBytes,
        0,
        reason: 'S1.3: the decode ledger must not be held through the encode',
      );
      encodeGate.complete();
      await until(() => controller.debugInflightBytes == 0);
    });

    // TC-1132 (AC2) -- the mechanical guard on the charge-at-real-size ruling.
    test('the encode tail is charged at the real frame size, never the nominal',
        () async {
      final encodeGate = Completer<void>();
      final controller = buildController(
        decoder: (path) async => decodedFixture(),
        encoder:
            (rgba, {required width, required height, required quality}) async {
          await encodeGate.future;
          return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
        },
        decodeLaneWidth: 1,
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(32, 32);
      unawaited(
        controller.preloadImages(
          items: rawItems(['a']),
          selectedItemId: 'a',
          notifyLoaded: () {},
        ),
      );
      await until(() => controller.debugEncodePublishTailBytes > 0);
      expect(controller.debugEncodePublishTailBytes, 64);
      expect(
        controller.debugEncodePublishTailBytes,
        lessThan(kNominalFullFrameBytes),
      );
      encodeGate.complete();
      await until(() => controller.debugInflightBytes == 0);
    });

    // TC-1133 (AC1) -- impossible before S1.3: the first frame's charge was
    // held on the decode ledger for the whole encode.
    test('a second decode starts while the first frame is still encoding',
        () async {
      final encodeGate = Completer<void>();
      var decoderEntries = 0;
      final controller = buildController(
        decoder: (path) async {
          decoderEntries++;
          return decodedFixture();
        },
        encoder:
            (rgba, {required width, required height, required quality}) async {
          await encodeGate.future;
          return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
        },
        decodeLaneWidth: 1,
        // Room for exactly ONE nominal frame on the decode ledger.
        inflightByteBudget: kNominalFullFrameBytes,
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(32, 32);
      unawaited(
        controller.preloadImages(
          items: rawItems(['a', 'b']),
          selectedItemId: 'a',
          notifyLoaded: () {},
        ),
      );
      await until(
        () => decoderEntries >= 2,
        reason: 'the second decode to start while the first frame encodes',
      );
      expect(controller.debugEncodePublishTailBytes, greaterThan(0));
      encodeGate.complete();
      await until(() => controller.debugInflightBytes == 0);
    });

    // TC-1134 (AC1)
    test('a tail release after dispose is a no-op', () async {
      final encodeGate = Completer<void>();
      final controller = buildController(
        decoder: (path) async => decodedFixture(),
        encoder:
            (rgba, {required width, required height, required quality}) async {
          await encodeGate.future;
          return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
        },
        decodeLaneWidth: 1,
      );
      controller.updateTargetSize(32, 32);
      unawaited(
        controller.preloadImages(
          items: rawItems(['a']),
          selectedItemId: 'a',
          notifyLoaded: () {},
        ),
      );
      await until(() => controller.debugEncodePublishTailBytes > 0);
      controller.dispose();
      encodeGate.complete();
      await pumpMicrotasks(64);
      expect(controller.debugInflightBytes, 0);
      expect(controller.debugEncodePublishTailBytes, 0);
    });

    // TC-1135 (AC1)
    test('an encode that throws still releases its tail charge', () async {
      final controller = buildController(
        decoder: (path) async => decodedFixture(),
        encoder:
            (rgba, {required width, required height, required quality}) async =>
                throw StateError('encoder down'),
        decodeLaneWidth: 1,
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(32, 32);
      unawaited(
        controller.preloadImages(
          items: rawItems(['a']),
          selectedItemId: 'a',
          notifyLoaded: () {},
        ),
      );
      await until(
        () => controller.debugInflightBytes == 0,
        reason: 'a throwing encode must still release its tail charge',
      );
    });

    // ---- WP0.2: the memory-ledger snapshot (schema agreed with phase 0) ----

    // TC-1138 -- a SCHEMA + COHERENCE pin, not a memory measurement.
    // The load-bearing property is that the two transient ledgers are reported
    // SEPARATELY: a snapshot that folded them into one "in flight" number would
    // silently under-count the encode/publish tail, and this assertion is what
    // makes that fail rather than merely look plausible.
    test('the ledger snapshot reports both transient ledgers separately',
        () async {
      final encodeGate = Completer<void>();
      final controller = buildController(
        decoder: (path) async => decodedFixture(),
        encoder:
            (rgba, {required width, required height, required quality}) async {
          await encodeGate.future;
          return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
        },
        decodeLaneWidth: 2,
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(32, 32);
      unawaited(
        controller.preloadImages(
          items: rawItems(['a']),
          selectedItemId: 'a',
          notifyLoaded: () {},
        ),
      );
      await until(() => controller.debugEncodePublishTailBytes > 0);
      final snapshot = controller.debugMemoryLedgerSnapshot;
      // Mid-encode: the frame has left the decode ledger and sits on the tail.
      expect(snapshot.decodeInflightBytes, 0);
      expect(snapshot.encodePublishTailBytes, 64);
      // Every field agrees with the individual getter it mirrors, so the
      // snapshot cannot drift from the ledgers it claims to report.
      expect(snapshot.decodeInflightBytes, controller.debugDecodeInflightBytes);
      expect(
        snapshot.encodePublishTailBytes,
        controller.debugEncodePublishTailBytes,
      );
      expect(
        snapshot.decodeInflightByteBudget,
        controller.debugDecodeInflightByteBudget,
      );
      expect(
        snapshot.retainedPayloadByteBudget,
        controller.debugPayloadCacheByteBudget,
      );
      // LIVE retained bytes, not the ceiling -- the distinction the capture
      // table depends on.
      expect(snapshot.retainedPayloadBytes, isNot(snapshot.retainedPayloadByteBudget));
      expect(snapshot.retainedPayloadBytes, greaterThanOrEqualTo(0));
      encodeGate.complete();
      await until(() => controller.debugInflightBytes == 0);
    });
  });

  // ---- WP1.4: decode parallelism is independent of the retention tier -----
  group('decode parallelism is independent of the retention tier', () {
    DecodedRgba decodedFixture() {
      final rgba = Uint8List(4 * 4 * 4);
      for (var i = 0; i < rgba.length; i += 4) {
        rgba[i + 3] = 0xFF;
      }
      return DecodedRgba(rgba: rgba, width: 4, height: 4);
    }

    Future<NativeImageResult> needsRawDecodeLoader(
      String path, {
      required ImageRequestPurpose purpose,
      int? targetLongEdge,
    }) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

    ImagePreloadController build({
      required RetentionPolicy retention,
      required int decodeLaneWidth,
      required Future<DecodedRgba> Function(String path) decoder,
    }) => ImagePreloadController(
      imageLoader: needsRawDecodeLoader,
      dngDecoder: (path) => decoder(path),
      payloadEncoder:
          (rgba, {required width, required height, required quality}) async =>
              Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]),
      decodeLaneWidth: decodeLaneWidth,
      retention: retention,
    );

    TestWidgetsFlutterBinding.ensureInitialized();

    // TC-1136 (AC1, S1.4)
    test('every retention tier yields the same decode byte budget at a given '
        'lane width', () {
      final budgets = <int>{};
      for (final tier in RetentionTier.values) {
        final built = build(
          retention: retentionPolicyForTier(tier),
          decodeLaneWidth: 4,
          decoder: (path) async => decodedFixture(),
        );
        addTearDown(built.dispose);
        budgets.add(built.debugDecodeInflightByteBudget);
        // ...and the same after arriving at the tier through setRetention.
        final switched = build(
          retention: const RetentionPolicy.floor(),
          decodeLaneWidth: 4,
          decoder: (path) async => decodedFixture(),
        );
        addTearDown(switched.dispose);
        switched.setRetention(retentionPolicyForTier(tier));
        budgets.add(switched.debugDecodeInflightByteBudget);
      }
      expect(budgets, hasLength(1));
      expect(budgets.single, 5 * kNominalFullFrameBytes);
    });

    // TC-1137 (AC1) -- the headline case: the retention tier no longer caps
    // how many RAW decodes the BYTE GATE will admit at once.
    //
    // Measured on the GATED ledger, not on raw decoder entries. A plain
    // "peak concurrent decoder calls" count does NOT discriminate here: this
    // script also runs unbudgeted decodes off the lane, and BOTH the old and
    // the new code reach 4 decoder entries (measured, standalone probe
    // 2026-09-11). What actually changed is what the byte gate permits:
    //
    //   BEFORE (retention-derived, conservative tier = 256 MiB budget):
    //     debugByteBlockedPumps = 3, decode ledger pinned at 2 nominal frames
    //   AFTER  (lane-width-derived, width 4 -> 5 nominal frames):
    //     debugByteBlockedPumps = 0, decode ledger reaches 4 nominal frames
    //
    // Both readings were captured by running the identical script against the
    // pre-change production files (git HEAD) and against this change.
    test('the conservative tier no longer caps admitted decode concurrency',
        () async {
      final gate = Completer<void>();
      var decoderEntries = 0;
      final controller = build(
        retention: retentionPolicyForTier(RetentionTier.conservative),
        decodeLaneWidth: 4,
        decoder: (path) async {
          decoderEntries++;
          await gate.future;
          return decodedFixture();
        },
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(32, 32);
      unawaited(
        controller.preloadImages(
          items: [
            for (final id in ['a', 'b', 'c', 'd', 'e'])
              PhotoItem(id: id, files: [File('/tmp/$id.dng')]),
          ],
          selectedItemId: 'a',
          notifyLoaded: () {},
        ),
      );
      // Four decodes held open at their full NOMINAL pre-decode charge is
      // exactly 4x kNominalFullFrameBytes on the decode ledger; under the old
      // retention-derived budget this could never exceed 2.
      await until(
        () => controller.debugDecodeInflightBytes >= 4 * kNominalFullFrameBytes,
        reason: 'the byte gate to admit four concurrent full-frame decodes',
      );
      expect(
        controller.debugByteBlockedPumps,
        0,
        reason: 'the tier must not refuse a single admission at width 4',
      );
      expect(decoderEntries, greaterThanOrEqualTo(4));
      gate.complete();
      await until(() => controller.debugInflightBytes == 0);
    });
  });
}
