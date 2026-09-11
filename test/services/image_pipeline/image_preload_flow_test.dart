import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/cache_budget.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload_cache.dart';
import 'package:halcyon_flutter/services/image_pipeline/prefetch_scheduler.dart';
import 'package:halcyon_flutter/services/image_pipeline/retention_policy.dart';
import '../../support/preload_fixtures.dart';
import 'dart:io';
import 'dart:ui' as ui;

// --- from image_preload_window_test.dart ---
// Precache-span guarantees (AC2, AC3) and the SERIAL LANE law (TC-098a..d).
//
// The spans under test:
//   * tier-1 (screen resolution) precache covers the WHOLE -3..+5 retention
//     window, so every retained slot also holds a decoded screen-resolution
//     entry;
//   * tier-2 (full size) covers -1..+3 via `kTierTwoBefore`/`kTierTwoAfter`,
//     behind the frozen 250ms navigation debounce. Forward-biased for the
//     same reason retention is (-3..+5): browsing is overwhelmingly forwards.
//
// What changed on 2026-08-26 (user ruling; contract at
// docs/logs/2026-08-26/serial-lane-unification-contract.md): the +/-1
// "expensive startup radius" is GONE. An expensive (no-preview RAW) item is
// eligible in exactly the same slots as a cheap one; the only difference left
// is the concurrency mode of payload production -- cheap in parallel, expensive
// one at a time on the shared serial lane, near-to-far from the selection.
// TC-098 used to be the mechanical guard for the opposite claim ("no payload
// and no decode beyond +/-1"); it is replaced below by TC-098a..d, which pin
// the four properties of the new law: full-window fill, single flight, start
// order, and mid-queue reprioritisation.

// Drains SYNCHRONOUSLY instead of waiting for a real (disabled-by-default
// in AutomatedTestWidgetsFlutterBinding) frame -- see REPAIR 3 /
// publication_pacer.dart: the paced tier-1/tier-2 publish queue only
// drains when its frame hook fires, and a plain test() never pumps a real
// frame on its own. The pacer re-arms itself after each drained item, so
// a synchronous hook fully drains the queue before submit() returns.
void _microtaskFrame(void Function() callback) => callback();

// `_finishOffLane`'s encode continuation is deliberately unawaited by the
// controller (it has no caller). If a test ends -- and `addTearDown`
// disposes the controller -- while that continuation is still in flight,
// its later `_inflight.release(...)` races the disposed budget's `clear()`
// and trips a cross-test assertion (attributed to whatever test happens to
// be running when it lands). Poll `debugInflightBytes` to zero before ending
// a test that used an expensive/RAW controller. Note this alone is not
// sufficient when a serial-lane burst is still queued (it can read 0
// transiently between two items); callers with a multi-item burst still in
// flight should also wait for the actual completion condition first.
Future<void> _settle(ImagePreloadController controller) => until(
  () => controller.debugInflightBytes == 0,
  reason: 'controller inflight-bytes budget to drain before teardown',
);

/// Whether every slot of the -3..+5 retention window around [selected] holds a
/// payload. Derived from the retention constants, never hand-written.
bool controllerWindowFilled(
  ImagePreloadController controller,
  List<PhotoItem> items,
  int selected,
) {
  for (var d = -kRetentionBefore; d <= kRetentionAfter; d++) {
    final index = selected + d;
    if (index < 0 || index >= items.length) continue;
    if (controller.payloadFor(items[index].id) == null) return false;
  }
  return true;
}

// --- from image_preload_stage_overlap_test.dart ---
// Plan Task 12 (S4): the stage-overlap guarantee and the bytes-in-flight bound.
//
// TC-841 / TC-842 / TC-839b
// (docs/logs/2026-09-03/plan-decode-optimizations.md).
//
// TC-841 is the mechanical PROOF that P3's stage split actually pipelines:
// before it, a lane task was decode-then-encode, so decode(B) could not begin
// until encode(A) had finished and the two intervals were strictly disjoint.
//
// Ticks are a monotonic counter, NOT a clock: every assertion is about ORDER,
// which is deterministic. No assertion here reads wall-clock time.

/// One recorded stage interval.
typedef Tick = ({String stage, String id, int enter, int exit});

/// A 4x4 OPAQUE RGBA frame (64 bytes). Alpha is 0xFF because the identity
/// short-circuit asserts sampled opacity in debug.
DecodedRgba decodedFixture() {
  final rgba = Uint8List(4 * 4 * 4);
  for (var i = 3; i < rgba.length; i += 4) {
    rgba[i] = 0xFF;
  }
  return DecodedRgba(rgba: rgba, width: 4, height: 4);
}

List<PhotoItem> rawItems(List<String> ids) => [
  for (final id in ids) PhotoItem(id: id, files: [File('/tmp/$id.dng')]),
];

/// Four RAW items: enough for the lane to still have work queued once the
/// first hand-off has happened, which is what makes the overlap observable.
List<PhotoItem> fourRawItems() => rawItems(['a', 'b', 'c', 'd']);

