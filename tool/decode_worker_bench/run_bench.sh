#!/bin/bash
# Persistent-decode-worker measurement gate runner (spec §B.5).
#
# Usage: bash tool/decode_worker_bench/run_bench.sh <sample-dir> <out-file>
#
# House rules implemented here, not merely documented:
#   1. Pre-registration: the go/no-go rule text is written into the result
#      file ABOVE any number, before any number exists.
#   2. Provenance: git HEAD plus an exported-symbol check (nm -gU) on the
#      vendored dylib, proving the measured binary contains the code under
#      test -- never mtime.
#   3. Every measured command captures RC=$? on the line immediately after
#      it, INSIDE the artifact. Never ${PIPESTATUS[0]}, never a harness
#      completion notification.
#
# Real photos only; no synthetic fallback. No UI or memory measurement.
set -u

SAMPLE_DIR="${1:-}"
OUT="${2:-}"

if [ -z "$SAMPLE_DIR" ] || [ -z "$OUT" ]; then
  echo "usage: bash tool/decode_worker_bench/run_bench.sh <sample-dir> <out-file>" >&2
  exit 2
fi

if [ ! -d "$SAMPLE_DIR" ]; then
  echo "ERROR: sample directory '$SAMPLE_DIR' does not exist." >&2
  echo "This harness reads real photos only (no synthetic fallback)." >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

WORK="$(mktemp -d)"
LIST="$WORK/samples_abs.txt"
find "$SAMPLE_DIR" -type f \( -iname '*.dng' -o -iname '*.raf' -o -iname '*.rw2' \) \
  | sort > "$LIST.all"
TOTAL_FOUND=$(wc -l < "$LIST.all" | tr -d ' ')
# MAX_SAMPLES caps the deterministic sorted-first-N slice actually measured.
# It exists ONLY to keep the whole gate inside a single bounded foreground run
# on a host where shell backgrounding is forbidden and the per-command wall
# clock is hard-capped; it never lowers the >=5 sample floor in the rule below.
# Default 0 = use every sample found.
MAX_SAMPLES="${MAX_SAMPLES:-0}"
if [ "$MAX_SAMPLES" -gt 0 ]; then
  head -n "$MAX_SAMPLES" "$LIST.all" > "$LIST"
else
  cp "$LIST.all" "$LIST"
fi
SAMPLE_COUNT=$(wc -l < "$LIST" | tr -d ' ')

DYLIB="${DNG_DYLIB:-/Users/jhangyu/project/ceyx/plugin/macos/Libraries/libdng_decoder_native.dylib}"

{
  echo "================================================================================"
  echo "PERSISTENT DECODE WORKER -- MEASUREMENT GATE"
  echo "PRE-REGISTRATION BLOCK -- written to this file BEFORE any measurement"
  echo "existed. Everything below the RESULTS banner was appended after this"
  echo "block was on disk."
  echo "================================================================================"
  echo ""
  echo "SAMPLE_DIR=$SAMPLE_DIR"
  echo "TOTAL_FOUND=$TOTAL_FOUND"
  echo "MAX_SAMPLES=$MAX_SAMPLES (0 = all; a deterministic sorted-first-N slice"
  echo "  used purely to fit one bounded foreground run; never below the 5 floor)"
  echo "SAMPLE_COUNT=$SAMPLE_COUNT"
  echo ""
  echo "DECISION RULE (verbatim from"
  echo "docs/logs/2026-08-28/spec-tier2-bias-and-persistent-decoder.md Sec B.5):"
  echo ""
  echo "  GO if, over at least 5 distinct no-preview RAW samples,"
  echo "  median(throwaway_wall_ms) - median(warm_wall_ms)"
  echo "      >= 0.15 * median(throwaway_wall_ms)"
  echo "  AND that absolute difference is >= 50 ms."
  echo "  Otherwise NO-GO."
  echo ""
  echo "  Fewer than 5 usable samples => NO-GO by insufficient evidence."
  echo "  Never a smaller sample set, never synthetic input."
  echo ""
  echo "  Medians are taken over the WARM calls only (call_index 1..5):"
  echo "  per sample, the median of its 5 warm calls; per variant, the median"
  echo "  of those per-sample values. call_index 0 is the cold call and is"
  echo "  recorded but excluded from the medians."
  echo ""
  echo "No re-running with different parameters until a run passes: a failing"
  echo "run stays in this artifact."
  echo "================================================================================"
  echo "RESULTS  (everything below this banner was produced AFTER the block above)"
  echo "================================================================================"
  echo ""
  echo "## 0. Tree state"
  echo "-- git rev-parse HEAD"
} >> "$OUT"
git rev-parse HEAD >> "$OUT" 2>&1
RC=$?; echo "HEAD_RC=$RC" >> "$OUT"
echo "HEAD=$(git rev-parse HEAD 2>/dev/null)" >> "$OUT"
echo "-- git status --porcelain" >> "$OUT"
git status --porcelain >> "$OUT" 2>&1
RC=$?; echo "STATUS_RC=$RC" >> "$OUT"

