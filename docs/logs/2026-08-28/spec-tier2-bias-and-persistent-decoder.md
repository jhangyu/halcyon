# Spec — Tier-2 forward bias & persistent decode worker

Date: 2026-08-28 · Baseline HEAD: `e664ff9` · Author: spec-perf12-opus (team `spec-plans`)
Source: `docs/logs/2026-08-28/perf-review-report.md` proposals 1 and 2,
`docs/logs/2026-08-28/perf-review-concurrency.md`.
Companion plan: `docs/superpowers/plans/2026-08-28-tier2-bias-and-persistent-decoder.md`.

The two proposals are **independent**. They touch disjoint files, have disjoint
acceptance criteria, and can be implemented, reviewed and reverted separately.
Section A can ship even if section B is abandoned at its measurement gate.

---

## A. Forward-bias the tier-2 full-size decode window

### A.1 Goal

Spend the scarce full-resolution (tier-2) decode budget on the slots a
forward-browsing user is about to reach, instead of splitting it evenly across
slots behind and ahead. Concretely: replace the symmetric `±2` tier-2 window
with an asymmetric `-1..+3` window of the **same size** (5 slots).

### A.2 In scope

- Split `kTierTwoRadius` into `kTierTwoBefore` / `kTierTwoAfter`.
- Update the two `TierTwoScheduler` call sites that derive the tier-2 window.
- Update the existing tests that assert the symmetric band.
- Record the decision in `docs/sop/memory.md` and the test-case matrix in
  `docs/sop/unit_test.md`.

### A.3 Out of scope

- The payload retention window `-3..+5` (`kRetentionBefore` / `kRetentionAfter`,
  `lib/services/image_pipeline/photo_payload_cache.dart:6,10`) — unchanged.
- The 250 ms tier-2 navigation debounce — unchanged.
- The serial-lane start order and `laneRankFor` — unchanged.
- Any change to the tier-2 window **size** (it stays 5 slots, so the peak number
  of resident full-resolution `ui.Image` entries is unchanged).
- The byte budgets `kPayloadByteBudget` / `imageCacheBudgetBytes`.

### A.4 Current behavior (evidence at HEAD `e664ff9`)

| Fact | Location |
|---|---|
| Tier-2 window is one symmetric constant, value 2 | `lib/services/image_pipeline/prefetch_scheduler.dart:13` |
| The immediate window publish uses it symmetrically | `lib/services/image_pipeline/tier_two_scheduler.dart:130-138` |
| The debounced sweep recomputes the same symmetric bounds and id set | `lib/services/image_pipeline/tier_two_scheduler.dart:187-207` |
| `retentionWindowIds` already takes independent `before`/`after` | `lib/services/image_pipeline/photo_payload_cache.dart:183-194` |
| Retention is already forward-biased `-3..+5` | `lib/services/image_pipeline/photo_payload_cache.dart:6,10` |
| Lane start order is already forward-first at equal distance | `lib/services/image_pipeline/serial_decode_lane.dart:170-180` |
| Cost of a catch-up full-res decode when a slot has no tier-2 entry | `lib/services/image_pipeline/tier_two_scheduler.dart:248-254` (61–406 ms, one FFI decode) |
| Tests that assert the symmetric band | `test/services/image_pipeline/image_preload_window_test.dart:230,244,249`; `test/services/image_pipeline/image_preload_controller_dual_window_tier2_test.dart:145,150,212,217` |

So today, at selection index `i`, slots `i-2` and `i-1` hold full-resolution
entries the forward-browsing user rarely returns to, while `i+3` — already
retained as a payload by the `-3..+5` rule — has no tier-2 entry and pays a
catch-up FFI decode the moment the user steps onto it.

### A.5 Proposed design

Replace the single constant with two, in the same file and with the same
doc-comment ownership:

```dart
/// Slots BEFORE the selection that get a FULL-SIZE (tier-2) decode.
const int kTierTwoBefore = 1;

/// Slots AFTER the selection that get a FULL-SIZE (tier-2) decode.
/// Asymmetric for the same reason retention is: browsing is overwhelmingly
/// forwards.
const int kTierTwoAfter = 3;
```

`TierTwoScheduler.updateWindow` and `TierTwoScheduler._decodeWindow` pass
`before: kTierTwoBefore, after: kTierTwoAfter`; `_decodeWindow`'s iteration
bounds become `currentIndex - kTierTwoBefore` .. `currentIndex + kTierTwoAfter`.
Nothing else changes: the loop still walks index order (load-bearing for lane
start order, `tier_two_scheduler.dart:195-200`), `pendingUpgrades` is still
sorted by `laneRankFor`, and stale-id eviction still uses the recomputed
`neededIds`.

