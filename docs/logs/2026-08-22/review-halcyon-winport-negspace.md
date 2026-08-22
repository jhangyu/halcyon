# Review — Halcyon `windows-port`, negative-space + cross-platform regression pass

> Reviewer slot: `negspace` (Task #3). Contract: `docs/logs/2026-08-22/windows-port-review-contract.md` (Team A).
> Angle: **what does this diff remove or silently alter, and who depended on it** — deliberately orthogonal to the
> line-by-line correctness passes owned by `rev-winbuild-opus` (`windows/`) and `rev-buildscript-opus` (`build_windows.py`).
> Read-only review. Nothing was merged, committed, or fixed.

**Anchors**
- Base `main` @ `5e35d392cc20b43ace294e538eb5d4734290ae7f`
- Branch `windows-port` @ `a8ae0382bec2870c329d02096df93bc3476baf5b`, merge-base = `5e35d39` (1 commit, 8 files, +919/−9)
- Dirty tree at review time: `lib/views/rename_dialog.dart`, `windows/flutter/generated_plugins.cmake` (neither touched)
- Raw evidence: `tmp/verify/negspace-*.txt`

**Verdict: `MERGE-READY`** — no `[BLOCKER]` found in the negative-space scope. Five `[SHOULD-FIX]` and three `[NIT]`
items below, plus one **precondition**: the sibling repo must merge first (see SF-4). This verdict is scoped to
negative space only; correctness of `windows/` and `build_windows.py` is owned by the other two reviewers.

---

## A2 — Per-file negative-space table

| File | What behaviour is removed or altered | Who depended on it | Verdict |
|---|---|---|---|
| `windows/CMakeLists.txt:3,7` | `project()` / `BINARY_NAME` `photo_selector_flutter` → `halcyon`. Renames the exe and every `${BINARY_NAME}`-derived path: `:65 BUILD_BUNDLE_DIR = $<TARGET_FILE_DIR:${BINARY_NAME}>`, `:75 install(TARGETS)`, `windows/runner/CMakeLists.txt:9-57` (13 sites), `windows/flutter/generated_plugins.cmake:17`. | All indirect via the variable — **zero hardcoded consumers inside `windows/`** (`tmp/verify/negspace-06-windows-cmake.txt`). Outside: the two packaging scripts discover the exe by glob (`build_windows.ps1:472 -Filter '*.exe'`, branch `build_windows.py:580 glob("*.exe")`), so both survive the rename. Docs do not — see SF-2/NIT-3. | OK; aligns Windows with macOS (`macos/Runner/Configs/AppInfo.xcconfig:8 PRODUCT_NAME = Halcyon`, and `build/macos/Build/Products/*/Halcyon.app` on disk) |
| `windows/CMakeLists.txt:92-94` (new `file(MAKE_DIRECTORY)`) | Removes the failure mode of `install(DIRECTORY "${NATIVE_ASSETS_DIR}")` on a clean build. `PROJECT_BUILD_DIR` ends in `/` (`windows/flutter/CMakeLists.txt:24`), so the composed path is correct. | Nothing depended on the old failure. **Side effect:** the install rule can no longer fail loudly if a future package ships native assets and the flutter tool fails to populate the dir — it will copy an empty dir instead. | OK, see NIT-8 |
| `windows/runner/Runner.rc:93-98` | Embedded metadata `photo_selector_flutter` → `Halcyon` / `halcyon` / `halcyon.exe`. | Windows shell/Explorer properties only. No build rule, script, or Dart code reads these. | OK, see NIT-6 |
| `windows/runner/main.cpp:40` | Window title `L"photo_selector_flutter"` → `L"Halcyon"`. | **Nothing.** Verified no `FindWindow` / `GetWindowText` title-based lookup exists (`tmp/verify/negspace-17-title-and-anchor.txt`); the window *class* name `kWindowClassName = L"FLUTTER_RUNNER_WIN32_WINDOW"` (`win32_window.cpp:19`) is unchanged, so single-instance / class-registration behaviour is untouched. No Dart reference to the old name in `lib/` or `test/`. | OK |
| `windows/flutter/generated_plugins.cmake:10` | Adds `dng_processor_ffi` to `FLUTTER_FFI_PLUGIN_LIST`. This is a *generated* file; `flutter pub get` regenerates it identically, so `main`'s committed version was merely stale, not different-by-intent. Consequence: `:24` now dereferences `${dng_processor_ffi_bundled_libraries}` into `PLUGIN_BUNDLED_LIBRARIES`, which `windows/CMakeLists.txt:84-88` installs. | Creates a hard cross-repo dependency on the sibling branch — see SF-4. | Content OK, ordering constraint SF-4 |
| `scripts/package_windows.sh:103,106,170,178,199-200` | Adds `build_windows.py` to the pack and makes its absence a hard `fail`. Alters the closing guidance to name the `.py` first. **Removes nothing** — the `.ps1` is still copied (`:169`). | The zip's own `README_WINDOWS.md`, which is *not* updated — see SF-1. (Correctness of the script itself: `rev-buildscript-opus`'s scope; one line noted below.) | See SF-1 |
| `scripts/windows/build_windows.py` (new, 624 lines) | Pure addition. Removes nothing from the tree. Mode `100644` (not `+x`) — invoked as `python build_windows.py`, matching how `README_WINDOWS.md:52` invokes the ps1, so the missing exec bit is not a defect. | n/a | OK |
| `docs/logs/2026-08-22/windows-build-handover.md` + `windows-port-changes.md` (new) | Pure addition. The contract (line 14) marks `windows-build-handover.md` superseded; **the file already carries its own staleness banner** at its head (`⚠️ 已過時（2026-08-22 稍晚）— 先讀 windows-port-changes.md`), enumerating exactly which sections no longer hold. No stale-doc hazard introduced. | Future sessions | OK |

