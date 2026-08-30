"""provision / verify / build / package / release-preflight / print-plan.

Frozen interface: Plan_ci_rewrite.md §2 (WP-B). G-5: this file must contain no
target-name or platform-name equality branching — every per-platform fact is
read from ``targets.spec(target)``.

``build()`` and ``print_plan()`` share the same argv-rendering helper
(``_build_argv``) so a build flag can never drift between what CI executes and
what ``--print-plan`` prints for a target with no matching runner on hand
(Spec §4.8).
"""

from __future__ import annotations

import os
import sys
import tarfile
import zipfile
from pathlib import Path

from . import report, run, targets


def _build_argv(repo_root: Path, target: str) -> list:
    """Renders the exact argv `build()` execs: `build_apps.py` is the single
    build entry point (CLAUDE.md); this never reimplements it, only calls it."""
    spec = targets.spec(target)
    build_apps = os.fspath(Path(repo_root, "scripts", "build_apps.py").resolve())
    return ["python3", build_apps, target, *spec["build_flags"]]


def provision(repo_root: Path, target: str) -> int:
    spec = targets.spec(target)
    commands = spec["provision"]
    if not commands:
        return 0
    log_path = report.log_path_for(repo_root, target, "provision")
    headers = []
    bodies = []
    rc = 0
    for argv in commands:
        # targets.py's frozen schema (Plan §2) carries no explicit cwd field.
        # `pod install` is only ever invoked from <repo_root>/macos (ci.yml:121-123);
        # every other provisioning command runs from repo_root. This branches on
        # the *command itself*, not on `target`/`platform` (G-5's forbidden forms).
        cwd = (repo_root / "macos") if argv[:1] == ["pod"] else repo_root
        result = run.run(list(argv), cwd=cwd)
        headers.append(" ".join(argv))
        bodies.append(result.stdout + result.stderr)
        if result.returncode != 0:
            rc = result.returncode
    report.write_log(log_path, header="\n".join(headers), body="\n".join(bodies), rc=rc)
    return rc


def verify(repo_root: Path) -> int:
    """flutter pub get -> analyze -> test -j 1. All three ALWAYS run; failures
    accumulate; one non-zero exit at the end (R-4: an analyze failure must not
    hide a test failure)."""
    steps = [
        ("pub-get", ["flutter", "pub", "get"]),
        ("analyze", ["flutter", "analyze"]),
        ("test", ["flutter", "test", "-j", "1"]),
    ]
    failed = []
    for phase, argv in steps:
        log_path = report.log_path_for(repo_root, "host", phase)
        result = run.run_logged(argv, log_path, cwd=repo_root)
        if result.returncode != 0:
            failed.append(phase)
    print(report.summary("host", len(steps), len(failed)))
    return 0 if not failed else 1


def build(repo_root: Path, target: str, mode: str = "release") -> int:
    """Thin delegator to scripts/build_apps.py. Exit code 2 (colour-gate
    refusal) is propagated as a failure, not swallowed (G-7)."""
    targets.spec(target)  # KeyError on an unknown target before any I/O.
    argv = _build_argv(repo_root, target)
    if mode != "release":
        argv.append(f"--{mode}")
    log_path = report.log_path_for(repo_root, target, "build")
    result = run.run_logged(argv, log_path, cwd=repo_root)
    return result.returncode


def package(repo_root: Path, target: str, version: str) -> int:
    """Resolves artifact_path, produces archive_name via zipfile/tarfile. One
    implementation replaces ditto/Compress-Archive/tar for all three platforms."""
    spec = targets.spec(target)
    kind = spec["artifact_kind"]
    raw_path = spec["artifact_path"]

    if kind == "glob_dir":
        matches = sorted(repo_root.glob(raw_path))
        if not matches:
            print(f"ERROR: no artifact matched {raw_path}", file=sys.stderr)
            return 1
        artifact = matches[0]
    else:
        artifact = repo_root / raw_path

    if not artifact.exists():
        print(f"ERROR: no artifact matched {raw_path}", file=sys.stderr)
        return 1

    archive_name = spec["archive_name"].format(version=version)
    archive_path = Path(repo_root, archive_name).resolve()
    archive_format = spec["archive_format"]

    if archive_format == "zip":
        # app_bundle: entries relative to the bundle's PARENT, so every member
        # is prefixed "<Bundle>.app/" — equivalent to `ditto --keepParent`.
        # dir: entries relative to the directory ITSELF (no prefix) —
        # equivalent to `Compress-Archive -Path <dir>/*`.
        base = artifact.parent if kind == "app_bundle" else artifact
        with zipfile.ZipFile(os.fspath(archive_path), "w", zipfile.ZIP_DEFLATED) as zf:
            for file_path in sorted(artifact.rglob("*")):
                if file_path.is_file():
                    zf.write(file_path, os.fspath(file_path.relative_to(base)))
    elif archive_format == "gztar":
        # Equivalent to `tar -C "$(dirname "$bundle_dir")" bundle`.
        with tarfile.open(os.fspath(archive_path), "w:gz") as tf:
            tf.add(os.fspath(artifact), arcname="bundle")
    else:
        print(f"ERROR: unknown archive_format {archive_format!r}", file=sys.stderr)
        return 1

    print(f"PACKAGE-OK: {os.fspath(archive_path)}")
    return 0


def release_preflight(repo_root: Path, version: str, targets_list) -> int:
    """Asserts each expected archive exists at the exact path action-gh-release
    globs; prints it. This IS the release.yml verification (contract: 'release
    tag 實發' out of scope)."""
    missing = []
    for target in targets_list:
        spec = targets.spec(target)
        archive_name = spec["archive_name"].format(version=version)
        archive_path = Path(repo_root, archive_name).resolve()
        if archive_path.is_file():
            size = archive_path.stat().st_size
            print(f"PREFLIGHT-OK: {os.fspath(archive_path)} {size} bytes")
        else:
            missing.append(os.fspath(archive_path))
    if missing:
        for path in missing:
            print(f"ERROR: missing archive {path}", file=sys.stderr)
        return 1
    return 0


def print_plan(repo_root: Path, target: str) -> int:
    """Prints rendered argv for provision/build/package without executing
    anything (Spec §4.8) — the whole point is rendering Windows argv from a
    macOS laptop."""
    spec = targets.spec(target)
    for argv in spec["provision"]:
        print(f"PLAN provision: {list(argv)!r}")
    print(f"PLAN build: {_build_argv(repo_root, target)!r}")
    archive_name = spec["archive_name"].format(version="{version}")
    package_desc = {
        "artifact_kind": spec["artifact_kind"],
        "artifact_path": spec["artifact_path"],
        "archive_name": archive_name,
        "archive_format": spec["archive_format"],
    }
    print(f"PLAN package: {package_desc!r}")
    return 0
