// Width sweep harness for the parallel decode-lane re-benchmark (spec §9).
//
// plan-parallel-decode-lane.md step 7.2 assumed run_bench.sh could force a
// lane width; it cannot -- that script is the cold/warm DngDecoderService
// gate from spec-tier2-bias-and-persistent-decoder.md §B.5, and it has no
// concept of a controller or a width. This file replaces it for the width
// sweep only: it drives the SAME call path the app's DecodeLane bodies use
// in production -- `DngDecoderService.decodeOnWorker`, bench.dart's
// `throwaway` variant -- which spawns a fresh worker Isolate per call, so
// concurrent calls genuinely run in parallel (unlike the synchronous
// same-isolate `.decode()` the `warm` variant uses, which cannot overlap on
// a single isolate). `width` concurrent async workers pull from a shared
// queue and call `decodeOnWorker`, matching how `DecodeLane` admits up to
// `width` task bodies at once.
//
// Usage: dart run tool/decode_worker_bench/width_sweep.dart <width> <file...>
//
// Prints one line per run to stdout: "width,sampleCount,wallMs".
// Headless: no dart:ui, no UI, no RSS measurement.
import 'dart:io';

import 'package:ceyx/ceyx.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
      'usage: dart run tool/decode_worker_bench/width_sweep.dart '
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

  final sw = Stopwatch()..start();
  var next = 0;
  Future<void> worker() async {
    while (next < files.length) {
      final i = next++;
      try {
        await DngDecoderService().decodeOnWorker(files[i]);
      } catch (e) {
        stderr.writeln('decode failed for ${files[i]}: $e');
      }
    }
  }

  await Future.wait(List.generate(width, (_) => worker()));
  sw.stop();

  stdout.writeln('$width,${files.length},${sw.elapsedMilliseconds}');
}
