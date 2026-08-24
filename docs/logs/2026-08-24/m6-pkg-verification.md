# M6 package verification — F-05, F-12/13, F-16, F-17, F-19

> Team `m6-redef-team`, task #6. Researched against Halcyon's `sdk: ^3.9.0` constraint (pubspec.yaml). No code/pubspec changes made. Sources are pub.dev pages, GitHub, and search-engine synthesis (no local `pub get`/build run — treat platform badges as pub.dev-published claims, not locally verified).

---

## F-05 — HEIC decode

**Question**: can Flutter's built-in codec (`ui.instantiateImageCodec`) decode HEIC uniformly, or is there a package that unifies HEIC→RGBA/JPEG across macOS/Windows/Linux/Android/iOS?

**Finding: NOT unifiable. Flutter's built-in codec has never supported HEIC** — open since 2018, `flutter/flutter#20522`, unresolved. `instantiateImageCodec` calls into Skia/Impeller which has no HEIC decoder; this is a longstanding, unfixed gap, not a config issue.

Package survey:

| Package | mac | win | lin | and | ios | Notes |
|---|:--:|:--:|:--:|:--:|:--:|---|
| `flutter_image_compress` | ❌ (encode-only, no decode) | ❌ | ❌ | ⚠️ encode only, API28+ w/ hw encoder | ✅ encode via ImageIO | Its own docs: "Decoding supports JPEG, PNG, GIF, RAW, WebP, BMP, SVG" — **HEIC is not in the decode list at all**, on any platform. Encoding is API28+/iOS11+ only, explicitly "Not on macOS" for encode either. |
| `heic_to_png_jpg` | ⚠️ | ⚠️ | ⚠️ | ✅ | ✅ | Its own README: desktop path "uses the Dart `image` package fallback (HEIC support may be limited)" — i.e. self-admits desktop HEIC is not solid. |
| `heif_converter` | — | — | — | ✅ | ✅ | Mobile-only wrapper (Android/iOS native HEIF SDKs), no desktop story found. |
| pure-Dart `image` package | — | — | — | — | — | No HEIC codec in the pure-Dart `image` package (HEIC is a licensed/complex container format; no pure-Dart decoder exists in the ecosystem). |

**Verdict: none viable.** There is no package (pure-Dart or platform-wrapping) that gives HEIC decode parity across all five platforms today. Every candidate either (a) doesn't decode HEIC at all, (b) only encodes on mobile, or (c) self-reports desktop support as unreliable/fallback-only.

**Recommendation for the user's P-4 decision**: HEIC cannot be "unified in Dart and treated exactly like JPG." Realistic options are:
1. Drop HEIC support entirely (simplest, matches "unified Dart or removed" rule).
2. Keep HEIC macOS/iOS-only via the existing native `CGImageSource` passthrough (already working per matrix F-05 row) and treat it as a declared platform-set exception like F-17/F-18/F-19 — but the user's ruling for F-05 didn't grant that relaxation the way it did for F-16/F-17/F-19, so this needs an explicit user call.
3. FFI-bind `libheif` (C library, ships on all target OSes via system packages/vendoring) for a truly unified decode — much larger engineering lift, out of scope for a package swap.

UNVERIFIED: whether `libheif` FFI is a realistic scope fit — not researched in depth (would need its own investigation if the user picks option 3).

---

## F-12/F-13 — System Trash

**Question**: is there a Dart/Flutter package that moves files to OS trash/recycle-bin on macOS/Windows/Linux (freedesktop trash spec on Linux)?

**Finding: no viable package exists.** Searched pub.dev directly (`pub.dev/packages?q=trash`) and via search engine for likely names (`trash`, `recycle_bin`, `system_trash`, `trashman`, `send2trash`-equivalent). Results:
- No package analogous to Python's `send2trash` or Node's `trash` (which wrap native trash APIs: macOS `FSMoveObjectToTrashSync`, Windows `IFileOperation`, Linux freedesktop trash spec) exists in the Flutter/Dart package ecosystem.
- `flutter_cache_cleaner` has a `--trash` CLI flag but it's a **dev-tooling CLI**, not an importable library callable from app code.
- `photo_manager` has trash-adjacent methods but is scoped to Android/iOS/macOS **photo library assets** (`PHAsset`/`MediaStore`), not arbitrary filesystem paths — wrong abstraction for Halcyon's file-based model, and no Windows/Linux support anyway.

