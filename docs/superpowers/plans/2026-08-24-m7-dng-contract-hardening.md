# M7 DNG Contract Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use extended-agent-teams:team-spawn (recommended) or extended-agent-teams:team-fable to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Workers see only their own task plus this header and the Global Constraints — the **Interfaces** blocks are how neighbouring tasks' names and types are learned.

**Goal:** Close the seven engineering gaps the user kept from the external-plan audit, plus two named behaviour fixes — Android `content://` URI resolution with a destructive-navigation guard, and a JPEG (not PNG) sidebar RAW-fallback re-encode — without contradicting any standing M6 ruling.

**Architecture:** M6's shape is unchanged and is not reopened: pure-Dart `DngPreviewExtractor` → `dartImageLoad` → `PhotoSource`, no platform branches in `lib/`. M7 adds (a) precision to the extractor's terminal states — undersized candidate, malformed container, out-of-range orientation — (b) coverage for the untested big-endian reader branch, (c) durable tracked tooling for the decode gate and decoder-packaging parity, and (d) two behaviour fixes at the OS-integration edge.

**Tech Stack:** Flutter 3.35.1 / Dart ^3.9.0, `image: ^4.9.2` (already a dependency, `pubspec.yaml:50`), `dng_processor_ffi` (macOS/Windows/Android artifacts), Kotlin/AGP 9 Android runner, Python 3 for the tracked checker script.

## GOVERNANCE — SETTLED, DO NOT RE-LITIGATE

**User verdict, 2026-08-24: the per-feature preference cascade (ruling P-1 / contract term C-8) STANDS. The external design doc's claim of a five-platform *mandatory* target set, and its assertion that it supersedes the M6 documents (`f8ac3ab`, `…design.md:11,18,29-39,101,256`), are VOID — never ratified, and contradicted by a standing ruling.**

Consequences, binding on every task in this plan and on any future session reading it:
- Each feature lands on the widest cascade tier it can actually support: all platforms > macOS+Windows+Linux+Android > macOS+Windows+Linux > macOS+Windows minimum. Structural blockers demote a platform *per feature*, not globally.
- The RAW decoder legitimately ships on macOS+Windows+Android today. The Linux `.so` remains open item P-2 — an open item, not a blocker.
- iOS FFI is **not** a blocker and is not in this plan (see the Dropped section for the reason and the successor effort).
- No task rewrites `docs/logs/2026-08-24/m6-*.md`. **The M6 record is closed.** New decisions land in this plan's Decision Log and, for architecture, in `memory.md` as AD-NNN / G-NNN.

**Spec inputs (read-only):**
- `scripts/tmp/m6-r2-verify/external-plan-gap-audit.md` — the audit these tasks come from.
- `docs/logs/2026-08-24/m6-spec-contract.md` — C-1…C-8, §2.1 chosen shape, §4 U-11/U-12.
- `docs/logs/2026-08-24/m6-feature-platform-matrix.md` §3 — rulings P-1…P-14.
- `docs/logs/2026-08-24/m6-execution-plan.md` — execution ledger and the house rules this plan inherits.

---

## Global Constraints

Every task implicitly includes all of these. Values are copied verbatim from the M6 contract.

- **C-2 parity rule:** No behaviour may exist on a subset of the supported platform set. Declared exceptions are a closed list — F-12 system Trash (mac+win native), F-16 Open With (macOS/Windows/Android/iOS; Linux excluded), F-18 file association (Windows+macOS). Nothing new may cite them as precedent.
- **C-3, no platform branches in `lib/`:** `Platform.isX`, `kIsWeb`, `defaultTargetPlatform`, conditional imports, and shelled-out platform binaries are forbidden in `lib/`. The enumerated exceptions are unchanged: `perf_driver.dart`'s env reads and the single F-19 reveal site in `status_line.dart`. Verification command for every task that touches `lib/`:
  ```bash
  grep -rn "Platform\.is\|kIsWeb\|defaultTargetPlatform" lib/ | grep -v perf_driver.dart | grep -v status_line.dart; RC=$?
  ```
  Expected: no rows (`RC=1`).
- **C-4:** A test asserting single-platform semantics is deleted with its reason recorded; the frozen-file seal in `docs/logs/2026-08-24/baseline-registry.md` is lifted only for those tests, and new sha256 values are re-registered in the same commit.
- **C-5 / P-8 / P-13:** Performance gates run before any deletion. Swift-accelerator retention is rejected; on FAIL, optimise and re-gate. **Standing latency rule: any per-sample decode under 75 ms passes outright, regardless of the 2.0× ratio clause.**
- **C-6 scope-out:** no new product features beyond the two named items, no UI redesign, and **no UI latency or memory measurement by agents** — those are user-run only.
- **C-7:** parking-lot discipline. Findings during a round do not become acceptance criteria for that round. Round budget: 3 rounds.
- **C-8 / P-1:** the per-feature preference cascade, as stated in the Governance section above. Settled.
- **UI verification is USER-RUN ONLY.** No task may drive the app's UI, screenshot it, automate key or drop interactions, or assert on rendered pixels. Where visual confirmation is needed, the agent's deliverable is a build plus written instructions; the observation is the user's. This is a standing project rule.
- **No committed binary fixtures.** The user declined a committed fixture corpus (audit gap 6). Synthetic test inputs are **built in code at test time** and written to a temp directory — see Task 1's shared helper. Photographic inputs come only from `local_data/photo_samples/` (untracked).
- **House rules:**
  - Every verification command's exit code is self-captured **inside the artifact** on the line immediately after the command's output: `RC=$?`. Never `${PIPESTATUS[0]}`, never a pipe- or tee-derived code, never the harness's completion notification.
  - New or rewritten tests must be seen **red before green**, with the red output kept in the task's artifact.
  - Any benchmark must first prove the binary/dylib under measurement contains the code under test (content marker or exported symbol), not mtime.
  - Commits follow Conventional Commits, with `git add` naming exactly this task's files. **No full-tree git operations** (`stash` / `reset` / `checkout --` / `clean`) — other workers have uncommitted files in the tree.

