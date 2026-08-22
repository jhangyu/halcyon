# Cross-platform thumbnail/preview architecture — independent take A

> Author: `arch-thumb-a-opus` (Team C, slot A). Written independently of slot B; that file was not read.
> Anchor: Halcyon `main` @ `5e35d39`, working tree dirty only in `lib/views/rename_dialog.dart` and `windows/flutter/generated_plugins.cmake` (untouched here).
> Analysis only. No code was changed. Evidence: `tmp/verify/thumb-a-evidence.txt`, `tmp/verify/thumb-a-dart-extract-bench.txt`, `tmp/verify/thumb-a-callsites.txt`, `tmp/verify/thumb-a-winport-diffstat.txt`, `tmp/verify/thumb-a-gitstatus.txt`.

---

## 0. Premise correction — read this before section 1

The frozen contract (`windows-port-review-contract.md:90`) states as established fact:

> `lib/services/native_thumbnail_service.dart:87` talks to `MethodChannel('halcyon/thumbnail')`, implemented only in `macos/Runner/AppDelegate.swift`. On Windows the channel is absent, so `:122` catches `MissingPluginException` and degrades to `NativeImageFailure('MISSING_PLUGIN')`.

**That is not true of the current tree.** `halcyon/thumbnail` *is* implemented and registered on Windows, on `main`, today:

| Fact | Evidence |
|---|---|
| Channel registered on Windows | `windows/runner/halcyon_channels.cpp:66-67` (`MethodChannel(messenger, "halcyon/thumbnail", &codec)`), handler set at `:68-105` |
| `Channels` constructed at engine start | `windows/runner/flutter_window.cpp:39` |
| Sources compiled into the runner | `windows/runner/CMakeLists.txt:11-13` |
| Landed commit | `2af5243 feat(windows): add WIC thumbnail, Recycle Bin and Open With bridges` |
| `windows-port` branch does **not** touch it | `git diff --name-only main...windows-port` → 8 files, none is `halcyon_image.cpp` / `halcyon_channels.cpp` (`tmp/verify/thumb-a-winport-diffstat.txt`) |

So on Windows `MissingPluginException` is **not** thrown, `native_thumbnail_service.dart:122-135` is **not** the death point, and JPEG/PNG display works. The real death point for RAW is one line: `windows/runner/halcyon_image.cpp:392-403`, which returns `Fail("RAW_UNSUPPORTED", …)` for every `.dng/.arw/.cr2/.nef/.orf/.rw2`, deliberately choosing a code that is *not* `NO_EMBEDDED_PREVIEW` (the comment at `:393-400` says so explicitly).

The **conclusion** of the contract's problem statement survives intact — `NativeImageNeedsRawDecode` can never be constructed on Windows, so `DngFullDecoder`/`dng_processor` is never invoked and preview-less DNGs cannot display. But the mechanism, the failing line, and therefore the shape of the smallest possible fix are all different from the premise. The rest of this document is built on the tree, not on the premise. Everything below is stated against `main` @ `5e35d39`.

A second consequence of the correction: because the Windows bridge answers `RAW_UNSUPPORTED` (a `PlatformException`, `native_thumbnail_service.dart:114-121`) rather than never answering, **every RAW file on Windows fails identically in all three purposes** — including the sidebar and the export, which the `MISSING_PLUGIN` story would have made look like a single preview-path problem.

### 0.1 Second premise change: the Windows FFI decode works (user amendment, 2026-08-22)

v1 of the contract's shared ground truth said the Windows DLL's behavioural correctness had "never been tested". **The user amended that during this round:** they confirmed on their own Windows machine that `dng_decoder_native.dll` (`flutter_dng_decoder` `windows-port` @ `d36e1bd`) decodes a DNG and renders it correctly. Per the amended contract, candidate designs must not hedge on "the FFI path might not work". Consequences applied throughout this document:

- **C4 is re-scoped from a does-it-work question to an API-level dependency check.** Section 2.0 below audits what the FFI surface actually exposes today — API shape, sizing control, orientation handling, threading — and each candidate then states which of those it depends on and whether that dependency is satisfied. This turned out to be the more interesting question by a distance: the decode path works, but it exposes **no sizing control at all**, which constrains every candidate identically (§2.0.1).
- **Candidate scoring is re-weighted, not merely annotated.** Routing Windows DNG decode through the FFI no longer carries unverified-platform risk, which is precisely why Candidate 2's "Dart emits the raw-decode signal" move went from *unblocks an attempt* to *ships the feature*, and why Candidate 3's former advantage ("avoids the DLL") stopped being an advantage at all.
- Still open and still in every candidate's risk column: (a) the DLL's **packaging** path into the built app — see `cmake-bundled-libraries-var-silent-typo`, where a misspelled `bundled_libraries` silently shipped no DLL and raised no error; (b) **cold-start decode latency** against the 1 s ceiling (§3.2 item 1) — a rendered image proves correctness, not timing; (c) whether the vendored SDK edits regress macOS/Android (Track B owns that).
- The stated justification for the bypass at `halcyon_image.cpp:393-395` — "there is no Windows build of the native decoder" — is now factually dead. The guard at `:392` is no longer a considered trade-off; it is stale code with an obsolete comment.

> Minor contract inconsistency worth flagging to the commander: the ground-truth table is amended to **RESOLVED**, but the C4 line in the acceptance-conditions list still reads "which is currently **unverified**". I followed the amended table and the lead's re-brief.

---

## 1. (C1) Current call graph — three cases × two platforms

### 1.1 Common spine (platform-independent)

Preview path:

```
AppState.selectItem                      app_state.dart:291
  └ AppState._preloadImages              app_state.dart:379
      └ ImagePreloadController.preloadImages
                                         image_preload_controller.dart:253
          ├ _loadPreview (selected, priority)          :307 → :670
          │   └ _requestPreviewBytes                    :718 → :631
          │       └ _imageLoader(path, purpose: preview) :632
          │           = AppState ctor closure          app_state.dart:85-89
          │             → NativeThumbnailService.requestImage
          │                                    native_thumbnail_service.dart:97
          │               → MethodChannel('halcyon/thumbnail').invokeMethod('getThumbnail')
          │                                    native_thumbnail_service.dart:87,104
          ├ _loadPreview × window (-3..+5)              :317-321
          ├ _precacheTierOneWindow (±2)                 :324 → :582
          │   └ tierOneProviderFor(bytes,w,h)           :598 → :25
          └ _scheduleTierTwoDecode (250ms debounce)     :325 → :335
              └ _decodeTierTwoWindow (±1)               :349
                  ├ byte items → _decodeFullSizeIntoImageCache :380 → :520
                  │                 └ fullSizeProviderFor(bytes)  :525 → :41
                  └ raw items  → _startRawDecode        :365 → :434
                                   └ _runRawDecode      :452
                                       ├ decoder(path)  :462  (DngFullDecoder)
                                       │   = halcyonDngFullDecoder  dng_decode_service.dart:34
                                       │     → DngDecoderService.decodeOnWorker
                                       │       dng_processor_ffi/lib/src/dng_decoder_service.dart:194
                                       ├ decodedRgbaToImage(exifOrientation)
                                       │                 :463 → decoded_rgba_image_provider.dart:21
                                       └ _decodedProviders[id] = DecodedRgbaImageProvider(image) :475
```

