# Premise Audit: Platform Runner Dirs + dng_processor (2026-08-21)

Auditor scope: A (4 admitted-unverified items, #3 skipped — assigned elsewhere),
B (dng_processor platform support), C (Linux claim).

Source doc: `docs/logs/2026-08-20/cross-platform-port-inventory.md`

Note on repo layout: `dng_processor` is NOT inside Halcyon; it lives at
`/Users/jhangyu/project/flutter_dng_decoder/dng_processor` and is pulled into
Halcyon via `pubspec.yaml:42-43` as a `path:` dependency. All dng_processor
paths below are absolute under that sibling repo, not under Halcyon.

A separate new package `flutter_dng_decoder/dng_processor_ffi/` was observed
mid-creation (has `macos/dng_processor_ffi.podspec`, `android/`, `lib/`,
`README.md`). Per instructions this is **excluded** from verdicts below — it
is in-flight teammate work, not pre-existing state — but its existence is
noted where relevant because it materially changes what "podspec exists" and
"how would bundling ever work" mean going forward.

## 結論先行 (FALSE / UNVERIFIABLE only)

| # | Claim | Verdict | One-line reason |
|---|---|---|---|
| A.1 | (unverified item, now resolved) "dng_processor 在 Windows/iOS 是否真能 build 出可用產物" | **FALSE** (resolves to: no, not currently) | `native/CMakePresets.json` only has `macos-metal` and two `android-vulkan*` presets — zero Windows/iOS presets; `native/CMakeLists.txt` has no `elseif(IOS)`/`CMAKE_SYSTEM_NAME STREQUAL iOS` branch anywhere in 900 lines; `windows/CMakeLists.txt` + `windows/runner/CMakeLists.txt` never `add_subdirectory` or otherwise reference `native/` at all. |
| A.2 | (unverified item, now resolved) "iOS 載入分支未讀，是否可行" | **FALSE** (branch exists but is non-viable as written) | `dng_bindings.dart:349-350`: `else if (Platform.isIOS) { lib = ffi.DynamicLibrary.process(); }`. This only works if the native symbols are statically linked into the host process, but nothing in `dng_processor/ios/` (Podfile, Runner.xcodeproj/project.pbxproj, or `native/CMakeLists.txt`) builds/links `native/src` into the iOS Runner — no podspec, no embed/run-script phase analogous to macOS's "Embed DNG Native Dylib". `Platform.isIOS` would call `DynamicLibrary.process()` and then fail to resolve any decoder symbol. |
| B.podspec | "Does any .podspec exist" | **UNVERIFIABLE as a settled fact** — one exists, but only in excluded in-flight work | `flutter_dng_decoder/dng_processor_ffi/macos/dng_processor_ffi.podspec` is the only project-authored podspec in the whole tree (others found are vendor/ephemeral `FlutterMacOS.podspec` copies). Since `dng_processor_ffi` is explicitly excluded (in-flight), the pre-existing, stable-state answer is: **no project podspec exists for dng_processor itself.** |
| C | "Linux 完全沒有 dng_processor 支援" | **TRUE, confirmed** (listed here because doc treated it as unverified-adjacent to A.1/A.4 — flagging to show it's now load-bearing evidence, not a guess) | See row C below. |

All other rows below are **TRUE** and are listed for completeness / evidence trail, not because they were wrong.

## A. Admitted-unverified claims

| Claim | Verdict | Evidence | If FALSE, what's actually true |
|---|---|---|---|
| "只確認 native/CMakeLists.txt、windows/CMakeLists.txt 存在" | TRUE | Both files exist: `flutter_dng_decoder/dng_processor/native/CMakeLists.txt` (900 lines), `flutter_dng_decoder/dng_processor/windows/CMakeLists.txt` (108 lines, pure Flutter Windows-app template — confirms it is app-style, not plugin, matching README claim). | — |
| "dist/ 只有 .apk / .app / .dylib" | TRUE (unchanged today) | `ls dng_processor/dist/`: `dng_processor.apk` (159MB), `dng_processor.app/`, `libdng_decoder_native.dylib` (1.4MB). No `.dll`, no `.ipa`, no iOS artifact of any kind. | — |
| "dng_processor 在 Windows/iOS 是否真能 build 出可用產物" (implicit assumption: maybe) | **FALSE** | See 結論先行 A.1 above. `native/CMakeLists.txt` platform conditionals are only `if(APPLE) / elseif(WIN32) / elseif(ANDROID) / elseif(UNIX)` for **compile definitions** (line 26-34), but the actual library-linking block (line 512-541: Metal/CoreFoundation for APPLE, Vulkan/log for ANDROID) has **no WIN32 or UNIX branch at all** — meaning even if you fixed the missing CMake integration, the link step has no Windows-library wiring today. Windows app scaffold (`windows/`) never invokes `native/CMakeLists.txt`. iOS has zero CMake awareness (no `if(IOS)` anywhere) and zero Xcode-side wiring. | Windows: CMake file exists but is disconnected from the app build and missing link-time libs. iOS: no build path exists at all — not even a broken one. |
| "dng_bindings.dart 349 行之後的 iOS 載入分支未讀" | **Resolved: read, and non-viable** | File is 359 lines total. Lines 349-350: `else if (Platform.isIOS) { lib = ffi.DynamicLibrary.process(); }`. This is the standard "statically linked into host binary" pattern, but no static-link mechanism exists for iOS (see A.2 above). Compare: Windows branch (line 343-344) is `ffi.DynamicLibrary.open('dng_decoder_native.dll')` — a bare filename with **no fallback-path search list**, unlike the elaborate 5-tier macOS `_openFirst([...])` search (lines 325-342). Linux branch (345-346) is equally bare: `ffi.DynamicLibrary.open('libdng_decoder_native.so')`. Only macOS and Android have been hardened with real path-resolution logic; Windows/Linux/iOS are all one-liners that assume the library is magically already discoverable. | iOS/Windows/Linux loading code exists syntactically but has never been exercised — no build produces the artifact these lines expect to find. |
| "Halcyon 的 windows/runner/*.cpp 是否 100% 等同 Flutter 範本" (extended to android/ios/linux per task) | **TRUE for all four platforms** | See per-platform table below. | — |

## A.4 — Template vs. real code, per platform

Method: `flutter create --platforms=windows,android,ios,linux` into
`Halcyon/scripts/tmp/template_audit/pristine_ref` (Flutter 3.44.6, the
locally installed SDK — same one used to build Halcyon), then `diff -rq`
against `Halcyon/{windows,android,ios,linux}`, then content-diffed every
non-boilerplate hit. Scratch dir is disposable and untouched by anything
except this audit.

| Platform | Verdict | What differs (all diffs inspected line-by-line) |
|---|---|---|
| windows | **Pure template** | `CMakeLists.txt`/`main.cpp`: project-name substitution only (`pristine_ref` → `photo_selector_flutter`). `Runner.rc`: app metadata only. `utils.cpp`: differs, but the diff is a **Flutter-template-version delta** (older template uses a `-1`-trick UTF16→UTF8 length calc; newer template uses `wcsnlen` with an explicit CWE-126 safety comment) — not hand-written app logic. `flutter_window.cpp`, `win32_window.cpp`: byte-identical. No reference to `dng_processor`/native anywhere in `windows/`. |
| android | **Pure template** | `AndroidManifest.xml`: app label + launcher icon path only. `MainActivity.kt`: package name only (`com.example.halcyon` vs `com.example.pristine_ref`), body is the stock 3-line `FlutterActivity()` subclass, byte-identical otherwise. `GeneratedPluginRegistrant.java`: differs only because Halcyon has plugins registered (expected, tool-generated). Extra files (`launcher_icon.png`, `proguard-rules.pro`, `.iml`) are standard app-customization artifacts, not hand-written platform glue. |
| ios | **Pure template** | `AppDelegate.swift` diff is a **Flutter-template-version delta**: pristine (newer SDK) uses `FlutterImplicitEngineDelegate` + `didInitializeImplicitFlutterEngine`; Halcyon's version uses the older direct `GeneratedPluginRegistrant.register(with: self)` in `didFinishLaunchingWithOptions`. Both are stock generator output for their respective Flutter versions — no custom code. `Info.plist`/`project.pbxproj`/xcconfig diffs are bundle-id/app-name/plugin-list boilerplate. Icon PNG diffs are just Halcyon's actual app icon vs the placeholder. `Podfile` exists in Halcyon but not pristine_ref only because pristine_ref was never `pod install`ed — a workspace-generation artifact, not custom logic. |
| linux | **Pure template** | `my_application.cc`/`.h`: diffs are 100% whitespace/formatting/brace-style deltas from Flutter template version drift (e.g. `first_frame_cb(MyApplication* self, FlView *view)` on two lines vs one, `//` vs `// ` comment spacing) plus the expected app-name substitution (`pristine_ref` → `photo_selector_flutter` in window title). No new functions, no new includes, no dng_processor reference. `CMakeLists.txt`: `BINARY_NAME`/`APPLICATION_ID` substitution only. |

Caveat (instrument check): the diffs are non-trivial in raw line count because
Halcyon's scaffolding predates the currently-installed Flutter SDK's template
generator by some margin (confirmed by the `FlutterImplicitEngineDelegate`
API only existing in the newer template) — this is template-version drift,
not evidence of hand-editing. Verified by reading full diff content, not just
`diff -rq` file-level noise.

## B. dng_processor platform support

| Claim | Verdict | Evidence |
|---|---|---|
| `android/` is app-style (`include(":app")`, `com.android.application`) | TRUE — independently confirmed | `dng_processor/android/settings.gradle.kts:24` (`include(":app")`) and `plugins { id("com.android.application") ... }` block, read directly, matches teammate's finding. |
| `ios/`, `macos/`, `windows/` are also app-style, not plugin-style | TRUE (new finding, extends teammate's scope) | All three have `Runner/`, `Runner.xcodeproj` or `windows/runner/` + top-level `CMakeLists.txt` defining `BINARY_NAME`/`add_executable` — this is the Flutter **app** template shape, not the plugin template shape (which would have no `Runner`/executable, just a library target). Confirmed by reading `pubspec.yaml` comment directly: "this project is an app project — its android/ and macos/ are app-shaped, so it cannot declare `flutter: plugin: platforms:` itself without breaking host app builds. See ../dng_processor_ffi/README.md." — dng_processor's own pubspec.yaml self-documents this. |
| Does any `.podspec` exist anywhere in the repo | Exists, but only in excluded in-flight work | `flutter_dng_decoder/dng_processor_ffi/macos/dng_processor_ffi.podspec` — this is the new plugin package under active construction, explicitly excluded per task instructions. Everything else found (`macos/Flutter/ephemeral/FlutterMacOS.podspec` in both dng_processor and Halcyon) is a vendored/generated CocoaPods artifact, not project-authored. **Stable-state answer: dng_processor itself has zero podspecs.** |
| `native/CMakeLists.txt` build requirements | TRUE, quantified | 900 lines. External deps: (1) zlib — `find_library`/`find_path` probe against Android NDK sysroot (no CMake config file there) with `find_package(ZLIB REQUIRED)` fallback elsewhere; (2) libjpeg — on APPLE, explicit Homebrew `jpeg-turbo` probe via `find_program(DNG_BREW_EXECUTABLE brew)` + hardcoded `/opt/homebrew/opt/jpeg-turbo/{lib,include}` paths (with a comment explaining this exists because linking the dylib directly breaks under sandboxed builds that can't read `/opt/homebrew`), `find_package(JPEG REQUIRED)` elsewhere; (3) Halide — vendored, pinned to v21.0.0, `find_package(Halide REQUIRED)`; (4) Apple frameworks CoreFoundation/CoreServices/Metal/Foundation; (5) Android: Vulkan (`find_library(VULKAN_LIBRARY vulkan)`, hard `FATAL_ERROR` if missing) + `log`. No Windows or Linux entries in the runtime-library link block. |
| Android prebuilt `.so` is arm64-only | TRUE, verified with `file` | `dng_processor/build/app/.../merged_native_libs/debug/.../lib/arm64-v8a/libdng_decoder_native.so` → `file` reports "ELF 64-bit LSB shared object, ARM aarch64". Only `arm64-v8a/` directory exists under every native-lib output path searched (`build-android/`, `merged_native_libs/`, `stripped_native_libs/`); no `armeabi-v7a` or `x86_64` build of `libdng_decoder_native.so` exists anywhere in the tree (armeabi-v7a/x86_64 dirs that do exist only contain `libflutter.so`, i.e. Flutter engine itself, not the DNG decoder). x86_64 emulators would indeed get nothing. |

## C. Linux support claim

| Claim | Verdict | Evidence |
|---|---|---|
| "Linux（dng_processor 完全沒有 Linux 支援）" | **TRUE, confirmed** | `dng_processor/` has no `linux/` directory at all (`android`, `ios`, `macos`, `windows` all exist; `linux` does not). `native/CMakeLists.txt` has a `qLinux=1` compile-definition branch (`elseif(UNIX)`, line 32-33) but this is dead-end scaffolding: no Linux entry in the link-libraries block (line 512-541), no CMake preset for Linux in `CMakePresets.json` (only `macos-metal`, `android-vulkan-stage1`, `android-vulkan`), and `dng_bindings.dart`'s Linux branch (line 345-346, `DynamicLibrary.open('libdng_decoder_native.so')`) has no fallback search paths and nothing ever builds that `.so` for Linux. P2 ranking (line 62-64 of source doc) is consistent with this — not contradicted by anything found. |

