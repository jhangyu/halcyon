# Bitmap Decoders — Phase 2 (HEIC/HEIF) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use podium:team-spawn (recommended) or podium:team-fable to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `.heic`/`.heif` files appear in Halcyon's sidebar and detail view through the existing image pipeline — same star/trash marks, same preload window, same export path — decoded identically on every platform by a native libheif + libde265 route added to the `ceyx` native package, with macOS verified end to end and Windows/Linux written but unverified.

**Architecture:** Phase 1 already built the seam. `.heic`/`.heif` join `SupportedPhotoFormats.bitmapDecodeExtensions`, so they inherit the widened `NativeImageNeedsRawDecode` → `DngFullDecoder` escape hatch, the `hasFullDecodeRoute` sidebar sized-decode gate, and the export arm — untouched. Phase 2 adds exactly two things: (a) a native HEIC decode route in `ceyx` (`heif_probe` / `heif_decode_rgba` / `heif_release` over a C ABI, backed by dynamically linked `libheif` + `libde265`), and (b) a third arm in `full_decoder_dispatch.dart` plus an injectable metadata-probe seam so `dart_image_loader.dart` can learn a HEIC's extent and orientation without a TIFF IFD0 walk and without a `Platform` check.

**Tech Stack:** C++17 (`ceyx/native`), CMake ≥ 3.16.3, libheif 1.23.2, libde265 1.1.1, Dart FFI (`package:ffi ^2.1.0`), Flutter 3.35.1, `flutter_test`.

**Source spec:** `docs/superpowers/specs/2026-08-28-bitmap-decoders-design.md` (signed off). Sections 4, 7, 8, 9 (phase-2 table) and 10 (phase-2 list) are phase-2 relevant. Do not reopen spec decisions.

**Phase-1 handoff:** `docs/logs/2026-08-28/bitmap-decoders-phase1-handoff.md`. Its "Refuted routes" list is binding: no fourth `NativeImageResult` variant, no transcode-to-bytes inside the loader, no OS-decoder HEIC route.

---

## Global Constraints

Copied from spec §7 / §10-phase-2 and the phase-1 handoff. Every one of these is a plan violation if broken, not a judgement call.

- **Two trees, never mixed in one commit.**
  - Ceyx-side work happens in `/Users/jhangyu/project/ceyx-heic` (git worktree, branch `feature/heic-decode`). `/Users/jhangyu/project/ceyx` is consumed **live** by other sessions and must not be touched — not read-modify, not `git`, not a build that writes into its tree.
  - Halcyon-side work happens in `/Users/jhangyu/project/Halcyon-decoders` (git worktree, branch `feature/bitmap-decoders`). `/Users/jhangyu/project/Halcyon` is off limits except read-only reads of `docs/sop/`.
  - Every task below states its tree in its **Files** block. A commit whose pathspec spans both trees is impossible by construction (separate repos) and a task that needs both is split.
- **Dynamic linking, not static** (LGPL-3 §4(d)(1)). `libheif` and `libde265` are built as separate shared libraries and shipped next to `libdng_decoder_native.dylib`; `otool -L` on the built dylib must show both as `@rpath` dependencies. Static linking into `dng_decoder_native` is rejected by the spec and must not be "simplified" into.
- **Decode-only build flags.** `WITH_X265=OFF`, `WITH_AOM_ENCODER=OFF`, `WITH_AOM_DECODER=OFF`, plus every other encoder/decoder plugin off except `WITH_LIBDE265=ON`. `libde265` is built with `ENABLE_ENCODER=OFF`. No GPL-2.0 component may enter the build.
- **LGPL-3 attribution.** `docs/legal/` in **both** trees gains the LGPL-3.0 licence text and per-library attribution naming the exact pinned versions and source URLs, so the corresponding source can be produced on request.
- **H1 known-answer gate: mean absolute error ≤ 2/255** per channel between the decode of a checked-in sample HEIC and a checked-in reference PNG produced by an **independent** decoder. It runs in `build_apps.py` Phase 1, in the same position as S4, and fails the build the same way.
- **The S4 colour gate still runs and still passes.** `--no-colour-gate` must not appear in any command in this plan. Every HEIC change rebuilds the library that carries the RAW pipeline, so S4 applies to that rebuild exactly as today.
- **macOS-scoped acceptance.** Windows and Linux get CMake rules and target-table rows but are **not verified** in phase 2. On any platform where the libraries are absent at runtime, the dispatcher's HEIC arm throws and the file degrades to the ordinary permanent miss — **the app must not fail to start**.
- **`flutter analyze` reports 0 issues** over `lib/`, `test/` **and** `tool/`.
- **`flutter test -j 1` ends with `All tests passed!`**, `RC=0`, declared test count == executed count.
- **The frozen three-variant seam is untouched.** `lib/services/image_pipeline/image_source_types.dart` must be **unchanged** by this plan (`git diff --stat` must not list it), and `grep -c "class .* extends NativeImageResult"` on it must return `3`.
- **The sidebar never receives `NativeImageNeedsRawDecode`.** Preserved verbatim for HEIC by the phase-1 bitmap branch.
- **AD-021 and AD-022 gates stay on `isDecodablePath`**, never on `hasFullDecodeRoute`.
- **`dart_image_loader.dart` stays free of `dart:io` `Platform` checks** (contract C-3). The HEIC probe reaches it as an injected function, never as a platform test.
- **No renaming** of `DngFullDecoder` / `DngSizedDecoder` / `DecodedRgba` (parked by the 2026-08-26 contract).
- **Commits are pathspec'd only:** `git commit -- <paths>`. `git stash`, `git reset`, `git checkout --`, `git clean` and `git add -A` are **forbidden** in every step, in both trees. A `git mv` commit lists **both** the old and the new path (2026-08-25 lesson).
- **SOP docs (`memory.md`, `unit_test.md`, `file_index.md`) live at `/Users/jhangyu/project/Halcyon/docs/sop/`, are gitignored, and are edited in place at MERGE time only** (Task 9, single final checklist) — never during worktree work, never in a commit.
- **Long builds are gate-runner territory.** Any `cmake --build`, `scripts/fetch_heif_deps.sh`, `python3 scripts/build_apps.py` or full-suite `flutter test` run in this plan exceeds the foreground timeout. The implementer must **request it via test-runner-haiku / the lead** and never run it in the background from an implementer seat.
- **Instrument discipline.** Exit codes are captured inside the artifact with `RC=$?` on the line immediately after the command — never read from a harness notification, never via `${PIPESTATUS[0]}`. Before any measurement, prove the binary under test contains the code under test (`nm -gU`), never by mtime.
- Test names must literally contain their `TC-3NN` identifier so `flutter test` output is greppable for acceptance.

---

## Upstream verification (done before pinning; spec §7.2's versions were unverified)

Checked 2026-08-28 against the GitHub release API:

| Library | Spec target (unverified) | **Actual latest release** | Published | Licence |
|---|---|---|---|---|
| libheif | 1.19.x | **1.23.2** | 2026-08-25 | LGPL-3.0-or-later (library); MIT for examples/wrappers |
| libde265 | 1.0.15 | **1.1.1** | 2026-06-03 | LGPL-3.0-or-later |

Sources:
- `https://api.github.com/repos/strukturag/libheif/releases/latest` → tag `v1.23.2`
- `https://api.github.com/repos/strukturag/libde265/releases/latest` → tag `v1.1.1`
- Tarballs: `https://github.com/strukturag/libheif/releases/download/v1.23.2/libheif-1.23.2.tar.gz`, `https://github.com/strukturag/libde265/releases/download/v1.1.1/libde265-1.1.1.tar.gz`

SHA-256, computed locally from the downloaded tarballs (these are the pins this plan writes into the fetch script):

```
8bd5d41d19dc84536d118b04774709f244df6104ef66d623dad5fa4650143405  libheif-1.23.2.tar.gz
fd48a927e94ed74fc7ce8829d222b9d8599fcbfe8b6448ba66705babc56ab219  libde265-1.1.1.tar.gz
```

Facts read out of the pinned sources (not assumed), which the steps below depend on:

- libheif's codec switches come from a `plugin_option(<NAME> …)` macro; the exact variables are `WITH_LIBDE265`, `WITH_X265`, `WITH_AOM_DECODER`, `WITH_AOM_ENCODER`, `WITH_DAV1D`, `WITH_KVAZAAR`, `WITH_UVG266`, `WITH_VVDEC`, `WITH_VVENC`, `WITH_X264`, `WITH_OpenH264_DECODER`, `WITH_SvtEnc`, `WITH_RAV1E`, `WITH_JPEG_DECODER`, `WITH_JPEG_ENCODER`, `WITH_OpenJPEG_ENCODER`, `WITH_OpenJPEG_DECODER`, `WITH_OPENJPH_ENCODER`, `WITH_FFMPEG_DECODER` (`libheif-1.23.2/CMakeLists.txt:126-310`), plus `WITH_EXAMPLES`, `WITH_GDK_PIXBUF`, `WITH_UNCOMPRESSED_CODEC`, `WITH_HEADER_COMPRESSION`, `WITH_LIBSHARPYUV`, `ENABLE_PLUGIN_LOADING`, `BUILD_TESTING` (`:317, 458, 578-589, 649`).
- libheif's library target is `heif`, `VERSION 1.23.2` / `SOVERSION 1` → macOS produces `libheif.1.dylib` → `libheif.1.23.2.dylib` (`libheif/CMakeLists.txt:197, 226-229`).
- libde265's library target is `de265`, `DE265_SOVERSION 0` → `libde265.0.dylib` (`libde265-1.1.1/CMakeLists.txt:37`, `libde265/CMakeLists.txt:117`).
- libde265's switches are `ENABLE_SDL`, `ENABLE_DECODER`, `ENABLE_ENCODER`, `ENABLE_SHERLOCK265`, `ENABLE_INTERNAL_DEVELOPMENT_TOOLS`, `WITH_FUZZERS`, `BUILD_SHARED_LIBS` (`CMakeLists.txt:67-192`).
- libheif's `cmake/modules/FindLIBDE265.cmake` locates libde265 with `find_path(LIBDE265_INCLUDE_DIR NAMES libde265/de265.h)` + `find_library(LIBDE265_LIBRARY NAMES libde265 de265)` and reads the version out of `libde265/de265-version.h`. **It cannot see an `add_subdirectory()`-provided CMake target** — it needs a real installed file at configure time.

### Deviation from spec §7.3, reported not silently taken

Spec §7.3 says "add the two projects via `add_subdirectory`". This plan **builds and installs them into a dist prefix instead** (`ceyx/native/third_party/heif-dist/`), mirroring `fetch_halide_v21_dist.sh`'s existing "fetch a built distribution" precedent, and links against that prefix with `find_path`/`find_library`. Three verified blockers force it:

1. `FindLIBDE265.cmake` (quoted above) does `find_library` for a file on disk. With `add_subdirectory(libde265)`, no such file exists at libheif's configure time, so `LIBDE265_FOUND` is false and libheif silently builds **without an HEVC decoder** — a green build that decodes nothing. Pre-seeding the cache with a target name does not work: `find_library` does not accept CMake targets.
2. `BUILD_SHARED_LIBS=ON` is a global CACHE variable. Ceyx's tree already has LibRaw, RawSpeed3, zlib and libjpeg-turbo subdirectories whose static-vs-shared choice is deliberate (`third_party.cmake`'s static-libjpeg rationale is a documented App-Sandbox blocker fix). Flipping the global default under them is an unforced regression risk on the RAW path.
3. libheif sets `CMAKE_CXX_STANDARD 20` and `cmake_policy(VERSION 3.0...3.22)` at its top level. Under `add_subdirectory` these land in a directory scope that ceyx's own `CMAKE_CXX_STANDARD 17` project is not written against.

Everything the spec actually *decided* is preserved: dynamic linking, decode-only flags, no new package, integration through `scripts/build_apps.py`, `@rpath` install names, and placement next to `libdng_decoder_native.dylib`.

---

## File Structure

### Tree A — `/Users/jhangyu/project/ceyx-heic` (branch `feature/heic-decode`)

| Path | Responsibility | Task |
|---|---|---|
| `native/scripts/fetch_heif_deps.sh` | **NEW.** Download + SHA-256-verify + build + install libheif/libde265 into `native/third_party/heif-dist/` | 1 |
| `native/third_party/heif-dist/PROVENANCE.md` | **NEW.** Pinned versions, URLs, SHA-256, exact configure flags, licence pointers | 1 |
| `.gitignore` | Ignore `native/third_party/heif-dist/` except `PROVENANCE.md` | 1 |
| `native/include/heif_api.h` | **NEW.** Frozen C ABI: `HeifResult`, `heif_probe`, `heif_decode_rgba`, `heif_release` | 2 |
| `native/include/heif_error_codes.h` | **NEW.** `HeifErrorCode` values on the -301 scale (disjoint from DNG and RAW) | 2 |
| `native/src/pipeline/heif_decode.cpp` | **NEW.** libheif calls: read file, primary item, decode to interleaved RGBA, optional scale | 2 |
| `native/src/ffi/heif_ffi_api.cpp` | **NEW.** C ABI wrapper, allocation and `heif_release` | 2 |
| `native/cmake/heif.cmake` | **NEW.** dist discovery, link, `@rpath` runtime-lib staging | 2 |
| `native/CMakeLists.txt` | Declare `DNG_ENABLE_HEIF`; `include(cmake/heif.cmake)` | 2 |
| `native/cmake/pipeline.cmake` | Exclude the two HEIF TUs when `DNG_ENABLE_HEIF=OFF` | 2 |
| `native/tests/test_heif_color.cpp` | **NEW.** H1 known-answer gate executable | 3 |
| `native/tests/data/h1_sample.heic`, `native/tests/data/h1_reference.png` | **NEW.** H1 fixtures | 3 |
| `native/cmake/tests.cmake` | `add_executable(test_heif_color …)` | 3 |
| `plugin/lib/src/heif_bindings.dart` | **NEW.** FFI struct + guarded symbol lookups | 4 |
| `plugin/lib/src/heif_error_codes.dart` | **NEW.** Dart mirror of the -301 scale | 4 |
| `plugin/lib/src/heif_decoder_service.dart` | **NEW.** `HeifDecoderService`: `probeOnWorker`, `decodeOnWorker` | 4 |
| `plugin/lib/ceyx.dart` | Export the HEIF surface from the barrel | 4 |
| `plugin/macos/ceyx.podspec` | `vendored_libraries` gains `libheif.1.dylib`, `libde265.0.dylib` | 4 |
| `plugin/test/heif_error_codes_test.dart`, `plugin/test/heif_result_layout_test.dart`, `plugin/test/heif_symbol_absent_test.dart` | **NEW.** ABI + degradation pins | 4 |
| `docs/legal/THIRD_PARTY_LICENSES.md`, `docs/legal/LGPL-3.0.txt` | libheif/libde265 attribution | 8 |

### Tree B — `/Users/jhangyu/project/Halcyon-decoders` (branch `feature/bitmap-decoders`)

| Path | Responsibility | Task |
|---|---|---|
| `pubspec.yaml` | Dev-time redirect to `../ceyx-heic/plugin`; **reverted** to `../ceyx/plugin` in Task 9 | 5, 9 |
| `lib/models/supported_photo_formats.dart` | `.heic`/`.heif` join `bitmapDecodeExtensions` | 5 |
| `lib/services/image_pipeline/bitmap_container_probe.dart` | **NEW.** Injectable extent/orientation probe: HEIC via ceyx FFI, TIFF via the IFD0 walker | 6 |
| `lib/services/image_pipeline/dart_image_loader.dart` | Bitmap branch reads extent/orientation through the probe seam | 6 |
| `lib/services/image_pipeline/image_preload_controller.dart` | Sidebar sized path reads orientation through the same seam | 6 |
| `lib/services/image_pipeline/heif_decode_service.dart` | **NEW.** `DngFullDecoder`/`DngSizedDecoder` adapters over `HeifDecoderService` | 7 |
| `lib/services/image_pipeline/full_decoder_dispatch.dart` | Third arm: `.heic`/`.heif` → the HEIF adapters | 7 |
| `scripts/build_apps.py` | `--check` rows for the HEIF dist; H1 gate in Phase 1; macOS `@rpath` verification in Phase 3 | 8 |
| `docs/legal/LGPL-3.0.txt`, `docs/legal/THIRD_PARTY_LICENSES.md` | LGPL-3 text + libheif/libde265 attribution | 8 |
| `test/services/image_pipeline/bitmap_container_probe_test.dart` | **NEW.** TC-319 | 6 |
| `test/services/image_pipeline/dart_image_loader_test.dart` | TC-314, TC-315 | 6 |
| `test/services/image_pipeline/full_decoder_dispatch_test.dart` | TC-316, TC-317 | 7 |
| `README.md`, `README.zh-TW.md` | Supported-formats sections gain HEIC + platform caveat | 9 |
| `docs/logs/2026-08-28/bitmap-decoders-phase2-gate.md` | **NEW.** Acceptance artifact | 9 |

---

## Test-case matrix added by this phase

| TC | Case | Where |
|---|---|---|
| TC-314 | `dartImageLoad('x.heic', purpose: preview)` returns `NativeImageNeedsRawDecode` carrying the orientation supplied by a fake probe | `test/services/image_pipeline/dart_image_loader_test.dart` |
| TC-315 | `dartImageLoad('x.heic', purpose: sidebarThumbnail)` returns `NativeImageFailure`; the sized sidebar decoder is the only HEIC thumbnail route | same |
| TC-316 | With the HEIC library absent, the dispatcher throws and the item becomes a permanent miss — no crash, and **not** the D3 `NO_NATIVE_DECODER` code | `test/services/image_pipeline/full_decoder_dispatch_test.dart` |
| TC-317 | A `HeifResult` whose `rgba_len != width * height * 4` is rejected before `decodeImageFromPixels` sees it | same |
| TC-318 | H1 colour gate: the sample HEIC decodes within 2/255 MAE of the reference PNG (native-side, run in `build_apps.py` Phase 1) | `ceyx/native/tests/test_heif_color.cpp` |
| TC-319 | The probe seam routes `.heic` to the HEIF probe and `.tif` to the IFD0 walker, and returns `null` when the HEIF probe is unavailable | `test/services/image_pipeline/bitmap_container_probe_test.dart` |
| TC-320 | A HEIC declaring an over-budget extent yields `IMAGE_TOO_LARGE` before any decode | `test/services/image_pipeline/dart_image_loader_test.dart` |

TC-319 and TC-320 are additions to spec §9's phase-2 table. Adding checks is permitted; relaxing them is not (2026-08-27 lesson).

---

## Task skeletons

### Task 1 — Vendor libheif + libde265 as a pinned, decode-only dist  *(Tree A)*

**Files:** create `native/scripts/fetch_heif_deps.sh`, `native/third_party/heif-dist/PROVENANCE.md`; modify `.gitignore`.

**Interfaces:** produces `native/third_party/heif-dist/{include/libheif/heif.h, include/libde265/de265.h, lib/libheif.1.dylib, lib/libde265.0.dylib}` (plus versioned real files and `lib/cmake` config). Consumes nothing from ceyx.

**Behavior:** idempotent fetch → SHA-256 verify → unpack → configure/build/install libde265 first, then libheif against that prefix. Both with `CMAKE_INSTALL_NAME_DIR=@rpath` so the shipped dylibs carry `@rpath/libheif.1.dylib` / `@rpath/libde265.0.dylib` install names, `CMAKE_OSX_ARCHITECTURES=arm64`, `CMAKE_OSX_DEPLOYMENT_TARGET=11.0`, `CMAKE_BUILD_TYPE=Release`. Re-running with the prefix already populated and the recorded pins matching is a no-op.

**Constraints:** no encoder is built; no plugin loading; the SHA-256 check is a hard failure, never a warning; the script never writes outside `native/third_party/heif-dist/` and its own staging directory; `heif-dist/` is gitignored except `PROVENANCE.md`.

**Acceptance criteria:**
- [ ] `bash native/scripts/fetch_heif_deps.sh` exits 0 and prints the two resolved SHA-256 values matching the pins.
- [ ] `ls native/third_party/heif-dist/lib/libheif.1.dylib native/third_party/heif-dist/lib/libde265.0.dylib` succeeds.
- [ ] `otool -D native/third_party/heif-dist/lib/libheif.1.dylib` prints `@rpath/libheif.1.dylib`; same shape for libde265.
- [ ] `nm -gU native/third_party/heif-dist/lib/libheif.1.dylib | grep -c heif_decode_image` ≥ 1.
- [ ] `nm -gU native/third_party/heif-dist/lib/libheif.1.dylib | grep -c x265` returns 0.
- [ ] `git -C /Users/jhangyu/project/ceyx-heic status --porcelain` lists no file under `native/third_party/heif-dist/` except `PROVENANCE.md`.

### Task 2 — Native HEIC decode route and its C ABI  *(Tree A)*

**Files:** create `native/include/heif_api.h`, `native/include/heif_error_codes.h`, `native/src/pipeline/heif_decode.cpp`, `native/src/ffi/heif_ffi_api.cpp`, `native/cmake/heif.cmake`; modify `native/CMakeLists.txt`, `native/cmake/pipeline.cmake`.

**Interfaces (frozen C ABI):**
```c
typedef struct {
  int32_t  error_code;
  uint32_t width;
  uint32_t height;
  int32_t  orientation;
  uint8_t* rgba;
  int64_t  rgba_len;
} HeifResult;   /* 64-bit layout: error_code@0 width@4 height@8 orientation@12 rgba@16 rgba_len@24, sizeof==32 */

int32_t heif_probe(const char* path, uint32_t* width, uint32_t* height, int32_t* orientation);
int32_t heif_decode_rgba(const char* path, int32_t max_dim, HeifResult* out);
void    heif_release(HeifResult* r);
```

**Behavior:** `heif_probe` reads only the metadata boxes of the primary item (`pitm`) and reports the **post-transform** extent. `heif_decode_rgba` decodes the primary item to interleaved RGBA8, honouring libheif's default `irot`/`imir` handling, and copies row-by-row because libheif's plane stride may exceed `width * 4`. `max_dim <= 0` means full size; otherwise the long edge is capped with `heif_image_scale_image` — a request, not a guarantee. `rgba_len == width * height * 4` is asserted native-side before returning success.

**Orientation contract (decision, stated rather than dodged):** pixels are delivered **display-ready** — libheif applies the container's `irot`/`imir` transform properties during decode, and both entry points therefore report `orientation = 1`. The field exists so that a later decision about a HEIC's separate EXIF `Orientation` tag can change behaviour without an ABI break. Consequence, recorded as a stated limitation and a parking-lot item, not silently shipped: a HEIC that carries **only** an EXIF Orientation tag and no `irot` property will display unrotated. The user-run manual check in Task 9 is what would surface it on a real iPhone file; the mechanical signal is the H1 gate, whose reference PNG comes from an independent decoder and whose dimensions therefore disagree if the transform handling is wrong.

**Constraints:** `DNG_ENABLE_HEIF=OFF` must produce a build with neither TU compiled and no libheif dependency (the Windows/Linux and any dist-less build path). The two new TUs must be excluded by an anchored `list(FILTER … EXCLUDE REGEX ".*/heif_(decode|ffi_api)\\.cpp$")` in `pipeline.cmake`, exactly as `libraw_frontend.cpp` is. `dng_decoder_native` stays SHARED and keeps every existing link line. No exception may escape the C ABI (`catch (...)` at every entry point). Error codes live on the **-301** scale so they are disjoint from `DngErrorCode` (0, -1..-8, -100, -101) and `RawErrorCode` (≤ -201).

**Acceptance criteria:**
- [ ] `cmake --preset macos-metal` configures with `-- HEIF: libheif <ver> + libde265 <ver> (dynamic)` in the output.
- [ ] `cmake --build --preset macos-metal --target dng_decoder_native` succeeds.
- [ ] `nm -gU native/build/libdng_decoder_native.dylib | grep -c 'heif_decode_rgba\|heif_probe\|heif_release'` returns 3.
- [ ] `otool -L native/build/libdng_decoder_native.dylib | grep -c '@rpath/libheif\.1\.dylib\|@rpath/libde265\.0\.dylib'` returns 2.
- [ ] `ls native/build/libheif.1.dylib native/build/libde265.0.dylib` succeeds (POST_BUILD staging).
- [ ] Configuring with `-DDNG_ENABLE_HEIF=OFF` builds, and `nm -gU` then finds **no** `heif_` symbol.
- [ ] `grep -rn "x265\|libaom" native/CMakeLists.txt native/cmake/heif.cmake` shows no enabled encoder option.

### Task 3 — H1 known-answer colour gate  *(Tree A)*