Display:

```
MainDetailView.build                     main_detail_view.dart:106-125
  └ _buildZoomableViewer(bytes, useFullSize, id, decodedProvider)  :226
      └ provider = decodedProvider ?? (useFullSize ? fullSizeProviderFor : tierOneProviderFor)
                                         main_detail_view.dart:277-285
      └ Image(image: provider, gaplessPlayback: true)              :293
```

Sidebar thumbnails:

```
SidebarView itemBuilder range report     sidebar_view.dart:91,96 (AD-014)
  └ AppState.preloadThumbnails           app_state.dart:392
      └ ImagePreloadController.preloadThumbnails  image_preload_controller.dart:773
          └ 100ms debounce (G-001)        :791
              └ _imageLoader(path, purpose: sidebarThumbnail)  :830
                  → NativeThumbnailService.requestImage → channel
              └ `if (result is NativeImageBytes)` — anything else is dropped :836
  └ render: Image.memory(thumbBytes, width:32, height:32)  sidebar_view.dart:273-279
     (NB: no cacheWidth/cacheHeight — decode is at the JPEG's own resolution)
```

Export:

```
SidebarView menu → AppState.exportStarredThumbnails  sidebar_view.dart:324 → app_state.dart:431
  └ ThumbnailExportService.exportStarred (4 workers)  thumbnail_export_service.dart:61,111
      └ _fetchBytes = _defaultFetch                   :36
          └ NativeThumbnailService.getThumbnail(purpose: export)  :37-40
              → requestImage(allowRawDecodeSignal: false)  native_thumbnail_service.dart:148-153
              → channel; `result is NativeImageBytes ? bytes : null`  :154
      └ File(outPath).writeAsBytes(bytes)             :100
```

### 1.2 The matrix

Legend: **✅ works** · **⚠️ works, degraded** · **❌ dead**. "Dies at" gives the exact line where the platform gives up.

#### A. Preview (`purpose: preview`, 2800px cap)

| Case | macOS | Windows |
|---|---|---|
| **JPEG** | ✅ `AppDelegate.swift:360-370` raw-bytes passthrough (`isPreviewRequest && isJpeg`) → `:405-412` dispatch → `NativeImageBytes` → `_imageCache` → tier-1/tier-2. EXIF orientation honoured by Flutter's JPEG decoder (comment `:348-349`). | ✅ `halcyon_image.cpp:410-418` — byte-for-byte the same passthrough, same rationale (`:405-409`). |
| **DNG with embedded preview** | ✅ `AppDelegate.swift:371-376` `extractFullSizeEmbeddedJpeg` (Swift TIFF walker, `DngPreviewExtractor.swift`) → passthrough at `:405-412`. Orientation injected as an EXIF APP1 by the Swift extractor. | ⚠️ **works only via the Dart back-door.** Native dies at `halcyon_image.cpp:392-403` (`RAW_UNSUPPORTED`) → `native_thumbnail_service.dart:114-121` → `NativeImageFailure` → `image_preload_controller.dart:651-666` `case NativeImageFailure()` → `.dng` suffix test at `:659` → `DngPreviewExtractor.extractFullSizeEmbeddedJpegFromFile` at `:661` → bytes. Costs one wasted channel round-trip per item; correct pixels. |
| **DNG without embedded preview** | ✅ `AppDelegate.swift:388-401` emits `FlutterError("NO_EMBEDDED_PREVIEW", details: orientation)` → `native_thumbnail_service.dart:115-118` → `NativeImageNeedsRawDecode` → `image_preload_controller.dart:639-650` records `_needsRawDecode[id]` → tier-2 `_startRawDecode` `:365` → FFI decode → `DecodedRgbaImageProvider`. | ❌ **DEAD. Two lines, in order.** (1) `halcyon_image.cpp:401` returns `RAW_UNSUPPORTED`, not `NO_EMBEDDED_PREVIEW`, so `NativeImageNeedsRawDecode` is never constructed and `_needsRawDecode` stays empty ⇒ `_startRawDecode` (`image_preload_controller.dart:365`) is unreachable ⇒ the injected `halcyonDngFullDecoder` (`main.dart:25`) is dead code on Windows. (2) The Dart fallback then runs anyway and *also* returns null: `DngPreviewExtractor.extractFullSizeEmbeddedJpeg` returns `null` at `dng_preview_extractor.dart:200` (`best == null`, no qualifying SubIFD JPEG). `_requestPreviewBytes` returns null (`:666`) with `_needsRawDecode` empty, so `_loadPreview:727-732` puts the id in `_failedIds` and the view shows "無法讀取…" (`main_detail_view.dart:118` → `:213-224`). |
| **Non-DNG RAW** (`.arw/.cr2/.nef/.orf/.rw2`) — *outside the three named cases, included because it shares the death line* | ✅ `AppDelegate.swift:426-470`: embedded thumbnail via ImageIO, else CIRAWFilter. | ❌ Dies at `halcyon_image.cpp:392-403`. The Dart fallback is gated on `.dng` (`image_preload_controller.dart:659`), so there is no second chance at all. Permanently "unreadable". |
| **HEIC** | ✅ ImageIO. | ⚠️/❌ `halcyon_image.cpp:283-291` — depends on the user having the HEIF Image Extensions package; without it, `LOAD_FAILED` (the comment at `:287-289` states this). |

#### B. Sidebar thumbnail (`purpose: sidebarThumbnail`, 200px)

| Case | macOS | Windows |
|---|---|---|
| **JPEG** | ✅ `AppDelegate.swift:475-486` ImageIO thumbnail at 200px, JPEG re-encode. | ✅ `halcyon_image.cpp:420-421` → `DecodeAndReencode` (`:274`): WIC decode → scaler `:313-331` → rotation baked in `:338-348` → JPEG `:363`. |
| **DNG with embedded preview** | ✅ `AppDelegate.swift:426-442` (embedded thumbnail; `targetSize <= 256` accepts small icons). | ❌ **DEAD.** `halcyon_image.cpp:392-403`. `preloadThumbnails` only accepts `NativeImageBytes` (`image_preload_controller.dart:836`); there is no `NativeImageFailure` branch and **no Dart-extractor fallback on this path at all** (`DngPreviewExtractor` is referenced exactly once in the file, at `:661`, inside `_requestPreviewBytes`). Result: grey placeholder square forever (`sidebar_view.dart:261-270`). |
| **DNG without embedded preview** | ⚠️ `AppDelegate.swift:426-442` then, since `isPreviewRequest` is false, the CIRAWFilter branch at `:448` is skipped; falls to `:479-485` ImageIO with `FromImageIfAbsent: true`. Produces something for most files. Never emits `NO_EMBEDDED_PREVIEW` (native only emits it for `purpose == "preview"`, `:319`,`:371`). | ❌ Same as above — `halcyon_image.cpp:392-403`. |
| **Non-DNG RAW** | ✅ as above. | ❌ Same line. |

