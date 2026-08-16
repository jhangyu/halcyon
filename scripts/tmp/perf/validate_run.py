#!/usr/bin/env python3
"""Validity gate for Halcyon perf runs (Round 3, D1).

A perf log can be complete-looking and worthless. Every failure this round had
the same shape: the artefact exists, the format is right, the content is empty
or non-comparable, and nothing screams. This gate screams.

It answers one question -- "is this log allowed to be turned into numbers?" --
and answers it with an exit code:

    exit 0  ACCEPT   the log may be fed to parse_r2.py
    exit 1  REJECT   the log is invalid; any numbers derived from it are void
    exit 2  usage error

It does NOT compute statistics. parse_r2.py is the only parser and is never
modified. Use scripts/tmp/perf/analyze_run.sh, which runs this gate first and
refuses to invoke parse_r2.py on a rejected log.

Usage:
    validate_run.py <run.log> --stdout <stdout-capture.log>
                    [--expect-mode profile|debug|release]
                    [--min-switches N]        (default 20)
                    [--no-native]             (log has no native side)

Checks, each with a stable reason code (see docs/logs/2026-08-16/
verification-standards.md for the failure shapes these come from).
"""

import argparse
import os
import re
import subprocess
import sys
from collections import defaultdict

# Event classes parse_r2.py needs in order to populate its report sections.
REQUIRED_EVENTS = [
    ("folder.load.end", "folder-load section / validity"),
    ("pass.begin", "per-pass wall-clock decomposition"),
    ("pass.end", "per-pass wall-clock decomposition"),
    ("switch.begin", "switch classification table"),
    ("image.resolved", "tier1-HIT / tier1-MISS / tier2 classification"),
]


class Verdict:
    def __init__(self):
        self.errors = []   # (code, message)
        self.notes = []    # informational lines

    def fail(self, code, msg):
        self.errors.append((code, msg))

    def note(self, msg):
        self.notes.append(msg)

    @property
    def ok(self):
        return not self.errors


def parse_perf(path, prefix="PERF"):
    """Returns [(ts_us, name, fields)] for lines matching '<prefix>|ts|name|...'.

    Tolerates the 'flutter: ' prefix that `flutter run` stdout adds.
    """
    evs = []
    with open(path, errors="replace") as f:
        for line in f:
            line = line.strip()
            if line.startswith("flutter: "):
                line = line[len("flutter: "):]
            if not line.startswith(prefix + "|"):
                continue
            parts = line.split("|")
            if len(parts) < 3:
                continue
            try:
                ts = int(parts[1])
            except ValueError:
                continue
            evs.append((ts, parts[2], parts[3:]))
    return evs


def kv(fields):
    out = {}
    for f in fields:
        if "=" in f:
            k, v = f.split("=", 1)
            out[k] = v
    return out


# --------------------------------------------------------------------------
# checks
# --------------------------------------------------------------------------

def check_build_mode(v, sources, expect_mode):
    """The mode must be provable from the run's own captured output.

    Round-3a compared Debug numbers against Profile baselines and produced a
    phantom 8x regression. A log that cannot prove its build mode is not
    comparable to anything. Proof may come from the stdout capture ("Launching
    ... in profile mode") or from a companion build log ("Built
    build/macos/Build/Products/Profile/Halcyon.app") -- round-2 captured them
    in separate files.
    """
    sources = [p for p in sources if p]
    if not sources:
        v.fail("E_NO_BUILD_MODE_PROOF",
               "no --stdout / --build-log given; build mode unprovable")
        return None

    modes = {}  # mode -> source that proved it
    seen_any_file = False
    for path in sources:
        if not os.path.exists(path):
            v.fail("E_NO_BUILD_MODE_PROOF", f"capture not found: {path}")
            continue
        seen_any_file = True
        text = open(path, errors="replace").read()
        for m in re.finditer(r"on macOS in (\w+) mode", text):
            modes.setdefault(m.group(1).lower(), path)
        for m in re.finditer(r"Built build/macos/Build/Products/(\w+)/", text):
            modes.setdefault(m.group(1).lower(), path)

    if not seen_any_file:
        return None
    if not modes:
        v.fail("E_NO_BUILD_MODE_PROOF",
               f"{sources}: no 'in <mode> mode' and no "
               "'Built build/macos/Build/Products/<Mode>/' line")
        return None
    if len(modes) > 1:
        v.fail("E_BUILD_MODE_MIXED",
               "captures report more than one build mode: "
               + ", ".join(f"{m} ({p})" for m, p in sorted(modes.items())))
        return None

    mode, src = next(iter(modes.items()))
    v.note(f"build mode: {mode} (proved from {src})")
    if expect_mode and mode != expect_mode.lower():
        v.fail("E_BUILD_MODE_MISMATCH",
               f"build mode is {mode}, --expect-mode says {expect_mode}; "
               "cross-mode comparison is not evidence")
    return mode


