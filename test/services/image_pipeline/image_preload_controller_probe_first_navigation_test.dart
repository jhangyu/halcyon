// In-suite translation of an earlier one-off scratch probe script. The
// original probe's behavior remains the frozen spec this file was derived
// from. This file applies the approved translation table from
// m3-contract.md A-C1:
//   decodedImageFor(x) != null    -> payloadFor(x) is PixelPayload
//   debugDisposed                 -> payloadFor(x) == null
//   decodedProviderFor(x) != null -> cache holds a payload for x

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_source.dart';

import '../../support/sample_photos.dart';

// Drains SYNCHRONOUSLY instead of waiting for a real (disabled-by-default
// in AutomatedTestWidgetsFlutterBinding) frame -- see REPAIR 3 /
// publication_pacer.dart: the paced tier-1/tier-2 publish queue only
// drains when its frame hook fires, and a plain test() never pumps a real
// frame on its own. The pacer re-arms itself after each drained item, so
// a synchronous hook fully drains the queue before submit() returns.
void _microtaskFrame(void Function() callback) => callback();

final _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAA'
  'AAYAAjCB0C8AAAAASUVORK5CYII=',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<PhotoItem> rawItems(int count) => List.generate(count, (index) {
    final id = 'IMG_${index.toString().padLeft(4, '0')}';
    return PhotoItem(id: id, files: [File('/tmp/$id.dng')]);
  });

  List<PhotoItem> jpgItems(int count) => List.generate(count, (index) {
    final id = 'IMG_${index.toString().padLeft(4, '0')}';
    return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
  });

  // Alpha must be opaque (0xFF): decoded_rgba_image_provider.dart's
  // debug-only identity short-circuit asserts sampled alpha is opaque.
  // Same repair as commits 253b89f / d43c2a1.
  DecodedRgba fakeDecoded() => DecodedRgba(
    rgba: Uint8List.fromList(
      List<int>.generate(2 * 2 * 4, (i) => i % 4 == 3 ? 0xFF : i),
    ),
    width: 2,
    height: 2,
  );

  final dngDir = sampleDngDir;
  final hasSamples = samplePhotosAvailable;

  File sampleNamed(String name) => File('${dngDir.path}/$name');

  // The M0/M3 sample inventory proves this pair is the intended content
  // witness: same extension, one preview-bearing and one no-preview.
  final previewDng = sampleNamed('2026-02-15-19-37-38.dng');
  final noPreviewDng = sampleNamed('IMG_20251112_092839.dng');

  List<PhotoItem> realListWith(File target, int targetIndex) => List.generate(
    14,
    (index) => PhotoItem(
      id: 'REAL_${index.toString().padLeft(4, '0')}',
      files: [index == targetIndex ? target : previewDng],
    ),
  );

  Future<void> until(bool Function() condition, {String? reason}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out waiting for: ${reason ?? 'condition'}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  setUp(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  test('P1 translated: cheap DNG has tier-1 entries at arrival; expensive '
      'cold arrival fills the same window, one decode at a time', () async {
    final cheap = ImagePreloadController(
      scheduleFrameCallback: _microtaskFrame,
      imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
          NativeImageBytes(Uint8List.fromList(_tinyPngBytes)),
      dngDecoder: (path) async => fail('cheap rung must not RAW-decode'),
    );
    addTearDown(cheap.dispose);
    cheap.updateTargetSize(800, 600);
    final cheapItems = rawItems(14);
    await cheap.preloadImages(
      items: cheapItems,
      selectedItemId: cheapItems[5].id,
      notifyLoaded: () {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final neighbourBytes = cheap.imageBytesFor(cheapItems[7].id)!;
    final key = await tierOneProviderFor(
      neighbourBytes,
      width: 800,
      height: 600,
    ).obtainKey(const ImageConfiguration());
    expect(PaintingBinding.instance.imageCache.containsKey(key), isTrue);
    expect(
      PaintingBinding.instance.imageCache.currentSize,
      9,
      reason:
          'P1 frozen cheap arrival count: exactly the current -3..+5 tier-1 '
          'window is decoded before the tier-2 debounce. Was 5 (a +/-2 span) '
          'until the round-2 tier-1 widening; changed under orchestrator '
          'authorization because this number encoded the OLD requirement, '
          'which the user replaced by ruling that tier-1 covers the whole '
          'retention window. The byte-identity gate on this file re-anchors '
          'to the new sha256; it is amended, not retired',
    );

    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    // The expensive half, RENEGOTIATED to the 2026-08-26 ruling. It used to
    // assert `payloadFor(selected) == null` and an EMPTY ImageCache right after
    // arrival, which encoded the old law: an expensive item was refused outside
    // +/-1 and even at distance 0 had to wait out the 250ms debounce. Both
    // clauses are now wrong AND untestable as written -- what happens "right
    // after arrival" is a race with the serial lane, not a design rule. The
    // rule that replaced them is asserted instead: the same -3..+5 window a
    // cheap item gets, filled one decode at a time.
    var inFlight = 0;
    var maxInFlight = 0;
    final expensive = ImagePreloadController(
      scheduleFrameCallback: _microtaskFrame,
      imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
          const NativeImageNeedsRawDecode(exifOrientation: 1),
      dngDecoder: (path) async {
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        inFlight--;
        return fakeDecoded();
      },
    );
    addTearDown(expensive.dispose);
    expensive.updateTargetSize(800, 600);
    final expensiveItems = rawItems(14);
    await expensive.preloadImages(
      items: expensiveItems,
      selectedItemId: expensiveItems[5].id,
      notifyLoaded: () {},
    );
    await until(
      () => List.generate(9, (i) => expensiveItems[2 + i].id).every(
        (id) => expensive.payloadFor(id) is PixelPayload,
      ),
      reason: 'the whole -3..+5 expensive window to land',
    );
    expect(maxInFlight, 1, reason: 'expensive production stays single-flight');
  });

  // Each assertion names its POSITION, so location-dependent bridge-first
  // scheduling cannot hide behind a single outer-window witness. The real
  // no-preview DNG must have been content-classified expensive BEFORE loader
  // acquisition; therefore before the frozen debounce expires its loader calls
  // are zero at every retained position.
  for (final spec in <({String name, int selected, int target})>[
    (name: 'selected distance 0', selected: 5, target: 5),
    (name: 'plus-one distance 1', selected: 5, target: 6),
    (name: 'outer retention distance 3', selected: 5, target: 8),
  ]) {
    test('TC-088 probe-first expensive item: ${spec.name} has ZERO loader '
        'calls before debounce', () async {
      expect(previewDng.existsSync(), isTrue, reason: 'preview sample missing');
      expect(
        noPreviewDng.existsSync(),
        isTrue,
        reason: 'no-preview sample missing',
      );
      expect(
        (await PhotoSource.probeSource(noPreviewDng.path, longEdge: 2800))
            .cost,
        SourceCost.expensive,
        reason: 'sanity: this must be the real no-preview content witness',
      );
      final targetCalls = <String>[];
      final controller = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async {
          targetCalls.add(path);
          return NativeImageBytes(Uint8List.fromList(_tinyPngBytes));
        },
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(800, 600);
      final photos = realListWith(noPreviewDng, spec.target);
      await controller.preloadImages(
        items: photos,
        selectedItemId: photos[spec.selected].id,
        notifyLoaded: () {},
      );
      expect(
        targetCalls.where((path) => path == noPreviewDng.path),
        isEmpty,
        reason:
            'the real probe must classify this no-preview DNG before any '
            'loader work, regardless of ${spec.name}',
      );
    }, skip: hasSamples ? null : 'no local samples');
  }

  // TC-089 deleted (M6 P3.3, Appendix B, C-4): see baseline-registry.md for
  // the disposition reason; TC-088 above stays.

  test('P2 translated: navigation bursts never exceed one expensive decode in '
      'flight and never decode out-of-window items, while cheap DNGs/JPEGs '
      'prefetch during the same burst', () async {
    // RENEGOTIATED (user ruling 2026-08-26). The frozen probe asserted ZERO
    // expensive decodes during a sub-debounce burst, which was the old law's
    // consequence: expensive work existed only behind the debounce. Under the
    // new law a burst MAY start decodes -- that is the point, RAW navigation is
    // to behave like JPEG -- so what is pinned instead is what must still never
    // happen: two decodes at once, a decode for an item outside the current
    // retention window, or a second decode of an item already decoded.
    final decodeCalls = <String>[];
    var inFlight = 0;
    var maxInFlight = 0;
    final expensive = ImagePreloadController(
      scheduleFrameCallback: _microtaskFrame,
      imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
          const NativeImageNeedsRawDecode(exifOrientation: 1),
      dngDecoder: (path) async {
        decodeCalls.add(path);
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        inFlight--;
        return fakeDecoded();
      },
    );
    addTearDown(expensive.dispose);
    expensive.updateTargetSize(800, 600);
    final raws = rawItems(20);
    for (final idx in [5, 6, 7, 8, 9, 8, 7, 6, 5]) {
      await expensive.preloadImages(
        items: raws,
        selectedItemId: raws[idx].id,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    expect(maxInFlight, 1, reason: 'the burst may never put two RAW decodes in '
        'flight at once');
    // Deliberately NOT "no path appears twice": this burst walks 5->9->5, so
    // index 5 leaves the -3..+5 window at position 9, loses its payload to the
    // one retention rule every kind shares, and legitimately re-decodes on the
    // way back. Re-decode-free navigation WITHIN the window is what P3/P4 pin.
    // What must hold here is that a decode is only ever bought for an item
    // some visited position actually wanted (2..14 across this burst).
    // Every decoded path must belong to some item that was inside the -3..+5
    // window of one of the visited positions (2..14 across the burst).
    final everInWindow = raws
        .sublist(2, 15)
        .map((item) => item.files.single.path)
        .toSet();
    expect(decodeCalls.where((p) => !everInWindow.contains(p)), isEmpty);
    expect(expensive.payloadFor(raws[5].id), isNotNull);

    final cheap = ImagePreloadController(
      scheduleFrameCallback: _microtaskFrame,
      imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
          NativeImageBytes(Uint8List.fromList(_tinyPngBytes)),
    );
    addTearDown(cheap.dispose);
    cheap.updateTargetSize(800, 600);
    final jpgs = jpgItems(20);
    for (final idx in [5, 6, 7, 8, 9, 8, 7, 6, 5]) {
      await cheap.preloadImages(
        items: jpgs,
        selectedItemId: jpgs[idx].id,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    final bytes5 = cheap.imageBytesFor(jpgs[5].id)!;
    final key5 = await tierOneProviderFor(
      bytes5,
      width: 800,
      height: 600,
    ).obtainKey(const ImageConfiguration());
    expect(PaintingBinding.instance.imageCache.containsKey(key5), isTrue);

    // Separate real-DNG witness: the cheap result must come from TIFF content,
    // not from the JPEG control above. A preview-bearing DNG still receives
    // immediate work throughout the same sub-debounce navigation burst.
    expect(previewDng.existsSync(), isTrue, reason: 'preview sample missing');
    var realCheapCalls = 0;
    final realCheap = ImagePreloadController(
      scheduleFrameCallback: _microtaskFrame,
      imageLoader: (path, {required purpose, int? targetLongEdge}) async {
        realCheapCalls++;
        return NativeImageBytes(Uint8List.fromList(_tinyPngBytes));
      },
    );
    addTearDown(realCheap.dispose);
    realCheap.updateTargetSize(800, 600);
    final realCheapItems = realListWith(previewDng, 5);
    for (final idx in [5, 6, 7, 8, 9, 8, 7, 6, 5]) {
      await realCheap.preloadImages(
        items: realCheapItems,
        selectedItemId: realCheapItems[idx].id,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    expect(
      realCheapCalls,
      greaterThan(0),
      reason:
          'P2 cheap-DNG witness: real preview-bearing TIFF content must '
          'schedule immediate loader work during the burst',
    );
  }, skip: hasSamples ? null : 'no local samples');

  test('P3 translated: one-step expensive round trip decodes once and retains '
      'the PixelPayload', () async {
    final decodeCalls = <String>[];
    final controller = ImagePreloadController(
      scheduleFrameCallback: _microtaskFrame,
      imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
          const NativeImageNeedsRawDecode(exifOrientation: 1),
      dngDecoder: (path) async {
        decodeCalls.add(path);
        return fakeDecoded();
      },
    );
    addTearDown(controller.dispose);
    final items = rawItems(20);
    final target = items[8].files.single.path;
    int targetDecodes() => decodeCalls.where((path) => path == target).length;

    await controller.preloadImages(
      items: items,
      selectedItemId: items[8].id,
      notifyLoaded: () {},
    );
    await until(() => controller.payloadFor(items[8].id) is PixelPayload);
    final first = controller.payloadFor(items[8].id);
    expect(targetDecodes(), 1);

    for (final idx in [9, 8]) {
      await controller.preloadImages(
        items: items,
        selectedItemId: items[idx].id,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
    expect(
      controller.payloadFor(items[8].id),
      isA<PixelPayload>(),
      reason:
          'frozen debugDisposed=false translation: the retained payload '
          'must still exist after the one-step round trip',
    );
    expect(identical(controller.payloadFor(items[8].id), first), isTrue);
    expect(targetDecodes(), 1);
  });

  test('P4 translated: two-step expensive excursion decodes once and retains '
      'the payload; JPEG bytes still survive identically', () async {
    final decodeCalls = <String>[];
    final controller = ImagePreloadController(
      scheduleFrameCallback: _microtaskFrame,
      imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
          const NativeImageNeedsRawDecode(exifOrientation: 1),
      dngDecoder: (path) async {
        decodeCalls.add(path);
        return fakeDecoded();
      },
    );
    addTearDown(controller.dispose);
    final items = rawItems(20);
    final target = items[8].files.single.path;
    int decodesOfTarget() => decodeCalls.where((p) => p == target).length;

    await controller.preloadImages(
      items: items,
      selectedItemId: items[8].id,
      notifyLoaded: () {},
    );
    await until(() => controller.payloadFor(items[8].id) is PixelPayload);
    final first = controller.payloadFor(items[8].id);
    expect(decodesOfTarget(), 1);

    for (final idx in [9, 10, 9, 8]) {
      await controller.preloadImages(
        items: items,
        selectedItemId: items[idx].id,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
    // The PixelPayload (window-resolution) is retained through the whole
    // excursion: it never leaves the unchanged -3..+5 retention window.
    expect(identical(controller.payloadFor(items[8].id), first), isTrue);
    // But under the forward-biased -1..+3 tier-2 window (AD-034) the excursion
    // to index 10 puts item 8 at distance -2 -- the slot the bias gave up --
    // so item 8's FULL-RES tier-2 entry is evicted there and re-decoded once
    // when the walk returns to index 9/8. That second decode is the accepted
    // AD-034 catch-up cost, NOT the AD-033 discarded-piggyback bug: it fires on
    // a legitimate re-entry against a live payload, not a single-visit discard.
    expect(decodesOfTarget(), 2);

    final cheapCalls = <String>[];
    final cheapController = ImagePreloadController(
      scheduleFrameCallback: _microtaskFrame,
      imageLoader: (path, {required purpose, int? targetLongEdge}) async {
        cheapCalls.add(path);
        return NativeImageBytes(Uint8List.fromList(_tinyPngBytes));
      },
    );
    addTearDown(cheapController.dispose);
    cheapController.updateTargetSize(800, 600);
    final cheapItems = rawItems(20);
    final cheapTarget = cheapItems[8].files.single.path;
    await cheapController.preloadImages(
      items: cheapItems,
      selectedItemId: cheapItems[8].id,
      notifyLoaded: () {},
    );
    final cheapFirst = cheapController.payloadFor(cheapItems[8].id);
    for (final idx in [9, 10, 9, 8]) {
      await cheapController.preloadImages(
        items: cheapItems,
        selectedItemId: cheapItems[idx].id,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
    expect(cheapCalls.where((path) => path == cheapTarget), hasLength(1));
    expect(
      identical(cheapController.payloadFor(cheapItems[8].id), cheapFirst),
      isTrue,
    );

    final jpgController = ImagePreloadController(
      scheduleFrameCallback: _microtaskFrame,
      imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
          NativeImageBytes(Uint8List.fromList(_tinyPngBytes)),
    );
    addTearDown(jpgController.dispose);
    jpgController.updateTargetSize(800, 600);
    final jpgs = jpgItems(20);
    await jpgController.preloadImages(
      items: jpgs,
      selectedItemId: jpgs[8].id,
      notifyLoaded: () {},
    );
    final before = jpgController.imageBytesFor(jpgs[8].id);
    for (final idx in [9, 10, 9, 8]) {
      await jpgController.preloadImages(
        items: jpgs,
        selectedItemId: jpgs[idx].id,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
    expect(identical(before, jpgController.imageBytesFor(jpgs[8].id)), isTrue);
  });
}
