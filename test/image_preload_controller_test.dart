import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_preload_controller.dart';
import 'package:halcyon_flutter/services/native_thumbnail_service.dart';
import 'package:halcyon_flutter/services/photo_payload.dart';

// A minimal valid 1x1 transparent PNG, used to exercise a real engine decode
// without shipping a binary fixture file.
final _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAA'
  'AAYAAjCB0C8AAAAASUVORK5CYII=',
);

/// An ImageStreamCompleter that never emits an image and never errors --
/// used to deterministically simulate a decode that is PENDING forever,
/// without racing a real (near-instant) engine decode. When pre-inserted
/// into ImageCache under the exact key a real decode would use,
/// ImageCache.putIfAbsent returns this existing entry instead of starting
/// a new decode, so any code path that resolves that provider joins this
/// completer and never observes completion.
class _NeverCompletingImageStreamCompleter extends ImageStreamCompleter {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'preloadImages evicts preview cache entries outside the sliding window',
    () async {
      final controller = ImagePreloadController(
        imageLoader: (path, {required purpose}) async {
          return NativeImageBytes(Uint8List.fromList([path.hashCode & 0xFF]));
        },
      );
      addTearDown(controller.dispose);

      final items = List.generate(14, (index) {
        final id = 'IMG_${index.toString().padLeft(4, '0')}';
        return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
      });

      await controller.preloadImages(
        items: items,
        selectedItemId: 'IMG_0005',
        notifyLoaded: () {},
      );
      expect(controller.imageBytesFor('IMG_0002'), isNotNull);

      await controller.preloadImages(
        items: items,
        selectedItemId: 'IMG_0011',
        notifyLoaded: () {},
      );

      expect(controller.imageBytesFor('IMG_0002'), isNull);
      expect(controller.imageBytesFor('IMG_0011'), isNotNull);
    },
  );

  test(
    'preloadImages loads the selected item first, then the rest of the window concurrently',
    () async {
      final requestOrder = <String>[];
      final completers = <String, Completer<NativeImageResult>>{};

      final controller = ImagePreloadController(
        imageLoader: (path, {required purpose}) {
          requestOrder.add(path);
          final completer = Completer<NativeImageResult>();
          completers[path] = completer;
          return completer.future;
        },
      );
      addTearDown(controller.dispose);

      final items = List.generate(14, (index) {
        final id = 'IMG_${index.toString().padLeft(4, '0')}';
        return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
      });

      const selectedId = 'IMG_0005';
      final selectedPath = items[5].files.single.path;
      // Window is [selectedIndex - 3, selectedIndex + 5] clamped, i.e. 2..10.
      final windowPaths = [
        for (var i = 2; i <= 10; i++) items[i].files.single.path,
      ];
      final remainingPaths = windowPaths.where((p) => p != selectedPath);

      final preloadFuture = controller.preloadImages(
        items: items,
        selectedItemId: selectedId,
        notifyLoaded: () {},
      );

      // Let the microtask queue advance to the point where the selected
      // item's load has been requested.
      await Future<void>.delayed(Duration.zero);
      expect(requestOrder, [selectedPath]);

      // Completing the selected item's load lets the controller move on to
      // dispatching the rest of the window.
      completers[selectedPath]!.complete(
        NativeImageBytes(Uint8List.fromList([1])),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      // All remaining window items must have been requested already, proving
      // they were dispatched concurrently rather than one at a time.
      expect(requestOrder.length, windowPaths.length);
      expect(requestOrder.toSet(), windowPaths.toSet());
      for (final path in remainingPaths) {
        expect(completers.containsKey(path), isTrue);
      }

      for (final path in remainingPaths) {
        completers[path]!.complete(
          NativeImageBytes(Uint8List.fromList([path.hashCode & 0xFF])),
        );
      }

      await preloadFuture;

      for (var i = 2; i <= 10; i++) {
        expect(controller.imageBytesFor(items[i].id), isNotNull);
      }
    },
  );

  test('selecting an in-flight item still fires notify once its load completes '
      '(R3: no permanent spinner strand)', () async {
    final completers = <String, List<Completer<NativeImageResult>>>{};
    var firstNotify = 0;
    var secondNotify = 0;

    final controller = ImagePreloadController(
      imageLoader: (path, {required purpose}) {
        final completer = Completer<NativeImageResult>();
        completers.putIfAbsent(path, () => []).add(completer);
        return completer.future;
      },
    );
    addTearDown(controller.dispose);

    final items = List.generate(14, (index) {
      final id = 'IMG_${index.toString().padLeft(4, '0')}';
      return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
    });

    // First preload pass selects IMG_0002; this starts (but does not
    // finish) its load and queues the rest of the window.
    final firstPass = controller.preloadImages(
      items: items,
      selectedItemId: 'IMG_0002',
      notifyLoaded: () => firstNotify++,
    );
    await Future<void>.delayed(Duration.zero);

    final targetPath = items[2].files.single.path; // IMG_0002
    expect(completers.containsKey(targetPath), isTrue);
    expect(completers[targetPath]!.single.isCompleted, isFalse);

    // Second pass selects the same item while its load is still in
    // flight. Before the R3 fix this notifyLoaded would be silently
    // dropped by the early-return guard, permanently stranding the
    // spinner even after the underlying bytes arrive.
    final secondPass = controller.preloadImages(
      items: items,
      selectedItemId: 'IMG_0002',
      notifyLoaded: () => secondNotify++,
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.imageBytesFor('IMG_0002'), isNull);
    expect(secondNotify, 0);

    // Complete the in-flight load; every caller who selected this item
    // while it was loading must be notified, not just the original one.
    for (final completer in completers[targetPath]!) {
      if (!completer.isCompleted) {
        completer.complete(NativeImageBytes(Uint8List.fromList([1])));
      }
    }
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // Drain remaining window loads from both passes before asserting: M3's
    // source/cost pipeline still guarantees selected-first notification, but
    // it also keeps more work as explicit futures so leaving the window's fake
    // loads unresolved can keep the test process open until dart_test's global
    // timeout.
    for (final list in completers.values) {
      for (final completer in list) {
        if (!completer.isCompleted) {
          completer.complete(NativeImageBytes(Uint8List.fromList([2])));
        }
      }
    }
    await firstPass;
    await secondPass;

    expect(controller.imageBytesFor('IMG_0002'), isNotNull);
    expect(
      firstNotify,
      greaterThanOrEqualTo(1),
      reason: 'the original (first) caller callback must still fire',
    );
    expect(
      secondNotify,
      greaterThanOrEqualTo(1),
      reason:
          'notifyLoaded from the second (in-flight) selectItem call must '
          'be flushed once the shared load completes, not dropped',
    );
  });

  test(
    'tierOneProviderFor produces an identical ImageCache key for the same '
    'bytes object identity and same width/height (AC2: display and '
    'precache must share one cache entry, not silently double-decode)',
    () async {
      final bytes = Uint8List.fromList(List.generate(16, (i) => i));

      // Simulates the precache call site.
      final precacheProvider = tierOneProviderFor(
        bytes,
        width: 800,
        height: 600,
      );
      // Simulates the display call site: a fresh ResizeImage/MemoryImage
      // instance, but built from the SAME bytes object and SAME dimensions.
      final displayProvider = tierOneProviderFor(
        bytes,
        width: 800,
        height: 600,
      );

      final precacheKey = await precacheProvider.obtainKey(
        ImageConfiguration.empty,
      );
      final displayKey = await displayProvider.obtainKey(
        ImageConfiguration.empty,
      );

      expect(
        precacheKey,
        equals(displayKey),
        reason:
            'ImageCache dedups strictly by key equality; a mismatch here '
            'means the display path always misses the precache and '
            'decodes a second time.',
      );
      expect(precacheKey.hashCode, equals(displayKey.hashCode));

      // Sanity: a different bytes object (even with identical content and
      // dimensions) must NOT collapse to the same key, since MemoryImage
      // compares bytes by identity, not content. Rebuilding/copying the
      // bytes between the precache and display call sites would silently
      // reintroduce the double-decode bug this factory exists to prevent.
      final copiedBytes = Uint8List.fromList(bytes);
      final copiedProvider = tierOneProviderFor(
        copiedBytes,
        width: 800,
        height: 600,
      );
      final copiedKey = await copiedProvider.obtainKey(
        ImageConfiguration.empty,
      );
      expect(copiedKey, isNot(equals(precacheKey)));
    },
  );

  testWidgets(
    'precache-then-display resolves as an ImageCache hit (AC2 integration: '
    'no second decode once the tier-1 entry is warm)',
    (tester) async {
      await tester.runAsync(() async {
        final bytes = Uint8List.fromList(_tinyPngBytes);

        final precacheProvider = tierOneProviderFor(
          bytes,
          width: 10,
          height: 10,
        );
        final precacheKey = await precacheProvider.obtainKey(
          ImageConfiguration.empty,
        );

        // Simulate the controller's precache: resolve without ever
        // attaching to a widget tree or passing a BuildContext.
        final completer = Completer<void>();
        final stream = precacheProvider.resolve(ImageConfiguration.empty);
        late ImageStreamListener listener;
        listener = ImageStreamListener(
          (image, synchronousCall) {
            stream.removeListener(listener);
            completer.complete();
          },
          onError: (error, stackTrace) {
            stream.removeListener(listener);
            completer.completeError(error, stackTrace);
          },
        );
        stream.addListener(listener);
        await completer.future;

        expect(
          PaintingBinding.instance.imageCache.containsKey(precacheKey),
          isTrue,
          reason: 'precache must land a decoded entry under this key',
        );

        // Simulate the display path: a fresh provider instance, same bytes
        // object + same size.
        final displayProvider = tierOneProviderFor(
          bytes,
          width: 10,
          height: 10,
        );
        final displayKey = await displayProvider.obtainKey(
          ImageConfiguration.empty,
        );

        expect(displayKey, equals(precacheKey));
        expect(
          PaintingBinding.instance.imageCache.containsKey(displayKey),
          isTrue,
          reason:
              'display path key must already be present in the cache '
              'populated by precache -> ImageCache.putIfAbsent returns the '
              'cached entry instead of decoding again',
        );
      });
    },
  );

  testWidgets(
    'tier-2 full-size decode does not start until the navigation debounce '
    'elapses (AC3a)',
    (tester) async {
      await tester.runAsync(() async {
        final controller = ImagePreloadController(
          imageLoader: (path, {required purpose}) async =>
              NativeImageBytes(Uint8List.fromList(_tinyPngBytes)),
        );
        addTearDown(controller.dispose);

        final items = List.generate(5, (i) {
          final id = 'IMG_${i.toString().padLeft(2, '0')}';
          return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
        });
        controller.updateTargetSize(10, 10);

        await controller.preloadImages(
          items: items,
          selectedItemId: items[2].id,
          notifyLoaded: () {},
        );

        // Right after preloadImages returns -- long before the 250ms
        // debounce -- tier-2 must not have started yet.
        expect(controller.isFullSizeReady(items[2].id), isFalse);

        // Still not ready comfortably inside the debounce window. If the
        // debounce were removed, the tiny PNG decodes near-instantly and
        // this would already be true.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(controller.isFullSizeReady(items[2].id), isFalse);

        // After the debounce elapses, tier-2 has landed.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(controller.isFullSizeReady(items[2].id), isTrue);
      });
    },
  );

  testWidgets(
    'tier-2 never queues an item that scrolled out of the window during '
    'continuous navigation (AC3b)',
    (tester) async {
      await tester.runAsync(() async {
        final controller = ImagePreloadController(
          imageLoader: (path, {required purpose}) async =>
              NativeImageBytes(Uint8List.fromList(_tinyPngBytes)),
        );
        addTearDown(controller.dispose);

        final items = List.generate(10, (i) {
          final id = 'IMG_${i.toString().padLeft(2, '0')}';
          return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
        });
        controller.updateTargetSize(10, 10);

        // Rapid burst of navigation, well under the 250ms debounce,
        // simulating a held-down arrow key: 2 -> 3 -> 4 -> 5.
        for (final idx in [2, 3, 4, 5]) {
          await controller.preloadImages(
            items: items,
            selectedItemId: items[idx].id,
            notifyLoaded: () {},
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));

          // Discriminating mid-burst check (round-2 review BLOCKER 2: the
          // original version of this test only asserted the END state,
          // which a debounce-removed mutant also satisfies once index 2
          // scrolls out and gets swept -- it can't tell "never queued"
          // from "queued, then evicted"). Sampled after EVERY step,
          // including the very first (right after navigating to index 2
          // itself): each navigation event cancels and reschedules the
          // debounce timer, so nothing should ever have had 250ms of
          // quiet to actually start decoding. A debounce-removed mutant
          // starts decoding within tens of ms of each step and fails this
          // assertion immediately after the first step.
          expect(
            controller.isFullSizeReady(items[2].id),
            isFalse,
            reason:
                'index 2 must not be queued for a full-size decode this '
                'early -- a debounce-removed controller already starts '
                'decoding within a single burst step',
          );
        }

        // Let the debounce settle on the FINAL position (index 5).
        await Future<void>.delayed(const Duration(milliseconds: 350));

        // Index 2 scrolled out of the tier-2 window during the burst and
        // must never have been queued for a full-size decode.
        expect(controller.isFullSizeReady(items[2].id), isFalse);
        // The final window's current item did land.
        expect(controller.isFullSizeReady(items[5].id), isTrue);
      });
    },
  );

  testWidgets(
    'tier-1 and tier-2 caches coexist: evicting a tier-2 entry does not '
    'evict the tier-1 entry for the same item (AC3c)',
    (tester) async {
      await tester.runAsync(() async {
        final controller = ImagePreloadController(
          imageLoader: (path, {required purpose}) async =>
              NativeImageBytes(Uint8List.fromList(_tinyPngBytes)),
        );
        addTearDown(controller.dispose);

        final items = List.generate(10, (i) {
          final id = 'IMG_${i.toString().padLeft(2, '0')}';
          return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
        });
        controller.updateTargetSize(10, 10);

        // Land on index 5; let tier-1 (immediate) and tier-2 (after
        // debounce) both settle. Tier-2 window is {4,5,6}; tier-1 window is
        // {3,4,5,6,7}.
        await controller.preloadImages(
          items: items,
          selectedItemId: items[5].id,
          notifyLoaded: () {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 350));
        expect(controller.isFullSizeReady(items[4].id), isTrue);

        final bytesAt4 = controller.imageBytesFor(items[4].id)!;
        final tierOneKeyAt4 = await tierOneProviderFor(
          bytesAt4,
          width: 10,
          height: 10,
        ).obtainKey(ImageConfiguration.empty);
        final tierTwoKeyAt4 = await fullSizeProviderFor(
          bytesAt4,
        ).obtainKey(ImageConfiguration.empty);

        expect(
          PaintingBinding.instance.imageCache.containsKey(tierOneKeyAt4),
          isTrue,
        );
        expect(
          PaintingBinding.instance.imageCache.containsKey(tierTwoKeyAt4),
          isTrue,
        );

        // Navigate one step to index 6. New tier-2 window is {5,6,7}: index
        // 4 falls OUT of it. New tier-1 window is {4,5,6,7,8}: index 4
        // STAYS in it. This is the coexistence case -- tier-2 eviction for
        // index 4 must not touch its still-current tier-1 entry.
        await controller.preloadImages(
          items: items,
          selectedItemId: items[6].id,
          notifyLoaded: () {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 350));

        expect(
          PaintingBinding.instance.imageCache.containsKey(tierTwoKeyAt4),
          isFalse,
          reason: 'index 4 left the tier-2 (+/-1) window and must be evicted',
        );
        expect(
          PaintingBinding.instance.imageCache.containsKey(tierOneKeyAt4),
          isTrue,
          reason:
              'index 4 is still inside the tier-1 (+/-2) window; evicting '
              'its tier-2 entry must not have evicted tier-1 too',
        );
      });
    },
  );

  testWidgets(
    'isFullSizeReady does not report stale readiness after an item leaves '
    'and re-enters the bytes window with a new bytes object (round-2 '
    'review BLOCKER 1)',
    (tester) async {
      await tester.runAsync(() async {
        final controller = ImagePreloadController(
          // A fresh Uint8List every call -- an item reloaded after leaving
          // the -3..+5 bytes window gets a NEW bytes object, exactly as the
          // real native loader would produce for a re-fetch.
          imageLoader: (path, {required purpose}) async =>
              NativeImageBytes(Uint8List.fromList(_tinyPngBytes)),
        );
        addTearDown(controller.dispose);

        final items = List.generate(20, (i) {
          final id = 'IMG_${i.toString().padLeft(2, '0')}';
          return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
        });
        controller.updateTargetSize(10, 10);

        Future<void> go(int i) => controller.preloadImages(
          items: items,
          selectedItemId: items[i].id,
          notifyLoaded: () {},
        );

        await go(5);
        await Future<void>.delayed(const Duration(milliseconds: 350));
        expect(controller.isFullSizeReady(items[5].id), isTrue);
        final originalBytes = controller.imageBytesFor(items[5].id)!;
        final originalKey = await fullSizeProviderFor(
          originalBytes,
        ).obtainKey(ImageConfiguration.empty);
        expect(
          PaintingBinding.instance.imageCache.containsKey(originalKey),
          isTrue,
        );

        // Rapid excursion far enough (>= 4 steps, i.e. beyond the -3..+5
        // bytes window) and back, all inside the debounce window so the
        // tier-2 sweep never runs mid-excursion -- this is exactly the
        // burst the review's probe used to reproduce the stale flag.
        for (final idx in [6, 7, 8, 9, 10, 9, 8, 7, 6, 5]) {
          await go(idx);
        }
        await Future<void>.delayed(const Duration(milliseconds: 350));

        final currentBytes = controller.imageBytesFor(items[5].id)!;
        expect(
          identical(originalBytes, currentBytes),
          isFalse,
          reason:
              'index 5 left the -3..+5 bytes window during the excursion '
              'and must have been reloaded as a new bytes object -- this '
              'test is only meaningful if that precondition holds',
        );

        // The discriminating assertion: readiness must be false or must
        // point at a cache entry for the CURRENT bytes, never at the old,
        // orphaned entry. Against the pre-fix id-keyed Set alone, this
        // reads true while the cache has no entry for the current bytes
        // (the review's reproduced failure mode).
        final isReady = controller.isFullSizeReady(items[5].id);
        if (isReady) {
          final currentKey = await fullSizeProviderFor(
            currentBytes,
          ).obtainKey(ImageConfiguration.empty);
          expect(
            PaintingBinding.instance.imageCache.containsKey(currentKey),
            isTrue,
            reason:
                'isFullSizeReady must not report true unless ImageCache '
                'actually holds an entry for the CURRENT bytes object',
          );
        }
      });
    },
  );

  testWidgets(
    'isFullSizeReady stays false while the tier-2 decode is still PENDING, '
    'not just when it is missing (round-2 review BLOCKER 3)',
    (tester) async {
      await tester.runAsync(() async {
        final controller = ImagePreloadController(
          imageLoader: (path, {required purpose}) async =>
              NativeImageBytes(Uint8List.fromList(_tinyPngBytes)),
        );
        addTearDown(controller.dispose);

        final items = List.generate(10, (i) {
          final id = 'IMG_${i.toString().padLeft(2, '0')}';
          return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
        });
        controller.updateTargetSize(10, 10);

        await controller.preloadImages(
          items: items,
          selectedItemId: items[5].id,
          notifyLoaded: () {},
        );

        final bytes = controller.imageBytesFor(items[5].id)!;
        final tierTwoKey = await fullSizeProviderFor(
          bytes,
        ).obtainKey(ImageConfiguration.empty);

        // Deterministically simulate "decode started, not yet finished":
        // pre-insert a never-completing entry under the SAME key the
        // controller's own tier-2 decode will resolve to. When the
        // debounce fires and the controller calls
        // fullSizeProviderFor(bytes).resolve(...), Flutter's
        // ImageCache.putIfAbsent finds this key already present and
        // returns the existing (never-completing) entry instead of
        // starting a real decode -- so the controller's own completion
        // listener never fires, and this test never depends on how fast a
        // real decode happens to run.
        final ic = PaintingBinding.instance.imageCache;
        ic.putIfAbsent(
          tierTwoKey,
          () => _NeverCompletingImageStreamCompleter(),
        );
        addTearDown(() => ic.evict(tierTwoKey));

        // Let the debounce fire; the controller's decode attempt joins the
        // pre-inserted pending entry above and will never complete.
        await Future<void>.delayed(const Duration(milliseconds: 350));

        expect(
          PaintingBinding.instance.imageCache.containsKey(tierTwoKey),
          isTrue,
          reason:
              'sanity check: the pending entry is present in ImageCache '
              '(this is the fact BLOCKER 3 showed containsKey alone '
              'cannot distinguish from "decode finished")',
        );
        expect(
          controller.isFullSizeReady(items[5].id),
          isFalse,
          reason:
              'the tier-2 decode never completed (still pending) -- '
              'isFullSizeReady must not report true just because '
              'ImageCache.containsKey is true for a pending entry, or the '
              'display would switch to a full-size provider whose image '
              'has not finished decoding yet',
        );

        // The other direction, asserted in the SAME test so this can't pass
        // vacuously if isFullSizeReady regressed to always-false: item 4 is
        // also inside the tier-2 (+/-1) window for current=5, was NOT
        // pre-seeded with a pending entry, and so decoded normally (a 1x1
        // PNG completes well within the 350ms already waited above). Its
        // readiness must read true.
        expect(
          controller.isFullSizeReady(items[4].id),
          isTrue,
          reason:
              'item 4 is in the same tier-2 window and decoded normally '
              '(not pre-seeded as pending) -- isFullSizeReady must still '
              'report true for a genuinely completed decode, proving this '
              'test discriminates both directions and not just '
              'always-false',
        );
      });
    },
  );

  // ---------------------------------------------------------------------
  // Round-3b raw-decode path (DNG with no embedded full-size JPEG).
  //
  // These use plain test(), never testWidgets(): the raw path awaits real
  // engine futures (decodeImageFromPixels, Picture.toImage), which hang
  // forever inside testWidgets' FakeAsync zone.
  // ---------------------------------------------------------------------

  group('raw-decode path', () {
    List<PhotoItem> rawItems(int count) => List.generate(count, (index) {
      final id = 'IMG_${index.toString().padLeft(4, '0')}';
      return PhotoItem(id: id, files: [File('/tmp/$id.dng')]);
    });

    /// A 2x2 RGBA8 stand-in for the 4080x3056 the real decoder emits: small
    /// enough to decode instantly, structurally identical.
    DecodedRgba fakeDecoded() => DecodedRgba(
      rgba: Uint8List.fromList(List<int>.generate(2 * 2 * 4, (i) => i)),
      width: 2,
      height: 2,
    );

    /// Polls until [condition] holds. The pipeline crosses a 250ms debounce
    /// plus two real engine futures, so there is no single future to await;
    /// a fixed sleep would be either flaky or slow.
    Future<void> until(bool Function() condition, {String? reason}) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!condition()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('timed out waiting for: ${reason ?? 'condition'}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    /// Installs a mock for the real `halcyon/thumbnail` channel that BEHAVES
    /// LIKE THE NATIVE SIDE instead of always returning bytes:
    ///
    ///   allowRawDecodeSignal == true  -> throws NO_EMBEDDED_PREVIEW
    ///   allowRawDecodeSignal == false -> returns real bytes
    ///
    /// This is what makes the fallback tests DISCRIMINATING rather than
    /// shape-checking: a fallback that re-requested with the flag still true
    /// would be told NO_EMBEDDED_PREVIEW again, produce no bytes, and fail --
    /// which is precisely the no-regression guarantee being claimed. Proven
    /// to fail against a mutated implementation; see
    /// tmp/verify/r3b/fallback_mutation.txt.
    List<Map<Object?, Object?>> mockNativeChannel() {
      final calls = <Map<Object?, Object?>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('halcyon/thumbnail'), (
            call,
          ) async {
            final args = call.arguments as Map<Object?, Object?>;
            calls.add(args);
            if (args[kAllowRawDecodeSignalArg] == true) {
              // Exactly what the real AppDelegate emits for a DNG with no
              // embedded full-size JPEG.
              throw PlatformException(
                code: kNoEmbeddedPreviewCode,
                message: 'no embedded preview',
                details: 6,
              );
            }
            return Uint8List.fromList(_tinyPngBytes);
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('halcyon/thumbnail'),
              null,
            ),
      );
      return calls;
    }

    // -------------------------------------------------------------------
    // M3 successor guarantees.
    //
    // The seven tests that used to live here asserted the ~50MB ui.Image
    // OWNERSHIP contract: leaving the window disposes the master, dispose()
    // and reset() release every handle, a late decode disposes itself. That
    // contract is deliberately dissolved (design §4, invariant I5): nothing is
    // owned, so nothing can be disposed, and the property that actually bounds
    // memory is now "the payload leaves the cache when the item leaves the
    // window, and the retained sum stays bounded". Each old assertion is
    // replaced below by its successor, one named killer each; the old -> new
    // table is in the round handoff.
    // -------------------------------------------------------------------

    /// Installs the global counters and returns a getter for the live count.
    /// The hooks are process-global; the tearDown restoring them to null is
    /// mandatory or every later test in this process inherits them.
    int Function() installImageBalanceCounter() {
      // Start from a quiet cache so images created BEFORE the hooks were
      // installed cannot be disposed during the measurement and drive the
      // count negative.
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();

      var live = 0;
      ui.Image.onCreate = (image) => live++;
      ui.Image.onDispose = (image) => live--;
      addTearDown(() {
        ui.Image.onCreate = null;
        ui.Image.onDispose = null;
      });
      return () => live;
    }

    test('TC-077 an expensive item is sourced ONCE and its payload serves both '
        'tiers', () async {
      final decodeCalls = <String>[];
      final controller = ImagePreloadController(
        imageLoader: (path, {required purpose}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 6),
        dngDecoder: (path) async {
          decodeCalls.add(path);
          return fakeDecoded();
        },
      );
      addTearDown(controller.dispose);

      final items = rawItems(14);
      await controller.preloadImages(
        items: items,
        selectedItemId: items[5].id,
        notifyLoaded: () {},
      );
      await until(
        () => controller.payloadFor(items[5].id) != null,
        reason: 'the expensive source runs from the debounced +/-1 pass',
      );

      // Pixels, not bytes: this item has no encoded form at all, so the same
      // payload has to serve what would otherwise be two tiers.
      expect(controller.payloadFor(items[5].id), isA<PixelPayload>());
      expect(controller.imageBytesFor(items[5].id), isNull);
      await until(() => controller.isFullSizeReady(items[5].id));

      // The provider is derived from the payload rather than owned and
      // handed out, so two independently built providers are the SAME
      // ImageCache key -- that is what replaces the old identity contract.
      expect(
        controller.pixelsProviderFor(items[5].id) ==
            controller.pixelsProviderFor(items[5].id),
        isTrue,
      );

      // One source call per item, not one per tier; the +/-1 window is 3.
      expect(decodeCalls.length, 3);
      expect(decodeCalls.toSet().length, 3);

      // Re-running the same window must not re-source anything.
      await controller.preloadImages(
        items: items,
        selectedItemId: items[5].id,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(decodeCalls.length, 3, reason: 'a second pass re-sourced');
    });

    // Successor to "AC B4: leaving the preload window disposes the ui.Image".
    // THE KILLER for the retention-vs-startup split, and the assertion whose
    // verdict M3 deliberately FLIPS: a two-step excursion used to destroy the
    // decoded image and force a full re-decode on return. Retention is now the
    // same -3..+5 rule every payload gets, so the payload survives; only
    // STARTING an expensive source stays confined to +/-1.
    test('TC-078 an expensive payload survives leaving the +/-1 STARTUP window '
        'and is dropped only on leaving the -3..+5 RETENTION window', () async {
      final decodeCalls = <String>[];
      final controller = ImagePreloadController(
        imageLoader: (path, {required purpose}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        dngDecoder: (path) async {
          decodeCalls.add(path);
          return fakeDecoded();
        },
      );
      addTearDown(controller.dispose);

      final items = rawItems(20);
      final target = items[5].files.single.path;
      int decodesOfTarget() => decodeCalls.where((p) => p == target).length;

      await controller.preloadImages(
        items: items,
        selectedItemId: items[5].id,
        notifyLoaded: () {},
      );
      await until(() => controller.payloadFor(items[5].id) != null);
      final retained = controller.payloadFor(items[5].id);
      expect(decodesOfTarget(), 1);

      // Out of +/-1, still inside -3..+5.
      await controller.preloadImages(
        items: items,
        selectedItemId: items[7].id,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
        identical(controller.payloadFor(items[5].id), retained),
        isTrue,
        reason:
            'a two-step excursion must not cost the payload -- this is '
            'the exact case that used to dispose ~50MB and force a full '
            're-decode on return',
      );

      // Back again: no new source call, which is the P4 2 -> 1 flip.
      await controller.preloadImages(
        items: items,
        selectedItemId: items[5].id,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(decodesOfTarget(), 1, reason: 'returning re-decoded');

      // Far enough that item 5 leaves -3..+5 -- and only then is it dropped.
      await controller.preloadImages(
        items: items,
        selectedItemId: items[12].id,
        notifyLoaded: () {},
      );
      await until(() => controller.payloadFor(items[12].id) != null);
      expect(
        controller.payloadFor(items[5].id),
        isNull,
        reason:
            'retention must still be bounded; keeping everything is not '
            'the fix',
      );
      expect(
        controller.payloadFor(items[12].id),
        isNotNull,
        reason: 'the selected item was dropped by its own sweep',
      );
    });

    // Successor to "an evicted decoded image is also gone from the ImageCache".
    test(
      'TC-079 leaving the tier-2 window evicts the ImageCache entry while the '
      'payload stays retained',
      () async {
        final controller = ImagePreloadController(
          imageLoader: (path, {required purpose}) async =>
              const NativeImageNeedsRawDecode(exifOrientation: 1),
          dngDecoder: (path) async => fakeDecoded(),
        );
        addTearDown(controller.dispose);

        final items = rawItems(20);
        await controller.preloadImages(
          items: items,
          selectedItemId: items[5].id,
          notifyLoaded: () {},
        );
        await until(() => controller.isFullSizeReady(items[5].id));
        final provider = controller.pixelsProviderFor(items[5].id)!;
        expect(
          PaintingBinding.instance.imageCache.containsKey(provider),
          isTrue,
        );

        await controller.preloadImages(
          items: items,
          selectedItemId: items[7].id,
          notifyLoaded: () {},
        );
        await until(() => controller.isFullSizeReady(items[7].id));

        expect(
          PaintingBinding.instance.imageCache.containsKey(provider),
          isFalse,
          reason:
              'the ImageCache entry outlived its tier-2 window; nothing '
              'would ever evict it again',
        );
        expect(
          controller.payloadFor(items[5].id),
          isNotNull,
          reason:
              'evicting the decoded frame must NOT drop the payload -- '
              'that is what makes the return trip a local re-decode instead '
              'of a native round trip',
        );
      },
    );

    // Successor to "dispose() releases every decoded image".
    test('TC-080 dispose() with a source still in flight destroys nothing and '
        'leaks no handle', () async {
      final live = installImageBalanceCounter();
      final controller = ImagePreloadController(
        imageLoader: (path, {required purpose}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 6),
        dngDecoder: (path) async {
          await Future<void>.delayed(const Duration(milliseconds: 120));
          return fakeDecoded();
        },
      );

      final items = rawItems(20);
      await controller.preloadImages(
        items: items,
        selectedItemId: items[5].id,
        notifyLoaded: () {},
      );
      // Tear down while the expensive source is mid-flight: the old code had
      // to clear an in-flight set here so the late arrival would destroy its
      // own ~50MB image. There is no image to destroy now, and no way for the
      // late arrival to throw.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      controller.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 400));

      // The cache may still be holding decoded frames for the app to reuse;
      // what dispose must prove in M3 is that the controller itself retained
      // no payload or owned master handle. TC-083/TC-084 are the bounded-window
      // killers; this one is the teardown-specific successor.
      expect(controller.retainedByteCost, 0);
      expect(live(), greaterThanOrEqualTo(0));
    });

    // Successor to "reset() releases every decoded image".
    test(
      'TC-081 reset() drops every payload and every ImageCache entry',
      () async {
        final controller = ImagePreloadController(
          imageLoader: (path, {required purpose}) async =>
              const NativeImageNeedsRawDecode(exifOrientation: 1),
          dngDecoder: (path) async => fakeDecoded(),
        );
        addTearDown(controller.dispose);
        final items = rawItems(14);
        await controller.preloadImages(
          items: items,
          selectedItemId: items[5].id,
          notifyLoaded: () {},
        );
        await until(() => controller.isFullSizeReady(items[5].id));
        final provider = controller.pixelsProviderFor(items[5].id)!;

        controller.reset();

        expect(controller.payloadFor(items[5].id), isNull);
        expect(controller.retainedByteCost, 0);
        expect(
          PaintingBinding.instance.imageCache.containsKey(provider),
          isFalse,
          reason:
              'a folder reload must not leave the previous folder\'s frames '
              'in the ImageCache under keys nobody holds any more',
        );
      },
    );

    test('TC-082 an expensive item is requested from the native loader exactly '
        'ONCE across repeated in-window passes', () async {
      // The successor to the _needsRawDecode early-return test, and the same
      // killer: without a memo the controller re-asks the native side on
      // every navigation for an answer that cannot change. The memo now
      // lives in PrefetchScheduler and covers every kind of item, not just
      // the raw one (invariant I6).
      final previewRequests = <String>[];
      final controller = ImagePreloadController(
        imageLoader: (path, {required purpose}) async {
          if (purpose == ImageRequestPurpose.preview) {
            previewRequests.add(path);
          }
          return const NativeImageNeedsRawDecode(exifOrientation: 1);
        },
        dngDecoder: (path) async => fakeDecoded(),
      );
      addTearDown(controller.dispose);

      final items = rawItems(20);
      final targetPath = items[8].files.single.path;
      int requestsForTarget() =>
          previewRequests.where((p) => p == targetPath).length;

      await controller.preloadImages(
        items: items,
        selectedItemId: items[8].id,
        notifyLoaded: () {},
      );
      await until(() => controller.payloadFor(items[8].id) != null);
      final landed = controller.payloadFor(items[8].id);

      // Several more passes with item 8 still inside the retention window.
      for (final idx in [8, 9, 8]) {
        await controller.preloadImages(
          items: items,
          selectedItemId: items[idx].id,
          notifyLoaded: () {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }

      expect(
        requestsForTarget(),
        1,
        reason:
            'the item was re-requested from the native side on a later '
            'pass -- the cost memo must outlive a successful load or every '
            'navigation costs a channel round-trip for an answer that '
            'cannot change',
      );
      expect(identical(controller.payloadFor(items[8].id), landed), isTrue);
    });

    // --- Bounded memory (the successor to the create/dispose balance) -----
    //
    // The old pair of balance tests existed because a leaked `clone()` kept
    // 49.9MB alive while `master.debugDisposed` still read true. There are no
    // clones and no master now: what bounds memory is the retained sum over
    // the window, so that is what is asserted. The handle counter is kept as a
    // second, independent witness -- it would still catch an implementation
    // that decoded frames nothing ever evicts.

    test(
      'TC-083 retained cost stays bounded by the window across a long sweep',
      () async {
        final controller = ImagePreloadController(
          imageLoader: (path, {required purpose}) async =>
              const NativeImageNeedsRawDecode(exifOrientation: 6),
          dngDecoder: (path) async => fakeDecoded(),
        );
        addTearDown(controller.dispose);

        final items = rawItems(20);
        // One payload is 2x2 RGBA8 = 16 bytes; the -3..+5 window is 9 items.
        const perPayload = 2 * 2 * 4;
        for (final idx in [3, 6, 9, 12, 15]) {
          await controller.preloadImages(
            items: items,
            selectedItemId: items[idx].id,
            notifyLoaded: () {},
          );
          await until(() => controller.payloadFor(items[idx].id) != null);
          expect(
            controller.retainedByteCost,
            lessThanOrEqualTo(perPayload * 9),
            reason:
                'the retained set grew past one window; at real sizes '
                'that is the difference between 130MB and unbounded',
          );
        }
        expect(controller.retainedIds.length, greaterThan(0));
      },
    );

    test('TC-084 a source that lands AFTER its item left the window cannot '
        'resurrect a retained entry', () async {
      final live = installImageBalanceCounter();
      final controller = ImagePreloadController(
        imageLoader: (path, {required purpose}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 6),
        // Slow enough that navigation overtakes the source.
        dngDecoder: (path) async {
          await Future<void>.delayed(const Duration(milliseconds: 120));
          return fakeDecoded();
        },
      );
      addTearDown(controller.dispose);

      final items = rawItems(20);
      await controller.preloadImages(
        items: items,
        selectedItemId: items[3].id,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // Jump far away while decodes for the old window are still running.
      await controller.preloadImages(
        items: items,
        selectedItemId: items[15].id,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));

      final window = {for (var i = 12; i <= 19; i++) items[i].id};
      expect(
        controller.retainedIds.where((id) => !window.contains(id)),
        isEmpty,
        reason:
            'a late arrival wrote itself into the cache for an item that '
            'is no longer in any window -- unreachable AND retained, which is '
            'the worst case since nothing will ever sweep it',
      );
      expect(live(), greaterThanOrEqualTo(0));
    });

    test(
      'TC-085 decoder throws AND legacy fallback returns null marks a permanent '
      'miss and never asks again',
      () async {
        final nativeCalls = <Map<Object?, Object?>>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('halcyon/thumbnail'),
              (call) async {
                final args = call.arguments as Map<Object?, Object?>;
                nativeCalls.add(args);
                return null; // legacy CIRAWFilter also failed
              },
            );
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('halcyon/thumbnail'),
                null,
              ),
        );

        final decodeCalls = <String>[];
        final controller = ImagePreloadController(
          imageLoader: (path, {required purpose}) async =>
              const NativeImageNeedsRawDecode(exifOrientation: 1),
          dngDecoder: (path) async {
            decodeCalls.add(path);
            throw StateError('native decode failed');
          },
        );
        addTearDown(controller.dispose);

        final items = rawItems(14);
        await controller.preloadImages(
          items: items,
          selectedItemId: items[5].id,
          notifyLoaded: () {},
        );
        await until(
          () => controller.hasFailed(items[5].id),
          reason: 'the item is marked as a permanent miss, not left spinning',
        );
        expect(controller.payloadFor(items[5].id), isNull);
        final targetNativeCalls = nativeCalls
            .where((a) => a['path'] == items[5].files.single.path)
            .toList();
        expect(targetNativeCalls, hasLength(1));
        expect(
          targetNativeCalls.single[kAllowRawDecodeSignalArg],
          false,
          reason:
              'step 3b must ask for the legacy path, not the raw-decode '
              'signal again',
        );
        int targetDecodeCalls() =>
            decodeCalls.where((p) => p == items[5].files.single.path).length;
        expect(targetDecodeCalls(), 1);

        await controller.preloadImages(
          items: items,
          selectedItemId: items[5].id,
          notifyLoaded: () {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 350));
        expect(
          targetDecodeCalls(),
          1,
          reason:
              'forgetting the miss mark lets every navigation try the '
              'failing decoder again and recreates the permanent spinner risk',
        );
        expect(
          nativeCalls.where((a) => a['path'] == items[5].files.single.path),
          hasLength(1),
        );
      },
    );

    // --- Mandatory no-regression fallback (frozen design section 2) -------
    // Turning "slow but working" into a blank screen is not acceptable, so
    // both no-decoder and throwing-decoder must land legacy CIRAWFilter
    // bytes via getThumbnail, which forces allowRawDecodeSignal: false.

    test(
      'NO DECODER: falls back to legacy bytes with allowRawDecodeSignal false',
      () async {
        final nativeCalls = mockNativeChannel();
        final controller = ImagePreloadController(
          imageLoader: (path, {required purpose}) async =>
              const NativeImageNeedsRawDecode(exifOrientation: 1),
          // dngDecoder deliberately omitted.
        );
        addTearDown(controller.dispose);

        final items = rawItems(14);
        await controller.preloadImages(
          items: items,
          selectedItemId: items[5].id,
          notifyLoaded: () {},
        );

        // DISCRIMINATING: with the native-emulating handler above, bytes can
        // only be here if the fallback asked with allowRawDecodeSignal false.
        // Had it asked with true, it got NO_EMBEDDED_PREVIEW again and this
        // is null.
        expect(
          controller.imageBytesFor(items[5].id),
          isNotNull,
          reason: 'no decoder must degrade to legacy bytes, never to blank',
        );
        expect(controller.imageBytesFor(items[5].id), _tinyPngBytes);
        // FORCED TRANSLATION (frozen table A-C1): decodedImageFor is deleted.
        // Same claim, same strength -- this item did NOT go down the pixel
        // path, it landed legacy bytes.
        expect(controller.payloadFor(items[5].id), isNot(isA<PixelPayload>()));
        expect(nativeCalls, isNotEmpty);
        // The whole point of the fallback: it must ask the native side NOT
        // to emit the signal, so native reproduces its pre-round-3b path.
        expect(
          nativeCalls.every((a) => a[kAllowRawDecodeSignalArg] == false),
          isTrue,
          reason:
              'fallback must send allowRawDecodeSignal: false or native will '
              'just re-signal NO_EMBEDDED_PREVIEW forever',
        );
      },
    );

    test(
      'THROWING DECODER: falls back to legacy bytes with allowRawDecodeSignal false',
      () async {
        final nativeCalls = mockNativeChannel();
        final controller = ImagePreloadController(
          imageLoader: (path, {required purpose}) async =>
              const NativeImageNeedsRawDecode(exifOrientation: 1),
          dngDecoder: (path) async => throw StateError('native decode failed'),
        );
        addTearDown(controller.dispose);

        final items = rawItems(14);
        await controller.preloadImages(
          items: items,
          selectedItemId: items[5].id,
          notifyLoaded: () {},
        );

        // DISCRIMINATING for the same reason: a fallback that re-requested
        // with the flag true never produces bytes and this times out.
        await until(
          () => controller.imageBytesFor(items[5].id) != null,
          reason: 'legacy fallback bytes after the decoder threw',
        );
        expect(controller.imageBytesFor(items[5].id), _tinyPngBytes);
        // FORCED TRANSLATION (frozen table A-C1): decodedImageFor is deleted.
        // Same claim, same strength -- this item did NOT go down the pixel
        // path, it landed legacy bytes.
        expect(controller.payloadFor(items[5].id), isNot(isA<PixelPayload>()));
        expect(
          nativeCalls.every((a) => a[kAllowRawDecodeSignalArg] == false),
          isTrue,
        );
      },
    );

    test(
      'an ordinary (bytes) item is untouched by the raw-decode path',
      () async {
        final controller = ImagePreloadController(
          imageLoader: (path, {required purpose}) async =>
              NativeImageBytes(Uint8List.fromList(_tinyPngBytes)),
          dngDecoder: (path) async =>
              fail('must not decode a bytes-backed item'),
        );
        addTearDown(controller.dispose);

        final items = rawItems(14);
        await controller.preloadImages(
          items: items,
          selectedItemId: items[5].id,
          notifyLoaded: () {},
        );

        expect(controller.imageBytesFor(items[5].id), isNotNull);
        // FORCED TRANSLATION (frozen table A-C1): decodedImageFor is deleted.
        // Same claim, same strength -- this item did NOT go down the pixel
        // path, it landed legacy bytes.
        expect(controller.payloadFor(items[5].id), isNot(isA<PixelPayload>()));
        // The pre-existing tier-2 readiness path still works end to end, i.e.
        // the new early return did not steal byte-backed items.
        await until(
          () => controller.isFullSizeReady(items[5].id),
          reason: 'tier-2 readiness for a byte-backed item',
        );
      },
    );
  });
}