---

## Findings

### `[SHOULD-FIX]` SF-1 — the pack ships `build_windows.py` but its README still sends the user to the superseded `.ps1`

`scripts/package_windows.sh:170` now copies `build_windows.py` into the zip root and `:199-200` tells the user
*"run build_windows.py (no Native Tools prompt needed) or build_windows.ps1"*. But `scripts/windows/README_WINDOWS.md`
is **not in the diff** (`git diff main...windows-port --name-only -- scripts/windows/README_WINDOWS.md` → empty) and still says:

- `README_WINDOWS.md:13` — zip-root listing shows only `build_windows.ps1`; the `.py` is invisible to a reader.
- `README_WINDOWS.md:35,49` — *"run everything from an **x64 Native Tools Command Prompt for VS 2022**"*, which the
  `package_windows.sh:199` line explicitly says is no longer needed for the `.py` path.
- `README_WINDOWS.md:52,59,62` — every worked example is `powershell -ExecutionPolicy Bypass -File .\build_windows.ps1`.

The branch's own rationale (`git show windows-port:docs/logs/2026-08-22/windows-port-changes.md`, §4 and §6) states the
`.ps1` is superseded because PowerShell 5.1's `Expand-Archive` breaks on the Halide zip's long Doxygen paths,
`$LASTEXITCODE` is unreliable, and the `flutter.BAT` / `CreateProcess` fix (`build_windows.py:200-224`) exists **only in
the `.py`**. A user following the shipped README verbatim therefore lands on the known-broken path while a working one
sits next to it, unmentioned. This is user-facing on the exact workflow this branch exists to enable.

Fix is one paragraph in `README_WINDOWS.md`. Note this is transitional if `scripts/build_apps.py` (Task #4, user
decision 2 in the contract) subsumes both — but if `windows-port` merges before `build_apps.py` lands, the zip ships
self-contradicting instructions.
Evidence: `tmp/verify/negspace-09-readme-handover.txt`.

### `[SHOULD-FIX]` SF-2 — two runbook lines become stale on rename; three others were *already* stale in the opposite direction

Newly stale after merge:
- `docs/logs/2026-08-21/windows-verification-runbook.md:113` — *"`build\windows\x64\runner\Debug\photo_selector_flutter.exe` exists"*
- `docs/logs/2026-08-21/windows-verification-runbook.md:229` — *"right-click a JPEG → Open with → the built `photo_selector_flutter.exe`"*

