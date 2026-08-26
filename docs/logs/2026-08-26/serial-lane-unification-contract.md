# Convergence Contract — cheap/expensive lane unification (2026-08-26)

User ruling (supersedes user decision D2 and AD-018): the ±1 expensive-startup
radius must not exist. The ONLY permitted behavioral difference between
cheap and expensive items is the payload-production concurrency mode:
cheap = parallel, expensive = serial, serial order near-to-far from the
selected index (0, +1, -1, +2, -2, +3, -3, +4, +5, clamped). Every other
subsystem — payload retention (-3..+5), tier-1 precache, tier-2 full-res
(±2 behind the 250ms navigation debounce), payload cache, tier-2
registry — is shared identically by both kinds.

## 終態 (end state, one sentence)

In an all-expensive (no-preview RAW) folder, a settle at index N fills the
whole -3..+5 payload window serially near-to-far with never more than one
RAW decode in flight, so stepping +1 then immediately +2 (or any step
within the settled window) displays instantly, exactly as it does for JPEG.

## In scope

- `lib/services/image_pipeline/prefetch_scheduler.dart` — delete
  `kExpensiveStartupRadius` and `allowsExpensiveWork`; cost memo/probe stay.
- `lib/services/image_pipeline/image_preload_controller.dart` — lane routing:
  after classify, cheap → parallel (as today), expensive → shared serial
  decode lane; delete the rung-refusal gate (current lines 542-549); window
  pass iterates near-to-far; a serially-landed payload gets its tier-1
  ImageCache entry decoded and notifies, without waiting for a next pass.
- `lib/services/image_pipeline/tier_two_scheduler.dart` — extract the serial
  queue into a shared single-flight lane (one decode in flight, pending
  entries reprioritizable); tier-2 keeps using it for catch-up loads and
  full-res upgrades; ±2 window and 250ms debounce unchanged.
- `lib/services/image_pipeline/photo_source.dart` — `allowExpensive`/
  `deferred`/`loadExpensive` either removed or repurposed strictly as
  lane-handoff (an unmeasurable file discovered as NeedsRawDecode mid-load
  is re-enqueued onto the serial lane, never stranded); no radius semantics.
- Affected tests under `test/services/image_pipeline/` (TC-098 replaced by
  the new invariant; TC-088/P2/P3/P4, dual-window, tier-two scheduler tests
  updated to the new contract).
- `memory.md` (AD-018 marked overturned, new AD recorded), `unit_test.md`
  (matrix updated), stale code comments referencing D2/±1.

## Out of scope (parking-lot, not this task)

- Cheap/expensive classification threshold (`largestLongEdge >= longEdge`).
- View-layer spinner/UX changes beyond what compiles.
- Perf instrumentation reshaping; scripts/build_apps.py; native code.
- Tier-2 radius or debounce value changes.

## Acceptance criteria (each mechanically checkable)

1. `grep -rn "kExpensiveStartupRadius\|allowsExpensiveWork" lib test tool`
   returns zero hits.
2. New test: all-expensive folder, settle at N → payload cache contains every
   id of the clamped -3..+5 window (not just ±1).
3. New test: fake-decoder concurrency counter proves at most ONE expensive
   decode in flight at any time, while cheap window loads still issue in
   parallel.
4. New test: fresh settle decode START order is distance order
   0, +1, -1, +2, -2, +3, -3, +4, +5 (clamped), asserted from the fake
   decoder call log.
5. New test: navigate to M while the serial lane is mid-queue → no decode
   starts for an item outside M's retention window; the next decode after
   the in-flight one completes is M's nearest missing item.
6. Tier-2 unchanged: TC-095, TC-096, TC-097, TC-099, TC-100, TC-239..242
   pass (updated only where they encoded the ±1 radius).
7. `flutter analyze` = 0 issues; full `flutter test` green (RC self-captured
   in artifact per 08-23 rule).
8. `memory.md` records the overturned AD-018 + successor AD; `unit_test.md`
   matrix covers every new/changed TC; no code comment still claims the ±1
   startup radius or D2 as current design.

## Round budget

3 rounds (implement → fresh review + full gate → blocker fixes). Budget
exhausted with criteria unmet → stop and report the failure trail; no
round 4 without the user.
