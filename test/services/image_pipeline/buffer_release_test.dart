import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ceyx/ceyx.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/decode_lane.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/raw_full_res_image.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_registry.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_scheduler.dart';

import '../../support/preload_fixtures.dart';

/// WP6b (gc-remediation plan, Steps 7.7-7.11): the native buffer a pooled
/// decode hands over is returned to `CeyxNativeBufferPool` at end-of-
/// consumption.
///
/// Since T6 (mem8 SR-2) that is EVERY outcome: `decodedRgbaToPixelPayload`'s
/// identity short-circuit returns an owned copy, so no retained payload
/// aliases the pooled buffer. `decodedRgbaToOrientedFullRes` still hands out
/// `decoded.rgba` itself, but only as the transient `fullRes` record whose
/// last use is the release site.
void main() {
  group('buffer_release_test.dart', () {
    /// A 4x4 OPAQUE RGBA frame, orientation 1 -- so the full-res path takes
    /// the identity short-circuit (the aliasing branch under test) and no
    /// `ui.Image` handle is created.
    DecodedRgba decodedFixture({void Function()? releaseNative}) {
      final rgba = Uint8List(4 * 4 * 4);
      for (var i = 0; i < rgba.length; i += 4) {
        rgba[i] = 0x40;
        rgba[i + 1] = 0x80;
        rgba[i + 2] = 0xC0;
        rgba[i + 3] = 0xFF;
      }
      return DecodedRgba(
        rgba: rgba,
        width: 4,
        height: 4,
        releaseNative: releaseNative,
      );
    }

    List<PhotoItem> twoRawItems() => [
      for (final id in ['a', 'b'])
        PhotoItem(id: id, files: [File('/tmp/$id.dng')]),
    ];

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
    }) {
      return ImagePreloadController(
        imageLoader: needsRawDecodeLoader,
        dngDecoder: (path) => decoder(path),
        payloadEncoder: encoder,
        decodeLaneWidth: 1,
      );
    }

    Future<void> pumpMicrotasks([int rounds = 24]) async {
      for (var i = 0; i < rounds; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    TestWidgetsFlutterBinding.ensureInitialized();

    // TC-1052 -- success path: the JPEG is a fresh Dart buffer, so nothing
    // aliases the native one and it goes back to the pool.
    test('an EncodedPayload success releases the native buffer', () async {
      // Counted PER PATH, not as one total: both preloaded items decode, so a
      // bare total of 2 cannot distinguish "each item released once" (correct)
      // from "item a released twice" (a double-free against the pool).
      final released = <String, int>{};
      // BOUNDED WAIT, not a pump count. The release happens in
      // `_finishOffLane`'s `finally`, one await AFTER `_completeOutcome`
      // publishes -- so a fixed number of pump rounds can legitimately stop
      // between "payload is visible" and "buffer is returned", which is what
      // made this test fail in the full suite and pass alone. Waiting on the
      // event itself is strictly stronger than pumping N times: it still
      // fails (by timeout) if the release never fires at all.
      final firstRelease = Completer<void>();
      final controller = buildController(
        decoder: (path) async => decodedFixture(
          releaseNative: () {
            released[path] = (released[path] ?? 0) + 1;
            if (!firstRelease.isCompleted) firstRelease.complete();
          },
        ),
        encoder:
            (rgba, {required width, required height, required quality}) async =>
                Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]),
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(32, 32);

      await controller.preloadImages(
        items: twoRawItems(),
        selectedItemId: 'a',
        notifyLoaded: () {},
      );
      await firstRelease.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail(
          'the native buffer was never returned to the pool within 5s '
          '(this is the mutation-B signature, not a slow machine)',
        ),
      );
      // Extra pumping AFTER the wait, so a spurious SECOND release would still
      // be caught by the exactly-once assertions below.
      await pumpMicrotasks();

      expect(controller.payloadFor('a'), isA<EncodedPayload>());
      // AC7.6: exactly once per decode, not "at least once".
      expect(released['/tmp/a.dng'], 1);
      expect(
        released.values,
        everyElement(1),
        reason: 'no buffer may be returned to the pool twice',
      );
    });

    // TC-1278 -- T6 (mem8 SR-2). The identity short-circuit now hands back an
    // OWNED COPY, so an encode failure on a small frame publishes a
    // PixelPayload that aliases nothing and the pooled slot goes back. This
    // replaces TC-1053/TC-1272, which asserted the retained aliasing T6
    // deleted.
    //
    // The 0xA5 poison probe is kept and flipped: it now proves the payload is
    // a COPY. The release DOES fire, overwriting the decoder buffer; if the
    // alias were still in place the retained payload's pixels would read
    // 0xA5 instead of the fixture's 0x40.
    test('a small frame + encode failure releases the pooled slot', () async {
      final released = <String, int>{};
      final fixtureBytes = <String, Uint8List>{};
      final firstRelease = Completer<void>();
      final controller = buildController(
        decoder: (path) async {
          final decoded = decodedFixture(
            // POISON PROBE: the release overwrites the decoder buffer, so a
            // reintroduced alias is caught as CORRUPTION of the displayed
            // payload, not merely as a count.
            releaseNative: () {
              released[path] = (released[path] ?? 0) + 1;
              final bytes = fixtureBytes[path]!;
              bytes.fillRange(0, bytes.length, 0xA5);
              if (!firstRelease.isCompleted) firstRelease.complete();
            },
          );
          fixtureBytes[path] = decoded.rgba;
          return decoded;
        },
        encoder:
            (rgba, {required width, required height, required quality}) async =>
                throw StateError('encoder down'),
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(32, 32);

      await controller.preloadImages(
        items: twoRawItems(),
        selectedItemId: 'a',
        notifyLoaded: () {},
      );
      await firstRelease.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail(
          'the pooled slot was never returned within 5s -- SR-2 requires it '
          'to be released on the pixel-fallback outcome too',
        ),
      );
      // Extra pumping AFTER the wait, so a spurious SECOND release would still
      // be caught by the exactly-once assertion below.
      await pumpMicrotasks();

      expect(controller.payloadFor('a'), isA<PixelPayload>());
      expect(released['/tmp/a.dng'], 1);
      expect(
        released.values,
        everyElement(1),
        reason: 'no buffer may be returned to the pool twice',
      );
      final payload = controller.payloadFor('a')! as PixelPayload;
      expect(
        payload.rgba.take(4),
        orderedEquals(<int>[0x40, 0x80, 0xC0, 0xFF]),
        reason: 'the retained payload is an OWNED COPY; the release above '
            'poisoned the decoder buffer with 0xA5, and seeing 0xA5 here '
            'would mean the T6 alias is back',
      );
    });

    /// A 4x4 opaque frame declared with EXIF orientation 6, so the full-res
    /// path ROTATES: `decodedRgbaToOrientedFullRes` returns a fresh readback
    /// plus a non-null `ui.Image` (decoded_rgba_image_provider.dart:308-316).
    Future<NativeImageResult> rotatedLoader(
      String path, {
      required ImageRequestPurpose purpose,
      int? targetLongEdge,
    }) async => const NativeImageNeedsRawDecode(exifOrientation: 6);

    // TC-1271 -- rotated encode-failure path: the retained PixelPayload is a
    // GPU readback, so the native buffer has no reader and goes back.
    test('a rotated PixelPayload fallback DOES release the native buffer',
        () async {
      final released = <String, int>{};
      final firstRelease = Completer<void>();
      final controller = ImagePreloadController(
        imageLoader: rotatedLoader,
        dngDecoder: (path) async => decodedFixture(
          releaseNative: () {
            released[path] = (released[path] ?? 0) + 1;
            if (!firstRelease.isCompleted) firstRelease.complete();
          },
        ),
        payloadEncoder:
            (rgba, {required width, required height, required quality}) async =>
                throw StateError('encoder down'),
        pointerPayloadEncoder: null,
        decodeLaneWidth: 1,
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(32, 32);

      await controller.preloadImages(
        items: twoRawItems(),
        selectedItemId: 'a',
        notifyLoaded: () {},
      );
      await firstRelease.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail(
          'the rotated fallback never returned the native buffer within 5s',
        ),
      );
      await pumpMicrotasks();

      expect(controller.payloadFor('a'), isA<PixelPayload>());
      expect(released['/tmp/a.dng'], 1);
      expect(
        released.values,
        everyElement(1),
        reason: 'no buffer may be returned to the pool twice',
      );
    });


    // -----------------------------------------------------------------------
    // T7 (mem8 SR-3): the identity path's pooled slot is returned at its LAST
    // READ -- the piggyback materialize -- not in `_finishOffLane`'s terminal
    // `finally`.
    //
    // WHY THESE TESTS EXIST AS A PAIR. The frozen spec's Step 7.2 placed the
    // release at the encode's return. That is use-after-release: on the
    // identity path `fullRes.rgba` IS the pooled slot (the transient aliasing
    // T6 deliberately kept), and `publishPiggybackFullRes` still reads it
    // through `ui.decodeImageFromPixels` AFTER the encode. The failure mode is
    // a torn or wholly wrong tier-2 frame -- no crash, no exception, and
    // nothing in the pre-existing suite goes red. A test that merely asserts
    // the callback fires would not have caught it either.
    //
    // So the sentinel below is a PAIRED POSITIVE CONTROL, in the shape the
    // deleted `buffer_release_p6_downscale_test` used: the SAME assertion, the
    // SAME fixture, the SAME read-back, run twice with only the poison MOMENT
    // moved. It reads BROKEN for the spec's 7.2 placement and INTACT for B'.
    // The poison stands in for the successor decode that the pool hands the
    // returned slot to -- that is what a real early release loses the pixels
    // to, and 0xA5 makes it legible instead of merely probable.
    // -----------------------------------------------------------------------
    group('T7 SR-3: release at the piggyback materialize', () {
      /// The scheduler, stripped to what `publishPiggybackFullRes` needs: a
      /// registry, a window containing `a`, and `payload` as `a`'s current
      /// payload so neither the pre-check nor the post-await re-check refuses.
      ({TierTwoScheduler scheduler, TierTwoRegistry registry}) harnessFor(
        SourcePayload payload,
      ) {
        SourcePayload? payloadFor(String id) => id == 'a' ? payload : null;
        final registry = TierTwoRegistry(currentPayloadFor: payloadFor);
        final scheduler = TierTwoScheduler(
          registry: registry,
          lane: DecodeLane(width: 1),
          currentPayloadFor: payloadFor,
          fullSizeProviderFor: (p) => throw StateError('not reached'),
          ensurePayload:
              (
                item, {
                required int distance,
                required VoidCallback? notifyLoaded,
                bool onSerialLane = false,
              }) async {},
          dngDecoder: () => null,
          exifOrientationFor: (id) => 1,
          navigationDebounce: Duration.zero,
        );
        scheduler.updateWindow([
          PhotoItem(id: 'a', files: [File('/tmp/a.dng')]),
        ], 0);
        return (scheduler: scheduler, registry: registry);
      }

      /// The pixels the ImageCache actually holds for [id].
      ///
      /// The registry keeps no reference to the `ui.Image` (invariant I5) and
      /// `RawFullResImage._image` is private, so this takes the route a widget
      /// takes: resolve the published provider and read the delivered frame.
      /// `RawFullResImage` is ONE-SHOT, but `publishFullRes` already resolved
      /// it, so this second resolve is served by the ImageCache's existing
      /// completer rather than by a second `loadImage`.
      Future<Uint8List> publishedPixels(
        TierTwoRegistry registry,
        String id,
      ) async {
        final key = registry.keyFor(id);
        expect(
          key,
          isA<RawFullResImage>(),
          reason: 'nothing was published, so there are no pixels to compare -- '
              'this is a broken fixture, not a passing assertion',
        );
        final result = Completer<Uint8List>();
        final stream = (key! as RawFullResImage).resolve(
          ImageConfiguration.empty,
        );
        late ImageStreamListener listener;
        listener = ImageStreamListener(
          (info, _) async {
            stream.removeListener(listener);
            final data = await info.image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            result.complete(data!.buffer.asUint8List());
          },
          onError: (error, _) {
            stream.removeListener(listener);
            result.completeError(error);
          },
        );
        stream.addListener(listener);
        return result.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () =>
              fail('the published tier-2 frame never delivered within 5s'),
        );
      }

      /// One arm of the sentinel. Publishes a 4x4 identity-path record whose
      /// `rgba` is filled with the fixture pattern, poisoning that buffer with
      /// 0xA5 either BEFORE the publish (the spec's 7.2 release point, where
      /// the slot is already back in the pool by then) or from inside
      /// `onPixelsConsumed` (B', the shipped placement). Returns the pixels the
      /// ImageCache ended up with.
      Future<Uint8List> publishThenRead({
        required bool poisonBeforePublish,
      }) async {
        final payload = EncodedPayload(Uint8List.fromList([0xFF, 0xD8]));
        final h = harnessFor(payload);
        final rgba = Uint8List(4 * 4 * 4);
        for (var i = 0; i < rgba.length; i += 4) {
          rgba[i] = 0x40;
          rgba[i + 1] = 0x80;
          rgba[i + 2] = 0xC0;
          rgba[i + 3] = 0xFF;
        }
        void poison() => rgba.fillRange(0, rgba.length, 0xA5);
        if (poisonBeforePublish) poison();
        await h.scheduler.publishPiggybackFullRes(
          'a',
          payload,
          (rgba: rgba, width: 4, height: 4, image: null, releaseNative: null),
          () {},
          distance: 0,
          onPixelsConsumed: poisonBeforePublish ? null : poison,
        );
        return publishedPixels(h.registry, 'a');
      }

      // TC-1282 -- the RED arm, kept in the suite as the positive control.
      // Releasing the slot at the encode's return (the frozen spec's 7.2) lets
      // the next decode write into the buffer this publish has not read yet:
      // the frame the user sees is the successor's pixels, silently.
      test(
        'TC-1282 (positive control): a slot reused BEFORE the materialize '
        'publishes the wrong pixels',
        () async {
          final pixels = await publishThenRead(poisonBeforePublish: true);
          expect(
            pixels.take(4),
            orderedEquals(<int>[0xA5, 0xA5, 0xA5, 0xA5]),
            reason: 'this arm exists to prove the sentinel CAN read broken. If '
                'it ever reads the fixture pattern the probe has gone blind '
                'and TC-1283 below is worthless.',
          );
        },
      );

      // TC-1283 -- the shipped placement (B'). Same sentinel, same read-back;
      // only the poison moment moved to `onPixelsConsumed`.
      test(
        'TC-1283: releasing at onPixelsConsumed publishes intact pixels',
        () async {
          final pixels = await publishThenRead(poisonBeforePublish: false);
          expect(
            pixels.take(4),
            orderedEquals(<int>[0x40, 0x80, 0xC0, 0xFF]),
            reason: 'the engine copies the pixels out of `fullRes.rgba` before '
                'the materialize completer resolves, and `onPixelsConsumed` '
                'fires after that -- so a slot returned there can no longer '
                'corrupt this frame. 0xA5 here means the callback moved above '
                'the copy.',
          );
        },
      );

      // TC-1284 -- the ordering pin, in the new shape the N-2-class invariant
      // took. Three facts, all observable from the callback itself:
      //   * it fires exactly once on the upload path;
      //   * it fires BEFORE the publish lands (that IS the SR-3 win: the slot
      //     is not held across the staleness re-check, the pacer and the
      //     publish);
      //   * it does NOT fire on the supplied-handle path, which never reads
      //     `fullRes.rgba` at all -- there the rotated release site inside
      //     `decodedRgbaToOrientedFullRes` already returned the slot and
      //     `_finishOffLane`'s net covers the rest.
      test('TC-1284: onPixelsConsumed fires once, before the publish lands',
          () async {
        final payload = EncodedPayload(Uint8List.fromList([0xFF, 0xD8]));
        final h = harnessFor(payload);
        var calls = 0;
        Object? keyAtCallback = 'unset';
        await h.scheduler.publishPiggybackFullRes(
          'a',
          payload,
          (
            rgba: Uint8List(4 * 4 * 4),
            width: 4,
            height: 4,
            image: null,
            releaseNative: null,
          ),
          () {},
          distance: 0,
          onPixelsConsumed: () {
            calls++;
            keyAtCallback = h.registry.keyFor('a');
          },
        );
        expect(calls, 1, reason: 'exactly one release per outcome');
        expect(
          keyAtCallback,
          isNull,
          reason: 'the publish had not landed yet when the slot was handed '
              'back -- if this is non-null the callback has drifted below '
              '`_publishOrDiscard` and SR-3 buys nothing on the identity path',
        );
        expect(h.registry.keyIds, contains('a'));
      });

      // TC-1287 -- T8 (mem8 SR-4), chain audit B.7b(1): the CATCH-UP upgrade
      // path returns its pooled slot.
      //
      // `_upgradeFullRes` decodes a RAW file and hands the frame to
      // `decodedRgbaToImage`, and before T8 NOBODY called `releaseNative` on
      // it -- not the scheduler, not the provider. The slot came back only
      // when Dart's garbage collector got around to running ceyx's safety-net
      // Finalizer, which is precisely the GC-dependent return SR-4 deletes.
      //
      // Driven the way TC-1221 drives it: a band slot still holding a
      // temporary PixelPayload buys a real file decode on band entry, which
      // is the one route into `_upgradeFullRes` a unit test can take.
      test('TC-1287: the catch-up upgrade path releases its pooled slot',
          () async {
        var released = 0;
        final payloads = <String, SourcePayload>{};
        final registry = TierTwoRegistry(
          currentPayloadFor: (id) => payloads[id],
        );
        final scheduler = TierTwoScheduler(
          registry: registry,
          lane: DecodeLane(width: 5),
          currentPayloadFor: (id) => payloads[id],
          // The real production mapping, NOT a throwing stub: the five
          // EncodedPayload band entrants legitimately ask for a provider, and
          // a stub that throws makes this test fail for a reason that has
          // nothing to do with slot release (it did, on the first run).
          fullSizeProviderFor: (p) => switch (p) {
            EncodedPayload(:final bytes) => fullSizeProviderFor(bytes),
            PixelPayload() => throw StateError(
              'the pixel slot must take the FILE DECODE route, not a provider',
            ),
          },
          ensurePayload:
              (
                item, {
                required int distance,
                required VoidCallback? notifyLoaded,
                bool onSerialLane = false,
              }) async {},
          // Identity orientation: without it `_upgradeFullRes` takes its
          // markFullResFailure early return BEFORE the decode, and the spy
          // would read 0 for the wrong reason.
          exifOrientationFor: (id) => 1,
          dngDecoder: () => (path) async {
            final rgba = Uint8List(2 * 2 * 4);
            // Opaque: the identity short-circuit in the provider asserts it.
            for (var i = 3; i < rgba.length; i += 4) {
              rgba[i] = 0xFF;
            }
            return DecodedRgba(
              rgba: rgba,
              width: 2,
              height: 2,
              releaseNative: () => released++,
            );
          },
          navigationDebounce: const Duration(seconds: 10),
        );
        addTearDown(scheduler.cancelDebounce);
        addTearDown(registry.clear);

        final items = photoItems(6, idPrefix: 'a', dir: '/tmp');
        for (final item in items) {
          payloads[item.id] = item.id == 'a3'
              ? PixelPayload(rgba: Uint8List(2 * 2 * 4), width: 2, height: 2)
              : freshEncodedPayload();
        }

        scheduler.schedule(items, 2, () {});
        await until(
          () => scheduler.debugBandEntryFileDecodeCount > 0,
          reason: "a3's pixel-state band entry to buy its file decode",
        );
        // The decode is bought BEFORE the release site; give the rest of the
        // upgrade a bounded chance to run rather than asserting into a race.
        await until(
          () => released > 0,
          reason: 'the upgrade path to return its pooled slot',
        );

        expect(
          released,
          1,
          reason: 'SR-4: the catch-up upgrade must hand its slot back '
              'EXPLICITLY. Reading 0 means the slot is returned only when the '
              "GC runs ceyx's safety-net Finalizer -- a leak for as long as "
              'the collector takes, and the defect chain audit B.7b(1) names.',
        );
      });

      // TC-1286 -- the CONTROLLER-level pin, and the only test here that goes
      // red when the B' wiring is removed.
      //
      // WHY IT EXISTS. TC-1282/1283/1284 drive `publishPiggybackFullRes`
      // directly, so they are blind to whether `_finishOffLane` actually
      // passes a callback; TC-1285's pool counters were MEASURED to stay green
      // with that wiring deleted (tmp/verify/t7-ac-discrimination.txt). Without
      // this test the entire controller half of SR-3 could be dropped and the
      // suite would not notice.
      //
      // THE OBSERVABLE. The selected item is pacer-EXEMPT, so its tier-2 entry
      // lands SYNCHRONOUSLY inside `publishPiggybackFullRes`. That splits the
      // two placements on an ORDERING, not on a duration:
      //   * B'           -> release fires at the materialize, BEFORE the entry
      //                     is registered, so the registry has no key yet;
      //   * finally-only -> release fires after `_completeOutcome` returns, by
      //                     which time the key is there.
      test('TC-1286: the pooled slot goes back BEFORE the tier-2 entry lands',
          () async {
        late ImagePreloadController controller;
        final firstRelease = Completer<void>();
        // Sampled INSIDE the release callback: the question is what was true
        // at the MOMENT of release, which nothing observed afterwards can
        // reconstruct.
        bool? tierTwoLandedAtRelease;
        controller = buildController(
          decoder: (path) async => decodedFixture(
            releaseNative: () {
              tierTwoLandedAtRelease ??= controller.debugTierTwoKeyIds.contains(
                'a',
              );
              if (!firstRelease.isCompleted) firstRelease.complete();
            },
          ),
          encoder:
              (rgba, {required width, required height, required quality}) async
                  => Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]),
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(32, 32);

        await controller.preloadImages(
          items: twoRawItems(),
          selectedItemId: 'a',
          notifyLoaded: () {},
        );
        await firstRelease.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('the pooled slot was never returned within 5s'),
        );
        await pumpMicrotasks();

        // Fixture guard: if the piggyback never published at all, the
        // assertion below would read false for the wrong reason.
        expect(
          controller.debugTierTwoKeyIds,
          contains('a'),
          reason: 'no tier-2 entry ever landed, so the ordering assertion '
              'below is vacuous',
        );
        expect(
          tierTwoLandedAtRelease,
          isFalse,
          reason: 'SR-3: the slot must be back in the pool at the materialize, '
              'BEFORE the staleness re-check, the pacer and the publish. '
              'Reading true means the release has fallen back to '
              "`_finishOffLane`'s terminal `finally` -- the exact state this "
              'task removed.',
        );
      });

      // TC-1285 -- the burst AC, against the REAL pool.
      //
      // `debugWaitsForCapacity` is incremented inside `CeyxNativeBufferPool.
      // acquire` itself, on exactly the at-cap-nothing-idle path, so this is
      // the pool's own counter and not a harness reimplementation of it. A
      // second navigation wave of 8 decodes must find all 8 slots free: if the
      // first wave is still holding its slots through the encode-publish tail,
      // the wave-2 acquires queue on `_waiting` and the counter moves.
      test('TC-1285: a second width-8 wave never waits for pool capacity',
          () async {
        final pool = CeyxNativeBufferPool(maxBuffers: 8);
        addTearDown(pool.debugDisposeIdle);
        // Captured, never invoked: every non-selected publish stays parked in
        // the pacer for the whole test, so wave 2 runs while wave 1's frames
        // are still queued -- the state the old `finally`-only release held
        // its slots across.
        final parkedFrames = <void Function()>[];
        var decoderCalls = 0;
        List<PhotoItem> wave(String tag) => [
          for (var i = 0; i < 8; i++)
            PhotoItem(id: '$tag$i', files: [File('/tmp/$tag$i.dng')]),
        ];

        final controller = ImagePreloadController(
          imageLoader: needsRawDecodeLoader,
          dngDecoder: (path) async {
            decoderCalls++;
            final buffer = await pool.acquire(4 * 4 * 4);
            // The REAL native memory, not a Dart copy: `rgba` has to be the
            // pooled slot for the release point to mean anything.
            final bytes = Pointer<Uint8>.fromAddress(
              buffer.address,
            ).asTypedList(4 * 4 * 4);
            for (var i = 0; i < bytes.length; i += 4) {
              bytes[i] = 0x40;
              bytes[i + 1] = 0x80;
              bytes[i + 2] = 0xC0;
              bytes[i + 3] = 0xFF;
            }
            return DecodedRgba(
              rgba: bytes,
              width: 4,
              height: 4,
              releaseNative: () => pool.release(buffer),
            );
          },
          payloadEncoder:
              (rgba, {required width, required height, required quality}) async
                  => Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]),
          decodeLaneWidth: 8,
          scheduleFrameCallback: parkedFrames.add,
          navigationDebounce: Duration.zero,
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(32, 32);

        await controller.preloadImages(
          items: wave('w1-'),
          selectedItemId: 'w1-0',
          notifyLoaded: () {},
        );
        await pumpMicrotasks(80);
        await controller.preloadImages(
          items: wave('w2-'),
          selectedItemId: 'w2-0',
          notifyLoaded: () {},
        );
        await pumpMicrotasks(80);

        // FIXTURE GUARD, not an AC. A zero-wait count is trivially true for a
        // pool nothing ever asked for a buffer, which is exactly how this test
        // would rot if the fake loader or the lane width drifted -- and it is
        // how the first draft of this test passed while measuring nothing.
        //
        // Counted HERE rather than off `pool.debugCheckedOut`: that field is a
        // CURRENT gauge (incremented on acquire, DECREMENTED on release), so
        // it reads 0 both for "every slot came back" and for "no decode ever
        // ran". Two opposite states, one reading -- not usable as evidence.
        expect(
          decoderCalls,
          greaterThanOrEqualTo(4),
          reason: 'the burst never reached the pooled decoder, so every '
              'counter below is measuring nothing',
        );
        // The positive form of AC2: every slot that was handed out came back
        // by an EXPLICIT release. Equality (not >=) is what makes a leaked
        // slot and a double release both visible.
        expect(pool.debugExplicitReleases, decoderCalls);
        expect(pool.debugCheckedOut, 0);
        expect(
          pool.debugWaitsForCapacity,
          0,
          reason: 'AC: an 8-wide burst must never queue on pool capacity. A '
              'non-zero count means slots are still being held past their '
              'last read (chain audit B.7a).',
        );
        // Spec AC2: the GC must not be what returns slots -- a finalizer
        // release is a missed explicit one, not a success.
        expect(pool.debugFinalizerReleases, 0);
      });

      test('TC-1284b: a supplied handle never fires onPixelsConsumed',
          () async {
        final payload = EncodedPayload(Uint8List.fromList([0xFF, 0xD8]));
        final h = harnessFor(payload);
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder);
        final supplied = recorder.endRecording().toImageSync(4, 4);
        var calls = 0;
        await h.scheduler.publishPiggybackFullRes(
          'a',
          payload,
          (
            rgba: Uint8List(0),
            width: 4,
            height: 4,
            image: supplied,
            releaseNative: null,
          ),
          () {},
          distance: 0,
          onPixelsConsumed: () => calls++,
        );
        expect(
          calls,
          0,
          reason: 'this path never reads `fullRes.rgba`, so it has no '
              '"pixels consumed" moment to report; firing here would be a '
              'release the rotated site already performed',
        );
      });
    });
  });
}
