#!/bin/bash
# Why do M2/M3 survive? Compare the extracted byte counts under each mutation
# against the unmutated baseline. If counts are identical, the guards are not
# load-bearing for these samples (redundant defence), not a probe blind spot.
set -u
cd "$(dirname "$0")/../.." || exit 1
SRC=macos/Runner/DngPreviewExtractor.swift
BAK=tmp/verify/r3/DngPreviewExtractor.swift.orig2
OUT=tmp/verify/r3/mutation_why.txt

cp "$SRC" "$BAK" || exit 1
trap 'cp "$BAK" "$SRC"' EXIT
: > "$OUT"

snap() {
  bash scripts/tmp/run_probe_extract.sh 2>&1 | grep -Eo 'bytes=[0-9]+' | tr '\n' ' '
}

cp "$BAK" "$SRC"
echo "baseline      : $(snap)" >> "$OUT"

cp "$BAK" "$SRC"
sed -i '' 's/photoVals\.first == 6 else { continue }/photoVals.first != nil else { continue }/' "$SRC"
echo "M2 no-photo   : $(snap)" >> "$OUT"

cp "$BAK" "$SRC"
sed -i '' 's/compVals\.first == 7 else { continue }/compVals.first != nil else { continue }/' "$SRC"
echo "M3 no-compress: $(snap)" >> "$OUT"

cp "$BAK" "$SRC"
sed -i '' 's/photoVals\.first == 6 else { continue }/photoVals.first != nil else { continue }/;s/compVals\.first == 7 else { continue }/compVals.first != nil else { continue }/' "$SRC"
echo "M4 neither    : $(snap)" >> "$OUT"

cp "$BAK" "$SRC"
diff -q "$BAK" "$SRC" >/dev/null && echo "restored: YES" >> "$OUT" || echo "restored: NO <-- INVESTIGATE" >> "$OUT"
cat "$OUT"
