#!/usr/bin/env python3
"""Analyse Halcyon perf artifacts: PERF| event logs and macOS `sample` traces.

Usage:
  python3 scripts/analyze_perf.py log <perf_log> [--compare <other_log>]
  python3 scripts/analyze_perf.py sample <sample_txt> [--thread SUBSTR] [--top N]
  python3 scripts/analyze_perf.py --selftest

Exit codes: 0 ok, 2 parse failure.

Two facts about the artifacts that this script exists to encapsulate:

1. The `stall|ms=` probe shipped in two shapes. The original
   (perf_log.dart:175-188) never reset its expectation, so `ms=` is CUMULATIVE
   drift and only consecutive-line DELTAS mean anything; reading it raw yields a
   blocked total larger than the session. The fixed probe reports the gap just
   observed. The two are told apart by monotonicity and the mode is printed.
2. In a `sample` call graph a frame's printed count is INCLUSIVE. Self time is
   count minus the sum of its immediate children, which is what makes "where did
   the thread actually burn" answerable.
"""

import re
import sys
from collections import Counter

# ---------------------------------------------------------------- perf log ---

PERF_RE = re.compile(r"^PERF\|(\d+)\|([^|]+)\|?(.*)$")


def parse_log(path):
    """-> list of (micros, event, {k: v}). Raises ValueError if nothing parsed."""
    events = []
    with open(path, errors="replace") as fh:
        for line in fh:
            m = PERF_RE.match(line.rstrip("\n"))
            if not m:
                continue
            kv = {}
            for field in m.group(3).split("|"):
                if "=" in field:
                    k, v = field.split("=", 1)
                    kv[k] = v
                elif field:
                    # Positional first field, e.g. `publish|<id>|...`.
                    kv.setdefault("_pos", field)
            events.append((int(m.group(1)), m.group(2), kv))
    if not events:
        raise ValueError(f"{path}: no PERF| lines found")
    return events


def _id_of(kv):
    return kv.get("id") or kv.get("_pos")


def _pct(part, whole):
    return 100.0 * part / whole if whole else 0.0


def _quantiles(sorted_vals, qs=(0.5, 0.9)):
    if not sorted_vals:
        return [0] * len(qs)
    n = len(sorted_vals)
    return [sorted_vals[min(n - 1, int(n * q))] for q in qs]


def stall_analysis(events, span_s):
    """-> dict. Auto-detects cumulative vs per-gap `ms=`."""
    stalls = [(us, int(kv["ms"])) for us, name, kv in events
              if name == "stall" and "ms" in kv]
    if len(stalls) < 2:
        return {"mode": "none", "n": len(stalls), "late_ms": 0, "duty_pct": 0.0}
    pairs = list(zip(stalls, stalls[1:]))
    rising = sum(1 for (_, a), (_, b) in pairs if b >= a)
    raw_sum_ms = sum(v for _, v in stalls)
    # Two independent tells, either sufficient. (a) A per-gap series cannot sum
    # to more wall clock than the session lasted, so overshoot proves the values
    # are running totals. (b) A near-monotonic series is a running total even
    # when it is short. (a) alone misses brief captures; (b) alone misses real
    # captures, where the probe's small catch-ups drop monotonicity to ~74%.
    cumulative = (raw_sum_ms > span_s * 1000.0) or _pct(rising, len(pairs)) > 90.0
    if cumulative:
        late = sum(max(0, b - a) for (_, a), (_, b) in pairs)
    else:
        late = sum(v for _, v in stalls)
    return {
        "mode": "cumulative (delta-reconstructed)" if cumulative else "per-gap (direct)",
        "n": len(stalls),
        "late_ms": late,
        "duty_pct": _pct(late / 1000.0, span_s),
    }


def decode_windows(events):
    """Pair req_start/req_end by id -> sorted [(start_us, end_us)]."""
    open_reqs, wins = {}, []
    for us, name, kv in events:
        key = _id_of(kv)
        if name == "req_start":
            open_reqs[key] = us
        elif name == "req_end" and key in open_reqs:
            wins.append((open_reqs.pop(key), us))
    return sorted(wins)


