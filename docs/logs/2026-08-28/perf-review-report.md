# Performance Review Report — fable-review perf squad

Date: 2026-08-28 · HEAD e664ff9 · Lead: perf-lead-fable
Inputs: `perf-review-memory-lifecycle.md` (perf-impl-1-sonnet), `perf-review-concurrency.md` (perf-impl-2-sonnet).
All cited locations spot-checked by the lead against the working tree. Analysis only — no source changed.

## Headline answer to the concurrency question

**Scaling expensive RAW decode to 2–6 concurrent workers is NOT recommended.** The
heavy stage is a single-GPU Metal/Vulkan Halide dispatch that serializes at the
driver regardless of isolate count (`../ceyx/plugin/lib/src/dng_decoder_service.dart:66,206-238,526-528`),
each concurrent decode adds ~96–360 MB transient RGBA (`dng_decoder_service.dart:473,639,642-647`;
single-image guard at `lib/services/image_pipeline/dart_image_loader.dart:171-182`),
and felt latency is already optimal because the serial lane runs the selected slot
first at full machine capacity (`lib/services/image_pipeline/image_preload_controller.dart:472-489`,
`serial_decode_lane.dart:176-180`). Concurrency would only fill paused-cursor
neighbours slightly sooner, at the cost of reintroducing the OOM exposure the
serial lane was built to remove. Keep the single serial lane.

## Ranked proposals (3)

### 1. Forward-bias the tier-2 full-size decode window (small effort, clear win)

- **Evidence**: `lib/services/image_pipeline/prefetch_scheduler.dart:13`
  (`kTierTwoRadius = 2`, symmetric) used at `tier_two_scheduler.dart:130-138` and
  `:187-207`; every other policy is forward-biased — retention `-3..+5`
  (`photo_payload_cache.dart:6,10`) and lane order forward-first
  (`serial_decode_lane.dart:176-180`).
- **Problem**: the scarce single-flight full-res budget (up to 91.55 MiB per
  no-preview RAW entry, `docs/logs/2026-08-23/cache-sizing-estimate.md:45,230`) is
  spent on backward slots `i-2`/`i-1` the forward-browsing user rarely revisits,
  while `i+3` — already retained as a payload — has no full-res entry and pays a
  catch-up decode on arrival.
- **Expected benefit**: forward steps land on ready full-size entries instead of a
  catch-up decode (61–406 ms encoded, one FFI RAW decode otherwise); up to two
  backward 91.55 MiB entries stop pressuring the ImageCache.
- **Effort**: small. Split into `kTierTwoBefore`/`kTierTwoAfter` (e.g. `-1..+3`);
  `retentionWindowIds` is already parameterized, two call sites change; rerun
  tier-2 window tests (AC-M5-2).

### 2. Persistent decode worker instead of per-decode throwaway isolate (moderate effort, measure first)

- **Evidence**: every expensive decode spawns a fresh `Isolate.run` whose body
  constructs `DngDecoderService()..initialize()` and reloads the dylib
  (`../ceyx/plugin/lib/src/dng_decoder_service.dart:374-381,141-150`); Halcyon
  never calls `warmupForSize`/`setPipelineCachePath` (zero callers in `lib/`), so
  every decode also cold-starts the GPU pipeline.
- **Expected benefit**: dylib load + GPU pipeline build paid once per session
  instead of once per RAW; largest on RAW-heavy folders with back-to-back decodes.
  Composes with the serial lane — still exactly one decode in flight, no memory
  change.
- **Effort**: moderate — one long-lived decode isolate owned by the serial lane
  (SendPort in, `TransferableTypedData` out), in ceyx or Halcyon-side.
- **Caveat (binding)**: the win depends on the unmeasured split between one-time
  pipeline build and per-frame GPU work. Run a headless `decodeMs`/`processMs`
  capture (ceyx already exposes `warmupForSize`/`pipelineCacheStatus`,
  `dng_decoder_service.dart:196-204,232-238`) before committing.

### 3. Machine-adaptive payload retention (real payoff, but gated on a missing platform memory source)

- **Evidence**: payload retention is fixed at 9 slots / 224 MiB — sized to exactly
  one RAW window plus 11% (`photo_payload_cache.dart:6,10,31`); re-entering an
  evicted no-preview RAW slot re-pays ~8.5 s of decode
  (`photo_payload_cache.dart:26`). The ImageCache sizing seam exists but is wired
  to `physicalMemoryBytes: null` (`lib/main.dart:16-23`) — no real physical-memory
  source exists anywhere in the app (dart:io has none; C-3 forbids `Platform.isX`
  branches).
- **Expected benefit**: on high-RAM machines, wider forward retention converts
  back-navigation re-decodes (~8.5 s each) into cache hits; payloads are plain
  `Uint8List`, so the only cost is held bytes and eviction already degrades
  farthest-first (`photo_payload_cache.dart:78,148-173`).
- **Effort**: moderate-to-large, dominated by step 1 — building a C-3-safe
  physical-memory source (native channel per platform), which does not exist.
  Step 2 (sizing both tiers from it, keeping today's values as the low-RAM floor)
  is small. If step 1 is judged too costly, drop this proposal — proposal 1 stands
  alone as the higher-ROI change.

## Explicitly rejected as not worth doing

- 2–6 concurrent RAW decode workers (headline above).
- FFI-thread pool instead of isolates (still serializes on the GPU; `thread_local`
  native diagnostics complicate ownership, `dng_decoder_service.dart:169-178,345-349`).
- `_pickVictim` O(n²) scan, tier-1 re-resolve per pass — bounded n / ImageCache
  hits; micro-optimizations with no measurable benefit.
