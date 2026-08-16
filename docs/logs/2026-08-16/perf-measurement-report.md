# Halcyon — "next photo" switch latency: measurement report

Date: 2026-08-16 · Baseline commit: `7c33194` (tracked tree clean, instrumentation reverted)
Author: perf-probe (analysis only — no optimisation implemented)

## TL;DR

The switch latency is **Flutter engine JPEG decode of the full-resolution image**, and
nothing else comes close.

| build | median | p95 | of which decode |
|---|---|---|---|
| Profile (AOT) | **127.5 ms** | 143.6 ms | 124.1 ms (**97 %**) |
| Debug (JIT — what the user ran) | **165.1 ms** | 197.9 ms | 121.3 ms (73 %) |

The two optimisations that just landed (e64b7aa, adfa624) worked: the native side is now
**0.6 ms** per JPEG and the MethodChannel roundtrip is **0.8–1.1 ms**. Commit adfa624 did
exactly what H1 suspected — it removed the cost from native and left the full-resolution
decode sitting on the display critical path, where nothing preloads it.

Two secondary findings:

* **A real hang bug** (not just slow): when the user switches to an image whose preview
  load is *already in flight*, the bytes land in the cache but `notifyListeners()` is never
  called, so the spinner stays on screen indefinitely. Reproduced on a DNG folder: bytes
  cached 17 ms after the keypress, image still not displayed **20 s later**.
* **RAW folders** cost 209 ms of native work per image, which lets a user outrun the
  preloader (6 visible spinners in 20 keypresses at 80 ms/key). JPEG folders never miss.

---

## 1. Methodology

The harness drives the **real** stack — real `MethodChannel` → real
`macos/Runner/AppDelegate.swift`, real engine decode, real raster — inside the built
macOS app. No mocks, no `flutter test` fake-async (which cannot await engine futures).

* A temporary `PerfDriver` (`lib/perf/perf_driver.dart`, deleted afterwards) activates on
  the `HALCYON_PERF_DIR` env var, calls `AppState.loadFolder`, then drives
  `AppState.nextPhoto()` for N switches and logs microsecond timestamps at each stage.
* The app is **sandboxed** (`macos/Runner/DebugProfile.entitlements`:
  `com.apple.security.app-sandbox = true`), so datasets and logs live in
  `~/Library/Containers/com.jhangyu.halcyon/Data/perf/` and are copied back to
  `tmp/verify/perf/`.
* Runs are launched by executing the built binary directly (no `flutter run` wrapper), so
  `stdout` carries both Dart (`PERF|`) and Swift (`PERFNATIVE|`) lines.

### Stage definitions

| stage | from | to | instrumented at |
|---|---|---|---|
| A | `AppState.selectItem` entry | bytes visible to the widget | app_state.dart:150, main_detail_view.dart |
| B | bytes available | **image decoded** (ImageStream first frame) | main_detail_view.dart |
| C | decoded | post-frame callback of the frame that paints it | main_detail_view.dart |

Stage B observes the same `ImageCache` entry that `Image.memory` uses (`MemoryImage`
equality is by bytes identity), so it measures the *same single decode*, not an extra one.

### Passes

| pass | behaviour | purpose |
|---|---|---|
| `paced` | wait for the image, then 1200 ms before the next key | a deliberate user |
| `rapid` | next key immediately after the image appears (~6/s) | sustained fast paging |
| `burst` | one key every **80 ms regardless of readiness** | H2: user outruns the preloader |

### Environment

Apple M3 Ultra · macOS 15.6.1 · 3840×2160 display · Flutter 3.44.6 / Dart 3.12.2 ·
engine `83675ed276`. Builds: `flutter build macos --profile` and `--debug`.

### Data

Real camera files copied from `local_data/photo_samples`:

* `data_jpg`: 30 files, all **6000×4000** (24 MP), 0.99–1.43 MB, from 7 unique originals.
* `data_dng`: 24 files, 3.4–9.2 MB DNG, from 12 unique originals.

---

## 2. Per-stage results

### 2.1 JPEG folder — Profile build (AOT), 48 switches

Raw: `tmp/verify/perf/jpg_profile.log` · summary: `jpg_profile.summary.txt`

