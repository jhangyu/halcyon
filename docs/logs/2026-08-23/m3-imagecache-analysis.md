# M3 ImageCache map + architectural optimisation review

Analyst: m3-cache-analyst-opus (read-only). Worktree `/Users/jhangyu/project/halcyon-m3`,
branch `m3-cache` @ `e7815a3` ("docs(logs): record the passed acceptance battery in the M3 handoff").
No file in this tree was modified except this one.

Scope note: this is a **static analysis**. Every claim below is anchored to code I read;
every number labelled "estimate" is arithmetic on decoded-bitmap geometry (RGBA8 = w*h*4),
not a measurement. Nothing here was run.

---

## 1. ImageCache map

Flutter's `ImageCache` is a global singleton (`PaintingBinding.instance.imageCache`). This app
touches it from exactly five places. Two of them are the tier precache paths, two are display
widgets, one is configuration.

### 1.0 Configuration — the single most important line in this analysis

`lib/main.dart:12-16`

```
const int imageCacheMaxBytes = 500 << 20;
void configureImageCache() {
  PaintingBinding.instance.imageCache.maximumSizeBytes = imageCacheMaxBytes;
}
```

Called from `main()` at `lib/main.dart:20`. So the app **does not** run on the 100 MB default —
it raises the decoded-bitmap ceiling to **500 MB**. `maximumSize` (entry count, default 1000) is
never touched, so the entry-count limit is not binding here; the byte limit is.

Semantics that matter: `ImageCache` only refuses to cache an image whose size exceeds
`maximumSizeBytes` *entirely*. At 500 MB no single decoded frame this app can produce is
oversized, so **every** decode lands and stays until either LRU pressure at 500 MB or an
explicit `evict`. Under the 100 MB default, a >100 MB entry would have been dropped
immediately after use; at 500 MB nothing is self-limiting.

