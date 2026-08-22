# Review — Halcyon `windows-port`, slot `winbuild`

> Reviewer: architect-reviewer (Team A, Task #1). Read-only review, 2026-08-22.
> Branch `windows-port` @ `a8ae038` on top of `main` @ `5e35d39`.
> Scope: **4 files only** — `windows/CMakeLists.txt`, `windows/runner/Runner.rc`,
> `windows/runner/main.cpp`, `windows/flutter/generated_plugins.cmake`.
> The other 4 files in the diff (`scripts/package_windows.sh`,
> `scripts/windows/build_windows.py`, and the two `docs/logs/` files) belong to
> other reviewers.
>
> Raw command output backing every claim: `tmp/verify/winbuild-*.txt`.
> Flutter SDK under test: `/Users/jhangyu/project/flutter`, 3.44.6, Dart 3.12.2.

---

## Verdict

**MERGE-READY** for the four files in my scope.

- 0 × `[BLOCKER]`
- 4 × `[SHOULD-FIX]`
- 4 × `[NIT]`

One **merge-ordering constraint** (F-04) is not a defect in the diff but must be
honoured or the first Windows build after merge hard-fails. See "Merge
conditions" at the end.

---

## F-01 `[SHOULD-FIX]` — the `NATIVE_ASSETS_DIR` comment states a root cause that the Flutter SDK source contradicts

`windows/CMakeLists.txt:92-96` (windows-port), added lines:

```
# The flutter tool only creates this directory when some package actually ships
# native assets; this project has none, so on a clean build it never exists and
# the install() below fails with "file INSTALL cannot find". Create it so the
# rule always has an (empty) source. Harmless when the tool does populate it.
file(MAKE_DIRECTORY "${NATIVE_ASSETS_DIR}")
```

**Half of the claim is verified. The other half is false.**

Verified (the part that holds):

| Claim | Status | Evidence |
|---|---|---|
| Flutter's template `install(DIRECTORY ...)` unconditionally | **TRUE** | `flutter/packages/flutter_tools/templates/app/windows.tmpl/CMakeLists.txt.tmpl:95-98` — no `if(EXISTS)`, no guard. Identical in the linux template at `:114-117`. |
| `install(DIRECTORY <missing>/)` hard-errors | **TRUE** | Reproduced on this host: `CMake Error at build/cmake_install.cmake:36 (file): file INSTALL cannot find "…/nonexistent_dir": No such file or directory.` — `tmp/verify/winbuild-native-assets-evidence.txt` §E1. Repro: 4-line `CMakeLists.txt` with `install(DIRECTORY "<missing>/" DESTINATION lib COMPONENT Runtime)`, then `cmake --install build --component Runtime`. |

Falsified (the stated root cause):

| Claim | Status | Evidence |
|---|---|---|
| "the flutter tool only creates this directory when some package actually ships native assets" | **FALSE** | `flutter_tools/lib/src/isolated/native_assets/native_assets.dart:463-465` creates it **unconditionally**, *before* the `if (assetTargetLocations.isEmpty) return` early-out at `:471`. |
| "on a clean build it never exists" | **FALSE for the normal build path** | `InstallCodeAssets` is a hard dependency of `BundleWindowsAssets` (`flutter_tools/lib/src/build_system/targets/windows.dart:108-114`), so it runs on every `flutter build windows`. `tool_backend.dart:87-90` passes `--output=build`, and `windows/flutter/CMakeLists.txt:24` sets `PROJECT_BUILD_DIR "${PROJECT_DIR}/build/"` — the two paths agree, so the tool creates exactly the directory the `install()` wants. `windows/runner/CMakeLists.txt:57` `add_dependencies(${BINARY_NAME} flutter_assemble)` puts that work strictly before the `INSTALL` target. |
| Corroborating (macOS, this host) | — | `build/native_assets/macos/` exists in this repo and contains only `native_assets.json`, although this project ships **zero** `build.dart`/hook native assets. The directory is created regardless. |

**What this means.** The author observed a real failure — I do not dispute the
symptom — but the explanation recorded in the code comment and in
`windows-port:docs/logs/2026-08-22/windows-port-changes.md` §7 is wrong, and the
real cause is undiagnosed. The most probable actual cause is visible in the
author's own diagnostic tip in that same doc: they ran
`cmake -DBUILD_TYPE=Release -P cmake_install.cmake` **directly**, without the
preceding `cmake --build`, which of course skips `flutter_assemble` and so hits
a genuinely absent directory. A second candidate is the stale-cache condition the
author documents one paragraph earlier (the rename forced a `build/windows`
wipe, and a half-reconfigured tree can install without a fresh assemble).

Neither of these is reproducible from macOS, so I cannot close it.

**Impact of the wrong comment**: a future maintainer reading
`windows/CMakeLists.txt:92-95` will believe the Flutter template is broken and
will propagate that belief (e.g. into `linux/CMakeLists.txt`, which has the
identical unguarded `install`). That is the cost worth fixing.

**Recommended fix (documentation only, no behaviour change)**: reword the comment
to state what is actually known — "belt-and-braces: the install rule below is
unguarded in Flutter's template, and any path that runs `cmake_install.cmake`
without a preceding `flutter assemble` fails with `file INSTALL cannot find`.
Root cause of the observed failure not fully diagnosed." Keep the `file()` call.

**Negative space — what does this remove, and who depended on it?**
It removes a loud failure: before this line, a Windows install with a missing
`build/native_assets/windows/` aborted. Nobody depended on that failure *today*
(this project has no native assets, so the abort was pure noise). But it is not
free — see F-05.

---

## F-02 `[SHOULD-FIX]` — `windows-port:docs/logs/2026-08-21/windows-verification-runbook.md` is now stale on the exe name

The rename at `windows/CMakeLists.txt:7` (`BINARY_NAME` → `halcyon`) makes two
runbook assertions wrong. Both survive on the branch unchanged:

- `docs/logs/2026-08-21/windows-verification-runbook.md:113` — "**Expected:**
  build succeeds; `build\windows\x64\runner\Debug\photo_selector_flutter.exe`
  exists." A user following the runbook after this merge will look for a file
  that can never exist and will conclude the build failed.
- `docs/logs/2026-08-21/windows-verification-runbook.md:229` — same, for the
  "Open With" section.

This is the only place in the repo where the old name is *load-bearing as an
instruction*. Everything else that survives is either historical prose or an
unrelated platform (see the enumeration below).

---

## F-03 `[SHOULD-FIX]` — `Runner.rc:98 ProductName` silently relocates the Windows preferences file

This is the one genuine **runtime behaviour change** in my four files, and the
diff does not mention it.

Proven chain, hop by hop:

1. `windows/runner/Runner.rc:98` — `VALUE "ProductName", "Halcyon"` (was
   `"photo_selector_flutter"`). `Runner.rc:92` `CompanyName` is unchanged at
   `"com.example"`.
2. `path_provider_windows-2.3.0/lib/src/path_provider_windows_real.dart:208-210`
   reads `CompanyName` and `ProductName` out of the **running executable's
   VERSIONINFO resource**, then `:216-218` joins them into the app-support
   directory name.
3. `shared_preferences_windows-2.4.1/lib/shared_preferences_windows.dart:340`
   calls `pathProvider.getApplicationSupportPath()` to decide where
   `shared_preferences.json` lives.
4. `lib/providers/app_state.dart:7,125,137` — `SharedPreferences.getInstance()`
   is on Halcyon's live path.

Net effect: the Windows preferences file moves from
`%APPDATA%\com.example\photo_selector_flutter\` to
`%APPDATA%\com.example\Halcyon\`. Any settings written by a pre-rename Windows
build are orphaned, and the app comes up with defaults.

**Blast radius is small and I want to be honest about that**: Windows has never
shipped, `windows-port` is the first build that ever produced a runnable exe
(the branch's own changes doc says so), and `.halcyon_status.json` — the star /
trash / last-viewed state that actually matters to users — lives in the photo
folder, not in SharedPreferences (`CLAUDE.md`, "State persistence"). So the
realistic loss is whatever `app_state.dart` keeps in prefs on exactly one
laptop.

**Recommended fix: document, do not code.** Add one line to the merge notes:
"Windows preferences path changes with this commit; delete
`%APPDATA%\com.example\photo_selector_flutter\` after upgrading." Writing a
migration shim for a platform with one pre-release user would be over-
engineering.

---

## F-04 `[SHOULD-FIX]` — cross-repo merge ordering: the `dng_processor_ffi` entry needs a DLL that is not on `flutter_dng_decoder` `main`

`windows/flutter/generated_plugins.cmake:10` adds `dng_processor_ffi` to
`FLUTTER_FFI_PLUGIN_LIST`. That activates this chain:

1. `windows/flutter/generated_plugins.cmake:22-25` —
   `add_subdirectory(.plugin_symlinks/dng_processor_ffi/windows)` and
   `list(APPEND PLUGIN_BUNDLED_LIBRARIES ${dng_processor_ffi_bundled_libraries})`.
2. `flutter_dng_decoder main:dng_processor_ffi/windows/CMakeLists.txt:48-51` —
   sets that variable to `${CMAKE_CURRENT_SOURCE_DIR}/Libraries/dng_decoder_native.dll`.
   (The variable name is **correct** here — the silent-typo failure recorded in
   the auto-memory `cmake-bundled-libraries-var-silent-typo` is already fixed on
   that repo's `main`, and the file now carries a 20-line comment explaining why
   the name must not change.)
3. `windows/CMakeLists.txt:84-88` — `install(FILES "${PLUGIN_BUNDLED_LIBRARIES}" ...)`.

The DLL exists **only on `flutter_dng_decoder`'s `windows-port` branch**:

```
main:        dng_processor_ffi/windows/CMakeLists.txt
             dng_processor_ffi/windows/Libraries/.gitkeep
windows-port: … + dng_processor_ffi/windows/Libraries/dng_decoder_native.dll
```

So if Halcyon `windows-port` merges and `flutter_dng_decoder` `windows-port`
does not, the next `flutter build windows` fails at install with a missing-file
error. That failure is **loud and intentional** (the sibling CMakeLists comment
at `:38-47` says exactly this is the designed non-silent failure mode), so it is
not a silent-corruption risk — but it is a hard break, and the user should not
discover it by hitting it.

**Important scoping note**: this coupling is *not introduced by this diff*. It
already exists on `main` — see F-08. The diff merely records the generated file.

---

## F-05 `[NIT]` — the fix converts a future loud failure into a silent one

`windows/CMakeLists.txt:96` `file(MAKE_DIRECTORY ...)` guarantees the
`install(DIRECTORY)` at `:97-99` always has a source. That is correct **today**,
because this project has zero native assets and an empty directory is the honest
answer.

If a future dependency ships a `build.dart` code asset and its hook fails or is
skipped, the directory will exist but be empty, `install` will copy nothing, and
the build will report success while the app ships without its native library —
a runtime `DynamicLibrary.open` failure with no build-time signal. That is
precisely the failure class the auto-memory entry
`cmake-bundled-libraries-var-silent-typo` records for this exact package.

Not worth fixing now (no native assets exist), but worth one line in the comment
so the trade-off is on record rather than rediscovered.

## F-06 `[NIT]` — `file(MAKE_DIRECTORY)` runs at configure time, `install()` at install time

`windows/CMakeLists.txt:96` executes during `cmake` configure and is then cached;
`windows/CMakeLists.txt:97` executes during `cmake --install`. Deleting
`build/native_assets/` without invalidating `build/windows/CMakeCache.txt` leaves
the fix inert.

In practice this self-heals — `flutter_assemble` is a phony target that re-runs
every build and re-creates the directory (`native_assets.dart:463-465`), and
`flutter clean` removes the whole `build/` tree including the CMake cache, which
forces a reconfigure. So the window is narrow.

The strictly-correct form would run at install time:

```cmake
install(CODE "file(MAKE_DIRECTORY \"${NATIVE_ASSETS_DIR}\")" COMPONENT Runtime)
install(DIRECTORY "${NATIVE_ASSETS_DIR}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
```

Optional. The current form is good enough.

## F-07 `[NIT]` — `Runner.rc` metadata is internally consistent, but `CompanyName` / `LegalCopyright` were left as template placeholders

Consistency check against `BINARY_NAME "halcyon"` (`windows/CMakeLists.txt:7`):

| Field | Value | Verdict |
|---|---|---|
| `Runner.rc:93` `FileDescription` | `Halcyon` | ✓ display string, title case correct |
| `Runner.rc:95` `InternalName` | `halcyon` | ✓ matches `BINARY_NAME` exactly |
| `Runner.rc:97` `OriginalFilename` | `halcyon.exe` | ✓ matches `${BINARY_NAME}.exe` |
| `Runner.rc:98` `ProductName` | `Halcyon` | ✓ display string (but see F-03) |
| `windows/runner/main.cpp:40` window title | `Halcyon` | ✓ matches `ProductName` |
| `Runner.rc:92` `CompanyName` | `com.example` | ✗ untouched template placeholder |
| `Runner.rc:96` `LegalCopyright` | `Copyright (C) 2026 com.example.` | ✗ untouched template placeholder |

The `halcyon` / `Halcyon` case split is **correct Win32 convention**, not an
inconsistency: `InternalName`/`OriginalFilename` track the file, `FileDescription`/
`ProductName` are user-visible. The two placeholders are pre-existing and out of
scope for this diff, but a rename pass is the natural moment to fix them — and
`CompanyName` is half of the F-03 path, so changing it later costs another
prefs relocation.

## F-08 `[NIT]` — the `generated_plugins.cmake` edit is redundant, not fragile

This was flagged as the highest-value question in my brief. **Answer: the entry
is durable. `flutter pub get` regenerates the file with byte-identical content.**

Mechanical proof, not inference:

1. The generator is `flutter_tools/lib/src/flutter_plugins.dart:717-721`
   (`_pluginCmakefileTemplate`, the `{{#ffiPlugins}}` loop) fed by the windows
   context at `:1041-1051`, filtered by `_filterFfiPlugins(plugins, WindowsPlugin.kConfigKey)`
   at `:992-1002` — i.e. membership is derived purely from each dependency's
   `pubspec.yaml`, never from the existing file's contents.
2. `flutter_dng_decoder` **`main`** already declares it:
   `main:dng_processor_ffi/pubspec.yaml:30-31` → `windows: ffiPlugin: true`.
   (Not only on its `windows-port` branch — I checked both.)
3. **Live evidence beats both of the above**: this repo is checked out on `main`,
   has never checked out `windows-port`, and its working-tree
   `windows/flutter/generated_plugins.cmake` (mtime `Aug 21 07:55`, i.e. written
   by a `flutter pub get` on `main`) is **md5-identical** to the version
   `windows-port` commits — `8eec7fb8256eda4b8a839cc88d585fab` for both.
   `tmp/verify/winbuild-generated-plugins-proof.txt`.

So the author did not "hand-edit a generated file"; they committed what the
generator produces. Regeneration is idempotent and will not wipe the entry.

Two consequences worth stating:

- The commit is **noise**, not risk. It would have appeared on `main` the next
  time anyone ran `flutter pub get` and committed the result.
- Because the coupling comes from the sibling `pubspec.yaml` on `main`, **F-04's
  merge-ordering hazard already exists on `main` today** — it is not created by
  this branch. Reverting this one line would not avoid it.

---

## Acceptance condition A2 — negative space, per file

*"What existing behaviour does this diff remove or alter, and who depended on it?"*

### `windows/CMakeLists.txt` (:3 `project()`, :7 `BINARY_NAME`, :92-96 new)

**Removes**: the target/project/executable name `photo_selector_flutter`.

Who depended on it, enumerated (`tmp/verify/winbuild-oldname-*.txt`):

| Dependent | Status after rename |
|---|---|
| `docs/logs/2026-08-21/windows-verification-runbook.md:113,229` | **STALE — actionable.** F-02. |
| `scripts/windows/build_windows.ps1:470-471` (comment: "currently photo_selector_flutter") | **STALE comment, behaviour fine** — the code globs `*.exe` (`:472`), so it is name-agnostic. |
| `windows-port:scripts/windows/build_windows.py:580` | **Unaffected** — `release_dir.glob("*.exe")`, name-agnostic. |
| `scripts/package_windows.sh` | **Unaffected** — never references the exe name. |
| `windows/CMakeLists.txt:68-73` (`BUILD_BUNDLE_DIR` → `$<TARGET_FILE_DIR:${BINARY_NAME}>`) | **Unaffected** — resolves to `…/runner/<Config>`, independent of the target's name. |
| Stale CMake cache in an existing `build/windows` | **Breaks loudly.** The author documents `No target "photo_selector_flutter"` and that `build/windows` must be deleted before reconfigure. Nothing automates this today — worth a guard in the new `build_apps.py` (Task #4's call, not mine). |
| `docs/logs/2026-08-2{0,1}/*.md` prose, `.claude/tmp/*` | Historical record. Correctly left alone. |

**Also alters**: introduces a **cross-platform naming split**. After this merge
Windows is the only platform called `halcyon`; every other platform still says
`photo_selector_flutter`:
`linux/CMakeLists.txt:7,10`, `linux/runner/my_application.cc:49,53`,
`ios/Runner/Info.plist:16`, `android/app/src/main/AndroidManifest.xml:3`,
`web/index.html:26,32`, `web/manifest.json:2,3`,
`macos/Runner.xcodeproj/…/Runner.xcscheme:18,36,52,87,104`.
Nothing breaks — each platform reads its own file — but "what is this app called"
now has two answers. Task #3 owns the cross-platform view; flagging it here
because this diff is what created the split.

**:92-96 (new `file(MAKE_DIRECTORY)`)** removes a loud install-time failure. See
F-01 and F-05.

### `windows/runner/Runner.rc` (:93,95,97,98)

**Removes**: the VERSIONINFO strings `photo_selector_flutter` /
`photo_selector_flutter.exe`.

Who depended on them: **`path_provider_windows`, and through it
`shared_preferences_windows` and `AppState`.** This is a real, non-obvious
runtime dependency and it is fully documented in F-03. No other consumer found —
no installer, no code-signing manifest, no registry key, and
`windows/runner/runner.exe.manifest` does not reference the name.

### `windows/runner/main.cpp` (:40)

**Removes**: the window title string `photo_selector_flutter`.

Who depended on it: **nobody.** Checked mechanically —

- The window *class* is `FLUTTER_RUNNER_WIN32_WINDOW`
  (`windows/runner/win32_window.cpp:19`), a separate constant that this diff does
  not touch, so window registration/lookup by class is unaffected.
- No `FindWindow`, no `CreateMutex`, no single-instance guard anywhere in
  `windows/runner/*.cpp|*.h` — grep returned zero hits. So the "Open With"
  hand-off (`main.cpp:29,37` → `flutter_window.cpp:16-17,47-49,92`) does **not**
  locate a running instance by title; it is a launch-argument push. Retitling
  cannot break it.
- The user has banned UI-driven verification, so no test or script keys off the
  title.

Pure display change. Consistent with `ProductName` (F-07).

### `windows/flutter/generated_plugins.cmake` (:10)

**Removes**: nothing — one added line, no deletions.

**Alters**: activates the `dng_processor_ffi` FFI plugin subdirectory on Windows,
which makes `install(FILES "${PLUGIN_BUNDLED_LIBRARIES}")`
(`windows/CMakeLists.txt:84-88`) require a DLL that only exists on the sibling
repo's `windows-port` branch. See F-04. Durability: see F-08.

---

## Does anything here affect a non-Windows build? — **No. Proven.**

`tmp/verify/winbuild-q4-nonwindows-proof.txt`.

1. **No Dart, no pubspec.** `git diff main...windows-port --name-only` filtered to
   `lib/`, `test/`, `pubspec*` returns **empty**. `flutter analyze` and
   `flutter test` read none of these four files. (A7 itself is another
   reviewer's condition; this establishes that my four files cannot move it.)
2. **`windows/CMakeLists.txt` has exactly one entry point** — the Windows CMake
   build. `macos/`, `ios/`, `android/`, `linux/`, `web/` build configs contain
   zero references to it (grep over `project.pbxproj`, both `Podfile`s,
   `build.gradle.kts`, `settings.gradle.kts`, `linux/CMakeLists.txt`,
   `web/index.html`).
3. **`generated_plugins.cmake` has exactly one consumer**:
   `windows/CMakeLists.txt:58` `include(flutter/generated_plugins.cmake)`.
   `linux/CMakeLists.txt:75` has a line that *looks* identical but resolves
   relative to `linux/`, i.e. `linux/flutter/generated_plugins.cmake` — a
   different, unmodified file whose `FLUTTER_FFI_PLUGIN_LIST` is empty (verified:
   `dng_processor_ffi` ships no `linux/` directory, so the generator cannot add
   it there). Calling this out because the two `include()` lines are textually
   identical and easy to misread as shared.
4. **`Runner.rc` and `main.cpp` are Windows-only by construction** — `.rc` is an
   MSVC resource script; `main.cpp` compiles only under
   `windows/runner/CMakeLists.txt`. Neither is referenced by any other platform's
   build.
5. **The only remaining coupling is the sibling package**, and it is
   `pubspec.yaml`-driven and pre-existing on `main` (F-08) — merging or not
   merging this branch changes nothing about it.

---

## Merge conditions

Nothing in these four files blocks the merge. Two coordination items:

1. **F-04 — merge `flutter_dng_decoder` `windows-port` at or before the first
   Windows build after this merge**, or that build fails at install with a
   missing `dng_decoder_native.dll`. Loud failure, no silent corruption. Team B
   owns whether that branch is fit to merge.
2. **F-02 / F-03 — two documentation lines.** Fix the runbook's exe name; record
   the Windows preferences relocation. Neither is code.

`[SHOULD-FIX]` F-01 (reword the misleading comment), `[NIT]` F-05/F-06/F-07 are
all optional and can go to the parking lot.

---

## What I could not determine

1. **The true root cause of the author's `file INSTALL cannot find` failure.**
   The symptom is real (they hit it); the recorded explanation is contradicted by
   SDK source (F-01). Reproducing it needs a Windows host. Consequence: the
   `file(MAKE_DIRECTORY)` line may be treating a symptom. It is harmless either
   way, so this does not block merge — but the branch's changes doc should not be
   trusted as a diagnosis.
2. **Whether `flutter pub get` regenerates `generated_plugins.cmake` on *this*
   invocation.** I deliberately did **not** run `flutter pub get`, because
   `windows/flutter/generated_plugins.cmake` carries uncommitted user work and
   is on my red-line list. I answered the question from the generator source plus
   the md5-identity of the already-regenerated working-tree file (F-08), which is
   stronger evidence than a single run would have been.
3. **Behavioural correctness of anything Windows.** Out of scope and stated in the
   contract as a known limitation. Nothing in this review implies the exe works.

---

## Acceptance conditions

| Condition | Status | Note |
|---|---|---|
| **A1** — report file exists at `docs/logs/2026-08-22/review-halcyon-winport-winbuild.md`; every finding tagged `[BLOCKER]`/`[SHOULD-FIX]`/`[NIT]` with a `file:line` citation | **PASS** | 8 findings, F-01…F-08, each tagged and cited. |
| **A2 (my slice)** — per file: what behaviour does this diff remove or alter, and who depended on it | **PASS** | "Negative space, per file" section, all 4 files, each with an enumerated dependent table. |
| **Verdict line** | **PASS** | `MERGE-READY`, top of document and repeated below. |

---

## Evidence files

| Path | Contents |
|---|---|
| `tmp/verify/winbuild-native-assets-template.txt` | Flutter windows + linux `CMakeLists.txt.tmpl` `NATIVE_ASSETS_DIR` blocks |
| `tmp/verify/winbuild-native-assets-evidence.txt` | E1 CMake repro of the install error · E2 `native_assets.dart:463-465` · E3 `windows.dart:108-114` · E4 `tool_backend.dart:87-90` + `PROJECT_BUILD_DIR` · E5 local `build/native_assets/macos/` · E6 `runner/CMakeLists.txt:57` |
| `tmp/verify/winbuild-generated-plugins-proof.txt` | md5-identity of branch vs regenerated file · sibling `pubspec.yaml` on `main` · generator source · DLL presence per branch |
| `tmp/verify/winbuild-oldname-main.txt` | `git grep photo_selector_flutter main` |
| `tmp/verify/winbuild-oldname-winport.txt` | `git grep photo_selector_flutter windows-port` |
| `tmp/verify/winbuild-oldname-worktree.txt` | working-tree grep incl. untracked |
| `tmp/verify/winbuild-path-provider-windows.txt` | `path_provider_windows_real.dart:195-235` VERSIONINFO → app-support path |
| `tmp/verify/winbuild-q4-nonwindows-proof.txt` | non-Windows isolation proof (5 checks) |

**VERDICT: MERGE-READY** — `windows/CMakeLists.txt`, `windows/runner/Runner.rc`,
`windows/runner/main.cpp`, `windows/flutter/generated_plugins.cmake`.
0 blockers; subject to the two merge conditions above.
