# Halcyon Windows RAW decode pack

This zip contains the committed source of both repos plus a one-click build
script. It is produced by `Halcyon/scripts/package_windows.sh` on the macOS
host; the authoritative procedure it automates is
`Halcyon/docs/logs/2026-08-21/windows-ffi-build-runbook.md` (also inside this
zip), which stays the reference for anything the script cannot do.

## Contents

```
<extracted root>\
  build_windows.ps1        one-click build (W12 native DLL + W14 Flutter app)
  README_WINDOWS.md        this file
  Halcyon\                 Flutter app (committed source only)
  flutter_dng_decoder\     native package (committed source only)
```

The two folders MUST stay siblings: `Halcyon/pubspec.yaml` depends on
`../flutter_dng_decoder/dng_processor_ffi` by relative path.

## Not in this zip (on purpose)

- `.git` history, build trees, `local_data/`, scratch folders.
- The Halide v21 binary distribution (~500 MB, not in git). `build_windows.ps1`
  downloads it automatically into
  `flutter_dng_decoder\dng_processor\native\third_party\halide\`.
- **Photo samples.** Verification (runbook S4/S5/S6) needs real DNG files from
  `local_data/photo_samples/DNG/`. Copy them to the Windows machine yourself.

## Prerequisites (install once, before running the script)

| Requirement | Check |
|---|---|
| Visual Studio 2022 with "Desktop development with C++" | run everything from an **x64 Native Tools Command Prompt for VS 2022** |
| **clang-cl** ("C++ Clang tools for Windows" VS component, or standalone LLVM) | `clang-cl --version` — mandatory, `cl.exe` is not sufficient |
| LunarG Vulkan SDK | `echo %VULKAN_SDK%` non-empty |
| Vulkan 1.1+ GPU + driver | `vulkaninfo` (runtime requirement — decode fails without it) |
| CMake 3.14+ | `cmake --version` |
| Ninja | `ninja --version` (ships with the VS C++ workload) |
| Flutter | `flutter --version` |
| NASM | optional; without it libjpeg-turbo builds with `WITH_SIMD=OFF` |

Internet access is required on first run (Halide distribution + zlib fetched by
CMake).

## Run it

From an **x64 Native Tools Command Prompt for VS 2022**, in the extracted root:

```bat
powershell -ExecutionPolicy Bypass -File .\build_windows.ps1
```

Useful switches:

```bat
:: also run the native blue-sky colour gate (runbook S4)
powershell -ExecutionPolicy Bypass -File .\build_windows.ps1 -CfaSampleDng D:\samples\sky.dng

:: native DLL only, skip the Flutter app build
powershell -ExecutionPolicy Bypass -File .\build_windows.ps1 -SkipFlutterBuild
```

What it does:

1. **Phase 0 / 0b** — checks every prerequisite above and fetches Halide v21.
   Any missing prerequisite is one clear error line, and the script exits
   without building anything.
2. **Phase 1 (W12)** — `cmake --preset windows-vulkan` + build target
   `dng_decoder_native`, then copies the resulting
   `build-windows\dng_decoder_native.dll` into
   `flutter_dng_decoder\dng_processor_ffi\windows\Libraries\`.
3. **Phase 2 (W14)** — `flutter pub get` + `flutter build windows --release` in
   `Halcyon\`, then verifies the DLL landed next to the runner exe in
   `build\windows\x64\runner\Release\`. If it did not, it prints the runbook's
   diagnostics instead of hand-copying the DLL (that would hide a real
   packaging bug).
4. **Phase 3** — prints the manual verification protocol (decode correctness and
   the first-decode 1-second gate). The script does not drive the UI.

The script is idempotent: re-running after fixing an error is safe, and it stops
at the first failure naming the phase.

## After a successful build

The DLL produced here still has to be committed back in the `flutter_dng_decoder`
repo (runbook S4) — this extracted tree has no git history, so copy
`flutter_dng_decoder\dng_processor_ffi\windows\Libraries\dng_decoder_native.dll`
back to the Mac (or to a real checkout) and commit it there.

Record the timing numbers from Phase 3 in the runbook's section 7 "Results".
