# Convergence contract — Windows port review, unified build script, cross-platform thumbnails

> Frozen 2026-08-22 by the main session (commander). Only the user may amend this contract.
> Three independent tracks, three independent terminal states. Round budget: 3 rounds each.
>
> **Execution note (2026-08-22)**: the harness allows one leader to manage only one team, so the three
> tracks run as one team `halcyon-winport` with 8 members and disjoint file ownership. "Team A/B/C"
> below reads as "Track A/B/C". Members: `rev-winbuild-opus`, `rev-buildscript-opus`, `rev-negspace-opus`,
> `impl-buildapps-opus` (A); `rev-dngsdk-opus`, `rev-cmake-opus` (B); `arch-thumb-a-opus`,
> `arch-thumb-b-opus` (C). All opus. Scratch evidence goes to `tmp/verify/` (gitignored via `/tmp/`).

## Shared ground truth (do not re-derive)

| Item | Fact |
|---|---|
| Halcyon `windows-port` | 1 commit `a8ae038` on top of `main` @ `5e35d39`; 8 files, +919/-9 |
| flutter_dng_decoder `windows-port` | 1 commit `d36e1bd`; 4 files (`native/CMakeLists.txt`, vendored `dng_pthread.{h,cpp}`, prebuilt `dng_decoder_native.dll` 1,906,688 B) |
| Prebuilt-binary precedent | `dng_processor_ffi/macos/Libraries/libdng_decoder_native.dylib` is ALREADY tracked in git. Committing the Windows DLL follows existing convention — do NOT raise it as a blocker on those grounds alone. |
| Authoritative change rationale | `docs/logs/2026-08-22/windows-port-changes.md` (on the `windows-port` branch; read with `git show windows-port:<path>`) |
| Superseded | `docs/logs/2026-08-22/windows-build-handover.md` — its P0/P1 sections are stale; only §9 (禁止重踩) and the "compiled ≠ correct" warning still hold |
| ~~Never verified~~ **RESOLVED 2026-08-22** | The user has personally confirmed on the Windows machine that `dng_decoder_native.dll` decodes DNGs and renders images correctly. **Contract amendment by the user.** Do NOT spend effort questioning the DLL's behavioural correctness, and do NOT hedge candidate designs on "the FFI path might not work on Windows" — it works. Packaging, provenance and reproducibility of the binary are still in scope; its output correctness is not. |
| Dirty working tree (Halcyon main) | `lib/views/rename_dialog.dart` — unrelated user WIP, **do not touch**. `windows/flutter/generated_plugins.cmake` — **CORRECTED 2026-08-22: this is NOT user work.** It is `flutter pub get` output written on `main` (mtime Aug 21 07:55, a day before the branch existed), and it is md5-identical to what `windows-port` commits (`8eec7fb8256eda4b8a839cc88d585fab`, commander-verified both sides). It is a generated file whose content is a pure function of the dependency set — see the "generated file is durable" row below. Merging it is a non-event. |
| Generated file is durable | `flutter_plugins.dart:992-1002` derives `FLUTTER_FFI_PLUGIN_LIST` membership purely from each dependency's `pubspec.yaml` and never reads the existing `generated_plugins.cmake`. The `ffiPlugin: true` / `windows:` declaration is on the decoder's **`main`**, not just its branch. So `flutter pub get` regenerates the `dng_processor_ffi` line identically; it cannot be lost and needs no manual protection. Source: `rev-winbuild-opus`, three independent proofs, commander-verified. |

## User decisions — round 3 (2026-08-22, Track C outcome)

8. **Dart-first is ADOPTED** for cross-platform thumbnails. Both architects converged on it independently (`thumbnail-cross-platform-analysis-a.md` Candidate 2, `-b.md` Candidate A). Deciding argument is verifiability: the work is Dart, testable on this host, needs no Windows toolchain and no new C++, and the `NativeImageNeedsRawDecode` signal can be emitted from Dart so Windows gets the raw-decode path without a runner change. macOS native stays the first rung, so it cannot regress — but the measured macOS perf path is touched and MUST be re-benchmarked.
9. **Windows export EXIF loss is a separate ticket, fixed now.** `halcyon_image.cpp:333` re-encodes without an EXIF block, so camera/lens/date/GPS are silently dropped on every Windows export, versus macOS which copies properties and forces `Orientation=1` (`AppDelegate.swift:266,271`). This is shipping data loss, and the Dart-first work cannot reach it. Carved out so it does not get buried.
   **Verification constraint, stated up front:** this fix is Windows C++ that cannot be compiled or run on this macOS host. It can only be verified on the user's Windows machine.

