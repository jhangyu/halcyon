# Windows Native Bridges — Verification Runbook (D5)

Date: 2026-08-21. Owner of the code under test: task D5 (`windows/**`).

## Read this first

The Windows native code described here was written on a **macOS host**. It has
**never been compiled, linked, or run**. There is no Windows toolchain on the
authoring machine and none was installed. Everything below is therefore
*unverified* until you, on a Windows machine, run it.

Nothing in this document says the code works. It says what was implemented,
what the intended observable behaviour is, and — for each step — what a failure
would actually mean, so a red result points at a cause instead of just being a
red result.

Expect the first build to fail. `/W4 /WX` is on for this target
(`windows/CMakeLists.txt:41`), so any conversion warning is a hard error. The
most likely failure mode is a compile error, and the second most likely is a
silent behavioural mismatch in the EXIF-orientation table (§6, item U3).

---

## 1. What was implemented

| Channel | Dart contract | Windows implementation | Notes |
|---|---|---|---|
| `halcyon/thumbnail` | `lib/services/native_thumbnail_service.dart:87` | `windows/runner/halcyon_image.cpp` | WIC decode → scale → EXIF-rotate → JPEG re-encode. RAW always fails. |
| `halcyon/trash` | `lib/services/trash_service.dart:7` | `windows/runner/halcyon_trash.cpp` | `IFileOperation` + `FOF_ALLOWUNDO` \| `FOFX_RECYCLEONDELETE`. |
| `halcyon/open_with` | `lib/services/open_with_channel.dart:22` | `windows/runner/halcyon_channels.cpp` + `flutter_window.cpp` | Push-only, native → Dart. argv on cold start, plus `WM_DROPFILES`. |

### Files

Created:
- `windows/runner/halcyon_native.h` — shared declarations, `halcyon::Channels`.
- `windows/runner/halcyon_channels.cpp` — channel registration, argument decoding.
- `windows/runner/halcyon_image.cpp` — WIC pipeline.
- `windows/runner/halcyon_trash.cpp` — Recycle Bin.

Modified:
- `windows/runner/flutter_window.h` / `.cpp` — owns `halcyon::Channels`, pushes the
  launch file, enables and handles `WM_DROPFILES`.
- `windows/runner/main.cpp` — resolves the launch file from argv before the argv
  vector is moved into the Dart entrypoint arguments.
- `windows/runner/CMakeLists.txt` — new sources, plus `windowscodecs.lib`,
  `shell32.lib`, `ole32.lib`, `oleaut32.lib`.

### Registration call sites (AC1)

- Channels are constructed at `windows/runner/flutter_window.cpp`, in
  `FlutterWindow::OnCreate()`, immediately after `RegisterPlugins(...)`, via
  `std::make_unique<halcyon::Channels>(flutter_controller_->engine()->messenger())`.
- The three `MethodChannel` objects are created in `halcyon::Channels::Channels`
  (`windows/runner/halcyon_channels.cpp`). `halcyon/thumbnail` and
  `halcyon/trash` get `SetMethodCallHandler`; `halcyon/open_with` deliberately
  does not.
- Launch-file push: `FlutterWindow::OnCreate()` → `channels_->PushOpenFile(...)`.
- Drop push: `FlutterWindow::MessageHandler` `case WM_DROPFILES` →
  `HandleDroppedFiles` → `DeliverOpenFile` → `PushOpenFile`.

### RAW degradation path (AC2)

`halcyon::RequestImage` (`windows/runner/halcyon_image.cpp`) checks
`IsRawExtension(lowered)` **before** any decode attempt and returns
`Fail("RAW_UNSUPPORTED", ...)`. The channel handler turns that into
`result->Error("RAW_UNSUPPORTED", ...)`, which crosses the channel as a
`PlatformException`. On the Dart side:

- `native_thumbnail_service.dart:114-121` catches `PlatformException`, sees a
  code that is **not** `kNoEmbeddedPreviewCode`, and returns
  `NativeImageFailure('RAW_UNSUPPORTED', ...)`.
- The legacy `getThumbnail` entry point (`:143-155`) maps that to `null`.

The extension list (`.dng .arw .cr2 .nef .orf .rw2`) mirrors
`macos/Runner/AppDelegate.swift:312-318`.

**The deliberate choice here is the error code.** Returning
`NO_EMBEDDED_PREVIEW` would have produced `NativeImageNeedsRawDecode`
(`native_thumbnail_service.dart:115-119`) and sent Dart looking for a
`DngFullDecoder` that has no Windows build path at all — see
`docs/logs/2026-08-21/premise-audit-platforms.md`. `RAW_UNSUPPORTED` is a plain
failure: no crash, no blank-with-spinner.

---

## 2. Prerequisites

```powershell
flutter doctor -v
```

