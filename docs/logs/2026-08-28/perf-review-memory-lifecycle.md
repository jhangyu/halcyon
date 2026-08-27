# Perf Review — Memory Strategy & Tier-1/Tier-2 Dual-Window Lifecycle

> Date: 2026-08-28 · Author: perf-impl-1-sonnet (team fable-review) · **Analysis only. No code changed.**
> Scope: `image_preload_controller.dart`, `tier_two_scheduler.dart`, `tier_two_registry.dart`,
> `photo_payload_cache.dart`, `prefetch_scheduler.dart`, `serial_decode_lane.dart`.

The subsystem is already well-factored: retention (payload cache), tier-2 readiness (registry),
tier-2 scheduling (scheduler) and the single decode lane are cleanly separated, and the
"eviction is just dropping a `Uint8List` reference" model removes a whole class of
use-after-dispose bugs. The two findings below are the only ones I judged to clear the value bar.

---

## Finding 1 — The tier-2 full-size decode window is symmetric (±2) while everything else is forward-biased

**Evidence**
- `prefetch_scheduler.dart:13` — `const int kTierTwoRadius = 2`, one symmetric radius.
- `tier_two_scheduler.dart:130-138` (`updateWindow`) and `:187-207` (`_decodeWindow`) both build the
  window with `before: kTierTwoRadius, after: kTierTwoRadius` → the slots `-2..+2`.
