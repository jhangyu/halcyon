import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ceyx/ceyx.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/decode_lane.dart';
import 'package:halcyon_flutter/services/image_pipeline/decoded_rgba_image_provider.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/retention_policy.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_registry.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_scheduler.dart';

import '../../support/preload_fixtures.dart';
import '../../support/loader_stubs.dart';
import '../../support/event_loop.dart';

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
  group('buffer release', () {
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
      await pumpEventLoop(24);

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
      await pumpEventLoop(24);

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

    // TC-1271 -- rotated encode-failure path: the retained PixelPayload is a
    // GPU readback, so the native buffer has no reader and goes back.
    test('a rotated PixelPayload fallback DOES release the native buffer',
        () async {
      final released = <String, int>{};
      final firstRelease = Completer<void>();
      final controller = ImagePreloadController(
        imageLoader: needsRawDecodeLoaderOrientation6,
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
      await pumpEventLoop(24);

      expect(controller.payloadFor('a'), isA<PixelPayload>());
      expect(released['/tmp/a.dng'], 1);
      expect(
        released.values,
        everyElement(1),
        reason: 'no buffer may be returned to the pool twice',
      );
    });


    // -----------------------------------------------------------------------
    // SR-4: no pooled slot may come back only because the garbage collector
    // ran ceyx's safety-net `Finalizer`. Since the q70 decouple the identity
    // path releases its planar slot inside `encodePhase`, so what is left to
    // pin here are the SURVIVING RGBA arms: the catch-up file decode, the
    // provider's error paths, and the burst behaviour of the real pool.
    // -----------------------------------------------------------------------
    group('pooled-slot release on the surviving RGBA arms', () {
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
        await pumpEventLoop(80);
        await controller.preloadImages(
          items: wave('w2-'),
          selectedItemId: 'w2-0',
          notifyLoaded: () {},
        );
        await pumpEventLoop(80);

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

      // TC-1288 / TC-1288b / TC-1289 -- T8 follow-up (reviewer SF-1), the
      // ERROR PATH of the two provider-side release sites.
      //
      // SR-4 says no slot return may depend on the garbage collector. The
      // release lines added by T7/T8 sit AFTER the materialize, unguarded: if
      // `gate()` or `_imageFromPixels` throws, the exception leaves the
      // function above them and the slot comes back only when ceyx's
      // safety-net `Finalizer` runs -- the very shape SR-4 deletes, surviving
      // on the failure branch. Counted with EXACT equality, because the fix
      // must not turn the success-path release into a double release.
      group('provider error paths return the pooled slot', () {
        test('TC-1288: a throwing gate still returns the slot '
            '(decodedRgbaToImage)', () async {
          var released = 0;
          final decoded = decodedFixture(releaseNative: () => released++);
          await expectLater(
            decodedRgbaToImage(
              decoded,
              // Non-identity, so the gate is actually bought.
              exifOrientation: 6,
              gate: () async => throw StateError('gate refused'),
            ),
            throwsStateError,
          );
          expect(
            released,
            1,
            reason: 'SR-4: a refused pacing slot must not strand the pooled '
                'buffer until the GC runs the safety-net Finalizer',
          );
        });

        test('TC-1288b: a throwing materialize still returns the slot '
            '(decodedRgbaToImage)', () async {
          var released = 0;
          // Dimensions disagree with the buffer, which
          // `_assertDecodedBufferLength` rejects from INSIDE
          // `_imageFromPixels` -- a throw at the materialize itself rather
          // than at the gate.
          final decoded = DecodedRgba(
            rgba: Uint8List(4 * 4 * 4),
            width: 8,
            height: 8,
            releaseNative: () => released++,
          );
          await expectLater(
            decodedRgbaToImage(decoded, exifOrientation: 1),
            throwsArgumentError,
          );
          expect(
            released,
            1,
            reason: 'SR-4: a failed materialize must hand the slot back '
                'explicitly, not leave it to the finalizer',
          );
        });

        test('TC-1289: a throwing gate still returns the slot '
            '(decodedRgbaToOrientedFullRes, rotated)', () async {
          var released = 0;
          final decoded = decodedFixture(releaseNative: () => released++);
          await expectLater(
            decodedRgbaToOrientedFullRes(
              decoded,
              // Rotated: the identity short-circuit returns ABOVE the gate and
              // deliberately hands the handle to the caller instead of
              // releasing, so only a rotated frame reaches the site under
              // test.
              exifOrientation: 6,
              gate: () async => throw StateError('gate refused'),
            ),
            throwsStateError,
          );
          expect(
            released,
            1,
            reason: 'SR-4: the rotated full-res path must return its slot on '
                'the failure branch too',
          );
        });

        test('TC-1289b: the identity short-circuit still does NOT release',
            () async {
          var released = 0;
          final decoded = decodedFixture(releaseNative: () => released++);
          final record = await decodedRgbaToOrientedFullRes(
            decoded,
            exifOrientation: 1,
          );
          expect(
            released,
            0,
            reason: 'the identity path transfers the handle to the caller '
                '(it travels on the record); releasing here would free a '
                "buffer the controller's terminal net owns",
          );
          expect(record.releaseNative, isNotNull);
        });
      });
    });

    // q70-decouple R1 (2026-09-29): the planar-encode carry's cancellation net
    // and the absence of an RGBA shrink on the planar success path.
    group('R1 planar encode carry', () {
      const w = 8, h = 8;

      Future<
          ({
            ImagePreloadController controller,
            Map<String, Completer<void>> gates,
            int Function() releases,
            int Function() encoderCalls,
          })> planarHarness(List<PhotoItem> items, RetentionPolicy retention) async {
        final bytes = ceyxOutputFormatByteCount(CeyxOutputFormat.yuv420, w, h);
        final slots = <CeyxNativeBuffer>[];
        final gates = <String, Completer<void>>{};
        var releases = 0;
        var encoderCalls = 0;
        final controller = ImagePreloadController(
          imageLoader: needsRawDecodeLoader,
          dngDecoder: (path) async {
            final id = path.split('/').last.split('.').first;
            final gate = gates.putIfAbsent(id, Completer<void>.new);
            await gate.future;
            final slot = await CeyxNativeBufferPool.shared.acquire(bytes);
            slots.add(slot);
            return DecodedRgba(
              rgba: Pointer<Uint8>.fromAddress(slot.address).asTypedList(bytes),
              width: w,
              height: h,
              format: CeyxOutputFormat.yuv420,
              nativeAddress: slot.address,
              nativeKeepAlive: slot,
              releaseNative: () => releases++,
            );
          },
          payloadEncoder: (rgba, {required width, required height, required quality}) async =>
              Uint8List.fromList([1, 2, 3]),
          pointerYuv420PayloadEncoder: ({
            required nativeAddress,
            required srcCapacity,
            required width,
            required height,
            required quality,
            keepAlive,
          }) async {
            encoderCalls++;
            return Uint8List.fromList([1, 2, 3]);
          },
          decodeLaneWidth: 1,
          retention: retention,
        );
        addTearDown(() {
          controller.dispose();
          for (final s in slots) {
            CeyxNativeBufferPool.shared.release(s);
          }
        });
        return (
          controller: controller,
          gates: gates,
          releases: () => releases,
          encoderCalls: () => encoderCalls,
        );
      }

      Future<void> until(bool Function() cond) async {
        for (var i = 0; i < 400 && !cond(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(cond(), isTrue, reason: 'condition never became true');
      }

      test('R1: a generation bump before encodePhase releases the planar slot '
          'once', () async {
        final items = twoRawItems();
        final hn = await planarHarness(
          items,
          const RetentionPolicy(before: 0, after: 1, payloadByteBudget: 1 << 30),
        );
        final c = hn.controller;
        c.updateTargetSize(32, 32);
        c.preloadImages(items: items, selectedItemId: 'a', notifyLoaded: () {});
        await until(() => hn.gates.containsKey('a'));
        // Move the window off 'a' entirely, then let its decode finish.
        c.setRetention(
          const RetentionPolicy(before: 0, after: 0, payloadByteBudget: 1 << 30),
        );
        c.preloadImages(items: items, selectedItemId: 'b', notifyLoaded: () {});
        await Future<void>.delayed(Duration.zero);

        hn.gates['a']!.complete();
        await until(() => c.debugCancelledDownstreamCount == 1);

        expect(hn.releases(), 1);
        expect(hn.encoderCalls(), 0);
      });

      test('R1: no RGBA shrink runs when the outcome carries no fullRes',
          () async {
        final items = [twoRawItems().first];
        final hn = await planarHarness(
          items,
          const RetentionPolicy(before: 0, after: 0, payloadByteBudget: 1 << 30),
        );
        final c = hn.controller;
        c.updateTargetSize(32, 32);
        c.preloadImages(items: items, selectedItemId: 'a', notifyLoaded: () {});
        await until(() => hn.gates.containsKey('a'));
        hn.gates['a']!.complete();
        await until(() => hn.encoderCalls() == 1);
        await until(() => hn.releases() == 1);

        expect(c.debugShrinkAfterEncodeCalls, 0);
      });
    });
  });
}
