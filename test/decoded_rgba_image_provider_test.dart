import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/decoded_rgba_image_provider.dart';
import 'package:halcyon_flutter/services/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/photo_payload.dart';

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
      test('TC-069 orientation $orientation survives the window downscale', () async {
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
          reason: 'downscaling and orienting in one pass must land the same '
              'pixels as orienting alone; a wrong composition keeps the shape '
              'and moves the content',
        );
        expect(payload.byteCost, payload.width * payload.height * 4);
      });
    }

    test('TC-070 a frame already smaller than the window is NOT upscaled', () async {
      final payload = await decodedRgbaToPixelPayload(
        blockySource(),
        exifOrientation: 1,
        longEdge: 4000,
      );
      expect(payload.width, 4);
      expect(payload.height, 6);
      expect(gridOf(payload)[0], [a, a, b, b]);
    });

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
        reason: 'retaining the full-resolution frame is what M3 exists to '
            'stop; at real sizes that is 50MB per item',
      );
      expect(payload.byteCost, 2 * 3 * 4);
    });
  });

  group('DecodedRgbaImageProvider (AC B2)', () {
    testWidgets('resolves a frame through Image(image:)', (tester) async {
      late ui.Image master;
      // runAsync: the decode is a real engine future (see the FakeAsync note
      // above).
      await tester.runAsync(() async {
        master = await decodedRgbaToImage(_source(), exifOrientation: 6);
      });
      addTearDown(master.dispose);

      final provider = DecodedRgbaImageProvider(master);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Image(image: provider, gaplessPlayback: true),
        ),
      );
      await tester.pump();

      // The criterion is that a frame ACTUALLY RESOLVED, not merely that the
      // widget built: resolve the same provider and require the
      // ImageStreamListener to fire with a non-null ImageInfo.
      ImageInfo? delivered;
      var listenerFired = false;
      final stream = provider.resolve(ImageConfiguration.empty);
      late ImageStreamListener listener;
      listener = ImageStreamListener((info, synchronousCall) {
        listenerFired = true;
        delivered = info;
        stream.removeListener(listener);
      });
      stream.addListener(listener);
      await tester.pump();

      expect(listenerFired, isTrue, reason: 'ImageStreamListener never fired');
      expect(delivered, isNotNull);
      expect(delivered!.image.width, 3);
      expect(delivered!.image.height, 2);
      delivered!.dispose();

      final rendered = tester.widget<RawImage>(find.byType(RawImage));
      expect(rendered.image, isNotNull, reason: 'no frame reached the tree');
      // Orientation 6 turns the 2x3 source into 3x2; asserting the rendered
      // size proves the oriented image (not the raw one) is what reached
      // the widget tree.
      expect(rendered.image!.width, 3);
      expect(rendered.image!.height, 2);
    });

    testWidgets('ImageCache eviction does not dispose the master image', (
      tester,
    ) async {
      late ui.Image master;
      await tester.runAsync(() async {
        master = await decodedRgbaToImage(_source(), exifOrientation: 1);
      });
      addTearDown(master.dispose);

      final provider = DecodedRgbaImageProvider(master);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Image(image: provider),
        ),
      );
      await tester.pump();
      expect(PaintingBinding.instance.imageCache.containsKey(provider), isTrue);

      // Tear the widget down and flush the cache: this is exactly what LRU
      // pressure does at ~50MB/image against the 500MB cap.
      await tester.pumpWidget(const SizedBox.shrink());
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      await tester.pump();

      expect(
        master.debugDisposed,
        isFalse,
        reason:
            'the cache disposed the master handle; the provider must hand out '
            'clones so only the clone dies with the cache entry',
      );
      // Still usable afterwards -- the real symptom of getting this wrong is
      // a "disposed image" crash on the NEXT resolve, not at eviction time.
      final second = DecodedRgbaImageProvider(master);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Image(image: second),
        ),
      );
      await tester.pump();
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    });

    test('key identity follows the ui.Image identity', () async {
      final one = await decodedRgbaToImage(_source(), exifOrientation: 1);
      final two = await decodedRgbaToImage(_source(), exifOrientation: 1);
      addTearDown(one.dispose);
      addTearDown(two.dispose);

      expect(
        DecodedRgbaImageProvider(one) == DecodedRgbaImageProvider(one),
        isTrue,
      );
      expect(
        DecodedRgbaImageProvider(one) == DecodedRgbaImageProvider(two),
        isFalse,
        reason: 'a re-decode must be a NEW cache key, not a silent alias',
      );
    });
  });
}
