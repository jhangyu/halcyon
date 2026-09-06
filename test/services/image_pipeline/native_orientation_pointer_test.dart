// Task 8 (native-rotation-spec.md): PhotoSource's orienting decoder seam.
//
// This round has no real oriented ceyx entry (Tasks 3-5 land later), so every
// case here drives a FAKE `DngOrientingFullDecoder` -- exactly what the spec
// intends for this round (Task 8 is re-verified against the real dylib in
// round 3). AC-8.6 (full suite green, analyze 0) is verified by the test
// runner outside this file.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_reencoder.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A 4x8 OPAQUE RGBA frame, alpha 0xFF so the identity short-circuit's
  /// sampled-opaque assert in `decoded_rgba_image_provider.dart` holds.
  Uint8List opaqueRgba(int width, int height) {
    final rgba = Uint8List(width * height * 4);
    for (var i = 0; i < rgba.length; i += 4) {
      rgba[i] = 0x40;
      rgba[i + 1] = 0x80;
      rgba[i + 2] = 0xC0;
      rgba[i + 3] = 0xFF;
    }
    return rgba;
  }

  List<PhotoItem> rawItems(List<String> ids) => [
        for (final id in ids) PhotoItem(id: id, files: [File('/tmp/$id.dng')]),
      ];

  /// Every RAW item needs a real decode, declaring orientation 6 (the AC-8.1
  /// fixture's rotation): the loader answers NeedsRawDecode so the item is
  /// deferred to the serial lane exactly as a preview-less DNG is.
  Future<NativeImageResult> needsRawDecodeLoaderOrientation6(
    String path, {
    required ImageRequestPurpose purpose,
    int? targetLongEdge,
  }) async => const NativeImageNeedsRawDecode(exifOrientation: 6);

  Future<void> pumpMicrotasks([int rounds = 24]) async {
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  group('native_orientation_pointer_test.dart', () {
    // AC-8.1 / AC-8.4: a fake orienting decoder reporting it already applied
    // the declared orientation (residual == identity) and handing back a
    // native-backed buffer must take the pointer encoder, never the byte
    // encoder, and must not count as a re-encode fallback.
    test(
      'orientingDngDecoder with appliedOrientation matching declared uses '
      'the pointer encoder',
      () async {
        final keeper = Object();
        var pointerCalls = 0;
        var copyCalls = 0;
        resetReencodeCounters();
        addTearDown(resetReencodeCounters);

        final controller = ImagePreloadController(
          imageLoader: needsRawDecodeLoaderOrientation6,
          // Legacy seam left null: only the orienting seam is exercised, and
          // AC-8.5 (a separate test below) is what proves that binding this
          // to null does not disturb anything.
          orientingDngDecoder: (path, {required exifOrientation}) async =>
              DecodedRgba(
            // Already-oriented: the source frame was 4 wide x 8 tall, and
            // orientation 6 (a 90 CW turn) swaps the extent -- exactly the
            // ORIENTED shape a real ceyx entry would hand back.
            rgba: opaqueRgba(8, 4),
            width: 8,
            height: 4,
            nativeAddress: 0x5678,
            nativeKeepAlive: keeper,
            appliedOrientation: exifOrientation,
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
            expect(nativeAddress, 0x5678);
            expect(identical(keepAlive, keeper), isTrue);
            // AC-8.3 (AD-040): return a REAL jpeg at the ORIENTED extent, so
            // the retained payload is provably the swapped shape rather than
            // an opaque stub the test cannot check.
            final frame = img.Image(width: width, height: height);
            return Uint8List.fromList(img.encodeJpg(frame, quality: quality));
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
        expect(copyCalls, 0, reason: 'AC-8.1: byte encoder must not run');
        expect(
          reencodeFallbacks,
          0,
          reason: 'AC-8.4: an oriented native decode must not fall back',
        );

        final payload = controller.payloadFor('a');
        expect(payload, isA<EncodedPayload>());

        // AC-8.3: the retained bytes decode to the ORIENTED extent (8x4, the
        // swap of the fake decoder's declared 4x8 source), proving the
        // pointer path carried the oriented width/height through, not the
        // unrotated ones.
        final decoded = img.decodeJpg((payload as EncodedPayload).bytes);
        expect(decoded, isNotNull);
        expect(decoded!.width, 8);
        expect(decoded.height, 4);
      },
    );

    // AC-8.2: `usePointer`'s expression at photo_source.dart:615 is
    // byte-identical after this task -- grepped mechanically, not eyeballed.
    test(
      'photo_source.dart usePointer expression is byte-identical (AC-8.2)',
      () {
        final source = File(
          'lib/services/image_pipeline/photo_source.dart',
        ).readAsStringSync();
        final needle =
            'final usePointer = fullRes != null && fullRes.image == null';
        final matches = needle.allMatches(source).length;
        expect(
          matches,
          1,
          reason: 'expected exactly one byte-identical usePointer line',
        );
      },
    );

    // Composition-root activation guard (round-3 review): main.dart's one-line
    // orientingDngDecoder wiring is the single point where native rotation
    // goes live; every other injection site defaults to null, so deleting it
    // leaves the whole suite green while silently reverting to host rotation.
    // Grepped mechanically, same style as AC-8.2 above.
    test('main.dart wires orientingDngDecoder into AppState', () {
      final source = File('lib/main.dart').readAsStringSync();
      const needle = 'orientingDngDecoder: halcyonOrientingFullDecoder';
      expect(
        needle.allMatches(source).length,
        1,
        reason:
            'expected the production AppState construction to pass '
            'orientingDngDecoder: halcyonOrientingFullDecoder exactly once',
      );
    });

    // AC-8.5: the null-binding arm is the byte-for-byte control -- a decode
    // with NO orientingDngDecoder configured must behave exactly as the
    // pre-Task-8 byte-copy path (this mirrors encode_test.dart's existing
    // "native-backed identity decode" case, but explicitly asserts the new
    // parameter defaulting to null changes nothing).
    test(
      'orientingDngDecoder: null leaves the legacy dngDecoder path unchanged',
      () async {
        var legacyCalls = 0;
        var copyCalls = 0;
        resetReencodeCounters();
        addTearDown(resetReencodeCounters);

        Future<NativeImageResult> identityLoader(
          String path, {
          required ImageRequestPurpose purpose,
          int? targetLongEdge,
        }) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

        final controller = ImagePreloadController(
          imageLoader: identityLoader,
          dngDecoder: (path) async {
            legacyCalls++;
            return DecodedRgba(rgba: opaqueRgba(4, 4), width: 4, height: 4);
          },
          // Deliberately omitted: orientingDngDecoder defaults to null.
          payloadEncoder:
              (rgba, {required width, required height, required quality}) async {
            copyCalls++;
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

        expect(legacyCalls, 1);
        expect(copyCalls, 1);
        expect(controller.payloadFor('a'), isA<EncodedPayload>());
      },
    );
  });
}
