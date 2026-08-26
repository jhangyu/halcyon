#!/bin/bash
# M7 Task 7 -- tracked DNG decode gate runner.
# Promotes the gitignored scripts/tmp/m6-r1-bench / scripts/tmp/m6-r2-verify
# harnesses into tool/, unchanged in method (audit gap 9).
#
# Usage: bash tool/m6_dng_gate/run_gate.sh <sample-dir> <out-file>
#
# Writes a machine-readable result file to <out-file>. Every measured
# command captures RC=$? on the line immediately after it, inside the
# artifact. Never ${PIPESTATUS[0]}, never a harness completion notification.
#
# House rules implemented here (not merely documented):
#   1. Provenance: the result file's header records git HEAD plus an
#      exported-symbol check (nm -gU) on the vendored native dylib the
#      RAW-decode fallback depends on, proving the measured binary contains
#      the code under test -- never mtime.
#   2. Pre-registration: the P-13 verdict rule text is written into the
#      result file ABOVE the numbers, before any number exists.
#
# No UI or memory measurement (C-6). Headless decode timings only.
set -u

SAMPLE_DIR="${1:-}"
OUT="${2:-}"

if [ -z "$SAMPLE_DIR" ] || [ -z "$OUT" ]; then
  echo "usage: bash tool/m6_dng_gate/run_gate.sh <sample-dir> <out-file>" >&2
  exit 2
fi

# Fail loudly when the sample directory is absent -- never fall back to
# synthetic input (Task 7 constraint, verbatim).
if [ ! -d "$SAMPLE_DIR" ]; then
  echo "ERROR: sample directory '$SAMPLE_DIR' does not exist." >&2
  echo "This harness reads real photos only (no synthetic fallback)." >&2
  echo "Populate local_data/photo_samples/ or pass a directory that exists." >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

WORK="$(mktemp -d)"
LIST="$WORK/samples_abs.txt"
find "$SAMPLE_DIR" -type f \( -iname '*.dng' -o -iname '*.jpg' -o -iname '*.jpeg' \) \
  | sort > "$LIST"
SAMPLE_COUNT=$(wc -l < "$LIST" | tr -d ' ')
if [ "$SAMPLE_COUNT" -eq 0 ]; then
  echo "ERROR: no .dng/.jpg/.jpeg files found under '$SAMPLE_DIR'." >&2
  exit 1
fi

DYLIB="${DNG_DYLIB:-/Users/jhangyu/project/ceyx/plugin/macos/Libraries/libdng_decoder_native.dylib}"

{
  echo "================================================================================"
  echo "M7 TASK 7 -- TRACKED DNG DECODE GATE"
  echo "PRE-REGISTRATION BLOCK -- written to this file BEFORE any measurement"
  echo "existed. Everything below the RESULTS banner was appended after this"
  echo "block was on disk."
  echo "================================================================================"
  echo ""
  echo "SAMPLE_DIR=$SAMPLE_DIR"
  echo "SAMPLE_COUNT=$SAMPLE_COUNT"
  echo "SAMPLE_LIST=$LIST"
  echo ""
  echo "DECISION RULE (P-13, verbatim, restated from"
  echo "docs/logs/2026-08-24/m6-feature-platform-matrix.md and the M7 plan's"
  echo "Global Constraint C-5): a sample PASSES if its per-sample warm-median"
  echo "decode latency is under 75ms absolutely, regardless of ratio;"
  echo "otherwise the 2.0x ratio clause against the recorded baseline"
  echo "applies: PASS iff current_median_ms <= 2.0 x baseline_median_ms."
  echo "No aggregation overrides a per-sample failure. The 75ms floor is a"
  echo "literal constant (see verdict_dng_extract.py FLOOR_MS), never a"
  echo "tunable. Applied mechanically, after this run, by"
  echo "tool/m6_dng_gate/verdict_dng_extract.py against its embedded"
  echo "baseline table (transcribed from scripts/tmp/m6-r2-verify/p5-3-verify.txt)."
  echo ""
  echo "No re-running with different parameters until a run passes: a"
  echo "failing run stays in this artifact."
  echo ""
  echo "RC=\$? is self-captured INSIDE this artifact on the line immediately"
  echo "after each measured command below."
  echo "================================================================================"
  echo "RESULTS  (everything below this banner was produced AFTER the block above)"
  echo "================================================================================"
  echo ""
  echo "## 0. Tree state"
  echo "-- git rev-parse HEAD"
} >> "$OUT"
git rev-parse HEAD >> "$OUT" 2>&1
RC=$?; echo "HEAD_RC=$RC" >> "$OUT"
echo "-- git status --porcelain" >> "$OUT"
git status --porcelain >> "$OUT" 2>&1
RC=$?; echo "STATUS_RC=$RC" >> "$OUT"

