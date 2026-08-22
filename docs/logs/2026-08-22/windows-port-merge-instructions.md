# Windows port — merge instructions

> Written 2026-08-22 by the main session after all six reviews signed off.
> **Nothing in this document has been executed.** It is a proposal for the user to approve.
> Contract: [`windows-port-review-contract.md`](./windows-port-review-contract.md).

## Verdict

| Track | Reviewers | Verdict | Blockers |
|---|---|---|---|
| Halcyon `windows-port` | `rev-winbuild-opus`, `rev-buildscript-opus`, `rev-negspace-opus` | MERGE-READY / MERGE-AFTER-BLOCKERS* / MERGE-READY | **0 open** |
| flutter_dng_decoder `windows-port` | `rev-dngsdk-opus`, `rev-cmake-opus` | MERGE-READY / MERGE-READY | **0** |

\* `rev-buildscript-opus` raised two blockers against `scripts/windows/build_windows.py`. Both are resolved: B2 (unguarded `import winreg`) and B1 (colour gate skipped → green exit + library placed) are fixed in `scripts/build_apps.py`, and that file is deleted by this merge anyway.

## State at time of writing

| | |
|---|---|
| Halcyon `main` | `5e35d39` |
| Halcyon `windows-port` | `a8ae038` — 1 commit, fast-forward (`0 1`, no divergence) |
| decoder `main` | `e05a9a4` |
| decoder `windows-port` | `d36e1bd` — 1 commit, fast-forward (`0 1`, no divergence) |

## Merge order is load-bearing

**Merge the decoder first.** Halcyon's `windows/flutter/generated_plugins.cmake:10` puts `dng_processor_ffi` in `FLUTTER_FFI_PLUGIN_LIST`; `:24` dereferences `${dng_processor_ffi_bundled_libraries}`; that resolves via `dng_processor_ffi/windows/CMakeLists.txt:48-51` to `Libraries/dng_decoder_native.dll`, which exists only on the decoder's `windows-port`. Reversed order breaks `flutter build windows` at `install(FILES ...)` on a clean checkout.

**This coupling is not created by `a8ae038`.** It flows from the decoder's `pubspec.yaml` on its own `main`, so any `flutter pub get` on Halcyon `main` produces the same line. Reverting it would not avoid the ordering requirement. (`rev-winbuild-opus` F-04, correcting the original framing.)

## Working-tree notes before you start

- `windows/flutter/generated_plugins.cmake` shows as modified but is **not user work**: it is `flutter pub get` output from `main` (mtime Aug 21 07:55) and is md5-identical to what the branch commits (`8eec7fb8256eda4b8a839cc88d585fab`). Merging it is a non-event.
- `lib/views/rename_dialog.dart` **is** genuine uncommitted user work. Leave it alone; it belongs to a different task.
- `windows/runner/halcyon_image.cpp` is being modified right now by the separate Windows-EXIF ticket. **Do not fold that into the merge commit.**
- Delete before committing: `scripts/tmp/build_windows_port.py`, `scripts/tmp/windows-port-changes.md` (throwaway `git show` dumps, confirmed by their author).

## Step 1 — decoder

```bash
cd /Users/jhangyu/project/flutter_dng_decoder
git checkout main
git merge --ff-only windows-port          # e05a9a4 -> d36e1bd
```

Nothing else changes in this repo. Its `docs/` tree is gitignored by design (`.gitignore:57`), so the two review reports there stay untracked — that matches repo convention.

## Step 2 — Halcyon

```bash
cd /Users/jhangyu/project/Halcyon
git merge --ff-only windows-port          # 5e35d39 -> a8ae038
```

If git refuses because of the dirty `generated_plugins.cmake`, the content is identical either way — check out the branch copy rather than stashing. **Do not `git stash` / `reset` / `checkout --` / `clean` at tree level**; `rename_dialog.dart` is live user work.

## Step 3 — post-merge gate (adopted as a fixed acceptance condition)

```bash
flutter analyze                # must be: exit 0, "No issues found!"
flutter test -j 1              # must be: exit 0, "All tests passed!", 162 tests executed
```

**All three conditions, not just the exit code.** Baseline established on `main@5e35d39` by `rev-negspace-opus`; raw output in `tmp/verify/negspace-analyze-main.txt` and `negspace-test-main.txt`. Exit 0 alone would not reveal a test file that silently stopped loading. `-j 1` is required — the default runner miscounts.

## Step 4 — land `build_apps.py` and retire the old scripts

`scripts/build_apps.py` (1668 lines) replaces `scripts/build.sh`, `scripts/windows/build_windows.py` and `scripts/windows/build_windows.ps1`.

**The deletion cannot be a separate commit.** `scripts/package_windows.sh:105` has a hard `[ -f "$PS1_SRC" ] || fail`, so removing `build_windows.ps1` breaks packaging unless `package_windows.sh:102,105,169,178` change in the same commit. `rev-buildscript-opus` notes those line numbers are post-change numbering on the branch — **re-derive them against the merged tree rather than trusting them**.

Also in this commit: `scripts/windows/README_WINDOWS.md` still documents only the `.ps1`, mandates an x64 Native Tools prompt, has no Python row in its prerequisites table, and repeats an idempotency claim the branch itself disproves. It must be rewritten or deleted alongside.

## Step 5 — SHOULD-FIX items to land with or right after the merge

