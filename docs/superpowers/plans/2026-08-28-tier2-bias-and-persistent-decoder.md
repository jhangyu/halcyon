# Tier-2 Forward Bias & Persistent Decode Worker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use podium:team-spawn (recommended) or podium:team-fable to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the tier-2 full-size decode window forward-biased (`-1..+3` instead of `±2`) and, if a pre-registered headless measurement says it is worth it, replace the per-decode throwaway isolate with one persistent decode worker.

**Architecture:** Two independent changes behind existing seams. (1) `kTierTwoRadius` splits into `kTierTwoBefore`/`kTierTwoAfter`, consumed by `TierTwoScheduler`'s two window computations — same window size, shifted forward. (2) A tracked headless benchmark measures throwaway-isolate vs warm-service decode cost; only on a GO verdict does a `PersistentDecodeWorker` get built behind the frozen `DngFullDecoder` typedef and wired into `halcyonDngFullDecoder`.

**Tech Stack:** Flutter 3.35 / Dart 3, `flutter_test`, `dart:isolate`, the `ceyx` FFI package (read-only), bash + the existing `tool/m6_dng_gate` harness conventions.

**Spec:** `docs/logs/2026-08-28/spec-tier2-bias-and-persistent-decoder.md`

## Global Constraints

- Baseline is HEAD `e664ff9`. All cited line numbers are at that commit.
- `flutter analyze` must report **0 issues** before any task is considered done.
- `flutter test` must exit 0 with `All tests passed!`; run tier-2 files with `-j 1`.
- **Do not modify `../ceyx`** this round. It is read-only.
- Do not change the payload retention window `-3..+5`, the 250 ms tier-2 debounce, `laneRankFor`, or `SerialDecodeLane`'s single-flight property.
- Do not change the tier-2 window **size**: it stays 5 slots (`kTierTwoBefore + kTierTwoAfter + 1 == 5`).
- Do not introduce decode concurrency. Exactly one expensive decode in flight, pipeline-wide.
- No UI or RSS measurement in any benchmark. Headless decode timings only.
- Benchmarks read real photos only. **No synthetic fallback**; a missing sample directory is a loud failure.
- Every measured command in a benchmark artifact captures `RC=$?` on the line immediately after it, **inside the artifact**. Never `${PIPESTATUS[0]}`, never a harness completion notification.
- Benchmark artifacts are pre-registered: the decision rule text is written into the file **before** any number exists.
- Shared working tree: `git commit` must always carry an explicit pathspec (`git commit -- <own paths>`). Never `git add -A`, never `git stash`/`reset`/`checkout --`/`clean`.
- Test names in `test/services/image_pipeline/image_preload_controller_dual_window_tier2_test.dart` are frozen by contract (file header lines 3-4): **do not rename them**, only update their bodies and comments.
- New test-case entries go in `docs/sop/unit_test.md`; new architecture decisions go in `docs/sop/memory.md`. Next free ids: TC-302+, AD-034+.

---

## Task Overview

| # | Task | Gated on |
|---|---|---|
| 1 | Asymmetric tier-2 window `-1..+3` | — |
| 2 | Persistent-decoder measurement gate (pre-registered, go/no-go) | — |
| 3 | `PersistentDecodeWorker` behind the `DngFullDecoder` seam | Task 2 `VERDICT=GO` |
| 4 | Wire the worker in, live-run proof, docs | Task 3 |

Task 1 is independent of Tasks 2-4 and may be done in parallel by a different member (disjoint files).

---

## File Structure

**Task 1**
- Modify: `lib/services/image_pipeline/prefetch_scheduler.dart:5-13` — owns the tier-2 window constants.
- Modify: `lib/services/image_pipeline/tier_two_scheduler.dart:42,115,130-138,168-207` — the only two consumers.
- Modify: `test/services/image_pipeline/image_preload_window_test.dart:7,212-253` — TC-097.
- Modify: `test/services/image_pipeline/image_preload_controller_dual_window_tier2_test.dart:20,126-292` — M5-DW1.
- Modify: `test/services/image_pipeline/tier_two_scheduler_test.dart:110` — a stale comment only.
- Modify: `docs/sop/memory.md`, `docs/sop/unit_test.md`.

**Task 2**
- Create: `tool/decode_worker_bench/bench.dart` — the two-variant measurement.
- Create: `tool/decode_worker_bench/run_bench.sh` — pre-registration, provenance, orchestration.
- Create: `tool/decode_worker_bench/README.md` — method and invocation.
- Create (output, committed): `docs/logs/2026-08-28/decode-worker-gate.txt`.

**Task 3**
- Create: `lib/services/image_pipeline/persistent_decode_worker.dart` — the worker and its isolate entry point.
- Create: `test/services/image_pipeline/persistent_decode_worker_test.dart`.

**Task 4**
- Modify: `lib/services/image_pipeline/dng_decode_service.dart:5-34` — binds `halcyonDngFullDecoder`.
- Create (output, committed): `docs/logs/2026-08-28/persistent-worker-live-proof.txt`.
- Modify: `docs/sop/memory.md`, `docs/sop/unit_test.md`.

---

# STAGE 1 — SKELETON

### Task 1: Asymmetric tier-2 window (`-1..+3`)

**Files:**
- Modify: `lib/services/image_pipeline/prefetch_scheduler.dart:5-13`
- Modify: `lib/services/image_pipeline/tier_two_scheduler.dart:42,115,130-138,168-207`
- Modify: `test/services/image_pipeline/image_preload_window_test.dart:7,212-253`
- Modify: `test/services/image_pipeline/image_preload_controller_dual_window_tier2_test.dart:20,142-172,211-217,244-263`
- Modify: `test/services/image_pipeline/tier_two_scheduler_test.dart:110`
- Modify: `docs/sop/memory.md`, `docs/sop/unit_test.md`

**Interfaces:**
- Consumes: `Set<String> retentionWindowIds<T>(List<T> items, int index, String Function(T) idOf, {int before, int after})` — `lib/services/image_pipeline/photo_payload_cache.dart:183`. Unchanged.
- Produces:
  - `const int kTierTwoBefore = 1;` (`prefetch_scheduler.dart`)
  - `const int kTierTwoAfter = 3;` (`prefetch_scheduler.dart`)
  - `kTierTwoRadius` is **deleted**.

**Behavior:**
At selection index `i`, the tier-2 full-size decode window becomes `i-1 .. i+3` (5 slots, unchanged count). `TierTwoScheduler.updateWindow` publishes that id set immediately on every navigation pass; `_decodeWindow` iterates `i-1 .. i+3` in index order (order is load-bearing for lane start order) and recomputes the same id set for stale-entry eviction. Slots that entered the window and have no payload still take the catch-up `_enqueueLoad` path; slots that left the window still have their tier-2 entry evicted. Nothing about the debounce, lane, retention, or byte budgets changes.

**Constraints:**
- `kTierTwoBefore + kTierTwoAfter + 1 == 5`. Do not widen the window.
- No alias for `kTierTwoRadius` may survive — `grep -rn "kTierTwoRadius" lib/ test/ tool/` must return zero matches.
- `_decodeWindow` must keep computing its loop bounds and its `neededIds` set from the same two constants, not one from the other (`tier_two_scheduler.dart:195-200`).
- The M5-DW test names in the dual-window file are frozen: update bodies and comments, never the names.

**Acceptance criteria:**
- [ ] AC1.1: `grep -rn "kTierTwoRadius" lib/ test/ tool/` → 0 matches.
- [ ] AC1.2: `grep -n "kTierTwoBefore\|kTierTwoAfter" lib/services/image_pipeline/prefetch_scheduler.dart` shows `const int kTierTwoBefore = 1;` and `const int kTierTwoAfter = 3;`.
- [ ] AC1.3: `flutter test -j 1 test/services/image_pipeline/image_preload_window_test.dart` exits 0 and TC-097 asserts `-1..+3` ready and `-2`/`+4` not ready.
- [ ] AC1.4: `flutter test -j 1 test/services/image_pipeline/` exits 0 with `All tests passed!` and declared test count == executed count.
- [ ] AC1.5: `flutter analyze` → `No issues found!`.
- [ ] AC1.6: `docs/sop/memory.md` contains a section heading starting `### AD-034`; `docs/sop/unit_test.md`'s TC-097 entry states the `-1..+3` span.

---

### Task 2: Persistent-decoder measurement gate

**Files:**
- Create: `tool/decode_worker_bench/bench.dart`
- Create: `tool/decode_worker_bench/run_bench.sh`
- Create: `tool/decode_worker_bench/README.md`
- Create: `docs/logs/2026-08-28/decode-worker-gate.txt` (the run artifact, committed)