Why `-1..+3` and not `0..+4`: keeping one backward slot preserves the
single-step "oops, back one" case at full resolution, which is the only
backward move that is common. Why not widen to `-2..+3` (6 slots): that would
raise the peak resident full-resolution image count by one, which is a memory
change, and this proposal is deliberately budget-neutral.

`kTierTwoRadius` is **removed**, not kept as an alias — a leftover alias would
let a future call site silently reintroduce a symmetric window.

### A.6 Acceptance criteria (mechanically checkable)

- [ ] AC-A1: `grep -rn "kTierTwoRadius" lib/ test/ tool/` returns zero matches.
- [ ] AC-A2: `lib/services/image_pipeline/prefetch_scheduler.dart` declares
  `const int kTierTwoBefore = 1;` and `const int kTierTwoAfter = 3;`.
- [ ] AC-A3: `TC-097` in
  `test/services/image_pipeline/image_preload_window_test.dart` (rewritten from
  the `-2..+2` version) asserts that after settle at index `i`, slots `i-1`
  through `i+3` are full-size ready and that `i-2` and `i+4` are **not**.
- [ ] AC-A4: `flutter test test/services/image_pipeline/` exits 0 with
  `All tests passed!` and declared test count == executed count.
- [ ] AC-A5: `flutter analyze` reports 0 issues.
- [ ] AC-A6: `docs/sop/unit_test.md` contains a TC entry for the new test, and
  `docs/sop/memory.md` contains a new AD entry recording the asymmetric window.

### A.7 Risks

| Risk | Mitigation |
|---|---|
| Existing tests iterate `-kTierTwoRadius..+kTierTwoRadius` and will fail | They are updated in the same task; failure before the update is the TDD red step. |
| `i+3` is at the retention window's `+5` edge minus 2 — a tier-2 slot with no payload triggers the catch-up `_enqueueLoad` path | Already the existing behavior for any window slot without a payload (`tier_two_scheduler.dart:213-229`); the widened forward reach only makes it happen at `+3` instead of at `+2`. |
| Rapid backward browsing now pays a catch-up decode at `-2` | Accepted, and explicitly the trade this proposal makes; the payload is still retained at `-3..-1`, so a backward step costs one full-res decode, not a full RAW re-decode. |

---

## B. Persistent decode worker (measure first)

### B.1 Goal

Stop paying the dylib load and the GPU pipeline cold start on **every** RAW
decode. Route the expensive full-decode path through one long-lived decode
isolate that keeps an initialized `DngDecoderService` alive for the session —
**but only if a headless measurement proves the per-decode start-up share is
worth removing.**

### B.2 In scope

1. A tracked headless benchmark that measures, on real no-preview RAW samples,
   the per-decode cost of the current throwaway-isolate path versus a
   warm-reused service, and reports the `decodeMs` / `processMs` split.
2. A pre-registered go/no-go rule evaluated against that measurement.
3. **If GO:** a Halcyon-side `PersistentDecodeWorker` behind the existing frozen
   `DngFullDecoder` seam (`lib/services/image_pipeline/dng_decode_contract.dart:30`),
   wired in at `halcyonDngFullDecoder`.

### B.3 Out of scope

- Any change to `../ceyx` (read-only this round). No new ceyx API, no
  `warmupForSize` / `setPipelineCachePath` call — the persistent isolate warms
  the process-global native state implicitly on its first decode, which is the
  entire mechanism under test.
- The sized/sidebar path `decodeDngSized` / `halcyonDngSizedDecoder`
  (`lib/services/image_pipeline/dng_decode_service.dart:41-62`). It runs on the
  parallel cheap path; funnelling it through one worker would serialize sidebar
  thumbnails and is a behavior change this proposal does not want.
- Concurrency changes of any kind. Exactly one expensive decode stays in flight
  (`serial_decode_lane.dart:54-62`); the worker does not add a second.
