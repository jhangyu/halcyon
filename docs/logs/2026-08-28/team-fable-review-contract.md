# Convergence Contract — fable-review (2026-08-28)

## End state (one sentence)
Two review reports exist under docs/logs/2026-08-28/ — one performance, one architecture/refactor — each proposing ONLY the highest-value improvements (or stating "已無值得改善的地方"), with zero source-code changes.

## In scope
- Performance squad: memory strategy, isolate/process scheduling, decode lifecycle, feasibility of scaling expensive RAW decode to 2–6 concurrent workers based on machine capability, tier-1/tier-2 dual-window strategy improvements.
- Refactor squad: high-coupling spots, duplicated functionality needing decoupling, comparison against strong reference architectures from similar open-source projects.

## Out of scope
- Any modification to lib/, test/, tool/, macos/, scripts/ or other source/config files.
- UI/RSS performance measurement (user measures UI perf himself — headless reasoning/benchmark analysis only).
- Implementing any proposal.

## Acceptance criteria
1. `docs/logs/2026-08-28/perf-review-report.md` exists: ranked proposals (max 3) each with evidence (file:line), expected benefit, and effort estimate — OR the single verdict "已無值得改善的地方".
2. `docs/logs/2026-08-28/refactor-review-report.md` exists: same format.
3. Every proposal cites real code locations that exist at current HEAD.
4. `git status` shows no modifications outside docs/logs/.
5. No proposal is over-engineering (no speculative abstraction, no micro-optimization without measurable benefit).

## Round budget
1 round (analysis only). Escalate to user if a second round seems needed.
