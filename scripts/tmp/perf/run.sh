#!/bin/bash
# Run the instrumented app headfully with the perf driver enabled.
# The app is sandboxed, so dataset + log live in its container and the log is
# copied back to tmp/verify/perf/ afterwards.
#
# Usage: run.sh <dataset_name> <label> <config: Profile|Debug|Release> [mode] [n] [pace_ms]
set -uo pipefail
cd /Users/jhangyu/project/Halcyon
NAME="$1"
LABEL="$2"
CONFIG="${3:-Profile}"
MODE="${4:-both}"
N="${5:-24}"
PACE="${6:-1200}"

CONTAINER="$HOME/Library/Containers/com.jhangyu.halcyon/Data/perf"
DIR="$CONTAINER/$NAME"
OUT="$CONTAINER/${LABEL}.log"
DEST="/Users/jhangyu/project/Halcyon/tmp/verify/perf"
STDOUT="$DEST/${LABEL}.stdout.log"

APP=$(ls -d build/macos/Build/Products/$CONFIG/*.app 2>/dev/null | head -1)
BIN="$APP/Contents/MacOS/$(basename "$APP" .app)"
echo "binary=$BIN dir=$DIR mode=$MODE n=$N pace=$PACE"
rm -f "$OUT"

HALCYON_PERF_DIR="$DIR" \
HALCYON_PERF_OUT="$OUT" \
HALCYON_PERF_MODE="$MODE" \
HALCYON_PERF_N="$N" \
HALCYON_PERF_PACE="$PACE" \
"$BIN" > "$STDOUT" 2>&1
echo "APP_EXIT=$?"

cp "$OUT" "$DEST/${LABEL}.log" 2>/dev/null || echo "no container log; falling back to stdout"
wc -l "$DEST/${LABEL}.log" "$STDOUT" 2>/dev/null
grep -c "PERFNATIVE" "$STDOUT"
