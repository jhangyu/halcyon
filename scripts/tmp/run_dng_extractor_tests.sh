#!/bin/bash
# Compiles the SHIPPED macos/Runner/DngPreviewExtractor.swift together with the
# test suite and runs it. Regenerates the synthetic fixtures first so they can
# never go stale relative to the generator.
#
#   scripts/tmp/run_dng_extractor_tests.sh [path-to-extractor.swift]
#
# The optional argument exists for mutation testing: pass a mutated COPY of the
# extractor (see mutation_dng_extractor.sh) so the tree itself is never edited.
# Exit 0 = all assertions held.
set -uo pipefail
cd "$(dirname "$0")/../.."

SRC="${1:-macos/Runner/DngPreviewExtractor.swift}"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "FATAL: swiftc not found; the shipped extractor cannot be exercised." >&2
  exit 3
fi

python3 scripts/tmp/make_synth_dng.py >/dev/null || {
  echo "FATAL: fixture generation failed" >&2; exit 3; }

BIN="$(mktemp -t halcyon_dng_extractor_tests)"
if ! swiftc -O "$SRC" scripts/tmp/dng_extractor_tests.swift -o "$BIN" 2>&1; then
  echo "FATAL: swiftc failed for $SRC" >&2
  rm -f "$BIN"
  exit 3
fi
"$BIN"
STATUS=$?
rm -f "$BIN"
exit $STATUS
