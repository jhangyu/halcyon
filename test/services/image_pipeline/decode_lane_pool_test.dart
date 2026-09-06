import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ceyx/ceyx.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/perf/perf_log.dart';
import 'package:halcyon_flutter/services/image_pipeline/decode_lane.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_service.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/retention_policy.dart';
import 'package:halcyon_flutter/services/image_pipeline/stage_widths.dart';

import '../../support/preload_fixtures.dart';

/// A body that reports when it starts, and finishes when its completer does.
({Future<void> Function() body, Completer<void> gate, List<String> starts})
    tracked(String name, List<String> starts) {
  final gate = Completer<void>();
  return (
    body: () async {
      starts.add(name);
      await gate.future;
    },
    gate: gate,
    starts: starts,
  );
}

void main() {
  group('decode_lane_test.dart', () {
    test('TC-340 width 1 runs one body at a time', () async {
      final lane = DecodeLane(width: 1);
      var inFlight = 0;
      var maxInFlight = 0;
      for (var i = 0; i < 5; i++) {
        lane.enqueue(
          (LaneTaskKind.payload, 'p$i'),
          priority: i,
          body: () async {
            inFlight++;
            maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
            await Future<void>.delayed(const Duration(milliseconds: 5));
            inFlight--;
          },
        );
      }
      while (lane.pendingCount > 0 || lane.isBusy) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(maxInFlight, 1);
    });

    test('TC-341 width 3 runs up to three bodies at a time', () async {
      final lane = DecodeLane(width: 3);
      var inFlight = 0;
      var maxInFlight = 0;
      for (var i = 0; i < 9; i++) {
        lane.enqueue(
          (LaneTaskKind.payload, 'p$i'),
          priority: i,
          body: () async {
            inFlight++;
            maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
            await Future<void>.delayed(const Duration(milliseconds: 5));
            inFlight--;
          },
        );
      }
      while (lane.pendingCount > 0 || lane.isBusy) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(maxInFlight, 3);
    });

    test('TC-342 start order is global priority order, whatever the width',
        () async {
      final lane = DecodeLane(width: 3);
      final starts = <String>[];
      // Enqueued worst-first, in one synchronous burst.
      for (final entry in [('far', 9), ('mid', 5), ('near', 0)]) {
        lane.enqueue(
          (LaneTaskKind.payload, entry.$1),
          priority: entry.$2,
          body: () async {
            starts.add(entry.$1);
            await Future<void>.delayed(const Duration(milliseconds: 5));
          },
        );
      }
      while (lane.pendingCount > 0 || lane.isBusy) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(starts, ['near', 'mid', 'far']);
    });

    test('TC-343 no body starts synchronously inside enqueue', () async {
      final lane = DecodeLane(width: 3);
      var started = false;
      lane.enqueue(
        (LaneTaskKind.payload, 'a'),
        priority: 0,
        body: () async => started = true,
      );
      expect(started, isFalse, reason: 'the pump is a microtask, not inline');
      await Future<void>.delayed(Duration.zero);
      expect(started, isTrue);
    });

    test('TC-344 a re-enqueued pending key is reprioritised, not duplicated',
        () async {
      final lane = DecodeLane(width: 1);
      final starts = <String>[];
      final block = Completer<void>();
      lane.enqueue(
        (LaneTaskKind.payload, 'blocker'),
        priority: 0,
        body: () async {
          starts.add('blocker');
          await block.future;
        },
      );
      await Future<void>.delayed(Duration.zero);
      lane.enqueue(
        (LaneTaskKind.payload, 'x'),
        priority: 9,
        body: () async => starts.add('x'),
      );
      lane.enqueue(
        (LaneTaskKind.payload, 'y'),
        priority: 5,
        body: () async => starts.add('y'),
      );
      lane.enqueue(
        (LaneTaskKind.payload, 'x'),
        priority: 1,
        body: () async => starts.add('x'),
      );
      expect(lane.pendingCount, 2, reason: 'x replaced its own entry');
      block.complete();
      while (lane.pendingCount > 0 || lane.isBusy) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(starts, ['blocker', 'x', 'y']);
    });

    test('TC-345 a throwing body does not wedge any runner', () async {
      final lane = DecodeLane(width: 2);
      final done = <String>[];
      lane.enqueue(
        (LaneTaskKind.payload, 'bad'),
        priority: 0,
        body: () async => throw StateError('boom'),
      );
      lane.enqueue(
        (LaneTaskKind.payload, 'good'),
        priority: 1,
        body: () async => done.add('good'),
      );
      while (lane.pendingCount > 0 || lane.isBusy) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(done, ['good']);
    });

    test('TC-346 widening at runtime starts pending work; narrowing never '
        'pre-empts an in-flight body', () async {
      final lane = DecodeLane(width: 1);
      var inFlight = 0;
      var maxInFlight = 0;
      final gate = Completer<void>();
      for (var i = 0; i < 4; i++) {
        lane.enqueue(
          (LaneTaskKind.payload, 'p$i'),
          priority: i,
          body: () async {
            inFlight++;
            maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
            await gate.future;
            inFlight--;
          },
        );
      }
      await Future<void>.delayed(Duration.zero);
      expect(inFlight, 1);
      lane.width = 3;
      await Future<void>.delayed(Duration.zero);
      expect(inFlight, 3, reason: 'widening fills the new slots');
      lane.width = 1;
      expect(inFlight, 3, reason: 'narrowing cannot cancel an FFI decode');
      gate.complete();
      while (lane.pendingCount > 0 || lane.isBusy) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(maxInFlight, 3);
    });
  });

  group('decode_pool_killswitch_test.dart', () {
    test('TC-944: the define parses the documented spellings', () {
      // Not supplied -> pool ON. This is the shipped default.
      expect(decodePoolEnabledFor(''), isTrue);
      expect(kDecodePoolEnabled, isTrue,
          reason: 'the test suite runs without the define, so the default arm '
              'must be the pool');

      // The documented off spellings must all actually turn it OFF. `0` is the
      // trap: `bool.fromEnvironment` would return its DEFAULT for this value,
      // leaving the pool on while the operator believes it is off.
      expect(decodePoolEnabledFor('0'), isFalse);
      expect(decodePoolEnabledFor('false'), isFalse);
      expect(decodePoolEnabledFor('off'), isFalse);

      // Anything else means on: an unrecognised value must not silently disable
      // the production path.
      expect(decodePoolEnabledFor('1'), isTrue);
      expect(decodePoolEnabledFor('true'), isTrue);
      expect(decodePoolEnabledFor('yes'), isTrue);

      // The const and the callable spell the same rule twice (Dart forbids a
      // method call in a const expression). Pin them together so they cannot
      // drift: a build could otherwise honour a spelling the tests reject, or
      // vice versa.
      expect(decodePoolEnabledFor(kDecodePoolDefine), equals(kDecodePoolEnabled));
    });
  });

  group('decode_pool_width_sink_test.dart', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    tearDown(() {
      PerfLog.testSink = null;
      setHalcyonDecodePoolWidth(2);
      debugDecodeWidthRecommendationsOverride = null;
    });

    test(
      'TC-960: setHalcyonDecodePoolWidth sets the pool width AND the native slot '
      'target, and logs the request',
      () {
        final lines = <String>[];
        PerfLog.testSink = lines.add;

        setHalcyonDecodePoolWidth(6);

        expect(CeyxDecodePool.shared.width, 6);
        expect(CeyxDecodePool.shared.nativeSlotTarget, 6);
        expect(lines, contains('lane.native_slots|requested=6'));
      },
    );

    test('TC-961: the Dart width and the native slot target cannot diverge', () {
      for (final w in <int>[1, 3, 5, 8]) {
        setHalcyonDecodePoolWidth(w);
        expect(
          CeyxDecodePool.shared.nativeSlotTarget,
          CeyxDecodePool.shared.width,
          reason: 'width and native slot target are one setting, not two',
        );
        expect(CeyxDecodePool.shared.width, w);
      }
    });

    test(
      'TC-962: a width above the machine recommendation propagates UNCLAMPED '
      '(ruling r-6)',
      () {
        // The machine reports a recommendation of 2 for the default class, and
        // the user asks for the slider maximum of 8. Ruling r-6: the user wins,
        // end to end. If any layer ever starts consulting the recommendation as
        // a clamp, this test is what fails.
        debugDecodeWidthRecommendationsOverride = () => <int>[3, 2, 1];

        final lines = <String>[];
        PerfLog.testSink = lines.add;

        setHalcyonDecodePoolWidth(8);

        expect(CeyxDecodePool.shared.width, 8);
        expect(CeyxDecodePool.shared.nativeSlotTarget, 8);
        expect(lines, contains('lane.native_slots|requested=8'));
        expect(
          halcyonDecodeWidthRecommendations(),
          <int>[3, 2, 1],
          reason: 'the recommendation is still readable — it is just not applied',
        );
      },
    );
  });

  group('decode_pool_wiring_test.dart', () {
    late List<int> pushed;
    late void Function(int) original;

    setUp(() {
      pushed = <int>[];
      original = ImagePreloadController.decodePoolWidthSink;
      ImagePreloadController.decodePoolWidthSink = pushed.add;
    });

    tearDown(() {
      ImagePreloadController.decodePoolWidthSink = original;
    });

    test('TC-938: setDecodeLaneWidth pushes the clamped width to the pool', () {
      final controller = ImagePreloadController(
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            const NativeImageFailure('UNUSED', 'width wiring only'),
        decodeLaneWidth: 1,
      );
      addTearDown(controller.dispose);

      // CONSTRUCTION pushes too: before this, the pool sat at its own default
      // (2) while the lane was at the constructor's value until the stored
      // preference hydrated -- a window in which the two bounds disagreed.
      expect(pushed, [1]);

      controller.setDecodeLaneWidth(5);
      expect(controller.decodeLaneWidth, 5);
      expect(pushed, [1, 5]);

      // Below-1 values clamp, and the POOL sees the clamped value -- not the
      // raw one, or the two bounds would disagree.
      controller.setDecodeLaneWidth(0);
      expect(controller.decodeLaneWidth, 1);
      expect(pushed, [1, 5, 1]);
    });

    test(
      'TC-966: setDecodeLaneWidth clamps exactly once for every requested '
      'width, and the sink sees the same clamped value as decodeLaneWidth',
      () {
        final controller = ImagePreloadController(
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              const NativeImageFailure('UNUSED', 'width wiring only'),
          decodeLaneWidth: 1,
        );
        addTearDown(controller.dispose);
        pushed.clear();

        for (final k in <int>[0, 1, 5, 9]) {
          controller.setDecodeLaneWidth(k);
          final expected = k < 1 ? 1 : k;
          expect(controller.decodeLaneWidth, expected);
          expect(
            pushed.last,
            controller.decodeLaneWidth,
            reason: 'clamping applied once, not twice',
          );
        }
      },
    );
  });

  group('stage_widths_test.dart', () {
    group('StageWidths.derive', () {
      test('TC-1020: derives every stage width from one number, secondary '
          'stages pinned at 2', () {
        for (var n = 1; n <= kMaxDecodeLaneWidth; n++) {
          final widths = StageWidths.derive(n);
          expect(widths.decodeLane, n, reason: 'decodeLane passes through');
          expect(widths.encode, 2, reason: 'encode pinned this revision');
          expect(widths.derive, 2, reason: 'derive pinned this revision');
        }
      });

      test('TC-1021: clamps the configured width once, at the source', () {
        expect(StageWidths.derive(0).decodeLane, 1);
        expect(StageWidths.derive(-5).decodeLane, 1);
        expect(
          StageWidths.derive(kMaxDecodeLaneWidth + 3).decodeLane,
          kMaxDecodeLaneWidth,
        );
        // Clamping never leaks into the secondary stages.
        expect(StageWidths.derive(0).encode, 2);
        expect(StageWidths.derive(kMaxDecodeLaneWidth + 3).derive, 2);
      });

      test('value equality holds (so a redundant push can be skipped)', () {
        expect(StageWidths.derive(4), StageWidths.derive(4));
        expect(StageWidths.derive(4).hashCode, StageWidths.derive(4).hashCode);
        expect(StageWidths.derive(4) == StageWidths.derive(5), isFalse);
      });
    });
  });

  group('image_preload_controller_lane_race_test.dart', () {
    // TC-380 (provisional number -- re-verify against the SOP register at merge).
    // Defect A from docs/logs/2026-08-30/lane-race-arch-verdict.md §1.A:
    // _ensurePayload checks `_loadingKeys.contains(id)` BEFORE the probe await but
    // claims the id AFTER it, so two entrants for the same id both pass the check
    // and both run a source load. The second `_cache.put` replaces the payload
    // object, orphaning the tier-1 ImageCache entry keyed on bytes identity.
    //
    // The race needs no wall-clock timing: `_scheduler.classify` is async, so the
    // first entrant is guaranteed to be suspended at that await when the second
    // entrant runs its check. The loader gate below only holds the first load open
    // long enough for the assertion to be about production, not about timing.

    TestWidgetsFlutterBinding.ensureInitialized();

    List<PhotoItem> items(int count) => List.generate(count, (index) {
      final id = 'IMG_${index.toString().padLeft(4, '0')}';
      return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
    });

    test(
      'TC-380 two concurrent entrants for the same id run exactly one load '
      'and never replace the payload object (decode lane width 2)',
      () async {
        final loadsByPath = <String, int>{};
        final gate = Completer<void>();

        final controller = ImagePreloadController(
          decodeLaneWidth: 2,
          imageLoader: (path, {required purpose, int? targetLongEdge}) async {
            loadsByPath[path] = (loadsByPath[path] ?? 0) + 1;
            // Hold the FIRST load open so a second entrant, if the claim is
            // still taken after the probe await, has every opportunity to
            // start its own load. Later loads are not gated, so a defective
            // build finishes and is measured rather than hanging.
            if (loadsByPath[path] == 1) {
              await gate.future;
            }
            // A FRESH bytes object per call: two loads therefore produce two
            // distinct payload objects, which is exactly what makes the
            // `identical` assertion below meaningful.
            return NativeImageBytes(Uint8List.fromList([137, 80, 78, 71]));
          },
        );
        addTearDown(controller.dispose);

        final photos = items(6);
        final selected = photos[2];

        // Two navigation passes with NO await in between: both reach
        // `_ensurePayload` for the selected id with `precomputedProbe == null`.
        final first = controller.preloadImages(
          items: photos,
          selectedItemId: selected.id,
          notifyLoaded: () {},
        );
        final second = controller.preloadImages(
          items: photos,
          selectedItemId: selected.id,
          notifyLoaded: () {},
        );

        // Let both entrants get past the probe await before anything lands.
        for (var i = 0; i < 8; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        gate.complete();
        await Future.wait([first, second]);

        expect(
          loadsByPath['/tmp/${selected.id}.jpg'],
          1,
          reason:
              'the in-flight claim must be taken BEFORE the probe await, so the '
              'second entrant parks instead of buying a second source load',
        );

        // PHASE 3 settle (settle-only instrument repair): awaiting the two
        // preloadImages futures no longer implies the load has landed -- the
        // pass returns once the window is issued. The single-load and
        // no-replacement assertions around this line are unchanged.
        await until(
          () => controller.payloadFor(selected.id) != null,
          reason: 'the contended payload to land',
        );
        final landed = controller.payloadFor(selected.id);
        expect(landed, isNotNull);

        // A late second load would replace the cached payload object and
        // silently orphan the tier-1 ImageCache key (bytes identity).
        for (var i = 0; i < 8; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(
          identical(controller.payloadFor(selected.id), landed),
          isTrue,
          reason: 'the payload OBJECT must never be replaced by a second load',
        );
      },
    );
  });
}
