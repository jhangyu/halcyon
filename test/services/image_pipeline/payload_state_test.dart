// Phase 5 — per-item ValueListenable<PayloadState>
// (async-pipeline-refactor-plan.md §3 Phase 5).
//
// What these pin, in the plan's own order:
//   TC-985  the stage ladder is walked forward only, never skipped backwards
//   TC-986  the notifier map does not leak across a 200-item navigation
//   TC-987  every notifier that leaves the map was disposed (count sink)
//   TC-988  listen -> evict -> read again: no throw, and the fresh notifier
//           reports `absent` (the disposal rule is this phase's whole risk)
//   TC-989  a landing for one strip row rebuilds THAT row's tile only
//   TC-990  `failed` is terminal until reset()
//
// Red-proof for every guard-type assertion here: docs/logs/2026-09-06/
// phase5-redproof.txt.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/views/layout/main_surface.dart';

import '../../support/preload_fixtures.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
        revision: ValueNotifier<int>(0),
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
}