- Contrast: the retention window is deliberately **asymmetric forward** — `kRetentionBefore = 3`,
  `kRetentionAfter = 5` (`photo_payload_cache.dart:6,10`, comment: "browsing is overwhelmingly
  forwards"). The serial lane's start order is likewise forward-first —
  `laneRankFor` yields `0, +1, -1, +2, -2, …` (`serial_decode_lane.dart:176-180`).
- Full-size tier-2 entries are the single most expensive resource in the whole pipeline:
  91.55 MiB per no-preview RAW entry (`docs/logs/2026-08-23/cache-sizing-estimate.md:45,230`) and each
  costs one FFI RAW decode or a full-frame JPEG decode; they are produced one-at-a-time on the shared
  serial lane.

**Why it matters**
When navigation settles at index *i*, the scheduler spends its scarce single-flight full-res budget
on `i-2` and `i-1` — slots the forward-biased user is least likely to revisit — while `i+3`
(already retained as a tier-1 payload, `-3..+5`) gets **no** full-res entry. Stepping forward onto
`i+3` therefore shows only the window-resolution tier-1 frame and triggers a catch-up decode on
arrival (61–406 ms for encoded, an FFI RAW decode otherwise) instead of hitting a ready entry.
Symmetric ±2 also parks up to two 91.55 MiB backward full-res entries in the (memory-derived)
Flutter `ImageCache`, adding LRU pressure that the sizing doc already flags as the first thing to
break under back-navigation (`cache-sizing-estimate.md:176-177`).

**Improved design (sketch)**
Split `kTierTwoRadius` into `kTierTwoBefore` / `kTierTwoAfter` (mirroring the retention constants)
and bias forward — e.g. `before: 1, after: 3` (same 5 slots, shifted forward) or the tighter
`before: 1, after: 2` (4 slots, less ImageCache pressure). The window helper
`retentionWindowIds(..., before:, after:)` is already parameterized, so only the two call sites in
`tier_two_scheduler.dart` and the stale-eviction set derived from the same constants change; the
`_decodeWindow` `tierStart..tierEnd` clamp loop already handles an asymmetric span. No change to the
registry, the lane, or the identity/cache-key invariants.

**Rough effort:** small — one constant split + two call sites + rerun the tier-2 window tests
(TC-098*, AC-M5-2). No architectural change.

---

## Finding 2 — Retention window + payload budget are fixed constants; no physical-memory source is wired anywhere, so back-navigation on capable machines re-pays the ~8.5 s RAW decode

**Evidence**
- Payload retention is a hardcoded 9 slots (`kRetentionBefore = 3` / `kRetentionAfter = 5`,
  `photo_payload_cache.dart:6,10`) and a hardcoded 224 MiB budget
  (`kPayloadByteBudget`, `photo_payload_cache.dart:31`), sized to hold *exactly one* `-3..+5` RAW
  window (201.59 MiB) with ~11 % headroom. Its own comment: "ponytail: one global number … Make it
  configurable per-cache before making it adaptive."
- The Flutter `ImageCache` budget has an *injectable seam* for machine-adaptivity
  (`imageCacheBudgetBytes(physicalMemoryBytes: …)`) but it is **not actually wired to any memory
  source**: `main.dart:22-23` calls it with `physicalMemoryBytes: null`, and the comment at
  `main.dart:16-21` explains why — `dart:io` has no platform-neutral total-physical-memory API
  (`ProcessInfo` is RSS-only) and `Platform.isX` branches are forbidden by constraint C-3, so at
  runtime the ImageCache simply gets `imageCacheBudgetBytes`'s own fixed `ceiling`. So **both** tiers
  are fixed today; the payload tier does not even have the seam.
- Re-entering an evicted no-preview RAW slot costs a full sequential RAW decode, "~8.5 s measured"
  (`photo_payload_cache.dart:26`), versus a cache hit if the payload were still retained. Payloads
  are plain `Uint8List` (or window-res RGBA) — retaining more is "just holding a reference," the
  cheap half of this design (`photo_payload_cache.dart:43-48`).

**Why it matters**
The budget is pinned just above one window, so on a high-RAM machine the retention window still
evicts the moment the user steps past `-3`, and every back-navigation beyond that re-pays up to
~8.5 s of RAW decode — the exact cost the retention design exists to eliminate. Because retained
payloads carry no `ui.Image` and no lifetime to manage, widening retention converts revisits into
hits at the cost of only held bytes, not decode work or dispose risk.

**Improved design (sketch)**
This is *not* "extend existing adaptivity to the payload tier" — there is no live adaptivity to
extend. It is two steps: **(1)** build a physical-memory source that satisfies C-3 — since
`dart:io`/`Platform.isX` are unavailable/forbidden, that means a `MethodChannel` (or FFI) reading
total RAM per platform, injected the same way `imageCacheBudgetBytes` already anticipates; **(2)**
size *both* the ImageCache ceiling and a new `kPayloadByteBudget` / forward retention depth from that
value, keeping today's 224 MiB / `-3..+5` as the low-RAM floor and scaling `kRetentionAfter` up on
high-RAM hosts (e.g. `+5 → +8/+11`). The cache already evicts farthest-first via
`setEvictionPriority` (`photo_payload_cache.dart:78,148-173`), so a wider window degrades gracefully
under budget with no new eviction logic.

**Rough effort:** moderate-to-large — dominated by step (1), the platform memory source (native
channel per shipped platform + the C-3-safe injection), which does not exist yet. Step (2) itself is
small (a sizing function + threading the value into the cache constructor, which already takes
`byteBudget`). **Risk/caveat:** payoff (avoiding the ~8.5 s re-decode) is asymmetric upside, but the
per-RAM-tier window depth must be tuned against the user's own UI measurement — I did no UI/RSS
measurement per team rules. Recommend landing the memory source + sizing hook first with today's
values as the floor, then let the user tune the high-RAM depth. If the platform memory source is
judged too costly, Finding 1 stands alone as the higher-ROI change.

---

### Notes / non-findings (did not clear the bar)
- `_pickVictim`'s `indexOf`-in-a-loop is O(n²) but n ≤ ~9 (already a `ponytail:` note) — not worth changing.
- `_precacheTierOneWindow` re-resolves all retained payloads each pass, but resolves are ImageCache
  hits on stable identity keys (invariant I1) — negligible.
- Single-flight serial lane vs. N-concurrent RAW decode is real but belongs to the decode-scheduling
  review (task #2), not memory/lifecycle.
