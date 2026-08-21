# Windows FFI RAW Decode — Build & Verification Runbook (R2 / AC-R2-7)

> **Scope**: bringing up full-size RAW decode on Windows via `dng_processor_ffi`
> + upstream `../flutter_dng_decoder/dng_processor/native`. This is **not**
> the same subsystem as `windows-verification-runbook.md` (that one covers the
> `windows/runner/*` native bridges — thumbnail/trash/open-with — which are a
> separate MethodChannel layer that already exists and is unrelated to this
> DLL).
> **Contract**: `windows-raw-r1r2-contract.md` §5b AC-R2-5/AC-R2-7/AC-R2-8.
> **Prerequisite reading**: `windows-ffi-upgrade-findings.md` (work items
> W1-W14, backend choice, risk R1-R8).

## One-click path (added 2026-08-21)

Sections 1-6 below are the reference procedure and remain authoritative. They
are now also scripted, so the normal route is:

1. On the Mac: `./scripts/package_windows.sh` — git-archives the committed
   source of Halcyon **and** `../flutter_dng_decoder` into one timestamped zip
   with the required sibling layout, plus `build_windows.ps1` and
   `README_WINDOWS.md` at the zip root.
2. Copy the zip to the Windows laptop and extract it.
3. From an **x64 Native Tools Command Prompt for VS 2022**, in the extracted
   root: `powershell -ExecutionPolicy Bypass -File .\build_windows.ps1`
   (source of the script: `Halcyon/scripts/windows/build_windows.ps1`).

