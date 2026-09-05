// Width sweep harness, PRODUCTION-PATH variant (parallel-decode R3-T3,
// ticket #15, ruling: option c). Sibling of width_sweep.dart, which is
// FROZEN as evidence for the completed legacy-path A/B and is deliberately
// not edited here.
//
// width_sweep.dart calls DngDecoderService().decodeOnWorker() directly --
// one fresh Isolate spawn plus one fresh dylib load per decode. Its own
// header claimed that was "the SAME call path the app's DecodeLane bodies
// use in production"; that claim went stale when the resident decode pool
// landed (0b08152) and was never updated. This file instead calls
// decodeDngFull() from lib/services/image_pipeline/dng_decode_service.dart,
// which is the actual production entry point: it branches on
// kDecodePoolEnabled into CeyxDecodePool.shared.decode(), the persistent
// worker pool the running app uses.
//
// Usage: dart run tool/decode_worker_bench/width_sweep_pool.dart <width> <file...>
//
// Prints "width,sampleCount,wallMs" then "COMPLETIONS:t1,...,tN" (ms offsets
// from a single batch-start Stopwatch, sorted, one per successfully decoded
// file) -- identical instrumentation pattern to width_sweep.dart's addition
// in ticket #15 (see that file's header comment for the constraints this
// preserves: no I/O inside the timed region, single Stopwatch origin).
//
// Headless: no dart:ui, no UI, no RSS measurement.
import 'dart:io';

import 'package:halcyon_flutter/services/image_pipeline/dng_decode_service.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
      'usage: dart run tool/decode_worker_bench/width_sweep_pool.dart '
      '<width> <file...>',
    );
    exit(2);
  }
  final width = int.parse(args.first);
  if (width < 1) {
    stderr.writeln('ERROR: width must be >= 1, got $width');
    exit(2);
  }
  final files = args.sublist(1);

  // Setup, not a measured quantity: match how the app sets the pool width
  // via setHalcyonDecodePoolWidth from decodeLaneWidth at the user's stress
  // setting.
  setHalcyonDecodePoolWidth(width);

  final sw = Stopwatch()..start();
  final completions = <int>[];
  var next = 0;
  Future<void> worker() async {
    while (next < files.length) {
      final i = next++;
      try {
        await decodeDngFull(files[i]);
        // Buffer only -- no I/O here, so this cannot perturb the timed batch.
        completions.add(sw.elapsedMilliseconds);
      } catch (e) {
        stderr.writeln('decode failed for ${files[i]}: $e');
      }
    }
  }

  await Future.wait(List.generate(width, (_) => worker()));
  sw.stop();

  stdout.writeln('$width,${files.length},${sw.elapsedMilliseconds}');
  final sorted = List<int>.of(completions)..sort();
  stdout.writeln('COMPLETIONS:${sorted.join(',')}');
}