Expected: "Visual Studio - develop for Windows" with a checkmark, Windows 10
SDK present. A failure here means you cannot build at all and nothing below is
meaningful — fix the toolchain first.

```powershell
cd <repo>
flutter pub get
```

Expected: succeeds. A failure most likely means the sibling
`../flutter_dng_decoder/dng_processor` directory is missing (see `CLAUDE.md`),
which is a checkout problem, not a Windows problem.

---

## 3. Step 1 — Build

```powershell
flutter build windows --debug
```

**Expected:** build succeeds; `build\windows\x64\runner\Debug\photo_selector_flutter.exe` exists.

**If it fails — how to read the failure:**

| Symptom | What it means |
|---|---|
| `Cxxxx: conversion from 'size_t' to 'int'` etc. as an **error** | `/WX` promoting a warning. A missing explicit cast in the new code. Localized, mechanical fix. |
| `cannot open include file 'ocidl.h' / 'oleauto.h' / 'wincodec.h'` | Windows SDK not on the include path — toolchain issue, not code. |
| `unresolved external symbol CLSID_WICImagingFactory` / `GUID_ContainerFormatJpeg` / `GUID_WICPixelFormat24bppBGR` | `windowscodecs.lib` did not get linked. Check the `target_link_libraries` block in `windows/runner/CMakeLists.txt`. |
| `unresolved external symbol SHCreateItemFromParsingName` | `shell32.lib` not linked (same block). |
| `unresolved external symbol CLSID_FileOperation` | `uuid.lib` is normally linked by default with MSVC; if not, add it. |
| `unresolved external symbol VariantInit/VariantClear` | `oleaut32.lib` not linked. |
| `'messenger': is not a member of 'flutter::FlutterEngine'` | The Flutter version's C++ wrapper differs from the one checked (verified against `flutter/engine/src/flutter/shell/platform/windows/client_wrapper/include/flutter/flutter_engine.h:80` in the local SDK). |
| Any error inside `halcyon_channels.cpp` about `std::get_if` | `EncodableValue` variant shape differs from the checked one (`.../common/client_wrapper/include/flutter/encodable_value.h:104-117`). |

Note: on the macOS authoring host, clangd reports `'flutter/binary_messenger.h'
file not found` for every new file, with a long cascade of bogus
`no type named 'string' in namespace 'std'` errors behind it. That is the macOS
IDE failing to find Windows-only headers; it is **not** evidence about the code
and must not be used as either a pass or fail signal.

---

## 4. Step 2 — Functional checks

Run the app against a folder of real photos. Per the repo's hard rule, use only
`local_data/photo_samples/` or a scratch copy — never a real photo library.

```powershell
flutter run -d windows
```

### 4.1 Sidebar thumbnails (JPEG/PNG, non-RAW)

**Do:** open a folder containing JPEGs and PNGs.

**Expect:** every non-RAW photo shows a sidebar thumbnail, right way up,
correct aspect ratio.

- *Blank thumbnails for everything* → the channel is not registered, or the
  method name does not match. Check the debug console for
  `MissingPluginException`; if present, `Channels` was never constructed or the
  channel name string is wrong.
- *Thumbnails appear but rotated or mirrored* → the EXIF orientation table
  (`TransformForOrientation`, `halcyon_image.cpp`) is wrong. This is unverified
  item U3 below. Note which orientation values misbehave.
- *Thumbnails are stretched* → the scaler is computing the wrong destination
  size; check the `scaled_width`/`scaled_height` rounding.
- *Trailing garbage / corrupt bottom of image* → the encoded length is wrong;
  look at the `IStream::Stat` vs `GlobalSize` clamp in `EncodeJpeg`.

### 4.2 Full-size preview of a JPEG

**Do:** select a JPEG.

**Expect:** full-resolution image displayed, correctly oriented.

This path returns the **original file bytes** untouched (mirroring
`AppDelegate.swift:360-370`), so orientation comes from the file's own EXIF and
is handled by Flutter, not by this code. If the sidebar thumbnail of the same
photo is oriented correctly but the preview is not (or vice versa), that
asymmetry localises the bug to exactly one of the two paths.

### 4.3 Preview of a non-JPEG, non-RAW file (PNG, HEIC)

**Expect (PNG):** displays.

**Expect (HEIC):** displays *only if* the "HEIF Image Extensions" package is
installed from the Microsoft Store. Without it, WIC has no HEIC codec and
`CreateDecoderFromFilename` fails → `LOAD_FAILED` → Halcyon shows its
unreadable-file error. That is the intended degradation, not a bug in this
code. **This is unverified item U4.**

### 4.4 RAW/DNG (AC2, the important one)

**Do:** put a `.dng`, `.arw`, `.cr2`, `.nef`, `.orf` or `.rw2` in the folder and
select it.

