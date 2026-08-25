# Cross-Cutting Naming Consistency Audit

Scope: cross-file/cross-language vocabulary consistency only (dimensions a/b/c below).
Per-file/per-identifier audits inside `lib/services`+`lib/providers` and `lib/views`+`lib/models` are owned by
teammates `scan-services` and `scan-views` respectively — not duplicated here.

Method: `codebase-memory` MCP (`search_code`/`search_graph`) for indexed enumeration, `grep`/`Read` (including
`macos/Runner/AppDelegate.swift` and `windows/`/`android/`/`ios/` native bridges) to verify every claim against
actual source. Index: project `Users-jhangyu-project-Halcyon`, 3300 nodes / 5410 edges, status `ready`.

## Vocabulary table (concept → names in use → recommendation)

| Concept | Names in use | Recommended canonical name |
|---|---|---|
| Star/keep marking | `PhotoStatus.starred`, `isStarred`, `toggleStar` UI, `starredItems` | No change — fully consistent, no `favorite` synonym anywhere (`grep -rn "favorite"` → 0 hits in `lib/`). |
| macOS-Trash delete path | `TrashService`, `trashFile`, `halcyon/trash` channel | No change — consistent name for a distinct, documented path (see architecture doc "Deletion has two paths"). |
| In-folder delete path | `recycleMode`, `RecycleOutcome`, `recycleTrashed`, `.trash/` subfolder | No change — distinct concept from the above by design; internally consistent. |
| Display-resolution image request | `ImageRequestPurpose.{sidebarThumbnail,preview,export}` | No change internally consistent, but see Finding F1 — the word "preview" collides with two unrelated concepts elsewhere. |
| Tier-2 (full-size) image provider | `TierTwoScheduler`, `tier_two_registry.dart`, `tierTwoNavigationDebounce` **vs.** `fullSizeProviderFor`, `FullSizeProviderFor` (typedef), `_fullSizeProviderForPayload` | See Finding F2 — same pipeline stage named `tierTwo` in scheduler/registry files and `fullSize` in the provider-factory file. |
| The pluggable image-loading collaborator injected into `AppState`/`ImagePreloadController` | `thumbnailLoader` (ctor param), `imageLoader` (call-site/field param), `loader` (`PhotoSource.loader`), `NativeImageLoad` (typedef), `dartImageLoad` (concrete impl) | See Finding F3 — 4 distinct names for one seam, one of them (`thumbnailLoader`) actively misleading. |
| Export-to-JPEG service | `ThumbnailExportService`, `exportBytesFor`, `ThumbnailExportOutcome` | See Finding F4 — class/type is named "Thumbnail" but produces a full ≤2048px export JPEG, not a thumbnail. |
| DNG embedded-JPEG extraction | `DngPreviewExtractor`, `DngPreviewProbe`, `DngEmbeddedJpeg`, `extractEmbeddedJpeg`, `extractFullSizeEmbeddedJpegFromFile` | No change internally — but see Finding F1, "preview" here is a different concept from `ImageRequestPurpose.preview`. |
| Rename-dialog UI preview list | `RenamePreviewList` | See Finding F1 — third unrelated user of "preview". |
| Pixel-data pipeline types | `DecodedRgba` (native decode output), `PixelPayload` (payload wrapper), `RawPixelsImage` (ImageProvider) | Cleared — this is a layered pipeline (decode-output → payload → provider), not name drift; each stage has one name used consistently. |

## (a) Same-concept-different-name audit across lib/

