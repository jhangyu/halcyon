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

## 4b. On the member rotation itself

**A fresh implementer's early claims need MORE verification, not less.** The outgoing implementer's
value came substantially from accumulated context — it caught the sample-set inversion, the tier-2
payload-kind branch that inverted which files are expensive, a two-open probe error, and a +/-1 span
error, several of which corrected the LEAD's own framing. None of that transfers. A new member is
not less careful; it is less loaded, and the errors it will make are the ones this document's trap
list exists to pre-empt. Front-load the traps explicitly, and audit its first few reports against
actual tool output before relaying any of them upward.

The corollary, and the reason §5's last bullet matters more than any individual finding:
accumulated context does not survive a rotation, but the INSTRUCTION does. "Verify the term in the
code, never infer it, and report what you find even when it contradicts whoever asked" reproduces
the same class of catch with a member who has none of the history.

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

---

# Round 2 execution record (m3-lead-2-opus)

## 8. AC5 is AMENDED, not retired — the frozen-blob gate re-anchors

`test/dng_nav_probe_m3_test.dart` asserted `imageCache.currentSize == 5` at `:101`, against a 14-item
all-cheap corpus selected at index 5, sampled 50 ms in (before the 250 ms tier-2 debounce, so the
count is tier-1 only). That `5` **was the old ±2 tier-1 span itself**, not a description of it.
Round 2 widens tier-1 to the full −3..+5 retention window = indices 2..10 = **9** slots. AC2 and AC5
were therefore mutually unsatisfiable: the blob was byte-untouched AND red.

Ruled at orchestrator level and reported to the user: **narrow edit authorized.** Derivation — the
user's round-2 ruling (constants and code together, tier-1 widened to the full window) is the newer
and higher authority, and the frozen `5` encodes the requirement that ruling replaces. Same category
as round 1's `test/photo_source_test.dart:104-122`: a requirement change flowing down into a test
that encoded the old requirement, NOT a test bent to fit an implementation. The alternative — drop
the widening — guts the round the user ordered, which the contract's internal consistency cannot force.

| | sha256 |
|---|---|
| OLD (round 1 gate) | `be3a595d6cc49c48d9f4bd29e91ecf5827261c50ae6b5d1c18e911e8b47d2341` |
| **NEW (binding from `d87d1d5`)** | `59b1f3c7112b01784cd868ffd2fbd5bab9f25c30ec46eb8a26d542cee33b8e2c` |

Diff: **1 file, +8/-3**, one contiguous region `@@ -100,10 +100,15 @@` — the literal `5` → `9` plus
its reason string. Verified by the lead with `git show d87d1d5`, not taken on report. Committed alone
as `d87d1d5`; implementation is separate at `f9869db`.

**The other two gates are UNTOUCHED and STILL BINDING** (re-verified after all edits):
`scripts/tmp/dng_nav_probe_test.dart` `05565d33…`, `test/image_preload_controller_m3_amend3_test.dart`
`fcdd564e…`. The latter being green is the standing evidence that sequential RAW decode and the 250 ms
debounce are unmoved.

Witnessed transition: RED `tmp/verify/20260823T145208Z-frozen-blobs.txt` (`Expected: <5> Actual: <9>`
at `:101:5`, prediction written above the result, `REAL_EXIT=1`) → GREEN
`tmp/verify/20260823T145732Z-GREEN-frozen-blobs.txt` (`+11: All tests passed!`, `REAL_EXIT=0`).

## 9. Open item: the nine-slot tier-1 guarantee does NOT materialise on no-preview RAW folders

By design of the (A) split, not by defect. `_precacheTierOneWindow` consumes payloads and never
produces them (`:707-708` peeks, skips on null). The only payload-creation path for an item measured
`SourceCost.expensive` is gated by `allowsExpensiveWork(distance:)` = `distance <= kExpensiveStartupRadius`
= 1. So on a folder of no-preview RAWs, slots at distance 2..5 hold neither a tier-1 nor a tier-2 entry.
Cheap (preview-bearing) items are unaffected — `preloadImages` loads the whole −3..+5 window at
`:344-352` and awaits it before tier-1 precache at `:356`.

Closing this needs EITHER raising `kExpensiveStartupRadius` (forbidden — it is exactly the ~42 s vs
~25 s cold-settle violation the split exists to prevent) OR a new payload-creation path for RAW
outside ±1 (out of scope; contradicts "sequential RAW decode unchanged"). **Both are user decisions
for a later round.** Reported upward; not this round's work.

## 10. The eviction sweep needed no edit — correcting §in-scope item 2

The contract says the out-of-span sweep at `:716-724` is "updated to respect the new span". Mechanically
it already does: it evicts by `!neededIds.contains(id)`, and `neededIds` is built from the span being
widened. Asserted by test (TC-096) rather than assumed. The implementer caught this against the lead's
own framing.

## 11. Exit-code instrumentation: THREE distinct false-green variants, all live

1. Round 1 — `EXIT=` read from an artifact whose value was empty because `${PIPESTATUS[0]}` did not expand.
2. Round 2 — that same non-expansion recurred in this shell; caught by the implementer on its own first attempt, bad artifact retained alongside the good one.
3. Round 2 — **the background-task harness notification reported "completed (exit code 0)" for a run whose real `flutter test` exit code was 1.** That is the WRAPPER's code. Visible only because `REAL_EXIT=$?` was written into the artifact.

**Standing rule: exit codes are read from the artifact's own captured `$?`. Never from a harness
notification, never from `${PIPESTATUS[0]}`.** Variant 3 sits directly on the acceptance path and the
notification is more convenient to read than the artifact, which is precisely why it will be read.

## 12. Round-2 verification log (lead-performed, not taken on report)

Every claim below was checked by the lead in the tree or the artifact:
- Frozen shas before and after the authorized edit; blob diff via `git show`, full context not `-U0`.
- RED and GREEN artifacts read end to end: pre-registration genuinely precedes the result in-file; HEAD hash present; exit codes carry real values.
- Full suite `tmp/verify/20260823T145359Z-fullsuite.txt`: `EXPECT executed = 238` at line 3, `+237 -1` at line 342, `REAL_EXIT=1` at line 346 — 237+1=238, matched with no reconciliation, single failure being the predicted collision.
- Spans in code: `:719,723` now `kRetentionBefore`/`kRetentionAfter`; `kTierTwoRadius = 2` at `prefetch_scheduler.dart:32`, consumed at `:400,:404`.
- One evidence-path citation error caught (`…145153Z…` did not exist; real file `…145208Z…`). **A report whose evidence paths do not resolve is not verifiable evidence** — check paths against `ls` before signoff.

Three times this round the implementer corrected its lead's framing with evidence (the AC2-vs-AC5
distinction, the eviction sweep, the `git diff -U0` hunk count). §4b's claim holds: the instruction
transfers even when the context does not.
