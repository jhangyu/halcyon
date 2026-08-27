# Convergence Contract — Adaptive Payload Retention (frozen 2026-08-28)

## End state (one sentence)
The app reads total physical RAM once at startup (macOS MethodChannel, null elsewhere) and sizes the payload retention window, payload byte budget, and ImageCache budget from it, with today's -3..+5 / 224 MiB / 768 MiB as the floor and no-reading default.

## In scope
Plan of record: `docs/superpowers/plans/2026-08-28-adaptive-payload-retention.md` Tasks 1–5.
Spec of record: `docs/logs/2026-08-28/spec-adaptive-payload-retention.md`.

## Out of scope
Windows/Linux/Android/iOS native handlers; UI tuning of rung depths; `kTierTwoRadius` / tier_two_scheduler; runtime re-sizing; any eviction-order / payload-kind / cache-key change.

## Acceptance criteria
Spec AC-1 … AC-13, verbatim from `docs/logs/2026-08-28/spec-adaptive-payload-retention.md` §5. All work happens in worktree `/Users/jhangyu/project/Halcyon-adaptive-retention` on branch `feat/adaptive-payload-retention`. After all ACs pass and review confirms, the branch is merged to `main` and the targeted suite re-run on `main` (post-merge gate).

## Round budget
3 rounds. Budget exhausted with ACs unmet → stop and report failure trace; no self-started round 4.

## Parking lot
- AC-1's literal "grep prints nothing" is unsatisfiable: two pre-existing prose doc comments match (`lib/main.dart:18`, `lib/services/image_pipeline/cache_budget.dart:6`), and the plan's own Step 5.3 comment re-adds one. No platform-conditional CODE exists in lib/. Mechanical check used instead: after excluding comment-only lines, zero matches. Spec wording fix deferred to user.
- `docs/sop/` is gitignored and exists only in the main repo; worktree cannot carry the plan's Step 5.7 doc edits. Resolution: content written to `docs/logs/2026-08-28/sop-updates-adaptive-retention.md` in the worktree; lead applies it to the main repo's docs/sop at merge time.
- Plan AC "grep -c kPayloadByteBudget == 2" is an off-by-one (actual 3: import, default param, and the stable log field-name literal Step 5.5 says to keep). Substantive AC met.
- Plan Step 3.5 commit command had `-m` after `--` (git parses it as pathspec); workers commit with `-m` before `--`. Plan text not amended.

Round-1 review findings (verdict CONFIRMED, no blockers; parked for the user):
- [should-fix] Spec §6 risk 4's mitigation does not hold as implemented: machines ≥3 GiB are already at the 768 MiB ImageCache ceiling, so the mid/high rungs widen the tier-1 span (9→12→15 slots) with ZERO extra ImageCache; per docs/logs/2026-08-23/cache-sizing-estimate.md figures the high rung leaves ~4% headroom and LRU may evict tier-2 entries the back-navigation guarantee depends on. Options: raise/rung-scale the ImageCache ceiling after the user re-derives sizing, or amend spec risk 4 + AD-035 to stop claiming absorption.
- [nit] Live-proof binary predates commits 1011709/b6a662f (startup line self-evidences main.dart, but controller plumbing in that binary is not HEAD-bound). Rebuild after merge or add an in-app version stamp.
- [nit] startup.memory debugPrint ships in release builds (RAM figure in device logs); consider gating behind the perf flag.
- [nit] Uncommitted macos/Podfile.lock drift in worktree (vendored ceyx 0.0.1→0.1.0 checksum, build side effect consistent with ed2e9ed's bump). Not merged; user decides where it lands.
