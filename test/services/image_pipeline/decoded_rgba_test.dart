import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ceyx/ceyx.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/supported_photo_formats.dart';
import 'package:halcyon_flutter/services/image_pipeline/decoded_rgba_image_provider.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/exif_orientation.dart';
import 'package:halcyon_flutter/services/image_pipeline/full_decoder_dispatch.dart';
import 'package:halcyon_flutter/services/image_pipeline/heif_decode_service.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_source.dart';
import 'package:image/image.dart' as img;

import '../../support/synthetic_dng.dart';
import '../../support/temp_dirs.dart';

/// A 2x3 opaque source: R carries a per-pixel marker so a wrong permutation
/// cannot pass by accident, and A is 0xFF everywhere so the premultiplied
/// (readback) and straight (short-circuit) encodings are byte-identical.
DecodedRgba _sourceShort() {
  const markers = <int>[10, 50, 90, 130, 170, 210];
  final bytes = Uint8List(2 * 3 * 4);
  for (var i = 0; i < markers.length; i++) {
    bytes[i * 4] = markers[i];
    bytes[i * 4 + 3] = 255;
  }
  return DecodedRgba(rgba: bytes, width: 2, height: 3);
}

/// A 2x2 OPAQUE source. Alpha must be 0xFF: both identity short-circuits
/// assert `_sampledOpaque`, so a transparent fixture would fail inside that
/// assert instead of in the assertion under test.
DecodedRgba _sourceGate() {
  final bytes = Uint8List(2 * 2 * 4);
  for (var p = 0; p < 4; p++) {
    bytes[p * 4] = 10 + p * 20; // R carries a marker
    bytes[p * 4 + 3] = 0xFF;
  }
  return DecodedRgba(rgba: bytes, width: 2, height: 2);
}

/// A gate the test opens by hand. `requests` counts slot requests, so
/// "gated exactly once" and "never gated" are both directly assertable.
class ManualGate {
  final List<Completer<void>> _waiting = [];
  int requests = 0;

  Future<void> call() {
    requests++;
    final completer = Completer<void>();
    _waiting.add(completer);
    return completer.future;
  }

  void openAll() {
    final due = List<Completer<void>>.of(_waiting);
    _waiting.clear();
    for (final completer in due) {
      completer.complete();
    }
  }
}

