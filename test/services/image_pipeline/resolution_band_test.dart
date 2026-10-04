// WP4.2 / spec S3.2 -- distance-driven resolution degradation.
//
// The spec, verbatim (S3.2; band since widened to -1..+2 and the
// window-resolution tier removed by the 2026-10-04 ruling, memory.md AD-072):
// "resolution follows distance from the selected item --
// full-size pixels only for selected +/-1; window-resolution for the near band;
// compressed payload bytes (JPEG) only beyond. Degradation, not eviction: far
// items downgrade from decoded pixels to their existing compressed payload;
// re-promotion decodes the JPEG payload (tens of ms), never re-decodes RAW off
// disk, so perceived preload speed is preserved."
//
// What this file pins, and what it deliberately does NOT:
//   * the band TABLE (which form an item at distance d is held in);
//   * that degraded items keep their RETAINED PAYLOAD -- degradation is not
//     eviction;
//   * that re-promotion into the full-resolution band rebuilds from that
//     retained payload and buys no new disk read and no RAW decode;
//   * that narrowing the resolution band did NOT move the payload cache's
//     eviction ranking, which is retention policy and out of scope for S3.2.
// It does not assert anything about WHICH items are retained or in what ORDER
// they are evicted -- that is retention_test.dart's subject and it is unchanged
// by this work package.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/cache_budget.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/prefetch_scheduler.dart';
import 'package:halcyon_flutter/services/image_pipeline/retention_policy.dart';

