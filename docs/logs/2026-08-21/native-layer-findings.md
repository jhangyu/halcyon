# Native/build-layer verification — 2026-08-21

Read-only investigation for Task #1 (research-native-sonnet). Working tree has an
active concurrent session; findings below separate **committed state** from
**in-flight (dirty/untracked) changes**. Note: there is already a contract doc
for the in-flight work at `docs/logs/2026-08-21/cross-platform-p0-contract.md` —
this investigation cross-checks it independently rather than trusting it, and
matches the code on disk.

Legend: [C] = confirmed by reading the file directly, [U] = unverified (not run/not testable read-only).

## 1. `dng_processor` package status — real plugin? platform build files? dist artifacts?

**[C] Correction to the task's premise**: Halcyon's `pubspec.yaml` does NOT
depend on `dng_processor` directly. It depends on a *new sibling package*,
`dng_processor_ffi`, added in-flight:

```
pubspec.yaml:
  dng_processor_ffi:
    path: ../flutter_dng_decoder/dng_processor_ffi
```
with a comment explaining why: `dng_processor` is an app-shaped project (its
`android/`/`macos/` dirs are Flutter *app* scaffolding, e.g.
`include(":app")`), so it cannot declare `flutter: plugin: platforms:` itself
without dragging file_picker/path_provider into Halcyon and breaking the
Android build. `dng_processor_ffi/` is a packaging-only real Flutter plugin.

**[C] `dng_processor_ffi/pubspec.yaml`** (`/Users/jhangyu/project/flutter_dng_decoder/dng_processor_ffi/pubspec.yaml:20-25`):
```
flutter:
  plugin:
    platforms:
      macos:
        ffiPlugin: true
      android:
        ffiPlugin: true
```
Only **macOS** and **Android** are declared. No `ios:`, `windows:`, `linux:`
entry exists — confirmed by directory listing: `dng_processor_ffi/` has only
`android/`, `macos/`, `lib/` (no `ios/`, `windows/`, `linux/` dirs at all).

- **macOS** [C]: `dng_processor_ffi/macos/dng_processor_ffi.podspec` vendors
  `Libraries/libdng_decoder_native.dylib` via CocoaPods (`s.vendored_libraries`),
  installed into the host app's `Frameworks/`. Prebuilt dylib is committed at
  `dng_processor_ffi/macos/Libraries/libdng_decoder_native.dylib`.