Already-correct-after-rename (i.e. **this diff fixes an existing contradiction**):
- `docs/logs/2026-08-21/windows-ffi-build-runbook.md:161,204` — already say `halcyon.exe`
- `docs/logs/2026-08-21/windows-ffi-upgrade-findings.md:107` (W14 acceptance) — already says `halcyon.exe`

The contradiction was previously written down at `scripts/tmp/verify/pack/ac4-ac5-ps1-runbook-crossreference.md:63-64`
(*"runbook says `halcyon.exe`, but `Halcyon/windows/CMakeLists.txt:7` sets `BINARY_NAME "photo_selector_flutter"`"*).
**Net effect of the rename is a reduction in stale references, 3 → 2**, and it moves the code to match the acceptance
criteria the W14 runbook already asserts. Update the two `windows-verification-runbook.md` lines at merge time.
Evidence: `tmp/verify/negspace-10-docs-ci.txt`, `tmp/verify/negspace-11-ci.txt`.

### `[SHOULD-FIX]` SF-3 — the clean-build fix is applied to Windows only; Linux has the identical latent defect

`windows/CMakeLists.txt:91-94` (after the diff):
```
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
file(MAKE_DIRECTORY "${NATIVE_ASSETS_DIR}")     # <- added by this diff
install(DIRECTORY "${NATIVE_ASSETS_DIR}" ...)
```
`linux/CMakeLists.txt:110` is the same template line with no guard:
```
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}" ...)   # <- no MAKE_DIRECTORY
```
By the author's own diagnosis (`windows-port-changes.md` §7: *"任何真正乾淨的建置都會失敗於 `file INSTALL cannot find`"*),
this defect fires on **any fresh checkout**, not just Windows. Linux is the only other platform using this
`install(DIRECTORY native_assets)` template (`macos/` uses the Xcode pipeline and has no such line — grep confirms 2 hits
total, `tmp/verify/negspace-12-ci-and-nativeassets.txt`). Either apply the same one-liner to `linux/CMakeLists.txt:110`
or record in the merge notes that Linux is knowingly left broken. Silently fixing one of two identical sites is the
class of gap this review exists to catch.

### `[SHOULD-FIX]` SF-4 — merge order is load-bearing: the sibling repo must merge first

Chain, all mechanically verified:
1. `windows/flutter/generated_plugins.cmake:10` puts `dng_processor_ffi` in `FLUTTER_FFI_PLUGIN_LIST`.
2. `:23` `add_subdirectory(... /dng_processor_ffi/windows ...)`, `:24` appends `${dng_processor_ffi_bundled_libraries}`.
3. `flutter_dng_decoder/dng_processor_ffi/windows/CMakeLists.txt:48-51` sets that variable to
   `${CMAKE_CURRENT_SOURCE_DIR}/Libraries/dng_decoder_native.dll` with `PARENT_SCOPE`. **Variable name is correct** —
   the previously-recorded `bundled_libraries` typo (`memory: cmake-bundled-libraries-var-silent-typo`) is fixed here,
   and the file now carries a 20-line comment block (`:17-36`) documenting exactly why the name must not drift.
4. `windows/CMakeLists.txt:84-88` `install(FILES "${PLUGIN_BUNDLED_LIBRARIES}")` consumes it.

That DLL exists **only on the decoder's `windows-port` branch**:
```
$ git cat-file -e main:dng_processor_ffi/windows/Libraries/dng_decoder_native.dll
fatal: path '...' does not exist in 'main'
$ git ls-tree -r --name-only windows-port -- dng_processor_ffi/windows
dng_processor_ffi/windows/CMakeLists.txt
dng_processor_ffi/windows/Libraries/.gitkeep
dng_processor_ffi/windows/Libraries/dng_decoder_native.dll
```
The decoder working tree's `Libraries/` is empty (`ls -l` → `total 0`). Merging Halcyon `windows-port` alone makes
`flutter build windows` fail at install time on a clean checkout. The plugin's comment (`:44-47`) calls this the
*intended, non-silent* failure mode, which is defensible design — but it makes ordering a hard precondition:

