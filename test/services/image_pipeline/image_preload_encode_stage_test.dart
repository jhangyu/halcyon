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

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';

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
}) {
  return ImagePreloadController(
    imageLoader: _needsRawDecodeLoader,
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

void main() {
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
    await pumpMicrotasks();

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
}