| pass | cache | n | stage | median ms | p95 ms | max ms |
|---|---|---|---|---|---|---|
| paced | hit | 24 | A select→bytesAvailable | 2.0 | 2.9 | 3.1 |
| paced | hit | 24 | **B bytes→decoded** | **124.1** | **137.4** | 232.6 |
| paced | hit | 24 | C decoded→painted | 2.6 | 3.9 | 4.1 |
| paced | hit | 24 | **TOTAL select→painted** | **127.5** | **143.6** | 235.5 |
| rapid | hit | 24 | A select→bytesAvailable | 1.6 | 2.8 | 5.7 |
| rapid | hit | 24 | B bytes→decoded | 142.3 | 169.3 | 175.9 |
| rapid | hit | 24 | C decoded→painted | 2.2 | 4.1 | 4.2 |
| rapid | hit | 24 | TOTAL select→painted | 145.8 | 172.6 | 180.8 |

**Accounting:** A+B+C = 2.0+124.1+2.6 = **128.7 ms** vs measured TOTAL **127.5 ms** — the
stages account for the end-to-end latency within **1 %**. No unexplained gap.

Cache: **48/48 hits**. 1 `view.spinner` in the whole run (the very first image after
folder load). 0 timeouts.

### 2.2 JPEG folder — Debug build (JIT), 48 switches

Raw: `tmp/verify/perf/jpg_debug.log` · summary: `jpg_debug.summary.txt`

This is the build mode the user measured 200–500 ms in.

| pass | cache | n | stage | median ms | p95 ms | max ms |
|---|---|---|---|---|---|---|
| paced | hit | 24 | A select→bytesAvailable | 41.9 | 47.2 | 50.9 |
| paced | hit | 24 | **B bytes→decoded** | **121.3** | **158.7** | 162.4 |
| paced | hit | 24 | C decoded→painted | 2.2 | 4.8 | 24.4 |
| paced | hit | 24 | **TOTAL select→painted** | **165.1** | **197.9** | 225.2 |
| rapid | hit | 24 | A select→bytesAvailable | 13.5 | 21.5 | 27.3 |
| rapid | hit | 24 | B bytes→decoded | 147.6 | 191.7 | 217.8 |
| rapid | hit | 24 | C decoded→painted | 3.3 | 4.6 | 6.0 |
| rapid | hit | 24 | TOTAL select→painted | 168.2 | 217.4 | 242.9 |

Accounting: 41.9+121.3+2.2 = 165.4 vs TOTAL 165.1 — within 0.2 %.

Two notes:

* Decode cost is **build-mode independent** (121 ms debug vs 124 ms profile) — it happens
  in the engine's C++ codec, not in Dart.
* Stage A is **21× worse in debug** (41.9 ms vs 2.0 ms): unoptimised Dart widget rebuild.
  Debug frames show median `build=20.8 ms` vs `0.4 ms` in profile.
  → **the user's 200–500 ms figure contains ~40 ms/switch of debug-only overhead.**

### 2.3 DNG folder — Profile build, 40 switches

Raw: `tmp/verify/perf/dng_profile.log` · summary: `dng_profile.summary.txt`

| pass | cache | n | stage | median ms | p95 ms | max ms |
|---|---|---|---|---|---|---|
| paced | hit | 20 | A select→bytesAvailable | 1.8 | 2.7 | 2.8 |
| paced | hit | 20 | **B bytes→decoded** | **130.6** | **150.7** | 151.1 |
| paced | hit | 20 | C decoded→painted | 1.9 | 3.8 | 3.8 |
| paced | hit | 20 | **TOTAL select→painted** | **135.4** | **156.4** | 156.5 |
| rapid | hit | 20 | A select→bytesAvailable | 1.5 | 5.9 | 9.9 |
| rapid | hit | 20 | B bytes→decoded | 174.7 | 270.5 | 288.5 |
| rapid | hit | 20 | C decoded→painted | 2.6 | 4.4 | 6.0 |
| rapid | hit | 20 | TOTAL select→painted | 177.0 | 273.6 | 293.1 |

The native RAW pipeline is 350× more expensive than the JPEG passthrough but stays *off*
the critical path as long as the preloader keeps up (which at ≤6 switches/s it does):

| native stage (DNG) | n | median | p95 | max |
|---|---|---|---|---|
| queue wait | 84 | 0.0 ms | 0.1 ms | 0.3 ms |
| embedded-preview extraction (`rawDecode`) | 84 | **123.0 ms** | 200.3 ms | 266.5 ms |
| JPEG re-encode q0.8 (`reencode`) | 84 | **82.7 ms** | 166.0 ms | 182.6 ms |
| **nativeTotal (handler entry → result)** | 84 | **209.1 ms** | 343.7 ms | 402.2 ms |

Compare JPEG (same instrumentation, `jpg_profile`): `nativeTotal` median **0.6 ms**,
`jpegRead` **0.3 ms**.

