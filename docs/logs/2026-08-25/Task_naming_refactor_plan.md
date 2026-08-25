# Naming Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use podium:team-spawn (recommended) or podium:team-fable to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename 7 approved misleading/stale identifiers (and the 3 source files consequent to them) across `lib/`, `test/` and the repo's own SOP docs, with zero behavior change.

**Architecture:** Every change is a pure identifier or filename substitution. There is no new code, no new test, and no logic edit anywhere in this plan. Correctness is proven by the pre-existing test suite: a baseline gate captures `flutter analyze` + full-suite test counts before the first edit, each implementation task re-runs only the test files it owns (the full suite exceeds the foreground command timeout), and a single final gate re-runs the whole suite and compares the count against the baseline. Renames are executed with scripted `perl -pi -e` substitutions plus `git mv`, never by hand-editing 12 files, and each task ends with a verification `grep` whose expected output is stated exactly.

**Tech Stack:** Flutter 3.35.x / Dart, `flutter analyze`, `flutter test`, `git mv`, `perl -pi -e` (used instead of `sed -i`, which is not portable between GNU and BSD/macOS), `grep`.

## Convergence Contract

---
終態: All 7 approved renames landed in the working tree, `flutter analyze` reports 0 issues, `flutter test` full suite green with test count unchanged from baseline, docs synced (CLAUDE.md wording, unit_test.md file references if filenames change), changes committed as Conventional Commits.
In-scope:
1. sidebar_view.dart:366 local `actionTextColor` → `iconColor`
2. test/widget_test.dart:15 test description string `PhotoSelectorApp` → `HalcyonApp`
3. lib/services/image_source_types.dart:96 doc comment references non-existent `ThumbnailLoader` type — fix the reference list to actual current names
4. AppState constructor param `thumbnailLoader` → `imageLoader` (lib/providers/app_state.dart:67,80 + ~18 test call sites) + fix CLAUDE.md architecture section wording "a `ThumbnailLoader` function"
5. class `ThumbnailExportService` → `PhotoExportService` (18 refs across lib+test), incl. related result/type names in the same file if they carry the Thumbnail prefix wrongly
6. class `DngPreviewExtractor` → `DngEmbeddedJpegExtractor`, class `DngPreviewProbe` → `DngEmbeddedJpegProbe` (98 refs, 12+ files)
7. File renames consequent to items 5–6 (lib file + test files) WITH all imports and unit_test.md references updated — keep milestone suffixes (m0/f3/endian etc.) in test filenames as-is
Out-of-scope (parking-lot, do NOT include): readDngOrientation dead-code removal; tierTwo/fullSize dual terminology (documented intentional); milestone-suffix scheme changes; any behavior change whatsoever.
驗收條件:
AC1. `flutter analyze` → 0 issues.
AC2. `flutter test` full suite green; test count equals pre-refactor baseline (baseline must be captured before first change).
AC3. `grep -rn "thumbnailLoader\|ThumbnailExportService\|DngPreviewExtractor\|DngPreviewProbe\|PhotoSelectorApp\|actionTextColor" lib test CLAUDE.md` → 0 hits (excluding docs/logs audit reports).
AC4. `grep -rn "ThumbnailLoader" lib` → 0 hits.
AC5. unit_test.md contains no references to old filenames that no longer exist on disk.
AC6. Conventional Commits, each commit with explicit pathspec (`git add <files>` + `git commit -- <paths>`).
Round budget: 3 rounds. Only the user may amend this contract.
---

## Global Constraints

- Working directory for every command in this plan: `/Users/jhangyu/project/Halcyon`. All paths are repo-relative.
- **Zero behavior change.** No logic edit, no signature-shape change, no new/removed/renamed test case, no new file other than the artifacts under `scripts/tmp/naming-refactor/`. If a rename appears to require a logic change, STOP and report to the lead.
- **Tasks execute strictly serially, one at a time.** A rename leaves the tree un-analyzable mid-flight, so no two implementation tasks may run concurrently. Task N+1 starts only after Task N is signed off.
- **File ownership is exclusive per task** — the per-task `Files:` list is the complete set a task may modify. One deliberate shared-file exception exists and is spelled out in Task 3 and Task 4 (`test/thumbnail_export_service_test.dart`); no other overlap exists.
- **Shared-tree git red lines:** never run `git stash`, `git reset`, `git checkout --`, `git clean`, or `git add -A`/`git add .`. Stage only your own files by explicit path. Commit only with an explicit pathspec: `git commit -m "..." -- <your paths>`. Other members' uncommitted and staged work may be present in the tree at any moment; a bare `git commit` would sweep it in.
- **Never trust harness exit-code notifications.** Every command whose result matters must write to an artifact file and self-capture its own return code on the immediately following line: `... > artifact.txt 2>&1; RC=$?; echo "RC=$RC" >> artifact.txt`. Never use `${PIPESTATUS[0]}`. Read the artifact to learn the result.
- **Do not run the full `flutter test` suite** in an implementation task — it exceeds the foreground command timeout. Only Task 1 and Task 5 (the two gate tasks) run the full suite. Implementation tasks run `flutter test -j 1 <their own test files>` only.
- **Never self-authorize a background or detached run** (`&`, `nohup`, `run_in_background`) to dodge a timeout. If a command times out, report `BLOCKED` to the lead with the artifact path and let the lead decide.
- Always use `flutter test -j 1` (parallel runs overwrite the progress line and lose the per-file evidence).
- Use `perl -pi -e`, not `sed -i` (BSD `sed` on macOS requires an argument to `-i` and will silently create backup files or fail).
- The shell is **zsh**: an unquoted `$FILES` variable does **not** word-split. Every substitution command in this plan therefore lists its target files literally on the command line. Do not "simplify" them into a variable.
- **`AC3` is literal, with no `.swift` exception (user decision, 2026-08-25 — "option B").** Five references cite `macos/Runner/DngPreviewExtractor.swift`, an upstream Swift file this repo was ported from that no longer exists on disk. They split into two groups and are handled differently:
  - **Two in `lib/`+`test/` (`lib/services/dng_preview_extractor.dart:5`, `test/dng_preview_extractor_test.dart:12`) are reworded** so the string `DngPreviewExtractor` disappears from `lib/` and `test/` entirely. Exact replacement prose is given verbatim in Task 3 Step 5. The provenance fact is preserved — only the spelling of the citation changes.
  - **Three in the docs (`unit_test.md:374`, `file_index.md:78`, `file_index.md:226`) keep the citation as-is.** AC3's grep covers `lib test CLAUDE.md` only; `unit_test.md` and `file_index.md` are outside its scope, and rewriting a historical provenance note there would lose information for no acceptance benefit. Doc substitutions therefore keep the `(?!\.swift)` negative-lookahead guard (Task 5 Step 3).
  - The `(?!\.swift)` guard also stays on Task 3's code substitution. It is what keeps the scripted pass from mangling those two comments into half-renamed nonsense before Step 5 rewords them deliberately. Guard first, reword second — never let the perl pass "handle" them.
  - Net effect: after Task 3, `grep -rn "DngPreviewExtractor" lib test` → **0 lines**. There is no surviving exception anywhere under `lib/` or `test/`.
- **`'Thumbnail Starred...'` is a user-facing menu label** (`lib/views/sidebar_view.dart:389`, plus the doc comment at `:11` and at `lib/services/photo_export_service.dart:17`). It is UI copy, not an identifier — out of scope, do not touch. No substitution in this plan matches it (the pattern is `ThumbnailExport…`, one word; the label has a space).
- Artifacts go to `scripts/tmp/naming-refactor/`. `scripts/tmp/` is tracked tooling but these artifacts are scratch — **never commit them**.
- Commit messages follow Conventional Commits (`refactor:` for the renames, `docs:` for the doc sync).
- Baseline reference numbers (verified 2026-08-25, before any change): `thumbnailLoader` 18 hits (2 in `lib/`, 16 in `test/`), `ThumbnailExport*` 27 hits, `DngPreviewExtractor` + `DngPreviewProbe` 98 hits across 14 `.dart` files, `actionTextColor` 7 hits, `PhotoSelectorApp` 1 hit, `ThumbnailLoader` 1 hit in `lib/` + 1 in `CLAUDE.md`.

---

## File Structure

Files created (renamed) by this plan:

| Old path | New path | Owner task |
|---|---|---|
| `lib/services/dng_preview_extractor.dart` | `lib/services/dng_embedded_jpeg_extractor.dart` | Task 3 |
| `test/dng_preview_extractor_test.dart` | `test/dng_embedded_jpeg_extractor_test.dart` | Task 3 |
| `test/dng_preview_extractor_m0_test.dart` | `test/dng_embedded_jpeg_extractor_m0_test.dart` | Task 3 |
| `test/dng_preview_extractor_f3_test.dart` | `test/dng_embedded_jpeg_extractor_f3_test.dart` | Task 3 |
| `test/dng_preview_extractor_endian_test.dart` | `test/dng_embedded_jpeg_extractor_endian_test.dart` | Task 3 |
| `lib/services/thumbnail_export_service.dart` | `lib/services/photo_export_service.dart` | Task 4 |
| `test/thumbnail_export_service_test.dart` | `test/photo_export_service_test.dart` | Task 4 |

Identifier renames:

| Old identifier | New identifier | Kind | Owner task |
|---|---|---|---|
| `actionTextColor` | `iconColor` | local variable | Task 2 |
| `PhotoSelectorApp` (in a test description string) | `HalcyonApp` | string literal | Task 2 |
| `DngPreviewExtractor` | `DngEmbeddedJpegExtractor` | class | Task 3 |
| `DngPreviewProbe` | `DngEmbeddedJpegProbe` | class | Task 3 |
| `thumbnailLoader` | `imageLoader` | named constructor parameter | Task 4 |
| `ThumbnailExportService` | `PhotoExportService` | class | Task 4 |
| `ThumbnailExportOutcome` | `PhotoExportOutcome` | class | Task 4 |

Docs synced (Task 5 only): `CLAUDE.md`, `unit_test.md`, `file_index.md`, `memory.md`.

