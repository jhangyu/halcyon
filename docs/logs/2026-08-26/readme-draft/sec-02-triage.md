## The triage workflow

This is the core loop: open a folder, browse it, mark photos, move on. Everything below
describes what the app actually does when a photographer sits down with a card full of
RAW and JPG files.

### Opening a folder

`PhotoLibraryScanner.scan()` lists the directory's immediate entries with
`dir.list(followLinks: false)` and does not descend into subdirectories — only files
directly inside the chosen folder are picked up.
<!-- evidence: lib/services/library/photo_library_scanner.dart:8 -->

Each entry is filtered before it is considered a photo: it must be a regular file, its
name must not start with `.` (dotfiles/AppleDouble sidecars are skipped), and its
extension must be in the supported set.
<!-- evidence: lib/services/library/photo_library_scanner.dart:11-16 -->

The supported extensions are `.jpg`, `.jpeg`, `.arw`, `.rw2`, `.dng`, `.png`, `.cr2`,
`.nef`, `.orf`.
<!-- evidence: lib/models/supported_photo_formats.dart:6-16 -->

Matched files are grouped (see below) into `PhotoItem`s and the resulting list is sorted
by id, case-insensitively.
<!-- evidence: lib/services/library/photo_library_scanner.dart:22-26 -->

### RAW and JPG sibling grouping

Grouping key is the filename with its extension stripped —
`SupportedPhotoFormats.photoIdFor()` returns `p.basenameWithoutExtension(file.path)`. All
files sharing that basename, regardless of extension, land in the same `List<File>` under
that key.
<!-- evidence: lib/models/supported_photo_formats.dart:41-43 -->
<!-- evidence: lib/services/library/photo_library_scanner.dart:14-19 -->

That grouped list becomes one `PhotoItem(id: entry.key, files: entry.value)` — a single
sidebar entry, a single `PhotoStatus`, and a single row the user interacts with, no matter
how many files are in the group.
<!-- evidence: lib/services/library/photo_library_scanner.dart:22-24 -->
<!-- evidence: lib/models/photo_item.dart:7-16 -->

Which file the app actually loads for display is decided by `bestFileToLoad()`: it walks
a fixed preference order (`.jpg`, `.jpeg`, `.png`) and returns the first match; if none of
those extensions are present it falls back to the first supported file in the group, and
only falls back to an arbitrary file if the whole group is otherwise unsupported.
<!-- evidence: lib/models/supported_photo_formats.dart:45-61 -->

Downstream, a folder containing any multi-file group (i.e. any RAW+JPG pair) makes the app
default to recycle-mode deletion instead of permanent delete, on the reasoning that a
card being culled shouldn't lose a RAW to a mis-click.
<!-- evidence: lib/providers/app_state.dart:285-287 -->

Marking or deleting operates on the `PhotoItem`, so a single star or trash action applies
to every file in the group together — the RAW and its JPG sibling move as one unit.
<!-- evidence: lib/models/photo_item.dart:10 -->

### Marking

Two mark states exist beyond "unmarked": `starred` and `trashed`
(`PhotoStatus` enum). `markCurrent(status)` toggles: pressing the same mark again clears it
back to `unmarked`; pressing a different mark sets it. Toggling *off* does not
auto-advance; setting a *new* mark does, if auto-advance is enabled.
<!-- evidence: lib/providers/app_state.dart:367-381 -->
<!-- evidence: memory.md G-005 -->

Auto-advance is a persisted user preference (`SharedPreferences` key `autoAdvance`,
default `false`), toggled via `setAutoAdvance()`.
<!-- evidence: lib/providers/app_state.dart:139,151,405-409 -->

The floating action bar mirrors the same two calls — star and trash/recycle icon buttons
both invoke `AppState.markCurrent()`, and the trash icon's glyph and tooltip switch
between "delete" and "restore from trash" depending on recycle mode.
<!-- evidence: lib/views/photo_action_bar.dart:49-69 -->

Marks are saved to disk on every change (`_saveStatusCache()`); the persistence format and
resume behaviour are covered elsewhere in this document.
<!-- evidence: lib/providers/app_state.dart:378 -->

### Navigation and zoom

`←`/`→` move to the previous/next photo by index within the current sorted list, with
bounds checks (no wraparound at either end).
<!-- evidence: lib/providers/app_state.dart:351-365 -->

Zoom is owned entirely outside `AppState`, by a per-screen `ZoomController` created and
disposed by `MainScreen` — deliberately *not* by the detail view, because the detail view
rebuilds on every photo switch and would otherwise reset the zoom level each time the user
pressed left/right.
<!-- evidence: lib/views/zoom_controller.dart:10-15 -->
<!-- evidence: memory.md AD-015 -->

Each zoom step multiplies or divides the current scale by a fixed factor of `1.25`, capped
at a maximum of `5.0×`. Zooming back down to at-or-below `1.05×` snaps all the way to the
identity matrix instead of settling just above `1.0×`, avoiding a drifted pan offset.
<!-- evidence: lib/views/zoom_controller.dart:44,50-58,60-75 -->

### Keyboard shortcuts

All keyboard handling for the triage loop lives in one place — a single `Focus` widget's
`onKeyEvent` callback in `MainScreen`. This is the complete set of bindings the app
registers; no other file in `lib/` attaches a key handler.
<!-- evidence: lib/views/main_screen.dart:97-135 -->

| Key | Action |
|---|---|
| `←` | Previous photo |
| `→` | Next photo |
| `↑` | Zoom in (×1.25 per step, up to 5×) |
| `↓` | Zoom out (×1.25 per step, snaps to fit below ~1.05×) |
| `S` | Toggle star mark on the current photo |
| `X` | Toggle trash mark on the current photo |
| `R` | Toggle recycle mode (folder-local `.trash/` vs. permanent/system delete) |

<!-- evidence: lib/views/main_screen.dart:104-129 -->

Recycle mode can also be toggled by right-clicking the trash icon in the floating action
bar; left-click on that same icon keeps its ordinary "mark this photo" meaning.
<!-- evidence: lib/views/photo_action_bar.dart:60-68 -->

### On-screen feedback during triage

Transient status messages are shown by a custom `StatusLine` widget (bottom of the
window), which replaced Flutter's `SnackBar` for a fixed, explicit timing: fully visible
for 2.5s, then a 0.5s fade, then removed.
<!-- evidence: lib/views/status_line.dart:25-26 -->
<!-- evidence: memory.md AD-009 -->

Two feedback messages fire directly from the triage loop:

- A one-time warning when a folder is opened and found not writable — surfaced once per
  `loadFolder()` call, not once per mark. Writability is checked by actually creating and
  deleting a probe file, not by reading Unix permission bits, because permission bits are
  unreliable on `noowners`-mounted exFAT cards.
  <!-- evidence: lib/providers/app_state.dart:288-289 -->
  <!-- evidence: memory.md AD-009 -->
- An error message if the folder scan itself throws (e.g. a permission error walking the
  directory), surfaced with the underlying exception text.
  <!-- evidence: lib/providers/app_state.dart:324-326 -->
