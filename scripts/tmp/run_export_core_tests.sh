#!/bin/bash
# Exercises the SHIPPED export core in macos/Runner/AppDelegate.swift on a real
# file. The block between EXPORT-CORE-BEGIN/END is extracted VERBATIM, wrapped
# in a Flutter-free `enum AppDelegate`, compiled with scripts/tmp/export_core/
# main.swift and run -- so what is proven is the shipped text, not a copy that
# can drift away from it. Nothing in the tree is edited.
#
#   scripts/tmp/run_export_core_tests.sh <targetSize> <src> <out.jpg>
#
# Generated Swift and the binary land in tmp/verify/export/ (scratch, sweepable;
# they are regenerated on every run whose inputs changed).
# Exit 0 = a JPEG was produced; 3 = environment/extraction/compile failure.
set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

SRC_FILE=macos/Runner/AppDelegate.swift
DRIVER=scripts/tmp/export_core/main.swift
OUTDIR=tmp/verify/export
GEN="$OUTDIR/export_core_generated.swift"
BIN="$OUTDIR/export_core"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "FATAL: swiftc not found; the shipped export core cannot be exercised." >&2
  exit 3
fi

# The sample photos are deliberately NOT tracked (they are ~23MB and live in the
# gitignored tmp/verify/export/). Fail loudly rather than with an opaque
# "returned nil" when the caller points at one that is gone.
if [ "$#" -ge 2 ] && [ ! -f "$2" ]; then
  echo "FATAL: source photo '$2' not found. This script is tracked but its" >&2
  echo "sample photos are not; pass any real photo path, e.g." >&2
  echo "  $0 2048 ~/Pictures/some.jpg /tmp/out.jpg" >&2
  exit 3
fi

mkdir -p "$OUTDIR"
{
  echo "import Foundation"
  echo "import ImageIO"
  echo "import CoreGraphics"
  echo "enum AppDelegate {"
  awk '/EXPORT-CORE-BEGIN/{flag=1;next}/EXPORT-CORE-END/{flag=0}flag' "$SRC_FILE"
  echo "}"
} > "$GEN"

LINES=$(wc -l < "$GEN")
if [ "$LINES" -lt 40 ]; then
  echo "FATAL: extracted block is only $LINES lines; markers missing?" >&2
  exit 3
fi

if [ ! -x "$BIN" ] || [ "$GEN" -nt "$BIN" ] || [ "$DRIVER" -nt "$BIN" ]; then
  swiftc -O "$GEN" "$DRIVER" -o "$BIN" || {
    echo "FATAL: swiftc failed" >&2; exit 3; }
fi

"$BIN" "$@"
