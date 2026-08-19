# EXIF Rename — Design

Date: 2026-08-19
Status: Approved (design), implementation not started

## Goal

Let the user batch-rename every photo in the currently opened folder from its
EXIF metadata, using a default `YYYY-MM-DD-hh-mm-ss` pattern, three alternate
date presets, or a user-composed rule built from EXIF variables. Must handle
folders of ~10,000 photos without freezing the UI, and must be undoable.

## Scope

In scope:
- New `Rename by EXIF...` entry in the sidebar action menu, directly above
  `Recycle Trashed` / `Delete Trashed`.
- Rename dialog: preset picker, custom rule editor, live 5-file random preview.
- EXIF metadata read service (macOS native + Dart fallback).
- Rename planning (pure function) and application (serial, cancellable).
- Undo of the last rename batch via an on-disk rename log.
- Progress + result reporting in the existing status line.

Out of scope:
- Renaming folders, or moving files between folders.
- Renaming a subset (starred only) — the operation always covers the whole
  loaded folder.
- Windows/Android native EXIF (covered by the Dart fallback path).

## Decisions

| # | Decision |
|---|---|
| D1 | Scope of operation = all photos in the current folder. |
| D2 | `{seq}` is a user-placed variable, default width 1 digit (`{seq:3}` for 3). A hard collision that survives planning still gets a `-1`/`-2` suffix as a last resort — never overwrite. |
| D3 | Reversible: write `.halcyon_rename_log.jsonl` in the folder AND expose a one-shot Undo. Plus a pre-flight preview of 5 randomly picked files. |
| D4 | EXIF source = native macOS `CGImageSource` with a pure-Dart fallback on other platforms. Per `PhotoItem`, read metadata **once** from `bestFileToLoad` (JPG preferred) and apply it to every file in the group. |
| D5 | Variable set covers date/time components, camera info, shooting parameters, and file-related tokens. |
| D6 | Missing EXIF: capture date falls back to file mtime; all other missing variables render as an empty string. Files are never skipped for missing metadata. |
| D7 | A custom rule is persisted per folder under the `_rename_rule` key of `.halcyon_status.json`, and pre-filled when the dialog reopens. Picking a built-in preset clears the key. |

## UI