{
  echo ""
  echo "## 1. Provenance: native artifact content marker (never mtime)"
  echo "-- vendored dylib: $DYLIB"
} >> "$OUT"
if [ -f "$DYLIB" ]; then
  echo "-- nm -gU (looking for dng_decode_and_process_sized)" >> "$OUT"
  nm -gU "$DYLIB" 2>>"$OUT" | grep dng_decode_and_process_sized >> "$OUT" 2>&1
  RC=$?; echo "NM_GREP_RC=$RC (0 means the symbol is present in this build)" >> "$OUT"
  echo "-- shasum -a 256" >> "$OUT"
  shasum -a 256 "$DYLIB" >> "$OUT" 2>&1
  RC=$?; echo "SHA_RC=$RC" >> "$OUT"
else
  echo "DYLIB_MISSING: $DYLIB not found on this host -- symbol/dims check skipped, reported not silently passed" >> "$OUT"
  echo "NM_GREP_RC=skipped" >> "$OUT"
fi

{
  echo ""
  echo "## 2. Current-tree marker: one existing dart_image_loader test run BEFORE the bench"
  echo "-- flutter test test/dart_image_loader_test.dart"
} >> "$OUT"
flutter test test/dart_image_loader_test.dart >> "$OUT" 2>&1
RC=$?; echo "MARKER_TEST_RC=$RC" >> "$OUT"

{
  echo ""
  echo "## 3. G1 extraction bench (informational; embedded-JPEG extraction path only)"
  echo "-- dart run tool/m6_dng_gate/g1_extract_bench.dart v1 <\$SAMPLE_COUNT files>"
} >> "$OUT"
# shellcheck disable=SC2046
dart run tool/m6_dng_gate/g1_extract_bench.dart v1 $(cat "$LIST") >> "$OUT" 2>&1
RC=$?; echo "G1_RUN_RC=$RC" >> "$OUT"

{
  echo ""
  echo "## 4. G3 sidebar bench (verdict-bearing; full sidebar route incl. RAW-decode fallback)"
  echo "-- DNG_NATIVE_BUILD_DIR=\$(dirname \$DYLIB) G3_LIST=$LIST G3_OUT=$WORK/g3.csv flutter test -j 1 tool/m6_dng_gate/g3_sidebar_bench.dart"
} >> "$OUT"
DYLIB_DIR="$(dirname "$DYLIB")"
DNG_NATIVE_BUILD_DIR="$DYLIB_DIR" G3_LIST="$LIST" G3_OUT="$WORK/g3.csv" flutter test -j 1 tool/m6_dng_gate/g3_sidebar_bench.dart >> "$OUT" 2>&1
RC=$?; echo "G3_RUN_RC=$RC" >> "$OUT"

{
  echo ""
  echo "## 5. G3 sidebar bench CSV (verdict_dng_extract.py parses lines between the markers below)"
  echo "G3_SIDEBAR_CSV_BEGIN"
} >> "$OUT"
if [ -f "$WORK/g3.csv" ]; then
  cat "$WORK/g3.csv" >> "$OUT"
fi
echo "G3_SIDEBAR_CSV_END" >> "$OUT"

{
  echo ""
  echo "## 6. Provenance re-check: tree unchanged during measurement"
} >> "$OUT"
git status --porcelain >> "$OUT" 2>&1
RC=$?; echo "STATUS_AFTER_RC=$RC" >> "$OUT"

echo "RUNNER_COMPLETED" >> "$OUT"
echo "RC=0" >> "$OUT"
exit 0
