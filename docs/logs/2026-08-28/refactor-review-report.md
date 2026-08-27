# Refactor Review Report — team fable-review

2026-08-28 · refactor squad (lead: refactor-lead-fable) · analysis only, no source changes
Verified against HEAD `e664ff9a581e291bf2741280acbe445cba2af365`. All cited locations spot-checked by the lead.

Inputs: `refactor-review-coupling.md` (in-repo coupling/duplication scan), `refactor-review-reference-arch.md` (external reference-architecture comparison).

## Verdict

Architecturally, Halcyon needs no refactor: it already matches the shape the strongest references (Aves, Flutter official app-architecture guide) recommend for its size, with constructor-injected collaborators delivering the testability a DI-framework migration would promise (`lib/providers/app_state.dart:62-104`) and the one relevant ChangeNotifier scoping mitigation already applied (zoom state extracted to `ZoomController`, `app_state.dart:144-146`).

One small, genuine duplication survives both squads' filtering and the lead's spot-check. It is the entire list.

## Proposal 1 (only proposal) — deduplicate the "reload folder preserving selection" dance

- **Evidence**: `AppState.processStarred` captures selection (`lib/providers/app_state.dart:444-445`) then reloads via `loadFolder(targetSelectionId, targetFallbackIndex)` (`:467-473`); `AppState.deleteTrashed` repeats the same capture (`:499-500`) and reload (`:524-530`) verbatim. Both silently co-own the multi-branch selection-restore contract inside `loadFolder` (`:300-316`), and the two copies have already drifted slightly (one reads `_currentDir` at reload time, the other captures `dir` up front).
- **Benefit**: LOW–MODERATE. One owner for a subtle contract instead of two; removes the drift vector for any future file-mutating batch action.
- **Effort**: ~15 minutes; one private helper (e.g. `_reloadPreservingSelection()`), ~6 lines net removed, low risk, fully covered by existing `app_state_test.dart` paths.
- **Honest framing**: borderline on the nitpick line (its own author says so). Skip it with no loss if no third file-mutating batch action is planned; do it opportunistically the next time either method is touched.

## Findings considered and rejected (for the record, not proposals)

- **AppState-as-god-object**: 584 lines is coordination, not bloat — scanning, status persistence, preload, file actions, export, rename, and zoom were already deliberately extracted (AD-005/AD-015/AD-026, G-010). Splitting further reverses managed decisions.
- **Riverpod / Bloc / Clean-Architecture migration, repository-interface layer, Command/Result async wrapper**: all pure cost at ~10k LOC lib/; the payoffs each would sell are already present or the repetition (~3 async actions) is too small to pay for the abstraction. Details in `refactor-review-reference-arch.md`.

## Compliance

- `git status`: only new files under `docs/logs/2026-08-28/`; no source/config touched.
- Both analysts' citations verified by the lead against HEAD; no claim failed spot-check.
