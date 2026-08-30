# Pre-registration — Phase 13 re-encode benchmark (one-buffer design)
Written before any number exists. Fixture: local_data/photo_samples/DNG/IMG_20251112_092839.dng
Measured, 3 runs, medians, ALL IN ONE RUN:
  - full-resolution JPEG encode at q80 (SHIPPED, user ruling 2026-08-30) and at q90 (comparison): wall-time ms + output bytes
  - tier-1 decode: ResizeImage(MemoryImage(q80 output)) to a 2800px long edge: wall-time ms
VERDICT RULE (frozen now):
  - q80 encode median <= 500 ms -> PROCEED.
  - q80 encode median  > 500 ms -> STOP, report to team-lead before writing pipeline code.
    The STOP report cites the recorded next-round evaluation order: (a) native encode
    library, (b) WebP. NEITHER is pre-selected; a new user decision round happens with
    these measured numbers.
Also to be reported (no threshold, informational for the user): the selected-item
worst case = FFI decode + q80 encode + tier-1 decode, and the q80-vs-q90 size/time delta
(what the q80 ruling saved, so the choice is documented against numbers rather than assumed).
No re-running with different parameters to obtain a passing number. The first run's numbers are the numbers.

---

## VERDICT (appended 2026-08-30, after the numbers)

**STOP.** The q80 full-resolution encode median is **4102 ms** (raw reps
[4456, 4102, 3923]), which is **> 500 ms by ~8x**. Per the frozen verdict rule
this halts pipeline work; no Task 1 code is written.

Measured numbers (see `reencode-bench.txt`, `RC=0`, all in ONE run):
- Fixture full-resolution oriented dims: 4080 x 3056 (12.5 MP; ~49.9 MiB RGBA).
- `encode|q80|bytes=3219940|ms=4102` → ~3.07 MiB, median 4102 ms.
- `encode|q90|bytes=5415389|ms=4139` → ~5.16 MiB, median 4139 ms.
- `tier1decode|ms=200` — q80 output ResizeImage→2800px long edge, median 200 ms
  (raw [145, 200, 228]); this matches spec §2.3's ~200 ms tier-1 regression ESTIMATE.

**q80-vs-q90 delta (what the q80 ruling saved):** q80 is ~2.09 MiB smaller per
item (3.07 vs 5.16 MiB, −40% bytes) at essentially the same encode wall-time
(4102 vs 4139 ms — encode cost is dominated by the pixel scan, not the quality
setting). The ruling saves memory, not encode time.

**Selected-item worst case** = FFI decode + q80 encode + tier-1 decode
= (61–406 ms, spec §1.1 range; not re-timed here) + 4102 ms + 200 ms
≈ **4.36–4.71 s** of added latency on the just-landed selected item. The encode
alone dominates and blows the lane occupancy budget R1 warned about.

Note the fixture is 12.5 MP (4080x3056), below the 24 MP model item in spec §7;
a 24 MP RAW would encode proportionally *slower* still (~1.9x the pixels). The
gate fires decisively regardless.

**Next-round evaluation order (recorded, NEITHER pre-selected — a fresh user
decision happens with these numbers in hand):**
1. **(a)** a native encode library (e.g. libjpeg-turbo / ceyx-hosted encoder).
2. **(b)** WebP (lower memory footprint).

`package:image`'s pure-Dart `encodeJpg` is the measured bottleneck; both options
above replace it. Do not start either without the user's decision.
