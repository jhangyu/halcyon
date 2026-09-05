# R3-T3 (ticket #15) — Pre-Registration (r3t3-sonnet, before GO)

## Standing directives quoted (per instruction)

Directive 1 (USER RULING 2026-09-05, premise escalation, option A):
> Proceed per the original contract: R1-T2 Metal context override goes ahead as
> scoped; the pre-existing intermittent concurrent ARW -206 race is investigated
> in a PARALLEL ticket (does not block R1-T2, but a root-cause finding that
> implicates files R1-T2 touches must be cross-reported immediately). Contract
> AC and round budget unchanged.

Directive 2 (USER DIRECTIVE 2026-09-05, standing, supersedes escalation habits):
> The initial go decision (full contract scope: Metal de-globalization + new
> dylib + Halcyon hookup) is FINAL. No measurement outcome — ratios above or
> below any bar, premise figures failing to reproduce, newly discovered defects
> — may be used to propose abandoning or shrinking the committed scope again.
> Measurements steer HOW tickets execute and what gets reported; they do not
> reopen WHETHER the work happens. Escalate measurement surprises as findings
> attached to the round report, not as descope proposals.

## Task

Headless A/B of `tool/decode_worker_bench` at `width=5`, OLD dylib (A) vs NEW
dylib (B), same corpus, same machine, medians over >=3 repeats per arm, arms
run adjacent (no interleaving of other work in between). Not self-completing;
report READY_FOR_SIGNOFF to lead3-opus.

## Pre-registered expectations (committed BEFORE either arm runs)

- **Direction**: NEW dylib (B) batch wall time at width=5 should be
  substantially lower than OLD (A), matching the campaign's contract AC1
  ("5-way concurrent batch wall time < 2.5x single-decode time, currently
  ~5x"). A arm is expected to reproduce the ~5x staircase (each decode
  effectively serialized). B arm is expected to show batch wall time
  < 2.5x its own single-decode median, AND the per-decode completion
  timestamps list should show overlapping completions, not an even staircase
  spacing (i.e., not merely a smaller ratio via faster serial decodes).
- **Magnitude anchor** (from R2-T2 same-repo evidence, NOT directly
  transferable across measurement tools but used as a directional prior):
  R2-T2 measured ARW ratio improvement 2.6763 -> 1.8144 under a different
  harness (`test_concurrent_decode`), not `decode_worker_bench`. I do not
  assume this number reproduces verbatim; I only assume the same direction
  (large improvement) and the AC1 threshold as the pass bar.
- **UUID arms** (mandatory, hard-fail if violated): A arm loaded dylib UUID
  MUST be `5B25A6BA-7B00-3BAF-A656-C9F1993BAC98`. B arm loaded dylib UUID
  MUST be `92A5FBEF-3F51-3D50-BDEC-095A940E6475`. These two UUIDs MUST differ
  in the collected evidence — if the dumped `DYLD_PRINT_LIBRARIES=1` grep
  shows the same UUID in both arms, that is an instrument failure, not a
  measurement result, and must be reported as such (per the 2026-09-05
  R2-signoff correction lesson: a same-configure/same-path artifact proves
  nothing about which binary was actually loaded).

## What counts as failure (pre-committed, not adjustable post-hoc)

1. Either arm's dyld UUID dump does not match its expected UUID above ->
   instrument failure, re-swap and re-verify before any number is trusted.
2. B arm's 5-way batch wall time >= 2.5x its own single-decode median ->
   AC1 FAIL for this ticket (reported as a finding per Directive 2 — NOT
   grounds to propose descoping; scope stays as contracted regardless).
3. Completions list for B arm shows an even/staircase spacing pattern
   indistinguishable from serialized decodes, even if the raw ratio number
   passes < 2.5x -> AC1 evidence is deemed insufficient (contract explicitly
   requires "the staircase disappears", not just a smaller ratio) and must
   be reported as a partial/ambiguous result, not silently rounded to PASS.
4. Final state of `ceyx/plugin/macos/Libraries/` is anything other than the
   NEW (B) dylib at end of ticket -> swap-protocol failure, must be fixed
   before reporting, since leaving the OLD dylib vendored would silently
   break the Halcyon build for downstream work.
5. Any of the four backup copies (A: r3/r3t1/, docs/logs artifacts/, ceyx
   artifacts/r3-a-arm-backup/; B: ceyx/artifacts/r3-b-arm-backup/) fails
   sha256 verification at end of ticket -> report as a data-integrity
   finding, do not silently proceed to signoff.

## Order commitment

Git-log order and arm-run order will be shown verbatim in the final report
(command history / timestamps), not narrated after the fact. Arms will be
run adjacent: A (>=3 repeats) immediately followed by B (>=3 repeats), no
other machine work interleaved, honoring the token-protocol machine window
from lead3-opus and ticket #14's non-overlap requirement.

