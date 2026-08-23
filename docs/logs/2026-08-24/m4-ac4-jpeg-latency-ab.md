# M4 AC4 / [U-1] — JPEG switch latency A/B

Owner: m4-perf-1-sonnet. Written for m4-lead-opus per the frozen contract
`docs/logs/2026-08-24/m4-m6-convergence-contract.md` AC4.

## Pre-registration (written before any measured run — locked)

### Metric
Event pair `selectItem.enter` -> `image.painted`, per the permanent perf
harness. `lib/perf/perf_driver.dart`'s `switch.end|<label>|<i>|<id>|dur=<us>`
already computes exactly this span: `switch.begin`'s timestamp is taken
immediately before `state.nextPhoto()` (which synchronously calls
`AppState.selectItem`, which logs `selectItem.enter`), and the waiter
completing is driven by `PerfLog.onImageReady`, which is invoked from
`main_detail_view.dart:203` right after the `image.painted` log line. So
`switch.end dur=` IS the `selectItem.enter -> image.painted` latency; no
separate event-pairing is needed and none is done — using the harness's own
computed span avoids introducing a second, unreviewed parsing path.

### Sample = every `dur=` value from `switch.end` lines, both `paced` and
`rapid` passes pooled (`HALCYON_PERF_MODE=both`) — both are legitimate
instant-navigation scenarios, differing only in inter-switch pacing, not in
what is measured. `switch.timeout` / `burst.timeout` anywhere in a leg is a
hard reject for that leg (image never arrived; not a data point, a failure).

### Dataset — TWO datasets, both required (amended, see Amendments log)
**Dataset A — literal JPEG files**: `local_data/photo_samples/JPG/`, 7 files:
```
2025-01-19-14-43-30.jpg
2025-01-19-14-43-32.jpg
2025-01-19-14-43-37.jpg
2025-01-19-14-43-39.jpg
2025-01-19-14-43-40.jpg
2025-01-19-14-43-47.jpg
2025-01-19-14-43-49.jpg
```
7 files -> a pass covers `items.length - 1` = 6 switches. `mode=both` gives
paced(6) + rapid(6) = 12 samples per single app invocation. **Superseded by
amendment #2 (per-mode analysis, n>=36/mode floor)**: run the SAME binary
against this dataset **6 separate invocations** (fresh app launch each time,
same binary/commit, `mode=both, N=6, pace=1200` unchanged per run), pool
`paced` samples across all 6 invocations (36) and `rapid` samples across all
6 invocations (36) SEPARATELY — never pooled with each other. This is
sampling repetition, not a parameter change on a single run.

**Dataset B — embedded-JPEG-preview DNGs (JPEG-passthrough tier-1 path)**:
the 13 `2026-*` DNGs, from `local_data/photo_samples/DNG/`:
```
2026-02-15-19-37-38.dng
2026-02-15-20-53-24.dng
2026-02-15-20-53-31.dng
2026-02-15-20-57-15.dng
2026-02-15-20-57-23-2.dng
2026-02-15-20-57-23.dng
2026-02-15-20-57-26.dng
2026-02-15-20-57-28.dng
2026-02-15-21-53-33.dng
2026-02-15-21-53-41.dng
2026-02-15-21-53-42.dng
2026-02-15-21-53-43.dng
2026-08-07-17-52-54.dng
```
13 files -> a pass covers `items.length - 1` = 12 switches. `mode=both` gives
paced(12) + rapid(12) = 24 samples per invocation. **Amendment #2**: run 3
invocations, pool `paced` samples across all 3 (36) and `rapid` samples
across all 3 (36) SEPARATELY, to clear the n>=36/mode floor.

Each dataset AND each mode (`paced`, `rapid`) within it gets its own baseline
median, its own noise band, and its own independent PASS/FAIL verdict (see
Pass/fail rule below). **AC4 passes only if all four dataset x mode combos pass.**

