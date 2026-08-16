#!/usr/bin/env python3
"""Parse instrumented Halcyon perf logs into per-stage statistics.

Usage: parse.py <run.log> [<stdout.log>]
Emits a markdown-ish summary on stdout.
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


def load(path):
    evs = []
    with open(path, errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line.startswith("PERF|"):
                continue
            parts = line.split("|")
            try:
                ts = int(parts[1])
            except (IndexError, ValueError):
                continue
            evs.append((ts, parts[2], parts[3:]))
    return evs


def load_native(path):
    evs = []
    try:
        f = open(path, errors="replace")
    except OSError:
        return evs
    with f:
        for line in f:
            line = line.strip()
            if not line.startswith("PERFNATIVE|"):
                continue
            parts = line.split("|")
            try:
                ts = int(parts[1])
            except (IndexError, ValueError):
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


def ms(us):
    return us / 1000.0


def main():
    path = sys.argv[1]
    evs = load(path)
    native = load_native(sys.argv[2]) if len(sys.argv) > 2 else []

    # index events by (name, id) -> list of timestamps
    by_name_id = defaultdict(list)
    for ts, name, fields in evs:
        ident = fields[0] if fields else ""
        by_name_id[(name, ident)].append(ts)

    def first_after(name, ident, t):
        for ts in by_name_id.get((name, ident), []):
            if ts >= t:
                return ts
        return None

    switches = []
    cur_label = None
    for i, (ts, name, fields) in enumerate(evs):
        if name == "pass.begin":
            cur_label = fields[0]
        if name != "switch.begin":
            continue
        label, idx, ident = fields[0], int(fields[1]), fields[2]
        t0 = ts
        # cache decision
        hit = None
        for ts2, n2, f2 in evs[i : i + 12]:
            if n2 in ("cache.hit", "cache.miss") and f2 and f2[0] == ident:
                hit = n2 == "cache.hit"
                break
        tb = first_after("view.bytesAvailable", ident, t0)
        td = first_after("image.decoded", ident, t0)
        tp = first_after("image.painted", ident, t0)
        te = None
        for ts2, n2, f2 in evs[i:]:
            if n2 in ("switch.end", "switch.timeout") and len(f2) > 2 and f2[2] == ident:
                te = ts2
                break
        # channel roundtrip for this id, if any, after t0
        chan = None
        for ts2, n2, f2 in evs[i:]:
            if n2 == "channel.preview" and f2 and f2[0] == ident:
                chan = int(kv(f2).get("roundtrip", 0))
                break
            if n2 == "switch.begin" and ts2 > t0:
                break
        switches.append(
            dict(
                label=label or cur_label,
                i=idx,
                id=ident,
                hit=hit,
                t0=t0,
                tb=tb,
                td=td,
                tp=tp,
                te=te,
                chan=chan,
            )
        )

    print(f"# parsed {len(switches)} switches from {path}\n")

    groups = defaultdict(list)
    for s in switches:
        key = (s["label"], "hit" if s["hit"] else "miss")
        groups[key].append(s)

    print("| pass | cache | n | stage | median ms | p95 ms | max ms |")
    print("|---|---|---|---|---|---|---|")
    for key in sorted(groups):
        rows = groups[key]
        stages = {
            "A select->bytesAvailable": [
                s["tb"] - s["t0"] for s in rows if s["tb"] is not None
            ],
            "B bytes->decoded": [
                s["td"] - s["tb"] for s in rows if s["td"] and s["tb"]
            ],
            "C decoded->painted": [
                s["tp"] - s["td"] for s in rows if s["tp"] and s["td"]
            ],
            "TOTAL select->painted": [
                s["tp"] - s["t0"] for s in rows if s["tp"] is not None
            ],
        }
        for sname, vals in stages.items():
            if not vals:
                continue
            print(
                f"| {key[0]} | {key[1]} | {len(vals)} | {sname} | "
                f"{ms(st.median(vals)):.1f} | {ms(pct(vals,0.95)):.1f} | {ms(max(vals)):.1f} |"
            )

    # channel roundtrips observed for the *selected* item (critical path)
    crit = [
        int(kv(f).get("roundtrip", 0))
        for _, n, f in evs
        if n == "channel.preview" and kv(f).get("isSelected") == "true"
    ]
    allch = [
        int(kv(f).get("roundtrip", 0))
        for _, n, f in evs
        if n == "channel.preview"
    ]
    print()
    if crit:
        print(
            f"channel.preview on critical path (isSelected=true): n={len(crit)} "
            f"median={ms(st.median(crit)):.1f}ms p95={ms(pct(crit,0.95)):.1f}ms"
        )
    if allch:
        print(
            f"channel.preview all (incl. background window): n={len(allch)} "
            f"median={ms(st.median(allch)):.1f}ms p95={ms(pct(allch,0.95)):.1f}ms"
        )

    # microbench
    for tag in ("micro.channel", "micro.decode", "micro.decode1800", "micro.fileread"):
        vals = []
        dims = set()
        for _, n, f in evs:
            if n != tag:
                continue
            d = kv(f)
            key = "roundtrip" if tag == "micro.channel" else ("dur" if tag == "micro.fileread" else "total")
            if key in d:
                vals.append(int(d[key]))
            for x in f:
                if "x" in x and x.replace("x", "").isdigit():
                    dims.add(x)
        if vals:
            print(
                f"{tag}: n={len(vals)} median={ms(st.median(vals)):.1f}ms "
                f"p95={ms(pct(vals,0.95)):.1f}ms min={ms(min(vals)):.1f} max={ms(max(vals)):.1f} "
                f"dims={sorted(dims)[:3]}"
            )

    # slow frames
    slow = [(int(kv(f).get("build", 0)), int(kv(f).get("raster", 0)), int(kv(f).get("total", 0)))
            for _, n, f in evs if n == "frame.slow"]
    if slow:
        print(
            f"\nframe.slow (>20ms total): n={len(slow)} "
            f"median build={ms(st.median([s[0] for s in slow])):.1f}ms "
            f"median raster={ms(st.median([s[1] for s in slow])):.1f}ms "
            f"max total={ms(max(s[2] for s in slow)):.1f}ms"
        )

    # spinner occurrences (visible loading state = user-visible stall)
    spinners = [f[0] for _, n, f in evs if n == "view.spinner"]
    print(f"\nview.spinner events (user-visible loading placeholder): {len(spinners)}")
    timeouts = [f for _, n, f in evs if n == "switch.timeout"]
    print(f"switch.timeout events: {len(timeouts)}")

    # native breakdown
    if native:
        nat = defaultdict(list)
        for _, n, f in native:
            d = kv(f)
            if n == "result.dispatch" and "nativeTotal" in d:
                nat["nativeTotal"].append(int(d["nativeTotal"]))
            if n == "jpegPassthrough.read" and "dur" in d:
                nat["jpegRead"].append(int(d["dur"]))
            if n == "bg.start" and "queueWait" in d:
                nat["queueWait"].append(int(d["queueWait"]))
            if n == "decoded" and "dur" in d:
                nat["rawDecode"].append(int(d["dur"]))
            if n == "reencode" and "dur" in d:
                nat["reencode"].append(int(d["dur"]))
        print("\nnative stages (us -> ms):")
        for k, v in nat.items():
            print(
                f"  {k}: n={len(v)} median={ms(st.median(v)):.1f}ms "
                f"p95={ms(pct(v,0.95)):.1f}ms max={ms(max(v)):.1f}ms"
            )


if __name__ == "__main__":
    main()
