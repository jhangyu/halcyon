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

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';

import '../../support/synthetic_dng.dart';
import '../../support/temp_dirs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
        payloadEncoder: null,
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

      final items = [PhotoItem(id: 'cheap', files: [File(path)])];

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
        payloadEncoder: null,
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

      final items = [PhotoItem(id: 'expensive', files: [File(path)])];

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
}
