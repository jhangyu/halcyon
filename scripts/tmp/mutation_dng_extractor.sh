#!/bin/bash
# Discrimination proof for the DNG extractor test suite.
#
# Every mutation is applied to a COPY of the shipped extractor in a temp dir;
# macos/Runner/DngPreviewExtractor.swift is NEVER written to. That matters:
# teammates are working in this tree, and an in-tree mutation shows up in their
# context as an apparently-intentional weakening of shipped code (this has
# already caused an incident on another project).
#
# Usage: scripts/tmp/mutation_dng_extractor.sh [report-path]
# Exit 0 only if the clean copy passes AND every mutant is killed.
set -uo pipefail
cd "$(dirname "$0")/../.."

SRC=macos/Runner/DngPreviewExtractor.swift
OUT="${1:-tmp/verify/r3/mutation_dng_extractor.txt}"
WORK="$(mktemp -d -t halcyon_dng_mut)"
mkdir -p "$(dirname "$OUT")"
: > "$OUT"

say() { echo "$1" | tee -a "$OUT"; }
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

say "# DNG extractor test-suite discrimination proof"
say "# source (never modified): $SRC"
say "# HEAD: $(git rev-parse --short HEAD 2>/dev/null)"
say ""

fails=0

# run_mutant <label> <sed-expression> <grep-guard> <expected-failing-checks>
run_mutant() {
  local label="$1" expr="$2" guard="$3" expect="$4"
  local copy="$WORK/${label// /_}.swift"
  cp "$SRC" "$copy"
  sed -i '' "$expr" "$copy"
  if ! grep -q "$guard" "$copy"; then
    say "$label: MUTATION DID NOT APPLY (guard '$guard' not found) <-- fix the script"
    fails=$((fails + 1))
    return
  fi
  local log="$WORK/${label// /_}.log"
  bash scripts/tmp/run_dng_extractor_tests.sh "$copy" > "$log" 2>&1
  local rc=$?
  local failed
  failed="$(grep -c '^FAIL ' "$log")"
  if [ "$rc" -eq 0 ]; then
    say "$label: SURVIVED (suite still exit 0) <-- BLIND SPOT"
    fails=$((fails + 1))
  else
    say "$label: KILLED (exit=$rc, $failed failing checks; expected $expect)"
    grep '^FAIL ' "$log" | sed 's/^/      /' | cut -c1-140 >> "$OUT"
    grep '^FAIL ' "$log" | sed 's/^/      /' | cut -c1-140
  fi
}

say "--- control: unmutated copy must pass ---"
cp "$SRC" "$WORK/clean.swift"
bash scripts/tmp/run_dng_extractor_tests.sh "$WORK/clean.swift" > "$WORK/clean.log" 2>&1
CLEAN_RC=$?
if [ "$CLEAN_RC" -eq 0 ]; then
  say "control: PASS (exit 0, $(grep -c '^PASS ' "$WORK/clean.log") checks)"
else
  say "control: FAIL (exit $CLEAN_RC) <-- the suite is broken; mutants below mean nothing"
  fails=$((fails + 1))
fi
say ""

say "--- mutants ---"
run_mutant "M1 threshold 0.90->1.50" \
  's/maxDim >= 0\.90 \* cropMax/maxDim >= 1.50 * cropMax/' \
  '1.50 \* cropMax' "everything to go nil"

run_mutant "M2 threshold 0.90->0.10" \
  's/maxDim >= 0\.90 \* cropMax/maxDim >= 0.10 * cropMax/' \
  '0.10 \* cropMax' "S2 (half-size preview accepted)"

run_mutant "M3 drop PhotometricInterpretation==6" \
  's/photoVals\.first == 6 else { continue }/photoVals.first != nil else { continue }/' \
  'photoVals.first != nil' "S1 (linear-raw decoy selected)"

run_mutant "M4 drop Compression==7" \
  's/compVals\.first == 7 else { continue }/compVals.first != nil else { continue }/' \
  'compVals.first != nil' "S1 (lossy-JPEG decoy selected)"

run_mutant "M5 drop both format guards" \
  's/photoVals\.first == 6 else { continue }/photoVals.first != nil else { continue }/;s/compVals\.first == 7 else { continue }/compVals.first != nil else { continue }/' \
  'compVals.first != nil' "S1 (main image selected)"

run_mutant "M6 accept multi-strip images" \
  's/stripOffVals\.count == 1 else { continue }/stripOffVals.count >= 1 else { continue }/;s/stripCountVals\.count == 1 else { continue }/stripCountVals.count >= 1 else { continue }/' \
  'stripCountVals.count >= 1' "S6 (multi-strip candidate half-sliced)"

run_mutant "M7 pick smallest instead of largest" \
  's/if best == nil || area > UInt64/if best == nil || area < UInt64/' \
  'area < UInt64' "S5 (smaller candidate selected)"

run_mutant "M8 never inject orientation" \
  's/if orientation != 1, let oriented = injectExifOrientation(/if false, let oriented = injectExifOrientation(/' \
  'if false, let oriented' "R2 + S3 (orientation lost)"

run_mutant "M9 overwrite pre-existing EXIF orientation" \
  's/if jpegHasExifOrientation(jpeg) {/if false {/' \
  'if false {' "S4 (existing orientation clobbered)"

say ""
say "blind spots: $fails"
exit "$fails"
