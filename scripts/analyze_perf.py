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


def stall_attribution(events, window_us=10_000):
    """H2 copy-vs-GC discriminator: attribute each stall to an adjacent
    payload-landing event.

    A stall that ENDS just before a `pool.materialize` / `decode.ffi` line is
    the signature of the ~97MB decode payload landing on the UI isolate. With
    the pool.materialize instrumentation (ceyx decode_pool.dart) we can now
    split those into:
      - materialize-explained: the measured materialize duration covers >=50%
        of the stall -> the cost IS the materialize/copy step;
      - candidate-GC: a landing is adjacent but the measured materialize was
        too small to explain the stall -> the blockage is elsewhere in the
        landing (heap admission / GC pause being the prime suspect);
      - unattributed: nothing overlaps or follows the stall.
    NOTE: `decode.ffi`'s own dur_us is WORKER wall time, never counted as
    on-main cost.

    OVERLAP vs ADJACENCY (jank-rootcause-analysis.md §6 probe 4). The original
    rule was adjacency only: a landing had to appear within `window_us` AFTER
    the stall line, and the landing list held `pool.materialize`/`decode.ffi`
    but NOT `materialize`. Both halves of that were wrong for the dominant
    cost. `materialize` (`ui.decodeImageFromPixels`, the ~92MB engine-buffer
    copy plus GPU upload) runs 100-258ms in real captures, so its line lands
    far outside any 10ms post-window, and the stalls it causes happen DURING
    it, not before it. Excluding it reported 78 of 104 stalls as
    "unattributed" in capture_222859 -- the analyser's blind spot reading as a
    finding about GC. An event with a measured duration is therefore now
    matched by INTERVAL OVERLAP (`end - dur_us` .. `end` against the stall's
    own `ms` window); zero-duration adjacency is kept only for `decode.ffi`,
    which has no on-main interval to overlap with.
    """
    stalls = [(us, int(kv["ms"])) for us, name, kv in events
              if name == "stall" and "ms" in kv]
    # Cumulative-mode logs carry running totals; convert to per-gap deltas so
    # the ms compared against materialize durations is the actual gap.
    if len(stalls) >= 2:
        span_s = (events[-1][0] - events[0][0]) / 1e6
        if stall_analysis(events, span_s)["mode"].startswith("cumulative"):
            stalls = [(b_us, max(0, b - a))
                      for (_, a), (b_us, b) in zip(stalls, stalls[1:])]
    landings = [(us, name, kv) for us, name, kv in events
                if name in ("materialize", "pool.materialize", "decode.ffi")]
    rows, explained, gc_cand, unattributed = [], 0, 0, 0
    explained_ms, gc_ms = 0, 0
    for sus, ms in stalls:
        # The stall itself spans [sus - ms, sus]: the probe reports drift it has
        # ALREADY observed, so the blockage precedes the line.
        s_start = sus - ms * 1000
        near = []
        for us, name, kv in landings:
            if name == "decode.ffi":
                # Worker wall time; only its landing instant is on-main.
                if 0 <= us - sus <= window_us:
                    near.append((0, us - sus, name, kv, None))
                continue
            dur = int(kv.get("dur_us", 0))
            # Overlap of [us - dur, us] with [s_start, sus], in microseconds.
            overlap = min(us, sus) - max(us - dur, s_start)
            if overlap > 0:
                near.append((-overlap, us - sus, name, kv, dur))
            elif 0 <= us - sus <= window_us:
                near.append((0, us - sus, name, kv, dur))
        if not near:
            unattributed += 1
            continue
        # Best = largest overlap; ties (adjacency-only matches) fall back to the
        # nearest landing, which is what the original rule picked.
        neg_overlap, gap, name, kv, mat_us = min(near, key=lambda r: (r[0], r[1]))
        covered_us = -neg_overlap
        # >=50% of the stall accounted for, by overlap where there is one and by
        # the raw duration where the match was adjacency-only.
        share_us = covered_us or (mat_us or 0)
        if share_us >= ms * 500:
            explained += 1
            explained_ms += ms
            verdict = "materialize-explained"
        else:
            gc_cand += 1
            gc_ms += ms
            verdict = "candidate-GC"
        rows.append((sus, ms, name, gap, mat_us, verdict))
    return {
        "n": len(stalls),
        "explained": explained,
        "explained_ms": explained_ms,
        "gc_candidate": gc_cand,
        "gc_candidate_ms": gc_ms,
        "unattributed": unattributed,
        "has_materialize": any(n == "pool.materialize" for _, n, _ in landings),
        "rows": rows,
    }


