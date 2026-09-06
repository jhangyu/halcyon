import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/decoded_rgba_image_provider.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';

/// T2 (docs/logs/2026-09-06/h1h2-plan.md ticket T2, spec §1.6/§3 AC-H1-3):
/// pins H1-A's `pixelPayloadFromOrientedImage` (decoded_rgba_image_provider.dart)
/// mechanically -- byte-equivalence against the OLD shape
/// (`decodedRgbaToPixelPayload` alone) for all 8 EXIF orientations at scale
/// 1.0, plus a downscale-arm shape/placement check.
///
/// Written to the SPEC's declared API (§1.2), not to T1's code -- the
/// independent-verifier discipline the ticket brief requires.
///
/// TC-999 / TC-1000 (grepped for collision against the whole tree, incl.
/// untracked, at paste time; highest prior in docs/sop/unit_test.md was
/// TC-997, and this file's sibling TC-998/998b are the other T2 test file).
///
/// Marker fixture and `_expected` table borrowed verbatim from
/// decoded_rgba_image_provider_test.dart (same file, same convention) so a
/// wrong orientation cannot pass by shape alone -- 90CW/90CCW share a shape,
/// mirrored/unmirrored share a shape, only per-pixel markers discriminate
/// all 8 cases.
///
/// Engine requirement: plain `test()`, never `testWidgets()`, per
/// lessons-learned 2026-08-17 -- a `testWidgets` body's FakeAsync zone hangs
/// forever on a real engine future (`decodeImageFromPixels`,
/// `Picture.toImage`), and this file awaits both, repeatedly.
const int a = 10, b = 50, c = 90, d = 130, e = 170, f = 210;

DecodedRgba source2x3() {
  const rows = <List<int>>[
    [a, b],
    [c, d],
    [e, f],
  ];
  final bytes = Uint8List(2 * 3 * 4);
  var i = 0;
  for (final row in rows) {
    for (final marker in row) {
      bytes[i++] = marker;
      bytes[i++] = 0;
      bytes[i++] = 0;
      bytes[i++] = 255; // opaque: premultiplied/straight agree
    }
  }
  return DecodedRgba(rgba: bytes, width: 2, height: 3);
}

const _expected = <int, List<List<int>>>{
  1: [
    [a, b],
    [c, d],
    [e, f],
  ],
  2: [
    [b, a],
    [d, c],
    [f, e],
  ],
  3: [
    [f, e],
    [d, c],
    [b, a],
  ],
  4: [
    [e, f],
    [c, d],
    [a, b],
  ],
  5: [
    [a, c, e],
    [b, d, f],
  ],
  6: [
    [e, c, a],
    [f, d, b],
  ],
  7: [
    [f, d, b],
    [e, c, a],
  ],
  8: [
    [b, d, f],
    [a, c, e],
  ],
};

List<List<int>> gridOf(PixelPayload payload) => List.generate(
  payload.height,
  (y) =>
      List.generate(payload.width, (x) => payload.rgba[(y * payload.width + x) * 4]),
);

