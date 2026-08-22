# Windows export EXIF carry-over — verification protocol

> Task #10 / contract decision 9. Fix lives in `windows/runner/halcyon_image.cpp`.
>
> **This code has never been compiled or executed.** It was written on a macOS host, which has
> no MSVC and no WIC. Everything below is a test the *user* runs on the Windows machine; every
> statement in the fix's comments about runtime behaviour is a prediction until this protocol
> passes. Nothing here needs the app's UI — all checks are file-in / file-out plus a CLI
> metadata dump.

---

## 0. What changed, in one paragraph

Before: every Windows export (`ImageRequestPurpose.export`, long edge 2048) went through
`DecodeAndReencode` → `EncodeJpeg`, which wrote a bare JPEG with **no EXIF block at all** —
camera body, lens, exposure, date and GPS were silently dropped. Rotation was still correct,
because it is baked into the pixels by the flip-rotator.

After: for `purpose == "export"` only, the decoder frame's metadata blocks (EXIF / GPS / IPTC /
XMP) are copied onto the encoder frame via `IWICMetadataBlockWriter::InitializeFromBlockReader`,
and then **EXIF IFD0 Orientation (tag 274) is overwritten with 1** — not copied. It must be 1,
because the pixels are already rotated; carrying the source value over would make every viewer
rotate a second time. XMP `tiff:Orientation` is removed for the same reason (Adobe tools may
prefer it over EXIF). Exif `PixelXDimension` / `PixelYDimension` are rewritten to the encoded
size, but only if they were already present.

`preview` and `sidebarThumbnail` pass `nullptr` as the metadata source and are unchanged.

---

## 1. Build

From the repo root on the Windows machine, in a shell where `flutter` is on PATH:

```powershell
cd C:\path\to\Halcyon
flutter clean
flutter pub get
flutter build windows --release
```

**Expected**: exit code 0; `build\windows\x64\runner\Release\halcyon.exe` exists.

**Failure signatures to expect if the fix is wrong** (this is the step most likely to fail,
since the file has never seen a compiler):

| Symptom | Meaning | Fix |
|---|---|---|
| `'IWICMetadataBlockWriter': undeclared identifier` (or the same for `IWICMetadataBlockReader` / `IWICMetadataQueryWriter`) | the `#include <wincodecsdk.h>` added at `halcyon_image.cpp:28` (comment at `:21-27`) is not taking effect | check it sits after `<wincodec.h>` and after `<windows.h>` |
| unresolved external symbol `IID_IWICMetadataBlockWriter` | something is referencing the named IID instead of `__uuidof` | the fix deliberately uses only `IID_PPV_ARGS`; if MSVC still wants the symbol, add `wincodecsdk.lib` to `windows/runner/CMakeLists.txt:50-53` next to `windowscodecs.lib` |
| `RemoveMetadataByName` / `SetMetadataByName` not a member | wrong interface reached by QI | both are on `IWICMetadataQueryWriter`; `GetMetadataByName` comes from its base `IWICMetadataQueryReader` |
| `error C2664` on `OverwriteExistingUint` | `UINT` vs `int` mismatch at the call site | call sites pass `width` / `height`, both `UINT` |
| any `warning C4xxx` reported as an **error** in the new code | `windows/CMakeLists.txt:42` builds with `/W4 /WX` — warnings are errors here | most likely a signed/unsigned or narrowing complaint in `OverwriteExistingUint`; fix the type, do not add a `/wd` suppression |

If a compile error is confined to the ~63 new code lines, that is a coding defect in this fix,
not a repo problem — report it verbatim rather than working around it.

---

## 2. Pick the test file

Requirements for the source photo, all three needed:

1. A **non-RAW** file — `.jpg`, `.jpeg`, `.png`, `.tif`. RAW/DNG still short-circuits at
   `halcyon_image.cpp:529-540` with `RAW_UNSUPPORTED`, so a DNG tests nothing here.
2. Long edge **> 2048 px**, so the resize path actually runs (that is where the rewritten
   PixelXDimension matters).
3. **EXIF Orientation ≠ 1** — ideally 6 or 8 (a portrait shot straight off a camera). This is
   the whole double-rotation test. A file that is already Orientation 1 cannot fail check C3.

Confirm the source before exporting:

```powershell
exiftool -Orientation# -ImageWidth -ImageHeight -Make -Model -LensModel -DateTimeOriginal "SOURCE.jpg"
```

`exiftool` is the reference tool here; install with `winget install -e --id OliverBetz.ExifTool`
if absent. `Orientation#` (with the `#`) prints the raw numeric tag, not the "Rotate 90 CW"
prose — the numeric form is what the assertions below are written against.

**Expected**: `Orientation` prints `6` (or `8`, or anything ≠ `1`), and the width/height/Make
fields are non-empty. If Orientation is already 1, pick a different file.

Record the values; they are the "before" side of every comparison.

---

## 3. Produce the export

