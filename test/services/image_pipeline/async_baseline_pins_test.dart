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

    test(
      'TC-973a: expensive selected item — preloadImages completes while the '
      'lane still has the payload task pending',
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

        // The lane's pending-queue accessor (`debugLanePendingPriorityFor`)
        // only reflects QUEUED tasks: by the time `await preloadImages`
        // returns control, the lane's microtask pump has typically already
        // dequeued the one task (width 1) into "running", so a queue-only
        // check would be a false negative. The decode-started flag plus
        // "still not cached" is the mechanically equivalent, timing-robust
        // proof that preloadImages returned WITHOUT waiting for the decode.
        expect(
          decodeStarted.isCompleted,
          isTrue,
          reason: 'the expensive decode must have been kicked off',
        );
        expect(
          controller.imageBytesFor(selectedId),
          isNull,
          reason:
              'the payload has not landed -- preloadImages did not await '
              'the decode',
        );
      },
    );

    test(
      'TC-973b: cheap selected item — preloadImages does not complete '
      'before its payload is cached',
      () async {
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
          notifyLoaded: () {},
        );

        expect(
          cheap.imageBytesFor(selectedId),
          isNotNull,
          reason:
              'a cheap selected item decodes INLINE inside the awaited '
              'segment of preloadImages, so by the time it returns the '
              'payload is already cached',
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
        for (final item in selections) {
          await controller.preloadImages(
            items: items,
            selectedItemId: item.id,
            notifyLoaded: () => notifyCount++,
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

  group('B4 — probe barrier', () {
    final dngDir = sampleDngDir;
    final hasSamples = samplePhotosAvailable;
    final noPreviewDng = File('${dngDir.path}/IMG_20251112_092839.dng');

    test(
      'TC-975: no window item reaches the decode lane while one window '
      "item's probe is still unresolved",
      () async {
        if (!hasSamples) {
          markTestSkipped('no sample DNGs available on this host');
          return;
        }
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

        // Every OTHER window item is a real, EXPENSIVE (no-embedded-preview)
        // DNG whose decode never completes -- so IF the barrier is dropped
        // and one of them is routed onto the lane once its own (fast, real)
        // probe resolves, it becomes visible as a pending lane task and
        // stays that way (nothing here ever finishes a decode).
        final controller = ImagePreloadController(
          scheduleFrameCallback: _microtaskFrame,
          imageLoader: (path, {required purpose, int? targetLongEdge}) async {
            fail('no embedded preview: loader must not be asked for pixels');
          },
          dngDecoder: (path) async => Completer<DecodedRgba>().future,
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(800, 600);

        // Selected item (index 0) plus 4 other expensive DNGs, plus one
        // window item (farthest, distance 5) whose file is the never-
        // resolving FIFO instead of a real photo.
        final items = List<PhotoItem>.generate(6, (i) {
          final id = 'FIFO_${i.toString().padLeft(2, '0')}';
          if (i == 5) {
            return PhotoItem(id: id, files: [File(fifoPath)]);
          }
          return PhotoItem(id: id, files: [noPreviewDng]);
        });

        // Deliberately unawaited: with the probe barrier intact, this
        // Future itself never completes (it awaits Future.wait over every
        // window probe, including the stuck one). If a future phase drops
        // the barrier, this call resolves quickly instead.
        unawaited(
          controller.preloadImages(
            items: items,
            selectedItemId: items[0].id,
            notifyLoaded: () {},
          ),
        );

        // Give every OTHER (real) probe and the tier-2 debounce (250ms) time
        // to have fired if the barrier were not in place.
        await Future<void>.delayed(const Duration(milliseconds: 400));

        for (final item in items.sublist(1)) {
          expect(
            controller.debugLanePendingPriorityFor(item.id),
            isNull,
            reason:
                '${item.id}: no window item beyond the selected one may '
                'reach the lane while the probe barrier still has one '
                'unresolved probe (the FIFO item)',
          );
        }
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
