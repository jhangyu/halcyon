// Merged (round 4 M2 consolidation) from:
//   tier_two_scheduler_test.dart
//   tier_two_piggyback_handle_test.dart
//   tier_two_publish_dedupe_test.dart
//   tier_two_publish_pacing_test.dart
//   tier_two_publish_race_test.dart
//   tier_two_registry_test.dart
// Each original file's tests are wrapped in a group() named after its
// basename to keep setUp/tearDown scoping and test names intact. Top-level
// helper name collisions across files were resolved with a private
// `_<shortname>` suffix (Rule 2); no test behavior was changed.

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/decode_lane.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/raw_full_res_image.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_registry.dart';
import 'package:halcyon_flutter/services/image_pipeline/tier_two_scheduler.dart';

import '../../support/preload_fixtures.dart';

// ---------------------------------------------------------------------------
// Helpers from tier_two_scheduler_test.dart
// ---------------------------------------------------------------------------

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

  final DecodeLane lane = DecodeLane();
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

/// Like [_Harness], but with a debounce long enough that it CANNOT fire during
/// the test, and a wide lane so every dispatched slot starts instead of queuing
/// behind the first one.
///
/// Both are load-bearing for TC-1180/TC-1181: the whole point of those tests is
/// that a newly band-entering item starts WITHOUT the debounce elapsing, so a
/// zero (or merely short) debounce would make the assertion pass for the wrong
/// reason, and a width-1 lane would hide which slots were dispatched.
class _BandEntryHarness {
  _BandEntryHarness() {
    registry = TierTwoRegistry(currentPayloadFor: (id) => payloads[id]);
    scheduler = TierTwoScheduler(
      registry: registry,
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
      // Ten seconds: far beyond any pump below, so nothing the debounced sweep
      // would do can contribute to what these tests observe.
      navigationDebounce: const Duration(seconds: 10),
    );
  }

  final DecodeLane lane = DecodeLane(width: 5);
  late final TierTwoRegistry registry;
  late final TierTwoScheduler scheduler;
  final Map<String, SourcePayload> payloads = {};
  final List<String> loadOrder = [];
  final Map<String, Completer<void>> inFlight = {};