### Entry point
`lib/views/sidebar_view.dart` — insert a `PopupMenuItem(value: kRenameMenuValue)`
labelled `Rename by EXIF...` plus a `PopupMenuDivider` immediately above the
existing `delete` item. Enabled when the folder has items and is writable
(`PhotoStatusStore`'s existing writability probe); disabled otherwise.

Gotcha to respect: the menu `value` string and the `onSelected` switch case must
match exactly, or the button silently does nothing (see `memory.md` — a test
that hardcodes the string will not catch this; the test must reference the same
constant the widget uses).

### Rename dialog

Layout: **two-pane, ~880px wide** (chosen mockup:
`docs/mockups/exif-rename/variant-2-twopane.html`). Left pane holds the preset
list and the rule editor; right pane holds the live preview, so the result
updates while the rule is being edited.

- **Preset list** (radio rows in the left pane, always visible — not a
  dropdown), five entries:
  1. `{YYYY}-{MM}-{DD}-{hh}-{mm}-{ss}` (default)
  2. `{YYYY}{MM}{DD}_{hh}{mm}{ss}`
  3. `IMG_{YYYY}{MM}{DD}_{hh}{mm}{ss}`
  4. `{YYYY}-{MM}-{DD}_{seq}`
  5. `Custom...` — reveals the rule editor
- **Rule editor** (left pane, below the presets): a `TextField` holding the
  template, plus tappable variable chips grouped by category that insert at the
  caret. Invalid template (unknown variable, empty result) disables the Run
  button and shows the reason inline.
- **Preview** (right pane): 5 randomly chosen items rendered as
  `old name → new name`, recomputed on every template change. Re-rolls with a
  small shuffle button.
- **Run** starts the batch and closes the dialog; **Cancel** dismisses.
- **Rule memory**: when the dialog opens, a previously saved custom rule for
  this folder is pre-filled and the preset selection starts on `Custom...`. If
  no custom rule is saved, the default preset is selected. The rule is written
  back on Run, not on every keystroke.

### Variables

| Group | Tokens |
|---|---|
| Date/time | `{YYYY}` `{MM}` `{DD}` `{hh}` `{mm}` `{ss}` |
| Camera | `{camera}` (model) `{lens}` (lens model) `{make}` (manufacturer) `{artist}` (EXIF Artist / photographer) |
| Shooting | `{f}` (aperture) `{focal}` (focal length, mm) `{iso}` `{shutter}` `{direction}` (GPS image direction, whole degrees) |
| File | `{seq}` (sequence, `{seq:N}` for zero-padded width N, default 1) `{orig}` (original basename without extension) |

Values are sanitised for filesystem safety: `/`, `:`, and NUL are replaced with
`_`; leading/trailing whitespace and dots are trimmed. The extension is always
preserved from the source file and is not part of the template.

### Status line
`lib/views/status_line.dart` shows, in order:
- `Reading EXIF 4,120 / 10,238…`
- `Renaming 3,214 / 10,238…`
- `Renamed 10,238 · 12 failed` with an `Undo` action; failures open the same
  style of failure list already used by `RecycleOutcome`.

## Architecture

```
sidebar_view (menu) ─▶ RenameDialog ─▶ AppState.renameByExif(rule)
                                          │
                          ┌───────────────┴───────────────┐
                          ▼                               ▼
             ExifMetadataService.readBatch()      RenameService
             (MethodChannel halcyon/exif          planRenames()  ← pure
              or Dart isolate fallback)           applyRenames() ← serial, cancellable
                                                  undoLast()
```

### `lib/services/exif_metadata_service.dart`
```dart
class ExifMetadata {
  final DateTime? captureDate;
  final String? camera, lens, make, artist;
  final double? aperture, focalLength;
  final int? iso;
  final String? shutter;
  final double? gpsImgDirection; // kCGImagePropertyGPSImgDirection
}

typedef ExifBatchReader =
    Future<List<ExifMetadata?>> Function(List<String> paths);
```
- macOS: one `MethodChannel('halcyon/exif')` call per chunk of 500 paths; the
  Swift side uses `DispatchQueue.concurrentPerform` over
  `CGImageSourceCopyPropertiesAtIndex` (header only, no pixel decode).
- Other platforms: the same interface backed by the `exif` pub package parsing
  the file header inside `Isolate.run`. Writing a TIFF parser by hand is not
  worth it for a fallback path — the package covers the standard IFD0/ExifIFD/GPS
  tags this feature needs.
- Injected into `AppState` as a typedef, mirroring the existing `DngFullDecoder`
  seam, so tests substitute a fake reader.

### `lib/services/rename_service.dart`
```dart
class RenamePlan {
  final PhotoItem item;
  final String newBase;          // without extension
  final List<({File from, String to})> moves; // every file + its ._ sidecar
}
```
- `planRenames(items, metadata, rule, existingNames)` → `List<RenamePlan>`,
  pure and fully unit-testable. Responsibilities:
  - render the template per item, applying D6 fallbacks;
  - assign `{seq}` per collision group, ordered by original filename, so the
    numbering is deterministic;
  - avoid names already present in the folder;
  - append `-1`/`-2` when a collision survives everything else;
  - group siblings: every file in a `PhotoItem` (RAW + JPG + `._` AppleDouble
    sidecar) gets the same new base name.
- `applyRenames(plans, onProgress, cancelToken)` — serial `File.rename`. Rename
  is a same-volume metadata operation (microseconds); running it in parallel
  buys nothing and turns collision avoidance into a race. Each completed plan is
  appended to `.halcyon_rename_log.jsonl` before moving on, so a cancel or crash
  still leaves an undoable record. The log is JSON Lines, not one JSON array:
  10,000 rewrites of a growing array would be O(n²), an append-only sink is O(n).
- `undoLast(dir)` — replays the log in reverse.

### `AppState`
- `renameByExif(RenameRule rule)`, `undoRename()`, and a `renameProgress`
  observable driving the status line.
- **After a successful rename, `AppState` MUST remap the persisted status
  entries.** `.halcyon_status.json` is keyed by `PhotoItem.id` (the basename);
  without a remap every star/trash mark and the last-viewed pointer is lost.
  Same remap applies on undo.
- **Rule persistence (D7)**: `PhotoStatusStore` gains
  `loadRenameRule(dir)` / `saveRenameRule(dir, String? rule)` writing the
  `_rename_rule` key of the same JSON file (`null` deletes the key).
  **Gotcha**: `saveStatuses()` rebuilds the map from scratch and today only
  carries `_last_viewed_id` forward — it must carry `_rename_rule` forward too,
  or the first star after a rename silently drops the saved rule. Same for
  `applySavedStatuses()`'s stale-key cleanup, which must not treat
  `_rename_rule` as an orphaned photo id.
- Item `id` and `files` are updated in place and `notifyListeners()` is called
  once at the end of the batch, not per file.

## Performance

For 10,000 photos the only real cost is metadata reading:
- EXIF: one read per `PhotoItem` (not per file), header only, parallel on the
  native side, chunked at 500 for progress reporting. Expected: a few seconds.
- Rename: ~10,000 serial same-volume renames, expected 1–2 seconds.
- The UI stays responsive throughout; the operation is cancellable, and a cancel
  stops at the last completed plan with the log intact.

## Error handling

- Per-file failures (permission denied, file vanished, target exists) are
  collected into a failure list and surfaced, mirroring `RecycleOutcome`. A
  silently failed rename is indistinguishable from a broken app.
- A non-writable folder disables the menu entry up front.
- Template errors are caught in the dialog before the batch starts.

## Testing

Unit tests with a fake `ExifBatchReader`, mostly against the pure planner:

| TC | Case |
|---|---|
| 1 | Default preset renders `YYYY-MM-DD-hh-mm-ss` from a known capture date |
| 2 | Two items in the same second with `{seq}` get 1 and 2, ordered by original name |
| 3 | `{seq:3}` zero-pads to `001` |
| 4 | Collision without `{seq}` falls back to `-1`/`-2` and never overwrites |
| 5 | A planned name that already exists in the folder is avoided |
| 6 | Missing capture date falls back to file mtime |
| 7 | Missing `{lens}` renders as an empty string, file is still renamed |
| 8 | RAW + JPG + `._` sidecar of one item all receive the same base name |
| 9 | Undo log round-trip restores every original name |
| 10 | Status store keys are remapped after rename (stars survive) |
| 11 | Cancel mid-batch leaves a valid, replayable log |
| 12 | A custom rule survives a round-trip through `.halcyon_status.json` |
| 13 | `saveStatuses()` after a star change preserves both `_last_viewed_id` and `_rename_rule` |
| 14 | `applySavedStatuses()` does not treat `_rename_rule` as a stale photo key |

Each gets a TC-NNN entry in `unit_test.md`.

## UI decision record

Four mockups were produced in `docs/mockups/exif-rename/` (compact dropdown,
two-pane, token-pill builder, right-docked inspector). **variant-2-twopane is
the chosen layout**; the other three are kept for reference only and are not
implemented.
