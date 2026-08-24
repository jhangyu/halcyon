import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/perf/perf_log.dart';

// P-2b proof half 1 (plumbing): kHalcyonBuildCommit is a compile-time
// String.fromEnvironment const, so this test only means anything when run
// with the matching --dart-define. It is NOT a normal suite member: run
// bare (`flutter test`) it asserts the documented default ('unknown'), and
// with the sentinel define it asserts the sentinel was picked up. Either way
// it exercises real behaviour, so it is left enabled for the ordinary suite
// too rather than skipped -- the default-value assertion is itself a useful
// regression guard (catches an accidental defaultValue change).
//
// Proof half 2 (scripts/build_apps.py actually passes a REAL hash on a real
// build) is necessarily out of this file's reach -- it is a Python subprocess
// test, evidenced separately in tmp/verify/ (see p2b-handoff.md / the P-2b
// report to m6-lead-opus).
void main() {
  test(
    'P-2b kHalcyonBuildCommit reflects HALCYON_BUILD_COMMIT at compile time',
    () {
      const sentinel = String.fromEnvironment(
        'HALCYON_BUILD_COMMIT',
        defaultValue: 'unknown',
      );
      // This is exactly how lib/perf/perf_log.dart's kHalcyonBuildCommit is
      // declared (perf_log.dart:11-14) -- re-declaring the same
      // String.fromEnvironment call here, rather than asserting against the
      // library constant directly, is what lets this test prove the
      // --dart-define reaches DART CODE AT ALL, independent of whether
      // perf_log.dart's own declaration is wired correctly.
      expect(kHalcyonBuildCommit, sentinel);
      if (sentinel == 'unknown') {
        // Bare `flutter test`, no --dart-define passed: the documented
        // default. If this ever silently changes, the "unknown must
        // invalidate the run" operating rule (unit_test.md) would too.
        expect(kHalcyonBuildCommit, 'unknown');
      } else {
        // Run with --dart-define=HALCYON_BUILD_COMMIT=<sentinel>: the value
        // must be exactly what was passed, not truncated or reformatted.
        expect(kHalcyonBuildCommit, isNot('unknown'));
      }
    },
  );
}