def concurrency_share(wins):
    """-> (share {level: fraction}, max_level, median_level_by_time)."""
    if not wins:
        return {}, 0, 0
    points = sorted([(a, 1) for a, _ in wins] + [(b, -1) for _, b in wins])
    share, level, prev = Counter(), 0, points[0][0]
    for t, delta in points:
        share[level] += t - prev
        prev, level = t, level + delta
    total = sum(share.values()) or 1
    cum, median = 0, 0
    for lvl in sorted(share):
        cum += share[lvl]
        if cum >= total / 2:
            median = lvl
            break
    return ({lvl: share[lvl] / total for lvl in sorted(share)},
            max(share), median)


def summarise_log(path):
    events = parse_log(path)
    span_s = (events[-1][0] - events[0][0]) / 1e6
    hist = Counter(name for _, name, _ in events)

    overruns = [(float(kv.get("total_ms", 0)), float(kv.get("build_ms", 0)),
                 float(kv.get("raster_ms", 0)))
                for _, name, kv in events if name == "frame_overrun"]
    totals = sorted(t for t, _, _ in overruns)
    unexplained = sum(1 for t, b, r in overruns if t - (b + r) > t / 2)

    pubs = Counter()
    pub_paths = Counter()
    for _, name, kv in events:
        if name == "publish":
            pubs[_id_of(kv)] += 1
            pub_paths[kv.get("path", "untagged")] += 1

    wins = decode_windows(events)
    durs = sorted((b - a) / 1000.0 for a, b in wins)
    share, max_level, median_level = concurrency_share(wins)

    counters = [kv for _, name, kv in events if name == "idle_publish_counters"]
    idle_runs = int(counters[-1].get("idleRuns", 0)) if counters else 0
    safeguard = int(counters[-1].get("safeguardRuns", 0)) if counters else 0

    return {
        "path": path,
        "lines": len(events),
        "span_s": span_s,
        "navs": hist.get("nav", 0),
        "hist": hist,
        "stall": stall_analysis(events, span_s),
        "overrun_n": len(overruns),
        "overrun_p50": _quantiles(totals)[0],
        "overrun_p90": _quantiles(totals)[1],
        "overrun_max": totals[-1] if totals else 0,
        "overrun_unexplained_pct": _pct(unexplained, len(overruns)),
        "publishes": sum(pubs.values()),
        "publish_ids": len(pubs),
        "publish_per_id": (sum(pubs.values()) / len(pubs)) if pubs else 0,
        "publish_max": max(pubs.values()) if pubs else 0,
        "publish_dup_ids": sum(1 for v in pubs.values() if v > 1),
        "publish_paths": pub_paths,
        "decodes": len(wins),
        "decode_p50": _quantiles(durs)[0],
        "decode_p90": _quantiles(durs)[1],
        "decode_max": durs[-1] if durs else 0,
        "conc_share": share,
        "conc_max": max_level,
        "conc_median": median_level,
        "idle_runs": idle_runs,
        "safeguard_runs": safeguard,
        "safeguard_pct": _pct(safeguard, idle_runs + safeguard),
    }


