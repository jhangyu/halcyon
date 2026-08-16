import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_preload_controller.dart';

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
  test(
    'preloadImages evicts preview cache entries outside the sliding window',
    () async {
      final controller = ImagePreloadController(
        imageLoader: (path, {required purpose}) async {
          return Uint8List.fromList([path.hashCode & 0xFF]);
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
      final completers = <String, Completer<Uint8List?>>{};

      final controller = ImagePreloadController(
        imageLoader: (path, {required purpose}) {
          requestOrder.add(path);
          final completer = Completer<Uint8List?>();
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
      completers[selectedPath]!.complete(Uint8List.fromList([1]));
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
        completers[path]!.complete(Uint8List.fromList([path.hashCode & 0xFF]));
      }

      await preloadFuture;

      for (var i = 2; i <= 10; i++) {
        expect(controller.imageBytesFor(items[i].id), isNotNull);
      }
    },
  );

  test(
    'selecting an in-flight item still fires notify once its load completes '
    '(R3: no permanent spinner strand)',
    () async {
      final completers = <String, Completer<Uint8List?>>{};
      var firstNotify = 0;
      var secondNotify = 0;

      final controller = ImagePreloadController(
        imageLoader: (path, {required purpose}) {
          final completer = Completer<Uint8List?>();
          completers[path] = completer;
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
      expect(completers[targetPath]!.isCompleted, isFalse);

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
      completers[targetPath]!.complete(Uint8List.fromList([1]));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

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

      // Drain remaining window loads from both passes so the test doesn't
      // leak pending futures.
      for (final completer in completers.values) {
        if (!completer.isCompleted) {
          completer.complete(Uint8List.fromList([2]));
        }
      }
      await firstPass;
      await secondPass;
    },
  );

  test(
    'tierOneProviderFor produces an identical ImageCache key for the same '
    'bytes object identity and same width/height (AC2: display and '
    'precache must share one cache entry, not silently double-decode)',
    () async {
      final bytes = Uint8List.fromList(List.generate(16, (i) => i));

      // Simulates the precache call site.
      final precacheProvider = tierOneProviderFor(bytes, width: 800, height: 600);
      // Simulates the display call site: a fresh ResizeImage/MemoryImage
      // instance, but built from the SAME bytes object and SAME dimensions.
      final displayProvider = tierOneProviderFor(bytes, width: 800, height: 600);

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

        final precacheProvider = tierOneProviderFor(bytes, width: 10, height: 10);
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
        final displayProvider = tierOneProviderFor(bytes, width: 10, height: 10);
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
              Uint8List.fromList(_tinyPngBytes),
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
              Uint8List.fromList(_tinyPngBytes),
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
              Uint8List.fromList(_tinyPngBytes),
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
              Uint8List.fromList(_tinyPngBytes),
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
              Uint8List.fromList(_tinyPngBytes),
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
      });
    },
  );
}
