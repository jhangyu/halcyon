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
}
