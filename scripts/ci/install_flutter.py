"""Install the Flutter SDK from git, for runners where flutter-action cannot.

subosito/flutter-action selects the SDK by runner architecture, and Flutter
publishes no Linux arm64 SDK archive, so the arm leg clones the tag instead.
All facts (tag, destination) arrive as argv from targets.py (G-5); this file
names no platform. Stdlib only, run as a script:
``install_flutter.py --tag 3.44.6 --dest ~/flutter``. Appends <dest>/bin to
$GITHUB_PATH when set (later workflow steps see it) and bootstraps with an
absolute-path ``flutter --version``.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

REPO = "https://github.com/flutter/flutter.git"


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--tag", required=True)
    p.add_argument("--dest", required=True)
    a = p.parse_args(argv)
    dest = Path(a.dest).expanduser().resolve()
    if not dest.exists():
        rc = subprocess.run(["git", "clone", "--depth", "1", "-b", a.tag, REPO, str(dest)]).returncode
        if rc != 0:
            print(f"ERROR: git clone of flutter {a.tag} failed (rc {rc})", file=sys.stderr)
            return rc
    bindir = dest / "bin"
    gh_path = os.environ.get("GITHUB_PATH")
    if gh_path:
        with open(gh_path, "a", encoding="utf-8") as f:
            f.write(f"{bindir}\n")
    out = subprocess.run([str(bindir / "flutter"), "--version"], capture_output=True, text=True)
    print((out.stdout + out.stderr).strip())
    if out.returncode != 0 or a.tag not in out.stdout + out.stderr:
        print(f"ERROR: flutter --version did not report {a.tag} (rc {out.returncode})", file=sys.stderr)
        return 1
    print(f"FLUTTER-INSTALL-OK: {a.tag} at {dest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
