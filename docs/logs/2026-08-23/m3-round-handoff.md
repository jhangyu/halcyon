# M3 round handoff — single-probe seam

> Date: 2026-08-23
> Squad: m3-lead-opus (lead), m3-impl-1-opus (implementer), m3-test-haiku (test runner)
> Worktree: `/Users/jhangyu/project/halcyon-m3`, branch `m3-cache`
> Lineage: `3ffa4c4` <- `b0ab0f8` <- `e04550f` <- `3280f14` <- `81689a6` <- `69b1c60` <- `1ba170a`
> Status of the acceptance battery and AC8: see §9. This document is durable; `tmp/verify/` is not.

## 1. What changed

The probe seam was two questions with two answers: `probe()` for the cost rung, and the native
bridge's `NativeImageNeedsRawDecode` for EXIF orientation. A no-preview DNG therefore bought a
bridge round trip before its rung was even known. Per the user's ruling, both facts now come out of
ONE file open and ONE IFD walk.

- `DngPreviewExtractor.probeContent` replaces `largestCandidateLongEdge` and additionally returns
  IFD0's orientation, read off the `reader`+`ifd0` the walk had already parsed. The JPEG SOI check
  moved in here too — keeping it in `PhotoSource` made the probe two opens for one walk.
- `PhotoSource.probeSource` is the canonical entry point (see §2 for why `probe()` still exists).
- The content probe now runs FIRST for every item at EVERY distance, not only beyond ±1
  (Amendment 3 clause 2). Orientation comes from that walk, so the debounced ±1 pass reaches
  `loadExpensive` with zero loader calls.
- The debounced ±1 loads run one at a time instead of fanning out.
- Retention is unchanged: one type-blind `-3..+5` window, `byteCost`-only budget. `±1` remains
  expensive-RAW startup eligibility ONLY and is never a retention boundary.

## 2. The `probe()` projection — DO NOT DELETE IT

`probe()` survives as a one-line pure delegation `(await probeSource(...)).cost`, with ZERO
production callers. It exists solely because the hash-frozen blob
`test/dng_nav_probe_m3_test.dart:147,:180` compares `PhotoSource.probe(...)` DIRECTLY against a
`SourceCost`, and that file may not be edited.

Orchestrator ruling, binding: the user's ruling constrains the number of IFD **walks**, not the
number of identifiers; a projection performs no additional walk. Two gates enforce it:
1. `probe()` contains no walk logic, no branch and no file open of its own.
2. Production code calls only `probeSource`; `grep -rn "PhotoSource\.probe(" lib/` returns only the
   explanatory comment.

**M5/M6 leads: this is not redundancy.** Removing it requires user authorization to edit the frozen
blobs, which retires the historical-RED byte-identity gate.

### Hazard worth keeping
An intermediate state during implementation had `probe()` itself returning the record. `flutter
analyze` stayed CLEAN, because `expect()` takes dynamic arguments — the breakage only appears at
RUNTIME. A type change behind an `expect()` call is invisible to the analyzer; run the frozen blobs.

## 3. Three named behaviour changes — NOT equivalence refactors

State them as changes wherever this work is summarised.
1. **±1 RAW decodes are sequential.** A neighbour's worst case is now the SUM of the queue ahead of
   it, not the MAX. This is a real latency change, deliberately taken.
2. **A JPEG costs +1 file open and +2 bytes on the hot path.** The probe stops at the SOI check for
   a JPEG — not an IFD walk — but the open is new. The whole probe is exactly one open.
3. **`preloadImages` snapshots the caller's list.** Honest framing: the aliasing pre-existed M3
   (the clamp and the caller-owned list are untouched pre-M3 code); its REACHABILITY on the ordinary
   path is this change's doing; the crash was NEVER witnessed at base. Do not restate this as "a
   latent pre-M3 crash we fixed" — that overclaims.

## 4. PL-owned deviations

`test/photo_source_test.dart:104-122` (`e04550f`) — the no-preview fall-through is now observed
AFTER the 250 ms debounce instead of the instant `preloadImages` returns; capability assertion and
test name unchanged, timing-only. Entailed by Amendment 3 clause 2 and frozen TC-088: probe-first
defers an expensive item at distance 0, so `hasFailed` flips on the debounced pass. Authorized by
the user's probe-first ruling via the orchestrator, after escalation. This was a requirement change
flowing down into a test that encoded the old requirement — NOT a test bent to fit an implementation.

