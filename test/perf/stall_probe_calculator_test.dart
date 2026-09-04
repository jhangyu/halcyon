// W3 (docs/logs/2026-09-04/remediation-round-contract.md AC5): the D3 stall
// probe used to accumulate `expectedMs` from t=0 forever, so once one stall
// pushed the stopwatch ahead of schedule, every later tick re-logged the same
// growing cumulative drift instead of the length of just that gap. These
// tests exercise the pure delta logic (`StallProbeCalculator`) without a real
// `Timer`, per the D1 test-suite convention of never depending on wall time.
//
// TC-914, TC-915.

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/perf/perf_log.dart';

void main() {
  // TC-914 -- happy path: ticks arriving exactly on schedule never log.
  test('no drift when ticks land exactly on the 8ms schedule', () {
    final calc = StallProbeCalculator();
    for (var elapsed = 8; elapsed <= 80; elapsed += 8) {
      expect(calc.tick(elapsed), isNull);
    }
    expect(calc.debugExpectedMs, 80);
  });

  // TC-915 -- the actual bug: two coalesced ticks after a stall must each
  // report the length of their OWN gap, not a running cumulative total.
  test('coalesced ticks after a stall log the per-gap delta, not the total',
      () {
    final calc = StallProbeCalculator();

    // Establish a clean baseline: 5 on-schedule ticks (expected == elapsed).
    for (var elapsed = 8; elapsed <= 40; elapsed += 8) {
      expect(calc.tick(elapsed), isNull);
    }
    expect(calc.debugExpectedMs, 40);

    // A single long stall: the isolate was blocked from t=40 to t=140 (100ms
    // gap against the next 8ms-scheduled tick at expected=48).
    final firstDrift = calc.tick(140);
    expect(firstDrift, isNotNull);
    expect(firstDrift, 140 - 48, reason: 'first gap is measured against the pre-stall schedule');
    // Resync happened: expectedMs must now equal the actual elapsed time,
    // not the old schedule.
    expect(calc.debugExpectedMs, 140);

    // The very next probe fire, 8ms later (t=148) is BACK on schedule
    // relative to the resync -- must NOT re-report the old 92ms drift.
    expect(calc.tick(148), isNull);
    expect(calc.debugExpectedMs, 148);

    // A second, independent stall: t=148 -> t=200 (52ms gap). Must log only
    // this gap (52ms-ish), never the sum of both stalls.
    final secondDrift = calc.tick(200);
    expect(secondDrift, isNotNull);
    expect(secondDrift, 200 - 156, reason: 'second gap must not include the first stall');
    expect(secondDrift! < 100, true,
        reason: 'a cumulative-total bug would report well over 100ms here');
  });

  // TC-915b -- threshold boundary: exactly at threshold does not log.
  test('drift exactly at the threshold does not log', () {
    final calc = StallProbeCalculator(thresholdMs: 16);
    expect(calc.tick(8), isNull);
    // expectedMs=16, elapsed=32 -> drift=16, not > 16.
    expect(calc.tick(32), isNull);
  });
}
