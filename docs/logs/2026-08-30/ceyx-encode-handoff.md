# ceyx encode handoff — HEIF encode, WebP lossless, WebP metadata mux

Written 2026-08-30 during the settings-panel Export Filetype round (task #12,
round 2b/2c). This is a forward handoff for whoever next touches the `ceyx`
native encode surface — it records exactly what Halcyon needs, where the gap
is on the native side today, and where Halcyon will plug it in once it
exists. Nothing in this doc is a request to build anything now; round 2c
shipped JPEG + WebP(lossy) only and dropped HEIF/WebP(lossless) from the UI
entirely (not shown disabled) per explicit user ruling.

## What Halcyon needs from ceyx, in priority order

1. **WebP metadata mux (EXIF carry-over for WebP exports)** — highest value
   for the least native work, since WebP-lossy already ships today with a
   real, working encode path; it just loses every EXIF tag.
2. **HEIF encode entry point** — currently does not exist in ceyx at all
   (decode-only). Needed before `ExportFiletype.heif` can flip to
   `available: true`.
3. **WebP lossless** — `libwebp` itself (vendored, statically linked) already
   contains the lossless encoder; the only gap is that ceyx's C wrapper
   never calls it. Needed before `ExportFiletype.webpLossless` can flip to
   `available: true`.

## Exact evidence gathered (file:line)

- `ceyx/native/include/ceyx_encode_api.h` (lines 61-72): the encode C ABI
  declares exactly two entry points —
  `ceyx_encode_jpeg_rgba8(rgba, width, height, quality, out, out_len)` and
  `ceyx_encode_webp_rgba8(rgba, width, height, quality, out, out_len)`. Both
  take a single `int32_t quality` and nothing else — no format-specific
  config struct, no metadata pointer. There is no `ceyx_encode_heif_*`
  declaration anywhere in this header or in any other file under
  `ceyx/native/`.
- `ceyx/native/src/ffi/encode_ffi_api.cpp` (lines 177-199, specifically
  185-186): `ceyx_encode_webp_rgba8`'s implementation calls
  `WebPEncodeRGBA(rgba, width, height, width * 4, (float)quality, &webp_buf)`
  — libwebp's one-shot **lossy** convenience function. It never touches
  `WebPConfig`, `WebPPicture`, or `WebPMux` — the lower-level libwebp APIs
  that would be needed for a lossless mode or for embedding EXIF/XMP.
- `nm -gU` on the vendored, already-built
  `build/macos/Build/Products/Debug/Halcyon.app/Contents/Frameworks/libdng_decoder_native.dylib`
  (2026-08-30 local build) confirms the **linked libwebp itself DOES export**
  `_WebPEncodeLosslessRGBA` and friends (`WebPEncodeLosslessBGR/BGRA/RGB`,
  `WebPConfigLosslessPreset`, `WebPMux` is not directly probed but `mux.h` is
  vendored at `ceyx/native/third_party/libwebp-dist/include/webp/mux.h`) — so
  the lossless codec and the muxing machinery are already compiled into the
  binary Halcyon ships. **This is a wrapper-only gap, not a missing
  dependency**: no new third-party library needs to be vendored, only new
  C entry points in `ceyx_encode_api.h` + `encode_ffi_api.cpp` that call the
  lower-level libwebp APIs already present in the binary.
- `ceyx/plugin/lib/src/encode_bindings.dart` (lines 59-118): `CeyxEncodeBindings`
  guards every symbol lookup in a try/catch and exposes `available` — the
  precedent for how a future `heif`/`webpLossless`/mux entry point should be
  wired on the Dart side (additive, never breaks a build that predates it,
  same pattern `HeifNativeBindings` already uses for its own additive HEIF
  decode symbols in `ceyx/plugin/lib/src/heif_bindings.dart`).
- `ceyx/plugin/lib/src/encode_service.dart` (lines 46-134):
  `CeyxEncodeService.encodeJpegNative`/`encodeWebpNative` are the two
  existing high-level Dart entry points, each `Future<Uint8List> Function(rgba, {width, height, quality})` run on a worker isolate via `Isolate.run`.
  A future `encodeHeifNative`/`encodeWebpLosslessNative`/an EXIF-carrying
  variant of `encodeWebpNative` should follow the exact same shape (isolate
  boundary, same error taxonomy via `CeyxEncodeErrorCode`/
  `CeyxEncodeException`/`CeyxEncodeUnavailableException`) so Halcyon's
  consuming code doesn't need new plumbing patterns, only new call sites.