/// Pumps real, zero-duration timers/microtasks -- what would let a pending
/// future settle if nothing else were blocking it.
Future<void> _pumpEventLoop([int rounds = 8]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

// A 2x3 source image whose every pixel is a distinct marker, so a wrong
// orientation cannot pass by accident. Shape-only assertions have no
// discriminating power here: 90CW and 90CCW produce the SAME 3x2 shape, and
// mirrored/unmirrored produce the same shape as each other. Only per-pixel
// identity separates all 8 EXIF cases.
//
//   src (w=2, h=3):   A B
//                     C D
//                     E F
const int a = 10, b = 50, c = 90, d = 130, e = 170, f = 210;

DecodedRgba _sourceProvider() {
  const rows = <List<int>>[
    [a, b],
    [c, d],
    [e, f],
  ];
  final bytes = Uint8List(2 * 3 * 4);
  var i = 0;
  for (final row in rows) {
    for (final marker in row) {
      bytes[i++] = marker; // R carries the marker
      bytes[i++] = 0;
      bytes[i++] = 0;
      bytes[i++] = 255; // opaque, so premultiplication is a no-op
    }
  }
  return DecodedRgba(rgba: bytes, width: 2, height: 3);
}

/// Reads back the R channel of every pixel as a row-major grid of markers.
Future<List<List<int>>> _markerGrid(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final bytes = data!.buffer.asUint8List();
  return List.generate(
    image.height,
    (y) => List.generate(image.width, (x) => bytes[(y * image.width + x) * 4]),
  );
}

// Expected results, written out longhand from the EXIF spec rather than
// recomputed with the same formula the implementation uses -- a test that
// re-derives the mapping would pass against a wrong-but-self-consistent
// implementation.
const _expected = <int, List<List<int>>>{
  1: [
    [a, b],
    [c, d],
    [e, f],
  ], // as stored
  2: [
    [b, a],
    [d, c],
    [f, e],
  ], // mirror horizontal
  3: [
    [f, e],
    [d, c],
    [b, a],
  ], // rotate 180
  4: [
    [e, f],
    [c, d],
    [a, b],
  ], // mirror vertical
  5: [
    [a, c, e],
    [b, d, f],
  ], // transpose (mirror horizontal + rotate 270 CW)
  6: [
    [e, c, a],
    [f, d, b],
  ], // rotate 90 CW
  7: [
    [f, d, b],
    [e, c, a],
  ], // transverse (mirror horizontal + rotate 90 CW)
  8: [
    [b, d, f],
    [a, c, e],
  ], // rotate 270 CW
};

/// T2 (docs/logs/2026-09-06/h1h2-plan.md ticket T2, spec §1.6/§3 AC-H1-3):
/// pins H1-A's `pixelPayloadFromOrientedImage` (decoded_rgba_image_provider.dart)
/// mechanically -- byte-equivalence against the OLD shape
/// (`decodedRgbaToPixelPayload` alone) for all 8 EXIF orientations at scale
/// 1.0, plus a downscale-arm shape/placement check.
///
/// Marker fixture and `_expected` table borrowed verbatim from
/// decoded_rgba_image_provider_test.dart (same file, same convention) so a
/// wrong orientation cannot pass by shape alone -- 90CW/90CCW share a shape,
/// mirrored/unmirrored share a shape, only per-pixel markers discriminate
/// all 8 cases.
const int aO = 10, bO = 50, cO = 90, dO = 130, eO = 170, fO = 210;

DecodedRgba source2x3() {
  const rows = <List<int>>[
    [aO, bO],
    [cO, dO],
    [eO, fO],
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

const _expectedO = <int, List<List<int>>>{
  1: [
    [aO, bO],
    [cO, dO],
    [eO, fO],
  ],
  2: [
    [bO, aO],
    [dO, cO],
    [fO, eO],
  ],
  3: [
    [fO, eO],
    [dO, cO],
    [bO, aO],
  ],
  4: [
    [eO, fO],
    [cO, dO],
    [aO, bO],
  ],
  5: [
    [aO, cO, eO],
    [bO, dO, fO],
  ],
  6: [
    [eO, cO, aO],
    [fO, dO, bO],
  ],
  7: [
    [fO, dO, bO],
    [eO, cO, aO],
  ],
  8: [
    [bO, dO, fO],
    [aO, cO, eO],
  ],
};

List<List<int>> gridOfO(PixelPayload payload) => List.generate(
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

/// A 4x2 RGBA buffer whose first pixel is a distinct marker, so a test cannot
/// pass by receiving "some" DecodedRgba.
DecodedRgba _fakeDecoded({int width = 4, int height = 2}) {
  final rgba = Uint8List(width * height * 4);
  rgba[0] = 0xA5;
  return DecodedRgba(rgba: rgba, width: width, height: height);
}

void main() {
  group('decoded_rgba_shortcircuit_test.dart', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    // TC-819
    test('identity orientation at longEdge 0 returns the decoder buffer itself',
        () async {
      final src = _sourceShort();
      final payload =
          await decodedRgbaToPixelPayload(src, exifOrientation: 1, longEdge: 0);
      expect(identical(payload.rgba, src.rgba), isTrue);
      expect(payload.width, 2);
      expect(payload.height, 3);
    });

    // TC-820
    test('identity orientation with no downscale required short-circuits too',
        () async {
      final src = _sourceShort();
      final payload = await decodedRgbaToPixelPayload(
        src,
        exifOrientation: 1,
        longEdge: 4096,
      );
      expect(identical(payload.rgba, src.rgba), isTrue);
    });

    // TC-821 -- the short-circuit must be byte-equal to the GPU round trip it
    // replaces. `decodedRgbaToImage` is the same upload+orient path the old
    // implementation used, so its readback is the reference output.
    test('short-circuit bytes equal the GPU round trip for an opaque frame',
        () async {
      final src = _sourceShort();
      final image = await decodedRgbaToImage(src, exifOrientation: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      final reference = data!.buffer.asUint8List();

      final payload =
          await decodedRgbaToPixelPayload(src, exifOrientation: 1, longEdge: 0);
      expect(payload.rgba, orderedEquals(reference));
    });

    // TC-822 -- the out-of-bounds guard must survive the short-circuit.
    test('buffer/dimension mismatch still throws on the short-circuit path',
        () async {
      final bad = DecodedRgba(rgba: Uint8List(4), width: 2, height: 3);
      expect(
        () => decodedRgbaToPixelPayload(bad, exifOrientation: 1, longEdge: 0),
        throwsArgumentError,
      );
    });

    // TC-823 -- the non-identity path is untouched: orientation 6 still rotates.
    test('orientation 6 still rotates and does not short-circuit', () async {
      final src = _sourceShort();
      final payload =
          await decodedRgbaToPixelPayload(src, exifOrientation: 6, longEdge: 0);
      expect(identical(payload.rgba, src.rgba), isFalse);
      expect(payload.width, 3);
      expect(payload.height, 2);
    });

    // TC-824a
    test('oriented full-res carries no handle for orientation 1', () async {
      final src = _sourceShort();
      final full = await decodedRgbaToOrientedFullRes(src, exifOrientation: 1);
      expect(full.image, isNull);
      expect(identical(full.rgba, src.rgba), isTrue);
      expect(full.width, 2);
      expect(full.height, 3);
    });

    // TC-824b
    test('oriented full-res carries the rendered handle for orientation 6',
        () async {
      final src = _sourceShort();
      final full = await decodedRgbaToOrientedFullRes(src, exifOrientation: 6);
      expect(full.image, isNotNull);
      expect(full.image!.width, 3);
      expect(full.image!.height, 2);
      expect(full.width, 3);
      expect(full.height, 2);
      // The bytes and the handle must describe the same frame.
      final data =
          await full.image!.toByteData(format: ui.ImageByteFormat.rawRgba);
      expect(full.rgba, orderedEquals(data!.buffer.asUint8List()));
      full.image!.dispose();
    });

    // TC-824c -- the handle is handed out live, not already disposed.
    test('the returned handle is the caller\'s to dispose', () async {
      final src = _sourceShort();
      final full = await decodedRgbaToOrientedFullRes(src, exifOrientation: 6);
      expect(full.image!.debugDisposed, isFalse);
      full.image!.dispose();
      expect(full.image!.debugDisposed, isTrue);
    });
  });

  group('decoded_rgba_composite_gate_test.dart', () {
    // Deliverable 2 (docs/logs/2026-09-03/decode-jank-remediation-contract.md):
    // EXIF-orientation compositing no longer runs immediately on decode-result
    // arrival; it waits for a pacing slot. TC-898 .. TC-901.
    //
    // THE OWNERSHIP ARGUMENT, asserted here: the slot is awaited BEFORE any
    // `ui.Image` exists, so a slow or never-granted slot cannot leak a handle.

    TestWidgetsFlutterBinding.ensureInitialized();

    // TC-898 -- THE AC2 test. Delete the `await gate()` line in
    // `decodedRgbaToOrientedFullRes` and this case fails.
    //
    // NOTE: this deviates from the plan's literal `doesNotComplete` matcher --
    // that matcher registers a permanent `future.then(fail)` listener for the
    // rest of the test (see package:matcher `_DoesNotComplete.matches`), which
    // is incompatible with this same test later opening the gate and awaiting
    // the very future it was applied to (it would then always fail, by
    // matcher design, regardless of implementation correctness). A manual
    // "has it settled yet" flag captures the identical AC2 assertion --
    // "compositing must not run before a slot is granted" -- without that
    // conflict.
    test('a non-identity orientation waits for the gate before compositing',
        () async {
      final gate = ManualGate();
      var settled = false;
      final pending = decodedRgbaToOrientedFullRes(
        _sourceGate(),
        exifOrientation: 6, // 90 CW -- a real GPU pass
        gate: gate.call,
      ).then((value) {
        settled = true;
        return value;
      });

      await _pumpEventLoop();
      expect(
        settled,
        isFalse,
        reason: 'compositing must not run before a slot is granted',
      );
      expect(gate.requests, 1);

      gate.openAll();
      final result = await pending;
      expect(settled, isTrue);
      expect(result.width, 2);
      expect(result.height, 2);
      expect(
        result.image,
        isNotNull,
        reason: 'a GPU pass ran, so a handle came back',
      );
      result.image!.dispose();
    });

    // TC-899 -- AC7: the no-op orientation composites nothing, so it must not
    // even ask for a slot (asking would add latency for zero work).
    test('orientation 1 never asks the gate for a slot', () async {
      final gate = ManualGate();

      final fullRes = await decodedRgbaToOrientedFullRes(
        _sourceGate(),
        exifOrientation: 1,
        gate: gate.call,
      );
      expect(fullRes.image, isNull, reason: 'identity short-circuit, no GPU pass');

      final payload = await decodedRgbaToPixelPayload(
        _sourceGate(),
        exifOrientation: 1,
        longEdge: 0, // no downscale either
        gate: gate.call,
      );
      expect(payload.width, 2);

      final image = await decodedRgbaToImage(_sourceGate(), exifOrientation: 1);
      addTearDown(image.dispose);

      expect(gate.requests, 0, reason: 'AC7: orientation 1 skips compositing entirely');
    });

    // TC-900
    test('the gate is requested exactly once per oriented full-res decode',
        () async {
      final gate = ManualGate();
      final pending = decodedRgbaToImage(
        _sourceGate(),
        exifOrientation: 8, // 90 CCW
        gate: gate.call,
      );
      gate.openAll();
      final image = await pending;
      addTearDown(image.dispose);

      expect(gate.requests, 1, reason: 'one compositing pass buys one slot');
    });

    // TC-901 -- the pixel-payload path also uploads and composites, so its GPU
    // pass is paced too (a 200px downscale of a 50MB frame is not free).
    test('a pixel-payload downscale waits for the gate', () async {
      final gate = ManualGate();
      var settled = false;
      final pending = decodedRgbaToPixelPayload(
        _sourceGate(),
        exifOrientation: 1,
        longEdge: 1, // forces a real downscale pass past the short-circuit
        gate: gate.call,
      ).then((value) {
        settled = true;
        return value;
      });

      await _pumpEventLoop();
      expect(settled, isFalse);
      expect(gate.requests, 1);

      gate.openAll();
      final payload = await pending;
      expect(payload.width, 1);
      expect(payload.height, 1);
    });
  });

  group('decoded_rgba_image_provider_test.dart', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    group('decodedRgbaToImage orientation (AC B3)', () {
      // Plain test(), NOT testWidgets(): a testWidgets body runs inside a
      // FakeAsync zone where awaiting a real engine future (decodeImageFromPixels,
      // Picture.toImage) hangs until timeout.
      for (final orientation in _expected.keys) {
        test('orientation $orientation maps every pixel correctly', () async {
          final image = await decodedRgbaToImage(
            _sourceProvider(),
            exifOrientation: orientation,
          );
          addTearDown(image.dispose);

          final expected = _expected[orientation]!;
          expect(image.width, expected.first.length);
          expect(image.height, expected.length);
          expect(await _markerGrid(image), expected);
        });
      }

      test('an unrecognised orientation degrades to no transform', () async {
        final image = await decodedRgbaToImage(_sourceProvider(), exifOrientation: 99);
        addTearDown(image.dispose);
        expect(await _markerGrid(image), _expected[1]);
      });

      test('a buffer that disagrees with the dimensions is rejected', () async {
        expect(
          () => decodedRgbaToImage(
            DecodedRgba(rgba: Uint8List(4), width: 2, height: 3),
            exifOrientation: 1,
          ),
          throwsArgumentError,
        );
      });
    });

    group('applyExifOrientation caller-owns contract', () {
      test('returns src ITSELF for orientation 1, with no copy', () async {
        final src = await decodedRgbaToImage(_sourceProvider(), exifOrientation: 1);
        addTearDown(src.dispose);
        expect(identical(await applyExifOrientation(src, 1), src), isTrue);
        // Unrecognised values degrade to the identity, same object.
        expect(identical(await applyExifOrientation(src, 42), src), isTrue);
      });

      test(
        'never disposes src, for either the identity or a real transform',
        () async {
          final src = await decodedRgbaToImage(_sourceProvider(), exifOrientation: 1);
          addTearDown(src.dispose);

          final identity = await applyExifOrientation(src, 1);
          expect(src.debugDisposed, isFalse);
          expect(identical(identity, src), isTrue);

          final rotated = await applyExifOrientation(src, 6);
          addTearDown(rotated.dispose);
          expect(
            src.debugDisposed,
            isFalse,
            reason: 'the caller owns src; this function must never dispose it',
          );
          expect(rotated.width, 3);
          expect(rotated.height, 2);
        },
      );
    });

    // PhotoSource step 3: orientation and the window downscale in ONE pass.
    // Composition is the whole risk here -- scaling before rotating, or
    // mirroring about the scaled axis instead of the source axis, both produce
    // an image of exactly the RIGHT SHAPE with the wrong pixels, so only a
    // per-pixel check over all eight cases discriminates.
    group('decodedRgbaToPixelPayload (M3 step 3)', () {
      // Same 2x3 marker layout as _sourceProvider(), but each marker inflated to a
      // uniform 2x2 block. A 0.5x downscale therefore collapses each block back
      // to exactly one pixel of its own marker: the expected grids are the
      // frozen _expected table, unchanged.
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
            bytes[i + 3] = 255; // opaque: premultiplication is a no-op
          }
        }
        return DecodedRgba(rgba: bytes, width: 4, height: 6);
      }

      List<List<int>> gridOf(PixelPayload payload) => List.generate(
        payload.height,
        (y) => List.generate(
          payload.width,
          (x) => payload.rgba[(y * payload.width + x) * 4],
        ),
      );

      for (final orientation in _expected.keys) {
        test(
          'TC-069 orientation $orientation survives the window downscale',
          () async {
            // Oriented long edge is 6 for every case (4x6 <-> 6x4), so longEdge 3
            // is a clean 0.5x for all eight.
            final payload = await decodedRgbaToPixelPayload(
              blockySource(),
              exifOrientation: orientation,
              longEdge: 3,
            );
            final expected = _expected[orientation]!;
            expect(payload.width, expected.first.length);
            expect(payload.height, expected.length);
            expect(
              gridOf(payload),
              expected,
              reason:
                  'downscaling and orienting in one pass must land the same '
                  'pixels as orienting alone; a wrong composition keeps the shape '
                  'and moves the content',
            );
            expect(payload.byteCost, payload.width * payload.height * 4);
          },
        );
      }

      test(
        'TC-070 a frame already smaller than the window is NOT upscaled',
        () async {
          final payload = await decodedRgbaToPixelPayload(
            blockySource(),
            exifOrientation: 1,
            longEdge: 4000,
          );
          expect(payload.width, 4);
          expect(payload.height, 6);
          expect(gridOf(payload)[0], [a, a, b, b]);
        },
      );

      // The reason step 3 exists: what is RETAINED must be the window-sized
      // buffer, not the full-resolution frame the decoder handed over.
      test('TC-071 the retained buffer is the DOWNSCALED size, not the decoded '
          'size', () async {
        final decoded = blockySource();
        final payload = await decodedRgbaToPixelPayload(
          decoded,
          exifOrientation: 1,
          longEdge: 3,
        );
        expect(
          payload.byteCost,
          lessThan(decoded.rgba.lengthInBytes),
          reason:
              'retaining the full-resolution frame is what M3 exists to '
              'stop; at real sizes that is 50MB per item',
        );
        expect(payload.byteCost, 2 * 3 * 4);
      });
    });

    test('TC-322: a TIFF with Orientation 6 renders 90 degrees clockwise, '
        'swapping width and height exactly once', () async {
      // A real 2x3 TIFF whose six pixels carry six distinct R-channel markers.
      // Shape alone cannot separate 90CW from 90CCW (both give 3x2), so the
      // marker grid is what makes this test discriminating.
      const rows = <List<int>>[
        [a, b],
        [c, d],
        [e, f],
      ];
      final source = img.Image(width: 2, height: 3);
      for (var y = 0; y < 3; y++) {
        for (var x = 0; x < 2; x++) {
          source.setPixelRgb(x, y, rows[y][x], 0, 0);
        }
      }
      final tmp = Directory.systemTemp.createTempSync('halcyon_tiff_orient');
      addTempDirTeardown(tmp);
      final path = '${tmp.path}${Platform.pathSeparator}orient6.tif';
      File(path).writeAsBytesSync(img.encodeTiff(source));

      // The real TIFF arm: package:image does NOT bake orientation, so applying
      // it downstream is required, not belt-and-braces.
      final decoded = await decodeTiffFull(path);
      expect(decoded.width, 2);
      expect(decoded.height, 3);

      final payload = await decodedRgbaToPixelPayload(
        decoded,
        exifOrientation: 6,
        longEdge: 2800,
      );
      expect(payload.width, 3, reason: 'orientation 6 swaps the axes');
      expect(payload.height, 2);
      expect(payload.rgba.length, 3 * 2 * 4);

      // Orientation 6 = rotate 90 clockwise:
      //   A B          E C A
      //   C D    ->    F D B
      //   E F
      final grid = <List<int>>[];
      for (var y = 0; y < 2; y++) {
        final row = <int>[];
        for (var x = 0; x < 3; x++) {
          row.add(payload.rgba[(y * 3 + x) * 4]);
        }
        grid.add(row);
      }
      expect(grid, [
        [e, c, a],
        [f, d, b],
      ]);
    });
  });

  group('decoded_rgba_image_provider_orientation_test.dart', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    group('TC-1002: OLD vs NEW shape, byte-equal at scale 1.0, all 8 orientations', () {
      for (final orientation in _expectedO.keys) {
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
          expect(gridOfO(newPayload), _expectedO[orientation]);
        });
      }
    });

    group('TC-1003: downscale arm (dimensions + corner placement, not byte-exactness)', () {
      // Same 2x3 marker layout, each marker inflated to a uniform 2x2 block so
      // a 0.5x downscale collapses each block back to one pixel of its own
      // marker -- same recipe as decoded_rgba_image_provider_test.dart's
      // blockySource(), reused here rather than re-derived so a formula bug in
      // one file cannot rubber-stamp the same bug in the other.
      DecodedRgba blockySource() {
        const rows = <List<int>>[
          [aO, bO],
          [cO, dO],
          [eO, fO],
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

      for (final orientation in _expectedO.keys) {
        test('orientation $orientation downscaled to longEdge 3', () async {
          // Oriented long edge is 6 for every case (4x6 <-> 6x4), so longEdge 3
          // is a clean 0.5x for all eight -- same convention as the existing
          // decodedRgbaToPixelPayload TC-069 suite.
          final payload = await newShapePixels(
            blockySource(),
            exifOrientation: orientation,
            longEdge: 3,
          );
          final expected = _expectedO[orientation]!;
          expect(payload.width, expected.first.length);
          expect(payload.height, expected.length);
          // Corner-colour placement, not byte-exactness (spec §1.6 / plan T2
          // step 2): resampling legitimately differs in rounding between the
          // old single-pass rotate+scale and the new two-pass (rotate once,
          // then a SEPARATE scaled draw off the retained oriented image) --
          // this fixture's blocks are uniform so the corners survive either
          // rounding path unambiguously.
          final grid = gridOfO(payload);
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
  });

  group('full_decoder_dispatch_test.dart', () {
    late Directory tmp;

    setUpAll(() {
      tmp = Directory.systemTemp.createTempSync('halcyon_dispatch');
    });
    tearDownAll(() => deleteTempDir(tmp));

    Future<String> write(String name, Uint8List bytes) async {
      final file = File('${tmp.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    }

    /// A real, decodable 4x2 TIFF with a distinguishable pixel pattern.
    Uint8List realTiff({int width = 4, int height = 2}) {
      final image = img.Image(width: width, height: height);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          image.setPixelRgb(x, y, (x * 30) & 0xFF, (y * 60) & 0xFF, 7);
        }
      }
      return img.encodeTiff(image);
    }

    group('dispatchFullDecode', () {
      test('TC-309: routes .tif and .tiff to the TIFF arm', () async {
        final calls = <String>[];
        Future<DecodedRgba> tiffArm(String path) async {
          calls.add(path);
          return _fakeDecoded();
        }

        Future<DecodedRgba> rawArm(String path) async =>
            fail('the RAW arm must not be called for a TIFF');

        for (final name in ['a.tif', 'b.TIFF']) {
          final decoded = await dispatchFullDecode(
            '${tmp.path}${Platform.pathSeparator}$name',
            rawArm: rawArm,
            tiffArm: tiffArm,
          );
          expect(decoded.rgba[0], 0xA5);
        }
        expect(calls, hasLength(2));
      });

      test('TC-309: routes .dng and .arw to the engine arm', () async {
        final calls = <String>[];
        Future<DecodedRgba> rawArm(String path) async {
          calls.add(path);
          return _fakeDecoded();
        }

        Future<DecodedRgba> tiffArm(String path) async =>
            fail('the TIFF arm must not be called for a RAW container');

        for (final name in ['a.dng', 'b.arw']) {
          await dispatchFullDecode(
            '${tmp.path}${Platform.pathSeparator}$name',
            rawArm: rawArm,
            tiffArm: tiffArm,
          );
        }
        expect(calls, hasLength(2));
      });

      test('TC-309: throws UnsupportedError for an unroutable extension',
          () async {
        Future<DecodedRgba> never(String path) async => fail('must not run');
        for (final name in ['a.xyz', 'b.jpg', 'c.webp', 'd.cr2']) {
          await expectLater(
            dispatchFullDecode(
              '${tmp.path}${Platform.pathSeparator}$name',
              rawArm: never,
              tiffArm: never,
            ),
            throwsUnsupportedError,
            reason: '$name has no full-decode route',
          );
        }
      });
    });

    group('TIFF arm', () {
      test('decodes a real TIFF to a self-consistent RGBA buffer', () async {
        final path = await write('good.tif', realTiff());
        final decoded = await decodeTiffFull(path);
        expect(decoded.width, 4);
        expect(decoded.height, 2);
        expect(decoded.rgba.length, 4 * 2 * 4);
      });

      test('throws on a TIFF package:image cannot decode', () async {
        // buildSyntheticTiffHeader carries no pixel data. The plan assumed
        // `img.decodeTiff` returns null on this input (-> StateError), but
        // package:image ^4.9.2 instead THROWS a TypeError from `_decodeTile`
        // (no StripOffsets). The plan already treats a decodeTiff throw as an
        // unchanged rethrow / permanent miss, so this widens only the assertion
        // to match on-disk reality: an undecodable TIFF makes the full arm
        // throw (StateError from the null path OR the library's own Error).
        final path = await write(
          'corrupt.tif',
          buildSyntheticTiffHeader(width: 800, height: 600),
        );
        await expectLater(decodeTiffFull(path), throwsA(isA<Error>()));
      });

      test('TC-308: the TIFF arm refuses an over-budget extent BEFORE any '
          'decode is attempted', () async {
        var decodeAttempts = 0;
        Future<DecodedRgba> spy(Uint8List bytes, {int? maxDim}) async {
          decodeAttempts++;
          return _fakeDecoded();
        }

        final path = await write(
          'huge_sidebar.tif',
          buildSyntheticTiffHeader(width: 30000, height: 30000),
        );
        await expectLater(
          decodeTiffFull(path, decodeBytes: spy),
          throwsA(
            isA<ImageTooLargeException>().having(
              (e) => e.message,
              'message',
              contains('IMAGE_TOO_LARGE'),
            ),
          ),
        );
        expect(
          decodeAttempts,
          0,
          reason: 'the budget refusal must precede the decode, not follow it',
        );
      });

      test('TC-308: an in-budget TIFF still reaches the decoder', () async {
        var decodeAttempts = 0;
        Future<DecodedRgba> spy(Uint8List bytes, {int? maxDim}) async {
          decodeAttempts++;
          return _fakeDecoded();
        }

        final path = await write('small_sidebar.tif', realTiff());
        await decodeTiffFull(path, decodeBytes: spy);
        expect(decodeAttempts, 1);
      });
    });

    group('phase-2 HEIC arm', () {
      test('TC-309: routes .heic/.heif to the HEIF arm, never to TIFF or RAW',
          () async {
        final calls = <String>[];
        Future<DecodedRgba> heifArm(String path) async {
          calls.add(path);
          return _fakeDecoded();
        }

        Future<DecodedRgba> never(String path) async =>
            fail('only the HEIF arm may run for a HEIC container');

        for (final name in ['a.heic', 'b.HEIF']) {
          final decoded = await dispatchFullDecode(
            '${tmp.path}${Platform.pathSeparator}$name',
            rawArm: never,
            tiffArm: never,
            heifArm: heifArm,
          );
          expect(decoded.rgba[0], 0xA5);
        }
        expect(calls, hasLength(2));
      });

      test('TC-327: an unavailable HEIF library becomes a decoder throw, not a '
          'crash and not the D3 no-decoder state', () async {
        // What the ceyx service does on a build with -DDNG_ENABLE_HEIF=OFF.
        Future<DecodedRgba> unavailable(String path) async =>
            throw HeifUnavailableException(path);

        await expectLater(
          dispatchFullDecode(
            '${tmp.path}${Platform.pathSeparator}gone.heic',
            heifArm: unavailable,
          ),
          throwsA(isA<HeifUnavailableException>()),
        );
      });

      test('TC-327: PhotoSource turns that throw into the uniform permanent '
          'miss, with failureCode null', () async {
        final source = PhotoSource(
          loader: (path, {required purpose, int? targetLongEdge}) async =>
              const NativeImageNeedsRawDecode(exifOrientation: 1),
          dngDecoder: (path) async => throw HeifUnavailableException(path),
        );
        final outcome = await source.load('/tmp/gone.heic', longEdge: 2800);
        expect(outcome.payload, isNull);
        expect(outcome.deferred, isFalse);
        expect(
          outcome.failureCode,
          isNull,
          reason: 'NO_NATIVE_DECODER (D3) stays reserved for dngDecoder == null; '
              'a HEIC on a HEIF-less build is an ordinary permanent miss, and '
              'the app must not report "decoding unavailable" app-wide',
        );
        expect(outcome.observedCost, SourceCost.expensive);
      });

      test('TC-328: a length/geometry mismatch is rejected before it can reach '
          'decodeImageFromPixels', () async {
        // The adapter's own check. A buffer that disagrees with its declared
        // geometry would otherwise blow _imageFromPixels' assert deep inside the
        // provider, where the message names neither the file nor the decoder.
        await expectLater(
          heifImageToDecodedRgba(
            rgba: Uint8List(4 * 2 * 4 - 1),
            width: 4,
            height: 2,
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('31'), contains('32')),
            ),
          ),
        );
      });

      test('TC-328: a consistent buffer passes through unchanged', () async {
        final rgba = Uint8List(4 * 2 * 4);
        rgba[0] = 0xA5;
        final decoded =
            await heifImageToDecodedRgba(rgba: rgba, width: 4, height: 2);
        expect(decoded.width, 4);
        expect(decoded.height, 2);
        expect(decoded.rgba[0], 0xA5);
      });
    });

    group('codec expansion: AVIF and JXL routing', () {
      late List<String> firedArms;

      Future<DecodedRgba> spyArm(String name) async {
        firedArms.add(name);
        return DecodedRgba(rgba: Uint8List(4), width: 1, height: 1);
      }

      setUp(() => firedArms = []);

      test('.avif routes to the HEIF arm, not a new one', () async {
        // AVIF is AV1 in the SAME ISO-BMFF container libheif already parses. A
        // separate AVIF arm would be a second decode path for one format.
        await dispatchFullDecode(
          'tmp/x.avif',
          heifArm: (p) => spyArm('heif'),
          tiffArm: (p) => spyArm('tiff'),
          rawArm: (p) => spyArm('raw'),
          jxlArm: (p) => spyArm('jxl'),
        );
        expect(firedArms, ['heif']);
      });

      test('.jxl routes to the JXL arm', () async {
        await dispatchFullDecode(
          'tmp/x.jxl',
          heifArm: (p) => spyArm('heif'),
          tiffArm: (p) => spyArm('tiff'),
          rawArm: (p) => spyArm('raw'),
          jxlArm: (p) => spyArm('jxl'),
        );
        expect(firedArms, ['jxl']);
      });

      test('.webp is NOT routed to any FFI arm', () async {
        // Ratified ruling: WebP import stays on the Flutter engine path. Skia
        // already decodes it; routing every WebP through FFI is a regression in
        // the common case with no user benefit.
        expect(SupportedPhotoFormats.isEncodedBitstreamPath('tmp/x.webp'), isTrue);
        expect(SupportedPhotoFormats.isBitmapDecodePath('tmp/x.webp'), isFalse);
      });

      test('an unknown extension still throws UnsupportedError', () async {
        expect(
          () => dispatchFullDecode('tmp/x.xyz',
              heifArm: (p) => spyArm('heif'),
              tiffArm: (p) => spyArm('tiff'),
              rawArm: (p) => spyArm('raw'),
              jxlArm: (p) => spyArm('jxl')),
          throwsA(isA<UnsupportedError>()),
        );
      });

      test('sibling preference order matches the Q6 ruling exactly', () {
        expect(SupportedPhotoFormats.preferredLoadExtensions,
            ['.jpg', '.jpeg', '.heic', '.heif', '.webp', '.avif', '.jxl', '.png']);
      });
    });
  });

  group('exif_orientation_test.dart', () {
    test('TC-213 exifTransformFor maps all eight EXIF values', () {
      expect(exifTransformFor(1), (quarterTurnsCw: 0, mirrored: false));
      expect(exifTransformFor(2), (quarterTurnsCw: 0, mirrored: true));
      expect(exifTransformFor(3), (quarterTurnsCw: 2, mirrored: false));
      expect(exifTransformFor(4), (quarterTurnsCw: 2, mirrored: true));
      expect(exifTransformFor(5), (quarterTurnsCw: 1, mirrored: true));
      expect(exifTransformFor(6), (quarterTurnsCw: 1, mirrored: false));
      expect(exifTransformFor(7), (quarterTurnsCw: 3, mirrored: true));
      expect(exifTransformFor(8), (quarterTurnsCw: 3, mirrored: false));
    });

    test('TC-213b an unrecognised orientation is identity, not a guess', () {
      expect(exifTransformFor(0), (quarterTurnsCw: 0, mirrored: false));
      expect(exifTransformFor(9), (quarterTurnsCw: 0, mirrored: false));
      expect(exifTransformFor(-1), (quarterTurnsCw: 0, mirrored: false));
    });
  });
}