**Expect:** the app stays alive, and the photo shows Halcyon's explicit
error/unreadable state — **not** a crash, **not** an indefinite spinner, **not** a
silent blank pane.

- *App crashes* → AC2 fails outright.
- *Infinite spinner* → the failure is not reaching the Dart error path; check
  that the error code arriving in Dart is literally `RAW_UNSUPPORTED` and not
  `NO_EMBEDDED_PREVIEW`.
- *Silent blank with no error* → the Dart side treated the result as success.

Mechanical check, independent of what the UI looks like: with
`flutter run -d windows` attached, a RAW selection should print a
`Failed to get native thumbnail: ...` line from
`native_thumbnail_service.dart:120`.

### 4.5 Recycle Bin

**Do:** mark a photo for deletion and let Halcyon delete it (system-trash path,
not in-folder recycle mode).

**Expect:** the file disappears from the folder, appears in the Windows Recycle
Bin, and `Ctrl+Z` in Explorer / right-click → Restore puts it back at the
original path.

- *File is permanently gone (not in the Bin)* → the flags did not take.
  `FOFX_RECYCLEONDELETE` is Windows 8+; `FOF_ALLOWUNDO` is the fallback. **This
  combination is unverified — item U5.** This is the highest-consequence
  failure in the whole document: it destroys user data instead of parking it.
  **Test this on throwaway files first.**
- *A shell confirmation dialog appears* → `FOF_SILENT | FOF_NOCONFIRMATION |
  FOF_NOERRORUI` is not suppressing UI as intended.
- *`TrashException: ...` in the UI* → read the code: `NOT_FOUND` means the path
  never resolved; `TRASH_FAILED` means the shell refused.
- *App hangs on delete* → the STA assumption is wrong (see U2).

### 4.6 Open With / shell association (cold start)

**Do:** from Explorer, right-click a JPEG → Open with → the built
`photo_selector_flutter.exe`. Do this with Halcyon **not already running**.

**Expect:** Halcyon starts and navigates to that photo's folder with that photo
selected.

- *App opens on an empty state* → either argv never carried the path, or the
  buffered message was dropped. Flutter's default channel buffer holds one
  message, and exactly one is sent, so overflow should not be the cause. **This
  end-to-end path is unverified — item U6.**
- *App opens the folder but not the right photo* → that is Dart-side
  navigation behaviour, outside this task's scope.

### 4.7 Drag and drop

**Do:** drag a photo file onto the running Halcyon window.

**Expect:** same behaviour as 4.6.

- *Nothing happens* → `DragAcceptFiles` was not applied to the right HWND, or
  Flutter's `HandleTopLevelWindowProc` consumed `WM_DROPFILES` before the
  runner's switch saw it. The latter would be a genuine surprise and is
  **unverified — item U7**.

---

## 5. Step 3 — Regression guard

```powershell
flutter analyze
```

**Expected:** `No issues found!`

This says nothing about the C++ — it is only a check that the Windows work did
not disturb the Dart tree. Run on the authoring host: **PASS**
(`No issues found! (ran in 1.4s)`).

```powershell
flutter test -j 1
```

**Expected:** unchanged from before this task. No Dart file was modified by D5.

---

## 6. Everything that is unverified, and what would falsify it

This is the honest core of the delivery.

**U0 — The code has never been compiled.** *Falsified by:* the first
`flutter build windows` producing any compile or link error. Given `/W4 /WX`,
this is more likely than not on the first attempt.

**U1 — The code has never been run.** No claim below about runtime behaviour
has been observed. *Falsified by:* any step in §4.