Combined with `kPayloadByteBudget = 256 MB` (`lib/services/photo_payload_cache.dart:19`), the
two mechanical caps that the design doc names as the *replacement* for the deleted ownership
contract (handover §4 invariant I5: "常駐峰值由『視窗內 Σ byteCost』與 Flutter 的 500 MB 上限
雙重機械封頂") sum to **756 MB of admissible resident image memory before either one evicts
anything** — against a 350 MB peak-RSS acceptance ceiling. The observed 900 MB kernel peak is
not a contradiction of the design; it is the design's own stated ceiling being reached.

### 1.1 Tier-1 (window-resolution `ResizeImage`)

- Created by the shared factory `tierOneProviderFor` — `lib/services/image_preload_controller.dart:28-39`
  (`ResizeImage(MemoryImage(bytes), width, height, policy: fit)`).
- **Keyed by**: `ResizeImageKey(MemoryImage(bytes-identity), width, height, policy)`. Bytes
  *object identity* + the two size ints (documented at `:23-27`).
- **Decoded size**: `width`/`height` come from `updateTargetSize` (`:257-260`), written by the
  view as `constraints.max* * devicePixelRatio` (`lib/views/main_detail_view.dart:257-260`).
  On a 2x Retina display with a ~1600x1000 logical detail pane this is 3200x2000 →
  **~25.6 MB per entry**. `policy: fit` means the decode is bounded by the box, so this is an
  upper bound per entry regardless of source megapixels.
- **Precached** for current ±2 in `_precacheTierOneWindow` (`:696-725`), which resolves each
  provider through `_decodeIntoImageCache` (`:754-765`).
- **Evicted by**: the stale sweep at `:716-724` — ids outside the ±2 set, on every
  `preloadImages` pass. Note the early return at `:699`: if `updateTargetSize` has never been
  called, the method returns *before* the eviction sweep, so tier-1 keys are never retired on
  that (startup-only) path.
- **Steady-state residency**: ≤5 entries → **~128 MB estimate** at 2x DPR.

### 1.2 Tier-2 (full-size, unresized `MemoryImage`)

- Factory `fullSizeProviderFor` — `:44` (`MemoryImage(bytes)`, no resize at all).
- **Keyed by**: `MemoryImage` bytes-object identity + scale.
- **Decoded size**: the *source* resolution of the encoded payload, i.e. the embedded JPEG
  preview the native bridge selected, or the JPEG file itself. This is the expensive one:
  a 12 MP frame (4032x3024) decodes to **~48.8 MB**; the 24 MB 24 MP file in the corpus
  (~6000x4000) decodes to **~96 MB**. There is no cap of any kind on this path.
- **Precached** for current ±1 (`kExpensiveStartupRadius = 1`,
  `lib/services/prefetch_scheduler.dart:12`) in `_decodeTierTwoWindow` (`:388-445`), reached
  only after the frozen 250 ms debounce (`:372-381`, `tierTwoNavigationDebounce` at `:49`),
  plus the chained decode after a queued expensive load (`:485-487`).
- **Evicted by**: `_evictTierTwoEntry` (`:682-689`), from two call sites —
  (a) payload-window exit, `:314-316` (fires when the id leaves the **-3..+5** payload window);
  (b) the ±1 stale sweep at `:439-444`, **which only runs inside the debounced body**.
- **Residency**: 3 entries at rest (**~146 MB estimate**, more with the 24 MP file). But see
  §2.2: between navigation pauses the ±1 sweep does not run, so the only eviction in force is
  the 9-slot payload window.

### 1.3 `RawPixelsImage` (`ui.decodeImageFromPixels`)

- `lib/services/raw_pixels_image.dart:24-88`. Key is `RawPixelsImage` itself, with
  `operator ==` on **`identical(payload.rgba)`** + w/h + scale (`:68-83`) — deliberately identity,
  not value (`:59-66`).
- **Decoded size**: exactly the retained `PixelPayload` geometry, because the payload was
  already downscaled to `longEdge` and orientation-corrected at production time
  (`decodedRgbaToPixelPayload`, `lib/services/decoded_rgba_image_provider.dart:91-132`).
  At a 2800 px long edge that is ~2800x2100 → **~23.5 MB decoded**, on top of the ~23.5 MB
  `Uint8List` the payload cache retains. So a pixel item costs roughly **2x its byteCost** while
  displayed/precached.
- **Both tiers use the same provider for this kind** (`:743` and `:751`), so a pixel item occupies
  **one** ImageCache entry, not two — pixel items are structurally cheaper than encoded ones.
- Also built ad-hoc per read by `pixelsProviderFor` (`:177-180`) → `AppState.currentDecodedProvider`
  (`lib/providers/app_state.dart:186-187`) → the display `Image` (`main_detail_view.dart:277-285`).
  A fresh object each time, but key equality is buffer identity, so it is a cache hit.
- **Evicted by**: the tier-1 sweep and/or `_evictTierTwoEntry`, depending on which map recorded
  the key. Both maps can hold the *same* key for the same item (both factories returned the same
  object shape), which is benign for eviction but means one `evict` retires both bookkeeping views.

### 1.4 Sidebar thumbnails

`lib/views/sidebar_view.dart:281-296`: `ResizeImage(MemoryImage(thumbBytes), cap, cap, fit)` with
`cap = 32 * devicePixelRatio` (`:281`). Decoded entry ≈ 64x64x4 = **16 KB**. Bytes come from
`_thumbCache` (`image_preload_controller.dart:84`), pruned to the visible range ±20 rows at
`:811-812`, native-capped at 200 px. Up to ~41 rows resident.
**Total thumbnail contribution: well under 5 MB.** Not a suspect. Nobody evicts these decoded
entries explicitly; they age out by LRU, which at 16 KB each is irrelevant.

### 1.5 Corpus totals (estimate, 26 files: 13 cheap JPEG-bearing, 13 no-preview DNGs 9–13 MB, one 24 MB)

| Holder | Entries | Per-entry | Subtotal |
|---|---|---|---|
| Tier-1 `ResizeImage` (±2) | 5 | ~25.6 MB @2x DPR | **~128 MB** |
| Tier-2 full-size (±1), encoded items | 3 | ~48.8 MB (96 MB for the 24 MP) | **~146–240 MB** |
| `RawPixelsImage`, pixel items in window | shared w/ tier-1 | ~23.5 MB | (counted above) |
| Sidebar thumbnails | ~41 | 16 KB | ~0.7 MB |
| **Decoded (ImageCache) total** | | | **~275–370 MB** |
| Retained payloads (measured by the team) | | | **113.7 MB** |
| **Dart-side total** | | | **~390–485 MB** |

That leaves roughly 400–500 MB for the engine/raster/GPU baseline and native decoder working
buffers — which is the piece the parallel pre-M3 baseline run has to attribute. My estimate does
**not** close the 786 MB gap on its own, and I do not claim it does.

---

## 2. Who can hold the unattributed memory — ranked

### 2.1 Rank 1 — the 500 MB ImageCache ceiling itself (`main.dart:12`)

Not a leak; a *permission*. Every decoded frame described in §1 is allowed to stay until 500 MB
is reached. With tier-1 at ~128 MB and tier-2 at ~146–240 MB, ordinary steady-state operation
sits at 275–370 MB of decoded bitmaps **and nothing evicts it, because nothing has to**. This is
the single largest attributable Dart-side holder and the cheapest to change.

### 2.2 Rank 2 — tier-2 entries whose ±1 sweep never runs

`_decodeTierTwoWindow`'s stale sweep lives at `:439-444`, i.e. *inside* the debounced body. Every
navigation event cancels and reschedules that timer (`:377-378`). Therefore during continuous
navigation the ±1 sweep never executes and the **only** eviction still in force is the payload-window
drop at `:314-316`, whose window is **-3..+5 (9 slots), not ±1 (3 slots)**.

Consequence: a browse pattern of "pause ~300 ms, step, pause" — which is exactly triage — decodes a
new ±1 set at each pause while previously decoded full-size entries survive until they fall out of
the 9-slot payload window. Worst case is **up to 9 resident full-size entries ≈ 440 MB**
(one of them the 96 MB 24 MP frame). This is the most plausible mechanical explanation for a
900 MB peak coexisting with a 113.7 MB payload total, and it is consistent with the reported
"6 of 9 window slots populated".

### 2.3 Rank 3 — live `ImageStream` listeners holding images past eviction

`evict()` removes the cache entry; it does not free a `ui.Image` that a live listener still
references. Live listeners in this app:
- the display `Image` widget (`main_detail_view.dart:291-307`) with `gaplessPlayback: true`
  (`:296`), which by design **retains the previous frame's `ImageInfo`** until the new one
  resolves — so at a tier-1→tier-2 switch, and at every navigation step, two full frames are
  legitimately alive at once;
- the PERF instrumentation resolve at `main_detail_view.dart:194-208` — it adds a listener and
  removes it in the callback (`:206`), so it is bounded, but it is a second live reference during
  the decode window, and it is compiled into the build that was measured;
- the precache listeners at `:757-760` and `:662-666`, both self-removing on first frame/error.

None of these is unbounded. Their effect is a **transient multiplier of ~2x on the largest
entries during navigation**, which is precisely when the peak is sampled.

### 2.4 Rank 4 — native/decoder-side buffers outside the Dart heap

`decodedRgbaToPixelPayload` (`decoded_rgba_image_provider.dart:91-132`) materialises the
**full-resolution** RAW frame as a `ui.Image` (`:96`), then a scaled `ui.Image` (`:113`), then
reads it back with `toByteData` (`:119`). At 4080x3056 the full-res intermediate is ~49.9 MB and
lives, together with the scaled copy and the `Uint8List` read-back, for the duration of the call.
The `finally` at `:128-131` disposes both `ui.Image`s correctly — but `ui.Image.dispose()` releases
the *handle*; the GPU/Skia-side resource is reclaimed on the engine's own schedule, not
synchronously. The +/-1 loads are serialised (`_enqueueTierTwoLoad`, `:465-494`), which caps this
at one decode in flight — good — but the transient is ~120 MB per expensive item and it lands at
the same moment as the tier-2 decodes. For 13 no-preview DNGs this is a repeated, large,
non-Dart-heap transient that an RSS *peak* measurement will catch.

### 2.5 Rank 5 — a full-size path still reachable for pixel items? **No.**

I checked specifically. `_fullSizeProviderForPayload` (`:747-752`) returns `RawPixelsImage(payload)`
for `PixelPayload`, i.e. the *window-resolution* buffer. There is no code path that decodes a
no-preview DNG at full resolution into the ImageCache. The full-resolution frame exists only as
the transient in §2.4. This candidate from the brief is **refuted**.

### 2.6 Not a factor

- `maximumSize` (1000 entries) is never approached.
- Sidebar thumbnails (§1.4): <5 MB.
- `_thumbCache` byte buffers: 200 px JPEGs, ~41 of them.

---

## 3. Architectural recommendations (ranked; all inside the frozen constraints)

**R1 — Lower `imageCacheMaxBytes` from 500 MB to a figure derived from the 350 MB RSS ceiling.**
`main.dart:12`, one constant. A defensible value is ~160 MB: it holds the ±1 tier-2 set for a
12 MP corpus *or* the ±2 tier-1 set, and forces LRU to arbitrate instead of admitting both in full.
**Trade-off**: LRU may evict a tier-2 entry that `isFullSizeReady` (`:219-227`) then reports false
for, so a back-navigation shows tier-1 first and re-decodes tier-2. That is a *quality* regression on
the return leg, **not** a latency regression on the D2-protected switch (tier-1 is still an
instant cache hit). No timing, debounce, window semantics or provider factory is touched.
**Effort**: 1 line + re-run the acceptance battery. Highest ratio in this document.

**R2 — Make the ±1 tier-2 eviction sweep run on every navigation, not only inside the debounced body.**
Today the sweep is at `:439-444`, unreachable during continuous navigation (§2.2). Hoist the
*eviction half only* — computing the ±1 id set and calling `_evictTierTwoEntry` for tier-2 keys
outside it — into `preloadImages` alongside the existing payload sweep (`:308-316`). The *decode*
half must stay behind the debounce, untouched.
**Trade-off**: an item at distance 2–5 that was full-size-decoded during an earlier pause loses that
entry and re-decodes when navigated back to. Note this is *already* the behaviour whenever the user
pauses (the sweep runs then); R2 only makes it consistent. D2's ±1 timing/debounce/window semantics
are unchanged — this changes only *when unwanted entries are released*, never when wanted ones are
produced.
**Effort**: ~20 lines + a test asserting tier-2 key count ≤3 after a burst with no pause.

**R3 — Cap the tier-2 decode at a multiple of viewport pixels rather than source resolution.**
`fullSizeProviderFor` (`:44`) is `MemoryImage(bytes)` with no bound at all, so a 24 MP file costs
96 MB. Wrapping it in `ResizeImage(..., width: k*targetW, height: k*targetH, policy: fit)` with
k≈2–2.5 keeps 1:1 pixel detail well past 100% zoom while cutting the 24 MP case by ~4x.
**Trade-off / caution**: `InteractiveViewer` allows `maxScale: 5.0` (`main_detail_view.dart:319`),
so at extreme zoom this becomes visibly softer than today. It also changes what the frozen factory
`fullSizeProviderFor` *means* (the factory stays in place and the call sites at
`main_detail_view.dart:280-285` do not move, but its output geometry changes), so I flag this as
**borderline — recommend user confirmation** rather than free.
**Effort**: ~10 lines + a zoom-quality visual check.

**R4 — Give the tier-1 sweep a path that runs even when `updateTargetSize` has never fired.**
`_precacheTierOneWindow` returns at `:699` before its eviction sweep (`:716-724`). Reordering
(sweep first, then the width/height guard) costs nothing and closes a startup-shaped hole.
**Trade-off**: none identified. **Effort**: 3 lines.

**R5 — Bound the peak of the RAW reduction transient.**
`decodedRgbaToPixelPayload` holds full-res + scaled + read-back simultaneously (§2.4). Disposing
`raw` immediately after `_applyTransform` returns (rather than in the `finally` at `:128-131`,
after `toByteData`) removes ~50 MB from the overlap window. Requires care: `_applyTransform`'s
returned image must not alias `src`, which it does not when a transform actually ran, but *does*
in the identity+scale==1.0 case (`:111-113`).
**Trade-off**: a correctness-sensitive edit to a disposal path; needs the identity case handled
explicitly. **Effort**: ~10 lines + a test on orientation 1 / no-downscale.

### Requires user decision (contract changes — NOT recommended unilaterally)

- **Shrink `kPayloadByteBudget`** from 256 MB (`photo_payload_cache.dart:19`). The measured 113.7 MB
  says it is not binding today, but it is half of the 756 MB admissible total. D4 freezes the
  *type-blind byteCost-only* rule, not the number — still, changing it changes the stated design.
- **Reduce `kRetentionBefore`/`kRetentionAfter`** (`:6`/`:10`) from -3..+5. Directly attacks §2.2's
  9-slot worst case, and directly attacks the instant back-and-forth selling point. Dead on arrival
  under D2 unless the user asks for it.
- **Reduce `kExpensiveStartupRadius`** from 1 to 0 (`prefetch_scheduler.dart:12`). Explicitly frozen
  by D2.

---

## 4. Negative space — what M3 stopped doing

The deleted §7 list (handover `docs/logs/2026-08-23/image-pipeline-redesign-handover.md:212-214`)
removed, among others: `_rawDecodesInFlight`, `_startRawDecode`/`_runRawDecode`, the self-disposing
late decode, `DecodedRgbaImageProvider`, the 25-line debounce warning block, and — the one that
matters here — **the `dispose()` half of `_evictTierTwoEntry`**.

What that machinery actually bounded: the pre-M3 pipeline owned a ~49.9 MB `ui.Image` per RAW item
and **destroyed** it at eviction. Destruction was synchronous and unconditional; it did not wait for
LRU, did not wait for a listener to let go, and applied to the *largest* single objects in the
system. Invariant I5 (handover `:155`) records that this was dissolved deliberately, and names the
replacement guarantee verbatim: "常駐峰值由『視窗內 Σ byteCost』與 Flutter 的 500 MB 上限雙重機械封頂".

**What now performs that role for tier-2 `ui.Image` entries:** only `imageCache.evict(key)` —
`_evictTierTwoEntry:682-689`, the tier-1 sweep `:716-724`, and `reset`/`dispose` (`:236-239`,
`:265-270`). Three properties of `evict` that `dispose` did not have, and that are the honest
answer to the negative-space question:

1. **`evict` is advisory, `dispose` was not.** A live `ImageStream` listener — including
   `gaplessPlayback`'s deliberately retained previous frame (`main_detail_view.dart:296`) — keeps the
   `ui.Image` alive after eviction. The old code could not be defeated this way.
2. **`evict` requires a key, and the key is bookkeeping that can go missing.** `_tierTwoKeys[id]` is
   written in the `.then` at `:668-671`. For today's two providers (`MemoryImage` and
   `RawPixelsImage`, whose `obtainKey` returns a `SynchronousFuture` — `raw_pixels_image.dart:31-33`)
   that callback runs synchronously, so **this is not a live bug**. It is, however, written as if it
   were async, and any future provider with a genuinely asynchronous `obtainKey` would silently
   orphan entries that nothing can ever evict. Structurally fragile, currently correct — I checked
   rather than assumed.
