import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ceyx/ceyx.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/decoded_rgba_image_provider.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';

/// mem8 v3 T16 — display-path mechanical acceptance (SR-12), checks 1, 2, 4, 5.
///
/// RULING RECORDED INLINE — do not re-litigate. *1:1 view renders from yuv420
/// and the chroma loss is **ACCEPTED BY USER RULING (2026-09-19, R-A)**. No
/// RGBA escape hatch is provided (R-C).* Acceptance here is **mechanical
/// correctness only**. A reviewer or future session that reopens "does 1:1 look
/// worse" is re-litigating a settled ruling and must **stop and ask the user**.
///
/// ARM LABEL (T16.2). Every case in this file fakes the decoder: the frames are
/// synthetic planes built here, so NO GPU BACKEND AND NEITHER KERNEL ARM RUNS.
/// These checks are platform-agnostic BY CONSTRUCTION and must not be read as
/// per-platform coverage. The arm-labelled pixel evidence is check 3's
/// (`yuv420_format_loss_test.dart`) and the Android tier-1 run.
///
/// COLOUR PROVENANCE (T16.1.6), stated ONCE for all of T16 and never restated:
/// BT.601, full-range 0-255, centered (2x2 box-average) chroma siting — plan
/// `docs/logs/2026-09-19/mem8-v3-plan.md` §3:135, :407-408, coefficients :415.
/// The single converter of record (SR-11) is native `ceyx_yuv420_to_rgba8`
/// (`../ceyx/native/include/raw_ffi_api.h`), oracle header
/// `../ceyx/native/include/ceyx_yuv420_oracle.h:40`. **No second oracle exists
/// in this file**: nothing here open-codes the colour maths, and the expected
/// RGB below is not computed — it is whatever the one converter returns, which
/// is why the assertions are about STRUCTURE (extent, orientation, opacity,
/// non-blankness) and not about specific colour values.
///
/// WHY THE REAL CONVERTER AND NOT T15a's SPY: the spy fills the destination
/// with 0xFF, which makes an alpha assertion (check 5) pass no matter what the
/// seam did. A vacuous green is the failure mode this campaign's ledger is
/// built around, so these cases run the native entry.
/// HOW TO RUN THESE, and why they do not run by default.
///
/// `flutter test` loads no native library (`<no native library loaded>`), so
/// the single converter of record is unreachable and every case here would
/// fail on resolution rather than on anything it asserts. The established
/// mechanism in this codebase is ceyx's own `DNG_NATIVE_BUILD_DIR` override —
/// see `../ceyx/plugin/test/encode_service_test.dart:177-180`, which skips the
/// same way for the same reason:
///
///   DNG_NATIVE_BUILD_DIR=/Users/jhangyu/project/ceyx/plugin/macos/Libraries \
///     flutter test test/services/image_pipeline/yuv420_display_path_test.dart
///
/// THE HAZARD THIS COMMENT EXISTS TO FLAG: a skipped run and a full run differ
/// only in the skip line. **A T16 acceptance claim must cite a run whose
/// counts show these cases PASSING, never a suite green that skipped them.**
/// The library was proved to export the converter by symbol inspection, never
/// by mtime: `tmp/verify/t16/nm-macos-dylib.txt` contains
/// `_ceyx_yuv420_to_rgba8` (`nm -gU`, RC captured separately).
final String? _nativeDir = Platform.environment['DNG_NATIVE_BUILD_DIR'];
final String? _skipReason = _nativeDir == null
    ? 'set DNG_NATIVE_BUILD_DIR to ceyx plugin/macos/Libraries: these cases '
        'run the REAL converter (T16 forbids a second oracle, and T15a\'s '
        '0xFF-filling spy makes the alpha check vacuous)'
    : null;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(debugResetUpconvertSeam);

  /// A synthetic yuv420 frame with a HORIZONTAL LUMA RAMP.
  ///
  /// The ramp matters twice: a uniform frame cannot distinguish a correct
  /// rotation from a transposed one (check 2), and it cannot distinguish real
  /// output from a zero-filled buffer (check 1's "no silent blank").
  /// Chroma is neutral (128) so the converted pixels stay grey — an assertion
  /// about hue would be a second oracle, which T16.1.6 forbids.
  DecodedRgba yuvRamp(int w, int h) {
    final bytes = Uint8List(
      ceyxOutputFormatByteCount(CeyxOutputFormat.yuv420, w, h),
    );
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        // 16..235 keeps the ramp inside the range where a full-range decode
        // cannot clamp, so a clamped byte is a real finding rather than noise.
        bytes[y * w + x] = 16 + ((219 * x) ~/ (w > 1 ? w - 1 : 1));
      }
    }
    // Chroma planes follow the luma plane; sized by the FROZEN contract entry,
    // never open-coded, because `ceil(w/2)` is what the odd cases turn on.
    bytes.fillRange(w * h, bytes.length, 128);
    return DecodedRgba(
      rgba: bytes,
      width: w,
      height: h,
      format: CeyxOutputFormat.yuv420,
    );
  }

  Future<Uint8List> pixelsOf(ui.Image image) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return data!.buffer.asUint8List();
  }

  /// "Not a silent blank": a zero-filled or single-valued frame fails.
  void expectNotBlank(Uint8List rgba, {required String reason}) {
    final distinct = <int>{};
    for (var p = 0; p < rgba.length; p += 4) {
      distinct.add(rgba[p]);
    }
    expect(
      distinct.length,
      greaterThan(1),
      reason: '$reason — the source carries a luma ramp, so a single-valued '
          'result means the display path emitted a blank, not the converted '
          'frame',
    );
  }

  group('T16 check 1: no crash / no silent blank on the yuv420 display path',
      () {
    // TC-1365
    test(
      'decodedRgbaToImage (the _upgradeFullRes seam, tier_two_scheduler.dart:848) '
      'materialises a yuv420 frame',
      () async {
        final image = await decodedRgbaToImage(
          yuvRamp(8, 6),
          exifOrientation: 1,
        );
        addTearDown(image.dispose);
        expect(image.width, 8);
        expect(image.height, 6);
        expectNotBlank(
          await pixelsOf(image),
          reason: 'decodedRgbaToImage returned a blank frame',
        );
      },
    );

    // TC-1366
    test(
      'decodedRgbaToPixelPayload with a DOWNSCALE (the sidebar-tile seam, '
      'thumbnail_derivation.dart:50) takes the GPU arm, not the short-circuit',
      () async {
        // longEdge BELOW the source long edge, so the identity short-circuit is
        // NOT taken and the upload/readback arm runs — the arm T15a's cases,
        // which all pass longEdge: 0, never exercise on a yuv420 source.
        final payload = await decodedRgbaToPixelPayload(
          yuvRamp(16, 12),
          exifOrientation: 1,
          longEdge: 8,
        );
        expect(payload.width, 8, reason: 'the downscale arm did not run');
        expect(payload.height, 6);
        expect(
          payload.rgba.length,
          ceyxOutputFormatByteCount(CeyxOutputFormat.rgba8, 8, 6),
          reason: 'a payload sized for the SOURCE format means unconverted '
              'planar yuv reached the sidebar',
        );
        expectNotBlank(
          payload.rgba,
          reason: 'the sidebar tile is blank',
        );
      },
    );
  }, skip: _skipReason);

  group('T16 check 2: extent and EXIF orientation applied exactly once', () {
    // TC-1367
    test('the produced ui.Image extent equals the decode extent', () async {
      final image = await decodedRgbaToImage(
        yuvRamp(10, 4),
        exifOrientation: 1,
      );
      addTearDown(image.dispose);
      expect(image.width, 10);
      expect(image.height, 4);
    });

    // TC-1368
    test('a quarter-turn EXIF orientation swaps the extent exactly once',
        () async {
      final image = await decodedRgbaToImage(
        yuvRamp(10, 4),
        exifOrientation: 6, // 90 CW
      );
      addTearDown(image.dispose);
      expect(image.width, 4, reason: 'orientation 6 did not rotate, or the '
          'rotation was applied twice (twice = back to 10x4)');
      expect(image.height, 10);
    });

    // TC-1369
    test(
      'an orientation the DECODER already applied is not applied a second time',
      () async {
        // The residual path: declared 6, already applied 6 -> identity. Before
        // `residualExifOrientation` existed this rotated a natively-oriented
        // frame a second time, which is precisely "exactly once" failing.
        final frame = yuvRamp(10, 4);
        final image = await decodedRgbaToImage(
          DecodedRgba(
            rgba: frame.rgba,
            width: frame.width,
            height: frame.height,
            format: CeyxOutputFormat.yuv420,
            appliedOrientation: 6,
          ),
          exifOrientation: 6,
        );
        addTearDown(image.dispose);
        expect(image.width, 10, reason: 'the frame was rotated a SECOND time');
        expect(image.height, 4);
      },
    );
  }, skip: _skipReason);

  group('T16 check 4: odd dimensions end-to-end', () {
    // TC-1370 (7x4, odd width), TC-1371 (4x7, odd height), TC-1372 (7x5,
    // both) -- one number per case. ceil(w/2) is load-bearing here: an odd
    // extent sized with (w/2)*(h/2) under-allocates and the converter reads
    // past the source.
    for (final extent in const <({int w, int h})>[
      (w: 7, h: 4), // odd WIDTH
      (w: 4, h: 7), // odd HEIGHT
      (w: 7, h: 5), // both, for the corner the two singles cannot reach
    ]) {
      test('${extent.w}x${extent.h} survives the full display path', () async {
        final image = await decodedRgbaToImage(
          yuvRamp(extent.w, extent.h),
          exifOrientation: 1,
        );
        addTearDown(image.dispose);
        expect(image.width, extent.w);
        expect(image.height, extent.h);
        final rgba = await pixelsOf(image);
        expect(
          rgba.length,
          ceyxOutputFormatByteCount(
            CeyxOutputFormat.rgba8,
            extent.w,
            extent.h,
          ),
        );
        expectNotBlank(rgba, reason: 'odd-dimension frame came back blank');
      });
    }
  }, skip: _skipReason);

  group('T16 check 5: the alpha/opacity invariant holds on converted output',
      () {
    // TC-1373. `_sampledOpaque` is an ASSERT, so it only bites in debug mode —
    // which is how `flutter test` runs. The short-circuit arms are the ones
    // that carry it (:418 and :546).
    test('both identity short-circuits return fully opaque converted bytes',
        () async {
      final payload = await decodedRgbaToPixelPayload(
        yuvRamp(8, 6),
        exifOrientation: 1,
        longEdge: 0,
      );
      for (var p = 0; p < payload.rgba.length; p += 4) {
        expect(payload.rgba[p + 3], 0xFF,
            reason: 'pixel ${p ~/ 4} of the converted payload is not opaque');
      }

      final full = await decodedRgbaToOrientedFullRes(
        yuvRamp(8, 6),
        exifOrientation: 1,
      );
      addTearDown(() => full.releaseNative?.call());
      for (var p = 0; p < full.rgba.length; p += 4) {
        expect(full.rgba[p + 3], 0xFF,
            reason: 'pixel ${p ~/ 4} of the converted full-res frame is not '
                'opaque');
      }
    });
  }, skip: _skipReason);
}
