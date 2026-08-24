# M6 R1 handover — session 2 → session 3 (2026-08-24, context-gate convergence)

> Written by the team-lead of `m6-r1-team` at the 45% context threshold. Next session resumes as team lead.

## Startup sequence (do in order)
1. Read this file, then `docs/logs/2026-08-24/m6-execution-plan.md` (the authoritative writing-plans-format plan; header + Global Constraints + the not-yet-done sections P4.1–P4.6, P5.1–P5.3) and `m6-feature-platform-matrix.md` §3 (rulings P-1…P-14 — ALL resolved except P-2 Linux `.so`).
2. `TaskList` — tickets #1–#6 should be completed (#6 pending the cycle-2 verdict below); #7/#8/#9 (P4, P4 review, P5) remain, blockedBy-chained.
3. Team residue: NONE expected — ticket #6 closed (cycle-2 verdict MERGEABLE, EXIF fix 2f01a6b independently verified), all members rotated out before this handover finalized. If `~/.claude/teams/m6-r1-team/config.json` still lists live members, follow team-shutdown-protocol before spawning replacements.

## State: DONE and signed off (all on `main`, working tree clean apart from scratch)
- **P0+P1 merged**: errata (13023aa) + gates. Gate rulings: G1 V1 same-isolate PASS (P-9 sync-read accepted); G2 accepted (P-10); sidebar gate closed by P-13 ruling — **standing rule: any per-sample decode < 75 ms passes outright, regardless of the 2.0× ratio clause** (recorded in plan Appendix A).
- **P2 complete + reviewed mergeable**: pure-Dart producer `dart_image_loader.dart`, F-08 extension-gate removal, composition-root switch, sidebar codec + P2.5b RAW-decode fallback (`decodeOnWorker(maxDim:)`; vendored dylib exports the sized symbol), generation-guard blocker fix (251f3fb).
- **P3 complete (ticket #5 closed)**: HEIC removed (68308c4), export via `image` pkg (dd1edcb), oversized guard (d2c4469), macOS native thumbnail deletion (ce5a81c), Windows native image deletion (12a98df), Dart channel-service deletion → `image_source_types.dart` (3a7a2b2 + 86d12ee), EXIF isolate-only (36dfc37), exit batch (476a2f0). Suite 272/272 skipped 0; macOS + Android release builds green.
- **P3 review**: oracle probe 8/8 (orientation mapping independently verified); the one should-fix (export EXIF loss) fixed per user ruling P-14 in **2f01a6b** (core-tag copy via pkg:exif; `copyResize` drops exif — explicit reattach; `img.decodeJpg` strips Orientation at decode — independent-oracle test). Awaiting reviewer cycle-2 confirmation only.

## NEXT (in order)
1. ~~Close ticket #6~~ DONE — MERGEABLE, ticket closed, reviewer shut down.
2. **P4** (ticket #7): dispatch per plan sections P4.1–P4.6 — parallel-safe split: P4.1 desktop_drop (pubspec, main_screen, flutter_window.cpp trim) / P4.2 reveal (status_line.dart — THE one C-3 exception site) / P4.3 keyboard recycle route (main_screen + photo_action_bar) / P4.4 Windows association (research step first) / P4.5 Open With mobile (research step first; flow parked on P-1 tier-2). P4.1+P4.3 share main_screen.dart — same worker or serial. Then P4.6 exit batch + P4 round review (ticket #8).
3. **P5** (ticket #9): F-25 cache-budget seam, C-4 re-baseline audit (unit_test.md TC matrix update owed for: TC-047/048 deleted, TC-049 added, TC-089 deleted, new P2/P3 tests), post-merge verification + G″″ regression re-run (75 ms floor applies). Final task closure is the USER's, not agents'.

## Standing discipline that caught real bugs this round (keep enforcing)
- RC self-captured, never through pipes/tee (bit three times); notifications lie in both directions.
- Prove the measured binary contains the code under test (G3″ measured a dylib without the sized symbol → numbers ruled inadmissible; G3‴ used dims-marker proof).
- Teammate-negative conclusions = timing first (three "failures" this round were WIP-flux artifacts; one "artifact includes deletion" claim was my own grep|head RC bug).
- Reviewers verify via independent oracles, not the implementation's own outputs (bakeExifOnDecoded probe; Orientation via pkg:exif because img.decodeJpg strips it).
- Workers stop-and-report on plan-vs-reality conflicts; the plan text gets amended (Step 2b pattern) so docs never drift from executed reality.

## Parking-lot (report to user at round end)
- P-2 open: Linux `.so` build for FFI decoder (F-07/F-09 land on mac/win/android tier until it exists).
- ~26 idle claude-swarm tmux servers from PAST sessions (idle shells, fail-closed, 48h auto-clean hook).
- External session committed five-platform DNG plan docs (f8ac3ab, ce1dd73, under docs/superpowers/plans/) — subject overlaps this contract; user may want them reconciled with the matrix.
- PNG-only re-encode in sidebar RAW fallback (perf tradeoff; JPEG-encode candidate now that `image` pkg is in).
- JPEG sidebar latency item CLOSED by P-13 (no further loop).
- memory.md AD entry for the M6 contract + G-entry for the G3 instrument lesson: owed in P5.2.

## Verification commands (run to confirm this handover's claims)
```bash
git log --oneline -14   # expect 2f01a6b at tip (or reviewer-era commits after)
flutter analyze         # 0
flutter test -j 1       # 272/272, skipped 0 (count grows with P4 work)
grep -rn "halcyon/thumbnail|halcyon/exif" macos windows lib   # no rows
grep -c "RULED:" docs/logs/2026-08-24/m6-feature-platform-matrix.md  # ~28
```