3. **Nothing evicts on memory pressure or on a schedule.** Eviction is driven purely by window
   transitions. When no window transition occurs — the §2.2 case — nothing is released at all, and
   the backstop is the 500 MB LRU ceiling that R1 proposes to lower. Before M3, the RAW path's
   narrow window plus unconditional dispose meant the largest objects were released on a much
   tighter schedule than the current 9-slot payload window provides.

The design's claim is not wrong: byteCost + the 500 MB cap *do* mechanically bound residency. The
gap is that the bound they compose to (756 MB) was never reconciled with the 350 MB acceptance
ceiling. That reconciliation — not a leak hunt — is the substance of R1 and R2.

---

## 5. Uncertainties, flagged

- **Every MB figure is arithmetic, not measurement.** I could not run anything (read-only mandate).
- **Device pixel ratio and detail-pane logical size are unknown to me.** Tier-1 per-entry cost scales
  with DPR²; at 1x DPR my ~128 MB tier-1 estimate falls to ~32 MB and R1's headline shrinks.
- **My estimates do not fully account for 786 MB.** I attribute ~275–370 MB of decoded bitmaps.
  The remainder needs the parallel pre-M3 baseline run to separate engine/raster/GPU baseline from
  regression. Do not treat §1.5 as a closed budget.
- **Skia/Impeller GPU-side residency is invisible to Dart-level reasoning.** §2.4's claim that
  `ui.Image.dispose()` does not synchronously return GPU memory is standard engine behaviour, but I
  verified no engine source in this session.
- **R2 assumes the reported "6 of 9 slots populated" refers to the payload window.** If it refers to
  something else, §2.2's ranking weakens.
