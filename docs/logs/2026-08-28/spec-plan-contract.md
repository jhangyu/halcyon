# Convergence Contract — spec & plan phase (2026-08-28)

## End state (one sentence)
Three spec files and three implementation-plan files exist covering the four accepted review proposals, ready for an implementation team to execute proposals 1, 2, and the dedup helper this session (adaptive retention deferred to a future session).

## Deliverables (exclusive file ownership per member)
1. **spec-perf12-opus**: `docs/logs/2026-08-28/spec-tier2-bias-and-persistent-decoder.md` + plan `docs/superpowers/plans/2026-08-28-tier2-bias-and-persistent-decoder.md` — proposals 1 (forward-bias tier-2 window) and 2 (persistent decode worker, incl. the mandatory measure-first gate).
2. **spec-adaptive-opus**: `docs/logs/2026-08-28/spec-adaptive-payload-retention.md` + plan `docs/superpowers/plans/2026-08-28-adaptive-payload-retention.md` — proposal 3 (machine-adaptive payload retention incl. the physical-memory source design). SPEC/PLAN ONLY — implementation deferred to next session.
3. **spec-dedup-opus**: `docs/logs/2026-08-28/spec-reload-preserving-selection-helper.md` + plan `docs/superpowers/plans/2026-08-28-reload-preserving-selection-helper.md` — extract the duplicated "capture selection → mutate files → loadFolder preserving selection" dance in AppState.processStarred/deleteTrashed into one private helper.

## Source material (read, do not modify)
- docs/logs/2026-08-28/perf-review-report.md, perf-review-memory-lifecycle.md, perf-review-concurrency.md
- docs/logs/2026-08-28/refactor-review-report.md, refactor-review-coupling.md
- Plan rules: /Users/jhangyu/.claude/plugins/cache/jhangyu/podium/1.0.3/skills/writing-plans/SKILL.md (two-stage process + self-review are mandatory)

## Acceptance criteria
1. Each spec states: goal, in/out of scope, current-behavior evidence (file:line at HEAD e664ff9), proposed design, acceptance criteria, risks.
2. Each plan follows writing-plans SKILL.md: complete skeleton first, then bite-sized steps with code, TDD, mechanically checkable acceptance per task, self-review run.
3. Proposal 2's plan includes the headless decodeMs/processMs measurement gate BEFORE the persistent-worker build, with a stated go/no-go criterion.
4. No source/test/tool file modified in this phase.

## Out of scope
- Any implementation. Adaptive payload retention implementation (next session).

## Round budget
1 round.
