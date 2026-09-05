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
