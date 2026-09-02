// TC-494, TC-495 (final — the +7 gallery registry shift, user-ruled).
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/services/image_pipeline/raw_pixels_image.dart';
import 'package:halcyon_flutter/views/layout/common/photo_thumbnail.dart';

/// Builds a real, decodable PNG whose pixel dimensions are NON-square and far
/// larger than any plausible cap. A square fixture would make the aspect-ratio
/// and fitted-longest-edge assertions non-discriminating by construction (a
/// squashed square still measures as square) — same fixture property as the
/// retired `sidebar_view_thumbnail_decode_cap_test.dart` (M1).
Future<Uint8List> _buildOversizedNonSquareFixturePng() async {
  const width = 400;
  const height = 200; // 2:1 aspect, both edges far above any 74*dpr cap.
  final pixels = Uint8List(width * height * 4);
  for (var i = 0; i < pixels.length; i += 4) {
    pixels[i] = 210; // R
    pixels[i + 1] = 90; // G
    pixels[i + 2] = 40; // B
    pixels[i + 3] = 255; // A
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
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

/// Builds a 32x16 (2:1) PixelPayload in window-resolution pixel space.
PixelPayload _fixturePixelPayload() {
  const width = 32;
  const height = 16;
  final rgba = Uint8List(width * height * 4);
  for (var i = 0; i < rgba.length; i += 4) {
    rgba[i] = 20; // R
    rgba[i + 1] = 120; // G
    rgba[i + 2] = 70; // B
    rgba[i + 3] = 255; // A
  }
  return PixelPayload(rgba: rgba, width: width, height: height);
}

/// The widget PhotoThumbnail builds for a non-null payload is an `Image`;
/// that is what carries the provider. This is the same extraction path a
/// consumer (theme) uses, so a fix that only changes the widget's paint box
/// (not its decode) still fails here.
Image _imageWidget(WidgetTester tester) =>
    tester.widget<Image>(find.descendant(
      of: find.byType(PhotoThumbnail),
      matching: find.byType(Image),
    ));

Future<ui.Image> _resolve(WidgetTester tester, ImageProvider provider) async {
  final context = tester.element(find.byType(PhotoThumbnail));
  final config = createLocalImageConfiguration(context);
  late ui.Image decoded;
  await tester.runAsync(() async {
    final completer = Completer<ui.Image>();
    final stream = provider.resolve(config);
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, synchronousCall) {
        stream.removeListener(listener);
        completer.complete(info.image);
      },
      onError: (error, stackTrace) {
        stream.removeListener(listener);
        completer.completeError(error, stackTrace);
      },
    );
    stream.addListener(listener);
    decoded = await completer.future;
  });
  return decoded;
}

void main() {
  testWidgets(
    'TC-494 at dpr 3.0 with width 74 height 49 the resolved image longest '
    'decoded edge equals exactly (74*3).round() — equality, not <=',
    (tester) async {
      const dpr = 3.0;
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = const Size(1200, 2400);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      late Uint8List fixtureBytes;
      await tester.runAsync(() async {
        fixtureBytes = await _buildOversizedNonSquareFixturePng();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: PhotoThumbnail(
            payload: EncodedPayload(fixtureBytes),
            width: 74,
            height: 49,
          ),
        ),
      );
      await tester.pump();

      final image = _imageWidget(tester);
      expect(image.width, 74);
      expect(image.height, 49);
      expect(image.fit, BoxFit.cover);

      final provider = image.image;
      final decoded = await _resolve(tester, provider);

      final longestEdge =
          decoded.width > decoded.height ? decoded.width : decoded.height;
      final cap = (74 * dpr).round();

      // Equality, not `<=`: for the 400x200 fixture fit within a `cap x cap`
      // box preserving aspect ratio, the longest edge (width, since 400 > 200)
      // must equal `cap` EXACTLY — a merely-bounded assertion would also pass
      // under two mutations the equality kills: an uncapped decode (full 400px
      // edge, way above cap) and a "cap term ungated" bug like hardcoding
      // `cap = 74`, dropping the `* dpr` factor entirely (74 still satisfies a
      // `<= cap + 1` bound at dpr 3.0 while being the wrong size). Same
      // discriminator as the retired sidebar decode-cap test (see the reason at
      // `sidebar_view_thumbnail_decode_cap_test.dart:164-175`, carried into the
      // +7 renumbered TC-494).
      expect(
        longestEdge,
        equals(cap),
        reason:
            'decoded longest edge must equal 74*devicePixelRatio ($cap) '
            'exactly (the fitted size for this 2:1 fixture), not merely be '
            'bounded by it; got ${decoded.width}x${decoded.height}. A '
            'mismatch means either the decode is uncapped or the '
            '"* devicePixelRatio" term of the cap computation was dropped.',
      );

      // Ported from the retired sidebar_view_thumbnail_decode_cap_test.dart
      // (:188-193): the longest-edge equality above alone does not catch a
      // decode that squashes the 2:1 fixture into a cap x cap square (its
      // longest edge would still equal `cap`). Assert the decoded aspect
      // ratio is preserved within 1% of the source's.
      final sourceAspect = 400 / 200;
      final decodedAspect = decoded.width / decoded.height;
      expect(
        (decodedAspect - sourceAspect).abs() / sourceAspect,
        lessThan(0.01),
        reason: 'decoded aspect must stay within 1% of source',
      );

      decoded.dispose();
    },
  );

  testWidgets(
    'TC-495 a PixelPayload resolves to a bare RawPixelsImage, not a '
    'ResizeImage',
    (tester) async {
      const dpr = 1.0;
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = const Size(1200, 2400);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final payload = _fixturePixelPayload();

      await tester.pumpWidget(
        MaterialApp(
          home: PhotoThumbnail(payload: payload, width: 74, height: 49),
        ),
      );
      await tester.pump();

      final image = _imageWidget(tester);
      final provider = image.image;
      // Bare RawPixelsImage: NOT wrapped in ResizeImage (the wrapper would cap
      // nothing — RawPixelsImage ignores the decode callback — while reading in
      // review as protection that exists). Do not assert on the painted result
      // even though decoding works: resolution of the provider is not the
      // discriminated property, its family is.
      expect(provider, isA<RawPixelsImage>());
      expect(provider, isNot(isA<ResizeImage>()));
      final asRaw = provider as RawPixelsImage;
      expect(identical(asRaw.payload.rgba, payload.rgba), isTrue,
          reason: 'RawPixelsImage keys on the retained buffer identity');
    },
  );
}