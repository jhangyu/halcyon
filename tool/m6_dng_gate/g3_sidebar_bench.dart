// M7 Task 7 -- tracked port of scripts/tmp/m6-r2-verify/g3_regress_dart_test.dart
// (itself a one-line-import-fixup copy of scripts/tmp/m6-r1-bench/g3second_dart_test.dart,
// which G3''' reused unmodified). Method PORTED UNCHANGED (audit gap 9): same
// route, same pipeline, same timing methodology as the recorded G'''' run
// (scripts/tmp/m6-r2-verify/g3-regress-p53.txt / p5-3-verify.txt).
//
// Timed unit: file path in -> sidebar CACHE BYTES out, covering the shipped
// pipeline exactly as image_preload_controller.dart's sweep pays for it:
//   dartImageLoad(purpose: sidebarThumbnail)
//     -> NativeImageBytes: sidebarCacheBytes(bytes)
//     -> otherwise (RAW path only), the P2.5b RAW-decode fallback:
//          decodeDngSized(path, maxDim: 200)
//          readOrientation(path) ?? kDefaultExifOrientation
//          pngFromOrientedPixels(decoded, exifOrientation: orientation)
// This calls the shipped functions directly, not a reimplementation.
//
// Runs under `flutter test` (flutter_tester) because dart:ui image decoding
// is unavailable to `dart compile exe`. JIT bias runs AGAINST Dart (same
// caveat carried forward from the original harness).
//
// Headless: no widgets, no UI pumping, no RSS measurement (C-6).
//
// Usage: G3_LIST=<path-list-file> G3_OUT=<csv-out-file> \
//        flutter test -j 1 tool/m6_dng_gate/g3_sidebar_bench.dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/models/supported_photo_formats.dart';
import 'package:halcyon_flutter/services/dart_image_loader.dart';
import 'package:halcyon_flutter/services/dng_decode_service.dart';
import 'package:halcyon_flutter/services/dng_preview_extractor.dart';
import 'package:halcyon_flutter/services/image_source_types.dart';
import 'package:halcyon_flutter/services/sidebar_thumbnail_codec.dart';

/// The exact shipped pipeline that lands a row in `_thumbCache`, INCLUDING
/// the P2.5b RAW-decode fallback (image_preload_controller.dart).
Future<Uint8List?> cacheBytesFor(String path) async {
  final result =
      await dartImageLoad(path, purpose: ImageRequestPurpose.sidebarThumbnail);
  if (result is NativeImageBytes) {
    return sidebarCacheBytes(result.bytes);
  }
  // P2.5b fallback: only for RAW paths, mirroring the sweep's guard exactly.
  if (!SupportedPhotoFormats.isRawPath(path)) return null;
  try {
    final decoded = await decodeDngSized(path, maxDim: 200);
    final orientation =
        await DngPreviewExtractor.readOrientation(path) ??
            kDefaultExifOrientation;
    return pngFromOrientedPixels(decoded, exifOrientation: orientation);
  } catch (_) {
    return null;
  }
}

/// UNTIMED dims/verdict-only decode: long-edge-200-cap semantics, identical
/// getTargetSize callback to sidebarCacheBytes's own internal decode.
Future<ui.Image?> decodeLongEdgeCapped(Uint8List bytes, {int cap = 200}) async {
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (int width, int height) {
        if (width <= cap && height <= cap) {
          return ui.TargetImageSize(width: width, height: height);
        }
        return width >= height
            ? ui.TargetImageSize(width: cap)
            : ui.TargetImageSize(height: cap);
      },
    );
    final frame = await codec.getNextFrame();
    return frame.image;
  } catch (_) {
    return null;
  }
}

void main() {
  final listPath = Platform.environment['G3_LIST'];
  final outPath = Platform.environment['G3_OUT'];

  test('g3_sidebar_bench (P2.5b RAW-decode fallback, tracked port)', () async {
    expect(listPath, isNotNull, reason: 'G3_LIST env var required');
    expect(outPath, isNotNull, reason: 'G3_OUT env var required');
    final files = File(listPath!)
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty)
        .toList();
    final out = StringBuffer();
    out.writeln('side,file,size_bytes,found,cold_ms,w1,w2,w3,w4,w5,'
        'warm_median_ms,out_rgba_bytes,dims_variantA,dims_variantB_longedge200');

    for (final path in files) {
      final name = path.split('/').last;
      final size = File(path).lengthSync();

      var sw = Stopwatch()..start();
      Uint8List? bytes = await cacheBytesFor(path);
      sw.stop();
      final cold = sw.elapsedMicroseconds / 1000.0;

      if (bytes == null) {
        out.writeln('dart,$name,$size,false,'
            '${cold.toStringAsFixed(3)},-1,-1,-1,-1,-1,-1,-1,-,-');
        continue;
      }

      final warm = <double>[];
      for (var i = 0; i < 5; i++) {
        sw = Stopwatch()..start();
        bytes = await cacheBytesFor(path);
        sw.stop();
        warm.add(sw.elapsedMicroseconds / 1000.0);
      }
      final median = ([...warm]..sort())[warm.length ~/ 2];

      // Untimed: decode the FINAL cache bytes (what the last warm call
      // produced) to obtain dims for the verdict's dims clause.
      final img = await decodeLongEdgeCapped(bytes!);
      final w = img?.width ?? -1;
      final h = img?.height ?? -1;
      img?.dispose();
      final dims = '${w}x$h';

      out.writeln('dart,$name,$size,true,'
          '${cold.toStringAsFixed(3)},'
          '${warm.map((m) => m.toStringAsFixed(3)).join(',')},'
          '${median.toStringAsFixed(3)},${w * h * 4},$dims,$dims');
    }
    File(outPath!).writeAsStringSync(out.toString());
  }, timeout: const Timeout(Duration(minutes: 20)));
}
