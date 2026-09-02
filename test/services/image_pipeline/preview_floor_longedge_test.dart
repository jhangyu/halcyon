// F4 / AC6: ONE threshold answers "is the embedded preview big enough?".
//
// The routing verdict (`PhotoSource.probeSource`) compares the largest
// embedded candidate against the LIVE viewport long edge (AD-033, frozen).
// The loader used to enforce a DIFFERENT, hardcoded floor of 2800
// (`ImageRequestPurpose.preview.targetSize`). On a window whose physical long
// edge is under 2800 the two disagreed: the probe said `cheap`, the loader
// then rejected the very candidate the probe had counted and forced a full RAW
// decode for an item classified cheap.
//
// Synthetic fixtures on purpose: the user's own corpus carries 7008px
// previews, which clear BOTH thresholds and are therefore blind to this bug.
// The disagreement only shows on a preview that sits between the real viewport
// and 2800.
//
//   TC-660  a sub-2800 viewport routes a 2000px-preview RAW cheap end-to-end
//   TC-661  AD-033 guard: a viewport ABOVE the preview still routes expensive

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/dart_image_loader.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_source.dart';

import '../../support/synthetic_dng.dart';
import '../../support/temp_dirs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late String dngPath;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('m4_preview_floor');
    addTempDirTeardown(dir);
    // ONE candidate at 2000px: bigger than a small window, smaller than the
    // old hardcoded 2800 floor. DefaultCropSize tracks the largest candidate,
    // so this candidate also clears the extractor's 0.90*cropMax full-size
    // gate -- the only thing under test here is the FLOOR.
    dngPath = await writeSyntheticDng(
      buildSyntheticDng(
        candidates: const [SyntheticCandidate(width: 2000, height: 1333)],
      ),
      dir: dir,
      name: 'preview2000.dng',
    );
  });

  // No decoder is wired on purpose. With no decoder, a `NeedsRawDecode` verdict
  // becomes an unmistakable `expensive` + null payload + NO_NATIVE_DECODER,
  // so "the loader rejected the preview" cannot hide behind a successful
  // decode. The assertion is therefore about the ROUTE, not the pixels.
  const source = PhotoSource(loader: dartImageLoad);

  test('TC-660 a sub-2800 viewport routes a 2000px-preview RAW cheap '
      'end-to-end', () async {
    const viewportLongEdge = 1600;

    // Half one: the routing verdict. 2000 >= 1600, so AD-033 says cheap.
    expect(
      (await PhotoSource.probeSource(dngPath, longEdge: viewportLongEdge)).cost,
      SourceCost.cheap,
      reason: 'the frozen AD-033 comparison against the LIVE viewport is the '
          'reference answer this test holds the loader to',
    );

    // Half two: the loader must reach the SAME answer. Before the fix it
    // measured the same file against a hardcoded 2800, rejected the 2000px
    // candidate, and returned NeedsRawDecode -- a full RAW decode for an item
    // the scheduler had just put on the cheap lane.
    final outcome = await source.load(dngPath, longEdge: viewportLongEdge);
    expect(
      outcome.observedCost,
      SourceCost.cheap,
      reason: 'the loader must apply the SAME long edge the routing '
          'comparison used, not a hardcoded 2800',
    );
    expect(
      outcome.payload,
      isNotNull,
      reason: 'the embedded preview clears the live viewport, so it must be '
          'served; a null payload here is the wasted-RAW-decode route',
    );
    expect(outcome.deferred, isFalse);
    expect(outcome.failureCode, isNull);
  });

  // The negative half. AD-033 is frozen: this fix changes WHERE the number
  // comes from and must not loosen the comparison. A viewport ABOVE the
  // preview's long edge must still refuse the preview.
  test('TC-661 a viewport above the preview still routes expensive '
      '(AD-033 unchanged)', () async {
    const viewportLongEdge = 4000;

    expect(
      (await PhotoSource.probeSource(dngPath, longEdge: viewportLongEdge)).cost,
      SourceCost.expensive,
      reason: '2000 < 4000: a sub-viewport preview scaled up is visibly '
          'blurry, which is exactly what AD-033 refuses',
    );

    final outcome = await source.load(dngPath, longEdge: viewportLongEdge);
    expect(
      outcome.observedCost,
      SourceCost.expensive,
      reason: 'threading the live long edge must not make the loader more '
          'permissive -- 2000px cannot satisfy a 4000px viewport',
    );
    expect(outcome.payload, isNull);
    expect(
      outcome.failureCode,
      kNoNativeDecoderCode,
      reason: 'no decoder is wired, so the refused preview surfaces as the D3 '
          'state -- proof the loader really did reject the candidate',
    );
  });
}
