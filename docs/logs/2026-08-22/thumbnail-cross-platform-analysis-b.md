# Cross-platform thumbnail/preview architecture — independent analysis (take B)

> Author: `arch-thumb-b-opus` (Track C, slot B). Analysis only — **no code was changed**.
> Anchor: Halcyon `main` @ `5e35d39`. Written independently of `thumbnail-cross-platform-analysis-a.md`, which was not read.
> **Revision 2 (2026-08-22)** — rewritten against the corrected Track C problem statement and the user's contract amendment (FFI decode on Windows works). Revision 1's candidate set was sized against "make thumbnails cross-platform"; this revision sizes them against the actual gap, which is one hard-coded RAW rejection.
> Evidence: `tmp/verify/thumb-b-01-windows-channel-exists.txt`, `-02-invariants.txt`, `-03-git-status.txt`, `-04-citation-check.txt`, `-05-ffi-surface.txt`.

---

## 0. Relationship to the corrected contract

I reached the corrected premise independently before the re-brief arrived (evidence: `tmp/verify/thumb-b-01-windows-channel-exists.txt`, written from `git ls-files` + `windows/runner/CMakeLists.txt:12` + `git log -- windows/runner/halcyon_image.cpp` → `2af5243`). Revision 1 of this document already located the bypass at `halcyon_image.cpp:401` and already flagged the DLL amendment. So nothing here is salvaged from the wrong premise — but the **candidate sizing** was wrong, and that is what revision 2 fixes.

One residual inconsistency in the contract, for the commander: the ground-truth table (line 21) and the Track C problem statement (lines 95-110) are corrected, but the **C4 text at line 124 still reads "which is currently unverified"**. I have written to the amended C4 the team lead sent (API-level dependency check), not to line 124.

---

## 1. (C1) Current call graph — matrix

### 1.0 Shared prefix, identical on both platforms

**Preview** (the `app_state.dart:86` entry named in the task):

| # | Hop | File:line |
|---|---|---|
| 1 | `AppState.selectItem` | `lib/providers/app_state.dart:291` |
| 2 | `AppState._preloadImages` | `lib/providers/app_state.dart:379` |
| 3 | `ImagePreloadController.preloadImages` | `lib/services/image_preload_controller.dart:253` |
| 4 | `_loadPreview` | `lib/services/image_preload_controller.dart:670` |
| 5 | `_requestPreviewBytes` | `lib/services/image_preload_controller.dart:631` |
| 6 | `_imageLoader` — the closure injected at the constructor | `lib/providers/app_state.dart:83-89` (**`:86` is `NativeThumbnailService.requestImage`**) |
| 7 | `NativeThumbnailService.requestImage` | `lib/services/native_thumbnail_service.dart:97` |
| 8 | `MethodChannel('halcyon/thumbnail').invokeMethod('getThumbnail', {...})` | `native_thumbnail_service.dart:87`, `:104-109` |

**Sidebar thumbnail**: `SidebarView._noteBuiltIndex` (`lib/views/sidebar_view.dart:69-101`, itemBuilder-driven per AD-014) → `AppState.preloadThumbnails` (`app_state.dart:392`) → `ImagePreloadController.preloadThumbnails` (`image_preload_controller.dart:773`; 100 ms debounce `:792`, generation guard `:813`, ±20 prefetch `:802`) → `_imageLoader(..., purpose: sidebarThumbnail)` (`:830-833`) → hops 7-8. Display: `app_state.dart:192` → `sidebar_view.dart:260` → `Image.memory` (`:273`).

**Export**: `ThumbnailExportService.exportStarred` (`thumbnail_export_service.dart:61`; 4 concurrent workers `:47`, `:111-112`) → `_defaultFetch` (`:36-41`) → `NativeThumbnailService.getThumbnail` (`native_thumbnail_service.dart:143`, **always `allowRawDecodeSignal: false`** `:152`) → hops 7-8 → `File(outPath).writeAsBytes` (`thumbnail_export_service.dart:100`).

**Display tail (preview)**: `AppState.currentImageBytes` / `currentDecodedProvider` / `currentItemHasFullSize` / `currentItemFailed` (`app_state.dart:177`, `:185`, `:198`, `:190`) → provider selection `main_detail_view.dart:277-285` → `Image(gaplessPlayback: true)` `:293-300`. Tier-1 precache ±2 (`image_preload_controller.dart:582-611`, factory `:25`); tier-2 precache ±1 after 250 ms quiet (`:46`, `:341`, `:349`, `:520`, factory `:41`); raw-decode branch `:362-367` → `_startRawDecode:434` → `_runRawDecode:452` → `halcyonDngFullDecoder` (`dng_decode_service.dart:34`) → `DngDecoderService.decodeOnWorker` → `decodedRgbaToImage` (`decoded_rgba_image_provider.dart:21`) → `applyExifOrientation` (`:47`) → `DecodedRgbaImageProvider` (`:158`).