In the app: open the folder containing the test file, star it, and run the "Thumbnail Starred"
export to an empty destination folder. That is the only user path that sends
`purpose: "export"` (`lib/services/thumbnail_export_service.dart:36-40`).

**Expected**: a file `DEST\SOURCE.jpg` exists and is non-zero length.

**Failure signature**: the export reports a failure string for this file, or produces nothing.
That means the metadata copy has broken the encode — which the fix is specifically designed to
prevent, since every metadata step is non-fatal. If this happens, the bug is in
`CopySourceMetadata` (`halcyon_image.cpp:238-284`); the likely culprit is an `HRESULT` that is
being propagated rather than swallowed. Report it as a regression, do not ship.

---

## 4. The assertions

Run all of these in one go and keep the output:

```powershell
exiftool -G1 -a -s -Orientation# -ImageWidth -ImageHeight -ExifImageWidth -ExifImageHeight -Make -Model -LensModel -FocalLength -ExposureTime -FNumber -ISO -DateTimeOriginal -GPSLatitude -GPSLongitude "DEST\SOURCE.jpg"
```

### C1 — EXIF survived at all (the defect being fixed)

**Expected**: `Make`, `Model`, `DateTimeOriginal` and at least one exposure field
(`ExposureTime` / `FNumber` / `ISO`) are present and equal to the source values from step 2.

**Failure signature**: the command prints nothing but `ImageWidth` / `ImageHeight`, or exiftool
says the file has no EXIF. That is the *pre-fix* behaviour — meaning the metadata copy never
ran. Check first that you exported through the app's export action and not a preview; then that
`purpose` really arrived as the string `"export"` (gate at `halcyon_image.cpp:566`).

### C2 — Orientation is 1, and was WRITTEN not copied

```powershell
exiftool -s -s -s -Orientation# "DEST\SOURCE.jpg"
```

**Expected**: exactly `1`.

**Failure signatures**, and what each means:

| Output | Meaning |
|---|---|
| the source value (`6` / `8` / …) | the override at `halcyon_image.cpp:272` did not take. The image will be double-rotated in every viewer. **Blocker.** |
| nothing / tag absent | `SetMetadataByName` failed *and* the source had no Orientation to copy. Harmless (viewers assume 1) but means the write silently no-ops — worth investigating before trusting C1's other tags. |
| `1` **on a source that was also `1`** | the test file was invalid; go back to step 2 and pick a rotated source. |

### C3 — the pixels are not double-rotated

This is the check C2 alone cannot make: Orientation could read 1 while the pixels were rotated
twice, or rotated zero times.

```powershell
exiftool -s -s -s -ImageWidth -ImageHeight "SOURCE.jpg"
exiftool -s -s -s -ImageWidth -ImageHeight "DEST\SOURCE.jpg"
```

`ImageWidth`/`ImageHeight` from exiftool are the **stored** pixel dimensions, before any
orientation is applied.

For a source with Orientation 6 or 8 (a 90° rotation), stored `W > H` while the photo is
portrait. After export the pixels are physically rotated, so the exported file must have the
**aspect ratio inverted**:

- **Expected**: source stored `W × H` with `W > H` → export stored `W' × H'` with `H' > W'`, and
  `W'/H' ≈ H/W` (within rounding), with `max(W', H') == 2048`.
- **Failure signature — no rotation applied**: export is still landscape (`W' > H'`) with
  Orientation 1. The photo will display sideways. Means the flip-rotator at
  `halcyon_image.cpp:473-482` stopped running.
- **Failure signature — double rotation**: export is portrait *and* Orientation reads 6/8 (i.e.
  C2 already failed). Viewers rotate the pixels a second time and the photo comes out upside
  down or sideways. This is the exact failure mode the fix is designed around.

For Orientation 3 (180°) the aspect ratio does **not** change, so C3 degrades to an eyeball
check: open source and export side by side in Windows Photos and confirm the export is not
upside down. (Opening two files in an image viewer is a human comparison of output files; it is
not UI-driven verification of the app.)

### C4 — the size cap still holds

**Expected**: `max(ImageWidth, ImageHeight) == 2048` on the export.

**Failure signature**: 2800 (the `preview` cap) means the export purpose is not reaching the
export gate at all; the original long edge means the resize was skipped.

### C5 — Exif pixel dimensions agree with reality

**Expected**: if `ExifImageWidth` / `ExifImageHeight` are present at all, they equal the
export's `ImageWidth` / `ImageHeight`.

**Failure signature**: they still hold the *source's* full-size dimensions (e.g. 6000 × 4000 on
a 2048-long-edge file). Self-contradictory file. Non-blocking — most viewers trust the stored
dimensions — but it means `OverwriteExistingUint` (`halcyon_image.cpp:184-203`) did not take
effect. If they are absent entirely, that is expected and correct: the helper deliberately never
creates a tag that was not already there.

### C6 — preview and sidebar thumbnails did not change

The fix must not touch them. Browse the same folder in the app and confirm images still appear
in the sidebar and in the main preview, at the same speed as before.

