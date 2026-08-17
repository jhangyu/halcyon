# Convergence Contract — Recycle Mode Implementation

Frozen: 2026-08-18. Only the user may amend this after freezing.

## Terminal state (one sentence)

Recycle mode is live: in a folder holding same-basename sibling groups, batch delete moves the whole group into `<folder>/.trash/` with collision suffixes, the detail-view delete button shows `restore_from_trash*` and toggles mode on right-click, the sidebar follows the mode, success shows a 2.5s SnackBar and failures show a blocking dialog — with `flutter test` green and `flutter analyze` clean.

## Authoritative documents

- Spec: `docs/superpowers/specs/2026-08-17-recycle-mode-design.md`
- Plan (task-by-task, code included): `docs/superpowers/plans/2026-08-17-recycle-mode.md`

The plan is the single source of truth for task content. Implementers execute their assigned tasks verbatim from it.

## In-scope deliverables

Tasks 1–6 of the plan, each landing as its own commit:

1. T1 — `.cr2/.nef/.orf` added to `supportedExtensions`
2. T2 — `PhotoFileActions.recycleTrashed`, `RecycleOutcome`, `MoveFile`
3. T3 — `AppState.recycleMode`, `toggleRecycleMode`, `BatchDeleteResult`, dispatch
4. T4 — `PhotoActionBar` extraction, mode icons, right-click toggle
5. T5 — `showBatchDeleteFeedback`
6. T6 — sidebar status icon, menu label, feedback wiring

## Out of scope (do not build, do not "improve")

- Restore-from-`.trash` UI
- `.trash` auto-cleanup or quota management
- Mode persistence across folders
- Automatic fallback to `.trash` when the system trash API fails
- Turning direct-delete into a permanent delete
- Any change to `processStarred` (copy/move path)
- Any refactor not named in the plan

Checked: if none of the above ever lands, the terminal state is still reachable.

## Acceptance criteria (checked one by one at signoff)

1. Each of T1–T6 has its own commit; `git log --oneline` shows six new commits.
2. Every new test was observed failing before it passed. Evidence: the implementer's report quotes the actual red output (error text) for each new test.
3. `flutter test` exits 0 and prints `All tests passed!`. Per-file progress lines are NOT evidence (overwriting progress display omits fast files).
4. `flutter analyze` prints `No issues found!`.
5. Test count sanity: `grep -c "test(\|testWidgets(" test/*.dart` total matches the `+N` count in the test run.
6. Icon assertions pass in both directions: recycle mode finds `Icons.restore_from_trash_outlined`/`Icons.restore_from_trash`, direct mode finds `Icons.delete_outline`/`Icons.delete`.
7. Grep confirms no persistence leaked in: `grep -rn "recycleMode" lib/` shows no `SharedPreferences` or `.halcyon_status.json` write.
8. Verified against the delivered tip: every verification report states the `git rev-parse HEAD` it ran against, and that hash equals the final commit.

T7 (live macOS run) is explicitly NOT part of team signoff — it is raised to the user separately, because observing a real window is not something a reporting agent has been reliable at.

## Wave budget

Four implementation waves, dictated by the dependency graph, plus one signoff wave:

- Wave 1 (parallel): impl-state → T1 | impl-ui → T2
- Wave 2: impl-state → T3 (needs T2)
- Wave 3 (parallel): impl-ui → T4, T5 (need T3)
- Wave 4: impl-state → T6 (needs T4, T5)
- Wave 5: full-suite verification + fresh review

Within any single wave, at most two retry attempts. Exhausted budget with acceptance criteria unmet → stop and report the failure trace to the user; do not open a further wave unilaterally.

## File ownership (mutually exclusive; two members never edit the same file)

**impl-state**
- `lib/models/supported_photo_formats.dart`
- `lib/providers/app_state.dart`
- `lib/views/sidebar_view.dart`
- `test/app_state_test.dart`
- `test/sidebar_view_test.dart`

**impl-ui**
- `lib/services/photo_file_actions.dart`
- `lib/views/photo_action_bar.dart`
- `lib/views/main_detail_view.dart`
- `lib/views/batch_delete_feedback.dart`
- `test/photo_file_actions_test.dart`
- `test/photo_action_bar_test.dart`
- `test/batch_delete_feedback_test.dart`

**test-runner**: owns nothing; runs commands and writes artifacts under `scripts/tmp/verify/`.

## Parking lot

Anything discovered mid-wave that is not in the acceptance criteria goes here and is reported to the user at the end. It does not get built, and it does not become a new acceptance criterion. Only R3 cases (security hole, false premise, irreversible risk) interrupt a wave.

- (empty at freeze)