> **Merge `flutter_dng_decoder` `windows-port` (`d36e1bd`) before Halcyon `windows-port` (`a8ae038`).**

Also note the packing script snapshots whatever the decoder repo has checked out, so `package_windows.sh` must not be
run with the decoder on `main`. Evidence: `tmp/verify/negspace-04-decoder-plugin.txt`, `negspace-13-tracking.txt`.

### `[SHOULD-FIX]` SF-5 (out of my scope, one line as instructed) — `scripts/build.sh:57` logs a name macOS stopped producing

`scripts/build.sh:57` prints `Output: build/macos/Build/Products/$(macos_config_name)/photo_selector_flutter.app`, but
`macos/Runner/Configs/AppInfo.xcconfig:8` sets `PRODUCT_NAME = Halcyon` and the tree actually contains
`build/macos/Build/Products/{Debug,Profile,Release}/Halcyon.app`. **Pre-existing, not caused by this diff** — flagged
because Task #4 (`scripts/build_apps.py`) is rewriting exactly this code path and should not copy the bug forward.
Evidence: `tmp/verify/negspace-14-naming-parity.txt`.

### `[NIT]` NIT-6 — `Runner.rc` is half-rebranded

`windows/runner/Runner.rc:92` `CompanyName "com.example"` and `:96` `LegalCopyright "Copyright (C) 2026 com.example."`
were left untouched while `:93`/`:98` became `Halcyon`. macOS already uses `com.jhangyu.halcyon`
(`AppInfo.xcconfig:11`). Cosmetic; visible in Explorer → Properties → Details.

### `[NIT]` NIT-3 — `build_windows.ps1:470-471` comment is now false

> `# The runner exe name comes from Halcyon/windows/CMakeLists.txt BINARY_NAME`
> `# (currently photo_selector_flutter); runbook S5 calls it halcyon.exe.`

The parenthetical is stale after the rename. No functional impact: `:472` globs `*.exe`. Moot if the `.ps1` is deleted
at merge time per the contract's out-of-scope note.

### `[NIT]` NIT-8 — `file(MAKE_DIRECTORY)` converts a loud failure into a silent no-op for a future case

Today the project ships no native assets, so the guard is strictly an improvement. If a package later *does* ship them
and the flutter tool fails to populate `build/native_assets/windows/`, `install(DIRECTORY)` will now copy an empty
directory instead of erroring. The added comment (`windows/CMakeLists.txt:89-93`) explains the *why* but not this
trade-off. Suggest one extra sentence.

### Cross-team note (not a finding against this diff) — the frozen contract's Team C premise is factually wrong on `main`

Contract line 90 states the `halcyon/thumbnail` `MethodChannel` is *"implemented only in `macos/Runner/AppDelegate.swift`.
On Windows the channel is absent."* On `main` today that is false:

- `windows/runner/halcyon_channels.cpp:67` registers `halcyon/thumbnail`, `:109` `halcyon/trash`, `:143` `halcyon/open_with`
- `windows/runner/halcyon_image.cpp` is a WIC-backed implementation with a `purpose == "preview"` branch at `:410`
- `windows/runner/CMakeLists.txt:11-13` compiles `halcyon_channels.cpp` / `halcyon_image.cpp` / `halcyon_trash.cpp`
- all four are **tracked** (`git ls-files windows/runner/`), and `windows/runner/CMakeLists.txt` is **not** in this diff —
  so this predates `windows-port`.

Raised because the commander froze that premise for Tasks #7/#8; the two thumbnail architects will otherwise design
against a Windows column that does not match the code. Evidence: `tmp/verify/negspace-08-windows-channels.txt`.

---

## Verified claims — nothing Windows-checkout-shaped snuck in

The commit message claims exec-bit losses, `scripts/tmp` deletions and a `pubspec.lock` downgrade were deliberately
excluded. All three re-verified independently (`tmp/verify/negspace-03-artifacts.txt`):

