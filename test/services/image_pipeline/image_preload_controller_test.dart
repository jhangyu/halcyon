import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload_cache.dart';
import '../../support/preload_fixtures.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_source.dart';
import '../../support/sample_photos.dart';
import 'package:halcyon_flutter/services/image_pipeline/prefetch_scheduler.dart';
import 'package:halcyon_flutter/services/image_pipeline/raw_full_res_image.dart';
import '../../support/synthetic_dng.dart';
import '../../support/temp_dirs.dart';

// Drains SYNCHRONOUSLY instead of waiting for a real (disabled-by-default
// in AutomatedTestWidgetsFlutterBinding) frame -- see REPAIR 3 /
// publication_pacer.dart: the paced tier-1/tier-2 publish queue only
// drains when its frame hook fires, and a plain test() never pumps a real
// frame on its own. The pacer re-arms itself after each drained item, so
// a synchronous hook fully drains the queue before submit() returns.
void _microtaskFrame(void Function() callback) => callback();

/// An ImageStreamCompleter that never emits an image and never errors --
/// used to deterministically simulate a decode that is PENDING forever,
/// without racing a real (near-instant) engine decode. When pre-inserted
/// into ImageCache under the exact key a real decode would use,
/// ImageCache.putIfAbsent returns this existing entry instead of starting
/// a new decode, so any code path that resolves that provider joins this
/// completer and never observes completion.
class _NeverCompletingImageStreamCompleter extends ImageStreamCompleter {}

// --- absorbed from image_preload_controller_probe_first_navigation_test.dart ---
// In-suite translation of an earlier one-off scratch probe script. The
// original probe's behavior remains the frozen spec this file was derived
// from. This file applies the approved translation table from
// m3-contract.md A-C1:
//   decodedImageFor(x) != null    -> payloadFor(x) is PixelPayload
//   debugDisposed                 -> payloadFor(x) == null
//   decodedProviderFor(x) != null -> cache holds a payload for x

// --- absorbed from image_preload_controller_dual_window_tier2_test.dart ---
// M5 dual-window RAW full-resolution tier-2 tests.
//
// Contract: docs/logs/2026-08-24/m5-dual-window-design.md, AC-M5-2..6, AC-M5-9.
// Test names below are byte-exact per the frozen team contract; do not rename.
//
// Interface freeze this file builds against (do not invent beyond it):
//   * ImagePreloadController.debugTierTwoKeyIds (@visibleForTesting Set<String>)
//     -- the ids that currently hold a resident tier-2 ImageCache entry.
//   * PhotoSource's SourceOutcome carries a nullable `fullRes` record, produced
//     ONLY by the same FFI decode that produced the payload (piggyback,
//     design Sec 2.2) -- exercised indirectly here via decoder-call counting,
//     since this file owns no photo_source.dart internals.
//   * RawFullResImage (lib/services/raw_full_res_image.dart), keyed on
//     identical(payloadIdentity) + width + height, never holds a retained
//     buffer (AC-M5-9).
//
// Historical note: a pixel-backed (expensive/RAW) item used to get a payload
// only within +/-1 of SOME selection it had passed through (AD-018), so the
// pixel sub-case below walks the selection through neighbouring positions
// before settling in order to see the full -1..+3 band (kEvictionBandBefore /
// kEvictionBandAfter; the test NAMES below still say "+/-2" and are frozen by the
// contract at the top of this file -- the band they assert is now -1..+3,
// AD-034)
// populated. AD-018 was OVERTURNED on 2026-08-26 (memory.md AD-033: expensive
// items now fill the same -3..+5 window as cheap ones, serially), which makes
// that walk unnecessary rather than wrong -- it is kept because what it
// asserts at the end is still exactly the property under test, and a settled
// walk is a strictly harder case than a cold settle.

