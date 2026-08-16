import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_preload_controller.dart';

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
}