LOG_ROWS = [
    ("PERF lines", "lines", "{:,}"),
    ("session span (s)", "span_s", "{:.1f}"),
    ("nav count", "navs", "{:,}"),
    ("stall events", ("stall", "n"), "{:,}"),
    ("stall mode", ("stall", "mode"), "{}"),
    ("UI lateness (ms)", ("stall", "late_ms"), "{:,}"),
    ("stall duty cycle (%)", ("stall", "duty_pct"), "{:.1f}"),
    ("frame_overrun count", "overrun_n", "{:,}"),
    ("overrun total p50 (ms)", "overrun_p50", "{:.0f}"),
    ("overrun total p90 (ms)", "overrun_p90", "{:.0f}"),
    ("overrun max (ms)", "overrun_max", "{:.0f}"),
    (">50% neither build/raster (%)", "overrun_unexplained_pct", "{:.0f}"),
    ("publishes", "publishes", "{:,}"),
    ("distinct published ids", "publish_ids", "{:,}"),
    ("publishes per id (mean)", "publish_per_id", "{:.1f}"),
    ("publishes per id (max)", "publish_max", "{:,}"),
    ("ids published >1x", "publish_dup_ids", "{:,}"),
    ("decodes (req pairs)", "decodes", "{:,}"),
    ("decode dur p50 (ms)", "decode_p50", "{:.0f}"),
    ("decode dur p90 (ms)", "decode_p90", "{:.0f}"),
    ("max concurrent decodes", "conc_max", "{:,}"),
    ("median concurrent (by time)", "conc_median", "{:,}"),
    ("idle publish runs", "idle_runs", "{:,}"),
    ("safeguard publish runs", "safeguard_runs", "{:,}"),
    ("safeguard share (%)", "safeguard_pct", "{:.0f}"),
]


def _get(summary, key):
    return summary[key[0]][key[1]] if isinstance(key, tuple) else summary[key]


def print_log_report(summary, other=None):
    print(f"== {summary['path']}")
    if other:
        print(f"== compare: {other['path']}\n")
        w = 31
        print(f"{'metric':<{w}} {'A':>22} {'B':>22} {'delta':>14}")
        print("-" * (w + 62))
    for label, key, fmt in LOG_ROWS:
        a = _get(summary, key)
        if not other:
            print(f"  {label:<31} {fmt.format(a)}")
            continue
        b = _get(other, key)
        if isinstance(a, str) or isinstance(b, str):
            delta = ""
        elif a:
            delta = f"{b - a:+,.1f} ({_pct(b - a, a):+.0f}%)"
        else:
            delta = f"{b - a:+,.1f}"
        print(f"{label:<31} {fmt.format(a):>22} {fmt.format(b):>22} {delta:>14}")

    for s in ([summary] if not other else [summary, other]):
        print(f"\n-- concurrency time-share: {s['path'].split('/')[-1]}")
        print("   " + "  ".join(f"{lvl}:{frac*100:.1f}%"
                                for lvl, frac in sorted(s["conc_share"].items())))
        print("-- publish path mix: " + ", ".join(
            f"{k}={v}" for k, v in s["publish_paths"].most_common()))
        print("-- top events: " + ", ".join(
            f"{k}={v}" for k, v in s["hist"].most_common(8)))


# ------------------------------------------------------------- sample text ---

THREAD_RE = re.compile(r"^\s*(\d+) Thread_\S+(?::\s*(.*))?$")
NODE_RE = re.compile(r"^(\s*[+!:|\s]*?)(\d+) (.*)$")
ADDR_RE = re.compile(r"\s*\[0x[^\]]*\].*$")
OFFSET_RE = re.compile(r"\s*\+ [\d,.]+\s*$")
UNSYMBOLIZED = ("???", "kDartIsolateSnapshotInstructions")
# A leaf parked in one of these is waiting, not working.
IDLE_LEAVES = ("mach_msg2_trap", "__psynch_cvwait", "__workq_kernreturn",
               "kevent", "__semwait_signal", "poll", "select$DARWIN_EXTSN")


def clean_frame(text):
    name = ADDR_RE.sub("", text)
    name = OFFSET_RE.sub("", name).strip()
    if any(tag in name for tag in UNSYMBOLIZED):
        return "<unsymbolized Dart/JIT code>"
    return name


