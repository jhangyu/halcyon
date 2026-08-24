# M6 spec & contract — unified Dart core, cross-platform parity

> Master table: m6-feature-platform-matrix.md — update the matrix first, then sync this file.

> **Consolidated** 2026-08-24 from `m6-contract-rewrite.md`, `m6-arch-reevaluation.md`, `platform-only-inventory.md` and `platform-only-inventory-addendum.md` (all four now deleted; superseded by this file + `m6-execution-plan.md`). Precedence when sources disagreed: matrix `RULED:` verdicts (newest, matrix §2/§3) > `m6-pkg-verification.md` findings > the Windows-RAW arbitrated correction below > `m6-arch-reevaluation.md` > `m6-contract-rewrite.md` > addendum > first inventory.
> This file owns the WHAT and the RULES. Phases, gates, tests and risks live in `m6-execution-plan.md`.

---

## 0. Execution status (R1 session 2 close, 2026-08-24)

C-1's terminal state is REACHED for the image/EXIF core: photo byte production, sidebar thumbnails, export, and EXIF reads are implemented once in Dart and the native `halcyon/thumbnail`/`halcyon/exif` paths are deleted (ledger: `m6-execution-plan.md` "Execution status ledger"; tree @ 2f01a6b, suite 272/272, macOS+Android release builds green, both round reviews MERGEABLE). Declared exceptions (C-2) unchanged and verified surviving: Trash, Open-With transport, file association. C-3 grep guard: 0 outside `perf_driver.dart` + the F-19 site. C-5's gate history closed by rulings P-9/P-10/P-13 (new standing rule: <75 ms absolute passes outright). §4's U-11/U-12 are now IN EFFECT in code. P-14 added core-tag EXIF carry-over to export. Remaining scope: OS-integration items (P4) and closure items (P5); open decision: P-2 only.

## 1. Contract terms (C-1…C-8)

**C-1 — Terminal state.** Halcyon's photo behaviour — which files load, what pixels appear, what a delete does, what an export produces — is implemented once in Dart and produces the same observable result on every supported platform; the native runners hold app shell and window plumbing only.

**C-2 — The parity rule.** No behaviour may exist on a subset of the supported platform set. Native code (including a Flutter *package* that itself wraps per-platform native code, e.g. `desktop_drop`) is permitted only as an accelerator that (a) exists on every supported platform and (b) is proven output-identical to the Dart implementation. Performance is not behaviour; output is.
**Adjustment (matrix rulings, 2026-08-24 3rd/4th pass — supersedes the original blanket reading):** `desktop_drop` covers macOS+Windows+Linux for F-17 and is adopted. The user granted **declared exceptions** to the parity rule for: F-12 system Trash (keep existing macOS+Windows native channels — no Dart package exists), F-16 Open With (universal on macOS/Windows/Android/iOS via native transport + mobile handler wiring; Linux excluded), F-18 file association (Windows+macOS). These exceptions are enumerated and closed — nothing else may cite them as precedent. Practical rule, unchanged for the rest: **`halcyon/thumbnail` and `halcyon/exif` native paths are deleted, not ported** (RULED unified Dart).