## Halcyon-side integration points that will consume these

- **`lib/services/library/photo_export_service.dart`**:
  - `ExportFiletype` enum (near the top of the file) already declares all
    four identities (`jpeg`, `heif`, `webpLossy`, `webpLossless`) with a
    `bool available` flag per entry — this enum was deliberately built
    extensible now (round 2b) specifically so a future round only needs to
    flip `available: true` on the relevant entries, not redesign the type.
    Each entry also carries its own `extension` (`jpg`/`heic`/`webp`/`webp`)
    already.
  - `PhotoExportService.exportBytesFor`'s `filetype` branch is currently
    `if (filetype == ExportFiletype.webpLossy) { ... } else { /* jpeg path
    */ }`. Adding HEIF or WebP-lossless means adding another branch here
    that calls the new native entry point the same way the webpLossy branch
    calls `webpEncode` (see below) — reuse `_decodeAndResizeFrame` for the
    shared decode/orient/resize step, it already returns a plain
    `img.Image` that any codec's raw-RGBA encode can consume via
    `frame.getBytes(order: img.ChannelOrder.rgba)`.
  - `PhotoExportService.longEdge`/`jpegQuality`/`filetype` are all read-at-
    call-time instance fields set from `AppState` — a future
    `ExportFiletype.webpLossless` selection should probably disable
    `jpegQuality`'s effect (lossless doesn't take a quality knob) — the
    settings-tab code already anticipates this: round 2c's `_quality()`
    widget comment notes the enabled/disabled logic was simplified away
    this round specifically because it was unreachable, and should come
    back if `webpLossless.available` ever flips true.
  - The `WebpEncode` typedef (injection seam, mirrors `DngFullDecoder`) is
    the pattern to copy for a `HeifEncode`/lossless variant: production
    code defaults to the real `CeyxEncodeService` call, tests inject a
    pure-Dart fake (see `test/services/library/photo_export_service_test.dart`,
    group `round 2b: Export Filetype`) because `flutter test`'s dylib search
    path cannot resolve the native library outside a built `.app` bundle
    (verified by direct probe during this round — `DngNativeBindings.load()`'s
    candidate list has no entry matching Halcyon's repo layout under
    `flutter test`).
- **`lib/providers/app_state.dart`**: `_exportFiletype`/`setExportFiletype`/
  `_normaliseExportFiletype` already fall back to the default for a
  recognised-but-`available: false` name (not just a garbage one), so no
  change is needed there when `available` flips to true for a new type —
  existing users who somehow had a stale unavailable pref will pick it back
  up automatically once it becomes available again, without a migration.
- **`lib/views/settings_dialog/export_tab.dart`**: `_filetype()` filters
  `ExportFiletype.values.where((f) => f.available)` to build the segmented
  control. Flipping `available: true` on an entry is the ONLY change needed
  here to make it reappear in the UI (round 2c deliberately removed the
  "shown but disabled" treatment used in round 2b, per user ruling — do not
  reintroduce a disabled/tooltip state without re-confirming that's still
  wanted).

## EXIF-loss fact, as currently shipped (round 2c)

WebP (lossy) exports carry **zero EXIF** today — confirmed by test
(`TC-480`, `test/services/library/photo_export_service_test.dart`), not just
asserted. `ceyx_encode_webp_rgba8` has no metadata-pointer argument, and
`package:image`'s own WebP encode/decode path doesn't round-trip an EXIF
block either. Per explicit user ruling (round 2c, option 2), this ships
**silently** — no UI caption or warning is shown to the user about the
missing metadata. If a future round wants to fix this (via a WebP mux entry
point per the priority list above), `photo_export_service.dart`'s
`_attachSourceExif` (JPEG-only today, mutates an `img.Image`'s
`img.ExifData` via `package:exif`) is the existing reference implementation
of "what EXIF Halcyon already knows how to re-read from the source file and
attach" — a WebP path would need an analogous mux call instead of
`img.encodeJpg`, not a redesign of the tag-reading half.