Decoder is injected unconditionally on every platform at `lib/main.dart:24-25`. **On Windows `_dngDecoder` is non-null**; the only reason no RAW decode happens is that `NativeImageNeedsRawDecode` never arrives.

### 1.1 Matrix — `preview` (2800 px)

| Case | macOS | Windows |
|---|---|---|
| **JPEG** | `AppDelegate.swift:360-370` returns original file bytes verbatim; dispatch `:405-412`. Flutter honours the JPEG's own EXIF orientation. **Works.** | `halcyon_image.cpp:410-418` — same passthrough via `ReadWholeFile`. **Works.** |
| **DNG with embedded preview** | `AppDelegate.swift:371-376` → Swift `extractFullSizeEmbeddedJpeg` → passthrough `:405-412`. **Works.** | Short-circuits at `halcyon_image.cpp:392-403` → `PlatformException("RAW_UNSUPPORTED")` → `native_thumbnail_service.dart:120-121` → `NativeImageFailure`. **Rescued in Dart** at `image_preload_controller.dart:659-665` → `DngPreviewExtractor.extractFullSizeEmbeddedJpegFromFile` (`:661`). **Works** — median 4.49 ms, max 8.56 ms (measured in `8ef9bc7`). |
| **DNG without embedded preview** | `AppDelegate.swift:388-401` emits `FlutterError("NO_EMBEDDED_PREVIEW", details: orientation)` → `native_thumbnail_service.dart:115-118` → `NativeImageNeedsRawDecode` → `_needsRawDecode[id]` (`:649`) → tier-2 `:362-367` → FFI decode. **Works.** | Short-circuits at `:392-403`. Dart rescue runs, returns `null` (no qualifying SubIFD), `_requestPreviewBytes` returns `null` (`:666`) → `_loadPreview:727-732` → `_failedIds` → error state. **DEAD — this is the gap.** |
| **Non-DNG RAW** (`.arw/.cr2/.nef/.orf/.rw2`) | `AppDelegate.swift:426-470` — embedded thumb, else `CIFilter(imageURL:)` render `:449-458`. **Works** (but see memory `cirawfilter-ignores-targetsize`: always full-res, ignores `targetSize`). | Short-circuits at `:392-403`. The Dart rescue at `:659` is gated on `.dng`, so **no fallback**. **DEAD.** |

### 1.2 Matrix — `sidebarThumbnail` (200 px)

| Case | macOS | Windows |
|---|---|---|
| **JPEG** | `isPreviewRequest == false` → no passthrough → `AppDelegate.swift:475-486` `CreateThumbnailAtIndex` (`FromImageIfAbsent: true`, `MaxPixelSize: 200`, `WithTransform: true`) → re-encode `:501-502`. **Works.** | `halcyon_image.cpp:420-421` → `DecodeAndReencode` → scale `:312-331`, orientation baked `:338-348`, re-encode `:363`. **Works.** |
| **DNG with embedded preview** | `:426-442`, accepted because `targetSize <= 256` (`:439`). **Works.** | Short-circuits at `:392-403`. `preloadThumbnails` has **no Dart fallback at all** — `image_preload_controller.dart:836` is a bare `if (result is NativeImageBytes)` and drops everything else. **DEAD, and silent** (`_failedIds` is never populated from this path, so there is not even an error marker). |
| **DNG without embedded preview** | Falls to `:479-485` `FromImageIfAbsent: true` → ImageIO decodes the mosaic for a 200 px thumb. Slow but **works**. | **DEAD, silent.** |
| **Non-DNG RAW** | As above. **Works.** | **DEAD, silent.** |

### 1.3 Matrix — `export` (2048 px, EXIF carry-over, Orientation forced to 1)

| Case | macOS | Windows |
|---|---|---|
| **JPEG** | `AppDelegate.swift:329-345` terminal branch → `makeExportJpeg:291` (`CreateThumbnailFromImageAlways: true`, `:239`) → `encodeExportJpeg:254` copies the **whole** source property dictionary (`:265`) and forces `Orientation = 1` in both top-level (`:266`) and TIFF (`:271`) dicts. **Fully correct.** | `purpose == "export"` is not `"preview"`, so the passthrough at `:410` is skipped and `DecodeAndReencode(path, 2048)` runs. Pixels correct (scaled + rotated). **But `EncodeJpeg` (`halcyon_image.cpp:171-272`) writes pixels only — no metadata block is copied.** Every EXIF tag is silently dropped. **Partially broken, silently — a shipping data-loss bug independent of the RAW gap.** |
| **DNG w/ preview** | Export branch → ImageIO. **Works.** | Short-circuits at `:392-403` → `getThumbnail` returns `null` (`native_thumbnail_service.dart:154`) → `thumbnail_export_service.dart:93-95` throws → recorded in `failures`. **DEAD (loud).** |
| **DNG w/o preview** | **Works.** | **DEAD (loud).** |
| **Non-DNG RAW** | **Works.** | **DEAD (loud).** |