**Verdict: none viable — report back to user per the matrix's explicit instruction** (do NOT default to removal).

**Options for the user**:
1. Keep the existing native `MethodChannel` implementations (macOS `TrashService` already works; Windows already works per current matrix row F-12 = ✅/✅). This contradicts the "native only as output-identical accelerator available on every platform" rule, but no package can replace it — the alternative is writing new native code (Win32 `IFileOperation`, GTK/GIO or manual freedesktop trash-spec writer for Linux) which is a from-scratch native-code project, not a package integration, and out of scope for this research task.
2. Drop system Trash entirely and rely solely on F-13's in-folder `.trash/` recycle mode (already pure Dart, already works on macOS/Windows/Linux per the matrix).

F-13 (`.trash/` recycle) itself needs no package — it's `dart:io` file moves, already uniform. No platform-specific filesystem surprises found in research (Linux/Windows both support directory-based move-and-rename the same way `photo_file_actions.dart` already uses).

---

## F-16 — "Open With" (OS hands the app a file path)

**Question**: standard Flutter mechanism per desktop platform; does any package cover macOS AND Windows AND Linux desktop file-open events?

**Finding: no cross-desktop package. Closest candidate is desktop-partial and worse than what Halcyon already has.**

| Package | mac | win | lin | and | ios | Notes |
|---|:--:|:--:|:--:|:--:|:--:|---|
| `open_file_handler` | ✅ | ❌ | ❌ | ✅ | ✅ | pub.dev page confirms platform badges: Android/iOS/macOS only. v1.0.0, published ~2 months ago (low sample size, small package). README explicitly scopes to "Open with app" cold/warm start, but **no Windows/Linux support at all**. |
| `app_links` | partial (custom URL schemes) | ❌ desktop file-open | ❌ | ✅ | ✅ | Designed for deep-links (URI schemes), not raw file-path launch args; Flutter's own desktop runners (`windows/`, `linux/`) receive file-open args through the native entrypoint (`main.cpp`/GTK `open` signal), which is exactly what Halcyon's existing custom C++ channel already does — `app_links` doesn't add anything beyond what's already implemented. |
| `receive_sharing_intent` / `uni_links` | — | — | — | ✅ | ✅ | Mobile share-sheet intents only; irrelevant to desktop file-open-with. |

**Verdict: no package unifies this — report back to user.** Halcyon's current state is actually *ahead* of what any package offers: working native push-only channel on macOS (`AppDelegate.swift:80-100`) and a verified end-to-end Windows implementation (`main.cpp`/`halcyon_channels.cpp`/`flutter_window.cpp`). No package would replace this without a net capability loss (Linux still uncovered either way).

**Options for the user**:
1. Keep the existing native transport (already macOS+Windows) as a declared exception — same class of decision as F-18's user-granted desktop-pair exception. This is the pragmatic choice since no package does better.
2. Add a hand-written Linux desktop entrypoint hook (GTK `application_open` signal in `linux/my_application.cc`) to reach Linux — native code work, not a package swap, out of scope here but flagged as the only path to Linux parity.

---

## F-17 — Drag file onto window

**Question**: `desktop_drop` exact platform coverage, maintenance status, known limitations.

**Finding: `desktop_drop` covers macOS + Windows + Linux (+ Android preview + Web); actively maintained.**

- Platform badges on pub.dev: **Android, Linux, macOS, Web, Windows** (iOS absent — expected, iOS has no drag-and-drop-onto-window concept).
- Latest version 0.6.1 stable line (0.8.0-dev noted in one fetch — check exact version at integration time), published within days of this research (active cadence).
- Changelog shows continuous platform-specific fixes: macOS multi-source drag support (public.file-url / NSFilePromiseReceiver fallback, directory support via `DropItemDirectory`, security-scoped bookmarks, macOS min bumped to 10.13), Linux fixes for non-ASCII paths and Wayland functionality, a past breaking API change (`urls: List<Uri>` → `files: List<XFile>`).
- Alternative `super_drag_and_drop` exists (iOS/macOS/Windows, virtual-file support) but self-describes as "very early stage, experimental" — not a safer choice than `desktop_drop`.

**Verdict: unifiable on desktop (macOS + Windows + Linux).** This exceeds the matrix's Windows-only baseline (today only `flutter_window.cpp` implements it) and the user's stated bar ("desktop-only availability is acceptable; if even macOS cannot be covered, remove") is comfortably met — macOS *is* covered, well.

