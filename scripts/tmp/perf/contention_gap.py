#!/usr/bin/env python3
"""Per-block gap = nativeTotal - (queueWait + [decoded|dngPassthrough.read] + reencode).
Large positive gap = time not accounted for by measured stages, i.e. wait
(e.g. main-thread dispatch contention). Uses parse_r2.ms/pct, unmodified.
"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from parse_r2 import pct, ms
import statistics as st
from collections import defaultdict

def main():
    path = sys.argv[1]
    lines = [l.strip() for l in open(path, errors="replace") if l.startswith("PERFNATIVE|")]
    events = [(int(l.split("|")[1]), l.split("|")[2], l.split("|")[3:]) for l in lines]
    events.sort()
    open_blocks = defaultdict(list)
    closed = []
    for ts, name, f in events:
        fn = f[0] if f else None
        if name == "handler.enter":
            purpose = f[1] if len(f) > 1 else "?"
            open_blocks[fn].append({"purpose": purpose, "queueWait": 0, "stage": 0, "reencode": 0})
        elif name == "bg.start":
            if open_blocks[fn]:
                d = dict(x.split("=") for x in f[1:] if "=" in x)
                open_blocks[fn][-1]["queueWait"] = int(d.get("queueWait", 0))
        elif name in ("decoded", "dngPassthrough.read", "jpegPassthrough.read"):
            if open_blocks[fn]:
                d = dict(x.split("=") for x in f[1:] if "=" in x)
                open_blocks[fn][-1]["stage"] += int(d.get("dur", 0))
        elif name == "dngPassthrough.miss":
            if open_blocks[fn]:
                d = dict(x.split("=") for x in f[1:] if "=" in x)
                open_blocks[fn][-1]["stage"] += int(d.get("dur", 0))
        elif name == "reencode":
            if open_blocks[fn]:
                d = dict(x.split("=") for x in f[1:] if "=" in x)
                open_blocks[fn][-1]["reencode"] = int(d.get("dur", 0))
        elif name == "result.dispatch":
            if open_blocks[fn]:
                blk = open_blocks[fn].pop(0)
                d = dict(x.split("=") for x in f[1:] if "=" in x)
                blk["nativeTotal"] = int(d.get("nativeTotal", -1))
                blk["gap"] = blk["nativeTotal"] - (blk["queueWait"] + blk["stage"] + blk["reencode"])
                blk["filename"] = fn
                closed.append(blk)

    groups = defaultdict(list)
    for b in closed:
        if "nativeTotal" not in b:
            continue
        key = b["purpose"]
        groups[key].append(b)

    print(f"# {path}")
    for k, rows in sorted(groups.items()):
        gaps = [r["gap"] for r in rows]
        gaps_pos = [g for g in gaps if g > 0]
        print(f"purpose={k} n={len(rows)} gap: median={ms(st.median(gaps)):.2f}ms "
              f"p95={ms(pct(gaps,0.95)):.2f}ms max={ms(max(gaps)):.2f}ms "
              f"n_gap>0={len(gaps_pos)} n_gap>5ms={sum(1 for g in gaps if g>5000)}")

if __name__ == "__main__":
    main()
