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
}