**Recommendation**: adopt `desktop_drop`, replacing the Windows-only native implementation. Pin the exact version and re-check its Wayland/Linux caveats during integration (Wayland fixes are recent per changelog — worth a smoke test on whichever Linux desktop environment the user's build targets).

---

## F-19 — Reveal in file manager

**Question**: can `url_launcher` open a directory in Finder/Explorer/`xdg-open` portably? Alternatives (`open_file`, `open_filex`)? Distinguish "select/highlight file" vs "open folder."

**Finding: no single package. `url_launcher` explicitly does NOT support this** — confirmed by an open `flutter/flutter` GitHub issue (#73317) asking for exactly this capability, unresolved, meaning it's a known gap not a documentation oversight.

| Package | Capability | mac | win | lin | Notes |
|---|---|:--:|:--:|:--:|---|
| `url_launcher` | folder/file reveal | ❌ | ❌ | ❌ | No native directory-reveal support; issue #73317 open, unaddressed. |
| `open_file` / `open_filex` | open file with default app | partial | partial | partial | These **open** a file with its associated app (e.g. opens the JPEG in Preview/Photos) — not the same as revealing/selecting it in the file manager. Wrong semantics for "reveal in Finder." |
| `open_file_macos` | **select/highlight in Finder** | ✅ | — | — | macOS-only; API explicitly supports `viewInFinder: true` to highlight the exact file, which is the "select" semantic Halcyon currently uses (`status_line.dart:158-161` → `Process.run('open', …)`, currently folder-open not select). |
| — (no package) | Windows reveal | — | manual | — | Standard idiom is `Process.run('explorer.exe', ['/select,$path'])` — a raw process call, not a package; this is a **less capable but equivalent-effort replacement** for what a native channel would do (i.e., no advantage over the status quo except being process-spawn instead of a MethodChannel). |
| — (no package) | Linux reveal | — | — | manual | `xdg-open` opens the **folder**, not select-in-manager (most Linux file managers have no standardized "select file" CLI verb — DBus `org.freedesktop.FileManager1.ShowItems` exists on GNOME/Nautilus/Nemo but isn't portable across all DEs). |

**Verdict: no unifying package. Best achievable is per-platform `Process.run` calls (already effectively what Halcyon's macOS code does today via `open`), not a package integration.**
- macOS: `open_file_macos` gives clean select-in-Finder semantics, or keep the existing `Process.run('open', [path])` (folder-open, not select) with proper error handling (today's bug is the discarded Future, not the mechanism).
- Windows: `Process.run('explorer.exe', ['/select,$path'])` gives select-in-Explorer semantics — no package needed, pure `dart:io`.
- Linux: only folder-open (`Process.run('xdg-open', [folderPath])`) is portably achievable; file-select requires DBus calls that aren't universal across desktop environments.

**Recommendation for the user's P-7 decision**: this is achievable in pure Dart (`dart:io Process.run`) on macOS + Windows without any package (matches the "second choice: keep on Windows/macOS desktop" ruling comfortably, and can extend to Linux folder-open, just not file-select on Linux). No package adds value over direct `Process.run` calls here — recommend skipping package adoption and just fixing the existing `Process.run` call's discarded-Future bug plus adding the Windows/Linux branches directly.

---

## Summary table

| Item | Verdict | Recommended package | Platform coverage |
|---|---|---|---|
| F-05 HEIC | none viable | — | Flutter codec: 0 platforms. All packages checked fail decode on ≥3 of 5 platforms. |
| F-12/13 Trash | none viable | — | No trash package exists in the Dart ecosystem at all. |
| F-16 Open With | none viable | — | Best candidate (`open_file_handler`) is mac+ios+android only, no desktop-file-launch improvement over existing native code. |
| F-17 Drag-drop | **unifiable (desktop)** | `desktop_drop` | mac ✅ win ✅ lin ✅ (android preview, web ✅, ios n/a) |
| F-19 Reveal | achievable, no package needed | — (`dart:io Process.run`) | mac ✅ (select) win ✅ (select) lin ⚠️ (folder-open only) |

UNVERIFIED items: exact `desktop_drop` version pin and Wayland smoke-test (changelog claims fixed, not independently run); `libheif` FFI feasibility for F-05 option 3; DBus `ShowItems` portability across non-GNOME Linux DEs for F-19.
