# Perf Review — Concurrent Expensive RAW Decode Feasibility

Reviewer: perf-impl-2-sonnet (team fable-review) · 2026-08-28 · HEAD e664ff9
Scope: decode scheduling strategy; feasibility of scaling expensive RAW decode
from the current serial lane to 2–6 concurrent workers sized by machine class.
Analysis only, no source changes.

## TL;DR verdict

**Multi-worker concurrent expensive decode (2–6 workers) is NOT worth it. Keep
the single serial lane.** The throughput ceiling is the GPU, not idle CPU cores,
so N concurrent decoders do not decode N× faster; meanwhile each concurrent
full-RAW decode adds ~100–360 MB of transient memory, turning a bounded-memory
design into an OOM risk. The latency the user actually feels — the selected
image appearing — is already optimal because the serial lane runs the visible
item first at full machine capacity.

The one high-value scheduling improvement that *is* worth doing: **reuse a
persistent decode worker instead of spawning a fresh `Isolate.run` per decode**,
which today reloads the dylib and cold-starts the GPU pipeline on every single
RAW.

---

## How decode actually runs today

- One expensive decode at a time on `SerialDecodeLane` — at most one task body
  executing (`serial_decode_lane.dart:60-62`, `120-138`). This lane is shared by
  both payload production and tier-2 upgrades so "one RAW decode in flight" is a
  pipeline-wide property, not per-scheduler (`image_preload_controller.dart:92-97`,
  memory.md AD-033 line 354).
- The decode itself is dispatched through `ceyx`'s `decodeOnWorker`, which spins
  up a **fresh** `Isolate.run` per call
  (`dng_decoder_service.dart:260-271`). Inside that throwaway isolate a brand-new
  `DngDecoderService()..initialize()` runs, which calls
  `DngNativeBindings.load()` to load the dylib from scratch
  (`dng_decoder_service.dart:374-381`, `141-150`).
- The native pipeline is a **GPU (Metal/Vulkan) Halide** pipeline: error codes
  include `gpuUnavailable`, `kernelFailed`, GPU dispatch stages, and a
  `VkPipelineCache` persistence path (`dng_decoder_service.dart:66`, `206-238`,
  `526-528`). Time is reported as `decodeMs` (CPU DNG-SDK decompress) +
  `processMs` (GPU Halide) (`dng_decoder_service.dart:41-56`).
- Halcyon never calls `warmupForSize` or `setPipelineCachePath` — grep of `lib/`
  finds zero callers. So every decode pays a cold pipeline build.
- The serial lane's own doc comment already states the design rationale
  verbatim: *"A RAW decode saturates cores rather than waiting on IO, so N in
  parallel is slower per image AND makes the item the user is looking at contend
  with its neighbours."* (`serial_decode_lane.dart:41-45`). Cost measured
  61–406 ms per decode (`photo_source.dart:22-26`, memory.md AD-033).

---

## Feasibility assessment: 2–6 concurrent workers

### 1. Throughput ceiling is the GPU — concurrency buys almost nothing

The heavy stage (`processMs`) is a Metal/Vulkan Halide dispatch. A single GPU
serializes command buffers from multiple isolates at the driver level; two
isolates each submitting a full demosaic+render pipeline do not run in parallel
on one GPU, they queue. So the GPU-bound fraction of each decode gets **zero**
speedup from concurrency, and pays extra for context/VRAM churn.

The CPU-bound fraction (`decodeMs`, DNG-SDK decompress) *could* overlap across
isolates — but the design comment's "saturates cores" claim implies a single
decode already uses multiple cores. If true, 2–6 concurrent decodes merely
time-slice the same cores → slower per image, same total wall-clock. Net
throughput gain is bounded by the CPU-decompress fraction only, and only if that
fraction is genuinely single-threaded today — neither of which is established.
Without a measured `decodeMs`/`processMs` split (user measures perf himself;
no headless split was run this round) the upside is speculative and small.

**Recommended worker-count heuristic if forced to pick one: 1 (i.e. keep
serial).** A machine-class heuristic (`Platform.numberOfProcessors`) would size
the pool to CPU cores, but cores are not the bottleneck — the single GPU is — so
the heuristic would provision workers that contend rather than parallelize.

### 2. Memory ceiling — the disqualifying cost

Each concurrent full-RAW decode holds a full-resolution RGBA8 buffer:
`width * height * 4` (`dng_decoder_service.dart:473`, `639`). And the worker path
**copies** it: `Uint8List.fromList(...)` then `TransferableTypedData` — so during
the copy the buffer exists twice in that isolate (`dng_decoder_service.dart:642-647`).

- 24 MP (6000×4000): ~96 MB resident, ~192 MB transient during copy.
- 45 MP (e.g. A7R): ~180 MB resident, ~360 MB transient.