def parse_sample(path):
    """-> {thread_label: [(depth, count, frame_name)]} in file order."""
    threads, current, in_graph = {}, None, False
    with open(path, errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if line.startswith("Call graph:"):
                in_graph = True
                continue
            if line.startswith("Binary Images:"):
                break
            if not in_graph:
                continue
            m = THREAD_RE.match(line)
            if m:
                label = (m.group(2) or "").strip() or "Thread (unnamed)"
                # Same name can appear twice; keep them distinct.
                key, n = label, 2
                while key in threads:
                    key, n = f"{label} #{n}", n + 1
                current = threads.setdefault(key, [])
                current.append((-1, int(m.group(1)), label))
                continue
            m = NODE_RE.match(line)
            if m and current is not None:
                current.append((len(m.group(1)), int(m.group(2)),
                                clean_frame(m.group(3))))
    if not threads:
        raise ValueError(f"{path}: no `sample` call graph found")
    return threads


def thread_stats(nodes):
    """-> (total, self_by_name, inclusive_by_name, idle_self, blocked_self).

    `idle_self` follows the "parked in a wait syscall" rule. `blocked_self` is
    the subset of it spent in `__psynch_cvwait`, which on the UI isolate is
    mostly waiting for other isolates to reach a GC safepoint -- stalled, not
    resting. It is broken out because whether you call it busy changes the
    denominator of every percentage below.
    """
    total = nodes[0][1]
    frames = nodes[1:]
    self_by, incl_by, idle, blocked = Counter(), Counter(), 0, 0
    own_idle = [0] * len(frames)
    for i, (depth, count, name) in enumerate(frames):
        child_sum, j = 0, i + 1
        if j < len(frames) and frames[j][0] > depth:
            child_depth = frames[j][0]
            while j < len(frames) and frames[j][0] > depth:
                if frames[j][0] == child_depth:
                    child_sum += frames[j][1]
                j += 1
        own = count - child_sum
        self_by[name] += own
        incl_by[name] += count
        if any(tag in name for tag in IDLE_LEAVES):
            idle += own
            own_idle[i] = own
            if "__psynch_cvwait" in name:
                blocked += own
    # Inclusive BUSY = a frame's inclusive count minus the wait time inside its
    # subtree. Without this every ancestor of the run loop's `mach_msg` park
    # outranks the work, which is the opposite of what the question asks.
    sub_idle, stack = list(own_idle), []
    for i, (depth, _, _) in enumerate(frames):
        while stack and frames[stack[-1]][0] >= depth:
            j = stack.pop()
            if stack:
                sub_idle[stack[-1]] += sub_idle[j]
        stack.append(i)
    while len(stack) > 1:
        j = stack.pop()
        sub_idle[stack[-1]] += sub_idle[j]
    incl_busy = Counter()
    for i, (_, count, name) in enumerate(frames):
        incl_busy[name] += count - sub_idle[i]
    return (total, self_by, incl_by, max(0, min(idle, total)), blocked,
            incl_busy)


def print_sample_report(path, want_thread=None, top_n=15):
    threads = parse_sample(path)
    print(f"== {path}\n")
    print(f"{'thread':<46} {'total':>7} {'busy':>7} {'idle':>7} {'busy%':>7}")
    stats = {}
    for label, nodes in threads.items():
        stats[label] = thread_stats(nodes)
        total, _self, _incl, idle = stats[label][:4]
        if total >= 50:  # skip the long tail of short-lived helper threads
            print(f"{label[:45]:<46} {total:>7,} {total-idle:>7,} "
                  f"{idle:>7,} {_pct(total-idle, total):>6.1f}%")

    picks = [l for l in threads if want_thread and want_thread.lower() in l.lower()]
    if not picks:
        if want_thread:
            print(f"\n!! no thread matching {want_thread!r}; falling back")
        picks = ([l for l in threads if "io.flutter.ui" in l]
                 or [l for l in threads if "Main Thread" in l]
                 or [max(threads, key=lambda l: stats[l][0])])
    label = picks[0]
    total, self_by, incl_by, idle, blocked, incl_busy = stats[label]
    busy = total - idle

    print(f"\n-- {label}: {total:,} samples, busy {busy:,} "
          f"({_pct(busy, total):.1f}%), idle {idle:,} ({_pct(idle, total):.1f}%)")
    print("   idle = self samples parked in " + "/".join(IDLE_LEAVES[:3]) + "/...")
    if blocked:
        print(f"   of which {blocked:,} are __psynch_cvwait (GC-safepoint waits). "
              f"Counting those as busy gives {busy + blocked:,} "
              f"({_pct(busy + blocked, total):.1f}%) -- the D5 report's denominator.")
    print(f"\n   top {top_n} frames by INCLUSIVE BUSY samples "
          f"(inclusive count minus waits inside the subtree)")
    print(f"   {'busy':>7} {'%thr':>6} {'%busy':>6}  frame")
    for name, count in incl_busy.most_common(top_n * 4):
        if name == "<unsymbolized Dart/JIT code>" or count >= busy * 0.97:
            continue  # skip the JIT bucket and the whole-thread root spine
        print(f"   {count:>7,} {_pct(count, total):>5.1f}% "
              f"{_pct(count, busy):>5.1f}%  {name[:96]}")
        top_n -= 1
        if top_n == 0:
            break
    print(f"\n   top 10 frames by SELF samples")
    for name, count in self_by.most_common(10):
        waiting = any(tag in name for tag in IDLE_LEAVES)
        share = "  wait" if waiting else f"{_pct(count, busy):>5.1f}%"
        print(f"   {count:>7,} {_pct(count, total):>5.1f}% {share}  {name[:96]}")


# ------------------------------------------------------------------ selftest --

LOG_FIXTURE_CUMULATIVE = """PERF|100|build.stamp|commit=x|iso=main
PERF|1000|nav|id=a|iso=main
PERF|2000|req_start|id=a|tier=lane
PERF|10000|stall|ms=20|iso=main
PERF|20000|stall|ms=45|iso=main
PERF|30000|stall|ms=70|iso=main
PERF|40000|req_end|id=a|dur=38000|bytes=99
PERF|41000|publish|id=a|path=tier1
PERF|42000|publish|id=a|path=tier1
PERF|43000|frame_overrun|build_ms=2.0|raster_ms=1.0|total_ms=100.0
PERF|44000|idle_publish_counters|idleRuns=3|safeguardRuns=1|viaSafeguard=false
PERF|1000100|nav|id=b|iso=main
"""

LOG_FIXTURE_PERGAP = """PERF|1000|nav|id=a
PERF|10000|stall|ms=20
PERF|20000|stall|ms=25
PERF|30000|stall|ms=18
PERF|1000100|nav|id=b
"""

SAMPLE_FIXTURE = """Analysis of sampling Halcyon (pid 1) every 1 millisecond
Call graph:
    100 Thread_1: io.flutter.ui
    + 100 start  (in dyld) + 4  [0x1]
    +   60 mach_msg2_trap  (in libsystem_kernel.dylib)  [0x2]
    +   40 fml::MessageLoopImpl::FlushTasks(fml::FlushType)  (in FlutterMacOS) + 8  [0x3]
    +   ! 30 ???  (in <unknown binary>)  [0x4]
    +   ! : 25 flutter::ImmutableBuffer::init(_Dart_Handle*)  (in FlutterMacOS) + 88  [0x5]
    +   ! :   25 _platform_memmove  (in libsystem_platform.dylib) + 88  [0x6]
    +   ! 10 dart::bin::Builtin_File_Read(_Dart_NativeArguments*)  (in FlutterMacOS) + 224  [0x7]
    +   !   10 read  (in libsystem_kernel.dylib) + 8  [0x8]
    30 Thread_2: com.apple.NSEventThread
    + 30 mach_msg2_trap  (in libsystem_kernel.dylib)  [0x9]
Binary Images:
"""


def selftest(tmpdir="."):
    import os
    import tempfile

    def write(text, suffix):
        fd, p = tempfile.mkstemp(suffix=suffix, dir=tmpdir)
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
        return p

    paths = []
    try:
        p = write(LOG_FIXTURE_CUMULATIVE, ".log")
        paths.append(p)
        s = summarise_log(p)
        # 1.0000 s span: 100us .. 1000100us.
        assert abs(s["span_s"] - 1.0) < 1e-6, s["span_s"]
        assert s["navs"] == 2, s["navs"]
        assert s["stall"]["mode"].startswith("cumulative"), s["stall"]["mode"]
        # Deltas 25 + 25 = 50 ms of lateness, NOT the raw 20+45+70=135.
        assert s["stall"]["late_ms"] == 50, s["stall"]["late_ms"]
        assert abs(s["stall"]["duty_pct"] - 5.0) < 1e-6, s["stall"]["duty_pct"]
        assert s["decodes"] == 1 and abs(s["decode_p50"] - 38.0) < 1e-6
        assert s["publishes"] == 2 and s["publish_ids"] == 1
        assert s["publish_per_id"] == 2.0 and s["publish_dup_ids"] == 1
        assert s["overrun_n"] == 1 and s["overrun_unexplained_pct"] == 100.0
        assert s["idle_runs"] == 3 and s["safeguard_runs"] == 1
        assert abs(s["safeguard_pct"] - 25.0) < 1e-6
        assert s["conc_max"] == 1, s["conc_max"]

        p = write(LOG_FIXTURE_PERGAP, ".log")
        paths.append(p)
        s2 = summarise_log(p)
        assert s2["stall"]["mode"].startswith("per-gap"), s2["stall"]["mode"]
        # Overshoot tell: a per-gap series claiming more lateness than the
        # session lasted must really be cumulative.
        over = LOG_FIXTURE_PERGAP.replace("ms=20", "ms=900000")
        p3 = write(over, ".log")
        paths.append(p3)
        assert summarise_log(p3)["stall"]["mode"].startswith("cumulative")
        # Non-monotonic -> summed directly: 20+25+18 = 63.
        assert s2["stall"]["late_ms"] == 63, s2["stall"]["late_ms"]

        p = write(SAMPLE_FIXTURE, ".txt")
        paths.append(p)
        threads = parse_sample(p)
        assert "io.flutter.ui" in threads, list(threads)
        total, self_by, incl_by, idle = thread_stats(threads["io.flutter.ui"])[:4]
        assert total == 100, total
        assert idle == 60, idle                      # the mach_msg leaf
        ib = "flutter::ImmutableBuffer::init(_Dart_Handle*)  (in FlutterMacOS)"
        assert incl_by[ib] == 25, incl_by.most_common(5)
        mm = "_platform_memmove  (in libsystem_platform.dylib)"
        assert self_by[mm] == 25, self_by[mm]
        fr = "dart::bin::Builtin_File_Read(_Dart_NativeArguments*)  (in FlutterMacOS)"
        assert incl_by[fr] == 10, incl_by[fr]
        # Unsymbolized JIT frames collapse into one bucket.
        assert incl_by["<unsymbolized Dart/JIT code>"] == 30
        # Self time of FlushTasks = 40 - (30 + 10) = 0.
        ft = "fml::MessageLoopImpl::FlushTasks(fml::FlushType)  (in FlutterMacOS)"
        assert self_by[ft] == 0, self_by[ft]

        try:
            parse_log(write("not a perf log\n", ".log"))
        except ValueError:
            pass
        else:
            raise AssertionError("parse_log accepted a non-log file")
    finally:
        for p in paths:
            try:
                os.unlink(p)
            except OSError:
                pass
    print("selftest: all assertions passed")


# ---------------------------------------------------------------- dispatch ---

def main(argv):
    if "--selftest" in argv:
        selftest()
        return 0
    if len(argv) < 2:
        print((__doc__ or "").strip(), file=sys.stderr)
        return 2
    mode, path, rest = argv[0], argv[1], argv[2:]

    def opt(flag, default=None):
        return rest[rest.index(flag) + 1] if flag in rest else default

    try:
        if mode == "log":
            other = opt("--compare")
            print_log_report(summarise_log(path),
                             summarise_log(other) if other else None)
        elif mode == "sample":
            print_sample_report(path, opt("--thread"), int(opt("--top", 15)))
        else:
            print(f"unknown subcommand {mode!r}; expected 'log' or 'sample'",
                  file=sys.stderr)
            return 2
    except (ValueError, OSError, IndexError) as e:
        print(f"parse failure: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