def rotation_acceptance(events):
    """AC-9.1 (native-rotation-spec.md sec 6.3): the four-clause verdict from
    ONE capture, no baseline comparison.

    Four raw counts feed the verdict:
      - reencode.submit|path=byte   (and path=pointer, kept for context)
      - full-frame `materialize|` events
      - reencode.copy| lines
      - orient|rotated=true lines

    `materialize|` has FOUR producers in this codebase (decoded_rgba_image_
    provider.dart's full-res route, sidebar_thumbnail_codec.dart, raw_pixels_
    image.dart's tier-1 route, and tier_two_scheduler.dart's piggyback route).
    This is NOT `pool.materialize|`, a wholly separate event already consumed
    by stall_attribution() above; conflating the two would silently corrupt
    both readings.

    PRIMARY (fix cycle 1, round-2 review counterexample): the full-res call
    site (decoded_rgba_image_provider.dart's `decodedRgbaToOrientedFullRes`)
    now appends `|src=fullres` -- an exact, unambiguous tag. Count those
    directly. The three other producers never emit `src=` at all.

    FALLBACK, for logs captured before that tag existed (or any future
    untagged full-res producer): a `materialize|` line with no `src=` is
    still counted as "full-frame" if its `bytes=` also occurs among this
    capture's `reencode.submit|` lines (multiset match via Counter min) --
    `reencode.submit|` only ever fires on the full-resolution buffer that
    feeds the re-encoder, on both the byte and pointer arms. BUT that join
    silently reads zero when a full-res materialize ran and the reencode was
    then skipped or failed (the round-2 counterexample) -- a materialize with
    no matching submit is invisible to it. To close that hole, any leftover
    untagged materialize whose `bytes=` is >= the smallest `reencode.submit|`
    bytes seen in this same capture (i.e. at least as big as a KNOWN full-res
    buffer, so it cannot be a thumbnail or tier-1 window-res decode) is also
    counted, as an "unmatched full-frame candidate" -- surfaced separately in
    the report so a reader can see WHY the clause is nonzero even without an
    exact byte match.
    """
    reencode_submit_bytes = Counter()
    submit_path = Counter()
    copy_n = 0
    materialize_bytes = Counter()          # untagged (no src=) materialize
    fullres_tagged_n = 0                   # src=fullres materialize
    rotated_true = 0
    orient_n = 0
    applied_mismatch = 0
    residual_non1 = 0
    orient_shape_new = 0
    degraded_n = 0

    for _, name, kv in events:
        if name == "reencode.submit":
            submit_path[kv.get("path", "?")] += 1
            if "bytes" in kv:
                reencode_submit_bytes[int(kv["bytes"])] += 1
        elif name == "reencode.copy":
            copy_n += 1
        elif name == "materialize" and "bytes" in kv:
            if kv.get("src") == "fullres":
                fullres_tagged_n += 1
            else:
                materialize_bytes[int(kv["bytes"])] += 1
        elif name == "orient":
            orient_n += 1
            if kv.get("rotated") == "true":
                rotated_true += 1
            if "applied" in kv and "exif" in kv:
                orient_shape_new += 1
                if kv["applied"] != kv["exif"]:
                    applied_mismatch += 1
            if "residual" in kv and kv["residual"] != "1":
                residual_non1 += 1
        elif name == "orient.degraded":
            degraded_n += 1

    joined_untagged = sum(
        min(n, reencode_submit_bytes.get(b, 0))
        for b, n in materialize_bytes.items()
    )
    unmatched_candidates = 0
    if reencode_submit_bytes:
        smallest_submit = min(reencode_submit_bytes)
        for b, n in materialize_bytes.items():
            leftover = n - min(n, reencode_submit_bytes.get(b, 0))
            if leftover > 0 and b >= smallest_submit:
                unmatched_candidates += leftover

    full_frame_materialize = (
        fullres_tagged_n + joined_untagged + unmatched_candidates
    )

    byte_n = submit_path.get("byte", 0)
    pointer_n = submit_path.get("pointer", 0)

    if rotated_true == 0:
        verdict = "VOID"
    elif byte_n == 0 and full_frame_materialize == 0 and copy_n == 0:
        verdict = "PASS"
    else:
        verdict = "FAIL"

    return {
        "verdict": verdict,
        "reencode_submit_byte": byte_n,
        "reencode_submit_pointer": pointer_n,
        "full_frame_materialize": full_frame_materialize,
        "full_frame_materialize_tagged": fullres_tagged_n,
        "full_frame_materialize_joined": joined_untagged,
        "full_frame_materialize_unmatched": unmatched_candidates,
        "reencode_copy": copy_n,
        "orient_rotated_true": rotated_true,
        "orient_n": orient_n,
        "orient_new_shape_n": orient_shape_new,
        "orient_applied_exif_mismatch": applied_mismatch,
        "orient_residual_non1": residual_non1,
        "orient_degraded_n": degraded_n,
    }