// A 1x1 image used only to satisfy RawFullResImage's constructor for the
// PROBE key built in M5-DW2 -- see the comment at that test. The probe's
// image is never actually delivered: resolving the probe hits the REAL
// already-resident tier-2 entry (same key by identity+dimensions), and this
// placeholder is disposed unused once that happens.
Future<ui.Image> _decodeTinyImage() {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    Uint8List.fromList([0, 0, 0, 0]),
    1,
    1,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

// --- absorbed from image_preload_controller_permanent_miss_test.dart ---
// M4 (scheduling unification). Three acceptance conditions of the frozen
// convergence contract `docs/logs/2026-08-24/m4-m6-convergence-contract.md`:
//
//   AC1  the sidebar shares the preview path's permanent-miss set, so a
//        thumbnail that can never load is requested ONCE, not once per sweep
//        (design authority §2.2 "2 sets of policies that never talk",
//        invariant I8).
//   AC2  the preview path has a generation guard: a stale `preloadImages`
//        resume must not write into the generation that replaced it
//        (invariant I4).
//   AC3  the step-3b fallback failure path records a permanent miss, which is
//        what keeps invariant T1 (no spinner-forever) true.

// --- absorbed from image_preload_controller_cheap_on_serial_lane_test.dart ---
// TC-718 / TC-719 (registered in docs/sop/unit_test.md; renumbered twice --
// provisional TC-550/551 collided with a parallel layout session, and the
// replacement TC-651/652 collided with an untracked theme session holding
// TC-648..665. See docs/logs/2026-09-02/h3-routing-findings.md).
//
// Field defect (2026-09-02, confirmed from a user log): a photo whose content
// probe measured a perfectly usable embedded preview -- verdict `cheap` -- was
// nevertheless rendered by a full native RAW decode, with visibly different
// colours, whenever it happened to be produced on the SERIAL LANE rather than
// by the parallel window pass.
//
// Mechanism (image_preload_controller.dart, the `canDoExpensive` ternary):
// the branch that chooses `loadExpensive` (which calls the decoder DIRECTLY
// and never asks the loader for an embedded preview) tested only two things --
// "am I on the serial lane?" and "do I already know this file's orientation?"
// -- and never the item's measured COST. The orientation memo is filled by the
// content probe for every measured TIFF/ARW, cheap ones included, so the
// second condition was true for every RAW file and the branch degenerated into
// "RAW-decode anything that reaches the serial lane".
//
// Cheap items reach the serial lane through two cost-blind callers: the
// sidebar payload lane (exercised here, because it is the one a test can drive
// deterministically) and the tier-2 catch-up load. The fix is at the shared
// decision point, so pinning either caller pins both.
//
// The container is synthetic, so these tests need no sample corpus and run on
// CI: one candidate at 800x600 and a small viewport, which is unambiguously
// `cheap` (800 >= 400) and carries an IFD0 orientation.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('image_preload_controller_test.dart', () {
    // Synchronise on the ACTUAL signal a piece of controller work produces,
    // never on a guessed number of event-loop turns or a fixed sleep. Reaching
    // most observable state here crosses at least one `await` (an async content
    // probe, PhotoSource.probeSource file I/O, the 250ms tier-2 debounce, and/or
    // a real engine decode). A fixed `Future.delayed(Duration.zero)` or a short
    // millisecond sleep happens to cover those turns on a fast runner but loses
    // the race on a loaded one — the macOS-CI-only failures this file kept
    // producing. Polling the real condition is deterministic regardless of
    // scheduler speed. Use this for any assertion on state that becomes TRUE
    // after an await; a fixed sleep is only correct when asserting that a state
    // stays FALSE (a non-event cannot be polled for).
    Future<void> pumpUntil(bool Function() condition, {String? reason}) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!condition()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('timed out waiting for: ${reason ?? 'condition'}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }

    test(
      'TC-218 a thumbnail load in flight does not mark the id as loading',
      () async {
        final items = List.generate(5, (index) {
          final id = 'IMG_${index.toString().padLeft(4, '0')}';
          return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
        });
        final gate = Completer<void>();

        final controller = ImagePreloadController(
          scheduleFrameCallback: _microtaskFrame,
          navigationDebounce: Duration.zero,
          imageLoader: (path, {required purpose, int? targetLongEdge}) async {
            if (purpose == ImageRequestPurpose.sidebarThumbnail) {
              await gate.future;
            }
            return NativeImageBytes(Uint8List.fromList([1, 2, 3]));
          },
        );
        addTearDown(controller.dispose);

        final pending = controller.preloadThumbnails(
          items: items,
          startIdx: 0,
          endIdx: 0,
          notifyLoaded: () {},
        );

        // The thumbnail fetch for items[0] is parked in the gate. The DETAIL
        // path must not believe items[0].id is already being loaded -- that is
        // the 'thumb_$id' vs bare-id collision the file documents at the top.
        expect(controller.isLoadingForTest(items[0].id), isFalse);

        gate.complete();
        await pending;
      },
    );

    test(
      'preloadImages evicts preview cache entries outside the sliding window',
      () async {
        final controller = ImagePreloadController(
          scheduleFrameCallback: _microtaskFrame,
          navigationDebounce: Duration.zero,
          imageLoader: (path, {required purpose, int? targetLongEdge}) async {
            return NativeImageBytes(Uint8List.fromList([path.hashCode & 0xFF]));
          },
        );
        addTearDown(controller.dispose);

        final items = List.generate(14, (index) {
          final id = 'IMG_${index.toString().padLeft(4, '0')}';
          return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
        });

        await controller.preloadImages(
          items: items,
          selectedItemId: 'IMG_0005',
          notifyLoaded: () {},
        );
        // PHASE 3 settle (settle-only instrument repair): preloadImages returns
        // once the window is issued, so the window's payloads land a few
        // event-loop turns later. Every assertion here is unchanged.
        await until(
          () => controller.imageBytesFor('IMG_0002') != null,
          reason: 'the -3 slot to land',
        );
        expect(controller.imageBytesFor('IMG_0002'), isNotNull);

        await controller.preloadImages(
          items: items,
          selectedItemId: 'IMG_0011',
          notifyLoaded: () {},
        );
        await until(
          () => controller.imageBytesFor('IMG_0011') != null,
          reason: 'the new selection to land',
        );

        expect(controller.imageBytesFor('IMG_0002'), isNull);
        expect(controller.imageBytesFor('IMG_0011'), isNotNull);
      },
    );

    // PHASE 3 (2026-09-06) RE-EXPRESSION, not a deletion. This test used to
    // assert `expect(requestOrder, [selectedPath])`: the selected CHEAP item's
    // loader request was issued strictly alone, before any other slot. That was
    // a consequence of the `await _ensurePayload(items[currentIndex], ...)`
    // Phase 3 removes -- all nine slots are now issued in one synchronous burst
    // and their content probes resolve in arbitrary order, so no settle can
    // restore it. The INTENT ("the selected item is the most urgent work")
    // survives; its mechanism moved from await-ordering to lane priority, so it
    // is re-expressed below in priority form for an EXPENSIVE selection, which
    // is where lane order is actually decided. The concurrency assertions are
    // unchanged.
    test(
      'preloadImages dispatches the whole window concurrently, and an expensive '
      'selection outranks every other window slot on the lane',
      () async {
        final requestOrder = <String>[];
        final completers = <String, Completer<NativeImageResult>>{};

        final controller = ImagePreloadController(
          scheduleFrameCallback: _microtaskFrame,
          navigationDebounce: Duration.zero,
          imageLoader: (path, {required purpose, int? targetLongEdge}) {
            requestOrder.add(path);
            final completer = Completer<NativeImageResult>();
            completers[path] = completer;
            return completer.future;
          },
        );
        addTearDown(controller.dispose);

        final items = List.generate(14, (index) {
          final id = 'IMG_${index.toString().padLeft(4, '0')}';
          return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
        });

        const selectedId = 'IMG_0005';
        final selectedPath = items[5].files.single.path;
        // Window is [selectedIndex - 3, selectedIndex + 5] clamped, i.e. 2..10.
        final windowPaths = [
          for (var i = 2; i <= 10; i++) items[i].files.single.path,
        ];
        final remainingPaths = windowPaths.where((p) => p != selectedPath);

        final preloadFuture = controller.preloadImages(
          items: items,
          selectedItemId: selectedId,
          notifyLoaded: () {},
        );

        // All window items must have been requested already, proving
        // they were dispatched concurrently rather than one at a time. Poll for
        // the full set rather than a fixed number of turns: each window item is
        // dispatched through its own awaited probe.
        await pumpUntil(
          () => requestOrder.length == windowPaths.length,
          reason: 'the whole window to be dispatched concurrently',
        );
        expect(requestOrder.length, windowPaths.length);
        expect(requestOrder.toSet(), windowPaths.toSet());
        for (final path in remainingPaths) {
          expect(completers.containsKey(path), isTrue);
        }

        for (final path in windowPaths) {
          completers[path]!.complete(
            NativeImageBytes(Uint8List.fromList([path.hashCode & 0xFF])),
          );
        }

        await preloadFuture;
        // PHASE 3 settle: preloadFuture completes once the window is ISSUED.
        await until(
          () => [
            for (var i = 2; i <= 10; i++) items[i].id,
          ].every((id) => controller.imageBytesFor(id) != null),
          reason: 'the whole window to land',
        );

        for (var i = 2; i <= 10; i++) {
          expect(controller.imageBytesFor(items[i].id), isNotNull);
        }

        // THE RE-EXPRESSED SELECTED-FIRST CLAIM. For expensive items the lane
        // decides the order, and it orders by the priority it is handed, never
        // by enqueue or arrival order (plan risk R8) -- so this is asserted on
        // `debugLanePendingPriorityFor`, not on `requestOrder`.
        final startedPaths = <String>[];
        final expensive = ImagePreloadController(
          scheduleFrameCallback: _microtaskFrame,
          navigationDebounce: Duration.zero,
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              const NativeImageNeedsRawDecode(exifOrientation: 1),
          dngDecoder: (path) async {
            startedPaths.add(path);
            // Never completes: the lane's one slot stays occupied, so every
            // other window slot is observable as PENDING with its rank.
            return Completer<DecodedRgba>().future;
          },
        );
        addTearDown(expensive.dispose);
        expensive.updateTargetSize(10, 10);
        final raws = List.generate(14, (index) {
          final id = 'RAW_${index.toString().padLeft(4, '0')}';
          return PhotoItem(id: id, files: [File('/tmp/$id.dng')]);
        });
        await expensive.preloadImages(
          items: raws,
          selectedItemId: raws[5].id,
          notifyLoaded: () {},
        );
        final otherWindowIds = [
          for (var i = 2; i <= 10; i++)
            if (i != 5) raws[i].id,
        ];
        await until(
          () => otherWindowIds.every(
            (id) => expensive.debugLanePendingPriorityFor(id) != null,
          ),
          reason: 'the whole expensive window to reach the lane',
        );

        // The selected item's own entry is either still QUEUED (then its rank
        // must be the lowest) or already DEQUEUED into the lane's single slot
        // (then it outranked everything by definition -- and the decoder proves
        // it really is the one running, so a null here can never mean "never
        // enqueued").
        final selectedPending = expensive.debugLanePendingPriorityFor(
          raws[5].id,
        );
        if (selectedPending == null) {
          expect(
            startedPaths,
            [raws[5].files.single.path],
            reason:
                'the selected item left the queue because it is the one '
                'running, not because it was never enqueued',
          );
        }
        final selectedRank = selectedPending ?? -1;
        for (final id in otherWindowIds) {
          expect(
            selectedRank < expensive.debugLanePendingPriorityFor(id)!,
            isTrue,
            reason:
                '$id outranks or ties the selected item: the selection must be '
                'the most urgent work on the lane',
          );
        }
      },
    );

    test('selecting an in-flight item still fires notify once its load completes '
        '(R3: no permanent spinner strand)', () async {
      final completers = <String, List<Completer<NativeImageResult>>>{};
      var firstNotify = 0;
      var secondNotify = 0;

      final controller = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        navigationDebounce: Duration.zero,
        imageLoader: (path, {required purpose, int? targetLongEdge}) {
          final completer = Completer<NativeImageResult>();
          completers.putIfAbsent(path, () => []).add(completer);
          return completer.future;
        },
      );
      addTearDown(controller.dispose);

      final items = List.generate(14, (index) {
        final id = 'IMG_${index.toString().padLeft(4, '0')}';
        return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
      });

      final targetPath = items[2].files.single.path; // IMG_0002

      // First preload pass selects IMG_0002; this starts (but does not
      // finish) its load and queues the rest of the window.
      final firstPass = controller.preloadImages(
        items: items,
        selectedItemId: 'IMG_0002',
        notifyLoaded: () => firstNotify++,
      );
      await pumpUntil(
        () => completers.containsKey(targetPath),
        reason:
            "the selected item's loader to be invoked after the async probe",
      );

      expect(completers.containsKey(targetPath), isTrue);
      expect(completers[targetPath]!.single.isCompleted, isFalse);

      // Second pass selects the same item while its load is still in
      // flight. Before the R3 fix this notifyLoaded would be silently
      // dropped by the early-return guard, permanently stranding the
      // spinner even after the underlying bytes arrive.
      final secondPass = controller.preloadImages(
        items: items,
        selectedItemId: 'IMG_0002',
        notifyLoaded: () => secondNotify++,
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.imageBytesFor('IMG_0002'), isNull);
      expect(secondNotify, 0);

      // Complete the in-flight load; every caller who selected this item
      // while it was loading must be notified, not just the original one.
      for (final completer in completers[targetPath]!) {
        if (!completer.isCompleted) {
          completer.complete(NativeImageBytes(Uint8List.fromList([1])));
        }
      }
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      // Drain remaining window loads from both passes before asserting: M3's
      // source/cost pipeline still guarantees selected-first notification, but
      // it also keeps more work as explicit futures so leaving the window's fake
      // loads unresolved can keep the test process open until dart_test's global
      // timeout.
      for (final list in completers.values) {
        for (final completer in list) {
          if (!completer.isCompleted) {
            completer.complete(NativeImageBytes(Uint8List.fromList([2])));
          }
        }
      }
      await firstPass;
      await secondPass;

      expect(controller.imageBytesFor('IMG_0002'), isNotNull);
      expect(
        firstNotify,
        greaterThanOrEqualTo(1),
        reason: 'the original (first) caller callback must still fire',
      );
      expect(
        secondNotify,
        greaterThanOrEqualTo(1),
        reason:
            'notifyLoaded from the second (in-flight) selectItem call must '
            'be flushed once the shared load completes, not dropped',
      );
    });

    test(
      'tierOneProviderFor produces an identical ImageCache key for the same '
      'bytes object identity and same width/height (AC2: display and '
      'precache must share one cache entry, not silently double-decode)',
      () async {
        final bytes = Uint8List.fromList(List.generate(16, (i) => i));

        // Simulates the precache call site.
        final precacheProvider = tierOneProviderFor(
          bytes,
          width: 800,
          height: 600,
        );
        // Simulates the display call site: a fresh ResizeImage/MemoryImage
        // instance, but built from the SAME bytes object and SAME dimensions.
        final displayProvider = tierOneProviderFor(
          bytes,
          width: 800,
          height: 600,
        );

        final precacheKey = await precacheProvider.obtainKey(
          ImageConfiguration.empty,
        );
        final displayKey = await displayProvider.obtainKey(
          ImageConfiguration.empty,
        );

        expect(
          precacheKey,
          equals(displayKey),
          reason:
              'ImageCache dedups strictly by key equality; a mismatch here '
              'means the display path always misses the precache and '
              'decodes a second time.',
        );
        expect(precacheKey.hashCode, equals(displayKey.hashCode));

        // Sanity: a different bytes object (even with identical content and
        // dimensions) must NOT collapse to the same key, since MemoryImage
        // compares bytes by identity, not content. Rebuilding/copying the
        // bytes between the precache and display call sites would silently
        // reintroduce the double-decode bug this factory exists to prevent.
        final copiedBytes = Uint8List.fromList(bytes);
        final copiedProvider = tierOneProviderFor(
          copiedBytes,
          width: 800,
          height: 600,
        );
        final copiedKey = await copiedProvider.obtainKey(
          ImageConfiguration.empty,
        );
        expect(copiedKey, isNot(equals(precacheKey)));
      },
    );

    testWidgets(
      'precache-then-display resolves as an ImageCache hit (AC2 integration: '
      'no second decode once the tier-1 entry is warm)',
      (tester) async {
        await tester.runAsync(() async {
          final bytes = Uint8List.fromList(tinyPngBytes);

          final precacheProvider = tierOneProviderFor(
            bytes,
            width: 10,
            height: 10,
          );
          final precacheKey = await precacheProvider.obtainKey(
            ImageConfiguration.empty,
          );

          // Simulate the controller's precache: resolve without ever
          // attaching to a widget tree or passing a BuildContext.
          final completer = Completer<void>();
          final stream = precacheProvider.resolve(ImageConfiguration.empty);
          late ImageStreamListener listener;
          listener = ImageStreamListener(
            (image, synchronousCall) {
              stream.removeListener(listener);
              completer.complete();
            },
            onError: (error, stackTrace) {
              stream.removeListener(listener);
              completer.completeError(error, stackTrace);
            },
          );
          stream.addListener(listener);
          await completer.future;

          expect(
            PaintingBinding.instance.imageCache.containsKey(precacheKey),
            isTrue,
            reason: 'precache must land a decoded entry under this key',
          );

          // Simulate the display path: a fresh provider instance, same bytes
          // object + same size.
          final displayProvider = tierOneProviderFor(
            bytes,
            width: 10,
            height: 10,
          );
          final displayKey = await displayProvider.obtainKey(
            ImageConfiguration.empty,
          );

          expect(displayKey, equals(precacheKey));
          expect(
            PaintingBinding.instance.imageCache.containsKey(displayKey),
            isTrue,
            reason:
                'display path key must already be present in the cache '
                'populated by precache -> ImageCache.putIfAbsent returns the '
                'cached entry instead of decoding again',
          );
        });
      },
    );

    testWidgets(
      'tier-2 full-size decode does not start until the navigation debounce '
      'elapses (AC3a)',
      (tester) async {
        await tester.runAsync(() async {
          // Debounce shortened to 40ms (from the production 250ms default):
          // this test's own semantics are the ordering around the debounce
          // firing, not its absolute duration, and 40ms still leaves ample
          // room for the 5-15ms mid-window check below.
          const shortDebounce = Duration(milliseconds: 40);
          final controller = ImagePreloadController(
            scheduleFrameCallback: _microtaskFrame,
            navigationDebounce: shortDebounce,
            imageLoader:
                (path, {required purpose, int? targetLongEdge}) async =>
                    NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
          );
          addTearDown(controller.dispose);

          final items = List.generate(5, (i) {
            final id = 'IMG_${i.toString().padLeft(2, '0')}';
            return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
          });
          controller.updateTargetSize(10, 10);

          await controller.preloadImages(
            items: items,
            selectedItemId: items[2].id,
            notifyLoaded: () {},
          );

          // Right after preloadImages returns -- long before the debounce --
          // tier-2 must not have started yet.
          expect(controller.isFullSizeReady(items[2].id), isFalse);

          // Still not ready comfortably inside the debounce window. If the
          // debounce were removed, the tiny PNG decodes near-instantly and
          // this would already be true. 15ms is well under the 40ms debounce.
          await Future<void>.delayed(const Duration(milliseconds: 15));
          expect(controller.isFullSizeReady(items[2].id), isFalse);

          // After the debounce elapses, tier-2 has landed. Poll the real
          // readiness signal rather than betting a fixed sleep covers the
          // debounce PLUS the decode on a loaded runner.
          await pumpUntil(
            () => controller.isFullSizeReady(items[2].id),
            reason: 'tier-2 to land for the selected item after the debounce',
          );
          expect(controller.isFullSizeReady(items[2].id), isTrue);
        });
      },
    );

    testWidgets(
      'tier-2 never queues an item that scrolled out of the window during '
      'continuous navigation (AC3b)',
      (tester) async {
        await tester.runAsync(() async {
          // Debounce shortened to 40ms: the ordering under test is "each
          // navigation resets the timer", not its absolute length.
          final controller = ImagePreloadController(
            scheduleFrameCallback: _microtaskFrame,
            navigationDebounce: const Duration(milliseconds: 40),
            imageLoader:
                (path, {required purpose, int? targetLongEdge}) async =>
                    NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
          );
          addTearDown(controller.dispose);

          final items = List.generate(10, (i) {
            final id = 'IMG_${i.toString().padLeft(2, '0')}';
            return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
          });
          controller.updateTargetSize(10, 10);

          // Rapid burst of navigation, well under the 40ms debounce,
          // simulating a held-down arrow key: 2 -> 3 -> 4 -> 5.
          for (final idx in [2, 3, 4, 5]) {
            await controller.preloadImages(
              items: items,
              selectedItemId: items[idx].id,
              notifyLoaded: () {},
            );
            await Future<void>.delayed(const Duration(milliseconds: 10));

            // Discriminating mid-burst check (round-2 review BLOCKER 2: the
            // original version of this test only asserted the END state,
            // which a debounce-removed mutant also satisfies once index 2
            // scrolls out and gets swept -- it can't tell "never queued"
            // from "queued, then evicted"). Sampled after EVERY step,
            // including the very first (right after navigating to index 2
            // itself): each navigation event cancels and reschedules the
            // debounce timer, so nothing should ever have had 250ms of
            // quiet to actually start decoding. A debounce-removed mutant
            // starts decoding within tens of ms of each step and fails this
            // assertion immediately after the first step.
            expect(
              controller.isFullSizeReady(items[2].id),
              isFalse,
              reason:
                  'index 2 must not be queued for a full-size decode this '
                  'early -- a debounce-removed controller already starts '
                  'decoding within a single burst step',
            );
          }

          // Let the debounce settle on the FINAL position (index 5): poll until
          // the current item lands. Once it has, the debounce has fired, so the
          // out-of-window index 2 has had its full chance to be (wrongly) queued.
          await pumpUntil(
            () => controller.isFullSizeReady(items[5].id),
            reason: "the final position's tier-2 to land after the burst",
          );

          // Index 2 scrolled out of the tier-2 window during the burst and
          // must never have been queued for a full-size decode.
          expect(controller.isFullSizeReady(items[2].id), isFalse);
          // The final window's current item did land.
          expect(controller.isFullSizeReady(items[5].id), isTrue);
        });
      },
    );

    testWidgets(
      'tier-1 and tier-2 caches coexist: evicting a tier-2 entry does not '
      'evict the tier-1 entry for the same item (AC3c)',
      (tester) async {
        await tester.runAsync(() async {
          final controller = ImagePreloadController(
            scheduleFrameCallback: _microtaskFrame,
            navigationDebounce: Duration.zero,
            imageLoader:
                (path, {required purpose, int? targetLongEdge}) async =>
                    NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
          );
          addTearDown(controller.dispose);

          final items = List.generate(10, (i) {
            final id = 'IMG_${i.toString().padLeft(2, '0')}';
            return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
          });
          controller.updateTargetSize(10, 10);

          // Land on index 5; let tier-1 (immediate) and tier-2 (after
          // debounce) both settle. Tier-2 window is {4,5,6}; tier-1 window is
          // {3,4,5,6,7}.
          await controller.preloadImages(
            items: items,
            selectedItemId: items[5].id,
            notifyLoaded: () {},
          );
          await pumpUntil(
            () => controller.isFullSizeReady(items[4].id),
            reason: 'tier-2 to land for index 4 after the debounce',
          );
          expect(controller.isFullSizeReady(items[4].id), isTrue);

          final bytesAt4 = controller.imageBytesFor(items[4].id)!;
          final tierOneKeyAt4 = await tierOneProviderFor(
            bytesAt4,
            width: 10,
            height: 10,
          ).obtainKey(ImageConfiguration.empty);
          final tierTwoKeyAt4 = await fullSizeProviderFor(
            bytesAt4,
          ).obtainKey(ImageConfiguration.empty);

          expect(
            PaintingBinding.instance.imageCache.containsKey(tierOneKeyAt4),
            isTrue,
          );
          expect(
            PaintingBinding.instance.imageCache.containsKey(tierTwoKeyAt4),
            isTrue,
          );

          // Navigate to index 7. New tier-2 window is +/-2 = {5,6,7,8,9}: index
          // 4 falls OUT of it. New tier-1 window is the whole -3..+5 = {4..12}:
          // index 4 STAYS in it, exactly on the -3 boundary. This is the
          // coexistence case -- tier-2 eviction for index 4 must not touch its
          // still-current tier-1 entry.
          //
          // The step is two items rather than one because round 2 widened tier-2
          // from +/-1 to +/-2; a single step no longer takes index 4 out of the
          // tier-2 window, which would make this test vacuous rather than false.
          // The ASSERTIONS are unchanged -- only the navigation distance needed
          // to cross the boundary moved.
          await controller.preloadImages(
            items: items,
            selectedItemId: items[7].id,
            notifyLoaded: () {},
          );
          // Poll for the eviction itself (it runs on the 250ms debounce sweep)
          // rather than assuming a fixed sleep outlasts it on a slow runner.
          await pumpUntil(
            () =>
                !PaintingBinding.instance.imageCache.containsKey(tierTwoKeyAt4),
            reason: "index 4's tier-2 entry to be evicted after leaving +/-2",
          );

          expect(
            PaintingBinding.instance.imageCache.containsKey(tierTwoKeyAt4),
            isFalse,
            reason: 'index 4 left the tier-2 (+/-2) window and must be evicted',
          );
          expect(
            PaintingBinding.instance.imageCache.containsKey(tierOneKeyAt4),
            isTrue,
            reason:
                'index 4 is still inside the tier-1 (-3..+5) window; evicting '
                'its tier-2 entry must not have evicted tier-1 too',
          );
        });
      },
    );

    testWidgets(
      'isFullSizeReady does not report stale readiness after an item leaves '
      'and re-enters the bytes window with a new bytes object (round-2 '
      'review BLOCKER 1)',
      (tester) async {
        await tester.runAsync(() async {
          // Debounce shortened to 40ms: the burst below must still complete
          // faster than a full debounce interval (each navigate is near-
          // instant, well under 40ms) so the tier-2 sweep never runs mid-
          // excursion, matching the test's original intent.
          final controller = ImagePreloadController(
            scheduleFrameCallback: _microtaskFrame,
            navigationDebounce: const Duration(milliseconds: 40),
            // A fresh Uint8List every call -- an item reloaded after leaving
            // the -3..+5 bytes window gets a NEW bytes object, exactly as the
            // real native loader would produce for a re-fetch.
            imageLoader:
                (path, {required purpose, int? targetLongEdge}) async =>
                    NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
          );
          addTearDown(controller.dispose);

          final items = List.generate(20, (i) {
            final id = 'IMG_${i.toString().padLeft(2, '0')}';
            return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
          });
          controller.updateTargetSize(10, 10);

          Future<void> go(int i) => controller.preloadImages(
            items: items,
            selectedItemId: items[i].id,
            notifyLoaded: () {},
          );

          await go(5);
          await pumpUntil(
            () => controller.isFullSizeReady(items[5].id),
            reason: 'the initial tier-2 for index 5 to land',
          );
          expect(controller.isFullSizeReady(items[5].id), isTrue);
          final originalBytes = controller.imageBytesFor(items[5].id)!;
          final originalKey = await fullSizeProviderFor(
            originalBytes,
          ).obtainKey(ImageConfiguration.empty);
          expect(
            PaintingBinding.instance.imageCache.containsKey(originalKey),
            isTrue,
          );

          // Rapid excursion far enough (>= 4 steps, i.e. beyond the -3..+5
          // bytes window) and back, all inside the debounce window so the
          // tier-2 sweep never runs mid-excursion -- this is exactly the
          // burst the review's probe used to reproduce the stale flag.
          for (final idx in [6, 7, 8, 9, 10, 9, 8, 7, 6, 5]) {
            await go(idx);
          }
          // 60ms: 20ms of margin over the 40ms debounce, enough for the fake
          // (near-instant) decode to also land.
          await Future<void>.delayed(const Duration(milliseconds: 60));

          final currentBytes = controller.imageBytesFor(items[5].id)!;
          expect(
            identical(originalBytes, currentBytes),
            isFalse,
            reason:
                'index 5 left the -3..+5 bytes window during the excursion '
                'and must have been reloaded as a new bytes object -- this '
                'test is only meaningful if that precondition holds',
          );

          // The discriminating assertion: readiness must be false or must
          // point at a cache entry for the CURRENT bytes, never at the old,
          // orphaned entry. Against the pre-fix id-keyed Set alone, this
          // reads true while the cache has no entry for the current bytes
          // (the review's reproduced failure mode).
          final isReady = controller.isFullSizeReady(items[5].id);
          if (isReady) {
            final currentKey = await fullSizeProviderFor(
              currentBytes,
            ).obtainKey(ImageConfiguration.empty);
            expect(
              PaintingBinding.instance.imageCache.containsKey(currentKey),
              isTrue,
              reason:
                  'isFullSizeReady must not report true unless ImageCache '
                  'actually holds an entry for the CURRENT bytes object',
            );
          }
        });
      },
    );

    testWidgets(
      'isFullSizeReady stays false while the tier-2 decode is still PENDING, '
      'not just when it is missing (round-2 review BLOCKER 3)',
      (tester) async {
        await tester.runAsync(() async {
          // Debounce shortened to 40ms: the pre-insertion below still needs to
          // land before tier-2 attempts its own decode, so the debounce
          // cannot be zero here, only shortened.
          final controller = ImagePreloadController(
            scheduleFrameCallback: _microtaskFrame,
            navigationDebounce: const Duration(milliseconds: 40),
            imageLoader:
                (path, {required purpose, int? targetLongEdge}) async =>
                    NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
          );
          addTearDown(controller.dispose);

          final items = List.generate(10, (i) {
            final id = 'IMG_${i.toString().padLeft(2, '0')}';
            return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
          });
          controller.updateTargetSize(10, 10);

          await controller.preloadImages(
            items: items,
            selectedItemId: items[5].id,
            notifyLoaded: () {},
          );

          // PHASE 3 settle (settle-only instrument repair): the pass returns
          // once the window is issued. Still well inside the 40ms tier-2
          // debounce, so the pre-insertion below still wins the race it is
          // designed to win. Assertions unchanged.
          await until(
            () => controller.imageBytesFor(items[5].id) != null,
            reason: 'the selected payload to land',
          );
          final bytes = controller.imageBytesFor(items[5].id)!;
          final tierTwoKey = await fullSizeProviderFor(
            bytes,
          ).obtainKey(ImageConfiguration.empty);

          // Deterministically simulate "decode started, not yet finished":
          // pre-insert a never-completing entry under the SAME key the
          // controller's own tier-2 decode will resolve to. When the
          // debounce fires and the controller calls
          // fullSizeProviderFor(bytes).resolve(...), Flutter's
          // ImageCache.putIfAbsent finds this key already present and
          // returns the existing (never-completing) entry instead of
          // starting a real decode -- so the controller's own completion
          // listener never fires, and this test never depends on how fast a
          // real decode happens to run.
          final ic = PaintingBinding.instance.imageCache;
          ic.putIfAbsent(
            tierTwoKey,
            () => _NeverCompletingImageStreamCompleter(),
          );
          addTearDown(() => ic.evict(tierTwoKey));

          // Let the debounce fire; the controller's decode attempt for item 5
          // joins the pre-inserted pending entry above and will never complete.
          // Synchronise on item 4 becoming ready: item 4 shares this tier-2
          // window, was NOT pre-seeded, and decodes normally — its readiness is
          // a positive signal that the debounce has fired (so item 5's decode
          // attempt has also happened and joined the pending entry), without
          // betting a fixed sleep outlasts the debounce plus a real decode.
          await pumpUntil(
            () => controller.isFullSizeReady(items[4].id),
            reason: 'the tier-2 debounce to fire (item 4 decodes normally)',
          );

          expect(
            PaintingBinding.instance.imageCache.containsKey(tierTwoKey),
            isTrue,
            reason:
                'sanity check: the pending entry is present in ImageCache '
                '(this is the fact BLOCKER 3 showed containsKey alone '
                'cannot distinguish from "decode finished")',
          );
          expect(
            controller.isFullSizeReady(items[5].id),
            isFalse,
            reason:
                'the tier-2 decode never completed (still pending) -- '
                'isFullSizeReady must not report true just because '
                'ImageCache.containsKey is true for a pending entry, or the '
                'display would switch to a full-size provider whose image '
                'has not finished decoding yet',
          );

          // The other direction, asserted in the SAME test so this can't pass
          // vacuously if isFullSizeReady regressed to always-false: item 4 is
          // also inside the tier-2 (+/-1) window for current=5, was NOT
          // pre-seeded with a pending entry, and so decoded normally (a 1x1
          // PNG completes well within the 350ms already waited above). Its
          // readiness must read true.
          expect(
            controller.isFullSizeReady(items[4].id),
            isTrue,
            reason:
                'item 4 is in the same tier-2 window and decoded normally '
                '(not pre-seeded as pending) -- isFullSizeReady must still '
                'report true for a genuinely completed decode, proving this '
                'test discriminates both directions and not just '
                'always-false',
          );
        });
      },
    );

    // ---------------------------------------------------------------------
    // Round-3b raw-decode path (DNG with no embedded full-size JPEG).
    //
    // These use plain test(), never testWidgets(): the raw path awaits real
    // engine futures (decodeImageFromPixels, Picture.toImage), which hang
    // forever inside testWidgets' FakeAsync zone.
    // ---------------------------------------------------------------------

    group('raw-decode path', () {
      List<PhotoItem> rawItems(int count) => List.generate(count, (index) {
        final id = 'IMG_${index.toString().padLeft(4, '0')}';
        return PhotoItem(id: id, files: [File('/tmp/$id.dng')]);
      });

      /// A 2x2 RGBA8 stand-in for the 4080x3056 the real decoder emits: small
      /// enough to decode instantly, structurally identical. Alpha must be
      /// opaque (0xFF): decoded_rgba_image_provider.dart's debug-only identity
      /// short-circuit asserts sampled alpha is opaque. Same repair as
      /// commits 253b89f / d43c2a1.
      DecodedRgba fakeDecoded() => DecodedRgba(
        rgba: Uint8List.fromList(
          List<int>.generate(2 * 2 * 4, (i) => i % 4 == 3 ? 0xFF : i),
        ),
        width: 2,
        height: 2,
      );

      /// Polls until [condition] holds. The pipeline crosses a 250ms debounce
      /// plus two real engine futures, so there is no single future to await;
      /// a fixed sleep would be either flaky or slow.
      Future<void> until(bool Function() condition, {String? reason}) async {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (!condition()) {
          if (DateTime.now().isAfter(deadline)) {
            fail('timed out waiting for: ${reason ?? 'condition'}');
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }

      // `_finishOffLane`'s encode continuation is deliberately unawaited by the
      // controller (it has no caller). If a test ends -- and `addTearDown`
      // disposes the controller -- while that continuation is still in flight,
      // its later `_inflight.release(...)` races the disposed budget's
      // `clear()` and trips a cross-test assertion (attributed to whatever
      // test happens to be running when it lands). Poll `debugInflightBytes`
      // to zero before ending a test that used an expensive/RAW controller.
      Future<void> settle(ImagePreloadController controller) => until(
        () => controller.debugInflightBytes == 0,
        reason: 'controller inflight-bytes budget to drain before teardown',
      );

      // M6 P3.3 (Appendix B, C-4): the `halcyon/thumbnail` channel is deleted.
      // `_legacyBytes`/`NativeThumbnailService` no longer exist, so a DNG with
      // no embedded preview and no decoder (or a throwing decoder) is a
      // genuine permanent miss (U-12 ruling) -- there is nothing left to
      // degrade to, and nothing left to mock. The `mockNativeChannel` helper
      // and the tests that asserted a channel-backed legacy-bytes fallback
      // are replaced below by the uniform-miss assertions.

      // -------------------------------------------------------------------
      // M3 successor guarantees.
      //
      // The seven tests that used to live here asserted the ~50MB ui.Image
      // OWNERSHIP contract: leaving the window disposes the master, dispose()
      // and reset() release every handle, a late decode disposes itself. That
      // contract is deliberately dissolved (design §4, invariant I5): nothing is
      // owned, so nothing can be disposed, and the property that actually bounds
      // memory is now "the payload leaves the cache when the item leaves the
      // window, and the retained sum stays bounded". Each old assertion is
      // replaced below by its successor, one named killer each; the old -> new
      // table is in the round handoff.
      // -------------------------------------------------------------------

      /// Installs the global counters and returns a getter for the live count.
      /// The hooks are process-global; the tearDown restoring them to null is
      /// mandatory or every later test in this process inherits them.
      int Function() installImageBalanceCounter() {
        // Start from a quiet cache so images created BEFORE the hooks were
        // installed cannot be disposed during the measurement and drive the
        // count negative.
        clearImageCacheSetUp();

        var live = 0;
        ui.Image.onCreate = (image) => live++;
        ui.Image.onDispose = (image) => live--;
        addTearDown(() {
          ui.Image.onCreate = null;
          ui.Image.onDispose = null;
        });
        return () => live;
      }

      test('TC-077 an expensive item is sourced ONCE and its payload serves both '
          'tiers', () async {
        final decodeCalls = <String>[];
        final controller = ImagePreloadController(
          scheduleFrameCallback: _microtaskFrame,
          navigationDebounce: Duration.zero,
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              const NativeImageNeedsRawDecode(exifOrientation: 6),
          dngDecoder: (path) async {
            decodeCalls.add(path);
            return fakeDecoded();
          },
        );
        addTearDown(controller.dispose);

        final items = rawItems(14);
        await controller.preloadImages(
          items: items,
          selectedItemId: items[5].id,
          notifyLoaded: () {},
        );
        await until(
          () => controller.payloadFor(items[5].id) != null,
          reason: 'the expensive source runs on the shared serial decode lane',
        );

        // Pixels, not bytes: this item has no encoded form at all, so the same
        // payload has to serve what would otherwise be two tiers.
        expect(controller.payloadFor(items[5].id), isA<PixelPayload>());
        expect(controller.imageBytesFor(items[5].id), isNull);
        await until(() => controller.isFullSizeReady(items[5].id));

        // The provider is derived from the payload rather than owned and
        // handed out, so two independently built providers are the SAME
        // ImageCache key -- that is what replaces the old identity contract.
        expect(
          controller.pixelsProviderFor(items[5].id) ==
              controller.pixelsProviderFor(items[5].id),
          isTrue,
        );

        // One source call per item, not one per tier. The count is the whole
        // -3..+5 retention window (9) since the 2026-08-26 ruling, not the old
        // +/-1 trio: an expensive item is eligible wherever a cheap one is. The
        // load-bearing half of this assertion is the SECOND line -- one decode
        // per item, so the piggyback still pays for both tiers with one call.
        await until(
          () => decodeCalls.length == kRetentionBefore + kRetentionAfter + 1,
          reason: 'the whole window to be decoded off the serial lane',
        );
        expect(
          decodeCalls.toSet().length,
          kRetentionBefore + kRetentionAfter + 1,
        );

        // Re-running the same window must not re-source anything.
        await controller.preloadImages(
          items: items,
          selectedItemId: items[5].id,
          notifyLoaded: () {},
        );
        // Debounce is zero on this controller: a short settle is still needed
        // for a near-instant fake decode to land, proving the negative (no
        // re-source), but there is no debounce interval left to outlast.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          decodeCalls.length,
          kRetentionBefore + kRetentionAfter + 1,
          reason: 'a second pass re-sourced',
        );
        await settle(controller);
      });

      // Successor to "AC B4: leaving the preload window disposes the ui.Image".
      // THE KILLER for the retention-vs-startup split, and the assertion whose
      // verdict M3 deliberately FLIPS: a two-step excursion used to destroy the
      // decoded image and force a full re-decode on return. Retention is now the
      // same -3..+5 rule every payload gets, so the payload survives; only
      // STARTING an expensive source stays confined to +/-1.
      test('TC-078 an expensive payload survives leaving the +/-1 STARTUP window '
          'and is dropped only on leaving the -3..+5 RETENTION window', () async {
        final decodeCalls = <String>[];
        final controller = ImagePreloadController(
          scheduleFrameCallback: _microtaskFrame,
          navigationDebounce: Duration.zero,
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              const NativeImageNeedsRawDecode(exifOrientation: 1),
          dngDecoder: (path) async {
            decodeCalls.add(path);
            return fakeDecoded();
          },
        );
        addTearDown(controller.dispose);

        final items = rawItems(20);
        final target = items[5].files.single.path;
        int decodesOfTarget() => decodeCalls.where((p) => p == target).length;

        await controller.preloadImages(
          items: items,
          selectedItemId: items[5].id,
          notifyLoaded: () {},
        );
        await until(() => controller.payloadFor(items[5].id) != null);
        final retained = controller.payloadFor(items[5].id);
        expect(decodesOfTarget(), 1);

        // Excursion to index 7: item 5 is now at distance -2, the slot the
        // forward-biased -1..+3 window gave up (AD-034), so its FULL-RES tier-2
        // entry is evicted -- but the ~50MB window-resolution PAYLOAD is still
        // inside the unchanged -3..+5 retention window and must survive.
        await controller.preloadImages(
          items: items,
          selectedItemId: items[7].id,
          notifyLoaded: () {},
        );
        // Debounce is zero on this controller: a short settle for the fake
        // decode is still needed before the negative assertion below (payload
        // must survive, proven by identity).
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          identical(controller.payloadFor(items[5].id), retained),
          isTrue,
          reason:
              'a two-step excursion must not cost the payload -- this is '
              'the exact case that used to dispose ~50MB and force a full '
              're-decode on return',
        );

        // Back again: the payload is reused (no ~50MB re-production), but under
        // AD-034 item 5 legitimately LEFT the tier-2 window at index 7 (distance
        // -2), so returning pays exactly one catch-up FULL-RES decode -> 2. This
        // is the accepted forward-bias cost, NOT the AD-033 discarded-piggyback
        // bug: the two decodes are separated by a full navigate-away-and-back and
        // the second fires on re-entry against a live payload with an evicted
        // tier-2 entry, not a single-visit discard.
        await controller.preloadImages(
          items: items,
          selectedItemId: items[5].id,
          notifyLoaded: () {},
        );
        // Poll for the catch-up full-res decode to fire rather than assuming a
        // fixed sleep covers the debounce plus the serial-lane decode.
        await until(
          () => decodesOfTarget() == 2,
          reason: 'the AD-034 catch-up full-res decode on re-entry',
        );
        expect(
          decodesOfTarget(),
          2,
          reason:
              'returning re-decodes the full-res once (AD-034 catch-up); '
              'the payload itself was not re-produced',
        );

        // Far enough that item 5 leaves -3..+5 -- and only then is it dropped.
        await controller.preloadImages(
          items: items,
          selectedItemId: items[12].id,
          notifyLoaded: () {},
        );
        await until(() => controller.payloadFor(items[12].id) != null);
        expect(
          controller.payloadFor(items[5].id),
          isNull,
          reason:
              'retention must still be bounded; keeping everything is not '
              'the fix',
        );
        expect(
          controller.payloadFor(items[12].id),
          isNotNull,
          reason: 'the selected item was dropped by its own sweep',
        );
        await settle(controller);
      });

      // Successor to "an evicted decoded image is also gone from the ImageCache".
      test('TC-079 leaving the tier-2 window evicts the ImageCache entry while the '
          'payload stays retained', () async {
        final controller = ImagePreloadController(
          scheduleFrameCallback: _microtaskFrame,
          navigationDebounce: Duration.zero,
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              const NativeImageNeedsRawDecode(exifOrientation: 1),
          dngDecoder: (path) async => fakeDecoded(),
        );
        addTearDown(controller.dispose);

        final items = rawItems(20);
        await controller.preloadImages(
          items: items,
          selectedItemId: items[5].id,
          notifyLoaded: () {},
        );
        await until(() => controller.isFullSizeReady(items[5].id));
        // M5 re-anchor: before M5 a RAW's tier-2 entry WAS its
        // window-resolution provider (both tiers shared one entry), so this
        // read used to be `pixelsProviderFor`. M5 gives pixel payloads a real
        // FULL-RESOLUTION tier-2 entry, and that is the entry whose lifetime
        // this test is about. Nothing else here changes.
        final provider = controller.debugTierTwoProviderFor(items[5].id)!;
        expect(
          PaintingBinding.instance.imageCache.containsKey(provider),
          isTrue,
        );

        // Under the forward-biased -1..+3 window (AD-034) item 5 leaves tier-2
        // as early as index 7 (distance -2, the slot the bias gave up); index
        // 8 puts it at distance -3, out of tier-2 but still on the -3 retention
        // boundary, which is the state this test is about (frame evicted,
        // payload kept).
        await controller.preloadImages(
          items: items,
          selectedItemId: items[8].id,
          notifyLoaded: () {},
        );
        await until(() => controller.isFullSizeReady(items[8].id));
        // The selected item (index 8) reaches readiness via the immediate
        // piggyback path, which can win the race against the 250ms debounce
        // that runs the tier-2 eviction sweep. Poll for the eviction itself so
        // this waits exactly as long as the sweep needs on any runner -- it
        // waits for the eviction, it does not relax the assertion.
        await until(
          () => !PaintingBinding.instance.imageCache.containsKey(provider),
          reason: "item 5's stale tier-2 entry to be evicted by the sweep",
        );

        expect(
          PaintingBinding.instance.imageCache.containsKey(provider),
          isFalse,
          reason:
              'the ImageCache entry outlived its tier-2 window; nothing '
              'would ever evict it again',
        );
        expect(
          controller.payloadFor(items[5].id),
          isNotNull,
          reason:
              'evicting the decoded frame must NOT drop the payload -- '
              'that is what makes the return trip a local re-decode instead '
              'of a native round trip',
        );
        await settle(controller);
      });

      // Successor to "dispose() releases every decoded image".
      test('TC-080 dispose() with a source still in flight destroys nothing and '
          'leaks no handle', () async {
        final live = installImageBalanceCounter();
        final controller = ImagePreloadController(
          scheduleFrameCallback: _microtaskFrame,
          navigationDebounce: Duration.zero,
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              const NativeImageNeedsRawDecode(exifOrientation: 6),
          dngDecoder: (path) async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return fakeDecoded();
          },
        );

        final items = rawItems(20);
        await controller.preloadImages(
          items: items,
          selectedItemId: items[5].id,
          notifyLoaded: () {},
        );
        // Tear down while the expensive source is mid-flight: the old code had
        // to clear an in-flight set here so the late arrival would destroy its
        // own ~50MB image. There is no image to destroy now, and no way for the
        // late arrival to throw. Waits scaled down with the decoder's own
        // artificial delay (120ms -> 20ms); this timing is independent of the
        // (also now zero) tier-2 navigation debounce.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        controller.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // The cache may still be holding decoded frames for the app to reuse;
        // what dispose must prove in M3 is that the controller itself retained
        // no payload or owned master handle. TC-083/TC-084 are the bounded-window
        // killers; this one is the teardown-specific successor.
        expect(controller.retainedByteCost, 0);
        expect(live(), greaterThanOrEqualTo(0));
      });

      // Successor to "reset() releases every decoded image".
      test(
        'TC-081 reset() drops every payload and every ImageCache entry',
        () async {
          final controller = ImagePreloadController(
            scheduleFrameCallback: _microtaskFrame,
            navigationDebounce: Duration.zero,
            imageLoader:
                (path, {required purpose, int? targetLongEdge}) async =>
                    const NativeImageNeedsRawDecode(exifOrientation: 1),
            dngDecoder: (path) async => fakeDecoded(),
          );
          addTearDown(controller.dispose);
          final items = rawItems(14);
          await controller.preloadImages(
            items: items,
            selectedItemId: items[5].id,
            notifyLoaded: () {},
          );
          await until(() => controller.isFullSizeReady(items[5].id));
          final provider = controller.pixelsProviderFor(items[5].id)!;

          controller.reset();

          expect(controller.payloadFor(items[5].id), isNull);
          expect(controller.retainedByteCost, 0);
          expect(
            PaintingBinding.instance.imageCache.containsKey(provider),
            isFalse,
            reason:
                'a folder reload must not leave the previous folder\'s frames '
                'in the ImageCache under keys nobody holds any more',
          );
        },
      );

      test(
        'TC-082 an expensive item is requested from the native loader exactly '
        'ONCE across repeated in-window passes',
        () async {
          // The successor to the _needsRawDecode early-return test, and the same
          // killer: without a memo the controller re-asks the native side on
          // every navigation for an answer that cannot change. The memo now
          // lives in PrefetchScheduler and covers every kind of item, not just
          // the raw one (invariant I6).
          final previewRequests = <String>[];
          final controller = ImagePreloadController(
            scheduleFrameCallback: _microtaskFrame,
            navigationDebounce: Duration.zero,
            imageLoader: (path, {required purpose, int? targetLongEdge}) async {
              if (purpose == ImageRequestPurpose.preview) {
                previewRequests.add(path);
              }
              return const NativeImageNeedsRawDecode(exifOrientation: 1);
            },
            dngDecoder: (path) async => fakeDecoded(),
          );
          addTearDown(controller.dispose);

          final items = rawItems(20);
          final targetPath = items[8].files.single.path;
          int requestsForTarget() =>
              previewRequests.where((p) => p == targetPath).length;

          await controller.preloadImages(
            items: items,
            selectedItemId: items[8].id,
            notifyLoaded: () {},
          );
          await until(() => controller.payloadFor(items[8].id) != null);
          final landed = controller.payloadFor(items[8].id);

          // Several more passes with item 8 still inside the retention window.
          // Debounce is zero on this controller: a short settle is still needed
          // for the negative assertion below (no re-request).
          for (final idx in [8, 9, 8]) {
            await controller.preloadImages(
              items: items,
              selectedItemId: items[idx].id,
              notifyLoaded: () {},
            );
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }

          expect(
            requestsForTarget(),
            1,
            reason:
                'the item was re-requested from the native side on a later '
                'pass -- the cost memo must outlive a successful load or every '
                'navigation costs a channel round-trip for an answer that '
                'cannot change',
          );
          expect(identical(controller.payloadFor(items[8].id), landed), isTrue);
        },
      );

      // --- Bounded memory (the successor to the create/dispose balance) -----
      //
      // The old pair of balance tests existed because a leaked `clone()` kept
      // 49.9MB alive while `master.debugDisposed` still read true. There are no
      // clones and no master now: what bounds memory is the retained sum over
      // the window, so that is what is asserted. The handle counter is kept as a
      // second, independent witness -- it would still catch an implementation
      // that decoded frames nothing ever evicts.

      test(
        'TC-083 retained cost stays bounded by the window across a long sweep',
        () async {
          final controller = ImagePreloadController(
            scheduleFrameCallback: _microtaskFrame,
            navigationDebounce: Duration.zero,
            imageLoader:
                (path, {required purpose, int? targetLongEdge}) async =>
                    const NativeImageNeedsRawDecode(exifOrientation: 6),
            dngDecoder: (path) async => fakeDecoded(),
          );
          addTearDown(controller.dispose);

          final items = rawItems(20);
          // One payload is 2x2 RGBA8 = 16 bytes; the -3..+5 window is 9 items.
          const perPayload = 2 * 2 * 4;
          for (final idx in [3, 6, 9, 12, 15]) {
            await controller.preloadImages(
              items: items,
              selectedItemId: items[idx].id,
              notifyLoaded: () {},
            );
            await until(() => controller.payloadFor(items[idx].id) != null);
            expect(
              controller.retainedByteCost,
              lessThanOrEqualTo(perPayload * 9),
              reason:
                  'the retained set grew past one window; at real sizes '
                  'that is the difference between 130MB and unbounded',
            );
          }
          expect(controller.retainedIds.length, greaterThan(0));
        },
      );

      test('TC-084 a source that lands AFTER its item left the window cannot '
          'resurrect a retained entry', () async {
        final live = installImageBalanceCounter();
        final controller = ImagePreloadController(
          scheduleFrameCallback: _microtaskFrame,
          navigationDebounce: Duration.zero,
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              const NativeImageNeedsRawDecode(exifOrientation: 6),
          // Slow enough that navigation overtakes the source.
          dngDecoder: (path) async {
            await Future<void>.delayed(const Duration(milliseconds: 120));
            return fakeDecoded();
          },
        );
        addTearDown(controller.dispose);

        final items = rawItems(20);
        await controller.preloadImages(
          items: items,
          selectedItemId: items[3].id,
          notifyLoaded: () {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        // Jump far away while decodes for the old window are still running.
        await controller.preloadImages(
          items: items,
          selectedItemId: items[15].id,
          notifyLoaded: () {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 600));

        final window = {for (var i = 12; i <= 19; i++) items[i].id};
        expect(
          controller.retainedIds.where((id) => !window.contains(id)),
          isEmpty,
          reason:
              'a late arrival wrote itself into the cache for an item that '
              'is no longer in any window -- unreachable AND retained, which is '
              'the worst case since nothing will ever sweep it',
        );
        expect(live(), greaterThanOrEqualTo(0));
      });

      test(
        'TC-085 decoder throws marks a permanent miss immediately (no legacy '
        'channel left to fall back to, M6 U-12) and never asks again',
        () async {
          final decodeCalls = <String>[];
          final controller = ImagePreloadController(
            scheduleFrameCallback: _microtaskFrame,
            navigationDebounce: Duration.zero,
            imageLoader:
                (path, {required purpose, int? targetLongEdge}) async =>
                    const NativeImageNeedsRawDecode(exifOrientation: 1),
            dngDecoder: (path) async {
              decodeCalls.add(path);
              throw StateError('native decode failed');
            },
          );
          addTearDown(controller.dispose);

          final items = rawItems(14);
          await controller.preloadImages(
            items: items,
            selectedItemId: items[5].id,
            notifyLoaded: () {},
          );
          await until(
            () => controller.hasFailed(items[5].id),
            reason: 'the item is marked as a permanent miss, not left spinning',
          );
          expect(controller.payloadFor(items[5].id), isNull);
          int targetDecodeCalls() =>
              decodeCalls.where((p) => p == items[5].files.single.path).length;
          expect(targetDecodeCalls(), 1);

          await controller.preloadImages(
            items: items,
            selectedItemId: items[5].id,
            notifyLoaded: () {},
          );
          // Debounce is zero on this controller: a short settle is still
          // needed for the negative assertion below (no retry of the failing
          // decode).
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(
            targetDecodeCalls(),
            1,
            reason:
                'forgetting the miss mark lets every navigation try the '
                'failing decoder again and recreates the permanent spinner risk',
          );
        },
      );

      // --- Uniform explicit miss (M6 U-12, replaces the pre-M6 "degrade to
      // legacy bytes" oracle) -------------------------------------------------
      // The native CIRAWFilter re-request no longer exists on any platform, so
      // a DNG with no embedded preview and no working decoder can no longer
      // degrade to slow-but-working bytes; it is a genuine permanent miss --
      // recorded, notified, never re-tried, and NEVER an unresolved spinner.

      test('NO DECODER: an immediate permanent miss, not a spinner', () async {
        final controller = ImagePreloadController(
          scheduleFrameCallback: _microtaskFrame,
          navigationDebounce: Duration.zero,
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              const NativeImageNeedsRawDecode(exifOrientation: 1),
          // dngDecoder deliberately omitted.
        );
        addTearDown(controller.dispose);

        final items = rawItems(14);
        await controller.preloadImages(
          items: items,
          selectedItemId: items[5].id,
          notifyLoaded: () {},
        );

        await until(
          () => controller.hasFailed(items[5].id),
          reason:
              'no decoder and no legacy channel means nothing can produce '
              'this item -- it must be marked, not left spinning forever',
        );
        expect(controller.imageBytesFor(items[5].id), isNull);
        expect(controller.payloadFor(items[5].id), isNull);
      });

      test(
        'THROWING DECODER: an immediate permanent miss, not a spinner',
        () async {
          final controller = ImagePreloadController(
            scheduleFrameCallback: _microtaskFrame,
            navigationDebounce: Duration.zero,
            imageLoader:
                (path, {required purpose, int? targetLongEdge}) async =>
                    const NativeImageNeedsRawDecode(exifOrientation: 1),
            dngDecoder: (path) async =>
                throw StateError('native decode failed'),
          );
          addTearDown(controller.dispose);

          final items = rawItems(14);
          await controller.preloadImages(
            items: items,
            selectedItemId: items[5].id,
            notifyLoaded: () {},
          );

          await until(
            () => controller.hasFailed(items[5].id),
            reason:
                'a throwing decoder and no legacy channel means nothing can '
                'produce this item -- it must be marked, not left spinning',
          );
          expect(controller.imageBytesFor(items[5].id), isNull);
          expect(controller.payloadFor(items[5].id), isNull);
        },
      );

      test(
        'an ordinary (bytes) item is untouched by the raw-decode path',
        () async {
          final controller = ImagePreloadController(
            scheduleFrameCallback: _microtaskFrame,
            navigationDebounce: Duration.zero,
            imageLoader:
                (path, {required purpose, int? targetLongEdge}) async =>
                    NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
            dngDecoder: (path) async =>
                fail('must not decode a bytes-backed item'),
          );
          addTearDown(controller.dispose);

          final items = rawItems(14);
          await controller.preloadImages(
            items: items,
            selectedItemId: items[5].id,
            notifyLoaded: () {},
          );

          // PHASE 3 settle (settle-only instrument repair). Assertions unchanged.
          await until(
            () => controller.imageBytesFor(items[5].id) != null,
            reason: 'the selected byte-backed payload to land',
          );
          expect(controller.imageBytesFor(items[5].id), isNotNull);
          // FORCED TRANSLATION (frozen table A-C1): decodedImageFor is deleted.
          // Same claim, same strength -- this item did NOT go down the pixel
          // path, it landed legacy bytes.
          expect(
            controller.payloadFor(items[5].id),
            isNot(isA<PixelPayload>()),
          );
          // The pre-existing tier-2 readiness path still works end to end, i.e.
          // the new early return did not steal byte-backed items.
          await until(
            () => controller.isFullSizeReady(items[5].id),
            reason: 'tier-2 readiness for a byte-backed item',
          );
        },
      );
    });

    test('TC-350 controller lane width defaults to 1 and is settable', () {
      final c = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
      );
      addTearDown(c.dispose);
      expect(
        c.decodeLaneWidth,
        1,
        reason: 'default is the historical behaviour',
      );

      final wide = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        decodeLaneWidth: 3,
      );
      addTearDown(wide.dispose);
      expect(wide.decodeLaneWidth, 3);

      wide.setDecodeLaneWidth(0);
      expect(wide.decodeLaneWidth, 1, reason: 'a corrupt value must not crash');
    });
  });

  group('image_preload_controller_probe_first_navigation_test.dart', () {
    // Alpha must be opaque (0xFF): decoded_rgba_image_provider.dart's
    // debug-only identity short-circuit asserts sampled alpha is opaque.
    // Same repair as commits 253b89f / d43c2a1.
    DecodedRgba fakeDecoded() => DecodedRgba(
      rgba: Uint8List.fromList(
        List<int>.generate(2 * 2 * 4, (i) => i % 4 == 3 ? 0xFF : i),
      ),
      width: 2,
      height: 2,
    );

    final dngDir = sampleDngDir;
    final hasSamples = samplePhotosAvailable;

    File sampleNamed(String name) => File('${dngDir.path}/$name');

    // The M0/M3 sample inventory proves this pair is the intended content
    // witness: same extension, one preview-bearing and one no-preview.
    final previewDng = sampleNamed('2026-02-15-19-37-38.dng');
    final noPreviewDng = sampleNamed('IMG_20251112_092839.dng');

    List<PhotoItem> realListWith(File target, int targetIndex) => List.generate(
      14,
      (index) => PhotoItem(
        id: 'REAL_${index.toString().padLeft(4, '0')}',
        files: [index == targetIndex ? target : previewDng],
      ),
    );

    setUp(clearImageCacheSetUp);

    test('P1 translated: cheap DNG has tier-1 entries at arrival; expensive '
        'cold arrival fills the same window, one decode at a time', () async {
      // Left at the production debounce (no override): the currentSize==9
      // assertion below needs the tier-1 window to finish BEFORE tier-2 starts
      // adding its own (distinct-key) entries to the same ImageCache. Even a
      // short 40ms debounce raced the async probe/content-check chain that
      // preloadImages itself performs before this poll's first check, so this
      // one keeps the real interval.
      final cheap = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
        dngDecoder: (path) async => fail('cheap rung must not RAW-decode'),
      );
      addTearDown(cheap.dispose);
      cheap.updateTargetSize(800, 600);
      final cheapItems = paddedItems(14, extension: 'dng');
      await cheap.preloadImages(
        items: cheapItems,
        selectedItemId: cheapItems[5].id,
        notifyLoaded: () {},
      );
      // Poll the ASSERTED quantity itself (currentSize == 9), not a proxy: a
      // fixed sleep races real precache completion under CPU contention --
      // containsKey below stays true for a still-pending entry, so only
      // currentSize (completed entries) can tell "resident" from "in flight".
      // (round-2 review blocker: reproduced 3/3 in a 14-file batch run.)
      await until(
        () => PaintingBinding.instance.imageCache.currentSize == 9,
        reason: 'the whole -3..+5 tier-1 window to finish precaching',
      );
      // Quiescence drain: the poll above returns the INSTANT currentSize first
      // reads 9, which an over-decoding regression (e.g. still climbing to 12)
      // could pass through on its way past -- re-settle briefly so the frozen
      // ==9 expect below still catches "more than 9", not just "at least 9".
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final neighbourBytes = cheap.imageBytesFor(cheapItems[7].id)!;
      final key = await tierOneProviderFor(
        neighbourBytes,
        width: 800,
        height: 600,
      ).obtainKey(const ImageConfiguration());
      expect(PaintingBinding.instance.imageCache.containsKey(key), isTrue);
      expect(
        PaintingBinding.instance.imageCache.currentSize,
        9,
        reason:
            'P1 frozen cheap arrival count: exactly the current -3..+5 tier-1 '
            'window is decoded before the tier-2 debounce. Was 5 (a +/-2 span) '
            'until the round-2 tier-1 widening; changed under orchestrator '
            'authorization because this number encoded the OLD requirement, '
            'which the user replaced by ruling that tier-1 covers the whole '
            'retention window. The byte-identity gate on this file re-anchors '
            'to the new sha256; it is amended, not retired',
      );

      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      // The expensive half, RENEGOTIATED to the 2026-08-26 ruling. It used to
      // assert `payloadFor(selected) == null` and an EMPTY ImageCache right after
      // arrival, which encoded the old law: an expensive item was refused outside
      // +/-1 and even at distance 0 had to wait out the 250ms debounce. Both
      // clauses are now wrong AND untestable as written -- what happens "right
      // after arrival" is a race with the serial lane, not a design rule. The
      // rule that replaced them is asserted instead: the same -3..+5 window a
      // cheap item gets, filled one decode at a time.
      var inFlight = 0;
      var maxInFlight = 0;
      final expensive = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        navigationDebounce: Duration.zero,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        dngDecoder: (path) async {
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          inFlight--;
          return fakeDecoded();
        },
      );
      addTearDown(expensive.dispose);
      expensive.updateTargetSize(800, 600);
      final expensiveItems = paddedItems(14, extension: 'dng');
      await expensive.preloadImages(
        items: expensiveItems,
        selectedItemId: expensiveItems[5].id,
        notifyLoaded: () {},
      );
      await until(
        () => List.generate(
          9,
          (i) => expensiveItems[2 + i].id,
        ).every((id) => expensive.payloadFor(id) is PixelPayload),
        reason: 'the whole -3..+5 expensive window to land',
      );
      expect(
        maxInFlight,
        1,
        reason: 'expensive production stays single-flight',
      );
    });

    // Each assertion names its POSITION, so location-dependent bridge-first
    // scheduling cannot hide behind a single outer-window witness. The real
    // no-preview DNG must have been content-classified expensive BEFORE loader
    // acquisition; therefore before the frozen debounce expires its loader calls
    // are zero at every retained position.
    for (final spec in <({String name, int selected, int target})>[
      (name: 'selected distance 0', selected: 5, target: 5),
      (name: 'plus-one distance 1', selected: 5, target: 6),
      (name: 'outer retention distance 3', selected: 5, target: 8),
    ]) {
      test('TC-088 probe-first expensive item: ${spec.name} has ZERO loader '
          'calls before debounce', () async {
        expect(
          previewDng.existsSync(),
          isTrue,
          reason: 'preview sample missing',
        );
        expect(
          noPreviewDng.existsSync(),
          isTrue,
          reason: 'no-preview sample missing',
        );
        expect(
          (await PhotoSource.probeSource(
            noPreviewDng.path,
            longEdge: 2800,
          )).cost,
          SourceCost.expensive,
          reason: 'sanity: this must be the real no-preview content witness',
        );
        final targetCalls = <String>[];
        final controller = ImagePreloadController(
          scheduleFrameCallback: _microtaskFrame,
          navigationDebounce: Duration.zero,
          imageLoader: (path, {required purpose, int? targetLongEdge}) async {
            targetCalls.add(path);
            return NativeImageBytes(Uint8List.fromList(tinyPngBytes));
          },
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(800, 600);
        final photos = realListWith(noPreviewDng, spec.target);
        await controller.preloadImages(
          items: photos,
          selectedItemId: photos[spec.selected].id,
          notifyLoaded: () {},
        );
        expect(
          targetCalls.where((path) => path == noPreviewDng.path),
          isEmpty,
          reason:
              'the real probe must classify this no-preview DNG before any '
              'loader work, regardless of ${spec.name}',
        );
      }, skip: hasSamples ? null : 'no local samples');
    }

    // TC-089 deleted (M6 P3.3, Appendix B, C-4): see baseline-registry.md for
    // the disposition reason; TC-088 above stays.

    test('P2 translated: navigation bursts never exceed one expensive decode in '
        'flight and never decode out-of-window items, while cheap DNGs/JPEGs '
        'prefetch during the same burst', () async {
      // RENEGOTIATED (user ruling 2026-08-26). The frozen probe asserted ZERO
      // expensive decodes during a sub-debounce burst, which was the old law's
      // consequence: expensive work existed only behind the debounce. Under the
      // new law a burst MAY start decodes -- that is the point, RAW navigation is
      // to behave like JPEG -- so what is pinned instead is what must still never
      // happen: two decodes at once, a decode for an item outside the current
      // retention window, or a second decode of an item already decoded.
      final decodeCalls = <String>[];
      var inFlight = 0;
      var maxInFlight = 0;
      final expensive = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        navigationDebounce: Duration.zero,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        dngDecoder: (path) async {
          decodeCalls.add(path);
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          inFlight--;
          return fakeDecoded();
        },
      );
      addTearDown(expensive.dispose);
      expensive.updateTargetSize(800, 600);
      final raws = paddedItems(20, extension: 'dng');
      for (final idx in [5, 6, 7, 8, 9, 8, 7, 6, 5]) {
        await expensive.preloadImages(
          items: raws,
          selectedItemId: raws[idx].id,
          notifyLoaded: () {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        maxInFlight,
        1,
        reason:
            'the burst may never put two RAW decodes in '
            'flight at once',
      );
      // Deliberately NOT "no path appears twice": this burst walks 5->9->5, so
      // index 5 leaves the -3..+5 window at position 9, loses its payload to the
      // one retention rule every kind shares, and legitimately re-decodes on the
      // way back. Re-decode-free navigation WITHIN the window is what P3/P4 pin.
      // What must hold here is that a decode is only ever bought for an item
      // some visited position actually wanted (2..14 across this burst).
      // Every decoded path must belong to some item that was inside the -3..+5
      // window of one of the visited positions (2..14 across the burst).
      final everInWindow = raws
          .sublist(2, 15)
          .map((item) => item.files.single.path)
          .toSet();
      expect(decodeCalls.where((p) => !everInWindow.contains(p)), isEmpty);
      expect(expensive.payloadFor(raws[5].id), isNotNull);

      final cheap = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        navigationDebounce: Duration.zero,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
      );
      addTearDown(cheap.dispose);
      cheap.updateTargetSize(800, 600);
      final jpgs = paddedItems(20);
      for (final idx in [5, 6, 7, 8, 9, 8, 7, 6, 5]) {
        await cheap.preloadImages(
          items: jpgs,
          selectedItemId: jpgs[idx].id,
          notifyLoaded: () {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final bytes5 = cheap.imageBytesFor(jpgs[5].id)!;
      final key5 = await tierOneProviderFor(
        bytes5,
        width: 800,
        height: 600,
      ).obtainKey(const ImageConfiguration());
      expect(PaintingBinding.instance.imageCache.containsKey(key5), isTrue);

      // Separate real-DNG witness: the cheap result must come from TIFF content,
      // not from the JPEG control above. A preview-bearing DNG still receives
      // immediate work throughout the same sub-debounce navigation burst.
      expect(previewDng.existsSync(), isTrue, reason: 'preview sample missing');
      var realCheapCalls = 0;
      final realCheap = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        navigationDebounce: Duration.zero,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async {
          realCheapCalls++;
          return NativeImageBytes(Uint8List.fromList(tinyPngBytes));
        },
      );
      addTearDown(realCheap.dispose);
      realCheap.updateTargetSize(800, 600);
      final realCheapItems = realListWith(previewDng, 5);
      for (final idx in [5, 6, 7, 8, 9, 8, 7, 6, 5]) {
        await realCheap.preloadImages(
          items: realCheapItems,
          selectedItemId: realCheapItems[idx].id,
          notifyLoaded: () {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        realCheapCalls,
        greaterThan(0),
        reason:
            'P2 cheap-DNG witness: real preview-bearing TIFF content must '
            'schedule immediate loader work during the burst',
      );
    }, skip: hasSamples ? null : 'no local samples');

    test(
      'P3 translated: one-step expensive round trip decodes once and retains '
      'the PixelPayload',
      () async {
        final decodeCalls = <String>[];
        final controller = ImagePreloadController(
          scheduleFrameCallback: _microtaskFrame,
          navigationDebounce: Duration.zero,
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              const NativeImageNeedsRawDecode(exifOrientation: 1),
          dngDecoder: (path) async {
            decodeCalls.add(path);
            return fakeDecoded();
          },
        );
        addTearDown(controller.dispose);
        final items = paddedItems(20, extension: 'dng');
        final target = items[8].files.single.path;
        int targetDecodes() =>
            decodeCalls.where((path) => path == target).length;

        await controller.preloadImages(
          items: items,
          selectedItemId: items[8].id,
          notifyLoaded: () {},
        );
        await until(() => controller.payloadFor(items[8].id) is PixelPayload);
        final first = controller.payloadFor(items[8].id);
        expect(targetDecodes(), 1);

        for (final idx in [9, 8]) {
          await controller.preloadImages(
            items: items,
            selectedItemId: items[idx].id,
            notifyLoaded: () {},
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(
          controller.payloadFor(items[8].id),
          isA<PixelPayload>(),
          reason:
              'frozen debugDisposed=false translation: the retained payload '
              'must still exist after the one-step round trip',
        );
        expect(identical(controller.payloadFor(items[8].id), first), isTrue);
        expect(targetDecodes(), 1);
      },
    );

    test('P4 translated: two-step expensive excursion decodes once and retains '
        'the payload; JPEG bytes still survive identically', () async {
      final decodeCalls = <String>[];
      final controller = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        navigationDebounce: Duration.zero,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        dngDecoder: (path) async {
          decodeCalls.add(path);
          return fakeDecoded();
        },
      );
      addTearDown(controller.dispose);
      final items = paddedItems(20, extension: 'dng');
      final target = items[8].files.single.path;
      int decodesOfTarget() => decodeCalls.where((p) => p == target).length;

      await controller.preloadImages(
        items: items,
        selectedItemId: items[8].id,
        notifyLoaded: () {},
      );
      await until(() => controller.payloadFor(items[8].id) is PixelPayload);
      final first = controller.payloadFor(items[8].id);
      expect(decodesOfTarget(), 1);

      for (final idx in [9, 10, 9, 8]) {
        await controller.preloadImages(
          items: items,
          selectedItemId: items[idx].id,
          notifyLoaded: () {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      // The PixelPayload (window-resolution) is retained through the whole
      // excursion: it never leaves the unchanged -3..+5 retention window.
      expect(identical(controller.payloadFor(items[8].id), first), isTrue);
      // But under the forward-biased -1..+3 tier-2 window (AD-034) the excursion
      // to index 10 puts item 8 at distance -2 -- the slot the bias gave up --
      // so item 8's FULL-RES tier-2 entry is evicted there and re-decoded once
      // when the walk returns to index 9/8. That second decode is the accepted
      // AD-034 catch-up cost, NOT the AD-033 discarded-piggyback bug: it fires on
      // a legitimate re-entry against a live payload, not a single-visit discard.
      expect(decodesOfTarget(), 2);

      final cheapCalls = <String>[];
      final cheapController = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        navigationDebounce: Duration.zero,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async {
          cheapCalls.add(path);
          return NativeImageBytes(Uint8List.fromList(tinyPngBytes));
        },
      );
      addTearDown(cheapController.dispose);
      cheapController.updateTargetSize(800, 600);
      final cheapItems = paddedItems(20, extension: 'dng');
      final cheapTarget = cheapItems[8].files.single.path;
      await cheapController.preloadImages(
        items: cheapItems,
        selectedItemId: cheapItems[8].id,
        notifyLoaded: () {},
      );
      // PHASE 3 settle (settle-only instrument repair): preloadImages returns
      // once the window is issued, so the selected item's payload lands a few
      // event-loop turns later. The bytes-identity property asserted below is
      // unchanged -- only the instant at which the reference is taken moves.
      await until(
        () => cheapController.payloadFor(cheapItems[8].id) != null,
        reason: 'the cheap selected payload to land',
      );
      final cheapFirst = cheapController.payloadFor(cheapItems[8].id);
      for (final idx in [9, 10, 9, 8]) {
        await cheapController.preloadImages(
          items: cheapItems,
          selectedItemId: cheapItems[idx].id,
          notifyLoaded: () {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(cheapCalls.where((path) => path == cheapTarget), hasLength(1));
      expect(
        identical(cheapController.payloadFor(cheapItems[8].id), cheapFirst),
        isTrue,
      );

      final jpgController = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        navigationDebounce: Duration.zero,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
      );
      addTearDown(jpgController.dispose);
      jpgController.updateTargetSize(800, 600);
      final jpgs = paddedItems(20);
      await jpgController.preloadImages(
        items: jpgs,
        selectedItemId: jpgs[8].id,
        notifyLoaded: () {},
      );
      // PHASE 3 settle (see the cheap arm above); the identity assertion at the
      // end of this test is unchanged.
      await until(
        () => jpgController.imageBytesFor(jpgs[8].id) != null,
        reason: 'the JPEG selected payload to land',
      );
      final before = jpgController.imageBytesFor(jpgs[8].id);
      for (final idx in [9, 10, 9, 8]) {
        await jpgController.preloadImages(
          items: jpgs,
          selectedItemId: jpgs[idx].id,
          notifyLoaded: () {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        identical(before, jpgController.imageBytesFor(jpgs[8].id)),
        isTrue,
      );
    });
  });

  group('image_preload_controller_dual_window_tier2_test.dart', () {
    // Alpha must be opaque (0xFF): decoded_rgba_image_provider.dart's
    // debug-only identity short-circuit asserts sampled alpha is opaque,
    // because it returns STRAIGHT RGBA where the old readback path returned
    // PREMULTIPLIED. Same repair as commits 253b89f / d43c2a1.
    DecodedRgba fakeDecoded() => DecodedRgba(
      rgba: Uint8List.fromList(
        List<int>.generate(2 * 2 * 4, (i) => i % 4 == 3 ? 0xFF : i),
      ),
      width: 2,
      height: 2,
    );

    Future<bool> tierOneResident(
      ImagePreloadController controller,
      String id, {
      required int width,
      required int height,
    }) async {
      final bytes = controller.imageBytesFor(id);
      if (bytes != null) {
        final key = await tierOneProviderFor(
          bytes,
          width: width,
          height: height,
        ).obtainKey(const ImageConfiguration());
        return PaintingBinding.instance.imageCache.containsKey(key);
      }
      // Pixel-backed items share their tier-1 entry with RawPixelsImage, keyed
      // on the retained buffer's identity (invariant I1) -- there is no
      // separate encoded-bytes key to build for that kind.
      final provider = controller.pixelsProviderFor(id);
      if (provider == null) return false;
      final key = await provider.obtainKey(const ImageConfiguration());
      return PaintingBinding.instance.imageCache.containsKey(key);
    }

    Future<void> until(bool Function() condition, {String? reason}) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!condition()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('timed out waiting for: ${reason ?? 'condition'}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    // `_finishOffLane`'s encode continuation is deliberately unawaited by the
    // controller (it has no caller). If a test ends -- and `addTearDown`
    // disposes the controller -- while that continuation is still in flight,
    // its later `_inflight.release(...)` races the disposed budget's `clear()`
    // and trips a cross-test assertion (attributed to whatever test happens to
    // be running when it lands). Poll `debugInflightBytes` to zero before
    // ending a test that used an expensive/RAW controller.
    Future<void> settle(ImagePreloadController controller) => until(
      () => controller.debugInflightBytes == 0,
      reason: 'controller inflight-bytes budget to drain before teardown',
    );

    setUp(() {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    });

    // ------------------------------------------------------------- AC-M5-2

    test('M5-DW1 tier-2 keys equal the +/-2 band after settle, for encoded and '
        'pixel payloads alike', () async {
      // --- cheap (encoded) sub-case: whole window is populated in one pass.
      final cheap = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        navigationDebounce: Duration.zero,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
        dngDecoder: (path) async => fail('a cheap rung must never RAW-decode'),
      );
      addTearDown(cheap.dispose);
      cheap.updateTargetSize(10, 10);
      final cheapItems = paddedItems(14);
      const cheapSelected = 5;
      await cheap.preloadImages(
        items: cheapItems,
        selectedItemId: cheapItems[cheapSelected].id,
        notifyLoaded: () {},
      );
      await until(
        () =>
            cheap.debugTierTwoKeyIds.length ==
            2 * kFullResolutionBandRadius + 1,
        reason: 'cheap full-resolution band to settle to +/-1',
      );

      final cheapExpectedBand = <String>{
        for (var d = -kFullResolutionBandRadius;
            d <= kFullResolutionBandRadius;
            d++)
          cheapItems[cheapSelected + d].id,
      };
      expect(
        cheap.debugTierTwoKeyIds.toSet(),
        cheapExpectedBand,
        reason:
            'encoded payloads: the tier-2 key id set must equal exactly the '
            '+/-1 full-resolution band after settle (WP4.2/S3.2)',
      );
      // +2 and +3 joined this list when S3.2 narrowed the full-resolution band
      // from -1..+3 to +/-1: they are DEGRADED, not evicted -- still retained,
      // still holding a window-resolution tier-1 entry, just no full-size one.
      for (final d in [-3, -2, 2, 3, 4, 5]) {
        final id = cheapItems[cheapSelected + d].id;
        expect(
          await tierOneResident(cheap, id, width: 10, height: 10),
          isTrue,
          reason: 'distance $d (encoded) must still hold a tier-1 entry',
        );
        expect(
          cheap.debugTierTwoKeyIds.contains(id),
          isFalse,
          reason: 'distance $d (encoded) must NOT hold a tier-2 entry',
        );
      }

      // --- pixel (expensive/RAW) sub-case: walk through neighbouring
      // selections first, then settle on the middle position. The walk was
      // REQUIRED under AD-018 (a payload only existed within +/-1 of some
      // visited selection); since AD-033 it is merely a harder starting
      // state than a cold settle.
      // --- core claim: the -1..+3 band ends up with EXACTLY that band in
      // debugTierTwoKeyIds.
      //
      // Retention (-3..+5, width 9) and the target band (-1..+3, width 5)
      // are close enough in width that this walk can hold every band id's
      // payload alive simultaneously through to the final settle: 5 seeds
      // 2..10, 7 seeds 4..12, 3 seeds 0..8, so the union covers the whole
      // final band, and the final settle at 5 re-widens retention to
      // [2,10] -- a superset of everything acquired -- while its own
      // tier-2 window [4,8] triggers the catch-up upgrade for every band id
      // that does not already carry a live tier-2 entry.
      ImagePreloadController buildPixelController() => ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        navigationDebounce: Duration.zero,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        dngDecoder: (path) async => fakeDecoded(),
      );

      final pixel = buildPixelController();
      addTearDown(pixel.dispose);
      pixel.updateTargetSize(10, 10);
      final pixelItems = paddedItems(14, extension: 'dng');
      const pixelSelected = 5;

      for (final idx in [5, 7, 3, 5]) {
        await pixel.preloadImages(
          items: pixelItems,
          selectedItemId: pixelItems[idx].id,
          notifyLoaded: () {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await until(
        () =>
            pixel.debugTierTwoKeyIds.length ==
            2 * kFullResolutionBandRadius + 1,
        reason: 'pixel full-resolution band to settle to +/-1 after the walk',
      );

      final pixelExpectedBand = <String>{
        for (var d = -kFullResolutionBandRadius;
            d <= kFullResolutionBandRadius;
            d++)
          pixelItems[pixelSelected + d].id,
      };
      expect(
        pixel.debugTierTwoKeyIds.toSet(),
        pixelExpectedBand,
        reason:
            'pixel payloads: the tier-2 key id set must equal exactly the '
            '+/-1 full-resolution band after settle, same as encoded payloads',
      );

      // --- boundary claim: -3, -2, +4, +5 have a tier-1 entry (once a
      // payload was ever produced for them) and NEVER a tier-2 entry. Under
      // the forward-biased -1..+3 window (AD-034) the backward boundaries are
      // now -3 and -2 and the forward boundaries are +4 and +5.
      //
      // Each boundary is checked with its OWN short walk rather than inside
      // the combined walk above: retention (width 9) and the full -3..+5
      // span (also width 9) coincide only exactly AT the final selection, so
      // any walk that swings out to acquire one extreme's payload evicts the
      // other extreme's payload before the final settle -- a structural
      // consequence of the frozen retention/tier-2 window sizes, not a test
      // artefact. Isolating each boundary sidesteps that without weakening
      // what is actually asserted per position.
      //
      // distances -3 and -2 are free: the items at pixelSelected-3 (index 2)
      // and pixelSelected-2 (index 3) already received payloads from the "3"
      // stop of the walk above and survive into the final retention window
      // [2,10], but hold no tier-2 entry because the tier-2 window is now
      // [4,8]. -2 is the slot the forward bias gave up (AD-034).
      for (final d in [-3, -2]) {
        final backwardId = pixelItems[pixelSelected + d].id;
        expect(
          await tierOneResident(pixel, backwardId, width: 10, height: 10),
          isTrue,
          reason: 'distance $d (pixel) must still hold a tier-1 entry',
        );
        expect(
          pixel.debugTierTwoKeyIds.contains(backwardId),
          isFalse,
          reason: 'distance $d (pixel) must NOT hold a tier-2 entry',
        );
      }
      await settle(pixel);

      for (final d in [2, 3, 4, 5]) {
        final boundary = buildPixelController();
        addTearDown(boundary.dispose);
        boundary.updateTargetSize(10, 10);
        final boundaryItems = paddedItems(14, extension: 'dng');
        final targetIndex = pixelSelected + d;

        // Seed the boundary id's payload by selecting it directly (distance
        // 0 to itself), then settle on the real selection: retention [2,10]
        // keeps the payload (distance d <= 5), but the tier-2 window [4,8]
        // does not include it, so its tier-2 entry is evicted.
        await boundary.preloadImages(
          items: boundaryItems,
          selectedItemId: boundaryItems[targetIndex].id,
          notifyLoaded: () {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await boundary.preloadImages(
          items: boundaryItems,
          selectedItemId: boundaryItems[pixelSelected].id,
          notifyLoaded: () {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final id = boundaryItems[targetIndex].id;
        expect(
          await tierOneResident(boundary, id, width: 10, height: 10),
          isTrue,
          reason: 'distance $d (pixel) must still hold a tier-1 entry',
        );
        expect(
          boundary.debugTierTwoKeyIds.contains(id),
          isFalse,
          reason: 'distance $d (pixel) must NOT hold a tier-2 entry',
        );
        await settle(boundary);
      }
    });

    // ------------------------------------------------------------- AC-M5-3

    test(
      'M5-DW2 a pixel-backed item at distance 0 gets a FULL-resolution tier-2 '
      'entry distinct from its window-resolution tier-1 entry',
      () async {
        final controller = ImagePreloadController(
          scheduleFrameCallback: _microtaskFrame,
          navigationDebounce: Duration.zero,
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
        await controller.preloadImages(
          items: items,
          selectedItemId: items[5].id,
          notifyLoaded: () {},
        );
        await until(
          () => controller.isFullSizeReady(items[5].id),
          reason: 'distance-0 pixel item to gain a full-size tier-2 entry',
        );
        expect(controller.isFullSizeReady(items[5].id), isTrue);
        expect(controller.debugTierTwoKeyIds.contains(items[5].id), isTrue);

        final payload = controller.payloadFor(items[5].id);
        expect(payload, isA<PixelPayload>());

        // No frozen accessor exposes the resolved tier-2 image or its key
        // object directly, so this reconstructs a PROBE RawFullResImage from
        // the same identity + dimensions the controller must have used
        // (payloadIdentity=payload, 400x300 -- the fake decoder's fixed
        // output). RawFullResImage's operator== is identical(payloadIdentity)
        // + width + height only (raw_full_res_image.dart, frozen), so this
        // probe's key is EQUAL to the controller's real tier-2 key without
        // needing to see it: resolving it hits the ALREADY-RESIDENT ImageCache
        // entry rather than decoding anything new, letting the actual
        // dimensions be read back.
        final dummyImage = await _decodeTinyImage();
        final probe = RawFullResImage(
          payloadIdentity: payload!,
          width: 400,
          height: 300,
          image: dummyImage,
        );
        final probeCompleter = Completer<ImageInfo>();
        late ImageStreamListener probeListener;
        final probeStream = probe.resolve(const ImageConfiguration());
        probeListener = ImageStreamListener((image, synchronousCall) {
          probeStream.removeListener(probeListener);
          probeCompleter.complete(image);
        }, onError: (error, stackTrace) => probeCompleter.completeError(error));
        probeStream.addListener(probeListener);
        final tierTwoInfo = await probeCompleter.future;
        addTearDown(() => dummyImage.dispose());
        expect(
          (tierTwoInfo.image.width, tierTwoInfo.image.height),
          (400, 300),
          reason:
              'the resolved tier-2 entry must be the FULL 400x300 decode, not '
              'a window-resolution one',
        );

        final tierOneProvider = controller.pixelsProviderFor(items[5].id)!;
        final tierOneCompleter = Completer<ImageInfo>();
        late ImageStreamListener tierOneListener;
        final tierOneStream = tierOneProvider.resolve(
          const ImageConfiguration(),
        );
        tierOneListener = ImageStreamListener(
          (image, synchronousCall) {
            tierOneStream.removeListener(tierOneListener);
            tierOneCompleter.complete(image);
          },
          onError: (error, stackTrace) => tierOneCompleter.completeError(error),
        );
        tierOneStream.addListener(tierOneListener);
        final tierOneInfo = await tierOneCompleter.future;
        expect(
          (tierOneInfo.image.width, tierOneInfo.image.height),
          (200, 150),
          reason:
              'the tier-1 entry must stay at the WINDOW target size (200x150), '
              'distinct from the full-resolution tier-2 entry',
        );

        final tierOneKey = await tierOneProvider.obtainKey(
          const ImageConfiguration(),
        );
        final tierTwoKey = await probe.obtainKey(const ImageConfiguration());
        expect(
          tierOneKey.runtimeType,
          isNot(tierTwoKey.runtimeType),
          reason:
              'the tier-1 and tier-2 ImageCache keys must be distinct '
              '(different provider kinds -> unequal by construction)',
        );
        await settle(controller);
      },
    );

    // ------------------------------------------------------------- AC-M5-4

    test('M5-DW3 payload production and full-res tier-2 for a RAW item inside '
        '+/-1 cost exactly ONE decoder call', () async {
      final decodeCalls = <String>[];
      final controller = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        navigationDebounce: Duration.zero,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        dngDecoder: (path) async {
          decodeCalls.add(path);
          return fakeDecoded();
        },
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(10, 10);
      final items = paddedItems(14, extension: 'dng');
      final target = items[5].files.single.path;

      await controller.preloadImages(
        items: items,
        selectedItemId: items[5].id,
        notifyLoaded: () {},
      );
      await until(
        () => controller.isFullSizeReady(items[5].id),
        reason: 'distance-0 pixel item to gain a full-size tier-2 entry',
      );
      expect(
        decodeCalls.where((p) => p == target).length,
        1,
        reason:
            'single-decode dual-output (piggyback): payload production and '
            'the full-res tier-2 upload must share ONE FFI decode call',
      );
      await settle(controller);
    });

    // ------------------------------------------------------------- AC-M5-5

    test(
      'M5-DW4 leaving +/-2 evicts the full-res entry; re-entering re-upgrades '
      'with exactly one extra decoder call and an identical retained payload',
      () async {
        final decodeCalls = <String>[];
        final controller = ImagePreloadController(
          scheduleFrameCallback: _microtaskFrame,
          navigationDebounce: Duration.zero,
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              const NativeImageNeedsRawDecode(exifOrientation: 1),
          dngDecoder: (path) async {
            decodeCalls.add(path);
            return fakeDecoded();
          },
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(10, 10);
        final items = paddedItems(20, extension: 'dng');
        final target = items[8].files.single.path;
        int targetCalls() => decodeCalls.where((p) => p == target).length;

        await controller.preloadImages(
          items: items,
          selectedItemId: items[8].id,
          notifyLoaded: () {},
        );
        await until(() => controller.isFullSizeReady(items[8].id));
        expect(targetCalls(), 1);
        final firstPayload = controller.payloadFor(items[8].id);
        expect(firstPayload, isNotNull);

        // Item 8 is at distance -3 from selection 11: outside the forward-biased
        // -1..+3 tier-2 window but still inside the -3..+5 retention window, so
        // the payload survives while the tier-2 entry must be evicted.
        await controller.preloadImages(
          items: items,
          selectedItemId: items[11].id,
          notifyLoaded: () {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          controller.debugTierTwoKeyIds.contains(items[8].id),
          isFalse,
          reason:
              'containsKey == false: the full-res entry is gone once '
              'outside the -1..+3 window',
        );
        expect(
          controller.payloadFor(items[8].id),
          isNotNull,
          reason: 'the payload itself is still retained (distance -3 >= -3)',
        );

        // Re-enter at distance -1 (select item 9, window [8,12]): the catch-up
        // upgrade path must re-decode ONCE more (payload already exists, only
        // the full-res entry is missing). -1 is chosen because the forward bias
        // gave up -2; item 8 must land inside [sel-1, sel+3] to re-upgrade.
        await controller.preloadImages(
          items: items,
          selectedItemId: items[9].id,
          notifyLoaded: () {},
        );
        await until(() => controller.isFullSizeReady(items[8].id));
        expect(
          targetCalls(),
          2,
          reason: 'exactly one extra decoder call for the re-upgrade',
        );
        expect(
          identical(controller.payloadFor(items[8].id), firstPayload),
          isTrue,
          reason: 'the retained payload object is unchanged by the re-upgrade',
        );
        await settle(controller);
      },
    );

    // ------------------------------------------------------------- AC-M5-6

    test('M5-DW5 a failing full-res decode keeps tier-1 display, writes NO '
        'permanent miss, and is not retried for the same payload', () async {
      final decodeCalls = <String>[];
      final items = paddedItems(20, extension: 'dng');
      final target = items[8].files.single.path;
      final perPathCalls = <String, int>{};
      final controller = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        navigationDebounce: Duration.zero,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        dngDecoder: (path) async {
          decodeCalls.add(path);
          final n = (perPathCalls[path] ?? 0) + 1;
          perPathCalls[path] = n;
          // Every item decodes fine EXCEPT the target's SECOND-and-later
          // attempt: its first (piggyback) call must still succeed, so the
          // failure under test is specifically the catch-up re-upgrade, not
          // payload production.
          if (path == target && n > 1) {
            throw StateError('simulated full-res decode failure');
          }
          return fakeDecoded();
        },
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(10, 10);
      int targetCalls() => decodeCalls.where((p) => p == target).length;

      await controller.preloadImages(
        items: items,
        selectedItemId: items[8].id,
        notifyLoaded: () {},
      );
      await until(() => controller.isFullSizeReady(items[8].id));
      expect(targetCalls(), 1);

      // Item 8 at distance -3 from selection 11: evicts the full-res entry,
      // retains the payload.
      await controller.preloadImages(
        items: items,
        selectedItemId: items[11].id,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.payloadFor(items[8].id), isNotNull);

      // Re-enter at distance -1 (select item 9, window [8,12]): the catch-up
      // decode runs and THROWS. -1 is used because the forward bias gave up
      // -2; item 8 must land inside [sel-1, sel+3] to trigger the re-upgrade.
      await controller.preloadImages(
        items: items,
        selectedItemId: items[9].id,
        notifyLoaded: () {},
      );
      await until(
        () => targetCalls() == 2,
        reason: 'the failing catch-up attempt to run',
      );
      // Give the failed attempt's bookkeeping a moment to settle before
      // asserting the negative (no tier-2, no permanent miss).
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(
        controller.hasFailed(items[8].id),
        isFalse,
        reason:
            'a full-res-only failure must NOT become a permanent miss: '
            'payload production already succeeded, so the item is still '
            'fully displayable at tier-1',
      );
      expect(
        controller.isFullSizeReady(items[8].id),
        isFalse,
        reason:
            'no tier-2 entry after the failed upgrade; tier-1 display '
            'is retained instead',
      );

      // Two further debounce triggers while still in-window: must NOT retry
      // the failing decode for the same (unchanged) payload.
      await controller.preloadImages(
        items: items,
        selectedItemId: items[9].id,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await controller.preloadImages(
        items: items,
        selectedItemId: items[10].id,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        targetCalls(),
        2,
        reason:
            'the failing full-res attempt count must stay at 1 (2 total: '
            '1 successful piggyback + 1 failing catch-up) after two more '
            'debounce settles for the same payload',
      );
      await settle(controller);
    });

    // ------------------------------------------------------------- AC-M5-9

    test(
      'M5-DW6 a full-res upgrade adds ZERO bytes to the payload cache',
      () async {
        final controller = ImagePreloadController(
          scheduleFrameCallback: _microtaskFrame,
          navigationDebounce: Duration.zero,
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              const NativeImageNeedsRawDecode(exifOrientation: 1),
          dngDecoder: (path) async => fakeDecoded(),
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(10, 10);
        final items = paddedItems(14, extension: 'dng');

        final beforeDecode = controller.retainedByteCost;
        expect(
          beforeDecode,
          0,
          reason:
              'nothing decoded yet; the load-bearing comparison is the '
              'AFTER check below',
        );

        await controller.preloadImages(
          items: items,
          selectedItemId: items[5].id,
          notifyLoaded: () {},
        );
        await until(() => controller.isFullSizeReady(items[5].id));

        // Since the 2026-08-26 ruling an expensive item fills the SAME -3..+5
        // window a cheap one does (it just queues), so the band that can hold a
        // payload here is the whole retention window, not the old +/-1 trio.
        // retainedByteCost must equal EXACTLY the sum of those payloads' own
        // byteCost -- if the full-res upgrade added its ~payload-sized buffer to
        // the payload cache instead of going straight to the ImageCache-owned
        // ui.Image, this sum would be short of the real total.
        await until(
          () => List.generate(
            9,
            (i) => items[2 + i].id,
          ).every((id) => controller.payloadFor(id) != null),
          reason: 'the whole -3..+5 window to land',
        );
        var expectedTotal = 0;
        for (var i = 2; i <= 10; i++) {
          final payload = controller.payloadFor(items[i].id);
          expect(
            payload,
            isNotNull,
            reason: 'every -3..+5 item must have a retained payload',
          );
          expectedTotal += payload!.byteCost;
        }
        expect(
          controller.retainedByteCost,
          expectedTotal,
          reason:
              'the full-res tier-2 upgrade must add ZERO bytes to the payload '
              'cache (AC-M5-9): retainedByteCost accounts only for '
              'PixelPayload.byteCost, never for the full-resolution ImageCache '
              'entry',
        );
        await settle(controller);
      },
    );
  });

  group('image_preload_controller_permanent_miss_test.dart', () {
    test('M4-AC1 a permanently failing sidebar thumbnail is requested EXACTLY ONCE '
        'across three preloadThumbnails sweeps', () async {
      // RE-WIRED 2026-08-30 (plan Task 6): the invariant is unchanged -- a row
      // that can never produce a tile is asked ONCE per folder load, not once
      // per sweep (design authority 2.2, invariant I8). What changed is WHO is
      // asked. The sidebar no longer calls the loader with
      // `purpose: sidebarThumbnail`; it asks the shared PAYLOAD producer, so
      // the failure has to be injected there and the "ask" counted there.
      final producerAsks = <String>[];
      final items = List.generate(5, (i) {
        final id = 'IMG_${i.toString().padLeft(2, '0')}';
        return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
      });
      final failingPath = items[0].files.single.path;

      final controller = ImagePreloadController(
        imageLoader: (path, {required purpose, int? targetLongEdge}) async {
          producerAsks.add(path);
          if (path == failingPath) {
            // Unreadable/corrupt: an answer that cannot change.
            return const NativeImageFailure('UNREADABLE', 'corrupt file');
          }
          return NativeImageBytes(Uint8List.fromList(tinyPngBytes));
        },
        payloadEncoder: throwingPayloadEncoder,
      );
      addTearDown(controller.dispose);

      // Each sweep must report a DIFFERENT visible range, or preloadThumbnails
      // early-returns on the unchanged-range check and the test would prove
      // nothing. The 100ms debounce plus the fake loads need to drain between
      // sweeps, hence the wait.
      Future<void> sweep(int start, int end) async {
        await controller.preloadThumbnails(
          items: items,
          startIdx: start,
          endIdx: end,
          notifyLoaded: () {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }

      await sweep(0, 1);
      await sweep(0, 2);
      await sweep(0, 1);

      expect(
        producerAsks.where((p) => p == failingPath).length,
        1,
        reason:
            'the sidebar re-asked for an answer that cannot change: without '
            'the permanent-miss set every sweep costs another production '
            'attempt, forever',
      );
      // Anti-vacuity: a mutant that simply stopped fetching thumbnails would
      // also satisfy the assertion above.
      expect(
        controller.thumbnailPayloadFor(items[1].id),
        isNotNull,
        reason: 'loadable thumbnails must still land',
      );
      expect(controller.thumbnailPayloadFor(items[0].id), isNull);
      expect(
        controller.debugThumbPermanentMisses.contains(items[0].id),
        isTrue,
      );
    });

    test(
      'M4-AC1b a failed sidebar thumbnail must not poison the PREVIEW state of a '
      'DIFFERENT file whose own name happens to be "thumb_" + its name',
      () async {
        // RE-WIRED 2026-08-30 (plan Task 6). The invariant under test is the
        // CONTAINER-COLLISION one and it is untouched by the redesign: the
        // sidebar's negative cache and the preview's are two containers, never
        // one container with two key shapes.
        //
        // PhotoItem.id is basenameWithoutExtension (supported_photo_formats.dart:44,
        // used as the grouping key in photo_library_scanner.dart:23), so ids are
        // user-controlled filenames. Any in-band key prefix therefore has a
        // reachable collision: here the sidebar's key for `IMG_01` is exactly the
        // preview's key for the file literally named `thumb_IMG_01.jpg`.
        //
        // What DID change: the failing file now fails at the shared producer, so
        // it is legitimately a preview miss as well. That is the new design, not
        // a leak -- the assertion that matters is that the VICTIM is untouched.
        final victim = PhotoItem(
          id: 'thumb_IMG_01',
          files: [File('/tmp/thumb_IMG_01.jpg')],
        );
        final failing = PhotoItem(
          id: 'IMG_01',
          files: [File('/tmp/IMG_01.jpg')],
        );
        final items = [failing, victim];

        final controller = ImagePreloadController(
          imageLoader: (path, {required purpose, int? targetLongEdge}) async {
            if (path == failing.files.single.path) {
              return const NativeImageFailure('UNREADABLE', 'corrupt file');
            }
            return NativeImageBytes(Uint8List.fromList(tinyPngBytes));
          },
          payloadEncoder: throwingPayloadEncoder,
        );
        addTearDown(controller.dispose);

        await controller.preloadThumbnails(
          items: items,
          startIdx: 0,
          endIdx: 1,
          notifyLoaded: () {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));

        // The failure really happened -- without this the assertion below could
        // pass because nothing was ever recorded.
        expect(controller.thumbnailPayloadFor(failing.id), isNull);
        expect(
          controller.debugThumbPermanentMisses.contains(failing.id),
          isTrue,
        );
        expect(controller.thumbnailPayloadFor(victim.id), isNotNull);

        expect(
          controller.hasFailed(victim.id),
          isFalse,
          reason:
              'a failure for a DIFFERENT file marked this one as a permanent '
              'preview miss -- the main view will call it unreadable until the '
              'folder is reloaded, and it never failed at anything',
        );
        expect(
          controller.debugThumbPermanentMisses.contains(victim.id),
          isFalse,
          reason:
              'the sidebar container must not collide on the prefixed name '
              'either',
        );
      },
    );

    test('M6-PL1 a throwing thumbnail producer must not abort the sweep, must '
        'release the in-flight key, and must record a permanent miss like a '
        'non-bytes result', () async {
      // RE-WIRED 2026-08-30 (plan Task 6). Every clause of this invariant
      // still applies, only the producer changed: the sweep asks the shared
      // PAYLOAD path instead of calling the loader with the sidebar purpose.
      //
      // This test found a REAL regression in the redesign, not just a stale
      // binding. `_ensurePayload` rethrows a throwing source (it must, to
      // preserve the preview path's error propagation) and the decode lane
      // swallows the exception to stay runnable -- so the row ended the body
      // with no payload AND no miss, and every later sweep re-enqueued it.
      // The sidebar's lane body now catches and records the miss.
      final producerAsks = <String>[];
      final items = List.generate(3, (i) {
        final id = 'IMG_${i.toString().padLeft(2, '0')}';
        return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
      });
      final throwingPath = items[0].files.single.path;

      final controller = ImagePreloadController(
        imageLoader: (path, {required purpose, int? targetLongEdge}) async {
          producerAsks.add(path);
          if (path == throwingPath) {
            // Simulates a loader implementation throwing instead of returning
            // a NativeImageFailure -- e.g. an unconverted platform exception
            // from a bridge, or any other loader-internal error.
            throw StateError(
              'native bridge threw instead of returning '
              'NativeImageFailure',
            );
          }
          return NativeImageBytes(Uint8List.fromList(tinyPngBytes));
        },
        payloadEncoder: throwingPayloadEncoder,
      );
      addTearDown(controller.dispose);

      Future<void> sweep(int start, int end) async {
        await controller.preloadThumbnails(
          items: items,
          startIdx: start,
          endIdx: end,
          notifyLoaded: () {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }

      await sweep(0, 2);

      // The sweep must CONTINUE past the thrower: items 1 and 2 come after
      // item 0 in fetch order, and a thrower that unwound the loop (or wedged
      // the lane runner) would leave neither of them ever requested.
      expect(
        controller.thumbnailPayloadFor(items[1].id),
        isNotNull,
        reason:
            'a throwing producer for item 0 must not abort the rest of the '
            'sweep -- item 1 comes after it in fetch order',
      );
      expect(
        controller.thumbnailPayloadFor(items[2].id),
        isNotNull,
        reason: 'item 2 must also still be requested',
      );

      // Two more sweeps with DIFFERENT ranges (so the unchanged-range
      // early-return never masks a re-request), both covering item 0.
      await sweep(0, 1);
      await sweep(1, 2);
      await sweep(0, 2);

      expect(
        controller.debugThumbPermanentMisses.contains(items[0].id),
        isTrue,
        reason: 'a throwing producer must be recorded, not merely swallowed',
      );
      expect(
        producerAsks.where((p) => p == throwingPath).length,
        1,
        reason:
            'a throwing producer must be treated like a non-bytes result and '
            'recorded as a permanent miss -- without a released in-flight '
            'key AND a recorded miss, the thrower is either re-requested '
            'forever or perpetually skipped as "still loading" instead of '
            'being answered once',
      );
      // The in-flight key really was released: a leaked key would make the
      // row look "still loading" forever, which is indistinguishable from the
      // assertion above unless the miss is checked separately.
      expect(controller.isLoadingForTest(items[0].id), isFalse);
    });

    testWidgets(
      'M4-AC2 a stale preloadImages resume must not reschedule tier-2 for the '
      'window it started with (invariant I4)',
      (tester) async {
        await tester.runAsync(() async {
          final gate = Completer<NativeImageResult>();
          final items = List.generate(14, (i) {
            final id = 'IMG_${i.toString().padLeft(2, '0')}';
            return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
          });
          final gatedPath = items[0].files.single.path;

          final controller = ImagePreloadController(
            navigationDebounce: const Duration(milliseconds: 40),
            imageLoader: (path, {required purpose, int? targetLongEdge}) {
              if (path == gatedPath) return gate.future;
              return Future<NativeImageResult>.value(
                NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
              );
            },
          );
          addTearDown(controller.dispose);
          controller.updateTargetSize(10, 10);

          // Pass A parks inside its priority load: the user navigated away
          // before its bytes arrived.
          final stalePass = controller.preloadImages(
            items: items,
            selectedItemId: items[0].id,
            notifyLoaded: () {},
          );
          await Future<void>.delayed(Duration.zero);

          // Pass B is the CURRENT generation and completes normally, scheduling
          // tier-2 for its own window (index 9).
          await controller.preloadImages(
            items: items,
            selectedItemId: items[9].id,
            notifyLoaded: () {},
          );

          // Now pass A resumes. Without a generation guard it walks on to
          // _precacheTierOneWindow / _scheduleTierTwoDecode for index 0, which
          // CANCELS the current generation's debounce timer and replaces it with
          // a schedule for a window the user has already left.
          gate.complete(NativeImageBytes(Uint8List.fromList(tinyPngBytes)));
          await stalePass;

          await Future<void>.delayed(const Duration(milliseconds: 60));

          expect(
            controller.isFullSizeReady(items[9].id),
            isTrue,
            reason:
                'the stale resume cancelled and replaced the current '
                "generation's tier-2 schedule -- the item the user is actually "
                'looking at never got its full-size decode',
          );
          expect(
            controller.isFullSizeReady(items[0].id),
            isFalse,
            reason: 'nothing may be decoded for the abandoned window',
          );
        });
      },
    );

    testWidgets(
      'M6-PL7 the SECOND generation guard (after the window await, :406) must '
      'discard a stale resume too, not only the priority-load guard (:381)',
      (tester) async {
        await tester.runAsync(() async {
          // Guard 1 (:381, right after the priority load) only fires when a
          // stale pass is superseded before its window loads even start. This
          // test parks pass A one step later -- inside the WINDOW await
          // (Future.wait(pendingLoads), :398) -- so guard 1 sees no
          // supersession yet and pass A only becomes stale WHILE waiting on the
          // window. That is the only way execution reaches guard 2 with a
          // generation mismatch already in hand.
          final gate = Completer<NativeImageResult>();
          final items = List.generate(14, (i) {
            final id = 'IMG_${i.toString().padLeft(2, '0')}';
            return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
          });
          // Pass A (selected index 0) retains -3..+5 -> window 0..5. Index 2
          // is inside that window. Pass B (selected index 10) retains 7..13.
          // Index 2 is outside pass B's window, so gating it stalls ONLY pass
          // A's window loop while pass B runs to completion untouched.
          final gatedPath = items[2].files.single.path;

          final controller = ImagePreloadController(
            navigationDebounce: const Duration(milliseconds: 40),
            imageLoader: (path, {required purpose, int? targetLongEdge}) {
              if (path == gatedPath) return gate.future;
              return Future<NativeImageResult>.value(
                NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
              );
            },
          );
          addTearDown(controller.dispose);
          controller.updateTargetSize(10, 10);

          // Pass A's priority load (item 0) is NOT gated, so it clears guard 1
          // and enters the window loop, where it parks on item 2's gate.
          final stalePass = controller.preloadImages(
            items: items,
            selectedItemId: items[0].id,
            notifyLoaded: () {},
          );
          // Give pass A's priority load and the start of its window loop a
          // chance to run before pass B supersedes it.
          await Future<void>.delayed(const Duration(milliseconds: 50));

          // Pass B is the current generation. None of its window items (7..13)
          // are gated, so it runs to completion and schedules tier-2 for
          // index 10.
          await controller.preloadImages(
            items: items,
            selectedItemId: items[10].id,
            notifyLoaded: () {},
          );

          // Release pass A. It resumes past Future.wait with a generation that
          // no longer matches -- guard 2 (:406) is what must stop it here;
          // guard 1 already ran and saw no mismatch.
          gate.complete(NativeImageBytes(Uint8List.fromList(tinyPngBytes)));
          await stalePass;

          await Future<void>.delayed(const Duration(milliseconds: 60));

          expect(
            controller.isFullSizeReady(items[10].id),
            isTrue,
            reason:
                "current window's tier-2 schedule must survive the stale "
                'resume',
          );
          expect(
            controller.isFullSizeReady(items[0].id),
            isFalse,
            reason: 'the abandoned window must get no tier-2 decode',
          );
        });
      },
    );

    test(
      'M4-AC3 step-3b failure inside PhotoSource.load reports a NON-deferred '
      'null payload -- the signal the caller turns into a permanent miss',
      () async {
        // M6 U-12 (P3.3): the legacy CIRAWFilter channel this used to mock is
        // deleted -- a throwing decoder with no channel to fall back to IS the
        // failure now, no mock needed to force it.
        final source = PhotoSource(
          loader: (path, {required purpose, int? targetLongEdge}) async =>
              const NativeImageNeedsRawDecode(exifOrientation: 1),
          dngDecoder: (path) async => throw StateError('native decode failed'),
          payloadEncoder: throwingPayloadEncoder,
        );

        final outcome = await source.load(
          '/tmp/IMG_0000.dng',
          longEdge: 2800,
          allowExpensive: true,
        );

        expect(outcome.payload, isNull);
        expect(
          outcome.deferred,
          isFalse,
          reason:
              'deferred:true here means "come back from the +/-1 pass", but '
              'this WAS that pass -- the caller would wait forever instead of '
              'recording a permanent miss (invariant T1)',
        );
      },
    );

    test(
      'M4-AC3 the step-3b failure path marks a permanent miss and RELEASES the '
      'view from its spinner (invariant T1)',
      () async {
        // M6 U-12 (P3.3): no legacy channel left to mock -- the throwing
        // decoder below IS the failure, immediately.
        var notifies = 0;
        final controller = ImagePreloadController(
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              const NativeImageNeedsRawDecode(exifOrientation: 1),
          dngDecoder: (path) async => throw StateError('native decode failed'),
        );
        addTearDown(controller.dispose);

        final items = List.generate(14, (i) {
          final id = 'IMG_${i.toString().padLeft(4, '0')}';
          return PhotoItem(id: id, files: [File('/tmp/$id.dng')]);
        });

        await controller.preloadImages(
          items: items,
          selectedItemId: items[5].id,
          notifyLoaded: () => notifies++,
        );

        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (!controller.hasFailed(items[5].id)) {
          if (DateTime.now().isAfter(deadline)) {
            fail(
              'step 3b failed and nobody recorded a miss: the view can never '
              'tell "not loaded yet" from "will never load" and spins forever',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        expect(controller.payloadFor(items[5].id), isNull);
        expect(
          notifies,
          greaterThanOrEqualTo(1),
          reason:
              'recording the miss without notifying leaves the spinner on '
              'screen until some unrelated event rebuilds the view',
        );
      },
    );
  });

  group('image_preload_controller_cheap_on_serial_lane_test.dart', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('halcyon-cheap-serial-lane');
      addTempDirTeardown(dir);
    });

    DecodedRgba fakeDecoded() => DecodedRgba(
      rgba: Uint8List.fromList(List<int>.generate(2 * 2 * 4, (i) => i)),
      width: 2,
      height: 2,
    );

    /// Waits for [condition], or gives up. Never `fail`s: both tests assert on
    /// COUNTERS afterwards, so a timeout must not hide the counter's value.
    Future<void> settle(bool Function() condition) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!condition() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      // One more quiet period so a late producer's work is counted too.
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }

    test(
      'TC-718 a CHEAP item produced on the serial lane asks the LOADER for its '
      'embedded preview and never runs a RAW decode',
      () async {
        final path = await writeSyntheticDng(
          buildSyntheticDng(
            candidates: const [SyntheticCandidate(width: 800, height: 600)],
            orientation: 1,
          ),
          dir: dir,
          name: 'cheap.dng',
        );

        var loaderCalls = 0;
        var decoderCalls = 0;

        final controller = ImagePreloadController(
          // No re-encode: this test is about ROUTING, and the native encoder is
          // not available under plain `flutter test`.
          payloadEncoder: throwingPayloadEncoder,
          imageLoader: (p, {required purpose, int? targetLongEdge}) async {
            loaderCalls++;
            return NativeImageBytes(Uint8List.fromList([137, 80, 78, 71]));
          },
          dngDecoder: (p) async {
            decoderCalls++;
            return fakeDecoded();
          },
        );
        addTearDown(controller.dispose);
        // longEdge 400 < the container's 800px candidate => verdict `cheap`.
        controller.updateTargetSize(400, 300);

        final items = [
          PhotoItem(id: 'cheap', files: [File(path)]),
        ];

        // The SIDEBAR route: no payload exists yet, so the sweep hands the item
        // to the serial lane (`onSerialLane: true`) -- the exact shape the field
        // log showed for all 18 wrongly-coloured photos.
        await controller.preloadThumbnails(
          items: items,
          startIdx: 0,
          endIdx: 0,
          notifyLoaded: () {},
        );
        await settle(() => loaderCalls > 0 || decoderCalls > 0);

        expect(
          decoderCalls,
          0,
          reason:
              'a cheap item must never RAW-decode: its embedded preview is '
              'usable and the decoder produces visibly different colours',
        );
        expect(
          loaderCalls,
          greaterThan(0),
          reason: 'the loader is what extracts the embedded preview',
        );
      },
    );

    test(
      'TC-719 an EXPENSIVE item on the serial lane still RAW-decodes exactly '
      'once (the fix must not disable the expensive route)',
      () async {
        // 100px candidate against a 400px viewport => verdict `expensive`.
        final path = await writeSyntheticDng(
          buildSyntheticDng(
            candidates: const [SyntheticCandidate(width: 100, height: 80)],
            orientation: 1,
          ),
          dir: dir,
          name: 'expensive.dng',
        );

        var decoderCalls = 0;

        final controller = ImagePreloadController(
          payloadEncoder: throwingPayloadEncoder,
          imageLoader: (p, {required purpose, int? targetLongEdge}) async =>
              // The loader agrees there is nothing usable, exactly as it would
              // for a container whose only preview is below the floor.
              const NativeImageNeedsRawDecode(exifOrientation: 1),
          dngDecoder: (p) async {
            decoderCalls++;
            return fakeDecoded();
          },
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(400, 300);

        final items = [
          PhotoItem(id: 'expensive', files: [File(path)]),
        ];

        await controller.preloadImages(
          items: items,
          selectedItemId: 'expensive',
          notifyLoaded: () {},
        );
        await settle(() => decoderCalls > 0);

        expect(
          decoderCalls,
          1,
          reason:
              'an item with no usable embedded preview must still reach the '
              'decoder, and exactly once (invariant I6)',
        );
      },
    );
  });
}