**U2 — Threading.** Both handlers run **synchronously on the platform thread**.
Two consequences, one deliberate and one a real limitation:
  - *Deliberate:* `IFileOperation` is documented as STA-only ("cannot be used
    for a multithreaded apartment"), and `main.cpp:18` initialises the platform
    thread with `COINIT_APARTMENTTHREADED`. Running trash inline is therefore
    correct by construction, not laziness.
  - *Limitation:* the thumbnail decode also blocks the platform thread, so the
    UI stalls for the duration of each decode. macOS dispatches this to a
    background queue (`AppDelegate.swift:308`). A worker thread was not used
    because marshalling a `MethodResult` back to the platform thread needs a
    `PostMessage` hop whose lifetime correctness cannot be checked without a
    compiler, and an unverifiable use-after-free is worse than a stall.
    *Falsified by:* visible hitching when scrolling the sidebar, or any single
    decode exceeding the project's 1-second ceiling. If that happens, the fix
    is a worker thread plus a private `WM_APP` message posted to the runner
    HWND. Measure before building it.

**U3 — EXIF orientation mapping.** `TransformForOrientation` handles all eight
values. Orientations 1/3/6/8 (pure rotations, what cameras actually emit) are
unambiguous. Orientations 2/4/5/7 combine a flip with a rotation, and the order
in which WIC applies the two was **not** confirmed from documentation — the
`IWICBitmapFlipRotator::Initialize` page does not state it. *Falsified by:* a
mirrored or 180°-wrong thumbnail for a photo whose Orientation tag is 2, 4, 5
or 7. Isolated to one switch statement.

**U4 — HEIC support.** Assumed to work only with the Store's HEIF Image
Extensions installed. *Falsified by:* HEIC decoding on a machine without that
package (assumption too pessimistic), or failing to decode with it installed
(assumption too optimistic).

**U5 — Recycle Bin flag combination.** `FOF_ALLOWUNDO | FOF_SILENT |
FOF_NOCONFIRMATION | FOF_NOERRORUI | FOFX_RECYCLEONDELETE | FOFX_EARLYFAILURE`
was assembled from the documented meaning of each flag, never executed.
*Falsified by:* §4.5 — a file permanently deleted instead of recycled, or a
dialog appearing. **Test on throwaway files.**

**U6 — Cold-start Open With.** The claim that Flutter's channel buffer holds
the `openFile` message until Dart registers its handler is taken from the
documented push-only design that macOS already relies on
(`open_with_channel.dart:6-11`); it was not observed on Windows. *Falsified by:*
§4.6 opening to an empty state.

**U7 — `WM_DROPFILES` reaching the runner.** Assumes Flutter's
`HandleTopLevelWindowProc` does not consume the message first. *Falsified by:*
§4.7 doing nothing.

**U8 — Argument-type decoding.** `targetSize` is read as `int32_t` and
`int64_t`. If the standard codec delivers something else, `target_size` silently
falls back to 4000 and every thumbnail is full-size. *Falsified by:* sidebar
thumbnails that are correct but enormous, and slow.

**U9 — JPEG encoder quality option.** The `ImageQuality` property-bag write is
intentionally not error-checked, so a codec that rejects it yields default
quality instead of 0.8. *Falsified by:* output JPEGs much larger or smaller than
the macOS equivalents. Cosmetic.

**U10 — `purpose == "export"` has no dedicated branch.** On macOS, export has
its own path that deliberately bypasses the raw-bytes passthroughs
(`AppDelegate.swift:329-345`). Here, export simply falls through to
decode-and-re-encode at `targetSize` 2048, which happens to be the correct
behaviour — but it is correct by coincidence of ordering (the JPEG passthrough
is gated on `purpose == "preview"`), not by an explicit branch. *Falsified by:*
an exported JPEG coming back at original resolution instead of 2048px long edge.

**U11 — No unit tests were added.** None of this is reachable from
`flutter test`; it is native code behind a platform channel. The §4 steps are
the only test.

### APIs verified against Microsoft Learn (signature, parameter order, header, lib)

`IWICImagingFactory::CreateDecoderFromFilename`, `IWICBitmapScaler::Initialize`,
`IWICFormatConverter::Initialize`, `IWICBitmapFrameEncode::WriteSource`,
`IWICBitmapFlipRotator::Initialize`,
`IWICBitmapFrameDecode::GetMetadataQueryReader`, the WIC encoder sequence
(`CreateEncoder` → `Initialize` → `CreateNewFrame` → frame `Initialize` →
`SetSize` → `SetPixelFormat` → `WriteSource` → `Commit` → `Commit`),
`CreateStreamOnHGlobal` / `GetHGlobalFromStream` (including the documented
warning that `GlobalSize` returns capacity, not logical length — hence the
`IStream::Stat` clamp), `IFileOperation` and its STA-only constraint,
`IFileOperation::SetOperationFlags` flag semantics and minimum versions,
`SHCreateItemFromParsingName`, and the `System.Photo.Orientation` metadata query
paths `/app1/ifd/{ushort=274}` (JPEG) and `/ifd/{ushort=274}` (TIFF).

Verified against the **local Flutter engine source** rather than docs:
`flutter::MethodChannel` / `MethodResult` / `MethodCall` signatures,
`FlutterEngine::messenger()`, and the `EncodableValue` variant alternative list
(`std::vector<uint8_t>` → `Uint8List`).

Written from memory, **not** verified against documentation:
`WICBitmapTransformOptions` enumerator names and the flip-vs-rotate application
order (U3); `WICBitmapInterpolationModeFant` as the enumerator name;
`WICDecodeMetadataCacheOnDemand`; `WICBitmapEncoderNoCache`;
`WICBitmapDitherTypeNone`; `WICBitmapPaletteTypeCustom`;
`GUID_WICPixelFormat24bppBGR`; `GUID_ContainerFormatJpeg`. A wrong enumerator
name is a compile error, not a silent bug — U0 catches all of these.