- UI-side or RSS measurement (project rule: the user measures UI performance
  himself; agent benchmarks are headless decode timings only — see
  `tool/m6_dng_gate/README.md` and `run_gate.sh`'s "No UI or memory
  measurement (C-6)").

### B.4 Current behavior (evidence at HEAD `e664ff9`)

| Fact | Location |
|---|---|
| Halcyon's full-decode seam is a bare `typedef` returning `DecodedRgba` | `lib/services/image_pipeline/dng_decode_contract.dart:12-30` |
| The production adapter constructs a fresh `DngDecoderService` per call and calls `decodeOnWorker` | `lib/services/image_pipeline/dng_decode_service.dart:12-34` |
| `decodeOnWorker` spawns a **fresh** `Isolate.run` per call | `../ceyx/plugin/lib/src/dng_decoder_service.dart` `decodeOnWorker` |
| That isolate constructs `DngDecoderService(...)..initialize()`, reloading the dylib | `../ceyx/plugin/lib/src/dng_decoder_service.dart` `_decodeFileToTransferable` |
| Timing split is exposed as `DngImage.decodeMs` (CPU DNG-SDK) + `processMs` (GPU Halide) | `../ceyx/plugin/lib/src/dng_decoder_service.dart` `DngImage` |
| Warm-up / pipeline-cache seams exist and are never called from `lib/` | `warmupForSize`, `setPipelineCachePath`, `pipelineCacheStatus` in `dng_decoder_service.dart`; `grep -rn "warmupForSize\|setPipelineCachePath" lib/` → 0 matches |
| The decode is already single-flight pipeline-wide | `lib/services/image_pipeline/serial_decode_lane.dart:54-62,120-138`; `lib/services/image_pipeline/image_preload_controller.dart:92-97` |
| Precedent for a tracked, pre-registered, provenance-stamped headless gate | `tool/m6_dng_gate/run_gate.sh`, `tool/m6_dng_gate/README.md` |

### B.5 Measurement gate (mandatory, before any worker code)

A new tracked benchmark `tool/decode_worker_bench/` measures two variants over
the same real sample set, in one process, headless:

- **variant `throwaway`** — today's production shape: for each decode, a fresh
  `DngDecoderService()` and `decodeOnWorker(path)` (fresh `Isolate.run`, dylib
  reload, cold pipeline).
- **variant `warm`** — a single `DngDecoderService()..initialize()` reused for
  every decode via the same-isolate `decodeFile`-style entry point, so the
  dylib load and pipeline build are paid exactly once for the whole run.

Protocol, matching the house harness (`tool/m6_dng_gate`): the sample directory
is a required argument and there is **no synthetic fallback**; the result file
records git HEAD and an `nm -gU` exported-symbol check of the vendored dylib
above any number; the verdict rule text is written into the artifact **before**
the numbers exist; each measured command's `RC=$?` is captured on the line
immediately after it, inside the artifact.

Reported per sample: wall-clock ms per decode, plus `decodeMs` and `processMs`
as returned by the decoder. Per-variant metric = median over the samples of
(per-sample median of 5 measured decodes), first decode of each variant recorded
separately as the cold one.

**Pre-registered go/no-go rule:**

> **GO** if, over at least 5 distinct no-preview RAW samples,
> `median(throwaway_wall_ms) - median(warm_wall_ms) >= 0.15 * median(throwaway_wall_ms)`
> **and** that absolute difference is `>= 50 ms`.
> Otherwise **NO-GO**.

**NO-GO fallback (explicit, not a failure):** stop. Do not build the persistent
worker. Record the measured numbers and the NO-GO verdict in the artifact and in
`docs/sop/memory.md` as a gotcha ("the throwaway isolate costs <15% / <50 ms per
decode; a persistent worker is not worth the lifecycle complexity"). Proposal A
is unaffected and stands alone.

If fewer than 5 usable no-preview RAW samples are available on the machine, the
result is **NO-GO by insufficient evidence** — never a smaller sample set, never
synthetic input.

### B.6 Proposed design (only if GO)

New file `lib/services/image_pipeline/persistent_decode_worker.dart`:

```dart
/// One long-lived decode isolate. The dylib loads once and the GPU pipeline
/// warms once per session instead of once per RAW.
class PersistentDecodeWorker {
  PersistentDecodeWorker({void Function(SendPort) entryPoint = decodeWorkerMain});

  /// Satisfies the frozen [DngFullDecoder] seam.
  Future<DecodedRgba> decode(String path);
}

/// Top-level isolate entry point. Owns exactly one initialized
/// `DngDecoderService` and answers one request at a time.
void decodeWorkerMain(SendPort responses);
```

Shape and rationale:

- **One outstanding request.** Calls are chained on an internal `Future`, so at
  most one request is on the wire and responses need no correlation id. This is
  not a new constraint: the serial lane already guarantees one expensive decode
  in flight (`serial_decode_lane.dart:54-62`).
- **Lazy spawn.** The isolate is spawned on the first `decode` call, not at app
  start, so a session that never opens a RAW pays nothing.
- **Wire format.** Request: `(String path, SendPort reply)`. Success reply:
  `(TransferableTypedData bytes, int width, int height)`. Failure reply:
  `(String message)`. The worker copies to Dart-owned bytes before transfer,
  exactly as ceyx's worker does today — native pointers must not cross isolate
  boundaries.
- **Death handling.** The wrapper listens on the isolate's `onExit`/`onError`
  ports; an unexpected exit completes the pending request with an error and
  clears the cached worker, so the **next** `decode` call spawns a fresh one.
  No retry, no backoff, no supervision tree — the caller already treats any
  throw from `DngFullDecoder` as "this decode failed"
  (`dng_decode_contract.dart:27-30`).
- **`entryPoint` injection** exists solely so tests can exercise the real
  `Isolate.spawn` plumbing with a canned responder instead of loading the
  native dylib. It is a test seam, not an extension point; only two entry
  points ever exist (production and the test fake).
- **No shutdown API.** The worker lives for the process. Adding a `dispose()`
  with no caller would be dead code.

Wiring: `halcyonDngFullDecoder` (`dng_decode_service.dart:34`) becomes the
shared worker's `decode`. `decodeDngFull` is deleted along with it — keeping an
unused per-call adapter would be a second, silently-diverging decode path.
`decodeDngSized` / `halcyonDngSizedDecoder` are untouched.

### B.7 Acceptance criteria (mechanically checkable)

Gate (always):

- [ ] AC-B1: `tool/decode_worker_bench/` exists and `bash
  tool/decode_worker_bench/run_bench.sh <sample-dir> <out-file>` exits 0 and
  writes `<out-file>`.
- [ ] AC-B2: `<out-file>` contains, in this order: a `HEAD=` line, an
  `NM_SYMBOLS=` line, the verbatim go/no-go rule text from §B.5, then the
  measurements, then a single `VERDICT=GO` or `VERDICT=NO-GO` line.
- [ ] AC-B3: The artifact is committed under `docs/logs/2026-08-28/` and its
  verdict is quoted in the task's sign-off report.

Implementation (only if `VERDICT=GO`):

- [ ] AC-B4: `lib/services/image_pipeline/persistent_decode_worker.dart` exists
  and exports `PersistentDecodeWorker` and the top-level `decodeWorkerMain`.
- [ ] AC-B5: A test proves worker **reuse**: N successive `decode` calls against
  an injected fake entry point cause exactly **one** isolate spawn (the fake
  reports its own spawn count in its replies).
- [ ] AC-B6: A test proves **respawn after death**: after the fake entry point
  kills its isolate, the pending call completes with an error and the next
  `decode` call succeeds against a newly spawned isolate.
- [ ] AC-B7: `grep -n "halcyonDngFullDecoder" lib/services/image_pipeline/dng_decode_service.dart`
  shows it bound to the persistent worker, and `grep -rn "decodeDngFull" lib/`
  returns zero matches.
- [ ] AC-B8: `flutter analyze` reports 0 issues and `flutter test` exits 0 with
  `All tests passed!`.
- [ ] AC-B9: A live-run proof — the real app (or a headless script using the
  real dylib) decodes two different no-preview RAWs in one process and both
  succeed, with the artifact recording that only one isolate was spawned.
- [ ] AC-B10: `docs/sop/memory.md` gains an AD entry for the persistent worker
  and `docs/sop/unit_test.md` gains the TC entries for AC-B5 / AC-B6.

### B.8 Risks

| Risk | Mitigation |
|---|---|
| The win is speculative — the pipeline-build vs per-frame split is unmeasured | That is exactly what the §B.5 gate exists to settle; no worker code is written before it returns GO. |
| A long-lived isolate holding an initialized service retains native state for the whole session | Native RGBA buffers are freed inside the worker after each transfer (ceyx's existing worker contract); what persists is the loaded dylib and the GPU pipeline, which is the intended win. Peak transient memory per decode is unchanged because concurrency is unchanged. |
| A wedged worker could stall every subsequent RAW decode | Failure completes the pending request with an error and drops the cached worker; the next call respawns. The serial lane already survives a failing task body (`serial_decode_lane.dart:120-138`). |
| Benchmarking with the wrong binary would produce a confident wrong number | The artifact records `nm -gU` exported symbols of the vendored dylib and git HEAD before any measurement, per the `tool/m6_dng_gate` precedent — provenance from observed symbols, never mtime. |
| Test using a fake entry point does not exercise the real dylib | AC-B9 requires a live run against the real decoder; the fake-entry tests cover only the lifecycle logic they claim to cover. |
| macOS `warmupForSize` / pipeline-cache seams stay unused, so part of the theoretical win is left on the table | Deliberate: calling them would require touching ceyx, which is out of scope this round. Recorded as a follow-up, not a gap. |
