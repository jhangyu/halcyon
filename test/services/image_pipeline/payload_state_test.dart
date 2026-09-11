// Merged (round 4 M2 consolidation) from:
//   payload_state_test.dart (this file's own tests, base)
//   payload_state_disposal_race_test.dart
//   payload_state_eviction_race_test.dart
//   photo_payload_cache_test.dart
//   shared_payload_retention_test.dart
// Each source file's tests are wrapped in a group() named after its basename
// to keep setUp/tearDown scoping and test names intact. Top-level helper name
// collisions across files were resolved with a private `_<shortname>` suffix
// (Rule 2); no test behavior was changed.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload_cache.dart';
import 'package:halcyon_flutter/services/image_pipeline/retention_policy.dart';
import 'package:halcyon_flutter/views/layout/main_surface.dart';

import '../../support/preload_fixtures.dart';

// ---------------------------------------------------------------------------
// Helpers from payload_state_test.dart (base file)
// ---------------------------------------------------------------------------

void _microtaskFrame(void Function() callback) => callback();

/// A controller whose loader always succeeds with a real (tiny) PNG.
ImagePreloadController _cheapController() => ImagePreloadController(
  scheduleFrameCallback: _microtaskFrame,
  imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
      NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
  dngDecoder: (path) async => fail('cheap rung must not RAW-decode'),
);

/// The canonical progression. `failed` is deliberately NOT in it: it is not a
/// rung of the ladder, it is the terminal branch off it.
const List<PayloadStage> _ladder = <PayloadStage>[
  PayloadStage.absent,
  PayloadStage.decoding,
  PayloadStage.tierOneReady,
  PayloadStage.tierTwoReady,
];

/// Collapses repeats (a `thumbnailReady` flip re-notifies with the same stage)
/// and asserts the remaining sequence is a PREFIX of [_ladder] — i.e. it
/// starts at the beginning and skips nothing.
void expectPrefixOfLadder(List<PayloadStage> observed, {String? reason}) {
  final collapsed = <PayloadStage>[];
  for (final stage in observed) {
    if (collapsed.isEmpty || collapsed.last != stage) collapsed.add(stage);
  }
  expect(
    collapsed,
    _ladder.sublist(0, collapsed.length),
    reason:
        reason ??
        'observed stages $collapsed must be a prefix of $_ladder '
            '(forward only, nothing skipped, nothing repeated out of order)',
  );
}

// ---------------------------------------------------------------------------
// Helpers from payload_state_disposal_race_test.dart
// ---------------------------------------------------------------------------

void _microtaskFrameDisposalRace(void Function() callback) => callback();

// ---------------------------------------------------------------------------
// Helpers from shared_payload_retention_test.dart
// ---------------------------------------------------------------------------