def print_rotation_report(r):
    print("\n== AC-9.1 native-rotation acceptance")
    if r["orient_n"] == 0 and r["reencode_submit_byte"] == 0 and \
            r["reencode_submit_pointer"] == 0 and r["reencode_copy"] == 0:
        print("   no orient|/reencode.*| lines in this log -- capture "
              "predates the instrumentation or the rotation code path never "
              "ran; nothing to gate.")
        return
    print(f"   verdict: {r['verdict']}")
    print(f"   reencode.submit|path=byte:  {r['reencode_submit_byte']}")
    print(f"   reencode.submit|path=pointer: {r['reencode_submit_pointer']}")
    print(f"   full-frame materialize|:    {r['full_frame_materialize']} "
          f"(tagged src=fullres: {r['full_frame_materialize_tagged']}, "
          f"bytes-joined: {r['full_frame_materialize_joined']}, "
          f"unmatched candidates: {r['full_frame_materialize_unmatched']})")
    if r["full_frame_materialize_unmatched"] > 0:
        print("   NOTE: unmatched candidates are untagged materialize| lines "
              "as big as this capture's smallest reencode.submit| buffer "
              "with no exact byte match -- likely a full-res materialize "
              "whose reencode was skipped or failed after it ran.")
    print(f"   reencode.copy|:             {r['reencode_copy']}")
    print(f"   orient|rotated=true:        {r['orient_rotated_true']} "
          f"(of {r['orient_n']} orient| lines)")
    if r["verdict"] == "VOID":
        print("   VOID (AC-9.2): orient|rotated=true == 0 -- this capture "
              "had no rotated photos and must be retaken.")
    print("-- recorded, not gating (AC-9.3):")
    if r["orient_new_shape_n"] == 0:
        print("   old-shape orient| lines only (no applied=/residual= "
              "fields) -- mismatch/residual counts unavailable.")
    else:
        print(f"   orient|applied= != orient|exif=: "
              f"{r['orient_applied_exif_mismatch']} of {r['orient_new_shape_n']}")
        print(f"   orient|residual= != 1: {r['orient_residual_non1']} of "
              f"{r['orient_new_shape_n']}")
    print(f"   orient.degraded| lines: {r['orient_degraded_n']}")


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
        "stall_attr": stall_attribution(events),
        "rotation": rotation_acceptance(events),
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
        attr = s["stall_attr"]
        print(f"-- stall attribution (copy-vs-GC discriminator, "
              f"{attr['n']} stalls):")
        if not attr["has_materialize"]:
            print("   no pool.materialize events in this log -- capture "
                  "predates the instrumentation; only decode.ffi adjacency "
                  "available, so 'candidate-GC' below really means "
                  "'adjacent-but-unmeasured'.")
        print(f"   materialize-explained: {attr['explained']} "
              f"({attr['explained_ms']} ms)  candidate-GC: "
              f"{attr['gc_candidate']} ({attr['gc_candidate_ms']} ms)  "
              f"unattributed: {attr['unattributed']}")
        for sus, ms, name, gap, mat_us, verdict in attr["rows"][:12]:
            mat = f" materialize_us={mat_us}" if mat_us is not None else ""
            # `gap` is the landing line's offset from the stall line and is
            # NEGATIVE whenever the match was an overlap by an event still
            # running when the stall was reported.
            print(f"   stall {ms:>4} ms at {sus/1e6:>7.3f}s -> {name} "
                  f"(gap {gap:+d} us{mat}) {verdict}")
        if len(attr["rows"]) > 12:
            print(f"   ... {len(attr['rows']) - 12} more attributed stalls")
        print_rotation_report(s["rotation"])


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