Ordered by cost of *not* doing them.

| # | Item | Why now |
|---|---|---|
| 1 | Reword the `NATIVE_ASSETS_DIR` comment in `windows/CMakeLists.txt` | The recorded root cause is **falsified** — `native_assets.dart:463-465` creates the directory unconditionally, before the empty early-out. Keep the `file(MAKE_DIRECTORY)` line; fix the comment, so nobody patches `linux/CMakeLists.txt` on a false premise. |
| 2 | Reword the `find_package(Halide ... COMPONENTS Halide)` comment at `native/CMakeLists.txt:367-371` | Also falsified: bare `find_package` does **not** hard-fail without system libpng/libjpeg (reproduced rc=0). The real reason is that the bare call re-entered `find_package(JPEG)` and clobbered the deliberate static `JPEG_LIBRARIES` at `:207`. The change is right; the stated reason is wrong. |
| 3 | `native/CMakeLists.txt:445-446` → `$<TARGET_FILE_DIR:dng_warp_generator>/Halide.dll` | `${CMAKE_CURRENT_BINARY_DIR}` is the wrong directory under any multi-config generator. Works today only because the build drives single-config Ninja; Visual Studio reproduces the exact `0xC0000135` this block exists to prevent. |
| 4 | Fix `linux/CMakeLists.txt:110` — same unguarded `install(DIRECTORY "${NATIVE_ASSETS_DIR}")` | The branch fixed Windows only. Two sites, one fixed. (Asserted by symmetry — no Linux host was available.) |
| 5 | Update `docs/logs/2026-08-21/windows-verification-runbook.md:113,229` | Still tells the user to expect `photo_selector_flutter.exe`. The only place the old name is load-bearing **as an instruction** — a user following it post-merge concludes the build failed. |
| 6 | Add a prefs-migration note for Windows | `Runner.rc:98 ProductName` silently relocates `%APPDATA%\com.example\photo_selector_flutter\` → `...\Halcyon\` via `path_provider_windows` reading VERSIONINFO. Note, not code — Windows never shipped, and the state users care about is `.halcyon_status.json` in the photo folder. `CompanyName` (`:92`) is the other half of that path; fixing it later costs a second relocation. |
| 7 | `dng_processor_ffi/.gitignore` — add a `*.dll` negation | It carries defensive negations for `*.dylib` and `*.so` but none for `*.dll`. Works today, but Windows is the only deliverable without a seatbelt — and this repo has already been bitten once by a silent packaging failure. |
| 8 | Ignore `dng_processor/native/build-windows/` | Its `build/` and `build-android/` siblings are ignored (`.gitignore:25-26`); this one is not. A Windows build leaves ~159 MB untracked. |
| 9 | `dng_processor_ffi/windows/Libraries/PROVENANCE.md` | The DLL has no PDB, build-ID or VERSIONINFO, so toolchain and source commit are unrecoverable. Hygiene, not correctness: a future rebuild has no baseline to diff against. |
| 10 | Delete `dng_processor_ffi/windows/Libraries/.gitkeep` | Its own text says to delete it once the DLL is committed. |

## Settled by the user — do not reopen

- **The DLL decodes correctly and its colour matches macOS.** Verified by the user on the Windows machine, 2026-08-22. Closed.

## The one thing left that only the user can do, on the Windows machine

**Measure the cold first-decode latency for a preview-less DNG**, against the project's hard 1-second ceiling. Both architects named this the top unknown. It cannot be mitigated by decoding smaller first, because no such API exists (PL-10). Measure it before and after wiring up `warmupForSize` / `setPipelineCachePath` (PL-9).

## Limitations that must not be softened in the merge commit

- **`build_apps.py`'s native CMake path has never been executed.** Every Windows-only branch — vcvars bootstrap, registry refresh, vulkaninfo, symlink pre-check, DLL bundling — is reasoned and unit-probed, never run on Windows. First run on a real Windows machine should be treated as first contact, not a regression test.
- **The Halide sha256 values are trust-on-first-use, not an independent pin.** They catch a future asset substitution, not one that predates 2026-08-22. Upstream ships no checksum or signature asset. See PL-8 for how a human upgrades this.
- **The `ios` target in `build_apps.py` is new and unexercised.**
- **Colour correctness is SETTLED**, verified by the user on the Windows machine against macOS on 2026-08-22. Closed, not outstanding. Do not reopen it in later documents.

## Suggested merge commit framing for the decoder

The vendored `dng_pthread.h` edit **removes** a pre-existing defect rather than introducing risk. The old unguarded `#define timespec dng_timespec` was rewriting the platform's own declarations on Windows — `nanosleep`, `clock_getres/gettime/settime`, `timespec_get`, and libc++'s `__libcpp_timespec_t` all had their `timespec` textually replaced. macOS and Android are provably unaffected: preprocessed output is token-identical (`dng_pthread.cpp`) and byte-identical (`dng_mutex.cpp`) across the merge, verified with the project's real compile flags and a passing negative control. Separately, the `std::auto_ptr` → `std::unique_ptr` change was **mandatory, not cosmetic**: `auto_ptr` does not exist at `-std=gnu++17`, so the old code could never have compiled on Windows.

Do not describe the user's render confirmation as validating the `timespec` change — it validates the thread-lifecycle change only. Nothing reaches the `timespec` branch: every `dng_condition::Wait` call site takes the `-1.0` default.