Stronger, non-UI form of the same check, if you want it: on the **pre-fix** binary export a
`preview`-sized render by any means you already have, then repeat post-fix and compare hashes.
If that is inconvenient, the code-path argument in §6 is the fallback evidence.

**Failure signature**: any EXIF present in a preview-path output, or a thumbnail that stops
rendering.

### C7 — no-EXIF source still exports

Take a JPEG that has no EXIF at all (e.g. one saved by MS Paint) and export it.

**Expected**: the export succeeds and produces a valid, viewable JPEG.

**Failure signature**: the export fails for this file. Metadata copying was supposed to be
best-effort; a failure here means a non-fatal path became fatal, which would be a worse bug than
the one being fixed. **Blocker.**

---

## 5. Recording the result

Paste the full output of step 4 into `tmp/verify/winexif-windows-run.txt` (that directory is
gitignored) along with the exiftool version and the `flutter build windows` exit code, and
report per-check C1–C7 pass/fail. A missing tick is not the same as a pass — each check above
has a named failure signature precisely so a wrong result is recognisable.

---

## 6. What a reviewer should look at in the diff

`git diff windows/runner/halcyon_image.cpp` — 63 added code lines, ~85 added comment lines
(this file's existing comment density is deliberately high and explains WHY, not WHAT).

1. **The gate**, `RequestImage` (`:557-569`). `const bool is_export = purpose == "export";` is
   the *only* place the new behaviour is switched on. Walk it: `sidebarThumbnail` and `preview`
   both arrive here with `is_export == false`, pass `false` to `DecodeAndReencode`, which passes
   `nullptr` as `EncodeJpeg`'s `metadata_source`, which makes the `if (metadata_source != nullptr)`
   at `:355` false and `CopySourceMetadata` unreachable. There is no other caller of
   `CopySourceMetadata`. Also note the JPEG passthrough at `:542-555` returns before the gate and
   is untouched, and the RAW short-circuit at `:529-540` is untouched.
2. **Orientation is written, not copied**: `:268-272`. `orientation.uiVal = 1` at `:271` is a
   literal, and `:272` writes it to EXIF IFD0 tag 274.
   Confirm nothing reads the source orientation into that PROPVARIANT.
3. **Every metadata failure is non-fatal**: `CopySourceMetadata` returns `void`, every
   `HRESULT` is either an early `return` (`:243`, `:247`, `:254`, `:259`) or explicitly
   discarded with `(void)` (`:272`, `:275`, and inside `OverwriteExistingUint` at `:201`). `EncodeJpeg`'s return value is unaffected by it.
   Compare with the pre-existing `(void)options->Write(...)` at `:325`, which the fix
   deliberately mirrors.
4. **Ordering**: `Initialize` → `SetSize` → `SetPixelFormat` → `InitializeFromBlockReader` →
   `WriteSource` → `Commit`. The metadata write sits after frame init and before `WriteSource`,
   which is the ordering of Microsoft's documented "re-encode a JPEG with metadata" sequence.
5. **Lifetime**: the decoder is created with `WICDecodeMetadataCacheOnDemand` (`:415`), so
   metadata is read lazily from the source stream. The `decoder` and `frame` ComPtrs must still
   be alive when `CopySourceMetadata` runs — they are, both are locals of `DecodeAndReencode`
   that outlive the `EncodeJpeg` call at `:498`.
6. **Nothing else changed**: `kJpegQuality`, the scaler, the flip-rotator, the format converter,
   the `IStream::Stat` length clamp and the RAW/JPEG short-circuits are all untouched.

---

## 7. Predictions, explicitly labelled

None of the following has been executed. Each is an inference from Microsoft's documented API
behaviour, and each has a check above that would expose it if wrong:

- `IWICBitmapFrameDecode` QIs to `IWICMetadataBlockReader`, and `IWICBitmapFrameEncode` QIs to
  `IWICMetadataBlockWriter`, for the JPEG codec. → C1.
- `InitializeFromBlockReader` copies EXIF, GPS, IPTC and XMP blocks wholesale. → C1.
- `SetMetadataByName(L"/app1/ifd/{ushort=274}", VT_UI2 1)` on the JPEG encoder's query writer
  reaches the same tag that `ReadExifOrientation` reads back. → C2.
- `RemoveMetadataByName(L"/xmp/tiff:Orientation")` returns a benign not-found when there is no
  XMP block, rather than invalidating the writer. → C7 covers the no-metadata case.
- `GetMetadataByName` on the query *writer* works as an existence probe for a tag that
  `InitializeFromBlockReader` just imported. → C5.
- Writing metadata before `WriteSource` does not disturb the pixel data or the `ImageQuality`
  property-bag setting. → C3, C4, and file size sanity.
- The whole sequence is safe to run on the Flutter platform thread's COM apartment, which
  `main.cpp` initialises as STA. WIC is documented as apartment-agnostic for these interfaces;
  the pre-existing encode path already runs there.