Explicitly NOT renamed (verified in scope review, listed so no implementer "helpfully" fixes them): `DngEmbeddedJpeg` (already correct), `ExportBytesFetch`, `NativeImageLoad`, `PhotoSource.loader`, `fullSizeProviderFor` / `tierTwo*`, `RenamePreviewList`, `ImageRequestPurpose.preview`, every milestone suffix (`_m0`, `_f3`, `_m3`, `_m4`, `_m5`, `_m6`, `_endian`), `sidebar_thumbnail_codec.dart`, and the `ImageBytesLoader` mention in `lib/services/dng_decode_contract.dart:8`.

---

# STAGE 1 — SKELETON

### Task 1: Baseline Gate

**Files:**
- Create: `scripts/tmp/naming-refactor/01-baseline-analyze.txt`
- Create: `scripts/tmp/naming-refactor/01-baseline-suite.txt`
- Create: `scripts/tmp/naming-refactor/01-baseline-counts.txt`
- Modify: none. **This task modifies zero source files.**

**Interfaces:**
- Consumes: nothing.
- Produces: `scripts/tmp/naming-refactor/01-baseline-counts.txt`, a plain-text file containing exactly these five lines, in this order, with the `<n>` placeholders replaced by the observed integers:
  ```
  BASELINE_ANALYZE_RC=<n>
  BASELINE_ANALYZE_ISSUES=<n>
  BASELINE_TEST_RC=<n>
  BASELINE_TESTS_PASSED=<n>
  BASELINE_HEAD=<40-char git commit hash>
  ```
  Task 5 reads `BASELINE_TESTS_PASSED` and compares it against the post-refactor count.

**Behavior:**
Captures the pre-refactor ground truth. The contract's AC2 requires the baseline to exist *before the first change*, so this task must complete and be signed off before Task 2 starts. The full suite is expected to be green already; if it is not, the refactor must not start — report `BLOCKED` with the artifact path rather than "fixing" anything, because a red baseline makes AC2 unprovable.

The full suite takes longer than a short foreground command. Run it in the foreground anyway. If it exceeds the harness timeout, do **not** retry with `&`, `nohup`, or a background runner: report `BLOCKED` to the lead with the partial artifact path and the exact command, and let the lead handle the timeout escalation. Before declaring an artifact truncated, first confirm the producing process has exited, or re-read the file after a pause and compare `wc -l` — a file still being written is indistinguishable from a killed run.

**Constraints:**
- Zero source files touched; zero commits made by this task.
- `flutter test` must be invoked with `-j 1`.
- Return codes self-captured inside the artifact via `RC=$?` on the line immediately after the command.
- Do not delete or overwrite these artifacts later — Task 5 reads them.

**Acceptance criteria:**
- [ ] `scripts/tmp/naming-refactor/01-baseline-analyze.txt` exists, ends with a line matching `RC=0`, and contains `No issues found!`.
- [ ] `scripts/tmp/naming-refactor/01-baseline-suite.txt` exists, ends with a line matching `RC=0`, and contains `All tests passed!`.
- [ ] `scripts/tmp/naming-refactor/01-baseline-counts.txt` exists and contains all five keys listed in the Produces block, each with an integer/hash value (no empty right-hand side).
- [ ] `git status --porcelain lib test *.md` shows no modification attributable to this task.

---

### Task 2: Tier-1 Cosmetic Renames

**Files:**
- Modify: `lib/views/sidebar_view.dart` (7 occurrences of `actionTextColor` at lines 366, 374, 382, 390, 398, 415, 417)
- Modify: `test/widget_test.dart:15` (one string literal)
- Create: `scripts/tmp/naming-refactor/02-*.txt` (artifacts)

**Interfaces:**
- Consumes: nothing from earlier tasks (Task 1 produced only artifacts).
- Produces: nothing consumed by later tasks. `lib/views/sidebar_view.dart` and `test/widget_test.dart` are owned solely by this task and are touched by no other task in this plan.

**Behavior:**
`actionTextColor` is a local `Color` variable inside the popup-menu `itemBuilder` closure. Two sibling methods in the same file already name the identical `_iconColor(context)` result `iconColor` (`:305`, `:324`); this rename makes the third consistent. The two existing `iconColor` locals live in different method bodies, so there is no shadowing or redeclaration conflict — verified by reading `lib/views/sidebar_view.dart:300-420`.

`test/widget_test.dart:15` describes the test as `'PhotoSelectorApp renders empty-folder prompt'`, but the widget it pumps at `:26` is `HalcyonApp` (`lib/main.dart`). `PhotoSelectorApp` exists nowhere in the repo — it is a pre-Halcyon name. Only the description string changes; the test body, its file name, and its assertions are untouched. Renaming `widget_test.dart` itself is NOT in scope (the audit floated it; the contract did not adopt it).

**Constraints:**
- Do not touch the `'Thumbnail Starred...'` menu label at `lib/views/sidebar_view.dart:389` or the doc comment at `:11` — user-facing copy.
- Do not rename `test/widget_test.dart` the file.
- Do not touch `_iconColor` (the method) — only the local variable.

**Acceptance criteria:**
- [x] `grep -c "actionTextColor" lib/views/sidebar_view.dart` → `0`.
- [x] `grep -c "iconColor" lib/views/sidebar_view.dart` → `15` (8 pre-existing matching lines + the 7 lines that held `actionTextColor`; both baselines measured 2026-08-25 and re-confirmed in Step 2).
- [x] `grep -rn "PhotoSelectorApp" lib test` → no output (exit code 1).
- [x] `grep -n "HalcyonApp renders empty-folder prompt" test/widget_test.dart` → 1 line.
- [x] `scripts/tmp/naming-refactor/02-analyze.txt` contains `No issues found!` and ends with `RC=0`.
- [x] `scripts/tmp/naming-refactor/02-tests-after.txt` contains `All tests passed!`, ends with `RC=0`, and its passed-test count equals the count in `02-tests-before.txt`.
- [x] `git log -1 --name-only` shows exactly two files: `lib/views/sidebar_view.dart`, `test/widget_test.dart`.

---

### Task 3: DNG Embedded-JPEG Extractor Rename

**Files:**
- Rename: `lib/services/dng_preview_extractor.dart` → `lib/services/dng_embedded_jpeg_extractor.dart`
- Rename: `test/dng_preview_extractor_test.dart` → `test/dng_embedded_jpeg_extractor_test.dart`
- Rename: `test/dng_preview_extractor_m0_test.dart` → `test/dng_embedded_jpeg_extractor_m0_test.dart`
- Rename: `test/dng_preview_extractor_f3_test.dart` → `test/dng_embedded_jpeg_extractor_f3_test.dart`
- Rename: `test/dng_preview_extractor_endian_test.dart` → `test/dng_embedded_jpeg_extractor_endian_test.dart`
- Modify: `lib/services/photo_source.dart` (import `:5`, refs `:303`, `:330`)
- Modify: `lib/services/dart_image_loader.dart` (import `:3`, refs `:44`, `:71`, `:97`, `:109`)
- Modify: `lib/services/image_preload_controller.dart` (import `:11`, ref `:853`)
- Modify: `test/dart_image_loader_test.dart` (import `:7` + 10 refs)
- Modify: `test/photo_source_test.dart` (import `:5` + refs, incl. a comment at `:23`)
- Modify: `test/photo_source_single_probe_test.dart` (import `:25` + ref)
- Modify: `test/m6_bridge_free_test.dart` (import `:8` + ref)
- Modify (**shared-file exception**): `test/thumbnail_export_service_test.dart` — **import line 8 and its `DngPreview*` symbol references only.** This file must be touched here because Task 3's file rename breaks its import; leaving it would make `flutter analyze` red. Task 4 owns everything else in this file (its `ThumbnailExportService` references and the file rename itself). Because tasks run serially, there is no concurrent-write hazard.
- Create: `scripts/tmp/naming-refactor/03-*.txt` (artifacts)

**Interfaces:**
- Consumes: nothing from Tasks 1–2.
- Produces, for Task 4 and Task 5:
  - `lib/services/dng_embedded_jpeg_extractor.dart` exporting `class DngEmbeddedJpegExtractor` (private constructor `DngEmbeddedJpegExtractor._()`; static members unchanged: `extractEmbeddedJpeg`, `probeEmbeddedJpeg`, `probeContent`, `extractFullSizeEmbeddedJpegFromFile`, `readOrientation`, `readOrientationFromFile`, `readImageDimensions`) and `class DngEmbeddedJpegProbe` (`const DngEmbeddedJpegProbe({required DngEmbeddedJpeg? jpeg, required bool malformed})`).
  - `class DngEmbeddedJpeg` is **unchanged** — same name, same 4 fields (`bytes`, `width`, `height`, `orientation`).
  - The canonical import path for all consumers becomes `package:halcyon_flutter/services/dng_embedded_jpeg_extractor.dart` (tests) / `'dng_embedded_jpeg_extractor.dart'` (relative, within `lib/services/`).

**Behavior:**
`DngPreviewExtractor` reads the embedded JPEG renditions out of a DNG's TIFF SubIFDs. The word "preview" collides with two unrelated concepts in this codebase (`ImageRequestPurpose.preview`, the 2800px display tier; and `RenamePreviewList`, a rename-dialog widget), so the class is renamed to say what it actually extracts. This is a mechanical whole-word substitution: no member is renamed, no signature changes, no file's logic is edited.

Two provenance comments cite the upstream Swift file this code was ported from, `macos/Runner/DngPreviewExtractor.swift`. Under the user's "option B" ruling, AC3 admits no `.swift` exception, so these are **reworded by hand in Step 5** to state the same fact without spelling the old class name. The scripted substitution in Step 4 deliberately skips them (via the `(?!\.swift)` guard) so that Step 5 rewrites whole sentences rather than patching up a half-substituted line.

