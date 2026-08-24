# M6 redefinition session handover (2026-08-24, usage-gate convergence)

> Written by team-lead of `m6-redef-team` at ~90% usage. Resume point for the next session / post-reset cron.

## State: what is DONE and signed off
- Tasks #1–#6 all completed and signed off (inventory, arch re-evaluation, adversarial re-sweep, contract rewrite, doc consolidation, package research).
- Authoritative doc set (all in `docs/logs/2026-08-24/`):
  - `m6-feature-platform-matrix.md` — MASTER. Carries the user's per-item `RULED:` verdicts (2026-08-24) for F-01…F-28 and P-1…P-8 statuses. Update flow: matrix first, then sync the two docs below.
  - `m6-spec-contract.md` — contract C-1…C-8, design decisions, evidence, capability losses U-11/U-12, corrections log.
  - `m6-execution-plan.md` — G1 benchmark gate, test disposition (TC-089 case deleted, sha re-registration), Phases 0–6 with mechanical ACs, risks.
  - `m6-pkg-verification.md` — package research backing F-05/F-12/F-16/F-17/F-19.
- The four pre-consolidation docs (platform-only-inventory, addendum, contract-rewrite, arch-reevaluation) were deleted per user order; their content lives in the three docs above.
- No code/test/memory.md changes anywhere this round — docs only. Working tree outside docs/ untouched.

## ALL RULINGS COMPLETE (2026-08-24 3rd + 4th pass) — matrix, spec-contract and execution-plan ALL SYNCED
- F-05 remove HEIC now (decoder later); F-12 keep mac+win native Trash exception; F-13 keep; F-16 universal Open With on macOS/Windows/Android/iOS; F-17 desktop_drop; F-19 direct Process.run (C-3 gained an enumerated exception for the one F-19 site).
- P-1 RESOLVED: per-feature preference cascade — all platforms > +Android > mac/win/linux > mac/win minimum.
- P-8 RESOLVED: Swift-accelerator retention rejected; gate FAIL → optimise and re-gate.
- P-5 RESOLVED: pure-Dart `image` package for export (JPEG kept).
- Only P-2 (Linux .so build for FFI decoder) remains open; does not block Phases 1–3.

## NEXT (after usage reset)
1. Phase 0 residual: memory.md AD-010 erratum (memory.md:92) + two code-comment corrections (native_thumbnail_service.dart:83-88, halcyon_image.cpp:533-536). Requires user go-ahead to start touching code/docs outside docs/logs.
2. Team m6-redef-team shutdown per protocol (5 idle healthy + 2 zombie opus consolidators, zero files produced by zombies).
3. Then Phase 1 (benchmark gates G1/G2/G3) per m6-execution-plan.md §1.

## Next actions once rulings arrive
1. Update `m6-feature-platform-matrix.md` rows F-05/F-12/F-16 (+P-4/P-6 statuses) with the rulings.
2. Sync `m6-spec-contract.md` §5 and `m6-execution-plan.md` Phase 4 accordingly.
3. Then Phase 0 of the execution plan can start (contract freeze + AD-010 errata at memory.md:92, native_thumbnail_service.dart:83-88, halcyon_image.cpp:533-536).

## Team residue to clean at shutdown (follow ~/.claude/reference/team-shutdown-protocol.md)
- Team `m6-redef-team`. Idle healthy members: explorer-platform-sonnet, auditor-platform-opus, architect-opus, researcher-pkg-sonnet, consolidator-3-sonnet.
- **Zombies**: consolidator-opus and consolidator-2-opus (both stalled during a suspected opus API outage, both ignored shutdown_requests, both produced zero files — safe to force-clean; verify with tmux ls if TeamDelete complains).
- TaskList #1–#6 all completed; no pending tickets.

## Verification commands
```bash
ls docs/logs/2026-08-24/ | grep -E "m6-(spec-contract|execution-plan|feature-platform-matrix|pkg-verification)"  # 4 files
git status --porcelain -- lib/ test/ macos/ windows/ memory.md task.md   # empty (no code changes)
grep -c "RULED:" docs/logs/2026-08-24/m6-feature-platform-matrix.md      # ~28
```
