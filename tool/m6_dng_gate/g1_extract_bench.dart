// M7 Task 7 -- tracked port of scripts/tmp/m6-r1-bench/g1_dart.dart.
// Under test: lib/services/dng_embedded_jpeg_extractor.dart
// `DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpegFromFile(path)`.
//
// Method PORTED UNCHANGED from the gitignored M6 harness (audit gap 9):
//   mode v1 = same-isolate call (the extractor runs on the calling isolate)
//   mode v2 = Isolate.run(...) per call (the exif_metadata_service.dart
//             pattern), i.e. spawn cost is charged to every measurement,
//             matching what the production path would pay.
// Protocol identical to the original: cold = first call of this process
// against this file, then 5 warm calls, per-sample metric = median of the 5.
// Dimensions come from a baseline JPEG SOF0..SOF15 scan.
//
// Headless: no dart:ui, no UI, no RSS measurement (C-6).
//
// Usage: dart run tool/m6_dng_gate/g1_extract_bench.dart <v1|v2> <file...>
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:halcyon_flutter/services/dng_embedded_jpeg_extractor.dart';

/// Baseline JPEG SOF0..SOF15 scan; byte-for-byte the same algorithm as the
/// original scripts/tmp/m6-r1-bench/g1_native.swift `sofDims` and
/// scripts/tmp/m6-r1-bench/g1_dart.dart `sofDims`.
String sofDims(Uint8List d) {
  final n = d.length;
  if (n < 4) return '?';
  if (d[0] != 0xFF || d[1] != 0xD8) return '?';
  var pos = 2;
  while (pos + 4 <= n) {
    if (d[pos] != 0xFF) return '?';
    final marker = d[pos + 1];
    if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      pos += 2;
      continue;
    }
    if (marker == 0xD9) return '?';
    final segLen = (d[pos + 2] << 8) | d[pos + 3];
    if (segLen < 2) return '?';
    final isSOF = (marker >= 0xC0 && marker <= 0xCF) &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isSOF) {
      if (pos + 9 > n) return '?';
      final h = (d[pos + 5] << 8) | d[pos + 6];
      final w = (d[pos + 7] << 8) | d[pos + 8];
      return '${w}x$h';
    }
    if (marker == 0xDA) return '?';
    pos += 2 + segLen;
  }
  return '?';
}

Future<Uint8List?> callV1(String path) =>
    DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpegFromFile(path);

Future<Uint8List?> callV2(String path) => Isolate.run(
      () => DngEmbeddedJpegExtractor.extractFullSizeEmbeddedJpegFromFile(path),
    );

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
        'usage: dart run tool/m6_dng_gate/g1_extract_bench.dart <v1|v2> <file...>');
    exitCode = 2;
    return;
  }
  final mode = args.first; // 'v1' | 'v2'
  final files = args.skip(1).toList();
  final call = mode == 'v2' ? callV2 : callV1;

  stdout.writeln(
      'side,file,size_bytes,found,cold_ms,w1,w2,w3,w4,w5,warm_median_ms,out_bytes,sof_dims');
  for (final path in files) {
    final name = path.split('/').last;
    final size = File(path).lengthSync();

    var sw = Stopwatch()..start();
    final first = await call(path);
    sw.stop();
    final cold = sw.elapsedMicroseconds / 1000.0;

    final warm = <double>[];
    Uint8List? last;
    for (var i = 0; i < 5; i++) {
      sw = Stopwatch()..start();
      last = await call(path);
      sw.stop();
      warm.add(sw.elapsedMicroseconds / 1000.0);
    }
    final median = ([...warm]..sort())[warm.length ~/ 2];
    final dims = last == null ? '-' : sofDims(last);
    stdout.writeln('dart_$mode,$name,$size,${first != null},'
        '${cold.toStringAsFixed(3)},'
        '${warm.map((m) => m.toStringAsFixed(3)).join(',')},'
        '${median.toStringAsFixed(3)},${last?.length ?? -1},$dims');
  }
}
