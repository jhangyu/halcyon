#!/usr/bin/env python3
"""Parse round-2 Halcyon perf logs (event-driven harness) into AC7 stats.

Usage: parse_r2.py <run.log> [<stdout.log with PERFNATIVE lines>]
"""
import sys
import statistics as st
from collections import defaultdict


def pct(xs, p):
    if not xs:
        return float("nan")
    xs = sorted(xs)
    if len(xs) == 1:
        return xs[0]
    k = (len(xs) - 1) * p
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def ms(us):
    return us / 1000.0


def kv(fields):
    out = {}
    for f in fields:
        if "=" in f:
            k, v = f.split("=", 1)
            out[k] = v
    return out


def load(path, prefix):
    evs = []
    with open(path, errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line.startswith(prefix + "|"):
                continue
            parts = line.split("|")
            try:
                ts = int(parts[1])
            except (IndexError, ValueError):
                continue
            evs.append((ts, parts[2], parts[3:]))
    return evs


def main():
    path = sys.argv[1]
    evs = load(path, "PERF")
    native = load(sys.argv[2], "PERFNATIVE") if len(sys.argv) > 2 else []

    print(f"# {path}")

    # ---- switch.begin, grouped per pass label, paired to the first
    # image.resolved for the same id at/after the switch ----
    switch_begins = [
        (ts, f[0], int(f[1]), f[2]) for ts, n, f in evs if n == "switch.begin"
    ]
    resolved_by_id = defaultdict(list)  # id -> [(ts, tier, sync, dur)]
    for ts, n, f in evs:
        if n != "image.resolved":
            continue
        d = kv(f)
        resolved_by_id[f[0]].append(
            (ts, int(d.get("tier", 0)), d.get("sync") == "true", int(d.get("dur", 0)))
        )
    for lst in resolved_by_id.values():
        lst.sort()

    def first_resolved_after(ident, t0):
        for ts, tier, sync, dur in resolved_by_id.get(ident, []):
            if ts >= t0:
                return ts, tier, sync, dur
        return None

    def upgrade_after(ident, t_first, t_next_switch):
        # a LATER tier=2 resolve for the same id, strictly after the first
        # resolve, before the id's next switch.begin (end of this occurrence)
        for ts, tier, sync, dur in resolved_by_id.get(ident, []):
            if ts > t_first and tier == 2 and (t_next_switch is None or ts < t_next_switch):
                return ts, sync, dur
        return None

    by_label = defaultdict(list)
    for i, (ts0, label, idx, ident) in enumerate(switch_begins):
        # next switch.begin for the SAME id (bounds the upgrade window)
        t_next = None
        for ts2, l2, i2, id2 in switch_begins[i + 1 :]:
            if id2 == ident:
                t_next = ts2
                break
        fr = first_resolved_after(ident, ts0)
        by_label[label].append((ts0, idx, ident, fr, t_next))

    print("\n## switch classification (select -> first resolve)\n")
    print("| pass | n switches | resolved | unresolved(VOID risk) |")
    print("|---|---|---|---|")
    all_void = False
    for label, rows in sorted(by_label.items()):
        resolved_n = sum(1 for r in rows if r[3] is not None)
        unresolved = len(rows) - resolved_n
        if unresolved:
            all_void = True
        print(f"| {label} | {len(rows)} | {resolved_n} | {unresolved} |")

    for label, rows in sorted(by_label.items()):
        hit = []  # tier1 sync=true
        miss = []  # tier1 sync=false
        t2imm = []  # tier2 sync=true on first resolve (immediate)
        other = []
        for ts0, idx, ident, fr, t_next in rows:
            if fr is None:
                continue
            _, tier, sync, dur = fr
            latency_us = fr[0] - ts0
            if tier == 1 and sync:
                hit.append(latency_us)
            elif tier == 1 and not sync:
                miss.append(latency_us)
            elif tier == 2 and sync:
                t2imm.append(latency_us)
            else:
                other.append(latency_us)

        def stat_line(name, vals):
            if not vals:
                return f"  {name}: n=0"
            over100 = sum(1 for v in vals if ms(v) > 100)
            return (
                f"  {name}: n={len(vals)} median={ms(st.median(vals)):.1f}ms "
                f"p95={ms(pct(vals,0.95)):.1f}ms max={ms(max(vals)):.1f}ms "
                f"count>100ms={over100}"
            )

        total_classified = len(hit) + len(miss) + len(t2imm) + len(other)
        hit_rate = (len(hit) / total_classified * 100) if total_classified else float("nan")
        print(f"\n### pass={label}  (hit rate defined as tier1-hit / all classified = {hit_rate:.1f}%)")
        print(stat_line("class1 tier1-HIT (sync=true)", hit))
        print(stat_line("class2 tier1-MISS (sync=false, on-demand decode)", miss))
        print(stat_line("class3 tier2-IMMEDIATE (landed on tier2 first build)", t2imm))
        print(stat_line("class4-other (unexpected tier/sync combo)", other))

        # tier-2 upgrade events (class 4 in the report taxonomy): for
        # switches that resolved on tier1 first, was there a later tier2
        # upgrade, and was the full-size entry actually complete then?
        upgrades = []
        for ts0, idx, ident, fr, t_next in rows:
            if fr is None or fr[1] != 1:
                continue
            up = upgrade_after(ident, fr[0], t_next)
            if up:
                upgrades.append(up)
        if upgrades:
            up_durs = [u[2] for u in upgrades]
            complete_at_swap = sum(1 for u in upgrades if u[1])  # sync=true means complete
            print(
                f"  tier2-UPGRADE (later swap after tier1): n={len(upgrades)} "
                f"median={ms(st.median(up_durs)):.1f}ms max={ms(max(up_durs)):.1f}ms "
                f"complete-at-swap(sync=true)={complete_at_swap}/{len(upgrades)}"
            )

    # ---- defects: anything *.timeout, i.e. >900ms wait that didn't settle ----
    print("\n## defects (waits that exceeded the 900ms cap)\n")
    defects = [(ts, n, f) for ts, n, f in evs if n.endswith(".timeout")]
    if not defects:
        print("  none")
    for ts, n, f in defects:
        print(f"  {n}|{'|'.join(f)}")

    # ---- deliberate scenario pacing vs wall clock ----
    print("\n## wall-clock decomposition per pass\n")
    pace_total = defaultdict(int)
    pace_begin = {}
    for ts, n, f in evs:
        if n == "scenario.pace.begin":
            pace_begin["x"] = ts
        elif n == "scenario.pace.end" and "x" in pace_begin:
            pass  # paired implicitly; sum via begin/end deltas below
    # simpler: sum consecutive begin/end pairs in order
    pace_events = [(ts, n, f) for ts, n, f in evs if n in ("scenario.pace.begin", "scenario.pace.end")]
    total_pace_us = 0
    open_ts = None
    for ts, n, f in pace_events:
        if n == "scenario.pace.begin":
            open_ts = ts
        elif n == "scenario.pace.end" and open_ts is not None:
            total_pace_us += ts - open_ts
            open_ts = None

    pass_bounds = {}
    for ts, n, f in evs:
        if n == "pass.begin":
            pass_bounds.setdefault(f[0], [None, None])[0] = ts
        if n == "pass.end":
            pass_bounds.setdefault(f[0], [None, None])[1] = ts
    for label, (t0, t1) in sorted(pass_bounds.items()):
        if t0 is None or t1 is None:
            continue
        wall = t1 - t0
        print(
            f"  pass={label}: wall={ms(wall):.0f}ms "
            f"(deliberate scenario pacing counted globally below, "
            f"paced-pass pacing = n_switches * 400ms)"
        )
    print(f"  total deliberate scenario.pace time (all passes): {ms(total_pace_us):.0f}ms")

    other_over1s = [
        (ts, n, f) for ts, n, f in evs
        if n in ("folder.load.end",) and int(kv(f).get("dur", 0)) > 1000000
    ]
    print("\n## non-paced operations over 1s (folder.load etc.)\n")
    if not other_over1s:
        print("  none")
    for ts, n, f in other_over1s:
        print(f"  {n}|{'|'.join(f)}")

    # ---- view.spinner (user-visible stall / outrun evidence) ----
    spinners = [f[0] for _, n, f in evs if n == "view.spinner"]
    print(f"\n## view.spinner events (bytes not yet loaded for selected item): {len(spinners)}")
    if spinners:
        print(f"  ids: {spinners}")

    # ---- native (Swift) side ----
    if native:
        nat = defaultdict(list)
        for _, n, f in native:
            d = kv(f)
            if n == "result.dispatch" and "nativeTotal" in d:
                nat["nativeTotal"].append(int(d["nativeTotal"]))
            if n == "jpegPassthrough.read" and "dur" in d:
                nat["jpegPassthroughRead"].append(int(d["dur"]))
            if n == "decoded" and "dur" in d:
                nat["rawExtractDecode"].append(int(d["dur"]))
            if n == "reencode" and "dur" in d:
                nat["reencode"].append(int(d["dur"]))
            if n == "bg.start" and "queueWait" in d:
                nat["queueWait"].append(int(d["queueWait"]))
        print("\n## native (Swift) stages\n")
        for k, v in nat.items():
            over1s = sum(1 for x in v if ms(x) > 1000)
            print(
                f"  {k}: n={len(v)} median={ms(st.median(v)):.1f}ms "
                f"p95={ms(pct(v,0.95)):.1f}ms max={ms(max(v)):.1f}ms "
                f"count>1000ms(DEFECT)={over1s}"
            )

    if all_void:
        print("\n## VOID WARNING: at least one switch.begin never got a matching image.resolved -- treat this run's numbers as suspect per the (id,occurrence) mismatch rule.")


if __name__ == "__main__":
    main()