**C-3 — No platform branches, ever.** `Platform.isX`, `kIsWeb`, `defaultTargetPlatform`, conditional imports, and shelled-out platform binaries are forbidden in `lib/` (mechanically checked; count is 0 today outside `perf_driver.dart`'s env reads). A feature that cannot be written this way is removed from the product, not special-cased. **Enumerated exception (F-19 ruling, 2026-08-24 4th pass):** the reveal-in-file-manager implementation may use `Process.run` with per-platform commands (`open -R` / `explorer.exe /select,` / `xdg-open`) in exactly one place, with awaited error handling; the grep guard excludes that one site by file, everything else stays at 0.

**C-4 — Tests follow the contract, not the other way round.** A test asserting single-platform semantics is deleted with its reason recorded. The frozen-file seal (`baseline-registry.md:47-51`) is lifted only for those tests; every other byte of a frozen file stays identical, and new sha256 values are re-registered in the same commit. See `m6-execution-plan.md` §2 for the disposition table.

**C-5 — Performance is gated, but a gate failure does not buy back a macOS-only path.** Gate G1/G2/G3 (`m6-execution-plan.md` §1) runs before any native deletion. **P-8 RESOLVED (2026-08-24 4th pass): Swift-accelerator retention is REJECTED by the user** (rationale: cheap-DNG display is embedded-JPEG extraction, which the pure-Dart walker already serves on Windows today, so Dart is expected to match). On FAIL: optimise and re-gate — never "keep the fast macOS-only branch."

**C-6 — Scope.** In: everything in the matrix's §2 target column for the platforms the user selects in P-1. Out: new features, UI redesign, the sibling `dng_processor_ffi` native build work beyond declaring what is needed (P-2), and any measurement of UI latency or memory (user-run only; MEMORY: agents are restricted to headless decode benchmarks).

**C-7 — Round budget: 3 rounds.** Parking-lot discipline applies: findings during a round do not become acceptance criteria for that round.

**C-8 — Blocking precondition: RESOLVED (2026-08-24 4th pass).** P-1 is answered as a **per-feature preference cascade**: 1st choice all platforms; 2nd macOS+Windows+Linux+Android; 3rd macOS+Windows+Linux; minimum macOS+Windows. Each feature lands on the widest tier it can actually support; structural blockers (F-26 iOS sandbox, F-27 web compile) demote that platform per feature, not globally. Code may move.

---

## 2. Design decisions

### 2.1 `PhotoSource` becomes the byte source (chosen shape)

`PhotoSource` stops being a switch over someone else's answer and becomes the thing that produces bytes for all three purposes (detail view, sidebar, export):

```
PhotoSource.load(path, longEdge, allowExpensive):
  jpeg/png        -> File.readAsBytes                                -> EncodedPayload, cost cheap
  dng / tiff-raw  -> DngPreviewExtractor.extractFullSizeEmbeddedJpegFromFile   (:87)
       hit        -> EncodedPayload, cost cheap                        (ruling a)
       miss       -> needsRawDecode(orientation: readOrientation(path) (:109)
                        ?? kDefaultExifOrientation)                    (ruling b)
                     -> !allowExpensive ? deferred+orientation (I6)
                        : DngFullDecoder -> PixelPayload + M5 fullRes  (photo_source.dart:166-176, unchanged)
  sidebar (200px) -> same bytes source -> ui.instantiateImageCodec(targetWidth:200)   (D-20)
  export (2048px) -> same bytes source -> decode/resize/encode                        (D-21)
```

The injected loader seam (`NativeImageLoad`, `photo_source.dart:76-80`; production default `app_state.dart:83-89`) is **kept** as a test-injection point, with a pure-Dart production implementation. `NativeImageNeedsRawDecode` is **kept as a type** — ruling (b) moves only the *producer* into Dart; the variant still carries "this file needs a real decode" to the scheduler and to M5's tier-2 (`photo_source.dart:166-176`). Renaming the type (e.g. `ImageSourceResult`) is optional cleanup, not a requirement.

### 2.2 Rejected alternatives

| Shape | Verdict |
|---|---|
| **(a) Loader-seam-only** (earlier design, driven by the now-deleted frozen test TC-089) | **Rejected as the primary shape.** It fixes the detail view only and leaves two of the three byte paths still calling native directly: the sidebar (`image_preload_controller.dart:1181-1185`) and export (`thumbnail_export_service.dart:37-40`) bypass `PhotoSource.load` entirely — both would stay platform-gated, which C-2 forbids. |
| **(b) Dart-first inside `PhotoSource`** — **chosen** | One type-aware layer owns byte acquisition for all three purposes, so parity is structural rather than per-call-site; removes the `allowRawDecodeSignal` negotiation protocol entirely. |
| **(c) Delete `NativeImageNeedsRawDecode` as a type** (now permitted, no longer test-frozen) | Rejected on architectural merit. Collapsing it into a bytes-or-null return would re-merge the deferral vs. permanent-miss cases that `SourceOutcome.deferred` exists to separate (`photo_source.dart:28-44`). Ruling (b) is satisfied by relocating the producer; deleting the type buys nothing and costs the I6 distinction. |
| **(d) Keep native as a macOS accelerator behind the seam** | Forbidden by C-2 unless it exists on every supported platform *and* is proven output-identical. |
| **(d′) Keep CIRAWFilter as a "fallback only" path** | Still single-platform behaviour — the exact shape the ruling forbids. Recorded so it isn't rediscovered as a clever compromise. |

---

## 3. Evidence base (key file:line facts)

- **Windows RAW behaviour — corrected statement (arbitrated, supersedes an earlier signed-off claim in `m6-arch-reevaluation.md` §0.3 that "a cheap DNG does not load on Windows at all"):** Windows native fails **all six** RAW extensions pre-extraction (`windows/runner/halcyon_image.cpp:509-518`, `:529-540`, returning `RAW_UNSUPPORTED`); the Dart walker then recovers `.dng` for the **detail view only** (`RAW_UNSUPPORTED` ≠ `NO_EMBEDDED_PREVIEW` → `NativeImageFailure` at `native_thumbnail_service.dart:125-132` → `fallbackAfterNativeFailure` at `photo_source.dart:190-201`, `:364-367`, yielding `EncodedPayload` with `observedCost: cheap`). Non-DNG RAW is dead everywhere, and **all sidebar thumbnails are blank on every platform** because `image_preload_controller.dart:1181-1185` bypasses `PhotoSource.load` entirely. Caught by the adversarial addendum (§1.7, §2.3), arbitrated against source.
- Sole tree-wide producer of `NativeImageNeedsRawDecode`: `native_thumbnail_service.dart:126-129`, gated on the macOS-only emission at `AppDelegate.swift:396` (condition `:391`, orientation via `readDngOrientation` `:393`).
- Cost classification + orientation are **already** pure Dart, cross-platform, one IFD walk: `photo_source.dart:302-333` → `DngPreviewExtractor.probeContent` (`:319`); memo fill `image_preload_controller.dart:713-721`; tier-2 read `:895-903`. This is why the rewiring is localized — only the *entry decision* inside `load()` changes.
- Pure-Dart extractor is a complete, deliberately platform-free port: `dng_preview_extractor.dart:5-20` (header), `:60` `extractEmbeddedJpeg`, `:87` `extractFullSizeEmbeddedJpegFromFile`, `:109` `readOrientation`, `:137` `readDngOrientation`, `:226` `probeContent`.
- I/O strategy differs (why the benchmark gate is mandatory): Swift `Data(contentsOf:)` (`DngPreviewExtractor.swift:50`) vs. Dart paged `readSync` 8 KB × 48 LRU, 64 KB direct-read threshold (`dng_preview_extractor.dart:626-628`, `:679-682`); Swift baseline measured at 0.7–1.2 ms.
- FFI decoder platform reach = macOS, Android, Windows only (`../flutter_dng_decoder/dng_processor_ffi/pubspec.yaml` `flutter.plugin.platforms`); no iOS, no Linux.
- `halcyon/exif` is the existing parity gold standard: `MissingPluginException` → `readWithPackage` (`exif_metadata_service.dart:50-51`), isolate fallback (`:78-80`).
- Windows `halcyon/open_with` **is** wired in the push direction (resolves the first inventory's §7 uncertainty): channel `halcyon_channels.cpp:142-143`; sender `:160` `PushOpenFile`, called at `flutter_window.cpp:48` (launch file) and `:87` (running instance).
- **Three falsehood-erratum obligations** — the same incorrect claim ("a Dart-side construction point for the raw-decode signal already exists") is recorded in three places and must be corrected as part of this work: `memory.md:92` (AD-010), `native_thumbnail_service.dart:83-88`, `windows/runner/halcyon_image.cpp:533-536`.
- **Frozen-file unsealing scope**: the `baseline-registry.md:47-51` seal is lifted **only** for tests that conflict with cross-platform parity (C-4). Every other byte of a frozen file, and every test whose assertion is still true cross-platform, stays untouched.
- **Benchmark artifact reference**: prior 94–183× native-vs-fallback speed figures on cheap DNGs are recorded in `scripts/tmp/round2-verify/20260823T173937Z-risk1-cheap-dng-bench.txt` — quoted, not re-verified, by `m6-arch-reevaluation.md` §7; the pre-registered G1 gate (`m6-execution-plan.md` §1) is what actually re-measures Dart vs. Swift for this round's decision.
- **Test-count baseline discrepancy**: `baseline-registry.md:42` records 238 executed tests; the M6 rederivation handover records 252. Both are in the tree; do not assert either — measure the count **in the same session** immediately before Phase 2 changes land (`m6-execution-plan.md` Phase 2 AC 2).

---

## 4. Capability losses (accepted trade-offs, not silent regressions)

- **U-11 — Non-DNG RAW rendering loss.** Converging non-DNG RAW (`.arw/.cr2/.nef/.orf/.rw2`) to "embedded-preview extraction only, everywhere" (matrix F-08, RULED unified Dart) means **macOS loses CIRAWFilter full rendering** for files with no embedded preview. Hit rate of the Dart embedded-preview extraction on these formats is unmeasured; Phase 1 measures it before promising coverage.
- **U-12 — "Degraded, never blank" guarantee dies on macOS.** Today `_legacyBytes` (`photo_source.dart:282-288`) re-requests with `allowRawDecodeSignal: false`, and macOS answers with CIRAWFilter pixels — slow, capped at 2800 px, but a picture (oracle-protected at `test/image_preload_controller_test.dart:1118-1120`). No other platform has ever had this. Under the ruling this is single-platform behaviour and is removed; the uniform replacement is an explicit "this file needs a RAW decoder that is not available" state on **every** platform, including macOS.

---

## 5. Open user decisions

Full P-1…P-8 platform-set and scope table lives in `m6-feature-platform-matrix.md` §3 — reference by ID there, not duplicated here. **All former open decisions were ruled on 2026-08-24 (3rd + 4th pass); statuses below are final:**

- **P-1 RESOLVED**: per-feature preference cascade (see C-8).
- **F-05 (HEIC) RESOLVED**: remove from the supported set now; add a HEIC decoder later as a separate follow-up task. (Also fixes the "prefers the file that fails" bug, `supported_photo_formats.dart:47-56`.)
- **F-12/F-13 (system Trash) RESOLVED**: keep the existing macOS+Windows native channels as a declared exception; `.trash/` recycle (F-13) stays as-is alongside.
- **F-16 (Open With) RESOLVED**: universal support on macOS/Windows/Android/iOS (Linux excluded). Existing native transport kept on desktop; Android/iOS get new handler wiring (candidate `open_file_handler`).
- **F-17 (drag-drop) RESOLVED**: adopt `desktop_drop` (macOS+Windows+Linux), replacing the Windows-only native implementation.
- **F-19 (reveal in file manager) RESOLVED**: direct `Process.run` per-platform commands (macOS `open -R` file-select, Windows `explorer.exe /select,` file-select, Linux `xdg-open` folder-open), no package; fix the discarded-`Future` bug (`status_line.dart:158-161`). Note: this is Halcyon→OS; the OS→Halcyon "open file in Halcyon and navigate to it" flow is F-16 and is unaffected.
- **P-5 RESOLVED**: adopt the pure-Dart `image` package for export (JPEG kept); a HEIC-capable package may also be adopted if one exists (none pure-Dart today — ties to the F-05 follow-up).
- **P-8 RESOLVED**: see C-5 — Swift-accelerator retention rejected; on gate FAIL optimise and re-gate.
- **P-9 RESOLVED (2026-08-24 5th pass)**: synchronous same-isolate extraction accepted (G1 V1 PASS at 0.5–1.2 ms/extraction; the pre-registered UI-jank escalation was put to the user and accepted; no resident-isolate rework).
- **P-10 RESOLVED (2026-08-24 5th pass)**: G2's JPEG-read latency FAIL accepted (bytes/dims identical, worst 0.51 ms absolute); the latency clause no longer blocks deletion of the JPEG passthrough; no re-gate for this path.
- **P-11 RESOLVED (2026-08-24 5th pass)**: sidebar thumbnails use the 200 px smallest-candidate extraction entry point + decode-time long-edge downscale; the corrected-route re-gate (execution-plan P2.6) remains the deletion gate.
- **P-12 RESOLVED (2026-08-24 6th pass)**: the G3′ re-gate confirmed 13 bare-CFA DNGs (no embedded JPEG at any size) as a real capability gap. User ruling: sidebar gains a RAW-decode fallback through the FFI sized-decode entry (`decodeOnWorker(maxDim:)` — the vendored dylib exports the sized symbol; verified). FFI-tier platforms only (P-1 cascade); no-FFI platforms keep the uniform explicit miss. Execution-plan task P2.5b; deletion stays gated on the follow-up G3″ re-gate. The JPEG cache-encode latency item stays under C-5's optimise-and-re-gate loop.
- **P-13 RESOLVED (2026-08-24 7th pass)**: sidebar gate PASSED by user ruling. **Standing amendment to the C-5 gate rule: any per-sample decode latency under 75 ms passes outright, regardless of the 2.0× ratio clause**; the measured 75–100 ms bare-CFA samples were explicitly accepted in the same ruling (background, once per file, cached). The JPEG sidebar latency item is closed and leaves the optimise-and-re-gate loop. P3 native deletion is unblocked.
- **Remaining open item: P-2 only** (Linux `.so` build for the FFI decoder — under the cascade, F-07/F-09 land on the macOS+Windows+Android tier until it exists).

---

## 6. §7.1 corrections log (preserved verbatim from `m6-arch-reevaluation.md`)

| What I claimed | What is true | How it was caught |
|---|---|---|
| "On Windows a cheap DNG does not load either" (§0.3, first revision; also reported to the lead) | Windows native fails all six RAW extensions pre-extraction, but `RAW_UNSUPPORTED` ≠ `NO_EMBEDDED_PREVIEW`, so it maps to `NativeImageFailure` (`native_thumbnail_service.dart:125-132`) and `fallbackAfterNativeFailure` recovers `.dng` for the **detail view** (`photo_source.dart:190-201`, `:364-367`). Non-DNG RAW is dead everywhere, and the sidebar is blank for all of them on every platform (`image_preload_controller.dart:1181-1185`) | Auditor addendum §1.7 + §2.3, arbitrated by the lead against source. My error was stopping the trace at the native `Fail(...)` instead of following the Dart mapping — the same "read one layer, infer the rest" failure the inventory's §6 claim made |
| Scoping that followed from it ("the fix makes DNG work on Windows for the first time") | The Windows-facing fix is routing the sidebar through `PhotoSource` and covering non-DNG RAW — **not** a Windows-side DNG extractor | Same |
| "`NativeImageNeedsRawDecode` cannot be deleted because frozen tests construct it" (§2.2, first revision) | It *can* now be deleted; it is kept because deleting it would collapse the deferred-vs-permanent-miss distinction (`photo_source.dart:28-44`), which is an architectural reason, not a test-freeze one (§2.2 row (c)) | The user's second ruling |
