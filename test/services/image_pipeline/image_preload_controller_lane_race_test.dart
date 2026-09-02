// TC-380 (provisional number -- re-verify against the SOP register at merge).
// Defect A from docs/logs/2026-08-30/lane-race-arch-verdict.md §1.A:
// _ensurePayload checks `_loadingKeys.contains(id)` BEFORE the probe await but
// claims the id AFTER it, so two entrants for the same id both pass the check
// and both run a source load. The second `_cache.put` replaces the payload
// object, orphaning the tier-1 ImageCache entry keyed on bytes identity.
//
// The race needs no wall-clock timing: `_scheduler.classify` is async, so the
// first entrant is guaranteed to be suspended at that await when the second
// entrant runs its check. The loader gate below only holds the first load open
// long enough for the assertion to be about production, not about timing.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<PhotoItem> items(int count) => List.generate(count, (index) {
    final id = 'IMG_${index.toString().padLeft(4, '0')}';
    return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
  });

  test(
    'TC-380 two concurrent entrants for the same id run exactly one load '
    'and never replace the payload object (decode lane width 2)',
    () async {
      final loadsByPath = <String, int>{};
      final gate = Completer<void>();

      final controller = ImagePreloadController(
        decodeLaneWidth: 2,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async {
          loadsByPath[path] = (loadsByPath[path] ?? 0) + 1;
          // Hold the FIRST load open so a second entrant, if the claim is
          // still taken after the probe await, has every opportunity to
          // start its own load. Later loads are not gated, so a defective
          // build finishes and is measured rather than hanging.
          if (loadsByPath[path] == 1) {
            await gate.future;
          }
          // A FRESH bytes object per call: two loads therefore produce two
          // distinct payload objects, which is exactly what makes the
          // `identical` assertion below meaningful.
          return NativeImageBytes(Uint8List.fromList([137, 80, 78, 71]));
        },
      );
      addTearDown(controller.dispose);

      final photos = items(6);
      final selected = photos[2];

      // Two navigation passes with NO await in between: both reach
      // `_ensurePayload` for the selected id with `precomputedProbe == null`.
      final first = controller.preloadImages(
        items: photos,
        selectedItemId: selected.id,
        notifyLoaded: () {},
      );
      final second = controller.preloadImages(
        items: photos,
        selectedItemId: selected.id,
        notifyLoaded: () {},
      );

      // Let both entrants get past the probe await before anything lands.
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      gate.complete();
      await Future.wait([first, second]);

      expect(
        loadsByPath['/tmp/${selected.id}.jpg'],
        1,
        reason:
            'the in-flight claim must be taken BEFORE the probe await, so the '
            'second entrant parks instead of buying a second source load',
      );

      final landed = controller.payloadFor(selected.id);
      expect(landed, isNotNull);

      // A late second load would replace the cached payload object and
      // silently orphan the tier-1 ImageCache key (bytes identity).
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        identical(controller.payloadFor(selected.id), landed),
        isTrue,
        reason: 'the payload OBJECT must never be replaced by a second load',
      );
    },
  );
}