---

## Task index

| # | Task | Audit item | Depends on |
|---|---|---|---|
| 1 | Synthetic-DNG test helper + big-endian (`MM`) coverage | F / gap 5 | — |
| 2 | Undersized-candidate rule → RAW decode, + orientation range-clamp | C, E / gaps 1, 4 | 1 |
| 3 | Malformed-DNG parse-failure state | D / gaps 2+3 | 1 |
| 4 | Android `content://` resolution + destructive-navigation guard | A | — |
| 5 | Sidebar RAW-fallback re-encode PNG → JPEG | B | — |
| 6 | Decoder packaging / ABI consistency checker | G / gap 8 | — |
| 7 | Promote the decode benchmark harness into tracked `tool/` | H / gap 9 | — |

Tasks 4, 5, 6, 7 are independent and may run in parallel with each other and with the 1→2→3 chain.

**Tasks 1, 2 and 3 all edit `lib/services/dng_preview_extractor.dart` and MUST be serialised in that order** — one worker at a time, or a strict hand-off. Two workers never hold that file concurrently.

Task 2 changes what the sidebar does with small-preview DNGs, and Task 5 changes how sidebar bytes are encoded. They touch different files (`dng_preview_extractor.dart` + `dart_image_loader.dart` versus `sidebar_thumbnail_codec.dart`) and are safe in parallel, but whichever lands second re-runs the other's suite before committing.

---

## Task 1: Synthetic-DNG test helper + big-endian (`MM`) coverage

**Files:**
- Create: `test/support/synthetic_dng.dart`
- Create: `test/dng_preview_extractor_endian_test.dart`
- Modify: `lib/services/dng_preview_extractor.dart` — **only if the differential test finds a real defect** (see Behavior)
- Modify: `unit_test.md`

**Interfaces:**
- Consumes: `DngPreviewExtractor.extractEmbeddedJpeg(String path, {int? longEdge, void Function(int byteCount)? onDiskRead})` (`lib/services/dng_preview_extractor.dart:60`, returns `Future<DngEmbeddedJpeg?>` with `.bytes/.width/.height/.orientation`, never throws); `DngPreviewExtractor.readOrientation(String path)` (`:109`, `Future<int?>`); the byte-order contract documented at `:500-506` (`true` = `II`, `false` = `MM`, `null` = neither).
- **Produces — the shared helper every later extractor task depends on.** Exact API, in `test/support/synthetic_dng.dart`:
  - `class SyntheticCandidate { const SyntheticCandidate({required int width, required int height}); final int width; final int height; }`
  - `Uint8List buildSyntheticDng({required List<SyntheticCandidate> candidates, int orientation = 1, bool bigEndian = false, bool corruptOffsets = false})` — returns a complete in-memory TIFF/DNG container: header with the requested byte-order marker, IFD0 carrying `Orientation` and `SubIFDs`, and one SubIFD per candidate pointing at a real minimal JPEG bitstream of the stated dimensions. `corruptOffsets: true` makes every candidate's `StripOffsets`/`StripByteCounts` point past EOF while leaving the container itself structurally walkable — that is Task 3's malformed input.
  - `Future<String> writeSyntheticDng(Uint8List bytes, {required Directory dir, required String name})` — writes and returns the absolute path.
  - Determinism requirement: two calls with identical arguments return byte-identical output, so a differential test can compare an `II` build against an `MM` build and attribute any difference to the reader.

**Behavior:**

Two things, one task, because neither is deliverable alone: the helper has no reason to exist without a first consumer, and the endian test has no input without the helper.

*Why a code-built helper and not committed files.* The user declined a committed binary fixture corpus (audit gap 6). Every synthetic input this plan needs is therefore constructed in memory by `buildSyntheticDng` and written to `Directory.systemTemp` inside the test, torn down by `addTearDown`. Nothing binary enters git; the inputs stay exactly reproducible from a clean checkout because the generator is source. **This is a design point of the task, not an implementation detail** — a worker who instead commits `.dng` files under `test/` has violated the user's ruling.

*Why the endian test.* `_detectByteOrder` and `_readerFor` claim big-endian support, but no `MM` fixture or test exists anywhere in `test/` — the entire big-endian branch is unexercised code (audit gap 5). Write a **differential** test: build the same logical container twice, once `bigEndian: false` and once `bigEndian: true`, and assert the extractor returns identical results for both. Differential on purpose — asserting absolute values would let a wrong-but-internally-consistent reader pass.

Compare, for the `II` build against the `MM` build: selected width and height at `longEdge: 200`; selected width and height at `longEdge: null`; the extracted `bytes` (exact `Uint8List` equality); and `readOrientation`.

If the results differ, that is a real defect in the byte-order/reader layer and this task fixes it there. If they match, the deliverable is the helper plus the test, and the artifact says "no defect found" — a legitimate outcome, but only when backed by the passing differential assertion, never by inspection.

**Constraints:**
- The helper lives under `test/support/` and is imported by tests only; nothing in `lib/` may import it.
- No `dart:ui` dependency in the helper — it must work under plain `flutter test` without an engine surface.
- Do not commit any `.dng`, `.jpg`, or other binary under `test/`. Verify with `git status --porcelain test/` before committing.
- No changes to `_select` or to orientation handling in this task — Tasks 2 and 3 own those, and concurrent edits to this file are forbidden.
- Any fix must be seen red first, with the failing assertion quoted in the artifact.

