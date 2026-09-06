// P3 Task 2 (docs/logs/2026-09-06/p3-plan-P3.md) -- duplicate-producer
// reachability probe, TEST-ONLY. Question: during the deferred lane hand-off
// window (the claim is dropped at the A3/A5 sites, then re-acquired only when
// the lane body's own `_ensurePayload` re-entry runs), can a second producer
// for the SAME id actually start a duplicate RAW decode through the public
// `preloadImages` seam?
//
// This file makes NO edits to lib/. Per the campaign's binding ruling
// (G-023 / user 2026-09-06): measure only, never close the window here.
//
// METRIC: `PhotoSource.decodePhase` calls the injected `imageLoader` exactly
// once per attempt (the bridge round trip that answers NeedsRawDecode), and
// the LANE body's own retry (`decodePhaseExpensive`) calls the injected
// `dngDecoder` directly instead -- it never asks the loader again (invariant
// I6). So "how many times has this id's source actually been asked to
// produce a payload" is `loaderCalls[path] + decoderCalls[path]`, not either
// counter alone. Both are recorded per path below.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';

import '../../support/preload_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A single item whose file path does not exist on disk. `PhotoSource
  // .probeSource`'s content walk (`DngEmbeddedJpegExtractor.probeContent`)
  // then reports "could not measure" (`cost: null`) exactly as it does for
  // any unreadable file -- no garbage-byte fixture file is needed to reach
  // the same probe outcome a genuinely unmeasurable RAW container produces.
  // `cost: null` is what routes the item into `_source.decodePhase` (rather
  // than the measured-expensive fast path at site A3, which never calls
  // `decodePhase` at all) -- see the plan's ownership-map row A5.
  PhotoItem soleItem() => paddedItems(1, extension: 'dng').single;

  /// Builds a controller whose loader always answers `NeedsRawDecode` for
  /// [item]'s path (so the deferred hand-off route is taken every time) and
  /// whose `dngDecoder` is the lane body's own production call. Both are
  /// counted per path.
  ({
    ImagePreloadController controller,
    Map<String, int> loaderCalls,
    Map<String, int> decoderCalls,
  })
  buildHarness(PhotoItem item, {int decodeLaneWidth = 1}) {
    final loaderCalls = <String, int>{};
    final decoderCalls = <String, int>{};
    final controller = ImagePreloadController(
      decodeLaneWidth: decodeLaneWidth,
      // Explicit null: the default is the REAL native JPEG re-encoder
      // (Phase 13), which has no native library loaded in a unit test and
      // would turn every decode into a silent permanent miss instead of a
      // landed payload. Every decode-only test in this suite binds null the
      // same way (see photo_source.dart's `_normalizedEncoded`/`encodePhase`
      // doc comments); this probe is a decode-only test, not an encoder test.
      payloadEncoder: null,
      imageLoader: (path, {required purpose, int? targetLongEdge}) async {
        loaderCalls[path] = (loaderCalls[path] ?? 0) + 1;
        return const NativeImageNeedsRawDecode(exifOrientation: 1);
      },
      dngDecoder: (path) async {
        decoderCalls[path] = (decoderCalls[path] ?? 0) + 1;
        // Opaque (alpha 255) on every pixel: `decodedRgbaToOrientedFullRes`
        // asserts straight-vs-premultiplied RGBA agree for opaque pixels
        // only, and a fully-transparent buffer (the all-zero default) trips
        // that assertion.
        return DecodedRgba(
          rgba: Uint8List.fromList(
            List<int>.generate(2 * 2 * 4, (i) => i % 4 == 3 ? 255 : 0),
          ),
          width: 2,
          height: 2,
        );
      },
    );
    return (
      controller: controller,
      loaderCalls: loaderCalls,
      decoderCalls: decoderCalls,
    );
  }

  int totalCallsFor(
    String path,
    Map<String, int> loaderCalls,
    Map<String, int> decoderCalls,
  ) => (loaderCalls[path] ?? 0) + (decoderCalls[path] ?? 0);

  test(
    'POSITIVE CONTROL: the counting instrument itself can observe the '
    'combined loader+decoder count reach 2 for the same id (two genuinely '
    'separate production cycles, no hand-off race required) -- proves a '
    'negative result below is not a broken counter',
    () async {
      final item = soleItem();
      final harness = buildHarness(item);
      final controller = harness.controller;
      addTearDown(controller.dispose);
      final path = item.bestFileToLoad!.path;

      controller.preloadImages(
        items: [item],
        selectedItemId: item.id,
        notifyLoaded: () {},
      );
      await until(
        () => controller.payloadFor(item.id) != null,
        reason: 'the first production cycle to land',
      );
      expect(
        totalCallsFor(path, harness.loaderCalls, harness.decoderCalls),
        2,
        reason:
            'one bridge discovery call (deferred) + one lane decoder call is '
            'the correct SINGLE-production count -- the control below is what '
            'checks this reaches 2 a SECOND time',
      );

      // A folder reload is a legitimate, deliberate second production cycle
      // for the SAME id -- not a defect, and not the hand-off race under
      // test. It proves the harness can register the counter climbing past
      // its first-cycle value.
      controller.reset();
      controller.preloadImages(
        items: [item],
        selectedItemId: item.id,
        notifyLoaded: () {},
      );
      await until(
        () => controller.payloadFor(item.id) != null,
        reason: 'the second production cycle (post-reset) to land',
      );

      expect(
        totalCallsFor(path, harness.loaderCalls, harness.decoderCalls),
        4,
        reason:
            'two full production cycles (2 calls each) is what the '
            'instrument must show when nothing suppresses the second one -- '
            'this is the proof the counter is not silently stuck',
      );
    },
  );

  test(
    'REACHABILITY PROBE: a second preloadImages pass issued at increasing '
    'pump depths after the first pass hands the deferred item to the lane '
    '-- does the second entrant ever buy its own duplicate decode?',
    () async {
      // Every attempted pump depth and its observed total-calls count, so a
      // negative result documents exactly what was tried rather than a bare
      // "1". Depths span from "no pump at all" (second entrant issued in the
      // very same synchronous burst) to well past the microtask the lane's
      // `_schedulePump` uses (`decode_lane.dart:149`), which is the only
      // scheduling boundary the deferred hand-off crosses before the lane
      // body re-acquires the claim.
      const pumpDepths = [0, 1, 2, 3, 4, 8, 16, 32];
      final observed = <int, int>{};

      for (final depth in pumpDepths) {
        final item = soleItem();
        final harness = buildHarness(item);
        final controller = harness.controller;
        final path = item.bestFileToLoad!.path;

        controller.preloadImages(
          items: [item],
          selectedItemId: item.id,
          notifyLoaded: () {},
        );
        for (var i = 0; i < depth; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        // The second entrant: same id, no folder reload, no cache clear --
        // exactly the shape a rapid re-selection of the same photo produces.
        controller.preloadImages(
          items: [item],
          selectedItemId: item.id,
          notifyLoaded: () {},
        );

        await until(
          () => controller.payloadFor(item.id) != null,
          reason: 'depth=$depth: the contended item to land',
        );
        // Settle any straggling microtasks/lane activity before reading the
        // final count.
        for (var i = 0; i < 16; i++) {
          await Future<void>.delayed(Duration.zero);
        }

        observed[depth] = totalCallsFor(
          path,
          harness.loaderCalls,
          harness.decoderCalls,
        );
        controller.dispose();
      }

      final maxObserved = observed.values.reduce((a, b) => a > b ? a : b);
      final reproducible = maxObserved >= 3; // 1 discovery + 2 decodes, or worse

      // ignore: avoid_print
      print(
        'halcyon.p3.probe|scenarios=$observed|reproducible=$reproducible',
      );

      final findingsFile = File(
        'docs/logs/2026-09-06/p3-claim-probe-findings.txt',
      );
      findingsFile.parent.createSync(recursive: true);
      findingsFile.writeAsStringSync(
        '${reproducible ? 'REPRODUCIBLE' : 'NOT-REPRODUCIBLE'}\n'
        'Scenarios attempted (pump depth in Future.delayed(Duration.zero) '
        'cycles between the first preloadImages pass and the second '
        'entrant, single-item window, decodeLaneWidth=1):\n'
        '${pumpDepths.map((d) => '  depth=$d -> total_calls=${observed[d]}').join('\n')}\n'
        'Positive-control result: the same counting instrument (this file, '
        'harness above) observed the combined loader+decoder count reach 4 '
        'across two DELIBERATE reset()-separated production cycles for the '
        'same id (2 calls per cycle), proving it is not stuck at any fixed '
        'value.\n'
        'Expected single-production count per cycle is 2 (one deferred '
        'bridge discovery call via imageLoader, one lane decodePhaseExpensive '
        'call via dngDecoder). A reproducible duplicate would show >=3 for '
        'some depth: either a second imageLoader call for the same path '
        '(impossible while `_loadingKeys` still holds the id through the '
        'entire `decodePhase` await -- see image_preload_controller.dart '
        '`_ensurePayload`\'s claim-then-probe ordering, BUG 2026-09-03 fix), '
        'or a second dngDecoder call from a second lane task body for the '
        'same key. `DecodeLane.enqueue` (decode_lane.dart:117-136) dedups '
        'strictly by `(LaneTaskKind, id)`: a re-enqueue of a key still '
        'PENDING replaces the existing entry rather than adding a second '
        'one, and the only way a re-enqueue instead creates a genuinely new, '
        'second-running entry is if it lands after the first entry has '
        'already been dequeued via `_takeNext()` (decode_lane.dart:185-196) '
        'and is running -- but that dequeue-to-claim-reacquire span inside '
        'the lane body is pure synchronous Dart with no await in between '
        '(_runOne -> next.body() -> _ensurePayload\'s claim add at :1469), '
        'so no externally-issued preloadImages call, at any pump depth, can '
        'land inside it: Dart is single-isolate and cooperative, and that '
        'span crosses no scheduling boundary a second call could be '
        'scheduled into. This analysis is offered as an explanation for a '
        'negative finding, not as a substitute for the measurement above.\n',
      );
    },
  );
}
