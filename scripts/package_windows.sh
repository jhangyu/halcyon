#!/usr/bin/env bash
#
# package_windows.sh — build the one-zip Windows hand-off pack.
#
# Produces a single zip containing the committed source of BOTH repos as
# siblings, plus the one-click Windows build script:
#
#   <zip root>/
#     build_windows.ps1
#     build_windows.py
#     README_WINDOWS.md
#     Halcyon/
#     flutter_dng_decoder/
#
# The sibling layout is load-bearing: Halcyon/pubspec.yaml depends on
# ../flutter_dng_decoder/dng_processor_ffi by relative path.
#
# Source selection is `git archive HEAD` in each repo, i.e. committed content
# only. That automatically excludes build trees, local_data/, untracked scratch
# files, .git/ itself, and anything another session has in flight but not yet
# committed. Uncommitted tracked changes are reported as a warning below so it
# is obvious what is NOT in the zip.
#
# Usage:
#   ./scripts/package_windows.sh [--out DIR] [--decoder DIR]
#
set -euo pipefail

HALCYON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DECODER_DIR="$(cd "$HALCYON_DIR/.." && pwd)/flutter_dng_decoder"
OUT_DIR="$(pwd)"

# Committed paths that are scratch/artifacts rather than build inputs. git
# archive would carry them (they are tracked for historical reasons), so they
# are pruned from the staging tree explicitly. Paths are relative to the
# staged Halcyon/ or flutter_dng_decoder/ root.
HALCYON_PRUNE=(
  "scripts/tmp"
  "local_data"
)
DECODER_PRUNE=(
  "dng_processor/native/scripts/tmp"
  "local_data"
)

log() {
  printf '\n==> %s\n' "$1"
}

step() {
  printf '    %s\n' "$1"
}

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/package_windows.sh [--out DIR] [--decoder DIR]

Options:
  --out DIR       Where to write the zip (default: current directory).
  --decoder DIR   Path to the flutter_dng_decoder checkout
                  (default: sibling of this repo).
  -h, --help      This message.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --out)
      [ $# -ge 2 ] || fail "--out needs a directory"
      OUT_DIR="$2"
      shift 2
      ;;
    --decoder)
      [ $# -ge 2 ] || fail "--decoder needs a directory"
      DECODER_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      fail "unknown argument: $1"
      ;;
  esac
done

command -v git >/dev/null 2>&1 || fail "git not found on PATH"
command -v zip >/dev/null 2>&1 || fail "zip not found on PATH"

[ -d "$DECODER_DIR" ] || fail "decoder repo not found: $DECODER_DIR (pass --decoder DIR)"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

PS1_SRC="$HALCYON_DIR/scripts/windows/build_windows.ps1"
PY_SRC="$HALCYON_DIR/scripts/windows/build_windows.py"
README_SRC="$HALCYON_DIR/scripts/windows/README_WINDOWS.md"
[ -f "$PS1_SRC" ] || fail "missing $PS1_SRC"
[ -f "$README_SRC" ] || fail "missing $README_SRC"
[ -f "$PY_SRC" ] || fail "missing $PY_SRC"

# Refuse to run if either HEAD is unreadable (empty repo, corrupt objects,
# detached nothing) — a half-populated zip is worse than no zip.
read_head() {
  local dir="$1"
  git -C "$dir" rev-parse --verify HEAD 2>/dev/null \
    || fail "cannot read HEAD in $dir — is it a git repo with at least one commit?"
}

HALCYON_HEAD="$(read_head "$HALCYON_DIR")"
DECODER_HEAD="$(read_head "$DECODER_DIR")"

log "Source repositories"
step "Halcyon:              $HALCYON_DIR @ ${HALCYON_HEAD:0:12}"
step "flutter_dng_decoder:  $DECODER_DIR @ ${DECODER_HEAD:0:12}"

# Warn about tracked-but-uncommitted work: it will NOT be in the zip.
warn_dirty() {
  local dir="$1"
  local name="$2"
  local dirty
  dirty="$(git -C "$dir" status --porcelain --untracked-files=no)"
  if [ -n "$dirty" ]; then
    log "WARNING: $name has uncommitted tracked changes — these are NOT in the zip"
    printf '%s\n' "$dirty" | sed 's/^/    /'
  fi
}

warn_dirty "$HALCYON_DIR" "Halcyon"
warn_dirty "$DECODER_DIR" "flutter_dng_decoder"

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/halcyon-winpack.XXXXXX")"
cleanup() {
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

log "Staging committed source"
mkdir -p "$STAGE_DIR/Halcyon" "$STAGE_DIR/flutter_dng_decoder"
git -C "$HALCYON_DIR" archive HEAD | tar -x -C "$STAGE_DIR/Halcyon"
git -C "$DECODER_DIR" archive HEAD | tar -x -C "$STAGE_DIR/flutter_dng_decoder"
step "Halcyon:             $(find "$STAGE_DIR/Halcyon" -type f | wc -l | tr -d ' ') files"
step "flutter_dng_decoder: $(find "$STAGE_DIR/flutter_dng_decoder" -type f | wc -l | tr -d ' ') files"

prune() {
  local root="$1"
  shift
  local rel
  for rel in "$@"; do
    if [ -e "$root/$rel" ]; then
      rm -rf "${root:?}/$rel"
      step "pruned $(basename "$root")/$rel"
    fi
  done
}

log "Pruning committed scratch paths"
prune "$STAGE_DIR/Halcyon" "${HALCYON_PRUNE[@]}"
prune "$STAGE_DIR/flutter_dng_decoder" "${DECODER_PRUNE[@]}"

log "Adding the one-click Windows script"
cp "$PS1_SRC" "$STAGE_DIR/build_windows.ps1"
cp "$PY_SRC" "$STAGE_DIR/build_windows.py"
cp "$README_SRC" "$STAGE_DIR/README_WINDOWS.md"
{
  printf '\n---\n\n'
  printf 'Packed %s from:\n\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
  printf -- '- Halcyon @ %s\n' "$HALCYON_HEAD"
  printf -- '- flutter_dng_decoder @ %s\n' "$DECODER_HEAD"
} >> "$STAGE_DIR/README_WINDOWS.md"
step "build_windows.ps1 + build_windows.py + README_WINDOWS.md at zip root"

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
ZIP_PATH="$OUT_DIR/halcyon-windows-pack-$TIMESTAMP.zip"

log "Creating zip"
( cd "$STAGE_DIR" && zip -q -r -X "$ZIP_PATH" . )
[ -f "$ZIP_PATH" ] || fail "zip was not created at $ZIP_PATH"

ENTRY_COUNT="$(unzip -Z1 "$ZIP_PATH" | wc -l | tr -d ' ')"
ZIP_SIZE="$(du -h "$ZIP_PATH" | cut -f1 | tr -d ' ')"

log "Done"
step "zip:      $ZIP_PATH"
step "size:     $ZIP_SIZE"
step "entries:  $ENTRY_COUNT"
step "top level:"
unzip -Z1 "$ZIP_PATH" | awk -F/ '{ if ($1 == "" ) next; if (NF > 1) print $1"/"; else print $1 }' \
  | sort -u | sed 's/^/      /'
step "sources:  Halcyon @ ${HALCYON_HEAD:0:12}, flutter_dng_decoder @ ${DECODER_HEAD:0:12}"
step "next:     copy the zip to the Windows laptop, extract, read README_WINDOWS.md,"
step "          then run build_windows.py (no Native Tools prompt needed) or"
step "          build_windows.ps1 from an x64 Native Tools Command Prompt."
