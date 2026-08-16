import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The DNG embedded-JPEG selection logic lives in Swift
/// (macos/Runner/DngPreviewExtractor.swift), so it cannot be exercised from
/// Dart directly. This test shells out to the Swift suite, which compiles the
/// SHIPPED file together with scripts/tmp/dng_extractor_tests.swift.
///
/// It lives in test/ on purpose: a check that someone has to remember to run
/// is a check that stops being run. `flutter test` now covers the extractor.
///
/// It fails -- never skips -- when swiftc or the sample material is missing.
/// A silently skipped test is exactly the empty-but-green artefact this round
/// kept producing.
void main() {
  test(
    'shipped DNG extractor passes its Swift test suite',
    () async {
      final repoRoot = Directory.current.path;
      final script = File(
        '$repoRoot/scripts/tmp/run_dng_extractor_tests.sh',
      );
      expect(
        script.existsSync(),
        isTrue,
        reason: 'missing ${script.path}; the Swift suite cannot be run',
      );

      // HALCYON_DNG_EXTRACTOR_SRC exists so this test's own failure path can
      // be demonstrated: point it at a mutated copy of the extractor and this
      // test must go red. Unset (the normal case) = the shipped file.
      final override = Platform.environment['HALCYON_DNG_EXTRACTOR_SRC'];
      final result = await Process.run(
        'bash',
        [script.path, if (override != null) override],
        workingDirectory: repoRoot,
      );

      final output = '${result.stdout}\n${result.stderr}';
      // exit 3 = environment (no swiftc, compile failure, fixture generation).
      // Report it as a failure rather than a skip: an unrun check is not a
      // passing check.
      expect(
        result.exitCode,
        0,
        reason: 'scripts/tmp/run_dng_extractor_tests.sh exited '
            '${result.exitCode}\n$output',
      );
      // Guard against a suite that exits 0 having asserted nothing.
      expect(
        output,
        contains('ALL PASS'),
        reason: 'suite exited 0 without reporting ALL PASS\n$output',
      );
      final checks = RegExp(r'checks run: (\d+)').firstMatch(output);
      expect(
        checks,
        isNotNull,
        reason: 'suite did not report a check count\n$output',
      );
      expect(
        int.parse(checks!.group(1)!),
        greaterThanOrEqualTo(20),
        reason: 'suite ran suspiciously few checks\n$output',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
