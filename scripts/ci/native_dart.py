"""Make the Flutter SDK's Dart VM the runner's NATIVE architecture, or fail.

Flutter picks its Windows build target from the Dart VM's own ABI, and
subosito/flutter-action installs an SDK whose Dart is x64 — so on an arm64
runner Flutter would silently build windows-x64 under emulation. Every fact
(stamp path, refresh command, expected ABI string, dart path) arrives as argv
from targets.py (G-5); this file names no platform. Stdlib only, run as a
script: ``native_dart.py --stamp S --dart D --expect ABI -- <refresh cmd>``.
``{flutter_root}`` in any argument is replaced by the SDK root, found from
FLUTTER_ROOT or from ``flutter`` on PATH (<root>/bin/flutter).
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path


def flutter_root():
    env = os.environ.get("FLUTTER_ROOT")
    if env:
        return Path(env)
    found = shutil.which("flutter")
    if not found:
        raise SystemExit("ERROR: cannot locate the Flutter SDK (no FLUTTER_ROOT, no flutter on PATH)")
    return Path(found).resolve().parent.parent


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--stamp", required=True, help="SDK-relative engine stamp to delete (forces the refresh)")
    p.add_argument("--dart", required=True, help="SDK-relative dart executable")
    p.add_argument("--expect", required=True, help="substring `dart --version` must contain")
    p.add_argument("refresh", nargs=argparse.REMAINDER, help="-- <refresh command>")
    a = p.parse_args(argv)
    cmd = [c for c in a.refresh if c != "--"]
    if not cmd:
        raise SystemExit("ERROR: no refresh command given after --")
    root = flutter_root()
    cmd = [c.replace("{flutter_root}", str(root)) for c in cmd]
    stamp = root / a.stamp
    if stamp.exists():
        stamp.unlink()
        print(f"removed {stamp}")
    rc = subprocess.run(cmd).returncode
    if rc != 0:
        print(f"ERROR: refresh command exited {rc}: {cmd!r}", file=sys.stderr)
        return rc
    out = subprocess.run([str(root / a.dart), "--version"], capture_output=True, text=True)
    text = out.stdout + out.stderr
    print(text.strip())
    if a.expect not in text:
        print(f"ERROR: Dart VM is not {a.expect!r} after refresh; Flutter would build "
              "for the wrong architecture.", file=sys.stderr)
        return 1
    print(f"NATIVE-DART-OK: {a.expect}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
