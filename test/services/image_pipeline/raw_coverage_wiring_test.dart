import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_source.dart';

/// Contract: docs/logs/2026-08-26/raw-support-contract.md
///
/// T4 scope: full-decoder wiring through the preload controller / app_state
/// side of the pipeline. `image_source_types.dart`/`dart_image_loader.dart`
/// are owned by other members (T2/T3); these tests drive the CONTROLLER
/// through the same public seam the pre-existing suite uses (see
/// photo_source_test.dart's design note) rather than asserting on those
/// files' internals.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'D2: a browse-only RAW (.cr2) that has no embedded preview stays a '
    'preview-only permanent miss -- it never reaches the full decoder',
    () async {
      // Simulates what the generalised dart_image_loader.dart reports for a
      // browse-only extension with no embedded preview: a plain
      // NativeImageFailure, NEVER NativeImageNeedsRawDecode, because D2
      // formats have no decode route at all (contract: "D2 -- formats the
      // engine cannot decode ... stay browsable via embedded preview only").
      var decoderCalls = 0;
      final controller = ImagePreloadController(
        imageLoader: (path, {required purpose}) async {
          return const NativeImageFailure(
            'RAW_NO_EMBEDDED_PREVIEW',
            'no embedded preview and no decoder for this format',
          );
        },
        dngDecoder: (path) async {
          decoderCalls++;
          throw StateError(
            'the decoder must never be invoked for a D2 browse-only RAW',
          );
        },
      );
      addTearDown(controller.dispose);

      final items = [
        PhotoItem(id: 'cr2-1', files: [File('/tmp/cr2-1.cr2')]),
      ];

      await controller.preloadImages(
        items: items,
        selectedItemId: 'cr2-1',
        notifyLoaded: () {},
      );

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!controller.hasFailed('cr2-1')) {
        if (DateTime.now().isAfter(deadline)) {
          fail('timed out waiting for the permanent-miss pass');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(controller.imageBytesFor('cr2-1'), isNull);
      expect(controller.hasFailed('cr2-1'), isTrue);
      expect(
        decoderCalls,
        0,
        reason:
            'D2 browse-only formats have no decode route; the decoder must '
            'stay untouched',
      );
    },
  );

  test(
    'AC3: NativeImageResult has exactly three variants, proven by an '
    'exhaustive switch with no default case (a fourth variant fails to '
    'compile here, not just at runtime)',
    () {
      String classify(NativeImageResult r) => switch (r) {
        NativeImageBytes() => 'bytes',
        NativeImageNeedsRawDecode() => 'needs_raw_decode',
        NativeImageFailure() => 'failure',
      };

      expect(
        classify(NativeImageBytes(Uint8List.fromList([1, 2, 3]))),
        'bytes',
      );
      expect(
        classify(const NativeImageNeedsRawDecode(exifOrientation: 1)),
        'needs_raw_decode',
      );
      expect(
        classify(const NativeImageFailure('X', 'y')),
        'failure',
      );
    },
  );

  test(
    'a DngFullDecoder/DngSizedDecoder fake wired through the controller '
    'reaches an engine-decodable non-DNG RAW when the loader signals '
    'NeedsRawDecode -- proves the full-size path is format-agnostic once the '
    'loader routes correctly (photo_source.dart already dispatches '
    'NativeImageNeedsRawDecode to dngDecoder regardless of extension; the '
    'remaining gate lives in dart_image_loader.dart, owned by T2)',
    () async {
      var decodedPath = '';
      final controller = ImagePreloadController(
        imageLoader: (path, {required purpose}) async {
          return const NativeImageNeedsRawDecode(exifOrientation: 1);
        },
        dngDecoder: (path) async {
          decodedPath = path;
          return DecodedRgba(
            rgba: Uint8List(4 * 2 * 2),
            width: 2,
            height: 2,
          );
        },
      );
      addTearDown(controller.dispose);

      final items = [
        PhotoItem(id: 'rw2-1', files: [File('/tmp/rw2-1.rw2')]),
      ];

      await controller.preloadImages(
        items: items,
        selectedItemId: 'rw2-1',
        notifyLoaded: () {},
      );

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (controller.imageBytesFor('rw2-1') == null &&
          controller.payloadFor('rw2-1') == null) {
        if (DateTime.now().isAfter(deadline)) {
          fail('timed out waiting for the RAW decode pass');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(decodedPath, '/tmp/rw2-1.rw2');
    },
  );

  test(
    'AC5 D3: an engine-decodable RAW with no configured native decoder '
    '(a platform with no native library) is a permanent miss carrying the '
    'D3 no-native-decoder code -- distinct from a decoder that exists but '
    'throws',
    () async {
      final controller = ImagePreloadController(
        imageLoader: (path, {required purpose}) async {
          return const NativeImageNeedsRawDecode(exifOrientation: 1);
        },
        dngDecoder: null,
      );
      addTearDown(controller.dispose);

      final items = [
        PhotoItem(id: 'arw-1', files: [File('/tmp/arw-1.arw')]),
      ];

      await controller.preloadImages(
        items: items,
        selectedItemId: 'arw-1',
        notifyLoaded: () {},
      );

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!controller.hasFailed('arw-1')) {
        if (DateTime.now().isAfter(deadline)) {
          fail('timed out waiting for the permanent-miss pass');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(controller.hasFailed('arw-1'), isTrue);
      expect(controller.isNoNativeDecoder('arw-1'), isTrue);
      expect(
        controller.noNativeDecoderCodeFor('arw-1'),
        kNoNativeDecoderCode,
      );
    },
  );

  test(
    'AC5 D3 negative: a THROWING decoder (decoder exists but failed) is a '
    'permanent miss WITHOUT the D3 no-native-decoder code -- not conflated '
    'with the no-decoder-on-this-platform state',
    () async {
      final controller = ImagePreloadController(
        imageLoader: (path, {required purpose}) async {
          return const NativeImageNeedsRawDecode(exifOrientation: 1);
        },
        dngDecoder: (path) async => throw StateError('native decode failed'),
      );
      addTearDown(controller.dispose);

      final items = [
        PhotoItem(id: 'arw-2', files: [File('/tmp/arw-2.arw')]),
      ];

      await controller.preloadImages(
        items: items,
        selectedItemId: 'arw-2',
        notifyLoaded: () {},
      );

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!controller.hasFailed('arw-2')) {
        if (DateTime.now().isAfter(deadline)) {
          fail('timed out waiting for the permanent-miss pass');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(controller.hasFailed('arw-2'), isTrue);
      expect(
        controller.isNoNativeDecoder('arw-2'),
        isFalse,
        reason:
            'a throwing decoder is a genuine decode failure, not "no '
            'decoder on this platform" -- conflating them would hide a real '
            'bug behind a platform-support message',
      );
      expect(controller.noNativeDecoderCodeFor('arw-2'), isNull);
    },
  );

  test(
    'PhotoSource.load: decoder == null carries kNoNativeDecoderCode directly '
    'on SourceOutcome.failureCode (unit-level proof, below the controller '
    'seam)',
    () async {
      final source = PhotoSource(
        loader: (path, {required purpose}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        dngDecoder: null,
      );

      final outcome = await source.load(
        '/tmp/IMG_0000.arw',
        longEdge: 2800,
        allowExpensive: true,
      );

      expect(outcome.payload, isNull);
      expect(outcome.deferred, isFalse);
      expect(outcome.failureCode, kNoNativeDecoderCode);
    },
  );

  test(
    'PhotoSource.load: every other outcome (bytes, throwing decoder, '
    'NativeImageFailure) carries a null failureCode -- the field must not '
    'leak into unrelated paths',
    () async {
      final bytesSource = PhotoSource(
        loader: (path, {required purpose}) async =>
            NativeImageBytes(Uint8List.fromList([1, 2, 3])),
      );
      final bytesOutcome = await bytesSource.load(
        '/tmp/a.jpg',
        longEdge: 2800,
      );
      expect(bytesOutcome.failureCode, isNull);

      final throwingSource = PhotoSource(
        loader: (path, {required purpose}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        dngDecoder: (path) async => throw StateError('decode failed'),
      );
      final throwingOutcome = await throwingSource.load(
        '/tmp/b.arw',
        longEdge: 2800,
      );
      expect(throwingOutcome.failureCode, isNull);

      final failureSource = PhotoSource(
        loader: (path, {required purpose}) async =>
            const NativeImageFailure('UNREADABLE', 'corrupt'),
      );
      final failureOutcome = await failureSource.load(
        '/tmp/c.cr2',
        longEdge: 2800,
      );
      expect(failureOutcome.failureCode, isNull);
    },
  );

  // RETIRED (2026-08-30, plan Task 6): 'D2 sidebar fix: a browse-only RAW
  // (.cr2) never invokes the sized sidebar decoder'. The sized sidebar decoder
  // is deleted, so the gate it asserted on (isDecodablePath vs isRawPath) no
  // longer exists on this path. The D2 ruling itself is still enforced -- by
  // PhotoSource, covered by this file's failureCode tests above.
}