def check_abort_and_folder(v, evs):
    aborts = [f for _, n, f in evs if n == "driver.abort"]
    if aborts:
        v.fail("E_DRIVER_ABORT",
               f"driver.abort present ({len(aborts)}x): {aborts[0]}")

    loads = [(ts, f) for ts, n, f in evs if n == "folder.load.end"]
    if not loads:
        v.fail("E_NO_FOLDER_LOAD", "no folder.load.end event")
        return
    for _, f in loads:
        items = kv(f).get("items")
        if items is None:
            v.fail("E_FOLDER_LOAD_SHAPE",
                   f"folder.load.end has no items= field: {f}")
        elif int(items) == 0:
            v.fail("E_FOLDER_EMPTY",
                   "folder.load.end items=0 -- the app read an empty or "
                   "nonexistent directory (relative-path sandbox trap)")
        else:
            v.note(f"folder.load.end items={items}")


def check_completion(v, evs):
    if not any(n == "driver.done" for _, n, _ in evs):
        v.fail("E_NO_DRIVER_DONE",
               "no driver.done -- the run was truncated or killed; "
               "a partial log is not a run")


def check_required_events(v, evs, native, expect_native):
    present = {n for _, n, _ in evs}
    for name, why in REQUIRED_EVENTS:
        if name not in present:
            v.fail("E_MISSING_EVENT_CLASS",
                   f"no '{name}' events -- parse_r2.py cannot populate: {why}")
    if expect_native:
        nt = [f for _, n, f in native
              if n == "result.dispatch" and "nativeTotal" in kv(f)]
        if not nt:
            v.fail("E_MISSING_NATIVE",
                   "no PERFNATIVE result.dispatch|nativeTotal= events -- the "
                   "native stages section would be silently absent")
        else:
            v.note(f"native result.dispatch nativeTotal samples: {len(nt)}")


def check_resolved_shape(v, evs):
    """image.resolved must carry a positional id at field[0] plus tier/sync/dur.

    parse_r2.py reads f[0] as the id. If the harness ever emits 'id=<x>' as a
    kv instead, every switch becomes unresolved and the report goes empty
    without any parse error.
    """
    res = [f for _, n, f in evs if n == "image.resolved"]
    if not res:
        return  # already reported by check_required_events
    bad_pos = [f for f in res if not f or "=" in f[0]]
    if bad_pos:
        v.fail("E_RESOLVED_ID_NOT_POSITIONAL",
               f"image.resolved id must be field[0] positional; saw {bad_pos[0]}")
    for key in ("tier", "sync", "dur"):
        missing = [f for f in res if key not in kv(f)]
        if missing:
            v.fail("E_RESOLVED_FIELD_MISSING",
                   f"{len(missing)}/{len(res)} image.resolved events lack "
                   f"'{key}='; e.g. {missing[0]}")


def pass_windows(evs):
    """Yields (label, t_begin, t_end) for each pass.begin/pass.end pair."""
    out = []
    open_pass = None
    for ts, n, f in evs:
        if n == "pass.begin":
            open_pass = (f[0] if f else "?", ts)
        elif n == "pass.end" and open_pass:
            out.append((open_pass[0], open_pass[1], ts))
            open_pass = None
    return out


