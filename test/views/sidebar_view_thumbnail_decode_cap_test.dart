// M1 (image-pipeline redesign, docs/logs/2026-08-23/image-pipeline-redesign-handover.md
// §6 M1): the sidebar must declare its own decode-time cap — 32 *
// devicePixelRatio on the longest edge, without distorting aspect ratio —
// instead of relying on Image.memory's width/height, which are LAYOUT
// constraints only. Flutter still decodes the source bytes at full
// resolution unless a ResizeImage (or cacheWidth/cacheHeight) caps the
// *decode*, not just the paint box.
//
// This test is deliberately black-box: it pumps the real SidebarView list
// thumbnail path, extracts the exact ImageProvider it built, and resolves
// THAT provider (not a hand-rolled one) so a fix that only changes the
// widget's paint box (not its decode) still fails here.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/temp_dirs.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/views/sidebar_view.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';

/// Builds a real, decodable PNG whose pixel dimensions are NON-square and
/// larger than any plausible sidebar cap. A square fixture would make the
/// aspect-ratio assertion non-discriminating by construction (a squashed
/// square still measures as square) — see the M1 task brief's method
/// requirement.
Future<Uint8List> _buildOversizedNonSquareFixturePng() async {
  const width = 400;
  const height = 200; // 2:1 aspect, both edges far above any 32*dpr cap.
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

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // Same drain pattern as sidebar_view_test.dart: a pre-existing, unrelated
  // framework debug assertion fires on every painted selected row.
  void drainListTileWarning(WidgetTester tester) {
    for (var exception = tester.takeException(); exception != null; ) {
      if (!exception.toString().contains(
        'ListTile background color or ink splashes may be invisible',
      )) {
        throw exception;
      }
      exception = tester.takeException();
    }
  }

  testWidgets(
    'AC2/AC3: sidebar thumbnail decode is capped at 32*devicePixelRatio on '
    'the longest edge and preserves source aspect ratio within 1%',
    (tester) async {
      const dpr = 3.0;
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = const Size(1200, 2400);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      late Uint8List fixtureBytes;
      late AppState state;
      await tester.runAsync(() async {
        fixtureBytes = await _buildOversizedNonSquareFixturePng();

        final dir = await Directory.systemTemp.createTemp(
          'halcyon_sidebar_m1_',
        );
        addTempDirTeardown(dir);
        await File(p.join(dir.path, 'IMG_0001.jpg')).writeAsBytes([1, 2, 3]);

        state = AppState(
          imageLoader: (path, {required purpose}) async {
            return NativeImageBytes(Uint8List.fromList(fixtureBytes));
          },
        );
        await state.loadFolder(dir);
      });

      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const MaterialApp(
            home: Scaffold(body: SizedBox(width: 320, child: SidebarView())),
          ),
        ),
      );
      await tester.pump();
      drainListTileWarning(tester);
      // AppState.loadFolder already triggers the first preloadThumbnails
      // call (app_state.dart:282), which starts a REAL Timer (100ms
      // _thumbnailDebounceTimer, image_preload_controller.dart:791) inside
      // the real async zone entered above via tester.runAsync — advancing
      // FakeAsync time with tester.pump(duration) does not fire it. Give it
      // real wall-clock time to fire instead, matching the pattern in
      // sidebar_view_test.dart's export test.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
      drainListTileWarning(tester);

      final imageWidget = tester.widget<Image>(
        find.descendant(
          of: find.byType(SidebarView),
          matching: find.byType(Image),
        ),
      );
      final provider = imageWidget.image;

      final context = tester.element(find.byType(SidebarView));
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

      final longestEdge = decoded.width > decoded.height
          ? decoded.width
          : decoded.height;
      final cap = (32 * dpr).round();

      // AC2: kills "no decode cap" (an uncapped decode reproduces the
      // fixture's full 400px edge, far above cap) AND kills "cap term
      // ungated" (e.g. hardcoding `cap = 32`, dropping the `* dpr` factor
      // entirely). Both mutations still satisfy a mere `<= cap + 1` upper
      // bound at dpr 3.0 (32 <= 97), so the assertion must pin the EXACT
      // fitted size instead of only bounding it from above: for a 400x200
      // source fit within a `cap x cap` box preserving aspect ratio, the
      // longest edge (width, since 400 > 200) must equal `cap` exactly
      // (mod +/-1 for integer rounding in the fit computation).
      expect(
        longestEdge,
        inInclusiveRange(cap - 1, cap + 1),
        reason:
            'decoded longest edge must equal 32*devicePixelRatio ($cap) '
            'exactly (the fitted size for this 400x200 fixture), not merely '
            'be bounded by it; got ${decoded.width}x${decoded.height}. A '
            'mismatch means either the decode is uncapped or the '
            '"* devicePixelRatio" term of the cap computation was dropped.',
      );

      // AC3: kills "exact-policy distortion" — width+height passed to
      // ResizeImage with policy: exact (or naive cacheWidth+cacheHeight)
      // would pass the edge-length check above while silently squashing
      // every non-square thumbnail into a square.
      const sourceAspect = 400 / 200;
      final decodedAspect = decoded.width / decoded.height;
      expect(
        decodedAspect,
        closeTo(sourceAspect, sourceAspect * 0.01),
        reason:
            'decoded aspect ratio ($decodedAspect) must stay within 1% of '
            'the source aspect ratio ($sourceAspect); a mismatch means the '
            'decode cap distorted the image instead of fitting within it.',
      );

      decoded.dispose();
    },
  );
}
