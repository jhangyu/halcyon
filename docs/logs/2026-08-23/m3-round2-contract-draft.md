# M3 round 2 — contract DRAFT (pending orchestrator approval)

> Squad m3-lead-opus / m3-impl-1-opus / m3-test-haiku. Worktree `/Users/jhangyu/project/halcyon-m3`,
> branch `m3-cache`, base `0c9e3b7`. Round budget: 3 rounds. Frozen once the orchestrator approves;
> only the user may change it afterwards.
> Units: MiB throughout (bytes / 1048576), raw byte counts pinned for anything load-bearing.

## End state (one line)
The −3..+5 window holds a screen-resolution entry for every slot and a full-size entry for −2..+2,
sized by the user's constants (224 MiB payload / 768 MiB ImageCache), with sequential RAW decode,
the 250 ms debounce and every JPEG behaviour bit-for-bit unmoved.

## Resolved before freeze: the shared-radius constant

`kExpensiveStartupRadius = 1` (`prefetch_scheduler.dart:12`) is ONE constant serving TWO meanings:
- the tier-2 full-size decode window (`image_preload_controller.dart:393,397`), which the spec widens
  to ±2; and
- expensive-RAW startup eligibility (`prefetch_scheduler.dart:99` `allowsExpensiveWork`, `:108`
  `allowsStartup`).

Widening the single constant moves BOTH, putting five items on the sequential RAW rung instead of
three — ~42 s cold settle instead of ~25 s on a no-preview folder, at the measured 8.5 s per
expensive settle.

**DECISION: SPLIT THE CONSTANT.** New `kTierTwoRadius = 2` governs the full-size decode window;
`kExpensiveStartupRadius` stays `1` and continues to gate RAW startup eligibility only.

This is DERIVED from two standing user statements rather than chosen by preference, so it needs no
further ruling:
1. the frozen clarification — *"±1: expensive RAW STARTUP eligibility only, never a retention
   boundary"*; and
2. the round-2 ruling — *"sequential RAW decode unchanged."*
Both can be simultaneously satisfied ONLY by splitting. Widening the shared constant would satisfy
the tier-2 requirement while silently violating (1) and (2) — while appearing to implement exactly
what was asked. Recorded as the lead's derivation; the orchestrator or user may override at freeze,
in which case AC6 and the sequential-decode out-of-scope line change with it.

## In scope
1. `main.dart:12` `imageCacheMaxBytes` → 768 MiB; `photo_payload_cache.dart:19` `kPayloadByteBudget`
   → 224 MiB.
2. `_precacheTierOneWindow` (`image_preload_controller.dart:696-724`): span widened from a hardcoded
   ±2 to the retention window (`kRetentionBefore`/`kRetentionAfter`, i.e. −3..+5), and the
   out-of-span eviction sweep at `:716-724` updated to respect the new span.
3. Tier-2 full-size decode window widened ±1 → ±2, per option (A) via a new dedicated constant.
4. Tests for the new guarantees (see AC2, AC3), RED before GREEN where feasible.
5. A real measured run demonstrating the guarantee, reusing the AC8 harness.

## Out of scope
- M4 / M5 / M6.
- **Absolute-RSS attribution.** The 532.3 MiB residual stays a NAMED OPEN ITEM, not this round's work.
- Any change to sequential RAW decode or the 250 ms debounce.
- The payload retention rule itself (−3..+5 stays; only the precache spans move).
- PL-owned files; `scripts/tmp/dng_nav_probe_test.dart`; the two frozen test blobs.
- Merging to main (orchestrator merges).

## Acceptance criteria (mechanically checkable)
- **AC1** — constants verbatim: `grep -n "imageCacheMaxBytes = " lib/main.dart` shows `768 << 20`
  (805,306,368 B) and `grep -n "kPayloadByteBudget = " lib/services/photo_payload_cache.dart` shows
  224 MiB (234,881,024 B).
- **AC2** — a test proves a tier-1 ImageCache entry exists for ALL NINE window slots and is NOT
  evicted while in-window. Named killer: an item at −3 or +5 retains its tier-1 entry.
- **AC3** — a test proves tier-2 entries exist for −2..+2 (five slots) after the debounce settles.
- **AC4** — full suite green, count pre-registered BEFORE the run, hash-bound to the tested HEAD;
  `flutter analyze` "No issues found!"; exit code captured (not inferred).
- **AC5** — frozen blobs byte-untouched and green: `test/dng_nav_probe_m3_test.dart`
  (`be3a595d…`), `test/image_preload_controller_m3_amend3_test.dart` (`fcdd564e…`),
  `scripts/tmp/dng_nav_probe_test.dart` (`05565d33…`). JPEG controls unmoved.
- **AC6** — expensive-RAW startup eligibility remains ±1 (option A): grep shows
  `allowsExpensiveWork`/`allowsStartup` still bound to `kExpensiveStartupRadius = 1`.
- **AC7** — M2 type-blindness greps still 0 for `image_preload_controller.dart`,
  `prefetch_scheduler.dart`, `photo_payload_cache.dart`; AC3-of-round-1 (`photo_payload_cache.dart`
  names no payload kind) still 0.
- **AC8** — a REAL measured run of the new guarantee (AC8 harness reused). Peak RSS recorded and
  compared against the 768 + 224 arithmetic. **REPORTED, NOT GATED** — the gate is the user's
  amended relative criterion (not worse than the pre-M3 baseline under the identical method).
  Method agreed with the lead BEFORE the run; expectation pre-registered before the number exists.
- **AC9** — `main_detail_view.dart:280-285` call sites and `tierOneProviderFor`/`fullSizeProviderFor`
  unchanged (`git diff` for those lines == 0).
- **AC10** — every battery artifact hash-bound to the HEAD it ran against.

## Process
- Mid-point gate: lead audit before irreversible controller edits.
- Artifact-first: raw output written to `tmp/verify/` before any report.
- Worker reports READY_FOR_SIGNOFF with evidence; the lead signs off and closes.
- Test runner captures raw output and does NOT judge.
- No `git stash`/`reset`/`checkout --`/`clean`; explicit `git add` of own files only.
