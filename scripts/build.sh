#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-macos}"
MODE="${BUILD_MODE:-release}"

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/build.sh [target] [--debug|--profile|--release]

Targets:
  macos       Build the macOS app. Default target.
  android     Build an Android APK.
  android-apk Build an Android APK.
  android-aab Build an Android App Bundle.
  web         Build the web app.
  windows     Build the Windows desktop app. Must run on Windows.
  linux       Build the Linux desktop app. Must run on Linux.
  all         Build all targets supported by the current host.

Examples:
  ./scripts/build.sh
  ./scripts/build.sh web
  ./scripts/build.sh android-aab --release
  BUILD_MODE=debug ./scripts/build.sh macos
USAGE
}

log() {
  printf '\n==> %s\n' "$1"
}

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

host_os() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux) echo "linux" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *) echo "unknown" ;;
  esac
}

supports_target() {
  local target="$1"
  local host
  host="$(host_os)"

  case "$target" in
    macos) [[ "$host" == "macos" ]] ;;
    windows) [[ "$host" == "windows" ]] ;;
    linux) [[ "$host" == "linux" ]] ;;
    android|android-apk|android-aab|web) return 0 ;;
    *) return 1 ;;
  esac
}

build_target() {
  local target="$1"

  if ! supports_target "$target"; then
    fail "'$target' build is not supported on this host ($(host_os))."
  fi

  case "$target" in
    macos)
      log "Building macOS app ($MODE)"
      flutter build macos "--$MODE"
      ;;
    android|android-apk)
      log "Building Android APK ($MODE)"
      flutter build apk "--$MODE"
      ;;
    android-aab)
      log "Building Android App Bundle ($MODE)"
      flutter build appbundle "--$MODE"
      ;;
    web)
      log "Building web app ($MODE)"
      flutter build web "--$MODE"
      ;;
    windows)
      log "Building Windows app ($MODE)"
      flutter build windows "--$MODE"
      ;;
    linux)
      log "Building Linux app ($MODE)"
      flutter build linux "--$MODE"
      ;;
    *)
      usage
      fail "Unknown build target '$target'."
      ;;
  esac
}

build_all() {
  local target
  local targets=(macos android-apk web windows linux)

  for target in "${targets[@]}"; do
    if supports_target "$target"; then
      build_target "$target"
    else
      log "Skipping $target build on $(host_os)"
    fi
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --debug)
      MODE="debug"
      shift
      ;;
    --profile)
      MODE="profile"
      shift
      ;;
    --release)
      MODE="release"
      shift
      ;;
    macos|android|android-apk|android-aab|web|windows|linux|all)
      TARGET="$1"
      shift
      ;;
    *)
      usage
      fail "Unknown argument '$1'."
      ;;
  esac
done

command -v flutter >/dev/null 2>&1 || fail "Flutter is not available in PATH."

cd "$ROOT_DIR"

log "Resolving Flutter dependencies"
flutter pub get

if [[ "$TARGET" == "all" ]]; then
  build_all
else
  build_target "$TARGET"
fi

log "Build script completed"
