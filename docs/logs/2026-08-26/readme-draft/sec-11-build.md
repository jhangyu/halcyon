## Building from source

### Prerequisites

| Requirement | Version verified in this tree | Notes |
|---|---|---|
| Flutter SDK | 3.44.6 | Dart 3.12.2; `pubspec.yaml` declares `sdk: ^3.9.0` |
| Ceyx checkout | sibling directory | Must be at `../ceyx` relative to this repository |
| JDK (Android only) | Temurin 25, or Homebrew `openjdk@21` / `openjdk@17` | Auto-selected by the build script in that order |
| Gradle (Android only) | 9.1.0 | Pinned by the wrapper |
| Android Gradle Plugin | 9.0.1 | Kotlin 2.3.21 |

<!-- evidence: pubspec.yaml:22 (sdk constraint), flutter --version output 2026-08-26 -->
<!-- evidence: pubspec.yaml:46-47 (ceyx path dependency) -->
<!-- evidence: scripts/build_apps.py:232-234 (JDK search order), scripts/build_apps.py:448 (PATH fallback warning) -->
<!-- evidence: android/gradle/wrapper/gradle-wrapper.properties:5, android/settings.gradle.kts:22-23 -->

**The Ceyx sibling checkout is not optional.** `pubspec.yaml` declares the decoder as a
relative path dependency on `../ceyx/plugin`, so `flutter pub get` fails outright if that
directory is missing. Clone Ceyx next to Halcyon, not inside it.

<!-- evidence: pubspec.yaml:46-47 -->

Android builds additionally require compatibility mode to be left enabled —
`android.newDsl=false` and `android.builtInKotlin=false` in `android/gradle.properties` —
because Flutter's Gradle plugin does not yet support AGP 9's new DSL. Removing those two
lines breaks the Android build.

<!-- evidence: android/gradle.properties:4-5, memory.md G-009 -->

### Running in development

```bash
flutter pub get
flutter run -d macos     # also: -d chrome, or a connected device id
flutter analyze          # must report 0 issues
flutter test             # full suite
```

### Release builds

`scripts/build_apps.py` is the single build entry point. It builds the native decoder and
the Flutter application for every target, and it replaced the earlier per-platform shell
and PowerShell scripts, which were deleted. Do not reintroduce a per-platform script.

```bash
python3 scripts/build_apps.py              # macOS release, the default target
python3 scripts/build_apps.py android --release
python3 scripts/build_apps.py web
python3 scripts/build_apps.py all          # every target this host can build
python3 scripts/build_apps.py --check      # toolchain check only, builds nothing
```

<!-- evidence: scripts/build_apps.py:249-266 (target table), scripts/build_apps.py:1599 (target argument) -->

Targets are `macos`, `ios`, `android` / `android-apk` / `android-aab`, `web`, `windows`,
`linux`, and `all`. The `all` target is host-filtered and skips rather than fails on
targets this host cannot build; `ios` is deliberately excluded from it so that an
unattended run never has to make a code-signing decision. `windows` and `linux` must be
built on their own operating system.

<!-- evidence: scripts/build_apps.py:249-266 -->

### The colour gate

A native decoder library is not trusted until it has passed the runbook S4 colour gate — a
blue-sky sample check asserting that the blue channel dominates the red one, which catches
a decoder wired up with its colour matrix wrong. Phase 0 of the build refuses to place an
ungated library.

- Pass a blue-sky DNG with `--cfa-sample-dng <file>` whenever a native build is due.
- `--no-colour-gate` is the loud opt-out. A run that uses it **exits 2, never 0**, and the
  resulting library is marked unvalidated.

<!-- evidence: scripts/build_apps.py:927-932 (Phase 0 refusal), scripts/build_apps.py:1220-1226 (skip warning), scripts/build_apps.py:1622-1624 (--no-colour-gate exits 2), scripts/build_apps.py:1721 -->

### Build outputs and what is source

Build outputs land under the root `build/` directory. The `android/`, `ios/`, `macos/`,
`web/`, `windows/` and `linux/` directories are source and configuration, not build output
— they stay in version control.

### A note on the Windows path

`scripts/build_apps.py` has never driven the Windows native build end to end. Treat the
first real Windows run of the script as first contact rather than a regression test. The
underlying CMake/MSVC path itself is not unproven — an upstream commit added it and built
the shipped `dng_decoder_native.dll` by hand on a real Windows machine — but that build
recorded no S4 colour-gate run, so the DLL is trust-on-first-use.

<!-- evidence: CLAUDE.md, Commands section -->
