import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/serial_decode_lane.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_registry.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_scheduler.dart';

// A minimal valid 1x1 transparent PNG, so a real engine decode can be
// exercised without shipping a binary fixture file. Same bytes as
// test/tier_two_registry_test.dart:16-19.
final _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAA'
  'AAYAAjCB0C8AAAAASUVORK5CYII=',
);

/// A fresh encoded payload holding its OWN bytes object, so two payloads never
/// collide on the MemoryImage cache key (which is bytes identity + scale).
EncodedPayload _freshEncodedPayload() =>
    EncodedPayload(Uint8List.fromList(_tinyPngBytes));

List<PhotoItem> _items(int count) => List.generate(
  count,
  (i) => PhotoItem(id: 'a$i', files: [File('/tmp/a$i.jpg')]),
);

/// Drives the scheduler with everything it needs stubbed out, so the tests
/// below exercise SCHEDULING only: no controller, no payload cache, no photo
/// source, no prefetch scheduler.
///
/// [payloads] stands in for the controller's retention cache; every
/// `ensurePayload` call is recorded in [loadOrder] and parked on a completer
/// the test releases by hand, which is what makes "one decode in flight, FIFO"
/// observable without a wall-clock wait.
class _Harness {
  _Harness() {
    registry = TierTwoRegistry(currentPayloadFor: (id) => payloads[id]);
    scheduler = TierTwoScheduler(
      registry: registry,
      // The scheduler no longer owns a queue: it shares the pipeline's ONE
      // serial decode lane with payload production (user ruling 2026-08-26).
      // The single-flight and re-ordering properties asserted below are now
      // properties of that lane, driven through the scheduler.
      lane: lane,
      currentPayloadFor: (id) => payloads[id],
      fullSizeProviderFor: (payload) => switch (payload) {
        EncodedPayload(:final bytes) => fullSizeProviderFor(bytes),
        PixelPayload() => throw StateError('not exercised here'),
      },
      ensurePayload:
          (
            item, {
            required int distance,
            required VoidCallback? notifyLoaded,
            bool onSerialLane = false,
          }) {
            loadOrder.add(item.id);
            return (inFlight[item.id] ??= Completer<void>()).future;
          },
      dngDecoder: () => null,
      exifOrientationFor: (id) => null,
      // Zero, so the debounce fires on the next event-loop turn instead of
      // costing the suite a real 250ms wall-clock wait per test.
      navigationDebounce: Duration.zero,
    );
  }

  final SerialDecodeLane lane = SerialDecodeLane();
  late final TierTwoRegistry registry;
  late final TierTwoScheduler scheduler;
  final Map<String, SourcePayload> payloads = {};
  final List<String> loadOrder = [];
  final Map<String, Completer<void>> inFlight = {};

