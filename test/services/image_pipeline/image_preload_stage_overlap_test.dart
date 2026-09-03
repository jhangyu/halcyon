// Plan Task 12 (S4): the stage-overlap guarantee and the bytes-in-flight bound.
//
// TC-841 / TC-842 / TC-839b
// (docs/logs/2026-09-03/plan-decode-optimizations.md).
//
// TC-841 is the mechanical PROOF that P3's stage split actually pipelines:
// before it, a lane task was decode-then-encode, so decode(B) could not begin
// until encode(A) had finished and the two intervals were strictly disjoint.
//
// Ticks are a monotonic counter, NOT a clock: every assertion is about ORDER,
// which is deterministic. No assertion here reads wall-clock time.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';

/// One recorded stage interval.
typedef Tick = ({String stage, String id, int enter, int exit});

/// A 4x4 OPAQUE RGBA frame (64 bytes). Alpha is 0xFF because the identity
/// short-circuit asserts sampled opacity in debug.
DecodedRgba decodedFixture() {
  final rgba = Uint8List(4 * 4 * 4);
  for (var i = 3; i < rgba.length; i += 4) {
    rgba[i] = 0xFF;
  }
  return DecodedRgba(rgba: rgba, width: 4, height: 4);
}

List<PhotoItem> rawItems(List<String> ids) => [
  for (final id in ids) PhotoItem(id: id, files: [File('/tmp/$id.dng')]),
];

/// Four RAW items: enough for the lane to still have work queued once the
/// first hand-off has happened, which is what makes the overlap observable.
List<PhotoItem> fourRawItems() => rawItems(['a', 'b', 'c', 'd']);

Future<NativeImageResult> _needsRawDecodeLoader(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

ImagePreloadController buildController({
  required Future<DecodedRgba> Function(String path) decoder,
  required Future<Uint8List> Function(
    Uint8List rgba, {
    required int width,
    required int height,
    required int quality,
  })
  encoder,
  int decodeLaneWidth = 1,
  int? inflightByteBudget,
}) {
  return ImagePreloadController(
    imageLoader: _needsRawDecodeLoader,
    dngDecoder: (path) => decoder(path),
    payloadEncoder: encoder,
    decodeLaneWidth: decodeLaneWidth,
    inflightByteBudget: inflightByteBudget,
  );
}

Future<void> pumpMicrotasks([int rounds = 40]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // TC-841 / TC-842 -- the stage-overlap proof.
  //
  // DETERMINISTIC BY CONSTRUCTION, not by timing: the first encode parks on a
  // Completer the test controls, so "decodes ran while an encode was in
  // flight" is decided by that gate and never by which of two delays happened
  // to be shorter. Before this task the lane body was decode-then-encode, so a
  // held encode held the lane slot too and NO further decode could enter --
  // the decode and encode intervals were strictly disjoint.
  test('a decode runs while the first encode is in flight, and decodes stay '
      'bounded', () async {
    var clock = 0;
    final ticks = <Tick>[];
    var concurrentDecodes = 0;
    var peakDecodes = 0;
    final firstEncodeGate = Completer<void>();
    var encodesStarted = 0;
    int? firstEncodeEnter;

    final controller = buildController(
      decodeLaneWidth: 1,
      decoder: (path) async {
        concurrentDecodes++;
        peakDecodes = peakDecodes > concurrentDecodes
            ? peakDecodes
            : concurrentDecodes;
        final enter = clock++;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        ticks.add((stage: 'decode', id: path, enter: enter, exit: clock++));
        concurrentDecodes--;
        return decodedFixture();
      },
      encoder:
          (rgba, {required width, required height, required quality}) async {
            final enter = clock++;
            if (encodesStarted++ == 0) {
              firstEncodeEnter = enter;
              await firstEncodeGate.future;
            }
            ticks.add((
              stage: 'encode',
              id: 'enc',
              enter: enter,
              exit: clock++,
            ));
            return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
          },
    );
    addTearDown(controller.dispose);
    controller.updateTargetSize(32, 32);

    unawaited(
      controller.preloadImages(
        items: fourRawItems(),
        selectedItemId: 'a',
        notifyLoaded: () {},
      ),
    );
    await pumpMicrotasks();

    // The first encode is STILL PARKED (its tick is not recorded yet), and
    // decodes entered after it started: the stages overlap.
    expect(firstEncodeEnter, isNotNull, reason: 'an encode must have started');
    expect(
      ticks.any((t) => t.stage == 'encode' && t.enter == firstEncodeEnter),
      isFalse,
      reason: 'the gate must still be holding the FIRST encode open',
    );
    expect(
      ticks.where((t) => t.stage == 'decode' && t.enter > firstEncodeEnter!),
      isNotEmpty,
      reason: 'a decode must start while the first encode is still running',
    );
    // TC-842: the pipelining must not have widened the decode stage.
    expect(peakDecodes, lessThanOrEqualTo(controller.decodeLaneWidth));

    firstEncodeGate.complete();
    await pumpMicrotasks();
    expect(controller.debugInflightBytes, 0);
  });

  // TC-839b -- the byte budget bounds the encode stage.
  //
  // Returns the PEAK number of encodes simultaneously in flight for the same
  // four-item script under the given budget. The companion case below runs the
  // identical script with a generous budget and observes 2, which is what
  // makes the budgeted assertion able to fail.
  Future<int> peakConcurrentEncodesWithBudget(int? budget) async {
    var concurrent = 0;
    var peak = 0;
    final controller = buildController(
      decodeLaneWidth: 2,
      inflightByteBudget: budget,
      decoder: (path) async {
        await Future<void>.delayed(const Duration(milliseconds: 2));
        return decodedFixture();
      },
      encoder:
          (rgba, {required width, required height, required quality}) async {
            concurrent++;
            peak = peak > concurrent ? peak : concurrent;
            await Future<void>.delayed(const Duration(milliseconds: 20));
            concurrent--;
            return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
          },
    );
    addTearDown(controller.dispose);
    controller.updateTargetSize(32, 32);
    unawaited(
      controller.preloadImages(
        items: fourRawItems(),
        selectedItemId: 'a',
        notifyLoaded: () {},
      ),
    );
    await pumpMicrotasks(300);
    expect(controller.debugInflightBytes, 0);
    return peak;
  }

  test('a byte budget below one frame serialises the encodes', () async {
    expect(await peakConcurrentEncodesWithBudget(1), 1);
  });

  test('a generous budget lets the same script overlap encodes', () async {
    expect(await peakConcurrentEncodesWithBudget(1 << 24), 2);
  });
}