def check_per_pass_resolved(v, evs):
    """Every pass that switched images must have resolved images.

    The process-global dedupe bug made the SECOND measurement pass emit zero
    image.resolved events. Overall counts still looked healthy.
    """
    windows = pass_windows(evs)
    if not windows:
        return
    for label, t0, t1 in windows:
        switches = [ts for ts, n, _ in evs
                    if n == "switch.begin" and t0 <= ts <= t1]
        resolved = [ts for ts, n, _ in evs
                    if n == "image.resolved" and t0 <= ts <= t1]
        if switches and not resolved:
            v.fail("E_PASS_ZERO_RESOLVED",
                   f"pass '{label}': {len(switches)} switch.begin but ZERO "
                   "image.resolved in the pass window")
        else:
            v.note(f"pass '{label}': switches={len(switches)} "
                   f"resolved={len(resolved)}")


def check_unresolved_switches(v, evs):
    """parse_r2's VOID WARNING, promoted to a hard reject."""
    resolved_by_id = defaultdict(list)
    for ts, n, f in evs:
        if n == "image.resolved" and f:
            resolved_by_id[f[0]].append(ts)
    for lst in resolved_by_id.values():
        lst.sort()

    unresolved = 0
    for ts, n, f in evs:
        if n != "switch.begin" or len(f) < 3:
            continue
        ident = f[2]
        if not any(t >= ts for t in resolved_by_id.get(ident, [])):
            unresolved += 1
    if unresolved:
        v.fail("E_UNRESOLVED_SWITCH",
               f"{unresolved} switch.begin never got a matching "
               "image.resolved (parse_r2 VOID condition)")


def check_tier2_present(v, evs):
    """A run with no tier=2 resolve anywhere cannot populate the tier2 sections.

    Keying the resolve dedupe on id alone (instead of (id, tier)) removes the
    whole tier2-UPGRADE class while the report still looks complete.
    """
    res = [f for _, n, f in evs if n == "image.resolved"]
    if not res:
        return
    if not any(kv(f).get("tier") == "2" for f in res):
        v.fail("E_NO_TIER2_RESOLVE",
               f"{len(res)} image.resolved events, none with tier=2 -- the "
               "tier2-IMMEDIATE / tier2-UPGRADE classes would be empty while "
               "the report still renders (check the (id,tier) dedupe key)")


def check_timeout_events(v, evs):
    """switch/burst timeouts void measurements; settle-waits only warn.

    `switch.timeout` and `burst.timeout` mean the thing being measured never
    arrived -- the round-4 shape, where every item ran out the 15s clock and
    the log still looked normal. Other `*.timeout` events (e.g.
    pass.paced.reset.timeout, rapid.final.timeout) are settle-waits between
    passes; round-2's published baseline logs contain them, so they are
    reported but do not void the run.
    """
    hard = [(n, f) for _, n, f in evs
            if n in ("switch.timeout", "burst.timeout")]
    if hard:
        v.fail("E_SWITCH_TIMEOUT",
               f"{len(hard)} switch/burst timeout events (e.g. {hard[0][0]}|"
               f"{'|'.join(hard[0][1])}) -- the measured image never arrived")
    soft = [n for _, n, _ in evs
            if n.endswith(".timeout") and n not in ("switch.timeout",
                                                    "burst.timeout")]
    if soft:
        v.note(f"non-blocking settle-wait timeouts: {len(soft)} "
               f"({', '.join(sorted(set(soft)))})")