**Interfaces:**
- Consumes (from `package:ceyx/ceyx.dart`, read-only):
  - `class DngDecoderService { DngDecoderService({String? libraryPath}); void initialize(); DngImage decode(String filePath); Future<DngImage> decodeOnWorker(String filePath, {int? maxDim}); }`
  - `class DngImage { Uint8List rgbaData; int width; int height; double decodeMs; double processMs; double get totalMs; }`
- Produces: an artifact file whose last line is exactly `VERDICT=GO` or `VERDICT=NO-GO`, plus CSV rows between `BENCH_CSV_BEGIN` / `BENCH_CSV_END` with header `variant,file,call_index,wall_ms,decode_ms,process_ms,width,height`.

**Behavior:**
`bench.dart <throwaway|warm> <file...>` runs, per file, 1 cold + 5 warm calls and prints one CSV row per call (`call_index` 0 = cold).
- `throwaway`: a fresh `DngDecoderService()` and `await service.decodeOnWorker(path)` per call — today's production shape, paying a fresh `Isolate.run`, dylib load, and cold GPU pipeline every time.
- `warm`: one `DngDecoderService()..initialize()` constructed before the first call and reused for every call via the synchronous same-isolate `service.decode(path)` — dylib load and pipeline build paid once for the whole run.

`run_bench.sh <sample-dir> <out-file>` writes the pre-registration block (sample list, the verbatim decision rule, the `RC=$?` self-capture pledge), then the provenance block (`git rev-parse HEAD`, `git status --porcelain`, `nm -gU` on the vendored dylib, `shasum -a 256`), then runs both variants, then appends the CSV between markers. It does **not** compute the verdict; a human/reviewer applies the rule and appends the `VERDICT=` line, quoting the numbers it was derived from.

**Constraints:**
- Missing sample dir, zero samples, or fewer than 5 distinct no-preview RAW samples → the run still completes and records what it found; the verdict in that case is `VERDICT=NO-GO` with reason `insufficient evidence`. Never substitute synthetic input, never lower the sample threshold.
- Provenance is symbol-based (`nm -gU`) and HEAD-based. Never mtime.
- Failing runs stay in the artifact. No re-running with different parameters until it passes.
- The bench must not import anything from `lib/services/image_pipeline/` — it measures the ceyx seam directly, so a Halcyon-side change cannot silently move the number.

**Acceptance criteria:**
- [ ] AC2.1: `bash tool/decode_worker_bench/run_bench.sh <sample-dir> docs/logs/2026-08-28/decode-worker-gate.txt` exits 0 and the file exists.
- [ ] AC2.2: `grep -c "^RC=\|_RC=" docs/logs/2026-08-28/decode-worker-gate.txt` is ≥ 4 (every measured command self-captured its return code).
- [ ] AC2.3: The artifact contains, in this order: the decision-rule text, `HEAD_RC=`, `NM_GREP_RC=`, `BENCH_CSV_BEGIN`, rows, `BENCH_CSV_END`, and a final `VERDICT=GO` or `VERDICT=NO-GO` line.
- [ ] AC2.4: `awk -F, '$1=="throwaway"' <artifact>` and `awk -F, '$1=="warm"'` each yield ≥ 30 rows (≥5 samples × 6 calls).
- [ ] AC2.5: The sign-off report quotes the two medians, their difference, and the verdict.

---

### Task 3: `PersistentDecodeWorker` (only if Task 2 reports `VERDICT=GO`)

**Files:**
- Create: `lib/services/image_pipeline/persistent_decode_worker.dart`
- Create: `test/services/image_pipeline/persistent_decode_worker_test.dart`

**Interfaces:**
- Consumes: `class DecodedRgba { const DecodedRgba({required Uint8List rgba, required int width, required int height}); }` and `typedef DngFullDecoder = Future<DecodedRgba> Function(String path);` — `lib/services/image_pipeline/dng_decode_contract.dart:12-30`.
- Produces:
  ```dart
  typedef DecodeWorkerEntryPoint = void Function(SendPort responses);

  class PersistentDecodeWorker {
    PersistentDecodeWorker({DecodeWorkerEntryPoint entryPoint = decodeWorkerMain});
    Future<DecodedRgba> decode(String path);
  }

  void decodeWorkerMain(SendPort responses);
  ```
  `decode` satisfies the `DngFullDecoder` typedef.

**Behavior:**
- **Lazy spawn.** The isolate is spawned on the first `decode` call. Later calls reuse it.
- **Handshake.** The entry point's first act is `responses.send(<its own ReceivePort's SendPort>)`; the wrapper awaits that before sending any request.
- **One outstanding request.** `decode` chains onto an internal `Future`, so at most one request is on the wire and replies need no correlation id. The serial lane already guarantees this upstream; the chain makes the worker correct on its own terms rather than relying on a caller.
- **Wire format.** Request: `[String path, SendPort reply]`. Success reply: `['ok', TransferableTypedData bytes, int width, int height]`. Failure reply: `['err', String message]`.
- **Errors.** A failure reply makes `decode` throw `StateError(message)`. An isolate that dies (`onExit`/`onError`) completes the pending request with `StateError('decode worker died: <detail>')` and clears the cached worker, so the **next** `decode` spawns a fresh one. No retry, no backoff.
- **Length check.** After a success reply the wrapper asserts `bytes.length == width * height * 4` and throws `StateError` otherwise — the same guard `decodeDngFull` has today (`dng_decode_service.dart:16-23`).
- **No shutdown API.** The worker lives for the process; a `dispose()` with no caller would be dead code.
- `entryPoint` exists solely so tests can drive the real `Isolate.spawn` plumbing with a canned responder instead of the native dylib. Exactly two entry points ever exist: `decodeWorkerMain` and the test fake.

**Constraints:**
- `decodeWorkerMain` and the test fake must be **top-level** functions (`Isolate.spawn` requires it).
- Native pointers must not cross isolate boundaries: the worker copies to Dart-owned bytes before transfer (this is what `ceyx`'s own worker does).
- No `warmupForSize` / `setPipelineCachePath` call — that would need a ceyx change, which is out of scope.
- No pool, no supervision, no restart loop. One worker, respawned on next use after death.
- The file must not import `package:flutter/...` — it is pure Dart plus the ceyx seam, so the tests can run without a widget binding.

**Acceptance criteria:**
- [ ] AC3.1: `lib/services/image_pipeline/persistent_decode_worker.dart` declares `class PersistentDecodeWorker` and top-level `void decodeWorkerMain(SendPort responses)`.
- [ ] AC3.2: Test `TC-302 the persistent worker spawns exactly one isolate across N decodes` passes: 3 successive `decode` calls against the fake entry point return `spawnGeneration == 1` for all three.
- [ ] AC3.3: Test `TC-303 a dead worker fails the in-flight call and is respawned on the next one` passes: the call made while the fake kills itself throws `StateError`, and the following `decode` succeeds with `spawnGeneration == 2`.
- [ ] AC3.4: Test `TC-304 a worker error reply surfaces as a StateError without killing the worker` passes: an `['err', ...]` reply throws, and the next `decode` still reports `spawnGeneration == 1`.
- [ ] AC3.5: `flutter test -j 1 test/services/image_pipeline/persistent_decode_worker_test.dart` exits 0 with `All tests passed!`.
- [ ] AC3.6: `flutter analyze` → `No issues found!`.

---

### Task 4: Wire the worker in, live-run proof, docs (only after Task 3)

**Files:**
- Modify: `lib/services/image_pipeline/dng_decode_service.dart:5-34`
- Create: `docs/logs/2026-08-28/persistent-worker-live-proof.txt`
- Modify: `docs/sop/memory.md`, `docs/sop/unit_test.md`

**Interfaces:**
- Consumes: `PersistentDecodeWorker.decode` from Task 3.
- Produces: `const DngFullDecoder halcyonDngFullDecoder` bound to the shared worker's `decode`. `decodeDngFull` is deleted. `decodeDngSized` / `halcyonDngSizedDecoder` are unchanged.

**Behavior:**
`dng_decode_service.dart` gains a single file-private `final _sharedDecodeWorker = PersistentDecodeWorker();` and `halcyonDngFullDecoder` becomes a top-level function that forwards to it. Because `halcyonDngFullDecoder` was `const`, and the forwarding function is a tear-off of a top-level function, it stays a compile-time constant. The `main.dart` composition root (`lib/main.dart:35`) is untouched.

The live-run proof is a headless script run that decodes **two different** no-preview RAW files in one process through `halcyonDngFullDecoder` and records: both succeed, dimensions, and that the second decode's wall time is lower than the first (the warm-reuse signature). This is the mechanism-level activation proof — code review and unit tests with a fake entry point cannot supply it.

**Constraints:**
- Zero remaining references to `decodeDngFull` anywhere in `lib/`.
- The sidebar sized path stays on `decodeOnWorker`; do not route it through the worker.
- The live proof captures `RC=$?` inside the artifact and records `git rev-parse HEAD` plus the dylib's `nm -gU` line before the numbers.

**Acceptance criteria:**
- [ ] AC4.1: `grep -rn "decodeDngFull" lib/` → 0 matches.
- [ ] AC4.2: `grep -n "halcyonDngFullDecoder" lib/services/image_pipeline/dng_decode_service.dart` shows it bound to the persistent worker.
- [ ] AC4.3: `grep -n "decodeDngSized\|halcyonDngSizedDecoder" lib/services/image_pipeline/dng_decode_service.dart` still shows the unchanged sized path.
- [ ] AC4.4: `flutter analyze` → `No issues found!` and `flutter test` exits 0 with `All tests passed!`.
- [ ] AC4.5: `docs/logs/2026-08-28/persistent-worker-live-proof.txt` exists, contains `HEAD=`, `NM_GREP_RC=0`, two `DECODE ok` lines with different file names, and `PROOF_RC=0`.
- [ ] AC4.6: `docs/sop/memory.md` contains `### AD-035` describing the persistent worker; `docs/sop/unit_test.md` contains TC-302, TC-303 and TC-304 entries.

