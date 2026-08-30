# Lane-race round-1 review — S-1 excerpt (reconstructed)

The original `lane-race-round1-review.md` was written by the round reviewer as
an untracked file in the (since-removed) `Halcyon-lane-race` worktree and was
lost when that worktree was cleaned up after merge `894616d`. This excerpt is
reconstructed verbatim-in-substance by team-lead from the reviewer's delivered
verdict message (2026-08-30). Overall verdict was CONFIRMED, 0 blockers,
2 should-fix, 4 nits; S-1 below is the should-fix this branch fixes.

## S-1 — a THIRD instance of the same defect class, uncovered by either fix

`tier_two_scheduler.dart:344-345` (inline chained upgrade, key `(payload, id)`)
and `:378-379` (queued upgrade, key `(fullRes, id)`) are different LaneKeys, so
DecodeLane will not dedupe them, and at width >= 2 both can run for the SAME id
concurrently. `_upgradeFullRes` takes no in-flight claim at all — both pass the
pre-await `hasFullResEntryFor` check and both call the FFI decoder. Reachable
across two navigation passes. Cost: one wasted 61-406ms decode plus a
duplicated ~275MiB transient peak. It is NOT a leak precisely because Fix B
(first-writer-wins in `publishFullRes`, commit `eae7ebb`) now disposes the
loser — which is why this was should-fix and not a blocker. But it means the
"exactly ONE decoder call" property (AC-M5-4) and the frozen navigation probes
now only hold at width 1, and the shipped default became 3 (`ad52737`).

Reviewer's suggested fix: the same shape as Fix A (`0c0f152`) — a synchronous
`_upgradesInFlight` Set claim in `_upgradeFullRes`; TC-381b's harness in
`tier_two_publish_race_test.dart` already builds the exact fixture to test it.
