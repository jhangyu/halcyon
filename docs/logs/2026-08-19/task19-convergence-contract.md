---
date: 2026-08-19
title: "Task 19 — Zoom State Extraction — Convergence Contract (FROZEN)"
---

# Task 19 Convergence Contract (FROZEN 2026-08-19)

Only the user may amend this contract. Anchor: branch `main`, HEAD `6aace8d`.
Source of truth for design detail: `docs/logs/2026-08-19/zoom-state-extraction-handover.md`.

## End state (one sentence)

`AppState` holds no zoom/animation state and `main_detail_view.dart` performs no
`AppState` setter writes; all zoom behaviour lives in a view-layer
`ZoomController` owned by `MainScreen`, with zero behavioural regression.

## In scope

- New file `lib/views/zoom_controller.dart` (`ZoomController extends ChangeNotifier`).
- `lib/views/main_screen.dart` — owns/creates/disposes the controller, keyboard entry.
- `lib/views/main_detail_view.dart` — consumes the injected controller.
- `lib/providers/app_state.dart` — removal of the 5 zoom fields + 3 zoom methods + `transformCtrl.dispose()`.
- New unit tests for `ZoomController` (plain `test()`, no widgets).
- Doc updates: `task.md` (Task 19 status), `memory.md` (G-010 / TD-011 closure + any new AD/G), `unit_test.md` (new TC entries).

## Out of scope (do not touch)

`sidebar_view.dart`, `status_line.dart`, `image_preload_controller.dart`, any macOS
native / Swift file, any performance work, double-tap zoom, zoom-level HUD,
replacing `lastKnownCenter` with `MediaQuery`.

## Acceptance criteria (mechanically checkable, each verified by a non-author)

- AC1 `flutter analyze lib test` → `No issues found!`
- AC2 `flutter test` → all pass, test count >= 95 (baseline at `6aace8d`).
- AC3 `grep -n "transformCtrl\|targetMatrix\|shouldAnimateZoom\|pointerPosition\|lastKnownCenter" lib/providers/app_state.dart` → no output.
- AC4 `grep -n "read<AppState>()\." lib/views/main_detail_view.dart` → no zoom-related hits.
- AC5 `lib/views/zoom_controller.dart` exists and is constructible without `AppState`
      (proved by the new unit tests instantiating it directly).
- AC6 New `ZoomController` tests cover: upper bound 5.0, scale <= 1.05 reset-to-centre,
      focus selection `pointerPosition ?? lastKnownCenter`. Each test MUST be shown red
      first (report the failing output) before it goes green.
- AC7 `flutter build macos --release` → `✓ Built ... Halcyon.app`.
- AC8 Manual checklist (handover §12, items 1–7) executed by the user; all pass.
  AC8 is the user's gate — the team reports "ready for manual verification", not a pass.

## Round budget

3 rounds. If the budget is exhausted with ACs unmet: stop, report the failure trail
and the remaining gap. Do not open a 4th round unilaterally.

## Red lines

- No `notifyListeners()` from inside a `LayoutBuilder` builder (infinite rebuild).
- `ZoomController` MUST be owned by `MainScreen`, not `MainDetailView` — zoom must
  survive photo switches (handover §11).
- Shared working tree: other sessions may have uncommitted files. FORBIDDEN:
  `git stash`, `git reset`, `git checkout --`, `git clean`. Commit only with explicit
  `git add <your files>`.
- No commits without the lead's sign-off.

## Outcome (2026-08-19, round 2 of 3)

Shipped as `6d74cd4`. AC1-AC7 verified by non-authors; AC8 (the 7-item manual
checklist) run by the user against a release build installed to /Applications —
all 7 pass. Review verdict: MERGEABLE, 0 blockers.

Note on staging: `app_state.dart` was staged via a filtered blob
(`git hash-object` + `git update-index`) because another session's uncommitted
thumbnail-export work lives in the same file; committing it verbatim would have
landed an import of the then-untracked `thumbnail_export_service.dart` and broken
a clean checkout. That session's worktree changes were left untouched.

## Parking lot (append only; nothing here enters this task)

Raised by the fresh review, deferred by the lead, awaiting user triage:

1. The listener-based animation trigger has no widget-level test — deleting
   `widget.zoom.addListener(...)` (`main_detail_view.dart:39`) kills all keyboard
   zoom with the whole suite still green. Today's only defence is manual AC8.
2. Nothing asserts `transformCtrl.dispose()` is called.
3. `MainDetailView` lost its `const`, so a sidebar drag now re-runs its build
   every pan frame.
4. `ZoomController.maxScale` and the literal `5.0`/`1.0` at
   `main_detail_view.dart:300-301` mirror each other with nothing enforcing it.
5. Zoom lifetime narrowed from AppState-lifetime to `_MainScreenState`-lifetime.
   No behavioural delta today because `home:` never remounts.