**Acceptance criteria:**
- [ ] `test/support/synthetic_dng.dart` exports `SyntheticCandidate`, `buildSyntheticDng` and `writeSyntheticDng` with exactly the signatures above (`grep -n "buildSyntheticDng\|writeSyntheticDng\|class SyntheticCandidate" test/support/synthetic_dng.dart`).
- [ ] A determinism assertion: two `buildSyntheticDng` calls with identical arguments produce equal `Uint8List`s.
- [ ] `test/dng_preview_extractor_endian_test.dart` contains one "MM equals II" assertion for each of: selected dims at `longEdge: 200`, selected dims at `longEdge: null`, extracted bytes, orientation.
- [ ] `flutter test -j 1 test/dng_preview_extractor_endian_test.dart` → `All tests passed!`, declared test count equals executed count, `RC=0` self-captured.
- [ ] Red-first evidence in the artifact: a run where the new test fails (against a deliberately wrong expectation, or against the unfixed extractor if a defect was found).
- [ ] `git status --porcelain test/` shows no binary files added.
- [ ] `flutter analyze` → `0 issues`.
- [ ] `unit_test.md` gains a TC-NNN row per new test case, with IDs that collide with nothing existing (`grep -c 'TC-' unit_test.md` before and after recorded).
- [ ] Committed with only this task's files staged explicitly.

---

## Task 2: Undersized-candidate rule → RAW decode, + orientation range-clamp

**Files:**
- Modify: `lib/services/dng_preview_extractor.dart:60` (signature), `:330-345` (`_walk` orientation), `:480-499` (`_select`), `:53-56` (the doc comment stating the fallback rule)
- Modify: `lib/services/dart_image_loader.dart:51-56` (the **non-sidebar** branch — the sidebar branch at `:40-50` must not be touched)
- Modify: `test/dng_preview_extractor_test.dart`, `test/dart_image_loader_test.dart`
- Modify: `unit_test.md`
- Modify: `memory.md` (one AD-NNN entry)

**Interfaces:**
- Consumes: `buildSyntheticDng` / `writeSyntheticDng` from Task 1; `NativeImageFailure(String code, String message)`, `NativeImageNeedsRawDecode({required int exifOrientation})` and `ImageRequestPurpose` (`targetSize`: `sidebarThumbnail` 200, `preview` 2800, `export` 2048 — `lib/services/image_source_types.dart:13-38`).
- Produces, for Task 3:
  - `static Future<DngEmbeddedJpeg?> DngPreviewExtractor.extractEmbeddedJpeg(String path, {int? longEdge, int? minLongEdge, void Function(int byteCount)? onDiskRead})` — `minLongEdge` is the new parameter, `null` by default.
  - `static int _sanitizeOrientation(int? raw)` — private; returns `raw` when `raw != null && raw >= 1 && raw <= 8`, otherwise `1`.

**Behavior:**

*Undersized-candidate rule (audit gap 1, user ruling C).* The user's ruling: **when no embedded candidate reaches the requested long edge, the file enters RAW decode instead of being served an undersized candidate.** It applies to the **preview / full-size path**. The **sidebar route keeps its existing lenient smallest-then-largest-candidate behaviour** — rulings P-11 and P-13 govern the sidebar and they stand. Both halves of that are load-bearing; state both in the code comments, not just here.

Mechanism: `minLongEdge` is applied *after* candidate selection, in both selection modes. When the selected candidate's `max(width, height)` is below `minLongEdge`, the extractor returns `null`. Selection itself is untouched — this adds a rejection, not a different choice — so the detail view still receives the largest qualifying candidate rather than a merely-adequate one. `minLongEdge: null` (the default) is today's behaviour exactly, which is what keeps the sidebar and every other caller unchanged.

Call site: the non-sidebar branch of `dartImageLoad` (`lib/services/dart_image_loader.dart:51-56`) currently calls `extractFullSizeEmbeddedJpegFromFile(path)`, which is a thin wrapper over `extractEmbeddedJpeg(path, longEdge: null)` returning only `.bytes` (`dng_preview_extractor.dart:87-92`). Replace that call with `extractEmbeddedJpeg(path, longEdge: null, minLongEdge: ImageRequestPurpose.preview.targetSize)` and use `.bytes`. A `null` result then flows into the branch's existing miss handling — for a `.dng` with `purpose == preview` that is `NativeImageNeedsRawDecode`, i.e. exactly "enter RAW decode". No new state, no new failure code.

**Scope limit that must not be silently widened: apply `minLongEdge` only for `purpose == preview`.** For `purpose == export` there is no RAW-decode path in the loader — a miss becomes `NativeImageFailure('RAW_NO_EMBEDDED_PREVIEW', …)`, so applying the rule there would convert "export a smaller-than-ideal image" into "export fails", which is a capability loss the ruling did not ask for. Export keeps today's lenient behaviour. If a worker believes export should also be strict, that is a question for the lead, not a decision to make inside the task.

Leave `extractFullSizeEmbeddedJpegFromFile` in place with its current signature; grep its other callers (`grep -rn "extractFullSizeEmbeddedJpegFromFile" lib/ test/`) and leave them on the lenient path.

**Consequences a worker must not paper over.** (1) The doc comment at `:53-56` must be rewritten to state the `minLongEdge` rule and to say explicitly that the sidebar route remains lenient under P-11/P-13; leaving it describing unconditional fallback-to-largest is a doc-drift failure. (2) DNGs whose largest embedded preview is under 2800 px move from "instant preview" to "one RAW decode, then cached". M6 measured that decode at 31.6–63.1 ms for bare-CFA samples (`p5-3-verify.txt`, ruling P-13), under the 75 ms floor — but those samples were *already* on that path. The newly-routed ones have not been measured, so this task re-runs the gate over them rather than assuming the old numbers transfer. (3) A DNG with no FFI decoder on the current cascade tier goes from "small preview" to an explicit miss; that follows from the ruling and is recorded, not worked around.

*Orientation range-clamp (audit gap 4, user ruling E).* `_walk` does `_orientationOf(reader, ifd0) ?? 1` (`:334`) — null-defaults, but accepts any integer the tag carries, so a file claiming orientation 9 or 0 propagates an out-of-range value into pixel-orientation baking downstream. Route every orientation read in this file through `_sanitizeOrientation`, and cover the boundaries in a table-driven test.

