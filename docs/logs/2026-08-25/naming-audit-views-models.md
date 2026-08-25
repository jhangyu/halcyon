# Naming Audit — lib/views/, lib/models/, lib/main.dart

Date: 2026-08-25
Scope owner: scan-views (Task #2)
Method: full manual read of every file in scope + memory.md AD/G cross-check (no codebase-memory graph queries needed — file count small enough for direct read; grep sweep run for stale-suffix markers).

## Files covered (16 total)

- `lib/main.dart`
- `lib/models/photo_item.dart`
- `lib/models/supported_photo_formats.dart`
- `lib/views/batch_delete_feedback.dart`
- `lib/views/main_detail_view.dart`
- `lib/views/main_screen.dart`
- `lib/views/photo_action_bar.dart`
- `lib/views/rename_dialog.dart`
- `lib/views/rename_dialog/actions.dart`
- `lib/views/rename_dialog/preview_list.dart`
- `lib/views/rename_dialog/rule_editor.dart`
- `lib/views/rename_dialog/section_label.dart`
- `lib/views/settings_dialog.dart`
- `lib/views/sidebar_view.dart`
- `lib/views/status_line.dart`
- `lib/views/theme_tokens.dart`
- `lib/views/zoom_controller.dart`

## Summary

This scope is clean. No semantic-drift or stale version/generation-suffix findings. This codebase has been through repeated documented refactor rounds (AD-014, AD-015, AD-020, AD-024–028 in memory.md) that specifically target naming/responsibility hygiene in this exact directory (e.g. AD-015 extracted `ZoomController` explicitly to fix a naming/responsibility problem; AD-014 rewired sidebar preload triggering). A grep sweep for `v2|legacy|deprecated|old|new|tmp|temp|fixed|full` across all 16 files found zero identifier hits (the one match was inside a UI string, not an identifier). No class/method/field name found where the name says X and the code does Y.

One low-severity **inconsistent** finding below; nothing rose to misleading or stale-suffix severity, so those two buckets are empty.

## Findings

### Inconsistent (1)

| file:line | current name | evidence | proposed name | usage count | risk |
|---|---|---|---|---|---|
| `lib/views/sidebar_view.dart:305`, `:324`, `:366` | `iconColor` (×2) vs `actionTextColor` (×1) | All three bind the exact same call `_iconColor(context)` to different local names within the same widget/file: `_buildTopActions` (:305) and `_buildActionMenu` (:324) both call it `iconColor`; the `itemBuilder` closure nested inside `_buildActionMenu` (:366) rebinds the identical call to `actionTextColor` purely because it's used to color menu-item text rather than an icon. | Rename `actionTextColor` → `iconColor` (or introduce one shared local passed into the closure) so the same value has one name across the file. | 3 call sites, all internal to `sidebar_view.dart` | internal-only, zero external callers, trivial rename |

## Not flagged (considered and ruled out)

- `RenamePreviewList`, `RuleEditor`, `RenameActions` all take a `HalcyonTokens t` parameter — single-letter name, but used consistently as the established convention across the entire `rename_dialog/` subtree; not drift.
- `kThumbnailStarredMenuValue` → `AppState.exportStarredThumbnails` (`sidebar_view.dart:340,345`) — constant name, UI label ("Thumbnail Starred..."), and target method name all agree on "thumbnail" + "starred"; no mismatch.
- `PhotoItem.displayName` forwarding to `id` (`models/photo_item.dart:18`) — documented as intentional display-purpose alias, not drift (there is no other candidate value it could show).
- G-021 in memory.md is a documented intentional stale-looking artifact (placeholder entry kept only so old references still grep-hit) — correctly not a rename candidate, it's data not code.

## Acceptance criteria status

1. Report file exists and lists all 16 covered files — PASS.
2. Every finding has file:line + evidence + proposed name + usage count — PASS (1 finding).
3. No code files modified — PASS (read-only session).

## Uncertain / not done

- None. Full scope read directly; no MCP graph indexing was needed given the small file count (2,975 total lines).