/// Runs the NEW shape (spec §1.1's branch): full-res oriented pixels first,
/// then EITHER the identity short-circuit (fullRes.image == null) OR
/// `pixelPayloadFromOrientedImage` derived from the retained oriented image.
/// Disposes the oriented image itself (test-owned here; production ownership
/// is the caller's per OrientedFullRes's doc, ticket T1/T5 territory).
Future<PixelPayload> newShapePixels(
  DecodedRgba decoded, {
  required int exifOrientation,
  required int longEdge,
}) async {
  final fullRes = await decodedRgbaToOrientedFullRes(
    decoded,
    exifOrientation: exifOrientation,
  );
  try {
    if (fullRes.image == null) {
      return await decodedRgbaToPixelPayload(
        decoded,
        exifOrientation: exifOrientation,
        longEdge: longEdge,
      );
    }
    return await pixelPayloadFromOrientedImage(
      fullRes.image!,
      longEdge: longEdge,
    );
  } finally {
    fullRes.image?.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TC-999: OLD vs NEW shape, byte-equal at scale 1.0, all 8 orientations', () {
    for (final orientation in _expected.keys) {
      test('orientation $orientation', () async {
        final oldPayload = await decodedRgbaToPixelPayload(
          source2x3(),
          exifOrientation: orientation,
          longEdge: 0, // 0 = never-upscale rule's "no cap" -> scale stays 1.0
        );
        final newPayload = await newShapePixels(
          source2x3(),
          exifOrientation: orientation,
          longEdge: 0,
        );

        expect(newPayload.width, oldPayload.width);
        expect(newPayload.height, oldPayload.height);
        expect(
          newPayload.rgba,
          oldPayload.rgba,
          reason:
              'pixelPayloadFromOrientedImage must be byte-identical to the '
              'old decodedRgbaToPixelPayload shape at scale 1.0 for '
              'orientation $orientation',
        );
        // Cross-check against the hand-written table too, not just OLD==NEW
        // (a bug shared by both call shapes would otherwise be invisible).
        expect(gridOf(newPayload), _expected[orientation]);
      });
    }
  });

  group('TC-1000: downscale arm (dimensions + corner placement, not byte-exactness)', () {
    // Same 2x3 marker layout, each marker inflated to a uniform 2x2 block so
    // a 0.5x downscale collapses each block back to one pixel of its own
    // marker -- same recipe as decoded_rgba_image_provider_test.dart's
    // blockySource(), reused here rather than re-derived so a formula bug in
    // one file cannot rubber-stamp the same bug in the other.
    DecodedRgba blockySource() {
      const rows = <List<int>>[
        [a, b],
        [c, d],
        [e, f],
      ];
      final bytes = Uint8List(4 * 6 * 4);
      for (var y = 0; y < 6; y++) {
        for (var x = 0; x < 4; x++) {
          final marker = rows[y ~/ 2][x ~/ 2];
          final i = (y * 4 + x) * 4;
          bytes[i] = marker;
          bytes[i + 3] = 255;
        }
      }
      return DecodedRgba(rgba: bytes, width: 4, height: 6);
    }

    for (final orientation in _expected.keys) {
      test('orientation $orientation downscaled to longEdge 3', () async {
        // Oriented long edge is 6 for every case (4x6 <-> 6x4), so longEdge 3
        // is a clean 0.5x for all eight -- same convention as the existing
        // decodedRgbaToPixelPayload TC-069 suite.
        final payload = await newShapePixels(
          blockySource(),
          exifOrientation: orientation,
          longEdge: 3,
        );
        final expected = _expected[orientation]!;
        expect(payload.width, expected.first.length);
        expect(payload.height, expected.length);
        // Corner-colour placement, not byte-exactness (spec §1.6 / plan T2
        // step 2): resampling legitimately differs in rounding between the
        // old single-pass rotate+scale and the new two-pass (rotate once,
        // then a SEPARATE scaled draw off the retained oriented image) --
        // this fixture's blocks are uniform so the corners survive either
        // rounding path unambiguously.
        final grid = gridOf(payload);
        expect(grid.first.first, expected.first.first, reason: 'top-left corner');
        expect(grid.first.last, expected.first.last, reason: 'top-right corner');
        expect(grid.last.first, expected.last.first, reason: 'bottom-left corner');
        expect(grid.last.last, expected.last.last, reason: 'bottom-right corner');
      });
    }

    test('a frame already smaller than the window is NOT upscaled', () async {
      final payload = await newShapePixels(
        blockySource(),
        exifOrientation: 1,
        longEdge: 4000,
      );
      expect(payload.width, 4);
      expect(payload.height, 6);
    });
  });

  test(
    'pixelPayloadFromOrientedImage borrows its argument: never disposes it',
    () async {
      final fullRes = await decodedRgbaToOrientedFullRes(
        source2x3(),
        exifOrientation: 6, // non-identity: image is non-null
      );
      final oriented = fullRes.image!;
      addTearDown(oriented.dispose);

      await pixelPayloadFromOrientedImage(oriented, longEdge: 0);
      expect(
        oriented.debugDisposed,
        isFalse,
        reason: 'the caller owns OrientedFullRes.image; this function must '
            'never dispose it (spec §1.2/§1.4)',
      );

      // And again, on the downscale arm.
      await pixelPayloadFromOrientedImage(oriented, longEdge: 1);
      expect(oriented.debugDisposed, isFalse);
    },
  );

  // NOTE (attempted, not included): spec §1.2 step 4 documents a `StateError`
  // for a null `toByteData` readback, mirroring `:206-208`'s wording family.
  // That arm could not be exercised independently here: the only way to make
  // a LIVE `ui.Image` return null from `toByteData` is to dispose it first,
  // and a disposed image instead trips the engine's own
  // `debugAssertNotDisposed` (an `AssertionError` inside `dart:ui`, before
  // this function's own null-check ever runs) -- observed directly rather
  // than assumed. Not a T2 finding to act on (T1's code is out of scope for
  // this ticket); noted here as an uncertainty for the report rather than
  // silently dropped.
}