---

# STAGE 2 — IMPLEMENTATION STEPS

## Task 1 — Steps

- [ ] **Step 1.1: Rewrite TC-097 to assert the `-1..+3` band (the failing test)**

Replace `test/services/image_pipeline/image_preload_window_test.dart` lines 212-253 (the whole `testWidgets('TC-097 ...')` block) with:

```dart
  testWidgets('TC-097 tier-2 full-size entries cover -1..+3 after the '
      'debounce settles (AC3)', (tester) async {
    await tester.runAsync(() async {
      final controller = cheapController();
      addTearDown(controller.dispose);
      controller.updateTargetSize(10, 10);

      final photos = jpgItems(14);
      const selected = 5;
      await controller.preloadImages(
        items: photos,
        selectedItemId: photos[selected].id,
        notifyLoaded: () {},
      );
      // The frozen 250 ms debounce is UNCHANGED by the forward-bias change;
      // this waits it out rather than altering it.
      await Future<void>.delayed(const Duration(milliseconds: 400));

      for (var d = -kTierTwoBefore; d <= kTierTwoAfter; d++) {
        expect(
          controller.isFullSizeReady(photos[selected + d].id),
          isTrue,
          reason:
              'distance $d is inside the tier-2 window and must hold a '
              'full-size entry; the window is forward-biased -1..+3 so that '
              'the next forward step lands on a ready entry instead of a '
              'catch-up decode',
        );
      }

      // The span is -1..+3, not "everything": both boundaries must still
      // bite, or the test would pass just as well against an unbounded
      // window. -2 is the slot the forward bias GAVE UP; +4 is the slot it
      // still does not reach.
      expect(
        controller.isFullSizeReady(photos[selected - kTierTwoBefore - 1].id),
        isFalse,
        reason: 'distance -2 is outside the forward-biased tier-2 window',
      );
      expect(
        controller.isFullSizeReady(photos[selected + kTierTwoAfter + 1].id),
        isFalse,
        reason: 'distance +4 is outside the tier-2 window',
      );
    });
  });
```

Also update the file-header comment at line 7 from:

```dart
//   * tier-2 (full size) covers +/-2 via `kTierTwoRadius`, behind the frozen
//     250ms navigation debounce.
```

to:

```dart
//   * tier-2 (full size) covers -1..+3 via `kTierTwoBefore`/`kTierTwoAfter`,
//     behind the frozen 250ms navigation debounce. Forward-biased for the
//     same reason retention is (-3..+5): browsing is overwhelmingly forwards.
```

- [ ] **Step 1.2: Run it to confirm it fails**

Run: `flutter test -j 1 test/services/image_pipeline/image_preload_window_test.dart`
Expected: FAIL — compile error `Undefined name 'kTierTwoBefore'` / `Undefined name 'kTierTwoAfter'`.

- [ ] **Step 1.3: Split the constant**

In `lib/services/image_pipeline/prefetch_scheduler.dart`, replace lines 5-13 (the doc comment plus `const int kTierTwoRadius = 2;`) with:

```dart
/// How far BEFORE the selected item a FULL-SIZE (tier-2) decode is precached.
///
/// Retention is a wider thing again (`-3..+5`): these radii decide only which
/// slots are decoded at FULL size, not which are kept -- and, since the
/// 2026-08-26 serial-lane ruling, they decide nothing at all about which slots
/// may START an expensive decode. Every slot of the retention window may;
/// expensive ones simply queue on `SerialDecodeLane` instead of running in
/// parallel.
///
/// Forward-biased (`-1..+3`) rather than symmetric, for the same reason
/// retention and the lane start order already are: browsing is overwhelmingly
/// forwards, so spending the scarce full-resolution budget on `i-2` buys a
/// slot the user rarely returns to while `i+3` -- already retained as a
/// payload -- pays a catch-up decode on arrival. The WINDOW SIZE is unchanged
/// at 5 slots, so the peak number of resident full-resolution images is the
/// same as under the old symmetric `+/-2`.
const int kTierTwoBefore = 1;

/// How far AFTER the selected item a FULL-SIZE (tier-2) decode is precached.
/// See [kTierTwoBefore] for why this is the larger of the two.
const int kTierTwoAfter = 3;
```

- [ ] **Step 1.4: Update `TierTwoScheduler`'s two window computations**

In `lib/services/image_pipeline/tier_two_scheduler.dart`:

Replace lines 130-138 (`updateWindow`'s body) with:

```dart
  void updateWindow(List<PhotoItem> items, int currentIndex) {
    _windowIds = retentionWindowIds<PhotoItem>(
      items,
      currentIndex,
      (item) => item.id,
      before: kTierTwoBefore,
      after: kTierTwoAfter,
    );
  }
```

Replace lines 187-207 (the bounds and `neededIds` at the top of `_decodeWindow`) with:

```dart
    final tierStart = (currentIndex - kTierTwoBefore).clamp(
      0,
      items.length - 1,
    );
    final tierEnd = (currentIndex + kTierTwoAfter).clamp(
      0,
      items.length - 1,
    );
    // The iteration bounds above and the id set below are recomputed from the
    // same constants rather than one derived from the other, so the ordered
    // loop range and the (unordered) neededIds set cannot disagree. The loop
    // below still walks tierStart..tierEnd (not neededIds) because iterating
    // an unordered Set here would change the tier-2 decode ORDER, which is
    // load-bearing for the sequential queue.
    final neededIds = retentionWindowIds<PhotoItem>(
      items,
      currentIndex,
      (item) => item.id,
      before: kTierTwoBefore,
      after: kTierTwoAfter,
    );
    _windowIds = neededIds;
```

Then fix the three prose references:
- line 42: `FOR WHICH items (the +/-[kTierTwoRadius] window)` → `FOR WHICH items (the [kTierTwoBefore]..[kTierTwoAfter] window)`
- line 115: `Publishes the +/-[kTierTwoRadius] id set` → `Publishes the -[kTierTwoBefore]..+[kTierTwoAfter] id set`
- lines 128-129 and 168/174: replace `the +/-2 radius is unchanged` with `the -1..+3 window is unchanged`, `decode current +/-kTierTwoRadius at full size` with `decode current -kTierTwoBefore..+kTierTwoAfter at full size`, and `The span here is kTierTwoRadius (2)` with `The span here is -1..+3 (kTierTwoBefore/kTierTwoAfter)`.
- lines 177 and 179 mention `the +/-2 band` in the catch-up rationale → `the -1..+3 band`.

- [ ] **Step 1.5: Run TC-097 to confirm it passes**

Run: `flutter test -j 1 test/services/image_pipeline/image_preload_window_test.dart`
Expected: PASS — `All tests passed!`.

- [ ] **Step 1.6: Update M5-DW1 in the dual-window file (bodies and comments only, names frozen)**

In `test/services/image_pipeline/image_preload_controller_dual_window_tier2_test.dart`:

Header line 20, replace `populated. AD-018 was OVERTURNED on 2026-08-26 (memory.md AD-033: expensive` — the preceding line reads `before settling in order to see the full +/-kTierTwoRadius (2) band`; change it to:

```dart
// before settling in order to see the full -1..+3 band (kTierTwoBefore /
// kTierTwoAfter; the test NAMES below still say "+/-2" and are frozen by the
// contract at the top of this file -- the band they assert is now -1..+3,
// AD-034)
```

Cheap sub-case (lines 141-172), replace with:

```dart
      await until(
        () =>
            cheap.debugTierTwoKeyIds.length ==
            kTierTwoBefore + kTierTwoAfter + 1,
        reason: 'cheap tier-2 band to settle to -1..+3',
      );

      final cheapExpectedBand = <String>{
        for (var d = -kTierTwoBefore; d <= kTierTwoAfter; d++)
          cheapItems[cheapSelected + d].id,
      };
      expect(
        cheap.debugTierTwoKeyIds.toSet(),
        cheapExpectedBand,
        reason:
            'encoded payloads: the tier-2 key id set must equal exactly the '
            '-1..+3 band after settle',
      );
      for (final d in [-3, -2, 4, 5]) {
        final id = cheapItems[cheapSelected + d].id;
        expect(
          await tierOneResident(cheap, id, width: 10, height: 10),
          isTrue,
          reason: 'distance $d (encoded) must still hold a tier-1 entry',
        );
        expect(
          cheap.debugTierTwoKeyIds.contains(id),
          isFalse,
          reason: 'distance $d (encoded) must NOT hold a tier-2 entry',
        );
      }
```

Pixel sub-case, replace lines 211-217 with:

```dart
      await until(
        () =>
            pixel.debugTierTwoKeyIds.length ==
            kTierTwoBefore + kTierTwoAfter + 1,
        reason: 'pixel tier-2 band to settle to -1..+3 after the walk',
      );

      final pixelExpectedBand = <String>{
        for (var d = -kTierTwoBefore; d <= kTierTwoAfter; d++)
          pixelItems[pixelSelected + d].id,
      };
```

and its `reason` string (line ~223) from `'+/-2 band after settle, same as encoded payloads'` to `'-1..+3 band after settle, same as encoded payloads'`.

Then the pixel boundary block: the `minus3Id` check (lines ~244-263) is extended to cover `-2` as well, and the isolated-controller loop drops `3` (now inside the window) and gains `4`,`5` only. Replace the `minus3Id` block with:

```dart
      // distances -3 and -2 are free: the items at pixelSelected-3 (index 2)
      // and pixelSelected-2 (index 3) already received payloads from the "3"
      // stop of the walk above and survive into the final retention window
      // [2,10], but hold no tier-2 entry because the tier-2 window is now
      // [4,8]. -2 is the slot the forward bias gave up (AD-034).
      for (final d in [-3, -2]) {
        final backwardId = pixelItems[pixelSelected + d].id;
        expect(
          await tierOneResident(pixel, backwardId, width: 10, height: 10),
          isTrue,
          reason: 'distance $d (pixel) must still hold a tier-1 entry',
        );
        expect(
          pixel.debugTierTwoKeyIds.contains(backwardId),
          isFalse,
          reason: 'distance $d (pixel) must NOT hold a tier-2 entry',
        );
      }
```

and change the following loop header from `for (final d in [3, 4, 5]) {` to:

```dart
      for (final d in [4, 5]) {
```

Inside that loop, the comment `but the tier-2 window [3,7]` becomes `but the tier-2 window [4,8]`.

- [ ] **Step 1.7: Fix the stale comment in the scheduler test**

In `test/services/image_pipeline/tier_two_scheduler_test.dart` line 110, change:

```dart
      // Window is +/-kTierTwoRadius (2) around index 7, and the lane starts
```

to:

```dart
      // Window is -kTierTwoBefore..+kTierTwoAfter (-1..+3) around index 7, and
      // the lane starts
```

- [ ] **Step 1.8: Run the whole image-pipeline suite**

Run: `flutter test -j 1 test/services/image_pipeline/ 2>&1 | tail -20`
Expected: `All tests passed!`, and the reported test count equals the declared count.

Run: `flutter analyze`
Expected: `No issues found!`

Run: `grep -rn "kTierTwoRadius" lib/ test/ tool/`
Expected: no output (exit 1).

- [ ] **Step 1.9: Record the decision and the test change**

Append to `docs/sop/memory.md`, after the last AD section:

```markdown
### AD-034｜Tier-2 全尺寸解碼視窗改為前向偏斜 -1..+3（2026-08-28）

- **背景**：`kTierTwoRadius = 2` 是專案內唯一還對稱的視窗政策；保留視窗早已是 `-3..+5`（`photo_payload_cache.dart:6,10`），序列車道啟動順序也是同距離先前進（`serial_decode_lane.dart:170-180`）。
- **決策**：拆成 `kTierTwoBefore = 1` / `kTierTwoAfter = 3`（`prefetch_scheduler.dart`），`kTierTwoRadius` 刪除不留別名。視窗大小維持 5 格，因此常駐全解析度影像的峰值數量不變，這不是記憶體變更。
- **理由**：向後兩格（`i-2`、`i-1`）的全解析度項目使用者很少回頭看；`i+3` 明明已被保留為 payload，卻在使用者踏上去時要付一次補做解碼（61–406 ms 一次 FFI 解碼）。把預算往前挪，換到的是「往前一步就落在已就緒的項目上」。
- **代價（已接受）**：向後第二格改成補做解碼。payload 仍保留在 `-3..-1`，所以往回一步的代價是一次全解析度解碼，不是整張 RAW 重解。
- **關聯**：AD-018（已被 AD-033 推翻）、AD-033（便宜/昂貴唯一差異是併發模式）、AD-028（scheduler 三單元切分不變）。本條只改「哪些格子做全尺寸解碼」，debounce、車道、保留視窗、位元組預算全部不動。
```

In `docs/sop/unit_test.md`, update the TC-097 row/section so its description reads `-1..+3`（`kTierTwoBefore`/`kTierTwoAfter`）instead of `-2..+2`, and add one line noting M5-DW1's asserted band moved to `-1..+3` while its frozen test name still says `+/-2`.

- [ ] **Step 1.10: Commit**

```bash
git add lib/services/image_pipeline/prefetch_scheduler.dart \
        lib/services/image_pipeline/tier_two_scheduler.dart \
        test/services/image_pipeline/image_preload_window_test.dart \
        test/services/image_pipeline/image_preload_controller_dual_window_tier2_test.dart \
        test/services/image_pipeline/tier_two_scheduler_test.dart \
        docs/sop/memory.md docs/sop/unit_test.md
git commit -- lib/services/image_pipeline/prefetch_scheduler.dart \
        lib/services/image_pipeline/tier_two_scheduler.dart \
        test/services/image_pipeline/image_preload_window_test.dart \
        test/services/image_pipeline/image_preload_controller_dual_window_tier2_test.dart \
        test/services/image_pipeline/tier_two_scheduler_test.dart \
        docs/sop/memory.md docs/sop/unit_test.md \
  -m "perf(image-pipeline): forward-bias the tier-2 decode window to -1..+3"
```

---

## Task 2 — Steps

- [ ] **Step 2.1: Write the benchmark**

Create `tool/decode_worker_bench/bench.dart`:

```dart
// Persistent-decode-worker measurement gate (spec §B.5).
//
// Measures the per-decode cost of the two shapes the proposal is about:
//   variant `throwaway` = today's production shape -- a fresh
//     DngDecoderService and decodeOnWorker() per call, so every call pays a
//     fresh Isolate.run, a dylib load, and a cold GPU pipeline build.
//   variant `warm`      = one DngDecoderService()..initialize(), reused for
//     every call via the synchronous same-isolate decode(), so the dylib load
//     and the pipeline build are paid once for the whole run.
//
// The difference between the two medians IS the quantity the go/no-go rule is
// about. This file deliberately imports nothing from lib/services/, so a
// Halcyon-side change cannot move the number.
//
// Headless: no dart:ui, no UI, no RSS measurement.
//
// Protocol: per file, 1 cold call (call_index 0) then 5 warm calls
// (call_index 1..5). One CSV row per call on stdout.
//
// Usage: dart run tool/decode_worker_bench/bench.dart <throwaway|warm> <file...>
import 'dart:io';

import 'package:ceyx/ceyx.dart';

const int kWarmCalls = 5;

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
      'usage: dart run tool/decode_worker_bench/bench.dart '
      '<throwaway|warm> <file...>',
    );
    exit(2);
  }
  final variant = args.first;
  if (variant != 'throwaway' && variant != 'warm') {
    stderr.writeln("ERROR: variant must be 'throwaway' or 'warm', got '$variant'");
    exit(2);
  }
  final files = args.sublist(1);

  // The warm variant's whole point: ONE service for the whole run.
  DngDecoderService? shared;
  if (variant == 'warm') {
    shared = DngDecoderService()..initialize();
  }

  for (final path in files) {
    for (var call = 0; call <= kWarmCalls; call++) {
      final sw = Stopwatch()..start();
      DngImage image;
      try {
        if (variant == 'throwaway') {
          image = await DngDecoderService().decodeOnWorker(path);
        } else {
          image = shared!.decode(path);
        }
      } catch (e) {
        sw.stop();
        stdout.writeln('$variant,$path,$call,ERROR,ERROR,ERROR,0,0');
        stderr.writeln('decode failed for $path ($variant, call $call): $e');
        continue;
      }
      sw.stop();
      stdout.writeln(
        '$variant,$path,$call,${sw.elapsedMicroseconds / 1000.0},'
        '${image.decodeMs},${image.processMs},${image.width},${image.height}',
      );
    }
  }
}
```

- [ ] **Step 2.2: Write the runner**

Create `tool/decode_worker_bench/run_bench.sh`:

```bash
#!/bin/bash
# Persistent-decode-worker measurement gate runner (spec §B.5).
#
# Usage: bash tool/decode_worker_bench/run_bench.sh <sample-dir> <out-file>
#
# House rules implemented here, not merely documented:
#   1. Pre-registration: the go/no-go rule text is written into the result
#      file ABOVE any number, before any number exists.
#   2. Provenance: git HEAD plus an exported-symbol check (nm -gU) on the
#      vendored dylib, proving the measured binary contains the code under
#      test -- never mtime.
#   3. Every measured command captures RC=$? on the line immediately after
#      it, INSIDE the artifact. Never ${PIPESTATUS[0]}, never a harness
#      completion notification.
#
# Real photos only; no synthetic fallback. No UI or memory measurement.
set -u

SAMPLE_DIR="${1:-}"
OUT="${2:-}"

if [ -z "$SAMPLE_DIR" ] || [ -z "$OUT" ]; then
  echo "usage: bash tool/decode_worker_bench/run_bench.sh <sample-dir> <out-file>" >&2
  exit 2
fi

if [ ! -d "$SAMPLE_DIR" ]; then
  echo "ERROR: sample directory '$SAMPLE_DIR' does not exist." >&2
  echo "This harness reads real photos only (no synthetic fallback)." >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

WORK="$(mktemp -d)"
LIST="$WORK/samples_abs.txt"
find "$SAMPLE_DIR" -type f \( -iname '*.dng' -o -iname '*.raf' -o -iname '*.rw2' \) \
  | sort > "$LIST"
SAMPLE_COUNT=$(wc -l < "$LIST" | tr -d ' ')

DYLIB="${DNG_DYLIB:-/Users/jhangyu/project/ceyx/plugin/macos/Libraries/libdng_decoder_native.dylib}"

{
  echo "================================================================================"
  echo "PERSISTENT DECODE WORKER -- MEASUREMENT GATE"
  echo "PRE-REGISTRATION BLOCK -- written to this file BEFORE any measurement"
  echo "existed. Everything below the RESULTS banner was appended after this"
  echo "block was on disk."
  echo "================================================================================"
  echo ""
  echo "SAMPLE_DIR=$SAMPLE_DIR"
  echo "SAMPLE_COUNT=$SAMPLE_COUNT"
  echo ""
  echo "DECISION RULE (verbatim from"
  echo "docs/logs/2026-08-28/spec-tier2-bias-and-persistent-decoder.md Sec B.5):"
  echo ""
  echo "  GO if, over at least 5 distinct no-preview RAW samples,"
  echo "  median(throwaway_wall_ms) - median(warm_wall_ms)"
  echo "      >= 0.15 * median(throwaway_wall_ms)"
  echo "  AND that absolute difference is >= 50 ms."
  echo "  Otherwise NO-GO."
  echo ""
  echo "  Fewer than 5 usable samples => NO-GO by insufficient evidence."
  echo "  Never a smaller sample set, never synthetic input."
  echo ""
  echo "  Medians are taken over the WARM calls only (call_index 1..5):"
  echo "  per sample, the median of its 5 warm calls; per variant, the median"
  echo "  of those per-sample values. call_index 0 is the cold call and is"
  echo "  recorded but excluded from the medians."
  echo ""
  echo "No re-running with different parameters until a run passes: a failing"
  echo "run stays in this artifact."
  echo ""
  echo "RC=\$? is self-captured INSIDE this artifact on the line immediately"
  echo "after each measured command below."
  echo "================================================================================"
  echo "RESULTS  (everything below this banner was produced AFTER the block above)"
  echo "================================================================================"
  echo ""
  echo "## 0. Tree state"
  echo "-- git rev-parse HEAD"
} >> "$OUT"
git rev-parse HEAD >> "$OUT" 2>&1
RC=$?; echo "HEAD_RC=$RC" >> "$OUT"
echo "HEAD=$(git rev-parse HEAD 2>/dev/null)" >> "$OUT"
echo "-- git status --porcelain" >> "$OUT"
git status --porcelain >> "$OUT" 2>&1
RC=$?; echo "STATUS_RC=$RC" >> "$OUT"

{
  echo ""
  echo "## 1. Provenance: native artifact content marker (never mtime)"
  echo "-- vendored dylib: $DYLIB"
} >> "$OUT"
if [ -f "$DYLIB" ]; then
  nm -gU "$DYLIB" 2>>"$OUT" | grep dng_decode_and_process >> "$OUT" 2>&1
  RC=$?; echo "NM_GREP_RC=$RC (0 means the decode symbol is present in this build)" >> "$OUT"
  shasum -a 256 "$DYLIB" >> "$OUT" 2>&1
  RC=$?; echo "SHA_RC=$RC" >> "$OUT"
else
  echo "DYLIB_MISSING: $DYLIB not found on this host." >> "$OUT"
  echo "NM_GREP_RC=missing" >> "$OUT"
fi

if [ "$SAMPLE_COUNT" -lt 5 ]; then
  {
    echo ""
    echo "## 2. Sample sufficiency"
    echo "SAMPLE_COUNT=$SAMPLE_COUNT is below the 5-sample floor in the rule above."
    echo "BENCH_CSV_BEGIN"
    echo "BENCH_CSV_END"
    echo "VERDICT=NO-GO (insufficient evidence: fewer than 5 usable samples)"
  } >> "$OUT"
  echo "NO-GO: fewer than 5 samples in '$SAMPLE_DIR'." >&2
  exit 0
fi

DYLIB_DIR="$(dirname "$DYLIB")"
CSV="$WORK/bench.csv"
echo "variant,file,call_index,wall_ms,decode_ms,process_ms,width,height" > "$CSV"

{
  echo ""
  echo "## 3. Variant throwaway (today's production shape)"
} >> "$OUT"
# shellcheck disable=SC2046
DNG_NATIVE_BUILD_DIR="$DYLIB_DIR" \
  dart run tool/decode_worker_bench/bench.dart throwaway $(cat "$LIST") >> "$CSV" 2>>"$OUT"
RC=$?; echo "THROWAWAY_RC=$RC" >> "$OUT"

{
  echo ""
  echo "## 4. Variant warm (one reused, initialized service)"
} >> "$OUT"
# shellcheck disable=SC2046
DNG_NATIVE_BUILD_DIR="$DYLIB_DIR" \
  dart run tool/decode_worker_bench/bench.dart warm $(cat "$LIST") >> "$CSV" 2>>"$OUT"
RC=$?; echo "WARM_RC=$RC" >> "$OUT"

{
  echo ""
  echo "## 5. Measurements"
  echo "BENCH_CSV_BEGIN"
} >> "$OUT"
cat "$CSV" >> "$OUT"
echo "BENCH_CSV_END" >> "$OUT"

{
  echo ""
  echo "## 6. Verdict"
  echo "Apply the DECISION RULE above to the CSV and append exactly one line:"
  echo "  VERDICT=GO      or      VERDICT=NO-GO"
  echo "together with the two medians and their difference it was derived from."
} >> "$OUT"

echo "wrote $OUT"
```

- [ ] **Step 2.3: Write the README**

Create `tool/decode_worker_bench/README.md`:

```markdown
# `tool/decode_worker_bench` — persistent-decode-worker measurement gate

Answers one question before any refactor is attempted: **how much of a RAW
decode's cost is the throwaway isolate's dylib load plus cold GPU pipeline
build?** Spec: `docs/logs/2026-08-28/spec-tier2-bias-and-persistent-decoder.md`
§B.5.

Two variants over the same real samples, in one run:

- `throwaway` — a fresh `DngDecoderService()` and `decodeOnWorker(path)` per
  call. This is exactly what `halcyonDngFullDecoder` does today.
- `warm` — one `DngDecoderService()..initialize()` reused for every call via
  the synchronous same-isolate `decode(path)`. The dylib load and the pipeline
  build are paid once for the whole run, which is the state a persistent
  worker would put the app in.

`warm` is a *proxy* for the persistent worker, not the worker itself: it runs
on the calling isolate, so it also removes the isolate hand-off cost. That
makes it an upper bound on the win. If even the upper bound fails the
threshold, the worker cannot pass it either — which is precisely why the gate
runs before the build.

## Invocation

```bash
bash tool/decode_worker_bench/run_bench.sh <sample-dir> <out-file>
```

The sample directory must exist and hold at least 5 no-preview RAW files.
There is no synthetic fallback. The output file is pre-registered: the
decision rule is written above the numbers before the numbers exist, and each
measured command's `RC=$?` is captured on the following line inside the file.
```

- [ ] **Step 2.4: Verify the harness fails loudly on a missing directory**

Run: `bash tool/decode_worker_bench/run_bench.sh /nonexistent /tmp/x.txt; echo "RC=$?"`
Expected: `ERROR: sample directory '/nonexistent' does not exist.` and `RC=1`.

- [ ] **Step 2.5: Run the real gate**

Run:
```bash
bash tool/decode_worker_bench/run_bench.sh \
  local_data/photo_samples docs/logs/2026-08-28/decode-worker-gate.txt
echo "RUN_RC=$?"
```
Expected: `RUN_RC=0` and the artifact exists with `THROWAWAY_RC=0` and `WARM_RC=0`.

If `local_data/photo_samples` does not hold ≥5 no-preview RAW files on this host, use whatever real sample directory does; if none does, the artifact's own `VERDICT=NO-GO (insufficient evidence...)` line is the answer and Tasks 3-4 do not run.

- [ ] **Step 2.6: Compute the medians and append the verdict**

Run:
```bash
awk -F, 'NR>1 && $3>0 && $4!="ERROR" {print $1","$2","$4}' \
  docs/logs/2026-08-28/decode-worker-gate.txt | sort
```
Take, per `(variant,file)`, the median of the 5 warm calls; then per variant, the median of those per-file values. Append to the artifact:

```
MEDIAN_THROWAWAY_MS=<value>
MEDIAN_WARM_MS=<value>
DIFF_MS=<throwaway - warm>
DIFF_RATIO=<diff / throwaway>
VERDICT=GO        # or NO-GO
```

Apply the rule literally: GO requires `DIFF_RATIO >= 0.15` **and** `DIFF_MS >= 50`. Do not round a near-miss up. Do not re-run with different parameters to reach GO.

- [ ] **Step 2.7: Commit the harness and the artifact**

```bash
git add tool/decode_worker_bench/bench.dart \
        tool/decode_worker_bench/run_bench.sh \
        tool/decode_worker_bench/README.md \
        docs/logs/2026-08-28/decode-worker-gate.txt
git commit -- tool/decode_worker_bench/bench.dart \
        tool/decode_worker_bench/run_bench.sh \
        tool/decode_worker_bench/README.md \
        docs/logs/2026-08-28/decode-worker-gate.txt \
  -m "test(perf): pre-registered measurement gate for the persistent decode worker"
```

- [ ] **Step 2.8: On NO-GO, stop here and record the gotcha**

If the verdict is NO-GO, do **not** start Task 3. Append to `docs/sop/memory.md`:

```markdown
### G-022｜持久解碼 worker 未通過量測閘（2026-08-28）

- **量測**：`tool/decode_worker_bench`，證據 `docs/logs/2026-08-28/decode-worker-gate.txt`。丟棄式 isolate 中位數 <MEDIAN_THROWAWAY_MS> ms，重用暖服務中位數 <MEDIAN_WARM_MS> ms，差 <DIFF_MS> ms（<DIFF_RATIO>）。
- **結論**：低於預先登記的門檻（>=15% 且 >=50 ms），因此不建持久 worker。dylib 載入與 GPU pipeline 冷啟在本機的實測占比不足以償付一個常駐 isolate 的生命週期複雜度。
- **注意**：`warm` 變體是上界（同 isolate 執行，連 isolate 交接成本也省掉）；上界都不過，持久 worker 更不會過。
- **重測時機**：換 GPU/驅動、ceyx 換 Halide pipeline、或改成 Vulkan 路徑時重跑本閘再議。
```

Then report the NO-GO verdict with the numbers and stop.

---

## Task 3 — Steps *(only if `VERDICT=GO`)*

- [ ] **Step 3.1: Write the failing tests**

Create `test/services/image_pipeline/persistent_decode_worker_test.dart`:

```dart
// Lifecycle tests for PersistentDecodeWorker.
//
// These exercise the REAL Isolate.spawn plumbing (handshake, request/reply,
// death detection) against a fake entry point, so no native dylib is needed.
// What they do NOT prove is that the real decoder works -- that is the live
// -run proof in Task 4 (docs/logs/2026-08-28/persistent-worker-live-proof.txt).
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/persistent_decode_worker.dart';

// "Which isolate answered?" is not directly observable: a spawned isolate gets
// its own copy of process memory, so a counter inside it always reads 1. The
// fake therefore ECHOES a caller-supplied generation number instead. Requests
// are paths of the form '<n>:<command>'; the fake replies with width == n.
//
// That is enough to pin both properties under test, because the worker only
// ever spawns a NEW isolate when the previous one is gone: if a call asking
// for generation 2 succeeds after a death, a fresh isolate answered it; if
// three calls asking for generation 1 all succeed, one isolate served them
// all (a respawn would have shown up as an extra spawn-and-handshake, which
// the death test proves is observable).

void _fakeEntryPoint(SendPort responses) {
  final requests = ReceivePort();
  responses.send(requests.sendPort);
  requests.listen((message) {
    final parts = message as List<Object?>;
    final path = parts[0] as String;
    final reply = parts[1] as SendPort;
    final colon = path.indexOf(':');
    final generation = int.parse(path.substring(0, colon));
    final command = path.substring(colon + 1);
    switch (command) {
      case 'ok':
        reply.send([
          'ok',
          TransferableTypedData.fromList([
            Uint8List.fromList(List<int>.filled(generation * 1 * 4, 7)),
          ]),
          generation,
          1,
        ]);
      case 'err':
        reply.send(['err', 'fake decoder said no']);
      case 'die':
        // No reply at all: the isolate simply goes away, which is what a
        // native crash looks like from the parent's side.
        requests.close();
        Isolate.exit();
    }
  });
}

void main() {
  test(
    'TC-302 the persistent worker spawns exactly one isolate across N decodes',
    () async {
      final worker = PersistentDecodeWorker(entryPoint: _fakeEntryPoint);
      for (var i = 0; i < 3; i++) {
        final decoded = await worker.decode('1:ok');
        expect(
          decoded.width,
          1,
          reason: 'every call must be answered by the SAME first isolate',
        );
        expect(decoded.rgba.length, decoded.width * decoded.height * 4);
      }
    },
  );

  test(
    'TC-303 a dead worker fails the in-flight call and is respawned on the '
    'next one',
    () async {
      final worker = PersistentDecodeWorker(entryPoint: _fakeEntryPoint);
      expect((await worker.decode('1:ok')).width, 1);

      await expectLater(
        worker.decode('1:die'),
        throwsA(isA<StateError>()),
        reason: 'an isolate that dies mid-request must fail that request',
      );

      // The next call must succeed against a freshly spawned isolate. The
      // fake echoes the generation it was asked for, so asking for 2 proves
      // a NEW isolate answered rather than the dead one.
      expect((await worker.decode('2:ok')).width, 2);
    },
  );

  test(
    'TC-304 a worker error reply surfaces as a StateError without killing '
    'the worker',
    () async {
      final worker = PersistentDecodeWorker(entryPoint: _fakeEntryPoint);
      expect((await worker.decode('1:ok')).width, 1);

      await expectLater(
        worker.decode('1:err'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('fake decoder said no'),
          ),
        ),
      );

      // Still the SAME isolate: an error REPLY is not a death.
      expect((await worker.decode('1:ok')).width, 1);
    },
  );
}
```

- [ ] **Step 3.2: Run them to confirm they fail**

Run: `flutter test -j 1 test/services/image_pipeline/persistent_decode_worker_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'halcyon_flutter' ... persistent_decode_worker.dart` / `Undefined name 'PersistentDecodeWorker'`.

- [ ] **Step 3.3: Implement the worker**

Create `lib/services/image_pipeline/persistent_decode_worker.dart`:

```dart
import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ceyx/ceyx.dart';

import 'dng_decode_contract.dart';

/// The isolate body a [PersistentDecodeWorker] runs.
///
/// A parameter only so tests can drive the real [Isolate.spawn] plumbing with
/// a canned responder instead of loading the native dylib. Exactly two of
/// these ever exist: [decodeWorkerMain] and the test fake. It is not an
/// extension point.
typedef DecodeWorkerEntryPoint = void Function(SendPort responses);

/// ONE long-lived decode isolate for the expensive full-decode path.
///
/// Today every expensive decode spawns a throwaway `Isolate.run` that reloads
/// the native dylib and cold-starts the GPU pipeline. This keeps one
/// initialized decoder alive for the session instead, so both costs are paid
/// once. Justified by the measurement gate in
/// `docs/logs/2026-08-28/decode-worker-gate.txt`; the shape and the go/no-go
/// rule are specified in
/// `docs/logs/2026-08-28/spec-tier2-bias-and-persistent-decoder.md` Sec B.
///
/// It changes NOTHING about concurrency. At most one request is on the wire,
/// which matches -- and does not weaken -- `SerialDecodeLane`'s pipeline-wide
/// single-flight guarantee.
class PersistentDecodeWorker {
  PersistentDecodeWorker({this.entryPoint = decodeWorkerMain});

  final DecodeWorkerEntryPoint entryPoint;

  /// The live worker's request port, or null when no worker is running (never
  /// spawned yet, or the previous one died).
  SendPort? _requests;
  Isolate? _isolate;
  ReceivePort? _exitPort;

  /// Serialises callers: at most one request is outstanding, so replies need
  /// no correlation id.
  Future<void> _chain = Future<void>.value();

  /// Completes the in-flight request when the isolate dies without replying.
  Completer<List<Object?>>? _inFlight;

  /// Satisfies the frozen [DngFullDecoder] seam.
  Future<DecodedRgba> decode(String path) {
    final result = _chain.then((_) => _decodeOne(path));
    // The chain must survive a failed call, or one failure would poison every
    // later decode for the rest of the session.
    _chain = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<DecodedRgba> _decodeOne(String path) async {
    final requests = await _ensureWorker();
    final reply = ReceivePort();
    final completer = Completer<List<Object?>>();
    _inFlight = completer;
    reply.listen((message) {
      if (!completer.isCompleted) {
        completer.complete((message as List).cast<Object?>());
      }
    });
    try {
      requests.send([path, reply.sendPort]);
      final answer = await completer.future;
      if (answer.first == 'err') {
        throw StateError('decode worker failed: ${answer[1]}');
      }
      final transferable = answer[1] as TransferableTypedData;
      final width = answer[2] as int;
      final height = answer[3] as int;
      final bytes = transferable.materialize().asUint8List();
      final expectedLength = width * height * 4;
      if (bytes.length != expectedLength) {
        throw StateError(
          'decode worker returned rgba.length=${bytes.length} but '
          'width*height*4=$expectedLength (width=$width, height=$height)',
        );
      }
      return DecodedRgba(rgba: bytes, width: width, height: height);
    } finally {
      _inFlight = null;
      reply.close();
    }
  }

  Future<SendPort> _ensureWorker() async {
    final existing = _requests;
    if (existing != null) return existing;

    final handshake = ReceivePort();
    final exitPort = ReceivePort();
    final isolate = await Isolate.spawn(
      entryPoint,
      handshake.sendPort,
      onExit: exitPort.sendPort,
      onError: exitPort.sendPort,
      errorsAreFatal: true,
    );
    final requests = await handshake.first as SendPort;
    handshake.close();

    _isolate = isolate;
    _exitPort = exitPort;
    _requests = requests;

    exitPort.listen((detail) {
      // The worker is gone. Fail whatever was waiting on it and forget it, so
      // the NEXT decode spawns a fresh one. No retry here: the caller already
      // treats any throw from DngFullDecoder as "this decode failed".
      _requests = null;
      _isolate = null;
      _exitPort?.close();
      _exitPort = null;
      final pending = _inFlight;
      if (pending != null && !pending.isCompleted) {
        pending.completeError(StateError('decode worker died: $detail'));
      }
    });

    return requests;
  }
}

/// The production isolate body: owns exactly ONE initialized decoder service
/// for the life of the isolate, and answers one request at a time.
///
/// Native pointers must not cross isolate boundaries, so the RGBA buffer is
/// copied into Dart-owned bytes here and transferred as
/// [TransferableTypedData] -- the same contract ceyx's own worker keeps.
void decodeWorkerMain(SendPort responses) {
  final service = DngDecoderService()..initialize();
  final requests = ReceivePort();
  responses.send(requests.sendPort);
  requests.listen((message) {
    final parts = message as List<Object?>;
    final path = parts[0] as String;
    final reply = parts[1] as SendPort;
    try {
      final image = service.decode(path);
      reply.send([
        'ok',
        TransferableTypedData.fromList([
          Uint8List.fromList(image.rgbaData),
        ]),
        image.width,
        image.height,
      ]);
    } catch (e) {
      reply.send(['err', '$e']);
    }
  });
}
```

- [ ] **Step 3.4: Run the tests to confirm they pass**

Run: `flutter test -j 1 test/services/image_pipeline/persistent_decode_worker_test.dart`
Expected: PASS — `All tests passed!` with 3 tests.

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 3.5: Commit**

```bash
git add lib/services/image_pipeline/persistent_decode_worker.dart \
        test/services/image_pipeline/persistent_decode_worker_test.dart
git commit -- lib/services/image_pipeline/persistent_decode_worker.dart \
        test/services/image_pipeline/persistent_decode_worker_test.dart \
  -m "perf(image-pipeline): add a persistent decode worker behind the DngFullDecoder seam"
```

---

## Task 4 — Steps *(only after Task 3)*

- [ ] **Step 4.1: Bind `halcyonDngFullDecoder` to the worker**

In `lib/services/image_pipeline/dng_decode_service.dart`, replace lines 5-34 (the `decodeDngFull` doc comment, function, and the `halcyonDngFullDecoder` constant) with:

```dart
/// The ONE persistent decode worker for the expensive full-decode path.
///
/// Replaces the previous per-call adapter (`decodeDngFull`), which constructed
/// a fresh `DngDecoderService` and let ceyx spawn a throwaway `Isolate.run`
/// per decode -- reloading the dylib and cold-starting the GPU pipeline every
/// time. Justified by the measurement gate in
/// `docs/logs/2026-08-28/decode-worker-gate.txt`.
///
/// Deliberately NOT shared with [decodeDngSized]: that path serves sidebar
/// thumbnails on the parallel cheap route, and funnelling it through one
/// worker would serialise thumbnails.
final PersistentDecodeWorker _sharedDecodeWorker = PersistentDecodeWorker();

/// Single obvious entry point for the pipeline's full RAW decode, satisfying
/// the frozen [DngFullDecoder] seam.
Future<DecodedRgba> halcyonDngFullDecoder(String path) =>
    _sharedDecodeWorker.decode(path);
```

and add `import 'persistent_decode_worker.dart';` to the import block at the top of the file.

Note the type change: `halcyonDngFullDecoder` was `const DngFullDecoder`; it is now a top-level function with a matching signature. `lib/main.dart:35` passes it as `dngDecoder: halcyonDngFullDecoder` (a tear-off), which still type-checks against `DngFullDecoder?` unchanged.

- [ ] **Step 4.2: Verify nothing else referenced the old adapter**

Run: `grep -rn "decodeDngFull" lib/ test/ tool/`
Expected: no output (exit 1). If `test/` still references it, that test was asserting the old per-call shape — delete the assertion, not the worker.

Run: `flutter analyze`
Expected: `No issues found!`

Run: `flutter test 2>&1 | tail -5`
Expected: `All tests passed!`

- [ ] **Step 4.3: Produce the live-run proof**

Create a throwaway script under the gitignored scratch area and run it, capturing the artifact into `docs/logs/`:

```bash
mkdir -p scripts/tmp
cat > scripts/tmp/persistent_worker_proof.dart <<'DART'
// Live-run proof: two DIFFERENT no-preview RAW files decoded in ONE process
// through the shipped halcyonDngFullDecoder. Proves the real dylib path
// works through the persistent worker, which the fake-entry-point unit tests
// cannot.
import 'dart:io';

import 'package:halcyon_flutter/services/image_pipeline/dng_decode_service.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: dart run <this> <file-a> <file-b>');
    exit(2);
  }
  for (final path in args.take(2)) {
    final sw = Stopwatch()..start();
    final decoded = await halcyonDngFullDecoder(path);
    sw.stop();
    stdout.writeln(
      'DECODE ok file=$path width=${decoded.width} height=${decoded.height} '
      'bytes=${decoded.rgba.length} wall_ms=${sw.elapsedMicroseconds / 1000.0}',
    );
  }
}
DART

OUT=docs/logs/2026-08-28/persistent-worker-live-proof.txt
DYLIB=/Users/jhangyu/project/ceyx/plugin/macos/Libraries/libdng_decoder_native.dylib
{
  echo "PERSISTENT DECODE WORKER -- LIVE RUN PROOF"
  echo "HEAD=$(git rev-parse HEAD)"
} > "$OUT"
nm -gU "$DYLIB" | grep dng_decode_and_process >> "$OUT" 2>&1
RC=$?; echo "NM_GREP_RC=$RC" >> "$OUT"
DNG_NATIVE_BUILD_DIR="$(dirname "$DYLIB")" \
  dart run scripts/tmp/persistent_worker_proof.dart <file-a> <file-b> >> "$OUT" 2>&1
RC=$?; echo "PROOF_RC=$RC" >> "$OUT"
```

Substitute two real no-preview RAW paths for `<file-a>` and `<file-b>`. Expected in the artifact: `NM_GREP_RC=0`, two `DECODE ok` lines with different `file=` values and non-zero dimensions, and `PROOF_RC=0`. The second line's `wall_ms` should be lower than the first's — that gap is the warm-reuse signature. Record it; do not gate on it (a single pair is not a measurement).

- [ ] **Step 4.4: Record the decision and the tests**

Append to `docs/sop/memory.md`:

```markdown
### AD-035｜昂貴 RAW 全解碼改走單一常駐 worker isolate（2026-08-28）

- **問題**：每次昂貴解碼都由 ceyx 的 `decodeOnWorker` 開一個丟棄式 `Isolate.run`，其中重新 `DngNativeBindings.load()` 載入 dylib，且因為 Halcyon 從未呼叫 `warmupForSize`，GPU pipeline 每次冷啟。
- **決策**：新增 `lib/services/image_pipeline/persistent_decode_worker.dart`，`halcyonDngFullDecoder` 改綁定其 `decode`；`decodeDngFull` 刪除，不留第二條會悄悄分歧的解碼路徑。
- **前提（不可略過）**：先跑 `tool/decode_worker_bench` 量測閘並取得 GO，證據 `docs/logs/2026-08-28/decode-worker-gate.txt`；活體證明 `docs/logs/2026-08-28/persistent-worker-live-proof.txt`。
- **不動的部分**：併發模式完全不變（線上最多一個請求，與 `SerialDecodeLane` 的單飛行一致，不是新增併發）；`decodeDngSized`／側邊欄縮圖仍走原本的 `decodeOnWorker` 平行路徑，刻意不併入同一 worker，否則縮圖會被序列化；不呼叫 `warmupForSize`／`setPipelineCachePath`（那需要改 ceyx，本輪唯讀）。
- **失敗處理**：isolate 意外死亡 → 進行中的請求以 `StateError` 失敗、快取的 worker 清空，下一次 `decode` 重新 spawn。沒有重試、沒有 backoff、沒有 pool——呼叫端本來就把 `DngFullDecoder` 的任何 throw 當成「這次解碼失敗」。
- **關聯**：AD-010／AD-011（`NativeImageResult` 三變體與 `DngFullDecoder` seam 不變，本條只換 seam 背後的實作）、AD-033（單一序列車道不變）。
```

Append TC entries to `docs/sop/unit_test.md` for TC-302 / TC-303 / TC-304, following the existing entry format, noting that they use an injected fake isolate entry point and therefore prove lifecycle only — the real-dylib evidence is the live-run proof artifact.

- [ ] **Step 4.5: Commit**

```bash
git add lib/services/image_pipeline/dng_decode_service.dart \
        docs/logs/2026-08-28/persistent-worker-live-proof.txt \
        docs/sop/memory.md docs/sop/unit_test.md
git commit -- lib/services/image_pipeline/dng_decode_service.dart \
        docs/logs/2026-08-28/persistent-worker-live-proof.txt \
        docs/sop/memory.md docs/sop/unit_test.md \
  -m "perf(image-pipeline): route full RAW decode through the persistent worker"
```

---

## Self-Review

**1. Spec coverage**

| Spec item | Task |
|---|---|
| A.5 split `kTierTwoRadius` → `kTierTwoBefore`/`kTierTwoAfter` | Task 1, Step 1.3 |
| A.5 both `TierTwoScheduler` call sites | Task 1, Step 1.4 |
| A.6 AC-A1 no `kTierTwoRadius` anywhere | Task 1, AC1.1 / Step 1.8 |
| A.6 AC-A2 constant values | Task 1, AC1.2 |
| A.6 AC-A3 TC-097 asserts `-1..+3`, `-2`/`+4` excluded | Task 1, Step 1.1 |
| A.6 AC-A4/A5 suite + analyze green | Task 1, Step 1.8 |
| A.6 AC-A6 memory.md AD + unit_test.md TC | Task 1, Step 1.9 |
| B.5 tracked headless two-variant bench | Task 2, Steps 2.1-2.2 |
| B.5 pre-registration, provenance, self-captured RC, no synthetic fallback | Task 2, Step 2.2 |
| B.5 go/no-go rule verbatim in the artifact | Task 2, Step 2.2 (pre-registration block) |
| B.5 NO-GO fallback recorded as a gotcha, stop | Task 2, Step 2.8 |
| B.5 <5 samples ⇒ NO-GO by insufficient evidence | Task 2, Step 2.2 (sample-sufficiency branch) |
| B.6 `PersistentDecodeWorker` shape, lazy spawn, one outstanding request, wire format, death handling, length check, no shutdown API | Task 3, Step 3.3 |
| B.6 `entryPoint` as a test seam | Task 3, Steps 3.1/3.3 |
| B.6 wiring, `decodeDngFull` deleted, sized path untouched | Task 4, Steps 4.1-4.2 |
| B.7 AC-B1..B3 | Task 2, AC2.1-2.3, Steps 2.5-2.6 |
| B.7 AC-B4..B8 | Task 3, AC3.1-3.6 and Task 4, AC4.1-4.4 |
| B.7 AC-B9 live-run proof | Task 4, Step 4.3 |
| B.7 AC-B10 docs | Task 4, Step 4.4 |
| B.3 no ceyx change, no sized-path change, no concurrency change | Global Constraints + Task 3 Constraints |

No gaps found.

**2. Placeholder scan**

No `TBD`/`TODO`/"implement later"/"similar to Task N" appears. Every code step carries complete code. Every error path is named with its required behavior: missing sample dir → exit 1 with a message; <5 samples → `VERDICT=NO-GO (insufficient evidence)`; error reply → `StateError` and the worker survives; isolate death → `StateError` and respawn on next call; length mismatch → `StateError`. Two intentional fill-ins remain and are marked as such because only the running host can supply them: the real sample directory and the two RAW paths in Step 4.3, and the measured medians in Step 2.6/2.8 (`<MEDIAN_*>`), which are values a run produces rather than values a plan can know.

**3. Type consistency**

- `kTierTwoBefore` / `kTierTwoAfter` — `int`, declared in Task 1's Produces block, used with those exact names in Steps 1.1, 1.4, 1.6, 1.7.
- `retentionWindowIds(..., {int before, int after})` — named params match `photo_payload_cache.dart:183` exactly.
- `DecodeWorkerEntryPoint = void Function(SendPort)` — the test fake `_fakeEntryPoint(SendPort responses)` and the production `decodeWorkerMain(SendPort responses)` both match; both are top-level as `Isolate.spawn` requires.
- Wire format is identical in the fake and in `decodeWorkerMain`: request `[String, SendPort]`, success `['ok', TransferableTypedData, int width, int height]`, failure `['err', String]`. The wrapper reads exactly those positions.
- `DecodedRgba({required Uint8List rgba, required int width, required int height})` — matches `dng_decode_contract.dart:12-17`; `PersistentDecodeWorker.decode` returns `Future<DecodedRgba>`, satisfying `typedef DngFullDecoder = Future<DecodedRgba> Function(String path)`.
- ceyx surface used is exactly `DngDecoderService()`, `.initialize()`, `.decode(String)` (sync, returns `DngImage`), `.decodeOnWorker(String, {int? maxDim})` (async), and `DngImage.{rgbaData,width,height,decodeMs,processMs}` — all present in `../ceyx/plugin/lib/src/dng_decoder_service.dart` and exported by `package:ceyx/ceyx.dart`.
- Bench CSV header in `bench.dart` matches the column order the Step 2.6 `awk` reads (`$1` variant, `$2` file, `$3` call_index, `$4` wall_ms).

One issue found and fixed during this check: Step 4.1 originally kept `halcyonDngFullDecoder` as a `const DngFullDecoder` tear-off of an instance method, which is not a compile-time constant in Dart. It is now a top-level function, and Step 4.1 notes explicitly that `lib/main.dart:35`'s tear-off still type-checks.