### Build mode
Release, `flutter build macos --release`. **Deviation flagged**: the
contract's read-first list names `python3 scripts/build_apps.py` as the
single build entry point; I used `flutter build macos --release` directly
instead. Reason: `scripts/build_apps.py`'s own inline doc says its macOS path
"REPRODUCED: flutter build macos ... (main:TARGET default)" — same underlying
command — but it additionally restricts to arm64-only and runs the S4
colour-gate on the native `dng_processor` dylib, neither of which is relevant
here (this measurement never touches the RAW/native decode path — all 13
samples resolve via JPEG passthrough) and both add risk of a spurious gate
failure in a detached/foreign worktree. The produced binary is a universal
(x86_64+arm64) Mach-O; this host is arm64 (`uname -m` = arm64) so the arm64
slice is what actually runs, and it linked `libdng_decoder_native.dylib`
successfully (only the x86_64 slice link step ignored the arm64-only dylib,
which is expected and irrelevant). **Decision closed 2026-08-24 by
m4-lead-opus**: keep `flutter build macos --release`, do not redo leg A,
use the identical command for leg B — A/B validity depends on both legs
being built the same way, which matters more than which wrapper invoked the
same underlying flutter command. Recorded here as a deliberate,
lead-approved deviation from `scripts/build_apps.py`, not an oversight.

### Binary provenance protocol (both legs)
Before each build: `git rev-parse --short HEAD` + `git status --porcelain`
captured to a file. Build run in the foreground; its own `$?` captured as
`RC=$?` written on the line immediately after the build command, inside the
build log (never from a background-task notification). After build: `stat -L`
(not plain `stat`, which would read the `.framework` symlink itself) on the
produced Mach-O, compared against a timestamp taken immediately before the
build started — binary mtime must fall inside the observed window.

### Pass/fail rule — amended 2026-08-24 #2 (m4-lead-opus instruction): per-mode, never pooled again
Original rule pooled `paced` and `rapid` samples before computing the noise
band. The baseline data itself disproves that: Dataset B pooled gave
median=4.264ms / p95=46.678ms -> noise_band=42.414ms -> a PASS threshold of
46.678ms, which would sign off roughly a 10x regression as "no regression".
Cause, visible in run order in `baseline.stats.txt`'s `all_ms`: `paced`
(first 12 values) is tight (2.6-6.3ms, no tail); `rapid` (last 12 values) is
violently bimodal (1.35-64.8ms) because outrunning the preloader produces
occasional on-demand decodes. Pooling imports the rapid tail into the paced
tolerance and destroys sensitivity for both. **Fixed: analyse `paced` and
`rapid` separately, forever. No pooling across modes, in any dataset, at any
point in this task.**

- `baseline_median_mode` / `baseline_p95_mode` = computed separately for
  `paced` and `rapid`, per dataset, from that mode's `switch.end dur=` values only.
- `noise_band_mode_ms = max(baseline_p95_mode - baseline_median_mode, 1.5ms)`
  (floor lowered from 5.0 to 1.5ms now that modes aren't pooled — a
  per-mode band no longer needs to absorb cross-mode variance).
- `after_median_mode` = median of that dataset+mode's after-leg samples.
- **PASS (this dataset, this mode)** iff `after_median_mode <= baseline_median_mode + noise_band_mode_ms`.
- **REGRESSION / FAIL (this dataset, this mode)** iff the inequality above fails.
- **FAIL regardless of the above** if either leg (for that dataset+mode) has
  any `switch.timeout` / `burst.timeout`, if `validate_run.py` rejects either
  log, or if binary provenance cannot be established for either leg.
- **AC4 overall verdict = PASS iff ALL FOUR combos PASS**: (Dataset A, paced),
  (Dataset A, rapid), (Dataset B, paced), (Dataset B, rapid). A regression on
  any single mode of any single dataset is an AC4 regression.
- **Sample floor raised**: n=12 per mode (1 traversal) was too thin for a
  median. Target n>=36 per mode per leg -> at least 3 full app-invocation
  traversals per dataset (each traversal = one `mode=both` run, contributing
  one paced-pass-worth and one rapid-pass-worth of samples to their
  respective mode pools). Dataset A (7 files, 6 switches/mode/traversal)
  needs 6 traversals to clear 36; Dataset B (13 files, 12 switches/mode/traversal)
  needs 3 traversals to clear 36. Traversal counts declared here before running.

### Suspicion rule (distrust the instrument, not the code) — amended 2026-08-24
Applied per dataset AND per mode, before accepting any after-leg PASS/FAIL as reportable:
- **Implausible improvement**: `after_median` more than **15% faster** than
  `baseline_median`. M4 is a scheduling-unification change, not a decode
  optimization — it should not make the JPEG/JPEG-passthrough decode path
  itself faster. A win past this threshold is treated as evidence of a
  measurement fault (most likely stale/wrong binary), not evidence M4 is
  better, until disproven.
  - This threshold is deliberately asymmetric to the cheap-set risk the lead
    flagged: on Dataset B (the cheap/embedded-preview set), a stale after-leg
    binary would silently produce a LOWER number that reads as good news and
    would not otherwise trip any rule (the tie-detector below only catches a
    stale binary that happens to match baseline; a stale binary running
    DIFFERENT code from what actually landed can easily be faster or slower
    than both baseline and the true M4 result). The mtime-in-build-window
    check is the only other defense since the in-app version stamp (P-2) is
    parked.