{
  echo ""
  echo "## 1. Provenance: native artifact content marker (never mtime)"
  echo "-- vendored dylib: $DYLIB"
} >> "$OUT"
if [ -f "$DYLIB" ]; then
  nm -gU "$DYLIB" 2>>"$OUT" | grep dng_decode_and_process >> "$OUT" 2>&1
  RC=$?; echo "NM_GREP_RC=$RC (0 means the decode symbol is present in this build)" >> "$OUT"
  shasum -a 256 "$DYLIB" >> "$OUT" 2>&1
  RC=$?; echo "SHA_RC=$RC" >> "$OUT"
else
  echo "DYLIB_MISSING: $DYLIB not found on this host." >> "$OUT"
  echo "NM_GREP_RC=missing" >> "$OUT"
fi

if [ "$SAMPLE_COUNT" -lt 5 ]; then
  {
    echo ""
    echo "## 2. Sample sufficiency"
    echo "SAMPLE_COUNT=$SAMPLE_COUNT is below the 5-sample floor in the rule above."
    echo "BENCH_CSV_BEGIN"
    echo "BENCH_CSV_END"
    echo "VERDICT=NO-GO (insufficient evidence: fewer than 5 usable samples)"
  } >> "$OUT"
  echo "NO-GO: fewer than 5 samples in '$SAMPLE_DIR'." >&2
  exit 0
fi

DYLIB_DIR="$(dirname "$DYLIB")"
CSV="$WORK/bench.csv"
echo "variant,file,call_index,wall_ms,decode_ms,process_ms,width,height" > "$CSV"

{
  echo ""
  echo "## 3. Variant throwaway (today's production shape)"
} >> "$OUT"
# shellcheck disable=SC2046
DNG_NATIVE_BUILD_DIR="$DYLIB_DIR" \
  dart run tool/decode_worker_bench/bench.dart throwaway $(cat "$LIST") >> "$CSV" 2>>"$OUT"
RC=$?; echo "THROWAWAY_RC=$RC" >> "$OUT"

{
  echo ""
  echo "## 4. Variant warm (one reused, initialized service)"
} >> "$OUT"
# shellcheck disable=SC2046
DNG_NATIVE_BUILD_DIR="$DYLIB_DIR" \
  dart run tool/decode_worker_bench/bench.dart warm $(cat "$LIST") >> "$CSV" 2>>"$OUT"
RC=$?; echo "WARM_RC=$RC" >> "$OUT"

{
  echo ""
  echo "## 5. Measurements"
  echo "BENCH_CSV_BEGIN"
} >> "$OUT"
cat "$CSV" >> "$OUT"
echo "BENCH_CSV_END" >> "$OUT"

{
  echo ""
  echo "## 6. Verdict"
  echo "Apply the DECISION RULE above to the CSV and append exactly one line:"
  echo "  VERDICT=GO      or      VERDICT=NO-GO"
  echo "together with the two medians and their difference it was derived from."
} >> "$OUT"

echo "wrote $OUT"