## User decisions — round 2 (2026-08-22, later)

5. **Windows DLL colour correctness is CONFIRMED** — the user compared output against macOS, not just "an image appeared". This downgrades reviewer BLOCKER B1 from "the shipped DLL is untrusted" to "the script wrongly reports success when the gate did not run". B1 is therefore NOT a merge blocker, but the mechanism defect is still fixed in `build_apps.py`.
6. **macOS builds arm64 only this round.** x86_64 / Intel support is parked as PL-6.
7. **Halide download gets a sha256 pin.** Reviewer finding S1 is accepted and enters this round.

## User decisions already made (2026-08-22)

1. **Merge policy**: reviewers report → commander summarises → **user approves** → merge. No team merges anything.
2. **build_apps.py**: single source of truth, replaces both `scripts/build.sh` and `scripts/windows/build_windows.py`.
3. **build_apps.py scope**: covers native (`dng_processor`) build AND Flutter build, all platforms.
4. **Thumbnail**: analyse first, produce 2-3 candidate architectures with trade-offs, user picks. Do not implement.

---

## Team A — Halcyon windows-port review + unified build script

**Terminal state (one sentence)**: A written, evidence-backed review verdict on Halcyon's `windows-port` branch, plus a `scripts/build_apps.py` that builds every supported target (native + Flutter) from one entry point, both awaiting user approval before anything merges.

### In scope
- Review of `git diff main...windows-port` in `/Users/jhangyu/project/Halcyon` (8 files).
- New file `scripts/build_apps.py`.
- Review report at `docs/logs/2026-08-22/review-halcyon-windows-port.md`.

### Out of scope
- Merging, committing, rebasing, or pushing anything.
- `lib/` Dart source (no Dart changes exist in this branch).
- Deleting `scripts/build.sh` / `scripts/windows/build_windows.py` / `build_windows.ps1` — deletion happens at merge time, after user sign-off.
- The thumbnail problem (Team C owns it).

### Acceptance conditions (mechanically checkable)
- **A1** Each reviewer writes its OWN file `docs/logs/2026-08-22/review-halcyon-winport-<slot>.md` (slot = `winbuild` / `buildscript` / `negspace`); no two reviewers write the same file. Every finding tagged `[BLOCKER]` / `[SHOULD-FIX]` / `[NIT]` with a `file:line` citation. The commander merges them.
- **A2** The report explicitly answers the negative-space question for each of the 8 changed files: *what existing behaviour does this diff remove or alter, and who depended on it?* — in particular the `photo_selector_flutter` → `halcyon` binary rename (does anything outside `windows/` reference the old name?) and the `package_windows.sh` change.
- **A3** `scripts/build_apps.py` exists, `python3 -m py_compile scripts/build_apps.py` exits 0.
- **A4** `python3 scripts/build_apps.py --help` exits 0 and lists targets covering: macos, ios, android, web, windows, linux, plus an `all` mode.
- **A5** `python3 scripts/build_apps.py macos` (or the host-appropriate equivalent) actually produces a build artifact on this macOS host — **a real run, not a dry-run**. Path of the produced artifact recorded in the report.
- **A6** Every capability present in `scripts/build.sh` (224 lines) and in `windows-port:scripts/windows/build_windows.py` (624 lines) is either reproduced in `build_apps.py` or listed in the report as a deliberate, justified drop. A line-item table, not prose.
- **A7** `flutter analyze` still reports 0 issues.

### Red lines
- No `git merge` / `commit` / `push` / `rebase` / `stash` / `reset` / `checkout --` / `clean`. Read-only git (`show`, `diff`, `log`) is fine.
- Do not edit `lib/views/rename_dialog.dart` or any file under `lib/`.
- Do not edit files on the `windows-port` branch; work only against `main`'s working tree.
- Any reviewer finding *about `build_windows.py`* is folded into `build_apps.py` by the implementer — do not patch the old file.

---

## Team B — flutter_dng_decoder windows-port review

**Terminal state**: A written, evidence-backed review verdict on `/Users/jhangyu/project/flutter_dng_decoder`'s `windows-port` branch, focused on whether the vendored Adobe DNG SDK edits are safe for the already-shipping macOS/Android builds.

### In scope
- Review of `git diff main...windows-port` in `/Users/jhangyu/project/flutter_dng_decoder`.
- Review report at `/Users/jhangyu/project/flutter_dng_decoder/docs/review-windows-port.md` (create `docs/` if absent).

### Out of scope
- Merging, committing, pushing. Any source edits at all — this team is read-only except for its report.
- Building or running anything that mutates `native/build*/`.