One deliberate residue after this task, cleared by the next one:
- `lib/services/image_source_types.dart:67` still says ``DngPreviewExtractor.readOrientation`` inside a doc comment. That file is owned by Task 4 (it also needs Task 4's `ThumbnailLoader` and `ThumbnailExportService` fixes) and would otherwise be a two-owner file. The reference is inside a `///` comment using backticks, **not** a `[]` doc link, so it does not affect `flutter analyze`. Task 4 clears it, and only after Task 4 is `lib/` fully free of the old name.

Side effect to expect and accept: `test/dng_preview_extractor_m0_test.dart` builds temp-file paths from string literals containing `dng_preview_extractor_m0_…` (lines 215, 304, 319, 331, 366, 394). The file-token substitution rewrites those to `dng_embedded_jpeg_extractor_m0_…`. These are `Directory.systemTemp` scratch filenames created and consumed inside the test itself; renaming them changes nothing observable. Do not try to exclude them.

**Constraints:**
- Use `git mv` for every file rename (preserves rename detection in the diff); never `mv` + `git add`.
- Substitution patterns, exactly: `\bDngPreviewExtractor\b(?!\.swift)` → `DngEmbeddedJpegExtractor`; `\bDngPreviewProbe\b` → `DngEmbeddedJpegProbe`; `dng_preview_extractor` (no word boundaries — the trailing `_m0`/`_f3`/`_endian` makes `\b` fail after `extractor`) → `dng_embedded_jpeg_extractor`.
- The `(?!\.swift)` guard defers the two provenance comments to the hand-edit in Step 5; it does **not** exempt them from the final state. After Step 5 the string `DngPreviewExtractor` must not exist anywhere under `lib/` or `test/`.
- Do **not** rename `DngEmbeddedJpeg` (it is already correct and the new names must not collide with it — verified: no `DngEmbeddedJpegExtractor`/`DngEmbeddedJpegProbe`/`dng_embedded_jpeg_extractor.dart` exists in the repo today).
- Do not touch `lib/services/image_source_types.dart` (Task 4 owns it).
- Do not touch any file outside the `Files:` list — in particular not `unit_test.md`, `file_index.md`, `memory.md` (Task 5 owns all docs).
- Do not run the full test suite.

**Acceptance criteria:**
- [x] `ls lib/services/dng_preview_extractor.dart` → `No such file or directory`; `ls lib/services/dng_embedded_jpeg_extractor.dart` → exists.
- [x] `ls test/ | grep -c dng_preview_extractor` → `0`; `ls test/ | grep -c dng_embedded_jpeg_extractor` → `4`.
- [x] `grep -rn "DngPreviewExtractor\|DngPreviewProbe\|dng_preview_extractor" lib test` → **exactly 1 line**: `lib/services/image_source_types.dart:67` (the documented single-task deferral to Task 4). Zero `.swift`-citation lines remain — both were reworded in Step 5.
- [x] `grep -rn "DngPreviewExtractor" lib/services/dng_embedded_jpeg_extractor.dart test/dng_embedded_jpeg_extractor_test.dart` → no output (exit code 1).
- [x] `grep -n "macos/Runner/" lib/services/dng_embedded_jpeg_extractor.dart test/dng_embedded_jpeg_extractor_test.dart` → 2 lines, confirming the provenance fact survived the rewording.
- [x] `grep -rc "DngEmbeddedJpegExtractor\|DngEmbeddedJpegProbe" lib test | grep -v ":0$" | wc -l` → `13` (13 files carry the new names).
- [x] `scripts/tmp/naming-refactor/03-analyze.txt` contains `No issues found!` and ends with `RC=0`.
- [x] `scripts/tmp/naming-refactor/03-tests-after.txt` contains `All tests passed!`, ends with `RC=0`, and its passed count equals the count in `03-tests-before.txt`.
- [x] `git log -1 --name-status` shows 5 `R`(ename) entries and the modified consumers; no doc file present.

---

### Task 4: AppState Image-Loader Seam + PhotoExportService Rename

**Files:**
- Rename: `lib/services/thumbnail_export_service.dart` → `lib/services/photo_export_service.dart`
- Rename: `test/thumbnail_export_service_test.dart` → `test/photo_export_service_test.dart`
- Modify: `lib/providers/app_state.dart` (`:22` import, `:67` param, `:69` param, `:76`, `:80`, `:110`)
- Modify: `lib/services/image_source_types.dart` (`:26-27` comment, `:67` comment, `:93-100` doc comment)
- Modify: `lib/services/exif_orientation.dart:3` (historical comment naming the old file)
- Modify: `test/app_state_test.dart` (7 `thumbnailLoader` call sites: `:156, :280, :308, :424, :456, :488, :579`)
- Modify: `test/app_state_open_with_test.dart:100`
- Modify: `test/rename_coordinator_test.dart:119`
- Modify: `test/photo_action_bar_test.dart:38`
- Modify: `test/main_detail_view_test.dart:38`
- Modify: `test/main_test.dart:46`
- Modify: `test/sidebar_view_m1_test.dart:96`
- Modify: `test/sidebar_view_test.dart` (`:72`, `:118` comment, `:210` comment, `:211` comment, `:240` comment, `:261`)
- Create: `scripts/tmp/naming-refactor/04-*.txt` (artifacts)

**Interfaces:**
- Consumes from Task 3: `class DngEmbeddedJpegExtractor` in `lib/services/dng_embedded_jpeg_extractor.dart` — referenced from the doc comment at `lib/services/image_source_types.dart:67`, which this task updates.
- Produces, for Task 5:
  - `lib/services/photo_export_service.dart` exporting `class PhotoExportService` (constructor `PhotoExportService({ExportBytesFetch? fetchBytes, DngFullDecoder? decoder})`; members unchanged, incl. static `exportBytesFor`, `exportStarred`, `exportJpegForTest`, `bakeExifOnDecoded`) and `class PhotoExportOutcome` (`const PhotoExportOutcome({required int exportedCount, required List<...> failures})` — field names unchanged).
  - `typedef ExportBytesFetch` is unchanged, same file.
  - `AppState`'s constructor named parameter is `NativeImageLoad? imageLoader` (was `thumbnailLoader`); the `PhotoExportService? exportService` parameter keeps its name, only its type is renamed.
  - Every doc-comment reference in `lib/` now names only types that exist: `NativeImageLoad`, `DngEmbeddedJpegExtractor`, `PhotoExportService`, `photo_export_service.dart`.

**Behavior:**
Three related fixes land together because they share `lib/providers/app_state.dart` and `lib/services/image_source_types.dart`:

1. **`thumbnailLoader` → `imageLoader`** (contract item 4). The seam is a `NativeImageLoad`, which serves all three `ImageRequestPurpose` values (`sidebarThumbnail` 200px, `preview` 2800px, `export` 2048px) — calling it "thumbnail loader" misleads a reader into thinking it only affects the sidebar. `ImagePreloadController` already calls its own parameter `imageLoader` (`image_preload_controller.dart:76`), so this rename makes the two ends agree. Note the resulting line at `app_state.dart:80` reads `imageLoader: imageLoader ?? dartImageLoad,` — the named argument and the constructor parameter now share a name. That is legal Dart and is the intended end state; do not "disambiguate" it with `this.` or a rename.
2. **`ThumbnailExportService` → `PhotoExportService`, `ThumbnailExportOutcome` → `PhotoExportOutcome`** (contract item 5). The service produces a ≤2048px long-edge JPEG with re-read EXIF — an export, an order of magnitude larger than the 200px `sidebarThumbnail` tier. `AppState` already calls its field `_exportService`, so only the class's own name was drifting. `PhotoExportOutcome` is the "related result name carrying the Thumbnail prefix wrongly" that the contract's item 5 authorises. `ExportBytesFetch` carries no Thumbnail prefix and is NOT renamed.
3. **`image_source_types.dart:93-100` doc comment** (contract item 3). It currently claims the seam unified three typedefs named `ThumbnailLoader` (app_state.dart), `ImageBytesLoader` (image_preload_controller.dart) and `NativeImageLoad` (photo_source.dart). Verified: `ThumbnailLoader` exists nowhere in the repo, and `ImageBytesLoader` survives only in two other comments. Only `NativeImageLoad` is real. The fix drops the two dead type names and keeps the historical statement true by naming the files instead. (The `ImageBytesLoader` mention in `lib/services/dng_decode_contract.dart:8` is a different file, not in the contract, and is left alone — parking-lot.)

**Constraints:**
- `git mv` for both file renames.
- Substitution patterns, exactly: `\bThumbnailExportService\b` → `PhotoExportService`; `\bThumbnailExportOutcome\b` → `PhotoExportOutcome`; `thumbnail_export_service` → `photo_export_service`; `\bthumbnailLoader\b` → `imageLoader`.
- The `image_source_types.dart:93-100` doc comment is prose — hand-edit it with the exact replacement text given in Step 6. Do not attempt to script it.
- Do NOT rename: `ExportBytesFetch`, `NativeImageLoad`, `_exportService`, `exportService`, `sidebar_thumbnail_codec.dart`, or the `'Thumbnail Starred'` copy in `photo_export_service.dart:17`.
- Do not touch `lib/services/dng_decode_contract.dart`.
- Do not touch any doc file (`CLAUDE.md`, `unit_test.md`, `file_index.md`, `memory.md`) — Task 5 owns them. `AC3`/`AC4` will still show `CLAUDE.md` hits after this task; that is expected.
- Do not run the full test suite.

**Acceptance criteria:**
- [x] `ls lib/services/thumbnail_export_service.dart test/thumbnail_export_service_test.dart` → both `No such file or directory`; `ls lib/services/photo_export_service.dart test/photo_export_service_test.dart` → both exist.
- [x] `grep -rn "thumbnailLoader\|ThumbnailExportService\|ThumbnailExportOutcome\|thumbnail_export_service\|ThumbnailLoader" lib test` → no output (exit code 1).
- [x] `grep -rn "DngPreviewExtractor\|DngPreviewProbe\|dng_preview_extractor" lib test` → no output (exit code 1). This task's Step 5 clears the last surviving reference, so `lib/` and `test/` end fully free of the old names — AC3 has no `.swift` exception (user's option-B ruling).
- [x] `grep -c "imageLoader" lib/providers/app_state.dart` → `2`.
- [x] `grep -rc "thumbnailLoader" test | grep -v ":0$"` → no output.
- [x] `scripts/tmp/naming-refactor/04-analyze.txt` contains `No issues found!` and ends with `RC=0`.
- [x] `scripts/tmp/naming-refactor/04-tests-after.txt` contains `All tests passed!`, ends with `RC=0`, and its passed count equals the count in `04-tests-before.txt`.
- [x] `git log -1 --name-status` shows 2 `R` entries plus the modified consumers; no doc file present.

