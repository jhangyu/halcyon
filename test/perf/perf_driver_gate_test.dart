// TC-1421 (ruling 4c, 2026-10-02): PerfDriver must be inert in any build that
// lacks --dart-define=HALCYON_PERF_DRIVER=1, EVEN WHEN HALCYON_PERF_DIR is set
// at run time. Passes in the ordinary suite (no env, no define). Run with
// HALCYON_PERF_DIR exported to also prove `active` itself is gated:
//   HALCYON_PERF_DIR=scripts/tmp flutter test test/perf/perf_driver_gate_test.dart
// Reads the gate only; never calls PerfDriver.run (agents do not drive the UI
// harness, see perf_driver.dart header).
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/perf/perf_driver.dart';

void main() {
  test('TC-1421 PerfDriver stays inactive without the build-time define', () {
    expect(kPerfDriver, isFalse);
    expect(PerfDriver.active, isFalse);
  });
}