def check_timeout_spacing(v, evs, pace_ms):
    """Detect switch.begin spacing pinned to a fixed harness timeout.

    Round-4 shape: consecutive switches 15.005s apart, over and over, because
    every wait ran out the 15s clock. Deliberate pacing is regular too, so this
    only fires on spacings far larger than the configured pace.
    """
    floor_us = max(5_000_000, 3 * pace_ms * 1000)
    for label, t0, t1 in pass_windows(evs) or [("<whole log>", 0, 1 << 62)]:
        ts = [t for t, n, _ in evs if n == "switch.begin" and t0 <= t <= t1]
        deltas = [b - a for a, b in zip(ts, ts[1:])]
        run = []
        for d in deltas:
            if d >= floor_us and (not run or abs(d - run[0]) <= 50_000):
                run.append(d)
            else:
                run = [d] if d >= floor_us else []
            if len(run) >= 3:
                v.fail("E_FIXED_TIMEOUT_SPACING",
                       f"pass '{label}': {len(run)}+ consecutive switch.begin "
                       f"gaps of ~{run[0]/1e6:.3f}s (>= {floor_us/1e6:.1f}s "
                       "floor, spread <= 50ms) -- consistent with every wait "
                       "hitting a fixed harness timeout, not with real work")
                break


def check_sample_floor(v, evs, min_switches):
    n = sum(1 for _, name, _ in evs if name == "switch.begin")
    if n < min_switches:
        v.fail("E_SAMPLE_FLOOR",
               f"only {n} switch.begin events, floor is {min_switches}; "
               "too few samples to compare against a baseline")
    else:
        v.note(f"switch.begin samples: {n}")


def git_provenance(v):
    try:
        head = subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                              capture_output=True, text=True, timeout=20)
        dirty = subprocess.run(["git", "status", "--porcelain"],
                               capture_output=True, text=True, timeout=20)
    except Exception as e:  # pragma: no cover - provenance is informational
        v.note(f"git provenance unavailable: {e}")
        return
    if head.returncode == 0:
        v.note(f"HEAD at validation time: {head.stdout.strip()}")
    if dirty.returncode == 0:
        files = [l for l in dirty.stdout.splitlines() if l.strip()]
        v.note(f"dirty files at validation time: {len(files)}")
        for line in files[:20]:
            v.note(f"  {line}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--stdout", dest="stdout_path", default=None,
                    help="the run's stdout capture (proves build mode, "
                         "carries PERFNATIVE lines)")
    ap.add_argument("--build-log", dest="build_logs", action="append",
                    default=[],
                    help="companion build log that names the build mode; "
                         "may be given more than once")
    ap.add_argument("--expect-mode", default=None,
                    choices=["debug", "profile", "release"])
    ap.add_argument("--min-switches", type=int, default=20)
    ap.add_argument("--no-native", action="store_true",
                    help="this run legitimately has no native side")
    args = ap.parse_args()

    if not os.path.exists(args.log):
        print(f"REJECT E_NO_LOG: {args.log} does not exist")
        return 1

    evs = parse_perf(args.log, "PERF")
    native = parse_perf(args.stdout_path, "PERFNATIVE") if args.stdout_path \
        and os.path.exists(args.stdout_path) else []

    v = Verdict()
    if not evs:
        v.fail("E_NO_EVENTS", f"{args.log} contains no PERF| lines")

    pace_ms = 0
    for _, n, f in evs:
        if n == "driver.config":
            d = kv(f)
            pace_ms = int(d.get("pace", 0))
            v.note(f"driver.config: dir={d.get('dir')} n={d.get('n')} "
                   f"pace={d.get('pace')} mode={d.get('mode')}")
            break

    check_build_mode(v, [args.stdout_path] + args.build_logs, args.expect_mode)
    if evs:
        check_abort_and_folder(v, evs)
        check_completion(v, evs)
        check_required_events(v, evs, native, not args.no_native)
        check_resolved_shape(v, evs)
        check_per_pass_resolved(v, evs)
        check_unresolved_switches(v, evs)
        check_tier2_present(v, evs)
        check_timeout_events(v, evs)
        check_timeout_spacing(v, evs, pace_ms)
        check_sample_floor(v, evs, args.min_switches)
    git_provenance(v)

    print(f"# validity gate: {args.log}")
    for note in v.notes:
        print(f"  . {note}")
    if v.ok:
        print("ACCEPT: log is analysable")
        return 0
    print()
    for code, msg in v.errors:
        print(f"REJECT {code}: {msg}")
    print(f"\n{len(v.errors)} blocking problem(s). "
          "Numbers derived from this log are VOID.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
