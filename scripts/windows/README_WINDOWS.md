# Halcyon Windows RAW decode pack

This zip contains the committed source of both repos. It is produced by
`Halcyon/scripts/package_windows.sh` on the macOS host; the authoritative
procedure it automates is
`Halcyon/docs/logs/2026-08-21/windows-ffi-build-runbook.md` (also inside this
zip), which stays the reference for anything the script cannot do.

## Contents

```
<extracted root>\
  README_WINDOWS.md        this file
  Halcyon\                 Flutter app (committed source only)
    scripts\build_apps.py  the build script — run this
  ceyx\                    native package (committed source only)
```

The two folders MUST stay siblings: `Halcyon/pubspec.yaml` depends on
`../ceyx/plugin` by relative path.

There is deliberately no copy of the build script at the zip root. A root copy
and the one under `Halcyon\scripts\` could drift apart, and only one of them
would be the version under version control.

## Not in this zip (on purpose)

- `.git` history, build trees, `local_data/`, scratch folders.
- The Halide v21 binary distribution (~500 MB, not in git). `build_apps.py`
  downloads it automatically into
  `ceyx\native\third_party\halide\` and checks it
  against a recorded sha256.
- **Photo samples.** Verification (runbook S4/S5/S6) needs real DNG files from
  `local_data/photo_samples/DNG/`. Copy them to the Windows machine yourself.

## Prerequisites (install once, before running the script)

| Requirement | Check |
|---|---|
| Python 3 | `python --version` — the script itself is Python, stdlib only |
| Visual Studio 2022 with "Desktop development with C++" | `build_apps.py` finds it via vswhere and injects vcvars64 itself — **no Native Tools prompt needed** |
| **clang-cl** ("C++ Clang tools for Windows" VS component, or standalone LLVM) | `clang-cl --version` — mandatory, `cl.exe` is not sufficient |
| LunarG Vulkan SDK | `echo %VULKAN_SDK%` non-empty |
| Vulkan 1.1+ GPU + driver | `vulkaninfo` (runtime requirement — decode fails without it) |
| CMake 3.14+ | `cmake --version` |
| Ninja | `ninja --version` (ships with the VS C++ workload) |
| Flutter | `flutter --version` |
| Windows Developer Mode | required by Flutter for symlink support |
| NASM | optional; without it libjpeg-turbo builds with `WITH_SIMD=OFF`, which is a performance difference whose output-parity with the SIMD path is unverified |

Internet access is required on first run (Halide distribution + zlib fetched by
CMake).

`python build_apps.py windows --check` runs every check above and exits non-zero
naming the first missing one, without building anything.

## Run it

From any ordinary command prompt, in `Halcyon\`:

```bat
python scripts\build_apps.py windows
```

Useful flags:

```bat
:: prerequisites only, build nothing
python scripts\build_apps.py windows --check

:: run the native blue-sky colour gate (runbook S4)
python scripts\build_apps.py windows --cfa-sample-dng D:\samples\sky.dng

:: native DLL only, skip the Flutter app build
python scripts\build_apps.py windows --skip-flutter-build

:: force a clean reconfigure (needed after any CMake target rename)
python scripts\build_apps.py windows --clean
```

What it does:

1. **Phase 0 / 0b** — checks every prerequisite above and fetches Halide v21.
   Any missing prerequisite is one clear error line, and the script exits
   without building anything.
2. **Phase 1 (W12)** — `cmake --preset windows-vulkan` + build target
   `dng_decoder_native`, then copies the resulting
   `build-windows\dng_decoder_native.dll` into
   `ceyx\plugin\windows\Libraries\`.
3. **Phase 2 (W14)** — `flutter pub get` + `flutter build windows --release` in
   `Halcyon\`, then verifies the DLL landed next to `halcyon.exe` in
   `build\windows\x64\runner\Release\`. If it did not, it prints the runbook's
   diagnostics instead of hand-copying the DLL (that would hide a real
   packaging bug).
4. **Phase 3** — prints the manual verification protocol (decode correctness and
   the first-decode 1-second gate). The script does not drive the UI.

**The colour gate is not optional by default.** Phase 0 refuses a native build
with no `--cfa-sample-dng`, because placing a library that has never passed the
runbook S4 colour gate while reporting success is how an unvalidated binary
gets shipped. `--no-colour-gate` is the explicit opt-out; a run that uses it
exits 2, never 0.

Re-running after fixing an error is safe, with one exception the script now
detects and names for you: renaming a CMake target requires deleting the build
tree, which `--clean` does.

## After a successful build

The DLL produced here still has to be committed back in the `ceyx`
repo (runbook S4) — this extracted tree has no git history, so copy
`ceyx\plugin\windows\Libraries\dng_decoder_native.dll`
back to the Mac (or to a real checkout) and commit it there.

Record the timing numbers from Phase 3 in the runbook's section 7 "Results".
