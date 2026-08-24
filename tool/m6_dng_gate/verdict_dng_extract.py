#!/usr/bin/env python3
"""M7 Task 7 -- mechanical verdict for the tracked DNG decode gate.

Applies ruling P-13 (docs/logs/2026-08-24/m6-feature-platform-matrix.md,
matrix P-13; restated verbatim in
docs/superpowers/plans/2026-08-24-m7-dng-contract-hardening.md Task 7 and
Global Constraints C-5) VERBATIM:

    A sample PASSES if its per-sample warm-median decode latency is under
    75 ms absolutely, regardless of ratio. Otherwise the 2.0x ratio clause
    against the recorded baseline applies: PASS iff
    current_median_ms <= 2.0 * baseline_median_ms(recorded reference run).

No aggregation overrides a per-sample failure. The 75 ms floor is a literal
constant, not a tunable -- see FLOOR_MS below.

Usage: python3 tool/m6_dng_gate/verdict_dng_extract.py <result-file>
Exit code: 0 on PASS (every sample with a recorded baseline passes), 1 on
FAIL (any sample fails) or on a malformed/unreadable result file.
"""
import re
import sys

# P-13 absolute floor, ms. Ruling: matrix P-13 (2026-08-24), reaffirmed as
# Global Constraint C-5 in the M7 plan header: "any per-sample decode under
# 75 ms passes outright, regardless of the 2.0x ratio clause." Literal
# constant -- never a CLI parameter, never derived.
FLOOR_MS = 75.0

# P-13 ratio ceiling, applied only when a sample is at or above FLOOR_MS.
RATIO_LIMIT = 2.0

# Reference baseline (warm_median_ms), the recorded G'''' result-of-record
# for the 33-sample canonical set (scripts/tmp/m6-r1-bench/all_abs.txt),
# transcribed verbatim from scripts/tmp/m6-r2-verify/p5-3-verify.txt lines
# 43-76 (itself sourced from scripts/tmp/20260824T100530Z-m6-g3third.txt
# section 5 for the 13 bare-CFA DNGs, and
# scripts/tmp/20260824T095155Z-m6-g3second.txt section 6 ROUND 1 for the
# other 20 non-bare-CFA samples). This is the admissible baseline this
# harness reproduces against; it is data, not re-derived per run.
BASELINE_MS = {
    "2024-07-03-18-52-26.dng": 85.116,
    "2024-07-03-18-52-41.dng": 65.260,
    "2024-07-03-18-52-49.dng": 100.214,
    "2024-07-03-18-54-44.dng": 59.521,
    "2024-07-03-18-54-49.dng": 89.187,
    "2024-07-03-18-55-14.dng": 65.764,
    "2024-07-03-18-55-35.dng": 90.299,
    "2024-07-03-18-56-59.dng": 56.804,
    "2024-07-03-18-58-42.dng": 99.502,
    "2024-07-03-19-03-09.dng": 67.055,
    "2024-07-06-19-09-52.dng": 80.188,
    "2024-07-06-19-09-55.dng": 64.726,
    "IMG_20251112_092839.dng": 55.557,
    "2025-01-19-14-43-30.jpg": 23.270,
    "2025-01-19-14-43-32.jpg": 22.561,
    "2025-01-19-14-43-37.jpg": 25.352,
    "2025-01-19-14-43-39.jpg": 24.368,
    "2025-01-19-14-43-40.jpg": 25.910,
    "2025-01-19-14-43-47.jpg": 22.377,
    "2025-01-19-14-43-49.jpg": 23.709,
    "2026-02-15-19-37-38.dng": 0.379,
    "2026-02-15-20-53-24.dng": 0.393,
    "2026-02-15-20-53-31.dng": 0.396,
    "2026-02-15-20-57-15.dng": 0.326,
    "2026-02-15-20-57-23-2.dng": 0.305,
    "2026-02-15-20-57-23.dng": 0.313,
    "2026-02-15-20-57-26.dng": 0.303,
    "2026-02-15-20-57-28.dng": 0.299,
    "2026-02-15-21-53-33.dng": 0.325,
    "2026-02-15-21-53-41.dng": 0.333,
    "2026-02-15-21-53-42.dng": 0.322,
    "2026-02-15-21-53-43.dng": 0.297,
    "2026-08-07-17-52-54.dng": 28.476,
}

