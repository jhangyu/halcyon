#!/bin/bash
# Capture the machine state WHILE app switching is stuck (Dock + Cmd-Tab dead).
# Run this from a terminal that is already open; do not try to click anything
# first -- the point is to catch the stuck state, not the recovered one.
#
#   bash scripts/focus_forensics.sh            # writes docs/logs/<date>/focus-stuck-<time>.txt
#
# The three questions it answers, in order of what would change the diagnosis:
#   1. Is input captured system-wide (secure input) rather than by Halcyon?
#   2. Is Halcyon's main thread inside a tracking/modal loop?
#   3. Is there more than one Halcyon process / a stale bundle?
set -u
out_dir="docs/logs/$(date +%Y-%m-%d)"
mkdir -p "$out_dir"
out="$out_dir/focus-stuck-$(date +%H%M%S).txt"

{
  echo "=== date ==="; date
  echo; echo "=== frontmost app (lsappinfo) ==="
  front=$(lsappinfo front)
  echo "asn: $front"; lsappinfo info -only name -only pid "$front"

  echo; echo "=== secure input holder (0 = nobody) ==="
  # Non-zero means some process has grabbed keyboard input globally, which is
  # the one cause that would kill Cmd-Tab for every app, not just this one.
  ioreg -l -w 0 | grep -i 'kCGSSessionSecureInputPID' || echo '(no secure input entry)'

  echo; echo "=== Halcyon processes ==="
  pgrep -fl 'Halcyon.app/Contents/MacOS/Halcyon' || echo '(none running)'

  echo; echo "=== windows owned by Halcyon (level/onscreen) ==="
  osascript -e 'tell application "System Events" to tell process "Halcyon" to get {name, value of attribute "AXMain"} of windows' 2>&1

  echo; echo "=== main-thread stack sample (3s) ==="
  pid=$(pgrep -f 'Halcyon.app/Contents/MacOS/Halcyon' | head -1)
  if [ -n "${pid:-}" ]; then
    sample "$pid" 3 -mayDie 2>&1 | sed -n '1,120p'
  else
    echo '(no pid)'
  fi

  echo; echo "=== recent WindowServer / activation log (60s) ==="
  log show --last 60s --predicate 'process == "WindowServer" OR subsystem == "com.apple.activation"' --style compact 2>&1 | tail -60
} >"$out" 2>&1

echo "wrote $out"