**This row is the most under-reported part of the problem.** On Windows *every* RAW file has a blank sidebar thumbnail, including DNGs whose preview displays correctly in the main pane. A user culling a card of DNGs gets a working viewer and a column of empty grey squares.

#### C. Export (`purpose: export`, 2048px, EXIF carried over with Orientation=1)

| Case | macOS | Windows |
|---|---|---|
| **JPEG** | ✅ `AppDelegate.swift:329-345` terminal export branch → `makeExportJpeg:291` → `exportThumbnailOptions:237` (`FromImageAlways: true`, `WithTransform: true`) → `encodeExportJpeg:254` copies **all** source properties, forces `kCGImagePropertyOrientation = 1` (`:266`), fixes TIFF orientation (`:270-273`) and the EXIF pixel-dimension tags (`:276-280`). | ⚠️ **works, but not to spec.** `halcyon_image.cpp:420-421` → `DecodeAndReencode`. Pixels are right: capped at 2048 (`:312-331`), rotation baked in (`:338-348`), quality 0.8 (`:35`) vs macOS export's 0.85 (`AppDelegate.swift:227`). **But all EXIF is dropped** — the file's own comment says so (`:333-337`). The contract's "EXIF carry-over" requirement is unmet on Windows today. This is a silent divergence, not a failure code. |
| **DNG with embedded preview** | ✅ same export branch; ImageIO reads the DNG directly. | ❌ `halcyon_image.cpp:392-403` → `getThumbnail` returns null (`native_thumbnail_service.dart:154`) → `thumbnail_export_service.dart:93-94` throws `StateError('Export produced no image data')` → recorded in `failures` → user sees "N 張失敗" (`app_state.dart:444-446`). |
| **DNG without embedded preview** | ✅ same. Note the export branch is taken *before* the raw-bytes passthroughs (`AppDelegate.swift:322-329`), so it never returns original file bytes. | ❌ Same line. |
| **Non-DNG RAW** | ✅ same. | ❌ Same line. |

### 1.3 One-line summary of the Windows column

Everything that is broken on Windows is broken at **`windows/runner/halcyon_image.cpp:392-403`**, plus one structural gap on the Dart side — **`image_preload_controller.dart:836`** silently drops every non-`NativeImageBytes` sidebar result, and **`:659`** gates the only Dart fallback on `.dng`. The `MissingPluginException` clause at `native_thumbnail_service.dart:122-135` is currently unreachable on all four shipping platforms' desktop targets that have a runner; it still matters for iOS/Linux/Android.

---

## 2. (C2–C4) Candidate architectures

All three are stated against the same fixed requirements:

- **R-a** `sidebarThumbnail` @200px, 41 rows in flight (`thumbnailPrefetchMargin = 20`, `image_preload_controller.dart:50`), sequential, 100ms-debounced.
- **R-b** `preview` @2800px cap, must feed `tierOneProviderFor`/`fullSizeProviderFor` with **identical bytes object identity and identical w/h** or the ImageProvider cache key misses and the decode silently happens twice (`image_preload_controller.dart:20-41`, AD-011).
- **R-c** `export` @2048px long edge, EXIF carried over, Orientation forced to 1, pixels pre-rotated.
- **R-d** No user-visible stall > 1 s (memory: `one-second-operation-ceiling`).
- **R-e** `grep -rn "Platform.is\|defaultTargetPlatform" lib/` must stay at **0 hits** — verified 0 today (`tmp/verify/thumb-a-evidence.txt` E4). This was an explicit R1 acceptance condition (`windows-raw-r1r2-contract.md` AC3) and is what keeps the pipeline unit-testable with fakes.

Also stated up front, per the corrected problem statement: **the gap is one hard-coded RAW rejection plus the routing behind it, not a cross-platform redesign.** Any candidate that displaces a *working* native path must name the concrete failure that justifies it. I have applied that test destructively to my own first draft — see §2.2's revision note.

### 2.0 (C4 prerequisite) What the `dng_processor_ffi` surface actually exposes today

The decode works on Windows. The question that now matters is what the API lets a caller ask for. Audited against `dng_processor_ffi/lib/dng_processor_ffi.dart` and `lib/src/{dng_decoder_service,dng_bindings}.dart`; raw output in `tmp/verify/thumb-a-ffi-api.txt`.