LOG_FIXTURE_ATTRIBUTION = """PERF|1000|nav|id=a
PERF|10000|stall|ms=20
PERF|11000|pool.materialize|dur_us=18000|bytes=96962304|type=decode|iso=main
PERF|30000|stall|ms=30
PERF|31000|pool.materialize|dur_us=500|bytes=96962304|type=decode|iso=main
PERF|50000|stall|ms=15
PERF|52000|decode.ffi|id=x|bytes=96962304|dur_us=2978093|iso=main
PERF|70000|stall|ms=10
PERF|1000100|nav|id=b
"""

# Probe 4: the case the old adjacency rule could not see. The stall spans
# 100..200ms and the `materialize` that caused it does not LOG until 260ms --
# 60ms past even a generous post-window -- but its interval (260-200=60ms ..
# 260ms) covers the stall completely.
LOG_FIXTURE_OVERLAP = """PERF|1000|nav|id=a
PERF|200000|stall|ms=100
PERF|260000|materialize|id=7|bytes=96962304|dur_us=200000|iso=main
PERF|1000100|nav|id=b
"""

# AC-9.1 fixtures. `PASS_LOG` is the shape a landed fix should produce: two
# natively-oriented items take the pointer path with residual=1 (rotated=
# false -- the common case once native orientation lands, see AC-7.5), plus
# one item that still reports `rotated=true` -- covering AC-9.1's 4th-clause
# guard -- yet also lands on the pointer arm with zero materialize/copy (the
# instrument must recognise this as a clean PASS regardless of how a given
# ceyx build produces that combination; that decoder-level question is out of
# this script's scope).
ROTATION_LOG_PASS = """PERF|1000|nav|id=a
PERF|2000|orient|exif=6|applied=6|residual=1|rotated=false|bytes=96962304
PERF|3000|reencode.submit|id=1|path=pointer|bytes=96962304
PERF|4000|reencode.end|id=1|dur_us=9000|bytes=500000
PERF|5000|orient|exif=1|applied=1|residual=1|rotated=false|bytes=44236800
PERF|6000|reencode.submit|id=2|path=pointer|bytes=44236800
PERF|7000|reencode.end|id=2|dur_us=8000|bytes=400000
PERF|8000|orient|exif=6|applied=1|residual=6|rotated=true|bytes=50000000
PERF|9000|reencode.submit|id=3|path=pointer|bytes=50000000
PERF|9500|reencode.end|id=3|dur_us=9000|bytes=450000
PERF|1000100|nav|id=b
"""

# `RED_LOG` reproduces the pre-fix baseline shape (capture_225634): a rotated
# item takes the byte arm, pays a full-frame materialize (bytes match the
# reencode.submit bytes) and a copy. A same-sized thumbnail materialize is
# included as a negative control: its bytes (12000) never appear in any
# reencode.submit line, so it must NOT be counted as full-frame.
ROTATION_LOG_RED = """PERF|1000|nav|id=a
PERF|1500|materialize|id=9|bytes=12000|dur_us=500
PERF|2000|orient|exif=6|applied=1|residual=6|rotated=true|bytes=96962304
PERF|2500|materialize|id=1|bytes=96962304|dur_us=107800
PERF|3000|reencode.submit|id=1|path=byte|bytes=96962304
PERF|3200|reencode.copy|id=1|dur_us=10600|bytes=96962304
PERF|4000|reencode.end|id=1|dur_us=118400|bytes=500000
PERF|1000100|nav|id=b
"""

# No rotated photos in the workload at all -> VOID per AC-9.2, even though
# the three zero-clauses would otherwise read as a (meaningless) PASS.
ROTATION_LOG_VOID = """PERF|1000|nav|id=a
PERF|2000|orient|exif=1|applied=1|residual=1|rotated=false|bytes=44236800
PERF|3000|reencode.submit|id=1|path=pointer|bytes=44236800
PERF|1000100|nav|id=b
"""

