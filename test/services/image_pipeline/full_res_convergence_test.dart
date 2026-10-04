// Full-resolution convergence of the DISPLAYED photo (viewport-tier removal,
// 2026-10-04). The viewer repaints only when the selected item's per-item
// notifier ticks (`photo_viewport.dart`), so "the registry says full-res is
// resident" is not enough: the notifier must say so too, on every landing
// route. These tests pin the routes the old wrapper-based refresh missed.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/event_loop.dart';
import '../../support/preload_fixtures.dart';
import '../../support/temp_dirs.dart';

/// A folder of [count] tiny real image files, `f00.jpg`..: the scanner needs
/// real files, the loader below never reads them.
Directory _folder(int count) {
  final dir = makeTempDirSync('halcyon_fullres_conv');
  for (var i = 0; i < count; i++) {
    File('${dir.path}/f${i.toString().padLeft(2, '0')}.jpg')
        .writeAsBytesSync(tinyPngBytes);
  }
  return dir;
}

/// Every load waits on its own per-path gate until the test releases it.
class _GatedLoader {
  final Map<String, Completer<void>> _gates = {};

  Completer<void> _gate(String path) =>
      _gates.putIfAbsent(path, Completer<void>.new);

  void release(String path) {
    final gate = _gate(path);
    if (!gate.isCompleted) gate.complete();
  }

  Future<NativeImageResult> call(
    String path, {
    required ImageRequestPurpose purpose,
    int? targetLongEdge,
  }) async {
    await _gate(path).future;
    // A FRESH bytes object per load: the full-size cache key is bytes
    // identity, so two loads must never share one.
    return NativeImageBytes(Uint8List.fromList(tinyPngBytes));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    clearImageCacheSetUp();
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'TC-1460 double-skip: two navigations inside the debounce onto a COLD '
    'item still converge the displayed photo to full resolution',
    () async {
      final loader = _GatedLoader();
      final controller = ImagePreloadController(
        scheduleFrameCallback: immediateFrameCallback,
        imageLoader: loader.call,
        dngDecoder: (path) async => fail('cheap rung must not RAW-decode'),
      );
      final state = AppState(preloadController: controller);
      addTearDown(state.dispose);
      final dir = _folder(16);
      addTempDirTeardown(dir);

      await state.loadFolder(dir, targetSelectionId: 'f05');
      final items = state.items;
      final a = items[5], b = items[6], c = items[7];
      expect(state.selectedItemID, a.id);

      // The viewer's subscription, taken before anything lands (as
      // `photo_viewport.dart` does for the selected item).
      final notifier = state.payloadStateFor(c.id);
      final stages = <PayloadStage>[notifier.value.stage];
      void record() => stages.add(notifier.value.stage);
      notifier.addListener(record);
      addTearDown(() => notifier.removeListener(record));

      // Two navigations, each its own pass, both well inside the debounce.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      state.selectItem(b.id);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      state.selectItem(c.id);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(controller.payloadFor(c.id), isNull, reason: 'C must be cold');

      // Only C's load ever lands; its neighbours stay in flight forever, so
      // no other landing can wake C's notifier by accident.
      loader.release(c.bestFileToLoad!.path);
      await until(
        () => controller.isFullSizeReady(c.id),
        reason: 'C to gain a resident full-size entry',
      );
      // Past the debounce, so the settle sweep has run too.
      await Future<void>.delayed(
        tierTwoNavigationDebounce + const Duration(milliseconds: 150),
      );

      expect(
        notifier.value.stage,
        PayloadStage.tierTwoReady,
        reason: 'the registry holds C at full resolution; the notifier the '
            'viewer repaints from must say so (observed: $stages)',
      );
      final payload = controller.payloadFor(c.id);
      expect(payload, isA<EncodedPayload>());
      final display = state.displayProvider;
      expect(display, isA<MemoryImage>());
      expect(
        identical((display! as MemoryImage).bytes,
            (payload! as EncodedPayload).bytes),
        isTrue,
        reason: 'displayProvider must be the full-size provider for the '
            'retained payload',
      );
    },
  );

  test(
    'TC-1472 eviction and re-entry: a full-res item that leaves the band '
    'ticks DOWN, and ticks back UP when the user returns',
    () async {
      final controller = ImagePreloadController(
        scheduleFrameCallback: immediateFrameCallback,
        navigationDebounce: Duration.zero,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
        dngDecoder: (path) async => fail('cheap rung must not RAW-decode'),
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(10, 10);
      final items = paddedItems(20);
      final id = items[5].id;

      final notifier = controller.stateFor(id);
      final stages = <PayloadStage>[];
      void record() => stages.add(notifier.value.stage);
      notifier.addListener(record);
      addTearDown(() => notifier.removeListener(record));

      Future<void> select(int index) => controller.preloadImages(
            items: items,
            selectedItemId: items[index].id,
            notifyLoaded: () {},
          );

      await select(5);
      await until(() => notifier.value.stage == PayloadStage.tierTwoReady,
          reason: 'first convergence');

      // +3 steps forward: item 5 sits at -3 -- still RETAINED (payload kept)
      // but outside the -1..+2 band, so its full-size entry is evicted.
      await select(8);
      await until(() => !controller.debugTierTwoKeyIds.contains(id),
          reason: 'band leave evicts the full-size entry');
      expect(controller.payloadFor(id), isNotNull,
          reason: 'precondition: degraded, not evicted');
      expect(notifier.value.stage, PayloadStage.payloadReady,
          reason: 'a notifier left at tierTwoReady after its entry is gone '
              'is the stale-ready gap');

      await select(5);
      await until(() => notifier.value.stage == PayloadStage.tierTwoReady,
          reason: 're-entry must tick the notifier back to full resolution');
      expect(controller.isFullSizeReady(id), isTrue);
      expect(
        stages.sublist(stages.indexOf(PayloadStage.tierTwoReady)),
        [
          PayloadStage.tierTwoReady,
          PayloadStage.payloadReady,
          PayloadStage.tierTwoReady,
        ],
      );
    },
  );
}
