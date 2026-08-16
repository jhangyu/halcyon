#!/usr/bin/env python3
"""Split DNG nativeTotal samples from an r3 stdout log into passthrough
hit/miss/sidebarThumbnail groups, using parse_r2.pct/ms unmodified for stats.
One block = handler.enter .. result.dispatch for the same filename occurrence,
matched by in-order nearest-neighbor per filename (requests for the same file
are strictly sequential within a run, no interleaving observed).
"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from parse_r2 import pct, ms
import statistics as st
from collections import defaultdict

def main():
    path = sys.argv[1]
    lines = [l.strip() for l in open(path, errors="replace") if l.startswith("PERFNATIVE|")]
    events = []
    for l in lines:
        parts = l.split("|")
        ts = int(parts[1]); name = parts[2]; fields = parts[3:]
        events.append((ts, name, fields))
    events.sort()

    # walk sequentially, track current open request per filename via a simple
    # state machine: handler.enter opens a block, result.dispatch for the same
    # filename closes the most recently opened block for that filename.
    open_blocks = defaultdict(list)  # filename -> stack of dicts
    closed = []
    for ts, name, f in events:
        fn = f[0] if f else None
        if name == "handler.enter":
            purpose = f[1] if len(f) > 1 else "?"
            open_blocks[fn].append({"purpose": purpose, "passthrough": None, "read_dur": None})
        elif name == "dngPassthrough.read":
            if open_blocks[fn]:
                d = dict(x.split("=") for x in f[1:] if "=" in x)
                open_blocks[fn][-1]["passthrough"] = "hit"
                open_blocks[fn][-1]["read_dur"] = int(d.get("dur", -1))
        elif name == "dngPassthrough.miss":
            if open_blocks[fn]:
                open_blocks[fn][-1]["passthrough"] = "miss"
        elif name == "result.dispatch":
            if open_blocks[fn]:
                blk = open_blocks[fn].pop(0)  # FIFO: oldest open block for this filename closes first
                d = dict(x.split("=") for x in f[1:] if "=" in x)
                blk["nativeTotal"] = int(d.get("nativeTotal", -1))
                blk["filename"] = fn
                closed.append(blk)

    groups = defaultdict(list)
    reads = []
    unassignable = []
    for b in closed:
        if b["purpose"] == "sidebarThumbnail":
            groups["sidebarThumbnail"].append(b)
        elif b["purpose"] == "preview" and b["passthrough"] == "hit":
            groups["hit"].append(b)
            if b["read_dur"] is not None:
                reads.append(b["read_dur"])
        elif b["purpose"] == "preview" and b["passthrough"] == "miss":
            groups["miss"].append(b)
        else:
            unassignable.append(b)

    print(f"# {path}")
    print(f"total closed blocks: {len(closed)}")
    for gname in ("hit", "miss", "sidebarThumbnail"):
        rows = groups[gname]
        vals = [r["nativeTotal"] for r in rows]
        files = sorted(set(r["filename"] for r in rows))
        if vals:
            print(f"\ngroup={gname} n={len(vals)} median={ms(st.median(vals)):.1f}ms "
                  f"p95={ms(pct(vals,0.95)):.1f}ms max={ms(max(vals)):.1f}ms")
        else:
            print(f"\ngroup={gname} n=0")
        print(f"  files: {files}")
    print(f"\nunassignable n={len(unassignable)}")
    for b in unassignable:
        print(f"  {b}")
    if reads:
        print(f"\ndngPassthrough.read duration alone: n={len(reads)} median={ms(st.median(reads)):.1f}ms "
              f"p95={ms(pct(reads,0.95)):.1f}ms max={ms(max(reads)):.1f}ms")

if __name__ == "__main__":
    main()
