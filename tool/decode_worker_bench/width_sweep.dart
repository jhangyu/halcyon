// Width sweep harness for the parallel decode-lane re-benchmark (spec §9).
//
// plan-parallel-decode-lane.md step 7.2 assumed run_bench.sh could force a
// lane width; it cannot -- that script is the cold/warm DngDecoderService
// gate from spec-tier2-bias-and-persistent-decoder.md §B.5, and it has no
// concept of a controller or a width. This file replaces it for the width
// sweep only: it drives `DngDecoderService.decodeOnWorker` directly (same as
// bench.dart's `throwaway` variant) -- a fresh worker Isolate spawn plus a
// fresh dylib load per call. `width` concurrent async workers pull from a
// shared queue and call `decodeOnWorker`, matching how `DecodeLane` admits up
// to `width` task bodies at once.
//
// CORRECTED 2026-09-05 (parallel-decode ticket #15): this file's original
// header claimed the above IS "the SAME call path the app's DecodeLane
// bodies use in production". That was true when written and stopped being
// true when the resident decode pool landed (commit 0b08152): production now
// calls `decodeDngFull` (lib/services/image_pipeline/dng_decode_service.dart)
// which branches into `CeyxDecodePool.shared.decode()`, NOT
// `DngDecoderService().decodeOnWorker` directly. Nobody updated this comment
// when that landed, and a stale "drives the production path" claim survived
// long enough to be picked as ticket #15's AC1 instrument before the
// discrepancy was found. This file measures the LEGACY per-decode isolate
// path, still real and still useful as a contrast case, but NOT what the
// running app currently does. For a production-path measurement, see the
// sibling `width_sweep_pool.dart` (calls `decodeDngFull`, requires
// `flutter test` rather than `dart run`/`dart compile exe` because that
// function transitively needs Flutter's dart:ui bindings).
//
// Usage: dart run tool/decode_worker_bench/width_sweep.dart <width> <file...>
//
// Prints one summary line per run to stdout: "width,sampleCount,wallMs",
// followed by a "COMPLETIONS:t1,t2,...,tN" line (offsets in ms from a single
// batch-start instant, one per successfully decoded file, in completion
// order) -- added for parallel-decode R3-T3 (ticket #15) so AC1's "the
// completions list shows the staircase gone" can be checked mechanically
// via spread = c_last - c_first, instead of eyeballed.
//
// Instrumentation constraints (see ticket #15 pre-registration addendum):
//  - No changes to DngDecoderService / decodeOnWorker (the code under test).
//  - No I/O inside the timed region: each worker's completion offset is
//    buffered in memory (`completions`) and everything is printed only
//    after `sw.stop()`, so printing itself cannot perturb the measured wall
//    time.
//  - All offsets share the single `sw` instance as their origin, so
//    subtracting them is a direct, unambiguous spread.
//
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
  final completions = <int>[];
  var next = 0;
  Future<void> worker() async {
    while (next < files.length) {
      final i = next++;
      try {
        await DngDecoderService().decodeOnWorker(files[i]);
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