- **Android** [C]: `dng_processor_ffi/android/build.gradle` is a
  packaging-only Gradle library (`jniLibs.srcDirs`) pulling in
  `android/src/main/jniLibs/arm64-v8a/libdng_decoder_native.so` — **arm64 only**,
  explicitly documented in-file as a known limitation ("x86_64 emulators get
  no library and RAW decode will fail there").
- **Windows** [U/C-negative]: no plugin infrastructure exists in
  `dng_processor_ffi` for Windows. `dng_bindings.dart:339` does
  `ffi.DynamicLibrary.open('dng_decoder_native.dll')` with a bare filename and
  no bundling mechanism to put that DLL next to the exe — **not plausible as
  shipped**; would need a Windows-plugin CMake hook that doesn't exist yet.
- **Linux** [U/C-negative]: same as Windows — `dng_bindings.dart:341` opens
  `libdng_decoder_native.so` by bare name, no plugin/bundling path, no native
  Linux build output found anywhere under `dng_processor/native/{build,dist}`.
- **iOS** [U/C-negative]: `dng_bindings.dart:344-345` — `Platform.isIOS` branch
  uses `ffi.DynamicLibrary.process()` (static-link assumption: symbols must
  already be linked into the app binary). But `dng_processor_ffi` declares no
  `ios:` platform in its plugin manifest and has no `ios/` directory at all —
  there is no build mechanism that would statically link the native library
  into an iOS host app. This branch is dead code as shipped; iOS RAW decode is
  not plausible without new work.

**Full read of `dng_bindings.dart`** (`/Users/jhangyu/project/flutter_dng_decoder/dng_processor_ffi/lib/src/dng_bindings.dart`, 355 lines):
- The task description's claim of "a hardcoded path near line 339" is **stale**
  — [C] that line is now the Windows branch (`ffi.DynamicLibrary.open('dng_decoder_native.dll')`),
  not a hardcoded absolute path. A code comment at lines 302-306 documents that
  the *former* candidate 5 (a pair of absolute `$HOME/project/...` dev paths
  gated behind `DNG_DEV_FALLBACK`) was **removed on 2026-08-21 (labelled "D1")**
  as part of this same in-flight work, on the premise that the macOS
  `dng_processor_ffi` plugin's pod now bundles the dylib into `Frameworks/`
  instead.
- macOS loader (`_openFirst`, lines 195-217, candidates built at 325-337) now
  tries, in order: (1) system default via `DYLD_LIBRARY_PATH`, (2) app bundle
  `../Frameworks/libdng_decoder_native.dylib`, (3) `DNG_NATIVE_BUILD_DIR` env
  override, (4) two `Platform.script`-relative dev paths for `dart run`
  scenarios. No absolute dev-machine path remains unconditionally.
- iOS branch is after line 344 as the task description anticipated, but its
  content is `DynamicLibrary.process()`, not a path — see iOS finding above.

**`dng_processor` (old app-shaped package) native/dist state** [C]:
`../flutter_dng_decoder/dng_processor/native/` contains a full CMake native
build tree (`CMakeLists.txt`, `build/`, `build-android/`, source, Halide
runtime). `dng_processor/dist/` contains `libdng_decoder_native.dylib`,
`dng_processor.apk`, and `dng_processor.app` (dev/test artifacts of the old
sample app, not release artifacts of Halcyon). `dng_processor/windows/` and
`dng_processor/ios/` directories exist but are the **Flutter app-scaffold**
runners (i.e. `windows/runner/*.cpp`, `ios/Runner.xcodeproj`) for the
`dng_processor` sample app itself, not plugin platform folders — they build a
standalone test app, not a mechanism for bundling the native lib into
Halcyon. No Windows/Linux `.dll`/`.so` build output found anywhere under
`native/build` or `native/dist`.

## 2. Android build state

**[C]** `android/app/build.gradle.kts` — **not modified** in the working tree
(`git diff --stat` empty; last touched at commit `af2e73f`). Contents:
`namespace = "com.example.halcyon"`, `applicationId = "com.example.halcyon"` —
these already match each other in the committed file.

**[C] In-flight (untracked) change**: `git status` shows
`D  android/app/src/main/kotlin/com/example/photo_selector_flutter/MainActivity.kt`
(deleted, old package) and a new untracked file
`android/app/src/main/kotlin/com/example/halcyon/MainActivity.kt` containing:
```kotlin
package com.example.halcyon
import io.flutter.embedding.android.FlutterActivity
class MainActivity : FlutterActivity()
```
This now matches `namespace`/`applicationId` — the Kotlin package path move
resolves the mismatch the task description flagged. No thumbnail/trash/open-with
native bridge code exists in this `MainActivity.kt` — it is bare boilerplate
(3 lines). Android has **no native MethodChannel implementations at all** for
`halcyon/thumbnail`, `halcyon/trash`, or `halcyon/open_with` (confirmed by file
content + no other `.kt` files under `android/app/src/main/`).

Also untracked: `android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java`
— standard Flutter-generated plugin registrant, unrelated to Halcyon's own bridges.

**[U]** Did not run `flutter build apk` (red line: no builds).

## 3. Windows runner in-flight changes

**[C]** Modified (dirty): `windows/runner/CMakeLists.txt`,
`windows/runner/flutter_window.cpp`, `windows/runner/flutter_window.h`,
`windows/runner/main.cpp`. New untracked: `windows/runner/halcyon_channels.cpp`,
`windows/runner/halcyon_image.cpp`, `windows/runner/halcyon_native.h`,
`windows/runner/halcyon_trash.cpp`.

This is a from-scratch native bridge implementation, not a stub:
- `CMakeLists.txt` diff adds the three new `.cpp` files to the build and links
  `windowscodecs.lib` (WIC decode/encode), `shell32.lib` (`DragQueryFileW`,
  `SHCreateItemFromParsingName`), `ole32.lib`, `oleaut32.lib` — i.e. real WIC-
  and Shell-based image/trash code, not placeholders.
- `flutter_window.cpp`/`.h` diff wires: `WM_DROPFILES` handling
  (`HandleDroppedFiles` → `DeliverOpenFile` → `channels_->PushOpenFile`),
  `DragAcceptFiles(GetHandle(), TRUE)` in `OnCreate`, and a `halcyon::Channels`
  object constructed from the engine's `BinaryMessenger` — same push-only
  `halcyon/open_with` pattern as macOS's `AppDelegate.swift`.
- `main.cpp` diff resolves a launch-file argument
  (`halcyon::FirstExistingFileArgument`) from the command line **before** it's
  moved into `dart_entrypoint_arguments`, for shell-association "Open With".
- `windows/runner/halcyon_native.h` [C, full read] declares `IsRawExtension`,
  `RequestImage` (returns `ImageResult` for `sidebarThumbnail`/`preview`/
  `export` purposes, JPEG-encoded via WIC), `TrashFile` (Recycle Bin via
  `IFileOperation`, documented as requiring the STA thread `main.cpp`
  initializes with `COINIT_APARTMENTTHREADED`), `FirstExistingFileArgument`,
  and the `Channels` class registering `halcyon/thumbnail` + `halcyon/trash`
  handlers and a push-only `halcyon/open_with` channel.
  - **Explicit self-disclosed caveat in the file header (lines 10-12)**:
    *"NOTHING IN THIS FILE OR ITS IMPLEMENTATION HAS BEEN COMPILED OR RUN. It
    was written on a macOS host, which cannot build Windows targets."* Points
    to `docs/logs/2026-08-21/windows-verification-runbook.md` (present in the
    tree) as the follow-up verification path.
  - RAW input on Windows always fails with `RAW_UNSUPPORTED` by design —
    consistent with finding #1 that no Windows DNG native build path exists.

**[U]** Whether this compiles/links — cannot be verified read-only on macOS,
and the code's own header says so explicitly. Treat as **unverified, self-
flagged as such by the author**.

## 4. `native_thumbnail_service.dart` / `dng_decode_service.dart` in-flight changes

**[C] `native_thumbnail_service.dart`** — full read. Adds a
`MissingPluginException` catch clause (lines 122-135) alongside the existing
`PlatformException` clause in `requestImage()`. Comment explicitly ties this
to the cross-platform gap: *"No native handler registered for
`halcyon/thumbnail` at all (e.g. Windows/Android/iOS, ... see
cross-platform-port-inventory.md P0 item 3)"*. On `MissingPluginException` it
now returns `NativeImageFailure('MISSING_PLUGIN', 'Thumbnail service is
unavailable on this platform')` instead of letting the exception propagate
uncaught. This directly targets the doc's flagged risk that this exception
would otherwise rethrow through `image_preload_controller.dart`'s
`catch (_) { rethrow; }` and crash the preload pipeline. The
`kAllowRawDecodeSignalArg`/`NativeImageNeedsRawDecode` machinery (round-3b,
committed) is unchanged by this diff.

**[C] `dng_decode_service.dart`** — full read, small file (35 lines). Now
imports `package:dng_processor_ffi/dng_processor_ffi.dart` (not the old
`dng_processor` path) and calls `DngDecoderService().decodeOnWorker(path)`.
Comment states the dylib now lands in `<App>.app/Contents/Frameworks/` because
`dng_processor_ffi` is a real FFI plugin whose pod vendors it — consistent
with finding #1. This is the Dart-side half of the `dng_processor` →
`dng_processor_ffi` package swap described in #1; both changes are coupled
and must land together.

## Cross-check against existing contract doc

`docs/logs/2026-08-21/cross-platform-p0-contract.md` (written by the
concurrent session, not by me) declares this exact scope as in-flight P0 work
(D1: dng_processor_ffi plugin-ization, D2: MissingPluginException fallback,
D3: Android package fix) with mechanical acceptance criteria and an explicit
note that Windows/iOS native code is this-round out-of-scope for *verification*
but was additionally authorized by the user for unverified delivery. This
matches what's observed on disk; no contradiction found.

## Summary of what's real vs. still a gap

| Platform | Native RAW decode | Thumbnail/Trash/OpenWith bridges |
|---|---|---|
| macOS | [C] real FFI plugin, pod-vendored dylib | [C] existing Swift `AppDelegate.swift`, unaffected |
| Android | [C] real FFI plugin, arm64-only `.so` | [C] **none exist** — MainActivity is 3-line boilerplate |
| Windows | [U/C-negative] no plugin path, DNG always `RAW_UNSUPPORTED` | [C] in-flight WIC/Shell code written, **self-flagged as never compiled** |
| iOS | [U/C-negative] no plugin path, `DynamicLibrary.process()` dead branch | not in scope of dirty files reviewed here |
| Linux | [U/C-negative] no plugin path, no build output | not in scope |
