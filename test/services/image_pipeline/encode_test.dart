import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/encode_stage.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/jpeg_encoder.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_reencoder.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';

import '../../support/preload_fixtures.dart' show until;

void main() {
  group('encode_stage_test.dart', () {
    test('runningCount never exceeds width', () async {
      final stage = EncodeStage(width: 2);
      final gates = List.generate(10, (_) => Completer<void>());
      var peak = 0;
      for (final gate in gates) {
        unawaited(stage.run(() async {
          peak = peak > stage.runningCount ? peak : stage.runningCount;
          await gate.future;
        }));
      }
      await Future<void>.delayed(Duration.zero);
      expect(stage.runningCount, 2);
      for (final gate in gates) {
        gate.complete();
        await Future<void>.delayed(Duration.zero);
      }
      expect(peak, lessThanOrEqualTo(2));
      expect(stage.runningCount, 0);
    });

    test('start order is FIFO', () async {
      final stage = EncodeStage(width: 1);
      final started = <int>[];
      final gate = Completer<void>();
      unawaited(stage.run(() async {
        started.add(1);
        await gate.future;
      }));
      unawaited(stage.run(() async => started.add(2)));
      unawaited(stage.run(() async => started.add(3)));
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(started, [1, 2, 3]);
    });

    test('a throwing body reaches its own caller and does not wedge the stage',
        () async {
      final stage = EncodeStage(width: 1);
      await expectLater(
        stage.run(() async => throw StateError('encode failed')),
        throwsStateError,
      );
      expect(await stage.run(() async => 42), 42);
    });

    test('widening admits more bodies on the next microtask', () async {
      final stage = EncodeStage(width: 1);
      final gates = List.generate(3, (_) => Completer<void>());
      for (final gate in gates) {
        unawaited(stage.run(() => gate.future));
      }
      await Future<void>.delayed(Duration.zero);
      expect(stage.runningCount, 1);
      stage.width = 3;
      await Future<void>.delayed(Duration.zero);
      expect(stage.runningCount, 3);
      for (final gate in gates) {
        gate.complete();
      }
    });

    test('clear fails pending bodies and leaves running ones alone', () async {
      final stage = EncodeStage(width: 1);
      final gate = Completer<void>();
      unawaited(stage.run(() => gate.future));
      await Future<void>.delayed(Duration.zero);
      final pending = stage.run(() async => 1);
      stage.clear();
      await expectLater(pending, throwsStateError);
      expect(stage.runningCount, 1);
      gate.complete();
    });
  });

  group('image_preload_encode_stage_test.dart', () {
    // Plan Task 10 (S4): the JPEG re-encode runs OFF the DecodeLane.
    //
    // TC-828 / TC-829 / TC-830 (docs/logs/2026-09-03/plan-decode-optimizations.md).
    //
    // The lane body used to end after `PhotoSource.load`, which was decode THEN
    // encode -- so a ~89ms encode held a decode slot for all of it and lane
    // occupancy meant "decode + encode" rather than "decode". After this task the
    // lane body ends at `decodePhase` and the encode runs on `EncodeStage`.
    //
    // Every assertion here is about ORDER and OBJECT IDENTITY, never about
    // wall-clock time: the encoder is held open by a `Completer` the test controls,
    // so a build that still encodes inside the lane cannot pass by being fast.
    //
    // The fake decoder's buffer is OPAQUE (alpha 0xFF) because the identity
    // short-circuit in decoded_rgba_image_provider.dart asserts sampled alpha --
    // a zero-filled fixture would fail in debug for a reason unrelated to this
    // task.

    /// A 4x4 OPAQUE RGBA frame, orientation 1 -- so the source's full-res path
    /// takes the identity short-circuit and no `ui.Image` handle is created.
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

    List<PhotoItem> twoRawItems() => rawItems(['a', 'b']);

    /// 26 RAW items, 'a'..'z'. Navigating from 'a' to 'z' takes 'a' out of the
    /// retention window (-3..+5) entirely.
    List<PhotoItem> manyRawItems() =>
        rawItems([for (var c = 0; c < 26; c++) String.fromCharCode(0x61 + c)]);

    /// Every RAW item needs a real decode: the loader answers NeedsRawDecode, so
    /// the item is deferred to the serial lane exactly as a preview-less DNG is.
    Future<NativeImageResult> needsRawDecodeLoader(
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
    }) {
      return ImagePreloadController(
        imageLoader: needsRawDecodeLoader,
        dngDecoder: (path) => decoder(path),
        payloadEncoder: encoder,
        decodeLaneWidth: decodeLaneWidth,
      );
    }

    /// Drains the microtask queue and the zero-duration timer queue enough times
    /// for the probe, the lane hand-off and the off-lane continuation to run.
    /// Deterministic: every await in the path under test is either a microtask or
    /// a zero-duration delay.
    Future<void> pumpMicrotasks([int rounds = 24]) async {
      for (var i = 0; i < rounds; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    TestWidgetsFlutterBinding.ensureInitialized();

    // TC-828 -- the lane slot must be free while the encode is still running.
    test('the decode lane releases its slot before the encode completes', () async {
      final encodeGate = Completer<void>();
      final decodeStarts = <String>[];
      final controller = buildController(
        decoder: (path) async {
          decodeStarts.add(path);
          return decodedFixture();
        },
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
          items: twoRawItems(),
          selectedItemId: 'a',
          notifyLoaded: () {},
        ),
      );
      await pumpMicrotasks();

      // Item b's decode has started even though item a's encode has not finished.
      expect(
        decodeStarts.length,
        2,
        reason:
            'with lane width 1, b can only have decoded if a released its slot '
            'before its encode completed',
      );
      expect(controller.debugEncodeStageRunningCount, greaterThan(0));

      encodeGate.complete();
      await pumpMicrotasks();
      expect(controller.payloadFor('a'), isA<EncodedPayload>());
      expect(controller.debugEncodeStageRunningCount, 0);
    });

    // TC-829 -- the object in the cache is the encode result and is never
    // replaced by an interim PixelPayload.
    test('the payload written to the cache is final', () async {
      final controller = buildController(
        decoder: (path) async => decodedFixture(),
        encoder:
            (rgba, {required width, required height, required quality}) async =>
                Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]),
        decodeLaneWidth: 1,
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(32, 32);

      final observed = <SourcePayload?>[];
      await controller.preloadImages(
        items: twoRawItems(),
        selectedItemId: 'a',
        notifyLoaded: () => observed.add(controller.payloadFor('a')),
      );
      // BOUNDED WAIT, not a pump count: the off-lane encode continuation lands
      // the final payload one await after preloadImages resolves, so a fixed
      // pump count can legitimately stop between "resolved" and "landed",
      // which is what made this flake under load (Expected EncodedPayload,
      // Actual null).
      await until(
        () => controller.payloadFor('a') is EncodedPayload,
        reason: "the off-lane encode to land 'a's final EncodedPayload",
      );

      final landed = controller.payloadFor('a');
      expect(landed, isA<EncodedPayload>());
      // No notify ever saw a PixelPayload for this id: nothing interim was
      // published and swapped.
      expect(observed.whereType<PixelPayload>(), isEmpty);
      // Still the same object after the pipeline quiesces.
      expect(identical(controller.payloadFor('a'), landed), isTrue);
    });

    // TC-830 -- eviction between decode and encode.
    test('an id evicted mid-encode is not written to the cache', () async {
      final encodeGate = Completer<void>();
      var flushed = 0;
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
          items: manyRawItems(),
          selectedItemId: 'a',
          notifyLoaded: () => flushed++,
        ),
      );
      await pumpMicrotasks();
      // Navigate far enough that 'a' leaves the retention window (-3..+5).
      unawaited(
        controller.preloadImages(
          items: manyRawItems(),
          selectedItemId: 'z',
          notifyLoaded: () {},
        ),
      );
      await pumpMicrotasks();
      encodeGate.complete();
      await pumpMicrotasks();

      expect(controller.payloadFor('a'), isNull);
      expect(flushed, greaterThan(0), reason: 'no spinner may strand');
    });

    // TC-831c -- an encoder that throws still lands the PixelPayload fallback
    // through the new off-lane path.
    test('a throwing encoder still lands the pixel fallback', () async {
      final controller = buildController(
        decoder: (path) async => decodedFixture(),
        encoder:
            (rgba, {required width, required height, required quality}) async {
              throw StateError('encoder is down');
            },
        decodeLaneWidth: 1,
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(32, 32);

      await controller.preloadImages(
        items: twoRawItems(),
        selectedItemId: 'a',
        notifyLoaded: () {},
      );
      await pumpMicrotasks();

      expect(controller.payloadFor('a'), isA<PixelPayload>());
    });

    // TC-886 -- dispose() while an off-lane encode is in flight must not make the
    // continuation's byte release over-release the budget.
    //
    // The interleaving is FORCED, not raced: the encoder parks on a Completer the
    // test controls, so `dispose()` -> `InflightBytesBudget.clear()` provably
    // happens between the continuation's `acquire` and its `release`. Before the
    // epoch fix that release fired the `'_inFlight >= gave'` assertion, and
    // because it is an unawaited continuation the failure was attributed to
    // whichever test ran next.
    test(
      'dispose during an in-flight off-lane encode does not over-release the '
      'byte budget',
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
        controller.updateTargetSize(32, 32);

        unawaited(
          controller.preloadImages(
            items: twoRawItems(),
            selectedItemId: 'a',
            notifyLoaded: () {},
          ),
        );
        // The encode is now parked: bytes are acquired and not yet released.
        await pumpMicrotasks();

        controller.dispose();
        encodeGate.complete();
        // The continuation resumes here and runs its `finally` release.
        await pumpMicrotasks();
      },
    );

    // WP4 (docs/logs/2026-09-06/gc-remediation-plan.md Task 5) / spec AC6
    // half. On the rotated path (`fullRes.image != null`), the ~96MB `rgba`
    // readback's only consumer is the encoder, which has already returned by
    // the time this fires. This test fails if the double-hold (rgba retained
    // alongside the image through publish) ever comes back: before the fix,
    // `debugFullResBytesReleasedEarly` never increments.
    test(
      'the rotated path releases its rgba readback once the encoder is done',
      () async {
        // Orientation 3 (180deg, no mirror) is non-identity, so
        // decodedRgbaToOrientedFullRes renders a `ui.Image` and hands back a
        // non-null `image` -- the rotated path this test targets.
        Future<NativeImageResult> rotatedLoader(
          String path, {
          required ImageRequestPurpose purpose,
          int? targetLongEdge,
        }) async => const NativeImageNeedsRawDecode(exifOrientation: 3);

        final controller = ImagePreloadController(
          imageLoader: rotatedLoader,
          dngDecoder: (path) async => decodedFixture(),
          payloadEncoder:
              (rgba, {required width, required height, required quality}) async =>
                  Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]),
          decodeLaneWidth: 1,
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(32, 32);

        await controller.preloadImages(
          items: twoRawItems(),
          selectedItemId: 'a',
          notifyLoaded: () {},
        );
        await pumpMicrotasks();

        expect(
          controller.debugFullResBytesReleasedEarly,
          greaterThan(0),
          reason:
              'the rotated path full-res record must be shrunk before '
              'publish, dropping the readback whose only consumer (the '
              'encoder) has already returned',
        );
        // The shrink must not break the piggyback publish: the image handle
        // is still carried and lands in the tier-2 registry.
        expect(controller.fullResProviderFor('a'), isNotNull);
      },
    );

    // R2b (docs/logs/2026-09-06/gc-remediation-plan.md, production wiring):
    // a native-backed IDENTITY decode must be re-encoded through the pointer
    // entry, with the exact address/keepAlive `DecodedRgba` carried, and must
    // NOT touch the byte-copy encoder at all.
    test(
      'a native-backed identity decode uses the pointer encoder, not the '
      'byte-copy encoder',
      () async {
        final keeper = Object();
        var pointerCalls = 0;
        var copyCalls = 0;
        final controller = ImagePreloadController(
          imageLoader: needsRawDecodeLoader, // orientation 1 == identity
          dngDecoder: (path) async => DecodedRgba(
            rgba: decodedFixture().rgba,
            width: 4,
            height: 4,
            nativeAddress: 0x1234,
            nativeKeepAlive: keeper,
          ),
          payloadEncoder:
              (rgba, {required width, required height, required quality}) async {
                copyCalls++;
                return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
              },
          pointerPayloadEncoder:
              ({
                required nativeAddress,
                required width,
                required height,
                required quality,
                keepAlive,
              }) async {
                pointerCalls++;
                expect(nativeAddress, 0x1234);
                expect(identical(keepAlive, keeper), isTrue);
                return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
              },
          decodeLaneWidth: 1,
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(32, 32);

        await controller.preloadImages(
          items: rawItems(['a']),
          selectedItemId: 'a',
          notifyLoaded: () {},
        );
        await pumpMicrotasks();

        expect(pointerCalls, 1);
        expect(copyCalls, 0);
        expect(controller.payloadFor('a'), isA<EncodedPayload>());
      },
    );

    // R2b -- the gate must re-check `fullRes.image`, not just trust a
    // non-zero address: a ROTATED decode's `fullRes.rgba` is a fresh GPU
    // readback with no relation to the native address the decoder reported,
    // so even a native-backed decode must fall back to the byte-copy encoder
    // once orientation forces a GPU pass.
    test(
      'a native-backed ROTATED decode still uses the byte-copy encoder',
      () async {
        var pointerCalls = 0;
        var copyCalls = 0;
        Future<NativeImageResult> rotatedLoader(
          String path, {
          required ImageRequestPurpose purpose,
          int? targetLongEdge,
        }) async => const NativeImageNeedsRawDecode(exifOrientation: 3);

        final controller = ImagePreloadController(
          imageLoader: rotatedLoader,
          dngDecoder: (path) async => DecodedRgba(
            rgba: decodedFixture().rgba,
            width: 4,
            height: 4,
            nativeAddress: 0x1234,
            nativeKeepAlive: Object(),
          ),
          payloadEncoder:
              (rgba, {required width, required height, required quality}) async {
                copyCalls++;
                return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
              },
          pointerPayloadEncoder:
              ({
                required nativeAddress,
                required width,
                required height,
                required quality,
                keepAlive,
              }) async {
                pointerCalls++;
                return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
              },
          decodeLaneWidth: 1,
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(32, 32);

        await controller.preloadImages(
          items: rawItems(['a']),
          selectedItemId: 'a',
          notifyLoaded: () {},
        );
        await pumpMicrotasks();

        expect(pointerCalls, 0);
        expect(copyCalls, 1);
        expect(controller.payloadFor('a'), isA<EncodedPayload>());
      },
    );
  });

  group('jpeg_encoder_test.dart', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    // TC-360
    test('encodes RGBA8 to a JPEG bitstream of the same dimensions', () async {
      const w = 16, h = 16;
      final rgba = Uint8List(w * h * 4);
      for (var i = 0; i < rgba.length; i += 4) {
        rgba[i] = 0xFF; // R
        rgba[i + 3] = 0xFF; // A
      }

      final jpeg = await encodeJpegFromRgba(rgba, width: w, height: h, quality: 80);

      expect(jpeg.length, greaterThan(2));
      expect(jpeg[0], 0xFF, reason: 'JPEG SOI byte 0');
      expect(jpeg[1], 0xD8, reason: 'JPEG SOI byte 1');

      final codec = await ui.instantiateImageCodec(jpeg);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, w);
      expect(frame.image.height, h);
      frame.image.dispose();
    });
  });

  group('payload_reencoder_test.dart', () {
    PixelPayload pixelsRe(int w, int h) =>
        PixelPayload(rgba: Uint8List(w * h * 4), width: w, height: h);

    Future<Uint8List> okEncoderRe(
      Uint8List rgba, {
      required int width,
      required int height,
      required int quality,
    }) async => Uint8List(width * height); // 1 byte/pixel stand-in

    setUp(resetReencodeCounters);

    // TC-361
    test('encodes the FULL-RESOLUTION pixels into a plain EncodedPayload', () async {
      final result = await reencodePayload(
        encoder: okEncoderRe,
        fallback: () async => pixelsRe(10, 10),
        fullRes: (rgba: Uint8List(40 * 40 * 4), width: 40, height: 40),
      );
      expect(result, isA<EncodedPayload>());
      final encoded = result as EncodedPayload;
      expect(encoded.bytes.length, 1600, reason: 'full-res 40x40, not window 10x10');
      expect(encoded.byteCost, 1600);
      expect(reencodeFallbacks, 0);
    });

    // TC-362
    test('encoder failure falls back to the SAME PixelPayload', () async {
      final fallback = pixelsRe(10, 10);
      final result = await reencodePayload(
        encoder: (rgba, {required width, required height, required quality}) =>
            throw StateError('boom'),
        fallback: () async => fallback,
        fullRes: (rgba: Uint8List(16), width: 2, height: 2),
      );
      expect(identical(result, fallback), isTrue);
      expect(reencodeFallbacks, 1);
    });

    // TC-363
    test('absent full-resolution pixels fall back rather than encoding the window',
        () async {
      final fallback = pixelsRe(10, 10);
      final result = await reencodePayload(
        encoder: okEncoderRe,
        fallback: () async => fallback,
        fullRes: null,
      );
      expect(identical(result, fallback), isTrue,
          reason: 'never ship window-res pixels into the full-size tier');
      expect(reencodeFallbacks, 1);
    });

    // TC-368
    test('rgba shorter than width*height*4 falls back without calling the encoder',
        () async {
      final fallback = pixelsRe(10, 10);
      var encoderCalled = false;
      final result = await reencodePayload(
        encoder: (rgba, {required width, required height, required quality}) {
          encoderCalled = true;
          return okEncoderRe(rgba, width: width, height: height, quality: quality);
        },
        fallback: () async => fallback,
        // Claims 4x4 (needs 64 bytes) but only supplies 16 -- the native
        // encoder has no way to catch this itself (encode_ffi_api.cpp only
        // has the pointer + claimed dimensions), so the guard must be here.
        fullRes: (rgba: Uint8List(16), width: 4, height: 4),
      );
      expect(identical(result, fallback), isTrue);
      expect(encoderCalled, isFalse, reason: 'must not reach the native encoder');
      expect(reencodeFallbacks, 1);
    });

    // TC-412
    test('reencodePayload defaults to quality 70', () async {
      resetReencodeCounters();
      final seen = <int>[];
      Future<Uint8List> spy(
        Uint8List rgba, {
        required int width,
        required int height,
        required int quality,
      }) async {
        seen.add(quality);
        return Uint8List.fromList(<int>[1, 2, 3]);
      }

      final fallback = PixelPayload(
        rgba: Uint8List(2 * 2 * 4),
        width: 2,
        height: 2,
      );
      final out = await reencodePayload(
        encoder: spy,
        fallback: () async => fallback,
        fullRes: (rgba: Uint8List(2 * 2 * 4), width: 2, height: 2),
      );

      expect(kReencodeJpegQuality, 70);
      expect(seen, <int>[70]);
      expect(out, isA<EncodedPayload>());
      expect(reencodeFallbacks, 0);
    });
  });
}
