#!/usr/bin/env python3
"""Split a Halcyon DNG PERFNATIVE log into passthrough-HIT / passthrough-MISS /
sidebarThumbnail(no-passthrough) / undetermined subsets, by filename+purpose
correlation (FIFO per filename, matching handler.enter -> its result.dispatch).

This performs NO statistics. It only re-emits subsets of the original
PERFNATIVE lines, verbatim, into separate files so that the UNMODIFIED
parse_r2.py can compute nativeTotal (and other stage) medians on each subset.
This is grouping/filtering, not reimplementing the parser's math.

Usage: split_dng_native.py <perfnative.log> <out-prefix>
Writes:
  <out-prefix>.hit.log     -- preview purpose, dngPassthrough.read observed
  <out-prefix>.miss.log    -- preview purpose, dngPassthrough.miss observed
  <out-prefix>.thumb.log   -- sidebarThumbnail purpose (never uses passthrough)
  <out-prefix>.undetermined.log -- anything that didn't fit the above
Prints a summary of counts to stdout.
"""
import sys
from collections import defaultdict, deque


def main():
    path, out_prefix = sys.argv[1], sys.argv[2]
    with open(path, errors="replace") as f:
        lines = [ln.rstrip("\n") for ln in f if ln.strip()]

    # per-filename FIFO queues
    purpose_q = defaultdict(deque)
    read_q = defaultdict(deque)      # dngPassthrough.read lines pending
    miss_q = defaultdict(deque)      # dngPassthrough.miss lines pending
    decoded_q = defaultdict(deque)   # decoded lines pending (any purpose)
    reencode_q = defaultdict(deque)  # reencode lines pending (any purpose)

    # buffered raw lines per filename per occurrence, keyed by a per-file
    # occurrence counter so we can re-emit the exact lines that belong to
    # one handler.enter..result.dispatch occurrence.
    occ_lines = defaultdict(lambda: deque())  # filename -> deque of dict(kind->line)

    # We build occurrence records incrementally: a new record starts at
    # handler.enter for that file, and we append matching event lines to the
    # *most recent still-open* record for that file until its result.dispatch.
    open_rec = {}  # filename -> record dict currently accumulating

    hit_out, miss_out, thumb_out, undet_out = [], [], [], []

    def parse(ln):
        parts = ln.split("|")
        if len(parts) < 4 or not ln.startswith("PERFNATIVE|"):
            return None
        ts, ev, fname = parts[1], parts[2], parts[3]
        return ts, ev, fname, parts[4:]

    counts = defaultdict(int)

    for ln in lines:
        p = parse(ln)
        if p is None:
            continue
        ts, ev, fname, rest = p

        if ev == "handler.enter":
            purpose = rest[0] if rest else "?"
            rec = {
                "purpose": purpose, "lines": [ln],
                "read": None, "miss": None, "decoded": None, "reencode": None,
            }
            # push as the currently-open record for this filename; if one is
            # already open (rare interleave), keep it in a pending list too.
            open_rec.setdefault(fname, deque()).append(rec)
            continue

        if fname not in open_rec or not open_rec[fname]:
            # event with no matching open handler.enter -- treat as
            # undetermined, emit raw line for visibility.
            undet_out.append(ln)
            counts["undetermined_line_no_open_record"] += 1
            continue

        # Attach non-dispatch events to the OLDEST open record for this file
        # that hasn't been closed yet (FIFO), matching arrival order.
        if ev in ("bg.start", "dngPassthrough.read", "dngPassthrough.miss",
                  "decoded", "reencode"):
            rec = open_rec[fname][0]
            rec["lines"].append(ln)
            if ev == "dngPassthrough.read":
                rec["read"] = ln
            elif ev == "dngPassthrough.miss":
                rec["miss"] = ln
            elif ev == "decoded":
                rec["decoded"] = ln
            elif ev == "reencode":
                rec["reencode"] = ln
            continue

        if ev == "result.dispatch":
            rec = open_rec[fname].popleft()
            rec["lines"].append(ln)
            if not open_rec[fname]:
                del open_rec[fname]

            purpose = rec["purpose"]
            if purpose == "sidebarThumbnail":
                thumb_out.extend(rec["lines"])
                counts["thumb"] += 1
            elif purpose == "preview":
                if rec["read"] is not None and rec["miss"] is None:
                    hit_out.extend(rec["lines"])
                    counts["hit"] += 1
                elif rec["miss"] is not None and rec["read"] is None:
                    miss_out.extend(rec["lines"])
                    counts["miss"] += 1
                else:
                    undet_out.extend(rec["lines"])
                    counts["undetermined_preview_ambiguous"] += 1
            else:
                undet_out.extend(rec["lines"])
                counts["undetermined_unknown_purpose"] += 1
            continue

        # unrecognised event kind, ignore
        undet_out.append(ln)
        counts["undetermined_line_unknown_event"] += 1

    # any records that never closed (no result.dispatch seen) => undetermined
    for fname, dq in open_rec.items():
        for rec in dq:
            undet_out.extend(rec["lines"])
            counts["undetermined_never_dispatched"] += 1

    def write(path, ls):
        with open(path, "w") as f:
            for ln in ls:
                f.write(ln + "\n")

    write(out_prefix + ".hit.log", hit_out)
    write(out_prefix + ".miss.log", miss_out)
    write(out_prefix + ".thumb.log", thumb_out)
    write(out_prefix + ".undetermined.log", undet_out)

    total = sum(counts[k] for k in ("hit", "miss", "thumb",
                                     "undetermined_preview_ambiguous",
                                     "undetermined_unknown_purpose",
                                     "undetermined_never_dispatched"))
    print(f"# {path}")
    print(f"total result.dispatch-terminated occurrences classified: {total}")
    for k in ("hit", "miss", "thumb"):
        print(f"  {k}: {counts[k]}")
    other = sum(v for k, v in counts.items() if k.startswith("undetermined"))
    print(f"  undetermined (all reasons): {other}")
    for k, v in counts.items():
        if k.startswith("undetermined") and v:
            print(f"    - {k}: {v}")


if __name__ == "__main__":
    main()
