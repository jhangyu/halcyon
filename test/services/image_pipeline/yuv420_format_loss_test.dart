import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ceyx/ceyx.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/decoded_rgba_image_provider.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';

/// mem8 v3 T16 check 3 — the load-bearing INTEGRATION assertion (SR-12).
///
/// RULING RECORDED INLINE — do not re-litigate. *1:1 view renders from yuv420
/// and the chroma loss is **ACCEPTED BY USER RULING (2026-09-19, R-A)**. No
/// RGBA escape hatch is provided (R-C).* Acceptance here is **mechanical
/// correctness only**. A reviewer or future session that reopens "does 1:1 look
/// worse" is re-litigating a settled ruling and must **stop and ask the user**.
///
/// WHAT THIS MEASURES, and what it does NOT. T13 owns the converter's own
/// correctness at the source (C1-C4, converter vs oracle, `max_abs <= 3`). This
/// case owns the INTEGRATION: a real frame decoded as yuv420 and carried
/// through `materialiseRgba` against THE SAME FRAME decoded as rgba8. That
/// difference is the FORMAT's chroma loss, so the applicable bound is ceyx's
/// B4, ADOPTED BY CITATION and never re-derived here:
///   `mean_abs <= 2.0` AND `p99.9 <= 12`
///   — `../ceyx/native/tests/test_yuv420_to_rgba.cpp:639` (the comment naming
///     it the format's loss) and `:671` (the predicate itself).
/// Byte-identity across formats is NOT applicable and is not attempted.
/// Cross-BACKEND agreement is T12's Y7, not T16's.
///
/// VACUITY GUARD, pre-registered in `tmp/verify/t16/prereg.md` before any
/// number existed and accepted by the lead: **`mean_abs > 0` is REQUIRED**. A
/// zero means the two decodes did not actually differ in format — i.e. the test
/// measured one format twice and the bound passed without discriminating
/// anything. A result far INSIDE the bound is as suspicious as one outside.
///
/// ARM LABEL (T16.2) — DERIVED FROM THE LANDED DISPATCH, not from a summary.
/// `../ceyx/native/src/pipeline/raw_gpu_pipeline.cpp:542-543`:
///     use_fused_bayer_render = (src_w == out_w && src_h == out_h)
///                              && !fused_disabled_by_env;
/// The `output_format == rgba8` condition was REMOVED by ceyx `bda80348`, so
/// fusion is gated on SCALE ALONE and BOTH output formats fuse. This case
/// decodes UNSCALED (`maxDim: null`), so on the generic-RAW Bayer route it
/// takes **arm A, the fused kernel**, on whichever backend the host runs —
/// note the landed comment at `:517-519` states there is deliberately NO
/// backend test on that branch, so arm A is NOT macOS-only as the plan's
/// T16.2 table says. On this host the backend is Metal. The Vulkan side of the
/// same arm is covered by the tier-1 Android run cited in the T16 report.
///
/// COLOUR PROVENANCE is stated once in `yuv420_display_path_test.dart` and is
/// not restated here (T16.1.6). Nothing in this file open-codes colour maths:
/// both arms are produced by ceyx, so there is exactly one oracle.
/// HOW TO RUN THIS. `flutter test` loads no native library, and this case
/// needs a REAL decode, so it skips unless the ceyx override is set — the same
/// mechanism and the same reason as
/// `../ceyx/plugin/test/encode_service_test.dart:177-180`:
///
///   DNG_NATIVE_BUILD_DIR=/Users/jhangyu/project/ceyx/plugin/macos/Libraries \
///     flutter test test/services/image_pipeline/yuv420_format_loss_test.dart
///
/// **A skipped run and a real run differ only in the skip line**, so a T16
/// acceptance claim must cite counts showing this case PASSING. The library was
/// proved to export the converter by symbol inspection, never by mtime:
/// `tmp/verify/t16/nm-macos-dylib.txt`.
final String? _skipReason =
    Platform.environment['DNG_NATIVE_BUILD_DIR'] == null
        ? 'set DNG_NATIVE_BUILD_DIR to ceyx plugin/macos/Libraries: this case '
            'decodes a real RAW file through the native library'
        : null;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The ARW of record for this campaign: generic-RAW Bayer, the route whose
  // fused arm landed in ceyx bda80348/329817f3.
  const samplePath = '/Users/jhangyu/project/ceyx/image_samples/raw_sample.arw';

  test(
    'T16 check 3 (TC-1374): a yuv420 decode carried through materialiseRgba '
    'matches the rgba8 decode of the same frame within ceyx B4 [arm A, fused, '
    'unscaled Bayer]',
    () async {
      // A missing sample must FAIL, never skip. A silent skip on the one
      // load-bearing pixel case is how this campaign's ledger says a green
      // report gets written about a check that never ran.
      expect(
        File(samplePath).existsSync(),
        isTrue,
        reason: 'the sample of record is absent; this case cannot be skipped '
            'quietly — report the absence instead',
      );

      final service = DngDecoderService();
      service.initialize();
      final extent = service.probeOutputSize(samplePath);
      expect(extent, isNotNull, reason: 'probeOutputSize is unavailable, so '
          'the destination capacities cannot be sized from the contract');
      final w = extent!.width;
      final h = extent.height;

      final rgbaBytes = ceyxOutputFormatByteCount(CeyxOutputFormat.rgba8, w, h);
      final yuvBytes = ceyxOutputFormatByteCount(CeyxOutputFormat.yuv420, w, h);
      // Not equal by construction — if they ever were, the comparison below
      // would be measuring one format twice.
      expect(yuvBytes, lessThan(rgbaBytes));

      // Destinations come from ceyx's OWN pool rather than from `package:ffi`'s
      // `calloc`: Halcyon does not depend on that package (the analyzer says so
      // — `depend_on_referenced_packages`), and the pool is what production
      // actually hands the decoder, so this is the closer instrument as well as
      // the legal one.
      final pool = CeyxNativeBufferPool.shared;
      final rgbaDst = await pool.acquire(rgbaBytes);
      final yuvDst = await pool.acquire(yuvBytes);
      try {
        // Control arm: the SAME file, same extent, decoded as rgba8.
        service.decodeIntoPointerFormat(
          samplePath,
          rgbaDst.address,
          rgbaBytes,
          format: CeyxOutputFormat.rgba8,
        );
        // Subject arm: yuv420, then Halcyon's production materialisation seam.
        service.decodeIntoPointerFormat(
          samplePath,
          yuvDst.address,
          yuvBytes,
          format: CeyxOutputFormat.yuv420,
        );

        final reference = ffi.Pointer<ffi.Uint8>.fromAddress(
          rgbaDst.address,
        ).asTypedList(rgbaBytes);
        final materialised = await materialiseRgba(
          DecodedRgba(
            rgba: ffi.Pointer<ffi.Uint8>.fromAddress(
              yuvDst.address,
            ).asTypedList(yuvBytes),
            width: w,
            height: h,
            format: CeyxOutputFormat.yuv420,
            nativeAddress: yuvDst.address,
          ),
        );
        addTearDown(() => materialised.releaseNative?.call());
        expect(materialised.rgba.length, rgbaBytes);

        // Per-channel absolute difference over the RGB channels only: alpha is
        // a constant on both arms and would dilute the mean towards zero.
        var sum = 0.0;
        var counted = 0;
        final histogram = List<int>.filled(256, 0);
        for (var p = 0; p < rgbaBytes; p += 4) {
          for (var c = 0; c < 3; c++) {
            final d = (reference[p + c] - materialised.rgba[p + c]).abs();
            sum += d;
            histogram[d]++;
            counted++;
          }
        }
        final meanAbs = sum / counted;

        // p99.9 read off the histogram: the smallest value at or below which
        // 99.9% of the samples fall.
        final threshold = (counted * 0.999).ceil();
        var running = 0;
        var p999 = 255;
        for (var d = 0; d < 256; d++) {
          running += histogram[d];
          if (running >= threshold) {
            p999 = d;
            break;
          }
        }

        // The numbers go to stdout so the artifact records them even on a pass
        // — a bound that passes without its measured value is not evidence.
        // ignore: avoid_print
        print('T16 check 3 [arm A, fused, unscaled Bayer, Metal] '
            '${w}x$h mean_abs=$meanAbs p99.9=$p999');

        expect(
          meanAbs,
          greaterThan(0),
          reason: 'VACUITY GUARD: a zero mean means both arms produced the '
              'same bytes, i.e. one format was measured twice and the bound '
              'below passed without discriminating anything',
        );
        expect(meanAbs, lessThanOrEqualTo(2.0),
            reason: 'ceyx B4 bound (test_yuv420_to_rgba.cpp:671)');
        expect(p999, lessThanOrEqualTo(12),
            reason: 'ceyx B4 bound (test_yuv420_to_rgba.cpp:671)');
      } finally {
        pool.release(rgbaDst);
        // The seam consumed the SOURCE slot's bytes but had no `releaseNative`
        // to call (this frame was built here, not by the pool-owning decode
        // path), so the source goes back here.
        pool.release(yuvDst);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: _skipReason,
  );
}