### 2.4 Component microbenchmarks (same process, outside the widget pipeline)

| measurement | n | median | p95 | min | max |
|---|---|---|---|---|---|
| MethodChannel roundtrip, JPEG 1.0–1.4 MB | 12 | **0.8 ms** | 1.2 | 0.6 | 1.3 |
| MethodChannel roundtrip, DNG | 12 | 185.7 ms | 207.7 | 160.1 | 212.8 |
| `instantiateImageCodec` + `getNextFrame`, **6000×4000** | 12 | **121.4 ms** | 153.9 | 102.1 | 162.5 |
| same, `targetWidth: 1800` → **1800×1200** | 12 | **54.8 ms** | 69.2 | 44.5 | 74.6 |
| `File.readAsBytes` (JPEG) | 6 | 0.8 ms | 1.8 | 0.6 | 1.9 |

The DNG channel roundtrip (185.7 ms) is native work, not transfer: `nativeTotal` alone is
209 ms while the 2.3 MB payload transfer is sub-millisecond (see JPEG rows: 1.4 MB in
0.8 ms ⇒ transfer ≈ 0.6 ms/MB).

### 2.5 Frame timings (`SchedulerBinding.addTimingsCallback`, frames > 20 ms total)

| build / dataset | n slow frames | median build | median raster | max total |
|---|---|---|---|---|
| Profile / JPEG (48 switches) | 29 | 0.4 ms | **18.0 ms** | 148.4 ms |
| Profile / DNG (40 switches) | 45 | 0.5 ms | **19.9 ms** | 61.8 ms |
| Debug / JPEG (48 switches) | 74 | **20.8 ms** | 1.4 ms | 308.9 ms |

In profile the UI-thread build is negligible; the cost is **raster**, consistent with
uploading a 6000×4000×4 B = **96 MB** RGBA texture. In debug the picture inverts: build
dominates (unoptimised Dart).

---

## 3. Hypothesis verdicts

### H1 — Dart/engine-side decode is the bottleneck → **CONFIRMED**

Decode (stage B) is **124.1 ms of the 127.5 ms** profile median (**97 %**) and
**121.3 ms of 165.1 ms** in debug (73 %). Every decode was `sync=false` at
**6000×4000** — i.e. full camera resolution, never downscaled. Nothing decodes ahead of
display: `ImagePreloadController` (image_preload_controller.dart:43-96) caches
`Uint8List` only; there is no `precacheImage` anywhere in `lib/`.

Confirmed independently by microbenchmark: 121.4 ms for the same bytes outside the widget
tree, matching the in-pipeline 124.1 ms.

The brief's suspicion is exactly right: adfa624 moved the decode from native to the
engine. Native JPEG work went 0.6 ms; the 24 MP decode it used to do now happens on the
display critical path instead of during preload.

### H2 — Cache miss on the switched-to item → **REFUTED for JPEG, CONFIRMED for RAW**

Hit rate was **100 %** (48/48 JPEG, 40/40 DNG) in the paced and rapid passes.

Burst pass (one key every 80 ms, ignoring readiness — `jpg_burst.log`, `dng_burst.log`):

| dataset | keys | visible spinners | final image |
|---|---|---|---|
| JPEG | 24 | **0** | settled 152.9 ms after last key |
| DNG | 20 | **6** | **never — timed out after 20.0 s** |

JPEG cannot miss in practice: native passthrough is 0.6 ms, so a 9-image window refills
far faster than a human can press. RAW misses easily: 209 ms native per image × a 9-image
window cannot keep up with 80 ms/key.

Miss cost when it happens = channel roundtrip + decode = **1 ms + 124 ms** (JPEG) or
**209 ms + 131 ms ≈ 340 ms** (DNG). The 340 ms figure is the best explanation for the
upper end of the user's "200–500 ms".

### H3 — MethodChannel transfer cost of multi-MB payloads → **REFUTED**

1.0–1.4 MB JPEG payloads cross in **0.8–1.1 ms median** (p95 5.5 ms). Native handler
entry→result is **0.6 ms**; dispatch queue wait is **0.0 ms** (p95 0.1 ms). Transfer is
≈ 0.6 ms/MB — below 1 % of the switch budget.

### H4 — Main-thread jank → **PARTIALLY CONFIRMED (raster, not UI build)**

The decode itself is *not* on the UI thread (all `sync=false`, async codec). But in
profile builds 29–45 frames per run exceed 20 ms with **median raster 18–20 ms** and
build 0.4 ms — GPU upload of the 96 MB full-resolution texture. That adds roughly one
extra dropped frame on top of the decode. In debug the UI thread *is* the problem
(median build 20.8 ms), but that is a debug artefact.