The pipeline's own single-image guard rejects decodes whose decoded pixels exceed
1.5 GB (`dart_image_loader.dart:171-182`). Six concurrent 45 MP decodes mid-copy
approach ~2 GB of transient RGBA alone — before the retained payloads, the tier-2
piggyback full-res buffers (`photo_source.dart:311-321`), and Flutter's ImageCache.
The current design is explicitly bounded by "one decode in flight"; N-way
concurrency multiplies the peak by N and reintroduces exactly the OOM exposure the
serial lane removed.

### 3. Isolate vs FFI-thread

`Isolate.run` is the right isolation primitive (native pointers must not cross
isolate boundaries — `dng_decoder_service.dart:345-349`; the worker deliberately
copies to Dart-owned bytes before transfer). An FFI-thread pool inside one
isolate is *not* simpler here: the native diagnostics state is `thread_local`
(`dng_decoder_service.dart:169-178`) and the GPU pipeline/warmup state is
process-global, so multiple native threads would still serialize on the GPU while
complicating memory ownership. Neither model changes the GPU bottleneck.

### 4. Does concurrency reduce felt latency? No

The user looks at one image. The serial lane already runs the selected slot first
(rank 0), at full machine capacity, before any neighbor
(`image_preload_controller.dart:472-489`, `serial_decode_lane.dart:176-180`).
Concurrency cannot make slot 0 appear faster — it can only fill neighbors sooner,
and only when the user has *paused* (during fast navigation the debounce +
reprioritization already suppress neighbor decodes). The marginal win is "the
±1/±2 neighbors of a stopped cursor fill in ~half the time" — real but minor, and
not worth the memory blast radius above.

**Conclusion: not feasible as a net win. Keep the single serial lane.**

---

## The one improvement worth making: persistent decode worker

Every expensive decode today spawns a throwaway isolate that (a) reloads the
native dylib via `DngNativeBindings.load()` and (b) cold-starts the GPU pipeline,
because Halcyon never warms it and the fresh isolate shares no warmed state
(`dng_decoder_service.dart:260-271`, `374-381`, `196-204`; no `warmupForSize`
caller in `lib/`). On a Metal pipeline the first dispatch after load pays shader
compilation / pipeline construction that a warmed, reused worker would pay once.

Proposed direction (design only, for the impl squad to size):
- Replace per-call `Isolate.run` with **one long-lived decode isolate** owned by
  the serial lane, receiving `(path, maxDim)` over a `SendPort` and returning
  `TransferableTypedData`. The dylib loads once; the GPU pipeline warms once.
- This composes cleanly with the serial lane — still exactly one decode in
  flight, no memory-ceiling change — and attacks the actual per-decode overhead
  (cold dylib + cold pipeline) instead of the non-bottleneck (idle cores).
- Expected benefit: removes dylib-load + cold-pipeline cost from every decode
  after the first; largest impact on RAW-heavy folders where decodes are
  back-to-back. Effort: moderate (a persistent-worker wrapper in `ceyx`, or a
  Halcyon-side long-lived isolate around the existing FFI service).

Caveat (honest): the exact saving depends on how much of `processMs` is
one-time pipeline build vs per-frame GPU work — that split is unmeasured here.
If pipeline build is already cheap on Metal, the win shrinks to the dylib-load
cost only. This should be validated with a headless `decodeMs`/`processMs`
capture before committing to the refactor. `ceyx` already exposes
`warmupForSize` / `pipelineCacheStatus` to measure it
(`dng_decoder_service.dart:196-204`, `232-238`).

---

## Claims → evidence index

| Claim | Evidence |
|---|---|
| One decode in flight, shared lane | `serial_decode_lane.dart:60-62,120-138`; `image_preload_controller.dart:92-97`; memory.md:354 |
| Fresh isolate + dylib reload per decode | `dng_decoder_service.dart:260-271,374-381,141-150` |
| GPU Metal/Vulkan pipeline | `dng_decoder_service.dart:66,206-238,526-528` |
| Never warmed in Halcyon | no `warmupForSize`/`setPipelineCachePath` caller in `lib/` |
| Per-decode RGBA = w·h·4, copied in worker | `dng_decoder_service.dart:473,639,642-647` |
| Single-image 1.5 GB guard | `dart_image_loader.dart:171-182` |
| Serial-parallel rationale already documented | `serial_decode_lane.dart:41-45`; `photo_source.dart:22-26` |
| Selected slot decoded first | `image_preload_controller.dart:472-489`; `serial_decode_lane.dart:176-180` |
| Native pointers must not cross isolates; worker copies | `dng_decoder_service.dart:345-349,642-647` |
| thread_local native diagnostics | `dng_decoder_service.dart:169-178` |