**Constraints:**
- `minLongEdge` defaults to `null`. A worker who changes the default has silently altered every other call site.
- Only the non-sidebar branch of `dart_image_loader.dart` opts in, and only for `purpose == preview`. Do not touch the sidebar branch (`:40-50`) — it stays lenient under P-11/P-13.
- The valid EXIF orientation range is 1..8 inclusive; out-of-range and null both become 1.
- C-3 grep guard stays clean; no new dependency.
- Serialise with Tasks 1 and 3 on `dng_preview_extractor.dart`.

**Acceptance criteria:**
- [ ] `grep -n "minLongEdge" lib/services/dng_preview_extractor.dart lib/services/dart_image_loader.dart` shows the parameter declared as `int? minLongEdge` (defaulting to `null`), applied after `_select` in `extractEmbeddedJpeg`, and passed a non-null value at exactly one call site — the non-sidebar branch, guarded by `purpose == ImageRequestPurpose.preview && lower.endsWith('.dng')` (see A-6: strictness applies only where a RAW-decode path actually exists).
- [ ] `grep -n "extractEmbeddedJpeg" lib/services/dart_image_loader.dart` shows the sidebar branch call unchanged (no `minLongEdge` argument).
- [ ] `grep -n "_sanitizeOrientation" lib/services/dng_preview_extractor.dart` shows the helper defined once, and no bare `?? 1` orientation default remains in the file.
- [ ] Table-driven orientation test covering raw values 0, 1, 8, 9 and null, expecting 1, 1, 8, 1, 1 — built with Task 1's helper.
- [ ] Extractor tests, using a synthetic container whose only candidate is 160×120: `extractEmbeddedJpeg(path, longEdge: null, minLongEdge: 2800)` → `null`; the same call without `minLongEdge` → the 160×120 candidate. Same pair for the `longEdge: 200` selection mode, proving `minLongEdge` applies in both modes.
- [ ] Loader test (a): `dartImageLoad` on a `.dng` whose largest candidate is under 2800 px with `purpose: preview` → `NativeImageNeedsRawDecode` (previously it returned the undersized bytes). Red-first evidence required.
- [ ] Loader test (b): the same file with `purpose: sidebarThumbnail` → still `NativeImageBytes` (the sidebar stayed lenient), and with `purpose: export` → still `NativeImageBytes` (export stayed lenient).
- [ ] The doc comment at `dng_preview_extractor.dart:53-56` no longer describes fallback-to-largest as unconditional, states the `minLongEdge` rule, and states that the sidebar route remains lenient under P-11/P-13.
- [ ] Gate re-run over the newly-routed samples using Task 7's tracked harness (or, if Task 7 has not landed, the `scripts/tmp/m6-r1-bench/` harness with provenance recorded): every newly-routed sample's per-file decode is reported with the P-13 verdict applied. A sample over 75 ms is reported to the lead, not silently accepted.
- [ ] `flutter test -j 1` → `All tests passed!`, declared count equals executed count, `RC=0` self-captured; red-first evidence for each new assertion group.
- [ ] `flutter analyze` → `0 issues`; C-3 grep guard clean.
- [ ] `memory.md` AD-NNN entry recording the amendment to the fallback rule and its P-11/P-13 interaction.
- [ ] Committed with only this task's files staged explicitly.

---

## Task 3: Malformed-DNG parse-failure state

**Files:**
- Modify: `lib/services/dng_preview_extractor.dart:366-475` (`_gatherCandidates`), `:330-345` (`_walk`)
- Modify: `lib/services/dart_image_loader.dart:51-68`
- Modify: `test/dart_image_loader_test.dart`
- Modify: `unit_test.md`
- Modify: `memory.md` (one AD-NNN entry)

**Interfaces:**
- Consumes: `buildSyntheticDng(..., corruptOffsets: true)` from Task 1; `minLongEdge` from Task 2; `NativeImageFailure(String code, String message)`, `NativeImageNeedsRawDecode({required int exifOrientation})` from `lib/services/image_source_types.dart`; `kDefaultExifOrientation`.
- Produces:
  - `class DngPreviewProbe { const DngPreviewProbe({required this.jpeg, required this.malformed}); final DngEmbeddedJpeg? jpeg; final bool malformed; }` in `lib/services/dng_preview_extractor.dart`.
  - `static Future<DngPreviewProbe> DngPreviewExtractor.probeEmbeddedJpeg(String path, {int? longEdge, int? minLongEdge})` — the malformed-aware sibling of `extractEmbeddedJpeg`, which keeps its exact current signature and return type.
  - Failure code string `'DNG_PARSE_FAILED'`, emitted by `dartImageLoad`.

**Behavior:**

A structurally broken `.dng` currently walks to "no candidate", and `dartImageLoad`'s preview branch converts that into `NativeImageNeedsRawDecode` (`lib/services/dart_image_loader.dart:56-70`) — so a corrupt file is handed to the RAW decoder as though it were merely preview-less, then fails slowly with a generic decoder error. Audit gaps 2 and 3 are one root cause: `_gatherCandidates` returns a bare list, so "the container declared no candidate" and "the container declared only unreadable candidates" are indistinguishable at the call site.

`malformed` is `true` when the container parsed but every candidate it declared is unreadable — offset or byte-count past EOF, byte-count mismatch on read, or bytes that are not a JPEG bitstream — and `false` when the container simply declares no candidate at all. `probeEmbeddedJpeg` surfaces that distinction; `dartImageLoad` consumes it in the non-sidebar branch and returns `NativeImageFailure('DNG_PARSE_FAILED', <what failed>)` for the malformed case.

The valid-miss case is unchanged and must stay unchanged: a genuinely preview-less DNG still yields `NativeImageNeedsRawDecode` carrying the walker's orientation. That is ruling (b) of contract §2.1 and it is not being reopened.

The sidebar branch is also unchanged: a malformed file still yields `NativeImageFailure('NO_THUMBNAIL', …)` there, because the sidebar has no decode-versus-fail decision to make — it hands everything non-bytes to the same RAW fallback.