import '../../support/preload_fixtures.dart';
import '../../support/event_loop.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('resolution band table', () {
    // TC-1150 (revised 2026-10-04, AD-072: band -1..+2)
    test(
      'TC-1150 full-size pixels are kept only for selected -1..+2',
      () {
        expect(kFullResolutionBandBefore, 1);
        expect(kFullResolutionBandAfter, 2);
        // The budget's slot count is DERIVED from the band, never restated.
        expect(kFullResolutionBandSlotCount, 4);
      },
    );

    // TC-1152
    test(
      'TC-1152 the eviction band is NOT the resolution band: narrowing the '
      'full-resolution band left eviction ranking where it was',
      () {
        // The boundary test S3.2 is held to: a resolution-tiering change may
        // alter the FORM an item is held in, never WHICH items are retained or
        // the ORDER they are evicted in. The payload cache's eviction ranking
        // is computed against these two constants, which are frozen at the
        // pre-WP4.2 forward-biased -1..+3 reach. If a later change makes the
        // eviction ranking follow the full-resolution band, that is an
        // eviction-policy change and this test is the one that must be
        // consciously rewritten rather than quietly updated.
        expect(kEvictionBandBefore, 1);
        expect(kEvictionBandAfter, 3);
        expect(
          kEvictionBandAfter,
          isNot(kFullResolutionBandAfter),
          reason: 'the two bands are two questions and must not be one '
              'constant',
        );
      },
    );
  });

  group('degradation and re-promotion', () {
    setUp(clearImageCacheSetUp);

    /// A controller over encoded (cheap) sources that counts, per photo id,
    /// how many times the LOADER was asked for bytes -- i.e. how many disk
    /// reads the pipeline bought. The RAW decoder fails the test outright: the
    /// spec's re-promotion claim is that it is never reached.
    ({ImagePreloadController controller, Map<String, int> loads}) build() {
      final loads = <String, int>{};
      final controller = ImagePreloadController(
        scheduleFrameCallback: immediateFrameCallback,
        navigationDebounce: Duration.zero,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async {
          if (purpose == ImageRequestPurpose.preview) {
            loads[path] = (loads[path] ?? 0) + 1;
          }
          return NativeImageBytes(Uint8List.fromList(tinyPngBytes));
        },
        dngDecoder: (path) async =>
            fail('re-promotion must never RAW-decode off disk'),
      );
      controller.updateTargetSize(10, 10);
      return (controller: controller, loads: loads);
    }

    // TC-1153
    testWidgets(
      'TC-1153 an item beyond the full-resolution band is DEGRADED, not '
      'evicted: no full-size entry, payload still retained',
      (tester) async {
        await tester.runAsync(() async {
          final h = build();
          addTearDown(h.controller.dispose);
          final photos = paddedItems(14);
          const selected = 5;

          await h.controller.preloadImages(
            items: photos,
            selectedItemId: photos[selected].id,
            notifyLoaded: () {},
          );
          await until(
            () => [
              for (var d = -kFullResolutionBandBefore;
                  d <= kFullResolutionBandAfter;
                  d++)
                photos[selected + d].id,
            ].every(h.controller.isFullSizeReady),
            reason: 'the -1..+2 full-resolution band to settle',
          );

          for (final d in [-2, 3, 4]) {
            final id = photos[selected + d].id;
            expect(
              h.controller.isFullSizeReady(id),
              isFalse,
              reason: 'distance $d holds no full-resolution pixels (S3.2)',
            );
            // The whole point of "degradation, not eviction": the compressed
            // payload is STILL THERE. A test that only asserted the absence of
            // the full-size entry would pass just as well against an
            // implementation that dropped the payload, which would be an
            // out-of-scope eviction-policy change.
            expect(
              h.controller.payloadFor(id),
              isNotNull,
              reason: 'distance $d must keep its retained compressed payload',
            );
          }
        });
      },
    );

    // TC-1155
    testWidgets(
      'TC-1155 the payload budget override applies and restores, and the '
      'derived budget is unmoved by it',
      (tester) async {
        await tester.runAsync(() async {
          final h = build();
          addTearDown(h.controller.dispose);
          final derived = h.controller.derivedPayloadByteBudget;
          expect(h.controller.debugPayloadCacheByteBudget, derived);

          h.controller.setPayloadByteBudgetOverride(derived ~/ 2);
          expect(h.controller.debugPayloadCacheByteBudget, derived ~/ 2);
          // The point of a separate read-only getter: the responder halves the
          // DERIVED number, so it must not move while an override is in force,
          // or repeated pressure signals would halve an already-halved budget.
          expect(h.controller.derivedPayloadByteBudget, derived);

          h.controller.setPayloadByteBudgetOverride(null);
          expect(h.controller.debugPayloadCacheByteBudget, derived);
          expect(h.controller.derivedPayloadByteBudget, derived);
        });
      },
    );

    // TC-1156
    testWidgets(
      'TC-1156 restoring the override returns the CURRENT derived budget, not '
      'the one that was in force when the override was installed',
      (tester) async {
        await tester.runAsync(() async {
          final h = build();
          addTearDown(h.controller.dispose);
          final floor = h.controller.derivedPayloadByteBudget;

          h.controller.setPayloadByteBudgetOverride(floor ~/ 2);
          // The retention tier changes mid-episode. The override outranks it --
          // the in-force budget must NOT jump back up -- but the derived value
          // it will restore to has moved.
          final generous = retentionPolicyForTier(RetentionTier.generous);
          h.controller.setRetention(generous);
          expect(h.controller.debugPayloadCacheByteBudget, floor ~/ 2);
          expect(
            h.controller.derivedPayloadByteBudget,
            generous.payloadByteBudget,
          );

          h.controller.setPayloadByteBudgetOverride(null);
          expect(
            h.controller.debugPayloadCacheByteBudget,
            generous.payloadByteBudget,
            reason: 'null restores what the pipeline derives NOW',
          );
        });
      },
    );

    // TC-1157
    testWidgets(
      'TC-1157 dropBeyondBandTierTwoPixels evicts exactly the beyond-band '
      'tier-2 entries and drops no payload',
      (tester) async {
        await tester.runAsync(() async {
          final h = build();
          addTearDown(h.controller.dispose);
          final photos = paddedItems(14);
          const selected = 5;

          await h.controller.preloadImages(
            items: photos,
            selectedItemId: photos[selected].id,
            notifyLoaded: () {},
          );
          final band = <String>{
            for (var d = -kFullResolutionBandBefore;
                d <= kFullResolutionBandAfter;
                d++)
              photos[selected + d].id,
          };
          await until(
            () => band.every(h.controller.isFullSizeReady),
            reason: 'the -1..+2 full-resolution band to settle',
          );
          // A settled window has no beyond-band entries left, so the call is a
          // no-op here -- asserted explicitly rather than assumed: a drop that
          // took the IN-band entries too would black out the item the user is
          // looking at under pressure, and that is the failure mode worth
          // pinning.
          h.controller.dropBeyondBandTierTwoPixels();
          expect(
            h.controller.debugTierTwoKeyIds,
            band,
            reason: 'a settled band must survive the drop untouched',
          );

          // Now move the window, then manufacture the state the primitive exists
          // for: full-resolution entries resident for positions outside the band.
          //
          // Since l1l2 spec R1 (L2) a move evicts the REGISTERED band leavers at
          // the band-diff instant, so a move no longer strands anything (this
          // test used to rely on a +2 move doing so). The stranded entries are
          // therefore published by hand through the controller's test seam, the
          // way only a late-registering publish could leave them in production.
          //
          // Deliberately NOT awaited, and advanced by a MICROTASK rather than a
          // zero-duration delay: the tier-2 sweep is a Timer and would otherwise
          // fire first, turning the assertions below into a test of the sweep
          // instead of a test of this primitive.
          const moved = 7;
          unawaited(
            h.controller.preloadImages(
              items: photos,
              selectedItemId: photos[moved].id,
              notifyLoaded: () {},
            ),
          );
          await Future<void>.microtask(() {});
          for (final id in [photos[4].id, photos[5].id]) {
            h.controller.debugPublishTierTwoForTest(
              id,
              freshEncodedPayload(),
              await tinyImage(),
            );
          }
          final movedBand = <String>{
            for (var d = -kFullResolutionBandBefore;
                d <= kFullResolutionBandAfter;
                d++)
              photos[moved + d].id,
          };
          final strandedBefore = h.controller.debugTierTwoKeyIds.where(
            (id) => !movedBand.contains(id),
          );
          expect(
            strandedBefore,
            isNotEmpty,
            reason: 'precondition: the move stranded beyond-band tier-2 '
                'entries for the drop to collect -- without this the assertion '
                'below could not fail',
          );
          // Captured immediately before the drop and compared immediately
          // after, with no navigation in between: navigation legitimately
          // changes which payloads are retained, so a snapshot taken across one
          // would be measuring retention, not the drop.
          final retainedBefore = <String, bool>{
            for (final item in photos)
              item.id: h.controller.payloadFor(item.id) != null,
          };

          h.controller.dropBeyondBandTierTwoPixels();

          for (final id in h.controller.debugTierTwoKeyIds) {
            expect(
              movedBand.contains(id),
              isTrue,
              reason: '$id is outside the band and must hold no tier-2 pixels',
            );
          }

          // Degradation, not eviction: not one payload was dropped.
          for (final item in photos) {
            expect(
              h.controller.payloadFor(item.id) != null,
              retainedBefore[item.id],
              reason: 'the retained payload for ${item.id} must be untouched',
            );
          }
        });
      },
    );

    // TC-1154
    testWidgets(
      'TC-1154 re-promotion rebuilds from the retained payload: no second disk '
      'read, no RAW decode',
      (tester) async {
        await tester.runAsync(() async {
          final h = build();
          addTearDown(h.controller.dispose);
          final photos = paddedItems(14);
          const selected = 5;
          const degraded = selected + 3; // outside -1..+2, inside retention

          await h.controller.preloadImages(
            items: photos,
            selectedItemId: photos[selected].id,
            notifyLoaded: () {},
          );
          await until(
            () => h.controller.payloadFor(photos[degraded].id) != null,
            reason: 'the degraded slot to acquire its retained payload',
          );
          expect(
            h.controller.isFullSizeReady(photos[degraded].id),
            isFalse,
            reason: 'precondition: it starts degraded',
          );
          final loadsBefore = h.loads[photos[degraded].files.first.path] ?? 0;
          expect(
            loadsBefore,
            greaterThan(0),
            reason: 'precondition: its payload was read from disk exactly once',
          );

          // Navigate so the degraded slot becomes the selection: it enters the
          // full-resolution band and must be re-promoted.
          await h.controller.preloadImages(
            items: photos,
            selectedItemId: photos[degraded].id,
            notifyLoaded: () {},
          );
          await until(
            () => h.controller.isFullSizeReady(photos[degraded].id),
            reason: 're-promotion into the full-resolution band',
          );

          expect(
            h.loads[photos[degraded].files.first.path],
            loadsBefore,
            reason: 're-promotion must decode the RETAINED payload, not buy a '
                'second read of the file',
          );
          // The RAW decoder is pinned by `fail(...)` in the fixture above: if
          // re-promotion had gone down the RAW route, this test would already
          // have failed inside the loader.
        });
      },
    );
  });

  // The 'tier-1 precache is the +/-1 band only' group (TC-1223, TC-1224,
  // TC-1225, TC-1242, TC-1247) is DELETED with the viewport-resolution tier it
  // pinned (2026-10-04 ruling, memory.md AD-072). The band's decoded set is
  // now pinned by TC-1470 below; payload-kept-outside-the-band by TC-1153.
  group('full-resolution band -1..+2 (AD-072)', () {
    setUp(clearImageCacheSetUp);

    // TC-1470
    testWidgets(
      'TC-1470 the full-size decoded set is EXACTLY {cur-1, cur, cur+1, '
      'cur+2}; moving the selection evicts the leavers and decodes the '
      'entrants',
      (tester) async {
        await tester.runAsync(() async {
          final controller = ImagePreloadController(
            scheduleFrameCallback: immediateFrameCallback,
            navigationDebounce: Duration.zero,
            imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
                NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
            dngDecoder: (path) async => fail('cheap rung must not RAW-decode'),
          );
          addTearDown(controller.dispose);
          controller.updateTargetSize(10, 10);
          final photos = paddedItems(20);
          Set<String> ids(Iterable<int> indices) =>
              {for (final i in indices) photos[i].id};
          bool settledOn(Set<String> band) =>
              band.every(controller.isFullSizeReady) &&
              controller.debugTierTwoKeyIds.length == band.length &&
              controller.debugTierTwoKeyIds.containsAll(band);

          await controller.preloadImages(
            items: photos,
            selectedItemId: photos[5].id,
            notifyLoaded: () {},
          );
          final first = ids([4, 5, 6, 7]);
          await until(() => settledOn(first), reason: 'band 4..7 to settle');
          // Retention reaches -3..+5, so +3 holds a payload but no pixels:
          // the boundary is the band, not what happens to be retained.
          await until(() => controller.payloadFor(photos[8].id) != null);
          expect(controller.debugTierTwoKeyIds, first);
          expect(controller.isFullSizeReady(photos[3].id), isFalse);
          expect(controller.isFullSizeReady(photos[8].id), isFalse);

          await controller.preloadImages(
            items: photos,
            selectedItemId: photos[9].id,
            notifyLoaded: () {},
          );
          final second = ids([8, 9, 10, 11]);
          await until(() => settledOn(second), reason: 'band 8..11 to settle');
          expect(
            controller.debugTierTwoKeyIds,
            second,
            reason: 'every id of the old band (4..7) left it and must have '
                'been evicted',
          );
        });
      },
    );
  });
}
