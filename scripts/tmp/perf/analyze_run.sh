#!/bin/bash
# The ONLY supported way to turn a Halcyon perf log into numbers.
#
# Runs the validity gate first and refuses to invoke parse_r2.py when the gate
# rejects. Calling parse_r2.py by hand still works -- it is the authoritative
# parser and is never modified -- but then you own the validity argument
# yourself, and this round has four examples of that going wrong.
#
# Usage:
#   scripts/tmp/perf/analyze_run.sh <run.log> <stdout-capture.log> \
#       [--expect-mode profile] [--build-log <build.log>] [...gate flags]
#
# Report goes to stdout; the gate's verdict is printed above it and repeated
# in the report header so the artefact carries its own provenance.
set -uo pipefail
cd "$(dirname "$0")/../../.."

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <run.log> <stdout-capture.log> [gate flags...]" >&2
  exit 2
fi

LOG="$1"; shift
STDOUT="$1"; shift

GATE_OUT="$(python3 scripts/tmp/perf/validate_run.py "$LOG" --stdout "$STDOUT" "$@" 2>&1)"
GATE_RC=$?

echo "$GATE_OUT"
echo

if [ "$GATE_RC" -ne 0 ]; then
  echo "=============================================================="
  echo "REFUSING to run parse_r2.py: the validity gate rejected $LOG."
  echo "Any number produced from this log would be void. Fix the run."
  echo "=============================================================="
  exit "$GATE_RC"
fi

echo "=== validity gate ACCEPTED; parse_r2.py output follows ==="
echo
python3 scripts/tmp/perf/parse_r2.py "$LOG" "$STDOUT"