### H5 — RAW groups falling into CIRAWFilter full decode → **NOT OBSERVED; different RAW cost found**

All 84 DNG requests took the **embedded-preview** branch
(AppDelegate.swift:116-132) — every embedded preview was ≥ 1024 px, so the
`CIRAWFilter` fallback (AppDelegate.swift:134-154) never ran. **CIRAWFilter remains
untested** — no RW2 samples were available, only DNG.

The measured RAW cost is elsewhere and is large anyway: the code asks for
`kCGImageSourceThumbnailMaxPixelSize: max(targetSize, 8000)` (targetSize is 10000 for
`preview`), so ImageIO decodes the embedded preview at full **6000×4000** (123 ms) and
then re-encodes it to JPEG at q0.8 (82.7 ms) — **209 ms per image**, purely to hand
Flutter a JPEG that Flutter then decodes again for 131 ms.

### H6 (added) — Missing `notifyListeners` when the selected item's load is in flight → **CONFIRMED (hang bug)**

`_loadPreview` returns early when the id is already in `_loadingKeys`
(image_preload_controller.dart:79-81), and the in-flight load only notifies if it was
started with a non-null `notifyLoaded` (image_preload_controller.dart:91-94) — which
window preloads are **not** (image_preload_controller.dart:70). So if the user selects an
item that a *window* preload already started, the priority path returns without loading
and without arranging a notification; when the bytes land, the cache is updated but the UI
is never told.

Live trace from `dng_burst.log` (µs timestamps):

```
12135667 selectItem.enter|r020
12135684 cache.miss|r020|0
12135703 preload.priority.begin|r020|cached=false|inFlight=true
12135720 loadPreview.skip|r020|cached=false|inFlight=true|isSelected=true   <-- early return
12135783 preload.priority.end|r020|dur=80|nowCached=false
12137790 view.spinner|r020                                                  <-- spinner up
12152183 channel.preview|r020|bytes=2305343|notify=false|isSelected=true    <-- bytes cached, NO notify
32219179 burst.timeout|r020|afterKeys=20001539                              <-- still spinning 20s later
```

The bytes were available **17 ms** after the keypress; the image was still not on screen
**20 seconds** later. Occurred 4× in a single 20-key burst (r013, r014, r017, r020).
This is a correctness bug, not a performance one, and it is the tail of the user's
complaint on RAW folders.

---

## 4. Ranked recommendations

Each is tied to a measured number and the code location it would change. **Not
implemented** — analysis only.

### R1 — Decode at display resolution, not camera resolution · saves ~65 ms/switch (≈ 50 %)

`lib/views/main_detail_view.dart:192-199` — `Image.memory(bytes, fit: BoxFit.contain, …)`
has no `cacheWidth`/`cacheHeight`, so a 24 MP image is decoded to 96 MB of RGBA to be
displayed in a ~1800 px-wide box.

Measured: 6000×4000 decode **121.4 ms** → 1800×1200 decode **54.8 ms** (same bytes, same
process). Also shrinks the texture 96 MB → 8.6 MB, which should remove the 18–20 ms raster
frames in §2.5.

Caveat: `InteractiveViewer` allows `maxScale: 5.0`
(main_detail_view.dart:186-190), so a fixed low `cacheWidth` degrades zoomed sharpness.
Size it from the layout constraints already available in the `LayoutBuilder`
(main_detail_view.dart:170-175) × `devicePixelRatio`, and consider re-decoding at full
resolution only while zoomed in.

### R2 — Decode ahead of display, not just fetch bytes ahead · removes decode from the critical path

`lib/services/image_preload_controller.dart:43-96` caches `Uint8List` only. Adding
`precacheImage(MemoryImage(bytes), context)` for the window neighbours would make stage B
≈ 0 on a hit, taking the profile median from **127.5 ms → ~5 ms** and the debug median
from **165.1 ms → ~44 ms**.

**Dependency:** `ImageCache.maximumSizeBytes` defaults to 100 MB, which holds exactly *one*
96 MB full-resolution image — precached neighbours would be evicted before use. R2 is only
effective **after R1** (8.6 MB each ⇒ ~11 fit), or with an explicit
`PaintingBinding.instance.imageCache.maximumSizeBytes` raise. Recommend R1 first, then R2.

### R3 — Attach the notify callback to an already-in-flight load · fixes a >20 s hang

