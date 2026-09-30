#!/usr/bin/env bash
# Local isolated CI gate for the linux-arm leg (user decree 2026-09-30: fresh
# clone in a blank scratch dir, never the working tree; compile-only).
#
# Host side: bundles COMMITTED HEAD of Halcyon and the sibling ceyx (ref pinned
# in .github/workflows/ci.yml) — uncommitted files never enter the gate. Container
# side (ubuntu:24.04 arm64, matches the ubuntu-24.04-arm runner): clones both
# bundles into an empty dir, installs Flutter + the leg's provision deps, then
# runs every `python3 scripts/ci.py ...` line of ci.yml's `build` job (plus the
# `verify` job's selftest/verify), derived FROM the workflow, not mirrored.
#
# Usage: scripts/local_gate_linux_arm.sh [TARGET=linux-arm] [OUT_DIR]
# Exit: 0 all steps green | 3 BLOCKED at the ceyx-prebuilt fetch boundary (pin has
#       no linux-arm64 entry yet; everything before it ran green) | 1 a step failed.
# Resume after the ceyx release + repin: commit the pin, rerun this script.
# Every step's exit code is captured as RC=$? inside $OUT_DIR/gate.log.
set -uo pipefail
TARGET="${1:-linux-arm}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CEYX="${CEYX_DIR:-$REPO/../ceyx}"
OUT="${2:-$REPO/docs/logs/gate-linux-arm-$(date +%Y%m%d-%H%M%S)}"
PIN_KEY="${PIN_KEY:-linux-arm64}"          # key expected in scripts/ceyx_release_pin.json
FLUTTER_VER="${FLUTTER_VER:-3.44.6}"       # same as ci.yml flutter-version
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
CEYX_REF="$(git -C "$REPO" show HEAD:.github/workflows/ci.yml | awk '/repository: jhangyu\/ceyx/{f=1} f&&/ref:/{print $2; exit}')"
[ -n "$CEYX_REF" ] || { echo "cannot derive ceyx ref from ci.yml" >&2; exit 1; }
git -C "$REPO" bundle create "$OUT/halcyon.bundle" HEAD >/dev/null 2>&1 || { echo "halcyon bundle failed" >&2; exit 1; }
git -C "$CEYX" bundle create "$OUT/ceyx.bundle" --all >/dev/null 2>&1 || { echo "ceyx bundle failed" >&2; exit 1; }
echo "HALCYON_HEAD=$(git -C "$REPO" rev-parse HEAD) CEYX_REF=$CEYX_REF TARGET=$TARGET" | tee "$OUT/gate.log"

docker run --rm --platform linux/arm64 -v "$OUT:/in:ro" -v "$OUT:/out" \
  -e TARGET="$TARGET" -e PIN_KEY="$PIN_KEY" -e CEYX_REF="$CEYX_REF" -e FLUTTER_VER="$FLUTTER_VER" \
  -e PYTHONUTF8=1 -e CI=true ubuntu:24.04 bash -c '
set -u
LOG=/out/gate.log
step() { # step NAME cmd...
  local n="$1"; shift; echo "=== STEP $n: $*" >>$LOG
  "$@" >>/out/step-$n.log 2>&1; local RC=$?; echo "RC=$RC step=$n" >>$LOG; return $RC; }
fail() { echo "GATE_RESULT=FAIL at $1" >>$LOG; exit 1; }
uname -m >>$LOG
step apt-base bash -c "apt-get update && apt-get install -y --no-install-recommends git ca-certificates curl xz-utils unzip zip python3 sudo clang cmake ninja-build pkg-config libgtk-3-dev libglu1-mesa" || fail apt-base
W=$(mktemp -d /work.XXXX); cd $W
step clone-halcyon git clone /in/halcyon.bundle Halcyon || fail clone-halcyon
step clone-ceyx git clone /in/ceyx.bundle ceyx || fail clone-ceyx
step ceyx-ref git -C ceyx checkout --detach $CEYX_REF || fail ceyx-ref
git config --global --add safe.directory "*"
cd Halcyon
# Derive the step list from the workflow: verify-job selftest+verify, then the build job ci.py lines.
grep -oE "run: python3 scripts/ci.py .*" .github/workflows/ci.yml | sed "s/^run: //" | grep -v auto-release >/out/derived-steps.txt
grep -q -- "--target \${{ matrix.target }}\|{target: $TARGET}" .github/workflows/ci.yml && echo "WORKFLOW_HAS_LEG=$TARGET" >>$LOG || echo "WARN workflow has no $TARGET leg yet (steps rendered with TARGET override)" >>$LOG
# Flutter comes from CI'"'"'s own source: `ci.py provision` (runs first; emulates $GITHUB_PATH).
export GITHUB_PATH=/out/github_path; : >$GITHUB_PATH
prov="python3 scripts/ci.py provision --target $TARGET"
step "$(echo "$prov" | tr -c "a-zA-Z0-9\n" _)" $prov || fail "$prov"
[ -s $GITHUB_PATH ] && export PATH="$(tac $GITHUB_PATH | paste -sd: -):$PATH"
echo "PATH_AFTER_PROVISION=$PATH" >>$LOG
while read -r line; do
  cmd=${line//\$\{\{ matrix.target \}\}/$TARGET}
  case "$cmd" in
    *"ci.py provision "*) continue;;
    *"ci.py build "*|*"ci.py assert-capabilities "*)
      if ! grep -q "\"$PIN_KEY\"" scripts/ceyx_release_pin.json; then
        echo "BLOCKED_AT_FETCH: pin has no \"$PIN_KEY\" entry; ceyx arm64 release missing. Resume: repin, commit, rerun gate." >>$LOG
        echo "GATE_RESULT=BLOCKED_ON_CEYX_RELEASE" >>$LOG; exit 3; fi;;
  esac
  step "$(echo "$cmd" | tr -c "a-zA-Z0-9\n" _)" $cmd || fail "$cmd"
done </out/derived-steps.txt
echo "GATE_RESULT=PASS" >>$LOG'
RC=$?
echo "CONTAINER_RC=$RC" | tee -a "$OUT/gate.log"
echo "artifact: $OUT/gate.log"
exit $RC