The script transcribes §1 (prereq checks, fail-early), §3+§4 (W12: preset
configure/build, DLL into `dng_processor_ffi\windows\Libraries\`) and §5 (W14:
`flutter pub get` + `flutter build windows --release` + the DLL-next-to-exe
check with §5's diagnostics on failure). It does **not** do the §4 git commit
(the extracted tree has no `.git`) and does **not** perform §5/§6 verification —
it prints that protocol for you to run by hand. It also downloads the Halide
v21 Windows dist named in §1 automatically. Use the manual steps below whenever
the script stops, or when you want to understand what it is doing.

## 0. Read this first — nothing below has run on Windows

Every step in this document was written on a macOS host with no Windows
toolchain available. **Nothing in this runbook has been executed.** The CMake
changes for W1-W9 were authored and can only be checked with `grep`/structural
review on macOS; they have never been configured, compiled, or linked on
Windows. The packaging changes for W10/W11/W13 (this task) were verified only
to the extent that file structure and variable names are correct — whether
`flutter build windows` actually finds and bundles the DLL correctly has never
been observed. Treat every command below as "the intended next step," not as
"a step known to work." Expect the first configure/build attempt to surface
problems findings §5 (R1-R8) didn't anticipate — that is normal for code that
has never touched a real Windows/Vulkan toolchain, and is why this runbook is
written for a human on the actual machine rather than for unattended CI.

If you hit a wall that isn't covered here, that's expected — record what you
tried and what happened, don't guess past it.

---

## 1. Prerequisites (install once)

| Requirement | Why | Notes |
|---|---|---|
| Visual Studio 2022 (or Build Tools) with the "Desktop development with C++" workload | Provides `cl`/MSBuild/CMake generator integration that Flutter's `flutter build windows` drives | Flutter also needs this independent of this task, for `windows/runner` |
| **clang-cl** (LLVM toolchain, installable via the VS installer's "C++ Clang tools" component, or standalone LLVM for Windows) | W3: `-ffp-contract=off` (`CMakeLists.txt:218` in `native/`) has no MSVC equivalent; the color-accuracy byte-exact contract (`CMakeLists.txt:206-218`) depends on it. MSVC (`cl.exe`) is **not** sufficient for this build | Verify with `clang-cl --version` on a Developer Command Prompt |
| Vulkan SDK (LunarG, latest) | W5-W8: GPU backend is Vulkan; build needs `$ENV{VULKAN_SDK}/Lib/vulkan-1.lib` and headers | Installer sets `VULKAN_SDK` env var automatically — confirm with `echo %VULKAN_SDK%` |
| A Vulkan 1.1+ capable GPU + driver, supporting `vk_int8`/`vk_int16`/`vk_int64` Halide feature flags | Runtime requirement, not just build-time — decode will fail at runtime without it (R5 in findings) | If unsure, run `vulkaninfo` (ships with the SDK) after install and check `apiVersion` and available extensions before investing further time |
| CMake 3.14+ | Same floor as the rest of the native tree | Usually bundled with VS; `cmake --version` to confirm |
| NASM (optional) | Only needed if libjpeg-turbo SIMD is enabled (W2b, `WITH_SIMD`); can defer and build with `WITH_SIMD=OFF` first to get a compile pass, then revisit | https://www.nasm.us/ |
| Halide v21 Windows distribution | W1: fetched via `native/scripts/fetch_halide_v21_dist.sh` — **this script is currently hardcoded to the macOS arm64 asset** (`ASSET=Halide-21.0.0-arm-64-osx-...`); until someone patches it for Windows/x86_64 (`Halide-21.0.0-x86-64-windows-b629c80de18f1534ec71fddd8b567aa7027a0876.zip`, confirmed to exist in the v21.0.0 GitHub release), download and extract that asset manually into `native/third_party/halide/` matching the existing macOS layout | See findings W1 row for the exact asset name/URL source |

## 2. Repo layout you need

```
flutter_dng_decoder/                  (sibling checkout, path dependency of Halcyon)
├── dng_processor/
│   └── native/                       ← CMake project, upstream Halide+DNG-SDK+libjpeg build
│       ├── CMakeLists.txt
│       ├── CMakePresets.json         ← add "windows-vulkan" preset here (W9)
│       └── third_party/halide/       ← Halide dist goes here (W1)
└── dng_processor_ffi/
    ├── pubspec.yaml                  ← already declares windows: ffiPlugin: true (W10, done)
    └── windows/
        ├── CMakeLists.txt            ← already present, prebuilt-DLL packaging (W11, done)
        └── Libraries/
            └── dng_decoder_native.dll   ← DOES NOT EXIST YET — this is what W12 produces
```

## 3. Configure + build the native library (W9 preset, once it exists)

As of this writing the `windows-vulkan` CMake preset (W9) may or may not have
landed depending on which round of R2 you're picking up — check
`native/CMakePresets.json` for a `"windows-vulkan"` entry before proceeding. If
it is missing, that work item is still open; do not hand-invent a preset,
report back instead (see findings §3 stage 1/2 for what W1-W9 are supposed to
produce).

From a **Developer Command Prompt for VS 2022** (so `clang-cl` and the Windows
SDK are on `PATH`), with `VULKAN_SDK` set:

```bat
cd flutter_dng_decoder\dng_processor\native
cmake --preset windows-vulkan
cmake --build --preset windows-vulkan --target dng_decoder_native
```

Expected artifact per findings W9: `build-windows\dng_decoder_native.dll` (no
`lib` prefix — `add_library(dng_decoder_native SHARED)` on Windows names the
output exactly `dng_decoder_native.dll`, which is also the bare filename the
Dart bindings `dlopen` — see §5 below).

**If configure fails**, the most likely first-contact issues per findings §5
(risk table) are, roughly in the order you're likely to hit them:
1. `ZLIB::ZLIB` target not found → W2a not landed or vendoring path wrong.
2. `find_package(JPEG REQUIRED)` fails → W2b vendored libjpeg-turbo branch not
   reached (check it covers `WIN32`, not just `ANDROID`).
3. Unknown compiler flag `-ffp-contract=off` → wrong compiler selected in the
   preset (must be clang-cl, not `cl.exe`) — see Prerequisites.
4. `windows.h` macro collisions with dng_sdk/STL (`min`/`max`) → confirms risk
   R4; add `NOMINMAX`/`WIN32_LEAN_AND_MEAN` compile definitions if not already
   present.

**If link fails** with missing `.lib`/`.obj` for a Halide-generated stage,
that's risk R8 (an AOT `.a`→`.lib` extension parametrization spot was missed);
`grep -c '\.a"' native/CMakeLists.txt` in the AOT block should be 0 — if it
isn't, that's the bug, not something to route around by hand-renaming files.

**If everything compiles and links** but `test_cfa_color` fails (blue-sky
B >> R channel assertion), that is exactly the Halide v21 SPIR-V Tuple R==G
bug findings R2 warns about — check that the Stage4 three-channel-split kernel
condition (W7) was generalized from "Android" to "target contains vulkan"
rather than only matching Android.

## 4. W12 — produce and commit the DLL

Once `build-windows\dng_decoder_native.dll` exists and the native test suite
(whatever subset is runnable — at minimum `test_cfa_color` and any color
accuracy tests) passes on this machine:

```bat
copy flutter_dng_decoder\dng_processor\native\build-windows\dng_decoder_native.dll ^
     flutter_dng_decoder\dng_processor_ffi\windows\Libraries\
```

Then, in the `flutter_dng_decoder` repo:
```bat
git add dng_processor_ffi\windows\Libraries\dng_decoder_native.dll
git rm dng_processor_ffi\windows\Libraries\.gitkeep
git commit -m "feat(windows): commit prebuilt dng_decoder_native.dll (W12)"
```

Do not commit anything else from `native/build-windows/` — only the DLL, same
policy as the existing macOS/Android prebuilts (`README.md` "Refreshing the
binaries").

## 5. W14 — end-to-end verification in Halcyon

```bat
cd Halcyon
flutter pub get
flutter build windows --release
```

Check that `build\windows\x64\runner\Release\dng_decoder_native.dll` sits
**next to** `halcyon.exe` in the same directory (this is what `INSTALL_BUNDLE_LIB_DIR`
in `windows/CMakeLists.txt` + the `PLUGIN_BUNDLED_LIBRARIES` install rule is
supposed to produce — see §6 for how to confirm the plugin was picked up at
all before you get this far).

If the DLL is **not** there, do not manually copy it as a workaround — that
would hide a real packaging bug. Instead check, in order:
1. `Halcyon\windows\flutter\generated_plugins.cmake` — does
   `FLUTTER_FFI_PLUGIN_LIST` contain `dng_processor_ffi`? If not, `flutter pub
   get` didn't pick up the plugin declaration (re-check `pubspec.yaml` W10,
   or run `flutter clean` first — stale generated files are a known Flutter
   gotcha).
2. Re-run configure with `cmake --build ... --verbose` (or open the generated
   `.sln` and check the `dng_processor_ffi_library` CMake target's log) and
   grep for `dng_processor_ffi_bundled_libraries` — if the variable resolves
   to empty, that's the exact silent-failure mode `dng_processor_ffi/windows/CMakeLists.txt`
   warns about in its header comment. Confirm the file at
   `dng_processor_ffi/windows/Libraries/dng_decoder_native.dll` actually
   exists at configure time (W12 must have landed first).

Once the DLL is confirmed alongside the exe, launch the built app and open
DNG files from `local_data/photo_samples/DNG/` (do **not** use any other
photo folder — see MEMORY: test-only-with-photo-samples). Confirm:
- `DngResult.errorCode == 0` for each sample.
- No crash, no `RAW_UNSUPPORTED`/`MISSING_PLUGIN` fallback to the Dart preview
  path (that fallback existing is fine as a safety net, but if RAW decode is
  supposed to be working, samples should not be silently falling back to it —
  cross-check against the Dart preview extractor's own logging, if any, to be
  sure you're actually measuring the native path and not accidentally the R1
  fallback succeeding while native decode fails invisibly).

## 6. Timing protocol (Q5 / risk R1 — the 1-second gate)

This is the part findings flagged as the highest-risk unknown (risk R1: no
`VkPipelineCache` persistence fork exists for Windows, unlike Android's
`DNG_CROSS_BUILD` path — see `native/CMakeLists.txt:545,663-708`). Measure
**first decode** and **subsequent decodes** separately; they are expected to
behave very differently because Vulkan shader compilation is a one-time
per-process cost without a persisted pipeline cache.

Procedure:
1. Pick 3-5 representative DNG samples from `local_data/photo_samples/DNG/`
   (vary resolution/camera model if the sample set has variety).
2. Cold-launch the built `halcyon.exe` (fresh process each time you measure
   "first decode" — do not reuse a warm process).
3. For each cold launch, open one sample and record wall-clock time from
   "decode requested" to "decode complete" (`decodeMs + processMs` per the
   findings W14 judgment criterion, or wrap the FFI call site with a
   `Stopwatch` if that field isn't already surfaced to Dart).
4. **Hard gate: if the first decode of any sample exceeds 1000ms
   (memory: one-second-operation-ceiling), STOP.** Do not average it away,
   do not retry until it's fast, do not report a warm-cache number as if it
   were representative. Record:
   - the exact millisecond figure,
   - which sample,
   - GPU model/driver version (`vulkaninfo` output),
   - whether it's a one-time-per-process cost (does the *second* cold launch
     show the same first-decode latency, or does something OS-level cache
     shader compilation across processes already?).
5. After first-decode is recorded (pass or fail), reuse the *same* warm
   process and decode 5-10 more samples without restarting. Record min/median/
   max for these "subsequent decode" numbers separately. These are expected to
   be fast (comparable to the macOS Metal ~110ms baseline per
   memory: image-switch-latency-round2/round3) since the GPU pipeline is
   already built.

**If the 1s gate is breached on first decode**: per the user's Q5 decision
(contract §5b), this is a known, pre-authorized countermeasure — generalizing
the `VkPipelineCache` persistence fork (currently Android/`DNG_CROSS_BUILD`-only,
`native/CMakeLists.txt:545`, `halide_runtime_fork/`) to also cover
`_WIN32`/Vulkan. **Do not start that work directly.** It is a materially
different, weak-symbol-based engineering effort from packaging. Per
`~/.claude/reference/handover-extraction.md`, write a handover document first
(new work items, what was tried, exact timing numbers, GPU/driver info) before
opening a new round — this keeps the next session from re-deriving the same
diagnosis from scratch.

**If the 1s gate passes**: record the numbers in this file's "Results" section
below (or a dated log under `docs/logs/`) and this task's R2 AC-R2-8 is
satisfied — report back per the contract.

## 7. Results (fill in after running on the Windows laptop)

*(Nothing has been run yet. This section is intentionally empty — do not
pre-fill placeholder numbers. When you run the steps above, replace this
paragraph with the actual first/subsequent decode figures, GPU/driver info,
and pass/fail against the 1s gate.)*

---

## 8. Known limitations carried over from findings (do not re-litigate here)

- No CPU fallback backend exists (findings §2) — a machine without a
  compatible Vulkan driver cannot decode RAW on Windows at all, full stop.
- `native/scripts/fetch_halide_v21_dist.sh` is not yet OS/arch-aware (W1) —
  manual extraction is the documented workaround above until that script is
  patched.
- GitHub Actions `windows-latest` runners cannot validate the GPU-execution
  half of this (§4 of findings: no real GPU, software Vulkan has unverified
  feature support) — this runbook assumes a real machine with a real GPU.
