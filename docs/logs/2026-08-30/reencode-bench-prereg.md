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
