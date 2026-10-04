// Full-resolution band -1..+2 (viewport-tier removal, 2026-10-04; contract
// docs/logs/2026-10-04/viewport-tier-removal-contract.md, AC3 + AC4).
//
// AC3: decodes/retention for EXACTLY {cur-1, cur, cur+1, cur+2}, nothing
//      outside, and the cache budget is sized for 4 slots.
// AC4: an item that reached full resolution, left the band and came back has
//      its per-item notifier tick on the way out (no stale tierTwoReady) and
//      converge again on re-entry.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/cache_budget.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/prefetch_scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/event_loop.dart';
import '../../support/preload_fixtures.dart';
import '../../support/temp_dirs.dart';

/// Fresh bytes per load: the full-size cache key is bytes identity.
Future<NativeImageResult> _loader(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async =>
    NativeImageBytes(Uint8List.fromList(tinyPngBytes));

ImagePreloadController _controller() {
  final controller = ImagePreloadController(
    scheduleFrameCallback: immediateFrameCallback,
    navigationDebounce: Duration.zero,
    imageLoader: _loader,
    dngDecoder: (path) async => fail('cheap rung must not RAW-decode'),
  );
  controller.updateTargetSize(10, 10);
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    clearImageCacheSetUp();
    SharedPreferences.setMockInitialValues({});
  });

  group('AC3 band -1..+2', () {
    test('TC-1461 band constants are -1/+2 and the budget is sized for 4 slots',
        () {
      expect(kFullResolutionBandBefore, 1);
      expect(kFullResolutionBandAfter, 2);
      expect(kFullResolutionBandSlotCount, 4);

      // The budget must be the 4-slot working set, not the old 3-slot one:
      // compute both from the formula and require the app budget to match 4.
      const pixels = kReferenceFullResolutionPixels;
      int budgetFor(int slots) => imageCacheBudgetBytesFromWorkingSet(
            fullResolutionBandSlotCount: slots,
            fullResolutionImageByteCost: pixels * kDecodedBytesPerPixel,
            sidebarThumbnailPoolByteCost: kSidebarThumbnailPoolByteCost,
            safetyFactor: kImageCacheSafetyFactor,
          );
      expect(imageCacheBudgetBytes(), budgetFor(4));
      expect(budgetFor(4), greaterThan(budgetFor(3)));
    });

    testWidgets(
      'TC-1462 settled mid-list: decoded keys are exactly cur-1..cur+2, '
      'neighbours outside keep payload only',
      (tester) async {
        await tester.runAsync(() async {
          final controller = _controller();
          addTearDown(controller.dispose);
          final photos = paddedItems(16);
          const cur = 6;
          final band = <String>{for (var i = cur - 1; i <= cur + 2; i++) photos[i].id};

          await controller.preloadImages(
            items: photos,
            selectedItemId: photos[cur].id,
            notifyLoaded: () {},
          );
          await until(
            () => band.every(controller.isFullSizeReady),
            reason: 'band -1..+2 to reach full resolution',
          );
          // Let any stray out-of-band publish/eviction land before asserting
          // the set (a superset must not slip through on timing).
          await Future<void>.delayed(const Duration(milliseconds: 400));

          expect(controller.debugTierTwoKeyIds, band);
          for (final i in [cur - 2, cur + 3]) {
            expect(controller.isFullSizeReady(photos[i].id), isFalse,
                reason: 'index $i is outside the band');
            expect(controller.payloadFor(photos[i].id), isNotNull,
                reason: 'index $i is inside retention: payload kept, not '
                    'decoded');
          }
        });
      },
    );

    testWidgets(
      'TC-1463 sliding the selection moves the band: leavers are evicted, '
      'entrants decode, set equals the new band exactly',
      (tester) async {
        await tester.runAsync(() async {
          final controller = _controller();
          addTearDown(controller.dispose);
          final photos = paddedItems(16);
          Set<String> bandAt(int cur) =>
              {for (var i = cur - 1; i <= cur + 2; i++) photos[i].id};

          for (final cur in [6, 7, 10]) {
            await controller.preloadImages(
              items: photos,
              selectedItemId: photos[cur].id,
              notifyLoaded: () {},
            );
            await until(
              () => bandAt(cur).every(controller.isFullSizeReady),
              reason: 'band around $cur to reach full resolution',
            );
            await until(
              () => controller.debugTierTwoKeyIds.length == bandAt(cur).length,
              reason: 'leavers of the previous band to be evicted',
            );
            expect(controller.debugTierTwoKeyIds, bandAt(cur),
                reason: 'selection $cur');
          }
        });
      },
    );

    testWidgets(
      'TC-1464 clamped at both list ends the band shrinks, never wraps',
      (tester) async {
        await tester.runAsync(() async {
          final controller = _controller();
          addTearDown(controller.dispose);
          final photos = paddedItems(10);

          await controller.preloadImages(
            items: photos,
            selectedItemId: photos[0].id,
            notifyLoaded: () {},
          );
          final head = {photos[0].id, photos[1].id, photos[2].id};
          await until(() => head.every(controller.isFullSizeReady),
              reason: 'clamped head band 0..+2');
          await Future<void>.delayed(const Duration(milliseconds: 400));
          expect(controller.debugTierTwoKeyIds, head);

          await controller.preloadImages(
            items: photos,
            selectedItemId: photos[9].id,
            notifyLoaded: () {},
          );
          final tail = {photos[8].id, photos[9].id};
          await until(() => tail.every(controller.isFullSizeReady),
              reason: 'clamped tail band -1..0');
          await until(() => controller.debugTierTwoKeyIds.length == 2,
              reason: 'head band to be evicted');
          expect(controller.debugTierTwoKeyIds, tail);
        });
      },
    );
  });

  group('AC4 eviction / re-entry', () {
    test(
      'TC-1465 full-res -> leave band -> return: notifier ticks out of '
      'tierTwoReady, then converges to tierTwoReady again',
      () async {
        final controller = ImagePreloadController(
          scheduleFrameCallback: immediateFrameCallback,
          imageLoader: _loader,
          dngDecoder: (path) async => fail('cheap rung must not RAW-decode'),
        );
        final state = AppState(preloadController: controller);
        addTearDown(state.dispose);
        final dir = makeTempDirSync('halcyon_fullres_band');
        for (var i = 0; i < 16; i++) {
          File('${dir.path}/f${i.toString().padLeft(2, '0')}.jpg')
              .writeAsBytesSync(tinyPngBytes);
        }
        addTempDirTeardown(dir);

        await state.loadFolder(dir, targetSelectionId: 'f05');
        final target = state.items[5];

        // Subscribed before anything lands, as the viewer does. Index 5 is
        // moved only 3 away (stays inside retention -3..+5), so the notifier
        // object is not recreated on the way out.
        final notifier = state.payloadStateFor(target.id);
        final stages = <PayloadStage>[notifier.value.stage];
        void record() => stages.add(notifier.value.stage);
        notifier.addListener(record);
        addTearDown(() => notifier.removeListener(record));

        await until(
          () => notifier.value.stage == PayloadStage.tierTwoReady,
          reason: 'first convergence to full resolution (seen: $stages)',
        );
        expect(controller.isFullSizeReady(target.id), isTrue);

        // Beyond the band: selection 8 -> band 7..10, target at -3.
        state.selectItem(state.items[8].id);
        await until(
          () => !controller.isFullSizeReady(target.id),
          reason: 'band leaver to lose its full-size entry',
        );
        await until(
          () => notifier.value.stage != PayloadStage.tierTwoReady,
          reason: 'notifier must leave tierTwoReady on eviction — a stale '
              'ready state is the gap this test closes (seen: $stages)',
        );

        // Return.
        final ticksBeforeReturn = stages.length;
        state.selectItem(target.id);
        await until(
          () => notifier.value.stage == PayloadStage.tierTwoReady,
          reason: 're-entry to converge again (seen: $stages)',
        );
        expect(stages.length, greaterThan(ticksBeforeReturn),
            reason: 'the notifier must tick on re-entry');
        expect(controller.isFullSizeReady(target.id), isTrue);
      },
    );
  });
}
