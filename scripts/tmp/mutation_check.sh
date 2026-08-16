#!/bin/bash
# A5 discrimination test: prove the probe FAILS when the extractor logic is broken.
# Three independent mutations, each restored immediately. Backup taken first.
set -u
cd "$(dirname "$0")/../.." || exit 1
SRC=macos/Runner/DngPreviewExtractor.swift
BAK=tmp/verify/r3/DngPreviewExtractor.swift.orig
OUT=tmp/verify/r3/mutation_check.txt

cp "$SRC" "$BAK" || exit 1
: > "$OUT"

restore() { cp "$BAK" "$SRC"; }
trap restore EXIT

run_case() {
  local label="$1"
  bash scripts/tmp/run_probe_extract.sh >/dev/null 2>&1
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "$label: probe exit=0  -> NO DISCRIMINATION (mutation survived)" >> "$OUT"
    return 1
  else
    echo "$label: probe exit=$rc -> killed (probe correctly went red)" >> "$OUT"
    return 0
  fi
}

fails=0

echo "--- baseline (unmutated, expect exit 0) ---" >> "$OUT"
bash scripts/tmp/run_probe_extract.sh >/dev/null 2>&1
echo "baseline: probe exit=$? (expect 0)" >> "$OUT"

echo "--- M1: size threshold 0.90 -> 1.50 (nothing should qualify) ---" >> "$OUT"
restore
sed -i '' 's/maxDim >= 0\.90 \* cropMax/maxDim >= 1.50 * cropMax/' "$SRC"
grep -q "1.50 \* cropMax" "$SRC" || { echo "M1: PATCH DID NOT APPLY" >> "$OUT"; fails=$((fails+1)); }
run_case "M1 threshold" || fails=$((fails+1))

echo "--- M2: drop PhotometricInterpretation==6 guard (may select linear-raw IFD) ---" >> "$OUT"
restore
sed -i '' 's/photoVals\.first == 6 else { continue }/photoVals.first != nil else { continue }/' "$SRC"
grep -q "photoVals.first != nil" "$SRC" || { echo "M2: PATCH DID NOT APPLY" >> "$OUT"; fails=$((fails+1)); }
run_case "M2 photometric" || fails=$((fails+1))

echo "--- M3: drop Compression==7 guard ---" >> "$OUT"
restore
sed -i '' 's/compVals\.first == 7 else { continue }/compVals.first != nil else { continue }/' "$SRC"
grep -q "compVals.first != nil" "$SRC" || { echo "M3: PATCH DID NOT APPLY" >> "$OUT"; fails=$((fails+1)); }
run_case "M3 compression" || fails=$((fails+1))

restore
echo "--- restored; final baseline re-check ---" >> "$OUT"
bash scripts/tmp/run_probe_extract.sh >/dev/null 2>&1
echo "post-restore: probe exit=$? (expect 0)" >> "$OUT"
diff -q "$BAK" "$SRC" >/dev/null && echo "source restored byte-identical: YES" >> "$OUT" \
  || echo "source restored byte-identical: NO  <-- INVESTIGATE" >> "$OUT"

echo "surviving mutants: $fails" >> "$OUT"
cat "$OUT"
exit "$fails"