  /// Lets the zero-duration debounce timer fire and the queue advance one step.
  Future<void> pump() async {
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Releases the load currently parked for [id] and advances the queue.
  Future<void> release(String id) async {
    inFlight[id]!.complete();
    await pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'TC-239 the debounce is a cancel-and-reschedule: only the FINAL '
    'navigation position ever gets a tier-2 sweep',
    () async {
      final h = _Harness();
      final items = _items(10);

      // Two navigation events with no event-loop turn in between: the first
      // timer must be cancelled, so its window is never decoded at all.
      h.scheduler.schedule(items, 0, () {});
      h.scheduler.schedule(items, 7, () {});
      await h.pump();

      // Window is +/-kTierTwoRadius (2) around index 7, and the lane starts
      // at its centre: index 7 itself is the one load that may have begun.
      // (Until 2026-08-26 this asserted `contains('a5')` -- true only because
      // the old queue started at the window's low index. a5 is now the LAST
      // of the five, still queued behind a7, which is the intended order:
      // nearest to the selection first.)
      expect(h.loadOrder, ['a7']);
      expect(h.loadOrder, isNot(contains('a0')));
      expect(h.loadOrder, isNot(contains('a1')));
      expect(h.loadOrder, isNot(contains('a2')));
    },
  );

  test(
    'TC-240 the tier-2 queue is sequential: exactly ONE load is in flight at '
    'a time, released in near-to-far order',
    () async {
      final h = _Harness();
      final items = _items(5);

      h.scheduler.schedule(items, 2, () {});
      await h.pump();

      // All five slots are in the +/-2 window and none has a payload, so all
      // five are enqueued -- but only the first may have STARTED.
      //
      // "Index order" until 2026-08-26; the shared serial lane orders by
      // distance from the selection instead (0, +1, -1, +2, -2), so a
      // window centred on index 2 starts a2 and finishes with a0. The
      // SEQUENTIALITY this test pins is unchanged -- one at a time, and the
      // next one only starts when the previous is released.
      expect(h.loadOrder, ['a2']);

      await h.release('a2');
      expect(h.loadOrder, ['a2', 'a3']);

      await h.release('a3');
      expect(h.loadOrder, ['a2', 'a3', 'a1']);

      await h.release('a1');
      await h.release('a4');
      await h.release('a0');
      expect(h.loadOrder, ['a2', 'a3', 'a1', 'a4', 'a0']);
    },
  );

  test(
    'TC-241 the window re-check is INSIDE the queued body: an item the user '
    'has navigated away from is dropped instead of loaded',
    () async {
      final h = _Harness();
      final items = _items(10);

      h.scheduler.schedule(items, 0, () {});
      await h.pump();
      expect(h.loadOrder, ['a0']);

      // The user navigates away while a0's load is still in flight. a1 and a2
      // are already queued behind it, and must NOT be loaded once their turn
      // comes: their position is no longer on screen.
      h.scheduler.schedule(items, 7, () {});
      await h.pump();
      await h.release('a0');

      // The FIRST load after the in-flight one completes is the new
      // selection itself -- the lane re-ranked its pending entries around
      // index 7 instead of draining the queue built for index 0.
      expect(h.loadOrder, ['a0', 'a7']);

      // Drain the rest of the second sweep. a1 and a2 are still pending from
      // the first sweep and get their turn in here; their bodies must skip
      // themselves on the window re-check rather than load.
      for (final id in ['a7', 'a8', 'a6', 'a9', 'a5']) {
        await h.release(id);
      }
      expect(h.loadOrder, ['a0', 'a7', 'a8', 'a6', 'a9', 'a5']);
      expect(h.loadOrder, isNot(contains('a1')));
      expect(h.loadOrder, isNot(contains('a2')));
    },
  );

  test(
    'TC-242 a swept window publishes its encoded payloads to the registry, '
    'and the next sweep evicts the ids that left the window',
    () async {
      final h = _Harness();
      final items = _items(10);
      addTearDown(() => h.registry.clear());

      for (final id in ['a0', 'a1', 'a2', 'a3']) {
        h.payloads[id] = _freshEncodedPayload();
      }

      var loaded = 0;
      final allLoaded = Completer<void>();
      h.scheduler.schedule(items, 1, () {
        loaded++;
        if (loaded == 4 && !allLoaded.isCompleted) allLoaded.complete();
      });
      await allLoaded.future;
      await h.pump();

      // The +/-2 window around index 1 clamps to a0..a3.
      expect(h.registry.keyIds, {'a0', 'a1', 'a2', 'a3'});
      expect(h.registry.isReady('a1'), isTrue);
      // Payload production is never triggered for a slot that already has one.
      expect(h.loadOrder, isEmpty);

      // Navigating far away evicts every tier-2 entry outside the new window.
      h.scheduler.schedule(items, 8, () {});
      await h.pump();
      expect(h.registry.keyIds, isEmpty);
      expect(h.registry.isReady('a1'), isFalse);
    },
  );
}
