# EXIF Rename — Convergence Contract (frozen 2026-08-20)

Frozen before work starts. Only the user may amend this file.

## Terminal state (one sentence)

Every task in `docs/superpowers/plans/2026-08-19-exif-rename.md` (Tasks 1–10) is
implemented on `main`, `flutter test -j 1` is green for the whole suite, and
`flutter analyze` reports `No issues found!`.

## In-scope deliverables

| # | Deliverable | Owner file(s) |
|---|---|---|
| T1 | `RenameRule` template renderer | `lib/services/rename_rule.dart`, `test/rename_rule_test.dart` |
| T2 | `planRenames` collision-free planner | `lib/services/rename_service.dart`, `test/rename_service_test.dart` |
| T3 | `applyRenames` + JSONL undo journal | same as T2 |
| T4 | `PhotoStatusStore` rule persistence + key remap | `lib/services/photo_status_store.dart`, `test/photo_status_store_test.dart` |
| T5 | `ExifMetadataService` batch reader + `exif` dep | `lib/services/exif_metadata_service.dart`, `test/exif_metadata_service_test.dart`, `pubspec.yaml` |
| T6 | macOS `halcyon/exif` native channel | `macos/Runner/AppDelegate.swift` |
| T7 | `AppState.renameByExif` / `undoRename` | `lib/providers/app_state.dart`, `test/app_state_test.dart` |
| T8 | Two-pane rename dialog + menu entry | `lib/views/rename_dialog.dart`, `lib/views/sidebar_view.dart`, `test/rename_dialog_test.dart`, `test/sidebar_view_test.dart` |
| T9 | Status-line undo/cancel affordance | `lib/views/status_line.dart`, `lib/providers/app_state.dart`, `test/status_line_test.dart` |
| T10 | Project docs (memory/unit_test/file_index/task/handover) | those five files |

## Out of scope

- Windows / Android / Linux native EXIF handlers (Dart `exif` package fallback only).
- Renaming a subset of the folder; moving files to another folder.
- Any UI redesign beyond `docs/mockups/exif-rename/variant-2-twopane.html`.
- Agent-driven UI verification (simulated taps, osascript, screenshots) — forbidden
  in this repo. Live-run verification (plan Task 6 Step 4, Task 8 Step 6) is a
  **user manual step**, reported as an open gap at sign-off, not silently deferred.

## Acceptance criteria (checked one by one at sign-off)

1. `flutter analyze` → `No issues found!`
2. `flutter test -j 1` → whole suite green, exit code 0, `All tests passed!`.
3. Declared test count matches: for each new test file,
   `grep -c "  test(\|  testWidgets(" <file>` equals the `+N` in that file's run.
4. TC-024 … TC-056 all exist and pass, in the files listed in plan Task 10 Step 2.
5. No file outside the T1–T10 owner list is modified (verified by `git status`).
6. `memory.md` contains AD-016, AD-017, G-011; `unit_test.md` contains rows for
   TC-024…TC-056; `file_index.md` lists the four new lib files.
7. Every commit uses Conventional Commits and is made by the lead after sign-off,
   never by a worker.

## Round budget

4 batches. If acceptance is not fully met after batch 4, stop and report the
failure trajectory to the user — no self-authorised batch 5.

## Batch plan (file-ownership disjoint within a batch)

- **Batch 1** (parallel): T1+T2+T3+T5 (impl-core) · T4 (impl-store) · T6 (impl-macos)
- **Batch 2** (serial): T7 — depends on all of batch 1
- **Batch 3** (parallel): T8 (dialog+sidebar) · T9 (status line + AppState tail)
- **Batch 4**: T10 docs + full-suite verification + sign-off

## Parking lot

Anything discovered mid-batch that is not an acceptance criterion lands here and
is reported to the user at shutdown. Nothing gets promoted to an acceptance
criterion mid-flight.

- (empty at freeze)