`test/dng_preview_extractor_m0_test.dart` (`3ffa4c4`) — sample-count guard 14 -> 26, exactly two
lines (the literal and the same number inside its reason string). Narrow ownership transfer from the
red-lined oracle file, user-authorized, nothing else touched.

**Outstanding, flagged not fixed:** `test/dng_preview_extractor_m0_test.dart:17` still carries a
stale prose line saying the contract was amended to "14 .dng files". Outside the authorized scope;
for whoever owns that oracle file next.

## 5. The sample set — and a trap that caught two people

Canonical set at `3ffa4c4`: **26 total, 13 EXPENSIVE, 13 CHEAP.**
- Expensive: the twelve `2024-07-03-*`/`2024-07-06-*` files **plus `IMG_20251112_092839.dng`**.
- Cheap: the thirteen `2026-02-15-*` / `2026-08-07-*` files.

**NAMED TRAP: "12 new files" and "12 expensive" are DIFFERENT SETS.** `IMG_20251112_092839.dng` is
an OLD sample that measures expensive, so 12 new + 1 old = 13 expensive, and the old 14 minus that
one = 13 cheap. Both the lead and the implementer independently made the 14/12 slip and both
retracted it; a future reader will make it too.

**File provenance: mtime is useless here.** Several of the NEW `2024-07-*` files carry 2024 mtimes.
An `ls -t` identification produced a wrong list twice (once by the orchestrator, once by the
implementer, neither acted upon). Identity was established two independent ways that agree: fixture
history (`1ba170a`'s `expect(expensive, ['IMG_20251112_092839.dng'])` implies the old 14) and
content measurement (per-file `largestLongEdge`).

## 6. Why the twelve have no preview — settled, with an outside witness

Verdict: **(a) genuinely preview-less.** Not "previews smaller than the window", not "our walker is
blind".
- The twelve report `largestLongEdge` = **0** (not a small number, which rules out the
  under-the-window explanation) and full extraction returns null. The thirteen cheap report 6000 and
  yield 0.78-2.7 MB of real JPEG.
- `exiftool` (already installed; nothing was added) shows Xiaomi 2304FPN6DC / Xiaomi 13 Ultra phone
  DNGs whose IFD0 is `Compression JPEG` + `PhotometricInterpretation "Color Filter Array"`, with NO
  preview/thumbnail/JpgFromRaw tag in a full `-a -G1` dump. The JPEG inside is a BAYER MOSAIC.
- Control on the same instrument: Panasonic DC-S9, `PhotometricInterpretation YCbCr`, `Preview Image
  Start/Length` present.

**Right for the right reason.** `_gatherCandidates` requires `Compression==7` AND
`PhotometricInterpretation==6` (YCbCr), so a CFA mosaic is rejected BECAUSE it is a mosaic. Had the
walker counted that IFD0 JPEG as a candidate, we would hand a Bayer mosaic to the JPEG decoder and
paint a green mess on screen. The exclusion is load-bearing correctness, not a gap.

**Method note:** the two Dart paths share `_gatherCandidates`, so they are one witness wearing two
hats. Only the outside tool could discriminate "no preview exists" from "we cannot see it".

## 7. The founding base rate is corpus-specific

"The `.dng` extension rule was wrong 13 times in 14" describes the OLD corpus only. Those previews
are Lightroom-generated (`Preview Application Name: Adobe Photoshop Lightroom Classic` on the DC-S9
control) — it was a property of a Lightroom-PROCESSED library, not of DNGs in general. The current
set is 13 cheap / 13 expensive. Expect the cheap rung to dominate in processed/exported libraries
and NOT in straight-off-the-phone CFA raws. M3's motivation is unaffected; the statistic must not be
restated as a general rate.

## 8. Evidence quality

- **TC-094 is mutation-killed.** Removing the one-line list snapshot in an ISOLATED worktree made it
  fail with `Invalid argument(s): 0` / `dart:core int.clamp` — the exact crash it exists to catch.
  Restored by hash, shared tree untouched.
- **The control that made that red mean anything:** `local_data/` is gitignored, so the fresh
  worktree had NO samples and TC-094 carries a skip-if-no-samples guard. It would have SKIPPED
  silently and produced a "red" that was really an absent test. The samples were symlinked read-only
  and the UNMUTATED test run FIRST (`+1 All tests passed!`, zero skips) to prove it executes there.
- **A false label was caught in review:** the test runner reported the two sample-set failures as
  "TC-073 known pre-existing failure". Nothing was pre-existing; reading the raw log is what surfaced
  the sample-set change. Test runners report quoted output; the lead judges.
- `flutter test` progress lines are only reliable under `-j 1`.

## 9. Acceptance status

Verified by the lead at `3ffa4c4`, mechanically: AC3 (0), AC4 (0/0/0), AC5, AC6, AC7 and AC11 (diffs
vs `1ba170a` empty), AC13, plus the §2 projection gate. AC14 is asserted over the COMBINED probe by
TC-092 — this closes the discarded WIP's hole where orientation reads bypassed `onDiskRead`.
The single-walk killer TC-090 counts real `File.open()` via an `IOOverrides` zone and asserts
exactly ONE per probe; it already caught a 2-open first cut, so the instrument is proven, not assumed.

**BATTERY: PASSED**, hash-bound to `3ffa4c4` on the stable 26-file sample set.
- `flutter test -j 1`: `00:40 +232: All tests passed!`, zero `[E]` lines, `REAL_EXIT=0`.
- Count pre-registered at 232 executed / 0 failures BEFORE the run; observed exactly 232 / 0.
- `flutter analyze`: `No issues found!`.
- AC1/AC2/AC10/AC12 signoff rests on this run. Task #3 signed off and closed by the lead on it.

Documentation-only commits after the battery, which cannot move the count (zero test declarations):
`865ed73` (this handoff), `254b657` (M0 oracle sample-count note). Battery HEAD `3ffa4c4`;
post-battery HEAD `254b657`.

**Exit-code caveat worth carrying:** the runner's own artifacts ended with a literal `EXIT=` and NO
value — `${PIPESTATUS[0]}` did not expand in its shell — yet its report claimed `EXIT= value: 0`.
The exit code above comes from a separate lead re-run that captured it properly. If a future round
uses the same `tee` + `PIPESTATUS` pattern, verify the value actually landed in the file.

### AC8 AMENDED BY THE USER — M3 PASSES

**Amendment (user, 2026-08-23, the only authority that can change a frozen AC):** the ABSOLUTE
350 MiB ceiling is REPLACED by a RELATIVE criterion — *"peak RSS not worse than the pre-M3 baseline
under the identical method."*
Applied: M3 **900.0 MiB** vs pre-M3 baseline **994.9 MiB** => **AC8 PASSES.**

The absolute-value problem is **DEFERRED, NOT DISMISSED**: the application really does peak near
1 GiB, that is unattributed, and the composed cap arithmetic below really is inconsistent with any
350 MiB-class target. A future round inherits that, and inherits it with numbers attached.

Note what made the amendment possible at all: the pre-M3 baseline. Without a measured denominator the
only available moves would have been to loosen an absolute number arbitrarily or to blame M3 for a
condition it did not cause. The evidence below is retained in full because the amended criterion is
*defined* in terms of it.

Also ruled by the user: **sequential RAW decode is KEPT**, with the measured 2.3x throughput
reduction accepted as a known cost.

---

**AC8 AS ORIGINALLY FROZEN (RSS < 350 MB): FAILED — and the failure is a PRE-EXISTING CONDITION, not an M3 defect.**

*Unit convention, declared once and used throughout this section: MiB (bytes / 1048576). Raw byte
counts are pinned so a later restatement cannot lose the convention. "900 MiB" and "943.7 decimal MB"
are the same measurement; earlier messages in this round mixed the two.*

| | kernel max RSS (`/usr/bin/time -l`) | sampler peak (~100 ms) |
|---|---|---|
| pre-M3 `e234182` | **994.9 MiB** (1,043,218,432 B) | 930.5 MiB |
| M3 `e7815a3` | **900.0 MiB** (943,685,632 B) | 867.0 MiB |

**Both fail the 350 ceiling, and pre-M3 fails by more.** The kernel figure is authoritative; the
sampler sits below it in both runs, the expected direction for a sampler that misses transients.

VERDICT by a rule pre-registered BEFORE the baseline app was built (the rule text sits ABOVE the
result in the same artifact, so the ordering is self-evidencing): band of ~15% around 900 = 765..1035;
the baseline's 994.9 falls INSIDE it => **PRE-EXISTING CONDITION. M3 neither caused nor fixed it.**
The "<= 450 => M3 regression" branch was NOT triggered, so **disposal-removal is not implicated.**
M3 measured 9.5% lower; that is deliberately NOT claimed as an improvement, because the rule defines
that band as no attributable change and because of the unequal-work caveat below.

**THE RUNS DID NOT DO EQUAL WORK — read the memory delta only in this light.** Same script, pacing,
16 s budget and four switches, but pre-M3 completed **14 payload loads** to M3's **6**: a **2.3x
throughput reduction**. This is the first hard measurement of named behaviour change #1 (sequential
±1: worst case becomes the SUM, not the MAX). Consequences: the 9.5% memory delta must NOT be read as
"M3 uses less memory for equal work"; and M3's memory profile AT EQUAL WORK is unmeasured, because
this method cannot produce it.