| Claim | Command | Result |
|---|---|---|
| `pubspec.lock` untouched | `git diff main...windows-port -- pubspec.lock \| wc -l` and `git diff main windows-port -- pubspec.lock \| wc -l` | `0` and `0` — **TRUE** (checked both merge-base and tip-to-tip, so a lockfile downgrade cannot hide behind either form) |
| no `scripts/tmp` deletions | `git diff main...windows-port --name-status -- scripts/tmp` | empty — **TRUE** |
| no exec-bit losses | `git diff main...windows-port --raw` | `:100755 100755 ... M scripts/package_windows.sh` — mode preserved; **no `100755 → 100644` transition anywhere** — **TRUE** |
| no unintended deletions | `git diff main...windows-port --summary` | 3 × `create mode`, **0 deletes** — **TRUE** |

### Untracked-but-imported hazard (the `trash_service.dart` class of bug) — clear

Every source file `windows/runner/CMakeLists.txt:9-20` feeds to `add_executable` is tracked on `main`:
`flutter_window.cpp`, `halcyon_channels.cpp`, `halcyon_image.cpp`, `halcyon_trash.cpp`, `main.cpp`, `utils.cpp`,
`win32_window.cpp`, `Runner.rc`, `runner.exe.manifest` — all present in `git ls-files windows/runner/`
(`generated_plugin_registrant.cc` is tool-generated into `flutter/ephemeral/`, by design). `git status --porcelain windows/`
shows only the one known dirty file. **No file the Windows build needs exists solely in a working tree.**
The one cross-repo gap is SF-4, which is a branch-ordering issue, not an untracked-file issue.
Evidence: `tmp/verify/negspace-13-tracking.txt`.

### Rename blast radius, full-repo sweep

`grep -rIn "photo_selector_flutter" .` (37 hits, `tmp/verify/negspace-02-oldname-worktree.txt`), classified:

| Location | Status after merge |
|---|---|
| `windows/CMakeLists.txt:3,7`, `windows/runner/Runner.rc:93,95,97,98`, `windows/runner/main.cpp:40` | fixed by this diff |
| `docs/logs/2026-08-21/windows-verification-runbook.md:113,229` | **newly stale** → SF-2 |
| `scripts/windows/build_windows.ps1:471` | **newly stale comment**, no functional impact → NIT-3 |
| `scripts/build.sh:57` | already stale before this diff (macOS builds `Halcyon.app`) → SF-5 |
| `linux/CMakeLists.txt:7,10`, `linux/runner/my_application.cc:49,53` | pre-existing; Linux still `photo_selector_flutter` |
| `ios/Runner/Info.plist:16`, `web/manifest.json:2,3`, `web/index.html:26,32`, `android/app/src/main/AndroidManifest.xml:3` | pre-existing |
| `macos/Runner.xcodeproj/.../Runner.xcscheme:18,36,52,87,104` (`BuildableName`) | pre-existing and already wrong — macOS produces `Halcyon.app` |
| `docs/logs/2026-08-2{0,1}/*.md`, `scripts/tmp/**`, `.claude/tmp/**` | historical logs / scratch — correctly untouched |

**No packaging script, launch config, or CI job hardcodes the exe name.** Both packagers glob (`build_windows.ps1:472`,
`build_windows.py:580`). `.github/workflows/ci.yml` (the only CI file) runs analyze/test/build **macOS only**, has no
Windows job, and per its own header comment has never executed (no git remote) — zero CI blast radius
(`tmp/verify/negspace-11-ci.txt`). No Dart code in `lib/` or `test/` references the old name.
The user's `/Applications/Halcyon.app` overwrite workflow is a macOS path driven by `PRODUCT_NAME = Halcyon` and is
completely untouched by a Windows-side `BINARY_NAME` change.

---

## Merge mechanics — `windows/flutter/generated_plugins.cmake`

The file is modified both in the dirty working tree and on the branch. **The two are byte-identical:**

```
$ git show windows-port:windows/flutter/generated_plugins.cmake | shasum -a 256
c79928466629796bc868cf06f721ae680059aba0f2178e063cdd0c67026e2cec  -
$ shasum -a 256 windows/flutter/generated_plugins.cmake
c79928466629796bc868cf06f721ae680059aba0f2178e063cdd0c67026e2cec  windows/flutter/generated_plugins.cmake
```
`diff` between them exits 0. So there is no content conflict — but git will still refuse the merge with
*"Your local changes would be overwritten"* because the path is dirty. **Exact command a human should run at merge time,
guard first:**

