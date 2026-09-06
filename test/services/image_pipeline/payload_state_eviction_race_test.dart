import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/retention_policy.dart';

import '../../support/preload_fixtures.dart';

/// Same shape as `async_baseline_pins_test.dart`'s frame hook: publish on the
/// spot instead of waiting for a real engine frame.
void _microtaskFrame(void Function() callback) => callback();

void main() {
  // Without the binding, the controller's very first landing never completes
  // (and dispose() throws from _evictTierOneKeys reaching PaintingBinding),
  // so every assertion below would fail for a harness reason instead of the
  // mechanism under test. Same preamble as async_baseline_pins_test.dart.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(clearImageCacheSetUp);

  // A budget of one byte: PhotoPayloadCache._enforceBudget keeps only the
  // just-written entry, so every landing evicts every other payload --
  // including payloads whose ids are still inside the retention window. That
  // is the same pressure the production budget applies on a no-preview RAW
  // folder, just forced deterministically.
  //
  // Consequence that shapes both tests below: `_pickVictim` excludes only the
  // JUST-WRITTEN id, so "the selected item is the last victim" ranks candidates
  // but does not make the selection safe -- under this budget, EVERY window
  // neighbour that lands after A evicts A. So A can never be observed resident
  // while a full window is landing. The landing passes therefore use a
  // one-item list (no neighbours exist to evict A); the eviction is then forced
  // by the full window, which is the pressure under test. The budget stays the
  // only eviction mechanism -- `retainOnly`/`clear` are never called.
  ImagePreloadController buildController() {
    final controller = ImagePreloadController(
      scheduleFrameCallback: _microtaskFrame,
      retention: const RetentionPolicy(
        before: 3,
        after: 5,
        payloadByteBudget: 1,
      ),
      imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
          NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
      dngDecoder: (path) async => fail('cheap rung must not RAW-decode'),
    );
    controller.updateTargetSize(800, 600);
    return controller;
  }

  test(
    'TC-1010: a payload evicted under byte pressure stops claiming readiness',
    () async {
      final controller = buildController();
      addTearDown(controller.dispose);
      final items = paddedItems(12, extension: 'jpg');
      final a = items[0].id;
      final onlyA = <PhotoItem>[items[0]];

      await controller.preloadImages(
        items: onlyA,
        selectedItemId: a,
        notifyLoaded: () {},
      );
      await until(
        () => controller.imageBytesFor(a) != null,
        reason: "item A's payload to land",
      );
      // Materialise A's notifier the way a StripTile does.
      controller.stateFor(a);

      // A second selection inside A's retention window: its landing evicts A
      // for budget reasons while A is still retained.
      await controller.preloadImages(
        items: items,
        selectedItemId: items[1].id,
        notifyLoaded: () {},
      );
      await until(
        () => controller.imageBytesFor(a) == null,
        reason: "item A's payload to be evicted under byte pressure",
      );

      expect(
        controller.debugPayloadStateFor(a).stage,
        isNot(PayloadStage.tierOneReady),
        reason:
            'the per-item state claims a payload the cache no longer holds; a '
            'tile trusting it paints nothing and waits forever',
      );
      expect(
        controller.debugPayloadStateFor(a).stage,
        isNot(PayloadStage.tierTwoReady),
        reason: 'same lie, one rung higher',
      );
    },
  );

  test(
    'TC-1011: a re-decode landing after eviction notifies the item listener',
    () async {
      final controller = buildController();
      addTearDown(controller.dispose);
      final items = paddedItems(12, extension: 'jpg');
      final a = items[0].id;
      final onlyA = <PhotoItem>[items[0]];

      await controller.preloadImages(
        items: onlyA,
        selectedItemId: a,
        notifyLoaded: () {},
      );
      await until(
        () => controller.imageBytesFor(a) != null,
        reason: "item A's payload to land",
      );

      final ValueListenable<PayloadState> state = controller.stateFor(a);
      await controller.preloadImages(
        items: items,
        selectedItemId: items[1].id,
        notifyLoaded: () {},
      );
      await until(
        () => controller.imageBytesFor(a) == null,
        reason: "item A's payload to be evicted under byte pressure",
      );

      var notifications = 0;
      void listener() => notifications++;
      state.addListener(listener);
      addTearDown(() => state.removeListener(listener));

      // Navigate back: A is re-decoded and re-lands. One-item list again, so
      // the re-landing is not immediately undone by a neighbour under this
      // deliberately tiny budget.
      await controller.preloadImages(
        items: onlyA,
        selectedItemId: a,
        notifyLoaded: () {},
      );
      await until(
        () => controller.imageBytesFor(a) != null,
        reason: "item A's payload to land again",
      );

      expect(
        notifications,
        greaterThan(0),
        reason:
            'the re-landing was silent: _markStage refuses the transition '
            'because the stale state already reads tierOneReady, so the tile '
            'is never told to repaint',
      );
    },
  );
}