### 1.4 The gap, stated exactly

One branch — `windows/runner/halcyon_image.cpp:392-403` — fires before purpose dispatch and before any decode, for six extensions, across three purposes. Everything non-RAW on Windows works through WIC. The consequences ranked by user-visible severity:

1. **Silent**: every RAW row in the Windows sidebar is blank with no error marker (§1.2). Worst, because it looks like a broken app.
2. **Hard-dead**: DNG-without-preview and all non-DNG RAW previews (§1.1).
3. **Loud-dead**: all RAW export (§1.3).
4. **Separate, silent, non-RAW**: Windows JPEG export strips all EXIF (§1.3). Not caused by `:392`; needs its own fix regardless of which candidate wins.

---

## 2. Invariants any candidate must not break

Re-verified mechanically; raw output in `tmp/verify/thumb-b-02-invariants.txt`.

| # | Invariant | Source | How it breaks |
|---|---|---|---|
| I1 | **Zero `Platform.is*` / `defaultTargetPlatform` in `lib/services/` + `lib/providers/`** (grep exit 1, 0 hits) | R1 contract AC3 | Any pipeline-level platform branch. `main.dart` is the only legal site. |
| I2 | **`NativeImageResult` has exactly 3 subclasses** (`grep -c` = 3) | AD-010/AD-011, `native_thumbnail_service.dart:30-38` | A 4th variant, or splitting the type per purpose. |
| I3 | **Tier-1/tier-2 `ImageProvider` keys are identity-keyed on the `bytes` object**; display and precache must pass the *same* `Uint8List` and the *same* width/height | `image_preload_controller.dart:20-41`, `:196`, `:376-378`; `main_detail_view.dart:251-285` | Returning a *new* `Uint8List` per read (re-slice, re-encode, defensive `Uint8List.fromList`) rather than storing exactly one object in `_imageCache[id]`. Failure mode is **silent duplicate full-frame decodes**, not an error. |
| I4 | `DecodedRgbaImageProvider` equality is identity on its `ui.Image`; the controller owns the ~50 MB master handle | `decoded_rgba_image_provider.dart:186-195`, `image_preload_controller.dart:547-575` | Constructing providers at the display site. |
| I5 | `tierTwoNavigationDebounce` ordering is load-bearing for image lifetime | `image_preload_controller.dart:405-420` (the only written warning) | Making the tier-2 sweep synchronous or racing the preload pass. |
| I6 | A raw item is requested from the native loader **exactly once** — `_needsRawDecode` must not be cleared on success | `image_preload_controller.dart:397-404`, `:687` | A router that re-probes on every navigation. |
| I7 | Sidebar thumbnails are itemBuilder-driven with a 100 ms debounce + generation guard | AD-014 / G-001 | A fallback slow enough to outlive its generation every sweep. |

---

## 3. The `dng_processor` FFI surface — API-level facts (feeds C4)

The decoder's *correctness* is settled (user-confirmed). What matters now is whether its **API shape** can serve what each candidate asks of it. Raw notes in `tmp/verify/thumb-b-05-ffi-surface.txt`.

| Axis | What the surface actually exposes | Consequence |
|---|---|---|
| **Decode entry point** | `decodeOnWorker(String filePath) → Future<DngImage>` (`dng_decoder_service.dart:194`). That is the only decode API Halcyon uses. | — |
| **Sizing control** | **NONE.** `decodeOnWorker` takes a path and nothing else; `DngImage` returns full-resolution `rgbaData` (`:28-36`). `warmupForSize({width, height})` (`:143`) sizes *warmup*, not output. | **There is no way to ask the decoder for a 200 px thumbnail.** A bare-CFA DNG sidebar row costs a full ~50 MB decode under any candidate that routes the sidebar through FFI. This is the single hardest API-level constraint in this analysis. |
| **Orientation** | **NONE.** The decoder deliberately does not read or apply EXIF Orientation; Halcyon must (`decoded_rgba_image_provider.dart:13-16`). Halcyon gets the value from the native channel on macOS, and would need `DngPreviewExtractor.readOrientationFromFile` (`dng_preview_extractor.dart:41`, **currently unused in production**) elsewhere. | Any candidate that lights up FFI decode on Windows must also source the orientation value there. The Dart function already exists. |
| **Threading** | `decodeOnWorker` spawns a **fresh `Isolate.run` per call** (`:195`), and inside it `_decodeFileToTransferable:284` constructs a **new `DngDecoderService()..initialize()`**, i.e. a fresh `DynamicLibrary.load()` per decode. Native state is process-global (`:156-157`). | Per-decode isolate + library-load overhead on every photo. Also: `ThumbnailExportService` runs 4 concurrent workers (`:47`, `:111-112`), so RAW export = 4 simultaneous full-resolution native decodes. |
| **Warmup** | `warmupForSize` exists (`:143`) and **Halcyon never calls it** (grep over `lib/` + `test/`: only `dng_decode_service.dart:13` touches `DngDecoderService`, and it only constructs + `decodeOnWorker`). | Every first decode pays cold pipeline setup. Directly implicated in the 1 s ceiling. |
| **Pipeline cache** | `setPipelineCachePath` (`:161`) / `savePipelineCache` (`:174`) / `pipelineCacheStatus` (`:182`) exist and are documented as **Vulkan-applicable**. The Windows build uses the **Vulkan** backend (`CMakePresets.json:50-52`, `windows-vulkan`). **Halcyon never calls any of them.** | A cross-launch VkPipelineCache is available on Windows and is being left on the table. The R2 handover's P3 item ("首次解碼 >1s → VkPipelineCache 泛化輪") anticipated needing a large upstream change; **the Dart-side call is a one-liner that was simply never made.** Whether the shipped DLL was built with `DNG_VK_PIPELINE_CACHE=ON` is **[U]**. |
| **Embedded-preview extraction** | `getPreviewJpeg` (`:201`) / `getPreviewJpegOnWorker` (`:245`) exist — a **third** implementation of embedded-JPEG extraction. Halcyon never calls them. | Not needed: the Dart one is faster to reach (no isolate, no library load) and already measured. Noted because it feeds §5. |

