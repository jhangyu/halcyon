# Halcyon feature × platform availability matrix (M6 contract rewrite, task #4)

> **Created**: 2026-08-24, `architect-opus` (team `m6-redef-team`, TaskList #4)
> **Tree**: `main`, code anchor `c2ae385`, docs tip `8ece43d`. Every cell was re-derived from source; `file:line` given for the load-bearing ones.
> **Sources folded in**: `platform-only-inventory.md` (task #1), `platform-only-inventory-addendum.md` (task #3, adversarial), plus my own sweep for task #2.
> **Ruling in force** (user, 2026-08-24): single-platform-only behaviour or syntax is **strictly forbidden**; conflicting contracts get rewritten; conflicting tests get **deleted**, and the frozen-file seal in `baseline-registry.md` is lifted for exactly those tests.
> **Nothing was executed for this document** — no build, no test run. Claims marked *(unverified)* need one mechanical run to settle.

## Legend

| Symbol | Meaning |
|---|---|
| ✅ | Works today |
| ⚠️ | Works but diverges in output, quality or side effects |
| ❌ | Does not work (silent no-op, exception, blank, or compile failure) |
| — | Structurally impossible on that platform without a different app architecture |

Columns: **mac** = macOS, **win** = Windows, **lin** = Linux, **and** = Android, **ios** = iOS, **web** = Flutter web.
`build_apps.py:265` lists all six in `ALL_TARGETS`, so all six are claimed targets today.

---

## 0. R1 execution status (2026-08-24 session 2 close — supplements, does not rewrite, the pre-R1 snapshot in §1)

Rows whose §2 target LANDED this round (tree `main` @ 2f01a6b; suite 272/272, macOS+Android release builds green):
- **F-04/F-06/F-07(+F-09)/F-08/F-10 — DONE**: byte production is pure Dart (`dart_image_loader.dart` + `PhotoSource`); the raw-decode signal is Dart-constructed; non-DNG RAW embedded previews served everywhere; sidebar routed through the producer with decode-time downscale + sized-FFI RAW fallback (P-12) for bare-CFA DNGs. §1's per-platform ❌ for preview/sidebar are obsolete wherever they stemmed from "native bridge missing" — the remaining platform limits are only F-02 (folder-scan core on and/ios) and FFI availability (P-2).
- **F-05 — DONE**: HEIC out of the supported set; preference bug fixed (68308c4).
- **F-11 — DONE**: export decode→resize→encode via `image` pkg; core-tag EXIF carry-over restored, Orientation forced 1 (dd1edcb + 2f01a6b, P-14).
- **F-14 — DONE**: EXIF reads isolate-only everywhere (36dfc37).
- **F-20 — DONE**: oversized guard in Dart, same 1.5 GB budget (d2c4469).
- **Native deletion — DONE**: `halcyon/thumbnail` + `halcyon/exif` gone from macos/windows/lib (ce5a81c, 12a98df, 3a7a2b2, 36dfc37); `halcyon/trash` + `halcyon/open_with` preserved per the declared exceptions.
- **U-12 in effect**: the macOS-only "degraded, never blank" CIRAWFilter fallback is deleted; uniform explicit permanent-miss everywhere.

Not started: F-16/F-17/F-18/F-19/F-24 (P4), F-25 + re-baseline + merge verification (P5). Open: P-2 only.

## 1. Matrix — today

| # | Feature | mac | win | lin | and | ios | web | Where it is decided |
|---|---|:--:|:--:|:--:|:--:|:--:|:--:|---|
| F-01 | Open folder picker | ✅ | ✅ | ✅ | ⚠️ | ❌ | ❌ | `app_state.dart:224` → `file_selector`; iOS has no `getDirectoryPath` override → `UnimplementedError`; web returns null (addendum §1.3) |
| F-02 | Scan folder from disk | ✅ | ✅ | ✅ | ❌ | ❌ | — | `photo_library_scanner.dart:8` `dart:io`; Android has no storage permission declared (addendum §1.4); web has no `dart:io` (§1.5) |
| F-03 | Persist `.halcyon_status.json` + writability probe | ✅ | ✅ | ✅ | ❌ | ❌ | — | `photo_status_store.dart:22`, `:29-38` — mechanism itself is platform-neutral (addendum §3) |
| F-04 | Preview: JPEG / PNG | ✅ | ✅ | ❌ | ❌ | ❌ | — | Passthrough `AppDelegate.swift:358-369` / `halcyon_image.cpp:547-556`; elsewhere `MissingPluginException` → `NativeImageFailure` → no fallback for non-DNG (`photo_source.dart:190-201`, `:364-367`) |
| F-05 | Preview: HEIC | ✅ | ⚠️ | ❌ | ❌ | ❌ | — | In the supported set and *preferred* over RAW (`supported_photo_formats.dart:12`, `:23`, `:47-56`); Windows WIC needs the OS HEIF extension *(unverified)* (addendum §1.8) |
| F-06 | Preview: DNG **with** embedded preview (cheap) | ✅ | ⚠️ | ❌ | ❌ | ❌ | — | macOS Swift extractor `AppDelegate.swift:373` → `DngPreviewExtractor.swift:49`; Windows fails at `halcyon_image.cpp:529-540` but the Dart fallback recovers `.dng` only (addendum §1.7) |
| F-07 | Preview: DNG **without** embedded preview (FFI RAW decode) | ✅ | ❌ | ❌ | ❌ | ❌ | — | Entry is `NativeImageNeedsRawDecode`, whose only producer is macOS `AppDelegate.swift:396` → `native_thumbnail_service.dart:126-129` |
| F-08 | Preview: non-DNG RAW (`.arw .cr2 .nef .orf .rw2`) | ✅ | ❌ | ❌ | ❌ | ❌ | — | macOS CIRAWFilter `AppDelegate.swift:426`, `:433`; Windows blanket `RAW_UNSUPPORTED`; Dart fallback is `.dng`-only (`photo_source.dart:365`) |
| F-09 | Tier-2 full-resolution RAW (M5) | ✅ | ❌ | ❌ | ❌ | ❌ | — | Piggybacks F-07's branch, `photo_source.dart:166-176`, `image_preload_controller.dart:886-903` |
| F-10 | Sidebar thumbnails | ✅ | ✅ | ❌ | ❌ | ❌ | — | `image_preload_controller.dart:1181-1185` calls the **raw loader seam**, bypassing `PhotoSource.load`, so it gets no Dart fallback at all (addendum §1.2) |
| F-11 | Export starred (2048 px JPEG) | ✅ | ⚠️ | ❌ | ❌ | ❌ | — | `thumbnail_export_service.dart:37-40` → `getThumbnail(purpose: export)`; macOS native branch `AppDelegate.swift:330-345`; Windows re-encode path *(uncompiled/untested, `halcyon_image.cpp:3`)* |
| F-12 | Delete → system Trash | ✅ | ✅ | ❌ | ❌ | ❌ | — | `trash_service.dart:11`; `MissingPluginException` → `TrashException` `:15-18` |
| F-13 | Delete → in-folder `.trash/` recycle | ✅ | ✅ | ✅ | ❌ | ❌ | — | `PhotoFileActions` pure Dart (`photo_file_actions.dart:95`); blocked only by F-02 on and/ios |
| F-14 | EXIF batch read (rename feature) | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | Native on macOS `AppDelegate.swift:543`; Dart isolate fallback everywhere `exif_metadata_service.dart:50-51`, `:78-80`; `dart:isolate` absent on web |
| F-15 | Rename + rename log | ✅ | ✅ | ✅ | ❌ | ❌ | — | `rename_service.dart:125`, `:169`; `File.rename` fails cross-volume identically everywhere (addendum §3) |
| F-16 | "Open With" from the OS | ✅ | ✅ | ❌ | ❌ | ❌ | — | macOS `AppDelegate.swift:80-100`; Windows verified end to end (`main.cpp:23-30`, `halcyon_channels.cpp:157-193`, `flutter_window.cpp:45-49`) |
| F-17 | Drag a file onto the window | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ | Windows-only: `flutter_window.cpp:56`, `:104-110`, `:131` (addendum §1.6) — the one *inverse* case |
| F-18 | OS file-type association | ✅ | ❌ | ❌ | ❌ | ❌ | — | `macos/Runner/Info.plist:4-21` only (addendum §1.11) |
| F-19 | Reveal folder in the file manager | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | `status_line.dart:158-161` `Process.run('open', …)`, result discarded — silent dead button elsewhere (addendum §1.1) |
| F-20 | Oversized-image guard | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | `AppDelegate.swift:461` `IMAGE_TOO_LARGE`; no Dart code matches that code, so it degrades to a generic failure (addendum §1.10) |
| F-21 | Hidden-file rule (leading dot) | ✅ | ⚠️ | ✅ | ✅ | ✅ | — | Uniform Dart rule `photo_library_scanner.dart:16`; on Windows the app's own dotfiles are visible in Explorer and `FILE_ATTRIBUTE_HIDDEN` is ignored (addendum §1.14) |
| F-22 | AppleDouble `._name` sidecar handling | ✅ | ⚠️ | ⚠️ | ⚠️ | ⚠️ | — | `photo_file_actions.dart:50-58`, `:76-80`, `:108-111` — uniform code, inert where such files do not exist |
| F-23 | Keyboard shortcuts | ✅ | ✅ | ✅ | — | — | ✅ | `main_screen.dart:88-108`, no modifier keys anywhere → genuinely portable (addendum §3) |
| F-24 | Recycle-mode entry (right-click) | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ | `photo_action_bar.dart:60` `onSecondaryTap` — a desktop-input assumption, not a platform branch |
| F-25 | 768 MiB image cache | ✅ | ✅ | ✅ | ⚠️ | ⚠️ | ⚠️ | `main.dart:25` — uniform code, fatal-sized on mobile |
| F-26 | Unsandboxed arbitrary-path access | ✅ | ✅ | ✅ | ❌ | — | — | `macos/Runner/Release.entitlements` empty dict (addendum §1.12); iOS cannot be unsandboxed |
| F-27 | App compiles at all | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | 15 `lib/` files import `dart:io` with **zero** conditional imports in the tree (addendum §1.5) *(unverified by a build run)* |
| F-28 | Perf driver harness | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | `perf_driver.dart:36-154`, env-var gated; dev-only, not user-facing |

### 1.1 What the matrix says in one line

Only **F-14** (EXIF) and **F-23** (shortcuts) are genuinely uniform today. Everything the app actually does for a photographer — pick a folder, see a picture, delete, export — is macOS(+Windows) only, and *nothing* works end to end on Linux, Android, iOS or web.

---

## 2. Target state — every row converges into unified Dart, is removed, or is a declared platform-set decision

The rewritten contract's rule (see `m6-contract-rewrite.md` §1): **behaviour lives in Dart; native code is permitted only as an output-identical accelerator, and only where every supported platform has one.** Since no accelerator is available on every supported platform, the practical consequence is: **the `halcyon/thumbnail`, `halcyon/trash` and `halcyon/exif` native paths are deleted, not ported.**

> **USER RULING, per item (2026-08-24, second pass — authoritative).** Every row below now carries a `RULED:` verdict transcribed from the user's item-by-item decision. Rows marked **PENDING VERIFICATION** require a Dart/package platform-support check before the verdict finalizes; the research findings come back to the user where the ruling says so. Note the user granted an explicit relaxation for F-17/F-18/F-19: desktop-subset (Windows+macOS, or desktop-only) behaviour is acceptable for those OS-integration features — this is a user-granted exception to strict all-platform parity, limited to exactly those rows.

| # | Feature | Target | How |
|---|---|---|---|
| F-01 | Open folder | **RULED: keep as-is; iOS/web deliberately do not implement this feature** | Keep `file_selector`; no code branch. iOS/web exclusion is by user decision, not pending P-1 |
| F-02/F-03 | Scan + persist | **RULED: keep** | Already pure Dart; availability is a platform-set question, not a code question |
| F-04 | JPEG/PNG preview | **RULED: unified Dart** | `File.readAsBytes` → `EncodedPayload`; Flutter's codec honours EXIF. This is what the macOS "fast path" already does — natively re-implemented for no reason (`AppDelegate.swift:358-369`) |
| F-05 | HEIC | **RULED (final, 2026-08-24 3rd pass): remove HEIC from the supported set NOW; add a HEIC decoder later as a separate follow-up task** | Verification done (`m6-pkg-verification.md` §F-05: no Dart decode path exists, flutter#20522). Removal also fixes the "prefers the file that fails" bug (`supported_photo_formats.dart:47-56`). P-4 resolved |
| F-06 | Cheap DNG | **RULED: unified Dart** — ruling (a) | `DngPreviewExtractor.extractFullSizeEmbeddedJpegFromFile` (`dng_preview_extractor.dart:87`) becomes the primary producer; Swift twin deleted after the gate |
| F-07 | No-preview DNG | **RULED: unified Dart signal + FFI decode** — ruling (b) | Dart constructs the raw-decode signal from an extraction miss + `readOrientation` (`:109`); FFI availability drives P-2 |
| F-08 | Non-DNG RAW | **RULED: unified Dart** (embedded-preview extraction; no full decode) | The walker keys on TIFF magic, not extension (`photo_source.dart:300-301`), so `.arw/.nef/…` embedded previews are reachable in Dart *(hit rate unmeasured)*. Files with no embedded preview become an explicit "unsupported file" state on **every** platform. P-3 resolved by this ruling |
| F-09 | M5 tier-2 | **RULED: same as F-07** | No change to `photo_source.dart:166-176`; it simply becomes reachable everywhere the FFI library exists |
| F-10 | Sidebar thumbnails | **RULED: unified Dart** | Route through `PhotoSource` instead of the raw seam (`image_preload_controller.dart:1181-1185`), then decode with `ui.instantiateImageCodec(targetWidth: 200)` from the same bytes. Deletes the native `sidebarThumbnail` branch on both runners |
| F-11 | Export | **RULED: unified Dart** | Decode → resize → encode. Encoder choice remains the P-5 sub-decision (pure-Dart `image` package vs PNG format change) |
| F-12 | System Trash | **RULED (final, 2026-08-24 3rd pass): keep the existing macOS+Windows native system-Trash channels as a declared exception** | Verification done (`m6-pkg-verification.md` §F-12: no Dart/Flutter trash package exists in the ecosystem). `trash_service.dart:11` and both native handlers stay; `MissingPluginException` → `TrashException` remains the guard elsewhere |
| F-13 | `.trash/` recycle | **RULED (final): keep as-is** — already pure Dart, coexists with the retained system-Trash exception | `photo_file_actions.dart:95` |
| F-14 | EXIF | **RULED: unified Dart** | Delete the macOS channel and its handler (`AppDelegate.swift:67`, `:543`); always take the isolate path (`exif_metadata_service.dart:78-80`) — the fallback is already the reference implementation |
| F-15 | Rename | **RULED: keep** | Already uniform |
| F-16 | Open With | **RULED (final, 2026-08-24 3rd pass): universal support on macOS/Windows/Android/iOS** (Linux excluded by ruling) | macOS+Windows keep the existing native transport; Android/iOS need new intent/document-handler wiring (candidate `open_file_handler` covers Android/iOS/macOS — `m6-pkg-verification.md` §F-16). ⚠ Consistency note: on Android/iOS this only makes sense if P-1 puts them in the supported set — the folder-scan core (F-02) does not work there today |
| F-17 | Drag onto window | **RULED (final, 2026-08-24 3rd pass): unify via `desktop_drop`** (macOS/Windows/Linux), replacing the Windows-only native implementation (`flutter_window.cpp:56`,`:104-110`,`:131`) | Verification done (`m6-pkg-verification.md` §F-17: actively maintained, mac+win+linux) |
| F-18 | File association | **RULED: Windows+macOS support is acceptable** | `macos/Runner/Info.plist:4-21` today; add the Windows-side declaration. Explicit user-granted desktop-pair exception |
| F-19 | Reveal in file manager | **RULED (final, 2026-08-24 3rd pass): implement directly with `Process.run` per-platform commands** — macOS `open -R` (selects file), Windows `explorer /select,` (selects file), Linux `xdg-open` (opens folder only) — and fix the discarded-Future error handling (`status_line.dart:158-161`) | Verification done (`m6-pkg-verification.md` §F-19: url_launcher lacks this, flutter#73317; no package needed). Does NOT affect F-16's OS→Halcyon direction |
| F-20 | Oversized-image guard | **RULED: unified Dart** | Cheap in Dart: the probe already reads dimensions (`dng_preview_extractor.dart:226`) |
| F-21 | Hidden-file rule | **RULED: keep as the uniform rule, documented** | `name.startsWith('.')` is one behaviour on every platform; honouring `FILE_ATTRIBUTE_HIDDEN` would *introduce* a platform branch — explicitly rejected |
| F-22 | AppleDouble sidecars | **RULED: keep** | Uniform code, data-dependent effect; removing it would break macOS-written volumes read on Windows |
| F-23 | Shortcuts | **RULED: keep** | Already uniform |
| F-24 | Right-click recycle | **RULED: add a non-pointer route** | `photo_action_bar.dart:60` gains an alternative entry (e.g. keyboard/menu), regardless of the platform set |
| F-25 | 768 MiB cache | **RULED: unified Dart** (measured constant, never a platform branch) | `main.dart:25`; derive the budget from available memory in Dart — never `Platform.isAndroid` |
| F-26 | Unsandboxed access | **RULED: platform-set decision** (P-1 stays open) | iOS cannot satisfy the architecture (addendum §1.12) |
| F-27 | Compiles for web | **RULED: platform-set decision** (P-1 stays open) | Either drop web from `build_apps.py:265`'s `ALL_TARGETS` or accept conditional-import work across 15 files |
| F-28 | Perf driver | **RULED: keep** | Dev harness, not user-facing |

---

## 3. Platform-set and scope decisions this matrix forces (user only)

| # | Decision | Status after the 2026-08-24 per-item ruling |
|---|---|---|
| P-1 | **What is the supported platform set?** | **RESOLVED (2026-08-24 4th pass): per-feature preference cascade** — 1st choice: all platforms; 2nd: macOS+Windows+Linux+Android; 3rd: macOS+Windows+Linux; minimum: macOS+Windows. Each feature lands on the WIDEST tier it can actually support; structural blockers (F-26 iOS sandbox, F-27 web compile) demote that platform for the affected feature rather than excluding it globally |
| P-2 | RAW decode needs the FFI library, which ships for macos/android/windows only (`dng_processor_ffi/pubspec.yaml`). If Linux is to serve RAW decode, its `.so` must be built — the C++ path exists but has never been built for Linux | **OPEN** — under the P-1 cascade, F-07/F-09 currently land on macOS+Windows+Android tier; Linux `.so` build is the outstanding item |
| P-3 | Non-DNG RAW without an embedded preview becomes "unsupported" everywhere (F-08) | **RESOLVED** — F-08 ruled unified Dart; the capability reduction is accepted |
| P-4 | HEIC stays or goes (F-05) | **RESOLVED (2026-08-24 3rd pass)** — remove now, HEIC decoder added later as separate follow-up |
| P-5 | Export: add the pure-Dart `image` package, or change the export format to PNG (F-11) | **RESOLVED (2026-08-24 4th pass)** — adopt the pure-Dart `image` package (JPEG export kept); a HEIC-capable package may also be adopted if one exists (per `m6-pkg-verification.md` §F-05 none is pure-Dart today — ties to the F-05 follow-up) |
| P-6 | Open With / drag-drop / file association (F-16, F-17, F-18) | **RESOLVED (2026-08-24 3rd pass)** — F-16 universal on macOS/Windows/Android/iOS (native transport + mobile handler wiring); F-17 `desktop_drop`; F-18 Windows+macOS declarations |
| P-7 | Reveal-in-file-manager (F-19) | **RESOLVED (2026-08-24 3rd pass)** — direct `Process.run` per-platform commands, no package; fix discarded-Future handling |
| P-8 | Performance gate-failure policy | **RESOLVED (2026-08-24 4th pass): Swift-accelerator retention REJECTED.** User rationale: cheap-DNG display is embedded-JPEG extraction, and the pure-Dart walker already serves it on Windows today, so Dart is expected to match. Gate G1 still runs before any native deletion; on FAIL → optimise and re-gate — never keep the Swift path |
| P-9 | G1 measured (2026-08-24): same-isolate Dart extraction PASS; per-call `Isolate.run` variant FAIL by one sample (2.111×). Frozen cascade selects the same-isolate variant; the synchronous-read UI-jank question escalates to the user (agents may not measure UI) | **RESOLVED (2026-08-24 5th pass, user): synchronous read ACCEPTED** — sub-1.2 ms per extraction; ship the same-isolate variant, no resident-isolate rework |
| P-10 | G2 measured (2026-08-24): JPEG `File.readAsBytes` bytes/dims identical to native passthrough but 2.3–9.2× slower, worst absolute 0.51 ms vs 0.14 ms — latency clause FAIL at sub-millisecond scale; whether it matters is a product judgement | **RESOLVED (2026-08-24 5th pass, user): sub-millisecond gap ACCEPTED** — Dart read path ships as-is; the G2 latency clause no longer blocks native deletion; no re-gate required for this path |
| P-11 | G3 measured (2026-08-24): HARD FAIL attributed to instrument route error (full-size entry point instead of the 200 px smallest-candidate entry point); JPEG half additionally 16× slower via decode-then-downscale | **RESOLVED (2026-08-24 5th pass, user): adopt the decode-time downscale API** (`instantiateImageCodecWithSize` long-edge cap, plan P2.5) + the 200 px extraction entry point (plan P2.1); re-gate on the corrected route (plan P2.6) remains the gate for native deletion |
| P-14 | P3 round review found export JPEGs carry ZERO EXIF after the F-11 Dart cutover (deleted native branch copied all source EXIF with Orientation forced 1; the Dart path never reattached it) — unrecorded capability loss surfaced per discipline | **RESOLVED (2026-08-24 8th pass, user): RESTORE EXIF carry-over** — fixed in 2f01a6b via pkg:exif core-tag copy (Make/Model/DateTime/Artist/DateTimeOriginal/Exposure/FNumber/Focal/Lens/ISO/GPS), Orientation forced 1. Coverage is CORE TAGS, not maker notes — the `image` package strips Orientation at decode and `copyResize` drops exif (both worked around); doc contract reworded to "core EXIF" honestly. Verified red-first + independent-oracle Orientation check; suite 272/272 |
| P-13 | G3″/G3‴ (2026-08-24, instrument-corrected, production dylib, sized path proven by dims marker): null clause clears 13/13, dims native-exact; latency 55.6–100.2 ms vs native 33–39 ms (7/13 over the 2.0× ratio clause) | **RESOLVED (2026-08-24 7th pass, user): gate PASSED by ruling.** New standing latency criterion superseding the bare 2.0× ratio for decode gates: **any per-sample decode under 75 ms passes outright regardless of ratio**; the measured over-75 ms samples (worst 100.2 ms, background sweep, once per file then cached) are explicitly accepted in the same ruling — no re-measurement. The JPEG sidebar latency item (~25 ms absolute) is CLOSED by the same ruling and leaves the optimise-and-re-gate loop. Native deletion (P3) is UNBLOCKED |
| P-12 | G3′ re-gate (2026-08-24, corrected route): the 13 samples are CONFIRMED bare-CFA DNGs with NO embedded JPEG at any size — a real capability gap, not instrument error (Phase-1 diagnosis falsified by direct probe). macOS native serves them via its own RAW decode; the Dart sidebar route never decodes by design. Embedded-candidate DNGs now PASS 50–100× faster; portrait dims fixed | **RESOLVED (2026-08-24 6th pass, user): option B — sidebar gets a RAW-decode fallback** via the FFI sized-decode entry (`decodeOnWorker(maxDim:)`; the vendored dylib exports `dng_decode_and_process_sized` — verified by `nm`, the bindings comment claiming otherwise is stale). Lands on the FFI platform tier (macOS/Windows/Android) per the P-1 cascade; no-FFI platforms keep the uniform explicit miss. Plan task P2.5b; G3″ re-gate follows. JPEG latency clause (22× at ~25 ms absolute) stays under the standing optimise-and-re-gate loop |

---

## 4. Uncertainties

- No build or test was run for this document; F-27 in particular is an import-graph inference (addendum §1.5, §4.1).
- F-05's Windows HEIF behaviour and the whole Windows native side are unverified — the runner files are self-labelled `UNCOMPILED AND UNTESTED` (`halcyon_image.cpp:3`).
- F-08's Dart embedded-preview hit rate on `.arw/.cr2/.nef/.orf/.rw2` is unmeasured; the "unified Dart" verdict assumes only the extraction path, never a full non-DNG RAW decode.
- Android's `file_selector` tree-URI path may throw before storage permissions even matter (addendum §4.3).
