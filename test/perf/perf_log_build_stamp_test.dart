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
// test, evidenced separately: tmp/verify/p2b-build-half2.txt (the emitted
// --dart-define carrying a real hash) and tmp/verify/p2b-binary-grep2.txt
// (the hash found inside the compiled App.framework AOT snapshot).
void main() {
  test(
    'P-2b kHalcyonBuildCommit reflects HALCYON_BUILD_COMMIT at compile time',
    () {
      const sentinel = String.fromEnvironment(
        'HALCYON_BUILD_COMMIT',
        defaultValue: 'unknown',
      );
      // This is exactly how lib/perf/perf_log.dart's kHalcyonBuildCommit is
      // declared (perf_log.dart:11-14). Re-declaring the same
      // String.fromEnvironment call here, then comparing it against the
      // LIBRARY constant, checks that perf_log.dart's declaration (the same
      // key, the same default) is wired correctly -- it would catch a typo'd
      // key or a changed default there, in addition to confirming the
      // --dart-define reaches compiled Dart code at all.
      expect(kHalcyonBuildCommit, sentinel);
      if (sentinel == 'unknown') {
        // Bare `flutter test`, no --dart-define passed: the documented
        // default. If this ever silently changes, the "unknown must
        // invalidate the run" documented operating rule would too.
        expect(kHalcyonBuildCommit, 'unknown');
      } else {
        // Run with --dart-define=HALCYON_BUILD_COMMIT=<sentinel>: the value
        // must be exactly what was passed, not truncated or reformatted.
        expect(kHalcyonBuildCommit, isNot('unknown'));
      }
    },
  );
}