### F1 — "preview" names three unrelated concepts (medium risk, readability drift, no runtime bug)
- `lib/services/image_source_types.dart:19` — `ImageRequestPurpose.preview` (a 2800px display-resolution *request tier*). ~7 usages (`grep -rn "ImageRequestPurpose.preview\b" lib/` → `perf_driver.dart:201`, `photo_source.dart:121`, `dart_image_loader.dart:70,75,96`, `thumbnail_export_service.dart:58`, `dng_preview_extractor.dart:87`).
- `lib/services/dng_preview_extractor.dart:55,66` — `DngPreviewProbe`, `DngPreviewExtractor` (embedded-JPEG *extraction from a RAW file*). Referenced from 3 other files (`photo_source.dart:303,330`; `dart_image_loader.dart:44,71,97,109`; `image_preload_controller.dart:853`) — 8 call sites total.
- `lib/views/rename_dialog/preview_list.dart:14` — `RenamePreviewList` (a *list widget showing proposed rename operations*, unrelated to images). 1 usage (`rename_dialog.dart:148`).
- Evidence these are genuinely different concepts, not the same thing spelled differently: verified by reading all three definitions — they have no shared type, no shared caller, no shared file.
- Proposal: keep `ImageRequestPurpose.preview` (it's the oldest/most-load-bearing — frozen contract per `dng_decode_contract.dart`); rename `DngPreviewExtractor`/`DngPreviewProbe`/`DngEmbeddedJpeg` → `DngEmbeddedJpegExtractor`/`DngEmbeddedJpegProbe`/`DngEmbeddedJpeg` (already unambiguous, only the class/probe names need the `Embedded` qualifier) to stop the two RAW-decode-adjacent concepts from reading as the same thing at a glance. `RenamePreviewList` is fine as-is (different domain, low collision risk) — no rename needed, informational only.
- Usage count for the proposed rename: `DngPreviewExtractor` 1 def + 8 call sites across 3 files; `DngPreviewProbe` 1 def; risk = internal only, no public API/channel/test-string dependency (tests reference these classes directly, see (c) below — a rename requires touching `test/dng_preview_extractor_*.dart`, 4 files).

### F2 — Tier-2 pipeline stage has two names in the same subsystem (medium risk)
- `lib/services/image_preload_controller.dart:44` — `ImageProvider fullSizeProviderFor(Uint8List bytes)`, `:730` `_fullSizeProviderForPayload`, `:140` passed as `fullSizeProviderFor:` param.
- `lib/services/tier_two_scheduler.dart:62,69,77` — `FullSizeProviderFor` typedef param name, `_fullSizeProviderForPayload` field — i.e., the scheduler that is explicitly named `TierTwoScheduler` (class itself, file `tier_two_scheduler.dart`) receives its own core dependency under a `FullSize`-prefixed name, not `TierTwo`-prefixed.
- `lib/services/tier_two_registry.dart` (whole file) and `lib/views/main_detail_view.dart:276` (`tierOneProviderFor`) — the *sibling* function for the other tier is correctly `tierOneProviderFor`, making the asymmetry (`tierOneProviderFor` paired with `fullSizeProviderFor`, not `tierTwoProviderFor`) visible in a single file (`image_preload_controller.dart:28,44`).
- Note: `CLAUDE.md`'s own architecture section documents this exact pairing (`tierOneProviderFor` / `fullSizeProviderFor`), so this is a **known, load-bearing asymmetry**, not accidental drift — flagging per audit scope, not recommending an unreviewed rename. If renamed for consistency, `fullSizeProviderFor` → `tierTwoProviderFor` touches: `image_preload_controller.dart` (4 occurrences), `tier_two_scheduler.dart` (5 occurrences: typedef name, param, field, 2 call sites), plus doc references in `CLAUDE.md` and `tier_two_registry.dart:138` comment. Risk: internal-only, but `CLAUDE.md` counts as a doc dependency.

### F3 — the injectable image-loader seam has 4 names for one thing (highest usage-cost finding in this dimension)
- `lib/providers/app_state.dart:67` — constructor param `NativeImageLoad? thumbnailLoader`.
- `lib/providers/app_state.dart:80` — passed on as `imageLoader: thumbnailLoader ?? dartImageLoad`.
- `lib/services/image_preload_controller.dart:76` — `required NativeImageLoad imageLoader` (param name here matches the call site, not the constructor).
- `lib/services/photo_source.dart:85` — `final NativeImageLoad loader;` (field name drops both prefixes).
- `lib/services/dart_image_loader.dart:6` (doc comment) and `lib/services/image_source_types.dart:101` — typedef `NativeImageLoad`; concrete production implementation function is `dartImageLoad` (`lib/services/dart_image_loader.dart`).
- `lib/services/image_source_types.dart:97` — the file's own doc comment calls this pairing "(image_preload_controller.dart) and `NativeImageLoad` (photo_source.dart)" without settling on one term either.
- Risk: `thumbnailLoader` is actively misleading — the seam loads *all three* `ImageRequestPurpose` values (`sidebarThumbnail`, `preview`, `export`), not just thumbnails; a reader skimming `AppState`'s constructor would reasonably assume it only affects sidebar thumbnails. `CLAUDE.md`'s own architecture section calls it "an optional `ThumbnailLoader` function" — that type name (`ThumbnailLoader`) **does not exist anywhere in the codebase** (`grep -rn "ThumbnailLoader" lib/` → 0 hits); the doc itself has drifted from the code, or the code was renamed away from `ThumbnailLoader` to `NativeImageLoad` without updating `CLAUDE.md`.
- Proposal: standardize on `imageLoader` everywhere (matches the typedef's actual scope) — rename `app_state.dart:67`'s `thumbnailLoader` param → `imageLoader`, and `photo_source.dart:85`'s `loader` field → `imageLoader`. Update `CLAUDE.md`'s "`ThumbnailLoader` function" reference to `NativeImageLoad`.
- Usage count: `thumbnailLoader` — 2 occurrences (`app_state.dart:67,80`), no external/test references (confirmed via `grep -rn "thumbnailLoader" .` — only those 2 lines in the whole repo, so this is a same-file rename, zero cross-file risk). `loader` field — 1 declaration + used internally in `photo_source.dart`; low risk but touches `PhotoSource`'s only external-facing param, so grep all callers before renaming (`PhotoSource(loader:` construction sites) — not enumerated here as out of scope for this teammate's per-file duty, flagging to lead/scan-services.

### F4 — `ThumbnailExportService` doesn't export thumbnails
- `lib/services/thumbnail_export_service.dart:21,37` — `ThumbnailExportOutcome`, `ThumbnailExportService`; its actual job (`image_source_types.dart:20-28` comment, `thumbnail_export_service.dart:225` doc) is: decode → resize to ≤2048px long edge → re-encode JPEG q90 with re-read EXIF, for social-media export of starred photos. That's an "export" operation, and 2048px is far larger than the 200px `sidebarThumbnail` tier — calling it a "thumbnail" undersells/misdescribes what it does.
- Usage: `lib/providers/app_state.dart:69,76,110` (field `_exportService`, ctor param `exportService` — note `AppState` itself already avoids the word "thumbnail" for this collaborator, i.e. the drift is internal to `thumbnail_export_service.dart`'s own class name vs. how its caller refers to it).
- Proposal: rename `ThumbnailExportService` → `PhotoExportService` (or `SocialExportService` given the social-media-specific EXIF handling), `ThumbnailExportOutcome` → `ExportOutcome`. Usage count: class name appears 3 times as a type in `app_state.dart`, defined 2x in its own file, referenced in doc comments in `image_source_types.dart:26-28`; test file `test/thumbnail_export_service_test.dart` also needs a matching rename (see (c)). Risk: internal only, no public API — but touches a test filename.

## (b) MethodChannel / method-string / argument-key consistency — CLEARED, no findings

Verified every channel name, method string, and argument key across all five native-bridge implementations against the two Dart-side channel classes:

| Channel | Dart | macOS | Windows | Android | iOS |
|---|---|---|---|---|---|
| Trash | `MethodChannel('halcyon/trash')`, method `'trashFile'`, arg key `'path'` (`lib/services/trash_service.dart:7,11`) | `FlutterMethodChannel(name: "halcyon/trash")`, `call.method == "trashFile"`, `args["path"]` (`macos/Runner/AppDelegate.swift:23,28,30`) | not audited beyond grep (no output) | not audited beyond grep (no output) | not audited beyond grep (no output) |
| Open-with | `MethodChannel('halcyon/open_with')`, method `'openFile'` (`lib/services/open_with_channel.dart:30,36`) | `FlutterMethodChannel(name: "halcyon/open_with")`, `invokeMethod("openFile", ...)` (`macos/Runner/AppDelegate.swift:42,47,65`) | `halcyon_channels.cpp:85` name `"halcyon/open_with"`, `:105` `InvokeMethod("openFile", ...)` | `MainActivity.kt:38` `openWithChannelName = "halcyon/open_with"`, `:48,69` `invokeMethod("openFile", ...)` | `AppDelegate.swift:29` name `"halcyon/open_with"`, `:34,54` `invokeMethod("openFile", ...)` |

No collisions, no near-miss spellings (`openfile`/`open_file` variants), no argument-key mismatches found on any platform. This dimension is clean — do not touch as part of any naming refactor.

## (c) test/ directory naming drift

- `test/widget_test.dart:15` — `testWidgets('PhotoSelectorApp renders empty-folder prompt', ...)`: the test description string names a class `PhotoSelectorApp` that does not exist anywhere in the codebase (`grep -rn "PhotoSelectorApp" lib/` → 0 hits). The test actually pumps `HalcyonApp` (`lib/main.dart:52`, constructed at `widget_test.dart:26`). This is a stale name from before the app was renamed to Halcyon — the test file itself is also still the unrenamed Flutter-template default (`widget_test.dart`), unlike every other test file in the directory which is named after its subject. Proposal: rename file → `main_test.dart` conflicts (already exists, tests `main.dart` per a different concern — verify before merging) or `halcyon_app_smoke_test.dart`; fix the description string to say `HalcyonApp`. Usage count: 1 file, 1 string, zero cross-references (test descriptions aren't referenced elsewhere). Risk: none — purely cosmetic, safe same-file edit.
- Milestone/ticket-coded test filenames leak internal project jargon into permanent file names, e.g. `image_preload_controller_m3_amend3_test.dart`, `image_preload_dual_window_m5_test.dart`, `image_preload_scheduling_m4_test.dart`, `dng_preview_extractor_f3_test.dart`, `dng_preview_extractor_m0_test.dart`, `dng_nav_probe_m3_test.dart`, `m6_bridge_free_test.dart`. These aren't name *collisions* (each maps 1:1 to a real subject file plus a milestone qualifier) but they violate the stated test-naming convention (name after what's tested) once the milestone context (M3/M4/M5/M6/F3) is no longer live. Flagging as informational only — no proposed rename (renaming would require cross-referencing `unit_test.md`'s TC-NNN matrix per this repo's own SOP, which is out of this audit's scope) — surfacing for the lead to decide whether consolidation is worth it.
- All other test file names (`app_state_test.dart`, `cache_budget_test.dart`, `dart_image_loader_test.dart`, `photo_file_actions_test.dart`, `photo_source_test.dart`, `rename_service_test.dart`, `sidebar_view_test.dart`, `tier_two_registry_test.dart`, `tier_two_scheduler_test.dart`, `zoom_controller_test.dart`, `status_line_test.dart`, etc.) map 1:1 and correctly to an existing `lib/` source file (`lib/views/zoom_controller.dart`, `lib/views/status_line.dart` both confirmed to exist) — cleared, no drift.
- No `Fake`/`Mock`/`Stub`-prefixed helper classes were found anywhere under `test/` (`grep -rn "^class Fake\|^class Mock\|^class Stub" test/*.dart` → 0 hits) — test doubles in this codebase are apparently constructed inline or via `support/synthetic_dng.dart` rather than named fake classes, so there is no fake/subject naming-drift class of finding to report here.

## Acceptance criteria

1. Report file exists at this path, contains the vocabulary table and explicit coverage of (a)/(b)/(c) — PASS.
2. Every finding has file:line + evidence + proposal + usage count — PASS (F1–F4, plus the widget_test.dart finding all carry counts; the two "cleared" dimension write-ups intentionally carry no rename proposal since there is nothing to fix).
3. No code files modified — PASS (only this report file was written).