| Dimension | What exists | Consequence for this decision |
|---|---|---|
| **Public surface** | Exactly one export line (`dng_processor_ffi.dart:16-17`): `DngImage`, `DngErrorCode`, `DngDecodeException`, `DngDecoderService`. | Small and stable. Halcyon currently uses **one** of its methods (`decodeOnWorker`, via `dng_decode_service.dart:14`). |
| **Full decode** | `decodeOnWorker(String filePath) → Future<DngImage>` (`:194`). | Adapter already exists and satisfies `DngFullDecoder` (`dng_decode_service.dart:12-30`). ✅ satisfied. |
| **Sizing control** | **NONE.** `decodeOnWorker` takes a path and nothing else; the native entry point `dngDecodeAndProcess` is a one-argument function (`dng_bindings.dart:43`, `:121`). There is no scaled, half-size, or capped decode at any layer. | ⚠️ **The single most consequential API fact in this document.** `preview` (2800px), `sidebarThumbnail` (200px) and `export` (2048px) cannot be served by asking the decoder for a smaller image. Every candidate gets one full-resolution RGBA buffer (~4080×3056×4 ≈ 50 MB) or nothing, and any downsizing must happen on the Flutter side afterwards. It also means the 1 s ceiling cannot be mitigated by "decode small first, refine later" — that lever does not exist. This constrains all three candidates **identically**, so it is not a discriminator between them, but it is a hard ceiling on what any of them can promise. |
| **Embedded-preview extraction** | `getPreviewJpeg` (`:201`) and `getPreviewJpegOnWorker` (`:245`), native, returning JPEG bytes or null. | A **fourth** implementation of embedded-preview extraction already exists (after Swift, C++-adjacent WIC metadata, and Dart). Halcyon does not call it — 0 hits in `lib/` (`tmp/verify/thumb-a-evidence.txt` E5). Relevant to §2.4's duplication question, and a genuine option for Candidate 3 if C++ TIFF-walking is unattractive. |
| **Orientation** | **NONE.** `DngImage` carries `rgbaData/width/height/decodeMs/processMs` and no orientation field (`:28-54`); `decoded_rgba_image_provider.dart:13-17` states the decoder deliberately does not read or apply EXIF Orientation. | Orientation must be sourced *outside* the FFI. Today it rides in the `NO_EMBEDDED_PREVIEW` channel details (`AppDelegate.swift:392-398`). ✅ satisfiable without native code: `DngPreviewExtractor.readOrientationFromFile` (`dng_preview_extractor.dart:41-48`) reads IFD0 tag 0x0112 in pure Dart and defaults to 1. This is what makes a Dart-emitted `NativeImageNeedsRawDecode` possible at all — see Candidate 2. |
| **Threading** | `decodeOnWorker` → `Isolate.run` → `_decodeFileToTransferable` (`:283-286`) constructs a **fresh `DngDecoderService()..initialize()`**, i.e. a fresh `DngNativeBindings.load()` and `DynamicLibrary.open`, **per call**. Result crosses back as `TransferableTypedData`. | ✅ satisfied for correctness and for keeping the UI isolate free — which matters, because the controller calls it from `_runRawDecode` (`image_preload_controller.dart:462`) inside the ±1 tier-2 window and can have up to 3 in flight. ⚠️ but there is **no isolate or handle pooling**: every decode pays library-open plus whatever pipeline setup the backend does. See §3.2 item 1. |
| **Warmup / pipeline cache** | `warmupForSize` (`:143`), `setPipelineCachePath` (`:161`), `savePipelineCache` (`:174`), `pipelineCacheStatus` (`:182`). | ⚠️ **Halcyon calls none of them** (0 hits in `lib/`). `warmupForSize` itself runs in its own `Isolate.run` (`:144-147`); whether that warms the *later* decode isolate depends on the native state being process-global — the neighbouring `setPipelineCachePath` doc comment (`:156-157`) asserts process-global state, so it probably does, but it is **[U]** and untested on Windows. This is the one available mitigation for the 1 s risk and it is orthogonal to the architecture choice. |
| **Zero-copy variant** | `decode()` / `_decodeZeroCopy` (`:279-288`), documented as unsafe across isolates (`:271-275`). | Not used and should stay unused; `decodeOnWorker` is the correct call. No candidate proposes changing this. |

**Bottom line for C4:** every candidate's FFI dependency is *satisfied by today's API* — full decode, worker threading, and an out-of-band orientation source all exist. No candidate needs an upstream `dng_processor_ffi` change. What no candidate can obtain from the API is a reduced-resolution decode, and none of them pretends otherwise.

---

### Candidate 1 — **Thin Seam Patch** (make the parts that already exist reachable)

**The concrete failure it fixes:** rows B/DNG-with-preview and B/DNG-without-preview and C/DNG on Windows (blank sidebar thumbnails, failed exports), and A/DNG-without-preview (unreadable main pane) — without inventing any new component.

**Shape.** Three localised changes, no new architecture:

