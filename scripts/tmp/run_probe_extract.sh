#!/bin/bash
# Compiles the REAL shipped DngPreviewExtractor.swift together with the probe harness
# and runs it. One command, no duplicated logic anywhere.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="$(mktemp -t halcyon_probe_extract)"
swiftc macos/Runner/DngPreviewExtractor.swift scripts/tmp/probe_extract.swift -o "$BIN"
"$BIN"
STATUS=$?
rm -f "$BIN"
exit $STATUS
