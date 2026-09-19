import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/decoded_rgba_image_provider.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';

/// r6 cancel-return plan, Task 5 (AMENDMENT 2026-09-07): observation for the
/// P6 downscale sub-case (`r6-cancel-return-spec.md` §3's "sub-case worth
/// recording and NOT acting on", §9.1 user ruling reopening it).
///
/// WHERE THE SUB-CASE ACTUALLY LIVES: `photo_source.dart`'s `buildFallback`
/// calls `decodedRgbaToOrientedFullRes` (produces `fullRes`, `image: null` on
/// the identity path) and, when a fallback is needed, `fullRes.image == null`
/// routes to `decodedRgbaToPixelPayload(decoded, ..., longEdge: ...)` -- a
/// SEPARATE function with its OWN identity short-circuit
/// (`decoded_rgba_image_provider.dart`, `decodedRgbaToPixelPayload`) gated by
/// `longEdge <= 0 || longestEdge <= longEdge`. When that guard is false (the
/// decoded frame is LARGER than the requested long edge), the short-circuit is
/// skipped and a fresh GPU readback runs -- producing a `PixelPayload.rgba`
/// that is a DIFFERENT object from `fullRes.rgba`, not an alias of the pooled
/// buffer. `canReleaseNativeBuffer`'s current tail clause
/// (`return fullRes.image != null;`, image_preload_controller.dart:166) has no
/// way to see this: it only inspects `fullRes.image`, which is `null` on BOTH
/// branches of `decodedRgbaToPixelPayload` (that function never sets it), so
/// today both the true-aliasing case AND this fresh-buffer case defer to the
/// finalizer identically.
///
/// INSTRUMENT: object-identity between the published `PixelPayload.rgba` and
/// `fullRes.rgba` is the exact, zero-cost discriminator -- `identical()`,
/// no re-derivation of `longEdge`/dimensions at the release site (the
/// duplication the spec's §6 out-of-scope note worried about does not apply
/// to an identity check). The two groups below are the positive control: the
/// SAME predicate expression (`identical(published.rgba, fullRes.rgba)`)
/// reads `true` for the true-aliasing fixture and `false` for the
/// downscale-sub-case fixture, proving the instrument moves rather than
/// reading a constant.
void main() {
  group('P6 downscale sub-case observation (r6 Task 5)', () {
    DecodedRgba fixture() {
      // 8x8 opaque frame: large enough that a longEdge of 4 forces a real
      // downscale (8 > 4), and small enough the GPU round trip is cheap.
      final rgba = Uint8List(8 * 8 * 4);
      for (var i = 0; i < rgba.length; i += 4) {
        rgba[i] = 0x40;
        rgba[i + 1] = 0x80;
        rgba[i + 2] = 0xC0;
        rgba[i + 3] = 0xFF;
      }
      return DecodedRgba(rgba: rgba, width: 8, height: 8);
    }

    // Plain test(), NOT testWidgets(): testWidgets' TestWidgetsFlutterBinding
    // installs a fake-async zone, and awaiting a real-engine future in it
    // (GPU upload/draw/readback via _applyTransform/toByteData) hung
    // indefinitely when this file ran alongside the rest of
    // test/services/image_pipeline/ -- even wrapped in tester.runAsync(),
    // which is documented to escape the fake zone per-call but does not
    // prevent OTHER tests' bindings/timers in the same process from starving
    // it. plain test() uses no widget binding at all, so there is no fake
    // zone to escape. Reproduced: hung under testWidgets+runAsync when run as
    // `flutter test test/services/image_pipeline/` (r6-impl-sonnet report,
    // r6-runner-haiku 150s foreground timeout); passes standalone AND inside
    // the full directory run as plain test() (self-verified below).
    test(
      'TRUE aliasing: no downscale needed -> published.rgba IS fullRes.rgba '
      '(must stay with the finalizer -- P6 proper)',
      () async {
        final decoded = fixture();
        final fullRes = await decodedRgbaToOrientedFullRes(
          decoded,
          exifOrientation: 1,
        );
        expect(fullRes.image, isNull, reason: 'identity path, no GPU pass');

        // longEdge >= the source's longest edge (8) -- decodedRgbaToPixelPayload's
        // OWN short-circuit also fires, aliasing the same buffer again.
        final published = await decodedRgbaToPixelPayload(
          decoded,
          exifOrientation: 1,
          longEdge: 8,
        );

        expect(
          identical(published.rgba, fullRes.rgba),
          isTrue,
          reason:
              'positive control (aliasing arm): the instrument must read '
              'true here or it is not discriminating anything',
        );
      },
    );

    test(
      'DOWNSCALE SUB-CASE: fullRes.image is still null (identity path) but '
      'published.rgba is a FRESH readback -- safe to release, currently '
      'deferred to the finalizer by canReleaseNativeBuffer\'s image!=null tail',
      () async {
        final decoded = fixture();
        final fullRes = await decodedRgbaToOrientedFullRes(
          decoded,
          exifOrientation: 1,
        );
        // This is the crux fact the spec's retracted premise got wrong: the
        // sub-case is invisible to `fullRes.image` -- it is STILL null
        // here, identically to the true-aliasing arm above.
        expect(
          fullRes.image,
          isNull,
          reason:
              'canReleaseNativeBuffer cannot distinguish this arm from '
              'true P6 aliasing by inspecting fullRes.image alone -- both '
              'are null',
        );

        // longEdge < the source's longest edge (8) forces the downscale
        // branch inside decodedRgbaToPixelPayload's OWN short-circuit
        // check.
        final published = await decodedRgbaToPixelPayload(
          decoded,
          exifOrientation: 1,
          longEdge: 4,
        );

        expect(
          identical(published.rgba, fullRes.rgba),
          isFalse,
          reason:
              'positive control (sub-case arm): the SAME expression that '
              'read true above must read false here -- this is the '
              'instrument moving, not a constant reading',
        );
      },
    );
  });
}