**Two findings above are free wins on the 1-second question, independent of which candidate is chosen**: nobody is calling `warmupForSize`, and nobody is calling `setPipelineCachePath` on a Vulkan build. Both are Dart-side one-liners at the composition root (`lib/main.dart`).

---

## 4. (C2/C3/C4) Candidates, sized to the gap

### Candidate A — `DartRawRouter`: route RAW in Dart, leave both native paths alone

**Concrete failures fixed:** §1.4 items 1 and 2 for DNG (silent blank sidebar; dead DNG-without-preview preview).

**Shape.** The rescue logic that exists today for exactly one purpose (`image_preload_controller.dart:659-665`) becomes a small shared router used by the preview *and* thumbnail paths. On `NativeImageFailure` only — native stays the first and preferred source on both platforms:

1. `.dng` → `DngPreviewExtractor.extractFullSizeEmbeddedJpegFromFile` (`dng_preview_extractor.dart:26`) → `NativeImageBytes`.
2. `.dng`, extraction returned null, purpose == `preview` → **synthesise `NativeImageNeedsRawDecode(exifOrientation: await DngPreviewExtractor.readOrientationFromFile(path))`**. `readOrientationFromFile` (`:41`) already exists and is unused. This is the whole fix for §1.4 item 2: it re-lights the existing `DngFullDecoder` chain with no native change and no new type.
3. Otherwise → `NativeImageFailure` unchanged.

**Three purposes.**
- `preview`: rungs 1-2. No macOS change (native succeeds first).
- `sidebarThumbnail`: rung 1 only. Returns the *full-size* embedded JPEG, so `sidebar_view.dart:273` changes from `Image.memory(bytes)` to `Image(image: ResizeImage(MemoryImage(bytes), width: 200))`. **Prerequisite, not optional:** `extractFullSizeEmbeddedJpegFromFile` does `File(path).readAsBytes()` (`:30`) — it reads the **entire** DNG (25-60 MB) to slice out the preview. Across a 41-row sweep that is 1-2 GB of reads. The 4.49 ms median is one warm file on a macOS SSD, not a sweep budget. Add a `RandomAccessFile` byte-range variant before enabling this rung; otherwise ship rung 1 for `preview` only. Rung 2 is deliberately **not** offered for the sidebar — see the sizing row in §3.
- `export`: **not addressed.** Rung 1 would emit a full-size embedded JPEG, which is neither 2048 px nor an EXIF-carried-over-with-Orientation-1 file. Leave `thumbnail_export_service.dart` untouched; §1.4 items 3 and 4 stay open.

**Files.** New `lib/services/raw_source_router.dart`. Modified: `image_preload_controller.dart` (`_requestPreviewBytes:631-668` body; router call at `:830`), `dng_preview_extractor.dart` (byte-range variant, if the sidebar rung ships), `sidebar_view.dart:273`, tests, `unit_test.md`.

**Work.** 1 round, ~250-400 net lines with tests. Fully unit-testable on this host through the `ImageBytesLoader` / `DngFullDecoder` seams.

**macOS regression risk — low.** Native remains rung 0, so every currently-succeeding macOS path takes a byte-identical branch. Specific hazards: **I3** — the router must return exactly one `Uint8List` and `_loadPreview:726` must store that same object; no copying on the way out. **I6** — call only from `_requestPreviewBytes`, behind the `:687` early return. **I7** — re-check the generation guard *after* the slower Dart rung, not only after the channel call.