---

### Task 5: Doc Sync + Final Full-Suite Gate

**Files:**
- Modify: `CLAUDE.md` (`:38` `ThumbnailLoader` wording; `:49` `lib/services/thumbnail_export_service.dart` path)
- Modify: `unit_test.md` (`:374` `dng_preview_extractor.dart`; `:1127` and `:1139` test-file paths; `:1192`, `:1193`, `:1194`, `:1196`, `:1208` `thumbnail_export_service*` paths; the TC-030 / TC-164~171 headings naming `DngPreviewExtractor`)
- Modify: `file_index.md` (`:65`, `:78`, `:117`–`:120`, `:132`, `:226`, `:228`)
- Modify: `memory.md` (**append one new AD entry only** — do not rewrite historical entries)
- Create: `scripts/tmp/naming-refactor/05-*.txt` (artifacts)

**Interfaces:**
- Consumes: `scripts/tmp/naming-refactor/01-baseline-counts.txt` (`BASELINE_TESTS_PASSED`), and the final identifier/file names produced by Tasks 3 and 4 (`DngEmbeddedJpegExtractor`, `DngEmbeddedJpegProbe`, `dng_embedded_jpeg_extractor.dart`, `PhotoExportService`, `PhotoExportOutcome`, `photo_export_service.dart`, `imageLoader`, `NativeImageLoad`).
- Produces: `scripts/tmp/naming-refactor/05-final-gate.txt`, the sign-off artifact carrying `ANALYZE_RC`, `TEST_RC`, the post-refactor passed count, and the pass/fail line for each of AC1–AC6.

**Behavior:**
Docs are synced last, after all code renames have landed, so every doc reference points at a name that already exists on disk — no forward references anywhere in this plan.

`memory.md` is treated differently from the other three docs. Its `AD-NNN` / `G-NNN` entries are dated historical records of decisions as they were made; rewriting `DngPreviewExtractor` inside AD-021/AD-026/etc. would falsify the record. Instead, append one new AD entry at the end of the AD section recording this rename and giving the old→new mapping, so a future reader of the historical entries can resolve the old names. `unit_test.md` is the opposite case: the contract's AC5 is a mechanical check that it names no file that no longer exists, so **all** file-path references there, including in historical status rows, are updated. The `macos/Runner/DngPreviewExtractor.swift` citation in `unit_test.md:374` and `file_index.md:78,226` stays as-is — that file already did not exist before this refactor, so it is outside AC5's "old filenames" (it was never renamed by us), and both docs sit outside AC3's `lib test CLAUDE.md` scope. This is the one place where the old spelling legitimately survives: the two sibling citations that lived in `lib/` and `test/` were reworded away in Task 3 Step 5, because those two files *are* inside AC3's scope and the user's option-B ruling allows no exception there.

The final gate runs `flutter analyze` and the full `flutter test -j 1` suite, self-capturing both return codes into artifacts, then evaluates AC1–AC6 mechanically and writes a verdict line per criterion. AC2 requires the post-refactor passed count to be **equal** to `BASELINE_TESTS_PASSED`; a higher or lower number is a failure, not a bonus, because this plan adds and removes no tests.

If the full suite exceeds the foreground timeout: report `BLOCKED` with the artifact path. Do not background it. Before declaring the artifact truncated, confirm the `flutter test` process has exited (`pgrep -f "flutter test"` → no output) or re-read the file and compare `wc -l` against the earlier read — a file mid-write looks identical to a killed run.

**Constraints:**
- Doc substitution patterns must carry the `.swift` guard: `\bDngPreviewExtractor\b(?!\.swift)` and `DngPreviewExtractor\.swift` must survive verbatim.
- Do not modify any file under `lib/` or `test/` — all code is frozen at this point. If the gate is red, report the failure to the lead; do not fix code inside this task.
- Do not commit anything under `scripts/tmp/`.
- Two commits: one `docs:` commit for the four doc files, and no code commit.
- `flutter test -j 1`, foreground, artifact + `RC=$?`.