### Acceptance conditions
- **B1** Each reviewer writes its OWN file `/Users/jhangyu/project/flutter_dng_decoder/docs/review-winport-<slot>.md` (slot = `dngsdk` / `cmake`); findings tagged `[BLOCKER]`/`[SHOULD-FIX]`/`[NIT]` with `file:line` citations.
- **B2** The `dng_timespec` removal is independently verified, not taken on the branch author's word. Specifically, mechanically confirm and cite: (a) every reader of `struct timespec` / `dng_timespec` / `dng_pthread_now` / `dng_pthread_cond_timedwait` in the repo; (b) that no `sizeof`/`memcpy`/`memset`/`memcmp` touches a timespec (author claims 0 hits — re-run the grep and paste it); (c) that the non-`qWinOS` preprocessed output is byte-identical, i.e. the macOS/Android build is genuinely unaffected.
- **B3** The `auto_ptr` → `unique_ptr` change at `dng_pthread.cpp:316-317` is checked for ownership-semantics differences (`auto_ptr` copy-transfers, `unique_ptr` does not) across the whole function, including the `delete resultHolder` sites the author cites.
- **B4** The `CMakeLists.txt` changes are assessed for cross-platform regression: does `find_package(Halide REQUIRED COMPONENTS Halide)` drop components macOS relied on? Does the `MultiThreadedDLL` save/restore at `:386-387`/`:427` leak state to targets defined after `:427`? Does the `dng_stage_halide_dll` custom target fire on non-Windows?
- **B5** A verdict line: `MERGE-READY` / `MERGE-AFTER-BLOCKERS` / `DO-NOT-MERGE`, with the blocker list.
- **B6** macOS build of the native library still succeeds (or, if too expensive, the report states explicitly that this was not run and why).

### Red lines
- No writes anywhere except the report file. No git mutations.
- Do not delete or "fix" the 7 blank libjpeg-turbo stub `.in` files; they are a deliberate documented bypass.

---

## Team C — cross-platform thumbnail architecture analysis

**Terminal state**: A design document presenting 2-3 candidate architectures for making thumbnail/preview extraction platform-agnostic, each with trade-offs, work estimate, and blast radius — for the user to choose from. **No implementation.**

### Problem statement — CORRECTED 2026-08-22 (v1 was factually wrong; caught by `rev-negspace-opus`, re-verified by the commander against the source)

**What v1 of this contract claimed, and why it was wrong.** v1 said `halcyon/thumbnail` is "implemented only in `macos/Runner/AppDelegate.swift`" and that "on Windows the channel is absent", so `native_thumbnail_service.dart:122` catches `MissingPluginException`. **That is false on `main` today.** The `MissingPluginException` path is dead code on Windows. Two stale sources led to this error and must not be trusted again: `CLAUDE.md`'s "Native bridges" section, and the comment at `native_thumbnail_service.dart:122-129` which still names Windows as having no implementation.

**Ground truth, verified in the tree on `main`:**
- `windows/runner/halcyon_channels.cpp:67` registers `halcyon/thumbnail` (`:71` handles `getThumbnail`), `:109` `halcyon/trash`, `:143` `halcyon/open_with`.
- `windows/runner/halcyon_image.cpp` (424 lines) is a full WIC-backed implementation: EXIF Orientation read via WIC metadata query (`:118`), orientation→transform mapping (`:148`), orientation applied at `:338-343`, the macOS JPEG-passthrough mirrored at `:410-418`, decode+re-encode at `:420`.
- `windows/runner/CMakeLists.txt:11-13` compiles all three. All files are tracked. None of this is in the `windows-port` diff — it predates the branch.

**The actual bypass is `windows/runner/halcyon_image.cpp:392-403`.** `IsRawExtension` (`:372-381`, covering `.dng .arw .cr2 .nef .orf .rw2`) short-circuits BEFORE any decode and returns `Fail("RAW_UNSUPPORTED", ...)` — and the comment there says the choice of `RAW_UNSUPPORTED` over `kNoEmbeddedPreviewCode` is deliberate, precisely so Dart builds `NativeImageFailure` instead of `NativeImageNeedsRawDecode` and never goes looking for a `DngFullDecoder`.

**Its stated premise is now false.** The comment justifies the bypass with "there is no Windows build of the native decoder (`docs/logs/2026-08-21/premise-audit-platforms.md`)". As of 2026-08-22 there is one, and the user has confirmed it decodes correctly.

**Also relevant:** `lib/services/dng_preview_extractor.dart` (479 lines) is an existing pure-Dart port of the macOS embedded-preview extractor, already wired at `image_preload_controller.dart:661`.

