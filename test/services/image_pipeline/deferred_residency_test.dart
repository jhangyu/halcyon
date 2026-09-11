// Tasks 3 and 4 (compressed-residency v2): the deferred full-size decode+encode
// path, and the ONE controlled payload replacement it feeds.
//
// Spec v2 §3.2 / AC-5. A slot that could not produce its full-size JPEG at
// re-encode time keeps a TEMPORARY PixelPayload and gets a background-priority
// job that produces the JPEG and replaces the payload. The replacement is the
// most dangerous write in this round: payload object identity is the tier-1
// ImageCache key AND the tier-2 registry's readiness anchor, so the swap must
// retire both BEFORE it lands (spec §4, ordered retire-then-put).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/decode_lane.dart';
import 'package:halcyon_flutter/services/image_pipeline/deferred_full_size_encoder.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/lane_priority.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_reencoder.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';

import '../../support/preload_fixtures.dart';

Future<NativeImageResult> _needsRawDecodeLoader(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

DecodedRgba _frame(int width, int height) {
  final rgba = Uint8List(width * height * 4);
  for (var i = 3; i < rgba.length; i += 4) {
    rgba[i] = 0xFF;
  }
  return DecodedRgba(rgba: rgba, width: width, height: height);
}

/// The deferred full-size encode is OPT-IN at the controller (null supplier =>
/// abandon before decoding), so every controller in THIS file -- the file that
/// exists to exercise that path -- must bind the supplier EXPLICITLY. These
/// two named decoders exist so the `dngDecoder` and the `deferredEncodeDecoder`
/// arguments can be the SAME object, which is what production does.
Future<DecodedRgba> _decode60x40(String path) async => _frame(60, 40);

Future<DecodedRgba> _decode6000x4000(String path) async => _frame(6000, 4000);

List<PhotoItem> _rawItems(List<String> ids) => [
  for (final id in ids) PhotoItem(id: id, files: [File('/tmp/$id.dng')]),
];

PixelPayload _pixels(int width, int height) => PixelPayload(
  rgba: Uint8List(width * height * 4),
  width: width,
  height: height,
);

void main() {
  late ImageCache imageCache;
  late int originalMaximumSizeBytes;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    imageCache = PaintingBinding.instance.imageCache;
    originalMaximumSizeBytes = imageCache.maximumSizeBytes;
    imageCache.maximumSizeBytes = 256 << 20;
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  tearDown(() {
    imageCache.maximumSizeBytes = originalMaximumSizeBytes;
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  group('deferred_residency_test.dart', () {
    test(
      'TC-A5 (AC-5 liveness) a slot whose INLINE encode failed acquires a '
      'full-size JPEG payload through the deferred path, carrying the '
      "decoder's FULL-RESOLUTION dimensions",
      () async {
        var encodeCalls = 0;
        final controller = ImagePreloadController(
          imageLoader: _needsRawDecodeLoader,
          dngDecoder: _decode60x40,
          deferredEncodeDecoder: () => _decode60x40,
          payloadEncoder:
              (rgba, {required width, required height, required quality}) async {
                encodeCalls++;
                if (encodeCalls == 1) throw StateError('inline encode refused');
                return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
              },
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(32, 32);

        unawaited(
          controller.preloadImages(
            items: _rawItems(['a']),
            selectedItemId: 'a',
            notifyLoaded: () {},
          ),
        );

        await until(
          () => controller.debugPayloadFor('a') is EncodedPayload,
          reason: 'the deferred job replaced the temporary pixel payload',
        );
        final payload = controller.debugPayloadFor('a')! as EncodedPayload;
        expect(payload.width, 60);
        expect(payload.height, 40);
        expect(controller.debugDeferredCompletedCount, 1);
      },
    );

    test(
      'TC-A6 (AC-5 never below full size) the deferred path publishes the '
      'FULL-RESOLUTION frame, never the window-resolution downscale',
      () async {
        // 6000x4000 frame, 2800px preview long edge: if the job ever fed the
        // window-resolution buffer to the encoder, these dimensions would come
        // back at the downscaled size instead.
        final encodedSizes = <String>[];
        var encodeCalls = 0;
        final controller = ImagePreloadController(
          imageLoader: _needsRawDecodeLoader,
          dngDecoder: _decode6000x4000,
          deferredEncodeDecoder: () => _decode6000x4000,
          payloadEncoder:
              (rgba, {required width, required height, required quality}) async {
                encodeCalls++;
                encodedSizes.add('${width}x$height');
                if (encodeCalls == 1) throw StateError('inline encode refused');
                expect(quality, kReencodeJpegQuality);
                return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
              },
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(2800, 2800);

        unawaited(
          controller.preloadImages(
            items: _rawItems(['a']),
            selectedItemId: 'a',
            notifyLoaded: () {},
          ),
        );

        await until(
          () => controller.debugPayloadFor('a') is EncodedPayload,
          reason: 'the deferred job landed',
        );
        final payload = controller.debugPayloadFor('a')! as EncodedPayload;
        expect(payload.width, 6000);
        expect(payload.height, 4000);
        // The encoder was handed the full-resolution buffer, both times.
        expect(encodedSizes.last, '6000x4000');
      },
    );

    test(
      'TC-A7 (identity discipline) the replacement retires the tier-2 registry '
      'entry and the tier-1 key anchored on the OLD payload, and changes which '
      'ids are retained not at all',
      () async {
        var encodeCalls = 0;
        // The DEFERRED encode is held here until the test has observed the
        // temporary pixel payload. Without this gate the job lands inside the
        // same microtask chain as the retention write, so `until`'s first
        // 10ms poll already sees the REPLACEMENT and the test can never take
        // hold of the `previous` object it exists to make assertions about.
        // Holding the encoder is the narrowest possible gate: it changes the
        // job's timing and nothing about its logic or its guards.
        final releaseDeferredEncode = Completer<void>();
        final controller = ImagePreloadController(
          imageLoader: _needsRawDecodeLoader,
          dngDecoder: _decode60x40,
          deferredEncodeDecoder: () => _decode60x40,
          payloadEncoder:
              (rgba, {required width, required height, required quality}) async {
                encodeCalls++;
                if (encodeCalls == 1) throw StateError('inline encode refused');
                await releaseDeferredEncode.future;
                return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
              },
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(32, 32);

        unawaited(
          controller.preloadImages(
            items: _rawItems(['a', 'b']),
            selectedItemId: 'a',
            notifyLoaded: () {},
          ),
        );
        await until(
          () => controller.debugPayloadFor('a') is PixelPayload,
          reason: 'the temporary pixel payload is retained first',
        );
        final previous = controller.debugPayloadFor('a')!;
        final retentionBefore = controller.debugRetentionIds.toSet();

        releaseDeferredEncode.complete();
        await until(
          () => !identical(controller.debugPayloadFor('a'), previous),
          reason: 'the deferred replacement lands',
        );

        expect(controller.debugPayloadFor('a'), isA<EncodedPayload>());
        // The registry anchored on the OLD object must not still claim it.
        expect(controller.debugHasFullResEntryFor('a', previous), isFalse);
        // No id was added or dropped by the replacement.
        expect(controller.debugRetentionIds.toSet(), retentionBefore);
      },
    );

    test(
      'TC-A8 (abandonment) each failure mode leaves the slot exactly as it '
      'was, counts ONE abandonment, and never schedules a second job for the '
      'same payload object',
      () async {
        Future<void> check(
          String label, {
          DngFullDecoder? decoder,
          required PayloadEncoder encoder,
        }) async {
          final lane = DecodeLane(width: 1);
          final payload = _pixels(4, 4);
          final cache = <String, SourcePayload>{'a': payload};
          var replacements = 0;
          final deferred = DeferredFullSizeEncoder(
            lane: lane,
            dngDecoder: () => decoder,
            encoder: encoder,
            exifOrientationFor: (id) => 1,
            currentPayloadFor: (id) => cache[id],
            isRetained: (id) => cache.containsKey(id),
            onEncoded: (id, previous, replacement) {
              replacements++;
              cache[id] = replacement;
            },
            awaitIdleSlot: () async {},
          );

          deferred.schedule(
            _rawItems(['a']).single,
            previous: payload,
            distance: 0,
          );
          await until(
            () => deferred.debugAbandonedCount == 1,
            reason: '$label abandons exactly once',
          );
          expect(identical(cache['a'], payload), isTrue, reason: label);
          expect(replacements, 0, reason: label);

          // A second schedule for the SAME payload object is refused: failure
          // is never retried in a loop (the discipline TierTwoRegistry's
          // `_fullResFailures` memo already follows -- it dies with the
          // payload, and so does this one).
          deferred.schedule(
            _rawItems(['a']).single,
            previous: payload,
            distance: 0,
          );
          expect(deferred.debugScheduledCount, 1, reason: label);
        }

        Future<Uint8List> goodEncoder(
          Uint8List rgba, {
          required int width,
          required int height,
          required int quality,
        }) async => Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);

        await check('no decoder', decoder: null, encoder: goodEncoder);
        await check(
          'decoder throws',
          decoder: (path) async => throw StateError('decode failed'),
          encoder: goodEncoder,
        );
        await check(
          'encoder throws',
          decoder: (path) async => _frame(4, 4),
          encoder: throwingPayloadEncoder,
        );
        await check(
          'empty JPEG',
          decoder: (path) async => _frame(4, 4),
          encoder:
              (rgba, {required width, required height, required quality}) async =>
                  Uint8List(0),
        );
      },
    );

    test(
      'TC-A10 (AC-1 end to end) a controller whose INLINE encode throws and '
      'whose deferred encode succeeds reaches a steady state with ZERO pixel '
      'entries retained and non-zero encoded bytes',
      () async {
        var encodeCalls = 0;
        final controller = ImagePreloadController(
          imageLoader: _needsRawDecodeLoader,
          dngDecoder: _decode60x40,
          deferredEncodeDecoder: () => _decode60x40,
          payloadEncoder:
              (rgba, {required width, required height, required quality}) async {
                encodeCalls++;
                if (encodeCalls == 1) throw StateError('inline encode refused');
                return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
              },
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(32, 32);

        unawaited(
          controller.preloadImages(
            items: _rawItems(['a', 'b', 'c']),
            selectedItemId: 'a',
            notifyLoaded: () {},
          ),
        );

        await until(
          () =>
              controller
                      .debugMemoryLedgerSnapshot
                      .payloadCachePixelEntryCount ==
                  0 &&
              controller.debugRetentionIds.length == 3,
          reason: 'every retained slot reached its encoded form',
        );
        final snapshot = controller.debugMemoryLedgerSnapshot;
        expect(snapshot.payloadCachePixelEntryCount, 0);
        expect(snapshot.payloadCachePixelByteTotal, 0);
        expect(snapshot.payloadCacheEncodedByteTotal, greaterThan(0));
      },
    );

    test(
      'TC-A11 the INLINE success path records the full-resolution dimensions '
      'it encoded at',
      () async {
        final controller = ImagePreloadController(
          imageLoader: _needsRawDecodeLoader,
          dngDecoder: _decode60x40,
          deferredEncodeDecoder: () => _decode60x40,
          payloadEncoder:
              (rgba, {required width, required height, required quality}) async =>
                  Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]),
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(32, 32);

        unawaited(
          controller.preloadImages(
            items: _rawItems(['a']),
            selectedItemId: 'a',
            notifyLoaded: () {},
          ),
        );
        await until(
          () => controller.debugPayloadFor('a') is EncodedPayload,
          reason: 'the inline re-encode landed',
        );

        final payload = controller.debugPayloadFor('a')! as EncodedPayload;
        expect(payload.width, 60);
        expect(payload.height, 40);
        // No deferred job was needed for a slot that encoded inline.
        expect(controller.debugDeferredCompletedCount, 0);
      },
    );

    test(
      'TC-A12 with an encoder that throws on EVERY call the slot still '
      'renders: the payload survives the deferred abandonment and no id '
      'leaves the retention window',
      () async {
        final controller = ImagePreloadController(
          imageLoader: _needsRawDecodeLoader,
          dngDecoder: _decode60x40,
          deferredEncodeDecoder: () => _decode60x40,
          payloadEncoder: throwingPayloadEncoder,
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(32, 32);

        unawaited(
          controller.preloadImages(
            items: _rawItems(['a']),
            selectedItemId: 'a',
            notifyLoaded: () {},
          ),
        );
        await until(
          () => controller.debugPayloadFor('a') is PixelPayload,
          reason: 'the temporary pixel payload is retained',
        );
        final previous = controller.debugPayloadFor('a')!;
        await until(
          () => controller.debugDeferredAbandonedCount == 1,
          reason: 'the deferred job abandoned on the throwing encoder',
        );

        // The slot keeps EXACTLY what it had: an abandonment must never turn
        // an encode failure into a blank slot.
        expect(identical(controller.debugPayloadFor('a'), previous), isTrue);
        expect(controller.debugRetentionIds, contains('a'));
      },
    );

    test(
      'TC-A13 the deferred residency job COSTS one extra decode of the same '
      'path when the supplier is bound, and costs nothing at all when it is '
      'left at its default',
      () async {
        // This case pins BOTH sides of the opt-in shape. The pre-existing
        // decode-arithmetic tests (TC-078, P4, M5-DW4, M5-DW5, TC-098c,
        // TC-367, TC-430) never name the parameter and therefore observe the
        // `false` arm's numbers; the `true` arm is the only thing standing
        // between "the deferred path is off by default in tests" and "the
        // deferred path does not work at all", which would otherwise be
        // indistinguishable across the whole suite.
        Future<int> decodesOfA({required bool withDeferredDecoder}) async {
          var decodeCalls = 0;
          var encodeCalls = 0;
          Future<DecodedRgba> decoder(String path) async {
            decodeCalls++;
            return _frame(60, 40);
          }

          final controller = ImagePreloadController(
            imageLoader: _needsRawDecodeLoader,
            dngDecoder: decoder,
            payloadEncoder:
                (rgba, {required width, required height, required quality}) async {
                  encodeCalls++;
                  // Inline encode fails -> the slot lands in the TEMPORARY
                  // pixel form -> a deferred job is scheduled. The deferred
                  // encode succeeds, so the only reason it could fail to
                  // complete is the decoder it is handed.
                  if (encodeCalls == 1) throw StateError('inline encode refused');
                  return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
                },
            // Null in the `false` arm is EXACTLY what omitting the argument
            // gives -- which is what every pre-existing test does.
            deferredEncodeDecoder: withDeferredDecoder ? () => decoder : null,
          );
          addTearDown(controller.dispose);
          controller.updateTargetSize(32, 32);
          unawaited(
            controller.preloadImages(
              items: _rawItems(['a']),
              selectedItemId: 'a',
              notifyLoaded: () {},
            ),
          );
          if (withDeferredDecoder) {
            await until(
              () => controller.debugDeferredCompletedCount == 1,
              reason: 'the deferred job completed on the available decoder',
            );
            expect(controller.debugPayloadFor('a'), isA<EncodedPayload>());
          } else {
            await until(
              () => controller.debugDeferredAbandonedCount == 1,
              reason: 'the deferred job abandoned for want of a decoder',
            );
            // Abandoning must not blank the slot: the temporary pixel form is
            // still what the slot renders from.
            expect(controller.debugPayloadFor('a'), isA<PixelPayload>());
            expect(controller.debugDeferredCompletedCount, 0);
          }
          return decodeCalls;
        }

        expect(
          await decodesOfA(withDeferredDecoder: true),
          2,
          reason:
              'with a decoder the deferred job re-decodes the ORIGINAL file at '
              'full resolution -- exactly one extra decode of the same path',
        );
        expect(
          await decodesOfA(withDeferredDecoder: false),
          1,
          reason:
              'leaving the supplier at its default removes that decode and '
              'nothing else',
        );
      },
    );

    test(
      'TC-A9 the deferred band is the LAST LaneGroup member, so every existing '
      'priority band keeps the base it had',
      () {
        expect(LaneGroup.values.last, LaneGroup.deferredResidency);
        expect(laneBaseFor(LaneGroup.selected), 0);
        expect(laneBaseFor(LaneGroup.navigationWindow), 1000);
        expect(laneBaseFor(LaneGroup.fullRes), 2000);
        expect(laneBaseFor(LaneGroup.sidebarVisible), 3000);
        expect(laneBaseFor(LaneGroup.sidebarMargin), 4000);
        expect(laneBaseFor(LaneGroup.deferredResidency), 5000);
        // Lowest priority: even the farthest sidebar-margin row outranks the
        // nearest deferred residency job.
        expect(
          deferredResidencyPriorityFor(0),
          greaterThan(
            sidebarPriorityFor(index: 999, safeStart: 0, safeEnd: 1),
          ),
        );
      },
    );
  });
}