  Future<void> pump() async {
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers from tier_two_piggyback_handle_test.dart
// ---------------------------------------------------------------------------

PhotoItem _photoItem(String id) =>
    PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);

Future<ui.Image> _image(int w, int h) {
  final completer = Completer<ui.Image>();
  final bytes = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 255);
  ui.decodeImageFromPixels(
    bytes,
    w,
    h,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

({TierTwoScheduler scheduler, TierTwoRegistry registry}) _harness(
  SourcePayload? Function(String) payloadFor,
) {
  final registry = TierTwoRegistry(currentPayloadFor: payloadFor);
  final scheduler = TierTwoScheduler(
    registry: registry,
    lane: DecodeLane(width: 1),
    currentPayloadFor: payloadFor,
    fullSizeProviderFor: (p) => throw StateError('not reached'),
    ensurePayload:
        (item, {required distance, required notifyLoaded, onSerialLane = false}) async {},
    dngDecoder: () => null,
    exifOrientationFor: (id) => 1,
    navigationDebounce: Duration.zero,
  );
  return (scheduler: scheduler, registry: registry);
}

// ---------------------------------------------------------------------------
// Helpers from tier_two_publish_dedupe_test.dart
// ---------------------------------------------------------------------------

/// An ImageStreamCompleter that never emits an image and never errors --
/// deterministically simulates "registration landed, decode still pending"
/// without racing a real (near-instant) engine decode. Same trick as
/// tier_two_registry_test.dart's TC-232, duplicated here rather than shared
/// so this file's ownership stays self-contained.
class _NeverCompletingImageStreamCompleterDedupe extends ImageStreamCompleter {}

/// Records every submission; publishes exempt ones immediately and defers
/// everything else until [drain] -- same shape as the fake pacer in
/// tier_two_publish_pacing_test.dart (TC-907/908), duplicated here rather
/// than shared so this file's ownership stays self-contained.
class _FakePacerDedupe {
  final List<({String id, bool exempt})> submissions = [];
  final List<
      ({
        bool Function() stillValid,
        void Function() publish,
        void Function()? discard,
      })> _queued = [];

  void submit({
    required String id,
    required int rank,
    required bool exempt,
    required bool Function() stillValid,
    required void Function() publish,
    void Function()? discard,
    // R3-WP8: mechanical addition to satisfy PublishPacer's now-required
    // param; this fake does not otherwise use it.
    required int byteCost,
  }) {
    submissions.add((id: id, exempt: exempt));
    if (exempt) {
      if (stillValid()) {
        publish();
      } else {
        discard?.call();
      }
      return;
    }
    _queued.add((stillValid: stillValid, publish: publish, discard: discard));
  }

  void drain() {
    for (final entry in _queued) {
      if (entry.stillValid()) {
        entry.publish();
      } else {
        entry.discard?.call();
      }
    }
    _queued.clear();
  }
}

// ---------------------------------------------------------------------------
// Helpers from tier_two_publish_pacing_test.dart
// ---------------------------------------------------------------------------

/// Records every [TierTwoScheduler] publish submission and defers everything
/// non-exempt until [drain] is called -- standing in for `PublicationPacer`
/// without depending on its concrete type (that class is out of this
/// worker's file ownership this round; only the [PublishPacer] SHAPE is
/// shared).
class _FakePacerPacing {
  final List<({String id, bool exempt})> submissions = [];
  final List<
      ({
        bool Function() stillValid,
        void Function() publish,
        void Function()? discard,
      })> _queued = [];

  void submit({
    required String id,
    required int rank,
    required bool exempt,
    required bool Function() stillValid,
    required void Function() publish,
    void Function()? discard,
    // R3-WP8: mechanical addition to satisfy PublishPacer's now-required
    // param; this fake does not otherwise use it.
    required int byteCost,
  }) {
    submissions.add((id: id, exempt: exempt));
    if (exempt) {
      if (stillValid()) {
        publish();
      } else {
        discard?.call();
      }
      return;
    }
    _queued.add((stillValid: stillValid, publish: publish, discard: discard));
  }

  /// Publishes every queued (non-exempt) entry, mirroring `PublicationPacer`
  /// draining a frame.
  void drain() {
    for (final entry in _queued) {
      if (entry.stillValid()) {
        entry.publish();
      } else {
        entry.discard?.call();
      }
    }
    _queued.clear();
  }
}

PixelPayload _pixelPayloadPacing() =>
    PixelPayload(rgba: Uint8List(1 * 1 * 4), width: 1, height: 1);

/// Pumps the microtask/timer queue until [condition] holds or [maxIters] is
/// reached, instead of a fixed iteration count -- a fixed count of
/// `Future.delayed(Duration.zero)` turns proved flaky when this suite runs
/// alongside its siblings (heavier event-loop load needs more turns for the
/// SAME async chain to settle; observed in this round's own CI-style
/// multi-file run, see docs/logs/2026-09-04/r1-pacer2-verify.txt).
Future<void> _pumpUntilPacing(bool Function() condition, {int maxIters = 200}) async {
  for (var i = 0; i < maxIters && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

// ---------------------------------------------------------------------------
// Helpers from tier_two_publish_race_test.dart
// ---------------------------------------------------------------------------

PixelPayload _pixelPayloadRace() =>
    PixelPayload(rgba: Uint8List(1 * 1 * 4), width: 1, height: 1);

// ---------------------------------------------------------------------------
// Helpers from tier_two_registry_test.dart
// ---------------------------------------------------------------------------

/// An ImageStreamCompleter that never emits an image and never errors --
/// used to deterministically simulate a decode that is PENDING forever,
/// without racing a real (near-instant) engine decode. When pre-inserted into
/// ImageCache under the exact key a real decode would use,
/// ImageCache.putIfAbsent returns this existing entry instead of starting a
/// new decode, so any code path that resolves that provider joins this
/// completer and never observes completion.
class _NeverCompletingImageStreamCompleterRegistry extends ImageStreamCompleter {}

/// Publishes [payload] as an encoded tier-2 entry and waits for the decode
/// listener to fire. Returns the provider, which for MemoryImage IS the
/// ImageCache key.
Future<ImageProvider> _publishAndAwaitRegistry(
  TierTwoRegistry registry,
  String id,
  EncodedPayload payload,
) async {
  final provider = fullSizeProviderFor(payload.bytes);
  final fired = Completer<void>();
  registry.publishEncoded(id, payload, provider, () {
    if (!fired.isCompleted) fired.complete();
  });
  await fired.future;
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('tier_two_scheduler_test.dart', () {
    test(
      'TC-239 the debounce is a cancel-and-reschedule: only the FINAL '
      'navigation position ever gets a tier-2 sweep',
      () async {
        final h = _Harness();
        final items = photoItems(10, idPrefix: 'a', dir: '/tmp');

        // Two navigation events with no event-loop turn in between: the first
        // timer must be cancelled, so its window is never decoded at all.
        h.scheduler.schedule(items, 0, () {});
        h.scheduler.schedule(items, 7, () {});
        await h.pump();

        // Window is the full-resolution band (+/-kFullResolutionBandRadius,
        // i.e. -1..+1) around index 7, and the lane starts at its centre:
        // index 7 itself is the one load that may have begun.
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
        final items = photoItems(5, idPrefix: 'a', dir: '/tmp');

        h.scheduler.schedule(items, 2, () {});
        await h.pump();

        // The three slots in the +/-1 full-resolution band around index 2 are
        // a1..a3 (WP4.2/S3.2 narrowed the band from the forward-biased -1..+3;
        // a4 at distance +2 is now window-resolution-only and is re-promoted
        // from its retained payload if the user steps onto it); none has a
        // payload, so all three are enqueued -- but only the first may have
        // STARTED.
        //
        // "Index order" until 2026-08-26; the shared serial lane orders by
        // distance from the selection instead (0, +1, -1), so a band centred on
        // index 2 starts a2 and finishes with a1. The SEQUENTIALITY this test
        // pins is unchanged -- one at a time, and the next one only starts when
        // the previous is released.
        expect(h.loadOrder, ['a2']);

        await h.release('a2');
        expect(h.loadOrder, ['a2', 'a3']);

        await h.release('a3');
        expect(h.loadOrder, ['a2', 'a3', 'a1']);

        await h.release('a1');
        expect(h.loadOrder, ['a2', 'a3', 'a1']);
        // +2 is outside the full-resolution band: it is never enqueued for a
        // full-size decode at all.
        expect(h.loadOrder, isNot(contains('a4')));
      },
    );

    test(
      'TC-241 the window re-check is INSIDE the queued body: an item the user '
      'has navigated away from is dropped instead of loaded',
      () async {
        final h = _Harness();
        final items = photoItems(10, idPrefix: 'a', dir: '/tmp');

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

        // Drain the rest of the second sweep. Under the +/-1 full-resolution
        // band (WP4.2/S3.2) the sweep at index 7 covers a6..a8. a1 and a2 are
        // still pending from the first sweep and get their turn in here; their
        // bodies must skip themselves on the window re-check rather than load.
        for (final id in ['a7', 'a8', 'a6']) {
          await h.release(id);
        }
        expect(h.loadOrder, ['a0', 'a7', 'a8', 'a6']);
        expect(h.loadOrder, isNot(contains('a1')));
        expect(h.loadOrder, isNot(contains('a2')));
        expect(h.loadOrder, isNot(contains('a5')));
        // +2/+3 are outside the narrowed band and are never swept.
        expect(h.loadOrder, isNot(contains('a9')));
      },
    );

    test(
      'TC-242 a swept window publishes its encoded payloads to the registry, '
      'and the next sweep evicts the ids that left the window',
      () async {
        final h = _Harness();
        final items = photoItems(10, idPrefix: 'a', dir: '/tmp');
        addTearDown(() => h.registry.clear());

        for (final id in ['a0', 'a1', 'a2', 'a3', 'a4']) {
          h.payloads[id] = freshEncodedPayload();
        }

        var loaded = 0;
        final allLoaded = Completer<void>();
        h.scheduler.schedule(items, 1, () {
          loaded++;
          if (loaded == 3 && !allLoaded.isCompleted) allLoaded.complete();
        });
        await allLoaded.future;
        await h.pump();

        // The +/-1 full-resolution band around index 1 is a0..a2 (WP4.2/S3.2).
        // a3 and a4 keep their retained payloads -- they are DEGRADED, not
        // evicted -- but hold no full-resolution ImageCache entry.
        expect(h.registry.keyIds, {'a0', 'a1', 'a2'});
        expect(h.payloads.keys, containsAll(<String>['a3', 'a4']));
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

    // TC-1180 / TC-1181 -- user ruling 2026-09-11 22:00: an item NEWLY entering
    // the +/-kFullResolutionBandRadius band starts decoding immediately rather
    // than waiting out the 250ms navigation debounce
    // (docs/logs/2026-09-11/wp42-latency-regression-diagnosis.md: the debounce
    // was the only tier-2 enqueue point, which cost a 101.5ms -> 253.5ms
    // sequential-navigation median once the band narrowed to +/-1).
    test(
      'TC-1180 an item with a RETAINED payload entering the full-resolution '
      'band is published WITHOUT the navigation debounce elapsing',
      () async {
        final h = _BandEntryHarness();
        final items = photoItems(6, idPrefix: 'a', dir: '/tmp');
        addTearDown(h.scheduler.cancelDebounce);
        addTearDown(() => h.registry.clear());

        // Every slot's payload is already retained -- the -3..+5 retention
        // window is wider than the +/-1 full-resolution band, so this is the
        // ordinary state of a neighbour the user is about to step onto, and it
        // is the state the latency regression was measured in.
        for (final item in items) {
          h.payloads[item.id] = freshEncodedPayload();
        }

        h.scheduler.schedule(items, 2, () {});
        await h.pump();

        // The debounce is 10s and the pump is four zero-duration turns, so the
        // sweep cannot have run: this is the band-entry path's work alone.
        expect(h.registry.keyIds, {'a1', 'a2', 'a3'});
        // isReady needs the ImageStreamListener callback of a REAL engine
        // decode, which the zero-duration pump cannot bound (wp5-gate-diagnosis
        // section 1: the round gate caught exactly this under suite load), so
        // the positive readiness claim polls; the negative claims below stay
        // on the pump, which is what bounds them.
        await until(() => h.registry.isReady('a3'),
            reason: "a3's band-entry publish to become ready");
        expect(h.registry.isReady('a3'), isTrue);
        // The band is not widened by starting earlier.
        expect(h.registry.keyIds, isNot(contains('a0')));
        expect(h.registry.keyIds, isNot(contains('a4')));
        // And the immediate path never produces payloads: a cold slot's load
        // stays the controller's navigation pass and the debounced sweep's
        // business, so nothing is enqueued here.
        expect(h.loadOrder, isEmpty);
      },
    );

    test(
      'TC-1181 a cold (payload-less) band entrant is NOT loaded by the '
      'immediate path, and one-step moves publish only the new entrant',
      () async {
        final h = _BandEntryHarness();
        final items = photoItems(6, idPrefix: 'a', dir: '/tmp');
        addTearDown(h.scheduler.cancelDebounce);
        addTearDown(() => h.registry.clear());

        // a4 has NO payload: it is the cold slot. The rest are retained.
        for (final item in items) {
          if (item.id == 'a4') continue;
          h.payloads[item.id] = freshEncodedPayload();
        }

        h.scheduler.schedule(items, 2, () {});
        await h.pump();
        expect(h.registry.keyIds, {'a1', 'a2', 'a3'});

        // One step forward: the band moves a1..a3 -> a2..a4. a4 is the only
        // entrant, and being cold it must NOT be enqueued from here -- doing so
        // put a second, richer body on the shared serial lane for an id the
        // controller's own navigation pass is already producing.
        h.scheduler.schedule(items, 3, () {});
        await h.pump();
        expect(h.loadOrder, isEmpty);
        // a2/a3 were already in the band and are already published; nothing
        // new lands for them either.
        expect(h.registry.keyIds, {'a1', 'a2', 'a3'});

        // A slot that was already IN the band when its payload landed is not
        // this path's business either -- it is not a new entrant any more, so
        // the immediate path leaves it to the piggyback publish its own load
        // performs and, failing that, to the debounced sweep. Stepping to 4
        // admits a5 (new entrant, retained) and still does not publish a4,
        // whose payload landed while it was already inside the band.
        h.payloads['a4'] = freshEncodedPayload();
        h.scheduler.schedule(items, 4, () {});
        await h.pump();
        expect(h.registry.keyIds, contains('a5'));
        expect(h.registry.keyIds, isNot(contains('a4')));
        expect(h.loadOrder, isEmpty);
      },
    );
  });

  group('tier_two_piggyback_handle_test.dart', () {
    // TC-825 -- a supplied handle is published with ZERO uploads.
    test('a supplied handle is published without decodeImageFromPixels',
        () async {
      final payload = EncodedPayload(Uint8List(4));
      final h = _harness((id) => id == 'a' ? payload : null);
      h.scheduler.updateWindow([_photoItem('a')], 0);
      final image = await _image(4, 4);
      await h.scheduler.publishPiggybackFullRes(
        'a',
        payload,
        (rgba: Uint8List(0), width: 4, height: 4, image: image, releaseNative: null),
        () {},
        distance: 0,
      );
      expect(h.registry.keyIds, contains('a'));
      // The published entry IS the supplied handle: an upload would have
      // produced a different image and left this one to be disposed.
      expect(image.debugDisposed, isFalse);
    });

    // TC-826 -- out of the tier-2 window: dispose, publish nothing.
    test('a stale window disposes the supplied handle', () async {
      final payload = EncodedPayload(Uint8List(4));
      final h = _harness((id) => payload);
      h.scheduler.updateWindow(const [], 0);
      final image = await _image(4, 4);
      await h.scheduler.publishPiggybackFullRes(
        'a',
        payload,
        (rgba: Uint8List(0), width: 4, height: 4, image: image, releaseNative: null),
        () {},
        distance: 0,
      );
      expect(image.debugDisposed, isTrue);
      expect(h.registry.keyIds, isNot(contains('a')));
    });

    // TC-826b -- payload replaced under us.
    test('a replaced payload disposes the supplied handle', () async {
      final published = EncodedPayload(Uint8List(4));
      final current = EncodedPayload(Uint8List(4));
      final h = _harness((id) => current);
      h.scheduler.updateWindow([_photoItem('a')], 0);
      final image = await _image(4, 4);
      await h.scheduler.publishPiggybackFullRes(
        'a',
        published,
        (rgba: Uint8List(0), width: 4, height: 4, image: image, releaseNative: null),
        () {},
        distance: 0,
      );
      expect(image.debugDisposed, isTrue);
      expect(h.registry.keyIds, isNot(contains('a')));
    });

    // TC-825b -- no handle: today's upload path, unchanged.
    test('a null handle still uploads and publishes', () async {
      final payload = EncodedPayload(Uint8List(4));
      final h = _harness((id) => payload);
      h.scheduler.updateWindow([_photoItem('a')], 0);
      await h.scheduler.publishPiggybackFullRes(
        'a',
        payload,
        (rgba: Uint8List(4 * 4 * 4), width: 4, height: 4, image: null, releaseNative: null),
        () {},
        distance: 0,
      );
      expect(h.registry.keyIds, contains('a'));
    });
  });

  group('tier_two_publish_dedupe_test.dart', () {
    // TC-916 / TC-917 / TC-918 / TC-923 / TC-924.
    //
    // Contract deliverable W2 (docs/logs/2026-09-04/remediation-round-contract.md
    // / residual-jank-diagnosis.md #3 and #7):
    //   - a repeat `publishEncoded` for the SAME (id, payload-object) is dropped
    //     as a redundant re-publish (11.1 publishes/id observed, target ~2);
    //   - a NEW payload object (content-version) for the same id still lands --
    //     the tier1 -> full-res upgrade case must not break;
    //   - both TierTwoScheduler call sites that used to call
    //     `TierTwoRegistry.publishEncoded` DIRECTLY now route through the pacer
    //     (148 unpaced publishes observed).

    test(
      'TC-916 a second publishEncoded call for the SAME (id, payload object) '
      'is dropped instead of re-publishing',
      () async {
        final payload = freshEncodedPayload();
        final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);
        addTearDown(registry.clear);

        final firstProvider = fullSizeProviderFor(payload.bytes);
        var firstNotifications = 0;
        registry.publishEncoded(
          'IMG_00',
          payload,
          firstProvider,
          () => firstNotifications++,
        );
        await until(() => firstNotifications == 1,
            reason: 'the first publish lands');
        expect(registry.providerFor('IMG_00'), same(firstProvider));

        // Same id, same payload OBJECT, a fresh (would-be) provider -- this
        // must be dropped: no re-registration, no second notification.
        final secondProvider = fullSizeProviderFor(payload.bytes);
        var secondNotifications = 0;
        registry.publishEncoded(
          'IMG_00',
          payload,
          secondProvider,
          () => secondNotifications++,
        );
        // No completion signal to await for a dropped duplicate -- give the
        // event loop a few turns, then assert it never fired.
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(Duration.zero);
        }

        expect(
          secondNotifications,
          0,
          reason: 'the duplicate publish must not resolve a second listener',
        );
        expect(
          registry.providerFor('IMG_00'),
          same(firstProvider),
          reason: 'the registry entry must still be the FIRST publish\'s '
              'provider -- the duplicate must not overwrite it',
        );
      },
    );

    test(
      'TC-923 a same-payload republish LANDS once the earlier entry has been '
      'evicted from ImageCache underneath (round-2 review BLOCKER-1: eviction '
      'recovery must not be permanently blocked by the dedupe guard)',
      () async {
        final payload = freshEncodedPayload();
        final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);
        addTearDown(registry.clear);

        final firstProvider = fullSizeProviderFor(payload.bytes);
        registry.publishEncoded('IMG_00', payload, firstProvider, () {});
        await until(() => registry.isReady('IMG_00'),
            reason: 'the first publish lands');

        // Simulate LRU eviction pressure: ImageCache drops the entry WITHOUT
        // telling the registry. _sources still holds the same payload object,
        // but isReady must go false (residency check).
        PaintingBinding.instance.imageCache.evict(firstProvider);
        expect(registry.isReady('IMG_00'), isFalse,
            reason: 'sanity check: the entry is no longer resident');

        // The window sweep's recovery path resubmits the SAME payload object
        // to re-populate the cache. This must NOT be dropped as a duplicate --
        // the earlier entry is gone, not still resident.
        final secondProvider = fullSizeProviderFor(payload.bytes);
        var recovered = false;
        registry.publishEncoded(
          'IMG_00',
          payload,
          secondProvider,
          () => recovered = true,
        );
        await until(() => recovered,
            reason: 'the recovery republish for the SAME payload object must '
                'land once the earlier entry is no longer resident');

        expect(registry.isReady('IMG_00'), isTrue);
        expect(registry.providerFor('IMG_00'), same(secondProvider));
      },
    );

    test(
      'TC-924 a same-payload resubmit DURING the pending window (registered, '
      'decode not yet complete, ImageCache entry still resident) is dropped '
      '-- round-2 review re-review S1: residency must be checked with '
      'ImageCache.containsKey, not isReady, or a mid-decode resubmit slips '
      'through',
      () async {
        final payload = freshEncodedPayload();
        final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);
        addTearDown(registry.clear);

        final firstProvider = fullSizeProviderFor(payload.bytes);
        // Deterministically simulate "decode started, not yet finished" (same
        // trick as tier_two_registry_test.dart TC-232): pre-insert a
        // never-completing entry under the SAME key the registry's resolve
        // will land on, so the listener never fires but the registration
        // (obtainKey().then(...)) still completes synchronously.
        final ic = PaintingBinding.instance.imageCache;
        ic.putIfAbsent(firstProvider, () => _NeverCompletingImageStreamCompleterDedupe());
        addTearDown(() => ic.evict(firstProvider));

        var firstNotified = false;
        registry.publishEncoded(
          'IMG_00',
          payload,
          firstProvider,
          () => firstNotified = true,
        );
        // MemoryImage.obtainKey returns a SynchronousFuture, so registration
        // has already run by the next microtask turn.
        await Future<void>.delayed(Duration.zero);

        expect(registry.providerFor('IMG_00'), same(firstProvider),
            reason: 'sanity check: the first publish registered');
        expect(firstNotified, isFalse,
            reason: 'sanity check: the decode never completed -- still pending');
        expect(registry.isReady('IMG_00'), isFalse,
            reason: 'sanity check: isReady is false during the pending window '
                '(same fact BLOCKER 3 documents)');
        expect(ic.containsKey(firstProvider), isTrue,
            reason: 'sanity check: the entry IS still resident -- pending, not '
                'evicted');

        // Resubmitting the SAME payload object while still pending must be
        // dropped: the entry is still resident (containsKey true), even
        // though isReady is false. Using isReady here (instead of
        // containsKey) would have let this through.
        final secondProvider = fullSizeProviderFor(payload.bytes);
        var secondNotified = false;
        registry.publishEncoded(
          'IMG_00',
          payload,
          secondProvider,
          () => secondNotified = true,
        );
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(Duration.zero);
        }

        expect(secondNotified, isFalse,
            reason: 'the mid-pending resubmit must be dropped as a duplicate');
        expect(registry.providerFor('IMG_00'), same(firstProvider),
            reason: 'the registry entry must still be the FIRST publish\'s '
                'provider -- the duplicate must not overwrite it');
      },
    );

    test(
      'TC-917 a NEW content-version (different payload object) for the same '
      'id still lands even right after the first publish',
      () async {
        SourcePayload current = freshEncodedPayload();
        final registry = TierTwoRegistry(currentPayloadFor: (id) => current);
        addTearDown(registry.clear);

        final firstPayload = current as EncodedPayload;
        final firstProvider = fullSizeProviderFor(firstPayload.bytes);
        registry.publishEncoded('IMG_00', firstPayload, firstProvider, () {});
        await until(() => registry.isReady('IMG_00'),
            reason: 'the first publish lands');

        // tier1 -> full-res upgrade (or a re-encode landing): a genuinely NEW
        // payload object for the same id must always be published, never
        // treated as a duplicate.
        final secondPayload = freshEncodedPayload();
        current = secondPayload;
        final secondProvider = fullSizeProviderFor(secondPayload.bytes);
        var secondNotified = false;
        registry.publishEncoded(
          'IMG_00',
          secondPayload,
          secondProvider,
          () => secondNotified = true,
        );
        await until(() => secondNotified,
            reason: 'a new content-version must not be dropped as a duplicate');

        expect(registry.providerFor('IMG_00'), same(secondProvider));
        expect(registry.isReady('IMG_00'), isTrue);
      },
    );

    test(
      'TC-918 publishEncoded now goes through the paced path: a non-selected '
      'item\'s encoded publish does not land until the pacer drains',
      () async {
        final payloads = <String, SourcePayload>{
          'a0': freshEncodedPayload(),
          'a1': freshEncodedPayload(),
        };
        final registry = TierTwoRegistry(currentPayloadFor: (id) => payloads[id]);
        addTearDown(registry.clear);
        final pacer = _FakePacerDedupe();

        final scheduler = TierTwoScheduler(
          registry: registry,
          lane: DecodeLane(width: 2),
          currentPayloadFor: (id) => payloads[id],
          fullSizeProviderFor: (p) =>
              fullSizeProviderFor((p as EncodedPayload).bytes),
          ensurePayload:
              (item, {required int distance, required VoidCallback? notifyLoaded, bool onSerialLane = false}) async {},
          dngDecoder: () => null,
          exifOrientationFor: (id) => 1,
          navigationDebounce: Duration.zero,
          publishPacer: pacer.submit,
        );
        addTearDown(scheduler.cancelDebounce);

        // Selection is index 1 ('a1'); 'a0' is a neighbour at distance -1, both
        // already have an EncodedPayload so _decodeWindow's catch-up loop
        // publishes both without any FFI decode involved.
        final items = [
          PhotoItem(id: 'a0', files: [File('/tmp/a0.jpg')]),
          PhotoItem(id: 'a1', files: [File('/tmp/a1.jpg')]),
        ];
        scheduler.updateWindow(items, 1);
        scheduler.schedule(items, 1, () {});

        await until(
          () =>
              pacer.submissions.any((s) => s.id == 'a0') &&
              pacer.submissions.any((s) => s.id == 'a1'),
          reason: 'both encoded publishes reach the pacer',
        );

        final a0Submission = pacer.submissions.firstWhere((s) => s.id == 'a0');
        final a1Submission = pacer.submissions.firstWhere((s) => s.id == 'a1');
        expect(a0Submission.exempt, isFalse,
            reason: 'a0 is not the selected item -- publishEncoded must be '
                'PACED for it, not sent straight to the registry');
        expect(a1Submission.exempt, isTrue,
            reason: 'a1 (distance 0) is the selected item, exempt from pacing');

        await until(() => registry.isReady('a1'),
            reason: 'the selected item\'s publish is exempt and lands immediately');
        expect(
          registry.isReady('a0'),
          isFalse,
          reason: 'the non-selected encoded publish must not land '
              'synchronously -- it is queued in the (fake) pacer',
        );

        pacer.drain();
        await until(() => registry.isReady('a0'),
            reason: 'draining the pacer publishes the queued encoded entry');
      },
    );
  });

  group('tier_two_publish_pacing_test.dart', () {
    // TC-907 / TC-908.
    //
    // Contract deliverable 2 (docs/logs/2026-09-04/pacer-followup-contract.md):
    // TierTwoRegistry.publishFullRes must no longer be reachable from
    // TierTwoScheduler without going through a pacing seam. These tests drive
    // TierTwoScheduler with a fake PublishPacer that records every submission
    // and defers non-exempt ones, asserting:
    //   (a) a non-selected item's full-res publish does NOT land synchronously
    //       on decode completion (exempt: false, and the registry has no entry
    //       until the fake pacer is drained);
    //   (b) the selected item's full-res publish is exempt (never queued), so it
    //       is never starved by the pacer.

    test(
      'TC-907 a non-selected full-res upgrade does not land synchronously; '
      'draining the pacer publishes it',
      () async {
        final payloads = <String, SourcePayload>{
          'a0': _pixelPayloadPacing(),
          'a1': _pixelPayloadPacing(),
        };
        final registry = TierTwoRegistry(currentPayloadFor: (id) => payloads[id]);
        addTearDown(registry.clear);
        final pacer = _FakePacerPacing();

        final decodeGate = <String, Completer<void>>{};
        final scheduler = TierTwoScheduler(
          registry: registry,
          lane: DecodeLane(width: 2),
          currentPayloadFor: (id) => payloads[id],
          fullSizeProviderFor: (p) => throw StateError('not exercised here'),
          ensurePayload:
              (item, {required int distance, required VoidCallback? notifyLoaded, bool onSerialLane = false}) async {},
          dngDecoder: (() {
            Future<DecodedRgba> decode(String path) async {
              final id = path.split('/').last.split('.').first;
              await (decodeGate[id] ??= Completer<void>()).future;
              return DecodedRgba(rgba: Uint8List(1 * 1 * 4), width: 1, height: 1);
            }

            return () => decode;
          })(),
          exifOrientationFor: (id) => 1,
          navigationDebounce: Duration.zero,
          publishPacer: pacer.submit,
        );
        addTearDown(scheduler.cancelDebounce);

        // Selection is index 1 ('a1'); 'a0' is a neighbour at distance -1.
        final items = [
          PhotoItem(id: 'a0', files: [File('/tmp/a0.dng')]),
          PhotoItem(id: 'a1', files: [File('/tmp/a1.dng')]),
        ];
        scheduler.updateWindow(items, 1);
        scheduler.schedule(items, 1, () {});

        // Both decodes must be in flight (lane width 2) before releasing them.
        await _pumpUntilPacing(
          () => decodeGate.containsKey('a0') && decodeGate.containsKey('a1'),
        );
        decodeGate['a0']!.complete();
        decodeGate['a1']!.complete();
        await _pumpUntilPacing(
          () =>
              pacer.submissions.any((s) => s.id == 'a0') &&
              pacer.submissions.any((s) => s.id == 'a1'),
        );

        final a0Submission =
            pacer.submissions.firstWhere((s) => s.id == 'a0');
        final a1Submission =
            pacer.submissions.firstWhere((s) => s.id == 'a1');
        expect(a0Submission.exempt, isFalse,
            reason: 'a0 is not the selected item');
        expect(a1Submission.exempt, isTrue,
            reason: 'a1 (distance 0) is the selected item');

        // The non-selected publish must NOT have landed synchronously: the
        // registry has no ready entry for a0 until the pacer is drained.
        expect(registry.isReady('a0'), isFalse);
        // The selected item's publish is exempt, so it lands immediately and
        // is never starved.
        expect(registry.isReady('a1'), isTrue);

        pacer.drain();
        expect(registry.isReady('a0'), isTrue,
            reason: 'draining the pacer publishes the queued entry');
      },
    );

    test(
      'TC-908 a paced publish re-checks staleness at drain time: a payload '
      'replaced before drain disposes the image instead of caching it',
      () async {
        final payload = _pixelPayloadPacing();
        final payloads = <String, SourcePayload>{'a0': payload};
        final registry = TierTwoRegistry(currentPayloadFor: (id) => payloads[id]);
        addTearDown(registry.clear);
        final pacer = _FakePacerPacing();

        final decodeGate = Completer<void>();
        var decoderCalls = 0;
        final scheduler = TierTwoScheduler(
          registry: registry,
          lane: DecodeLane(width: 1),
          currentPayloadFor: (id) => payloads[id],
          fullSizeProviderFor: (p) => throw StateError('not exercised here'),
          ensurePayload:
              (item, {required int distance, required VoidCallback? notifyLoaded, bool onSerialLane = false}) async {},
          dngDecoder: (() {
            Future<DecodedRgba> decode(String path) async {
              decoderCalls++;
              await decodeGate.future;
              return DecodedRgba(rgba: Uint8List(1 * 1 * 4), width: 1, height: 1);
            }

            return () => decode;
          })(),
          exifOrientationFor: (id) => 1,
          navigationDebounce: Duration.zero,
          publishPacer: pacer.submit,
        );
        addTearDown(scheduler.cancelDebounce);

        // Selection at index 1, 'a0' at distance -1: non-exempt, gets queued.
        final items = [
          PhotoItem(id: 'a0', files: [File('/tmp/a0.dng')]),
          PhotoItem(id: 'x', files: [File('/tmp/x.dng')]),
        ];
        scheduler.updateWindow(items, 1);
        scheduler.schedule(items, 1, () {});
        // Let the debounce fire and the upgrade reach its held decode.
        await _pumpUntilPacing(() => decoderCalls > 0);
        decodeGate.complete();
        await _pumpUntilPacing(() => pacer.submissions.any((s) => s.id == 'a0' && !s.exempt));

        expect(pacer.submissions.any((s) => s.id == 'a0' && !s.exempt), isTrue);
        expect(registry.isReady('a0'), isFalse, reason: 'still queued');

        // The payload is replaced BEFORE the pacer drains.
        payloads['a0'] = _pixelPayloadPacing();

        pacer.drain();
        expect(registry.isReady('a0'), isFalse,
            reason: 'the queued image was for the OLD payload object');
      },
    );
  });

  group('tier_two_publish_race_test.dart', () {
    // TC-381a / TC-381b (provisional numbers -- re-verify against the SOP register
    // at merge). Defect B from docs/logs/2026-08-30/lane-race-arch-verdict.md §1.B:
    // every caller checks `hasFullResEntryFor` BEFORE its decode await, and the
    // post-await re-check validates window + payload identity but NOT entry
    // existence. Whichever publisher lands second overwrites `_keys[id]`, and the
    // displaced RawFullResImage's full-resolution ui.Image is never disposed.

    test(
      'TC-381a publishFullRes is first-writer-wins: the loser is disposed, not '
      'leaked, and the registered provider never changes',
      () async {
        final payload = _pixelPayloadRace();
        final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);
        addTearDown(registry.clear);

        final winner = await tinyImage();
        final loser = await tinyImage();

        var winnerNotifies = 0;
        var loserNotifies = 0;

        registry.publishFullRes('a0', payload, winner, () => winnerNotifies++);
        final firstProvider = registry.providerFor('a0');
        expect(firstProvider, isNotNull);

        // The second publisher for the SAME id and the SAME payload object --
        // exactly what the piggyback/upgrade race produces.
        registry.publishFullRes('a0', payload, loser, () => loserNotifies++);

        expect(
          identical(registry.providerFor('a0'), firstProvider),
          isTrue,
          reason: 'first writer wins: its live resolve/listener chain stands',
        );
        expect(
          loser.debugDisposed,
          isTrue,
          reason:
              'the surplus decode product must be released here; nothing else '
              'holds a reference to it, so otherwise it leaks ~91MiB',
        );
        expect(
          winner.debugDisposed,
          isFalse,
          reason: 'the winner is owned by the ImageCache entry and stays alive',
        );
        expect(
          loserNotifies,
          0,
          reason: 'the first writer owns the notification for this entry',
        );

        // Let the winner's listener fire, so teardown is not racing a pending
        // decode. (The value is not asserted; TC-231.. cover readiness.)
        for (var i = 0; i < 4; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(winnerNotifies, greaterThanOrEqualTo(0));
      },
    );

    test(
      'TC-381b a piggyback publish landing during an upgrade decode is not '
      'displaced by that upgrade (decode lane width 2)',
      () async {
        final payload = _pixelPayloadRace();
        final payloads = <String, SourcePayload>{'a0': payload};
        final registry = TierTwoRegistry(
          currentPayloadFor: (id) => payloads[id],
        );
        addTearDown(registry.clear);

        // The upgrade's FFI decode, held open so the piggyback can land inside
        // the gap between the upgrade's pre-await existence check and its
        // publish -- the exact window the defect lives in.
        final decodeGate = Completer<void>();
        var decoderCalls = 0;

        final scheduler = TierTwoScheduler(
          registry: registry,
          lane: DecodeLane(width: 2),
          currentPayloadFor: (id) => payloads[id],
          fullSizeProviderFor: (p) => throw StateError('not exercised here'),
          ensurePayload:
              (
                item, {
                required int distance,
                required VoidCallback? notifyLoaded,
                bool onSerialLane = false,
              }) async {
                // The payload is already retained; this is the catch-up case.
              },
          dngDecoder: (() {
            Future<DecodedRgba> decode(String path) async {
              decoderCalls++;
              await decodeGate.future;
              return DecodedRgba(rgba: Uint8List(1 * 1 * 4), width: 1, height: 1);
            }

            return () => decode;
          })(),
          exifOrientationFor: (id) => 1,
          navigationDebounce: Duration.zero,
        );
        addTearDown(scheduler.cancelDebounce);

        final items = List.generate(
          4,
          (i) => PhotoItem(id: 'a$i', files: [File('/tmp/a$i.dng')]),
        );

        scheduler.updateWindow(items, 0);
        scheduler.schedule(items, 0, () {});

        // Let the debounce fire and the upgrade reach its held decode.
        for (var i = 0; i < 8; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(decoderCalls, 1, reason: 'the catch-up upgrade decode started');

        // The piggyback publisher lands WHILE the upgrade decode is held.
        await scheduler.publishPiggybackFullRes(
          'a0',
          payload,
          (rgba: Uint8List(1 * 1 * 4), width: 1, height: 1, image: null, releaseNative: null),
          () {},
          distance: 0,
        );
        final piggybackProvider = registry.providerFor('a0');
        expect(piggybackProvider, isNotNull);

        // Release the upgrade: its post-await re-check passes (same window,
        // same payload object), so it reaches publishFullRes.
        decodeGate.complete();
        for (var i = 0; i < 8; i++) {
          await Future<void>.delayed(Duration.zero);
        }

        expect(
          identical(registry.providerFor('a0'), piggybackProvider),
          isTrue,
          reason:
              'the late upgrade must not displace the live entry; the displaced '
              'RawFullResImage would hold a full-resolution ui.Image nothing '
              'can ever evict or dispose',
        );
        expect(registry.keyIds, {'a0'});
      },
    );

    test(
      'TC-384 (provisional) inline chained upgrade and queued catch-up upgrade '
      'for the SAME id do not both run the FFI decode (decode lane width 2, '
      'S-1: check-then-act-across-await, third instance)',
      () async {
        final payload = _pixelPayloadRace();
        // Starts with no payload for 'a0' -- the first decodeWindow pass takes
        // the inline chained-upgrade path (`_enqueueLoad` ->
        // `_runLoadAndChainTierTwo` -> inline `_upgradeFullRes`) under lane key
        // (payload, 'a0'). `ensurePayload` below lands the payload synchronously
        // as its side effect, so a SECOND schedule() pass -- modelling the
        // window being revisited while the first upgrade is still in flight --
        // now sees a non-null payload and takes the queued catch-up path
        // (`_enqueueFullResUpgrade` -> queued `_upgradeFullRes`) under the
        // DIFFERENT lane key (fullRes, 'a0'). DecodeLane's key-dedup cannot
        // collapse these two different keys for the same photo id, so at lane
        // width 2 both reach `_upgradeFullRes` before either has published.
        final payloads = <String, SourcePayload>{};
        final registry = TierTwoRegistry(
          currentPayloadFor: (id) => payloads[id],
        );
        addTearDown(registry.clear);

        var decoderCalls = 0;
        final decodeGate = Completer<void>();

        final scheduler = TierTwoScheduler(
          registry: registry,
          lane: DecodeLane(width: 2),
          currentPayloadFor: (id) => payloads[id],
          fullSizeProviderFor: (p) => throw StateError('not exercised here'),
          ensurePayload:
              (
                item, {
                required int distance,
                required VoidCallback? notifyLoaded,
                bool onSerialLane = false,
              }) async {
                // The load "lands" the payload as its side effect, same object
                // identity every time so the post-await identity checks pass.
                payloads[item.id] = payload;
              },
          dngDecoder: (() {
            Future<DecodedRgba> decode(String path) async {
              decoderCalls++;
              await decodeGate.future;
              return DecodedRgba(rgba: Uint8List(1 * 1 * 4), width: 1, height: 1);
            }

            return () => decode;
          })(),
          exifOrientationFor: (id) => 1,
          navigationDebounce: Duration.zero,
        );
        addTearDown(scheduler.cancelDebounce);

        // A single-item list: this keeps the -1..+3 window to exactly {'a0'},
        // so decoderCalls below counts only the id under test and cannot be
        // inflated by neighbouring items' independent (non-racing) upgrades.
        final items = [PhotoItem(id: 'a0', files: [File('/tmp/a0.dng')])];

        scheduler.updateWindow(items, 0);
        scheduler.schedule(items, 0, () {});

        // Let the debounce fire, the inline chained load run, ensurePayload
        // land the payload, and the inline upgrade reach its held decode.
        for (var i = 0; i < 8; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(
          decoderCalls,
          1,
          reason: 'the inline chained upgrade started its FFI decode',
        );

        // Second pass over the SAME window: the payload is now non-null, so
        // this item is collected as a catch-up upgrade and queued under the
        // DIFFERENT lane key -- exactly the S-1 shape.
        scheduler.schedule(items, 0, () {});
        for (var i = 0; i < 8; i++) {
          await Future<void>.delayed(Duration.zero);
        }

        expect(
          decoderCalls,
          1,
          reason:
              'the queued catch-up upgrade must be turned away by the '
              'in-flight claim, not run a second duplicate FFI decode for the '
              'same id',
        );

        decodeGate.complete();
        for (var i = 0; i < 8; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(registry.keyIds, {'a0'});
      },
    );
  });

  group('tier_two_registry_test.dart', () {
    // Tests below use plain test(), never testWidgets(): the publish paths await
    // real engine futures (decodeImageFromPixels, MemoryImage decode), which
    // hang forever inside testWidgets' FakeAsync zone
    // (see test/image_preload_controller_test.dart:694-698).

    test('TC-231 isReady is false when nothing has been registered', () {
      final payload = freshEncodedPayload();
      final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);

      expect(registry.isReady('IMG_00'), isFalse);
      expect(registry.keyIds, isEmpty);
      expect(registry.providerFor('IMG_00'), isNull);
      expect(registry.fullResProviderFor('IMG_00'), isNull);
    });

    test('TC-232 isReady is false while the entry is PENDING, not just missing', () async {
      final payload = freshEncodedPayload();
      final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);
      final provider = fullSizeProviderFor(payload.bytes);

      // Deterministically simulate "decode started, not yet finished":
      // pre-insert a never-completing entry under the SAME key the registry's
      // resolve will land on. MemoryImage is its own key, so `provider` IS it.
      final ic = PaintingBinding.instance.imageCache;
      ic.putIfAbsent(provider, () => _NeverCompletingImageStreamCompleterRegistry());
      addTearDown(() => ic.evict(provider));

      var notified = false;
      registry.publishEncoded('IMG_00', payload, provider, () => notified = true);
      // MemoryImage.obtainKey returns a SynchronousFuture, so the key/source
      // registration has already run by this line.
      await Future<void>.delayed(Duration.zero);

      expect(
        ic.containsKey(provider),
        isTrue,
        reason: 'sanity check: the PENDING entry is present in ImageCache -- '
            'this is the fact BLOCKER 3 showed containsKey alone cannot '
            'distinguish from "decode finished"',
      );
      expect(registry.keyIds, contains('IMG_00'));
      expect(notified, isFalse);
      expect(
        registry.isReady('IMG_00'),
        isFalse,
        reason: 'the decode never completed -- isReady must not report true '
            'just because ImageCache.containsKey is true for a pending entry',
      );
    });

    test('TC-233 isReady is true once the decode listener has fired', () async {
      final payload = freshEncodedPayload();
      final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);
      addTearDown(registry.clear);

      final provider = await _publishAndAwaitRegistry(registry, 'IMG_00', payload);

      expect(PaintingBinding.instance.imageCache.containsKey(provider), isTrue);
      expect(registry.keyIds, {'IMG_00'});
      expect(registry.providerFor('IMG_00'), same(provider));
      expect(
        registry.isReady('IMG_00'),
        isTrue,
        reason: 'all four terms hold: listener fired, key registered, source is '
            'the current payload, entry resident',
      );
    });

    test(
        'TC-385 fullResProviderFor serves the ENCODED family through the '
        'display-path getter, not just RawFullResImage (2026-08-30 root-cause '
        'fix, tier2-rootcause.md)', () async {
      final payload = freshEncodedPayload();
      final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);
      addTearDown(registry.clear);

      final provider = await _publishAndAwaitRegistry(registry, 'IMG_00', payload);

      expect(registry.isReady('IMG_00'), isTrue);
      expect(
        registry.fullResProviderFor('IMG_00'),
        same(provider),
        reason: 'the display path (AppState.displayProvider ->'
            ' fullResProviderFor) must serve an encoded-payload tier-2 entry, '
            'not just a RawFullResImage one -- the old `key is RawFullResImage` '
            'filter silently dropped this whole family, so the view fell back '
            'to tier-1 forever for every re-encoded RAW/JPG item',
      );
    });

    test('TC-234 isReady goes false when the payload object is replaced', () async {
      final original = freshEncodedPayload();
      // The BLOCKER-1 scenario as a one-line closure swap. Reaching this through
      // the controller needs a 10-step navigation excursion plus two 350ms
      // debounce sleeps (image_preload_controller_test.dart:526-624).
      SourcePayload current = original;
      final registry = TierTwoRegistry(currentPayloadFor: (id) => current);
      addTearDown(registry.clear);

      await _publishAndAwaitRegistry(registry, 'IMG_00', original);
      expect(registry.isReady('IMG_00'), isTrue);

      // The item left the retention window and came back with a NEW payload
      // object; the id-keyed bookkeeping still describes the OLD one.
      final replacement = freshEncodedPayload();
      expect(identical(original, replacement), isFalse);
      current = replacement;

      expect(
        registry.isReady('IMG_00'),
        isFalse,
        reason: 'the registered entry was decoded for a payload that is no '
            'longer current -- stale readiness (round-2 BLOCKER 1)',
      );
      expect(
        registry.fullResProviderFor('IMG_00'),
        isNull,
        reason: 'every read gated on readiness must go null together',
      );
    });

    test('TC-235 isReady goes false when the ImageCache entry is evicted underneath', () async {
      final payload = freshEncodedPayload();
      final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);
      addTearDown(registry.clear);

      final provider = await _publishAndAwaitRegistry(registry, 'IMG_00', payload);
      expect(registry.isReady('IMG_00'), isTrue);

      // Someone else's cache pressure (or a tier-1 sweep) dropped the entry.
      // The bookkeeping is untouched -- only residency changed.
      PaintingBinding.instance.imageCache.evict(provider);

      expect(registry.keyIds, contains('IMG_00'));
      expect(
        registry.isReady('IMG_00'),
        isFalse,
        reason: 'readiness is re-derived at read time against ImageCache '
            'residency, not cached in the ready flag',
      );
    });

    test('TC-236 hasFullResEntryFor is true BEFORE the ready flag fires (AC-M5-4)', () async {
      final payload = PixelPayload(rgba: Uint8List(4), width: 1, height: 1);
      final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);
      addTearDown(registry.clear);

      // RawFullResImage equality is identical(payloadIdentity) + width + height,
      // so this key is == the one publishFullRes is about to build. Pre-inserting
      // a never-completing entry under it makes the publish resolve join a
      // pending entry, so its listener never fires.
      final pendingKey = RawFullResImage(
        payloadIdentity: payload,
        width: 1,
        height: 1,
        image: await tinyImage(),
      );
      final ic = PaintingBinding.instance.imageCache;
      ic.putIfAbsent(pendingKey, () => _NeverCompletingImageStreamCompleterRegistry());
      addTearDown(() => ic.evict(pendingKey));

      var notified = false;
      registry.publishFullRes(
        'IMG_00',
        payload,
        await tinyImage(),
        () => notified = true,
      );

      expect(notified, isFalse);
      expect(
        registry.isReady('IMG_00'),
        isFalse,
        reason: 'the full-res decode has not been delivered yet',
      );
      expect(
        registry.hasFullResEntryFor('IMG_00', payload),
        isTrue,
        reason: 'registration is synchronous and this is the question that '
            'decides whether to spend an FFI decode -- asking isReady here '
            'would buy a SECOND decode for an upgrade already in hand, which '
            'is exactly what AC-M5-4 forbids',
      );
      expect(
        registry.hasFullResEntryFor('IMG_00', freshEncodedPayload()),
        isFalse,
        reason: 'the entry belongs to one payload object, not to the id',
      );
    });