**Files:** create `native/tests/test_heif_color.cpp`, `native/tests/data/h1_sample.heic`, `native/tests/data/h1_reference.png`, `native/tests/data/H1_PROVENANCE.md`; modify `native/cmake/tests.cmake`.

**Interfaces:** `test_heif_color <sample.heic> <reference.png> [--max-mae N]`; prints one `[HEIF COLOR] … PASS|FAIL` line; exit 0 only on PASS. Mirrors `test_cfa_color`'s output contract exactly so `build_apps.py` can treat them identically.

**Behavior:** decodes the sample through the production FFI entry (`heif_decode_rgba`, `max_dim = 0`), reads the reference PNG, fails immediately on any dimension mismatch, then computes the mean absolute per-channel difference over RGB (alpha ignored) and requires `MAE <= 2.0` (in 0..255 units). The reference is produced by macOS ImageIO (`sips -s format png`), i.e. an **independent** implementation — a decoder compared against its own output proves nothing. The sample itself is produced by ImageIO from a checked-in JPEG so the fixture is reproducible on any macOS host without a phone.

**Pre-registration (written before the numbers exist):** the expected MAE between libheif and ImageIO on the same file is dominated by chroma-upsampling and YUV-matrix rounding and is expected to land in **0.0–1.5**. A run in 1.5–2.0 passes but must be reported as marginal. A run above 2.0 is a **failure to report**, not a threshold to raise; the only permitted response is to diagnose the range/matrix handling. A run that is exactly 0.0 is also suspicious and must be checked for the reference having been generated from our own decoder.

**Constraints:** PNG reading is done with a vendored single-header decoder or by converting the reference to a raw `.rgba` sidecar at fixture-creation time — no new third-party dependency may enter `ceyx/native` for this. (This plan takes the sidecar route: see Task 3 steps.) The fixture must be small (≤ 512 px long edge) so it can be committed. The gate must fail loudly when the fixture files are missing, never skip silently — the 2026-08-25 lesson (a silently skipped gate produces a PASS report indistinguishable from a full run) is why a skip prints a `SKIP` line **and** exits non-zero.

**Acceptance criteria:**
- [ ] `cmake --build --preset macos-metal --target test_heif_color` succeeds.
- [ ] `./build/test_heif_color tests/data/h1_sample.heic tests/data/h1_reference.rgba` prints a line containing `[HEIF COLOR]` and `PASS`, and `RC=0` captured with `RC=$?` on the next line.
- [ ] Deleting the reference and re-running prints `SKIP`/`FAIL` and exits non-zero (negative control, run once and recorded).
- [ ] Perturbing the tolerance to `--max-mae 0.0` makes the same run FAIL (proves the comparison is live, not a constant `PASS`).

### Task 4 — Dart FFI surface in the ceyx plugin  *(Tree A)*

**Files:** create `plugin/lib/src/heif_bindings.dart`, `plugin/lib/src/heif_error_codes.dart`, `plugin/lib/src/heif_decoder_service.dart`, `plugin/test/heif_error_codes_test.dart`, `plugin/test/heif_result_layout_test.dart`, `plugin/test/heif_symbol_absent_test.dart`; modify `plugin/lib/ceyx.dart`, `plugin/macos/ceyx.podspec`.

**Interfaces:**
```dart
class HeifImage { final Uint8List rgba; final int width, height, orientation; }
typedef HeifProbeResult = ({int width, int height, int orientation});

abstract final class HeifErrorCode { … static String name(int code); static bool isHeifError(int code); }
class HeifDecodeException implements Exception { … }
class HeifUnavailableException implements Exception { … }

class HeifDecoderService {
  HeifDecoderService({String? libraryPath});
  bool get heifAvailable;                                  // guarded symbol lookup
  Future<HeifProbeResult?> probeOnWorker(String path);
  Future<HeifImage> decodeOnWorker(String path, {int? maxDim});
}
```

**Behavior:** exactly the `DngNativeBindings` pattern — every HEIF symbol is looked up inside `try`/`catch` so an older dylib leaves `heifAvailable == false` instead of throwing in the constructor and killing *all* decoding. Work runs on a worker isolate via `Isolate.run` with a static entry point, and the native buffer is copied into Dart-owned bytes and shipped as `TransferableTypedData`, exactly as `_decodeFileToTransferable` does — no native pointer crosses an isolate boundary. `probeOnWorker` returns `null` (never throws) when the symbol is absent or the probe reports an error, because its caller is the loader, which must never throw.

