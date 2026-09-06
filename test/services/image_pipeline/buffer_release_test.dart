import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
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
    test('a PixelPayload fallback does NOT release the aliased buffer',
        () async {
      var released = 0;
      final controller = buildController(
        decoder: (path) async =>
            decodedFixture(releaseNative: () => released++),
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
    });
  });
}