    test('TC-237 the full-res failure memo is per payload object, not per id', () {
      final original = freshEncodedPayload();
      SourcePayload current = original;
      final registry = TierTwoRegistry(currentPayloadFor: (id) => current);

      expect(registry.hasFullResFailure('IMG_00', original), isFalse);

      registry.markFullResFailure('IMG_00', original);
      expect(
        registry.hasFullResFailure('IMG_00', original),
        isTrue,
        reason: 'a failed upgrade must not be re-bought on every 250ms settle',
      );

      // The item left the retention window and came back: NEW payload object,
      // so the memo must not apply and the upgrade may be tried once more
      // (design §2.5 -- a failed upgrade is not a permanent miss).
      final replacement = freshEncodedPayload();
      current = replacement;
      expect(registry.hasFullResFailure('IMG_00', replacement), isFalse);

      // ...and it is not a permanent miss for the id either.
      expect(registry.hasFullResFailure('IMG_01', original), isFalse);
    });

    test('TC-238 evict drops one id and clear drops every id', () async {
      final payloadA = freshEncodedPayload();
      final payloadB = freshEncodedPayload();
      final byId = {'IMG_00': payloadA, 'IMG_01': payloadB};
      final registry = TierTwoRegistry(currentPayloadFor: (id) => byId[id]);
      addTearDown(registry.clear);

      final providerA = await _publishAndAwaitRegistry(registry, 'IMG_00', payloadA);
      final providerB = await _publishAndAwaitRegistry(registry, 'IMG_01', payloadB);
      expect(registry.keyIds, {'IMG_00', 'IMG_01'});

      final ic = PaintingBinding.instance.imageCache;
      registry.evict('IMG_00');

      expect(registry.keyIds, {'IMG_01'});
      expect(registry.providerFor('IMG_00'), isNull);
      expect(registry.isReady('IMG_00'), isFalse);
      expect(
        ic.containsKey(providerA),
        isFalse,
        reason: 'evict must drop the ImageCache entry as well as the bookkeeping',
      );
      expect(
        registry.isReady('IMG_01'),
        isTrue,
        reason: 'evict is per id -- it must not disturb its neighbours',
      );

      registry.clear();

      expect(registry.keyIds, isEmpty);
      expect(registry.isReady('IMG_01'), isFalse);
      expect(ic.containsKey(providerB), isFalse);
    });