# Old-shape orient| lines (pre-Task-7: no applied=/residual=) must not crash
# the parser and must still drive the pass/fail clauses off `rotated=`.
ROTATION_LOG_OLDSHAPE = """PERF|1000|nav|id=a
PERF|2000|orient|exif=6|rotated=true|bytes=96962304
PERF|3000|reencode.submit|id=1|path=pointer|bytes=96962304
PERF|1000100|nav|id=b
"""

# Round-2 review counterexample (fix cycle 1): a natively-oriented item whose
# residual is identity (rotated=true is the DECLARED-vs-nothing flag here,
# see the reviewer's log verbatim) still pays a full-res `ui.decodeImageFromP
# ixels` (107.8ms) BEFORE the pointer path decides the reencode.submit| bytes
# it ends up shipping are smaller (50_000_000, e.g. a downstream crop/fallback
# thunk) -- so the materialize's bytes=96962304 never appears among this
# capture's reencode.submit| bytes. Under the OLD bytes-join-only logic this
# read full_frame_materialize=0 (a false PASS); the materialize is untagged
# (no src=fullres, simulating a log captured before that tag existed) so the
# fix must catch it via the unmatched-candidate fallback (96962304 >=
# smallest submit bytes 50_000_000).
ROTATION_LOG_ADVERSARIAL_SKIP = """PERF|1000|nav|id=a
PERF|2000|orient|exif=6|applied=6|residual=1|rotated=true|bytes=96962304
PERF|2500|materialize|id=1|bytes=96962304|dur_us=107800
PERF|3000|reencode.submit|id=1|path=pointer|bytes=50000000
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

        # No landing events at all -> everything unattributed, flag says the
        # capture predates the pool.materialize instrumentation.
        assert s["stall_attr"]["has_materialize"] is False
        assert s["stall_attr"]["explained"] == 0
        assert s["stall_attr"]["unattributed"] == s["stall_attr"]["n"]

        p = write(LOG_FIXTURE_ATTRIBUTION, ".log")
        paths.append(p)
        a = summarise_log(p)["stall_attr"]
        assert a["has_materialize"] is True
        assert a["n"] == 4, a
        # 18ms materialize inside a 20ms stall (>=50%) -> copy-explained.
        assert a["explained"] == 1 and a["explained_ms"] == 20, a
        # 0.5ms materialize under a 30ms stall, and a decode.ffi-adjacent
        # stall (worker dur_us never counts as on-main cost) -> candidate GC.
        assert a["gc_candidate"] == 2 and a["gc_candidate_ms"] == 45, a
        assert a["unattributed"] == 1, a
        verdicts = [row[5] for row in a["rows"]]
        assert verdicts == ["materialize-explained", "candidate-GC",
                            "candidate-GC"], verdicts

        p = write(LOG_FIXTURE_OVERLAP, ".log")
        paths.append(p)
        o = summarise_log(p)["stall_attr"]
        # Adjacency alone would call this unattributed (the line is 60ms after
        # the stall); interval overlap attributes it to the materialize.
        assert o["n"] == 1, o
        assert o["unattributed"] == 0, o
        assert o["explained"] == 1 and o["explained_ms"] == 100, o
        assert o["rows"][0][2] == "materialize", o["rows"]

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

        p = write(ROTATION_LOG_PASS, ".log")
        paths.append(p)
        r = summarise_log(p)["rotation"]
        assert r["verdict"] == "PASS", r
        assert r["reencode_submit_byte"] == 0, r
        assert r["full_frame_materialize"] == 0, r
        assert r["reencode_copy"] == 0, r
        assert r["orient_rotated_true"] == 1, r  # the 4th-clause guard item

        p = write(ROTATION_LOG_RED, ".log")
        paths.append(p)
        r = summarise_log(p)["rotation"]
        assert r["verdict"] == "FAIL", r
        assert r["reencode_submit_byte"] == 1, r
        assert r["full_frame_materialize"] == 1, r  # NOT the 12000-byte thumbnail
        assert r["reencode_copy"] == 1, r
        assert r["orient_rotated_true"] == 1, r
        assert r["orient_applied_exif_mismatch"] == 1, r  # applied=1 != exif=6
        assert r["orient_residual_non1"] == 1, r  # residual=6

        # Red proof per clause: take the RED fixture (already FAIL) and flip
        # ONE clause at a time toward the PASS fixture's shape; verdict must
        # stay FAIL until ALL three zero-clauses are satisfied and the guard
        # clause is non-zero. Demonstrates each clause actually gates.
        no_byte = ROTATION_LOG_RED.replace("path=byte", "path=pointer")
        p = write(no_byte, ".log")
        paths.append(p)
        r = summarise_log(p)["rotation"]
        assert r["reencode_submit_byte"] == 0, r
        assert r["verdict"] == "FAIL", r  # copy/materialize still nonzero

        no_copy = no_byte.replace(
            "PERF|3200|reencode.copy|id=1|dur_us=10600|bytes=96962304\n", "")
        p = write(no_copy, ".log")
        paths.append(p)
        r = summarise_log(p)["rotation"]
        assert r["reencode_copy"] == 0, r
        assert r["verdict"] == "FAIL", r  # materialize still nonzero

        no_materialize = no_copy.replace(
            "PERF|2500|materialize|id=1|bytes=96962304|dur_us=107800\n", "")
        p = write(no_materialize, ".log")
        paths.append(p)
        r = summarise_log(p)["rotation"]
        assert r["full_frame_materialize"] == 0, r
        assert r["verdict"] == "PASS", r  # all three zero-clauses now hold,
        # and orient|rotated=true==1 satisfies the guard.
        assert r["orient_rotated_true"] == 1, r

        p = write(ROTATION_LOG_VOID, ".log")
        paths.append(p)
        r = summarise_log(p)["rotation"]
        assert r["verdict"] == "VOID", r  # AC-9.2: rotated=true == 0

        p = write(ROTATION_LOG_OLDSHAPE, ".log")
        paths.append(p)
        r = summarise_log(p)["rotation"]
        assert r["verdict"] == "PASS", r
        assert r["orient_new_shape_n"] == 0, r  # no applied=/residual= fields
        assert r["orient_applied_exif_mismatch"] == 0, r
        assert r["orient_residual_non1"] == 0, r

        # Round-2 review counterexample (fix cycle 1): materialize's bytes
        # never appear among reencode.submit bytes -> the old bytes-join-only
        # logic would have read full_frame_materialize=0 (a false PASS, since
        # rotated_true=1 and byte/copy are both 0 here). The unmatched-
        # candidate fallback must catch it: RED (would-be PASS) -> GREEN
        # (correctly FAIL) under the fixed logic.
        p = write(ROTATION_LOG_ADVERSARIAL_SKIP, ".log")
        paths.append(p)
        r = summarise_log(p)["rotation"]
        assert r["full_frame_materialize_tagged"] == 0, r    # no src= tag
        assert r["full_frame_materialize_joined"] == 0, r    # bytes don't match
        assert r["full_frame_materialize_unmatched"] == 1, r  # caught here
        assert r["full_frame_materialize"] == 1, r
        assert r["verdict"] == "FAIL", r  # was silently PASS before the fix

        # `src=fullres` tagged materialize (fix cycle 1 primary signal): exact
        # count, no byte-size inference needed, and must NOT be double-counted
        # by the bytes-join/unmatched fallback (its bytes also happen to match
        # a same-session reencode.submit| line here, on purpose).
        ROTATION_LOG_TAGGED = """PERF|1000|nav|id=a
PERF|2000|orient|exif=6|applied=1|residual=6|rotated=true|bytes=96962304
PERF|2500|materialize|id=1|bytes=96962304|dur_us=107800|src=fullres
PERF|3000|reencode.submit|id=1|path=byte|bytes=96962304
PERF|3200|reencode.copy|id=1|dur_us=10600|bytes=96962304
PERF|1000100|nav|id=b
"""
        p = write(ROTATION_LOG_TAGGED, ".log")
        paths.append(p)
        r = summarise_log(p)["rotation"]
        assert r["full_frame_materialize_tagged"] == 1, r
        assert r["full_frame_materialize_joined"] == 0, r    # not double-counted
        assert r["full_frame_materialize_unmatched"] == 0, r
        assert r["full_frame_materialize"] == 1, r
        assert r["verdict"] == "FAIL", r  # byte-arm + copy also nonzero here

        # No relevant lines at all -> clean "no data", no crash.
        p = write("PERF|1000|nav|id=a\nPERF|1000100|nav|id=b\n", ".log")
        paths.append(p)
        r = summarise_log(p)["rotation"]
        assert r["verdict"] == "VOID", r  # rotated_true == 0 by construction
        assert r["orient_n"] == 0, r

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
