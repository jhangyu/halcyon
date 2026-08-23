# M3 Round 2 — outgoing lead handover (m3-lead-opus)

> Date: 2026-08-23. Worktree `/Users/jhangyu/project/halcyon-m3`, branch `m3-cache`.
> Written so a fresh lead reading ONLY committed docs can proceed without asking anything.
> Units: MiB throughout (bytes / 1048576).

## 1. The frozen contract

**`docs/logs/2026-08-23/m3-round2-contract-draft.md` is FROZEN.** Current text is commit `7b91407`
(the orchestrator froze "as drafted at d9fb357, which assumes (A) throughout"; `7b91407` is the same
contract with the (A) decision made explicit and its derivation recorded). Use `7b91407`.
Only the user may change it. Round budget 3; this is round 1 of 3.

**The (A) ruling — RULED and FROZEN.** `kExpensiveStartupRadius = 1` was one constant serving two
meanings: the tier-2 full-size decode window (`image_preload_controller.dart:393,397`) AND
expensive-RAW startup eligibility (`prefetch_scheduler.dart:99,108`). The decision is **SPLIT**:
new `kTierTwoRadius = 2` governs the tier-2 decode window; `kExpensiveStartupRadius` stays `1`.
Derivation: the frozen clarification *"±1: expensive RAW STARTUP eligibility only"* and the round-2
ruling *"sequential RAW decode unchanged"* can both hold ONLY under a split. Widening the shared
constant would put five items on the sequential RAW rung instead of three (~42 s cold settle vs
~25 s at the measured 8.5 s per expensive settle) — a silent violation that would look like faithful
implementation. **Do not let this be "simplified" back into one constant.**

## 2. Squad state

| Member | State |
|---|---|
| m3-impl-1-opus | ROTATED OUT (context). Seven commits, all signed off. Do not expect replies. |
| m3-impl-2-opus | ONLINE, docs read, NOT yet kicked off. Waiting for the frozen contract verbatim. |
| m3-test-haiku | Available for the battery. Round-1 brief still applies (see §5). |
| m3-lead-opus | Rotating out. This document is the flush. |

**The incoming lead's first action is to kick off m3-impl-2-opus with the contract verbatim.**

### m3-impl-2-opus asked two questions; both are answered

**(a) Does ±1→±2 apply to `kExpensiveStartupRadius` itself, or only the tier-2 span?**
Only the tier-2 span, via the NEW `kTierTwoRadius`. See §1. Its instinct that "the change may need to
be a separate constant" was correct and it refused to guess — the right behaviour.

**(b) Ownership for round 2.** Confirmed: `lib/main.dart`, `lib/services/photo_payload_cache.dart`,
`lib/services/prefetch_scheduler.dart`, `lib/services/image_preload_controller.dart`, plus new or
extended tests. **Corrections to its assumption:** put new guarantee tests in a NEW file rather than
`test/image_preload_controller_test.dart` — AC7 of round 1 pins `:1123/:1165/:1198` green and
byte-unmodified, and appending to that file risks it. `docs/logs/2026-08-23/*.md` belongs to the LEAD.

## 3. Open items — none of these are closed

1. **Task #4 / AC8.** Passes ONLY under the user's amended RELATIVE criterion ("peak RSS not worse
   than the pre-M3 baseline under the identical method"): M3 900.0 MiB vs pre-M3 994.9 MiB. The
   absolute ~1 GiB is **deferred, not dismissed**, and is unexplained on BOTH sides of the baseline.
2. **AC8 as originally written has never been executed** at its own nine-slot fully-populated
   workload — impossible in principle under the 30 s foreground cap at ~8.5 s per expensive settle.
3. **The span-widening is a PREREQUISITE, not a footnote.** Setting (224, 768) without widening
   `_precacheTierOneWindow` and the tier-2 span buys nothing: the constants would reserve headroom
   for a guarantee the app never delivers. That is exactly what round 2 exists to do.
4. **The 532.3 MiB residual** is the LARGEST single term in every sizing total and is a SUBTRACTION
   (measured peak minus accounted bitmaps), not a measurement. Moving the absolute number requires a
   real memory profile — more arithmetic over the same artifacts cannot reach it.
5. **`halcyon-m3-red` worktree** (`3e51bc4`, branch `m3-amend3-red`) is still registered. It predates
   this round and holds the historical-RED lane the frozen blobs' byte-identity gate depends on.
   Removing it must be a deliberate decision, not housekeeping.

## 4. Traps a fresh member cannot infer — front-load these

1. **`PhotoSource.probe()` is a deliberate one-line projection over `probeSource()`.** It exists
   solely to keep the hash-frozen blob `test/dng_nav_probe_m3_test.dart:147,:180` compiling, which
   compares it directly to a `SourceCost`. It has ZERO production callers by design.
   **Do not "clean it up".** Removing it requires user authorization to edit a frozen blob.