**Acceptance criteria:**
- [ ] AC1: `scripts/tmp/naming-refactor/05-analyze.txt` contains `No issues found!` and ends with `RC=0`.
- [ ] AC2: `scripts/tmp/naming-refactor/05-suite.txt` contains `All tests passed!`, ends with `RC=0`, and its passed count equals `BASELINE_TESTS_PASSED` from `01-baseline-counts.txt`.
- [ ] AC3: `grep -rn "thumbnailLoader\|ThumbnailExportService\|DngPreviewExtractor\|DngPreviewProbe\|PhotoSelectorApp\|actionTextColor" lib test CLAUDE.md` → **no output, exit code 1**. Literal, no exception of any kind (user's option-B ruling).
- [ ] AC4: `grep -rn "ThumbnailLoader" lib` → no output (exit code 1).
- [ ] AC5: for each `.dart` path referenced in `unit_test.md`, the file exists on disk — verified by the loop in Step 8, which must print `MISSING_COUNT=0`.
- [ ] AC6: `git log --oneline -5` shows Conventional-Commit subjects, and `git log -5 --name-only` shows no artifact path under `scripts/tmp/`.
- [ ] `scripts/tmp/naming-refactor/05-final-gate.txt` exists and contains one `AC1:`…`AC6:` line each, every one reading `PASS`.

---

# STAGE 2 — IMPLEMENTATION STEPS

## Task 1 Steps: Baseline Gate

- [ ] **Step 1: Create the artifact directory and record HEAD**

```bash
cd /Users/jhangyu/project/Halcyon
mkdir -p scripts/tmp/naming-refactor
git rev-parse HEAD > scripts/tmp/naming-refactor/01-head.txt
git status --porcelain lib test > scripts/tmp/naming-refactor/01-tree-before.txt
```

Expected: `01-head.txt` holds one 40-char hash. `01-tree-before.txt` may be empty or list other members' in-flight files — either is fine; it is recorded so a later diff can tell your changes from theirs.

- [ ] **Step 2: Capture the analyze baseline**

```bash
cd /Users/jhangyu/project/Halcyon
flutter analyze > scripts/tmp/naming-refactor/01-baseline-analyze.txt 2>&1; RC=$?; echo "RC=$RC" >> scripts/tmp/naming-refactor/01-baseline-analyze.txt
tail -3 scripts/tmp/naming-refactor/01-baseline-analyze.txt
```

Expected tail: a line `No issues found!` followed by `RC=0`. If `RC` is non-zero or issues are listed, STOP and report `BLOCKED` — the refactor may not start on a red analyze.

- [ ] **Step 3: Capture the full-suite baseline**

```bash
cd /Users/jhangyu/project/Halcyon
flutter test -j 1 > scripts/tmp/naming-refactor/01-baseline-suite.txt 2>&1; RC=$?; echo "RC=$RC" >> scripts/tmp/naming-refactor/01-baseline-suite.txt
tail -3 scripts/tmp/naming-refactor/01-baseline-suite.txt
```

Expected tail: a line of the form `+NNN: All tests passed!` followed by `RC=0`.

If this command is killed by the harness timeout: do NOT re-run it with `&`/`nohup`/a background runner. Run `pgrep -f "flutter test"` first — if it prints a PID the run is still alive and the artifact is not truncated, just incomplete; wait and re-read. If no PID and no `RC=` line, report `BLOCKED` to the lead with the artifact path and the exact command.

- [ ] **Step 4: Extract the counts into the machine-readable baseline file**

```bash
cd /Users/jhangyu/project/Halcyon
ART=scripts/tmp/naming-refactor
{
  echo "BASELINE_ANALYZE_RC=$(grep -o 'RC=[0-9]*' $ART/01-baseline-analyze.txt | tail -1 | cut -d= -f2)"
  echo "BASELINE_ANALYZE_ISSUES=$(grep -c 'issue found\|issues found' $ART/01-baseline-analyze.txt)"
  echo "BASELINE_TEST_RC=$(grep -o 'RC=[0-9]*' $ART/01-baseline-suite.txt | tail -1 | cut -d= -f2)"
  echo "BASELINE_TESTS_PASSED=$(grep -o '+[0-9]*: All tests passed!' $ART/01-baseline-suite.txt | tail -1 | grep -o '[0-9]*')"
  echo "BASELINE_HEAD=$(cat $ART/01-head.txt)"
} > $ART/01-baseline-counts.txt
cat $ART/01-baseline-counts.txt
```

Expected: five lines, each with a non-empty value, e.g.

```
BASELINE_ANALYZE_RC=0
BASELINE_ANALYZE_ISSUES=0
BASELINE_TEST_RC=0
BASELINE_TESTS_PASSED=356
BASELINE_HEAD=52057c5...
```

If `BASELINE_TESTS_PASSED` is empty, the `All tests passed!` line is absent — the suite did not finish or is red. Report `BLOCKED`.

- [ ] **Step 5: Confirm zero source modifications, then report**

```bash
cd /Users/jhangyu/project/Halcyon
diff <(git status --porcelain lib test) scripts/tmp/naming-refactor/01-tree-before.txt && echo "NO_SOURCE_CHANGE=OK"
```

Expected: `NO_SOURCE_CHANGE=OK`, no diff output.

No commit in this task — the artifacts are scratch and must not be committed. Report `READY_FOR_SIGNOFF` with the five baseline values and the artifact paths.

---

## Task 2 Steps: Tier-1 Cosmetic Renames

- [x] **Step 1: Record the owned files' current test state (green-before evidence)**

```bash
cd /Users/jhangyu/project/Halcyon
mkdir -p scripts/tmp/naming-refactor
flutter test -j 1 test/widget_test.dart test/sidebar_view_test.dart test/sidebar_view_m1_test.dart > scripts/tmp/naming-refactor/02-tests-before.txt 2>&1; RC=$?; echo "RC=$RC" >> scripts/tmp/naming-refactor/02-tests-before.txt
tail -2 scripts/tmp/naming-refactor/02-tests-before.txt
```

Expected: `+NN: All tests passed!` then `RC=0`. Record the `NN`; Step 6 must reproduce the same number.

- [x] **Step 2: Record the before-counts for the acceptance greps**

```bash
cd /Users/jhangyu/project/Halcyon
grep -c "actionTextColor" lib/views/sidebar_view.dart
grep -c "iconColor" lib/views/sidebar_view.dart
```

Expected: `7`, then `8`. (The 8 pre-existing `iconColor` hits are the `_iconColor` method declaration at `:69`, its 3 call sites at `:220`, `:305`, `:324`, the 2 local declarations at `:305`/`:324`, and 2 uses at `:311`/`:327`; `grep -c` counts lines, and `:305`/`:324` each hold both a declaration and the `_iconColor` call.) After Step 3, `iconColor` must be `8 + 7 = 15` lines and `actionTextColor` must be `0`.

- [x] **Step 3: Rename the local variable**

```bash
cd /Users/jhangyu/project/Halcyon
perl -pi -e 's/\bactionTextColor\b/iconColor/g' lib/views/sidebar_view.dart
grep -n "iconColor" lib/views/sidebar_view.dart | sed -n '1,20p'
```

Expected result at line 366 and its users:

```dart
        final iconColor = _iconColor(context);

        return [
          PopupMenuItem(
            value: kCopyMenuValue,
            enabled: hasStarred,
            child: Text(
              'Copy Starred...',
              style: TextStyle(color: iconColor),
            ),
```

- [x] **Step 4: Fix the stale test description string**

Edit `test/widget_test.dart` line 15. Replace exactly this line:

```dart
  testWidgets('PhotoSelectorApp renders empty-folder prompt', (
```

with:

```dart
  testWidgets('HalcyonApp renders empty-folder prompt', (
```

Nothing else in the file changes — the `await tester.pumpWidget(... const HalcyonApp())` body at `:23-28` is already correct.

- [x] **Step 5: Verify the greps**

```bash
cd /Users/jhangyu/project/Halcyon
echo "actionTextColor=$(grep -c 'actionTextColor' lib/views/sidebar_view.dart)"
echo "iconColor=$(grep -c 'iconColor' lib/views/sidebar_view.dart)"
grep -rn "PhotoSelectorApp" lib test; echo "PhotoSelectorApp_grep_rc=$?"
grep -n "HalcyonApp renders empty-folder prompt" test/widget_test.dart
```

Expected:
```
actionTextColor=0
iconColor=15
PhotoSelectorApp_grep_rc=1
15:  testWidgets('HalcyonApp renders empty-folder prompt', (
```

- [x] **Step 6: Run analyze and the owned tests**

```bash
cd /Users/jhangyu/project/Halcyon
flutter analyze > scripts/tmp/naming-refactor/02-analyze.txt 2>&1; RC=$?; echo "RC=$RC" >> scripts/tmp/naming-refactor/02-analyze.txt
flutter test -j 1 test/widget_test.dart test/sidebar_view_test.dart test/sidebar_view_m1_test.dart > scripts/tmp/naming-refactor/02-tests-after.txt 2>&1; RC=$?; echo "RC=$RC" >> scripts/tmp/naming-refactor/02-tests-after.txt
tail -2 scripts/tmp/naming-refactor/02-analyze.txt
tail -2 scripts/tmp/naming-refactor/02-tests-after.txt
```

Expected: `No issues found!` / `RC=0`, then the same `+NN: All tests passed!` count as Step 1 / `RC=0`.

- [x] **Step 7: Commit**

```bash
cd /Users/jhangyu/project/Halcyon
git add lib/views/sidebar_view.dart test/widget_test.dart
git commit -m "refactor(naming): rename actionTextColor to iconColor and fix stale PhotoSelectorApp test name" -- lib/views/sidebar_view.dart test/widget_test.dart
git log -1 --name-only
```

Expected: the commit lists exactly `lib/views/sidebar_view.dart` and `test/widget_test.dart`. If it lists anything else, another member's staged work was swept in — do NOT `reset`; freeze, report the commit hash to the lead, and let the lead adjudicate.

Report `READY_FOR_SIGNOFF` with the grep outputs and the two artifact tails.

---

## Task 3 Steps: DNG Embedded-JPEG Extractor Rename

- [x] **Step 1: Record green-before for the owned test files**

```bash
cd /Users/jhangyu/project/Halcyon
mkdir -p scripts/tmp/naming-refactor
flutter test -j 1 test/dng_preview_extractor_test.dart test/dng_preview_extractor_m0_test.dart test/dng_preview_extractor_f3_test.dart test/dng_preview_extractor_endian_test.dart test/dart_image_loader_test.dart test/photo_source_test.dart test/photo_source_single_probe_test.dart test/m6_bridge_free_test.dart test/thumbnail_export_service_test.dart > scripts/tmp/naming-refactor/03-tests-before.txt 2>&1; RC=$?; echo "RC=$RC" >> scripts/tmp/naming-refactor/03-tests-before.txt
tail -2 scripts/tmp/naming-refactor/03-tests-before.txt
```

Expected: `+NN: All tests passed!` then `RC=0`. Record `NN`.

- [x] **Step 2: Record the reference inventory before the change**

```bash
cd /Users/jhangyu/project/Halcyon
grep -rn "DngPreviewExtractor\|DngPreviewProbe" lib test | wc -l
grep -rn "DngPreviewExtractor.swift" lib test
```

Expected: `98`, then exactly 2 lines (`lib/services/dng_preview_extractor.dart:5`, `test/dng_preview_extractor_test.dart:12`). These are the two provenance comments. Step 4's scripted pass deliberately skips them; Step 5 rewords them by hand. They must NOT survive unchanged — under the user's option-B ruling, AC3 admits no `.swift` exception inside `lib/` or `test/`.

- [x] **Step 3: Rename the five files with `git mv`**

```bash
cd /Users/jhangyu/project/Halcyon
git mv lib/services/dng_preview_extractor.dart lib/services/dng_embedded_jpeg_extractor.dart
git mv test/dng_preview_extractor_test.dart test/dng_embedded_jpeg_extractor_test.dart
git mv test/dng_preview_extractor_m0_test.dart test/dng_embedded_jpeg_extractor_m0_test.dart
git mv test/dng_preview_extractor_f3_test.dart test/dng_embedded_jpeg_extractor_f3_test.dart
git mv test/dng_preview_extractor_endian_test.dart test/dng_embedded_jpeg_extractor_endian_test.dart
ls test/ | grep dng_embedded
```

Expected: four `dng_embedded_jpeg_extractor*_test.dart` filenames listed.

- [x] **Step 4: Substitute the class names and the file token**

One command, files listed literally (zsh does not word-split unquoted variables — do not refactor this into `$FILES`):

```bash
cd /Users/jhangyu/project/Halcyon
perl -pi -e 's/\bDngPreviewExtractor\b(?!\.swift)/DngEmbeddedJpegExtractor/g; s/\bDngPreviewProbe\b/DngEmbeddedJpegProbe/g; s/dng_preview_extractor/dng_embedded_jpeg_extractor/g' \
  lib/services/dng_embedded_jpeg_extractor.dart \
  lib/services/photo_source.dart \
  lib/services/dart_image_loader.dart \
  lib/services/image_preload_controller.dart \
  test/dng_embedded_jpeg_extractor_test.dart \
  test/dng_embedded_jpeg_extractor_m0_test.dart \
  test/dng_embedded_jpeg_extractor_f3_test.dart \
  test/dng_embedded_jpeg_extractor_endian_test.dart \
  test/dart_image_loader_test.dart \
  test/photo_source_test.dart \
  test/photo_source_single_probe_test.dart \
  test/m6_bridge_free_test.dart \
  test/thumbnail_export_service_test.dart
```

Note the ordering inside the `-e`: the `.swift` guard runs on the class-name pattern only. The lowercase file token `dng_preview_extractor` is substituted without word boundaries, because `\b` would fail on `dng_preview_extractor_m0_test` (`_` is a word character).

- [x] **Step 5: Reword the two provenance comments, then spot-check the substitution**

First confirm the guard worked — the two comments must still hold their original text at this point, un-mangled:

```bash
cd /Users/jhangyu/project/Halcyon
grep -n "DngPreviewExtractor" lib/services/dng_embedded_jpeg_extractor.dart test/dng_embedded_jpeg_extractor_test.dart
```

Expected: exactly 2 lines, both still reading `macos/Runner/DngPreviewExtractor.swift`. If either line shows a half-substituted name like `macos/Runner/DngEmbeddedJpegExtractor.swift`, the guard failed — STOP and report to the lead, do not hand-patch.

Now reword them. In `lib/services/dng_embedded_jpeg_extractor.dart`, replace exactly this line (line 5):

```dart
// Pure-Dart port of macos/Runner/DngPreviewExtractor.swift (Round 3a/3b),
```

with:

```dart
// Pure-Dart port of the upstream macOS Swift extractor that used to live
// under macos/Runner/ and has since been removed (Round 3a/3b),
```

Note this replaces one line with two; the following line (`// extended in M0 with byte-range disk reads and long-edge candidate selection.`) and the rest of the comment block are unchanged, so the block still reads as one sentence: "Pure-Dart port of the upstream macOS Swift extractor that used to live under macos/Runner/ and has since been removed (Round 3a/3b), extended in M0 with byte-range disk reads and long-edge candidate selection."

In `test/dng_embedded_jpeg_extractor_test.dart`, replace exactly these two lines (lines 10–11):

```dart
/// Task #1 (dng-dart-preview, AC1/AC2): pure-Dart port of
/// macos/Runner/DngPreviewExtractor.swift.
```

with:

```dart
/// Task #1 (dng-dart-preview, AC1/AC2): pure-Dart port of the upstream macOS
/// Swift extractor that used to live under macos/Runner/ (removed upstream).
```

Both rewordings preserve the provenance fact — that this is a port of a since-removed macOS Swift implementation, and where that implementation lived — while removing the string `DngPreviewExtractor` from `lib/` and `test/`, as the user's option-B ruling on AC3 requires. Neither file's code is touched; both edits are inside comment blocks.

Then spot-check the scripted substitution:

```bash
cd /Users/jhangyu/project/Halcyon
sed -n '1,12p;65,72p' lib/services/dng_embedded_jpeg_extractor.dart
grep -n "DngEmbeddedJpeg" lib/services/dart_image_loader.dart
```

Expected in `lib/services/dng_embedded_jpeg_extractor.dart`: the reworded provenance comment at lines 5–6, and the class (now shifted one line later by the rewording, at `:67-68`) reading

```dart
class DngEmbeddedJpegExtractor {
  const DngEmbeddedJpegExtractor._();
```

Expected in `lib/services/dart_image_loader.dart`: `DngEmbeddedJpegExtractor.extractEmbeddedJpeg`, `.probeEmbeddedJpeg`, `.readImageDimensions`, `.readOrientation` at lines 44, 71, 97, 109, and the import at `:3` now `import 'dng_embedded_jpeg_extractor.dart';`.

- [x] **Step 6: Verification greps**

```bash
cd /Users/jhangyu/project/Halcyon
echo "--- residual old names (expect exactly 1 line) ---"
grep -rn "DngPreviewExtractor\|DngPreviewProbe\|dng_preview_extractor" lib test
echo "--- provenance fact preserved (expect 2 lines) ---"
grep -n "macos/Runner/" lib/services/dng_embedded_jpeg_extractor.dart test/dng_embedded_jpeg_extractor_test.dart
echo "--- files carrying new names (expect 13) ---"
grep -rc "DngEmbeddedJpegExtractor\|DngEmbeddedJpegProbe" lib test | grep -v ":0$" | wc -l
echo "--- DngEmbeddedJpeg class untouched (expect its own definition line) ---"
grep -n "^class DngEmbeddedJpeg " lib/services/dng_embedded_jpeg_extractor.dart
```

Expected residual output, exactly this one line and no others:

```
lib/services/image_source_types.dart:67:/// read in Dart via `DngPreviewExtractor.readOrientation`, a bounded
```

That single line is the deliberate handoff to Task 4 (see Behavior); Task 4 clears it, after which `lib/` and `test/` are free of the old name. Then the provenance grep prints 2 lines (one per file, both naming `macos/Runner/` with no class name), then `13`, then `24:class DngEmbeddedJpeg {`.

- [x] **Step 7: Analyze and run the owned tests**

```bash
cd /Users/jhangyu/project/Halcyon
flutter analyze > scripts/tmp/naming-refactor/03-analyze.txt 2>&1; RC=$?; echo "RC=$RC" >> scripts/tmp/naming-refactor/03-analyze.txt
flutter test -j 1 test/dng_embedded_jpeg_extractor_test.dart test/dng_embedded_jpeg_extractor_m0_test.dart test/dng_embedded_jpeg_extractor_f3_test.dart test/dng_embedded_jpeg_extractor_endian_test.dart test/dart_image_loader_test.dart test/photo_source_test.dart test/photo_source_single_probe_test.dart test/m6_bridge_free_test.dart test/thumbnail_export_service_test.dart > scripts/tmp/naming-refactor/03-tests-after.txt 2>&1; RC=$?; echo "RC=$RC" >> scripts/tmp/naming-refactor/03-tests-after.txt
tail -2 scripts/tmp/naming-refactor/03-analyze.txt
tail -2 scripts/tmp/naming-refactor/03-tests-after.txt
```

Expected: `No issues found!` / `RC=0`; then the same `+NN: All tests passed!` count as Step 1 / `RC=0`. A different count means a test file was dropped or double-listed — investigate before committing.

- [x] **Step 8: Commit**

```bash
cd /Users/jhangyu/project/Halcyon
git add lib/services/dng_embedded_jpeg_extractor.dart lib/services/photo_source.dart lib/services/dart_image_loader.dart lib/services/image_preload_controller.dart test/dng_embedded_jpeg_extractor_test.dart test/dng_embedded_jpeg_extractor_m0_test.dart test/dng_embedded_jpeg_extractor_f3_test.dart test/dng_embedded_jpeg_extractor_endian_test.dart test/dart_image_loader_test.dart test/photo_source_test.dart test/photo_source_single_probe_test.dart test/m6_bridge_free_test.dart test/thumbnail_export_service_test.dart
git commit -m "refactor(naming): rename DngPreviewExtractor/Probe to DngEmbeddedJpegExtractor/Probe" -- lib/services/dng_embedded_jpeg_extractor.dart lib/services/photo_source.dart lib/services/dart_image_loader.dart lib/services/image_preload_controller.dart test/dng_embedded_jpeg_extractor_test.dart test/dng_embedded_jpeg_extractor_m0_test.dart test/dng_embedded_jpeg_extractor_f3_test.dart test/dng_embedded_jpeg_extractor_endian_test.dart test/dart_image_loader_test.dart test/photo_source_test.dart test/photo_source_single_probe_test.dart test/m6_bridge_free_test.dart test/thumbnail_export_service_test.dart
git log -1 --name-status
```

Expected: 5 `R…` rename entries plus 8 `M` entries, 13 paths total, no doc file, no `scripts/tmp/` path. If extra paths appear, freeze and report to the lead — do not `reset`.

Report `READY_FOR_SIGNOFF` with the Step 6 grep output and the Step 7 artifact tails.

---

## Task 4 Steps: AppState Image-Loader Seam + PhotoExportService Rename

- [x] **Step 1: Record green-before for the owned test files**

```bash
cd /Users/jhangyu/project/Halcyon
mkdir -p scripts/tmp/naming-refactor
flutter test -j 1 test/thumbnail_export_service_test.dart test/app_state_test.dart test/app_state_open_with_test.dart test/rename_coordinator_test.dart test/photo_action_bar_test.dart test/main_detail_view_test.dart test/main_test.dart test/sidebar_view_test.dart test/sidebar_view_m1_test.dart > scripts/tmp/naming-refactor/04-tests-before.txt 2>&1; RC=$?; echo "RC=$RC" >> scripts/tmp/naming-refactor/04-tests-before.txt
tail -2 scripts/tmp/naming-refactor/04-tests-before.txt
```

Expected: `+NN: All tests passed!` then `RC=0`. Record `NN`.

- [x] **Step 2: Rename the two files with `git mv`**

```bash
cd /Users/jhangyu/project/Halcyon
git mv lib/services/thumbnail_export_service.dart lib/services/photo_export_service.dart
git mv test/thumbnail_export_service_test.dart test/photo_export_service_test.dart
ls lib/services/photo_export_service.dart test/photo_export_service_test.dart
```

Expected: both paths echoed back, no error.

- [x] **Step 3: Substitute the class names, the file token, and the parameter name**

Files listed literally (zsh word-splitting caveat again):

```bash
cd /Users/jhangyu/project/Halcyon
perl -pi -e 's/\bThumbnailExportService\b/PhotoExportService/g; s/\bThumbnailExportOutcome\b/PhotoExportOutcome/g; s/thumbnail_export_service/photo_export_service/g; s/\bthumbnailLoader\b/imageLoader/g' \
  lib/providers/app_state.dart \
  lib/services/photo_export_service.dart \
  lib/services/image_source_types.dart \
  lib/services/exif_orientation.dart \
  test/photo_export_service_test.dart \
  test/app_state_test.dart \
  test/app_state_open_with_test.dart \
  test/rename_coordinator_test.dart \
  test/photo_action_bar_test.dart \
  test/main_detail_view_test.dart \
  test/main_test.dart \
  test/sidebar_view_test.dart \
  test/sidebar_view_m1_test.dart
```

- [x] **Step 4: Verify the `AppState` constructor reads as intended**

```bash
cd /Users/jhangyu/project/Halcyon
sed -n '60,82p' lib/providers/app_state.dart
```

Expected:

```dart
class AppState extends ChangeNotifier {
  AppState({
    PhotoLibraryScanner? scanner,
    PhotoStatusStore? statusStore,
    PhotoFileActions? fileActions,
    ImagePreloadController? preloadController,
    NativeImageLoad? imageLoader,
    DngFullDecoder? dngDecoder,
    PhotoExportService? exportService,
    ExifBatchReader? exifReader,
  }) : _scanner = scanner ?? PhotoLibraryScanner(),
       _exifReader = exifReader ?? ExifMetadataService.readBatch,
       _statusStore = statusStore ?? PhotoStatusStore(),
       _fileActions = fileActions ?? PhotoFileActions(),
       _exportService =
           exportService ?? PhotoExportService(decoder: dngDecoder),
       _preloadController =
           preloadController ??
           ImagePreloadController(
             imageLoader: imageLoader ?? dartImageLoad,
```

The `imageLoader: imageLoader ?? dartImageLoad,` line is correct and intended — the named argument of `ImagePreloadController` and the `AppState` parameter now share a name. Do not add `this.` or otherwise "fix" it.

- [x] **Step 5: Clear the stale DNG reference in `image_source_types.dart`**

Task 3 deliberately left one reference here. Edit `lib/services/image_source_types.dart` line 67. Replace exactly:

```dart
/// read in Dart via `DngPreviewExtractor.readOrientation`, a bounded
```

with:

```dart
/// read in Dart via `DngEmbeddedJpegExtractor.readOrientation`, a bounded
```

- [x] **Step 6: Fix the doc comment that names two non-existent types (contract item 3)**

Edit `lib/services/image_source_types.dart`. Replace exactly these three lines (currently 95–97):

```dart
/// ONE definition for what used to be three structurally identical typedefs:
/// `ThumbnailLoader` (app_state.dart), `ImageBytesLoader`
/// (image_preload_controller.dart) and `NativeImageLoad` (photo_source.dart).
```

with:

```dart
/// ONE definition for what used to be three structurally identical typedefs,
/// declared separately in app_state.dart, image_preload_controller.dart and
/// photo_source.dart; all three call sites now share this `NativeImageLoad`.
```

Rationale, for the record: `ThumbnailLoader` exists nowhere in the repo and `ImageBytesLoader` survives only in other comments, so naming them made the doc unverifiable. The surrounding lines (the `/// The seam through which…` opener at `:93`, the `/// It lives here, in the file that imports nothing but `dart:typed_data`,` continuation at `:98-100`, and the `typedef NativeImageLoad = …` declaration at `:101-105`) are unchanged.

- [x] **Step 7: Verification greps**

```bash
cd /Users/jhangyu/project/Halcyon
echo "--- old names in lib/test (expect no output) ---"
grep -rn "thumbnailLoader\|ThumbnailExportService\|ThumbnailExportOutcome\|thumbnail_export_service\|ThumbnailLoader" lib test; echo "grep_rc=$?"
echo "--- DngPreview residue (expect no output) ---"
grep -rn "DngPreviewExtractor\|DngPreviewProbe\|dng_preview_extractor" lib test; echo "dng_grep_rc=$?"
echo "--- new names present ---"
grep -n "imageLoader" lib/providers/app_state.dart
grep -c "PhotoExportService\|PhotoExportOutcome" lib/services/photo_export_service.dart
echo "--- UI copy untouched (expect 1 line each) ---"
grep -n "'Thumbnail Starred\.\.\.'" lib/views/sidebar_view.dart
grep -n "Thumbnail Starred" lib/services/photo_export_service.dart
```

Expected:
```
--- old names in lib/test (expect no output) ---
grep_rc=1
--- DngPreview residue (expect no output) ---
dng_grep_rc=1
--- new names present ---
67:    NativeImageLoad? imageLoader,
80:             imageLoader: imageLoader ?? dartImageLoad,
9
--- UI copy untouched (expect 1 line each) ---
389:              'Thumbnail Starred...',
17:/// Result of a "Thumbnail Starred" export batch. [failures] entries are
```

- [x] **Step 8: Analyze and run the owned tests**

```bash
cd /Users/jhangyu/project/Halcyon
flutter analyze > scripts/tmp/naming-refactor/04-analyze.txt 2>&1; RC=$?; echo "RC=$RC" >> scripts/tmp/naming-refactor/04-analyze.txt
flutter test -j 1 test/photo_export_service_test.dart test/app_state_test.dart test/app_state_open_with_test.dart test/rename_coordinator_test.dart test/photo_action_bar_test.dart test/main_detail_view_test.dart test/main_test.dart test/sidebar_view_test.dart test/sidebar_view_m1_test.dart > scripts/tmp/naming-refactor/04-tests-after.txt 2>&1; RC=$?; echo "RC=$RC" >> scripts/tmp/naming-refactor/04-tests-after.txt
tail -2 scripts/tmp/naming-refactor/04-analyze.txt
tail -2 scripts/tmp/naming-refactor/04-tests-after.txt
```

Expected: `No issues found!` / `RC=0`; then the same `+NN: All tests passed!` count as Step 1 / `RC=0`.

- [x] **Step 9: Commit**

```bash
cd /Users/jhangyu/project/Halcyon
git add lib/providers/app_state.dart lib/services/photo_export_service.dart lib/services/image_source_types.dart lib/services/exif_orientation.dart test/photo_export_service_test.dart test/app_state_test.dart test/app_state_open_with_test.dart test/rename_coordinator_test.dart test/photo_action_bar_test.dart test/main_detail_view_test.dart test/main_test.dart test/sidebar_view_test.dart test/sidebar_view_m1_test.dart
git commit -m "refactor(naming): rename thumbnailLoader to imageLoader and ThumbnailExportService to PhotoExportService" -- lib/providers/app_state.dart lib/services/photo_export_service.dart lib/services/image_source_types.dart lib/services/exif_orientation.dart test/photo_export_service_test.dart test/app_state_test.dart test/app_state_open_with_test.dart test/rename_coordinator_test.dart test/photo_action_bar_test.dart test/main_detail_view_test.dart test/main_test.dart test/sidebar_view_test.dart test/sidebar_view_m1_test.dart
git log -1 --name-status
```

Expected: 2 `R…` rename entries plus 11 `M` entries, 13 paths total, no doc file, no `scripts/tmp/` path.

Report `READY_FOR_SIGNOFF` with the Step 7 grep output and the Step 8 artifact tails.

---

## Task 5 Steps: Doc Sync + Final Full-Suite Gate

- [x] **Step 1: Confirm all code renames landed before touching docs**

```bash
cd /Users/jhangyu/project/Halcyon
ls lib/services/dng_embedded_jpeg_extractor.dart lib/services/photo_export_service.dart test/photo_export_service_test.dart
ls test/ | grep -c dng_embedded_jpeg_extractor
grep -rn "thumbnailLoader\|ThumbnailExportService\|ThumbnailLoader\|DngPreviewExtractor\|DngPreviewProbe" lib test; echo "grep_rc=$?"
```

Expected: three paths echoed, `4`, then `grep_rc=1`. The `DngPreviewExtractor` term is included here deliberately: under the user's option-B ruling it must already be gone from `lib/` and `test/` — including the two provenance comments Task 3 Step 5 reworded — before docs are synced. If any check fails, STOP and report `BLOCKED`; docs must not be synced ahead of code.

- [x] **Step 2: Sync `CLAUDE.md`**

Edit `CLAUDE.md` line 38. Replace the fragment

```
a `ThumbnailLoader` function, an optional `DngFullDecoder`
```

with

```
a `NativeImageLoad` image-loading function, an optional `DngFullDecoder`
```

Then edit line 49. Replace the fragment

```
lives in `lib/services/thumbnail_export_service.dart`, not in `AppDelegate.swift`
```

with

```
lives in `lib/services/photo_export_service.dart`, not in `AppDelegate.swift`
```

- [x] **Step 3: Sync `unit_test.md` and `file_index.md` by scripted substitution**

```bash
cd /Users/jhangyu/project/Halcyon
perl -pi -e 's/\bDngPreviewExtractor\b(?!\.swift)/DngEmbeddedJpegExtractor/g; s/\bDngPreviewProbe\b/DngEmbeddedJpegProbe/g; s/dng_preview_extractor/dng_embedded_jpeg_extractor/g; s/\bThumbnailExportService\b/PhotoExportService/g; s/\bThumbnailExportOutcome\b/PhotoExportOutcome/g; s/thumbnail_export_service/photo_export_service/g' unit_test.md file_index.md
```

- [x] **Step 4: Verify the `.swift` citations survived and the doc tables read correctly**

```bash
cd /Users/jhangyu/project/Halcyon
grep -n "DngPreviewExtractor.swift" unit_test.md file_index.md
grep -n "dng_embedded_jpeg_extractor\|photo_export_service" file_index.md
grep -rn "dng_preview_extractor\|thumbnail_export_service" unit_test.md file_index.md CLAUDE.md; echo "stale_grep_rc=$?"
```

Expected: the `.swift` citations still present at `unit_test.md:374`, `file_index.md:78`, `file_index.md:226`; the `file_index.md` rows now naming `dng_embedded_jpeg_extractor.dart` (`:78`, `:117`–`:120`, `:226`) and `photo_export_service.dart` (`:65`, `:132`, `:228`); and `stale_grep_rc=1` (no stale lowercase file tokens left anywhere in the three docs).

- [x] **Step 5: Append the rename record to `memory.md`**

Do **not** rewrite existing `AD-NNN`/`G-NNN` entries — they are dated records and still legitimately name the old identifiers. Append one new entry at the end of the architecture-decision section, using the next unused `AD-NNN` number (find it with `grep -o "AD-[0-9]*" memory.md | sort -u | tail -1`):

```markdown
## AD-0NN｜命名重構：Preview/Thumbnail 前綴改為描述實際行為（2026-08-25）

- **決策**：三組識別碼改名，行為零變動：`DngPreviewExtractor`→`DngEmbeddedJpegExtractor`、`DngPreviewProbe`→`DngEmbeddedJpegProbe`（檔案 `dng_preview_extractor.dart`→`dng_embedded_jpeg_extractor.dart`，含四個測試檔）；`ThumbnailExportService`→`PhotoExportService`、`ThumbnailExportOutcome`→`PhotoExportOutcome`（檔案 `thumbnail_export_service.dart`→`photo_export_service.dart`）；`AppState` 建構子參數 `thumbnailLoader`→`imageLoader`。
- **依據**：三份命名稽核報告（`docs/logs/2026-08-25/naming-audit-*.md`）。「preview」在此 codebase 同時指 `ImageRequestPurpose.preview`（2800px 顯示層級）、DNG 內嵌 JPEG 抽取、以及改名對話框的預覽清單，三者無關；`ThumbnailExportService` 產出的是長邊 ≤2048px 的匯出圖，不是 200px 縮圖；`thumbnailLoader` 這個 seam 實際服務全部三種 `ImageRequestPurpose`。
- **本檔既有條目不改寫**：AD/G 是當時決策的歷史紀錄，舊名稱保留原文；讀到舊名稱時以本條的對照表換算。
- **未改動（parking-lot）**：`readDngOrientation` 死碼、`tierTwo`/`fullSize` 雙軌術語（刻意保留，見 CLAUDE.md 架構段）、測試檔的里程碑後綴（m0/f3/m3/m4/m5/m6/endian）、`dng_decode_contract.dart:8` 的 `ImageBytesLoader` 註解。
- **上游 Swift 檔的歷史引用**：`lib/` 與 `test/` 內兩處引用已改寫為不含舊類別名的敘述（AC3 的 grep 範圍涵蓋 `lib test CLAUDE.md`，使用者裁決不留例外）；`unit_test.md:374`、`file_index.md:78,226` 三處在 AC3 範圍外，維持原文引用 `macos/Runner/DngPreviewExtractor.swift`，因為那是已被上游移除的檔案，改寫只會損失出處資訊。
```

- [ ] **Step 6: Run the final analyze gate**

```bash
cd /Users/jhangyu/project/Halcyon
flutter analyze > scripts/tmp/naming-refactor/05-analyze.txt 2>&1; RC=$?; echo "RC=$RC" >> scripts/tmp/naming-refactor/05-analyze.txt
tail -3 scripts/tmp/naming-refactor/05-analyze.txt
```

Expected: `No issues found!` then `RC=0`.

- [ ] **Step 7: Run the final full-suite gate**

```bash
cd /Users/jhangyu/project/Halcyon
flutter test -j 1 > scripts/tmp/naming-refactor/05-suite.txt 2>&1; RC=$?; echo "RC=$RC" >> scripts/tmp/naming-refactor/05-suite.txt
tail -3 scripts/tmp/naming-refactor/05-suite.txt
```

Expected: `+NNN: All tests passed!` then `RC=0`, where `NNN` equals `BASELINE_TESTS_PASSED`.

If the command is killed by the harness timeout: run `pgrep -f "flutter test"`. If it prints a PID, the run is alive and the artifact is merely incomplete — wait and re-read, comparing `wc -l scripts/tmp/naming-refactor/05-suite.txt` between reads. Only if there is no PID **and** no `RC=` line is the run actually dead; in that case report `BLOCKED` with the artifact path. Never re-run in the background.

- [ ] **Step 8: Evaluate AC1–AC6 mechanically and write the verdict artifact**

```bash
cd /Users/jhangyu/project/Halcyon
ART=scripts/tmp/naming-refactor
BASE=$(grep '^BASELINE_TESTS_PASSED=' $ART/01-baseline-counts.txt | cut -d= -f2)
NOW=$(grep -o '+[0-9]*: All tests passed!' $ART/05-suite.txt | tail -1 | grep -o '[0-9]*')
ARC=$(grep -o 'RC=[0-9]*' $ART/05-analyze.txt | tail -1 | cut -d= -f2)
TRC=$(grep -o 'RC=[0-9]*' $ART/05-suite.txt | tail -1 | cut -d= -f2)
AC3=$(grep -rn "thumbnailLoader\|ThumbnailExportService\|DngPreviewExtractor\|DngPreviewProbe\|PhotoSelectorApp\|actionTextColor" lib test CLAUDE.md | wc -l | tr -d ' ')
AC4=$(grep -rn "ThumbnailLoader" lib | wc -l | tr -d ' ')
MISSING=0
for f in $(grep -o '[a-z0-9_/]*\.dart' unit_test.md | sort -u); do
  [ -e "$f" ] || [ -e "lib/$f" ] || [ -e "test/$f" ] || { echo "MISSING: $f"; MISSING=$((MISSING+1)); }
done
{
  echo "BASELINE_TESTS_PASSED=$BASE"
  echo "FINAL_TESTS_PASSED=$NOW"
  echo "ANALYZE_RC=$ARC"
  echo "TEST_RC=$TRC"
  echo "AC3_HITS=$AC3"
  echo "AC4_HITS=$AC4"
  echo "MISSING_COUNT=$MISSING"
  [ "$ARC" = "0" ] && grep -q 'No issues found!' $ART/05-analyze.txt && echo "AC1: PASS" || echo "AC1: FAIL"
  [ "$TRC" = "0" ] && [ -n "$NOW" ] && [ "$NOW" = "$BASE" ] && echo "AC2: PASS" || echo "AC2: FAIL"
  [ "$AC3" = "0" ] && echo "AC3: PASS" || echo "AC3: FAIL"
  [ "$AC4" = "0" ] && echo "AC4: PASS" || echo "AC4: FAIL"
  [ "$MISSING" = "0" ] && echo "AC5: PASS" || echo "AC5: FAIL"
} > $ART/05-final-gate.txt
cat $ART/05-final-gate.txt
```

Expected: `MISSING_COUNT=0`, `AC3_HITS=0`, `AC4_HITS=0`, `FINAL_TESTS_PASSED` equal to `BASELINE_TESTS_PASSED`, and `AC1: PASS` through `AC5: PASS`.

Note on AC3: the grep is now run literally, with no filter piped after it (user's option-B ruling). It can reach `0` only because Task 3 Step 5 reworded the two provenance comments in `lib/`+`test/`; if `AC3_HITS` is non-zero, print the offending lines and report to the lead rather than editing code from this task.

Note on the AC5 loop: it resolves each `*.dart` token in `unit_test.md` against the repo root, `lib/` and `test/`. The `macos/Runner/DngPreviewExtractor.swift` citation that `unit_test.md:374` retains is a `.swift` path, so the `\.dart` pattern does not match it — correct, and deliberately so: `unit_test.md` sits outside AC3's `lib test CLAUDE.md` scope, and that file predates this refactor.

- [ ] **Step 9: Commit the doc sync**

```bash
cd /Users/jhangyu/project/Halcyon
git add CLAUDE.md unit_test.md file_index.md memory.md
git commit -m "docs: sync architecture, test-case and file-index docs to the renamed identifiers" -- CLAUDE.md unit_test.md file_index.md memory.md
git log -3 --oneline
git log -1 --name-only
```

Expected: the last commit lists exactly `CLAUDE.md`, `unit_test.md`, `file_index.md`, `memory.md`; `git log -3 --oneline` shows three Conventional-Commit subjects (`docs: …`, `refactor(naming): …`, `refactor(naming): …`).

- [ ] **Step 10: Verify AC6 and report**

```bash
cd /Users/jhangyu/project/Halcyon
git log -4 --name-only | grep -c "scripts/tmp"
git log -4 --pretty=%s
```

Expected: `0` (no artifact was ever committed), then four subjects each starting with `refactor(naming):`, `refactor(naming):`, `refactor(naming):` or `docs:`.

Append `AC6: PASS` to `scripts/tmp/naming-refactor/05-final-gate.txt` if both checks hold, `AC6: FAIL` otherwise. Report `READY_FOR_SIGNOFF` with the full contents of `05-final-gate.txt`.

---

## Self-Review

**1. Spec coverage** — every contract in-scope item maps to a task:

| Contract item | Task |
|---|---|
| 1. `actionTextColor` → `iconColor` | Task 2, Step 3 |
| 2. `PhotoSelectorApp` → `HalcyonApp` in test description | Task 2, Step 4 |
| 3. `image_source_types.dart:96` dead type names in doc comment | Task 4, Step 6 |
| 4. `thumbnailLoader` → `imageLoader` (lib + 16 test sites) | Task 4, Step 3 |
| 4b. `CLAUDE.md` "a `ThumbnailLoader` function" | Task 5, Step 2 |
| 5. `ThumbnailExportService` → `PhotoExportService` + `ThumbnailExportOutcome` → `PhotoExportOutcome` | Task 4, Steps 2–3 |
| 6. `DngPreviewExtractor`/`DngPreviewProbe` renames | Task 3, Steps 3–4 |
| 7. Consequent file renames + imports + `unit_test.md` | Task 3 Step 3, Task 4 Step 2, Task 5 Step 3 |
| AC1 analyze | Task 5, Step 6 (per-task in Tasks 2/3/4) |
| AC2 full suite vs baseline | Task 1 Steps 3–4 (baseline), Task 5 Steps 7–8 |
| AC3 grep, literal with no `.swift` exception (user's option-B ruling) | Task 3 Step 5 (rewords the two `lib/`+`test/` provenance comments), Task 4 Step 5 (clears the last deferred reference), Task 5 Step 8 (evaluates) |
| AC4 grep | Task 5, Step 8 |
| AC5 unit_test.md filenames | Task 5, Steps 3–4, 8 |
| AC6 Conventional Commits with pathspec | Task 2 Step 7, Task 3 Step 8, Task 4 Step 9, Task 5 Steps 9–10 |

No gaps. Out-of-scope items are enumerated in the File Structure section's "Explicitly NOT renamed" list so no implementer widens the blast radius.

**2. Placeholder scan** — no `TBD`/`TODO`/`implement later`/`similar to Task N`/"add appropriate error handling" appears. Every command is literal and runnable; every acceptance criterion is a `grep`, `ls`, `wc`, or artifact-content check with a stated expected value. The only `<n>` placeholders are inside Task 1's *Produces* block, where they describe the shape of a file the task creates by measurement, and each is bound by an explicit extraction command in Task 1 Step 4.

**3. Type consistency** — every identifier named in a Stage-2 step is declared in some task's Interfaces block: `DngEmbeddedJpegExtractor`, `DngEmbeddedJpegProbe`, `DngEmbeddedJpeg` (Task 3 Produces); `PhotoExportService`, `PhotoExportOutcome`, `ExportBytesFetch`, `NativeImageLoad`, `imageLoader` (Task 4 Produces, Task 4 Consumes-from-Task-3 for the `image_source_types.dart:67` fix); `BASELINE_TESTS_PASSED` (Task 1 Produces, Task 5 Consumes). File paths agree across tasks: Task 3 produces `lib/services/dng_embedded_jpeg_extractor.dart` and Tasks 4/5 reference exactly that spelling; Task 4 produces `lib/services/photo_export_service.dart` / `test/photo_export_service_test.dart` and Task 5 references exactly those.

**Revision 1 (2026-08-25) — AC3 option B.** The user ruled that AC3 stays literal: no `.swift` exception. Re-ran all three self-review checks against the changed sections only.

- *Spec coverage:* the AC3 row of the table above now names the two tasks that make the grep reachable (Task 3 Step 5 rewords the `lib/`+`test/` provenance comments; Task 4 Step 5 clears the deferred `image_source_types.dart:67` reference) alongside Task 5 Step 8, which evaluates it. No requirement lost coverage. `unit_test.md` and `file_index.md` keep their citations by design and stay covered by AC5 only, which is a `.dart`-only check and cannot collide with a `.swift` path.
- *Placeholder scan:* the new Step 5 in Task 3 supplies both replacement comment blocks verbatim, with the exact before-text to match and a note on the one-line-becomes-two line shift and its knock-on effect on the class's line number in the following spot-check. No "reword appropriately" or similar hand-wave. A guard check precedes the edit with an explicit failure instruction (STOP and report; do not hand-patch).
- *Type consistency:* the rewording touches comment prose only — no identifier, signature, or path changed, so no Interfaces block is affected. Residual-grep expectations were re-derived end to end and now form a consistent chain: Task 3 → exactly 1 line (`image_source_types.dart:67`); Task 4 → 0 lines; Task 5 AC3 → `AC3_HITS=0` with the `grep -v` filter removed from the evaluation script and the artifact key renamed `AC3_NON_SWIFT_HITS` → `AC3_HITS`.