```bash
cd /Users/jhangyu/project/Halcyon
# 1. Prove the local edit is redundant before discarding it (must print nothing and exit 0):
git show windows-port:windows/flutter/generated_plugins.cmake \
  | diff -q - windows/flutter/generated_plugins.cmake && echo SAFE-TO-DISCARD
# 2. Only if step 1 printed SAFE-TO-DISCARD:
git checkout -- windows/flutter/generated_plugins.cmake
# 3. Then merge. Do NOT let this touch lib/views/rename_dialog.dart (separate user WIP).
```
This file is regenerated verbatim by `flutter pub get`, so even a mistake here is self-healing.
I did **not** perform the merge or modify the file. Evidence: `tmp/verify/negspace-05-merge-mechanics.txt`.

---

## A7 — cross-platform regression **baseline** on `main`

Established so a post-merge re-run has something to match. This is the baseline, **not** a test of the branch.
Run at `main` @ `5e35d39`, dirty files `lib/views/rename_dialog.dart` + `windows/flutter/generated_plugins.cmake`.

| Gate | Command | Exit | Result | Raw output |
|---|---|---|---|---|
| Analyze | `flutter analyze` | **0** | `No issues found! (ran in 3.1s)` | `tmp/verify/negspace-analyze-main.txt` |
| Test | `flutter test -j 1` | **0** | `All tests passed!` ×1, **162 executed** | `tmp/verify/negspace-test-main.txt` |

`-j 1` used per standing guidance (the default runner miscounts). No `scripts/tmp/r2_backup/` analyze noise was present.

**Declared-vs-executed reconciliation** (`tmp/verify/negspace-15-baseline-counts.txt`, `negspace-16-testcount.txt`):
150 static `test(` / `testWidgets(` occurrences across 21 files, minus 4 that appear inside doc comments
(`zoom_controller_test.dart:5`, `dng_decoder_smoke_test.dart:12`, `image_preload_controller_test.dart:679`,
`decoded_rgba_image_provider_test.dart:96`) = **146 declaration sites**. The gap to 162 executed is fully accounted for
by two parameterised generators inside `for` loops — `dng_preview_extractor_test.dart:56` and
`decoded_rgba_image_provider_test.dart:100` — which each emit one test per fixture/orientation. The counts reconcile;
no test file was silently skipped.

**Post-merge gate (recommended, per the "merge-after verification is an independent gate" lesson):** re-run both
commands on `main` after the merge and require `analyze exit 0 / 0 issues` and `test exit 0 / All tests passed! / 162`.
A drop below 162 means a test file stopped loading, which `exit 0` alone will not reveal.

---

## What I could not determine

1. **Whether the Windows build actually succeeds after the rename on a machine other than the author's.** No Windows
   host here. The author's `EXIT=0` claim rests on `tmp/verify/clean-2.txt` **on the Windows laptop**, which is not in
   this repo — I could not open it. The `windows/CMakeLists.txt` change is self-consistent by inspection, but that is
   inspection, not execution.
2. **Behavioural correctness of `dng_decoder_native.dll`** — declared unverifiable in the contract's shared ground
   truth. Not re-litigated.
3. **Whether `README_WINDOWS.md` will survive at all**, since `build_apps.py` (Task #4) may replace the whole
   `scripts/windows/` entry point. SF-1's remedy depends on that decision.
4. **Whether the Linux clean-build defect (SF-3) actually reproduces** — no Linux host; asserted by symmetry with the
   author's Windows diagnosis, not by execution.
5. I did **not** re-derive the correctness of `build_windows.py`'s 624 lines or of the `windows/` runner sources —
   `rev-buildscript-opus` and `rev-winbuild-opus` own those.

---

**Verdict: `MERGE-READY`** (negative-space scope), subject to the SF-4 merge-order precondition
(`flutter_dng_decoder` `windows-port` first) and with SF-1/SF-2/SF-3 recommended before or alongside the merge.
No blockers found.
