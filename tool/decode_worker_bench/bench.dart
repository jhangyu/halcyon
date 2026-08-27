// Persistent-decode-worker measurement gate (spec §B.5).
//
// Measures the per-decode cost of the two shapes the proposal is about:
//   variant `throwaway` = today's production shape -- a fresh
//     DngDecoderService and decodeOnWorker() per call, so every call pays a
//     fresh Isolate.run, a dylib load, and a cold GPU pipeline build.
//   variant `warm`      = one DngDecoderService()..initialize(), reused for
//     every call via the synchronous same-isolate decode(), so the dylib load
//     and the pipeline build are paid once for the whole run.
//
// The difference between the two medians IS the quantity the go/no-go rule is
// about. This file deliberately imports nothing from lib/services/, so a
// Halcyon-side change cannot move the number.
//
// Headless: no dart:ui, no UI, no RSS measurement.
//
// Protocol: per file, 1 cold call (call_index 0) then 5 warm calls
// (call_index 1..5). One CSV row per call on stdout.
//
// Usage: dart run tool/decode_worker_bench/bench.dart <throwaway|warm> <file...>
import 'dart:io';

import 'package:ceyx/ceyx.dart';

const int kWarmCalls = 5;

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
      'usage: dart run tool/decode_worker_bench/bench.dart '
      '<throwaway|warm> <file...>',
    );
    exit(2);
  }
  final variant = args.first;
  if (variant != 'throwaway' && variant != 'warm') {
    stderr.writeln("ERROR: variant must be 'throwaway' or 'warm', got '$variant'");
    exit(2);
  }
  final files = args.sublist(1);

  // The warm variant's whole point: ONE service for the whole run.
  DngDecoderService? shared;
  if (variant == 'warm') {
    shared = DngDecoderService()..initialize();
  }

  for (final path in files) {
    for (var call = 0; call <= kWarmCalls; call++) {
      final sw = Stopwatch()..start();
      DngImage image;
      try {
        if (variant == 'throwaway') {
          image = await DngDecoderService().decodeOnWorker(path);
        } else {
          image = shared!.decode(path);
        }
      } catch (e) {
        sw.stop();
        stdout.writeln('$variant,$path,$call,ERROR,ERROR,ERROR,0,0');
        stderr.writeln('decode failed for $path ($variant, call $call): $e');
        continue;
      }
      sw.stop();
      stdout.writeln(
        '$variant,$path,$call,${sw.elapsedMicroseconds / 1000.0},'
        '${image.decodeMs},${image.processMs},${image.width},${image.height}',
      );
    }
  }
}
