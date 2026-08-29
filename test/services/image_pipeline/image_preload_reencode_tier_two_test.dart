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

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<PhotoItem> rawItems(int count) => List.generate(count, (index) {
    final id = 'IMG_${index.toString().padLeft(4, '0')}';
    return PhotoItem(id: id, files: [File('/tmp/$id.dng')]);
  });

  Future<NativeImageResult> needsRawDecodeLoader(
    String path, {
    required ImageRequestPurpose purpose,
  }) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

  // Real, tiny, decodable image bytes: the tier-2 catch-up path
  // (publishEncoded) resolves them through a real ImageProvider (MemoryImage),
  // so a non-image placeholder like [0xFF, 0xD8, ...] would fail to decode and
  // isFullSizeReady would never flip -- unlike the piggyback path, which
  // uploads the raw pixels directly via ui.decodeImageFromPixels and never
  // touches these encoded bytes at all.
  final tinyPngBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAA'
    'AAYAAjCB0C8AAAAASUVORK5CYII=',
  );

  Future<Uint8List> fakeJpegEncoder(
    Uint8List rgba, {
    required int width,
    required int height,
    required int quality,
  }) async => Uint8List.fromList(tinyPngBytes);

  final items = rawItems(14);

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

  Future<void> pumpTierTwoDebounce() async {
    // tierTwoNavigationDebounce is 250ms; give the sequential tier-2 queue
    // room to actually run the decode/upgrade it schedules.
    await Future<void>.delayed(const Duration(milliseconds: 600));
  }

  setUp(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

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
        imageLoader: needsRawDecodeLoader,
        dngDecoder: (path) async {
          decodeCallsByPath.update(path, (n) => n + 1, ifAbsent: () => 1);
          return DecodedRgba(rgba: Uint8List(64 * 48 * 4), width: 64, height: 48);
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
      expect(controller.debugTierTwoKeyIds.contains(items[0].id), isFalse,
          reason: 'item0 tier-2 entry must actually be evicted by this move');
      await navigateTo(controller, items, index: 0); // and back
      await pumpTierTwoDebounce();

      expect(
        decodeCallsByPath[path0],
        1,
        reason: 'the rebuild must come from the retained full-res JPEG',
      );
      expect(controller.isFullSizeReady(items[0].id), isTrue);
    },
  );

  // TC-367 — discrimination: without the encoder the same script costs 2 decodes.
  test('without re-encoding the same navigation costs a second decode', () async {
    final decodeCallsByPath = <String, int>{};
    final controller = ImagePreloadController(
      imageLoader: needsRawDecodeLoader,
      dngDecoder: (path) async {
        decodeCallsByPath.update(path, (n) => n + 1, ifAbsent: () => 1);
        return DecodedRgba(rgba: Uint8List(64 * 48 * 4), width: 64, height: 48);
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
  });
}