**THE CAPS DO NOT BOUND REAL RSS — on either side.** 500 MiB ImageCache (`main.dart:12`) + 256 MiB
payload budget (`photo_payload_cache.dart:19`) = **756 MiB admissible before any eviction is obliged
to fire, against a 350 ceiling — the design's own bound is 2.16x the criterion it must satisfy.**
Yet both runs measured ABOVE even that: M3 by 144 MiB, pre-M3 by 238.9 MiB. And pre-M3 did not have
the 256 MiB payload budget at all — its admissible ceiling was LOWER while it measured HIGHER.
Two conclusions: cap arithmetic does not explain real RSS, and this independently corroborates the
attribution from a different direction — the version WITH explicit disposal was the higher of the two.
**The 500 MiB ImageCache cap is byte-identical pre-M3** (`git show e234182:lib/main.dart`); what M3
changed is removing disposal alongside it, not the cap.

LIMITS ON THE RECORD:
- **AC8 as written — nine slots, FULLY POPULATED — has never been executed, in either run.** At ~8.5 s
  per expensive settle, a genuine nine-slot window needs ~1 minute; the user-elected 30 s cap made
  full population impossible IN PRINCIPLE. The 350 ceiling has not yet been tested at its own stated
  workload, and doing so would only be worse.
- Per-payload byteCost is not comparable across the two: pre-M3 logs `bytes=-1` on this path, M3 logs
  real values (15.5-22.4 MiB each, 113.7 MiB for six). So "payload retention is inside budget" holds
  for M3 but has no baseline counterpart by this method.
