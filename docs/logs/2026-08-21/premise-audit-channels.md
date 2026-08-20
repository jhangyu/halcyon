# Premise Audit: MethodChannels and Dart-side Platform Assumptions

Audit of `docs/logs/2026-08-20/cross-platform-port-inventory.md` claims in the
"MethodChannels / Dart-side platform assumptions" area. Read-only; no source
files modified.

## 結論先行（FALSE / UNVERIFIABLE only）

None of the claims in this assigned area were found to be FALSE or
UNVERIFIABLE. All checked claims (channel line numbers, degradation
behavior, EXIF fallback, Dart-side path/keyboard/hover assumptions) verified
TRUE against current source. One item needs a caveat, not a correction:

- **`halcyon/thumbnail` degradation claim (doc line 7, P0 item 3, table-two
  row "縮圖降級")**: the document says thumbnail's `MissingPluginException`
  is uncaught and crashes the preload pipeline. This was true when the
  document was written, but `lib/services/native_thumbnail_service.dart` was
  edited by a teammate minutes before this audit to add exactly the
  `on MissingPluginException` clause (lines 122-135) the document says is
  missing. Per task instructions this is **not** reported as a document
  error — it is a legitimate post-audit code change, not an instrument
  error. The document was accurate as of 2026-08-20; it is now stale on
  this one point. Flagging here only so downstream planning doesn't
  duplicate work already done.
- **"未驗證項" hover/touch sampling claim**: document says only three files
  were sampled. A full sweep (below, item D) found desktop-only interaction
  markers in **four** files, not three. This doesn't falsify the document's
  claim (it explicitly self-labels as an incomplete sample, not a count),
  but the real number for future planning is 4 files / 9 total view files.

## A. Four MethodChannels — line numbers and degradation

| Channel | Doc-claimed location | Verified location | MissingPluginException handling |
|---|---|---|---|
| `halcyon/open_with` | `open_with_channel.dart:22` | **TRUE** — `lib/services/open_with_channel.dart:22` | N/A — push-only (`setMethodCallHandler`, no `invokeMethod`), so there is nothing to catch. Doc doesn't claim otherwise. |
| `halcyon/thumbnail` | `native_thumbnail_service.dart:87` | **TRUE** — `lib/services/native_thumbnail_service.dart:87` | Doc says "no degradation, crashes". As of doc's writing this was true (see caveat above). Current file (post teammate edit) DOES catch it: `native_thumbnail_service.dart:122-135`, returns `NativeImageFailure('MISSING_PLUGIN', ...)`. Not reported as a document error per task instructions. |
| `halcyon/trash` | `trash_service.dart:7` | **TRUE** — `lib/services/trash_service.dart:7` | Catches `MissingPluginException` at `trash_service.dart:15-18`, throws `TrashException('Trash service is unavailable')` — degrades cleanly (no crash, caller decides what to do). Confirms doc's "trash degrades correctly" claim. |
| `halcyon/exif` | `exif_metadata_service.dart:23` | **TRUE** — `lib/services/exif_metadata_service.dart:23` | Catches `MissingPluginException` at `exif_metadata_service.dart:50-51`, falls back to `readWithPackage` (pure-Dart `package:exif` parse in an isolate). Confirms doc's "exif degrades correctly" claim. |

Fifth channel check: `grep -rn "MethodChannel(" lib/` and
`grep -rn "EventChannel(" lib/` return exactly the four channels above and
zero EventChannels. **No missed channel.**

## B. `halcyon/exif` pure-Dart fallback claim

Doc claim (table one, EXIF row): "**不必做**——已有純 Dart fallback
（`exif_metadata_service.dart:50-51`）".

**Verdict: TRUE.** `exif_metadata_service.dart:50-51` is exactly:
```
    } on MissingPluginException {
      return Future.wait(chunk.map(readWithPackage));
```
`readWithPackage` (line 78-85) runs `_parseWithPackage` (line 87-103) in an
`Isolate.run`, using `package:exif`'s `readExifFromFile` — no channel
dependency at all, works standalone on any platform. Field-for-field it
extracts the same set as the native path (`metadataFromMap`, lines 60-74):
captureDate, camera, lens, make, artist, shutter, aperture, focalLength,
gpsImgDirection, iso. This is not a subset — it is a full parallel
implementation of the same `ExifMetadata` shape, not partial coverage.

## C. Dart-side platform assumptions