Future<NativeImageResult> _needsRawDecodeLoader(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

ImagePreloadController buildController({
  required Future<DecodedRgba> Function(String path) decoder,
  required Future<Uint8List> Function(
    Uint8List rgba, {
    required int width,
    required int height,
    required int quality,
  })
  encoder,
  int decodeLaneWidth = 1,
  int? inflightByteBudget,
}) {
  return ImagePreloadController(
    imageLoader: _needsRawDecodeLoader,
    dngDecoder: (path) => decoder(path),
    payloadEncoder: encoder,
    decodeLaneWidth: decodeLaneWidth,
    inflightByteBudget: inflightByteBudget,
  );
}

Future<void> pumpMicrotasks([int rounds = 40]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

// --- from image_preload_controller_sequential_decode_retention_test.dart ---
// Amendment-3 scheduling controls. This historical-lane file is committed on
// top of untouched production 0e6407e so its RED is a genuine pre-fix result.

// --- from image_preload_controller_folder_generation_test.dart ---
/// P2 folder gate. No FFI decode is cancellable, so `reset()` cannot stop an
/// in-flight expensive load -- it can only clear the maps that load is about to
/// write into. These cases pin what happens to the load that lands afterwards.
///
/// Why it matters concretely: [PhotoItem.id] is a user-controlled FILENAME, so
/// a stale failure landing after a folder switch would latch a same-named file
/// in the NEW folder as "unreadable for this session".

Future<Uint8List> _encodeRealPngFolderGen(int width, int height) async {
  final rgba = Uint8List(width * height * 4);
  for (var i = 3; i < rgba.length; i += 4) {
    rgba[i] = 0xFF;
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  final image = await completer.future;
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return byteData!.buffer.asUint8List();
}

// --- from image_preload_reset_tier_one_evict_test.dart ---
// A 1x1 PNG. Real bytes matter: the tier-1 provider is a ResizeImage over a
// MemoryImage, and the entry only becomes tracked in the ImageCache once the
// codec actually decodes something.
final Uint8List _png1x1 = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

Future<NativeImageResult> _pngLoader(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => NativeImageBytes(Uint8List.fromList(_png1x1));

// --- from image_preload_reencode_tier_two_test.dart ---
// Phase 13 (one-buffer payload re-encode) tier-2 rebuild tests.
//
// Contract: docs/logs/2026-08-30/plan-payload-reencode.md Task 4, TC-366/367.
//
// TC-366 is the headline claim of the phase: once a no-preview RAW's
// full-resolution pixels have been re-encoded into a retained JPEG
// (EncodedPayload), a tier-2 rebuild after eviction reads that retained
// bitstream instead of paying for a second FFI decode. TC-367 proves the
// test discriminates: with re-encoding disabled the same navigation script
// costs a second decode, exactly as it did before this phase.
//
// Modelled on image_preload_controller_dual_window_tier2_test.dart's fakes
// and navigation helpers -- same fake loader/decoder shapes, no new harness.
//
// DEVIATION FROM THE PLAN'S LITERAL SCRIPT (documented per team-lead request):
// the plan's Task 4 step 1 sketch navigates 0 -> 9 -> 0 ("slides out of BOTH
// windows"). With the default retention floor (before=3, after=5) and a
// 14-item all-RAW list, navigating to index 9 evicts item[0] from RETENTION
// entirely (window becomes [6,13]), not merely from its tier-2 entry -- so a
// second FFI decode becomes a genuine, CORRECT requirement regardless of
// whether re-encoding is on, and the plan's literal script cannot discriminate
// the claim TC-366 is meant to test (self-defeating as written). This test
// instead navigates 0 -> 3 -> 0: at currentIndex=3, retention (-3..+5) still
// covers item[0] (3-3==0, so it stays retained), while the tier-2 band
// (-1..+3, kTierTwoBefore=1/kTierTwoAfter=3) does NOT (backward distance 3 >
// kTierTwoBefore=1) -- so ONLY item[0]'s tier-2 ImageCache entry is evicted,
// its payload survives, which is the actual precondition "tier-2 entry
// evicted, payload retained" the plan's prose names. The setup is verified
// in-test (assertion that item[0]'s tier-2 entry is actually gone after the
// move) rather than assumed.

/// A REAL, decodable PNG of the given size (opaque RGBA pixels), so the
/// tier-2 catch-up path's `MemoryImage` decode succeeds and the resulting
/// `ImageInfo.image.width/height` can be asserted against.
Future<Uint8List> _encodeRealPngReencode(int width, int height) async {
  final pixels = Uint8List(width * height * 4);
  for (var i = 0; i < pixels.length; i += 4) {
    pixels[i] = 0x11;
    pixels[i + 1] = 0x22;
    pixels[i + 2] = 0x33;
    pixels[i + 3] = 0xFF;
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    width,
    height,
    ui.PixelFormat.rgba8888,
    (image) => completer.complete(image),
  );
  final image = await completer.future;
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return byteData!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('image_preload_window_test.dart', () {
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

    ImagePreloadController cheapController() => ImagePreloadController(
      scheduleFrameCallback: _microtaskFrame,
      imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
          NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
      dngDecoder: (path) async => fail('a cheap rung must never RAW-decode'),
    );

    Future<bool> tierOneResident(
      ImagePreloadController controller,
      String id, {
      required int width,
      required int height,
    }) async {
      final bytes = controller.imageBytesFor(id);
      if (bytes == null) return false;
      final key = await tierOneProviderFor(
        bytes,
        width: width,
        height: height,
      ).obtainKey(const ImageConfiguration());
      return PaintingBinding.instance.imageCache.containsKey(key);
    }

    setUp(clearImageCacheSetUp);

    // ---------------------------------------------------------------- AC2

    testWidgets('TC-095 every slot of the -3..+5 retention window holds a '
        'tier-1 entry (AC2)', (tester) async {
      await tester.runAsync(() async {
        final controller = cheapController();
        addTearDown(controller.dispose);
        controller.updateTargetSize(10, 10);

        final photos = paddedItems(14);
        const selected = 5;
        await controller.preloadImages(
          items: photos,
          selectedItemId: photos[selected].id,
          notifyLoaded: () {},
        );
        // PHASE 3 settle: the pass returns once the window is ISSUED, so the
        // tier-1 entries it produces (now landing-driven) exist a few event-loop
        // turns later. What is asserted below is unchanged.
        await until(
          () => controllerWindowFilled(controller, photos, selected),
          reason: 'the whole cheap window to land',
        );

        // Derived from the retention constants, never hand-written: if the
        // retention window ever moves, this test must move with it rather than
        // silently keep checking the old span.
        final first = selected - kRetentionBefore;
        final last = selected + kRetentionAfter;
        expect(
          last - first + 1,
          9,
          reason: 'the window under test is nine slots',
        );

        for (var i = first; i <= last; i++) {
          expect(
            await tierOneResident(
              controller,
              photos[i].id,
              width: 10,
              height: 10,
            ),
            isTrue,
            reason:
                'slot $i (distance ${i - selected}) is inside -3..+5 and must '
                'hold a tier-1 entry; before round 2 the span was +/-2, so '
                'slots 2, 8, 9 and 10 had no ImageCache entry at all',
          );
        }
      });
    });

    testWidgets('TC-096 an item at -3 and one at +5 keep their tier-1 entries '
        'while in-window, and lose them on leaving (AC2 killer)', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final controller = cheapController();
        addTearDown(controller.dispose);
        controller.updateTargetSize(10, 10);

        final photos = paddedItems(20);
        await controller.preloadImages(
          items: photos,
          selectedItemId: photos[5].id,
          notifyLoaded: () {},
        );
        // PHASE 3 settle (see TC-095). Assertions below unchanged.
        await until(
          () => controllerWindowFilled(controller, photos, 5),
          reason: 'the whole cheap window to land',
        );

        // The two extreme slots named by AC2's killer: -3 is index 2, +5 is
        // index 10. Both are exactly ON the boundary, which is where an
        // off-by-one in the span would show up.
        expect(
          await tierOneResident(
            controller,
            photos[2].id,
            width: 10,
            height: 10,
          ),
          isTrue,
          reason: 'the -3 boundary slot must hold a tier-1 entry',
        );
        expect(
          await tierOneResident(
            controller,
            photos[10].id,
            width: 10,
            height: 10,
          ),
          isTrue,
          reason: 'the +5 boundary slot must hold a tier-1 entry',
        );

        // Step forward one. Index 2 becomes -4: outside retention entirely, so
        // its payload AND its tier-1 entry must go. This is the other half of
        // the guarantee -- "not evicted while in-window" is only meaningful if
        // something IS evicted once out of window.
        await controller.preloadImages(
          items: photos,
          selectedItemId: photos[6].id,
          notifyLoaded: () {},
        );
        // PHASE 3 settle: index 11 enters the window with this pass and must be
        // given time to land before the residency assertions below.
        await until(
          () => controllerWindowFilled(controller, photos, 6),
          reason: 'the window at the new selection to land',
        );
        expect(
          controller.payloadFor(photos[2].id),
          isNull,
          reason: 'index 2 is now -4 and must have left the retention window',
        );
        expect(
          await tierOneResident(
            controller,
            photos[3].id,
            width: 10,
            height: 10,
          ),
          isTrue,
          reason: 'index 3 is now -3 and is still in-window',
        );
        expect(
          await tierOneResident(
            controller,
            photos[11].id,
            width: 10,
            height: 10,
          ),
          isTrue,
          reason: 'index 11 is now +5 and must have gained a tier-1 entry',
        );
      });
    });

    // ---------------------------------------------------------------- AC3

    testWidgets('TC-097 tier-2 full-size entries cover -1..+3 after the '
        'debounce settles (AC3)', (tester) async {
      await tester.runAsync(() async {
        // Debounce shortened to 40ms via navigationDebounce; the property under
        // test (band shape after settle) is unaffected by its absolute length.
        final controller = ImagePreloadController(
          scheduleFrameCallback: _microtaskFrame,
          navigationDebounce: const Duration(milliseconds: 40),
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
          dngDecoder: (path) async =>
              fail('a cheap rung must never RAW-decode'),
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(10, 10);

        final photos = paddedItems(14);
        const selected = 5;
        await controller.preloadImages(
          items: photos,
          selectedItemId: photos[selected].id,
          notifyLoaded: () {},
        );
        // BOUNDED WAIT, not a fixed 60ms sleep: the 40ms debounce plus the
        // full-size decodes it fires are real engine futures, so a sleep
        // just-longer-than-the-debounce flaked under load when those decodes
        // took longer than the 20ms margin. Wait for the actual condition
        // (every in-window id ready), bounded at 5s so a real regression
        // still fails instead of hanging.
        await until(
          () => [
            for (var d = -kTierTwoBefore; d <= kTierTwoAfter; d++)
              photos[selected + d].id,
          ].every(controller.isFullSizeReady),
          reason: 'every id in the forward-biased tier-2 window to become '
              'full-size ready after the debounce settles',
        );

        for (var d = -kTierTwoBefore; d <= kTierTwoAfter; d++) {
          expect(
            controller.isFullSizeReady(photos[selected + d].id),
            isTrue,
            reason:
                'distance $d is inside the tier-2 window and must hold a '
                'full-size entry; the window is forward-biased -1..+3 so that '
                'the next forward step lands on a ready entry instead of a '
                'catch-up decode',
          );
        }

        // The span is -1..+3, not "everything": both boundaries must still
        // bite, or the test would pass just as well against an unbounded
        // window. -2 is the slot the forward bias GAVE UP; +4 is the slot it
        // still does not reach.
        expect(
          controller.isFullSizeReady(photos[selected - kTierTwoBefore - 1].id),
          isFalse,
          reason: 'distance -2 is outside the forward-biased tier-2 window',
        );
        expect(
          controller.isFullSizeReady(photos[selected + kTierTwoAfter + 1].id),
          isFalse,
          reason: 'distance +4 is outside the tier-2 window',
        );
      });
    });

    // ---------------------------------------------------------------- AC6

    // TC-098 (the old "+/-1 startup radius" killer) is retired: the radius it
    // guarded was struck out by the 2026-08-26 user ruling. TC-098a..d below
    // pin the law that replaced it.

    test('TC-098a an all-expensive folder fills the WHOLE -3..+5 payload '
        'window, not just +/-1 (criterion 2)', () async {
      final decodeCalls = <String>[];
      final controller = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        dngDecoder: (path) async {
          decodeCalls.add(path);
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return fakeDecoded();
        },
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(10, 10);

      final photos = paddedItems(14, extension: 'dng');
      const selected = 5;
      await controller.preloadImages(
        items: photos,
        selectedItemId: photos[selected].id,
        notifyLoaded: () {},
      );
      await until(
        () => List.generate(
          kRetentionBefore + kRetentionAfter + 1,
          (i) => photos[selected - kRetentionBefore + i].id,
        ).every((id) => controller.payloadFor(id) != null),
        reason: 'every slot of the retention window to acquire a payload',
        pollInterval: const Duration(milliseconds: 5),
      );

      for (var d = -kRetentionBefore; d <= kRetentionAfter; d++) {
        expect(
          controller.payloadFor(photos[selected + d].id),
          isNotNull,
          reason:
              'distance $d is inside -3..+5, so an EXPENSIVE item must acquire '
              'a payload there exactly as a cheap one does. Before the '
              '2026-08-26 ruling only -1..+1 ever did, which is why stepping +1 '
              'then +2 in an all-RAW folder always stalled',
        );
      }
      expect(
        decodeCalls.toSet(),
        hasLength(kRetentionBefore + kRetentionAfter + 1),
        reason: 'one decode per window slot, and no slot decoded twice',
      );
      await _settle(controller);
    });

    test('TC-098b at most ONE expensive decode is ever in flight, while cheap '
        'window loads still issue in parallel (criterion 3)', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      final expensive = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        dngDecoder: (path) async {
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          inFlight--;
          return fakeDecoded();
        },
      );
      addTearDown(expensive.dispose);
      expensive.updateTargetSize(10, 10);
      final raws = paddedItems(14, extension: 'dng');
      await expensive.preloadImages(
        items: raws,
        selectedItemId: raws[5].id,
        notifyLoaded: () {},
      );
      await until(
        () => controllerWindowFilled(expensive, raws, 5),
        reason: 'the whole expensive window to land',
        pollInterval: const Duration(milliseconds: 5),
      );
      expect(
        maxInFlight,
        1,
        reason:
            'a RAW decode saturates cores; nine of them in parallel is exactly '
            'what the serial lane exists to prevent',
      );
      await _settle(expensive);

      // The cheap half of the same claim: parallelism is retained for items
      // that do not need a decode at all.
      var cheapInFlight = 0;
      var cheapMaxInFlight = 0;
      final cheap = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async {
          cheapInFlight++;
          if (cheapInFlight > cheapMaxInFlight) {
            cheapMaxInFlight = cheapInFlight;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
          cheapInFlight--;
          return NativeImageBytes(Uint8List.fromList(tinyPngBytes));
        },
      );
      addTearDown(cheap.dispose);
      cheap.updateTargetSize(10, 10);
      final jpgs = paddedItems(14);
      await cheap.preloadImages(
        items: jpgs,
        selectedItemId: jpgs[5].id,
        notifyLoaded: () {},
      );
      // PHASE 3: the loads no longer start inside the awaited segment, so the
      // peak has to be observed after the window has actually landed.
      await until(
        () => controllerWindowFilled(cheap, jpgs, 5),
        reason: 'the whole cheap window to land',
        pollInterval: const Duration(milliseconds: 5),
      );
      // The window pass runs all NINE items in parallel. This was 8 before
      // Phase 3 (9 minus the selected item, which had its own awaited priority
      // load and was therefore a cache hit by the time the window pass reached
      // it); the selected item is now issued through the same path as every
      // other slot, so it overlaps with them. A TIGHTENING: 9 demands strictly
      // more overlap than 8, and the bound is still exact, so it still catches
      // a regression from full parallelism to partial (e.g. accidental serial
      // batching).
      expect(
        cheapMaxInFlight,
        equals(9),
        reason:
            'cheap payload acquisition across -3..+5 must overlap fully: all 9 '
            'window items should be in flight concurrently; the ruling changed '
            'the expensive lane only',
      );
    });

    test('TC-098c fresh settle decode START order is 0, +1, -1, +2, -2, +3, '
        '-3, +4, +5 (criterion 4)', () async {
      final starts = <String>[];
      final controller = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        dngDecoder: (path) async {
          starts.add(path);
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return fakeDecoded();
        },
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(10, 10);

      final photos = paddedItems(14, extension: 'dng');
      const selected = 5;
      await controller.preloadImages(
        items: photos,
        selectedItemId: photos[selected].id,
        notifyLoaded: () {},
      );
      await until(
        () => controllerWindowFilled(controller, photos, selected),
        reason: 'the whole expensive window to land',
        pollInterval: const Duration(milliseconds: 5),
      );

      // The user-ruled order, written as signed distances so the intent is
      // legible: nearest first, forward before backward at equal distance
      // (browsing is overwhelmingly forwards, the same asymmetry -3..+5 has).
      const ruledOrder = [0, 1, -1, 2, -2, 3, -3, 4, 5];
      expect(
        starts,
        [for (final d in ruledOrder) photos[selected + d].files.single.path],
        reason:
            'the serial lane must start decodes near-to-far from the selection; '
            'any other order means the item the user is looking at can be stuck '
            'behind one they are not',
      );
      await _settle(controller);
    });

    test('TC-098d navigating mid-queue reprioritises the lane: no decode starts '
        'outside the new window, and the next one is its nearest missing item '
        '(criterion 5)', () async {
      final starts = <String>[];
      final gates = <Completer<void>>[];
      final controller = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        dngDecoder: (path) async {
          starts.add(path);
          final gate = Completer<void>();
          gates.add(gate);
          await gate.future;
          return fakeDecoded();
        },
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(10, 10);

      final photos = paddedItems(30, extension: 'dng');
      await controller.preloadImages(
        items: photos,
        selectedItemId: photos[5].id,
        notifyLoaded: () {},
      );
      // The first decode (index 5) is parked on its gate, so the other eight
      // window items are queued behind it and nothing else has started.
      await until(
        () => starts.length == 1,
        reason: 'the first decode to start',
        pollInterval: const Duration(milliseconds: 5),
      );
      expect(starts.single, photos[5].files.single.path);

      // The user jumps to index 20. Its retention window (17..25) is disjoint
      // from the queue built for index 5 (2..10).
      await controller.preloadImages(
        items: photos,
        selectedItemId: photos[20].id,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        starts,
        hasLength(1),
        reason:
            'the parked decode still holds the lane; nothing may overtake it',
      );

      // Release the in-flight decode. What runs NEXT is the load-bearing claim.
      gates.single.complete();
      await until(
        () => starts.length == 2,
        reason: 'the next decode to start',
        pollInterval: const Duration(milliseconds: 5),
      );
      expect(
        starts[1],
        photos[20].files.single.path,
        reason:
            'the next decode after the in-flight one is the NEW selection, not '
            'the +1 item of the window the user has left',
      );

      // Drain enough of the new window to prove the stale entries never decode.
      //
      // `gates.length == starts.length` is trivially true both right after a
      // fresh decode starts (the case this loop wants) AND whenever nothing
      // new has started since the previous iteration already drained every
      // pending decode -- the new window can run out of undecoded items
      // before all 6 iterations complete. In that second case `gates.last` is
      // the SAME completer the previous iteration already completed, and a
      // blind `.complete()` throws `Bad state: Future already completed`
      // (flaky: only manifests on schedules where the window empties early).
      // Guard on `isCompleted` so a loop iteration with nothing new to drain
      // is a no-op instead of a crash.
      for (var i = 0; i < 6; i++) {
        // Wait for a NEW gate, not for `gates.length == starts.length`: the fake
        // decoder appends to both lists in the same synchronous step, so that
        // equality is ALWAYS true and guards nothing. The loop then completed
        // whichever gate happened to be last -- which, whenever the next decode
        // had not yet started, was the gate it had just completed.
        await until(
          () => gates.length >= i + 2,
          reason: 'decode #${i + 2} to start and reach its gate',
          pollInterval: const Duration(milliseconds: 5),
        );
        final gate = gates.last;
        if (!gate.isCompleted) {
          gate.complete();
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final stale = photos
          .sublist(2, 11)
          .map((item) => item.files.single.path)
          .toSet();
      expect(
        starts.skip(1).where(stale.contains),
        isEmpty,
        reason:
            'not one item of the abandoned window may start a decode after the '
            'navigation: they are outside the retention window, and the lane '
            'body re-checks that when its turn comes',
      );
      // Drain every gated decode this test left open (including ones that
      // start ONLY once an earlier one is released) so their off-lane encode
      // continuations (unawaited by the controller) finish BEFORE
      // `addTearDown` disposes it -- otherwise a later `_inflight.release(...)`
      // races the disposed budget's `clear()` and trips a cross-test assertion
      // attributed to whatever test is running when it lands.
      for (var round = 0; round < photos.length; round++) {
        final pending = gates.where((g) => !g.isCompleted).toList();
        if (pending.isEmpty && gates.length == starts.length) break;
        for (final gate in pending) {
          gate.complete();
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await _settle(controller);
    });

    test('TC-099 widening tier-1 creates no payloads of its own', () async {
      // The negative clause: tier-1 precache is a CONSUMER of payloads, never a
      // producer. It skips slots with no payload rather than fetching one, so
      // widening its span cannot smuggle work outside the startup rules. If this
      // inverts, the nine-slot tier-1 guarantee would be silently paying for
      // itself with RAW decodes outside +/-1.
      var loaderCalls = 0;
      final controller = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        navigationDebounce: const Duration(milliseconds: 40),
        imageLoader: (path, {required purpose, int? targetLongEdge}) async {
          loaderCalls++;
          return const NativeImageNeedsRawDecode(exifOrientation: 1);
        },
        dngDecoder: (path) async => fakeDecoded(),
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(10, 10);

      final photos = paddedItems(14, extension: 'dng');
      await controller.preloadImages(
        items: photos,
        selectedItemId: photos[5].id,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final callsAfterSettle = loaderCalls;

      // A second preload at the SAME position: tier-1 precache runs again over
      // all nine slots. If it produced payloads, it would call the loader again
      // for the six slots that have none.
      await controller.preloadImages(
        items: photos,
        selectedItemId: photos[5].id,
        notifyLoaded: () {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(
        loaderCalls,
        callsAfterSettle,
        reason:
            'a repeat pass over the widened tier-1 span must not fetch anything '
            'new; payload creation belongs to preloadImages and the debounced '
            'tier-2 pass alone',
      );
      await _settle(controller);
    });

    // ------------------------------------------------------------- AC1 pin

    test('TC-100 the two budget constants are pinned as raw byte counts', () {
      // Pinned in BYTES on purpose. The round-1 record lost time to MB-vs-MiB
      // drift, and 768 decimal MB (768,000,000) or 224 decimal MB (224,000,000)
      // would both still read as "768"/"224" in a review.
      expect(kImageCacheCeilingBytes, 805306368, reason: '768 MiB exactly');
      expect(kPayloadByteBudget, 268435456, reason: '256 MiB exactly');
      // The two are sized against OPPOSITE corpora -- the cache figure by the
      // cheap mix (two entries per item, full-size decode), the payload figure by
      // the expensive mix (window-resolution RGBA retained per slot). Neither can
      // sanity-check the other, so both are asserted independently.
      expect(kImageCacheCeilingBytes, 768 * 1024 * 1024);
      expect(kPayloadByteBudget, 256 * 1024 * 1024);
    });

    test(
      'TC-318 a mid-rung policy fills out to +8 and retains nothing at +9',
      () async {
        const midRung = RetentionPolicy(
          before: 3,
          after: 8,
          payloadByteBudget: 402653184,
        );
        final controller = ImagePreloadController(
          scheduleFrameCallback: _microtaskFrame,
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              const NativeImageNeedsRawDecode(exifOrientation: 1),
          dngDecoder: (path) async => fakeDecoded(),
          retention: midRung,
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(10, 10);

        final photos = paddedItems(30, extension: 'dng');
        const selected = 12;
        await controller.preloadImages(
          items: photos,
          selectedItemId: photos[selected].id,
          notifyLoaded: () {},
        );
        await until(
          () => List.generate(
            midRung.before + midRung.after + 1,
            (i) => photos[selected - midRung.before + i].id,
          ).every((id) => controller.payloadFor(id) != null),
          reason:
              'every slot of the mid-rung -3..+8 window to acquire a payload',
          pollInterval: const Duration(milliseconds: 5),
        );

        expect(
          controller.payloadFor(photos[selected + midRung.after].id),
          isNotNull,
          reason: '+8 is inside the mid rung and must hold a payload',
        );
        expect(
          controller.payloadFor(photos[selected + midRung.after + 1].id),
          isNull,
          reason: '+9 is outside the mid rung and must never be retained',
        );
        await _settle(controller);
      },
    );

    test(
      'TC-319 the default policy is still the shipped -3..+5 floor',
      () async {
        final controller = cheapController();
        addTearDown(controller.dispose);
        controller.updateTargetSize(10, 10);
        expect(controller.retention, const RetentionPolicy.floor());

        final photos = paddedItems(30, extension: 'dng');
        const selected = 12;
        await controller.preloadImages(
          items: photos,
          selectedItemId: photos[selected].id,
          notifyLoaded: () {},
        );
        await until(
          () => controllerWindowFilled(controller, photos, selected),
          reason: 'the -3..+5 floor window to fill',
          pollInterval: const Duration(milliseconds: 5),
        );

        expect(
          controller.payloadFor(photos[selected + kRetentionAfter + 1].id),
          isNull,
          reason: 'the default controller must not reach past +5',
        );
      },
    );

    test('TC-356 a width-3 controller runs more than one expensive decode at '
        'once, and never more than three', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      var call = 0;
      final wide = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        dngDecoder: (path) async {
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          // Deliberately uneven, so completion order differs from start order.
          await Future<void>.delayed(
            Duration(milliseconds: 5 + (call++ % 3) * 7),
          );
          inFlight--;
          return fakeDecoded();
        },
        decodeLaneWidth: 3,
      );
      addTearDown(wide.dispose);
      wide.updateTargetSize(10, 10);
      final raws = paddedItems(14, extension: 'dng');
      await wide.preloadImages(
        items: raws,
        selectedItemId: raws[5].id,
        notifyLoaded: () {},
      );
      await until(
        () => controllerWindowFilled(wide, raws, 5),
        reason: 'the whole expensive window to land',
        pollInterval: const Duration(milliseconds: 5),
      );
      expect(
        maxInFlight,
        greaterThan(1),
        reason: 'width 3 must actually overlap decodes',
      );
      expect(
        maxInFlight,
        lessThanOrEqualTo(3),
        reason: 'and must never exceed the configured width',
      );
      await _settle(wide);
    });

    test('TC-357 width 3 keeps the near-to-far START order: the first three '
        'starts are distances 0, +1, -1', () async {
      final starts = <String>[];
      final wide = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        dngDecoder: (path) async {
          starts.add(path);
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return fakeDecoded();
        },
        decodeLaneWidth: 3,
      );
      addTearDown(wide.dispose);
      wide.updateTargetSize(10, 10);
      final raws = paddedItems(14, extension: 'dng');
      await wide.preloadImages(
        items: raws,
        selectedItemId: raws[5].id,
        notifyLoaded: () {},
      );
      await until(
        () => starts.length >= 3,
        reason: 'three starts',
        pollInterval: const Duration(milliseconds: 5),
      );
      expect(
        starts.take(3).toList(),
        [
          raws[5].files.single.path,
          raws[6].files.single.path,
          raws[4].files.single.path,
        ],
        reason:
            'the 2026-08-26 near-to-far ruling is unchanged by width; only '
            'how many of the ranked entries start at once changed',
      );
      await until(
        () => controllerWindowFilled(wide, raws, 5),
        reason: 'the whole expensive window to land before teardown',
      );
      await _settle(wide);
    });
  });

  group('image_preload_stage_overlap_test.dart', () {
    // TC-841 / TC-842 -- the stage-overlap proof.
    //
    // DETERMINISTIC BY CONSTRUCTION, not by timing: the first encode parks on a
    // Completer the test controls, so "decodes ran while an encode was in
    // flight" is decided by that gate and never by which of two delays happened
    // to be shorter. Before this task the lane body was decode-then-encode, so a
    // held encode held the lane slot too and NO further decode could enter --
    // the decode and encode intervals were strictly disjoint.
    test('a decode runs while the first encode is in flight, and decodes stay '
        'bounded', () async {
      var clock = 0;
      final ticks = <Tick>[];
      var concurrentDecodes = 0;
      var peakDecodes = 0;
      final firstEncodeGate = Completer<void>();
      var encodesStarted = 0;
      int? firstEncodeEnter;

      final controller = buildController(
        decodeLaneWidth: 1,
        decoder: (path) async {
          concurrentDecodes++;
          peakDecodes = peakDecodes > concurrentDecodes
              ? peakDecodes
              : concurrentDecodes;
          final enter = clock++;
          await Future<void>.delayed(const Duration(milliseconds: 2));
          ticks.add((stage: 'decode', id: path, enter: enter, exit: clock++));
          concurrentDecodes--;
          return decodedFixture();
        },
        encoder:
            (rgba, {required width, required height, required quality}) async {
              final enter = clock++;
              if (encodesStarted++ == 0) {
                firstEncodeEnter = enter;
                await firstEncodeGate.future;
              }
              ticks.add((
                stage: 'encode',
                id: 'enc',
                enter: enter,
                exit: clock++,
              ));
              return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
            },
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(32, 32);

      unawaited(
        controller.preloadImages(
          items: fourRawItems(),
          selectedItemId: 'a',
          notifyLoaded: () {},
        ),
      );
      await pumpMicrotasks();

      // The first encode is STILL PARKED (its tick is not recorded yet), and
      // decodes entered after it started: the stages overlap.
      expect(
        firstEncodeEnter,
        isNotNull,
        reason: 'an encode must have started',
      );
      expect(
        ticks.any((t) => t.stage == 'encode' && t.enter == firstEncodeEnter),
        isFalse,
        reason: 'the gate must still be holding the FIRST encode open',
      );
      expect(
        ticks.where((t) => t.stage == 'decode' && t.enter > firstEncodeEnter!),
        isNotEmpty,
        reason: 'a decode must start while the first encode is still running',
      );
      // TC-842: the pipelining must not have widened the decode stage.
      expect(peakDecodes, lessThanOrEqualTo(controller.decodeLaneWidth));

      firstEncodeGate.complete();
      await pumpMicrotasks();
      expect(controller.debugInflightBytes, 0);
    });

    // TC-839b -- what bounds the ENCODE stage.
    //
    // MIGRATED 2026-09-11 (S1.3, plan Part A WP1.3 test-migration table).
    // OLD invariant: the in-flight BYTE budget bounds concurrent encodes
    // (budget of 1 B -> peak 1; budget of 2 nominal frames -> peak 2).
    // NEW invariant: after the stage boundary the decode byte budget bounds
    // NOTHING -- its charge has moved to the encode/publish tail ledger, which
    // never refuses -- so `EncodeStage.width` is the encode bound, and
    // `StageWidths.derive` makes that the configured lane width.
    // A budget-parameterised version of these two cases can now only pass
    // vacuously, which is why they are re-expressed rather than deleted.
    //
    // Returns the PEAK number of encodes simultaneously in flight for the same
    // four-item script at the given lane width. Each case was observed FAILING
    // at the opposite width (width 1 measured 1, width 2 measured 2), so
    // neither assertion is satisfied by the script alone.
    Future<int> peakConcurrentEncodesAtLaneWidth(int laneWidth) async {
      var concurrent = 0;
      var peak = 0;
      var tailBytesWhileEncoding = 0;
      final controller = buildController(
        decodeLaneWidth: laneWidth,
        decoder: (path) async {
          await Future<void>.delayed(const Duration(milliseconds: 2));
          return decodedFixture();
        },
        encoder:
            (rgba, {required width, required height, required quality}) async {
              concurrent++;
              peak = peak > concurrent ? peak : concurrent;
              await Future<void>.delayed(const Duration(milliseconds: 20));
              concurrent--;
              return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
            },
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(32, 32);
      unawaited(
        controller.preloadImages(
          items: fourRawItems(),
          selectedItemId: 'a',
          notifyLoaded: () {},
        ),
      );
      // Drain-bounded sampling, not a fixed pump count: the encoder delays in
      // real time, so a fixed budget makes the DRAIN assertion the flaky thing
      // that fails first and masks what this helper is actually measuring.
      // With a wall-clock deadline the peak below is the only assertion that
      // can distinguish the two widths.
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      // `peak == 0` is part of the condition because the ledger reads zero
      // BEFORE the first decode is dispatched too -- without it the loop exits
      // on the first iteration having observed nothing at all.
      while ((peak == 0 || controller.debugInflightBytes != 0) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(Duration.zero);
        if (concurrent > 0 && controller.debugEncodePublishTailBytes > 0) {
          tailBytesWhileEncoding = controller.debugEncodePublishTailBytes;
        }
      }
      expect(controller.debugInflightBytes, 0);
      // The new ledger's own coverage: a frame in the encode stage is still
      // accounted for, just not on the decode ledger any more.
      expect(
        tailBytesWhileEncoding,
        greaterThan(0),
        reason: 'the encode tail ledger must hold the frames being encoded',
      );
      return peak;
    }

    test('the encode stage width bounds concurrent encodes', () async {
      expect(await peakConcurrentEncodesAtLaneWidth(1), 1);
    });

    test('a wider encode stage lets the same script overlap encodes', () async {
      expect(await peakConcurrentEncodesAtLaneWidth(2), 2);
    });
  });

  group('image_preload_controller_sequential_decode_retention_test.dart', () {
    List<PhotoItem> items(int count) => List.generate(count, (index) {
      final id = 'IMG_${index.toString().padLeft(4, '0')}';
      return PhotoItem(id: id, files: [File('/tmp/$id.dng')]);
    });

    // Alpha must be opaque (0xFF): decoded_rgba_image_provider.dart's
    // debug-only identity short-circuit asserts sampled alpha is opaque.
    // Same repair as commits 253b89f / d43c2a1.
    DecodedRgba decoded() {
      final rgba = Uint8List(2 * 2 * 4);
      for (var i = 3; i < rgba.length; i += 4) {
        rgba[i] = 0xFF;
      }
      return DecodedRgba(rgba: rgba, width: 2, height: 2);
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

    // This is the scheduling killer: all three +/-1 items become eligible after
    // the frozen 250ms debounce, but no-preview RAW execution must be SERIAL.
    // At 0e6407e the tier-two loop uses unawaited(_ensurePayload(...).then(...))
    // for every item, so the 120ms decoder futures overlap and this assertion is
    // a real red pre-fix observation, not a timeout or setup failure.
    test(
      'TC-086 expensive post-debounce RAW execution is sequential',
      () async {
        var concurrent = 0;
        var maxConcurrent = 0;
        var started = 0;
        final controller = ImagePreloadController(
          scheduleFrameCallback: _microtaskFrame,
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              const NativeImageNeedsRawDecode(exifOrientation: 1),
          dngDecoder: (path) async {
            started++;
            concurrent++;
            if (concurrent > maxConcurrent) maxConcurrent = concurrent;
            await Future<void>.delayed(const Duration(milliseconds: 120));
            concurrent--;
            return decoded();
          },
        );
        addTearDown(controller.dispose);

        final photos = items(14);
        await controller.preloadImages(
          items: photos,
          selectedItemId: photos[5].id,
          notifyLoaded: () {},
        );
        await until(
          () => started == 3,
          reason: 'all +/-1 expensive decodes began',
        );
        await until(
          () => concurrent == 0,
          reason: 'all expensive decodes settled',
        );

        expect(
          maxConcurrent,
          1,
          reason:
              'all three eligible RAW items may retain under -3..+5, but only '
              'one native RAW decode may execute after the frozen debounce',
        );
        // `debugInflightBytes` alone can read 0 transiently BETWEEN two serial
        // items (nothing acquired yet for the next one), so it is not a valid
        // "the whole retention window is done" signal on its own here: wait for
        // every -3..+5 slot to actually have landed a payload first.
        await until(
          () => List.generate(
            9,
            (i) => photos[2 + i].id,
          ).every((id) => controller.payloadFor(id) != null),
          reason:
              'the whole -3..+5 retention window to finish its serial decode',
        );
        await settle(controller);
      },
    );

    // Cheap work retains the opposite scheduling rule: the full retention-window
    // loads launch in parallel rather than being serialised behind the selected
    // item. The selected call is completed first so the test observes the later
    // eight-window fan-out, not merely the deliberate priority phase.
    test('TC-088 cheap and expensive payloads retain identically at -3 and '
        'evict identically at -4', () async {
      Future<ImagePreloadController> make(bool expensive) async {
        return ImagePreloadController(
          scheduleFrameCallback: _microtaskFrame,
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              expensive
              ? const NativeImageNeedsRawDecode(exifOrientation: 1)
              : NativeImageBytes(Uint8List.fromList([137, 80, 78, 71])),
          dngDecoder: expensive ? (path) async => decoded() : null,
        );
      }

      final photos = items(20);
      for (final expensive in [false, true]) {
        final controller = await make(expensive);
        addTearDown(controller.dispose);
        await controller.preloadImages(
          items: photos,
          selectedItemId: photos[2].id,
          notifyLoaded: () {},
        );
        await until(
          () => controller.payloadFor(photos[2].id) != null,
          reason: '${expensive ? 'expensive' : 'cheap'} source landed',
        );
        final payload = controller.payloadFor(photos[2].id);

        await controller.preloadImages(
          items: photos,
          selectedItemId: photos[5].id,
          notifyLoaded: () {},
        );
        expect(
          identical(controller.payloadFor(photos[2].id), payload),
          isTrue,
          reason: '${expensive ? 'expensive' : 'cheap'} survives exactly at -3',
        );

        await controller.preloadImages(
          items: photos,
          selectedItemId: photos[6].id,
          notifyLoaded: () {},
        );
        expect(
          controller.payloadFor(photos[2].id),
          isNull,
          reason:
              '${expensive ? 'expensive' : 'cheap'} evicts immediately at -4',
        );
        if (expensive) await settle(controller);
      }
    });

    test('TC-089 cheap full retention-window source loads overlap', () async {
      var concurrent = 0;
      var maxConcurrent = 0;
      final first = Completer<NativeImageResult>();
      var isFirst = true;
      var firstRequested = false;
      final controller = ImagePreloadController(
        scheduleFrameCallback: _microtaskFrame,
        imageLoader: (path, {required purpose, int? targetLongEdge}) {
          if (isFirst) {
            isFirst = false;
            firstRequested = true;
            return first.future;
          }
          concurrent++;
          if (concurrent > maxConcurrent) maxConcurrent = concurrent;
          return Future<NativeImageResult>.delayed(
            const Duration(milliseconds: 80),
            () {
              concurrent--;
              return NativeImageBytes(Uint8List.fromList([137, 80, 78, 71]));
            },
          );
        },
      );
      addTearDown(controller.dispose);
      final photos = items(14);
      final preload = controller.preloadImages(
        items: photos,
        selectedItemId: photos[5].id,
        notifyLoaded: () {},
      );
      // Wait on the REAL signal that the priority (first) load has been invoked,
      // not a fixed event-loop turn: preloadImages reaches this loader only after
      // an async content probe, so on a loaded runner one `Duration.zero` turn can
      // fire before `first` exists to be completed. `until` fails loudly on
      // timeout. Positive, pollable condition -> convertible.
      await until(
        () => firstRequested,
        reason: 'priority (first) loader has been requested',
      );
      first.complete(NativeImageBytes(Uint8List.fromList([137, 80, 78, 71])));
      await preload;
      expect(
        maxConcurrent,
        greaterThan(1),
        reason: 'cheap payload acquisition across -3..+5 must overlap',
      );
    });
  });

  group('image_preload_controller_folder_generation_test.dart', () {
    List<PhotoItem> makeItems() => List.generate(14, (i) {
      final id = 'IMG_${i.toString().padLeft(4, '0')}';
      return PhotoItem(id: id, files: [File('/tmp/$id.dng')]);
    });

    Future<Uint8List> fakeJpegEncoder(
      Uint8List rgba, {
      required int width,
      required int height,
      required int quality,
    }) => _encodeRealPngFolderGen(width, height);

    /// Alpha MUST be opaque: a zero-filled buffer trips the debug-only alpha
    /// assert in decoded_rgba_image_provider.dart and turns every item into a
    /// permanent miss for a reason none of these cases is about.
    DecodedRgba opaqueDecoded() {
      final rgba = Uint8List(64 * 48 * 4);
      for (var i = 3; i < rgba.length; i += 4) {
        rgba[i] = 0xFF;
      }
      return DecodedRgba(rgba: rgba, width: 64, height: 48);
    }

    Future<NativeImageResult> needsRawDecodeLoader(
      String path, {
      required ImageRequestPurpose purpose,
      int? targetLongEdge,
    }) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

    /// Waits until [predicate] holds, or fails with [reason].
    Future<void> until(bool Function() predicate, String reason) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!predicate()) {
        if (DateTime.now().isAfter(deadline)) fail(reason);
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test(
      'TC-939 a decode superseded by a folder switch writes NO permanent miss '
      'and leaves the item re-requestable',
      () async {
        final release = Completer<void>();
        var blockedDecodeStarted = false;
        var supersede = true;

        final controller = ImagePreloadController(
          imageLoader: needsRawDecodeLoader,
          dngDecoder: (path) async {
            if (!supersede) return opaqueDecoded();
            blockedDecodeStarted = true;
            // Blocks until the folder has already been switched, then fails --
            // exactly what the pool's generation gate does to a superseded
            // decode (it throws CeyxPoolDiscardedException).
            await release.future;
            throw StateError('superseded decode');
          },
          payloadEncoder: fakeJpegEncoder,
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(32, 32);

        final items = makeItems();
        await controller.preloadImages(
          items: items,
          selectedItemId: items[5].id,
          notifyLoaded: () {},
        );
        await until(
          () => blockedDecodeStarted,
          'the expensive decode never started; this case would be vacuous',
        );

        // THE FOLDER SWITCH, with the decode still in flight.
        controller.reset();
        supersede = false;
        release.complete();
        // Let the superseded decode land and be refused.
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(
          controller.hasFailed(items[5].id),
          isFalse,
          reason:
              'a decode belonging to the PREVIOUS folder latched an id in the '
              'new one as unreadable-for-the-session',
        );
        expect(controller.payloadFor(items[5].id), isNull);

        // Re-requestable in the new generation: nothing about the refusal may
        // wedge the id (no stuck _loadingKeys claim, no hung future).
        await controller.preloadImages(
          items: items,
          selectedItemId: items[5].id,
          notifyLoaded: () {},
        );
        await until(
          () => controller.payloadFor(items[5].id) != null,
          'the item could not be loaded again after the folder switch: the '
          'superseded decode left state behind that blocks a fresh attempt',
        );
      },
    );

    test('TC-940 a SUCCESSFUL decode that lands after a folder switch is dropped, '
        'not published into the new folder', () async {
      final release = Completer<void>();
      var blockedDecodeStarted = false;

      final controller = ImagePreloadController(
        imageLoader: needsRawDecodeLoader,
        dngDecoder: (path) async {
          blockedDecodeStarted = true;
          await release.future;
          return opaqueDecoded();
        },
        payloadEncoder: fakeJpegEncoder,
      );
      addTearDown(controller.dispose);
      controller.updateTargetSize(32, 32);

      final items = makeItems();
      await controller.preloadImages(
        items: items,
        selectedItemId: items[5].id,
        notifyLoaded: () {},
      );
      await until(() => blockedDecodeStarted, 'the decode never started');

      // Anti-vacuity: prove the SAME wiring publishes a payload when no folder
      // switch intervenes, so a null below means "dropped", not "never worked".
      final control = ImagePreloadController(
        imageLoader: needsRawDecodeLoader,
        dngDecoder: (path) async => opaqueDecoded(),
        payloadEncoder: fakeJpegEncoder,
      );
      addTearDown(control.dispose);
      control.updateTargetSize(32, 32);
      await control.preloadImages(
        items: items,
        selectedItemId: items[5].id,
        notifyLoaded: () {},
      );
      await until(
        () => control.payloadFor(items[5].id) != null,
        'the control controller never published: this case cannot distinguish '
        'a dropped payload from a broken fixture',
      );

      controller.reset();
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // HONESTY NOTE (measured, not assumed): this case still passes with the
      // folder gate mutated OFF. A stale SUCCESS was ALREADY refused, by the
      // "left the window while the load was in flight" early-out -- `reset()`
      // empties `_navRetentionIds` and the sidebar's wanted set, so
      // `_retentionIds` (:320) no longer contains the id. So this is a
      // REGRESSION PIN for existing behaviour plus the gate's defence in
      // depth, NOT proof of the gate. The gate's own proof is TC-939: the
      // permanent-miss branch sits in the `else if (!outcome.deferred)` arm,
      // which no retention check guards, and that case DOES go red when the
      // gate is disabled.
      expect(
        controller.payloadFor(items[5].id),
        isNull,
        reason:
            'a payload decoded for the previous folder was published into the '
            'new one',
      );
      expect(controller.hasFailed(items[5].id), isFalse);
    });

    test(
      'TC-977 a folder switch DURING the issue pass produces zero cache writes '
      'for the old folder (Phase 3 risk R4)',
      () async {
        // Phase 3 made preloadImages a synchronous-issue scheduler: it returns
        // while every window slot is still suspended at its own content probe.
        // That created a window that did not exist before -- "switched folders
        // mid-ISSUE", as opposed to TC-939/TC-940's "mid-DECODE" -- and the
        // per-slot `_previewGeneration` guard inside `_issueWindowItem` is what
        // closes it. Without that guard the suspended probes would resume after
        // `reset()` and route their items, writing the OLD folder's payloads
        // into the fresh generation.
        var loaderCalls = 0;

        final controller = ImagePreloadController(
          imageLoader: (path, {required purpose, int? targetLongEdge}) async {
            loaderCalls++;
            return NativeImageBytes(await _encodeRealPngFolderGen(8, 8));
          },
          payloadEncoder: fakeJpegEncoder,
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(32, 32);

        final items = makeItems();
        // Returns with the whole window issued and NOTHING landed: every slot
        // is still inside its probe. This is the state the guard must survive.
        await controller.preloadImages(
          items: items,
          selectedItemId: items[5].id,
          notifyLoaded: () {},
        );
        expect(
          controller.payloadFor(items[5].id),
          isNull,
          reason:
              'precondition: the pass must still be mid-issue, or this case '
              'is testing the mid-decode path TC-939/940 already cover',
        );

        // THE FOLDER SWITCH, mid-issue.
        controller.reset();
        // Generous: every suspended probe resumes, and any slot that is going
        // to route itself has long since done so.
        await Future<void>.delayed(const Duration(milliseconds: 300));

        for (final item in items) {
          expect(
            controller.payloadFor(item.id),
            isNull,
            reason:
                '${item.id}: a slot issued for the PREVIOUS folder published a '
                'payload into the new generation',
          );
          expect(
            controller.hasFailed(item.id),
            isFalse,
            reason: '${item.id}: a superseded slot latched a permanent miss',
          );
        }
        expect(
          controller.debugTierOneKeyIds,
          isEmpty,
          reason:
              'zero tier-1 ImageCache writes for the old folder: precache is '
              'landing-driven since Phase 3, so a routed stale slot would show '
              'up here even if its payload were evicted again',
        );

        // Anti-vacuity: the same wiring DOES produce payloads when no folder
        // switch intervenes, so the nulls above mean "refused", not "the
        // fixture never worked".
        final control = ImagePreloadController(
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              NativeImageBytes(await _encodeRealPngFolderGen(8, 8)),
          payloadEncoder: fakeJpegEncoder,
        );
        addTearDown(control.dispose);
        control.updateTargetSize(32, 32);
        await control.preloadImages(
          items: items,
          selectedItemId: items[5].id,
          notifyLoaded: () {},
        );
        await until(
          () => control.payloadFor(items[5].id) != null,
          'the control controller never published: this case cannot '
          'distinguish a refused write from a broken fixture',
        );
        // MEASURED, NOT ASSUMED (this assertion was written as
        // `greaterThan(0)` first and observed to fail with 0): the guard sits
        // BETWEEN the probe and the routing call, so a superseded slot is
        // refused before it can ask the loader for anything at all. Zero source
        // work bought for the old folder is the stronger form of "zero cache
        // writes", so it is pinned rather than explained away. The control
        // controller above -- same wiring, same items, no reset -- is what
        // proves the fixture can reach the loader.
        expect(
          loaderCalls,
          isZero,
          reason:
              'a superseded slot bought source work for the old folder: the '
              'generation guard must refuse it before the loader is asked',
        );
      },
    );

    test('TC-941 reset() bumps the decode pool generation exactly once', () {
      final original = ImagePreloadController.decodePoolGenerationSink;
      var bumps = 0;
      ImagePreloadController.decodePoolGenerationSink = () => bumps++;
      addTearDown(() {
        ImagePreloadController.decodePoolGenerationSink = original;
      });

      final controller = ImagePreloadController(
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            const NativeImageFailure('UNUSED', 'generation wiring only'),
      );
      addTearDown(controller.dispose);

      expect(bumps, isZero);
      controller.reset();
      expect(bumps, 1);
      controller.reset();
      expect(bumps, 2);
    });
  });

  group('image_preload_reset_tier_one_evict_test.dart', () {
    setUp(clearImageCacheSetUp);

    // TC-487
    test('reset evicts the tier-1 ImageCache entries it recorded', () async {
      final controller = ImagePreloadController(
        imageLoader: _pngLoader,
        payloadEncoder: null,
      );
      addTearDown(controller.dispose);

      // Tier-1 precache is a no-op until the viewport size is known; without
      // this the assertions below would pass vacuously.
      controller.updateTargetSize(800, 600);
      final items = photoItems(8);
      await controller.preloadImages(
        items: items,
        selectedItemId: 'p0',
        notifyLoaded: () {},
      );
      // Tier-1 precache is unrelated to the tier-2 navigation debounce; this is
      // a generous settle for the fake (near-instant) load, not a debounce wait.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        controller.debugTierOneKeyIds,
        isNotEmpty,
        reason: 'no tier-1 keys recorded: the test would be vacuous',
      );

      // Rebuild the SAME cache key the controller used: tierOneProviderFor is
      // keyed on (bytes identity, width, height), and imageBytesFor hands back
      // the very buffer the retained payload holds.
      final bytes = controller.imageBytesFor('p0');
      expect(bytes, isNotNull, reason: 'p0 payload must be retained');
      final key = await tierOneProviderFor(
        bytes!,
        width: 800,
        height: 600,
      ).obtainKey(const ImageConfiguration());

      expect(
        PaintingBinding.instance.imageCache.statusForKey(key).untracked,
        isFalse,
        reason: 'precondition: p0 tier-1 entry is tracked before reset',
      );

      controller.reset();

      expect(
        PaintingBinding.instance.imageCache.statusForKey(key).untracked,
        isTrue,
        reason: 'reset must evict tier-1 entries, not just drop their keys',
      );
    });
  });

  group('image_preload_reencode_tier_two_test.dart', () {
    List<PhotoItem> rawItems(int count) => List.generate(count, (index) {
      final id = 'IMG_${index.toString().padLeft(4, '0')}';
      return PhotoItem(id: id, files: [File('/tmp/$id.dng')]);
    });

    Future<NativeImageResult> needsRawDecodeLoader(
      String path, {
      required ImageRequestPurpose purpose,
      int? targetLongEdge,
    }) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

    // Real, decodable image bytes ENCODED AT THE CALLER-SUPPLIED DIMENSIONS:
    // the tier-2 catch-up path (publishEncoded) resolves them through a real
    // ImageProvider (MemoryImage), so a non-image placeholder like
    // [0xFF, 0xD8, ...] would fail to decode and isFullSizeReady would never
    // flip -- unlike the piggyback path, which uploads the raw pixels directly
    // via ui.decodeImageFromPixels and never touches these encoded bytes at
    // all. Encoding at (width, height) rather than returning a fixed-size
    // stand-in is what lets TC-366 assert the retained bitstream is really
    // FULL-RESOLUTION (64x48), not the 32x32 navigation window (round-1 review
    // nit #4: a 1x1 fake previously proved only the decode count, not this).
    Future<Uint8List> fakeJpegEncoder(
      Uint8List rgba, {
      required int width,
      required int height,
      required int quality,
    }) => _encodeRealPngReencode(width, height);

    final items = rawItems(14);

    /// An OPAQUE 64x48 RGBA frame. Alpha must be 0xFF: the identity
    /// short-circuit in decoded_rgba_image_provider.dart asserts (debug-only)
    /// that sampled alpha is opaque, because it returns STRAIGHT RGBA where the
    /// old readback path returned PREMULTIPLIED. A zero-filled buffer trips that
    /// assert, which turns every item in these tests into a permanent miss for a
    /// reason neither TC-366 nor TC-367 is about -- neither asserts anything
    /// about alpha. Same repair as commits 253b89f / d43c2a1.
    DecodedRgba opaqueDecoded() {
      final rgba = Uint8List(64 * 48 * 4);
      for (var i = 3; i < rgba.length; i += 4) {
        rgba[i] = 0xFF;
      }
      return DecodedRgba(rgba: rgba, width: 64, height: 48);
    }

    Future<void> navigateTo(
      ImagePreloadController controller,
      List<PhotoItem> items, {
      required int index,
    }) async {
      controller.updateTargetSize(32, 32);
      await controller.preloadImages(
        items: items,
        selectedItemId: items[index].id,
        notifyLoaded: () {},
      );
    }

    // Debounce shortened to 40ms (from the production 250ms default) via each
    // test's own ImagePreloadController(navigationDebounce: ...); this helper's
    // wait is scaled down to match, with margin for the real (but small) PNG
    // encode/decode this file's fakes perform.
    Future<void> pumpTierTwoDebounce() async {
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }

    setUp(clearImageCacheSetUp);

    // Both tests navigate a 14-item all-RAW window, so neighbouring items get
    // decoded too (retention -3..+5). What is under test is the decode count
    // for item[0] SPECIFICALLY -- whether ITS tier-2 rebuild costs a second FFI
    // decode -- so the fake decoder counts calls PER PATH, not globally.

    // TC-366 — the headline claim: a tier-2 rebuild costs NO second FFI decode.
    test(
      're-encoded RAW rebuilds tier-2 without calling the decoder again',
      () async {
        final decodeCallsByPath = <String, int>{};
        final controller = ImagePreloadController(
          navigationDebounce: const Duration(milliseconds: 40),
          imageLoader: needsRawDecodeLoader,
          dngDecoder: (path) async {
            decodeCallsByPath.update(path, (n) => n + 1, ifAbsent: () => 1);
            return opaqueDecoded();
          },
          payloadEncoder: fakeJpegEncoder,
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(32, 32);
        final path0 = items[0].bestFileToLoad!.path;

        await navigateTo(controller, items, index: 0); // decode + re-encode
        await pumpTierTwoDebounce();
        expect(decodeCallsByPath[path0], 1);

        // index 3: retention (-3..+5) still covers item0 (3-3==0), but the
        // tier-2 band (-1..+3) does not (backward distance 3 > kTierTwoBefore
        // == 1) -- so ONLY item0's tier-2 entry is evicted, its payload stays
        // retained, exactly the scenario the plan names ("its tier-2 entry is
        // evicted", not "it leaves the retention window").
        await navigateTo(controller, items, index: 3);
        await pumpTierTwoDebounce();
        expect(
          controller.debugTierTwoKeyIds.contains(items[0].id),
          isFalse,
          reason: 'item0 tier-2 entry must actually be evicted by this move',
        );
        await navigateTo(controller, items, index: 0); // and back
        await pumpTierTwoDebounce();

        expect(
          decodeCallsByPath[path0],
          1,
          reason: 'the rebuild must come from the retained full-res JPEG',
        );
        expect(controller.isFullSizeReady(items[0].id), isTrue);

        // Resolve the actual tier-2 image and assert its pixel dimensions are
        // the FULL-RESOLUTION decode (64x48), not the 32x32 navigation window
        // -- a re-encode from window-resolution pixels would still pass every
        // assertion above (round-1 review nit #4).
        final tierTwoProvider = controller.debugTierTwoProviderFor(items[0].id);
        expect(tierTwoProvider, isNotNull);
        final infoCompleter = Completer<ImageInfo>();
        late ImageStreamListener listener;
        final stream = tierTwoProvider!.resolve(const ImageConfiguration());
        listener = ImageStreamListener((image, synchronousCall) {
          stream.removeListener(listener);
          infoCompleter.complete(image);
        }, onError: (error, stackTrace) => infoCompleter.completeError(error));
        stream.addListener(listener);
        final info = await infoCompleter.future;
        expect(
          (info.image.width, info.image.height),
          (64, 48),
          reason:
              'the retained tier-2 bitstream must be the FULL-RESOLUTION '
              'decode (64x48), not the 32x32 navigation window',
        );
        info.dispose();
      },
    );

    // TC-367 — discrimination: without the encoder the same script costs 2 decodes.
    test(
      'without re-encoding the same navigation costs a second decode',
      () async {
        final decodeCallsByPath = <String, int>{};
        final controller = ImagePreloadController(
          navigationDebounce: const Duration(milliseconds: 40),
          imageLoader: needsRawDecodeLoader,
          dngDecoder: (path) async {
            decodeCallsByPath.update(path, (n) => n + 1, ifAbsent: () => 1);
            return opaqueDecoded();
          },
          payloadEncoder: null,
        );
        addTearDown(controller.dispose);
        controller.updateTargetSize(32, 32);
        final path0 = items[0].bestFileToLoad!.path;
        await navigateTo(controller, items, index: 0);
        await pumpTierTwoDebounce();
        await navigateTo(controller, items, index: 3);
        await pumpTierTwoDebounce();
        await navigateTo(controller, items, index: 0);
        await pumpTierTwoDebounce();
        expect(decodeCallsByPath[path0], 2);
      },
    );
  });
}