1. `windows/runner/halcyon_image.cpp:392-403` — split the RAW branch. For `.dng` **and** `purpose == "preview"` **and** `allowRawDecodeSignal`, return `NO_EMBEDDED_PREVIEW` with the IFD0 orientation, mirroring `AppDelegate.swift:388-401`. That requires reading one TIFF tag in C++ (~40 lines; WIC's metadata reader already does exactly this for JPEG/TIFF at `halcyon_image.cpp:118-…`, and a DNG *is* a TIFF container, so `ReadExifOrientation` may work unmodified — **unverified**, see §3). Everything else keeps returning `RAW_UNSUPPORTED`.
2. `image_preload_controller.dart:830-839` (sidebar) — on a non-`NativeImageBytes` result for a `.dng`, fall back to `DngPreviewExtractor`, same as `_requestPreviewBytes:651-666` already does for preview. The extracted JPEG is full-size, so it must be handed to the sidebar with an explicit decode cap (see the regression note below).
3. `thumbnail_export_service.dart:36-41` — on a null native fetch for a `.dng`, fall back to `DngPreviewExtractor` + a Dart-side resize/re-encode. **This is the expensive third of the three**: nothing in Dart today can resize a JPEG and write EXIF, and there is no `image` package in `pubspec.yaml`. Options: (a) accept "export on Windows emits the *unresized* embedded preview" as a stated limitation; (b) add `package:image` (pure Dart, resizes and can write EXIF) for the export path only; (c) route export through `dart:ui` (`instantiateImageCodec(targetWidth:)` → `toByteData` → no JPEG encoder in `dart:ui`, so this dead-ends). Recommend (b) if export parity is wanted now, (a) if not.

**Serving the three purposes.** `sidebarThumbnail`: WIC for non-RAW (unchanged), Dart extractor + capped decode for DNG, still dead for non-DNG RAW. `preview`: unchanged for JPEG; Dart extractor for DNG-with-preview (already working); FFI decode for DNG-without-preview (newly reachable). `export`: unchanged for non-RAW; per the choice above for DNG.

**Files that change.** `windows/runner/halcyon_image.cpp`; `lib/services/image_preload_controller.dart`; `lib/services/thumbnail_export_service.dart`; `lib/views/sidebar_view.dart` (add `cacheWidth`/`cacheHeight`); tests: `test/image_preload_controller_test.dart`, `test/thumbnail_export_service_test.dart`, `unit_test.md`. Optionally `pubspec.yaml`.

**Work estimate.** 1–2 worker-days for the Dart half (all verifiable on macOS with fakes + real samples in `local_data/photo_samples/`); the C++ half is ~40 lines but is **unverifiable on macOS** and joins the existing pile of uncompiled Windows code.

**macOS perf-path regression risk — LOW, with one real trap.** The Dart changes are all in `NativeImageFailure` branches, which macOS never reaches for these formats (macOS returns bytes or `NO_EMBEDDED_PREVIEW`). The trap is item 2: `sidebar_view.dart:273-279` renders `Image.memory(bytes, width: 32, height: 32)` with **no `cacheWidth`/`cacheHeight`**, so the decode is at the JPEG's native resolution. Today macOS hands it a ~200px JPEG, so nobody noticed. Feeding it a 4000px embedded preview instead means ~48 MB decoded per row against a 500 MB `ImageCache` (`main.dart:12`) with up to 41 rows in the prefetch window — that is an OOM-class regression, not a slowdown. Any candidate that puts full-size bytes on the sidebar path **must** add the cache dims; doing so also slightly changes macOS behaviour (a real, small, verifiable improvement).

**EXIF orientation.** DNG-with-preview: already injected as an APP1 segment by `DngPreviewExtractor._injectExifOrientation` (`dng_preview_extractor.dart:208-211,232-265`), honoured by Flutter's JPEG decoder. DNG-without-preview: read natively on Windows in the new branch, carried in the `NO_EMBEDDED_PREVIEW` details, applied by `decodedRgbaToImage` (`decoded_rgba_image_provider.dart:21-38,47`). Export: baked into pixels by WIC (`halcyon_image.cpp:338-348`); if the Dart export fallback is taken, orientation must be baked there instead.

**AD-010/AD-011 freeze — NOT broken.** Still exactly three `NativeImageResult` variants. The `NO_EMBEDDED_PREVIEW` → `NativeImageNeedsRawDecode` mapping is reused verbatim; `DngFullDecoder`/`DecodedRgba` unchanged; both tier factories untouched.

**(C4) FFI dependency — API-level check.** Needs, from §2.0: `decodeOnWorker` (full decode) ✅ already adapted at `dng_decode_service.dart:12-30`; worker threading ✅; orientation ✅ but **sourced natively**, from the new C++ branch's `NO_EMBEDDED_PREVIEW` details, because this candidate keeps the signal native-emitted. Needs **no** sizing control, because the decoded image serves the main pane at full resolution exactly as it does on macOS today. Nothing here requires an upstream `dng_processor_ffi` change. The orientation source is this candidate's weakest link: it depends on `ReadExifOrientation` (`halcyon_image.cpp:118`) working against a DNG container, which is unverifiable from here (§3.2 item 3) — whereas Candidate 2 gets the same value from already-tested Dart. Residual non-API risk is packaging only (`cmake-bundled-libraries-var-silent-typo`); if the DLL fails to load, `_runRawDecode`'s catch (`image_preload_controller.dart:482-490`) → `_fallbackToLegacyBytes` (`:500`) → `RAW_UNSUPPORTED` → `_failedIds` → today's "unreadable" screen. No regression, but also no message naming the real cause — worth a log line.

**1 s ceiling.** Sidebar/preview for DNG-with-preview: measured Dart extraction warm median **3.79 ms**, max **8.56 ms** across 14 real samples (`tmp/verify/thumb-a-dart-extract-bench.txt`) — two orders of magnitude under the ceiling. DNG-without-preview on Windows: **UNKNOWN**, see §3.1. This is the single biggest open number in the whole document.

---

### Candidate 2 — **Dart Fallback Chain** (native stays first; the fallback becomes uniform and platform-independent)

> **Revision note (after the corrected premise).** My first draft of this candidate was "Dart-*First*": Dart would read JPEG/PNG bytes itself and demote the native channel to an accelerator. Under the corrected problem statement that fails its own test — it would replace two *working* passthroughs (`AppDelegate.swift:360-370`, `halcyon_image.cpp:410-418`) with no concrete failure behind it, purely for symmetry. I have cut it. What survives is the part that does answer a real failure, and it is strictly smaller.

**The concrete failures it fixes**, each named:
1. Windows DNG sidebar thumbnails are blank (`halcyon_image.cpp:392` short-circuit; `image_preload_controller.dart:836` drops the failure silently).
2. Windows DNG export fails (`thumbnail_export_service.dart:93-94` throws on the null fetch).
3. Windows preview-less DNGs are unreadable (`halcyon_image.cpp:401` returns the wrong code, so `NativeImageNeedsRawDecode` is never built).
4. **The structural one:** the Dart embedded-preview fallback exists for exactly *one* of three purposes — `image_preload_controller.dart:661`, inside `_requestPreviewBytes` — because each purpose hand-rolls its own error handling. Failures 1 and 2 are not separate bugs; they are the same missing fallback, absent twice. Fixing them one at a time (Candidate 1) leaves the third copy to be written by hand next time.

**Shape.** One new Dart component, `lib/services/image_source_chain.dart`, implementing the existing `ThumbnailLoader` typedef (`app_state.dart:23-27`) so it drops into the seam already at `app_state.dart:83-89` — no new seam, no new injection point. **The native channel is tried first for every purpose on every platform**, so both working native paths are preserved byte-for-byte. The chain only decides what happens *after* a `NativeImageFailure`:

| Purpose | Order tried |
|---|---|
| `preview` | (1) native channel — unchanged, still the JPEG/DNG passthroughs and macOS CIRAWFilter; (2) on failure, `DngPreviewExtractor` for `.dng` (this is exactly today's `:661` behaviour, relocated); (3) on failure *and* `.dng`, emit `NativeImageNeedsRawDecode(orientation)` with orientation from `DngPreviewExtractor.readOrientationFromFile` (`dng_preview_extractor.dart:41`) |
| `sidebarThumbnail` | (1) native channel — unchanged, it is the only thing that can resize; (2) on failure, `DngPreviewExtractor` + a `dart:ui` capped decode (`instantiateImageCodec(targetWidth: 200)`) |
| `export` | (1) native channel — unchanged, it is the only EXIF-preserving encoder; (2) on failure, `DngPreviewExtractor` + a Dart resize/encode, or the stated limitation (same three sub-options as Candidate 1) |

The one architectural move worth naming: **`NativeImageNeedsRawDecode` stops being a native-only signal.** Nothing in the sealed class or in `image_preload_controller.dart` requires it to originate in Swift — it just means "cheap bytes are unavailable and this is a RAW the decoder can handle". §2.0 confirms the two things that makes possible are both already available in Dart: the decoder is reachable (`decodeOnWorker`) and the orientation it does not supply can be read without native code. So Windows gets the full raw-decode path **with no C++ written, and no Windows-only code to review** — which, given that this host cannot compile Windows, is the whole argument.

**Serving the three purposes.** Identical to today wherever today works. `preview`/`sidebarThumbnail`/`export` all keep their native implementations on both platforms; only the failure branch changes, and it changes in one place instead of three. Non-DNG RAW stays native-only on both platforms (still dead on Windows — same as Candidate 1).

**Files that change.** New: `lib/services/image_source_chain.dart`, `test/image_source_chain_test.dart`. Edited: `lib/providers/app_state.dart` (default wiring at `:83-89`), `lib/services/image_preload_controller.dart` (delete the ad-hoc `.dng` fallback at `:651-666`, add the sidebar fallback at `:836`), `lib/services/thumbnail_export_service.dart` (`:36-41`), `lib/views/sidebar_view.dart` (cache dims), `unit_test.md`, `memory.md` (new AD). Zero C++, zero Swift.

**Work estimate.** 2–3 worker-days, essentially all of it verifiable on this macOS host with fakes plus the real samples in `local_data/photo_samples/`. Lower than my first draft precisely because the native-replacement half is gone.

**macOS perf-path regression risk — LOW.** Cutting "Dart-first" removed the two hazards that made this MEDIUM: no `File.readAsBytes` replacing a channel passthrough, so no new bytes provenance and no unmeasured IO-thread change on the hot path. Two hazards remain, both bounded:

1. **Deleting a live fallback.** `_requestPreviewBytes:651-666` is today the only thing keeping Windows DNG previews alive at all. Relocating it into the chain must preserve the `NativeImageFailure`-then-Dart ordering exactly, or Windows silently regresses to the state this whole exercise is about. Mechanically checkable: a test that a `.dng` whose loader returns `NativeImageFailure` still yields extractor bytes.
2. **Bytes identity (R-b) at the seam.** The chain returns one `Uint8List` per request and the controller stores it once (`image_preload_controller.dart:516,726`); both tier factories then key off that object (`:20-41`). A chain that re-read or re-wrapped bytes per tier would produce two keys and a silent duplicate full-frame decode — the exact failure AD-011 exists to prevent. This is a code-review invariant, not a design risk, and it is worth an explicit test that fails if a second decode appears.

macOS behaviour is otherwise unchanged by construction: every macOS request still hits the same native branch it hits today, and macOS never reaches the `NativeImageFailure` fallback for these formats.

**EXIF orientation.** Unchanged from Candidate 1 in every case; the chain only changes *who calls* the same three mechanisms (APP1 injection for extracted previews, `NO_EMBEDDED_PREVIEW` details → `decodedRgbaToImage` for decoded RAW, pixel-baking for export).

**AD-010/AD-011 freeze — NOT broken, but it is stretched and that should be an explicit decision.** Still three variants. However, `NativeImageNeedsRawDecode`'s doc comment (`native_thumbnail_service.dart:48-54`) and `kNoEmbeddedPreviewCode`'s (`:75-78`) both assert the signal is emitted by `AppDelegate.swift`. Under this candidate that stops being true. The type is unchanged; its *contract prose* must be rewritten, and the class arguably no longer belongs in a file named `native_thumbnail_service.dart`. Recommend recording this as an amendment to AD-010 rather than a break of it — but the user should confirm, because the freeze was written to stop exactly this kind of drift.

**(C4) FFI dependency — API-level check. This is the candidate that the §2.0 audit favours.** Needs: `decodeOnWorker` ✅; worker threading ✅ (already off the UI isolate, `:194-197`); orientation ✅ and — the discriminator — **sourced in Dart** via `DngPreviewExtractor.readOrientationFromFile` (`dng_preview_extractor.dart:41-48`), which is already implemented, already unit-tested, and testable on this host. Needs **no** sizing control for the main pane, for the same reason as Candidate 1. Requires **no** upstream `dng_processor_ffi` change and **no** Windows-side code at all: every dependency this candidate has on the FFI is satisfied by the API exactly as it ships today. That is the whole asymmetry — Candidates 1 and 3 need the orientation to come out of C++ that nobody here can compile; Candidate 2 reads the same IFD0 tag with Dart that already has passing tests. Residual exposure is packaging-only, with the same safe degradation as Candidate 1.

**1 s ceiling.** DNG-with-preview: same 3.79 ms median as Candidate 1, and *better* on macOS for JPEG (one fewer channel hop). DNG-without-preview on Windows: **UNKNOWN**, identical exposure to Candidate 1.

---

### Candidate 3 — **Native Parity** (each platform's runner implements the whole contract)

**The concrete failure it fixes:** the same Windows rows, but also the two cases neither other candidate fixes — **non-DNG RAW on Windows** (`.arw/.cr2/.nef/.orf/.rw2`, currently permanently unreadable, `halcyon_image.cpp:392`) and **Windows export EXIF loss** (`:333-337`).

**Shape.** Treat `halcyon/thumbnail` as a real cross-platform contract and hold each runner to it:

1. Port the TIFF/SubIFD walker to C++ in `halcyon_image.cpp` (third implementation, after `DngPreviewExtractor.swift` and `dng_preview_extractor.dart`), so Windows returns embedded-preview bytes for DNG on all three purposes and can resize them for the sidebar.
2. Emit `NO_EMBEDDED_PREVIEW` when the walker misses on `purpose == "preview"`, unlocking the FFI decoder.
3. Add a Windows RAW decode path for non-DNG RAW — realistically this means WIC's raw codec support (present for some cameras via vendor codec packs, absent otherwise) or accepting `RAW_UNSUPPORTED` for those.
4. Add EXIF carry-over to the Windows JPEG encoder: WIC supports this via `IWICMetadataBlockWriter`/`InitializeFromBlockReader`, forcing `System.Photo.Orientation = 1`.

**Serving the three purposes.** This is the only candidate that gets all three to macOS parity on Windows by construction, because the resize and the metadata copy happen in the same place they do on macOS.

**Files that change.** `windows/runner/halcyon_image.cpp` (large — the walker plus the metadata writer, ~400–600 lines), `windows/runner/halcyon_native.h`. Dart side: nothing, or nearly nothing.

**Work estimate.** 5–10 worker-days, **and essentially none of it is verifiable on the macOS host.** Every line joins the existing uncompiled pile (`halcyon_native.h:11-12`: "NOTHING IN THIS FILE OR ITS IMPLEMENTATION HAS BEEN COMPILED OR RUN"). Lesson `2026-08-16` (in-branch green proves nothing about the combination) applies with full force here.

**macOS perf-path regression risk — ZERO by construction.** No Dart, no Swift changes. This is the candidate's one strong advantage and it is a real one.

**EXIF orientation.** Entirely native, matching macOS: baked into pixels by `IWICBitmapFlipRotator` for resized outputs (already at `:338-348`), carried in the copied metadata block with Orientation forced to 1 for export.

**AD-010/AD-011 freeze — NOT broken.** No Dart type changes at all.

**(C4) FFI dependency — API-level check.** Same needs as Candidate 1 (`decodeOnWorker` ✅, threading ✅, orientation from the new C++ ⚠️ unverifiable here, no sizing needed ✅). Two API-level notes specific to this candidate: (a) with the DLL confirmed, "this candidate avoids the DLL for embedded previews" stopped being a selling point — it was only ever a hedge against a risk that no longer exists, while "400–600 lines of untestable C++" stayed a cost; (b) **step 1 may not need C++ at all.** §2.0 shows the FFI already exposes `getPreviewJpegOnWorker` (`dng_decoder_service.dart:245`), a native embedded-preview extractor Halcyon does not call. If the goal is a native Windows extractor, calling that from Dart is a two-line change instead of a TIFF walker — at which point step 1 of this candidate collapses into Candidate 2 and the only distinct content left is non-DNG RAW and the export EXIF writer. That is worth the commander knowing: **Candidate 3's unique value is narrower than its work estimate suggests.**

**1 s ceiling.** Sidebar/preview for DNG-with-preview: a C++ seek+slice, plausibly faster than Dart's 3.79 ms — but **unmeasured, and unmeasurable from here**. DNG-without-preview: same unknown DLL exposure. Export on a 25 MB DNG through WIC: unmeasured.

---

### 2.4 The duplication axis — is the second-language reimplementation a hazard or an acceptable cost?

The lead asked for an opinion on this, and it is a legitimate discriminator, so here it is stated plainly rather than hedged.

**The facts first.** Halcyon now carries the same two semantics — *EXIF-orientation handling* and *cheap-bytes passthrough* — in more than one language:

| Semantic | Implementations today |
|---|---|
| EXIF Orientation read → transform | `AppDelegate.swift:165-190` + `:451-454` (ImageIO/CIImage); `halcyon_image.cpp:118-…` + `:148` + `:338-348` (WIC); `dng_preview_extractor.dart:52-73` (IFD0 walk) + `decoded_rgba_image_provider.dart:47-138` (canvas transform). **Three.** |
| Cheap-bytes passthrough (return the file / embedded JPEG unmodified for `preview`) | `AppDelegate.swift:360-370` (JPEG) + `:371-403` (DNG); `halcyon_image.cpp:410-418` (JPEG only). **Two, and asymmetric** — Windows has no DNG half, which is precisely the gap this document is about. |
| Embedded-preview extraction (TIFF/SubIFD walk) | `macos/Runner/DngPreviewExtractor.swift`; `lib/services/dng_preview_extractor.dart` (479 lines, an explicit port); `dng_processor_ffi`'s native `getPreviewJpeg` (`:201`), uncalled. **Three, one of them unused.** |

**My opinion: the duplication is a real hazard, but *unifying it is the wrong response*, and the right response is to stop adding to it.**

The argument for hazard is concrete, not aesthetic: the asymmetry row above *is* the bug. Windows implemented one of the two passthrough halves and not the other, and nothing detected that — no test, no type, no compiler. The macOS DNG passthrough and the Windows DNG passthrough are not two copies that drifted; the second was never written, and the divergence was invisible because each runner is only checked against prose (`halcyon_native.h:57` describes the contract in a comment). Three orientation implementations means three chances for a sideways portrait photo, on three platforms, discoverable only by looking at a picture — and UI-driven verification is banned, so there is no cheap detector at all. That is a maintenance hazard by any honest reading.

But the response "unify them" (Candidate 3's implicit logic, and my first draft's) fails a cost test. Rewriting the working macOS Swift path or the working Windows WIC path buys nothing today — both produce correct pixels — and spends the scarcest resource in this project, which is *verification capacity on a host that cannot build Windows*. Deleting a working native path to reduce a count is exactly the "justify against tidiness" move the corrected contract forbids.

What actually follows is narrower and more useful: **treat the Dart layer as the place new capability goes, and let the native duplication stop growing.** Concretely — (a) do not write a fourth orientation reader or a third TIFF walker in C++ (this is a direct argument against Candidate 3 step 1, especially given `getPreviewJpegOnWorker` already exists unused); (b) when a purpose needs a fallback, put it in one Dart place that all three purposes share, which is Candidate 2's entire content; (c) leave the two existing native implementations alone and untouched. The count of duplicated semantics stops at its current value instead of rising, and no working code is disturbed. This is the single strongest argument for Candidate 2 over Candidate 1 — Candidate 1 fixes the same bugs but does so by adding a *third* passthrough branch in C++, i.e. it pays down the symptom while increasing the underlying quantity.

One honest counterweight the user should weigh: a Dart-side fallback means Windows's behaviour for DNG is assembled from a native miss plus a Dart recovery, which is harder to reason about from the C++ side alone than "the runner handles it". A reviewer who values each platform being self-explanatory in its own language will read that as a downgrade. I think it is a fair price; it is a taste call and it is the user's to make (R6.1).

### 2.5 Comparison

| | 1. Thin Seam Patch | 2. Dart Fallback Chain | 3. Native Parity |
|---|---|---|---|
| Fixes Windows DNG preview (no embedded) | ✅ | ✅ | ✅ |
| Fixes Windows DNG sidebar thumbnails | ✅ | ✅ | ✅ |
| Fixes Windows DNG export | ⚠️ needs a Dart resizer or a stated limitation | ⚠️ same | ✅ |
| Fixes Windows non-DNG RAW | ❌ | ❌ | ⚠️ only via WIC vendor codecs |
| Fixes Windows export EXIF loss | ❌ | ❌ | ✅ |
| Helps the next platform (Linux/iOS) | ❌ | ✅ | ❌ (re-do per platform) |
| Requires new C++ | ~40 lines | **none** | 400–600 lines |
| Verifiable on this macOS host | partly | **almost fully** | **almost not at all** |
| Replaces any *working* native path | no | no (after revision, §2.2) | no |
| Effect on duplicated semantics (§2.4) | +1 (third passthrough branch, in C++) | **0 (holds the line)** | +1 or +2 (fourth orientation reader, third TIFF walker) |
| macOS perf-path regression risk | LOW | LOW | **ZERO** |
| Breaks AD-010/011 freeze | no | no (prose amendment) | no |
| **(C4) FFI API dependency satisfied by today's surface** | ✅ decode/threading; ⚠️ orientation via unverifiable C++ | ✅ **all of it, in Dart** | ✅ decode/threading; ⚠️ orientation via unverifiable C++ |
| Needs a reduced-resolution decode (§2.0 — does not exist) | no | no | no |
| Residual DLL risk | packaging only | packaging only | packaging only |
| Work estimate | 1–2 d | 2–3 d | 5–10 d |

---

## 3. (C5) Recommendation, and what this analysis could not determine

### 3.1 Recommendation

**Candidate 2 (Dart Fallback Chain), with Candidate 1's `sidebar_view.dart` cache-dimension fix folded in as a prerequisite, and Candidate 3 kept in the parking lot for non-DNG RAW and the Windows export EXIF loss.**

The deciding argument is verifiability, and it is sharpened rather than weakened by both premise corrections. Every fix here has to survive a host that cannot compile, run, or measure the platform it is fixing, so the only checks that actually execute are Dart ones on macOS. Candidate 3 puts 400–600 lines of the hardest logic — a TIFF walker over untrusted bytes plus a metadata writer — into the one place nobody can test, on top of a pile of code that has never been compiled; that is precisely the soil that grew `cmake-bundled-libraries-var-silent-typo` and the `RAW_UNSUPPORTED`-vs-`NO_EMBEDDED_PREVIEW` subtlety, and §2.0 shows its step 1 may be redundant anyway since `getPreviewJpegOnWorker` already exists unused. Candidate 1 is the ponytail answer and is genuinely close: two of its three edits are the same edits Candidate 2 makes, it is a day cheaper, and if the priority is smallest-diff-ship-this-week it is the right pick and I would not argue. What tips me to Candidate 2 is three things that all point the same way. First, Candidate 1's third edit is ~40 lines of C++ that cannot be tested here and exists only to produce one integer — the EXIF orientation — which Candidate 2 reads with Dart that is already written and already has passing tests (§2.0, orientation row); the user's confirmation that the DLL decodes correctly is what turns that from "unblocks an attempt" into "ships the feature", using zero Windows-only code. Second, §2.4: Candidate 1 fixes these bugs by adding a *third* passthrough branch in a second language, while Candidate 2 fixes them by giving all three purposes the one fallback that currently exists for only one of them — same bugs closed, opposite effect on the duplication that caused them. Third, after cutting the "Dart-first" half of my own draft, Candidate 2 no longer displaces any working native path, so its macOS perf risk fell to LOW and the re-benchmarking burden I originally priced in disappeared; what remains is one code-review invariant (bytes identity, `image_preload_controller.dart:20-41`, worth a test that fails if a second decode appears) and one relocation that must preserve ordering exactly.

### 3.2 What I could NOT determine

Explicitly labelled; none of these were guessed at above.

1. **[UNKNOWN — the biggest one, and NOT closed by the 2026-08-22 confirmation] First-decode latency for a preview-less DNG on Windows.** The user confirmed the DLL produces a correct image; they did not report a timing, and "the picture appeared" is not a measurement. No Windows host is available to me. **§2.0 makes this worse, not better:** the API exposes no reduced-resolution decode, so the usual escape hatch — decode small first, refine after — does not exist, and `decodeOnWorker` re-opens the library in a fresh isolate on every call (`:283-286`). Whatever the number is, all three candidates inherit it identically and none of them can shrink it. Two further reasons it may blow the ceiling and nobody has checked: (a) the macOS-measured RAW decode was ~110 ms *after* a Halide pipeline was already warm; (b) `DngDecoderService` exposes `warmupForSize` and `setPipelineCachePath` precisely because first-run pipeline construction is expensive on some backends — and **Halcyon calls neither** (`tmp/verify/thumb-a-evidence.txt` E5, zero hits in `lib/`). Whatever candidate is chosen, the first Windows DNG decode is an unmeasured, unwarmed, uncached cold start. All three candidates carry this risk identically; none of them mitigates it. A mitigation exists (call `warmupForSize` at app start off the UI isolate) and is orthogonal to this decision.
2. **[RESOLVED 2026-08-22, was UNKNOWN] Whether the Windows DLL decodes a DNG correctly** — the user confirmed it does, on their own machine (§0.1). Two sub-questions remain open and are *not* answered by that confirmation: whether the DLL is reliably **packaged** into the built app (`cmake-bundled-libraries-var-silent-typo`), and whether the RGBA length invariant asserted at `dng_decode_service.dart:16-23` holds for all sample geometries rather than the one file that was displayed. A happy-path image also says nothing about the `timespec`/timed-wait code path the vendored SDK edits touched.
3. **[UNKNOWN] Whether `ReadExifOrientation` (`halcyon_image.cpp:118`) works on a DNG container.** It uses WIC metadata query paths documented for JPEG and TIFF; DNG *is* a TIFF, so it plausibly works, but WIC needs a decoder for the container before a metadata reader exists, and Windows may have no DNG decoder installed. This matters for Candidates 1 and 3. Falsifiable only on Windows.
4. **[UNKNOWN] Whether WIC can open a DNG at all on a stock Windows install** — i.e. whether `CreateDecoderFromFilename` (`halcyon_image.cpp:283`) would succeed for `.dng` if the RAW guard at `:392` were removed. If it can, a much cheaper Candidate 3 exists. If it cannot, the guard is load-bearing.
5. **[WITHDRAWN] `File.readAsBytes` vs channel-passthrough latency.** This was an open question against my first draft of Candidate 2. That half of the candidate is cut (§2.2 revision note), so no candidate now reads bytes in Dart on the hot path and the question no longer bears on the decision. Recorded rather than deleted so the commander can see it was resolved by scope reduction, not by measurement.
5b. **[U] Whether `warmupForSize` in its own isolate actually warms the later decode isolate.** `dng_decoder_service.dart:144-147` runs warmup inside `Isolate.run`; the neighbouring `setPipelineCachePath` comment (`:156-157`) asserts native state is process-global, which implies yes — but that is an inference from a comment about a *different* function, and it is untested on Windows. It matters because warmup is the only available mitigation for unknown #1.
5c. **[U] Whether `dng_processor_ffi`'s native `getPreviewJpeg` (`:201`) works on Windows and how it compares to the Dart extractor's 3.79 ms.** Halcyon has never called it on any platform. It is the cheap alternative to Candidate 3's C++ TIFF walker, so if the commander leans towards Candidate 3, this is the first thing to test.
6. **[UNKNOWN] HEIC availability on the user's Windows machine** (`halcyon_image.cpp:287-289`). Affects whether HEIC needs its own row in a future contract.
7. **[NOT ASSESSED] iOS, Linux, Android.** Android has no `halcyon/thumbnail` runner implementation at all, so the `MissingPluginException` clause (`native_thumbnail_service.dart:122-135`) *is* live there, and the analysis above does not cover it. It was out of scope for this task but it is the case where Candidate 2's platform-independence pays off most.
8. **[TASTE — R6.1] Whether "one Dart chain" or "each runner implements the contract" is the right long-run shape** is partly an architectural preference, not a fact. I have argued from verifiability, which is a fact-shaped argument; a reviewer who weighs "native platforms should look native" more heavily would reasonably land on Candidate 3.

---

## 4. (C6) `git status` — no platform source modified

The narrowed check — `git status --porcelain -- lib macos windows android ios linux web` — returns exactly two entries, both pre-existing:

```
 M lib/views/rename_dialog.dart            <- pre-existing user WIP (rename cron), untouched by me
 M windows/flutter/generated_plugins.cmake <- pre-existing, untouched by me
```

Both were already present in the baseline `git status` I took before reading anything, and both are recorded in the frozen contract itself (`windows-port-review-contract.md:16`) as the expected dirty state. Neither was opened for editing in this task. **No file under `lib/`, `macos/`, `windows/`, `android/`, `ios/`, `linux/`, `web/` was created or modified by me.**

New untracked entries attributable to this task: only `docs/logs/2026-08-22/thumbnail-cross-platform-analysis-a.md` (this file, inside the already-untracked `docs/logs/2026-08-22/`) and `tmp/verify/thumb-a-*.txt` (which does not appear in `git status` at all — `tmp/` is ignored). `scripts/build_apps.py` in the full listing belongs to Team A, not to me.

Full command output: `tmp/verify/thumb-a-gitstatus.txt`.