2. **A type change behind an `expect()` call is INVISIBLE to `flutter analyze`.** `expect()` takes
   dynamic arguments, so a record-vs-enum mismatch analyses clean and fails only at RUNTIME. This
   actually happened in round 1. Run the frozen blobs; do not trust a clean analyze.
3. **`local_data/` is gitignored.** Any fresh worktree has NO samples, and sample-guarded tests carry
   `skip:` — they will report as skips that look like passes. Symlink the samples read-only AND run
   the unmutated test FIRST to prove it executes before trusting any red.
4. **File mtimes are useless for sample provenance here.** Several of the newest DNGs carry 2024
   mtimes; `ls -t` produced a wrong list twice. Derive identity from fixture history or content.
5. **"12 new files" ≠ "12 expensive files".** `IMG_20251112_092839.dng` is an OLD sample that
   measures expensive. Canonical set: **26 total, 13 expensive** (the twelve `2024-07-*` + that one),
   **13 cheap** (the `2026-*` series). Two people independently made the 14/12 slip.
6. **Tier-2 cost inverts the scheduler's sense of "expensive".** `_fullSizeProviderForPayload`
   branches by payload kind: `EncodedPayload` → bare `MemoryImage`, FULL native size (91.55 MiB for
   this corpus's 24 MP embedded previews); `PixelPayload` → `RawPixelsImage`, already window-sized
   (~22.4 MiB). **The dear entries come from the CHEAP rung.** Also: `PixelPayload` yields the SAME
   provider in both tier switches, so a RAW is ONE shared cache entry; an `EncodedPayload` is TWO.
7. **The two constants are sized against DIFFERENT corpora** — the cache figure by the cheap mix,
   the payload figure by the expensive mix. Neither can sanity-check the other. Anyone "simplifying"
   the pair breaks one silently.
8. **MiB throughout, raw bytes pinned.** Round 1 lost time to MB-vs-MiB drift.

## 5. Process that worked — worth keeping

- **Pre-register interpretation rules BEFORE any number exists**, on disk, above the result in the
  same file so the ordering is self-evidencing. This is what made the AC8 attribution trustworthy.
- **Never let a workload be quietly reduced** because tooling makes a smaller one convenient. When
  the 30 s cap forced a reduction, it was escalated and became a USER election, stated in the report.
- **The test runner captures raw output and does NOT judge.** m3-test-haiku produced three
  inferred-not-observed reports in round 1: a false "known pre-existing failure" label that nearly
  buried the sample-set change, a "still executing" report on a finished process, and an
  `EXIT= value: 0` read from an artifact whose `EXIT=` was literally empty (`${PIPESTATUS[0]}` did
  not expand in its shell). **Verify exit codes yourself.**
- **Verify a claim in the code when it contradicts the framing YOU handed down.** This caught four
  things in round 1, twice correcting the lead.
- **Messages cross constantly.** Before telling someone their number is wrong, confirm you hold the
  current artifact — I once audited a superseded draft and reported its gap as live.
- Mid-point gate before irreversible controller edits; artifact-first to `tmp/verify/`; workers report
  READY_FOR_SIGNOFF and the lead closes tickets.

## 6. Useful measured numbers (all real, from `tmp/verify/`)

- Expensive (no-preview RAW) settle: **~8.5 s measured** per switch.
- 24 MP JPEG tier-2 re-decode: **~119 ms**, inferred by 4.09x scaling from a MEASURED
  `micro.decode|0|2800x2097|total=29112` = **29.1 ms** at 5.87 MP.
- Peak RSS: M3 **900.0 MiB** (943,685,632 B); pre-M3 **994.9 MiB** (1,043,218,432 B).
- Per-payload byteCost measured **15.5–22.4 MiB** for expensive payloads.
- Full-size RGBA at 6000x4000 = **91.55 MiB**; tier-1 at 1440x900 logical, DPR 2.0 = **18.54 MiB**.
- ImageCache requirement: **~369 MiB today** → **~626 MiB** under the round-2 guarantee (a 70%
  increase; an earlier 552 figure was wrong and made it look like 13%).
- AC8 harness: `scripts/tmp/ac8_rss.sh`; 15 artifacts under `tmp/verify/` (`ac8-*`,
  `ac8-baseline-*`, `tc094-*`).

## 7. Environment notes

- Detached/background runs require a user-issued approval token; **foreground BUILD commands get an
  automatic 90 s lane**. Reaching for the detached lane first caused two avoidable blocks in round 1.
  Foreground first.
- `flutter test` progress lines are only reliable under `-j 1`.
- Declared-test-count greps undercount: loop- and group-generated tests declare once and execute
  many times. Round 1's full suite executed **232**. Pre-register the EXECUTED expectation.
