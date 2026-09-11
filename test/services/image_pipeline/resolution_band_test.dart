// WP4.2 / spec S3.2 -- distance-driven resolution degradation.
//
// The spec, verbatim: "resolution follows distance from the selected item --
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
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/prefetch_scheduler.dart';
import 'package:halcyon_flutter/services/image_pipeline/retention_policy.dart';

import '../../support/preload_fixtures.dart';

/// Drains the publish pacer synchronously: without a frame hook a paced
/// publication waits for a real frame that a headless test never produces.
void _microtaskFrame(void Function() callback) => callback();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('resolution band table', () {
    // TC-1150
    test(
      'TC-1150 full-size pixels are kept only for selected +/-1',
      () {
        for (final distance in [-1, 0, 1]) {
          expect(
            isFullResolutionDistance(distance),
            isTrue,
            reason: 'distance $distance is inside the spec\'s selected +/-1',
          );
        }
        // Both edges must bite, or the assertion would pass against an
        // unbounded band. +2 is the slot the pre-WP4.2 forward bias
        // (-1..+3) used to hold at full resolution and no longer does.
        for (final distance in [-2, 2, 3]) {
          expect(
            isFullResolutionDistance(distance),
            isFalse,
            reason: 'distance $distance is outside the selected +/-1 band',
          );
        }
        expect(kFullResolutionBandRadius, 1);
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
        // eviction ranking follow kFullResolutionBandRadius, that is an
        // eviction-policy change and this test is the one that must be
        // consciously rewritten rather than quietly updated.
        expect(kEvictionBandBefore, 1);
        expect(kEvictionBandAfter, 3);
        expect(
          kEvictionBandAfter,
          isNot(kFullResolutionBandRadius),
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
        scheduleFrameCallback: _microtaskFrame,
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
              for (var d = -kFullResolutionBandRadius;
                  d <= kFullResolutionBandRadius;
                  d++)
                photos[selected + d].id,
            ].every(h.controller.isFullSizeReady),
            reason: 'the +/-1 full-resolution band to settle',
          );

          for (final d in [2, 3, 4]) {
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
            for (var d = -kFullResolutionBandRadius;
                d <= kFullResolutionBandRadius;
                d++)
              photos[selected + d].id,
          };
          await until(
            () => band.every(h.controller.isFullSizeReady),
            reason: 'the +/-1 full-resolution band to settle',
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

          // Now move the window and drop IMMEDIATELY, before the debounce can
          // sweep. This is the state the primitive exists for: full-resolution
          // entries still resident for a position the user has left.
          //
          // A SHORT move (+2), not a long one. A long jump evicts the old
          // slots' payloads outright, and the existing `_onPayloadEvicted` hook
          // takes their tier-2 entries with them -- leaving nothing stranded
          // and nothing for this primitive to do. Two steps forward is the case
          // that actually strands pixels: -1 and -2 fall out of the +/-1 band
          // while staying well inside the -3..+5 retention window, so their
          // payloads (and therefore their full-resolution entries) survive
          // until the debounced sweep gets round to them.
          const moved = 7;
          // Deliberately NOT awaited, and advanced by a MICROTASK rather than a
          // zero-duration delay. The navigation pass runs on a microtask and
          // calls `updateWindow` immediately, but the tier-2 sweep that would
          // evict the stranded entries is a Timer -- and timers run after the
          // microtask queue drains. Awaiting the future (or a Duration.zero
          // delay) lets that sweep fire first, leaving nothing stranded and
          // turning the assertions below into a test of the sweep instead of a
          // test of this primitive.
          unawaited(
            h.controller.preloadImages(
              items: photos,
              selectedItemId: photos[moved].id,
              notifyLoaded: () {},
            ),
          );
          await Future<void>.microtask(() {});
          final movedBand = <String>{
            for (var d = -kFullResolutionBandRadius;
                d <= kFullResolutionBandRadius;
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
          const degraded = selected + 3; // outside +/-1, inside retention

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

  group('tier-1 precache is the +/-1 band only (spec v2 §3.4, R-B)', () {
    setUp(clearImageCacheSetUp);

    /// A cheap-source controller: every item gets an EncodedPayload, and
    /// the RAW decoder fails the test outright so nothing here can be
    /// explained by a re-decode.
    ///
    /// [navigationDebounce] gates only [TierTwoScheduler] (see
    /// `image_preload_controller.dart:1102`, `_navigationDebounce` has
    /// exactly one read site); tier-1 precache reacts to a landed payload
    /// immediately regardless of this value. Tests that need to observe the
    /// tier-1-before-tier-2-ready window use a non-zero debounce so tier-2
    /// cannot win the race to "settled"; tests that only care about the
    /// final band-minus-ready state use zero.
    ImagePreloadController build({Duration navigationDebounce = Duration.zero}) {
      final controller = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        navigationDebounce: navigationDebounce,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
        dngDecoder: (path) async =>
            fail('the tier-1 precache must never RAW-decode'),
      );
      controller.updateTargetSize(10, 10);
      return controller;
    }

    Set<String> bandIds(List<PhotoItem> photos, int selected) => {
      for (var d = -kFullResolutionBandRadius;
          d <= kFullResolutionBandRadius;
          d++)
        if (selected + d >= 0 && selected + d < photos.length)
          photos[selected + d].id,
    };

    // AC-P2a (docs/logs/2026-09-12/gpu-texture-contract.md): a band id whose
    // tier-2 entry is already ready holds NO tier-1 key --
    // `_evictTierOneDuplicate` reclaims it the instant tier-2 becomes
    // displayable. So the settled tier-1 key set is the band MINUS whichever
    // ids have already reached tier-2, not the whole band unconditionally.

    // `Set`'s default `==` is identity-based, not value-based (it is NOT
    // overridden the way `List`/`Map` literals sometimes assume) -- two
    // distinct `Set<String>` instances with identical elements compare
    // unequal via `==`, so a poll predicate written as `a == b` never
    // succeeds even once the sets genuinely match. Value equality here.
    bool sameIds(Set<String> a, Set<String> b) =>
        a.length == b.length && a.containsAll(b);

    testWidgets(
      'TC-1223 before tier-2 is ready the set of ids holding a tier-1 '
      'ImageCache key EQUALS the +/-1 band id set; once tier-2 is ready '
      'for an id, that id drops out of the tier-1 set (AC-P2a)',
      (tester) async {
        await tester.runAsync(() async {
          // A debounce long enough that tier-1 (undebounced) settles onto
          // the full band well before tier-2 (debounced) becomes ready for
          // anything, so the first assertion below cannot be a race.
          final controller = build(
            navigationDebounce: const Duration(milliseconds: 300),
          );
          addTearDown(controller.dispose);
          final photos = paddedItems(14);
          const selected = 5;

          await controller.preloadImages(
            items: photos,
            selectedItemId: photos[selected].id,
            notifyLoaded: () {},
          );
          await until(
            () => sameIds(controller.debugTierOneKeyIds, bandIds(photos, selected)),
            reason: 'the tier-1 key set to settle onto the +/-1 band while '
                'tier-2 is still debounced',
          );
          expect(
            controller.debugTierOneKeyIds,
            bandIds(photos, selected),
            reason: 'window-resolution retention is abolished (R-B): the '
                '+/-1 band holds decoded tier-1 entries until tier-2 lands',
          );
          for (final id in bandIds(photos, selected)) {
            expect(
              controller.isFullSizeReady(id),
              isFalse,
              reason: 'precondition: tier-2 must not have landed yet, or '
                  'the assertion above proves nothing about ordering',
            );
          }

          // Let the tier-2 debounce elapse and its publish land.
          final centerId = photos[selected].id;
          await until(
            () => controller.isFullSizeReady(centerId),
            reason: 'tier-2 to become ready for the selected id',
          );
          await until(
            () => !controller.debugTierOneKeyIds.contains(centerId),
            reason: 'AC-P2a: the tier-1 duplicate for a tier-2-ready id must '
                'be reclaimed',
          );
          expect(
            controller.debugTierOneKeyIds.contains(centerId),
            isFalse,
            reason: 'the settled tier-1 set is band-minus-ready, not the '
                'whole band unconditionally',
          );
        });
      },
    );

    testWidgets(
      'TC-1224 a slot at +4 keeps its retained payload across the same '
      'pass: this is a FORM change, not an eviction. AC-P2a: once tier-2 '
      'catches up the band ids drop out of the tier-1 set',
      (tester) async {
        await tester.runAsync(() async {
          // Non-zero debounce (option (b), team-lead ruling
          // docs/logs/2026-09-12/): gives a real pre-tier-2 phase in which
          // the original TC-1224 claim (band equality, +4 untouched) is
          // checked exactly as it always was, THEN the debounce is let
          // through and the AC-P2a band-minus-ready claim is checked too.
          final controller = build(
            navigationDebounce: const Duration(milliseconds: 300),
          );
          addTearDown(controller.dispose);
          final photos = paddedItems(14);
          const selected = 5;
          final outerId = photos[selected + 4].id;

          await controller.preloadImages(
            items: photos,
            selectedItemId: photos[selected].id,
            notifyLoaded: () {},
          );
          await until(
            () => controller.payloadFor(outerId) != null,
            reason: 'the +4 slot to acquire its retained payload',
          );
          final retentionBefore = controller.debugRetentionIds.toSet();
          await until(
            () => sameIds(controller.debugTierOneKeyIds, bandIds(photos, selected)),
            reason: 'the tier-1 key set to settle onto the +/-1 band while '
                'tier-2 is still debounced',
          );

          expect(controller.payloadFor(outerId), isNotNull,
              reason: '+4 keeps its payload; only its decoded form goes');
          expect(controller.debugTierOneKeyIds, isNot(contains(outerId)));
          expect(
            controller.debugRetentionIds,
            retentionBefore,
            reason: 'no id was added to or dropped from retention (the '
                'per-hunk boundary test, expressed as an assertion)',
          );

          // AC-P2a phase: let the tier-2 debounce elapse. Every band id
          // holds a tier-1 key IFF its tier-2 is not yet ready -- band-minus-
          // ready, the exact inverse relationship, checked per id (not just
          // "the set shrank").
          final centerId = photos[selected].id;
          await until(
            () => controller.isFullSizeReady(centerId),
            reason: 'tier-2 to become ready for the selected id',
          );
          for (final id in bandIds(photos, selected)) {
            await until(
              () =>
                  controller.debugTierOneKeyIds.contains(id) !=
                  controller.isFullSizeReady(id),
              reason: 'band id $id to settle to band-minus-ready '
                  '(tier-1 key present XOR tier-2 ready)',
            );
          }
          // +4 is untouched by AC-P2a: it was never in the tier-1 band and
          // tier-2's own window is +/-2, so it never reaches tier-2 either.
          expect(controller.debugTierOneKeyIds, isNot(contains(outerId)));
          expect(controller.isFullSizeReady(outerId), isFalse);
        });
      },
    );

    testWidgets(
      'TC-1225 selection at index 0 keeps tier-1 keys for 0 and +1 and '
      'for no others (the band clamps, the sweep must respect the clamp). '
      'AC-P2a: once tier-2 catches up 0 and +1 drop out too',
      (tester) async {
        await tester.runAsync(() async {
          final controller = build(
            navigationDebounce: const Duration(milliseconds: 300),
          );
          addTearDown(controller.dispose);
          final photos = paddedItems(14);
          const selected = 0;

          await controller.preloadImages(
            items: photos,
            selectedItemId: photos[selected].id,
            notifyLoaded: () {},
          );
          await until(
            () => sameIds(controller.debugTierOneKeyIds, bandIds(photos, selected)),
            reason: 'the clamped two-slot band to settle while tier-2 is '
                'still debounced',
          );

          // The SET, not its size: a same-sized set of the WRONG ids would
          // pass a length assertion.
          expect(
            controller.debugTierOneKeyIds,
            {photos[0].id, photos[1].id},
            reason: 'a clamped band is two slots, and the stale sweep must '
                'not evict a key for an id that IS in the clamped band',
          );

          // AC-P2a phase: let the debounce elapse; both clamped-band ids
          // drop out of the tier-1 set once their tier-2 is ready.
          for (final id in {photos[0].id, photos[1].id}) {
            await until(
              () => controller.isFullSizeReady(id),
              reason: 'tier-2 to become ready for clamped-band id $id',
            );
            await until(
              () => !controller.debugTierOneKeyIds.contains(id),
              reason: 'AC-P2a: id $id to drop out of the tier-1 set once '
                  'ready',
            );
          }
          expect(
            controller.debugTierOneKeyIds,
            isEmpty,
            reason: 'both clamped-band ids reached tier-2; nothing else was '
                'ever in the tier-1 band to begin with',
          );
        });
      },
    );

    testWidgets(
      'TC-1242 ordering: tier-1 is visible (notifyLoaded observes it) before '
      'tier-2 is ready; the tier-1 duplicate is reclaimed only AFTER '
      "notifyLoaded fires for tier-2 (AC-P2a, 'no fallback flash')",
      (tester) async {
        await tester.runAsync(() async {
          final controller = build(
            navigationDebounce: const Duration(milliseconds: 200),
          );
          addTearDown(controller.dispose);
          final photos = paddedItems(14);
          const selected = 5;
          final centerId = photos[selected].id;

          var notifyCount = 0;
          var tierOnePresentAtFirstNotify = false;

          await controller.preloadImages(
            items: photos,
            selectedItemId: centerId,
            notifyLoaded: () {
              notifyCount++;
              // The tier-2 publish's decode-listener fires notifyLoaded
              // BEFORE `_evictTierOneDuplicate` (image_preload_controller.dart
              // TierTwoRegistry `onReadyForDisplay` wiring): the first
              // notification to observe tier-2 readiness for centerId must
              // still see the tier-1 entry live.
              if (controller.isFullSizeReady(centerId) &&
                  !tierOnePresentAtFirstNotify &&
                  controller.debugTierOneKeyIds.contains(centerId)) {
                tierOnePresentAtFirstNotify = true;
              }
            },
          );

          await until(
            () => controller.debugTierOneKeyIds.contains(centerId),
            reason: 'tier-1 to register for the selected id before tier-2 '
                'is ready (tier-1 is undebounced)',
          );
          expect(
            controller.isFullSizeReady(centerId),
            isFalse,
            reason: 'precondition: tier-2 still debounced',
          );

          await until(
            () => controller.isFullSizeReady(centerId),
            reason: 'tier-2 to become ready',
          );
          await until(
            () => !controller.debugTierOneKeyIds.contains(centerId),
            reason: 'the tier-1 duplicate to be reclaimed after tier-2 ready',
          );

          expect(
            notifyCount,
            greaterThan(0),
            reason: 'the tier-2 publish path must call notifyLoaded',
          );
          expect(
            tierOnePresentAtFirstNotify,
            isTrue,
            reason: 'notifyLoaded for tier-2 readiness must fire while '
                'tier-1 is STILL live -- eviction happens after, not before '
                '(no fallback flash)',
          );
        });
      },
    );

    // Plain test(), not testWidgets(): the RAW-decode path awaits real
    // engine futures, which hang forever inside testWidgets' FakeAsync zone.
    //
    // TC-1243 DELETED (round 2, team-lead ruling): it asserted the tier-2
    // survival property via the PIGGYBACK path (both tiers momentarily
    // `RawPixelsImage(payload)`), but mutation testing proved that path
    // never actually exercises guard #2 -- the REGISTERED tier-2 key for a
    // pixel item is always a `RawFullResImage` in production (both
    // piggyback and catch-up publish through `TierTwoRegistry.publishFullRes`,
    // which always builds one from a freshly-decoded `ui.Image`;
    // `_fullSizeProviderForPayload`'s `PixelPayload -> RawPixelsImage(payload)`
    // branch is a DISPLAY-time helper for the view layer, never what gets
    // written into `TierTwoRegistry._keys`). A test that cannot fail under
    // any reachable mutation is a fake green; deleting guard #2 itself left
    // TC-1243 passing. TC-1247 below subsumes the intended property
    // (tier-2 survives the dedup sweep) on the path that actually reaches
    // guard-adjacent logic, with a genuine mutation-verified red-leg
    // (docs/logs/2026-09-12/gpu-texture-contract.md round 2 adjudication;
    // tmp/verify/p2-mutation-redlegs.txt has both the TC-1243 fake-green
    // finding and TC-1247's red).
    test(
      'TC-1247 the CATCH-UP upgrade path (tier_two_scheduler.dart:637-655): a '
      'PixelPayload item that already holds tier-1 (RawPixelsImage) slides '
      'into the band, and its LATER catch-up publish (a genuinely separate '
      'RawFullResImage entry, not a shared one) correctly evicts the stale '
      'tier-1 duplicate while the new tier-2 entry survives',
      () async {
        // 300ms debounce: gates only the tier-2 sweep/catch-up (see [build]'s
        // doc), so there is a real window after re-entry in which tier-1 has
        // already re-registered from the RETAINED payload but the catch-up
        // decode has not landed yet.
        final controller = ImagePreloadController(
          scheduleFrameCallback: _microtaskFrame,
          navigationDebounce: const Duration(milliseconds: 300),
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              const NativeImageNeedsRawDecode(exifOrientation: 1),
          dngDecoder: (path) async {
            final rgba = Uint8List(4 * 3 * 4);
            for (var p = 0; p < 4 * 3; p++) {
              rgba[p * 4 + 3] = 0xFF; // opaque, per the RAW-decode contract
            }
            return DecodedRgba(rgba: rgba, width: 4, height: 3);
          },
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(10, 10);
        final photos = paddedItems(14);
        // Selected at index 8; the target item at index 5 sits at distance
        // -3 -- inside the -3..+5 retention window (so it gets a payload)
        // but OUTSIDE the tier-2 +/-2 window (so its piggybacked full-res
        // pixels get discarded, not published) and outside the tier-1 +/-1
        // band. It ends this phase holding a retained PixelPayload and NO
        // tier-2 entry: exactly the precondition the catch-up path exists
        // for ("slid into the band, or left and came back after its entry
        // was evicted").
        const farSelected = 8;
        const targetIndex = 5;
        final targetId = photos[targetIndex].id;

        await controller.preloadImages(
          items: photos,
          selectedItemId: photos[farSelected].id,
          notifyLoaded: () {},
        );
        await until(
          () => controller.payloadFor(targetId) is PixelPayload,
          reason: 'the far slot to RAW-decode and retain its PixelPayload',
        );
        expect(
          controller.isFullSizeReady(targetId),
          isFalse,
          reason: 'precondition: distance 3 is outside the tier-2 +/-2 '
              'window, so the piggybacked full-res pixels must have been '
              'discarded, not published',
        );

        // Re-enter: move the selection onto the target itself (distance 0),
        // inside both the tier-1 band and the tier-2 window.
        await controller.preloadImages(
          items: photos,
          selectedItemId: targetId,
          notifyLoaded: () {},
        );
        await until(
          () => controller.debugTierOneKeyIds.contains(targetId),
          reason: 'tier-1 to re-register the RETAINED payload immediately '
              '(no new decode) as it re-enters the band',
        );
        expect(
          controller.isFullSizeReady(targetId),
          isFalse,
          reason: 'precondition: the tier-2 sweep is still debounced, so the '
              'catch-up upgrade has not landed yet',
        );

        // Let the debounce elapse and the catch-up FFI decode land.
        await until(
          () => controller.isFullSizeReady(targetId),
          reason: 'the catch-up upgrade to publish tier-2',
        );
        await until(
          () => !controller.debugTierOneKeyIds.contains(targetId),
          reason: 'AC-P2a: the now-stale tier-1 duplicate must be reclaimed',
        );

        expect(
          controller.debugTierOneKeyIds.contains(targetId),
          isFalse,
          reason: '(i) the tier-1 key must be gone: unlike the piggyback '
              'case, the catch-up publish builds a DIFFERENT RawFullResImage '
              'object, so guard #2 (key equality) does NOT apply here -- '
              'this is a genuine duplicate, and it must be reclaimed',
        );
        expect(
          controller.isFullSizeReady(targetId),
          isTrue,
          reason: '(ii) the NEW tier-2 RawFullResImage entry must be '
              'resident (isFullSizeReady re-derives residency via '
              'ImageCache.containsKey, see tier_two_registry.dart:120): '
              'reclaiming the stale tier-1 duplicate must not touch it',
        );
      },
    );
  });
}
