# Round 1 — Preload Squad (Plan A) Handoff

Date: 2026-08-16
Squad: preload (preload-lead-opus, preload-impl-1-sonnet, preload-test-haiku)
Contract: docs/logs/2026-08-16/plan-image-switch-latency-A-C.md
Status: COMPLETE — signed off by orchestrator.

## 1. Completed work + evidence

**Commit `e64b7aa`** — `perf(preload): parallelize preview window loading with current-image priority`
Parent `adfa624` (native squad). Exactly two files, 70 insertions / 1 deletion:
- `lib/services/image_preload_controller.dart` (4 lines changed)
- `test/image_preload_controller_test.dart` (+67)

### Change
`ImagePreloadController.preloadImages` previously loaded the 9-item preview window with a sequential per-item `await` loop — each neighbour blocked the next. Now:
1. The currently selected item is still awaited first, with `notifyLoaded` fired as before (current-image priority preserved).
2. The remaining window items are collected into a `pendingLoads` list in a single synchronous loop pass, then dispatched together via `await Future.wait(pendingLoads)`.

Preserved unchanged: `_loadingKeys` dedup, `_imageCache` window eviction (`removeWhere`), `neededIds` computation, `notifyLoaded: null` for neighbours, early returns for empty list / index -1, and `preloadThumbnails`.

**Why dedup still holds:** `_loadPreview` performs its `_imageCache`/`_loadingKeys` guard check and `_loadingKeys.add` synchronously, before its first `await`. Because all neighbour futures are created in one synchronous loop pass with no `await` between iterations, no interleaving window opens between guard and add.

### Tests
`test/image_preload_controller_test.dart`, 2 tests:
- `preloadImages evicts preview cache entries outside the sliding window` (pre-existing, untouched)
- `preloadImages loads the selected item first, then the rest of the window concurrently` (new)

The new test uses a fake loader handing out a per-path `Completer<Uint8List?>` and records request order. It asserts: request order is exactly `[selectedPath]` before the selected item completes; then, after completing ONLY the selected completer and pumping microtasks, all 9 window paths have been requested while no neighbour completer has resolved; finally all completers resolve and every window index is cached.

**Discriminating power:** under the old sequential loop, after completing only the selected completer the recorded request list would hold 2 entries, not 9 — the assertion fails. The test genuinely detects a regression to sequential loading.

### Evidence files
- `tmp/verify/preload-signoff.txt` — declared-test census, targeted single-file run (2/2), full-suite run, and a post-commit hash-bound run at HEAD `e64b7aa` with worktree confirmed clean for owned files (tested content == committed content).
- `tmp/verify/postcommit-gate-1786853371.txt` — post-commit gate at HEAD `7c33194331808b540bce73e2da728e47f1b13c3f`, `dart_test.yaml` (`timeout: 10s`) captured in-file, `+14: All tests passed!`, `EXIT: 0`, zero timeouts.

Final chain: `af2e73f` (baseline) → `adfa624` (native, Plan C) → `e64b7aa` (preload, Plan A) → `7c33194` (10s test timeout policy).

Independent review: CONFIRMED by a fresh opus reviewer, mutation-tested.

## 2. Known limitations

- **Unbounded concurrency.** All 8 neighbours are dispatched at once with no concurrency cap. On the current 9-item window against a local native decoder this is the intended win. If the window is ever widened, or the loader is pointed at a slow/remote/rate-limited source, this becomes a thundering herd and will need a semaphore or batch size. Deliberate: no limiter was added for 8 local requests.
- **No cancellation.** Rapid navigation dispatches a new window before the previous one settles; in-flight loads for items that have since left the window still run to completion and are simply discarded by eviction. Wasted work, not incorrect behaviour. Unchanged from before this round.
- **Priority is ordering-at-dispatch, not scheduling.** The current image is requested and awaited first, but once neighbours are in flight the platform channel decides completion order. There is no priority queue underneath.
- **Measured end-user latency was not quantified.** Acceptance was structural (concurrent dispatch proven by test) plus green suite. No before/after timing was captured.
- `preloadThumbnails` still uses a sequential `await` loop. Out of scope this round; same parallelization would likely apply.

## 3. Interface contracts

None. The two squads' file sets were fully disjoint (`lib/services/image_preload_controller.dart` + `test/image_preload_controller_test.dart` vs `macos/Runner/AppDelegate.swift`) with no shared types or call-site changes. `ImagePreloadController`'s public API, the `ImageBytesLoader` typedef, and `_loadPreview`'s signature are all unchanged, so no caller required updating.

## 4. Next-round notes

Plan A and Plan C both landed; no round 2 planned. If work resumes here:

- Parallelizing `preloadThumbnails` the same way is the obvious next increment.
- Consider capping concurrency before widening the preview window.
- Contract items explicitly parked by the user remain parked: Plan B (low-res fallback / spinner flash), Plan D (bytes LRU cache), HEIC/PNG preview downsampling, RAW decode optimization, the empty Android `MainActivity.kt` handler, and `targetSize=10000` tuning.

### Parking-lot from this round (verbatim, not acted on)

- The reporter-nondeterminism trap: any future AC that says "grep the test artifact for a filename" is invalid for flutter test. Evidence standard should be exit code + total count vs declared count.
- test/photo_file_actions_test.dart and lib/services/trash_service.dart are UNTRACKED in the tree (pre-existing, not ours). photo_file_actions_test.dart executes in the suite but is not under version control — worth someone deciding whether to commit it.
- `flutter test` output shows app_state_test's "uses semantic image request purposes..." name repeatedly; likely a shared-name group, harmless, but noted.

### Process note worth carrying forward

A PASS was reported on an artifact that did not contain our test file, and the follow-up correctly came back BLOCKED. Root cause was neither: `flutter test`'s live reporter overwrites fast lines and runs suites concurrently, so which filenames appear in captured output is nondeterministic. The valid mechanical check is **declared test count (`grep -cE '^\s*(test|testWidgets)\(' test/*_test.dart`) == executed count in the final tally, plus exit code 0.** Refusing to claim PASS on unsubstantiated evidence was the correct call and should stay the norm.
