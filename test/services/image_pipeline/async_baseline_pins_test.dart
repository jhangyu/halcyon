// Phase 0 behavior baseline pins (async-pipeline-refactor-plan.md §2.2).
//
// These pin TODAY's observable behaviour of ImagePreloadController so every
// later refactor phase is a diff against a red-provable baseline, not
// against prose. Do not loosen any assertion here without an explicit
// contract amendment; TIGHTENING (Phase 3 onward) is allowed per plan §3.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';

import '../../support/preload_fixtures.dart';
import '../../support/sample_photos.dart';

void _microtaskFrame(void Function() callback) => callback();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(clearImageCacheSetUp);

  group('B1 — ImageProvider cache-key identity', () {
    test(
      'TC-972: two providers built from the SAME bytes object compare equal '
      'and obtain the same key; a copy of the bytes does not',
      () async {
        final bytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8]);
        final copy = Uint8List.fromList(bytes);

        final p1 = tierOneProviderFor(bytes, width: 100, height: 100);
        final p2 = tierOneProviderFor(bytes, width: 100, height: 100);
        final pCopy = tierOneProviderFor(copy, width: 100, height: 100);

        expect(p1, p2, reason: 'same bytes identity -> equal providers');
        final k1 = await p1.obtainKey(const ImageConfiguration());
        final k2 = await p2.obtainKey(const ImageConfiguration());
        expect(k1, k2, reason: 'same bytes identity -> same obtainKey');

        expect(
          p1 == pCopy,
          isFalse,
          reason: 'a byte-identical COPY must not compare equal',
        );
        final kCopy = await pCopy.obtainKey(const ImageConfiguration());
        expect(
          k1 == kCopy,
          isFalse,
          reason: 'a byte-identical COPY must not obtain an equal key '
              '(this is the tripwire for a silent duplicate decode)',
        );

        // Tier-2 (full-size) provider is a bare MemoryImage: same identity
        // rule applies.
        final f1 = fullSizeProviderFor(bytes);
        final f2 = fullSizeProviderFor(bytes);
        final fCopy = fullSizeProviderFor(copy);
        expect(f1, f2);
        expect(f1 == fCopy, isFalse);
      },
    );
  });

  group('B2 — selected-item await surface', () {
    final dngDir = sampleDngDir;
    final hasSamples = samplePhotosAvailable;
    final noPreviewDng = File('${dngDir.path}/IMG_20251112_092839.dng');

    // PHASE 3 TIGHTENING (plan §3 Phase 3 acceptance bullet 1). Before
    // Phase 3 this group pinned an ASYMMETRY: an expensive selected item was
    // enqueued and left in flight, but a cheap one decoded inline inside the
    // awaited segment, so `await preloadImages` implied "cheap selection is
    // cached". Phase 3 removed the selected-item await, so both arms now
    // assert the same, stronger property: preloadImages returns without
    // having waited for ANY production, and the payload lands afterwards
    // through the notify path. Both arms are red-proved by ONE mutation --
    // restoring `await _ensurePayload(items[currentIndex], ...)` at the top
    // of preloadImages -- recorded in docs/logs/2026-09-06/phase3-redproof.txt.
    test(
      'TC-973a: expensive selected item — preloadImages completes before the '
      'decode is even issued, and the decode still starts on the lane',
      () async {
        if (!hasSamples) {
          markTestSkipped('no sample DNGs available on this host');
          return;
        }
        final decodeStarted = Completer<void>();
        final controller = ImagePreloadController(
          scheduleFrameCallback: _microtaskFrame,
          imageLoader: (path, {required purpose, int? targetLongEdge}) async {
            fail('no embedded preview: loader must not be asked for pixels');
          },
          dngDecoder: (path) async {
            decodeStarted.complete();
            // Deliberately never completes: this is the pin's whole point --
            // the decode is still in flight when preloadImages returns.
            return Completer<DecodedRgba>().future;
          },
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(800, 600);

        final items = List<PhotoItem>.generate(
          3,
          (i) => PhotoItem(
            id: 'EXP_$i',
            files: [i == 0 ? noPreviewDng : noPreviewDng],
          ),
        );
        final selectedId = items[0].id;

        await controller.preloadImages(
          items: items,
          selectedItemId: selectedId,
          notifyLoaded: () {},
        );

        // TIGHTENED. It used to be enough that the decode had STARTED by the
        // time preloadImages returned (it awaited the selected item's probe
        // and lane enqueue). Since Phase 3 the pass issues and returns on the
        // same turn of the event loop, before the selected item's real file
        // probe can have resolved -- so the decode has NOT started yet at
        // return. This is the assertion the red-proof mutation flips: restore
        // the selected-item await and the probe+enqueue completes first,
        // making `decodeStarted.isCompleted` true here.
        expect(
          decodeStarted.isCompleted,
          isFalse,
          reason:
              'Phase 3: issuing is synchronous -- preloadImages returns '
              'before the selected item\'s probe has even resolved, so no '
              'decode can have started',
        );
        expect(
          controller.imageBytesFor(selectedId),
          isNull,
          reason:
              'the payload has not landed -- preloadImages did not await '
              'the decode',
        );

        // ...but the work WAS issued: the selected item reaches the lane on
        // its own and its decode starts without a second navigation event.
        // Dropping the await must not drop the work.
        await until(
          () => decodeStarted.isCompleted,
          reason: 'the expensive decode to be kicked off by the lane',
        );
        expect(
          controller.imageBytesFor(selectedId),
          isNull,
          reason: 'the decode never completes: the payload is still in flight',
        );
      },
    );

    test(
      'TC-973b: cheap selected item — preloadImages completes with the '
      'payload still in flight, and the payload still lands',
      () async {
        var notified = 0;
        final cheap = ImagePreloadController(
          scheduleFrameCallback: _microtaskFrame,
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
          dngDecoder: (path) async => fail('cheap rung must not RAW-decode'),
        );
        addTearDown(cheap.dispose);
        cheap.updateTargetSize(800, 600);

        final items = paddedItems(3, extension: 'jpg');
        final selectedId = items[0].id;

        await cheap.preloadImages(
          items: items,
          selectedItemId: selectedId,
          notifyLoaded: () => notified++,
        );

        // INVERTED by Phase 3 (was `isNotNull`: a cheap selected item used to
        // decode INLINE inside the awaited segment of preloadImages). The
        // whole point of the phase is that it no longer does.
        expect(
          cheap.imageBytesFor(selectedId),
          isNull,
          reason:
              'Phase 3: a cheap selected item is issued, not awaited, so its '
              'payload is still in flight when preloadImages returns',
        );

        // The payload still LANDS, and the caller learns about it through the
        // notify path -- deliberately observed via `notifyLoaded`, not by
        // re-awaiting preloadImages, because the callback is now the only
        // signal a caller has (plan §3 Phase 3 acceptance bullet 1).
        await until(
          () => notified > 0,
          reason: 'the selected item\'s notifyLoaded to fire',
        );
        expect(
          cheap.imageBytesFor(selectedId),
          isNotNull,
          reason: 'the payload landed after the pass returned',
        );
      },
    );
  });

  group('B3 — notification fan-out count', () {
    test(
      'TC-974: N distinct payload landings produce exactly N notifyLoaded '
      'callbacks',
      () async {
        var notifyCount = 0;
        final controller = ImagePreloadController(
          scheduleFrameCallback: _microtaskFrame,
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
          dngDecoder: (path) async => fail('cheap rung must not RAW-decode'),
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(800, 600);

        const n = 5;
        // Spaced 10 apart, wider than the default retention window
        // (-3..+5): each selection's item was never inside a PRIOR
        // selection's window, so it cannot have been silently cached
        // already (see below).
        final items = paddedItems(60, extension: 'jpg');
        final selections = [for (var k = 0; k < n; k++) items[k * 10]];

        // Today, only the EXPLICITLY-selected item's own `_ensurePayload`
        // call is handed the real `notifyLoaded` -- window neighbours are
        // probed/routed with `notifyLoaded: null` (they still land and are
        // cached, but silently; see `_probeWindowItem`). So N distinct
        // SELECTIONS (one navigation each, far enough apart that none was
        // already silently cached by a previous selection's window) is what
        // produces N landings with a callback. This is the pin's
        // cardinality claim: one call = one callback, never zero, never
        // more than one, for the item that call selected.
        // SETTLE ADDED BY PHASE 3 (instrument repair, not a loosening): the
        // callback used to have fired by the time `await preloadImages`
        // returned, because the selected item decoded inside the awaited
        // segment. Issuing is synchronous now, so each selection's callback
        // arrives after its pass returns. The CARDINALITY claim below is
        // unchanged -- and waiting for exactly `expected` here makes an extra
        // callback still visible to the final assertion.
        var expected = 0;
        for (final item in selections) {
          expected++;
          await controller.preloadImages(
            items: items,
            selectedItemId: item.id,
            notifyLoaded: () => notifyCount++,
          );
          await until(
            () => notifyCount >= expected,
            reason: 'selection ${item.id} to land and notify',
          );
        }

        expect(
          notifyCount,
          n,
          reason:
              'today, one global notifyLoaded fires per landed SELECTED '
              'payload -- N distinct selections, N callbacks. Phase 5 must '
              'not silently swallow a landing while changing WHO is woken.',
        );
      },
    );
  });

  // PHASE 3 INVERSION (plan §3 Phase 3 acceptance bullet 2). This group used
  // to pin the barrier itself: `await Future.wait(probeFutures)` held tier-1
  // precache and tier-2 arming behind EVERY window item's probe, so one
  // unresolved probe froze the whole pass (plan §8-D1 identifies that barrier
  // as the larger of the two stalls). Phase 3 removed it, so the same fixture
  // now pins the opposite: one stuck probe stalls nothing but its own slot.
  group('B4 — probe barrier removed', () {
    test(
      'TC-975: one unresolved window probe does not hold up the pass, the '
      'lane, or the tier-2 debounce',
      () async {
        // A FIFO with no writer: opening it for read genuinely never
        // resolves (real OS blocking semantics), which is a stronger and
        // more honest "probe that never resolves" than any fake seam --
        // there is no test injection point on PrefetchScheduler today.
        final tmpDir = Directory.systemTemp.createTempSync('b4_fifo');
        final fifoPath = '${tmpDir.path}/never.dng';
        final mkfifo = Process.runSync('mkfifo', [fifoPath]);
        expect(
          mkfifo.exitCode,
          0,
          reason: 'mkfifo unavailable on this host: ${mkfifo.stderr}',
        );
        // Deliberately NEVER unblocked and NEVER cleaned up here: the
        // pending `preloadImages` call below is itself deliberately
        // unawaited and outlives this test (the whole point of the pin is
        // that a probe never resolves). Writing to the FIFO, or deleting
        // its directory, in a teardown would resume that dangling future
        // and let it reach real production code (the imageLoader fake)
        // AFTER this test has already reported pass/fail, which the test
        // runner correctly treats as a leak ("test failed after it had
        // already completed"). Leaving one blocked OS thread and one
        // never-deleted temp dir for the remainder of this test PROCESS is
        // the smaller and more honest cost.

        // Every OTHER window item is an ordinary cheap item, so the pass has
        // real work to finish while the FIFO slot's probe stays stuck
        // forever. Tier-2 is the load-bearing observation: it is armed on the
        // synchronous tail of the pass and its 250ms debounce fires into a
        // real full-size decode, which the barrier used to make unreachable.
        final controller = ImagePreloadController(
          scheduleFrameCallback: _microtaskFrame,
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
          dngDecoder: (path) async => fail('cheap rung must not RAW-decode'),
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(800, 600);

        // Selected item (index 0) plus 4 ordinary items, plus one window item
        // (farthest, distance 5) whose file is the never-resolving FIFO
        // instead of a real photo.
        final cheapItems = paddedItems(6, extension: 'jpg');
        final items = List<PhotoItem>.generate(6, (i) {
          if (i == 5) {
            return PhotoItem(id: 'FIFO_05', files: [File(fifoPath)]);
          }
          return cheapItems[i];
        });

        // Deliberately unawaited AND observed for completion: with the probe
        // barrier intact this future never completes (it awaited
        // Future.wait over every window probe, including the stuck one).
        // Phase 3 removed the barrier, so it resolves on this turn of the
        // event loop -- and the `until` below is the assertion that fails,
        // by its own `fail()`, if the barrier ever comes back.
        var passCompleted = false;
        unawaited(
          controller
              .preloadImages(
                items: items,
                selectedItemId: items[0].id,
                notifyLoaded: () {},
              )
              .then((_) => passCompleted = true),
        );

        await until(
          () => passCompleted,
          reason:
              'preloadImages to complete despite one window item whose probe '
              'never resolves (the FIFO item)',
        );

        // INVERTED: the other window items DO reach production now. Each
        // routes on its own probe's completion instead of waiting for the set.
        await until(
          () => items
              .sublist(1, 5)
              .every((item) => controller.imageBytesFor(item.id) != null),
          reason:
              'every non-stuck window item to be produced while the FIFO '
              "item's probe is still unresolved",
        );

        // The tier-2 debounce was ARMED on the pass's synchronous tail and
        // fired: under the barrier it was never even armed.
        await until(
          () => controller.debugTierTwoKeyIds.contains(items[0].id),
          reason:
              'the tier-2 debounce to be armed and to fire for the selected '
              'item despite the unresolved probe',
        );

        // The stuck slot itself is the ONLY casualty: it never reaches the
        // lane, because its own probe is what is blocked.
        expect(
          controller.imageBytesFor('FIFO_05'),
          isNull,
          reason: 'the stuck slot alone stays unproduced',
        );
      },
    );
  });

  group('B5 — width single-source precondition', () {
    test(
      'TC-976: constructing with decodeLaneWidth pushes exactly that width, '
      'and setDecodeLaneWidth pushes exactly the new width',
      () {
        final pushed = <int>[];
        final original = ImagePreloadController.decodePoolWidthSink;
        ImagePreloadController.decodePoolWidthSink = pushed.add;
        addTearDown(() {
          ImagePreloadController.decodePoolWidthSink = original;
        });

        final controller = ImagePreloadController(
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
          decodeLaneWidth: 3,
        );
        addTearDown(controller.dispose);

        expect(pushed, [3], reason: 'constructor pushes exactly one push');

        pushed.clear();
        controller.setDecodeLaneWidth(7);
        expect(
          pushed,
          [7],
          reason: 'setDecodeLaneWidth pushes exactly one push, the new width',
        );
      },
    );
  });
}