- The unexplained remainder was not attributed. Candidates named but NOT verified: engine/raster
  baseline, unresized tier-2 `MemoryImage` entries (~46.5 MiB per 12MP, ~92 MiB for the 24MP file),
  native decoder buffers. An RSS number cannot apportion these; a memory profile can. Nobody guessed.
- A separate read-only analysis (`m3-imagecache-analysis.md`) REFUTED the full-size-decode-for-
  no-preview-DNGs candidate — window-resolution `RawPixelsImage` is the only reachable path — which
  agrees with the measured per-payload figures. It also found the ±1 tier-2 stale sweep sits INSIDE
  the debounced body, so sustained navigation can leave up to nine full-size entries resident. That is
  a design weakness inside M3's scope, recorded and NOT acted on.

THREE OPEN DECISIONS FOR THE USER, none of them resolvable by this squad:
1. **AC8 as frozen cannot be met by the design as frozen** — visible in two constants without running
   anything. Change a cap (both are policy numbers, not laws), change the ceiling, or tighten tier-2
   release.
2. The measured ~1 GiB is a pre-existing condition of the application, outside M3's frozen scope.
3. The 2.3x sequentialisation throughput cost is now quantified and may warrant its own decision,
   independent of memory.

Neither resolution should be "loosen the ceiling" nor "declare M3 clean". M3 delivered its stated end
state with a green battery; AC8 is a criterion the whole application fails and always did.

Artifacts (copied out of the two isolated diagnostic worktrees, which were then removed):
`tmp/verify/ac8-*` (M3 run), `tmp/verify/ac8-baseline-*` (pre-M3 run), `tmp/verify/tc094-*`
(mutation kill). Both diagnostic lanes ran without ever touching the `m3-cache` tree.

**The battery at `b0ab0f8` is VOID as acceptance evidence** — it ran while the sample directory
changed underneath it.
