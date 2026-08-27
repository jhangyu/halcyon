import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:halcyon_flutter/services/image_pipeline/decoded_rgba_image_provider.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/full_decoder_dispatch.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';

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

DecodedRgba _source() {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('decodedRgbaToImage orientation (AC B3)', () {
    // Plain test(), NOT testWidgets(): a testWidgets body runs inside a
    // FakeAsync zone where awaiting a real engine future (decodeImageFromPixels,
    // Picture.toImage) hangs until timeout.
    for (final orientation in _expected.keys) {
      test('orientation $orientation maps every pixel correctly', () async {
        final image = await decodedRgbaToImage(
          _source(),
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
      final image = await decodedRgbaToImage(_source(), exifOrientation: 99);
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
      final src = await decodedRgbaToImage(_source(), exifOrientation: 1);
      addTearDown(src.dispose);
      expect(identical(await applyExifOrientation(src, 1), src), isTrue);
      // Unrecognised values degrade to the identity, same object.
      expect(identical(await applyExifOrientation(src, 42), src), isTrue);
    });

    test(
      'never disposes src, for either the identity or a real transform',
      () async {
        final src = await decodedRgbaToImage(_source(), exifOrientation: 1);
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
    // Same 2x3 marker layout as _source(), but each marker inflated to a
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

  test('TC-311: a TIFF with Orientation 6 renders 90 degrees clockwise, '
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
    addTearDown(() => tmp.deleteSync(recursive: true));
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
}