**Ambiguity A-1 is settled here, in the negative.** The external plan delivers this distinction through a single-walk `inspectEmbeddedJpeg` API. M6 contract §2.1 *deliberately specifies* the two-call shape (`extractFullSizeEmbeddedJpegFromFile` then `readOrientation`). **This plan keeps the two-call shape.** A one-walk refactor is a performance refactor of a consciously-chosen design, not a behavioural gap; it stays out of scope until someone measures a cost that justifies reopening §2.1.

**Constraints:**
- `extractEmbeddedJpeg`'s signature and return type are unchanged — this task adds an API, it does not migrate callers.
- `probeEmbeddedJpeg` never throws; same contract as the rest of the file.
- Only the malformed path changes behaviour. The valid-miss path keeps producing `NativeImageNeedsRawDecode`.
- A truncated file that fails before IFD0 is readable is **not** malformed-with-candidates — it walks to `null` as today. Do not widen the definition; the existing truncation coverage at `test/dng_preview_extractor_test.dart:106-158` must keep passing untouched.
- Serialise with Tasks 1 and 2 on `dng_preview_extractor.dart`.

**Acceptance criteria:**
- [ ] `grep -n "DNG_PARSE_FAILED" lib/services/dart_image_loader.dart` → exactly one emission site, in the non-sidebar branch.
- [ ] `grep -n "class DngPreviewProbe\|probeEmbeddedJpeg" lib/services/dng_preview_extractor.dart` → type and method present.
- [ ] Test (a): a `corruptOffsets: true` synthetic container with `purpose: preview` → `NativeImageFailure` with code `DNG_PARSE_FAILED`. Red-first evidence required for this one.
- [ ] Test (b): a real preview-less DNG from `local_data/photo_samples/DNG/` with `purpose: preview` → still `NativeImageNeedsRawDecode` (the valid-miss path did not regress).
- [ ] Test (c): the same corrupt container with `purpose: sidebarThumbnail` → `NativeImageFailure` with code `NO_THUMBNAIL`.
- [ ] The pre-existing truncation tests at `test/dng_preview_extractor_test.dart:106-158` pass unmodified (quote the file's diff in the artifact showing no edits to those cases).
- [ ] `flutter test -j 1` → `All tests passed!`, declared count equals executed count, `RC=0` self-captured.
- [ ] `flutter analyze` → `0 issues`; C-3 grep guard clean.
- [ ] `memory.md` AD-NNN entry recording the malformed/valid-miss split and the decision to keep the two-call shape (A-1).
- [ ] `unit_test.md` TC rows added.
- [ ] Committed with only this task's files staged explicitly.

---

## Task 4: Android `content://` resolution + destructive-navigation guard

**Files:**
- Modify: `android/app/src/main/kotlin/com/example/halcyon/MainActivity.kt:48-59` (`handleIntent`) and its file-header comment, which currently states path resolution is out of scope
- Modify: `lib/providers/app_state.dart:237-244` (`openPhotoAtPath`)
- Modify: `lib/services/open_with_channel.dart` (doc comment only)
- Modify/Create: `test/app_state_open_with_test.dart` — create if absent; otherwise extend existing coverage, located with `grep -rln "openPhotoAtPath" test/`
- Modify: `unit_test.md`

**Interfaces:**
- Consumes: `AppState.openPhotoAtPath(String path)` (`lib/providers/app_state.dart:237`), `AppState.loadFolder(Directory dir, {String? targetSelectionId, int? targetFallbackIndex})` (`:245`), `SupportedPhotoFormats.isSupportedPath(String)` and `.photoIdFor(File)`.
- Produces: no new Dart API. Kotlin-side private helper `private fun resolveToFilePath(uri: Uri): String?` in `MainActivity`.

**Behavior:**

Two defects on one flow, so one task. **Do the guard first — it is the destructive one.**

*The guard.* `openPhotoAtPath` filters on file extension and then calls `loadFolder(file.parent, …)`. `loadFolder` clears `_currentDir`, `_items`, the preload controller and the selection **before** it scans (`:249-254`). So any string that merely *ends in* a supported extension wipes the folder the user is currently culling and replaces it with an empty scan of a directory that does not exist. A `content://` URI's opaque path segment — for example `/document/image:1234.jpg` — is exactly such a string, and it is exactly what `MainActivity.kt:51` forwards today. The fix: `openPhotoAtPath` returns early, mutating no state, unless the target file actually exists (`await File(path).exists()`) and its parent directory exists. The existing early return for unsupported extensions stays. The method's own doc comment already promises that unsupported files are "ignored rather than clearing the folder the user is already viewing" — this makes that promise true for the non-existent case too.

*The resolution.* `ACTION_VIEW` on Android normally delivers a `content://` URI, whose `uri.path` is provider-internal and is not a filesystem path. `resolveToFilePath` handles, in order: (1) `file` scheme → `uri.path` as-is; (2) `content` scheme → open the provider stream with `contentResolver.openInputStream(uri)` and copy it into the app's cache directory under a name derived from `OpenableColumns.DISPLAY_NAME`, falling back to the URI's last path segment; return the cache file's absolute path; (3) any other scheme → `null`, which drops the intent silently, as today. A copy rather than a path guess, because the Storage Access Framework exposes no real path and the app needs a `dart:io`-readable file. Whatever the guard then sees will exist.

**This does not unpark the mobile end-to-end flow.** After this task the app receives a real, readable single file, but the enclosing folder still cannot be scanned on Android (matrix F-02), so the user sees a one-photo folder at best. Say that in the report and in the two doc comments; do not claim F-16 mobile is complete.

**Constraints:**
- The guard is `lib/`-side and contains no platform branch (C-3) — it is a plain existence check that applies identically everywhere.
- The cache copy goes under `cacheDir`, never external storage. **No new Android permission may be declared.** If the implementation appears to need one, STOP and report.
- No new Flutter dependency for URI handling.
- Do not widen the `image/*` intent filter and do not restore `BROWSABLE` — commit `43a078c` narrowed both deliberately.
- The Kotlin path cannot be unit-tested in this harness. Its verification is a green Android release build; **do not claim runtime verification of the Kotlin path**, and do not invent a test that pretends to cover it.

**Acceptance criteria:**
- [ ] A test asserts `openPhotoAtPath('/nonexistent/dir/fake.jpg')` leaves `currentDir` and the item list **unchanged** from a pre-loaded folder state. This is the destructive-navigation regression and must be seen red against the current implementation first, with the red output in the artifact.
- [ ] A test asserts `openPhotoAtPath` on a real file inside a temp folder still loads that folder and selects the photo (the working path did not regress).
- [ ] `grep -n "Platform.is\|kIsWeb" lib/providers/app_state.dart; RC=$?` → `RC=1`.
- [ ] `grep -n "resolveToFilePath\|openInputStream\|cacheDir" android/app/src/main/kotlin/com/example/halcyon/MainActivity.kt` shows the content-scheme branch present.
- [ ] `grep -n "android.permission" android/app/src/main/AndroidManifest.xml` output is byte-identical before and after; both recorded in the artifact.
- [ ] `python3 scripts/build_apps.py android --release` completes with `RC=$?` self-captured as `0`.
- [ ] `flutter analyze` → `0 issues`; `flutter test -j 1` → `All tests passed!` with the executed count recorded.
- [ ] Both doc comments (`MainActivity.kt` header, `open_with_channel.dart`) state the new resolution behaviour and that the mobile flow remains parked on F-02.
- [ ] `unit_test.md` TC rows added.
- [ ] Committed with only this task's files staged explicitly.

---

## Task 5: Sidebar RAW-fallback re-encode PNG → JPEG

**Files:**
- Modify: `lib/services/sidebar_thumbnail_codec.dart` (both functions and the header doc)
- Modify: `lib/services/image_preload_controller.dart:1216-1229` (call site)
- Modify/Create: `test/sidebar_thumbnail_codec_test.dart` — locate existing coverage with `grep -rln "sidebarCacheBytes\|pngFromOrientedPixels" test/`
- Modify: `unit_test.md`
- Modify: `memory.md` (one G-NNN or AD-NNN entry)

**Interfaces:**
- Consumes: `decodedRgbaToPixelPayload(DecodedRgba decoded, {required int exifOrientation, int longEdge})` (`lib/services/decoded_rgba_image_provider.dart`); `package:image` — `img.Image.fromBytes`, `img.encodeJpg(Image, {int quality})` — already a dependency (`pubspec.yaml:50`) and already used at `lib/services/thumbnail_export_service.dart:102`.
- Produces (replacing the PNG-named pair; update both call sites):
  - `Future<Uint8List> sidebarCacheBytes(Uint8List encoded, {int longEdge = 200, int reencodeThreshold = 512 * 1024, int jpegQuality = 80})`
  - `Future<Uint8List> jpegFromOrientedPixels(DecodedRgba decoded, {required int exifOrientation, int longEdge = 200, int jpegQuality = 80})` — renamed from `pngFromOrientedPixels`.

**Behavior:**

`sidebar_thumbnail_codec.dart:17-19` records the reason for PNG in its own source: "PNG (not JPEG) because dart:ui only encodes PNG; P3.6 adopts the `image` package for export — if sidebar memory ever matters more, switch this to JPEG-q80 there." P3.6 landed (`dd1edcb`), so the stated precondition is met. This is the M6 parking-lot item being cashed in.

Both functions keep their existing structure — the same single decode, the same `decodedRgbaToPixelPayload` orientation-bake and long-edge downscale — and change only the encode step: build an `img.Image` from the RGBA8 payload (`img.Image.fromBytes` with `numChannels: 4`, `order: img.ChannelOrder.rgba`) and `img.encodeJpg(image, quality: jpegQuality)`. The `sidebarCacheBytes` pass-through branch and its `catch (_) { return encoded; }` fallback are unchanged: an undecodable input still caches the original rather than dropping the row.

Trade-off to measure and record: JPEG q80 should cut sidebar cache bytes several-fold against PNG for photographic content, at the cost of encode CPU and generational loss — the latter irrelevant, since these are display-only thumbnails never written back to disk. Measure the byte sizes. **Do not measure UI latency or app memory** (C-6: user-run only).

**Constraints:**
- Default quality 80, exposed as a named parameter so it is tunable without touching call sites.
- JPEG cannot carry alpha. Sidebar sources are photographic, so this is acceptable — but the test must confirm decode-back succeeds rather than assume it.
- No new dependency; use the pinned `image: ^4.9.2`.
- No behavioural change to the pass-through branch or to `reencodeThreshold`.
- C-3 clean; do not touch `dart_image_loader.dart` (Task 2 owns it).

**Acceptance criteria:**
- [ ] `grep -rn "pngFromOrientedPixels\|ImageByteFormat.png" lib/; RC=$?` → `RC=1` (the PNG path is gone, not left alongside).
- [ ] A test asserts `sidebarCacheBytes` output on an over-threshold input starts with the JPEG SOI marker (`0xFF 0xD8`) and decodes back to an image whose long edge is ≤ 200. Red-first evidence required.
- [ ] A test asserts the pass-through branch is unchanged: input at or under `reencodeThreshold` comes back byte-identical.
- [ ] A test asserts the undecodable-input fallback still returns the original bytes.
- [ ] A size-comparison artifact records, for at least 5 samples from `local_data/photo_samples/DNG/`, PNG byte size (before), JPEG byte size (after) and the ratio. No UI or memory numbers.
- [ ] `flutter test -j 1` → `All tests passed!`, declared count equals executed count, `RC=0` self-captured.
- [ ] `flutter analyze` → `0 issues`.
- [ ] `memory.md` entry recorded; `unit_test.md` TC rows added.
- [ ] Committed with only this task's files staged explicitly.

---

## Task 6: Decoder packaging / ABI consistency checker

**Files:**
- Create: `scripts/check_dng_ffi_artifacts.py`
- Create: `scripts/dng_ffi_artifacts.json`

**Interfaces:**
- Consumes: the sibling package `../flutter_dng_decoder/dng_processor_ffi/` — its `pubspec.yaml` `flutter.plugin.platforms` map (macOS, Android, Windows) and the packaged artifacts under its per-platform directories.
- Produces: `python3 scripts/check_dng_ffi_artifacts.py [--config scripts/dng_ffi_artifacts.json]` — exits `0` when every artifact marked `expected: true` is present and passes its symbol check, `1` otherwise; prints one line per platform as `<platform> <path> present=<bool> symbol=<present|absent|skipped>` plus a final summary line reporting how many checks were skipped.

**Behavior:**

Nothing in the repo mechanically asserts that the RAW decoder is actually packaged for the platforms the contract claims (audit gap 8). The checker closes that: a JSON manifest lists, per platform, the expected artifact path, an `expected` flag, and the symbol-verification tool for that platform's binary format — `nm -gU` for Mach-O, `nm -D` for ELF, `dumpbin /exports` for PE.

**Manifest scope is set by the settled governance verdict:** the cascade stands, so the manifest ships with macOS, Windows and Android marked `expected: true`. Linux is present with `expected: false` and a comment pointing at open item P-2, so the day the `.so` lands the change is one boolean. iOS is not in the manifest at all — see the Dropped section.

The symbol to verify is the sized-decode entry the sidebar RAW fallback depends on: `dng_decode_and_process_sized` (ruling P-12 confirmed the vendored dylib exports it and that the bindings' comment claiming otherwise is stale).

A host can only verify artifacts it can see and tools it has. When the required symbol tool is absent on the current OS, the checker prints `symbol=skipped` for that platform and counts it — it must never pretend. A missing artifact for an `expected: true` platform is a hard failure. A green line with skipped checks must be impossible to mistake for full coverage, which is what the summary count is for.

**Constraints:**
- Python 3 standard library only; no new dependency.
- The manifest is data and the checker is logic: adding or flipping a platform must not require editing the script.
- The script builds nothing and never modifies the sibling repo.
- Never report success while silently skipping an `expected: true` platform.

**Acceptance criteria:**
- [ ] `python3 scripts/check_dng_ffi_artifacts.py; RC=$?` → `RC=0` on this macOS host, with one line per configured platform and a summary line reporting the skipped count.
- [ ] Negative test recorded in the artifact: with a temporary manifest whose macOS path points at a nonexistent file, the same command gives `RC=1` and names the missing artifact.
- [ ] `grep -n "dng_decode_and_process_sized" scripts/check_dng_ffi_artifacts.py scripts/dng_ffi_artifacts.json` → present.
- [ ] The manifest marks macos/windows/android `expected: true`, linux `expected: false` with a P-2 comment, and contains no iOS entry.
- [ ] `grep -n "expected" scripts/dng_ffi_artifacts.json` output quoted in the artifact.
- [ ] Committed with only this task's files staged explicitly.

---

## Task 7: Promote the decode benchmark harness into tracked `tool/`

**Files:**
- Create: `tool/m6_dng_gate/README.md`
- Create: `tool/m6_dng_gate/g1_extract_bench.dart`
- Create: `tool/m6_dng_gate/g3_sidebar_bench.dart`
- Create: `tool/m6_dng_gate/verdict_dng_extract.py`
- Create: `tool/m6_dng_gate/run_gate.sh`

**Interfaces:**
- Consumes: the current gitignored harness sources under `scripts/tmp/m6-r1-bench/` (`g1_dart.dart`, `g3_dart_test.dart`, and the sample lists), and the recorded artifacts `scripts/tmp/20260824T08*-m6-g*.txt` and `scripts/tmp/m6-r2-verify/g3-regress-p53.txt` as the reference outputs to reproduce.
- Produces, for this and future rounds:
  - `bash tool/m6_dng_gate/run_gate.sh <sample-dir> <out-file>` — writes a machine-readable result file with its own `RC=` line self-captured inside it.
  - `python3 tool/m6_dng_gate/verdict_dng_extract.py <result-file>` — exits `0` on PASS and `1` on FAIL, printing one line per sample and a final `VERDICT: PASS|FAIL`.

**Behavior:**

The decode gate governs every performance decision in this project, and it currently exists only under gitignored `scripts/tmp/` — not re-runnable from a clean checkout (audit gap 9). This task moves it into tracked `tool/`, unchanged in method, and adds a verdict script so the pass/fail rule is executable code rather than a person re-reading a ruling. Task 2 is its first consumer.

The verdict rule is fixed by ruling P-13 and must be encoded verbatim: **a sample passes if its per-sample decode latency is under 75 ms absolutely, regardless of ratio; otherwise the 2.0× ratio clause against the recorded baseline applies.** The 75 ms floor is a constant with the ruling cited beside it, not a tunable — parameterising it away removes the ruling.

Two anti-fabrication rules are mandatory and must be *implemented*, not merely documented:
1. **Provenance.** `run_gate.sh` writes, in the result file's header, a content marker proving the measured code is the code under test — the git HEAD hash, plus an exported-symbol or dims check on any native artifact measured. Never mtime. This rule exists because a past round measured a dylib that did not contain the symbol under test and produced confident, wrong numbers.
2. **Pre-registration.** The verdict rule and expected values are written into the result file **above** the numbers, before the numbers exist. Re-running with different parameters until a run passes is forbidden; a failing run stays in the artifact.

Correctness criterion is reproduction, not redesign: run on the same samples, the promoted harness must reproduce the recorded G″″ result (33/33 PASS, bare-CFA samples in the 31.6–63.1 ms band per `p5-3-verify.txt`).

**Constraints:**
- The method must not change while porting. If the tmp harness contains a bug, report it — silently fixing it inside the port makes the reproduction check meaningless.
- `tool/` must not be gitignored; verify with `git check-ignore`.
- No UI or memory measurement (C-6).
- The harness reads photos from `local_data/photo_samples/` and must fail loudly with a clear message when that directory is absent — never fall back to synthetic input.

**Acceptance criteria:**
- [ ] `git check-ignore tool/m6_dng_gate/run_gate.sh; RC=$?` → `RC=1`.
- [ ] `bash tool/m6_dng_gate/run_gate.sh local_data/photo_samples/DNG /tmp/m7-gate.txt` completes, and `/tmp/m7-gate.txt` contains, in this order: the verdict rule text, the provenance header (HEAD hash plus symbol/dims marker), the per-sample numbers, and a self-captured `RC=` line.
- [ ] `python3 tool/m6_dng_gate/verdict_dng_extract.py /tmp/m7-gate.txt; RC=$?` prints a final `VERDICT:` line, and `RC` matches the verdict (`0` for PASS).
- [ ] Reproduction: per-sample PASS/FAIL matches the recorded G″″ result (33/33 PASS) for the samples both runs share. Any divergence is investigated and explained in the artifact, never rounded away.
- [ ] `grep -n "75" tool/m6_dng_gate/verdict_dng_extract.py` shows the floor as a literal constant with the P-13 citation in a comment.
- [ ] `README.md` documents the invocation, the P-13 rule, the provenance requirement and the pre-registration requirement.
- [ ] Committed with only this task's files staged explicitly.

---

## Explicitly dropped by user, 2026-08-24

Recorded so they do not resurface as rediscoveries. These are decisions, not oversights — a future session proposing them again is re-litigating a settled call.

- **Audit gap 6 — committed deterministic DNG fixtures.** Not wanted. Synthetic inputs are built in code at test time (Task 1's `test/support/synthetic_dng.dart`) and written to a temp directory; no binaries enter the repository.
- **Audit gap 10 — per-platform visible-image smoke records.** Declined. Observing the running app is user-run territory in this project; agents do not produce, fill, or infer such records.
- **Audit gap 7 — iOS FFI decoder port.** **Superseded by an announced future direction**, recorded here verbatim as given: *the `dng_decoder` library will later be upgraded into a general `raw_decoder` supporting ALL RAW formats.* Platform-port investment decisions — which platforms the decoder is built and packaged for, and in what order — belong to that future effort, not to M7. Nothing in this plan should be read as declining iOS on technical grounds; it is deferred to a successor with a different scope.
- **Audit item Z-1 — rewriting the M6 documents to a five-platform statement, and a `check_m6_dng_contract.py` enforcing it.** Void with the supersession claim; see the Governance section.
- **Audit ambiguity A-1 — the one-walk `inspectEmbeddedJpeg` refactor.** Out of scope: M6 contract §2.1 deliberately chose the two-call shape, and Task 3 delivers the behaviour the refactor was the vehicle for.

## Decision Log

Append one row per decision as it is made. This is M7's record; the M6 documents are closed and never carry these.

| ID | Decision | Answered by | Date | Consequence |
|---|---|---|---|---|
| G-1 | Per-feature cascade stands; five-platform mandate and supersession claim VOID | USER | 2026-08-24 | No governance gate in this plan; Task 6's manifest is three-platform; iOS out |
| G-2 | Undersized candidate → RAW decode (audit gap 1) | USER | 2026-08-24 | Task 2 wires `minLongEdge: ImageRequestPurpose.preview.targetSize` at the **non-sidebar** call site, for `purpose == preview` only; sidebar and export stay lenient (P-11/P-13); amends the documented fallback rule |
| A-6 | `minLongEdge` fires only for `.dng` on the preview path, not for every RAW format | This plan (Task 2) | 2026-08-24 | The RAW-decode escape hatch at `dart_image_loader.dart:54` is itself gated on `.dng`, so for `.cr2`/`.nef`/`.arw` a `null` becomes `NativeImageFailure('RAW_NO_EMBEDDED_PREVIEW')` rather than RAW decode — the same capability loss the plan already cites to exclude `export`. G-2 says "undersized candidate → RAW decode"; where no RAW decode exists the rule has nothing to deliver and only removes an image the user currently sees |
| A-5 | Scope of G-2 is the preview path, not the sidebar | This plan (Task 2) | 2026-08-24 | Reconciled an inconsistent draft that named `requireLongEdge` on the sidebar branch; `minLongEdge` on the preview branch is authoritative |
| G-3 | Committed fixture corpus declined | USER | 2026-08-24 | Task 1 ships a code-built synthetic-container helper instead |
| G-4 | Visible-render smoke records declined | USER | 2026-08-24 | No smoke-record task; UI observation stays user-run |
| G-5 | iOS FFI superseded by the future general `raw_decoder` effort | USER | 2026-08-24 | Not in M7; platform-port decisions belong to that effort |
| A-1 | One-walk `inspectEmbeddedJpeg` refactor out of scope | This plan (Task 3) | 2026-08-24 | Two-call shape kept per contract §2.1 |
| A-4 | Canonical sample present on this host | Verified | 2026-08-24 | `local_data/photo_samples/DNG/2024-07-03-18-52-26.dng` exists; tasks reading the photo corpus stop and report if it is gone rather than substituting |

## Context carried forward

- **Announced future direction (verbatim):** the `dng_decoder` library will later be upgraded into a general `raw_decoder` supporting ALL RAW formats. Anything in M7 touching decoder packaging (Task 6's manifest) or decoder benchmarking (Task 7's harness) should expect that successor to widen the format set — which is a reason to keep the manifest data-driven and the harness method-stable, both already required above.
- **Open item P-2:** the Linux `.so` for the FFI decoder. Unchanged in status by this plan; Task 6's manifest carries it as `expected: false` so it flips with one boolean.
- **Windows artefacts remain trust-on-first-use** — code changes landed in M6, no real Windows host has run them. Task 6 will report `symbol=skipped` for Windows on a macOS host; that is correct behaviour, not a pass.
- **Still parked:** the Android/iOS end-to-end Open With flow. Task 4 delivers a readable file; folder scanning on mobile (matrix F-02) remains unaddressed.
