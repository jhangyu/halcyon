import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_source.dart';

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

// A minimal valid 1x1 transparent PNG -- a real bitstream the engine can
// decode, without shipping a binary fixture.
final _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAA'
  'AAYAAjCB0C8AAAAASUVORK5CYII=',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'M4-AC1 a permanently failing sidebar thumbnail is requested EXACTLY ONCE '
    'across three preloadThumbnails sweeps',
    () async {
      final thumbRequests = <String>[];
      final items = List.generate(5, (i) {
        final id = 'IMG_${i.toString().padLeft(2, '0')}';
        return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
      });
      final failingPath = items[0].files.single.path;

      final controller = ImagePreloadController(
        imageLoader: (path, {required purpose}) async {
          if (purpose != ImageRequestPurpose.sidebarThumbnail) {
            return NativeImageBytes(Uint8List.fromList(_tinyPngBytes));
          }
          thumbRequests.add(path);
          if (path == failingPath) {
            // Unreadable/corrupt: an answer that cannot change.
            return const NativeImageFailure('UNREADABLE', 'corrupt file');
          }
          return NativeImageBytes(Uint8List.fromList(_tinyPngBytes));
        },
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
        thumbRequests.where((p) => p == failingPath).length,
        1,
        reason:
            'the sidebar re-asked for an answer that cannot change: without '
            'the shared permanent-miss set every sweep costs another channel '
            'round trip, forever',
      );
      // Anti-vacuity: a mutant that simply stopped fetching thumbnails would
      // also satisfy the assertion above.
      expect(
        controller.thumbnailBytesFor(items[1].id),
        isNotNull,
        reason: 'loadable thumbnails must still land',
      );
      expect(controller.thumbnailBytesFor(items[0].id), isNull);
    },
  );

  test(
    'M4-AC1b a failed sidebar thumbnail must not poison the PREVIEW state of a '
    'file whose own name happens to be "thumb_" + another file\'s name',
    () async {
      // PhotoItem.id is basenameWithoutExtension (supported_photo_formats.dart:44,
      // used as the grouping key in photo_library_scanner.dart:23), so ids are
      // user-controlled filenames. Any in-band key prefix therefore has a
      // reachable collision: here the sidebar's key for `IMG_01` is exactly the
      // preview's key for the file literally named `thumb_IMG_01.jpg`. The two
      // questions must live in two containers, not one container with two key
      // shapes.
      final victim = PhotoItem(
        id: 'thumb_IMG_01',
        files: [File('/tmp/thumb_IMG_01.jpg')],
      );
      final failing = PhotoItem(id: 'IMG_01', files: [File('/tmp/IMG_01.jpg')]);
      final items = [failing, victim];

      final controller = ImagePreloadController(
        imageLoader: (path, {required purpose}) async {
          if (purpose == ImageRequestPurpose.sidebarThumbnail &&
              path == failing.files.single.path) {
            return const NativeImageFailure('UNREADABLE', 'corrupt file');
          }
          return NativeImageBytes(Uint8List.fromList(_tinyPngBytes));
        },
      );
      addTearDown(controller.dispose);

      await controller.preloadThumbnails(
        items: items,
        startIdx: 0,
        endIdx: 1,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));

      // The failure really happened -- without this the assertion below could
      // pass because nothing was ever recorded.
      expect(controller.thumbnailBytesFor(failing.id), isNull);
      expect(controller.thumbnailBytesFor(victim.id), isNotNull);

      expect(
        controller.hasFailed(victim.id),
        isFalse,
        reason:
            'a sidebar thumbnail failure for a DIFFERENT file marked this one '
            'as a permanent preview miss -- the main view will call it '
            'unreadable until the folder is reloaded, and it never failed at '
            'anything',
      );
    },
  );

  test(
    'M6-PL1 a throwing sidebar thumbnail loader must not abort the sweep, '
    'must release the in-flight key, and must record a permanent miss like '
    'a non-bytes result',
    () async {
      // b3b0ddd's preloadThumbnails loop has no try/catch around the loader
      // await and removes _loadingKeys OUTSIDE any finally (round-1
      // parking-lot PL-1/PL-2/PL-10). A loader that THROWS instead of
      // returning a NativeImageFailure -- e.g. an unconverted
      // PlatformException, or a future non-macOS bridge -- unwinds the `for`
      // loop, so every remaining item in that sweep is silently never
      // requested, and the thrower's `thumb_<id>` in-flight key leaks for
      // the rest of the session.
      final thumbRequests = <String>[];
      final items = List.generate(3, (i) {
        final id = 'IMG_${i.toString().padLeft(2, '0')}';
        return PhotoItem(id: id, files: [File('/tmp/$id.jpg')]);
      });
      final throwingPath = items[0].files.single.path;

      final controller = ImagePreloadController(
        imageLoader: (path, {required purpose}) async {
          if (purpose != ImageRequestPurpose.sidebarThumbnail) {
            return NativeImageBytes(Uint8List.fromList(_tinyPngBytes));
          }
          thumbRequests.add(path);
          if (path == throwingPath) {
            // Simulates a loader implementation throwing instead of returning
            // a NativeImageFailure -- e.g. an unconverted platform exception
            // from a bridge, or any other loader-internal error.
            throw StateError('native bridge threw instead of returning '
                'NativeImageFailure');
          }
          return NativeImageBytes(Uint8List.fromList(_tinyPngBytes));
        },
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
      // item 0 in fetch order, and without try/catch the exception unwinds
      // the whole `for` loop, so neither is ever requested.
      expect(
        controller.thumbnailBytesFor(items[1].id),
        isNotNull,
        reason:
            'a throwing loader for item 0 must not abort the rest of the '
            'sweep -- item 1 comes after it in fetch order',
      );
      expect(
        controller.thumbnailBytesFor(items[2].id),
        isNotNull,
        reason: 'item 2 must also still be requested',
      );

      // Two more sweeps with DIFFERENT ranges (so the unchanged-range
      // early-return never masks a re-request), both covering item 0.
      await sweep(0, 1);
      await sweep(1, 2);
      await sweep(0, 2);

      expect(
        thumbRequests.where((p) => p == throwingPath).length,
        1,
        reason:
            'a throwing loader must be treated like a non-bytes result and '
            'recorded as a permanent miss -- without a released in-flight '
            'key AND a recorded miss, the thrower is either re-requested '
            'forever or perpetually skipped as "still loading" instead of '
            'being answered once',
      );
    },
  );

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
          imageLoader: (path, {required purpose}) {
            if (path == gatedPath) return gate.future;
            return Future<NativeImageResult>.value(
              NativeImageBytes(Uint8List.fromList(_tinyPngBytes)),
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
        gate.complete(NativeImageBytes(Uint8List.fromList(_tinyPngBytes)));
        await stalePass;

        await Future<void>.delayed(const Duration(milliseconds: 500));

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
          imageLoader: (path, {required purpose}) {
            if (path == gatedPath) return gate.future;
            return Future<NativeImageResult>.value(
              NativeImageBytes(Uint8List.fromList(_tinyPngBytes)),
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
        gate.complete(NativeImageBytes(Uint8List.fromList(_tinyPngBytes)));
        await stalePass;

        await Future<void>.delayed(const Duration(milliseconds: 600));

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
        loader: (path, {required purpose}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        dngDecoder: (path) async => throw StateError('native decode failed'),
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
        imageLoader: (path, {required purpose}) async =>
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
}
