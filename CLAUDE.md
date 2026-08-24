# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Halcyon is a Flutter RAW/JPG photo triage tool for photographers: browse a folder, star/delete-mark photos, batch copy/move starred files. Flutter is the main line; macOS gets two native capabilities (Trash, "Open With") through `MethodChannel` bridges in `macos/Runner/AppDelegate.swift`; thumbnail extraction and RAW decode are pure Dart on every platform. Windows/Android runners exist but several native bridges are Flutter-side-only stubs there (see "Native bridges" below).

## Commands

```bash
flutter pub get                       # install deps
flutter run -d macos                  # run (also: -d iphone, -d chrome)
flutter analyze                       # lint — must be 0 issues before considering work done
flutter test                          # full suite
flutter test test/app_state_test.dart # single file
flutter test --coverage

python3 scripts/build_apps.py              # macOS release build (default)
python3 scripts/build_apps.py android --release
python3 scripts/build_apps.py web
python3 scripts/build_apps.py all          # every target supported on this host
python3 scripts/build_apps.py --check      # toolchain check only, builds nothing
```

`scripts/build_apps.py` is the single build entry point (native `dng_processor` + Flutter, all six targets). It replaced `build.sh`, `build_windows.ps1` and `build_windows.py`, which are deleted — don't reintroduce a per-platform script. Placing a native library that has not passed the runbook S4 colour gate is refused at Phase 0; `--no-colour-gate` is the loud opt-out and that run exits 2. macOS builds arm64 only, because the vendored `libdng_decoder_native.dylib` is arm64-only. `build_apps.py` has never driven the Windows native build end to end — treat the first real Windows run of *the script* as first contact, not a regression test. The underlying CMake/MSVC path itself is not unproven: upstream commit `d36e1bd` (2026-08-22) added it and built the shipped 1,906,688-byte `dng_decoder_native.dll` by hand on a real Windows machine. That commit records no S4 colour-gate run, so the DLL is trust-on-first-use.

`windows`/`linux` targets must build on their own OS. Build outputs land under root `build/`; `android/`, `ios/`, `macos/`, `web/`, `windows/`, `linux/` are source/config, not build output — keep them in version control.

Android builds on macOS need a JDK; `scripts/build_apps.py` auto-selects Temurin JDK 25, falling back to Homebrew `openjdk@21`/`openjdk@17`. Current toolchain is Gradle 9.1.0 + AGP 9.0.1 + Kotlin 2.3.21 compat mode — `android.newDsl=false` / `android.builtInKotlin=false` are required because Flutter 3.35.1's Gradle plugin doesn't yet support AGP 9's new DSL.

There is a companion native package `dng_processor` referenced via a relative path dependency (`../flutter_dng_decoder/dng_processor`) — it must exist as a sibling directory to this repo for `flutter pub get` to succeed.

## Architecture

**Layering**: `views/` (UI, keyboard shortcuts) → `providers/app_state.dart` (`AppState extends ChangeNotifier`, the single coordination point for all app logic) → `services/` (scanning, persistence, native bridges) → `models/` (`PhotoItem`, format registry).

`AppState` composes its collaborators via constructor injection (`PhotoLibraryScanner`, `PhotoStatusStore`, `PhotoFileActions`, `ImagePreloadController`, a `ThumbnailLoader` function, an optional `DngFullDecoder`), which is what makes it testable without touching the filesystem or platform channels — tests substitute fakes for these params.

**Image pipeline (tier-1/tier-2 sliding preload)** — the core perf-sensitive subsystem, in `services/image_preload_controller.dart`:
- Tier-1: window-resolution `ResizeImage` decode, used for immediate display while navigating.
- Tier-2: full-size `MemoryImage` decode, only triggered after `tierTwoNavigationDebounce` (250ms) of navigation quiet, so rapid arrow-key browsing never bursts full-frame decodes.
- Both tiers MUST be constructed with the same `bytes` object identity and same width/height args (`tierOneProviderFor` / `fullSizeProviderFor`) — the `ImageProvider` cache key is only a hit when all three match; mismatches cause silent duplicate decodes.
- Sidebar thumbnails are driven by `itemBuilder` (visible-range-driven), not scroll listeners — this replaced an older scroll-debounce approach (see AD-014/G-001 in `memory.md`).

**DNG full-size decode** — DNGs with no embedded JPEG preview go through the `dng_processor` native package via the `DngFullDecoder` typedef in `services/dng_decode_contract.dart`. This is a frozen integration seam (`NativeImageResult` sealed class has exactly 3 variants — don't add a 4th without checking `memory.md` AD-010/AD-011) so the pipeline can be unit-tested with a fake decoder instead of loading the real native dylib.

**Native bridges (macOS, in `macos/Runner/AppDelegate.swift`)**, each a separate `MethodChannel`:
**Image loading is pure Dart.** There is no native thumbnail channel: `dartImageLoad` (`lib/services/dart_image_loader.dart`) is the sole producer of image bytes on every platform, returning one of the three `NativeImageResult` variants in `lib/services/image_source_types.dart`. `ImageRequestPurpose` carries the requested long edge (`sidebarThumbnail` @200px, `preview` @2800px, `export` @2048px); the export path — decode → resize → re-encode JPEG q90 with core EXIF re-read from the original file — lives in `lib/services/thumbnail_export_service.dart`, not in `AppDelegate.swift`. `AppDelegate.swift` registers exactly two channels:
- `halcyon/trash` — `TrashService`, moves files to macOS Trash instead of permanent delete.
- `halcyon/open_with` — `OpenWithChannel`, push-only (native → Dart) by design: at cold start the Flutter engine isn't ready to receive a Dart→native call yet, but Flutter buffers channel messages sent the other direction, so "Open With" file paths always arrive once the Dart handler registers. Windows/Android forwarding is not implemented.

**Deletion has two paths**: `TrashService` (system Trash, macOS only) and an in-folder "recycle mode" (`.trash/` subfolder, sibling RAW files grouped and moved together, name collisions get `-1`/`-2` suffixes) — see `PhotoFileActions`.

**State persistence**: `.halcyon_status.json` in the photo folder root (star/trash marks + last-viewed id) — plain JSON so it's diffable/portable. `PhotoStatusStore` also probes writability by actually creating+deleting a file (permission bits are unreliable on exFAT `noowners` mounts) and surfaces a one-time status-line warning if the folder isn't writable.

## Project SOP (this repo's own process docs)

This repo maintains its own timestamp-driven documentation SOP, defined in `rule.md`, intended to survive AI context loss across sessions. The core files and what each owns:

| File | Owns |
|---|---|
| `task.md` | Current task state — **check the `🔴 現在進行中 (ACTIVE)` block at the top first** |
| `memory.md` | Architecture decisions (AD-NNN) and gotchas (G-NNN) — check before touching the image pipeline or native bridges |
| `handover.md` | Short-term handoff: what's done, what's next |
| `plan.md` | Mid/long-term phase milestones |
| `file_index.md` | File/directory map — use this to locate things before searching blind |
| `unit_test.md` | Test strategy, test-case matrix (TC-NNN), pass/fail history, success thresholds |
| `docs/logs/YYYY-MM-DD/Task_*.md` | One unified log per task: Summary → Implementation Plan → Execution Log (with a self-overwriting breakpoint snapshot) → Walkthrough |

If you make an architecture decision or hit a gotcha, add it to `memory.md` (don't let it live only in a task log). Test additions must get a corresponding entry in `unit_test.md`'s test-case matrix. Commits follow Conventional Commits (`feat/fix/docs/refactor/chore`).