## Status

Pre-registration committed. Awaiting GO signal from lead3-opus (ticket #14's
suite must finish first — this ticket swaps the vendored dylib mid-run,
overlap would poison #14's evidence). No machine work (dylib swap, bench
execution) will start before GO.

## ADDENDUM 2026-09-05 (r3t3-sonnet, approved by lead3-opus) — appended before any arm ran

Original text above is left verbatim per this campaign's append-don't-edit
convention (see parallel-decode-r2-signoff-record.md's correction block).
This addendum supersedes original failure criterion 3 (mechanical judge
replaces the prose spacing test) and the Order Commitment section (blocked
A-then-B replaced by interleaved pairs), and widens failure criterion 4.
No numbers exist yet at the time of this write.

### Amendment 1 — mechanical staircase judge (replaces criterion 3's prose test)

Definitions:
- `S` = that arm's single-decode median (from the discarded warmup plus any
  concurrency-1 samples collected in that arm).
- `c1..c5` = the 5-way batch's per-decode completion timestamps, sorted
  ascending.
- `spread = c5 - c1`.

Physical anchors: full serialization predicts `spread ≈ 4S` (5 decodes back
to back, last minus first ≈ 4 decode-times). Full overlap (5 decodes
starting together, resource-permitting) predicts `spread` well under `1S` —
completions cluster near the duration of whichever one finishes last, not
stacked in multiples of `S`.

**Pre-registered threshold: `spread > 1.5S` => STAIRCASE, regardless of the
wall-time ratio.**

Reasoning: 1.5S sits closer to the full-overlap prediction (<1S) than to the
full-serial prediction (4S) — deliberately conservative toward declaring
STAIRCASE, so a batch that is "mostly overlapped but not perfectly" is not
rounded up to PASS. The expensive error here is calling a partially
serialized batch a pass. Threshold applies IDENTICALLY to both arms. If a
ratio-PASS coincides with a spread > 1.5S, that combination is reported
verbatim as "ratio PASS, shape FAIL" — never merged into a single verdict.
Expectation: A's spread should land near 4S (confirming the staircase
precondition holds on this harness); if it does not, that absence is itself
a reportable finding, not silently discarded. B's spread is expected to fall
under 1.5S if the fix works.

### Amendment 2 — interleaved design (replaces the Order Commitment section)

The "A block (>=3), then B block (>=3)" plan is replaced. New design,
pre-registered before any run:
- One discarded warmup decode before the first pair, to absorb one-time
  Metal library compile cost. Not counted in any median or spread.
- >=3 interleaved pairs: A,B,A,B,A,B. Order within each pair is fixed as
  A-then-B, decided now, not re-randomized after seeing any result. A
  symmetric alternation (e.g. A,B,B,A,A,B) is rejected because choosing it
  after the fact would be an undisclosed degree of freedom; fixing A-first
  now closes that.
- Swap by `cp` only between every run, never `mv`. sha256 AND dyld-printed
  UUID verified after EVERY swap (6 swaps total across 3 pairs, not just
  the first).
- Per-pair results reported (A_i vs B_i wall time and spread, i=1..3) in
  addition to medians across the 3 A-runs and 3 B-runs, so the reader can
  see 3/3 vs 2/3 rather than only an averaged verdict — matching this
  campaign's R2-T2 "beat control 3/3 in interleaved pairs" precedent.
- A distinct final verification step follows the 3rd pair, independent of
  and after that pair's own swap-verification, checking the vendored state
  per the widened criterion 4 below.

### Failure criterion 4 — widened per #17's finding

Original wording ("final state of `ceyx/plugin/macos/Libraries/` is anything
other than the NEW (B) dylib") is widened because #17 found the NEW dylib
declares four dependencies the OLD one never had — `libwebpmux.3`,
`libwebpdemux.2`, `libwebp.7`, `libsharpyuv.0` — and load fails without them
present.

**Widened criterion 4:** Final state of `ceyx/plugin/macos/Libraries/` must
be the NEW decoder dylib present AND all four webp libraries
(`libwebpmux.3`, `libwebpdemux.2`, `libwebp.7`, `libsharpyuv.0`) present ->
anything else is a swap-protocol failure, must be fixed before reporting.
The four webp libraries are NOT removed during A-arm swaps (only the decoder
dylib itself is swapped); the old dylib does not need them, but leaving them
in place costs nothing and avoids four more chances to end in a broken
state.

**Consequence for criterion 1:** if either arm fails to LOAD at all (rather
than running slowly), that is an instrument failure under criterion 1 —
report and stop, not a measurement outcome.

### Status update

Addendum committed. Still no machine work started (no swap, no bench run).
Awaiting explicit GO for the first arm from lead3-opus, gated on r3t2-haiku's
suite re-run completing without overlap.