| Doc claim | Verdict | Evidence |
|---|---|---|
| `app_state.dart:214-216` — `dart:io Directory` scan on real path via `getDirectoryPath()` | **TRUE** (file is `lib/providers/app_state.dart`, doc's bare filename is accurate since there's only one `app_state.dart` in `lib/`) | Lines 213-217: `Future<void> openFolder() async { final String? directoryPath = await getDirectoryPath(); if (directoryPath != null) { await loadFolder(Directory(directoryPath)); } }`. `getDirectoryPath()` is from `package:file_selector` (import at line 5) — a desktop-oriented native folder picker returning a real filesystem path, not a content URI. |
| `app_state.dart:216` — same, `Directory(directoryPath)` call | **TRUE** — exact line: `await loadFolder(Directory(directoryPath));` |
| `photo_file_actions.dart:95` | **TRUE**, line number exact — `lib/services/photo_file_actions.dart:95`: `final trashDir = Directory(p.join(dir.path, '.trash'));` inside `recycleTrashed`, building a real-path `Directory` for the in-folder recycle mode. |
| `photo_status_store.dart:23` | **TRUE**, line number exact — `lib/services/photo_status_store.dart:23`: `File statusFileFor(Directory dir) { return File(p.join(dir.path, '.halcyon_status.json')); }`. Confirms the doc's premise that `.halcyon_status.json` is written into the real photo folder via a real `Directory`/`File` path, which breaks under Android SAF `content://` URIs / iOS sandboxing. |
| `main_screen.dart:84-112` — keyboard-only interaction | **TRUE**, line numbers close (actual handler body spans ~83-111 inside `_buildKeyboardShortcutHandler`, doc's 84-112 range fully inside it) — `lib/views/main_screen.dart`: a `Focus` widget with `onKeyEvent` handling arrowLeft/arrowRight (prev/next photo), `S`/`X` (star/trash), arrowUp/arrowDown (zoom). No touch/gesture handling anywhere in this widget. |
| `main_detail_view.dart:309` — hover-driven UI | **TRUE**, line number exact — `lib/views/main_detail_view.dart:308-309`: `return MouseRegion( onHover: (event) { widget.zoom.pointerPosition = event.localPosition; }, ...)`. Confirms zoom/pan UI is keyed off `MouseRegion.onHover`, which has no touch equivalent. |

No file-picker usage found beyond `file_selector`'s `getDirectoryPath` in
`app_state.dart`; no other `dart:io Directory(` absolute-path scans found
outside the two files the document names (`app_state.dart`,
`photo_file_actions.dart`) plus `photo_status_store.dart`'s `File`/`Directory`
join.

## D. Full hover/touch parity sweep of `lib/views/`

Doc's "未驗證項" says only three files were sampled for hover/touch parity.
A real sweep (`grep -rn` for `MouseRegion`, `onHover`, `Tooltip`,
`RawKeyboard`, `KeyboardListener`, `Shortcuts`, `onSecondaryTap` across
`lib/views/`) gives:

- `lib/views/main_detail_view.dart` — `MouseRegion` (x1), `onHover` (x1) — zoom/pan pointer tracking (line 308-309).
- `lib/views/main_screen.dart` — `MouseRegion` (x1) — used elsewhere in the screen (outside the keyboard handler covered in C).
- `lib/views/zoom_controller.dart` — `MouseRegion` (x1), `onHover` (x1) — scroll-wheel/pointer zoom logic.
- `lib/views/photo_action_bar.dart` — `onSecondaryTap` (x1) — right-click action, no touch equivalent.

No hits for `Tooltip`, `RawKeyboard`, `KeyboardListener`, or `Shortcuts`
anywhere in `lib/views/`.

`lib/views/` contains 9 Dart files total (`batch_delete_feedback.dart`,
`main_detail_view.dart`, `main_screen.dart`, `photo_action_bar.dart`,
`rename_dialog.dart`, `settings_dialog.dart`, `sidebar_view.dart`,
`status_line.dart`, `zoom_controller.dart`). **4 of 9** contain desktop-only
interaction points (mouse hover/right-click), not the "three files" the doc
says were sampled — though the doc explicitly self-labels this as an
incomplete sample, not a completed count, so this is a supplement, not a
falsification.

## Summary count

- Claims checked: **13** (4 channel line/location pairs, 4 channel
  degradation behaviors, 1 fifth-channel check, 1 exif-fallback claim, 6
  Dart-side assumption line/claim pairs in section C, 1 hover/touch sampling
  claim in section D — several bundled above into combined rows).
- TRUE: **13**
- FALSE: **0**
- UNVERIFIABLE: **0**

All claims in this assigned area (MethodChannels + Dart-side platform
assumptions) hold up against current source, modulo the one caveat above
(thumbnail's `MissingPluginException` handling was fixed by a teammate
after the document was written — a stale-but-not-wrong situation, not a
document defect).

## Not verifiable / out of scope for this audit

- Native-side (Swift `AppDelegate.swift`) behavior for each channel was not
  re-verified here — that is outside the "MethodChannels and Dart-side"
  scope and belongs to a native-platform-focused pass.
- Whether `readWithPackage`'s `package:exif`-based parse actually succeeds
  on real-world DNG/RAW files with the same accuracy as the native
  `CGImageSourceCopyPropertiesAtIndex` path was not empirically tested
  (would require running the app / a build, which is off-limits under the
  build-lock red line). Only static code-shape parity was confirmed.