`lib/services/image_preload_controller.dart:79-81` (early return on `_loadingKeys`) and
`:91-94` (notify only when `notifyLoaded != null`). Keep a `Map<String, Completer>` or a
per-id listener list so the selected item is notified whichever load actually fetches it.
Evidence: 4 occurrences per 20-key burst on DNG; one left the UI spinning for the full
20 s timeout while the bytes sat in cache (§3 H6).

Cheapest correct fix, and it is a correctness bug — arguably do this before R1/R2.

### R4 — Ask ImageIO for a display-sized RAW preview and stop re-encoding · saves ~200 ms/RAW image of preload budget

`macos/Runner/AppDelegate.swift:119-124` requests
`kCGImageSourceThumbnailMaxPixelSize: max(targetSize, 8000)` (targetSize = 10000 for
`preview`, from `native_thumbnail_service.dart:6`), producing a full 6000×4000 decode
(**123 ms**); `AppDelegate.swift:181-182` then re-encodes to JPEG q0.8 (**82.7 ms**).
Requesting ~2000 px would cut the extraction, and returning raw RGBA/PNG-free bytes — or
better, letting Flutter decode a smaller preview — cuts the re-encode.

This does not shorten a cache **hit** (that is R1/R2's job) but it raises the preloader's
throughput from ~4.8 img/s to well above human key-repeat rate, which is what removes the
6 spinners per 20 keys measured in §3 H2.

### R5 — Judge latency from profile/release builds only · not a code change

Stage A is **41.9 ms in debug vs 2.0 ms in profile** and debug frames build in 20.8 ms vs
0.4 ms. About 40 ms of the user's per-switch observation is debug-only. The remaining
~125 ms is real and present in release.

### Instrumentation worth keeping (proposal, not applied)

None of the instrumentation was left in the tree. If a permanent hook is wanted, the
single highest-value one is a `SchedulerBinding.addTimingsCallback` behind a
`--dart-define` that logs frames over 32 ms; everything else in this report was
one-off scaffolding.

---

## 5. Limitations

1. **File multiplicity is synthetic.** 30 JPEG files come from 7 unique originals and 24
   DNGs from 12, so the OS page cache is warmer than a cold user folder. Impact is bounded:
   `File.readAsBytes` measured 0.5–2.8 ms, < 2 % of the switch budget.
2. **One image size only.** All JPEGs are 6000×4000 (24 MP). Larger sensors (45–60 MP)
   will scale stage B roughly linearly with pixel count. HEIC and PNG (which still take
   the native decode + re-encode path, AppDelegate.swift:159-171) were **not measured**.
3. **CIRAWFilter path untested.** No RW2 samples; all DNGs had ≥1024 px embedded previews,
   so H5's original suspicion could not be exercised.
4. **Keyboard dispatch excluded.** The harness calls `AppState.nextPhoto()` directly, so
   the platform key event → shortcut dispatch (~1 frame) is not in the numbers.
5. **`image.painted` is not GPU present.** It is the post-frame callback of the frame that
   contains the decoded image. Real on-screen latency adds one vsync (16.7 ms) plus the
   raster figures in §2.5 (median 18–20 ms in profile).
6. **Instrumentation overhead.** ~20 log calls per switch (in-memory buffer + `print`,
   file flush on a 300 ms timer). Stage B — the headline number — contains **zero** log
   calls between its endpoints, and the independent microbenchmark (121.4 ms) corroborates
   it.
7. **Single machine.** Apple M3 Ultra. Decode is CPU-bound; slower machines will be worse.

---

## 6. Artefacts

All under `tmp/verify/perf/` (scratch lane, not committed):

| file | contents |
|---|---|
| `instrumentation.patch` | full diff of the temporary instrumentation (reverted from the tree) |
| `jpg_profile.log` / `.stdout.log` / `.summary.txt` | Profile + JPEG, 48 switches |
| `jpg_debug.log` / `.stdout.log` / `.summary.txt` | Debug + JPEG, 48 switches |
| `dng_profile.log` / `.stdout.log` / `.summary.txt` | Profile + DNG, 40 switches |
| `jpg_burst.log` / `.summary.txt` | Profile + JPEG, 24 keys @ 80 ms |
| `dng_burst.log` / `.summary.txt` | Profile + DNG, 20 keys @ 80 ms |
| `build*.log` | build transcripts |

Scripts under `scripts/tmp/perf/`: `make_dataset.py`, `build.sh`, `run.sh`, `parse.py`,
`parse_burst.py`.

`.stdout.log` files carry the Swift `PERFNATIVE|` lines; `.log` files carry the Dart
`PERF|` lines.
