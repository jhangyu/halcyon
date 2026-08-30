#!/bin/bash
# Runner for the decode-lane width sweep (spec §9, plan Task 7).
#
# Usage: bash tool/decode_worker_bench/run_width_sweep.sh <width> <sample-dir> <max-samples>
#
# Prints "user+sys" and "wall" seconds derived from /usr/bin/time -l plus the
# harness's own wallMs to stdout. RC is captured by the caller via RC=$?
# immediately after invoking this script, per the Task 7 hard rule.
set -u

WIDTH="${1:-}"
SAMPLE_DIR="${2:-}"
MAX_SAMPLES="${3:-0}"

if [ -z "$WIDTH" ] || [ -z "$SAMPLE_DIR" ]; then
  echo "usage: bash tool/decode_worker_bench/run_width_sweep.sh <width> <sample-dir> <max-samples>" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

LIST="$(mktemp)"
find "$SAMPLE_DIR" -type f -iname '*.dng' | sort > "$LIST.all"
if [ "$MAX_SAMPLES" -gt 0 ]; then
  head -n "$MAX_SAMPLES" "$LIST.all" > "$LIST"
else
  cp "$LIST.all" "$LIST"
fi

# Same vendored dylib resolution as run_bench.sh.
DYLIB="${DNG_DYLIB:-/Users/jhangyu/project/ceyx/plugin/macos/Libraries/libdng_decoder_native.dylib}"
DYLIB_DIR="$(dirname "$DYLIB")"

# shellcheck disable=SC2046
DNG_NATIVE_BUILD_DIR="$DYLIB_DIR" \
  /usr/bin/time -l dart run tool/decode_worker_bench/width_sweep.dart "$WIDTH" $(cat "$LIST")