**EXIF orientation.** DNG embedded → injected by `dng_preview_extractor.dart:208-211`/`:232`, honoured by Flutter's JPEG decoder. Raw decode → applied at `decoded_rgba_image_provider.dart:21`/`:47` from the value rung 2 reads. Non-RAW Windows → baked into pixels by WIC (`halcyon_image.cpp:338-348`). Unchanged everywhere.

**(C3) AD-010/AD-011:** **not broken.** Three variants intact; only the *constructor* of `NativeImageNeedsRawDecode` moves from a translated native error code into Dart. Arguably what the seam was for.

**(C4) FFI dependency, API-level:**
- *Needs:* a full-resolution decode from a path (rung 2 only). **Satisfied** — `decodeOnWorker(String)` is exactly that shape.
- *Needs:* an orientation value the decoder does not supply. **Satisfied outside the FFI** by `readOrientationFromFile` (`dng_preview_extractor.dart:41`).
- *Does not need:* sizing control — the sidebar rung deliberately never reaches FFI, so the missing target-size parameter is **not** a blocker for this candidate. This is the main reason A survives the API check intact.
- *Threading:* one decode per selected photo, serialised by the tier-2 ±1 window and the 250 ms debounce (`:341`, `:354-355`). No concurrency pressure.
- *Packaging (still in scope per the amendment):* the DLL is absent from `dng_processor_ffi/windows/Libraries/` on `main` and committed `generated_plugins.cmake` has an empty `FLUTTER_FFI_PLUGIN_LIST`; both land via the branches named in the contract's merge-order precondition. Until then rung 2 throws, and `_runRawDecode:482-490` degrades correctly. **Rung 1 — the silent-blank-sidebar fix, the worst symptom — lands regardless.**

**1 s ceiling (DNG-without-preview, Windows):** ~5 ms Dart parse, then `decodeOnWorker`. Wall-clock **unmeasured** (W14 never ran). But A is the candidate that can most cheaply *improve* it: add `warmupForSize` + `setPipelineCachePath` at `main.dart` in the same round (§3).

---

### Candidate B — `NativeSignalFix`: make the Windows RAW branch purpose-aware

**Concrete failures fixed:** §1.4 item 2 for DNG, natively and symmetrically with macOS. Optionally items 1 and 3 if extended.

**Shape.** Replace the blanket refusal at `halcyon_image.cpp:392-403` with a narrow branch. Minimum viable version, for `.dng` + `purpose == "preview"` only:

1. Attempt embedded-JPEG extraction in C++ (parity with `AppDelegate.swift:371-376`), returning bytes if found.
2. On a miss, and when `allowRawDecodeSignal` is true — a value currently parsed then **discarded** (`halcyon_channels.cpp:91-94`) — return `result->Error("NO_EMBEDDED_PREVIEW", msg, EncodableValue(orientation))`.
3. Keep rejecting everything else.

Two details that will bite:
- `halcyon_channels.cpp:98-99` currently always puts the **path** in `details`. The `NO_EMBEDDED_PREVIEW` case must put the **int orientation** there, because `_parseOrientation` (`native_thumbnail_service.dart:159-162`) silently degrades any non-int to 1 — a wrong-but-plausible portrait render, not an error.
- Getting that orientation in C++ needs either a hand-written TIFF/IFD walk (a **fourth** copy of logic that already exists twice in this repo — §5) or `ReadExifOrientation` (`halcyon_image.cpp:118`) via WIC's `/ifd/{ushort=274}` query, which requires WIC to open a `.dng` at all. DNG is TIFF-EP, so the TIFF codec *may* handle it, but this is **[U]** and unverifiable from a macOS host.

Extending B to also fix the sidebar means giving Windows a RAW thumbnail source, i.e. a WIC RAW decode — which depends on whether the target machine has the (optional) Microsoft Raw Image Extension installed. **[U]**, and a second unverified dependency.

**Files.** `windows/runner/halcyon_image.cpp`, `halcyon_native.h`, `halcyon_channels.cpp`. Zero Dart changes.

**Work.** ~40-80 lines for the minimum version; more if the embedded extractor is hand-written. Authoring is cheap; the cost is **wall-clock**, not lines: nothing here can be compiled, run, or tested on this host, so each iteration costs a user-machine round-trip. The file already carries an "UNCOMPILED AND UNTESTED" banner (`:3-6`) and documents that its own orientation cases 2/4/5/7 are unverified (`:141-147`).

**macOS regression risk:** zero — no shared code, no Dart change.

**Three purposes.** `preview` fixed for DNG. `sidebarThumbnail` and `export` remain dead for RAW unless B is extended into the larger WIC work, which is where revision 1's cost estimate came from and which the corrected scope no longer justifies on its own.

**EXIF orientation.** Unchanged for existing paths; the new branch must supply the orientation int (see above).