    test(
      'TC-655 hasFullResEntryFor does not filter by provider type (F6, AC8)',
      () async {
        final payload = PixelPayload(rgba: Uint8List(4), width: 1, height: 1);
        final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);
        addTearDown(registry.clear);

        // Register a NON-RawFullResImage entry (the encoded-payload family) as
        // the tier-2 key for this id/payload pair. The old implementation
        // guarded with `_keys[id] is RawFullResImage`, so it would report
        // "no entry" here even though [id] already has an entry for exactly
        // this payload object -- the guard this test pins is that the answer
        // is driven by payload identity alone, matching the doc comment's
        // "the entry belongs to one payload object, not to the id".
        final provider = fullSizeProviderFor(Uint8List.fromList(tinyPngBytes));
        var notified = false;
        registry.publishEncoded(
          'IMG_00',
          payload,
          provider,
          () => notified = true,
        );
        await Future<void>.delayed(Duration.zero);

        expect(
          registry.providerFor('IMG_00'),
          isNot(isA<RawFullResImage>()),
          reason: 'sanity check: the registered entry is the non-RawFullResImage'
              ' kind the old type filter would have rejected',
        );
        expect(
          registry.hasFullResEntryFor('IMG_00', payload),
          isTrue,
          reason: 'an id/payload match is an entry, regardless of provider '
              'runtime type -- the type filter was dropped (F6)',
        );

        // notified is unused beyond keeping the listener referenced; avoid an
        // "unused variable" lint without asserting on decode timing here.
        expect(notified, isFalse);
      },
    );

    test(
      'TC-656 publishEncoded evicts the replaced key before overwriting (F6, AC8)',
      () async {
        final payload = freshEncodedPayload();
        final registry = TierTwoRegistry(currentPayloadFor: (id) => payload);
        addTearDown(registry.clear);

        final ic = PaintingBinding.instance.imageCache;

        final firstProvider = await _publishAndAwaitRegistry(registry, 'IMG_00', payload);
        expect(ic.containsKey(firstProvider), isTrue);

        // A second publishEncoded call for the SAME id with a DIFFERENT
        // provider (e.g. a re-encode landing after the first one) must not
        // orphan the first entry: the old implementation only ever wrote
        // `_keys[id] = key`, so `firstProvider` became unreachable bookkeeping
        // that nothing could ever evict -- a permanent ImageCache leak.
        final secondPayload = freshEncodedPayload();
        final secondProvider = await _publishAndAwaitRegistry(
          registry,
          'IMG_00',
          secondPayload,
        );

        expect(
          ic.containsKey(firstProvider),
          isFalse,
          reason: 'the replaced key must be evicted from ImageCache, not just '
              'overwritten in the registry\'s own bookkeeping (F6 orphan leak)',
        );
        expect(registry.providerFor('IMG_00'), same(secondProvider));
      },
    );
  });
}
