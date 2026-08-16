#!/usr/bin/env python3
"""WP1-regression cross-check: unpaired burst switches vs view.spinner ids."""


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


for name, path in [
    ("JPEG", "tmp/verify/r2/jpg_profile_r2b.log"),
    ("DNG", "tmp/verify/r2/dng_profile_r2b.log"),
]:
    evs = load(path)
    burst_ids = [f[2] for ts, n, f in evs if n == "switch.begin" and f[0] == "rapid"]
    resolved_ids = set(f[0] for ts, n, f in evs if n == "image.resolved")
    spinner_ids = [f[0] for ts, n, f in evs if n == "view.spinner"]
    unresolved_burst = [i for i in burst_ids if i not in resolved_ids]
    never_resolved_spinner = [i for i in spinner_ids if i not in resolved_ids]
    print(f"=== {name} rapid-burst pass ===")
    print(f"  burst switch ids fired: {len(burst_ids)}")
    print(f"  unresolved (never got ANY image.resolved anywhere in the run): {unresolved_burst}")
    print(f"  spinner ids seen: {spinner_ids}")
    print(f"  spinner ids that NEVER resolved (WP1 regression candidate): {never_resolved_spinner}")