**What this means for the scope.** The gap is narrower and better-defined than "make thumbnails cross-platform": it is that one hard-coded RAW rejection plus whatever embedded-preview and full-decode routing has to exist behind it. Candidates must be sized against THAT, not against a from-scratch cross-platform redesign. A candidate that proposes replacing the working macOS or Windows native path must justify the cost against a concrete failure, not against tidiness.

### In scope
- Read-only analysis of the image pipeline: `lib/services/{native_thumbnail_service,dng_preview_extractor,image_preload_controller,dng_decode_contract,dng_decode_service,thumbnail_export_service}.dart`, `lib/providers/app_state.dart:86`, `macos/Runner/AppDelegate.swift`.
- Design doc: the two architects work **independently on the identical full task** (map + propose) and each writes its own file — `docs/logs/2026-08-22/thumbnail-cross-platform-analysis-a.md` and `-b.md`. They do NOT split the work and do NOT read each other's file; divergence between two independent takes is the point (this is an architecture/taste call, judgment-rubrics R6.1). The commander synthesises both into one recommendation for the user.

### Out of scope
- **All code changes.** This round is analysis only.
- The Windows native build (Teams A/B own that).

### Acceptance conditions
- **C1** Doc exists and states the exact current call graph from `AppState:86` down to pixels on screen, with `file:line` for every hop, separately for: JPEG, DNG-with-embedded-preview, DNG-without-embedded-preview — on macOS and on Windows. The Windows column must say precisely where each path dies today.
- **C2** 2-3 named candidate architectures, each with: how it handles all three of `sidebarThumbnail` (200px) / `preview` (2800px) / `export` (2048px, EXIF carry-over with Orientation forced to 1); which files change; estimated work; what could regress on the already-verified macOS perf path; and how EXIF orientation gets applied.
- **C3** Each candidate is checked against `memory.md` AD-010/AD-011 (the frozen 3-variant `NativeImageResult` seam) and states whether it requires breaking that freeze.
- **C4** *(amended 2026-08-22 — both architects flagged that this line contradicted the ground-truth table; they were right, and both worked to the amended reading below.)* The Windows FFI decode path WORKS (user-confirmed, including colour). C4 is therefore an **API-level dependency check**, not a does-it-work check: each candidate states what it needs from the FFI surface (API shape, sizing control, orientation handling, threading) and whether today's API satisfies it.
- **C5** A recommendation with a one-paragraph justification, plus an explicit list of what the analysis could NOT determine.
- **C6** No file under `lib/`, `macos/`, or `windows/` is modified. Verified by `git status`.

### Red lines
- No code edits, no git mutations, no builds.
- Do not propose UI-driven verification (simulated clicks / osascript / screenshots) — the user has banned it.

---

## Parking lot (populated during execution; reported to user at the end)

Nothing here enters the current round, becomes an acceptance condition, or jumps the queue.