# Matches g3_sidebar_bench.dart's CSV data rows, e.g.:
# dart,2024-07-03-18-52-26.dng,9874332,true,43.455,...,43.455,120000,200x150,200x150
ROW_RE = re.compile(
    r"^dart,(?P<file>[^,]+),(?P<size>\d+),(?P<found>true|false),"
    r"(?P<cold>-?[\d.]+),(?P<w1>-?[\d.]+),(?P<w2>-?[\d.]+),(?P<w3>-?[\d.]+),"
    r"(?P<w4>-?[\d.]+),(?P<w5>-?[\d.]+),(?P<median>-?[\d.]+),"
)


def evaluate(median_ms: float, baseline_ms: float):
    """Applies P-13 verbatim. Returns (passed: bool, reason: str)."""
    if median_ms < FLOOR_MS:
        return True, "under %.0fms floor (P-13)" % FLOOR_MS
    limit = RATIO_LIMIT * baseline_ms
    ratio = median_ms / baseline_ms if baseline_ms else float("inf")
    if median_ms <= limit:
        return True, "ratio=%.3f <= %.1fx baseline" % (ratio, RATIO_LIMIT)
    return False, "ratio=%.3f > %.1fx baseline (median=%.3fms, limit=%.3fms)" % (
        ratio, RATIO_LIMIT, median_ms, limit)


def main(argv):
    if len(argv) != 2:
        print("usage: verdict_dng_extract.py <result-file>", file=sys.stderr)
        return 1
    path = argv[1]
    try:
        with open(path) as f:
            lines = f.readlines()
    except OSError as e:
        print("ERROR: cannot read result file %s: %s" % (path, e), file=sys.stderr)
        return 1

    print("DECISION RULE (P-13, verbatim): a sample passes if its per-sample "
          "warm-median decode latency is under %.0fms absolutely, regardless "
          "of ratio; otherwise it must be <= %.1fx the recorded baseline "
          "median." % (FLOOR_MS, RATIO_LIMIT))
    print("")

    applicable = 0
    fails = []
    skipped = []
    for line in lines:
        line = line.strip()
        m = ROW_RE.match(line)
        if not m:
            continue
        name = m.group("file")
        found = m.group("found") == "true"
        median = float(m.group("median"))
        if not found:
            print("%s: SKIP (no cache bytes produced -- not a latency sample)" % name)
            skipped.append(name)
            continue
        baseline = BASELINE_MS.get(name)
        if baseline is None:
            print("%s: SKIP (no recorded baseline for this sample name)" % name)
            skipped.append(name)
            continue
        applicable += 1
        passed, reason = evaluate(median, baseline)
        verdict = "PASS" if passed else "FAIL"
        print("%s: %s (median=%.3fms baseline=%.3fms %s)" % (
            name, verdict, median, baseline, reason))
        if not passed:
            fails.append(name)

    print("")
    print("applicable_samples=%d skipped_samples=%d failing_samples=%d" % (
        applicable, len(skipped), len(fails)))
    print("AGGREGATES ARE INFORMATIONAL AND NEVER OVERRIDE A PER-SAMPLE FAILURE.")

    if applicable == 0:
        print("VERDICT: FAIL -- no applicable samples found in result file")
        return 1
    if fails:
        print("VERDICT: FAIL -- %s" % ", ".join(fails))
        return 1
    print("VERDICT: PASS -- all %d applicable samples satisfy P-13" % applicable)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
