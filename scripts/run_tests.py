#!/usr/bin/env python3
"""Halcyon unified test entry point — sharded `flutter test` runner.

WHY THIS EXISTS
---------------
`flutter test` over the whole suite has outgrown the foreground command timeout
(150 s). The fix is NOT a longer timeout — it is sharding: the suite is split
into shards, each measured to complete well under the cap, and each shard is a
separate child process with its own artifact and its own self-captured exit
code. Agents run ONE SHARD PER BASH CALL (`--shard <name>`); a run without
`--shard` executes every shard sequentially (several minutes) and is for
humans at a terminal only.

This script deliberately does NOT reimplement anything already in `scripts/ci/`:

  * process execution      -> ci.run.run_logged   (shell=False, RC self-capture,
                              Windows .bat resolution, no `| grep`)
  * artifact + RC trailer  -> ci.report.write_log (last line is exactly `RC=<n>`)

CI runs no tests (CI is compile-only by project rule), so this script is the
only suite-level test gate. Shards run with `flutter test`'s default
concurrency: a serial run changes neither RC nor totals, only wall time, so
serial mode belongs to per-file timing attribution (with `--reporter json`),
never to a pass/fail gate.

USAGE
-----
    python3 scripts/run_tests.py --shard views     # one shard by name (agents: always this)
    python3 scripts/run_tests.py --shard 3         # one shard by 1-based index
    python3 scripts/run_tests.py --list            # shard table + TOTAL row, runs nothing
    python3 scripts/run_tests.py --audit-coverage  # every test file in exactly one shard
    python3 scripts/run_tests.py                   # every shard, in order (humans only)

Artifacts: build/ci-logs/tests-<shard>.txt, last line `RC=<n>`, written by the
producing process (2026-08-23: a harness notification lies in both directions).

Final line on stdout is exactly:

    TOTAL: <X> passed, <Y> failed, RC=<Z>

RC is non-zero if ANY shard failed. In `--shard` mode the same line is printed
for the single shard, so a one-shard invocation is still machine-checkable.
A broken shard table (see expand_shards) exits 2 before anything runs, in
every mode.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, os.fspath(REPO_ROOT / "scripts"))

from ci import report, run  # noqa: E402  (path bootstrap must precede import)


# ---------------------------------------------------------------------------
# Shard table — DATA, not logic. Membership is glob-derived, FIRST-MATCH-WINS:
# shards are expanded in order and a file belongs to the first shard whose
# entry matches it. Entry kinds:
#   * directory -> every *_test.dart underneath (recursive), minus files an
#                  earlier shard already claimed. This is how the catch-alls
#                  work: pipeline-misc names the whole image_pipeline
#                  directory and picks up every file no earlier glob claimed,
#                  so a NEW test file always lands in some shard.
#   * glob      -> REPO_ROOT.glob(entry), *_test.dart only. Zero matches is a
#                  hard error: a glob is a declared intent.
#   * file      -> a nonexistent path is a hard error; a file an earlier shard
#                  already claimed is a DUPLICATED hard error.
# A shard expanding to zero files is a hard error too. (2026-10-02: the old
# explicit lists silently dropped 55 deleted paths and orphaned 45 files for a
# month after the 0f61a49 consolidation — nothing may be dropped silently.)
#
# Budget: `flutter test` and this script are classified as BUILD commands by
# the global bash-safety hook, so the binding cap is the 150 s build allowance
# per Bash call. SHARD_BUDGET_S keeps 50 s of that cap as headroom; a shard
# over budget prints OVER-BUDGET — re-measure on an idle machine and, if it is
# genuinely slow, split that shard's globs (a data edit here). Each shard
# carries its last idle measurement as a `# measured` comment.
# ---------------------------------------------------------------------------

SHARD_BUDGET_S = 100

_PIPE = "test/services/image_pipeline/"

SHARDS = [
    {
        # measured 2026-10-02: 6.1s, load 19.16
        "name": "unit",
        "paths": ["test/*_test.dart", "test/models", "test/perf", "test/providers"],
    },
    {
        # measured 2026-10-02: 13.0s, load 10.46
        "name": "pipeline-decode",
        "paths": [_PIPE + g for g in (
            "dart_image_loader_*", "decode_*", "decoded_*", "deferred_*", "dng_*")],
    },
    {
        # measured 2026-10-02: 9.0s, load 8.87
        "name": "pipeline-preload",
        "paths": [_PIPE + g for g in ("image_preload_*", "sidebar_*", "pacing_*")],
    },
    {
        # measured 2026-10-02: 4.2s, load 9.47
        "name": "pipeline-payload",
        "paths": [_PIPE + g for g in (
            "payload_*", "encode_*", "exif_*", "frame_*", "yuv420_*", "q70_*",
            "publish_*", "pool_*", "stage_*")],
    },
    {
        # measured 2026-10-02: 12.4s, load 11.89
        "name": "pipeline-retention",
        "paths": [_PIPE + g for g in (
            "photo_source_*", "tier_two_*", "retention_*", "resolution_*")],
    },
    {
        # measured 2026-10-02: 14.7s, load 22.68
        # Catch-all: every image_pipeline test no glob above claimed.
        "name": "pipeline-misc",
        "paths": ["test/services/image_pipeline"],
    },
    {
        # measured 2026-10-02: 10.0s, load 27.72
        "name": "services",
        "paths": ["test/services/library", "test/services/platform", "test/services/rename"],
    },
    {
        # measured 2026-10-02: 4.7s, load 21.82
        "name": "views",
        "paths": ["test/views/*_test.dart"],
    },
    {
        # measured 2026-10-02: 12.7s, load 20.16
        # Catch-all for the layout directory (the old gallery/rest split
        # existed for a 40 s cap that never applied to this command).
        "name": "views-layout",
        "paths": ["test/views/layout"],
    },
]


def expand_shards(shards=None):
    """Ordered [(shard, files)] for the table; exits 2 on any table error.

    First-match-wins across the ordered list (see the table comment). Every
    error is collected and printed before exiting, so one run shows the whole
    damage instead of the first symptom.
    """
    shards = SHARDS if shards is None else shards
    claimed = {}
    errors = []
    expansion = []
    for shard in shards:
        name = shard["name"]
        files = []
        for entry in shard["paths"]:
            if "*" in entry:
                matches = sorted(
                    p for p in REPO_ROOT.glob(entry)
                    if p.is_file() and p.name.endswith("_test.dart"))
                if not matches:
                    errors.append(f"ZERO-MATCH: glob {entry} in shard {name} matches no test file")
                fresh = [p for p in matches if p not in claimed]
            else:
                target = REPO_ROOT / entry
                if target.is_dir():
                    fresh = [p for p in sorted(target.rglob("*_test.dart")) if p not in claimed]
                elif target.is_file():
                    if target in claimed:
                        errors.append(f"DUPLICATED: {entry} listed in shard {name} "
                                      f"but already claimed by {claimed[target]}")
                        fresh = []
                    else:
                        fresh = [target]
                else:
                    errors.append(f"MISSING: {entry} listed in shard {name}")
                    fresh = []
            for path in fresh:
                claimed[path] = name
            files.extend(fresh)
        if not files:
            errors.append(f"EMPTY: shard {name} expands to zero test files")
        expansion.append((shard, sorted(files)))
    if errors:
        for line in errors:
            print(line)
        sys.exit(2)
    return expansion


# ---------------------------------------------------------------------------
# Static declared-test count (the "declared" half of the declared-vs-executed
# check). 2026-08-17: `flutter test`'s progress line is overwritten in place, so
# the only way to know a whole file silently failed to load is to compare the
# count the source declares against the count the run reported.
# ---------------------------------------------------------------------------

_DECL_RE = re.compile(r"^[ \t]*(?:test|testWidgets)\(", re.MULTILINE)


def declared_count(files):
    total = 0
    for path in files:
        total += len(_DECL_RE.findall(path.read_text(encoding="utf-8", errors="replace")))
    return total


# `flutter test`'s expanded/compact reporter trailer, e.g.
#   "00:41 +212 ~9 -3: Some test name"
# Skips (`~`) and failures (`-`) are optional and their order is not assumed:
# the reporter prints `~` before `-`, and a fixed `-`-then-`~` pattern silently
# matched an earlier, failure-free trailer instead (2026-10-03: a red shard
# reported `failed=0`). The LAST match in the stream is the final tally.
_TALLY_RE = re.compile(r"\+(\d+)((?:\s+[~-]\d+)*)\s*:")


def parse_tally(text):
    """Returns (passed, failed, skipped) from the last reporter tally, or None."""
    matches = _TALLY_RE.findall(text)
    if not matches:
        return None
    passed, rest = matches[-1]
    counts = {"-": 0, "~": 0}
    for sign, value in re.findall(r"([~-])(\d+)", rest):
        counts[sign] = int(value)
    return int(passed), counts["-"], counts["~"]


def _loadavg():
    """1/5/15-minute load average, or None where the OS has no such notion."""
    try:
        return os.getloadavg()
    except (OSError, AttributeError):  # pragma: no cover - Windows
        return None


def _fmt_load(load):
    return "unavailable" if load is None else " ".join(f"{v:.2f}" for v in load)


def _append_timing(log_path, elapsed, load_before, load_after):
    """Inserts the timing block immediately BEFORE the artifact's `RC=<n>` line.

    The RC trailer must stay the literal last line (report.write_log's contract,
    so `tail -n 1` prints `RC=<n>` and nothing else) — hence insert, not append.
    """
    path = Path(log_path)
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines or not lines[-1].startswith("RC="):
        return
    lines[-1:-1] = [
        f"ELAPSED_SECONDS={elapsed:.1f}",
        f"LOADAVG_BEFORE={_fmt_load(load_before)}",
        f"LOADAVG_AFTER={_fmt_load(load_after)}",
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def run_shard(shard, files):
    """Runs one shard; returns a result dict. Never raises on a failing child."""
    name = shard["name"]
    declared = declared_count(files)
    log_path = report.log_path_for(REPO_ROOT, "tests", name)
    argv = ["flutter", "test", *[os.fspath(f.relative_to(REPO_ROOT)) for f in files]]

    # A shard time is only interpretable next to the machine load that produced
    # it: on 2026-09-03 this machine carried a load average near 180 from another
    # session's indexer, which would silently inflate every measurement. Both
    # samples and the elapsed time go INTO the artifact, so the artifact is
    # self-attributing and a future reader never has to trust a remembered number.
    load_before = _loadavg()
    started = time.monotonic()
    result = run.run_logged(argv, log_path, cwd=REPO_ROOT)
    elapsed = time.monotonic() - started
    load_after = _loadavg()
    _append_timing(log_path, elapsed, load_before, load_after)

    tally = parse_tally(result.stdout + result.stderr)
    if tally is None:
        # No tally at all means the run never got as far as reporting — a
        # compile error or a missing toolchain. That is a failure regardless of
        # what the exit code says.
        print(f"SHARD {name}: no reporter tally found in output — treating as failure")
        passed = failed = skipped = 0
        rc = result.returncode or 1
    else:
        passed, failed, skipped = tally
        rc = result.returncode

    executed = passed + failed + skipped
    print(
        f"SHARD {name}: files={len(files)} declared={declared} executed={executed} "
        f"passed={passed} failed={failed} skipped={skipped} "
        f"elapsed={elapsed:.1f}s load={_fmt_load(load_before)} RC={rc} log={log_path}"
    )
    if elapsed > SHARD_BUDGET_S:
        # Not a failure — a re-split signal. Silence here is how a shard drifts
        # over the harness cap and the suite becomes unrunnable again.
        print(
            f"OVER-BUDGET {name}: {elapsed:.1f}s > {SHARD_BUDGET_S}s budget "
            f"(load was {_fmt_load(load_before)}); re-measure on an idle machine "
            "and split this shard if it is genuinely too slow"
        )
    if tally is not None and executed != declared:
        # A warning, not a verdict: `test()` calls emitted inside loops or
        # helper functions legitimately make executed > declared, and a
        # group-level `skip:` can make them differ the other way. It exists so a
        # whole file failing to load can never pass unnoticed.
        print(
            f"COUNT-MISMATCH {name}: declared={declared} executed={executed} "
            "(check the shard log before trusting a green result)"
        )
    return {"name": name, "rc": rc, "passed": passed, "failed": failed,
            "skipped": skipped, "declared": declared, "executed": executed,
            "log": os.fspath(log_path)}


def select_shards(expansion, selector):
    if selector is None:
        return expansion
    for index, (shard, files) in enumerate(expansion, start=1):
        if selector == shard["name"] or selector == str(index):
            return [(shard, files)]
    return None


def audit_coverage(expansion):
    """Every `test/**/*_test.dart` must belong to exactly one shard.

    Duplicates cannot survive expand_shards (first-match-wins for directories
    and globs, a hard DUPLICATED error for explicit files), so what is left to
    check is the negative space: a test file under a directory no shard names
    would never run while a full run still printed a green TOTAL — the
    2026-07-10 allowlist failure mode. This check looks at what is NOT listed.

    Returns 0 when coverage is exact, 1 otherwise.
    """
    on_disk = set((REPO_ROOT / "test").rglob("*_test.dart"))
    sharded = {path for _, files in expansion for path in files}
    orphans = sorted(on_disk - sharded)
    for path in orphans:
        print(f"UNSHARDED: {path.relative_to(REPO_ROOT)} belongs to no shard — it would never run")
    print(f"COVERAGE: {len(on_disk)} files on disk, {len(sharded)} sharded, "
          f"{len(orphans)} unsharded, 0 duplicated")
    return 1 if orphans else 0


def print_table(expansion):
    print(f"{'#':>2}  {'shard':<18} {'files':>5} {'declared':>8}  paths")
    total_files = total_declared = 0
    for index, (shard, files) in enumerate(expansion, start=1):
        declared = declared_count(files)
        total_files += len(files)
        total_declared += declared
        print(f"{index:>2}  {shard['name']:<18} {len(files):>5} {declared:>8}  "
              f"{', '.join(shard['paths'])}")
    print(f"{'':>2}  {'TOTAL':<18} {total_files:>5} {total_declared:>8}")


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="run_tests.py",
        description="Run the Halcyon test suite in shards, each under the foreground timeout.")
    parser.add_argument("--shard", help="run one shard only, by name or 1-based index")
    parser.add_argument("--list", action="store_true", help="print the shard table and exit")
    parser.add_argument("--audit-coverage", action="store_true",
                        help="check every test file belongs to exactly one shard, then exit")
    args = parser.parse_args(argv)

    expansion = expand_shards()  # exits 2 on a broken table, in every mode

    if args.list:
        print_table(expansion)
        return 0
    if args.audit_coverage:
        return audit_coverage(expansion)

    # A full run is only meaningful if the shards actually cover the suite; a
    # green TOTAL over an incomplete roster is worse than a red one.
    if not args.shard and audit_coverage(expansion) != 0:
        print("ERROR: shard coverage is incomplete — fix SHARDS before trusting a full run",
              file=sys.stderr)
        return 2

    selected = select_shards(expansion, args.shard)
    if selected is None:
        names = ", ".join(shard["name"] for shard, _ in expansion)
        print(f"ERROR: unknown shard {args.shard!r}; known shards: {names}", file=sys.stderr)
        return 2

    results = [run_shard(shard, files) for shard, files in selected]
    passed = sum(r["passed"] for r in results)
    failed = sum(r["failed"] for r in results)
    rc = 0 if all(r["rc"] == 0 for r in results) else 1
    print(f"TOTAL: {passed} passed, {failed} failed, RC={rc}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
