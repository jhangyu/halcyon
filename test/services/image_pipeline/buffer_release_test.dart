import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/decoded_rgba_image_provider.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';

/// WP6b (gc-remediation plan, Steps 7.7-7.11): the native buffer a pooled
/// decode hands over is returned to `CeyxNativeBufferPool` at end-of-
/// consumption -- but ONLY when the published payload does not alias it.
///
/// The aliasing hazard is not hypothetical: `decodedRgbaToOrientedFullRes`'s
/// identity short-circuit returns `decoded.rgba` ITSELF
/// (decoded_rgba_image_provider.dart:259-264), so a RETAINED `PixelPayload`
/// IS the native buffer. Returning it would hand live, displayed pixels to
/// the next decode. On that branch ownership transfers to the cache and
/// ceyx's NativeFinalizer safety net reclaims it later.
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

    // TC-1053 -- encode-failure path: the retained PixelPayload aliases the
    // native buffer, so it must NOT be returned to the pool.
    // TC-1272 poison probe added: a wrong release corrupts the payload's
    // pixels, not merely a wrong count.
    test('a PixelPayload fallback does NOT release the aliased buffer',
        () async {
      var released = 0;
      late Uint8List fixtureBytes;
      final controller = buildController(
        decoder: (path) async {
          final decoded = decodedFixture(
            // POISON PROBE (TC-1272): a wrong release is caught as
            // CORRUPTION of the displayed payload, not merely as a count.
            // This assertion still fires if someone deletes the
            // `released == 0` check below.
            releaseNative: () {
              released++;
              fixtureBytes.fillRange(0, fixtureBytes.length, 0xA5);
            },
          );
          fixtureBytes = decoded.rgba;
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
      await pumpMicrotasks();

      expect(controller.payloadFor('a'), isA<PixelPayload>());
      expect(
        released,
        0,
        reason: 'the retained PixelPayload aliases this buffer '
            '(decoded_rgba_image_provider.dart:259-264)',
      );
      final payload = controller.payloadFor('a')! as PixelPayload;
      expect(
        payload.rgba.take(4),
        orderedEquals(<int>[0x40, 0x80, 0xC0, 0xFF]),
        reason: 'TC-1272: the retained payload ALIASES the native buffer, so '
            'a wrong release would have overwritten these pixels with 0xA5',
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

    // TC-1270 -- the release decision, as a pure predicate. Today's semantics:
    // only a published EncodedPayload frees the buffer.
    group('canReleaseNativeBuffer (TC-1270)', () {
      OrientedFullRes fullResWith({required bool rotated}) => (
        rgba: Uint8List(4 * 4 * 4),
        width: 4,
        height: 4,
        image: rotated ? _RotatedMarker.image : null,
        releaseNative: () {},
      );

      test('no pooled buffer means nothing to release', () {
        expect(
          canReleaseNativeBuffer(fullRes: null, published: null),
          isFalse,
        );
      });

      test('an EncodedPayload releases on both paths', () {
        final encoded = EncodedPayload(Uint8List.fromList([1, 2, 3]));
        expect(
          canReleaseNativeBuffer(
            fullRes: fullResWith(rotated: false),
            published: encoded,
          ),
          isTrue,
        );
      });

      test('an aliasing PixelPayload does NOT release', () {
        // MUST be the SAME rgba object as fullRes.rgba -- the predicate's
        // identity path clause now discriminates on object identity
        // (TC-1275/TC-1276), so a distinct buffer here would silently stop
        // testing aliasing at all.
        final aliased = fullResWith(rotated: false);
        expect(
          canReleaseNativeBuffer(
            fullRes: aliased,
            published: PixelPayload(
              rgba: aliased.rgba,
              width: 4,
              height: 4,
            ),
          ),
          isFalse,
        );
      });

      // TC-1274 -- nothing published means no reader exists for the buffer.
      test('TC-1274: nothing published means the buffer has no reader', () {
        expect(
          canReleaseNativeBuffer(
            fullRes: fullResWith(rotated: false),
            published: null,
          ),
          isTrue,
        );
      });

      // TC-1275/TC-1276 -- P6 downscale sub-case (r6 plan Task 5, small-scope
      // ruling): `photo_source.dart`'s `buildFallback` calls
      // `decodedRgbaToPixelPayload` on the identity path, which has its OWN
      // identity short-circuit gated on `longEdge`. When the decoded frame is
      // larger than the requested long edge, that short-circuit is skipped and
      // a fresh GPU readback runs -- `published.rgba` is then a DIFFERENT
      // object from `fullRes.rgba`, not an alias of the pooled buffer.
      // `identical()` is the exact, zero-cost discriminator; positive-control
      // evidence against real production code:
      // buffer_release_p6_downscale_test.dart.
      test(
        'TC-1275: identity path, PixelPayload NOT aliasing fullRes.rgba '
        '(downscale sub-case) -> releases',
        () {
          final aliased = fullResWith(rotated: false); // image: null
          final freshRgba = Uint8List(64); // different object from aliased.rgba
          expect(
            canReleaseNativeBuffer(
              fullRes: aliased,
              published: PixelPayload(rgba: freshRgba, width: 4, height: 4),
            ),
            isTrue,
          );
        },
      );

      test(
        'TC-1276: identity path, PixelPayload aliasing fullRes.rgba -> does '
        'NOT release (unchanged P6 proper)',
        () {
          final aliased = fullResWith(rotated: false);
          expect(
            canReleaseNativeBuffer(
              fullRes: aliased,
              published: PixelPayload(
                rgba: aliased.rgba,
                width: 4,
                height: 4,
              ),
            ),
            isFalse,
          );
        },
      );
    });
  });
}

/// A single 1x1 handle used ONLY as a non-null marker for
/// `OrientedFullRes.image` in predicate tests. The predicate never draws it.
class _RotatedMarker {
  static final ui.Image image = _make();
  static ui.Image _make() {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder);
    return recorder.endRecording().toImageSync(1, 1);
  }
}
