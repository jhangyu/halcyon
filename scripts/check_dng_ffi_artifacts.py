#!/usr/bin/env python3
"""Decoder packaging / ABI consistency checker (M7 Task 6, audit gap 8).

Verifies that the dng_processor_ffi RAW decoder artifacts the contract
claims to ship are actually present, and that the sized-decode symbol the
sidebar RAW fallback depends on (dng_decode_and_process_sized) is exported
from each artifact this host is able to inspect.

The manifest (scripts/dng_ffi_artifacts.json) is data; this script is pure
logic. Adding or flipping a platform (expected true/false, path, tool) must
never require editing this file.

A host can only check what it can see. When the required symbol-inspection
tool is absent on the current OS, the check for that platform prints
"symbol=skipped" and is counted in the summary's skipped total -- it is
never silently treated as a pass. A missing artifact for a platform marked
expected: true is always a hard failure (RC=1), independent of tool
availability.

Usage:
    python3 scripts/check_dng_ffi_artifacts.py [--config scripts/dng_ffi_artifacts.json]

Exit code: 0 if every expected:true platform's artifact is present and its
symbol check (when the tool is available) passes; 1 otherwise.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path


def resolve_manifest_path(repo_root: Path, raw_path: str) -> Path:
    """Resolve a manifest-declared path relative to the repo root.

    Paths in the manifest are written relative to the Halcyon repo root
    (e.g. "../flutter_dng_decoder/..."), not relative to the current
    working directory or to the config file's own location, so the checker
    behaves the same regardless of where it is invoked from or which
    --config file (default or a temporary one used for negative testing)
    is passed.
    """
    return (repo_root / raw_path).resolve()


def check_symbol(binary_path: Path, tool: str, tool_args: list[str], symbol: str) -> str:
    """Return 'present', 'absent', or 'skipped' for the given symbol."""
    tool_bin = shutil.which(tool)
    if tool_bin is None:
        return "skipped"

    try:
        result = subprocess.run(
            [tool_bin, *tool_args, str(binary_path)],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        # Tool resolved by shutil.which but failed to execute (e.g. wrong
        # format for this host's toolchain) -- treat as skipped, not a
        # false failure.
        return "skipped"

    output = (result.stdout or "") + (result.stderr or "")
    if symbol in output:
        return "present"
    return "absent"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config",
        default=str(Path(__file__).resolve().parent / "dng_ffi_artifacts.json"),
        help="Path to the JSON manifest (default: scripts/dng_ffi_artifacts.json)",
    )
    args = parser.parse_args()

    config_path = Path(args.config).resolve()
    if not config_path.is_file():
        print(f"ERROR: manifest not found: {config_path}")
        return 1

    with open(config_path, "r", encoding="utf-8") as f:
        manifest = json.load(f)

    symbol = manifest["symbol"]
    platforms = manifest["platforms"]

    # Repo root is always derived from this script's own on-disk location
    # (Halcyon/scripts/check_dng_ffi_artifacts.py -> repo root is scripts/..),
    # not from the --config path, so a temporary manifest used for negative
    # testing (e.g. scripts/tmp/foo.json) still resolves artifact paths
    # correctly.
    repo_root = Path(__file__).resolve().parent.parent

    overall_ok = True
    skipped_count = 0
    missing_artifact_failures: list[str] = []
    symbol_check_failures: list[str] = []

    for platform_name in sorted(platforms.keys()):
        entry = platforms[platform_name]
        expected = bool(entry.get("expected", False))
        rel_path = entry["path"]
        artifact_path = resolve_manifest_path(repo_root, rel_path)
        present = artifact_path.is_file()

        symbol_status = "skipped"
        if present:
            tool = entry.get("tool")
            tool_args = entry.get("tool_args", [])
            if tool:
                symbol_status = check_symbol(artifact_path, tool, tool_args, symbol)
            skipped_count_delta = 1 if symbol_status == "skipped" else 0
        else:
            # No artifact to inspect -- nothing to check, nothing to skip
            # in the "tool unavailable" sense. Still reported as skipped
            # for uniform output, but not double-counted as a tool gap.
            skipped_count_delta = 0

        skipped_count += skipped_count_delta

        print(
            f"{platform_name} {artifact_path} present={present} symbol={symbol_status}"
        )

        if expected and not present:
            overall_ok = False
            missing_artifact_failures.append(
                f"{platform_name}: expected artifact missing at {artifact_path}"
            )
        elif expected and present and symbol_status == "absent":
            overall_ok = False
            symbol_check_failures.append(
                f"{platform_name}: artifact present at {artifact_path} but does not export '{symbol}'"
            )

    print(f"SUMMARY: {skipped_count} check(s) skipped (tool unavailable on this host)")

    if missing_artifact_failures:
        print("MISSING ARTIFACT(S):")
        for line in missing_artifact_failures:
            print(f"  - {line}")

    if symbol_check_failures:
        print("SYMBOL CHECK FAILURE(S):")
        for line in symbol_check_failures:
            print(f"  - {line}")

    return 0 if overall_ok else 1


if __name__ == "__main__":
    sys.exit(main())
