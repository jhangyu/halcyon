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

void main() {
  group('inflightByteBudgetFor', () {
    // TC-1042
    test('the in-flight budget fits at least two real frames', () {
      const floor = RetentionPolicy.floor();
      expect(
        inflightByteBudgetFor(floor),
        greaterThanOrEqualTo(2 * kNominalFullFrameBytes),
      );
      expect(
        inflightByteBudgetFor(floor),
        greaterThan(kNominalFullFrameBytes),
      );
    });

    // TC-1042b
    test('a policy with a larger payload budget wins over the two-frame floor',
        () {
      const big = RetentionPolicy(
        before: 3,
        after: 5,
        payloadByteBudget: 4 * kNominalFullFrameBytes,
      );
      expect(inflightByteBudgetFor(big), 4 * kNominalFullFrameBytes);
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

    // TC-1044
    test('a full lane never blocks on bytes', () async {
      final controller = buildController(
        decoder: (path) async => decodedFixture(),
        decodeLaneWidth: 2,
        inflightByteBudget: kNominalFullFrameBytes, // room for ONE frame
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(32, 32);
      await controller
          .preloadImages(
            items: rawItems(['a', 'b', 'c', 'd']),
            selectedItemId: 'a',
            notifyLoaded: () {},
          )
          .timeout(const Duration(seconds: 5));
      await pumpMicrotasks(64);
      for (final id in ['a', 'b', 'c', 'd']) {
        expect(controller.payloadFor(id), isNotNull, reason: '$id never completed');
      }
      expect(
        controller.debugByteBlockedPumps,
        greaterThan(0),
        reason: 'the byte gate must actually have refused an admission',
      );
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
      for (var i = 0; i < 64; i++) {
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
  });
}