**Constraints:** the Dart `HeifResult` struct must mirror the C layout field-for-field and in order (Gotcha #58 in `memory.md`: a field-count mismatch was a real past bug); a layout test pins `sizeOf<HeifResult>() == 32`. No new pub dependency in the plugin. The barrel export must not leak `heif_bindings.dart`'s internals — export the same shape the DNG/RAW surfaces export.

**Acceptance criteria:**
- [ ] `flutter test` inside `plugin/` prints `All tests passed!` (three new files included).
- [ ] `grep -n "heif" plugin/lib/ceyx.dart` shows the new export block.
- [ ] `grep -c "libheif.1.dylib\|libde265.0.dylib" plugin/macos/ceyx.podspec` returns 2.
- [ ] `dart analyze` inside `plugin/` reports no issues.

### Task 5 — Registry: `.heic`/`.heif` join the bitmap-decode set  *(Tree B)*

**Files:** modify `lib/models/supported_photo_formats.dart`, `pubspec.yaml`, `test/models/supported_photo_formats_test.dart`.

**Interfaces:** `SupportedPhotoFormats.bitmapDecodeExtensions` becomes `{'.tif', '.tiff', '.heic', '.heif'}`. Nothing else in the class changes; `supportedExtensions`, `fullDecodeExtensions` and `hasFullDecodeRoute` all derive and update for free.

**Behavior:** this single edit is what makes `.heic` survive the folder scan, take the phase-1 bitmap branch in the loader, and pass the `hasFullDecodeRoute` sidebar gate. `preferredLoadExtensions` is **not** touched: a HEIC sibling must not outrank a JPEG sibling, exactly as for TIFF.

`pubspec.yaml`'s `ceyx: path:` is redirected to `../ceyx-heic/plugin` **for the duration of phase-2 development only**, because the HEIF Dart surface lives on the `feature/heic-decode` branch. Task 9 reverts it; the revert is paired with merging that branch into `ceyx` main, and the plan is not complete until it is done.

**Constraints:** phase 1's `grep -rn "heic\|heif" lib/` must-return-nothing rule is **retired by this task** and replaced by the phase-2 checks; do not carry the old assertion forward. The phase-1 test `TC-302` asserts `isSupportedPath('e.heic') == false` with the reason "HEIC is phase 2 and must not be claimed yet" — that assertion must be **inverted**, not deleted, so the change is visible in the diff.

**Acceptance criteria:**
- [ ] `grep -n "bitmapDecodeExtensions" lib/models/supported_photo_formats.dart` shows `{'.tif', '.tiff', '.heic', '.heif'}`.
- [ ] `grep -n "heic" lib/models/supported_photo_formats.dart` shows it only inside `bitmapDecodeExtensions` and its doc comment — not in `preferredLoadExtensions`, not in `engineBitstreamExtensions`.
- [ ] `flutter test test/models/supported_photo_formats_test.dart` prints `All tests passed!`.
- [ ] `grep -n "ceyx-heic" pubspec.yaml` returns exactly one line, and `grep -c "PHASE-2 DEV REDIRECT" pubspec.yaml` returns 1 — that marker is what Task 9's revert check greps for.
- [ ] `flutter analyze` reports 0 issues.

### Task 6 — The metadata-probe seam and the loader/sidebar wiring  *(Tree B)*

**Files:** create `lib/services/image_pipeline/bitmap_container_probe.dart`, `test/services/image_pipeline/bitmap_container_probe_test.dart`; modify `lib/services/image_pipeline/dart_image_loader.dart`, `lib/services/image_pipeline/image_preload_controller.dart`, `test/services/image_pipeline/dart_image_loader_test.dart`.

**Interfaces:**
```dart
typedef BitmapContainerExtent = ({int width, int height, int orientation});

/// The loader's view of the seam: path in, extent out, never throws.
typedef BitmapContainerProbe = Future<BitmapContainerExtent?> Function(String path);

/// The native-HEIF half of the seam, injected so tests need no dylib.
typedef HeifExtentProbe = Future<BitmapContainerExtent?> Function(String path);

Future<BitmapContainerExtent?> heifExtentProbe(String path);           // production HEIF arm
Future<BitmapContainerExtent?> probeBitmapContainer(String path, {HeifExtentProbe heifProbe});
Future<int> bitmapContainerOrientation(String path, {HeifExtentProbe heifProbe});

Future<NativeImageResult> dartImageLoad(
  String path, {
  required ImageRequestPurpose purpose,
  BitmapContainerProbe probe = probeBitmapContainer,   // additive, defaulted
});
```

**Behavior:** the loader's phase-1 bitmap branch currently makes two direct calls to `DngEmbeddedJpegExtractor` (`readImageDimensions`, `readOrientation`). Those are TIFF IFD0 walkers and return `null` on ISO-BMFF, so a HEIC would wave through the budget check and always report orientation 1. The branch is refactored to make **one** call to the injected `probe`, and `probeBitmapContainer` dispatches: `.heic`/`.heif` → `HeifDecoderService.probeOnWorker`, everything else → the existing IFD0 walker. Behaviour for TIFF is bit-identical (same two reads, same `null` semantics), which is what keeps TC-305/306/307 green unchanged.

The optional named parameter with a default keeps `dartImageLoad` a subtype of the `NativeImageLoad` typedef, so no call site changes — the same trick `dispatchFullDecode` already uses for its arms.

`image_preload_controller.dart`'s sidebar sized path reads orientation at `:1077-1079` through the same walker; it is switched to `bitmapContainerOrientation(file.path)`, which is the walker for RAW/TIFF and the HEIF probe for HEIC.

**Constraints:** no `Platform` check enters `dart_image_loader.dart` — the probe is a function, and the "is there a library on this platform" question is answered inside `bitmap_container_probe.dart`, which is the layer that owns the decoder seam (contract C-3, spec §3). `probeBitmapContainer` must **never throw**: a missing dylib, an absent symbol or a native error all become `null`. `dartImageLoad` still never throws. A `null` probe result waves through the budget check exactly as a `null` IFD0 extent does today — do not turn it into a failure.

**Acceptance criteria:**
- [ ] `test/services/image_pipeline/dart_image_loader_test.dart` contains tests named with `TC-314`, `TC-315` and `TC-320`, and all pass.
- [ ] `test/services/image_pipeline/bitmap_container_probe_test.dart` contains a test named with `TC-319` and it passes.
- [ ] `grep -c "Platform\." lib/services/image_pipeline/dart_image_loader.dart` returns 0.
- [ ] `grep -n "DngEmbeddedJpegExtractor" lib/services/image_pipeline/dart_image_loader.dart` still shows the RAW preview walk, and no longer shows a call inside the bitmap branch.
- [ ] `git diff --stat -- lib/services/image_pipeline/image_source_types.dart` produces no output.
- [ ] `flutter test -j 1` prints `All tests passed!`; `flutter analyze` reports 0 issues.

### Task 7 — The dispatcher's HEIC arm  *(Tree B)*

**Files:** create `lib/services/image_pipeline/heif_decode_service.dart`, modify `lib/services/image_pipeline/full_decoder_dispatch.dart`, `test/services/image_pipeline/full_decoder_dispatch_test.dart`.

**Interfaces:**
```dart
// heif_decode_service.dart
Future<DecodedRgba> decodeHeifFull(String path);
Future<DecodedRgba> decodeHeifSized(String path, {required int maxDim});
const DngFullDecoder  halcyonHeifFullDecoder  = decodeHeifFull;
const DngSizedDecoder halcyonHeifSizedDecoder = decodeHeifSized;

// full_decoder_dispatch.dart — arms added, signatures otherwise unchanged
Future<DecodedRgba> dispatchFullDecode(String path, {
  DngFullDecoder rawArm, DngFullDecoder tiffArm, DngFullDecoder heifArm});
Future<DecodedRgba> dispatchSizedDecode(String path, {required int maxDim,
  DngSizedDecoder rawArm, DngSizedDecoder tiffArm, DngSizedDecoder heifArm});
```

**Behavior:** dispatch order becomes HEIF → TIFF → RAW → `UnsupportedError`, keyed on `SupportedPhotoFormats` predicates. The HEIF adapters mirror `decodeDngFull` exactly: call the service, verify `rgba.length == width * height * 4`, throw `StateError` on mismatch, return `DecodedRgba`. When the library or symbol is absent the service throws `HeifUnavailableException`, which the adapter lets propagate — `photo_source.dart`'s step-3b catch converts it into the uniform permanent miss, and the D3 `kNoNativeDecoderCode` state stays reserved for `dngDecoder == null`.

A new predicate is needed because `.heic` must not fall into the TIFF arm: add `SupportedPhotoFormats.isHeifPath` (derived from a `heifExtensions` const that `bitmapDecodeExtensions` itself unions in, so the two cannot desync) in this task, and make the TIFF arm's guard `isBitmapDecodePath(path) && !isHeifPath(path)`. Deriving rather than restating is the same rule phase 1 applied to the RAW list.

**Constraints:** `halcyonFullDecoder`/`halcyonSizedDecoder` stay `const` tear-off aliases — the new arms are optional named parameters, so the tear-off remains a subtype of the seam typedef and `app_state.dart:95` / `main.dart:39` need no edit. No fourth `NativeImageResult` variant. No new pub dependency in Halcyon.

**Acceptance criteria:**
- [ ] `test/services/image_pipeline/full_decoder_dispatch_test.dart` contains tests named with `TC-316` and `TC-317`, and both pass; the phase-1 `TC-309` tests still pass unchanged.
- [ ] `grep -n "isHeifPath" lib/models/supported_photo_formats.dart lib/services/image_pipeline/full_decoder_dispatch.dart` shows the predicate defined once and used in both dispatch functions.
- [ ] `grep -n "const DngFullDecoder halcyonFullDecoder\|const DngSizedDecoder halcyonSizedDecoder" lib/services/image_pipeline/full_decoder_dispatch.dart` still returns both lines.
- [ ] `git diff --stat -- lib/providers/app_state.dart lib/main.dart` produces no output.
- [ ] `flutter analyze` reports 0 issues.

### Task 8 — Build-script integration, licensing, and the readiness rows  *(Tree B, plus a docs-only commit in Tree A)*

**Files:** modify `scripts/build_apps.py`; create `docs/legal/LGPL-3.0.txt`, `docs/legal/THIRD_PARTY_LICENSES.md` (Tree B). Separate commit in Tree A: `docs/legal/THIRD_PARTY_LICENSES.md`, `docs/legal/LGPL-3.0.txt`.

**Interfaces:** `build_apps.py` gains
- a `HEIF_DIST` constant and a `check_heif_dist(layout, problems)` helper called from `check_native` for the `macos` target (and, listed but inert, for `windows`/`linux`);
- an `--h1-sample-heic` / `--h1-reference-rgba` argument pair defaulting to the checked-in fixtures under the ceyx tree;
- an H1 gate block in `build_native`, immediately after the S4 block and before library placement;
- a `verify_macos_heif_rpaths(app_bundle)` check in Phase 3.

**Behavior:** the H1 gate is built and run exactly like S4 — `cmake --build --preset <p> --target test_heif_color`, then the executable with the fixtures, through `run_checked` so a non-zero exit fails the build. It is skipped only when `DNG_ENABLE_HEIF` is off for the target, and a skip prints an explicit `HEIF decode disabled for <target>: H1 gate not run` line (never a silent pass — 2026-08-25 lesson). `--no-colour-gate` continues to govern S4 only and gains no HEIC meaning; there is deliberately no `--no-h1-gate`.

Phase 3 verification asserts the two dylibs landed in `Contents/Frameworks/` and that `otool -L` on the placed `libdng_decoder_native.dylib` names them via `@rpath`. Phase 1's existing "copy sibling `*.dylib` from the build dir" loop already carries `libheif.1.dylib`/`libde265.0.dylib` into `plugin/macos/Libraries/` once Task 2's POST_BUILD stages them there — this is why Task 2 stages into the build dir rather than installing elsewhere.

Windows/Linux: `NATIVE_SPECS` rows and the CMake paths exist, and `check_heif_dist` reports the missing dist as a **problem** on those targets only when a native build is actually due there. Neither is verified in phase 2; the `--check` output labels them `unverified (phase 2 scope: macOS)`.

**Constraints:** no `--no-colour-gate` in any command, comment or default. The script must keep exiting 2 (not 0) when S4 was skipped; the H1 gate does not reuse that flag. `docs/legal/` files are committed in the tree that ships them: both, because both trees redistribute the binaries.

**Acceptance criteria:**
- [ ] `python3 scripts/build_apps.py macos --check` exits 0 and its output contains a `libheif` and a `libde265` line.
- [ ] `grep -c "no-colour-gate" scripts/build_apps.py` is unchanged from its pre-task value (record it first).
- [ ] `grep -n "test_heif_color" scripts/build_apps.py` shows the build and the run.
- [ ] `docs/legal/LGPL-3.0.txt` exists in both trees and contains `GNU LESSER GENERAL PUBLIC LICENSE`.
- [ ] `grep -c "1.23.2\|1.1.1" docs/legal/THIRD_PARTY_LICENSES.md` ≥ 2 in both trees.
- [ ] `flutter analyze` reports 0 issues (the script is under `scripts/`, which analysis covers outside `scripts/tmp/`).

### Task 9 — Gate run, READMEs, pubspec revert, and the merge checklist  *(Tree B; the ceyx merge is a lead checklist)*

**Files:** modify `README.md`, `README.zh-TW.md`, `pubspec.yaml`; create `docs/logs/2026-08-28/bitmap-decoders-phase2-gate.md`. Merge-time-only, never committed: `/Users/jhangyu/project/Halcyon/docs/sop/{memory.md,unit_test.md,file_index.md}`.

**Behavior:** the phase-2 acceptance gate runs once, with `RC=$?` captured inside the artifact on the line immediately after each command. The full macOS build (`python3 scripts/build_apps.py macos --cfa-sample-dng <sample>`) is requested from the gate runner, not run by the implementer. READMEs gain HEIC with the platform caveat — verified on macOS, written-but-unverified on Windows and Linux — plus the stated limitations (primary item only; no burst/Live-Photo secondaries, no HDR gain maps, no depth maps; a HEIC carrying only an EXIF Orientation tag may display unrotated). The Chinese file is authored as Chinese prose, not translated sentence-by-sentence, and is checked with the bracket-width pairing script (2026-08-27 lesson).

The **final** action is reverting `pubspec.yaml` to `ceyx: path: ../ceyx/plugin`, which is only valid once `feature/heic-decode` is merged into ceyx main. That merge is a **lead checklist**, listed not performed.

**Pre-registered pass rule, fixed before the run:** phase 2 passes iff (a) `flutter analyze` ends with `No issues found!` and `RC=0`; (b) `flutter test -j 1` contains `All tests passed!` and `RC=0`; (c) the artifact contains all of `TC-314`…`TC-320`; (d) the macOS build exits `RC=0` with the S4 line present and no `--no-colour-gate` in the invocation; (e) the H1 gate line reads `PASS`; (f) `otool -L` shows both `@rpath` HEIF dependencies and `nm -gU` finds `heif_decode_rgba`. Any other outcome is a **reported failure**, not a re-run with different arguments.

**Acceptance criteria:**
- [ ] `docs/logs/2026-08-28/bitmap-decoders-phase2-gate.md` exists and contains `RC=0` for every command, `No issues found!`, `All tests passed!`, a `[CFA COLOR] … PASS` line and a `[HEIF COLOR] … PASS` line.
- [ ] `grep -o "TC-3[12][0-9]" <artifact> | sort -u | wc -l` ≥ 7.
- [ ] `grep -c "no-colour-gate" <artifact>` returns 0.
- [ ] `grep -in "heic" README.md README.zh-TW.md` returns matches in both, each naming macOS as verified and Windows/Linux as unverified.
- [ ] `grep -n "ceyx-heic" pubspec.yaml` returns nothing, and `grep -n "path: ../ceyx/plugin" pubspec.yaml` returns one line.
- [ ] `git status --porcelain` lists no path under `docs/sop/`.
- [ ] `grep -n "AD-036" /Users/jhangyu/project/Halcyon/docs/sop/memory.md` returns a match.

---

## Task 1 — Steps  *(Tree A: `/Users/jhangyu/project/ceyx-heic`)*

- [ ] **Step 1: Create `native/scripts/fetch_heif_deps.sh`**

```bash
#!/usr/bin/env bash
# Vendors libheif + libde265 as a DECODE-ONLY, DYNAMICALLY LINKED distribution
# under native/third_party/heif-dist/. Idempotent.
#
# Why a built dist instead of add_subdirectory (spec 7.3's wording):
#   1. libheif's cmake/modules/FindLIBDE265.cmake does find_library() for a
#      file on disk. An add_subdirectory()'d libde265 target does not exist as
#      a file at libheif's configure time, so LIBDE265_FOUND would be false and
#      libheif would build with NO HEVC decoder -- a green build that decodes
#      nothing.
#   2. BUILD_SHARED_LIBS is a global CACHE variable. Ceyx already vendors
#      LibRaw, RawSpeed3, zlib and libjpeg-turbo whose static-vs-shared choice
#      is deliberate (see third_party.cmake's App-Sandbox rationale for static
#      libjpeg). Flipping the global default under them is an unforced risk.
#   3. libheif sets CMAKE_CXX_STANDARD 20 and cmake_policy(VERSION 3.0...3.22)
#      at its top level; ceyx's project is C++17.
# Everything the spec DECIDED is preserved: dynamic linking, decode-only,
# no new package, @rpath install names, placement next to the decoder dylib.
set -euo pipefail

HEIF_VERSION="1.23.2"
DE265_VERSION="1.1.1"
HEIF_URL="https://github.com/strukturag/libheif/releases/download/v${HEIF_VERSION}/libheif-${HEIF_VERSION}.tar.gz"
DE265_URL="https://github.com/strukturag/libde265/releases/download/v${DE265_VERSION}/libde265-${DE265_VERSION}.tar.gz"
HEIF_SHA256="8bd5d41d19dc84536d118b04774709f244df6104ef66d623dad5fa4650143405"
DE265_SHA256="fd48a927e94ed74fc7ce8829d222b9d8599fcbfe8b6448ba66705babc56ab219"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST="${NATIVE_DIR}/third_party/heif-dist"
STAGE="${DIST}/.stage"
STAMP="${DIST}/.pins"
WANT_PINS="libheif=${HEIF_VERSION}:${HEIF_SHA256} libde265=${DE265_VERSION}:${DE265_SHA256}"

if [ -f "${STAMP}" ] && [ "$(cat "${STAMP}")" = "${WANT_PINS}" ] \
   && [ -f "${DIST}/lib/libheif.1.dylib" ] && [ -f "${DIST}/lib/libde265.0.dylib" ]; then
  echo "[heif] dist already at the pinned versions:"
  echo "[heif]   libheif  ${HEIF_VERSION}  ${HEIF_SHA256}"
  echo "[heif]   libde265 ${DE265_VERSION}  ${DE265_SHA256}"
  exit 0
fi

# Downloads ${1} to ${2} and hard-fails unless its SHA-256 equals ${3}.
# A mismatch is never a warning: an unverified tarball must not reach a build
# whose output we then ship under an LGPL source-availability obligation.
fetch_verified() {
  local url="$1" dest="$2" want="$3" got=""
  if [ ! -f "${dest}" ]; then
    echo "[heif] downloading ${url}"
    curl -fsSL -o "${dest}.part" "${url}"
    mv "${dest}.part" "${dest}"
  fi
  got="$(shasum -a 256 "${dest}" | awk '{print $1}')"
  if [ "${got}" != "${want}" ]; then
    echo "[heif] SHA-256 MISMATCH for ${dest}" >&2
    echo "[heif]   expected ${want}" >&2
    echo "[heif]   actual   ${got}" >&2
    rm -f "${dest}"
    exit 1
  fi
  echo "[heif] verified $(basename "${dest}") ${got}"
}

mkdir -p "${STAGE}"
fetch_verified "${HEIF_URL}"  "${STAGE}/libheif-${HEIF_VERSION}.tar.gz"   "${HEIF_SHA256}"
fetch_verified "${DE265_URL}" "${STAGE}/libde265-${DE265_VERSION}.tar.gz" "${DE265_SHA256}"

rm -rf "${STAGE}/libheif-${HEIF_VERSION}" "${STAGE}/libde265-${DE265_VERSION}"
tar -xzf "${STAGE}/libheif-${HEIF_VERSION}.tar.gz"   -C "${STAGE}"
tar -xzf "${STAGE}/libde265-${DE265_VERSION}.tar.gz" -C "${STAGE}"

COMMON_ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="${DIST}"
  -DCMAKE_INSTALL_NAME_DIR=@rpath
  -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DBUILD_SHARED_LIBS=ON
)

# --- libde265 first: libheif's FindLIBDE265 needs it installed on disk. ---
# ENABLE_ENCODER=OFF is the LGPL-cleanliness half of the decode-only rule;
# ENABLE_SDL/SHERLOCK265 off drops the GUI inspection tools and their deps.
echo "[heif] configuring libde265 ${DE265_VERSION}"
cmake -S "${STAGE}/libde265-${DE265_VERSION}" -B "${STAGE}/build-de265" \
  "${COMMON_ARGS[@]}" \
  -DENABLE_DECODER=ON \
  -DENABLE_ENCODER=OFF \
  -DENABLE_SDL=OFF \
  -DENABLE_SHERLOCK265=OFF \
  -DENABLE_INTERNAL_DEVELOPMENT_TOOLS=OFF \
  -DWITH_FUZZERS=OFF
cmake --build "${STAGE}/build-de265" --parallel
cmake --install "${STAGE}/build-de265"

# --- libheif, decode-only, against the just-installed libde265. ---
# WITH_LIBDE265=ON is the ONLY codec left on. X265 and AOM_ENCODER are the two
# the spec names explicitly (x265 is GPL-2.0); the rest are turned off so a
# future upstream default flip cannot quietly pull an encoder in.
# WITH_LIBDE265_PLUGIN=OFF + ENABLE_PLUGIN_LOADING=OFF build the decoder INTO
# libheif: a dlopen-ed plugin directory would not survive app-bundle packaging.
# LIBDE265_INCLUDE_DIR/LIBDE265_LIBRARY are pre-seeded so the find module
# resolves to OUR dist and can never pick up a Homebrew libde265.
echo "[heif] configuring libheif ${HEIF_VERSION}"
cmake -S "${STAGE}/libheif-${HEIF_VERSION}" -B "${STAGE}/build-heif" \
  "${COMMON_ARGS[@]}" \
  -DCMAKE_PREFIX_PATH="${DIST}" \
  -DLIBDE265_INCLUDE_DIR="${DIST}/include" \
  -DLIBDE265_LIBRARY="${DIST}/lib/libde265.dylib" \
  -DWITH_LIBDE265=ON \
  -DWITH_LIBDE265_PLUGIN=OFF \
  -DENABLE_PLUGIN_LOADING=OFF \
  -DWITH_X265=OFF \
  -DWITH_X264=OFF \
  -DWITH_KVAZAAR=OFF \
  -DWITH_UVG266=OFF \
  -DWITH_VVDEC=OFF \
  -DWITH_VVENC=OFF \
  -DWITH_AOM_DECODER=OFF \
  -DWITH_AOM_ENCODER=OFF \
  -DWITH_DAV1D=OFF \
  -DWITH_SvtEnc=OFF \
  -DWITH_RAV1E=OFF \
  -DWITH_OpenH264_DECODER=OFF \
  -DWITH_FFMPEG_DECODER=OFF \
  -DWITH_JPEG_DECODER=OFF \
  -DWITH_JPEG_ENCODER=OFF \
  -DWITH_OpenJPEG_DECODER=OFF \
  -DWITH_OpenJPEG_ENCODER=OFF \
  -DWITH_OPENJPH_ENCODER=OFF \
  -DWITH_UNCOMPRESSED_CODEC=OFF \
  -DWITH_HEADER_COMPRESSION=OFF \
  -DWITH_LIBSHARPYUV=OFF \
  -DWITH_EXAMPLES=OFF \
  -DWITH_GDK_PIXBUF=OFF \
  -DWITH_REDUCED_VISIBILITY=ON \
  -DBUILD_TESTING=OFF \
  -DWITH_FUZZERS=OFF
cmake --build "${STAGE}/build-heif" --parallel
cmake --install "${STAGE}/build-heif"

# Proof, not assumption: a libheif built without a working libde265 configures
# and installs perfectly happily and then decodes nothing.
if ! nm -gU "${DIST}/lib/libheif.1.dylib" | grep -q 'heif_decode_image'; then
  echo "[heif] FAILED: libheif exports no heif_decode_image" >&2
  exit 1
fi
if ! otool -L "${DIST}/lib/libheif.1.dylib" | grep -q 'libde265'; then
  echo "[heif] FAILED: libheif has no libde265 dependency -- it was built" >&2
  echo "[heif]   WITHOUT an HEVC decoder and would silently decode nothing." >&2
  exit 1
fi
if nm -gU "${DIST}/lib/libheif.1.dylib" | grep -q 'x265_encoder'; then
  echo "[heif] FAILED: x265 encoder symbols present (GPL-2.0 contamination)" >&2
  exit 1
fi

printf '%s' "${WANT_PINS}" > "${STAMP}"
rm -rf "${STAGE}/build-de265" "${STAGE}/build-heif" \
       "${STAGE}/libheif-${HEIF_VERSION}" "${STAGE}/libde265-${DE265_VERSION}"
echo "[heif] dist ready at ${DIST}"
echo "[heif]   libheif  ${HEIF_VERSION}"
echo "[heif]   libde265 ${DE265_VERSION}"
```

Make it executable: `chmod +x native/scripts/fetch_heif_deps.sh`.

- [ ] **Step 2: Ignore the dist, keep the provenance**

Append to `/Users/jhangyu/project/ceyx-heic/.gitignore`, next to the existing `native/third_party/libraw/` block:

```gitignore
# Vendored HEIF decode distribution (libheif + libde265, built by
# native/scripts/fetch_heif_deps.sh). Source is fetched and built, never
# tracked -- the same policy as Halide and LibRaw. PROVENANCE.md IS tracked so
# the pinned versions, hashes and configure flags survive without the tree.
native/third_party/heif-dist/*
!native/third_party/heif-dist/PROVENANCE.md
```

The glob (`/*`) rather than the bare directory is required for the negation to
work at all: git does not descend into an excluded directory. Verify with
`git check-ignore -v native/third_party/heif-dist/PROVENANCE.md`, which must
report **no** match.

- [ ] **Step 3: Write `native/third_party/heif-dist/PROVENANCE.md`**

```markdown
# HEIF decode distribution — provenance

Built by `native/scripts/fetch_heif_deps.sh`. Nothing under this directory is
tracked except this file.

| Component | Version | Source | SHA-256 |
|---|---|---|---|
| libheif | 1.23.2 | https://github.com/strukturag/libheif/releases/download/v1.23.2/libheif-1.23.2.tar.gz | `8bd5d41d19dc84536d118b04774709f244df6104ef66d623dad5fa4650143405` |
| libde265 | 1.1.1 | https://github.com/strukturag/libde265/releases/download/v1.1.1/libde265-1.1.1.tar.gz | `fd48a927e94ed74fc7ce8829d222b9d8599fcbfe8b6448ba66705babc56ab219` |

Verified against the GitHub release API on 2026-08-28. The design spec's
1.19.x / 1.0.15 were explicitly unverified targets; these are the versions that
actually exist upstream.

## Licence and linkage

Both are **LGPL-3.0-or-later**. They are built as **separate shared libraries**
and loaded dynamically, which satisfies LGPL-3 section 4(d)(1) outright: a user
can replace `libheif.1.dylib` / `libde265.0.dylib` inside
`<App>.app/Contents/Frameworks/`. Static linking into `libdng_decoder_native`
is deliberately NOT done, because it would trigger the 4(d)(0) duty to ship
relinkable object files with every release.

The corresponding source for any shipped binary is the tarball at the URL and
hash above, plus the exact configure flags recorded in the fetch script.

## Decode-only build

No encoder is built. `WITH_X265=OFF` (x265 is GPL-2.0), `WITH_AOM_ENCODER=OFF`,
`ENABLE_ENCODER=OFF` for libde265, and every other libheif codec plugin off
except `WITH_LIBDE265=ON`. Plugin loading is off, so the HEVC decoder is
compiled into `libheif` rather than dlopen-ed from a plugin directory that
would not survive app-bundle packaging.

The fetch script asserts all three of these mechanically after the build:
`heif_decode_image` is exported, a `libde265` dependency is present (a libheif
built without a working HEVC decoder installs perfectly happily and then
decodes nothing), and no `x265_encoder` symbol exists.
```

- [ ] **Step 4: Run the fetch (gate runner)**

This configures and compiles two CMake projects and exceeds the foreground
timeout. **Request via test-runner-haiku / the lead**; do not run it from an
implementer seat and do not background it. The artifact goes inside the repo,
never under the system temp directory:

```bash
cd /Users/jhangyu/project/ceyx-heic
mkdir -p docs/logs/2026-08-28
bash native/scripts/fetch_heif_deps.sh > docs/logs/2026-08-28/heif-dist-fetch.log 2>&1
RC=$?
echo "RC=$RC" >> docs/logs/2026-08-28/heif-dist-fetch.log
```

`RC=$?` sits on the line immediately after the command and is written **into**
the artifact. Do not read the exit code from a harness notification and do not
use `${PIPESTATUS[0]}` — both have lied in this project before.

- [ ] **Step 5: Verify the dist mechanically**

```bash
cd /Users/jhangyu/project/ceyx-heic/native/third_party/heif-dist
ls lib/libheif.1.dylib lib/libde265.0.dylib
otool -D lib/libheif.1.dylib                                 # expect @rpath/libheif.1.dylib
otool -D lib/libde265.0.dylib                                # expect @rpath/libde265.0.dylib
nm -gU lib/libheif.1.dylib | grep -c heif_decode_image       # expect >= 1
nm -gU lib/libheif.1.dylib | grep -c x265                    # expect 0
otool -L lib/libheif.1.dylib | grep -c libde265              # expect >= 1
git -C /Users/jhangyu/project/ceyx-heic status --porcelain | grep heif-dist   # expect only PROVENANCE.md
```

`otool -D` (the install name), not `otool -L`, is the check that matters here:
an install name of `/Users/.../heif-dist/lib/libheif.1.dylib` would build and
run on this machine and fail on every other one. Note `stat` on a macOS
`.framework` reads the symlink, not the target — use `stat -L` if you need
sizes (2026-08-23 lesson).

- [ ] **Step 6: Commit (Tree A, pathspec'd)**

```bash
git -C /Users/jhangyu/project/ceyx-heic add \
  native/scripts/fetch_heif_deps.sh \
  native/third_party/heif-dist/PROVENANCE.md \
  docs/logs/2026-08-28/heif-dist-fetch.log
git -C /Users/jhangyu/project/ceyx-heic commit \
  -m "build(heif): vendor libheif 1.23.2 + libde265 1.1.1 as a decode-only dynamic dist" \
  -- native/scripts/fetch_heif_deps.sh \
     native/third_party/heif-dist/PROVENANCE.md \
     .gitignore \
     docs/logs/2026-08-28/heif-dist-fetch.log
git -C /Users/jhangyu/project/ceyx-heic status --porcelain
```

Three files are new and need `git add`; `.gitignore` is tracked. The pathspec
after `--` is exhaustive on purpose: a bare `git commit` sweeps the whole
index, including any teammate's staged work (2026-08-24 lesson). Never run
`git add -A`, `git stash`, `git reset`, `git checkout --` or `git clean`.

---

## Task 2 — Steps  *(Tree A: `/Users/jhangyu/project/ceyx-heic`)*

- [ ] **Step 1: Create `native/include/heif_error_codes.h`**

```c
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// HEIF decode error contract.
///
/// The -301 scale is chosen precisely so these can never collide with
/// DngErrorCode (0, -1..-8, -100, -101) or RawErrorCode (<= -201) inside a
/// shared int32_t error field — the same disjointness rule
/// raw_pipeline_contract.h:12-13 states for the RAW scale.
///
/// Any value or spelling change here MUST be mirrored in
/// plugin/lib/src/heif_error_codes.dart; plugin/test/heif_error_codes_test.dart
/// enforces it.
enum HeifErrorCode {
  kHeifSuccess = 0,
  kHeifErrNullPath = -301,          ///< null/empty path or null out-parameter
  kHeifErrOpenFailed = -302,        ///< file unreadable or not an ISO-BMFF/HEIF container
  kHeifErrNoPrimaryItem = -303,     ///< no `pitm` primary image item
  kHeifErrUnsupportedCodec = -304,  ///< no decoder for the coded item
  kHeifErrDecodeFailed = -305,      ///< the HEVC decode itself failed
  kHeifErrColorConversion = -306,   ///< YUV -> interleaved RGBA conversion failed
  kHeifErrAllocationFailed = -307,  ///< out of memory
  kHeifErrSizeOverflow = -308,      ///< extent exceeds the decoded-pixel ceiling
  kHeifErrMetadataInvalid = -309,   ///< non-positive or inconsistent dimensions
  kHeifErrUnknownException = -310   ///< a C++ exception reached the C ABI boundary
};

/// Mirrors the spelling used by the Dart side, for comparable log lines.
const char *heif_error_name(int32_t code);

#ifdef __cplusplus
}
#endif
```

- [ ] **Step 2: Create `native/include/heif_api.h`**

```c
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Result of heif_decode_rgba. The caller MUST free it with heif_release().
///
/// ABI contract: 6 fields; do NOT reorder or insert fields in the middle.
/// Layout on 64-bit: sizeof==32, error_code@0, width@4, height@8,
/// orientation@12, rgba@16, rgba_len@24.
/// Any change here MUST be mirrored in HeifResult (heif_bindings.dart).
/// See also: Gotcha #58 (memory.md) — a field-count mismatch was a past bug.
typedef struct {
  int32_t error_code;  ///< 0 = success, negative = a HeifErrorCode
  uint32_t width;      ///< post-transform width in pixels
  uint32_t height;     ///< post-transform height in pixels
  int32_t orientation; ///< always 1 — see the orientation contract below
  uint8_t *rgba;       ///< RGBA8 interleaved (width*height*4 bytes), or NULL
  int64_t rgba_len;    ///< exactly width*height*4 on success, else 0
} HeifResult;

/// Reads only the metadata boxes of the primary item and reports its
/// POST-TRANSFORM extent, cheaply enough to run before every preview decode.
///
/// Used by the Dart loader to satisfy the decoded-pixel budget check and to
/// fill NativeImageNeedsRawDecode.exifOrientation before any decode happens.
///
/// ORIENTATION CONTRACT (phase 2 decision, deliberately narrow):
/// libheif applies the container's `irot`/`imir` transform properties during
/// decode, so the pixels this API delivers are ALREADY display-ready and
/// orientation is always 1. The field exists so that a later decision about
/// a HEIC's separate EXIF Orientation tag can change behaviour without an ABI
/// break. Stated limitation: a HEIC carrying ONLY an EXIF Orientation tag and
/// no irot property will display unrotated.
///
/// Returns 0 on success or a negative HeifErrorCode. On any failure the
/// out-parameters are left untouched.
int32_t heif_probe(const char *path, uint32_t *width, uint32_t *height,
                   int32_t *orientation);

/// Decodes the PRIMARY item of a HEIC/HEIF file to interleaved RGBA8.
///
/// Multi-image files (bursts, Live Photos, depth/auxiliary images) yield the
/// `pitm` primary item only; HDR gain maps and depth maps are ignored.
///
/// max_dim <= 0 means full size. Otherwise the LONG edge is capped at max_dim
/// with the aspect ratio preserved — a REQUEST, not a guarantee, matching
/// DngSizedDecoder's documented semantics. Callers must read back
/// out->width/out->height rather than assume they got what they asked for.
///
/// Returns 0 on success or a negative HeifErrorCode; the same value is also
/// written to out->error_code. `out` must be non-NULL and is fully overwritten.
int32_t heif_decode_rgba(const char *path, int32_t max_dim, HeifResult *out);

/// Frees the RGBA buffer owned by *r and zeroes the struct. Safe on a NULL
/// pointer and safe to call twice. Does NOT free `r` itself — the struct is
/// caller-allocated (usually on the Dart side via calloc), unlike DngResult.
void heif_release(HeifResult *r);

#ifdef __cplusplus
}
#endif
```

- [ ] **Step 3: Create `native/include/heif_decode.h`**

```c
#pragma once

#include <stdint.h>

/// Internal C++-side entry points for the HEIF route. Not part of the shipped
/// C ABI — that is heif_api.h. Split so the ABI wrapper holds no libheif types
/// and the whole libheif dependency is confined to heif_decode.cpp.
int32_t heifProbePrimary(const char *path, uint32_t *width, uint32_t *height,
                         int32_t *orientation);

int32_t heifDecodePrimaryRgba(const char *path, int32_t max_dim,
                              uint8_t **out_rgba, int64_t *out_len,
                              uint32_t *out_width, uint32_t *out_height,
                              int32_t *out_orientation);
```

- [ ] **Step 4: Create `native/src/pipeline/heif_decode.cpp`**

```cpp
// HEIC/HEIF decode through libheif + libde265 (dynamically linked; see
// native/third_party/heif-dist/PROVENANCE.md for versions, hashes and the
// LGPL-3 relinking rationale).
//
// This TU holds everything that touches libheif's API. The C ABI wrapper in
// src/ffi/heif_ffi_api.cpp holds no libheif types, so a build with
// DNG_ENABLE_HEIF=OFF drops both files and the dylib has no libheif
// dependency at all.

#include "heif_decode.h"

#include <libheif/heif.h>

#include <cstdlib>
#include <cstring>

#include "heif_error_codes.h"

namespace {

// Mirrors kDecodedPixelBudgetBytes on the Dart side
// (lib/services/image_pipeline/dng_decode_contract.dart). The Dart loader
// checks it first via heif_probe; this is the second line for direct native
// callers such as the H1 gate, and the only line for a file whose probe was
// waved through.
constexpr int64_t kHeifMaxRgbaBytes = 1500000000;

struct ContextGuard {
  heif_context *ctx = nullptr;
  ~ContextGuard() {
    if (ctx) heif_context_free(ctx);
  }
};

struct HandleGuard {
  heif_image_handle *handle = nullptr;
  ~HandleGuard() {
    if (handle) heif_image_handle_release(handle);
  }
};

struct ImageGuard {
  heif_image *image = nullptr;
  ~ImageGuard() {
    if (image) heif_image_release(image);
  }
};

struct OptionsGuard {
  heif_decoding_options *options = nullptr;
  ~OptionsGuard() {
    if (options) heif_decoding_options_free(options);
  }
};

// Opens the file and takes the primary (`pitm`) image handle.
int32_t openPrimary(const char *path, ContextGuard &ctx, HandleGuard &handle) {
  ctx.ctx = heif_context_alloc();
  if (!ctx.ctx) return kHeifErrAllocationFailed;

  heif_error err = heif_context_read_from_file(ctx.ctx, path, nullptr);
  if (err.code != heif_error_Ok) return kHeifErrOpenFailed;

  err = heif_context_get_primary_image_handle(ctx.ctx, &handle.handle);
  if (err.code != heif_error_Ok || !handle.handle) return kHeifErrNoPrimaryItem;

  return kHeifSuccess;
}

// libheif's own error taxonomy, mapped onto ours. Only the distinctions the
// app can act on are preserved; everything else collapses to
// kHeifErrDecodeFailed.
int32_t mapDecodeError(const heif_error &err) {
  if (err.code == heif_error_Unsupported_filetype ||
      err.code == heif_error_Unsupported_feature) {
    return kHeifErrUnsupportedCodec;
  }
  if (err.code == heif_error_Memory_allocation_error) {
    return kHeifErrAllocationFailed;
  }
  if (err.code == heif_error_Color_profile_does_not_exist) {
    return kHeifErrColorConversion;
  }
  return kHeifErrDecodeFailed;
}

}  // namespace

int32_t heifProbePrimary(const char *path, uint32_t *width, uint32_t *height,
                         int32_t *orientation) {
  ContextGuard ctx;
  HandleGuard handle;
  const int32_t opened = openPrimary(path, ctx, handle);
  if (opened != kHeifSuccess) return opened;

  // POST-transform extent: libheif accounts for the item's irot/imir
  // properties here, which is the same geometry the decode below produces.
  const int w = heif_image_handle_get_width(handle.handle);
  const int h = heif_image_handle_get_height(handle.handle);
  if (w <= 0 || h <= 0) return kHeifErrMetadataInvalid;

  *width = static_cast<uint32_t>(w);
  *height = static_cast<uint32_t>(h);
  // Always 1: the pixels are delivered display-ready (see heif_api.h).
  *orientation = 1;
  return kHeifSuccess;
}

int32_t heifDecodePrimaryRgba(const char *path, int32_t max_dim,
                              uint8_t **out_rgba, int64_t *out_len,
                              uint32_t *out_width, uint32_t *out_height,
                              int32_t *out_orientation) {
  ContextGuard ctx;
  HandleGuard handle;
  const int32_t opened = openPrimary(path, ctx, handle);
  if (opened != kHeifSuccess) return opened;

  OptionsGuard options;
  options.options = heif_decoding_options_alloc();
  if (!options.options) return kHeifErrAllocationFailed;
  // 10/12-bit HEIC (iPhone HDR) must arrive as 8-bit: everything downstream of
  // DecodedRgba is RGBA8 (spec section 11 parks 16-bit display precision).
  options.options->convert_hdr_to_8bit = 1;
  // ignore_transformations is left at its default 0 on purpose: libheif
  // applies irot/imir, which is what makes the reported orientation 1.

  ImageGuard decoded;
  heif_error err =
      heif_decode_image(handle.handle, &decoded.image, heif_colorspace_RGB,
                        heif_chroma_interleaved_RGBA, options.options);
  if (err.code != heif_error_Ok || !decoded.image) return mapDecodeError(err);

  ImageGuard scaled;
  heif_image *frame = decoded.image;
  int width = heif_image_get_width(frame, heif_channel_interleaved);
  int height = heif_image_get_height(frame, heif_channel_interleaved);
  if (width <= 0 || height <= 0) return kHeifErrMetadataInvalid;

  if (max_dim > 0 && (width > max_dim || height > max_dim)) {
    // Long edge to max_dim, aspect preserved, both sides at least 1.
    const double scale = static_cast<double>(max_dim) /
                         static_cast<double>(width >= height ? width : height);
    int target_w = static_cast<int>(width * scale + 0.5);
    int target_h = static_cast<int>(height * scale + 0.5);
    if (target_w < 1) target_w = 1;
    if (target_h < 1) target_h = 1;
    err = heif_image_scale_image(frame, &scaled.image, target_w, target_h,
                                 nullptr);
    if (err.code != heif_error_Ok || !scaled.image) return mapDecodeError(err);
    frame = scaled.image;
    width = heif_image_get_width(frame, heif_channel_interleaved);
    height = heif_image_get_height(frame, heif_channel_interleaved);
    if (width <= 0 || height <= 0) return kHeifErrMetadataInvalid;
  }

  const int64_t needed =
      static_cast<int64_t>(width) * static_cast<int64_t>(height) * 4;
  if (needed > kHeifMaxRgbaBytes) return kHeifErrSizeOverflow;

  int stride = 0;
  const uint8_t *plane =
      heif_image_get_plane_readonly(frame, heif_channel_interleaved, &stride);
  if (!plane || stride <= 0) return kHeifErrColorConversion;

  uint8_t *buffer =
      static_cast<uint8_t *>(std::malloc(static_cast<size_t>(needed)));
  if (!buffer) return kHeifErrAllocationFailed;

  // Row-by-row, never one memcpy: libheif's plane stride is padded for SIMD
  // and is routinely larger than width*4. Copying `needed` bytes in one go
  // would shear the image and read past the plane on the last row.
  const size_t row_bytes = static_cast<size_t>(width) * 4;
  for (int y = 0; y < height; ++y) {
    std::memcpy(buffer + static_cast<size_t>(y) * row_bytes,
                plane + static_cast<size_t>(y) * static_cast<size_t>(stride),
                row_bytes);
  }

  *out_rgba = buffer;
  *out_len = needed;
  *out_width = static_cast<uint32_t>(width);
  *out_height = static_cast<uint32_t>(height);
  *out_orientation = 1;
  return kHeifSuccess;
}
```

- [ ] **Step 5: Create `native/src/ffi/heif_ffi_api.cpp`**

```cpp
// C ABI for the HEIF route. Mirrors src/ffi/dng_ffi_api.cpp's shape: no
// exception may cross this boundary, every entry validates its pointers, and
// buffer ownership transfers to the caller with an explicit release call.

#include "heif_api.h"

#include <cstdlib>
#include <cstring>

#include "heif_decode.h"
#include "heif_error_codes.h"

extern "C" {

const char *heif_error_name(int32_t code) {
  switch (code) {
    case kHeifSuccess: return "kHeifSuccess";
    case kHeifErrNullPath: return "kHeifErrNullPath";
    case kHeifErrOpenFailed: return "kHeifErrOpenFailed";
    case kHeifErrNoPrimaryItem: return "kHeifErrNoPrimaryItem";
    case kHeifErrUnsupportedCodec: return "kHeifErrUnsupportedCodec";
    case kHeifErrDecodeFailed: return "kHeifErrDecodeFailed";
    case kHeifErrColorConversion: return "kHeifErrColorConversion";
    case kHeifErrAllocationFailed: return "kHeifErrAllocationFailed";
    case kHeifErrSizeOverflow: return "kHeifErrSizeOverflow";
    case kHeifErrMetadataInvalid: return "kHeifErrMetadataInvalid";
    case kHeifErrUnknownException: return "kHeifErrUnknownException";
    default: return "kHeifErrUnknown";
  }
}

int32_t heif_probe(const char *path, uint32_t *width, uint32_t *height,
                   int32_t *orientation) {
  if (!path || !path[0] || !width || !height || !orientation) {
    return kHeifErrNullPath;
  }
  try {
    return heifProbePrimary(path, width, height, orientation);
  } catch (...) {
    return kHeifErrUnknownException;
  }
}

int32_t heif_decode_rgba(const char *path, int32_t max_dim, HeifResult *out) {
  if (!out) return kHeifErrNullPath;
  // Fully overwritten, never partially: a caller reading width/height after a
  // failure must see zeroes, not whatever was on its stack.
  std::memset(out, 0, sizeof(HeifResult));
  if (!path || !path[0]) {
    out->error_code = kHeifErrNullPath;
    return kHeifErrNullPath;
  }
  try {
    uint8_t *rgba = nullptr;
    int64_t len = 0;
    uint32_t w = 0;
    uint32_t h = 0;
    int32_t orientation = 1;
    const int32_t rc =
        heifDecodePrimaryRgba(path, max_dim, &rgba, &len, &w, &h, &orientation);
    if (rc != kHeifSuccess) {
      if (rgba) std::free(rgba);
      out->error_code = rc;
      return rc;
    }
    // The invariant _imageFromPixels asserts on the Dart side
    // (decoded_rgba_image_provider.dart:59-67), enforced here so a violation
    // can never reach Dart at all.
    if (len != static_cast<int64_t>(w) * static_cast<int64_t>(h) * 4) {
      std::free(rgba);
      out->error_code = kHeifErrMetadataInvalid;
      return kHeifErrMetadataInvalid;
    }
    out->error_code = kHeifSuccess;
    out->width = w;
    out->height = h;
    out->orientation = orientation;
    out->rgba = rgba;
    out->rgba_len = len;
    return kHeifSuccess;
  } catch (...) {
    out->error_code = kHeifErrUnknownException;
    return kHeifErrUnknownException;
  }
}

void heif_release(HeifResult *r) {
  if (!r) return;
  if (r->rgba) std::free(r->rgba);
  // Zeroing (not just freeing) is what makes a double release safe: the second
  // call sees a null pointer.
  std::memset(r, 0, sizeof(HeifResult));
}

}  // extern "C"
```

- [ ] **Step 6: Create `native/cmake/heif.cmake`**

```cmake
# heif.cmake - HEIC/HEIF decode route (libheif + libde265, DYNAMICALLY linked).
#
# The dist is produced by native/scripts/fetch_heif_deps.sh; see
# native/third_party/heif-dist/PROVENANCE.md for versions, hashes, the exact
# decode-only configure flags and the LGPL-3 relinking rationale.
#
# Included (not add_subdirectory'd) from native/CMakeLists.txt, after
# cmake/ffi.cmake, so dng_decoder_native already exists as a target.
if(NOT DNG_HOST_GENERATORS_ONLY)

if(DNG_ENABLE_HEIF)
    set(HEIF_DIST_DIR ${THIRD_PARTY_DIR}/heif-dist)

    find_path(HEIF_INCLUDE_DIR
        NAMES libheif/heif.h
        HINTS "${HEIF_DIST_DIR}/include"
        NO_DEFAULT_PATH)
    find_library(HEIF_LIBRARY
        NAMES heif
        HINTS "${HEIF_DIST_DIR}/lib"
        NO_DEFAULT_PATH)
    find_library(DE265_LIBRARY
        NAMES de265
        HINTS "${HEIF_DIST_DIR}/lib"
        NO_DEFAULT_PATH)

    # NO_DEFAULT_PATH on all three is deliberate: silently linking a Homebrew
    # libheif would stamp an absolute /opt/homebrew load command into the
    # shipped dylib, which App-Sandboxed hosts cannot open — the exact failure
    # third_party.cmake's static-libjpeg note records for libjpeg in 2026-08-17.
    if(NOT HEIF_INCLUDE_DIR OR NOT HEIF_LIBRARY OR NOT DE265_LIBRARY)
        message(FATAL_ERROR
            "HEIF decode is enabled but the vendored dist is missing.\n"
            "  expected under ${HEIF_DIST_DIR}\n"
            "  heif.h    = '${HEIF_INCLUDE_DIR}'\n"
            "  libheif   = '${HEIF_LIBRARY}'\n"
            "  libde265  = '${DE265_LIBRARY}'\n"
            "Run native/scripts/fetch_heif_deps.sh, or configure with "
            "-DDNG_ENABLE_HEIF=OFF to build without the HEIC route.")
    endif()

    target_include_directories(dng_decoder_native PRIVATE ${HEIF_INCLUDE_DIR})
    target_link_libraries(dng_decoder_native ${HEIF_LIBRARY} ${DE265_LIBRARY})
    target_compile_definitions(dng_decoder_native PRIVATE DNG_ENABLE_HEIF=1)

    message(STATUS "HEIF: libheif ${HEIF_LIBRARY} + libde265 ${DE265_LIBRARY} (dynamic)")

    if(APPLE)
        # Stage the two dylibs NEXT TO the built decoder library. Two reasons,
        # both load-bearing:
        #  1. dng_decoder_native records them as @rpath/libheif.1.dylib and
        #     @rpath/libde265.0.dylib (their install names, set by the fetch
        #     script), and the dylib carries an @loader_path rpath, so a bare
        #     dlopen out of the build directory resolves them.
        #  2. scripts/build_apps.py Phase 1 copies every sibling *.dylib from
        #     the build dir into plugin/macos/Libraries/, which is how they
        #     reach the app bundle. Staging here is what makes that free.
        # copy_if_different, so an unchanged dist does not retrigger the
        # downstream Flutter build every time.
        add_custom_command(TARGET dng_decoder_native POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                    "${HEIF_DIST_DIR}/lib/libheif.1.dylib"
                    "$<TARGET_FILE_DIR:dng_decoder_native>/libheif.1.dylib"
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                    "${HEIF_DIST_DIR}/lib/libde265.0.dylib"
                    "$<TARGET_FILE_DIR:dng_decoder_native>/libde265.0.dylib"
            COMMENT "Staging libheif/libde265 next to dng_decoder_native")
    endif()
else()
    target_compile_definitions(dng_decoder_native PRIVATE DNG_ENABLE_HEIF=0)
    message(STATUS "HEIF: disabled (DNG_ENABLE_HEIF=OFF) — no heif_ symbols will be exported")
endif()

endif() # NOT DNG_HOST_GENERATORS_ONLY
```

- [ ] **Step 7: Wire the option and the include into `native/CMakeLists.txt`**

Add the option next to the other early options, **before** the
`include(cmake/pipeline.cmake)` line, because the source filter in Step 8
reads it:

```cmake
# HEIC/HEIF decode route (spec section 7, phase 2). ON by default on platforms
# where the vendored dist exists; OFF drops both HEIF translation units and
# every libheif/libde265 dependency, which is the documented degradation for a
# platform whose dist has not been built (the app must still start and simply
# report HEIC files as unreadable).
option(DNG_ENABLE_HEIF
       "Build the HEIC/HEIF decode route (libheif + libde265, dynamically linked)" ON)
```

Then add the include **after** `include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/ffi.cmake)` and before `tests.cmake`:

```cmake
include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/heif.cmake)
```

Ordering matters and is not cosmetic: `heif.cmake` calls
`target_link_libraries(dng_decoder_native …)`, and the target is created in
`pipeline.cmake`; `tests.cmake` defines `test_heif_color`, which links
`dng_decoder_native` and therefore must come last.

- [ ] **Step 8: Exclude the HEIF TUs when the route is off (`native/cmake/pipeline.cmake`)**

Add immediately after the existing `libraw_(frontend|gpu_input_adapter)` filter
block:

```cmake
# Phase 2 (HEIC): src/pipeline/heif_decode.cpp includes libheif/heif.h, which is
# only on an include path when DNG_ENABLE_HEIF is ON (cmake/heif.cmake). The
# GLOB_RECURSE above would otherwise sweep both HEIF TUs into
# dng_decoder_native in OFF builds too and break them. The C ABI wrapper goes
# with it: exporting heif_ symbols that resolve to nothing is worse than not
# exporting them, because the Dart side's guarded lookup would succeed and then
# the decode would fail at runtime instead of degrading to a permanent miss.
if(NOT DNG_ENABLE_HEIF)
    list(FILTER NATIVE_SOURCES EXCLUDE REGEX ".*/heif_(decode|ffi_api)\\.cpp$")
endif()
```

The regex is anchored with a `.*/` prefix (path-independent basename match),
exactly like the four filters above it, so moving the files between `src/`
subdirectories cannot silently disarm it.

- [ ] **Step 9: Build and verify (gate runner)**

`cmake --build` on this project exceeds the foreground timeout. **Request via
test-runner-haiku / the lead.** The artifact lives inside the repo:

```bash
cd /Users/jhangyu/project/ceyx-heic/native
mkdir -p ../docs/logs/2026-08-28
LOG=../docs/logs/2026-08-28/heif-native-build.log
cmake --preset macos-metal > "$LOG" 2>/dev/null
echo "CONFIGURE_RC=$?" >> "$LOG"
cmake --build --preset macos-metal --target dng_decoder_native >> "$LOG" 2>/dev/null
echo "BUILD_RC=$?" >> "$LOG"
```

Each `RC=` line is captured with `$?` on the line immediately after its
command and written **into** the artifact. Never read the exit code from a
harness/background notification and never use `${PIPESTATUS[0]}` — both have
lied in this project before (2026-08-23 lesson).

Then, in the foreground, the mechanical checks. Every one is a fact about the
**built artifact**, never about mtime:

```bash
cd /Users/jhangyu/project/ceyx-heic/native
LOG=../docs/logs/2026-08-28/heif-native-build.log
grep -c "^CONFIGURE_RC=0$" "$LOG"     # expect 1
grep -c "^BUILD_RC=0$" "$LOG"         # expect 1
grep -c "HEIF: libheif" "$LOG"        # expect >= 1
nm -gU build/libdng_decoder_native.dylib | grep -cE "_heif_(probe|decode_rgba|release)$"   # expect 3
otool -L build/libdng_decoder_native.dylib | grep -c "@rpath/libheif\.1\.dylib"            # expect 1
otool -L build/libdng_decoder_native.dylib | grep -c "@rpath/libde265\.0\.dylib"           # expect 1
ls build/libheif.1.dylib build/libde265.0.dylib                                            # both exist
otool -L build/libdng_decoder_native.dylib | grep -c "/opt/homebrew/.*heif"                # expect 0
```

`nm` prints C symbols with a leading underscore on macOS, which is why the
pattern is `_heif_...$` — a bare `grep heif_decode_rgba` would also match the
string inside a comment or a `__TEXT` literal and is not a symbol-table check.

- [ ] **Step 10: Prove the OFF path (negative control, run once)**

Without this, "HEIF is optional" is a claim rather than a fact, and the
Windows/Linux degradation story is untested. Build via the gate runner:

```bash
cd /Users/jhangyu/project/ceyx-heic/native
cmake -S . -B build-noheif -DCMAKE_BUILD_TYPE=Release -DDNG_ENABLE_HEIF=OFF \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0
cmake --build build-noheif --target dng_decoder_native
nm -gU build-noheif/libdng_decoder_native.dylib | grep -c "_heif_"   # expect 0
otool -L build-noheif/libdng_decoder_native.dylib | grep -c heif     # expect 0
rm -rf build-noheif
```

Record the two counts in the build-log artifact. `build-noheif/` is a
throwaway directory and must be removed before committing; confirm with
`git status --porcelain`.

- [ ] **Step 11: Commit (Tree A, pathspec'd)**

```bash
git -C /Users/jhangyu/project/ceyx-heic add \
  native/include/heif_api.h \
  native/include/heif_decode.h \
  native/include/heif_error_codes.h \
  native/src/pipeline/heif_decode.cpp \
  native/src/ffi/heif_ffi_api.cpp \
  native/cmake/heif.cmake \
  docs/logs/2026-08-28/heif-native-build.log
git -C /Users/jhangyu/project/ceyx-heic commit \
  -m "feat(heif): native HEIC decode route over a C ABI backed by libheif" \
  -- native/include/heif_api.h \
     native/include/heif_decode.h \
     native/include/heif_error_codes.h \
     native/src/pipeline/heif_decode.cpp \
     native/src/ffi/heif_ffi_api.cpp \
     native/cmake/heif.cmake \
     native/CMakeLists.txt \
     native/cmake/pipeline.cmake \
     docs/logs/2026-08-28/heif-native-build.log
git -C /Users/jhangyu/project/ceyx-heic status --porcelain
```

`status --porcelain` must not list `build/`, `build-noheif/` or anything under
`third_party/heif-dist/` other than `PROVENANCE.md`.

---

## Task 3 — Steps  *(Tree A: `/Users/jhangyu/project/ceyx-heic`)*

The H1 gate is a **known-answer** test: our decoder against an independent
decoder's answer for the same file. Two rules make it meaningful rather than
decorative, and both are enforced by the steps below.

1. The reference must not come from our own decoder. It comes from macOS
   ImageIO (`sips`), a completely separate HEVC/HEIF implementation.
2. The comparison must be able to fail. Step 6 perturbs the tolerance to prove
   the gate is live, and Step 7 deletes the fixture to prove a missing input is
   loud rather than silently skipped (2026-08-25 lesson: a silently skipped
   gate produces a PASS report that is textually identical to a full run).

- [ ] **Step 1: Create `native/tests/data/png_to_rgba.py`**

The C gate must not gain a PNG decoder dependency, so the reference is
converted once, at fixture-creation time, into a trivially readable sidecar.
Python's standard library has `zlib`, which is all a non-interlaced PNG needs.

```python
#!/usr/bin/env python3
"""Convert a non-interlaced 8-bit RGB/RGBA PNG into the H1 sidecar format.

Sidecar layout (little-endian):
    magic   8 bytes  b"H1RGBA\\0\\0"
    width   uint32
    height  uint32
    pixels  width * height * 4 bytes, RGBA8 interleaved

Why a sidecar and not the PNG itself: native/tests/test_heif_color.cpp is the
build gate, and giving it a PNG decoder would mean either a new third-party
dependency inside ceyx/native (forbidden for a test fixture) or a hand-rolled
inflate. The conversion happens once, on the machine that creates the fixture,
with the standard library.

Usage: png_to_rgba.py <in.png> <out.rgba>
"""
import struct
import sys
import zlib


def read_chunks(data):
    if data[:8] != b"\\x89PNG\\r\\n\\x1a\\n":
        raise SystemExit("not a PNG")
    pos = 8
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        ctype = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        yield ctype, body
        pos += 12 + length  # length + type + body + crc


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: png_to_rgba.py <in.png> <out.rgba>")
    raw = open(sys.argv[1], "rb").read()

    width = height = None
    idat = bytearray()
    channels = None
    for ctype, body in read_chunks(raw):
        if ctype == b"IHDR":
            width, height, depth, colour, comp, filt, interlace = struct.unpack(
                ">IIBBBBB", body[:13])
            if depth != 8:
                raise SystemExit(f"bit depth {depth} unsupported (need 8)")
            if interlace != 0:
                raise SystemExit("interlaced PNG unsupported")
            if colour == 2:
                channels = 3
            elif colour == 6:
                channels = 4
            else:
                raise SystemExit(f"colour type {colour} unsupported (need 2 or 6)")
        elif ctype == b"IDAT":
            idat += body
        elif ctype == b"IEND":
            break

    if width is None or channels is None:
        raise SystemExit("PNG has no IHDR")

    data = zlib.decompress(bytes(idat))
    stride = width * channels
    out = bytearray(width * height * 4)
    prev = bytearray(stride)
    pos = 0
    for y in range(height):
        ftype = data[pos]
        pos += 1
        line = bytearray(data[pos:pos + stride])
        pos += stride
        for x in range(stride):
            a = line[x - channels] if x >= channels else 0
            b = prev[x]
            c = prev[x - channels] if x >= channels else 0
            if ftype == 1:
                line[x] = (line[x] + a) & 0xFF
            elif ftype == 2:
                line[x] = (line[x] + b) & 0xFF
            elif ftype == 3:
                line[x] = (line[x] + (a + b) // 2) & 0xFF
            elif ftype == 4:
                line[x] = (line[x] + paeth(a, b, c)) & 0xFF
            elif ftype != 0:
                raise SystemExit(f"unknown PNG filter {ftype}")
        for x in range(width):
            src = x * channels
            dst = (y * width + x) * 4
            out[dst + 0] = line[src + 0]
            out[dst + 1] = line[src + 1]
            out[dst + 2] = line[src + 2]
            out[dst + 3] = line[src + 3] if channels == 4 else 255
        prev = line

    with open(sys.argv[2], "wb") as fh:
        fh.write(b"H1RGBA\\0\\0")
        fh.write(struct.pack("<II", width, height))
        fh.write(bytes(out))
    print(f"[h1] wrote {sys.argv[2]}: {width}x{height} RGBA8")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Create `native/tests/data/make_h1_fixtures.sh`**

```bash
#!/usr/bin/env bash
# Regenerates the H1 known-answer fixtures on a macOS host. Run once; the
# outputs are committed so the gate needs no phone and no network.
#
# The reference MUST come from an implementation that is not ours. macOS
# ImageIO (via sips) is that implementation: it encodes the sample HEIC from a
# plain JPEG and independently decodes it back to PNG. Comparing libheif's
# decode against ImageIO's decode of the same coded bitstream is what makes
# this a known-answer test rather than a tautology.
#
# Keep the fixture small (long edge <= 512) so it can live in git.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_JPEG="${1:-}"
if [ -z "${SOURCE_JPEG}" ] || [ ! -f "${SOURCE_JPEG}" ]; then
  echo "usage: make_h1_fixtures.sh <source.jpg>" >&2
  echo "  pick a photographic JPEG with real colour content -- a synthetic" >&2
  echo "  flat-colour image would pass even with a broken YUV matrix." >&2
  exit 2
fi

WORK="${SCRIPT_DIR}/.h1work"
rm -rf "${WORK}"
mkdir -p "${WORK}"

# 1. Downscale to a committable size, staying photographic.
sips -Z 512 "${SOURCE_JPEG}" --out "${WORK}/small.jpg" > /dev/null

# 2. Encode HEIC with ImageIO.
sips -s format heic "${WORK}/small.jpg" --out "${SCRIPT_DIR}/h1_sample.heic" > /dev/null

# 3. Decode that same HEIC back to PNG with ImageIO -- the independent answer.
sips -s format png "${SCRIPT_DIR}/h1_sample.heic" --out "${WORK}/h1_reference.png" > /dev/null

# 4. Convert to the sidecar the C gate reads.
python3 "${SCRIPT_DIR}/png_to_rgba.py" "${WORK}/h1_reference.png" \
        "${SCRIPT_DIR}/h1_reference.rgba"

rm -rf "${WORK}"
echo "[h1] fixtures ready:"
ls -l "${SCRIPT_DIR}/h1_sample.heic" "${SCRIPT_DIR}/h1_reference.rgba"
shasum -a 256 "${SCRIPT_DIR}/h1_sample.heic" "${SCRIPT_DIR}/h1_reference.rgba"
```

Run it against a photographic JPEG already in the repo, e.g. one under
`image_samples/`, and record the two SHA-256 values in the provenance file of
Step 3. A synthetic flat-colour image is explicitly rejected in the usage text
because a wrong YUV matrix or a full-vs-limited-range mistake is invisible on
flat colour — precisely the defect class spec §7.5 says this gate exists to
catch.

- [ ] **Step 3: Create `native/tests/data/H1_PROVENANCE.md`**

```markdown
# H1 known-answer fixtures

| File | What it is |
|---|---|
| `h1_sample.heic` | An 8-bit HEIC encoded by macOS ImageIO (`sips -s format heic`) from a downscaled photographic JPEG |
| `h1_reference.rgba` | The **independent** answer: ImageIO's own decode of `h1_sample.heic` to PNG, converted to a raw RGBA8 sidecar by `png_to_rgba.py` |

Regenerate with `make_h1_fixtures.sh <source.jpg>` on a macOS host. Paste the
two SHA-256 values it prints into the indented block below (they are what makes
"the fixture changed" a detectable event rather than a silent one), replacing
the angle-bracket placeholders on first creation:

    <sha256 printed by make_h1_fixtures.sh>  h1_sample.heic
    <sha256 printed by make_h1_fixtures.sh>  h1_reference.rgba

## Why the reference is not produced by our decoder

A gate that compares a decoder against its own previous output detects
*regressions* and nothing else: a wrong YUV matrix, a full-vs-limited range
mistake, or swapped chroma planes would be baked into the reference and pass
forever. ImageIO is a separate implementation of the same standard, so a
systematic colour error in our path shows up as a large MAE immediately.

## Pre-registered judgement rule (fixed before the first number existed)

- Expected MAE between libheif and ImageIO on the same coded bitstream is
  dominated by chroma-upsampling and rounding differences: **0.0–1.5** (units
  of 1/255).
- **1.5–2.0** passes but is reported as marginal.
- **Above 2.0** is a FAILURE TO REPORT, not a threshold to raise. The only
  permitted response is diagnosing the range/matrix handling.
- **Exactly 0.0** is suspicious and must be checked: it usually means the
  reference was regenerated from our own decoder.
- A dimension mismatch is an immediate failure, never a resize-and-compare. It
  is also the signal that the `irot`/`imir` transform contract in `heif_api.h`
  is wrong, because ImageIO applies the container transform too.
```

- [ ] **Step 4: Create `native/tests/test_heif_color.cpp`**

```cpp
/**
 * test_heif_color.cpp — H1 known-answer colour gate for the HEIF route.
 *
 * Why this exists (spec section 7.5): the S4 CFA gate validates the RAW
 * demosaic/white-balance/colour-transform pipeline from a Bayer sample. HEIC
 * decoding is YUV 4:2:0 -> RGB with an NCLX/ICC colour description and shares
 * no code with it, so S4 says nothing about HEIC. A YUV range or
 * matrix-coefficient mistake (full vs limited range, BT.601 vs BT.709)
 * produces an image that is obviously THERE and subtly wrong — a smoke test
 * passes it and a reference comparison catches it.
 *
 * Usage:
 *   test_heif_color <sample.heic> <reference.rgba> [--max-mae N]
 *
 * Output contract (deliberately identical in shape to test_cfa_color's):
 * one "[HEIF COLOR] ... PASS|FAIL|SKIP" line; exit 0 ONLY on PASS.
 * A missing fixture prints SKIP and exits non-zero — a gate that skips
 * silently produces a report indistinguishable from a full run.
 */

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "heif_api.h"

namespace {

struct Reference {
  uint32_t width = 0;
  uint32_t height = 0;
  std::vector<uint8_t> rgba;
};

// Sidecar layout, written by native/tests/data/png_to_rgba.py:
//   magic "H1RGBA\0\0" | uint32 width | uint32 height | RGBA8 pixels
bool loadReference(const char *path, Reference *out, const char **why) {
  std::FILE *fh = std::fopen(path, "rb");
  if (!fh) {
    *why = "reference file not found";
    return false;
  }
  char magic[8] = {0};
  uint32_t header[2] = {0, 0};
  bool ok = std::fread(magic, 1, 8, fh) == 8 &&
            std::memcmp(magic, "H1RGBA\0\0", 8) == 0 &&
            std::fread(header, sizeof(uint32_t), 2, fh) == 2;
  if (!ok) {
    std::fclose(fh);
    *why = "reference is not an H1RGBA sidecar";
    return false;
  }
  out->width = header[0];
  out->height = header[1];
  const size_t expected =
      static_cast<size_t>(out->width) * out->height * 4;
  out->rgba.resize(expected);
  const size_t read = std::fread(out->rgba.data(), 1, expected, fh);
  std::fclose(fh);
  if (read != expected) {
    *why = "reference is truncated";
    return false;
  }
  return true;
}

// Mean absolute difference over R, G and B. Alpha is ignored: HEIC has no
// alpha here and both sides synthesise 255.
double meanAbsoluteError(const uint8_t *a, const uint8_t *b, size_t pixels) {
  double sum = 0.0;
  for (size_t i = 0; i < pixels; ++i) {
    const size_t o = i * 4;
    sum += std::fabs(static_cast<double>(a[o + 0]) - b[o + 0]);
    sum += std::fabs(static_cast<double>(a[o + 1]) - b[o + 1]);
    sum += std::fabs(static_cast<double>(a[o + 2]) - b[o + 2]);
  }
  return pixels == 0 ? 0.0 : sum / (static_cast<double>(pixels) * 3.0);
}

}  // namespace

int main(int argc, char **argv) {
  if (argc < 3) {
    std::fprintf(stderr,
                 "usage: test_heif_color <sample.heic> <reference.rgba> "
                 "[--max-mae N]\n");
    return 2;
  }
  const char *heicPath = argv[1];
  const char *refPath = argv[2];
  double maxMae = 2.0;  // spec section 7.5: MAE <= 2/255

  for (int i = 3; i < argc; ++i) {
    if (std::strcmp(argv[i], "--max-mae") == 0 && i + 1 < argc) {
      maxMae = std::atof(argv[++i]);
    } else {
      std::fprintf(stderr, "[HEIF COLOR] FAIL: unknown argument %s\n", argv[i]);
      return 2;
    }
  }

  Reference reference;
  const char *why = "";
  if (!loadReference(refPath, &reference, &why)) {
    // SKIP, and still non-zero: an absent fixture must not read as a pass.
    std::printf("[HEIF COLOR] SKIP: %s (%s)\n", refPath, why);
    return 1;
  }

  HeifResult result;
  const int32_t rc = heif_decode_rgba(heicPath, 0, &result);
  if (rc != 0 || !result.rgba) {
    std::printf("[HEIF COLOR] FAIL: decode error_code=%d for %s\n", rc,
                heicPath);
    heif_release(&result);
    return 1;
  }

  if (result.width != reference.width || result.height != reference.height) {
    // Not a resize-and-compare: a dimension mismatch means the container
    // transform (irot/imir) was handled differently from ImageIO, which is a
    // real defect in the heif_api.h orientation contract.
    std::printf("[HEIF COLOR] FAIL: size %ux%u != reference %ux%u for %s\n",
                result.width, result.height, reference.width, reference.height,
                heicPath);
    heif_release(&result);
    return 1;
  }

  const size_t pixels =
      static_cast<size_t>(result.width) * static_cast<size_t>(result.height);
  const double mae =
      meanAbsoluteError(result.rgba, reference.rgba.data(), pixels);
  const bool pass = mae <= maxMae;

  std::printf("[HEIF COLOR] file=%s size=%ux%u pixels=%zu MAE=%.4f max=%.4f "
              "[%s]\n",
              heicPath, result.width, result.height, pixels, mae, maxMae,
              pass ? "PASS" : "FAIL");

  heif_release(&result);
  return pass ? 0 : 1;
}
```

- [ ] **Step 5: Add the target to `native/cmake/tests.cmake`**

Immediately after the existing `test_cfa_color` block (`tests.cmake:199-201`),
so the two gates sit together:

```cmake
# H1 colour gate (spec section 7.5): HEIC decode vs an ImageIO reference.
# Guarded on DNG_ENABLE_HEIF because the executable calls heif_decode_rgba,
# which is not linked into dng_decoder_native in an OFF build.
if(DNG_ENABLE_HEIF)
    add_executable(test_heif_color tests/test_heif_color.cpp)
    target_include_directories(test_heif_color PRIVATE ${INC_DIR})
    target_link_libraries(test_heif_color PRIVATE dng_decoder_native)
endif()
```

- [ ] **Step 6: Build the gate, run it, and prove it can fail**

Build via the gate runner; the runs themselves are fast and stay in the
foreground.

```bash
cd /Users/jhangyu/project/ceyx-heic/native
cmake --build --preset macos-metal --target test_heif_color     # gate runner
```

```bash
cd /Users/jhangyu/project/ceyx-heic/native
LOG=../docs/logs/2026-08-28/h1-gate.log
mkdir -p ../docs/logs/2026-08-28
{
  echo "# H1 colour gate"
  echo
  echo "Pre-registered rule (fixed before these numbers existed, see"
  echo "tests/data/H1_PROVENANCE.md): PASS iff MAE <= 2.0; 1.5-2.0 is marginal"
  echo "and reported; above 2.0 is a reported FAILURE, never a raised threshold;"
  echo "exactly 0.0 is suspicious and must be checked for a self-referential"
  echo "reference. A dimension mismatch is an immediate failure."
  echo
  echo "## live run"
  ./build/test_heif_color tests/data/h1_sample.heic tests/data/h1_reference.rgba
  echo "RC=$?"
  echo
  echo "## negative control: tolerance 0.0 must FAIL"
  ./build/test_heif_color tests/data/h1_sample.heic tests/data/h1_reference.rgba --max-mae 0.0
  echo "RC=$?"
} > "$LOG" 2>&1
```

`RC=$?` is on the line immediately after each command, inside the artifact.

Judgement, applied to the artifact and not to a memory of it:

```bash
cd /Users/jhangyu/project/ceyx-heic/native
LOG=../docs/logs/2026-08-28/h1-gate.log
grep -c "\[HEIF COLOR\].*PASS" "$LOG"   # expect 1 (the live run)
grep -c "\[HEIF COLOR\].*FAIL" "$LOG"   # expect 1 (the negative control)
grep -c "^RC=0$" "$LOG"                 # expect 1
grep -c "^RC=1$" "$LOG"                 # expect 1
grep -o "MAE=[0-9.]*" "$LOG" | head -1  # record the number in the report
```

Two `[HEIF COLOR]` lines with exactly one PASS and one FAIL is the whole
signal: it proves the comparison is live rather than a constant.

- [ ] **Step 7: Prove a missing fixture is loud (negative control, once)**

```bash
cd /Users/jhangyu/project/ceyx-heic/native
mv tests/data/h1_reference.rgba tests/data/h1_reference.rgba.bak
./build/test_heif_color tests/data/h1_sample.heic tests/data/h1_reference.rgba
echo "MISSING_FIXTURE_RC=$?"     # expect 1, with a SKIP line on stdout
mv tests/data/h1_reference.rgba.bak tests/data/h1_reference.rgba
```

Append the two lines to the artifact. `mv` (not `rm`) because the fixture is a
committed file and this is a shared tree; restoring it is the last action of
the step and `git status --porcelain` must show the file back and unmodified.

- [ ] **Step 8: Commit (Tree A, pathspec'd)**

```bash
git -C /Users/jhangyu/project/ceyx-heic add \
  native/tests/test_heif_color.cpp \
  native/tests/data/h1_sample.heic \
  native/tests/data/h1_reference.rgba \
  native/tests/data/H1_PROVENANCE.md \
  native/tests/data/make_h1_fixtures.sh \
  native/tests/data/png_to_rgba.py \
  docs/logs/2026-08-28/h1-gate.log
git -C /Users/jhangyu/project/ceyx-heic commit \
  -m "test(heif): H1 known-answer colour gate against an ImageIO reference" \
  -- native/tests/test_heif_color.cpp \
     native/tests/data/h1_sample.heic \
     native/tests/data/h1_reference.rgba \
     native/tests/data/H1_PROVENANCE.md \
     native/tests/data/make_h1_fixtures.sh \
     native/tests/data/png_to_rgba.py \
     native/cmake/tests.cmake \
     docs/logs/2026-08-28/h1-gate.log
git -C /Users/jhangyu/project/ceyx-heic status --porcelain
```

Check the repo's `.gitignore` first: a blanket binary-asset rule could swallow
`h1_sample.heic`. If `git check-ignore -v native/tests/data/h1_sample.heic`
reports a match, add a negation next to the existing
`!native/third_party/libomp/lib/libomp.dylib` exception rather than weakening
the blanket rule.

---

## Task 4 — Steps  *(Tree A: `/Users/jhangyu/project/ceyx-heic`)*

- [ ] **Step 1: Write the failing plugin tests**

Create `plugin/test/heif_error_codes_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';

import 'package:ceyx/src/heif_error_codes.dart';
import 'package:ceyx/src/raw_error_codes.dart';

void main() {
  test('HEIF codes are disjoint from the DNG and RAW scales', () {
    const heifCodes = <int>[
      HeifErrorCode.nullPath,
      HeifErrorCode.openFailed,
      HeifErrorCode.noPrimaryItem,
      HeifErrorCode.unsupportedCodec,
      HeifErrorCode.decodeFailed,
      HeifErrorCode.colorConversion,
      HeifErrorCode.allocationFailed,
      HeifErrorCode.sizeOverflow,
      HeifErrorCode.metadataInvalid,
      HeifErrorCode.unknownException,
    ];
    // DNG occupies 0, -1..-8, -100, -101; RAW occupies <= -201 down to -211.
    // The HEIF block starts at -301 so a value can be attributed to exactly
    // one subsystem by inspection, which is what makes a shared int32 error
    // field safe.
    for (final code in heifCodes) {
      expect(code, lessThanOrEqualTo(-301));
      expect(RawErrorCode.isRawError(code), isFalse,
          reason: '$code must not be claimed by the RAW scale');
      expect(HeifErrorCode.isHeifError(code), isTrue);
    }
    expect(heifCodes.toSet(), hasLength(heifCodes.length),
        reason: 'no two HEIF codes may share a value');
  });

  test('names mirror heif_error_name() spelling for comparable log lines', () {
    expect(HeifErrorCode.name(HeifErrorCode.success), 'kHeifSuccess');
    expect(HeifErrorCode.name(HeifErrorCode.decodeFailed), 'kHeifErrDecodeFailed');
    expect(HeifErrorCode.name(-999), 'kHeifErrUnknown');
  });
}
```

Create `plugin/test/heif_result_layout_test.dart`:

```dart
import 'dart:ffi' as ffi;

import 'package:flutter_test/flutter_test.dart';

import 'package:ceyx/src/heif_bindings.dart';

void main() {
  test('HeifResult mirrors the C struct layout exactly', () {
    // heif_api.h freezes this: error_code@0 width@4 height@8 orientation@12
    // rgba@16 rgba_len@24, sizeof==32 on 64-bit. Gotcha #58 in memory.md is a
    // field-count mismatch that shipped once; this is the check that would
    // have caught it.
    expect(ffi.sizeOf<HeifResult>(), 32);
  });
}
```

Create `plugin/test/heif_symbol_absent_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';

import 'package:ceyx/ceyx.dart';

void main() {
  test('a dylib without the HEIF symbols degrades instead of throwing', () {
    // Constructing and querying must NEVER throw: an older dylib that predates
    // the HEIF route has to leave the rest of the decoder fully working. The
    // failure mode this pins is a constructor-time lookupFunction throw, which
    // would kill ALL decoding, not just HEIC.
    final service = HeifDecoderService(
      libraryPath: 'definitely-not-a-dylib-${DateTime.now().microsecond}',
    );
    expect(service.heifAvailable, isFalse);
  });

  test('probeOnWorker returns null rather than throwing when unavailable',
      () async {
    final service = HeifDecoderService(libraryPath: 'no-such-library');
    // The loader calls this and is documented as never throwing, so a null is
    // the only acceptable answer here.
    expect(await service.probeOnWorker('/tmp/whatever.heic'), isNull);
  });

  test('decodeOnWorker throws HeifUnavailableException when unavailable',
      () async {
    final service = HeifDecoderService(libraryPath: 'no-such-library');
    // The DECODE path is allowed to throw — the dispatcher's arm turns any
    // throw into the uniform permanent miss. What it must not do is crash or
    // return a bogus image.
    await expectLater(
      service.decodeOnWorker('/tmp/whatever.heic'),
      throwsA(isA<HeifUnavailableException>()),
    );
  });
}
```

Run `flutter test` inside `plugin/`. Expected: compile errors — `heif_error_codes.dart`, `heif_bindings.dart` and `HeifDecoderService` do not exist yet.

- [ ] **Step 2: Create `plugin/lib/src/heif_error_codes.dart`**

```dart
/// Dart mirror of the HEIF decode error contract.
///
/// Source of truth: `native/include/heif_error_codes.h` (enum `HeifErrorCode`
/// and `heif_error_name()`). Any value or spelling change there MUST be
/// reflected here — `test/heif_error_codes_test.dart` enforces it.
///
/// HEIF codes start at -301 precisely so they can never collide with
/// [DngErrorCode] (0, -1..-8, -100, -101) or [RawErrorCode] (<= -201) inside a
/// shared `int32_t` error field.
library;

abstract final class HeifErrorCode {
  static const int success = 0;
  static const int nullPath = -301;
  static const int openFailed = -302;
  static const int noPrimaryItem = -303;
  static const int unsupportedCodec = -304;
  static const int decodeFailed = -305;
  static const int colorConversion = -306;
  static const int allocationFailed = -307;
  static const int sizeOverflow = -308;
  static const int metadataInvalid = -309;
  static const int unknownException = -310;

  /// Mirrors `heif_error_name()` string for string, including the fallback, so
  /// Dart-side telemetry is comparable with native log lines.
  static String name(int code) {
    switch (code) {
      case success:
        return 'kHeifSuccess';
      case nullPath:
        return 'kHeifErrNullPath';
      case openFailed:
        return 'kHeifErrOpenFailed';
      case noPrimaryItem:
        return 'kHeifErrNoPrimaryItem';
      case unsupportedCodec:
        return 'kHeifErrUnsupportedCodec';
      case decodeFailed:
        return 'kHeifErrDecodeFailed';
      case colorConversion:
        return 'kHeifErrColorConversion';
      case allocationFailed:
        return 'kHeifErrAllocationFailed';
      case sizeOverflow:
        return 'kHeifErrSizeOverflow';
      case metadataInvalid:
        return 'kHeifErrMetadataInvalid';
      case unknownException:
        return 'kHeifErrUnknownException';
      default:
        return 'kHeifErrUnknown';
    }
  }

  /// True when [code] belongs to the HEIF scale (<= -301). Deliberately not
  /// limited to the named values: a future native code below -310 must still
  /// be attributed to this subsystem rather than to an unknown one.
  static bool isHeifError(int code) => code <= -301;
}

/// Thrown when a HEIC decode fails for a reason the native side reported.
class HeifDecodeException implements Exception {
  HeifDecodeException(this.errorCode, this.name, this.message);

  final int errorCode;
  final String name;
  final String message;

  @override
  String toString() => 'HeifDecodeException($errorCode $name): $message';
}

/// Thrown when this build of the native library has no HEIF route at all
/// (built with `-DDNG_ENABLE_HEIF=OFF`, or an older dylib).
///
/// This is deliberately NOT the same thing as Halcyon's D3 "no native decoder"
/// state, which stays reserved for a null decoder: a HEIC on a HEIF-less build
/// must degrade to the ordinary permanent miss, not to a whole-app "decoding
/// unavailable" banner.
class HeifUnavailableException implements Exception {
  HeifUnavailableException(this.path);

  final String path;

  @override
  String toString() =>
      'HeifUnavailableException: this build of dng_decoder_native exports no '
      'HEIF entry points; cannot decode $path';
}
```

- [ ] **Step 3: Create `plugin/lib/src/heif_bindings.dart`**

```dart
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import 'dng_bindings.dart';

/// FFI struct matching C `HeifResult` from `heif_api.h`.
///
/// ABI contract: 6 fields, this order. Layout on 64-bit: sizeof==32,
/// error_code@0, width@4, height@8, orientation@12, rgba@16, rgba_len@24.
/// `test/heif_result_layout_test.dart` pins the size (Gotcha #58: a
/// field-count mismatch shipped once).
final class HeifResult extends ffi.Struct {
  @ffi.Int32()
  external int errorCode;

  @ffi.Uint32()
  external int width;

  @ffi.Uint32()
  external int height;

  @ffi.Int32()
  external int orientation;

  external ffi.Pointer<ffi.Uint8> rgba;

  @ffi.Int64()
  external int rgbaLen;
}

typedef HeifProbeNative =
    ffi.Int32 Function(
      ffi.Pointer<Utf8> path,
      ffi.Pointer<ffi.Uint32> width,
      ffi.Pointer<ffi.Uint32> height,
      ffi.Pointer<ffi.Int32> orientation,
    );
typedef HeifProbeDart =
    int Function(
      ffi.Pointer<Utf8> path,
      ffi.Pointer<ffi.Uint32> width,
      ffi.Pointer<ffi.Uint32> height,
      ffi.Pointer<ffi.Int32> orientation,
    );

typedef HeifDecodeRgbaNative =
    ffi.Int32 Function(
      ffi.Pointer<Utf8> path,
      ffi.Int32 maxDim,
      ffi.Pointer<HeifResult> out,
    );
typedef HeifDecodeRgbaDart =
    int Function(
      ffi.Pointer<Utf8> path,
      int maxDim,
      ffi.Pointer<HeifResult> out,
    );

typedef HeifReleaseNative = ffi.Void Function(ffi.Pointer<HeifResult> result);
typedef HeifReleaseDart = void Function(ffi.Pointer<HeifResult> result);

/// Guarded bindings to the HEIF entry points of `dng_decoder_native`.
///
/// Every lookup is inside a `try`/`catch`, exactly as [DngNativeBindings] does
/// for its additive symbols: a dylib built with `-DDNG_ENABLE_HEIF=OFF`, or
/// any older drop, must leave [available] false rather than throw during
/// construction and kill ALL decoding rather than just HEIC.
class HeifNativeBindings {
  HeifNativeBindings._(this._probe, this._decode, this._release);

  final HeifProbeDart? _probe;
  final HeifDecodeRgbaDart? _decode;
  final HeifReleaseDart? _release;

  bool get available => _probe != null && _decode != null && _release != null;

  HeifProbeDart get probe => _probe!;
  HeifDecodeRgbaDart get decode => _decode!;
  HeifReleaseDart get release => _release!;

  /// Loads from the SAME library [DngNativeBindings] resolves, so there is one
  /// dylib search order in this package rather than two that can disagree
  /// about which copy got loaded.
  factory HeifNativeBindings.fromLibrary(ffi.DynamicLibrary lib) {
    HeifProbeDart? probe;
    HeifDecodeRgbaDart? decode;
    HeifReleaseDart? release;
    try {
      probe = lib.lookupFunction<HeifProbeNative, HeifProbeDart>('heif_probe');
      decode = lib.lookupFunction<HeifDecodeRgbaNative, HeifDecodeRgbaDart>(
        'heif_decode_rgba',
      );
      release = lib.lookupFunction<HeifReleaseNative, HeifReleaseDart>(
        'heif_release',
      );
    } catch (_) {
      // Partial success is treated as absence on purpose: two of three symbols
      // is a broken drop, and calling into it would be worse than degrading.
      probe = null;
      decode = null;
      release = null;
    }
    return HeifNativeBindings._(probe, decode, release);
  }
}
```

- [ ] **Step 4: Create `plugin/lib/src/heif_decoder_service.dart`**

```dart
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'dng_bindings.dart';
import 'heif_bindings.dart';
import 'heif_error_codes.dart';

/// A decoded HEIC image: RGBA8 interleaved, Dart-owned.
class HeifImage {
  HeifImage({
    required this.rgba,
    required this.width,
    required this.height,
    required this.orientation,
  });

  /// RGBA8 interleaved, length == width * height * 4.
  final Uint8List rgba;
  final int width;
  final int height;

  /// Always 1 in phase 2: libheif applies the container's irot/imir transform
  /// during decode, so these pixels are display-ready. See `heif_api.h`.
  final int orientation;
}

/// Extent + orientation of a HEIC's primary item, read from metadata only.
typedef HeifProbeResult = ({int width, int height, int orientation});

class _HeifWorkerResult {
  _HeifWorkerResult({
    required this.rgba,
    required this.width,
    required this.height,
    required this.orientation,
  });

  final TransferableTypedData rgba;
  final int width;
  final int height;
  final int orientation;

  HeifImage toImage() => HeifImage(
    rgba: rgba.materialize().asUint8List(),
    width: width,
    height: height,
    orientation: orientation,
  );
}

/// High-level HEIC/HEIF decoding service.
///
/// Shape deliberately mirrors [DngDecoderService]: the same dylib search order
/// (it reuses [DngNativeBindings]' loader), the same worker-isolate discipline
/// (native bytes are copied into Dart-owned memory inside the worker, and only
/// [TransferableTypedData] crosses the isolate boundary — no native pointer
/// ever does), and the same guarded-symbol degradation.
class HeifDecoderService {
  HeifDecoderService({String? libraryPath}) : _libraryPath = libraryPath;

  final String? _libraryPath;
  HeifNativeBindings? _bindings;
  bool _initialized = false;

  /// Never throws: a missing dylib or a missing symbol both leave the service
  /// unavailable, because HEIC being undecodable must not break RAW decoding.
  void _initialize() {
    if (_initialized) return;
    _initialized = true;
    try {
      final dng = _libraryPath == null
          ? DngNativeBindings.load()
          : DngNativeBindings.fromPath(_libraryPath);
      _bindings = HeifNativeBindings.fromLibrary(dng.library);
    } catch (_) {
      _bindings = null;
    }
  }

  /// Whether this build of the native library exports the HEIF entry points.
  bool get heifAvailable {
    _initialize();
    return _bindings?.available ?? false;
  }

  /// Metadata-only probe of the primary item.
  ///
  /// Returns null — never throws — when the route is unavailable or the native
  /// side reports an error. Its caller is Halcyon's image loader, which is
  /// documented as never throwing, so null is the only usable failure channel.
  Future<HeifProbeResult?> probeOnWorker(String path) async {
    if (!heifAvailable) return null;
    final libraryPath = _libraryPath;
    try {
      return await Isolate.run(() => _probeInIsolate(path, libraryPath));
    } catch (_) {
      return null;
    }
  }

  /// Decodes the primary item on a worker isolate.
  ///
  /// [maxDim] caps the long edge; it is a request, not a guarantee — read back
  /// [HeifImage.width]/[HeifImage.height].
  ///
  /// Throws [HeifUnavailableException] when the route is absent and
  /// [HeifDecodeException] when the native side reports an error. Halcyon's
  /// dispatcher turns either into the uniform permanent miss.
  Future<HeifImage> decodeOnWorker(String path, {int? maxDim}) async {
    if (!heifAvailable) throw HeifUnavailableException(path);
    final libraryPath = _libraryPath;
    // Hoisted to locals before the closure: referencing a field would capture
    // `this`, and an initialized service holds a DynamicLibrary that
    // Isolate.run cannot send (the same trap DngDecoderService documents).
    final requested = (maxDim != null && maxDim > 0) ? maxDim : 0;
    final result = await Isolate.run(
      () => _decodeInIsolate(path, libraryPath, requested),
    );
    return result.toImage();
  }

  /// Static so [Isolate.run] cannot capture parent-isolate state.
  static HeifProbeResult? _probeInIsolate(String path, String? libraryPath) {
    final service = HeifDecoderService(libraryPath: libraryPath).._initialize();
    final bindings = service._bindings;
    if (bindings == null || !bindings.available) return null;

    final pathPtr = path.toNativeUtf8();
    final width = calloc<Uint32>();
    final height = calloc<Uint32>();
    final orientation = calloc<Int32>();
    try {
      final rc = bindings.probe(pathPtr, width, height, orientation);
      if (rc != HeifErrorCode.success) return null;
      if (width.value == 0 || height.value == 0) return null;
      return (
        width: width.value,
        height: height.value,
        orientation: orientation.value,
      );
    } finally {
      malloc.free(pathPtr);
      calloc.free(width);
      calloc.free(height);
      calloc.free(orientation);
    }
  }

  static _HeifWorkerResult _decodeInIsolate(
    String path,
    String? libraryPath,
    int maxDim,
  ) {
    final service = HeifDecoderService(libraryPath: libraryPath).._initialize();
    final bindings = service._bindings;
    if (bindings == null || !bindings.available) {
      throw HeifUnavailableException(path);
    }

    final pathPtr = path.toNativeUtf8();
    final out = calloc<HeifResult>();
    try {
      final rc = bindings.decode(pathPtr, maxDim, out);
      final result = out.ref;
      if (rc != HeifErrorCode.success) {
        throw HeifDecodeException(
          rc,
          HeifErrorCode.name(rc),
          'native heif_decode_rgba failed for $path',
        );
      }
      if (result.rgba == nullptr || result.rgbaLen <= 0) {
        throw HeifDecodeException(
          HeifErrorCode.allocationFailed,
          HeifErrorCode.name(HeifErrorCode.allocationFailed),
          'RGBA buffer is null despite kHeifSuccess',
        );
      }
      final expected = result.width * result.height * 4;
      if (result.rgbaLen != expected) {
        // Native already checks this; re-checking here means a future ABI drift
        // surfaces as a typed exception rather than as a torn image.
        throw HeifDecodeException(
          HeifErrorCode.metadataInvalid,
          HeifErrorCode.name(HeifErrorCode.metadataInvalid),
          'rgba_len=${result.rgbaLen} but width*height*4=$expected',
        );
      }
      // Copy into Dart-owned bytes: TransferableTypedData cannot carry a
      // native-backed typed list across an isolate boundary safely.
      final copy = Uint8List.fromList(
        result.rgba.asTypedList(result.rgbaLen),
      );
      return _HeifWorkerResult(
        rgba: TransferableTypedData.fromList([copy]),
        width: result.width,
        height: result.height,
        orientation: result.orientation,
      );
    } finally {
      // heif_release frees the buffer and zeroes the struct; calloc.free then
      // releases the caller-owned struct itself. Order matters: freeing the
      // struct first would leak the buffer.
      if (bindings.available) bindings.release(out);
      calloc.free(out);
      malloc.free(pathPtr);
    }
  }
}
```

- [ ] **Step 5: Expose the loaded library from `DngNativeBindings`**

`HeifNativeBindings.fromLibrary` needs the `DynamicLibrary` that
`DngNativeBindings` resolved, so that this package has exactly one dylib search
order. Add one getter to `plugin/lib/src/dng_bindings.dart`, next to the other
public accessors:

```dart
  /// The resolved native library, so sibling binding sets (HEIF) can attach to
  /// the SAME image instead of re-running the candidate search and possibly
  /// loading a different copy.
  ffi.DynamicLibrary get library => _lib;
```

This is purely additive: `_lib` already exists as a private field.

- [ ] **Step 6: Export from the package barrel**

Append to `plugin/lib/ceyx.dart`:

```dart
export 'src/heif_decoder_service.dart'
    show HeifImage, HeifProbeResult, HeifDecoderService;

export 'src/heif_error_codes.dart'
    show HeifErrorCode, HeifDecodeException, HeifUnavailableException;
```

`heif_bindings.dart` is deliberately **not** exported: it is the FFI layer, and
the DNG/RAW surfaces keep theirs private too. The plugin's own tests import it
by path (`package:ceyx/src/heif_bindings.dart`), which is how
`raw_bindings_layout_test.dart` already works.

- [ ] **Step 7: Teach the pod to carry the two dylibs**

In `plugin/macos/ceyx.podspec`, extend the existing `vendored_libraries` line
and its explanatory comment:

```ruby
  # libdng_decoder_native.dylib links liblcms2/libjpeg (LibRaw's colour
  # management + JPEG deps) via find_package(), which resolves to Homebrew on
  # the build machine. native/cmake/pipeline.cmake's POST_BUILD step vendors
  # those two next to the dylib and repoints all three to @rpath/<name>, so
  # once CocoaPods embeds all three in Frameworks/ the loader resolves them
  # without requiring Homebrew on the host machine.
  #
  # Phase 2 (HEIC): libheif/libde265 are built by
  # native/scripts/fetch_heif_deps.sh with CMAKE_INSTALL_NAME_DIR=@rpath, so
  # they already carry @rpath install names and need no rewriting -- they are
  # simply staged next to the decoder dylib by native/cmake/heif.cmake and
  # embedded here. They are DYNAMICALLY linked on purpose: both are
  # LGPL-3.0-or-later, and a replaceable .dylib in Frameworks/ satisfies
  # section 4(d)(1) with no obligation to ship relinkable object files.
  s.vendored_libraries = 'Libraries/libdng_decoder_native.dylib',
                         'Libraries/liblcms2.2.dylib',
                         'Libraries/libjpeg.8.dylib',
                         'Libraries/libheif.1.dylib',
                         'Libraries/libde265.0.dylib'
```

CocoaPods fails the pod install if a listed `vendored_libraries` entry is
absent, so `plugin/macos/Libraries/` must contain both files before any Flutter
macOS build. They get there from `scripts/build_apps.py` Phase 1's sibling
`*.dylib` copy loop (Task 8); until that has run once, a `flutter build macos`
in this worktree will fail with a missing-file error naming the exact library —
that is the intended loud failure, not a regression to debug.

- [ ] **Step 8: Run the plugin tests**

```bash
cd /Users/jhangyu/project/ceyx-heic/plugin
flutter test -j 1
dart analyze
```

Expected: `All tests passed!` and no analyzer issues. The three new test files
run without a real dylib — they exercise the layout constant and the
absent-symbol degradation path only.

- [ ] **Step 9: Commit (Tree A, pathspec'd)**

```bash
git -C /Users/jhangyu/project/ceyx-heic add \
  plugin/lib/src/heif_bindings.dart \
  plugin/lib/src/heif_error_codes.dart \
  plugin/lib/src/heif_decoder_service.dart \
  plugin/test/heif_error_codes_test.dart \
  plugin/test/heif_result_layout_test.dart \
  plugin/test/heif_symbol_absent_test.dart
git -C /Users/jhangyu/project/ceyx-heic commit \
  -m "feat(heif): Dart FFI surface for the HEIC decode route" \
  -- plugin/lib/src/heif_bindings.dart \
     plugin/lib/src/heif_error_codes.dart \
     plugin/lib/src/heif_decoder_service.dart \
     plugin/lib/src/dng_bindings.dart \
     plugin/lib/ceyx.dart \
     plugin/macos/ceyx.podspec \
     plugin/test/heif_error_codes_test.dart \
     plugin/test/heif_result_layout_test.dart \
     plugin/test/heif_symbol_absent_test.dart
git -C /Users/jhangyu/project/ceyx-heic status --porcelain
```

Six files are new and need `git add`; three are tracked. The pathspec lists all
nine.

---

## Task 5 — Steps  *(Tree B: `/Users/jhangyu/project/Halcyon-decoders`)*

- [ ] **Step 1: Point the dependency at the HEIC worktree**

In `pubspec.yaml`, replace lines 46-47:

```yaml
  ceyx:
    path: ../ceyx/plugin
```

with:

```yaml
  # PHASE-2 DEV REDIRECT — MUST BE REVERTED BY TASK 9.
  # The HEIF Dart surface (HeifDecoderService) lives on ceyx's
  # feature/heic-decode branch, which is checked out at ../ceyx-heic. The live
  # ../ceyx worktree is consumed by other sessions and must not be modified,
  # so phase-2 development points here instead. Task 9 reverts this line to
  # `path: ../ceyx/plugin` and pairs the revert with merging
  # feature/heic-decode into ceyx main; the phase is not complete until both
  # have happened.
  ceyx:
    path: ../ceyx-heic/plugin
```

Then `flutter pub get`.

The `PHASE-2 DEV REDIRECT` marker is what Task 9's acceptance greps for, and
what makes an accidental merge of this state visible in review.

- [ ] **Step 2: Invert the phase-1 "not yet" assertion**

In `test/models/supported_photo_formats_test.dart`, the phase-1 TC-302 test
contains:

```dart
      expect(SupportedPhotoFormats.isSupportedPath('e.heic'), isFalse,
          reason: 'HEIC is phase 2 and must not be claimed yet');
```

Replace it with:

```dart
      expect(SupportedPhotoFormats.isSupportedPath('e.heic'), isTrue,
          reason: 'phase 2 claims HEIC: the native libheif route exists');
      expect(SupportedPhotoFormats.isSupportedPath('f.HEIF'), isTrue,
          reason: 'extension matching is case-insensitive');
```

Inverting rather than deleting is deliberate: a deleted assertion leaves no
trace in the diff that a documented phase boundary was crossed.

- [ ] **Step 3: Add the phase-2 registry tests**

Append inside the existing `group('phase-1 bitmap formats', …)`'s sibling
scope in `test/models/supported_photo_formats_test.dart`:

```dart
  group('phase-2 HEIC formats', () {
    test('TC-302: .heic/.heif are bitmap-decode, not engine bitstreams', () {
      for (final path in ['a.heic', 'b.heif', 'C.HEIC', 'D.HEIF']) {
        expect(SupportedPhotoFormats.isSupportedPath(path), isTrue);
        expect(SupportedPhotoFormats.isBitmapDecodePath(path), isTrue);
        expect(
          SupportedPhotoFormats.isEncodedBitstreamPath(path),
          isFalse,
          reason: 'the Flutter engine cannot decode HEIC on every platform, '
              'which is why it needs the native route at all',
        );
        expect(SupportedPhotoFormats.hasFullDecodeRoute(path), isTrue);
      }
      expect(SupportedPhotoFormats.bitmapDecodeExtensions,
          {'.tif', '.tiff', '.heic', '.heif'});
    });

    test('TC-302: a HEIC sibling does not outrank a JPEG sibling', () {
      File f(String name) => File(name);
      // HEIC is deliberately absent from preferredLoadExtensions, exactly like
      // TIFF: a rendered JPEG next to a HEIC is the cheaper, engine-decodable
      // file and must keep winning.
      expect(
        SupportedPhotoFormats.bestFileToLoad([f('a.heic'), f('a.jpg')])!.path,
        'a.jpg',
      );
      expect(
        SupportedPhotoFormats.bestFileToLoad([f('a.heic')])!.path,
        'a.heic',
        reason: 'the supported-file fallback still picks it up when the whole '
            'group is HEIC',
      );
    });
  });
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `flutter test test/models/supported_photo_formats_test.dart`
Expected: FAIL — `isSupportedPath('a.heic')` is false and
`bitmapDecodeExtensions` is `{'.tif', '.tiff'}`.

- [ ] **Step 5: Extend the registry**

In `lib/models/supported_photo_formats.dart`, replace the phase-1
`bitmapDecodeExtensions` declaration (the two-element literal
`{'.tif', '.tiff'}` and its doc comment) with the three declarations below.

The dispatcher needs to tell "route to the native libheif arm" from "route to
`package:image`", so the HEIC subset gets its own named const — and
`bitmapDecodeExtensions` is then a spread UNION of the two family sets rather
than a hand-written four-element literal, so the subset and the whole can never
disagree about what a `.heic` is:

```dart
  static const Set<String> tiffExtensions = {'.tif', '.tiff'};

  static const Set<String> heifExtensions = {'.heic', '.heif'};

  /// Already-rendered bitmap containers with no cheap encoded bitstream that a
  /// full decoder can still turn into RGBA: TIFF via `package:image`, HEIC via
  /// the native libheif route in `ceyx` (phase 2). Membership here is what
  /// gives a format the widened `NativeImageNeedsRawDecode` escape hatch, the
  /// sidebar's sized-decode fallback and the export arm — all three derive
  /// from this one set.
  static const Set<String> bitmapDecodeExtensions = {
    ...tiffExtensions,
    ...heifExtensions,
  };
```

Then add the predicate next to the existing ones:

```dart
  /// True for the containers the native libheif route decodes. Used by
  /// `full_decoder_dispatch.dart` to pick the HEIF arm; kept separate from
  /// [isBitmapDecodePath] because that set also contains TIFF, which goes to
  /// `package:image` instead.
  static bool isHeifPath(String path) {
    return heifExtensions.contains(p.extension(path).toLowerCase());
  }
```

Const set spreads are legal in a `const` context in Dart 3, so
`bitmapDecodeExtensions` stays `static const` and no allocation moves to
runtime.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd /Users/jhangyu/project/Halcyon-decoders
flutter test test/models/supported_photo_formats_test.dart
flutter analyze
```
Expected: `All tests passed!` and `No issues found!`.

- [ ] **Step 7: Run the whole suite and read the failures deliberately**

Run `flutter test -j 1` (gate runner if it exceeds the foreground timeout).

Expected: **failures are likely and are informative**, because `.heic` now
reaches the loader's bitmap branch while the probe seam (Task 6) and the
dispatcher arm (Task 7) do not exist yet. Any failure whose message is about
HEIC orientation or an unroutable extension is expected and is fixed by the
next two tasks — do NOT paper over it by narrowing the registry. Any failure
about TIFF, WebP or RAW is a real regression in this task and must be fixed
here.

Record which failures were seen, so Task 7's green run is a proven transition
rather than an assumption.

- [ ] **Step 8: Commit (Tree B, pathspec'd)**

```bash
git -C /Users/jhangyu/project/Halcyon-decoders commit \
  -m "feat(formats): claim .heic/.heif as bitmap-decode containers" \
  -- lib/models/supported_photo_formats.dart \
     test/models/supported_photo_formats_test.dart \
     pubspec.yaml \
     pubspec.lock
git -C /Users/jhangyu/project/Halcyon-decoders status --porcelain
```

All four files are tracked. `pubspec.lock` moves with the path redirect and
must be committed with it, or the next `flutter pub get` on another machine
silently resolves a different `ceyx`.

---

## Task 6 — Steps  *(Tree B)*

- [ ] **Step 1: Write the failing probe test**

Create `test/services/image_pipeline/bitmap_container_probe_test.dart`:

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/services/image_pipeline/bitmap_container_probe.dart';

import '../../support/synthetic_dng.dart';

void main() {
  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('halcyon_bitmap_probe');
  });
  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<String> write(String name, Uint8List bytes) async {
    final file = File('${tmp.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  group('TC-319: the probe seam routes by container family', () {
    test('a .tif is read by the IFD0 walker, not the HEIF probe', () async {
      var heifCalls = 0;
      Future<BitmapContainerExtent?> neverHeif(String path) async {
        heifCalls++;
        return null;
      }

      final path = await write(
        'scan.tif',
        buildSyntheticTiffHeader(width: 800, height: 600, orientation: 6),
      );
      final extent = await probeBitmapContainer(path, heifProbe: neverHeif);
      expect(extent, isNotNull);
      expect(extent!.width, 800);
      expect(extent.height, 600);
      expect(extent.orientation, 6);
      expect(
        heifCalls,
        0,
        reason: 'a TIFF must never reach the native HEIF probe — that would '
            'load a dylib on a path that has a pure-Dart answer',
      );
    });

    test('a .heic is read by the HEIF probe, not the IFD0 walker', () async {
      var heifCalls = 0;
      Future<BitmapContainerExtent?> fakeHeif(String path) async {
        heifCalls++;
        return (width: 4032, height: 3024, orientation: 1);
      }

      // Content is irrelevant: the IFD0 walker would return null on ISO-BMFF
      // anyway, so a non-null answer can only have come from the HEIF arm.
      final path = await write('shot.heic', Uint8List.fromList([0, 0, 0, 24]));
      final extent = await probeBitmapContainer(path, heifProbe: fakeHeif);
      expect(heifCalls, 1);
      expect(extent, isNotNull);
      expect(extent!.width, 4032);
      expect(extent.height, 3024);
      expect(extent.orientation, 1);
    });

    test('an unavailable HEIF probe yields null, never a throw', () async {
      Future<BitmapContainerExtent?> unavailable(String path) async => null;
      final path = await write('shot2.heic', Uint8List.fromList([0, 0, 0, 24]));
      expect(await probeBitmapContainer(path, heifProbe: unavailable), isNull);
    });

    test('a throwing HEIF probe is swallowed into null', () async {
      Future<BitmapContainerExtent?> boom(String path) async =>
          throw StateError('dylib exploded');
      final path = await write('shot3.heic', Uint8List.fromList([0, 0, 0, 24]));
      // The loader is documented as never throwing, so the seam beneath it
      // must absorb everything.
      expect(await probeBitmapContainer(path, heifProbe: boom), isNull);
    });

    test('bitmapContainerOrientation falls back to 1 when nothing answers',
        () async {
      Future<BitmapContainerExtent?> unavailable(String path) async => null;
      final path = await write('shot4.heic', Uint8List.fromList([0, 0, 0, 24]));
      expect(
        await bitmapContainerOrientation(path, heifProbe: unavailable),
        kDefaultExifOrientation,
      );
    });
  });
}
```

Add the import of `image_source_types.dart` if `kDefaultExifOrientation` is not
already reachable from `bitmap_container_probe.dart`'s export surface.

- [ ] **Step 2: Write the failing loader tests**

Append to `test/services/image_pipeline/dart_image_loader_test.dart`, inside
`void main() { … }`:

```dart
  group('phase-2 HEIC', () {
    late Directory heicTmp;

    setUpAll(() {
      heicTmp = Directory.systemTemp.createTempSync('halcyon_heic_loader');
    });
    tearDownAll(() {
      if (heicTmp.existsSync()) heicTmp.deleteSync(recursive: true);
    });

    Future<String> writeHeic(String name) async {
      final file = File('${heicTmp.path}${Platform.pathSeparator}$name');
      // A stub ISO-BMFF-looking header is enough: the loader never decodes,
      // and the probe is injected, so no byte of this file is parsed.
      await file.writeAsBytes(
        Uint8List.fromList([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70]),
        flush: true,
      );
      return file.path;
    }

    test('TC-314: a .heic at preview returns NeedsRawDecode carrying the '
        'orientation the probe supplied', () async {
      final path = await writeHeic('a.heic');
      final result = await dartImageLoad(
        path,
        purpose: ImageRequestPurpose.preview,
        probe: (_) async => (width: 4032, height: 3024, orientation: 6),
      );
      expect(result, isA<NativeImageNeedsRawDecode>());
      final signal = result as NativeImageNeedsRawDecode;
      expect(signal.exifOrientation, 6);
      expect(
        signal.declaredPreviewsUnreadable,
        isFalse,
        reason: 'a bitmap container is never preview-probed, so AD-022 cannot '
            'apply to it',
      );
    });

    test('TC-314: a null probe answer waves through with orientation 1',
        () async {
      // The degradation path: no dylib, no symbol, or a native error. It must
      // still reach the decoder, which is what produces the permanent miss —
      // refusing here would lose the distinction TC-316 depends on.
      final path = await writeHeic('b.heif');
      final result = await dartImageLoad(
        path,
        purpose: ImageRequestPurpose.preview,
        probe: (_) async => null,
      );
      expect(result, isA<NativeImageNeedsRawDecode>());
      expect(
        (result as NativeImageNeedsRawDecode).exifOrientation,
        kDefaultExifOrientation,
      );
    });

    test('TC-315: a .heic at sidebarThumbnail is a failure and NEVER '
        'NeedsRawDecode', () async {
      final path = await writeHeic('c.heic');
      var probeCalls = 0;
      final result = await dartImageLoad(
        path,
        purpose: ImageRequestPurpose.sidebarThumbnail,
        probe: (_) async {
          probeCalls++;
          return (width: 4032, height: 3024, orientation: 1);
        },
      );
      expect(result, isNot(isA<NativeImageNeedsRawDecode>()));
      expect(result, isA<NativeImageFailure>());
      expect((result as NativeImageFailure).code, 'NO_THUMBNAIL');
      expect(
        probeCalls,
        0,
        reason: 'the sidebar bails before the probe: an FFI round trip per '
            'thumbnail would be paid for an answer that is discarded',
      );
    });

    test('TC-320: a HEIC declaring 30000x30000 is IMAGE_TOO_LARGE', () async {
      final path = await writeHeic('huge.heic');
      // 30000 * 30000 * 4 == 3.6e9 > 1.5e9. The file is 8 bytes long, so any
      // other result would prove the check ran after a decode attempt.
      final result = await dartImageLoad(
        path,
        purpose: ImageRequestPurpose.preview,
        probe: (_) async => (width: 30000, height: 30000, orientation: 1),
      );
      expect(result, isA<NativeImageFailure>());
      expect((result as NativeImageFailure).code, 'IMAGE_TOO_LARGE');
    });
  });
```

- [ ] **Step 3: Run both test files to verify they fail**

```bash
cd /Users/jhangyu/project/Halcyon-decoders
flutter test test/services/image_pipeline/bitmap_container_probe_test.dart
flutter test test/services/image_pipeline/dart_image_loader_test.dart
```
Expected: FAIL — `bitmap_container_probe.dart` does not exist, and
`dartImageLoad` has no `probe` parameter.

- [ ] **Step 4: Create `lib/services/image_pipeline/bitmap_container_probe.dart`**

```dart
import 'package:ceyx/ceyx.dart';

import '../../models/supported_photo_formats.dart';
import 'dng_embedded_jpeg_extractor.dart';
import 'image_source_types.dart';

/// Extent and orientation of an already-rendered bitmap container, read from
/// metadata only — never by decoding.
typedef BitmapContainerExtent = ({int width, int height, int orientation});

/// Injection seam for the native HEIF metadata probe, so tests can exercise
/// every branch without loading a dylib.
typedef HeifExtentProbe = Future<BitmapContainerExtent?> Function(String path);

/// Reads a HEIC's primary-item extent through the `ceyx` FFI surface.
///
/// Never throws and never reports a partial answer: an absent library, an
/// absent symbol, or a native error all become `null`. This is the layer that
/// owns the "is there a decoder on this platform" question (contract C-3), so
/// that `dart_image_loader.dart` can stay free of `Platform` checks.
Future<BitmapContainerExtent?> heifExtentProbe(String path) async {
  try {
    final probe = await HeifDecoderService().probeOnWorker(path);
    if (probe == null) return null;
    return (
      width: probe.width,
      height: probe.height,
      orientation: probe.orientation,
    );
  } catch (_) {
    return null;
  }
}

/// One question — "how big is this container and which way up is it?" — with
/// one answer per container family:
///
///   .heic/.heif -> the native libheif probe (ISO-BMFF; the IFD0 walker
///                  returns null on it, which would silently mean
///                  "unknown extent, orientation 1")
///   everything  -> `DngEmbeddedJpegExtractor`'s bounded IFD0 walk, which is
///                  what TIFF and every TIFF-structured RAW already used
///
/// Returning `null` means "unknown", and callers must treat it as permission
/// to continue, not as a failure: that is exactly how the loader has always
/// treated an unreadable IFD0.
Future<BitmapContainerExtent?> probeBitmapContainer(
  String path, {
  HeifExtentProbe heifProbe = heifExtentProbe,
}) async {
  try {
    if (SupportedPhotoFormats.isHeifPath(path)) {
      return heifProbe(path);
    }
    final dims = await DngEmbeddedJpegExtractor.readImageDimensions(path);
    if (dims == null) return null;
    final orientation = await DngEmbeddedJpegExtractor.readOrientation(path);
    return (
      width: dims.width,
      height: dims.height,
      orientation: orientation ?? kDefaultExifOrientation,
    );
  } catch (_) {
    // The loader above this is documented as never throwing, and the sidebar
    // path below it treats a bad orientation as cosmetic. Swallowing here
    // keeps both promises with one catch instead of three.
    return null;
  }
}

/// Orientation alone, for callers that already know the extent is fine — the
/// sidebar's sized-decode path. Falls back to [kDefaultExifOrientation] when
/// nothing can answer, which is the identity transform.
Future<int> bitmapContainerOrientation(
  String path, {
  HeifExtentProbe heifProbe = heifExtentProbe,
}) async {
  final extent = await probeBitmapContainer(path, heifProbe: heifProbe);
  return extent?.orientation ?? kDefaultExifOrientation;
}
```

Note the deliberate asymmetry: the TIFF arm reads dimensions **first** and
returns `null` when they are unreadable, exactly reproducing the phase-1
behaviour where a null extent waves through the budget check. Reading the
orientation of a container whose dimensions could not be read would be a new,
unrequested behaviour.

- [ ] **Step 5: Thread the probe through `dart_image_loader.dart`**

Add the import:

```dart
import 'bitmap_container_probe.dart';
```

Change the signature (an optional named parameter with a default keeps
`dartImageLoad` a subtype of the `NativeImageLoad` typedef, so no call site
changes):

```dart
Future<NativeImageResult> dartImageLoad(
  String path, {
  required ImageRequestPurpose purpose,
  // Injected so this file needs no format knowledge beyond the registry
  // predicate and stays free of Platform checks (contract C-3): HEIC's extent
  // and orientation live in ISO-BMFF boxes that the TIFF IFD0 walker cannot
  // read, and reaching them means an FFI call that must not exist in a unit
  // test.
  BitmapContainerProbe probe = probeBitmapContainer,
}) async {
```

with the typedef declared in `bitmap_container_probe.dart`:

```dart
/// The loader's view of the probe: path in, extent out, never throws.
typedef BitmapContainerProbe = Future<BitmapContainerExtent?> Function(
  String path,
);
```

Then replace the body of the bitmap branch (currently
`dart_image_loader.dart:78-96`) — the two `DngEmbeddedJpegExtractor` calls
become one probe call:

```dart
      final extent = await probe(path);
      if (extent != null &&
          extent.width * extent.height * 4 > kDecodedPixelBudgetBytes) {
        // The budget moves WITH the escape hatch, so it covers TIFF and HEIC.
        // This is stricter than JPEG/WebP on purpose: these decodes happen on
        // the Dart heap or in the native decoder, where the failure mode is a
        // process OOM rather than an engine-side decode error. A null extent
        // (unreadable IFD0, or a HEIF probe that could not answer) waves
        // through, exactly as on the RAW path below.
        return const NativeImageFailure(
          'IMAGE_TOO_LARGE',
          'decode exceeds the decoded-pixel budget',
        );
      }
      return NativeImageNeedsRawDecode(
        exifOrientation: extent?.orientation ?? kDefaultExifOrientation,
        // Structurally false: no preview probe ran, so the container cannot
        // have "declared previews that were all unreadable" (AD-022).
      );
```

The `purpose != ImageRequestPurpose.preview` early return **stays above this
block, unchanged**. That ordering is what TC-315 pins: the sidebar returns
`NO_THUMBNAIL` before the probe runs, so no FFI round trip is paid per
thumbnail for an answer that is thrown away.

Nothing else in the file changes. In particular the `strictPreview` guard and
the RAW `NativeImageNeedsRawDecode` return stay gated on `isDecodablePath`.

- [ ] **Step 6: Switch the sidebar's orientation read**

In `lib/services/image_pipeline/image_preload_controller.dart`, at the sized
sidebar decode (currently `:1077-1079`), replace:

```dart
                final orientation =
                    await DngEmbeddedJpegExtractor.readOrientation(file.path) ??
                    kDefaultExifOrientation;
```

with:

```dart
                // One orientation source for every container family: the IFD0
                // walker for RAW/TIFF, the native probe for HEIC. Calling the
                // walker directly here would silently give every HEIC
                // orientation 1, because it cannot read ISO-BMFF.
                final orientation =
                    await bitmapContainerOrientation(file.path);
```

and add `import 'bitmap_container_probe.dart';`. If
`DngEmbeddedJpegExtractor` becomes unused in this file, remove its import —
`flutter analyze` flags an unused import.

- [ ] **Step 7: Run the tests to verify they pass**

```bash
cd /Users/jhangyu/project/Halcyon-decoders
flutter test test/services/image_pipeline/bitmap_container_probe_test.dart
flutter test test/services/image_pipeline/dart_image_loader_test.dart
flutter analyze
```
Expected: `All tests passed!` twice and `No issues found!`.

TC-305/306/307 (the phase-1 TIFF cases) must be green **without modification**.
If any of them changed behaviour, the probe's TIFF arm is not a faithful
reproduction of the two calls it replaced — fix the arm, not the tests.

- [ ] **Step 8: Verify the invariants mechanically**

```bash
cd /Users/jhangyu/project/Halcyon-decoders
grep -c "Platform\." lib/services/image_pipeline/dart_image_loader.dart   # expect 0
grep -c "class .* extends NativeImageResult" lib/services/image_pipeline/image_source_types.dart  # expect 3
git diff --stat -- lib/services/image_pipeline/image_source_types.dart    # expect no output
grep -n "isDecodablePath" lib/services/image_pipeline/dart_image_loader.dart  # strictPreview guard AND the RAW gate
```

- [ ] **Step 9: Commit (Tree B, pathspec'd)**

```bash
git -C /Users/jhangyu/project/Halcyon-decoders add \
  lib/services/image_pipeline/bitmap_container_probe.dart \
  test/services/image_pipeline/bitmap_container_probe_test.dart
git -C /Users/jhangyu/project/Halcyon-decoders commit \
  -m "feat(image-pipeline): read HEIC extent and orientation through a probe seam" \
  -- lib/services/image_pipeline/bitmap_container_probe.dart \
     lib/services/image_pipeline/dart_image_loader.dart \
     lib/services/image_pipeline/image_preload_controller.dart \
     test/services/image_pipeline/bitmap_container_probe_test.dart \
     test/services/image_pipeline/dart_image_loader_test.dart
git -C /Users/jhangyu/project/Halcyon-decoders status --porcelain
```

---

## Task 7 — Steps  *(Tree B)*

- [ ] **Step 1: Write the failing dispatcher tests**

Append to `test/services/image_pipeline/full_decoder_dispatch_test.dart`,
inside `void main() { … }`:

```dart
  group('phase-2 HEIC arm', () {
    test('TC-309: routes .heic/.heif to the HEIF arm, never to TIFF or RAW',
        () async {
      final calls = <String>[];
      Future<DecodedRgba> heifArm(String path) async {
        calls.add(path);
        return _fakeDecoded();
      }

      Future<DecodedRgba> never(String path) async =>
          fail('only the HEIF arm may run for a HEIC container');

      for (final name in ['a.heic', 'b.HEIF']) {
        final decoded = await dispatchFullDecode(
          '${tmp.path}${Platform.pathSeparator}$name',
          rawArm: never,
          tiffArm: never,
          heifArm: heifArm,
        );
        expect(decoded.rgba[0], 0xA5);
      }
      expect(calls, hasLength(2));
    });

    test('TC-309: the sized path routes .heic to the HEIF arm with maxDim',
        () async {
      var heifCalls = 0;
      Future<DecodedRgba> heifArm(String path, {required int maxDim}) async {
        expect(maxDim, 200);
        heifCalls++;
        return _fakeDecoded();
      }

      Future<DecodedRgba> never(String path, {required int maxDim}) async =>
          fail('only the HEIF arm may run for a HEIC container');

      await dispatchSizedDecode(
        '${tmp.path}${Platform.pathSeparator}a.heic',
        maxDim: 200,
        rawArm: never,
        tiffArm: never,
        heifArm: heifArm,
      );
      expect(heifCalls, 1);
    });

    test('TC-316: an unavailable HEIF library becomes a decoder throw, not a '
        'crash and not the D3 no-decoder state', () async {
      // What the ceyx service does on a build with -DDNG_ENABLE_HEIF=OFF.
      Future<DecodedRgba> unavailable(String path) async =>
          throw HeifUnavailableException(path);

      await expectLater(
        dispatchFullDecode(
          '${tmp.path}${Platform.pathSeparator}gone.heic',
          heifArm: unavailable,
        ),
        throwsA(isA<HeifUnavailableException>()),
      );
    });

    test('TC-316: PhotoSource turns that throw into the uniform permanent '
        'miss, with failureCode null', () async {
      final source = PhotoSource(
        loader: (path, {required purpose}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        dngDecoder: (path) async => throw HeifUnavailableException(path),
      );
      final outcome = await source.load('/tmp/gone.heic', longEdge: 2800);
      expect(outcome.payload, isNull);
      expect(outcome.deferred, isFalse);
      expect(
        outcome.failureCode,
        isNull,
        reason: 'NO_NATIVE_DECODER (D3) stays reserved for dngDecoder == null; '
            'a HEIC on a HEIF-less build is an ordinary permanent miss, and '
            'the app must not report "decoding unavailable" app-wide',
      );
      expect(outcome.observedCost, SourceCost.expensive);
    });

    test('TC-317: a length/geometry mismatch is rejected before it can reach '
        'decodeImageFromPixels', () async {
      // The adapter's own check. A buffer that disagrees with its declared
      // geometry would otherwise blow _imageFromPixels' assert deep inside the
      // provider, where the message names neither the file nor the decoder.
      await expectLater(
        heifImageToDecodedRgba(
          rgba: Uint8List(4 * 2 * 4 - 1),
          width: 4,
          height: 2,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('31'), contains('32')),
          ),
        ),
      );
    });

    test('TC-317: a consistent buffer passes through unchanged', () async {
      final rgba = Uint8List(4 * 2 * 4);
      rgba[0] = 0xA5;
      final decoded =
          await heifImageToDecodedRgba(rgba: rgba, width: 4, height: 2);
      expect(decoded.width, 4);
      expect(decoded.height, 2);
      expect(decoded.rgba[0], 0xA5);
    });
  });
```

Add the imports the file needs: `package:ceyx/ceyx.dart` (for
`HeifUnavailableException`), `photo_source.dart`, and
`heif_decode_service.dart`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/services/image_pipeline/full_decoder_dispatch_test.dart`
Expected: FAIL — `dispatchFullDecode` has no `heifArm` parameter and
`heifImageToDecodedRgba` does not exist.

- [ ] **Step 3: Create `lib/services/image_pipeline/heif_decode_service.dart`**

```dart
import 'dart:typed_data';

import 'package:ceyx/ceyx.dart';

import 'dng_decode_contract.dart';

/// Adapter from `ceyx`'s HEIF surface to the frozen [DngFullDecoder] /
/// [DngSizedDecoder] seam. Mirrors `dng_decode_service.dart` deliberately:
/// same length check, same StateError shape, same "read the dimensions back"
/// discipline for the sized path.
///
/// Kept production-clean: no dylib-preload workaround and no dev-only path
/// hacks. The two LGPL dylibs land in `<App>.app/Contents/Frameworks/` because
/// `ceyx` is a Flutter FFI plugin whose pod vendors them, and the package's
/// own search order finds them there.

/// The single place the RGBA geometry invariant is enforced on the HEIC path.
///
/// `PixelPayload`'s assert and `_imageFromPixels`' invariant both depend on
/// `rgba.length == width * height * 4`. Native checks it too; checking again
/// here means a future ABI drift surfaces as a named error instead of as an
/// assert deep inside the image provider, where the message names neither the
/// file nor the decoder.
Future<DecodedRgba> heifImageToDecodedRgba({
  required Uint8List rgba,
  required int width,
  required int height,
}) async {
  final expectedLength = width * height * 4;
  if (rgba.length != expectedLength) {
    throw StateError(
      'ceyx HEIF decode length mismatch: rgba.length=${rgba.length} but '
      'width*height*4=$expectedLength (width=$width, height=$height)',
    );
  }
  return DecodedRgba(rgba: rgba, width: width, height: height);
}

/// [DngFullDecoder]-shaped HEIC arm.
///
/// Throws [HeifUnavailableException] when this build of the native library has
/// no HEIF route, and [HeifDecodeException] when the decode itself fails.
/// Both are ordinary decoder throws downstream: `photo_source.dart`'s step-3b
/// catch converts them into the uniform permanent miss, and the D3
/// `kNoNativeDecoderCode` state stays reserved for a null decoder.
Future<DecodedRgba> decodeHeifFull(String path) async {
  final image = await HeifDecoderService().decodeOnWorker(path);
  return heifImageToDecodedRgba(
    rgba: image.rgba,
    width: image.width,
    height: image.height,
  );
}

/// [DngSizedDecoder]-shaped HEIC arm (sidebar thumbnails).
///
/// [maxDim] is forwarded as a request; the native side may return full
/// resolution, so the dimensions are read back rather than assumed.
Future<DecodedRgba> decodeHeifSized(
  String path, {
  required int maxDim,
}) async {
  final image = await HeifDecoderService().decodeOnWorker(path, maxDim: maxDim);
  return heifImageToDecodedRgba(
    rgba: image.rgba,
    width: image.width,
    height: image.height,
  );
}

const DngFullDecoder halcyonHeifFullDecoder = decodeHeifFull;
const DngSizedDecoder halcyonHeifSizedDecoder = decodeHeifSized;
```

Note: the returned `HeifImage.orientation` is deliberately **not** used here.
It is always 1 by the `heif_api.h` contract (libheif applies `irot`/`imir`
during decode), and the orientation the pipeline acts on is the one carried on
`NativeImageNeedsRawDecode` from the probe — one value, one path, so AD-024's
single-table rule is not weakened.

- [ ] **Step 4: Add the arm to `full_decoder_dispatch.dart`**

Add the import:

```dart
import 'heif_decode_service.dart';
```

Extend both dispatch functions. `dispatchFullDecode` becomes:

```dart
/// `isDecodablePath`, NOT `isRawPath`: the latter also matches D2 browse-only
/// containers (.cr2/.iiq/.mrw) the engine cannot decode, and routing one of
/// those to the engine arm would be a guaranteed-failing FFI round trip
/// instead of the immediate refusal the D2 ruling wants.
///
/// HEIC is checked FIRST and with its own predicate: `.heic` is also in
/// `bitmapDecodeExtensions`, so a plain `isBitmapDecodePath` test would send
/// it to `package:image`, which cannot read ISO-BMFF.
Future<DecodedRgba> dispatchFullDecode(
  String path, {
  DngFullDecoder rawArm = halcyonDngFullDecoder,
  DngFullDecoder tiffArm = decodeTiffFull,
  DngFullDecoder heifArm = halcyonHeifFullDecoder,
}) async {
  if (SupportedPhotoFormats.isHeifPath(path)) return heifArm(path);
  if (SupportedPhotoFormats.isBitmapDecodePath(path)) return tiffArm(path);
  if (SupportedPhotoFormats.isDecodablePath(path)) return rawArm(path);
  throw UnsupportedError('no full-decode route for $path');
}

Future<DecodedRgba> dispatchSizedDecode(
  String path, {
  required int maxDim,
  DngSizedDecoder rawArm = halcyonDngSizedDecoder,
  DngSizedDecoder tiffArm = decodeTiffSized,
  DngSizedDecoder heifArm = halcyonHeifSizedDecoder,
}) async {
  if (SupportedPhotoFormats.isHeifPath(path)) {
    return heifArm(path, maxDim: maxDim);
  }
  if (SupportedPhotoFormats.isBitmapDecodePath(path)) {
    return tiffArm(path, maxDim: maxDim);
  }
  if (SupportedPhotoFormats.isDecodablePath(path)) {
    return rawArm(path, maxDim: maxDim);
  }
  throw UnsupportedError('no sized-decode route for $path');
}
```

Also update the file's header comment's routing block to:

```
///   .heic/.heif -> the native libheif route in ceyx (phase 2)
///   .tif/.tiff  -> package:image decodeTiff on a worker isolate
///   RAW         -> the existing Ceyx engine decode (unchanged)
///   otherwise   -> UnsupportedError
```

`halcyonFullDecoder` / `halcyonSizedDecoder` at the bottom of the file are
**not** touched: the new arms are optional named parameters, so both tear-offs
stay subtypes of their seam typedefs and the `const` wiring in
`app_state.dart:95` and `main.dart:39` keeps compiling untouched.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd /Users/jhangyu/project/Halcyon-decoders
flutter test test/services/image_pipeline/full_decoder_dispatch_test.dart
flutter analyze
```
Expected: `All tests passed!` and `No issues found!`. Phase 1's TC-308/TC-309
tests must be green **unchanged** — the TIFF and RAW arms only moved down one
line each.

- [ ] **Step 6: Verify the composition root did not drift**

```bash
cd /Users/jhangyu/project/Halcyon-decoders
git diff --stat -- lib/providers/app_state.dart lib/main.dart   # expect no output
grep -n "const DngFullDecoder halcyonFullDecoder" lib/services/image_pipeline/full_decoder_dispatch.dart
grep -n "const DngSizedDecoder halcyonSizedDecoder" lib/services/image_pipeline/full_decoder_dispatch.dart
grep -n "isHeifPath" lib/models/supported_photo_formats.dart lib/services/image_pipeline/full_decoder_dispatch.dart lib/services/image_pipeline/bitmap_container_probe.dart
```

An empty diff on the two composition-root files is the mechanical proof that
adding a third format cost zero wiring — which is the whole point of the
dispatcher.

- [ ] **Step 7: Run the full suite**

Run `flutter test -j 1` (gate runner if it exceeds the foreground timeout).
Expected: `All tests passed!` with `RC=0`.

This is the run that must clear every failure Task 5 Step 7 recorded. Compare
against that recorded list explicitly: a failure that disappeared for a reason
other than "Tasks 6 and 7 landed" is a signal to investigate, not to celebrate.

- [ ] **Step 8: Commit (Tree B, pathspec'd)**

```bash
git -C /Users/jhangyu/project/Halcyon-decoders add \
  lib/services/image_pipeline/heif_decode_service.dart
git -C /Users/jhangyu/project/Halcyon-decoders commit \
  -m "feat(image-pipeline): dispatch .heic/.heif to the native libheif arm" \
  -- lib/services/image_pipeline/heif_decode_service.dart \
     lib/services/image_pipeline/full_decoder_dispatch.dart \
     test/services/image_pipeline/full_decoder_dispatch_test.dart
git -C /Users/jhangyu/project/Halcyon-decoders status --porcelain
```

---

## Task 8 — Steps  *(Tree B, plus one docs-only commit in Tree A)*

- [ ] **Step 1: Record the pre-task baseline**

```bash
cd /Users/jhangyu/project/Halcyon-decoders
grep -c "no-colour-gate" scripts/build_apps.py    # record this number
```

The acceptance criterion is that this count is **unchanged** at the end of the
task. It is the mechanical guard against the H1 gate quietly acquiring a
skip flag or the S4 opt-out being widened.

- [ ] **Step 2: Add the HEIF dist constant and the `--check` rows**

Near `NATIVE_SPECS` in `scripts/build_apps.py`:

```python
# Phase 2 (HEIC): the vendored libheif/libde265 distribution, produced by
# ceyx's native/scripts/fetch_heif_deps.sh. Only macOS is VERIFIED in phase 2;
# the Windows and Linux rows exist so the readiness check reports them, not
# because either has been run (spec section 7.3 records that build_apps.py's
# Windows native path has never run end to end).
HEIF_DIST = Path("native") / "third_party" / "heif-dist"
HEIF_RUNTIME_LIBS = {
    "macos": ["libheif.1.dylib", "libde265.0.dylib"],
    "windows": ["heif.dll", "libde265.dll"],
    "linux": ["libheif.so.1", "libde265.so.0"],
}
HEIF_VERIFIED_TARGETS = ("macos",)
```

Then add the helper next to `check_native`:

```python
def check_heif_dist(target, layout, problems):
    """Phase 0 readiness for the HEIC route (spec section 7.3).

    A missing dist is a PROBLEM, not a warning: cmake/heif.cmake fails the
    configure with the same message, and discovering it at Phase 0 costs
    seconds instead of a full Halide-backed configure.
    """
    dist = layout.native / "third_party" / "heif-dist"
    provenance = dist / "PROVENANCE.md"
    if not provenance.exists():
        problems.append(
            f"{provenance} not found - the HEIC route needs the vendored "
            "libheif/libde265 distribution. Run "
            "ceyx/native/scripts/fetch_heif_deps.sh, or configure the native "
            "build with -DDNG_ENABLE_HEIF=OFF to build without HEIC."
        )
        return

    libs = HEIF_RUNTIME_LIBS.get(target, [])
    missing = [name for name in libs if not (dist / "lib" / name).exists()]
    if missing:
        problems.append(
            f"HEIF dist at {dist} is missing {', '.join(missing)} - re-run "
            "ceyx/native/scripts/fetch_heif_deps.sh."
        )
        return

    suffix = "" if target in HEIF_VERIFIED_TARGETS else \
        " [unverified (phase 2 scope: macOS)]"
    for name in libs:
        ok(f"libheif/libde265 dist: {name}{suffix}")
```

Call it from `check_target`, alongside the existing `check_native(...)` call,
guarded on a native build being due:

```python
    if native_due and native_target_for(target) is not None:
        check_heif_dist(native_target_for(target), layout, problems)
```

- [ ] **Step 3: Add the H1 gate to Phase 1**

In `build_native`, immediately **after** the S4 `if args.cfa_sample_dng: … else: …`
block and **before** `dest_dir = layout.decoder / spec["dest"]`:

```python
    # H1 known-answer colour gate (spec section 7.5). S4 validates the RAW
    # demosaic/colour pipeline from a Bayer sample and shares no code with
    # HEIC's YUV -> RGB conversion, so extending --cfa-sample-dng to HEIC
    # would be theatre; HEIC needs its OWN reference comparison, in the same
    # Phase 1 position, failing the build the same way.
    #
    # There is deliberately no --no-h1-gate: the fixtures are committed, so
    # unlike S4 there is no "the user did not supply a sample" case to opt out
    # of. A disabled HEIF route is the only skip, and it prints a line.
    heif_sample = layout.native / "tests" / "data" / "h1_sample.heic"
    heif_reference = layout.native / "tests" / "data" / "h1_reference.rgba"
    if not heif_sample.exists() or not heif_reference.exists():
        fail(
            "the H1 HEIC colour-gate fixtures are missing.",
            hints=[
                f"expected {heif_sample} and {heif_reference}",
                "Regenerate with ceyx/native/tests/data/make_h1_fixtures.sh, or "
                "configure the native build with -DDNG_ENABLE_HEIF=OFF if this "
                "target has no HEIC route.",
            ],
        )
    run_checked("cmake", ["--build", "--preset", spec["preset"], "--target", "test_heif_color"],
                native_dir, "cmake build (test_heif_color)")
    h1_exe_name = "test_heif_color.exe" if host_os() == "windows" else "test_heif_color"
    h1_exe = build_dir / h1_exe_name
    if not h1_exe.exists():
        fail(f"{h1_exe_name} not found at {h1_exe}")
    run_checked(str(h1_exe), [str(heif_sample), str(heif_reference)], build_dir,
                "test_heif_color H1 colour gate")
```

`run_checked` is what makes a non-zero exit fail the build, exactly as it does
for `test_cfa_color` — the gate is not a print statement whose output nobody
reads.

- [ ] **Step 4: Verify the shipped bundle in Phase 3**

Extend `verify_macos_slices` (or add a sibling called from the same place):

```python
def verify_macos_heif_rpaths(app_bundle, problems):
    """Mechanically prove spec section 7.2's DYNAMIC-linking decision shipped.

    Not a style check: static linking would trigger LGPL-3 section 4(d)(0)'s
    duty to ship relinkable object files with every release. `otool -L` naming
    both libraries via @rpath, and both files being present in Frameworks/, is
    the evidence that a user can replace them.
    """
    frameworks = app_bundle / "Contents" / "Frameworks"
    decoder = frameworks / "libdng_decoder_native.dylib"
    if not decoder.exists():
        problems.append(f"{decoder} not bundled")
        return
    for name in HEIF_RUNTIME_LIBS["macos"]:
        if not (frameworks / name).exists():
            problems.append(
                f"{name} is not in {frameworks} - the HEIC route would fail to "
                "load at runtime on any machine without a system libheif."
            )
    out = subprocess.run(["otool", "-L", str(decoder)],
                         capture_output=True, text=True, check=False).stdout
    for name in HEIF_RUNTIME_LIBS["macos"]:
        if f"@rpath/{name}" not in out:
            problems.append(
                f"{decoder} does not name @rpath/{name} - either HEIF was "
                "linked statically (which the LGPL-3 position forbids) or the "
                "install name was not set to @rpath."
            )
```

- [ ] **Step 5: Write `docs/legal/LGPL-3.0.txt` (both trees)**

Fetch the canonical text once and place an identical copy in each tree:

```bash
curl -fsSL https://www.gnu.org/licenses/lgpl-3.0.txt \
  -o /Users/jhangyu/project/Halcyon-decoders/docs/legal/LGPL-3.0.txt
cp /Users/jhangyu/project/Halcyon-decoders/docs/legal/LGPL-3.0.txt \
   /Users/jhangyu/project/ceyx-heic/docs/legal/LGPL-3.0.txt
head -3 /Users/jhangyu/project/Halcyon-decoders/docs/legal/LGPL-3.0.txt
```

The head must show `GNU LESSER GENERAL PUBLIC LICENSE`. LGPL-3 is a set of
additional permissions on top of GPL-3 and its text references GPL-3 by name;
if the app's licence surface renders these files, `GPL-3.0.txt` should be
placed alongside it by the same command against
`https://www.gnu.org/licenses/gpl-3.0.txt`.

- [ ] **Step 6: Write the attribution (both trees)**

Create `/Users/jhangyu/project/Halcyon-decoders/docs/legal/THIRD_PARTY_LICENSES.md`:

```markdown
# Third-Party Licenses

Components redistributed inside Halcyon's app bundles. This file is an index,
not a substitute for the licence texts it points at.

The RAW/DNG native stack (Adobe DNG SDK, Halide, LibRaw, RawSpeed, pugixml,
zlib, libjpeg-turbo, lcms2) is documented in the `ceyx` repository at
`docs/legal/THIRD_PARTY_LICENSES.md`; it ships inside
`libdng_decoder_native.dylib`, which Halcyon embeds.

## libheif

- Used for: HEIF/AVIF container parsing, primary-item selection, `irot`/`imir`
  transform handling, and YUV to RGBA colour conversion for `.heic`/`.heif`.
- Version: **1.23.2**
- Source: <https://github.com/strukturag/libheif/releases/download/v1.23.2/libheif-1.23.2.tar.gz>
- SHA-256: `8bd5d41d19dc84536d118b04774709f244df6104ef66d623dad5fa4650143405`
- Licence: **LGPL-3.0-or-later** (`docs/legal/LGPL-3.0.txt`). The sample
  applications and the Go/C++ wrappers are MIT, and none of them are built or
  shipped.
- Linkage: **dynamic**. Shipped as `libheif.1.dylib` in
  `<App>.app/Contents/Frameworks/` and loaded by the OS loader.

## libde265

- Used for: HEVC (H.265) intra decoding of the coded image item.
- Version: **1.1.1**
- Source: <https://github.com/strukturag/libde265/releases/download/v1.1.1/libde265-1.1.1.tar.gz>
- SHA-256: `fd48a927e94ed74fc7ce8829d222b9d8599fcbfe8b6448ba66705babc56ab219`
- Licence: **LGPL-3.0-or-later** (`docs/legal/LGPL-3.0.txt`).
- Linkage: **dynamic**. Shipped as `libde265.0.dylib` in
  `<App>.app/Contents/Frameworks/`.

## Why dynamic linking, and what it means for you

LGPL-3 section 4 requires that a user be able to relink the application against
a modified version of the library. Both libraries are shipped as separate,
replaceable `.dylib` files, which satisfies section 4(d)(1) directly: replacing
`libheif.1.dylib` or `libde265.0.dylib` inside
`<App>.app/Contents/Frameworks/` with your own build is sufficient, and no
object files for Halcyon's own code need to be published.

No encoder is built or shipped. x265 (GPL-2.0), libaom, dav1d, kvazaar, SVT-AV1
and rav1e are all disabled at configure time, so nothing GPL-2.0 enters the
binary. The exact configure flags are recorded in
`ceyx/native/scripts/fetch_heif_deps.sh` and
`ceyx/native/third_party/heif-dist/PROVENANCE.md`.

## Corresponding source

The complete corresponding source for either library is the tarball at the URL
and SHA-256 above, built with the flags recorded in the fetch script.
```

Then append the same two component sections (libheif, libde265) plus the
dynamic-linking paragraph to
`/Users/jhangyu/project/ceyx-heic/docs/legal/THIRD_PARTY_LICENSES.md`, matching
that file's existing heading style (`## <Component>` with
Used for / Linkage / License / Text bullets).

- [ ] **Step 7: Run the readiness check**

```bash
cd /Users/jhangyu/project/Halcyon-decoders
python3 scripts/build_apps.py macos --check
echo "CHECK_RC=$?"
grep -c "no-colour-gate" scripts/build_apps.py   # must equal the Step 1 baseline
flutter analyze
```
Expected: `CHECK_RC=0`, output containing a `libheif.1.dylib` and a
`libde265.0.dylib` line, the baseline count unchanged, `No issues found!`.

- [ ] **Step 8: Commit (two separate commits, one per tree)**

Tree B:

```bash
git -C /Users/jhangyu/project/Halcyon-decoders add \
  docs/legal/LGPL-3.0.txt \
  docs/legal/THIRD_PARTY_LICENSES.md
git -C /Users/jhangyu/project/Halcyon-decoders commit \
  -m "build(heif): gate HEIC on the H1 colour check and record LGPL-3 attribution" \
  -- scripts/build_apps.py \
     docs/legal/LGPL-3.0.txt \
     docs/legal/THIRD_PARTY_LICENSES.md
git -C /Users/jhangyu/project/Halcyon-decoders status --porcelain
```

Tree A:

```bash
git -C /Users/jhangyu/project/ceyx-heic add docs/legal/LGPL-3.0.txt
git -C /Users/jhangyu/project/ceyx-heic commit \
  -m "docs(legal): libheif/libde265 LGPL-3 attribution and dynamic-linking position" \
  -- docs/legal/LGPL-3.0.txt \
     docs/legal/THIRD_PARTY_LICENSES.md
git -C /Users/jhangyu/project/ceyx-heic status --porcelain
```

Two commits, two repositories, one pathspec each. Never one command spanning
both trees.

---

## Task 9 — Steps  *(Tree B; the ceyx merge is a lead checklist)*

- [ ] **Step 1: Update `README.md`**

In the supported-formats section, after the existing TIFF entry:

```markdown
- **HEIC / HEIF** (`.heic`, `.heif`) — decoded by a bundled libheif +
  libde265 pair, so the result is identical on every platform rather than
  depending on the OS's own decoder. Verified on **macOS**; the Windows and
  Linux build rules are written but **have not been run** — on a platform
  where the libraries are absent the file is reported unreadable and the app
  starts normally. Multi-image files (bursts, Live Photos, depth and auxiliary
  images) show the primary image only; HDR gain maps and depth maps are
  ignored, and 10/12-bit HEIC is converted to 8 bits for display. Rotation
  recorded as a container transform is applied; a file that carries only an
  EXIF `Orientation` tag and no container transform may display unrotated.
  AVIF is not supported.
```

Do not restate the RAW list, and do not claim Windows or Linux support.

- [ ] **Step 2: Update `README.zh-TW.md`**

Author the same entry as Chinese prose — not a sentence-by-sentence
translation of Step 1 (2026-08-27 precedent). The facts that must survive:
HEIC/HEIF is decoded by a bundled libheif + libde265 pair so every platform
gets the same result; macOS is verified while Windows and Linux are written but
unrun; a platform without the libraries reports the file as unreadable and the
app still starts; only the primary image of a multi-image file is shown; HDR
gain maps and depth maps are ignored; 10/12-bit is converted to 8-bit;
container rotation is applied but an EXIF-only orientation may not be; AVIF is
unsupported.

Then run the punctuation check. It pairs bracket **widths**, which is
independent of where the lines wrap — a neighbour-character check silently
misses every bracket that a hard line break pushed to a line start
(2026-08-27 lesson):

```bash
cd /Users/jhangyu/project/Halcyon-decoders
python3 - <<'PY'
import re
text = open('README.zh-TW.md', encoding='utf-8').read()
# Half-width punctuation is correct inside code, so strip those regions first.
text = re.sub(r'```.*?```', '', text, flags=re.S)
text = re.sub(r'`[^`]*`', '', text)
bad = list(re.finditer(r'（[^）\n]*\)|\([^)\n]*）', text))
print('mixed-width bracket pairs:', len(bad))
for m in bad[:20]:
    print(' ', m.group(0)[:60])
PY
```
Expected: `mixed-width bracket pairs: 0`.

- [ ] **Step 3: Request the full macOS build (gate runner)**

This is the run that produces the S4 and H1 evidence and the shipped bundle.
It is long — **request via test-runner-haiku / the lead**. Note there is no
`--no-colour-gate` anywhere in the invocation, and that is not optional:

```bash
cd /Users/jhangyu/project/Halcyon-decoders
mkdir -p docs/logs/2026-08-28
LOG=docs/logs/2026-08-28/phase2-macos-build.log
python3 scripts/build_apps.py macos --cfa-sample-dng <blue-sky-sample.dng> > "$LOG" 2>&1
echo "BUILD_RC=$?" >> "$LOG"
```

The sample DNG is the same blue-sky file the phase-1 and earlier runbook S4
runs used; ask the lead for its path rather than substituting a different file,
because the S4 threshold was calibrated against it.

- [ ] **Step 4: Prove the built artifact contains the code under test**

Before reading a single colour number, establish provenance from an observed
build event and the symbol table — never from mtime (2026-08-23 lesson):

```bash
cd /Users/jhangyu/project/Halcyon-decoders
LOG=docs/logs/2026-08-28/phase2-macos-build.log
grep -c "^BUILD_RC=0$" "$LOG"                                  # expect 1
grep -c "cmake build (dng_decoder_native)" "$LOG"              # expect >= 1: the library WAS rebuilt in this run
grep -c "cmake build (test_heif_color)" "$LOG"                 # expect >= 1
grep -c "\[CFA COLOR\].*PASS" "$LOG"                           # expect >= 1  (S4)
grep -c "\[HEIF COLOR\].*PASS" "$LOG"                          # expect >= 1  (H1)
grep -c "no-colour-gate" "$LOG"                                # expect 0

APP=$(ls -d build/macos/Build/Products/Release/*.app | head -1)
ls "$APP/Contents/Frameworks/" | grep -E 'libheif|libde265|libdng_decoder_native'
nm -gU "$APP/Contents/Frameworks/libdng_decoder_native.dylib" | grep -cE '_heif_(probe|decode_rgba|release)$'   # expect 3
otool -L "$APP/Contents/Frameworks/libdng_decoder_native.dylib" | grep -c '@rpath/libheif\.1\.dylib'            # expect 1
otool -L "$APP/Contents/Frameworks/libdng_decoder_native.dylib" | grep -c '@rpath/libde265\.0\.dylib'           # expect 1
```

`grep -c "cmake build (dng_decoder_native)"` is the observed build event: it
proves this run produced the dylib whose symbols the next line inspects. A
symbol check on a dylib from an earlier run would be an instrument that
confidently confirms whatever was already there.

`grep -c` counts matching **lines**, not matches — with `-E` and the anchored
`$`, three separate symbols mean three lines, which is what makes `3` the right
expectation.

- [ ] **Step 5: Run the Dart gate and write the artifact**

```bash
cd /Users/jhangyu/project/Halcyon-decoders
{
  echo "# Bitmap decoders phase 2 (HEIC) — acceptance gate"
  echo
  echo "Pre-registered pass rule (fixed before this run, per the plan's Task 9):"
  echo "  (a) flutter analyze ends with 'No issues found!' and RC=0"
  echo "  (b) flutter test -j 1 contains 'All tests passed!' and RC=0"
  echo "  (c) this artifact contains all of TC-314 .. TC-320"
  echo "  (d) the macOS build exits RC=0 with an S4 [CFA COLOR] PASS line and"
  echo "      no --no-colour-gate anywhere in the invocation"
  echo "  (e) the H1 gate line reads [HEIF COLOR] ... PASS"
  echo "  (f) otool -L shows both @rpath HEIF dependencies and nm -gU finds"
  echo "      heif_probe, heif_decode_rgba and heif_release"
  echo "Any other outcome is a REPORTED FAILURE, not a re-run with different arguments."
  echo
  echo "commit: $(git rev-parse HEAD)"
  echo "ceyx commit: $(git -C /Users/jhangyu/project/ceyx-heic rev-parse HEAD)"
  echo
  echo '## $ flutter analyze'
  echo '```'
  flutter analyze 2>&1
  RC=$?
  echo "RC=$RC"
  echo '```'
  echo
  echo '## $ flutter test -j 1'
  echo '```'
  flutter test -j 1 2>&1
  RC=$?
  echo "RC=$RC"
  echo '```'
  echo
  echo '## macOS build, S4 and H1 evidence'
  echo 'See docs/logs/2026-08-28/phase2-macos-build.log; the Step-4 checks are reproduced here:'
  echo '```'
  cat docs/logs/2026-08-28/phase2-macos-build.log | grep -E '^BUILD_RC=|\[CFA COLOR\]|\[HEIF COLOR\]|cmake build \('
  echo '```'
} > docs/logs/2026-08-28/bitmap-decoders-phase2-gate.md 2>&1
```

`flutter test -j 1` is mandatory: a parallel run overwrites the progress line
and loses the declared-versus-executed count. `RC=$?` sits on the line
immediately after each command, inside the artifact.

- [ ] **Step 6: Judge the gate against the pre-registered rule**

```bash
cd /Users/jhangyu/project/Halcyon-decoders
A=docs/logs/2026-08-28/bitmap-decoders-phase2-gate.md
grep -c "^RC=0$" "$A"                          # expect 2
grep -c "No issues found!" "$A"                # expect >= 1
grep -c "All tests passed!" "$A"               # expect >= 1
grep -c "^BUILD_RC=0$" "$A"                    # expect 1
grep -c "\[CFA COLOR\].*PASS" "$A"             # expect >= 1
grep -c "\[HEIF COLOR\].*PASS" "$A"            # expect >= 1
grep -c "no-colour-gate" "$A"                  # expect 0
grep -o "TC-3[12][0-9]" "$A" | sort -u         # expect TC-314 .. TC-320
grep -o "TC-3[12][0-9]" "$A" | sort -u | wc -l # expect >= 7
```

If any check fails, STOP and report the failure with the artifact path. Do not
re-run with different arguments (no `-j` other than 1, no test-file subsetting,
no `--no-colour-gate`, no raised H1 tolerance) to obtain a green.

- [ ] **Step 7: Commit the READMEs and the artifacts**

```bash
git -C /Users/jhangyu/project/Halcyon-decoders add \
  docs/logs/2026-08-28/bitmap-decoders-phase2-gate.md \
  docs/logs/2026-08-28/phase2-macos-build.log
git -C /Users/jhangyu/project/Halcyon-decoders commit \
  -m "docs: state HEIC support and record the phase-2 acceptance gate" \
  -- README.md \
     README.zh-TW.md \
     docs/logs/2026-08-28/bitmap-decoders-phase2-gate.md \
     docs/logs/2026-08-28/phase2-macos-build.log
git -C /Users/jhangyu/project/Halcyon-decoders status --porcelain
```

If the build placed updated binaries under `../ceyx-heic/plugin/macos/Libraries/`,
those belong to Tree A and are committed there, in their own commit, by the
lead as part of Step 8's checklist — never swept into this one.

- [ ] **Step 8: MERGE-TIME CHECKLIST FOR THE LEAD — ceyx branch merge and the pubspec revert**

These steps change shared state across two repositories and are **not**
performed by a worker. They are listed in the order they must happen; step (5)
is not valid before step (3).

1. Confirm no other session is mid-write in `/Users/jhangyu/project/ceyx`:
   `git -C /Users/jhangyu/project/ceyx status --porcelain` and a check for
   running builds (`pgrep -f "cmake|flutter"`). A dirty tree or an active build
   means **stop and coordinate**, not merge anyway — this is the tree the
   phase-1 handoff named as live shared state.
2. Commit or confirm-clean every Tree A change:
   `git -C /Users/jhangyu/project/ceyx-heic status --porcelain` must be empty,
   including the freshly placed `plugin/macos/Libraries/libheif.1.dylib` and
   `libde265.0.dylib` (their own commit, pathspec'd, with a message naming the
   pinned versions).
3. Merge `feature/heic-decode` into `ceyx` main from the ceyx main worktree,
   with an explicit pathspec-free merge (a merge is the one operation that
   legitimately spans the tree) and **no** `git stash` / `reset` / `clean` at
   any point.
4. Re-run the ceyx plugin tests **on main after the merge**:
   in-branch green does not prove the cross-branch combination
   (2026-08-16 lesson). `cd /Users/jhangyu/project/ceyx/plugin && flutter test -j 1`.
5. Only now, in Tree B, revert the redirect: `pubspec.yaml`'s `ceyx:` entry
   goes back to `path: ../ceyx/plugin`, the `PHASE-2 DEV REDIRECT` comment
   block is deleted, `flutter pub get` is re-run, and both `pubspec.yaml` and
   `pubspec.lock` are committed together.
6. Verify: `grep -n "ceyx-heic" pubspec.yaml` returns nothing;
   `grep -n "path: ../ceyx/plugin" pubspec.yaml` returns one line;
   `grep -rn "ceyx-heic" lib/ test/ scripts/` returns nothing.
7. Re-run the phase-2 gate (Step 5) against the reverted pubspec. This is the
   run that proves the shipped configuration works, not the development one.
8. Merge `feature/bitmap-decoders` into Halcyon main, then re-run
   `flutter analyze` and `flutter test -j 1` **on main** — the standard
   post-merge gate from the 2026-08-16 lesson.

- [ ] **Step 9: MERGE TIME ONLY — update the SOP docs in place**

Do this **after** both merges, as the last action, and **never** inside a
`git add` / `git commit`. The three files at
`/Users/jhangyu/project/Halcyon/docs/sop/` are gitignored and shared with
sessions working on `main`; editing them earlier risks clobbering concurrent
work.

`memory.md` — append:

```markdown
### AD-036: HEIC decodes through a bundled libheif, dynamically linked, gated by its own known-answer check

Date: 2026-08-28. Phase 2 of the bitmap-decoder work; phase 1 (WebP + TIFF) is AD-035.

`.heic`/`.heif` join `SupportedPhotoFormats.bitmapDecodeExtensions` and
therefore inherit AD-035's routing wholesale: the widened
`NativeImageNeedsRawDecode` -> `DngFullDecoder` escape hatch, the
`hasFullDecodeRoute` sidebar sized-decode gate, and the export arm. No fourth
`NativeImageResult` variant, no second decoder typedef, no change to
`app_state.dart` or `main.dart` — adding the third format cost zero wiring,
which is the dispatcher's whole point.

Decode is native: libheif 1.23.2 + libde265 1.1.1, vendored into ceyx by
`native/scripts/fetch_heif_deps.sh` as a pinned, SHA-256-verified,
**decode-only** distribution (no x265, no libaom, no encoder of any kind), and
**dynamically linked**. Dynamic linking is a licence decision, not a packaging
preference: both libraries are LGPL-3.0-or-later, and a replaceable `.dylib`
in `Frameworks/` satisfies section 4(d)(1) outright, where static linking
would trigger 4(d)(0)'s duty to ship relinkable object files with every
release. `scripts/build_apps.py` Phase 3 asserts both `@rpath` dependencies so
the decision cannot silently regress.

The spec proposed integrating the two libraries with `add_subdirectory`. That
was not possible: libheif's `FindLIBDE265.cmake` does `find_library()` for a
file on disk and cannot see an `add_subdirectory`'d target, so libheif would
have configured, built and installed cleanly **with no HEVC decoder at all** —
a green build that decodes nothing. A built-dist prefix (the same shape as the
vendored Halide distribution) was used instead; the fetch script asserts
`heif_decode_image` is exported and a `libde265` dependency exists, precisely
because that failure is silent.

Two Dart-side additions carry it. `bitmap_container_probe.dart` is an
injectable metadata-probe seam: HEIC's extent and orientation live in ISO-BMFF
boxes that `DngEmbeddedJpegExtractor`'s IFD0 walker cannot read, and reaching
them means an FFI call that must not exist in a unit test. It is what keeps
`dart_image_loader.dart` free of `Platform` checks (contract C-3) while still
letting the decoded-pixel budget cover HEIC. `heif_decode_service.dart` is the
`DngFullDecoder`/`DngSizedDecoder` adapter; the dispatcher checks
`isHeifPath` BEFORE `isBitmapDecodePath`, because `.heic` is in both sets and
`package:image` cannot read ISO-BMFF.

Orientation contract: libheif applies the container's `irot`/`imir` transform
during decode, so pixels arrive display-ready and the native side reports
orientation 1. The ABI keeps the field so a later EXIF-`Orientation` decision
does not break it. Stated limitation: a HEIC carrying only an EXIF Orientation
tag and no container transform may display unrotated.

Colour correctness has its own gate. S4 validates the RAW demosaic pipeline
from a Bayer sample and shares no code with HEIC's YUV-to-RGB conversion, so
extending `--cfa-sample-dng` to HEIC would be theatre — but S4 still runs
unchanged for every build, because the HEIC code lands inside the same library.
The new H1 gate decodes a committed sample HEIC and compares it against a
reference produced by macOS ImageIO — an INDEPENDENT implementation, because a
decoder compared against its own output detects regressions and nothing else —
requiring mean absolute error <= 2/255. Its judgement rule was pre-registered
before the first number existed, and it fails the build the way S4 does. There
is deliberately no `--no-h1-gate`.

Accepted, stated limitations: primary item only (no burst or Live-Photo
secondaries, no HDR gain maps, no depth maps); 10/12-bit converted to 8-bit;
AVIF unsupported; Windows and Linux have build rules but are unverified, and on
any platform without the libraries a HEIC degrades to the ordinary permanent
miss (the D3 `NO_NATIVE_DECODER` state stays reserved for a null decoder).
```

`unit_test.md` — add seven TC-matrix rows:

| TC | Case | Test file |
|---|---|---|
| TC-314 | `.heic` at preview returns `NeedsRawDecode` with the probe's orientation; a null probe waves through at orientation 1 | `test/services/image_pipeline/dart_image_loader_test.dart` |
| TC-315 | `.heic` at sidebarThumbnail returns `NativeImageFailure` and never probes | `test/services/image_pipeline/dart_image_loader_test.dart` |
| TC-316 | An unavailable HEIF library becomes a decoder throw and an ordinary permanent miss, not the D3 code | `test/services/image_pipeline/full_decoder_dispatch_test.dart` |
| TC-317 | An RGBA buffer disagreeing with its geometry is rejected before the image provider sees it | `test/services/image_pipeline/full_decoder_dispatch_test.dart` |
| TC-318 | H1 colour gate: sample HEIC within 2/255 MAE of an ImageIO reference | `ceyx/native/tests/test_heif_color.cpp` (run by `build_apps.py` Phase 1) |
| TC-319 | The probe seam routes `.heic` to the HEIF probe and `.tif` to the IFD0 walker; unavailable and throwing probes both yield null | `test/services/image_pipeline/bitmap_container_probe_test.dart` |
| TC-320 | A HEIC declaring 30000x30000 yields `IMAGE_TOO_LARGE` before any decode | `test/services/image_pipeline/dart_image_loader_test.dart` |

`file_index.md` — add three rows:

| `lib/services/image_pipeline/bitmap_container_probe.dart` | Injectable extent/orientation probe: HEIC via the ceyx FFI, TIFF and RAW via the IFD0 walker |
| `lib/services/image_pipeline/heif_decode_service.dart` | `DngFullDecoder`/`DngSizedDecoder` adapters over `ceyx`'s `HeifDecoderService` |
| `ceyx/native/src/pipeline/heif_decode.cpp`, `ceyx/plugin/lib/src/heif_bindings.dart` | The native HEIC decode route and its Dart FFI surface |

- [ ] **Step 10: Verify the SOP edits landed and nothing leaked into git**

```bash
cd /Users/jhangyu/project/Halcyon-decoders
git status --porcelain | grep "docs/sop" ; echo "leak-check RC=$?"   # expect no match, RC=1
grep -c "AD-036" /Users/jhangyu/project/Halcyon/docs/sop/memory.md                        # expect >= 1
grep -c "bitmap_container_probe.dart" /Users/jhangyu/project/Halcyon/docs/sop/file_index.md  # expect >= 1
grep -o "TC-3[12][0-9]" /Users/jhangyu/project/Halcyon/docs/sop/unit_test.md | sort -u | wc -l  # expect >= 7 in the 314-320 range
```

- [ ] **Step 11: Report the manual check the user owns**

Phase-2 acceptance criterion 9 is **user-run only** and must NOT be attempted
by an agent (standing rule: UI and visual checks belong to the user). Report,
verbatim:

> Remaining manual check: open a folder containing an iPhone HEIC. It should
> appear in the sidebar and render in the detail view with the correct
> orientation. If it renders rotated, that is the stated EXIF-only-orientation
> limitation in AD-036, not a decode failure — please say so and it will be
> filed rather than debugged blind.

---

## Parking lot (report, do not do)

Carried forward from phase 1 plus what phase 2 added:

- WebP EXIF orientation is not applied (phase-1 stated gap).
- The encoded-bitstream branch (JPEG/PNG/WebP) is still outside the
  decoded-pixel budget (pre-existing).
- TIFF and HEIC export inherit the strict preview floor (pre-existing for
  `.dng`, knowingly widened).
- Multi-page TIFF: page 0 only.
- **New (phase 2):** a HEIC carrying only an EXIF `Orientation` tag and no
  `irot`/`imir` container transform displays unrotated. The ABI already carries
  the field needed to fix it.
- **New (phase 2):** AVIF. libheif can decode it with libaom or dav1d; both are
  deliberately disabled and no user need was stated (spec §11).
- **New (phase 2):** Windows and Linux verification of the HEIC native build
  (spec §7.3, explicitly deferred). Note that `build_apps.py`'s Windows native
  path has never run end to end at all — treat the first real Windows run as
  first contact, not a regression test.
- **New (phase 2):** Android `jniLibs` placement for the two `.so` files is
  mechanically the same as the existing decoder library and can follow once
  macOS is green; web has no FFI, so HEIC stays undecodable there.
- **New (phase 2):** the `DngFullDecoder`/`DngSizedDecoder`/`DecodedRgba`
  rename to format-neutral names is now carrying a third format's worth of
  misleading names. Still parked by the 2026-08-26 contract.
