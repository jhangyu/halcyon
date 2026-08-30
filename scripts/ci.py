#!/usr/bin/env python3
"""Halcyon unified CI entry point — argparse dispatch only.

Every CI/release job body is one `python3 scripts/ci.py <subcommand>` line, and
the same command is runnable on a laptop. All logic lives in `scripts/ci/`:

    targets.py   pure data — the only place a per-platform fact is stated
    run.py       list-argv subprocess wrapper (shell=False, RC self-capture)
    phases.py    provision / verify / build / package / release-preflight
    assertions.py the R-7 capability suite
    report.py    artifact logs + machine-checkable summary lines

Frozen CLI surface (workflows depend on these exact strings):

    python3 scripts/ci.py provision           --target T
    python3 scripts/ci.py verify
    python3 scripts/ci.py build               --target T [--mode release]
    python3 scripts/ci.py assert-capabilities --target T
    python3 scripts/ci.py package             --target T --version V
    python3 scripts/ci.py release-preflight   --version V --target T [--target T2 ...]
    python3 scripts/ci.py --print-plan        --target T

If a function in this file grows past 15 lines it belongs in phases.py.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

# Repo root is derived from this script's own on-disk location, never from the
# invocation cwd — the same pattern check_dng_ffi_artifacts.py:98-103 uses, so
# behaviour is identical whether CI runs from Halcyon/ or from the workspace root.
REPO_ROOT = Path(__file__).resolve().parent.parent

sys.path.insert(0, os.fspath(REPO_ROOT / "scripts"))


def check_ceyx_sibling(repo_root):
    """Spec §5.1: the single most likely first-round CI failure. Fail with a named
    error instead of an opaque `flutter pub get` resolution error."""
    plugin = (repo_root.parent / "ceyx" / "plugin").resolve()
    if not plugin.is_dir():
        print(f"ERROR: sibling ceyx checkout not found at {os.fspath(plugin)}", file=sys.stderr)
        return 1
    return 0


def check_python_interpreter():
    """Spec §4.7.3: an MSYS python on Windows reintroduces the whole path-mangling
    family through the back door. Refuse it up front."""
    if os.name != "nt":
        return 0
    exe = sys.executable
    if not Path(exe).drive or "/usr/bin" in exe:
        print(f"ERROR: MSYS-style Python interpreter refused on Windows: {exe}", file=sys.stderr)
        return 1
    return 0


def build_parser():
    p = argparse.ArgumentParser(prog="ci.py", description="Halcyon unified CI entry point")
    p.add_argument("--print-plan", action="store_true",
                   help="print the rendered argv for provision/build/package without executing")
    p.add_argument("--target", help="target name (used with --print-plan)")
    sub = p.add_subparsers(dest="command")
    _add_target_command(sub, "provision", "run the target's provisioning steps")
    sub.add_parser("verify", help="flutter pub get -> analyze -> test -j 1 (all three always run)")
    b = _add_target_command(sub, "build", "delegate to scripts/build_apps.py")
    b.add_argument("--mode", default="release")
    _add_target_command(sub, "assert-capabilities", "run the R-7 capability assertion suite")
    pk = _add_target_command(sub, "package", "produce the release archive")
    pk.add_argument("--version", required=True)
    rp = sub.add_parser("release-preflight", help="assert every expected archive exists")
    rp.add_argument("--version", required=True)
    rp.add_argument("--target", action="append", required=True, dest="targets")
    return p


def _add_target_command(sub, name, help_text):
    sp = sub.add_parser(name, help=help_text)
    sp.add_argument("--target", required=True)
    return sp


def dispatch(args):
    import ci.phases as phases
    if args.print_plan:
        return phases.print_plan(REPO_ROOT, args.target)
    if args.command == "provision":
        return phases.provision(REPO_ROOT, args.target)
    if args.command == "verify":
        return phases.verify(REPO_ROOT)
    if args.command == "build":
        return phases.build(REPO_ROOT, args.target, args.mode)
    if args.command == "assert-capabilities":
        import ci.assertions as assertions
        return assertions.run_suite(REPO_ROOT, args.target)
    if args.command == "package":
        return phases.package(REPO_ROOT, args.target, args.version)
    return phases.release_preflight(REPO_ROOT, args.version, args.targets)


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.print_plan:
        if not args.target:
            parser.error("--print-plan requires --target")
        return dispatch(args)
    if args.command is None:
        parser.print_help()
        return 2
    rc = check_python_interpreter() or check_ceyx_sibling(REPO_ROOT)
    if rc:
        return rc
    return dispatch(args)


if __name__ == "__main__":
    sys.exit(main())