| # | Item | Source | Commander's spot-check |
|---|---|---|---|
| ~~PL-1~~ **DECIDED** | **Committed macOS dylib is arm64-only, but `Halcyon.app` links fat x86_64+arm64.** The x86_64 slice therefore ships without the native decoder. | `impl-buildapps-opus`, A5 run | **CONFIRMED.** `lipo -info` on `dng_processor_ffi/macos/Libraries/libdng_decoder_native.dylib` → "Non-fat file ... arm64"; `lipo -info` on the freshly built `Halcyon.app/Contents/MacOS/Halcyon` → "x86_64 arm64". Pre-existing. **User decision 2026-08-22: build arm64 only this round; x86_64 support is parked (PL-6).** |
| PL-7 | **`-fvisibility=hidden` on `dng_sdk`.** `_dng_pthread_now` is one of ~2,411 wholesale-exported symbols in the shipping macOS dylib. Raised by `rev-dngsdk-opus` and routed to `rev-cmake-opus` — **the routing failed; that message never arrived and the question is UNANSWERED.** Do not record it as reviewed. | `rev-dngsdk-opus`; routing failure self-reported by `rev-cmake-opus` | Partial evidence exists: the Windows DLL exports exactly 12 symbols vs the macOS dylib's 12 + Halide AOT kernels + mangled `dng_sdk` internals. That asymmetry is Windows requiring explicit `dllexport` vs Mach-O default visibility — it is NOT evidence about a visibility flag either way. Answering it needs the export-control macros in the FFI source read, which nobody has done. |
| PL-8 | **Halide pins are trust-on-first-use, not an independent pin.** All five assets are pinned from the GitHub release API digest — same authority that serves the bytes. Catches a future substitution; does not catch bytes already substituted before 2026-08-22. Upstream publishes no checksum or signature asset (verified: v21.0.0 has 8 assets, none checksum-like). | `impl-buildapps-opus`, S1 | Stated in three places in the script so it cannot be misread as a pin. **To upgrade to a real pin:** a second person, on a different machine and network, downloads `Halide-21.0.0-arm-64-osx-b629c80de18f1534ec71fddd8b567aa7027a0876.tar.gz` (168,591,078 B), runs `shasum -a 256`, and confirms `040a6fbde5ba264870df4975138417ce2ff2c8e9de550302c8b17f36c36e5afa`. Record who verified and when. Deliberately not automated — a second download by the same script on the same machine re-derives the same TOFU value and would look like verification while proving nothing. |
| PL-9 | **`warmupForSize` / `setPipelineCachePath` / `savePipelineCache` / `getPreviewJpegOnWorker` have ZERO call sites** in `lib/` and `test/`. Commander-verified. The R2 handover budgets a whole upstream round for "first decode >1s → VkPipelineCache generalisation", but the Dart-side call is a one-liner in `main.dart` that was never made. Compounding: `decodeOnWorker` spawns a fresh `Isolate.run` per call and re-opens the `DynamicLibrary` inside it every time. | both architects, independently | Cheapest available shot at the 1s ceiling, independent of which thumbnail design wins. Whether the shipped DLL has `DNG_VK_PIPELINE_CACHE=ON` is unknown. |
| PL-10 | **`decodeOnWorker(String)` has no target-size entry point** — always full-resolution RGBA (~50MB). No sizing control exists at any FFI layer. A 200px sidebar row therefore costs a full RAW decode under every candidate design, on macOS too. | both architects, independently; signature commander-verified | Upstream feature request. This is why the "decode small first" mitigation for the 1s ceiling does not exist. |
| PL-11 | Deleting `DngPreviewExtractor.swift` (348 lines). The Dart extractor is a parity-verified, measured port and is already the Windows path; the Swift one exists only because it predates it. Net deletion. | `arch-thumb-b-opus` §5 | Blocked on measuring the macOS-path cost first. |
| PL-6 | Restoring x86_64 / Intel Mac support. Would require a fat `libdng_decoder_native.dylib`, which means a dual-architecture native build; the Halide AOT target string is single-arch, so this is not a flag flip. | User decision, deferred from PL-1 | Not started. |
| PL-2 | `linux/CMakeLists.txt:110` has the same unguarded `install(DIRECTORY "${NATIVE_ASSETS_DIR}")` clean-build defect that `windows-port` fixed for Windows only. | `rev-negspace-opus` SF-3 | Not spot-checked; asserted by symmetry, no Linux host available. |
| PL-3 | `scripts/windows/README_WINDOWS.md` still directs users to the superseded `.ps1` and mandates the x64 Native Tools prompt, while `package_windows.sh:170` now ships `build_windows.py`. Remedy depends on whether `build_apps.py` replaces the `scripts/windows/` entry point at merge time. | `rev-negspace-opus` SF-1 | Not spot-checked. |
| PL-4 | `CLAUDE.md`'s "Native bridges" section and the comment at `native_thumbnail_service.dart:122-129` both assert Windows has no `halcyon/thumbnail` implementation. Both are stale and actively misled the drafting of this contract. | Commander | **CONFIRMED** — see the corrected Track C problem statement above. |
| PL-5 | `Runner.rc:92,96` still carry `com.example` while `:93,98` were updated to Halcyon. | `rev-negspace-opus` NIT | Not spot-checked. |

## Merge-order precondition (NOT parking-lot — this is a hard dependency)

`flutter_dng_decoder` `windows-port` (`d36e1bd`) **must merge before** Halcyon `windows-port` (`a8ae038`). Halcyon's `windows/flutter/generated_plugins.cmake:10` adds `dng_processor_ffi` to `FLUTTER_FFI_PLUGIN_LIST`, `:24` dereferences `${dng_processor_ffi_bundled_libraries}`, which resolves via the decoder repo to `Libraries/dng_decoder_native.dll` — a file that exists only on the decoder's `windows-port` branch. Reversed order breaks `flutter build windows` on a clean checkout. Source: `rev-negspace-opus` SF-4.

## Post-merge gate (adopted 2026-08-22)

`flutter analyze` exit 0 **and** `flutter test -j 1` exit 0 **with 162 tests executed**. Baseline established on `main@5e35d39` by `rev-negspace-opus`; raw output in `tmp/verify/negspace-analyze-main.txt` and `negspace-test-main.txt`. Exit code alone is insufficient — it would not reveal a test file that silently stopped loading.
