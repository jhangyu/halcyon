#!/usr/bin/env python3
"""Summarise a burst-mode run (H2: user outruns the preloader).

Usage: parse_burst.py <run.log>
"""
import sys


def main():
    path = sys.argv[1]
    keys, spinners, stale_notify, skips_selected = [], [], [], []
    settled = None
    keys_done = None
    for line in open(path, errors="replace"):
        if not line.startswith("PERF|"):
            continue
        p = line.strip().split("|")
        ts, name = int(p[1]), p[2]
        rest = p[3:]
        if name == "burst.key":
            keys.append((ts, rest[1]))
        elif name == "burst.keysDone":
            keys_done = ts
        elif name in ("burst.settled", "burst.timeout"):
            settled = (name, ts, rest)
        elif name == "view.spinner" and keys_done is None and keys:
            spinners.append((ts, rest[0]))
        elif name == "view.spinner":
            spinners.append((ts, rest[0]))
        elif name == "channel.preview":
            kv = dict(x.split("=", 1) for x in rest[1:] if "=" in x)
            if kv.get("isSelected") == "true" and kv.get("notify") == "false":
                stale_notify.append((ts, rest[0]))
        elif name == "loadPreview.skip":
            kv = dict(x.split("=", 1) for x in rest[1:] if "=" in x)
            if kv.get("isSelected") == "true" and kv.get("inFlight") == "true":
                skips_selected.append((ts, rest[0]))

    print(f"file: {path}")
    print(f"burst keys pressed: {len(keys)} (80ms apart)")
    print(f"view.spinner (user-visible loading placeholder): {len(spinners)}")
    print(
        "loadPreview.skip on the SELECTED item while its load was in flight: "
        f"{len(skips_selected)}"
    )
    print(
        "bytes landed for the SELECTED item with notify=false "
        f"(no notifyListeners -> UI never rebuilds): {len(stale_notify)}"
    )
    for ts, ident in stale_notify:
        print(f"    at {ts}us item={ident}")
    if settled:
        print(f"final item outcome: {settled[0]} {settled[2]}")
    if keys_done:
        print(f"last key at {keys_done}us")


if __name__ == "__main__":
    main()