**(C3) AD-010/AD-011:** **not broken.** This is the candidate the seam was designed for — native emits the code, Dart translates it.

**(C4) FFI dependency, API-level:**
- *Needs:* exactly the same thing A does — `decodeOnWorker(String)` for the full decode. **Satisfied.**
- *Difference from A:* the orientation is sourced in C++ instead of Dart, which is the strictly harder of the two (**[U]** whether WIC opens a DNG; the Dart function already exists and is tested).
- *Sizing / threading:* identical to A for the minimum version.
- **Net:** B's FFI dependency is satisfied, but B pays for a native round-trip to obtain a signal that Dart can already synthesise for free.

**1 s ceiling:** identical to A for the minimum version. If extended to the sidebar via WIC RAW, the risk grows sharply — that path would run for 41 rows per sweep, and RAW decode through the Raw Image Extension is commonly hundreds of ms to seconds per file. **[U] and structurally the most likely to breach.**

---

### Candidate C — `UnifiedRawPolicy`: RAW belongs to Dart + FFI on every platform

This candidate **replaces working native paths**, so per the corrected scope it must justify that against concrete failures rather than symmetry. The concrete list:

1. **Two implementations of the same byte parser.** `macos/Runner/DngPreviewExtractor.swift` (348 lines) and `lib/services/dng_preview_extractor.dart` (479 lines) are a deliberate byte-for-byte port, parity-verified **once** across 14 samples in `8ef9bc7` and never since. Drift is silent by construction.
2. **`CIRAWFilter` ignores `targetSize`.** Memory `cirawfilter-ignores-targetsize`: macOS RAW preview is always decoded full-resolution regardless of the 2800 px cap, at ~10× the memory. That is a real open defect on the *macOS* path, and this candidate is the only one that removes it.
3. **Four EXIF-orientation implementations across three languages** (§5) — one of which self-declares unverified branches.
4. macOS **already** routes DNG-without-preview to the FFI decoder (`:388-401` → `NativeImageNeedsRawDecode` → `decodeOnWorker`). This candidate finishes a migration that is half-done, rather than starting one.

**Shape.** Draw the line at "the OS gives it to you for free" vs "it is RAW": the native channel keeps JPEG/PNG/HEIC on both platforms (fast, correct, cheap, already working); **all** RAW routing moves to Dart + FFI on both platforms. `AppDelegate.swift`'s RAW branches (`:371-403`, `:426-470`) and `DngPreviewExtractor.swift` get deleted; `halcyon_image.cpp:392-403` stops being a special case and becomes the same "not my job" answer on both platforms.

**Files.** `lib/services/raw_source_router.dart` (as in A, but now the sole RAW path), `image_preload_controller.dart`, `thumbnail_export_service.dart`, `sidebar_view.dart`, `macos/Runner/AppDelegate.swift` (**deletions**), `macos/Runner/DngPreviewExtractor.swift` (**delete, 348 lines**), `windows/runner/halcyon_image.cpp` (simplify), plus tests and a new AD in `memory.md`.

**Work.** 3+ rounds, and it is the only candidate that requires re-verifying the tier-1/tier-2 perf path end-to-end on macOS — the path the contract calls "already-verified".

**macOS regression risk — highest of the three, by a wide margin.** It changes the macOS RAW path, which today works. Two specific hazards: **I3**, if the Dart RAW path ever hands back a different `Uint8List` than the one `_imageCache[id]` holds; and the loss of ImageIO's free RAW *thumbnail*, which is what makes the macOS sidebar work for bare-CFA DNGs today (`AppDelegate.swift:479-485`).