Future<NativeImageResult> _bytesLoader(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => NativeImageBytes(Uint8List.fromList(<int>[1, 2, 3, 4]));

/// Polls [cond] until it is true or [timeout] elapses, whichever is first --
/// a real debounce/async-drain still gets its full budget if it needs it, but
/// the common case (condition already true) returns almost immediately
/// instead of paying a fixed sleep every time.
Future<void> _pollUntil(
  bool Function() cond,
  Duration timeout, {
  Duration step = const Duration(milliseconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(step);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('payload_state_test.dart', () {
    setUp(clearImageCacheSetUp);

    group('TC-985 stage ladder', () {
      test(
        'one item observes a PREFIX of absent -> decoding -> tierOneReady',
        () async {
          final controller = _cheapController();
          addTearDown(controller.dispose);
          controller.updateTargetSize(800, 600);

          final items = paddedItems(20);
          final id = items[10].id;

          final observed = <PayloadStage>[];
          final state = controller.stateFor(id);
          observed.add(state.value.stage);
          void record() => observed.add(state.value.stage);
          state.addListener(record);
          addTearDown(() => state.removeListener(record));

          await controller.preloadImages(
            items: items,
            selectedItemId: id,
            notifyLoaded: () {},
          );
          await until(
            () => controller.payloadFor(id) != null,
            reason: '$id payload to land',
          );
          // The landing writes the cache and the stage in the same statement,
          // so no extra settle is needed for the transition itself.
          expect(
            state.value.stage,
            PayloadStage.tierOneReady,
            reason: 'a retained payload IS tier-1 readiness',
          );
          expectPrefixOfLadder(observed);
          expect(
            observed.first,
            PayloadStage.absent,
            reason: 'nothing was retained or claimed when the notifier was made',
          );
          expect(
            observed,
            contains(PayloadStage.decoding),
            reason:
                'the claim must be observable, or a view has no way to tell '
                '"not started" from "in flight"',
          );
        },
      );

      test('a landed item is born ready when the view asks late', () async {
        final controller = _cheapController();
        addTearDown(controller.dispose);
        controller.updateTargetSize(800, 600);

        final items = paddedItems(20);
        final id = items[5].id;
        await controller.preloadImages(
          items: items,
          selectedItemId: id,
          notifyLoaded: () {},
        );
        await until(() => controller.payloadFor(id) != null);

        // No notifier existed while the load ran: the state is DERIVED from the
        // same containers the getters read, so it cannot disagree with them.
        expect(controller.stateFor(id).value.stage, PayloadStage.tierOneReady);
      });
    });

    group('TC-991 tier-2', () {
      test(
        'a full-size landing promotes the item to tierTwoReady, and the whole '
        'observed sequence is still a prefix of the ladder',
        () async {
          // The piggyback route: a real RAW decode hands back full-resolution
          // pixels in the same call that produces the payload, so tier-2 lands
          // without the debounce. Shape copied from the dual-window tier-2
          // test so this pins the CONTROLLER's path, not a synthetic one.
          final controller = ImagePreloadController(
            scheduleFrameCallback: _microtaskFrame,
            imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
                const NativeImageNeedsRawDecode(exifOrientation: 1),
            dngDecoder: (path) async => DecodedRgba(
              rgba: Uint8List.fromList(
                List<int>.generate(
                  400 * 300 * 4,
                  (i) => i % 4 == 3 ? 0xFF : i % 256,
                ),
              ),
              width: 400,
              height: 300,
            ),
          );
          addTearDown(controller.dispose);
          controller.updateTargetSize(200, 150);

          final items = paddedItems(14, extension: 'dng');
          final id = items[5].id;
          final observed = <PayloadStage>[];
          final state = controller.stateFor(id);
          observed.add(state.value.stage);
          void record() => observed.add(state.value.stage);
          state.addListener(record);
          addTearDown(() => state.removeListener(record));

          await controller.preloadImages(
            items: items,
            selectedItemId: id,
            notifyLoaded: () {},
          );
          await until(
            () => controller.isFullSizeReady(id),
            reason: '$id to gain a full-size tier-2 entry',
          );
          expect(
            state.value.stage,
            PayloadStage.tierTwoReady,
            reason:
                'the registry says the full-size entry is resident, so the '
                'per-item state must say so too',
          );
          expectPrefixOfLadder(observed);
          expect(
            observed,
            contains(PayloadStage.tierOneReady),
            reason: 'tier-2 must not swallow the tier-1 transition',
          );
        },
      );
    });

    group('TC-986/TC-987 lifetime', () {
      test(
        'a 200-item navigation leaves at most (retention union) notifiers, and '
        'every notifier that left the map was disposed',
        () async {
          // The 200 iterations below complete inside a single real
          // `kPayloadStateDisposalGrace` window, so with the wall clock every
          // notifier would still be inside its grace at assertion time and the
          // bound would be vacuously unreachable. The clock is therefore driven
          // explicitly: each navigation happens more than a grace after the
          // `stateFor` that preceded it, which is the steady state this test is
          // about. The BOUND ITSELF is unchanged -- relaxing it to
          // "union + deferred" would make it inflate with any leak that
          // manifested as mass deferral, i.e. an assertion that cannot fail.
          var now = DateTime(2026, 9, 6, 12);
          ImagePreloadController.payloadStateClock = () => now;
          addTearDown(
            () => ImagePreloadController.payloadStateClock = DateTime.now,
          );

          final controller = _cheapController();
          addTearDown(controller.dispose);
          controller.updateTargetSize(800, 600);

          final items = paddedItems(200);
          var asked = 0;
          for (final item in items) {
            // Exactly what a view does: ask for the state of the item it is
            // about to paint, every navigation.
            controller.stateFor(item.id);
            asked++;
            now = now.add(kPayloadStateDisposalGrace * 2);
            await controller.preloadImages(
              items: items,
              selectedItemId: item.id,
              notifyLoaded: () {},
            );
          }

          final union = controller.debugRetentionIds.length;
          expect(
            controller.debugPayloadStateCount,
            lessThanOrEqualTo(union),
            reason:
                'notifier lifetime IS the retention union; ${controller.debugPayloadStateCount} '
                'live notifiers against a union of $union means the sweep is '
                'not reaching them (plan risk R7, the unbounded-map arm)',
          );
          expect(
            asked,
            200,
            reason: 'anti-hollow: the loop must really have asked 200 times',
          );
          expect(
            controller.debugPayloadStateDisposeCount,
            asked - controller.debugPayloadStateCount,
            reason:
                'every notifier removed from the map must have been disposed — '
                'no silent drops (plan risk R7, the disposed-listener arm)',
          );
        },
      );

      test(
        'TC-988: listen, evict, read again — no throw and the fresh state is '
        'absent',
        () async {
          // Same reason as the test above: this case runs well inside one real
          // `kPayloadStateDisposalGrace`, so the sweep below would defer rather
          // than dispose and the eviction under test would never happen. The
          // clock is advanced past the grace before the far navigation; every
          // assertion is unchanged.
          var now = DateTime(2026, 9, 6, 12);
          ImagePreloadController.payloadStateClock = () => now;
          addTearDown(
            () => ImagePreloadController.payloadStateClock = DateTime.now,
          );

          final controller = _cheapController();
          addTearDown(controller.dispose);
          controller.updateTargetSize(800, 600);

          final items = paddedItems(60);
          final id = items[0].id;

          var notifications = 0;
          final state = controller.stateFor(id);
          void listener() => notifications++;
          state.addListener(listener);

          await controller.preloadImages(
            items: items,
            selectedItemId: id,
            notifyLoaded: () {},
          );
          await until(() => controller.payloadFor(id) != null);
          final before = notifications;
          expect(before, greaterThan(0));

          // Navigate far enough that `id` leaves the retention union entirely.
          now = now.add(kPayloadStateDisposalGrace * 2);
          await controller.preloadImages(
            items: items,
            selectedItemId: items[40].id,
            notifyLoaded: () {},
          );
          expect(
            controller.debugRetentionIds.contains(id),
            isFalse,
            reason: 'precondition: the id really did leave the union',
          );

          // The widget that is still mounted removes its listener a frame
          // later, and a rebuilt one may re-listen to the object it still
          // holds. `ChangeNotifier.addListener` asserts on a disposed notifier
          // (`debugAssertNotDisposed`) -- that assert IS the crash this phase's
          // disposal rule risks, so it is asserted here in the direction that
          // can actually fail.
          //
          // NOTE (red-proof, phase5-redproof.txt M5): `removeListener` is NOT
          // the hazard -- Flutter's own implementation tolerates it after
          // dispose, so an assertion about it could never fail. It is called
          // for realism, not as a check.
          state.removeListener(listener);
          expect(
            () => state.addListener(listener),
            returnsNormally,
            reason:
                'a widget still holding the evicted notifier must not crash '
                'the app when it re-listens (plan risk R7, first arm)',
          );
          state.removeListener(listener);

          final fresh = controller.stateFor(id);
          expect(fresh.value.stage, PayloadStage.absent);
          expect(
            identical(fresh, state),
            isFalse,
            reason: 'the evicted notifier must be REPLACED, not revived',
          );
          // And listening to the fresh one still works.
          fresh.addListener(listener);
          addTearDown(() => fresh.removeListener(listener));
        },
      );
    });

    group('TC-990 failure', () {
      test('failed is terminal until reset()', () async {
        final controller = ImagePreloadController(
          scheduleFrameCallback: _microtaskFrame,
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              const NativeImageFailure('UNREADABLE', 'test'),
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(800, 600);

        final items = paddedItems(20);
        final id = items[3].id;
        final state = controller.stateFor(id);

        await controller.preloadImages(
          items: items,
          selectedItemId: id,
          notifyLoaded: () {},
        );
        await until(
          () => controller.hasFailed(id),
          reason: '$id to latch as a permanent miss',
        );
        expect(state.value.stage, PayloadStage.failed);

        // A second pass must not walk it back to `decoding`.
        await controller.preloadImages(
          items: items,
          selectedItemId: id,
          notifyLoaded: () {},
        );
        expect(state.value.stage, PayloadStage.failed);

        controller.reset();
        expect(
          controller.stateFor(id).value.stage,
          PayloadStage.absent,
          reason: 'a folder reload is the only thing that clears the latch',
        );
      });
    });

    group('TC-989 rebuild isolation', () {
      testWidgets('a landing for row A does not rebuild row B\'s tile', (
        tester,
      ) async {
        final stateA = PayloadStateNotifier(const PayloadState.absent());
        final stateB = PayloadStateNotifier(const PayloadState.absent());
        addTearDown(stateA.dispose);
        addTearDown(stateB.dispose);
        final payloads = <String, SourcePayload?>{'A': null, 'B': null};
        final builds = <String, int>{'A': 0, 'B': 0};

        final model = PhotoStripModel(
          items: const <PhotoItem>[],
          selectedId: 'A',
          recycleMode: false,
          onSelect: (_) {},
          payloadFor: (id) => payloads[id],
          stateFor: (id) => id == 'A' ? stateA : stateB,
          onVisibleRange: (_, _) {},
        );

        Widget tile(String id) => StripTile(
          strip: model,
          id: id,
          builder: (context, payload) {
            builds[id] = builds[id]! + 1;
            return SizedBox(
              width: 10,
              height: 10,
              child: Text(payload == null ? '$id-empty' : '$id-ready'),
            );
          },
        );

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Column(children: <Widget>[tile('A'), tile('B')]),
          ),
        );
        expect(builds, <String, int>{'A': 1, 'B': 1});

        // A's payload lands: its state flips and its payload appears.
        payloads['A'] = freshEncodedPayload();
        stateA.trySetValue(const PayloadState(stage: PayloadStage.tierOneReady));
        await tester.pump();

        expect(
          builds['B'],
          1,
          reason:
              'B rebuilt on A\'s landing — the strip is still repainting as a '
              'whole, which is exactly what Phase 5 removes',
        );
        expect(builds['A'], 2, reason: 'A must have rebuilt (anti-hollow)');
        expect(find.text('A-ready'), findsOneWidget);
        expect(find.text('B-empty'), findsOneWidget);
      });
    });
  });

  group('payload_state_disposal_race_test.dart', () {
    // Race B (P1, `docs/logs/2026-09-06/p3-plan-P1.md` Task 2): the sidebar's
    // wanted set is rewritten ONLY inside its 100ms debounce timer
    // (`sidebar_thumbnail_controller.dart:448-483`). A row built during that
    // window calls `stateFor(id)` and materialises a notifier for an id that is
    // in neither `_navRetentionIds` nor `_wantedIds`. Any navigation-side
    // `_republishEvictionPriority` (`image_preload_controller.dart:554-560`,
    // reached from the navigation pass at :1085) runs `_sweepPayloadStates`,
    // which disposes exactly that notifier -- silently, with no tombstone, so
    // every later `_markStage`/`_markThumbnailReady` for the id early-returns and
    // the row never paints.
    //
    // The ordering is forced by CONSTRUCTION, not by sleeping: the entrance
    // coalesces intents onto a microtask that is queued BEFORE the awaiting
    // caller's continuation (`image_preload_controller.dart:898-901`), so
    // `await preloadThumbnails(...)` resumes with the sidebar's 100ms timer armed
    // and not yet fired, and `await preloadImages(...)` resumes with the
    // navigation pass -- and therefore the sweep -- already run.
    //
    // Plain `test()` with real timing: FakeAsync plus a real engine future hangs
    // forever (G-020/G-021).

    test(
      'TC-1012: a notifier materialised inside the 100ms sidebar debounce window '
      'survives a concurrent navigation sweep',
      () async {
        final controller = ImagePreloadController(
          scheduleFrameCallback: _microtaskFrameDisposalRace,
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
          dngDecoder: (path) async => fail('cheap rung must not RAW-decode'),
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(800, 600);

        final items = paddedItems(60, extension: 'jpg');
        final farId = items[40].id;

        // The sidebar scrolled to rows 40..44. `_wantedIds` is NOT updated yet:
        // the rewrite happens only inside the 100ms debounce timer, which has
        // been armed by this call but has not fired.
        await controller.preloadThumbnails(items: items, startIdx: 40, endIdx: 44);
        expect(
          controller.debugRetentionIds.contains(farId),
          isFalse,
          reason:
              'precondition: we are inside the debounce window, so the row is '
              'not in the retention union yet -- if this fails the test is no '
              'longer exercising the window',
        );

        // A row builds and asks for its state: this materialises the notifier.
        final state = controller.stateFor(farId) as PayloadStateNotifier;

        // A navigation pass fires mid-window and republishes eviction priority,
        // which sweeps notifiers outside the retention union.
        await controller.preloadImages(
          items: items,
          selectedItemId: items[0].id,
          notifyLoaded: () {},
        );
        expect(
          controller.debugRetentionIds.contains(items[0].id),
          isTrue,
          reason:
              'precondition: the navigation pass must actually have run before '
              'the assertion below, otherwise no sweep happened and a green '
              'result would prove nothing',
        );
        expect(
          controller.debugRetentionIds.contains(farId),
          isFalse,
          reason:
              'precondition: the debounce timer still has not fired, so the far '
              'row is outside the union the sweep keeps',
        );

        // Read the notifier OBJECT captured before the sweep. A re-read through
        // `stateFor(farId)` would silently create a FRESH notifier and be a
        // false green (same shape as the rejected `removeListener` guard,
        // handover §9).
        expect(
          state.isDisposed,
          isFalse,
          reason:
              'the freshly requested row lost its notifier to a navigation-side '
              'sweep: no tombstone, so every later _markStage for this id early-'
              'returns and the tile never paints',
        );
      },
    );

    test(
      'TC-1013: the disposal grace expires -- the next sweep collects the '
      'deferred notifier',
      () async {
        // The grace is a DELAY, not a leak. Driving it through the injected
        // clock instead of sleeping keeps this deterministic and keeps FakeAsync
        // (which would hang on a real engine future, G-020/G-021) out.
        var now = DateTime(2026, 9, 6, 12);
        ImagePreloadController.payloadStateClock = () => now;
        addTearDown(
          () => ImagePreloadController.payloadStateClock = DateTime.now,
        );

        final controller = ImagePreloadController(
          scheduleFrameCallback: _microtaskFrameDisposalRace,
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
          dngDecoder: (path) async => fail('cheap rung must not RAW-decode'),
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(800, 600);

        final items = paddedItems(60, extension: 'jpg');
        final farId = items[40].id;
        await controller.preloadThumbnails(items: items, startIdx: 40, endIdx: 44);
        final state = controller.stateFor(farId) as PayloadStateNotifier;

        await controller.preloadImages(
          items: items,
          selectedItemId: items[0].id,
          notifyLoaded: () {},
        );
        expect(state.isDisposed, isFalse, reason: 'deferred by the grace period');
        expect(controller.debugPayloadStateDeferredCount, greaterThan(0));

        // Past the grace, with the row still outside the retention union.
        now = now.add(kPayloadStateDisposalGrace * 2);
        await controller.preloadImages(
          items: items,
          selectedItemId: items[1].id,
          notifyLoaded: () {},
        );
        expect(
          controller.debugRetentionIds.contains(farId),
          isFalse,
          reason:
              'precondition: the row must still be outside the union, otherwise '
              'the sweep has no grounds to collect it and a red result would be '
              'about retention, not about the grace',
        );

        expect(
          state.isDisposed,
          isTrue,
          reason:
              'the grace is a delay, not a leak: once it expires the ordinary '
              'retention sweep must collect the notifier',
        );
      },
    );
  });

  group('payload_state_eviction_race_test.dart', () {
    // Without the binding, the controller's very first landing never completes
    // (and dispose() throws from _evictTierOneKeys reaching PaintingBinding),
    // so every assertion below would fail for a harness reason instead of the
    // mechanism under test. Same preamble as async_baseline_pins_test.dart.

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
  });

  group('photo_payload_cache_test.dart', () {
    // Both kinds at exactly the same byteCost, so any difference in how the
    // cache treats them is a difference in KIND, never in size.
    const side = 64;
    const cost = side * side * 4; // 16384 bytes

    EncodedPayload encoded() => EncodedPayload(Uint8List(cost));
    PixelPayload pixels() =>
        PixelPayload(rgba: Uint8List(cost), width: side, height: side);

    group('PhotoPayloadCache (D4: retention is type-blind)', () {
      // THE KILLER for D4. Everything else in this file is scaffolding.
      //
      // Runs the identical insert/evict scenario twice -- once with the pixel
      // payloads in even slots, once with them in odd slots -- and requires the
      // surviving ID SET to be identical. Any rule that consults the payload
      // kind (evict pixels first, exempt encoded bytes, weight one kind
      // differently) makes the two runs disagree, because the kinds sit at
      // different ids. A rule that reads only byteCost cannot tell the two runs
      // apart.
      test(
        'TC-060 eviction order is identical when the payload KINDS are swapped',
        () {
          List<String> survivorsWithPixelsAt(bool Function(int index) isPixel) {
            // Budget for 4 entries; 6 inserted, so 2 must go.
            final cache = PhotoPayloadCache(byteBudget: cost * 4);
            for (var i = 0; i < 6; i++) {
              cache.put('id$i', isPixel(i) ? pixels() : encoded());
            }
            return cache.ids.toList();
          }

          final pixelsEven = survivorsWithPixelsAt((i) => i.isEven);
          final pixelsOdd = survivorsWithPixelsAt((i) => i.isOdd);
          final allEncoded = survivorsWithPixelsAt((i) => false);

          expect(
            pixelsEven,
            allEncoded,
            reason:
                'putting pixel payloads in the even slots changed who survived '
                '-- the eviction rule is reading the payload kind, not byteCost',
          );
          expect(
            pixelsOdd,
            allEncoded,
            reason:
                'putting pixel payloads in the odd slots changed who survived '
                '-- the eviction rule is reading the payload kind, not byteCost',
          );
          // Sanity: the scenario really did evict something, so the assertions
          // above are not comparing three copies of "nothing happened".
          expect(allEncoded, ['id2', 'id3', 'id4', 'id5']);
        },
      );

      test('TC-061 eviction with priority set evicts the FARTHEST item, not '
          'the oldest (user ruling 2026-08-27)', () {
        final cache = PhotoPayloadCache(byteBudget: cost * 3);
        cache.put('a', encoded());
        cache.put('b', pixels());
        cache.put('c', encoded());
        // 'a' is the NEAREST (selected), 'c' is the farthest.
        cache.setEvictionPriority(['a', 'b', 'c']);
        cache.put('d', pixels());

        expect(cache.contains('c'), isFalse,
            reason: 'c was the farthest entry and should be evicted first');
        expect(cache.contains('a'), isTrue,
            reason: 'a is the selected item (nearest) and must survive');
        expect(cache.ids.toList(), ['a', 'b', 'd']);
      });

      test('TC-300 over-budget put evicts the farthest id, not the oldest', () {
        // Budget for 3 entries; priority order: selected=a (nearest), then b, c.
        // Insert a, b, c, then d (triggers eviction). Victim must be 'c'
        // (farthest), not 'a' (oldest).
        final cache = PhotoPayloadCache(byteBudget: cost * 3);
        cache.put('a', encoded());
        cache.put('b', pixels());
        cache.put('c', encoded());
        cache.setEvictionPriority(['a', 'b', 'c']);
        cache.put('d', pixels());

        expect(cache.contains('c'), isFalse,
            reason: 'c is farthest from selection and must be evicted');
        expect(cache.contains('a'), isTrue,
            reason: 'a is the selected item (nearest) and survives');
        expect(cache.contains('b'), isTrue);
        expect(cache.contains('d'), isTrue);
      });

      test('TC-301 selected (first-priority) item survives even when it is '
          'the oldest entry', () {
        // 'sel' is put first (oldest) but is nearest in priority.
        final cache = PhotoPayloadCache(byteBudget: cost * 2);
        cache.put('sel', encoded());
        cache.put('far1', pixels());
        cache.setEvictionPriority(['sel', 'far1']);
        // Trigger eviction by putting a third entry that exceeds budget.
        cache.put('far2', encoded());

        expect(cache.contains('sel'), isTrue,
            reason: 'the selected item must survive even though it is the oldest');
        expect(cache.contains('far1'), isFalse,
            reason: 'far1 is farthest and should be evicted');
        expect(cache.contains('far2'), isTrue,
            reason: 'far2 was just written and is the most recent');
      });

      test('TC-062 peek does not count as a use', () {
        final cache = PhotoPayloadCache(byteBudget: cost * 2);
        cache.put('a', encoded());
        cache.put('b', encoded());
        expect(cache.peek('a'), isNotNull);
        cache.put('c', encoded());
        expect(
          cache.contains('a'),
          isFalse,
          reason: 'peek must be observation-only, or bookkeeping reads would '
              'silently reorder eviction',
        );
      });

      test('TC-063 a payload larger than the whole budget is still retained', () {
        final cache = PhotoPayloadCache(byteBudget: cost);
        cache.put('huge', PixelPayload(
          rgba: Uint8List(cost * 4),
          width: side * 2,
          height: side * 2,
        ));
        expect(
          cache.peek('huge'),
          isNotNull,
          reason: 'writing a payload and evicting it in the same breath strands '
              'the view on a spinner that can never resolve',
        );
      });

      test('TC-064 retainOnly drops exactly the ids outside the window and '
          'reports them', () {
        final cache = PhotoPayloadCache();
        for (var i = 0; i < 5; i++) {
          cache.put('id$i', i.isEven ? encoded() : pixels());
        }
        final dropped = cache.retainOnly({'id1', 'id3'});
        expect(dropped..sort(), ['id0', 'id2', 'id4']);
        expect(cache.ids.toList(), ['id1', 'id3']);
        expect(cache.totalByteCost, cost * 2);
      });

      test('TC-065 the retention window is -3..+5, clamped at both ends', () {
        final items = List.generate(20, (i) => 'id$i');
        String idOf(String s) => s;

        expect(
          retentionWindowIds(items, 8, idOf),
          {for (var i = 5; i <= 13; i++) 'id$i'},
          reason: '-3..+5 around index 8',
        );
        expect(retentionWindowIds(items, 0, idOf), {
          for (var i = 0; i <= 5; i++) 'id$i',
        });
        expect(retentionWindowIds(items, 19, idOf), {
          for (var i = 16; i <= 19; i++) 'id$i',
        });
        expect(retentionWindowIds(<String>[], 0, idOf), isEmpty);
      });

      test('TC-219 retentionWindowIds honours explicit before/after', () {
        final items = List.generate(20, (i) => 'id$i');
        final window = retentionWindowIds<String>(
          items,
          10,
          (item) => item,
          before: 2,
          after: 2,
        );
        expect(window, {'id8', 'id9', 'id10', 'id11', 'id12'});
      });

      test('TC-220 retentionWindowIds defaults are still -3..+5', () {
        final items = List.generate(20, (i) => 'id$i');
        final window = retentionWindowIds<String>(items, 10, (item) => item);
        expect(window, {
          'id7', 'id8', 'id9', 'id10', 'id11', 'id12', 'id13', 'id14', 'id15',
        });
      });
    });
  });

  group('shared_payload_retention_test.dart', () {
    // TC-427
    test(
      'retention is the union of the navigation window and the sidebar set',
      () async {
        final controller = ImagePreloadController(
          imageLoader: _bytesLoader,
          payloadEncoder: throwingPayloadEncoder,
          navigationDebounce: Duration.zero,
        );
        final items = photoItems(60);

        await controller.preloadImages(
          items: items,
          selectedItemId: 'p0',
          notifyLoaded: () {},
        );
        await controller.preloadThumbnails(
          items: items,
          startIdx: 40,
          endIdx: 44,
          notifyLoaded: () {},
        );
        await _pollUntil(
          () =>
              controller.debugRetentionIds.contains('p0') &&
              controller.debugRetentionIds.contains('p42'),
          const Duration(milliseconds: 250),
        );

        final ids = controller.debugRetentionIds;
        expect(ids.contains('p0'), isTrue, reason: 'navigation window');
        expect(ids.contains('p42'), isTrue, reason: 'sidebar viewport');
        controller.dispose();
      },
    );

    // TC-428
    test('eviction priority puts every navigation id before every sidebar id', () async {
      final controller = ImagePreloadController(
        imageLoader: _bytesLoader,
        payloadEncoder: throwingPayloadEncoder,
      );
      final items = photoItems(60);
      await controller.preloadThumbnails(
        items: items,
        startIdx: 40,
        endIdx: 44,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await controller.preloadImages(
        items: items,
        selectedItemId: 'p0',
        notifyLoaded: () {},
      );

      final order = controller.debugEvictionPriority;
      expect(order.first, 'p0');
      final lastNav = order.indexOf('p5'); // inside -3..+5 of p0
      final firstSidebarOnly = order.indexOf('p42');
      expect(lastNav, greaterThanOrEqualTo(0));
      expect(firstSidebarOnly, greaterThan(lastNav));
      controller.dispose();
    });

    // TC-818
    test(
      'eviction priority ranks beyond-band ids last: -3 evicted before +5, '
      'then -2, then +4, band far-to-near after that',
      () async {
        final controller = ImagePreloadController(
          imageLoader: _bytesLoader,
          payloadEncoder: throwingPayloadEncoder,
        );
        final items = photoItems(60);
        await controller.preloadImages(
          items: items,
          selectedItemId: 'p10',
          notifyLoaded: () {},
        );

        // Window is p7..p15 (-3..+5 of p10); tier-2 band is p9..p13 (-1..+3).
        // Victim picking evicts from the END of this list, so the order below
        // reads keep-longest first: band near-to-far, then +4, -2, +5, -3.
        final order = controller.debugEvictionPriority;
        expect(order, <String>[
          'p10', 'p11', 'p9', 'p12', 'p13', // in band, near-to-far
          'p14', 'p8', // 1 beyond band edge: +4 outlives -2
          'p15', 'p7', // 2 beyond band edge: +5 outlives -3, -3 evicted first
        ]);
        controller.dispose();
      },
    );

    // TC-429
    test('sidebar-only ids never get a tier-1 or tier-2 ImageCache entry', () async {
      final controller = ImagePreloadController(
        imageLoader: _bytesLoader,
        payloadEncoder: throwingPayloadEncoder,
      );
      final items = photoItems(60);
      // Tier-1 precache is a no-op until the viewport size is known, so without
      // this the tier-1 assertion below would pass vacuously.
      controller.updateTargetSize(800, 600);
      await controller.preloadImages(
        items: items,
        selectedItemId: 'p0',
        notifyLoaded: () {},
      );
      await controller.preloadThumbnails(
        items: items,
        startIdx: 40,
        endIdx: 44,
        notifyLoaded: () {},
      );
      await _pollUntil(
        () => controller.debugTierOneKeyIds.isNotEmpty,
        const Duration(milliseconds: 400),
      );
      // The sidebar's own ids (p40..p44 plus the prefetch margin) are retained
      // for their PAYLOAD only; neither ImageCache tier may hold a key for them.
      for (final id in <String>['p40', 'p41', 'p42', 'p43', 'p44']) {
        expect(controller.debugTierTwoKeyIds.contains(id), isFalse, reason: id);
        expect(controller.debugTierOneKeyIds.contains(id), isFalse, reason: id);
      }
      // Sanity: the assertion above is not vacuous because the tiers are empty --
      // the selected navigation item DOES hold a tier-1 key.
      expect(controller.debugTierOneKeyIds, isNotEmpty);
      controller.dispose();
    });
  });
}
