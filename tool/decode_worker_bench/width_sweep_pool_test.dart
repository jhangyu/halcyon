// flutter-test entrypoint for width_sweep_pool.dart's production-path
// harness (ticket #15, ruling: option c). Required because decodeDngFull
// transitively imports package:flutter/foundation.dart, which needs the
// Flutter engine's dart:ui bindings that plain `dart run`/`dart compile exe`
// cannot provide -- `flutter test` supplies them headlessly (no real
// window, no rendering), same as every other suite in this repo.
//
// Parameters come from environment variables (read at runtime via
// Platform.environment, not compile-time consts) so the same compiled/run
// invocation can be driven from the shell exactly like the CLI harness:
//   POOL_SWEEP_WIDTH=5
//   POOL_SWEEP_FILES=/abs/path/1.dng,/abs/path/2.dng,...
//
// Usage:
//   POOL_SWEEP_WIDTH=<n> POOL_SWEEP_FILES=<comma-separated abs paths> \
//     flutter test tool/decode_worker_bench/width_sweep_pool_test.dart
//
// Prints the SAME two-line format as width_sweep.dart / width_sweep_pool.dart
// CLI mode: "width,sampleCount,wallMs" then "COMPLETIONS:t1,...,tN".
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'width_sweep_pool.dart';

void main() {
  test('production-pool width sweep', () async {
    final widthRaw = Platform.environment['POOL_SWEEP_WIDTH'];
    final filesRaw = Platform.environment['POOL_SWEEP_FILES'];
    if (widthRaw == null || filesRaw == null || filesRaw.isEmpty) {
      stderr.writeln(
        'usage: POOL_SWEEP_WIDTH=<n> POOL_SWEEP_FILES=<comma-separated '
        'abs paths> flutter test tool/decode_worker_bench/'
        'width_sweep_pool_test.dart',
      );
      fail('POOL_SWEEP_WIDTH / POOL_SWEEP_FILES not set');
    }
    final width = int.parse(widthRaw);
    final files = filesRaw.split(',');

    final result = await runPoolSweep(width, files);
    // print(), not stdout.writeln -- flutter test captures print() output
    // reliably; both are fine here since this happens strictly after
    // sw.stop() inside runPoolSweep, outside the timed region.
    // ignore: avoid_print
    print('${result.width},${result.sampleCount},${result.wallMs}');
    // ignore: avoid_print
    print('COMPLETIONS:${result.completions.join(',')}');
  });
}