**(C3) AD-010/AD-011:** **not broken** in this formulation (unlike revision 1's port-splitting design, which did break it — I withdrew that shape as unjustifiable under the corrected scope). Three variants intact.

**(C4) FFI dependency, API-level — this is where the candidate fails today:**
- *Needs:* full-resolution decode from a path. **Satisfied.**
- *Needs:* **a sized decode for the 200 px sidebar, on both platforms.** **NOT SATISFIED.** `decodeOnWorker(String)` has no target-size parameter and `DngImage` is always full-resolution (§3). Today macOS hides this because ImageIO produces a cheap 200 px RAW thumbnail; deleting that path and routing the sidebar through FFI would mean a ~50 MB full decode **per sidebar row on macOS too** — turning a working path into a memory and latency problem. That is a regression, not a trade-off.
- *Needs:* orientation. Satisfied in Dart (`readOrientationFromFile`).
- *Threading:* would put RAW export's 4 concurrent workers (`thumbnail_export_service.dart:47`) onto 4 simultaneous full-resolution native decodes on both platforms.
- **Verdict:** C is blocked on an **upstream** change — `dng_processor_ffi` gaining a target-size decode entry point (and ideally an embedded-preview-or-decode combined call). That is a feature request against `flutter_dng_decoder`, not a Halcyon refactor. Until it exists, C should not be started.

**1 s ceiling:** same as A for preview. For the sidebar it would be far worse on both platforms, per the sizing gap above.

---

### Side-by-side

| | A `DartRawRouter` | B `NativeSignalFix` | C `UnifiedRawPolicy` |
|---|---|---|---|
| Fixes silent blank Windows RAW sidebar (§1.4 #1) | ✅ for DNG, with the byte-range prerequisite | ❌ (unless extended into WIC RAW) | ✅ but at ~50 MB/row |
| Fixes dead Windows DNG-without-preview (§1.4 #2) | ✅ | ✅ | ✅ |
| Fixes non-DNG RAW on Windows | ❌ no Dart extractor for `.arw/.cr2/…` | ⚠️ only if a WIC RAW codec is installed **[U]** | ❌ same as A |
| Fixes RAW export (§1.4 #3) | ❌ | ❌ (minimum version) | ✅ |
| Fixes Windows JPEG export EXIF loss (§1.4 #4) | ❌ | ❌ | ❌ — needs its own ticket either way |
| Breaks AD-010/011 | No | No | No |
| Needs a Windows toolchain to author | No | **Yes — blind-authored** | Partly |
| Testable on this macOS host | **Fully** | **Not at all** | Fully (Dart side) |
| FFI API check | **Passes** | Passes | **Fails — no sizing control** |
| macOS regression risk | Low | None | **Highest** |
| Rounds | 1 | 1 + N user round-trips | 3+ upstream-blocked |

---

## 5. The duplication axis — is the second-language reimplementation a hazard?

The lead asked for an opinion. Here is the actual inventory.

**EXIF orientation — 4 implementations, 3 languages:**

| # | Where | Mechanism |
|---|---|---|
| 1 | Swift | `kCGImageSourceCreateThumbnailWithTransform` (`AppDelegate.swift:432`, `:482`), `oriented(forExifOrientation:)` (`:454`), export forces 1 (`:266`, `:271`) |
| 2 | Dart, metadata | `_injectExifOrientation` (`dng_preview_extractor.dart:232`) — writes an APP1 block so Flutter's decoder rotates |
| 3 | Dart, pixels | `applyExifOrientation` / `_ExifTransform` (`decoded_rgba_image_provider.dart:47`, `:126`) |
| 4 | C++ | `TransformForOrientation` (`halcyon_image.cpp:148`) + `IWICBitmapFlipRotator` (`:340`) |

Only #3 has unit tests. #4 self-declares that the flip+rotate composition order for orientations 2/4/5/7 was never confirmed (`:141-147`).

**Embedded-DNG-JPEG extraction — 3 implementations, 3 languages:** Swift `DngPreviewExtractor.swift` (348 lines); Dart `dng_preview_extractor.dart` (479 lines); and a third inside the FFI DLL (`getPreviewJpeg` / `getPreviewJpegOnWorker`, `dng_decoder_service.dart:201`, `:245`) that Halcyon never calls.

**JPEG passthrough — 2 implementations:** `AppDelegate.swift:360-370` and `halcyon_image.cpp:410-418`. ~10 lines each.

**Opinion, in three parts:**

1. **The passthrough duplication is fine. Leave it.** Ten lines of "read the file and return the bytes" in each platform's own idiom is cheaper than any abstraction that would unify it. There is no plausible drift that produces a wrong result.

2. **The orientation duplication is the real hazard, but the fix is tests, not architecture.** Four implementations is genuinely too many, and one of them is *known* to be unverified on the exact cases (mirrored orientations) that are rarest in the wild and therefore least likely to be caught by use. But note what would actually go wrong: a photo renders sideways. That is visible, reported instantly, and cheap to fix at the table (`halcyon_image.cpp:148`'s switch is deliberately written as "the single place to fix"). Restructuring the architecture to have one orientation implementation would mean owning pixel transforms in Dart for *every* path — which is candidate C, at candidate C's price. **My recommendation is to close this with a table-driven unit test over all 8 orientation values on the two Dart implementations (#2, #3), and to treat #4 as needing one manual check per mirrored case on the user's Windows machine — not to unify it.**

3. **The extraction duplication is the one worth acting on, and the action is deletion, not unification.** The Dart implementation is a byte-for-byte port of the Swift one, is parity-verified across 14 real samples, is measured (4.49 ms median / 8.56 ms max), and is *already* the Windows path. The Swift one exists only because it predates the Dart one. **`macos/Runner/AppDelegate.swift:371-403` could call into the Dart extractor's result instead — i.e. macOS stops extracting natively — and `macos/Runner/DngPreviewExtractor.swift` (348 lines) gets deleted.** The concrete failure this fixes is the silent-drift risk in item 1 above; the concrete cost is that macOS's DNG preview would move from a native file-read to a Dart file-read, which the measurement suggests is comparable but which is **[U]** until measured on the macOS path specifically. This is a small, separable ticket that does not require A, B or C, and I would put it behind A in priority. It is worth surfacing precisely because it is the *opposite* of what "reduce duplication" usually costs — here it is a net deletion.

---

## 6. (C5) Recommendation

**Do candidate A, and in the same round make the two free FFI calls nobody is making. Do not start B. Do not start C until the FFI gains a sized decode. Track the Windows export EXIF loss and the Swift-extractor deletion as two separate small tickets.**

A is the only candidate that survives the API-level FFI check intact, and it survives precisely because it never asks the FFI for something the FFI cannot do — it routes the sidebar through the pure-Dart extractor and reserves `decodeOnWorker` for the one case that genuinely needs a full decode. It fixes the worst symptom (a silently blank Windows RAW sidebar) with code already in the tree and no dependency on the DLL being packaged yet; it fixes the headline gap by *constructing* `NativeImageNeedsRawDecode` in Dart instead of asking C++ to signal it; it needs no Windows toolchain and is fully testable on this host; and it cannot regress macOS because the native channel stays the first source everywhere. B buys the same headline fix by writing blind C++ to obtain a signal Dart can synthesise for free, and its harder half (getting an orientation int out of WIC for a `.dng`) is unverifiable from here. C is the right long-term shape and is the only candidate that would fix the genuine macOS `CIRAWFilter` full-res defect — but it is blocked on an upstream API that does not exist, and routing a 200 px sidebar row through a 50 MB full-resolution decode is a regression, not a trade-off. Separately, and regardless of the choice: **`warmupForSize` and `setPipelineCachePath` are both available, both applicable to the Windows Vulkan build, and both never called** — two one-liners at `lib/main.dart` aimed squarely at the 1-second first-decode question that the R2 handover expected to cost a whole upstream round.

### What this analysis could NOT determine

1. **Windows first-decode wall-clock for a DNG-without-preview.** W14 never ran (`windows-ffi-r2-handover.md` §2 `[W] 未動`). The 1 s ceiling is **unmeasured, not met** — identical across all three candidates. Measure it before shipping any of them, and measure it again after the warmup/pipeline-cache calls in §3.
2. **Whether the shipped Windows DLL was built with `DNG_VK_PIPELINE_CACHE=ON`.** If not, `setPipelineCachePath` returns -1 and that half of the free win evaporates.
3. **Whether WIC can open a `.dng` at all** (candidate B's orientation read, and any WIC RAW extension of it). DNG is TIFF-EP so the TIFF codec may take it, but this is unverifiable from a macOS host.
4. **Whether the target Windows machine has a WIC RAW codec installed** (Microsoft Raw Image Extension is an optional Store package). B's sidebar extension could be a no-op there.
5. **Correctness of `TransformForOrientation` cases 2/4/5/7 on Windows** (`halcyon_image.cpp:141-147` self-declares this). Affects the **already-shipping** Windows JPEG path regardless of candidate.
6. **Cost of `DngPreviewExtractor` over a 41-row sidebar sweep on Windows disk.** The 4.49 ms median is one warm file on a macOS SSD, and the function reads the whole DNG (`dng_preview_extractor.dart:30`). I treat the byte-range rewrite as a prerequisite, but that judgement is unmeasured.
7. **Cost of moving macOS's DNG extraction to Dart** (§5 item 3) — the deletion is attractive but the macOS-path measurement was not run.
8. **Whether the vendored `dng_timespec` removal is safe under concurrency.** RAW export would run 4 simultaneous `decodeOnWorker` calls (`thumbnail_export_service.dart:47`, `:111-112`); the user's confirmation covers happy-path display, which does not exercise timed-wait / condition-variable paths. Track B owns this; it gates any Windows RAW export.
9. **Whether the user counts a progress-reported batch export as a "user-visible operation"** for the 1 s rule. Changes how §1.4 item 3 should be prioritised; only the user can settle it.

---

## 7. (C6) `git status` — no platform source modified

Full output in `tmp/verify/thumb-b-03-git-status.txt`. The two mechanical checks that matter:

```
$ git diff --stat -- lib/ macos/ windows/ android/ ios/ linux/ web/
 lib/views/rename_dialog.dart            | 660 +++++...   <- pre-existing user WIP
 windows/flutter/generated_plugins.cmake |   1 +          <- pre-existing user WIP

$ git ls-files --others --exclude-standard -- lib/ macos/ windows/ android/ ios/ linux/ web/
(empty)
```

Both `M` entries were present in the session-start snapshot before I did anything and are recorded as pre-existing user WIP in the contract (§Shared ground truth, "Dirty working tree"). No file under `lib/`, `macos/`, `windows/`, `android/`, `ios/`, `linux/` or `web/` was created, modified or deleted by me. My only writes are this document and `tmp/verify/thumb-b-*` (gitignored via `.gitignore:36`). `/Users/jhangyu/project/flutter_dng_decoder` was read-only throughout.