- **Suspiciously exact tie**: `after_median` and `baseline_median` within
  **0.5 ms** of each other AND with >=24 samples in both legs. Flags the
  case where the after-leg accidentally measured the same binary as
  baseline (e.g. build didn't actually rebuild, or wrong binary path).
- **On trigger (either rule, either dataset)**: do NOT report PASS/FAIL for
  that dataset. Re-verify binary provenance from build events (HEAD, git
  status, build RC, `stat -L` mtime-in-window) for the after-leg binary. If
  provenance re-confirms, re-run once. Report the trigger firing to the lead
  regardless of outcome — it is a finding, not something to silently absorb.

No parameter has been or will be changed after a leg's runs start without the
lead's explicit approval, recorded here as a dated amendment.

### Amendments log
- **2026-08-24, m4-lead-opus instruction** (before any after-leg run):
  1. Original pre-registration measured Dataset B (cheap DNGs) only, on the
     premise that the 7-file `photo_samples/JPG/` folder was too few samples
     to be useful. Lead audited and found this reinterpreted AC4 ("JPEG
     switch latency") into a more convenient proxy without authorization.
     Corrected: both Dataset A (literal `.jpg`, 7 files, repeated across 2
     invocations to clear the sample floor) and Dataset B (13 cheap DNGs) are
     now required; AC4 passes only if both pass. Dataset B's already-run
     baseline leg (median=4.264ms, p95=46.678ms, n=24, below) stands
     unchanged — it becomes Dataset B's baseline leg under the corrected
     two-dataset rule, not a discarded measurement.
  2. Added the suspicion rule (15% implausible-improvement trigger, 0.5ms
     exact-tie trigger) that was missing from the original file, per lead's
     explicit instruction, before any after-leg (M4) run exists to apply it
     to.
- **2026-08-24, m4-lead-opus instruction #2** (before any after-leg run):
  Trigger: the pooled Dataset B baseline (`paced`+`rapid` pooled) produced
  `noise_band_ms=42.414ms` against `median=4.264ms` — a band roughly 10x the
  median, which would have signed off a ~10x regression as "no regression."
  Root cause: `paced` and `rapid` are two different distributions (paced:
  tight 2.6-6.3ms; rapid: bimodal 1.35-64.8ms, because outrunning the
  preloader produces occasional on-demand decodes) and pooling them before
  computing the band imported the rapid tail into the paced tolerance.
  Corrected: `paced` and `rapid` are analysed and thresholded SEPARATELY,
  permanently, in both datasets; noise-band floor lowered 5.0ms -> 1.5ms now
  that cross-mode variance is no longer absorbed into it; AC4 verdict is now
  PASS iff all 4 (dataset x mode) combos pass; sample floor raised to n>=36
  per mode per leg (was n>=20 pooled), requiring 3 traversals for Dataset B
  and 6 traversals for Dataset A. Existing single-traversal data for both
  datasets is being extended with additional traversals, not discarded — see
  updated per-mode results below, which supersede the pooled numbers in the
  per-dataset "Measurement run" subsections above (those subsections are
  left as-is for the historical record of what was actually run and when;
  the authoritative PASS-threshold numbers are in the per-mode summary at
  the end of this Leg A section).

---

## Leg A — Baseline (b3b0ddd)

### Provenance (shared by both datasets — same binary)
- Tree: `/Users/jhangyu/project/halcyon-m4-baseline` (detached, read-only).
- HEAD: `b3b0ddd` (`tmp/verify/perf/baseline_head.txt`, in that tree).
- `git status --porcelain` at capture time: only `?? local_data` (gitignored
  sample symlink; expected, matches every other worktree in this project).
- Build command: `flutter build macos --release`, run in foreground.
- Pre-build timestamp: `2026-08-24 00:32:07` (`baseline_build_prebuild_time.txt`).
- Build completed, `RC=0` captured inside `tmp/verify/perf/baseline_build.log`
  (that tree) on the line immediately after the build ran.
- Binary: `build/macos/Build/Products/Release/Halcyon.app/Contents/MacOS/Halcyon`,
  universal x86_64+arm64. `stat -L` mtime: `Aug 24 00:33:22 2026` — inside the
  observed window (build started 00:32:07, checked 00:33:42). Host is arm64
  (`uname -m`), so the arm64 slice runs; it linked the native dylib
  successfully (irrelevant to this JPEG-only measurement regardless).

### Dataset B measurement run
- Dataset staged at `~/Library/Containers/com.jhangyu.halcyon/Data/perf/jpeg_ab`
  as REAL FILE COPIES, not symlinks — `PhotoLibraryScanner.scan()` at
  `lib/services/photo_library_scanner.dart:8` calls `dir.list(followLinks: false)`,
  so a symlinked dataset dir silently scans as `items=0` (first attempt hit
  this: `folder.load.end|items=0` -> `driver.abort|not enough items`, re-run
  after switching to copies fixed it — see raw log if needed, not kept).
- Run: `HALCYON_PERF_MODE=both HALCYON_PERF_N=12 HALCYON_PERF_PACE=1200`, app run
  directly (not `flutter run`) against the built `.app` binary.
- Raw log: `tmp/verify/baseline.log` (816 lines). Stdout capture:
  `tmp/verify/baseline.stdout.log`. `APP_EXIT=0` (self-captured, written inside
  the stdout log immediately after the run — not from a task notification).
- Validity gate: `tmp/verify/baseline.gate.txt` — **ACCEPT**. Build mode proved
  release from `halcyon-m4-baseline/tmp/verify/perf/baseline_build.log`'s
  `Built build/macos/Build/Products/Release/Halcyon.app` line (the binary was
  run directly, so the app's own stdout has no `flutter run`-style "in release
  mode" line — the companion build log is the mode proof here, which is why
  `--build-log` was passed). `folder.load.end items=13` (all 13 cheap DNGs
  scanned). `switch.begin samples: 24` (paced 12 + rapid 12). Zero
  `switch.timeout`/`burst.timeout`.
  Note: the gate's own `git provenance` section reports whatever tree the
  gate script is invoked FROM (I ran it from the main tree, so it shows that
  tree's HEAD/dirty count) — that section is informational only in this
  tool; it is NOT the baseline binary's provenance. The baseline binary's
  actual provenance is the "Provenance" subsection above (captured directly
  in the `halcyon-m4-baseline` tree before the build ran).
- Stats (`tmp/verify/baseline.stats.txt`), computed over all 24 `switch.end dur=`
  values (paced+rapid pooled), converted to ms:
  - n=24, timeouts=0
  - **median = 4.264 ms**
  - **p95 = 46.678 ms**
  - min = 1.346 ms, max = 64.774 ms
  - Spread is wide (some switches land near-instant tier-1 cache hits ~1-5ms,
    a handful land 15-65ms — plausibly on-demand tier-1 decode for items not
    yet warmed into the preload window at that point in the pass). This wide
    spread is exactly why the pre-registered rule uses p95-derived noise band
    rather than a fixed ms tolerance.
  - `noise_band_ms = max(46.678 - 4.264, 5.0) = 42.414 ms`
  - **PASS threshold for leg B: after_median <= 4.264 + 42.414 = 46.678 ms**

### Dataset A measurement run (literal `.jpg`, pooled across 2 invocations)
- Dataset staged at `~/Library/Containers/com.jhangyu.halcyon/Data/perf/jpg_ab`
  as real file copies (same `followLinks:false` reason as Dataset B).
- Same binary as Dataset B (same build, same provenance above — no rebuild
  between datasets).
- Run twice: `HALCYON_PERF_MODE=both HALCYON_PERF_N=6 HALCYON_PERF_PACE=1200`,
  fresh app launch each time. `APP_EXIT_run1=0`, `APP_EXIT_run2=0`
  (self-captured, `tmp/verify/baseline_jpgA_run{1,2}.stdout.log`).
- Raw logs: `tmp/verify/baseline_jpgA_run{1,2}.log`.
- Validity gate (`--min-switches 5` per individual run, since the floor
  applies to the pooled total not each invocation): both **ACCEPT**
  (`tmp/verify/baseline_jpgA_run{1,2}.gate.txt`). `folder.load.end items=7`
  both runs. `switch.begin samples: 12` each run, 0 timeouts either run.
- Pooled stats (`tmp/verify/baseline_jpgA.stats.txt`), n=24 across both
  invocations, 0 timeouts:
  - **median = 3.928 ms**
  - **p95 = 48.672 ms**
  - min = 1.656 ms, max = 68.184 ms
  - `noise_band_ms = max(48.672 - 3.928, 5.0) = 44.744 ms`
  - **PASS threshold for M4 on Dataset A: after_median <= 3.928 + 44.744 = 48.672 ms**
  - Spread shape matches Dataset B (mostly 2-6ms tier-1 hits, a handful of
    18-68ms outliers) — consistent with the same underlying mechanism
    (on-demand tier-1 decode for items not yet in the preload window),
    supports the two datasets not being wildly different regimes.

## Baseline leg — per-mode results (amendment #3, authoritative; supersedes amendment #2's n>=36 uplift)

### Amendment #3 — 2026-08-24, user-level baseline registry overrides the n>=36 uplift
`docs/logs/2026-08-24/baseline-registry.md` is authoritative for this project
and its rule is: a baseline already registered against an unchanged anchor
(`b3b0ddd`) **must not be re-measured** — cite the registered artifact
instead. Dataset A's registered baseline is the two-invocation-pooled run
(`baseline_jpgA_run1.log` + `baseline_jpgA_run2.log`, n=24 pooled,
`baseline_jpgA.stats.txt`); Dataset B's is the single original invocation
(`baseline_dngB_run1.log`, identical file to `baseline.log`, n=24 pooled,
`baseline.stats.txt`). Lead retracted amendment #2's n>=36 sample-count
uplift on this basis and instructed: drop the uplift target, do not re-run
any baseline leg, and the after-leg must mirror the ORIGINAL registered
traversal counts exactly (dataset A: 2 invocations; dataset B: 1 invocation)
so the A/B stays a matched comparison.

**Consequence**: `baseline_dngB_run{2,3}.log` and `baseline_jpgA_run{3,4,5,6}.log`
(and their `.stdout.log`/`.gate.txt` companions) exist on disk as artifacts of
the now-retracted uplift attempt but are **NOT used in the verdict below**.
They are left in place rather than deleted (no destructive cleanup of
artifacts mid-task) but are explicitly out of scope for AC4.

**What amendment #2's per-mode split fix keeps**: recomputing `paced`/`rapid`
separately from data already collected is reinterpretation, not
re-measurement, and is unaffected by the retraction — it stays. Only the
sample-count uplift is retracted.

### Per-mode results, ORIGINAL registered traversal counts only (n=12/mode/dataset)
Same binary/provenance as Leg A "Provenance" above (no rebuild). Zero
`switch.timeout`/`burst.timeout` in either source log. Stats in
`tmp/verify/baseline_permode_final.stats.txt`.

| Dataset | Mode | n | median | p95 | noise band (floor 1.5ms) | PASS threshold |
|---|---|---|---|---|---|---|
| B (13 cheap DNG, 1 invocation) | paced | 12 | 4.264 ms | 5.949 ms | 1.684 ms | <= 5.949 ms |
| B (13 cheap DNG, 1 invocation) | rapid | 12 | 7.987 ms | 55.086 ms | 47.100 ms | <= 55.086 ms |
| A (7 literal jpg, 2 invocations) | paced | 12 | 3.928 ms | 6.013 ms | 2.085 ms | <= 6.013 ms |
| A (7 literal jpg, 2 invocations) | rapid | 12 | 3.270 ms | 59.024 ms | 55.754 ms | <= 59.024 ms |

**These four thresholds are the ones the M4 leg (leg B) is judged against.**
The earlier n=36 table above this section is superseded and retained only
for the historical record of what was attempted.

Observations (still valid post-retraction, the underlying fix is the same):
- `paced` band collapsed from ~42-45ms (pooled) to ~1.7-2.1ms (split) — the
  split is what restores sensitivity, not the sample count. A regression of
  even a few ms now trips the rule.
- `rapid` keeps a wide band (~47-56ms) in both datasets — reflects the mode's
  actual design (outrunning the preloader deliberately produces occasional
  on-demand decodes, per `_pass`'s 1ms yield-only gap for rapid vs 1200ms for
  paced), not a pooling artifact and not fixable by more samples alone.
  Flagging for the lead's judgment on whether this is acceptable AC4
  sensitivity for that mode; not narrowed unilaterally.

Leg A status: **DONE** (both datasets, both modes, per-mode rule applied,
traversal counts match the registry's registered baselines exactly). Leg B
GO per lead's handoff — building at commit **9267fd2**.

