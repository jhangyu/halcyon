# Flutter-side portability audit (Windows / Android / iOS)

Date: 2026-08-21. Read-only investigation, builds on
`docs/logs/2026-08-20/cross-platform-port-inventory.md` (read first — that doc's
conclusions and P0/P1/P2 grading are not repeated here except where this audit
changes or sharpens them). Claim markers: [C] = confirmed by reading the file
cited, [U] = unverified / inferred.

---

## 1. Storage model audit — `dart:io` path/Directory/File dependencies

Every one of these assumes a real filesystem path is available and writable in
place. None of it works against an Android SAF `content://` tree URI or an iOS
sandbox without either (a) a URI-based access layer or (b) copying files into
an app-private directory first — there is no partial fix within these files.

| # | File:line | Dependency | Feasible fallback without rewriting the layer? |
|---|---|---|---|
| 1 | `app_state.dart:214` `openFolder()` → `getDirectoryPath()` (file_selector) then `Directory(directoryPath)` | Assumes `file_selector` returns a real OS path | [C] No — on Android, `file_selector`'s underlying picker returns a `content://` URI, not a filesystem path; wrapping it in `Directory(...)` will not throw at construction but every subsequent `.list()`/`.exists()` call will fail silently or throw. This is a hard blocker, not a fallback-shaped problem. |
| 2 | `app_state.dart:223-229` `openPhotoAtPath()` → `File(path)`, `file.parent` | Same as above, for OS "Open With" hand-off | [C] Same blocker; also depends on #6 below (`OpenWithChannel`) actually delivering a real path, which the channel's own doc comment (`open_with_channel.dart:17-20`) says Android does NOT do without extra native resolution work. |
| 3 | `photo_status_store.dart:22-24` `statusFileFor()` → `File(p.join(dir.path, '.halcyon_status.json'))` | Writes a sidecar file directly into the browsed folder | [C] No path-string fallback exists once `dir.path` is a URI, not a filesystem path. **However** the write itself is already isolated behind a single `File` factory method reused by every other method in the class (`applySavedStatuses`, `saveStatuses`, `saveLastViewedId`, `loadRenameRule`, `saveRenameRule`, `remapKeys` all call `statusFileFor(dir)` — `photo_status_store.dart:45,82,104,119,131,144`), so swapping the persistence target to an app-private directory (keyed by folder identity instead of `dir.path`) is a **single-point change if and only if `dir` is redefined to carry an app-private-safe path/id instead of the OS folder path.** That redefinition itself is not a Dart-only change — see decision point 1 below. |
| 4 | `photo_status_store.dart:30-38` `isWritable()` → `File(...).create()` / `.delete()` probe | Real filesystem write probe used to warn about read-only cards | [C] Same as #3 — works once `dir` resolves to a real writable path (app-private dir counts), breaks unconditionally for a SAF tree URI. |
| 5 | `photo_file_actions.dart:39,64,60,97` `destination.exists()`, `file.copy()`, `file.rename()`, `trashDir.create()` | Copy/move/recycle all use real `File`/`Directory` operations | [C] No fallback without a URI-based `DocumentFile`-style layer on Android; `file.rename()` in particular requires source and dest on the same real filesystem, which a SAF tree URI cannot give you directly (Android's `DocumentsContract` has its own move/copy primitives, entirely different API shape). This is the single most invasive rewrite implied by scoped storage — see decision point 1. |
| 6 | `rename_rule` / `AppState.renameByExif` — `app_state.dart:547` `dir.listSync()`, `app_state.dart:553` `file.statSync().modified`, `rename_service.dart` `File(...).rename()` via `applyRenames` (not read in full, but same shape as `photo_file_actions.dart`) | Directory listing + rename, synchronous | [C] Same blocker family as #5; also `listSync`/`statSync` are sync dart:io calls that do not exist for content resolvers at all — this is not a slow-path issue, it is a missing-API issue on Android. |
| 7 | `app_state.dart:627` `undoRename()` → `File(p.join(dir.path, kRenameLogName)).existsSync()` | Rename undo journal, same sidecar-file pattern as `.halcyon_status.json` | [C] Same as #3/#4 — single point, contingent on `dir` no longer being a raw OS path. |

**Overall verdict [C]:** there is no incremental "add a fallback branch" fix for
the storage layer. Every method above is written against `dart:io`
`File`/`Directory` with real paths, and the write/read call sites are already
consolidated (one `statusFileFor` helper, one `_availablePath` helper, one
`_moveFile`/`_trashFile` typedef pair in `photo_file_actions.dart:8-9,22-24`)
— which means the *injection seams already exist* (mirroring the
`ThumbnailLoader`/`DngFullDecoder` pattern noted in the 2026-08-20 doc), but
someone still has to write and inject the SAF/URI-based implementation behind
them. This is a genuinely new subsystem, not a switch flip. Matches
2026-08-20 doc's decision point 1 — this audit does not change that
conclusion, only pins down exactly which call sites (7, all listed above)
would need the new implementation wired in.

---

## 2. Input-modality audit — full sweep of `lib/views/`

**Files examined (all 9 `.dart` files in `lib/views/`; `AGENTS.md` is not
code):** `batch_delete_feedback.dart`, `main_detail_view.dart`,
`main_screen.dart`, `photo_action_bar.dart`, `rename_dialog.dart`,
`settings_dialog.dart`, `sidebar_view.dart`, `status_line.dart`,
`zoom_controller.dart` (view-state controller, no widgets, included because
`main_detail_view.dart` writes into it from `MouseRegion` callbacks).

Method: grepped each file for
`onKey|RawKeyboard|KeyEvent|Shortcuts|LogicalKeyboardKey|HardwareKeyboard|FocusNode|MouseRegion|onHover|onEnter|onExit|onSecondaryTap|onPanUpdate|GestureDetector|onTap|Draggable|Scrollbar|Listener\(`,
then read every hit in context.

| File:line | Interaction | Touch gap? |
|---|---|---|
| `main_screen.dart:84-113` `Focus.onKeyEvent` — arrowLeft/arrowRight = prev/next photo, `S` = star, `X` = trash, arrowUp/arrowDown = zoom step | Keyboard-only | [C] **Yes, total gap.** This is the entire core triage interaction (navigate, star, trash, zoom) and has zero touch/gesture equivalent anywhere in the codebase. `photo_action_bar.dart` provides tap equivalents for star/trash only (see below); prev/next photo and zoom step have no on-screen control at all. On a touch-only device the app is unusable past folder load. |
| `main_screen.dart:52-63` `MouseRegion`+`GestureDetector(onPanUpdate:...)` — sidebar resize drag handle | Drag-to-resize, 5px hit target | [C] Partial gap. `onPanUpdate` itself fires for touch drags too (Flutter's `GestureDetector` doesn't distinguish mouse vs touch for pan), so this is technically touch-capable, but a 5px-wide hit target (`main_screen.dart:65`, `width: 5`) is far below any touch target guideline (44pt/48dp) — usable with a mouse pointer's pixel precision, not reliably with a finger. |
| `main_detail_view.dart:309-315` `MouseRegion.onHover`/`onExit` — feeds `zoom.pointerPosition` so `stepZoomIn/Out` zoom toward the cursor | Hover-only, but degrades gracefully | [C] Gap exists but is soft: `zoom_controller.dart:78` falls back to `lastKnownCenter` when `pointerPosition` is null, so a touch device without hover would just always zoom around the viewer's center instead of a live cursor position — not a functional break, a UX degradation. |
| `main_detail_view.dart:316-320` `InteractiveViewer(transformationController:..., minScale:1.0, maxScale:5.0, trackpadScrollCausesScale:true)` | Pinch-zoom / pan | [C] **No gap** — `InteractiveViewer` supports touch pinch-to-zoom and drag-to-pan natively; this is the one part of the detail view that already works on touch without change. `trackpadScrollCausesScale` is additionally trackpad-specific but additive, not a regression for touch. |
| `photo_action_bar.dart:49-56` star `IconButton.onPressed` | Tap | [C] No gap — `onPressed` fires for tap on any pointer type. |
| `photo_action_bar.dart:59-69` `GestureDetector(onSecondaryTap:...)` wrapping the trash `IconButton` — right-click toggles recycle mode, left-click/`onPressed` marks trashed | Right-click-only for the mode toggle | [C] **Yes, gap.** `onSecondaryTap` has no touch equivalent in Flutter (no secondary pointer button on touchscreens); recycle-mode toggle is unreachable without a mouse. The primary trash action (`onPressed`) is fine on touch. |
| `sidebar_view.dart:180-186` `Scrollbar(controller:..., child: ListView(controller:...))` | Scroll list | [C] No gap — `ListView`/`Scrollbar` both support touch drag-scroll natively. |
| `sidebar_view.dart:231` thumbnail `onTap` (select item) | Tap | [C] No gap. |
| `rename_dialog.dart:349,472,510` `onTap` (label select, token insert, reroll button) | Tap | [C] No gap. |
| `batch_delete_feedback.dart`, `settings_dialog.dart`, `status_line.dart` | No interaction beyond standard `TextButton`/`ElevatedButton`/dialog widgets (grep found zero keyboard/hover/gesture hits) | [C] No gap — all standard Material tap targets. |

**Summary count:** 3 files with keyboard/mouse-only interactions
(`main_screen.dart`, `main_detail_view.dart`, `photo_action_bar.dart`); 6
files with no touch gap. The single largest gap is `main_screen.dart`'s
keyboard shortcut handler — it is the *only* way to navigate photos or zoom,
and has no on-screen/gesture equivalent at all. This matches and sharpens the
2026-08-20 doc's P1 item 9 ("行動端觸控分揀 UI"): the previous doc sampled 3
files and called it P1 (degraded-but-runs); this full sweep shows navigation
itself (not just zoom/secondary actions) is keyboard-only, which for a
touch-primary device is closer to P0 (does not run at all as a triage tool,
only as a photo *viewer* via pinch-zoom and sidebar tap-to-select).

---

## 3. Platform-conditional wiring

**There is no platform-conditional wiring anywhere in the Flutter code.** [C]

- `main.dart:24-26` constructs exactly one `AppState(dngDecoder: halcyonDngFullDecoder)` — no `Platform.isX` branch, no per-platform service selection. `halcyonDngFullDecoder` (`dng_decode_service.dart:34`) is a single top-level constant wired unconditionally on every platform.
- `app_state.dart:75-93` constructor default-wiring: `_scanner ?? PhotoLibraryScanner()`, `_statusStore ?? PhotoStatusStore()`, `_fileActions ?? PhotoFileActions()`, `_exportService ?? ThumbnailExportService()`, and the `ImagePreloadController`'s `imageLoader` defaulting to `NativeThumbnailService.requestImage` — every one of these is a single hardcoded default, not a per-platform selector. Confirms the 2026-08-20 doc's point 4 (the *injection seams* exist — constructor params) but there is currently zero code that would pick a different implementation based on `Platform.isAndroid`/`isWindows`/etc. Building that selection logic is still-unstarted work, not "mostly done."
- What a real per-platform selector would have to switch, concretely: `ThumbnailLoader` (native channel vs Dart `image`-package decode), `DngFullDecoder` (dng_processor FFI — same across platforms IF plugin-ized, per 2026-08-20 doc point 2/3), `TrashService` (system trash vs in-folder recycle — `photo_file_actions.dart:22-24` already takes `TrashFile`/`MoveFile` as injectable typedefs, so this one *is* a clean injection point today), `ExifBatchReader` (already platform-transparent, see §4).

**MissingPluginException fallback coverage, confirmed by reading the actual (including dirty, uncommitted) files:**

| Channel/service | Catches `MissingPluginException`? | Evidence |
|---|---|---|
| `halcyon/trash` (`trash_service.dart:15-18`) | [C] Yes — throws typed `TrashException`, caught by `AppState.deleteTrashed`'s `catch (e) { failures.add('$e'); }` (`app_state.dart:469-473`); surfaces to the user instead of crashing. |
| `halcyon/exif` (`exif_metadata_service.dart:50-51`) | [C] Yes — falls back to the pure-Dart `exif` package via `readWithPackage`, not just a null-swallow; this is a real functional fallback, not just crash-avoidance. |
| `halcyon/thumbnail` (`native_thumbnail_service.dart:122-135`) | [C] **Now yes** — this contradicts the 2026-08-20 doc's P0 item 3 ("`halcyon/thumbnail` 沒有 [捕捉]"), which is now stale. The current (dirty, uncommitted) file has an explicit `on MissingPluginException catch (e)` clause (`native_thumbnail_service.dart:122-135`) that returns `NativeImageFailure('MISSING_PLUGIN', ...)` instead of rethrowing, with a comment explicitly citing this doc's finding as the reason it was added. **Flag for team-lead:** the P0 gap this doc's own §3 item 3 describes appears to already be fixed in the currently-dirty tree; the fix should be re-verified against whatever the other concurrent session lands, since this file is mid-edit. |
| `halcyon/open_with` (`open_with_channel.dart:26-33`) | [U] N/A by design — push-only listener (`setMethodCallHandler`), nothing to catch; a platform that never sends `openFile` is simply a no-op, not an exception. |

---

## 4. Pure-Dart replacement candidates

| Candidate | Current native path | Dart fallback exists today? |
|---|---|---|
| EXIF reading | `halcyon/exif` channel, `CGImageSourceCopyPropertiesAtIndex` (macOS) | [C] **Yes, already shipped and wired as the automatic fallback** — `exif_metadata_service.dart:50-51,78-103` uses the `exif` pub package inside `Isolate.run` for every field the native path returns (`captureDate`, `camera`, `lens`, `make`, `artist`, `shutter`, `aperture`, `focalLength`, `gpsImgDirection`, `iso`). Coverage looks complete field-for-field by comparing `metadataFromMap` (`exif_metadata_service.dart:60-74`) against `_parseWithPackage` (`exif_metadata_service.dart:87-103`) — same `ExifMetadata` fields populated both ways. [U] Not verified: whether the `exif` package parses RAW-format headers (CR2/NEF/ORF) as reliably as `CGImageSourceCopyPropertiesAtIndex` does, or only JPEG/TIFF-container EXIF — no test evidence found in this audit for RAW-specific EXIF via the Dart path. |
| DNG embedded-JPEG extraction | Swift `TIFFReader` (native, not read in this audit — out of Flutter-side scope) | [U] 2026-08-20 doc already flags this as portable to pure Dart (pure byte parsing, no platform API). Not re-verified here since it's a Swift file, outside this audit's `lib/` scope. |
| Thumbnail-export JPEG encoding | `AppDelegate.swift:254-300` `CGImageDestination` (native, out of scope here) | [C] **No Dart fallback exists today.** `thumbnail_export_service.dart:36-41` (`_defaultFetch`) always calls `NativeThumbnailService.getThumbnail(path, purpose: ImageRequestPurpose.export)`, which (`native_thumbnail_service.dart:143-155`) always sets `allowRawDecodeSignal: false` and returns `null` bytes on `MissingPluginException` (`native_thumbnail_service.dart:122-135` → `getThumbnail:154` maps any non-`NativeImageBytes` result to `null`). `exportStarred`'s worker (`thumbnail_export_service.dart:92-95`) treats a null fetch as `StateError('Export produced no image data')`, recorded as a per-item failure. Net effect: on any platform without the native channel, "Thumbnail Starred" export fails for every item, silently-per-item (batch completes, all entries in `failures`) rather than crashing — but there is zero pure-Dart JPEG encoding path today. The `image` package is not imported anywhere in the files read in this audit; adding this fallback is new work, matching the 2026-08-20 doc's suggestion (P1 item 8), not something already half-built. |

---

## Corrections to the 2026-08-20 inventory doc

1. **P0 item 3 (`halcyon/thumbnail` MissingPluginException not caught) appears already fixed** in the current (dirty) tree — see §3 table above. Needs re-confirmation once the concurrent session's edits to `native_thumbnail_service.dart` settle, since this audit is read-only against an actively-changing file.
2. Item 2's "full hover/touch sweep, only 3 files sampled" gap (2026-08-20 doc's own "未驗證項") is now closed: all 9 `lib/views/` files examined, results in §2 above. The severity read should tighten from P1 ("功能降級") to closer-to-P0 for photo navigation specifically — star/trash/prev/next/zoom are the app's entire core loop and 4 of those 5 actions (all but star, which also has a tap button) have no touch path at all.

---

## Uncertain / not verified in this audit

- [U] Whether `photo_status_store.dart`'s consolidation around `statusFileFor()` (§1) is sufic­ient to make the SAF/sandbox fallback a "small" change — the *write* call sites are consolidated, but the *identity* of `dir` (currently a real `Directory` used both as a storage key and as a scan root) is not, and redefining it touches `app_state.dart`'s `loadFolder`/`_currentDir` plumbing broadly (not exhaustively traced in this pass — would need a dedicated call-graph pass on `_currentDir` usage, which appears in `app_state.dart` at least at lines 117, 149, 237, 345, 356, 419, 452, 492, 530, 626, plus every consumer of `AppState.currentDir`).
- [U] Whether the Dart `exif` package's RAW-file coverage matches native — see §4.
