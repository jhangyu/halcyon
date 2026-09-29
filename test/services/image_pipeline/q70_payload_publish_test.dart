// TC-1390..TC-1393 (q70-decouple AC3/AC4): tier-2 display is served by the q70
// PAYLOAD, not by decode-time pixels.
//
//   TC-1390  FIRST view of an item publishes tier-2 through the payload route.
//   TC-1391  the published image's extent equals the decoded frame's.
//   TC-1392  the catch-up path with the payload PRESENT: payload route +1,
//            file decode 0, no re-decode of the source.
//   TC-1393  a payload that cannot serve full-res pixels (PixelPayload) takes
//            the file fallback, and it is COUNTED (+1) with the payload route
//            flat.
//
// Both counters are never reset, so every assertion is a delta.
//
// TC-1393 deviation from the plan text: "payload absent" cannot be built by
// evicting an EncodedPayload -- the sweep would simply re-produce the payload
// and publish it through the payload route. The only state in which the
// payload cannot serve pixels is the PixelPayload arm, which is what the file
// fallback exists for.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/retention_policy.dart';
import 'package:image/image.dart' as img;

void _microtaskFrame(void Function() callback) => callback();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const width = 12;
  const height = 8;

  setUp(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  Future<void> until(bool Function() condition, String reason) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out waiting for: $reason');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Uint8List jpegBytes() => Uint8List.fromList(
    img.encodeJpg(img.Image(width: width, height: height), quality: 70),
  );

  DecodedRgba frame() => DecodedRgba(
    rgba: Uint8List.fromList(
      List<int>.generate(width * height * 4, (i) => i % 4 == 3 ? 0xFF : i),
    ),
    width: width,
    height: height,
  );

  final items = [
    for (final id in ['a', 'b', 'c', 'd'])
      PhotoItem(id: id, files: [File('/tmp/$id.dng')]),
  ];

  /// [encoded] true: the payload encoder works -> EncodedPayload.
  /// false: it throws -> PixelPayload (window-resolution, cannot serve
  /// full-res pixels).
  ({ImagePreloadController controller, List<String> decodeCalls}) newHarness({
    required bool encoded,
    Duration debounce = Duration.zero,
  }) {
    final decodeCalls = <String>[];
    final controller = ImagePreloadController(
      scheduleFrameCallback: _microtaskFrame,
      navigationDebounce: debounce,
      decodeLaneWidth: 1,
      retention: const RetentionPolicy(
        before: 3,
        after: 3,
        payloadByteBudget: 1 << 30,
      ),
      imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
          const NativeImageNeedsRawDecode(exifOrientation: 1),
      dngDecoder: (path) async {
        decodeCalls.add(path);
        return frame();
      },
      payloadEncoder:
          (rgba, {required width, required height, required quality}) async {
            if (!encoded) throw StateError('no encoder: pixel arm');
            return jpegBytes();
          },
    );
    addTearDown(() async {
      // The encode continuation is unawaited by the controller; let it drain.
      await until(() => controller.debugInflightBytes == 0, 'inflight drain');
      controller.dispose();
    });
    controller.updateTargetSize(32, 32);
    return (controller: controller, decodeCalls: decodeCalls);
  }

  Future<void> select(ImagePreloadController c, String id) => c.preloadImages(
    items: items,
    selectedItemId: id,
    notifyLoaded: () {},
  );

  Future<void> settleTierTwo(ImagePreloadController c, Set<String> ids) => until(
    () => c.debugTierTwoKeyIds.length == ids.length &&
        c.debugTierTwoKeyIds.containsAll(ids),
    'tier-2 keys == $ids (got ${c.debugTierTwoKeyIds})',
  );

  test('TC-1390 (AC3): the FIRST-view tier-2 entry is served by the payload '
      'route', () async {
    final h = newHarness(encoded: true);
    final c = h.controller;
    expect(c.isFullSizeReady('a'), isFalse,
        reason: 'VACUITY GUARD: first view means no prior tier-2 entry');
    final publishes = c.debugPayloadDecodePublishCount;
    final fileDecodes = c.debugBandEntryFileDecodeCount;

    await select(c, 'a');
    await until(() => c.isFullSizeReady('a'), 'first-view tier-2 ready');

    expect(c.debugPayloadFor('a'), isA<EncodedPayload>(),
        reason: 'vacuity guard: fixture must take the encoded arm');
    expect(c.debugPayloadDecodePublishCount - publishes, greaterThanOrEqualTo(1));
    expect(c.debugTierTwoKeyIds.contains('a'), isTrue);
    expect(c.debugBandEntryFileDecodeCount - fileDecodes, 0,
        reason: 'first view must not buy a file decode');
    // Exactly one publish per in-band item, none for a second route.
    expect(c.debugPayloadDecodePublishCount - publishes, c.debugTierTwoKeyIds.length,
        reason: 'one payload publish per tier-2 entry');
  });

  test('TC-1391 (AC3): the published image extent equals the decoded frame\'s',
      () async {
    final h = newHarness(encoded: true);
    final c = h.controller;
    await select(c, 'a');
    await until(() => c.isFullSizeReady('a'), 'first-view tier-2 ready');

    final provider = c.debugTierTwoProviderFor('a');
    expect(provider, isNotNull);
    final done = Completer<ui.Image>();
    final stream = provider!.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      if (!done.isCompleted) done.complete(info.image);
      stream.removeListener(listener);
    });
    stream.addListener(listener);
    final image = await done.future.timeout(const Duration(seconds: 5));

    expect(image.width, width);
    expect(image.height, height);
  });

  test('TC-1392 (AC4): catch-up with the payload PRESENT consumes it -- no '
      'file decode, no re-decode of the source', () async {
    final h = newHarness(encoded: true);
    final c = h.controller;
    await select(c, 'a');
    await until(
      () => items.every((i) => c.debugPayloadFor(i.id) != null),
      'all four EncodedPayloads resident',
    );
    await settleTierTwo(c, {'a', 'b'}); // band is +/-1
    // d: band {c,d}; b leaves tier-2 (distance -2) but stays retained.
    await select(c, 'd');
    await settleTierTwo(c, {'c', 'd'});
    expect(c.debugPayloadFor('b'), isA<EncodedPayload>(),
        reason: 'vacuity guard: b is retained with its payload, tier-2 gone');
    expect(c.isFullSizeReady('b'), isFalse);

    final publishes = c.debugPayloadDecodePublishCount;
    final fileDecodes = c.debugBandEntryFileDecodeCount;
    final sourceDecodes = h.decodeCalls.length;

    await select(c, 'c'); // band is b..d: only b re-enters
    await until(() => c.isFullSizeReady('b'), 'b caught up');

    expect(c.debugPayloadDecodePublishCount - publishes, 1);
    expect(c.debugBandEntryFileDecodeCount - fileDecodes, 0,
        reason: 'R5: a payload is present, so no file decode may be bought');
    expect(h.decodeCalls.length - sourceDecodes, 0,
        reason: 'the source file must not be decoded again');
  });

  test('TC-1393 (AC4): a payload that cannot serve pixels takes the COUNTED '
      'file fallback', () async {
    final h = newHarness(encoded: false);
    final c = h.controller;
    await select(c, 'a');
    await until(
      () => items.every((i) => c.debugPayloadFor(i.id) != null),
      'all four PixelPayloads resident',
    );
    expect(c.debugPayloadFor('a'), isA<PixelPayload>(),
        reason: 'vacuity guard: fixture must take the pixel arm');
    // PARKED PRODUCT GAP (lead ruling): a PixelPayload that lands AFTER the
    // tier-2 sweep is not upgraded until the next navigation; this
    // re-navigation WORKS AROUND that gap and is NOT the intended final
    // behaviour.
    await select(c, 'a');
    await settleTierTwo(c, {'a', 'b'}); // band is +/-1
    await select(c, 'd');
    await settleTierTwo(c, {'c', 'd'});

    final publishes = c.debugPayloadDecodePublishCount;
    final fileDecodes = c.debugBandEntryFileDecodeCount;

    await select(c, 'c'); // b re-enters the band
    await until(() => c.isFullSizeReady('b'), 'b caught up via file fallback');

    expect(c.debugBandEntryFileDecodeCount - fileDecodes, 1,
        reason: 'R5: the fallback must be loudly counted, exactly once');
    expect(c.debugPayloadDecodePublishCount - publishes, 0,
        reason: 'a PixelPayload must not go through the payload route');
  });

  test('TC-1402 (l1l2 AC3): a band leaver that returns before any settle is '
      're-served from its retained payload -- no file decode', () async {
    // 10 s debounce: the settle sweep cannot run inside this test, so the
    // only eviction the return can observe is the band-leave one (spec R1).
    final h = newHarness(encoded: true, debounce: const Duration(seconds: 10));
    final c = h.controller;
    await select(c, 'b'); // band a..c
    await until(
      () => items.every((i) => c.debugPayloadFor(i.id) != null),
      'all four EncodedPayloads resident',
    );
    await settleTierTwo(c, {'a', 'b', 'c'});

    await select(c, 'd'); // band c..d: a and b leave
    expect(c.debugTierTwoKeyIds, isNot(contains('b')),
        reason: 'R1: b was evicted at the band-leave instant, not at a settle');
    expect(c.debugPayloadFor('b'), isA<EncodedPayload>(),
        reason: 'vacuity guard: b keeps its retained payload');

    final publishes = c.debugPayloadDecodePublishCount;
    final fileDecodes = c.debugBandEntryFileDecodeCount;
    final sourceDecodes = h.decodeCalls.length;

    await select(c, 'c'); // band b..d: b returns
    await until(() => c.isFullSizeReady('b'), 'b re-served');

    expect(c.debugPayloadDecodePublishCount - publishes, greaterThanOrEqualTo(1),
        reason: 'R4: the return is served by decoding the retained payload');
    expect(c.debugBandEntryFileDecodeCount - fileDecodes, 0,
        reason: 'R4: no counted file fallback');
    expect(h.decodeCalls.length - sourceDecodes, 0,
        reason: 'the source file is not decoded again');
  });
}
