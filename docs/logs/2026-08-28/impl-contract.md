# Convergence Contract — implementation round (2026-08-28)

## End state (one sentence)
Deliverables 1 (tier-2 forward bias), 2 (persistent decode worker, gated), and 3 (reload-preserving-selection helper) are implemented on main per their signed-off plans, with flutter analyze at 0 issues and the full test suite green; adaptive payload retention is untouched.

## In scope / plans (implementers follow the plan verbatim, no improvisation)
1. docs/superpowers/plans/2026-08-28-tier2-bias-and-persistent-decoder.md — Task 1 only (kTierTwoBefore=1 / kTierTwoAfter=3).
2. Same plan — Tasks 2–4: measurement gate FIRST (pre-registered GO/NO-GO in spec §B.5); GO → PersistentDecodeWorker + binding; NO-GO → stop, record numbers + G-022, deliverable 2 ends there legitimately.
3. docs/superpowers/plans/2026-08-28-reload-preserving-selection-helper.md — _reloadPreservingSelection + TC-248.

## Out of scope
- Adaptive payload retention (spec/plan exist; next session).
- Any change to ceyx (../flutter_dng_decoder / ceyx plugin) — read-only.
- UI/RSS measurement (user measures UI perf himself).

## Acceptance criteria
1. flutter analyze: 0 issues.
2. flutter test (full suite, -j 1, RC self-captured in artifact): all pass, no skips of pre-existing tests.
3. Deliverable 1: kTierTwoRadius replaced by kTierTwoBefore=1/kTierTwoAfter=3; TC-097 + M5-DW bodies updated per plan; AD-034 row present.
4. Deliverable 2: gate artifact docs/logs/2026-08-28/decode-worker-gate.txt exists with pre-registered rule above the numbers, RC=$? self-captured, binary provenance (nm) recorded; if GO: worker implemented per plan Tasks 3–4 with live-run proof artifact; if NO-GO: G-022 recorded and Tasks 3–4 not built.
5. Deliverable 3: helper extracted per plan; grep counts `targetFallbackIndex:` and `indexWhere((i) => i.id ==` in app_state.dart each drop 2→1; TC-248 present and seen red→green.
6. Commits per deliverable, Conventional Commits, pathspec-only adds/commits.
7. Round reviewer (opus) verdict CONFIRMED over the combined diff.

## Shared files (lead-owned, applied sequentially)
docs/sop/unit_test.md, memory.md — implementers send their row text to team-lead; only the lead edits these files.

## Round budget
1 round (max 2 review→fix cycles per protocol).
