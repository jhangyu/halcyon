// Phase 4 — the unified lane priority function
// (async-pipeline-refactor-plan.md §3 Phase 4, with contract override S4).
//
// These are PROPERTY-style tests over the full legal distance range, not three
// hand-picked cases: the defect class this file exists to prevent (a
// within-group distance large enough to punch through the next band's base) is
// invisible to any fixed set of small examples, which is exactly how it
// survived in the pre-Phase-4 code.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/lane_priority.dart';

import '../../support/preload_fixtures.dart';

Future<NativeImageResult> _rawLoader(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

DecodedRgba _tiny() {
  final rgba = Uint8List(8 * 8 * 4);
  for (var i = 3; i < rgba.length; i += 4) {
    rgba[i] = 0xFF;
  }
  return DecodedRgba(rgba: rgba, width: 8, height: 8);
}

void main() {
  group('TC-978 band order', () {
    test('every band is strictly ordered, at every legal distance', () {
      // The whole cross product: for each ordered pair of bands and each legal
      // distance in BOTH, the lower band must win. This is the assertion that
      // makes the base gap load-bearing rather than decorative.
      const distances = <int>[
        0,
        1,
        2,
        10,
        99,
        100,
        500,
        998,
        kMaxWithinGroupDistance,
        // Deliberately beyond the legal range: the clamp must keep these in
        // their own band too (see TC-979).
        kLaneBandGap,
        kLaneBandGap + 1,
        100000,
      ];
      final groups = LaneGroup.values;
      for (var i = 0; i < groups.length; i++) {
        for (var j = i + 1; j < groups.length; j++) {
          for (final di in distances) {
            for (final dj in distances) {
              expect(
                lanePriorityFor(group: groups[i], withinGroupDistance: di),
                lessThan(
                  lanePriorityFor(group: groups[j], withinGroupDistance: dj),
                ),
                reason:
                    '${groups[i].name}@$di must outrank ${groups[j].name}@$dj',
              );
            }
          }
        }
      }
    });

    test(
      'the ruled band order is exactly P1 < P2 < full-res < P3 < P4 (S4)',
      () {
        // Named explicitly because this ORDER is a user ruling, not an
        // implementation detail: the refactor plan proposed moving full-res
        // above all sidebar work and the contract's override S4 cancelled it.
        // If a future refactor re-orders the enum, this fails loudly and the
        // person doing it has to go and get a user decision.
        expect(LaneGroup.values, [
          LaneGroup.selected,
          LaneGroup.navigationWindow,
          LaneGroup.fullRes,
          LaneGroup.sidebarVisible,
          LaneGroup.sidebarMargin,
        ]);
        expect(laneBaseFor(LaneGroup.selected), 0);
        expect(laneBaseFor(LaneGroup.navigationWindow), 1000);
        expect(laneBaseFor(LaneGroup.fullRes), 2000);
        expect(laneBaseFor(LaneGroup.sidebarVisible), 3000);
        expect(laneBaseFor(LaneGroup.sidebarMargin), 4000);
      },
    );
  });

  group('TC-979 within-group distance', () {
    test('is monotone up to the clamp and never leaves its band', () {
      for (final group in LaneGroup.values) {
        final base = laneBaseFor(group);
        var previous = lanePriorityFor(group: group, withinGroupDistance: 0);
        expect(previous, base);
        for (var d = 1; d <= kMaxWithinGroupDistance; d++) {
          final p = lanePriorityFor(group: group, withinGroupDistance: d);
          expect(p, greaterThan(previous), reason: '${group.name}@$d');
          expect(
            p,
            lessThan(base + kLaneBandGap),
            reason: '${group.name}@$d escaped its band',
          );
          previous = p;
        }
      }
    });

    test('clamps beyond the legal range instead of punching through', () {
      // The plan allowed "widen the gap" OR "clamp"; this implementation does
      // both, because the gap alone is an assumption about data (nobody ever
      // has 1000 sidebar rows visible) while the clamp is a property of the
      // code. A tall viewport must degrade to a TIE, never to a band jump.
      for (final group in LaneGroup.values) {
        final atClamp = lanePriorityFor(
          group: group,
          withinGroupDistance: kMaxWithinGroupDistance,
        );
        for (final d in [kLaneBandGap, kLaneBandGap + 7, 1 << 20]) {
          expect(
            lanePriorityFor(group: group, withinGroupDistance: d),
            atClamp,
            reason: '${group.name}@$d must clamp, not overflow into the next '
                'band',
          );
        }
      }
    });
  });

  group('TC-980 navigation classifier', () {
    test('the selected slot is P1 and everything else is P2', () {
      expect(navigationPriorityFor(0), laneBaseFor(LaneGroup.selected));
      for (final d in [1, -1, 2, -2, 3, -3, 5, -3, 11, -11]) {
        expect(
          navigationPriorityFor(d),
          greaterThanOrEqualTo(laneBaseFor(LaneGroup.navigationWindow)),
          reason: 'distance $d is window work, not the selection',
        );
        expect(
          navigationPriorityFor(d),
          lessThan(laneBaseFor(LaneGroup.fullRes)),
          reason: 'distance $d must not reach the full-res band',
        );
      }
    });

    test(
      'keeps the user-ruled near-to-far order 0, +1, -1, +2, -2, +3, -3, +4, +5',
      () {
        // The 2026-08-26 ruling, asserted as an ORDER over the whole retention
        // window rather than as a formula, so a change to laneRankForDistance
        // that preserved its shape but not its ruling would still fail.
        const ruledOrder = [0, 1, -1, 2, -2, 3, -3, 4, 5];
        final priorities = [
          for (final d in ruledOrder) navigationPriorityFor(d),
        ];
        for (var i = 1; i < priorities.length; i++) {
          expect(
            priorities[i],
            greaterThan(priorities[i - 1]),
            reason:
                'slot ${ruledOrder[i]} must rank after slot ${ruledOrder[i - 1]}',
          );
        }
      },
    );

    test('a forward slot outranks the mirrored backward slot', () {
      for (var d = 1; d <= 11; d++) {
        expect(
          navigationPriorityFor(d),
          lessThan(navigationPriorityFor(-d)),
          reason: 'browsing is predominantly forward (+$d before -$d)',
        );
      }
    });
  });

  group('TC-981 sidebar classifier', () {
    test('every visible row outranks every margin row (D1 AC1 property)', () {
      // D1's own regression tests (TC-963/TC-964) prove this through the
      // controller; this proves it over a range of viewport geometries the
      // controller tests do not enumerate, including the tall-viewport case
      // that defeated the pre-D1 formula and would defeat a gap-only fix.
      for (final span in [1, 2, 5, 41, 200, 1500]) {
        const safeStart = 100;
        final safeEnd = safeStart + span - 1;
        final visible = [
          for (var i = safeStart; i <= safeEnd; i++)
            sidebarPriorityFor(index: i, safeStart: safeStart, safeEnd: safeEnd),
        ];
        final margin = [
          for (final i in [
            safeStart - 1,
            safeStart - 20,
            safeEnd + 1,
            safeEnd + 20,
          ])
            sidebarPriorityFor(index: i, safeStart: safeStart, safeEnd: safeEnd),
        ];
        expect(
          visible.reduce((a, b) => a > b ? a : b),
          lessThan(margin.reduce((a, b) => a < b ? a : b)),
          reason:
              'span $span: the worst visible row must still outrank the best '
              'margin row',
        );
      }
    });

    test('a visible row ranks by distance from the centre', () {
      const safeStart = 10;
      const safeEnd = 30; // centre 20
      final centre = sidebarPriorityFor(
        index: 20,
        safeStart: safeStart,
        safeEnd: safeEnd,
      );
      expect(centre, laneBaseFor(LaneGroup.sidebarVisible));
      for (var d = 1; d <= 10; d++) {
        expect(
          sidebarPriorityFor(
            index: 20 + d,
            safeStart: safeStart,
            safeEnd: safeEnd,
          ),
          centre + d,
        );
        expect(
          sidebarPriorityFor(
            index: 20 - d,
            safeStart: safeStart,
            safeEnd: safeEnd,
          ),
          centre + d,
        );
      }
    });

    test('a margin row ranks by distance from the nearest edge', () {
      const safeStart = 10;
      const safeEnd = 30;
      final base = laneBaseFor(LaneGroup.sidebarMargin);
      for (var d = 1; d <= 20; d++) {
        expect(
          sidebarPriorityFor(
            index: safeStart - d,
            safeStart: safeStart,
            safeEnd: safeEnd,
          ),
          base + d,
        );
        expect(
          sidebarPriorityFor(
            index: safeEnd + d,
            safeStart: safeStart,
            safeEnd: safeEnd,
          ),
          base + d,
        );
      }
    });

    test(
      'a 4000-row viewport cannot punch a visible row out of the P3 band',
      () {
        // The concrete form of the defect the clamp exists for. Before the
        // clamp, a row 1200 slots from the centre would have produced
        // 3000 + 1200 = 4200, i.e. a P3 row ranking behind P4 margin work --
        // and with a smaller gap it would have crossed into full-res.
        // Span chosen so the worst centre distance (2000) EXCEEDS the band
        // gap: a 1500-row span only reaches 750 and would pass even with the
        // clamp removed, which is exactly the kind of test that looks like a
        // guard and is not one (observed: the earlier 1500-row version stayed
        // green under the clamp-removal mutation).
        const safeStart = 0;
        const safeEnd = 3999;
        for (final index in [0, 1, 1000, 2500, 3999]) {
          final p = sidebarPriorityFor(
            index: index,
            safeStart: safeStart,
            safeEnd: safeEnd,
          );
          expect(p, greaterThanOrEqualTo(laneBaseFor(LaneGroup.sidebarVisible)));
          expect(p, lessThan(laneBaseFor(LaneGroup.sidebarMargin)));
        }
      },
    );
  });

  group('TC-982 isSidebarPriority (G-027 predicate)', () {
    test('is true for sidebar bands and false for everything below', () {
      expect(isSidebarPriority(navigationPriorityFor(0)), isFalse);
      for (final d in [1, -1, 5, -3, 11]) {
        expect(isSidebarPriority(navigationPriorityFor(d)), isFalse);
      }
      for (final d in [0, 1, -1, 5]) {
        expect(
          isSidebarPriority(fullResPriorityFor(d)),
          isFalse,
          reason:
              'full-res is not sidebar work: a pending full-res entry must '
              'never be treated as re-rankable by a sidebar sweep',
        );
      }
      for (final index in [10, 20, 30, 5, 45]) {
        expect(
          isSidebarPriority(
            sidebarPriorityFor(index: index, safeStart: 10, safeEnd: 30),
          ),
          isTrue,
        );
      }
    });

    test('the boundary is exactly the sidebar-visible base', () {
      expect(
        isSidebarPriority(laneBaseFor(LaneGroup.sidebarVisible) - 1),
        isFalse,
      );
      expect(isSidebarPriority(laneBaseFor(LaneGroup.sidebarVisible)), isTrue);
    });
  });

  // The G-027 direction assertions (plan §3 Phase 4 acceptance bullet 3, risk
  // R5). These run through the real controller and lane rather than the pure
  // function, because the defect they guard is a WIRING defect: the pure
  // function can be perfectly ordered while the sidebar re-enqueues a key that
  // navigation is waiting on and demotes it.
  group('TC-983 G-027 direction through the real lane', () {
    test(
      'a navigation enqueue RAISES the priority of a key the sidebar queued, '
      'and a later sidebar sweep never demotes it back',
      () async {
        final gate = Completer<void>();
        final controller = ImagePreloadController(
          imageLoader: _rawLoader,
          dngDecoder: (path) async {
            // Gated so every enqueued key stays PENDING and its priority is
            // observable; the lane is width 1 so one key occupies the slot.
            await gate.future;
            return _tiny();
          },
          payloadEncoder: null,
          decodeLaneWidth: 1,
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(800, 600);
        final items = photoItems(400, extension: 'arw');

        // 1. The SIDEBAR queues p200 as a margin row (visible range is far
        //    away), i.e. in the worst band there is.
        await controller.preloadThumbnails(
          items: items,
          startIdx: 180,
          endIdx: 195,
          notifyLoaded: () {},
        );
        await until(
          () => controller.debugLanePendingPriorityFor('p200') != null,
          reason: 'the sidebar sweep to queue p200',
        );
        final sidebarPriority = controller.debugLanePendingPriorityFor('p200')!;
        expect(
          isSidebarPriority(sidebarPriority),
          isTrue,
          reason: 'precondition: p200 is queued as sidebar work',
        );

        // 2. NAVIGATION selects p200. The same lane key must be RE-RANKED up
        //    into the navigation bands -- this is the direction G-027 is
        //    about: the user is now looking at it.
        await controller.preloadImages(
          items: items,
          selectedItemId: 'p200',
          notifyLoaded: () {},
        );
        await until(
          () =>
              controller.debugLanePendingPriorityFor('p200') != null &&
              !isSidebarPriority(controller.debugLanePendingPriorityFor('p200')!),
          reason: 'the navigation enqueue to raise p200 out of the sidebar band',
        );
        final navigationPriority =
            controller.debugLanePendingPriorityFor('p200')!;
        expect(
          navigationPriority,
          lessThan(sidebarPriority),
          reason: 'a navigation enqueue must RAISE (numerically lower) the '
              'priority of a key the sidebar had queued',
        );

        // 3. THE SILENT DIRECTION. A later sidebar sweep that still wants
        //    p200 must NOT push it back down: re-ranking a navigation-pending
        //    key at a sidebar priority is exactly G-027 (memory.md:1051), and
        //    it is invisible without this assertion because nothing fails --
        //    the decode simply happens much later than the user expects.
        // SETTLE FIRST. Phase 3 made preloadImages asynchronous: its per-slot
        // probe chains keep resolving and RE-enqueueing after it returns. If
        // the sweep below runs while those are still in flight, a demotion is
        // transient -- a later navigation re-enqueue repairs it before any
        // end-state read, and this arm becomes an assertion that cannot fail
        // (observed: it stayed green under a mutation that deleted the guard).
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(
          controller.debugLanePendingPriorityFor('p200'),
          navigationPriority,
          reason: 'precondition: navigation work has settled',
        );

        // A DIFFERENT range that still keeps p200 in the margin. Repeating
        // the first range would be a no-op: the sweep short-circuits when the
        // visible range is unchanged (sidebar_thumbnail_controller.dart:415),
        // so an identical second sweep produces no re-enqueue at all and this
        // arm would pass without ever exercising the guard. Observed: with
        // the identical range, this test stayed GREEN under a mutation that
        // removed the guard entirely.
        await controller.preloadThumbnails(
          items: items,
          startIdx: 179,
          endIdx: 194,
          notifyLoaded: () {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 250));
        final afterSweep = controller.debugLanePendingPriorityFor('p200');
        expect(
          afterSweep,
          isNotNull,
          reason: 'p200 is still gated, so it must still be pending',
        );
        expect(
          isSidebarPriority(afterSweep!),
          isFalse,
          reason: 'G-027: the sidebar demoted the item navigation is waiting '
              'on, from $navigationPriority back to $afterSweep',
        );
        expect(afterSweep, lessThanOrEqualTo(navigationPriority));

        gate.complete();
      },
    );
  });

  // ROUND B REVIEW BLOCKER (fix cycle 1). The Phase 4 rebase moved three
  // producers onto the band table and missed a FOURTH: TierTwoScheduler's
  // catch-up sweep also enqueues the `(payload, id)` key, and it was still
  // handing the lane a bare `laneRankFor(distance)` (0..N).
  //
  // That is not a cosmetic inconsistency. DecodeLane RE-RANKS a pending key on
  // re-enqueue, so the sweep pulled the slots it touches (the tier-2 window,
  // -1..+3) down to 0..N while the plain navigation slots stayed at 1000+ --
  // silently inverting the 2026-08-26 start-order ruling. The suite was green
  // over it because no test mixed the two producers. This one does.
  group('TC-984 merged producer order (tier-2 catch-up + navigation)', () {
    test(
      'the tier-2 catch-up sweep does not demote navigation slots below it',
      () async {
        final gate = Completer<void>();
        final controller = ImagePreloadController(
          imageLoader: _rawLoader,
          dngDecoder: (path) async {
            // Gated forever: every window slot stays PENDING, so the merged
            // pending order is fully observable.
            await gate.future;
            return _tiny();
          },
          payloadEncoder: null,
          decodeLaneWidth: 1,
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(800, 600);
        final items = photoItems(40, extension: 'arw');

        await controller.preloadImages(
          items: items,
          selectedItemId: items[10].id,
          notifyLoaded: () {},
        );

        // Past the tier-2 debounce (250ms), so the catch-up sweep has run and
        // re-enqueued the -1..+3 slots it found without payloads. Without the
        // fix, THIS is the step that corrupts the order.
        await until(
          () => controller.debugLanePendingPriorityFor(items[13].id) != null,
          reason: 'the +3 slot to be pending',
        );
        await Future<void>.delayed(const Duration(milliseconds: 400));

        // ANTI-VACUITY (parking-lot item 2, async-pipeline-campaign-handover
        // §9): the merged-order assertions below would pass identically if
        // the tier-2 catch-up sweep never ran at all -- navigation alone
        // produces the ruled order for slots it already owns. This proves the
        // sweep actually re-enqueued at least one payload key, so the test's
        // bite depends on the mechanism its name claims, not solely on the
        // external red-proof (docs/logs/2026-09-06/parklot-redproof.txt).
        expect(
          controller.debugCatchUpEnqueueCount,
          greaterThan(0),
          reason:
              'the tier-2 catch-up sweep must have re-enqueued at least one '
              'slot for this assertion to test anything beyond navigation '
              'alone',
        );

        // The reviewer's counterexample, verbatim: -2 is ruled to start before
        // +3 (order 0, +1, -1, +2, -2, +3, ...). Asserted on PRIORITIES, never
        // on enqueue order.
        final minusTwo = controller.debugLanePendingPriorityFor(items[8].id);
        final plusThree = controller.debugLanePendingPriorityFor(items[13].id);
        expect(minusTwo, isNotNull, reason: 'the -2 slot must still be pending');
        expect(plusThree, isNotNull, reason: 'the +3 slot must still be pending');
        expect(
          minusTwo!,
          lessThan(plusThree!),
          reason:
              'the tier-2 catch-up sweep re-ranked +3 ($plusThree) below the '
              'untouched -2 slot ($minusTwo), inverting the 2026-08-26 '
              'start-order ruling',
        );

        // The whole ruled walk, not just the one pair: every slot the sweep
        // touched must still sit in the navigation bands alongside the ones it
        // did not touch, so the merged order is one consistent sequence.
        const ruledOrder = [0, 1, -1, 2, -2, 3];
        var previous = -1;
        for (final d in ruledOrder) {
          final p = controller.debugLanePendingPriorityFor(items[10 + d].id);
          expect(p, isNotNull, reason: 'slot $d must be pending');
          expect(
            p!,
            greaterThan(previous),
            reason: 'slot $d broke the merged ruled order',
          );
          previous = p;
        }

        gate.complete();
      },
    );
  });
}
