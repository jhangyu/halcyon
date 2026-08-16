#!/usr/bin/env python3
"""Discrimination proof for the perf validity gate (D1).

A gate that has never been shown rejecting anything is not evidence. This
takes a REAL round-2 log that the gate accepts (the same log round-2's
published baselines came from), injects one defect at a time, and asserts the
gate goes red with the expected reason code.

Every mutation is applied to a COPY under a temp dir. Nothing in the tree is
modified -- teammates are working in it.

Usage: validate_run_selftest.py [--out <report.txt>]
Exit 0 only if the clean log is ACCEPTED and every mutant is REJECTED with its
expected code.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
GATE = os.path.join(ROOT, "scripts", "tmp", "perf", "validate_run.py")
SRC_LOG = os.path.join(ROOT, "tmp", "verify", "r2", "dng_profile_r2b.log")
SRC_STDOUT = os.path.join(ROOT, "tmp", "verify", "r2", "dng_profile_r2b.stdout.log")
SRC_BUILD = os.path.join(ROOT, "tmp", "verify", "r2", "build_profile.log")


def run_gate(log, stdout, build, extra=()):
    cmd = [sys.executable, GATE, log]
    if stdout:
        cmd += ["--stdout", stdout]
    if build:
        cmd += ["--build-log", build]
    cmd += list(extra)
    p = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    codes = set(re.findall(r"^REJECT (E_\w+)", p.stdout, re.M))
    return p.returncode, codes, p.stdout


# --------------------------------------------------------------------------
# mutations: each takes the clean log text (and stdout/build text) and returns
# the mutated triple.
# --------------------------------------------------------------------------

def m_folder_empty(log, out, build):
    return re.sub(r"(folder\.load\.end\|items=)\d+", r"\g<1>0", log), out, build


def m_driver_abort(log, out, build):
    lines = log.splitlines(True)
    for i, l in enumerate(lines):
        if "|folder.load.end|" in l:
            lines.insert(i + 1, "PERF|9999999|driver.abort|not enough items\n")
            break
    return "".join(lines), out, build


def m_no_resolved_at_all(log, out, build):
    return "".join(l for l in log.splitlines(True)
                   if "|image.resolved|" not in l), out, build


def m_second_pass_no_resolved(log, out, build):
    """Kill image.resolved only inside the second pass -- the process-global
    dedupe shape, where overall counts still look healthy."""
    lines = log.splitlines(True)
    pass_idx, out_lines = 0, []
    for l in lines:
        if "|pass.begin|" in l:
            pass_idx += 1
        if pass_idx == 2 and "|image.resolved|" in l:
            continue
        out_lines.append(l)
    return "".join(out_lines), out, build


def m_no_tier2(log, out, build):
    return log.replace("tier=2", "tier=1"), out, build


def m_resolved_id_as_kv(log, out, build):
    return re.sub(r"(\|image\.resolved\|)([^|=\n]+)", r"\1id=\2", log), out, build


def m_resolved_drop_dur(log, out, build):
    return re.sub(r"(\|image\.resolved\|[^\n]*?)\|dur=\d+", r"\1", log), out, build


def m_no_driver_done(log, out, build):
    return "".join(l for l in log.splitlines(True)
                   if "|driver.done" not in l), out, build


def m_sample_floor(log, out, build):
    kept, seen = [], 0
    for l in log.splitlines(True):
        if "|switch.begin|" in l:
            seen += 1
            if seen > 5:
                continue
        kept.append(l)
    return "".join(kept), out, build


def m_switch_timeout(log, out, build):
    return log.replace("|switch.end|", "|switch.timeout|", 1), out, build


def m_fixed_timeout_spacing(log, out, build):
    """Re-stamp the paced pass's switch.begin events 15.005s apart -- the
    round-4 shape where every wait ran out a fixed harness clock."""
    lines = log.splitlines(True)
    # anchor inside the paced pass window so the re-stamped events stay in it
    base = None
    for l in lines:
        if "|pass.begin|paced" in l:
            base = int(l.split("|")[1]) + 1_000_000
            break
    if base is None:
        return log, out, build
    t, n, last = base, 0, base
    for i, l in enumerate(lines):
        if "|switch.begin|paced|" in l:
            parts = l.split("|")
            parts[1] = str(t)
            lines[i] = "|".join(parts)
            last = t
            t += 15_005_000
            n += 1
            if n >= 6:
                break
    # the pass must still contain them
    for i, l in enumerate(lines):
        if "|pass.end|paced" in l:
            parts = l.split("|")
            if int(parts[1]) < last:
                parts[1] = str(last + 1_000_000)
                lines[i] = "|".join(parts)
            break
    return "".join(lines), out, build


def m_no_native(log, out, build):
    return log, "".join(l for l in out.splitlines(True)
                        if "|result.dispatch|" not in l), build


def m_mixed_build_mode(log, out, build):
    return log, out, build + "\n✓ Built build/macos/Build/Products/Debug/Halcyon.app\n"


MUTANTS = [
    ("folder items=0 (sandbox relative-path trap)", m_folder_empty, "E_FOLDER_EMPTY", ()),
    ("driver.abort present", m_driver_abort, "E_DRIVER_ABORT", ()),
    ("no image.resolved anywhere", m_no_resolved_at_all, "E_MISSING_EVENT_CLASS", ()),
    ("second pass emits zero image.resolved", m_second_pass_no_resolved, "E_PASS_ZERO_RESOLVED", ()),
    ("no tier=2 resolve (id-only dedupe)", m_no_tier2, "E_NO_TIER2_RESOLVE", ()),
    ("image.resolved id sent as kv", m_resolved_id_as_kv, "E_RESOLVED_ID_NOT_POSITIONAL", ()),
    ("image.resolved missing dur=", m_resolved_drop_dur, "E_RESOLVED_FIELD_MISSING", ()),
    ("run truncated (no driver.done)", m_no_driver_done, "E_NO_DRIVER_DONE", ()),
    ("only 5 switches", m_sample_floor, "E_SAMPLE_FLOOR", ()),
    ("a switch.timeout event", m_switch_timeout, "E_SWITCH_TIMEOUT", ()),
    ("switches pinned 15.005s apart", m_fixed_timeout_spacing, "E_FIXED_TIMEOUT_SPACING", ()),
    ("native result.dispatch missing", m_no_native, "E_MISSING_NATIVE", ()),
    ("build log names two modes", m_mixed_build_mode, "E_BUILD_MODE_MIXED", ()),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    report = []

    def say(line):
        print(line)
        report.append(line)

    clean_log = open(SRC_LOG, errors="replace").read()
    clean_out = open(SRC_STDOUT, errors="replace").read()
    clean_build = open(SRC_BUILD, errors="replace").read()

    tmp = tempfile.mkdtemp(prefix="halcyon_gate_selftest_")
    failures = 0
    try:
        say(f"# perf validity gate discrimination proof")
        say(f"# source log: {os.path.relpath(SRC_LOG, ROOT)} "
            f"(round-2 published baseline)")
        say("")

        # --- control: the clean log must be ACCEPTED, else every mutant
        # --- "rejection" below is meaningless.
        p = os.path.join(tmp, "clean")
        os.makedirs(p)
        for name, text in (("run.log", clean_log), ("stdout.log", clean_out),
                           ("build.log", clean_build)):
            open(os.path.join(p, name), "w").write(text)
        rc, codes, _ = run_gate(os.path.join(p, "run.log"),
                                os.path.join(p, "stdout.log"),
                                os.path.join(p, "build.log"),
                                ["--expect-mode", "profile"])
        ok = rc == 0
        failures += 0 if ok else 1
        say(f"CONTROL  clean round-2 log -> exit={rc} "
            f"{'ACCEPT (as required)' if ok else 'REJECTED ' + str(sorted(codes)) + ' <-- GATE IS BROKEN'}")
        say("")

        # --- one defect at a time
        for i, (label, fn, expect, extra) in enumerate(MUTANTS):
            d = os.path.join(tmp, f"m{i:02d}")
            os.makedirs(d)
            log, out, build = fn(clean_log, clean_out, clean_build)
            open(os.path.join(d, "run.log"), "w").write(log)
            open(os.path.join(d, "stdout.log"), "w").write(out)
            open(os.path.join(d, "build.log"), "w").write(build)
            rc, codes, _ = run_gate(os.path.join(d, "run.log"),
                                    os.path.join(d, "stdout.log"),
                                    os.path.join(d, "build.log"),
                                    list(extra) + ["--expect-mode", "profile"])
            hit = rc != 0 and expect in codes
            failures += 0 if hit else 1
            status = "KILLED" if hit else "SURVIVED <-- gate blind here"
            say(f"M{i:02d} {status:<32} {label}")
            say(f"      expected {expect}; exit={rc} codes={sorted(codes)}")

        # --- no build-mode proof at all
        rc, codes, _ = run_gate(os.path.join(p, "run.log"), None, None)
        hit = rc != 0 and "E_NO_BUILD_MODE_PROOF" in codes
        failures += 0 if hit else 1
        say(f"M{len(MUTANTS):02d} {'KILLED' if hit else 'SURVIVED <-- gate blind here':<32} "
            "no stdout/build capture given")
        say(f"      expected E_NO_BUILD_MODE_PROOF; exit={rc} codes={sorted(codes)}")

        # --- debug log compared against profile baselines
        rc, codes, _ = run_gate(
            os.path.join(ROOT, "tmp/verify/r3/perf_dng_r3a.log"),
            os.path.join(ROOT, "tmp/verify/r3/flutter_run_dng_full.stdout.log"),
            None, ["--expect-mode", "profile"])
        hit = rc != 0 and "E_BUILD_MODE_MISMATCH" in codes
        failures += 0 if hit else 1
        say(f"M{len(MUTANTS)+1:02d} {'KILLED' if hit else 'SURVIVED <-- gate blind here':<32} "
            "real 3a debug-mode log vs profile baselines")
        say(f"      expected E_BUILD_MODE_MISMATCH; exit={rc} codes={sorted(codes)}")

        say("")
        say(f"blind spots: {failures}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if args.out:
        os.makedirs(os.path.dirname(args.out), exist_ok=True)
        open(args.out, "w").write("\n".join(report) + "\n")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
