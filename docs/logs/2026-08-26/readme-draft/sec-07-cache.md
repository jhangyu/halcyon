## Cache and memory management

### The problem

A full-resolution decoded frame from a modern sensor is large — a 24 MP RAW
decodes to roughly 91.55 MiB of RGBA pixels
<!-- evidence: lib/services/image_pipeline/cache_budget.dart:20 -->.
A photographer reviewing a folder holds an arrow key down and moves through
dozens of frames per second. A cache that decodes every frame at full
resolution on every keystroke stalls that loop; a cache with no eviction
policy exhausts memory on a folder of any real size. Halcyon's image pipeline
exists to make continuous full-window browsing possible without either
failure mode, and it does so with several purpose-built, independently sized
caches rather than one general-purpose one.

### The sidebar thumbnail lane

The sidebar does not drive its thumbnail prefetch from a `ScrollController`
listener. It is driven by `ListView.builder`'s `itemBuilder`, which reports
the index range it actually built each frame; `ImagePreloadController`
aggregates that into a visible range and fetches from there
<!-- evidence: memory.md AD-014 -->.
The earlier scroll-listener design only recomputed the needed range when the
user was actively scrolling, so a list left scrolled away from the top stayed
blank after a folder reload (star/trash/copy/move all reload the folder)
until the next scroll gesture; `itemBuilder` recomputes for free on every
rebuild, which makes the sidebar self-healing after a cache-clearing reload
<!-- evidence: memory.md AD-014 -->.
A 100ms debounce timer still buffers the resulting requests
(`_thumbnailDebounceTimer`), now paired with a batch-generation counter so a
batch superseded by rapid scrolling or a folder reload aborts before its next
`await` instead of spending a channel round trip on a list that no longer
exists
<!-- evidence: lib/services/image_pipeline/image_preload_controller.dart:779-781 -->
<!-- evidence: memory.md G-001 -->.

Fetch order is visible rows top-to-bottom first, then `thumbnailPrefetchMargin`
= 20 rows outward from each edge of the viewport, alternating below then above
<!-- evidence: lib/services/image_pipeline/image_preload_controller.dart:53 -->
<!-- evidence: lib/services/image_pipeline/image_preload_controller.dart:783-793 -->.
Fetched thumbnail bytes are held in an in-memory byte cache (`_thumbCache`,
a plain `Map<String, Uint8List>`) keyed by photo id and pruned to exactly the
range currently needed — visible range plus margin — on every batch
<!-- evidence: lib/services/image_pipeline/image_preload_controller.dart:91 -->
<!-- evidence: lib/services/image_pipeline/image_preload_controller.dart:795-796 -->.

Payloads at or under 512 KiB pass into that cache untouched — an embedded DNG
preview candidate is already thumbnail-sized. Anything larger is decoded once,
downscaled to a 200px long edge, and re-encoded as JPEG at quality 80
<!-- evidence: lib/services/image_pipeline/sidebar_thumbnail_codec.dart:26-30 -->.
The encoder choice is JPEG, not PNG, and that choice is specific to
photographic content: on the real DNG samples this project measures against,
JPEG at q80 comes out roughly 4–6x smaller than PNG. A synthetic test image
made of flat colour bars inverted that result — PNG beat JPEG on that
fixture — because large flat regions are close to ideal input for PNG's
filter-plus-deflate step and sharp synthetic edges are close to worst-case
input for JPEG's DCT step; that inversion is a property of the fixture's
content, not evidence against JPEG for the photographs the sidebar actually
displays
<!-- evidence: memory.md G-016 -->.

### The main image lane — two tiers

The main preview uses two decode tiers rather than one. Tier one is a
window-resolution decode — a `ResizeImage` wrapping the source bytes at the
current viewport's pixel size — used for immediate display while navigating
<!-- evidence: lib/services/image_pipeline/image_preload_controller.dart:28-39 -->.
Tier two is a full-size decode of the same source, held back until navigation
has been quiet for `tierTwoNavigationDebounce` = 250ms, so continuous
arrow-key browsing never triggers a burst of full-frame decodes for images the
user only passed through
<!-- evidence: lib/services/image_pipeline/image_preload_controller.dart:49 -->.
Scheduling for tier two — the debounce timer, the ±`kTierTwoRadius` window,
and a single sequential decode queue — lives in `TierTwoScheduler`
<!-- evidence: lib/services/image_pipeline/tier_two_scheduler.dart:58-73 -->;
readiness bookkeeping (which id has a resident tier-two entry, for which exact
payload object, and whether its decode listener has actually fired) lives
separately in `TierTwoRegistry`, which is pure state with no timers and no
async of its own
<!-- evidence: lib/services/image_pipeline/tier_two_registry.dart:26-58 -->.
The tier-two decode window is `kTierTwoRadius` = 2 items on either side of the
current photo
<!-- evidence: lib/services/image_pipeline/prefetch_scheduler.dart:32 -->
(the file lives at `lib/services/image_pipeline/prefetch_scheduler.dart` in
this tree's current layout).

### The two window constants that must not be merged

Two constants look interchangeable and are not: `kTierTwoRadius` = 2 governs
which items get a full-size decode, and `kExpensiveStartupRadius` = 1 governs
which items an expensive RAW decode is even allowed to start for
<!-- evidence: lib/services/image_pipeline/prefetch_scheduler.dart:12 -->
<!-- evidence: lib/services/image_pipeline/prefetch_scheduler.dart:32 -->.
Before this split, one shared constant served both meanings, and widening it
to grow the full-size preview window silently also widened how many expensive
RAW decodes could start at once — from three sequential items to five — which
on a folder of RAW files with no embedded preview measured out to roughly 42
seconds of cold settle time instead of roughly 25, at a measured 8.5 seconds
per sequential expensive decode
<!-- evidence: memory.md AD-018 -->.
The two constants were also derived from opposite sample sets and are not
usable as a cross-check on each other: `kTierTwoRadius` is unconstrained by
decode cost, while `kExpensiveStartupRadius` exists specifically to bound how
many concurrent expensive FFI decodes a burst of navigation can trigger
<!-- evidence: memory.md AD-019 -->
<!-- evidence: lib/services/image_pipeline/prefetch_scheduler.dart:5-12 -->.
Which items count as "expensive" is measured from file content, not inferred
from file extension — the old extension-based rule was wrong on roughly 13 of
every 14 files it classified
<!-- evidence: lib/services/image_pipeline/prefetch_scheduler.dart:44-47 -->.
A future contributor's instinct will be to fold these two constants back into
one because they look like the same number; the reason not to is that
"decode this many full-size previews" and "start this many expensive FFI
calls at once" are different questions whose answers happen to currently be
close in magnitude, not the same question asked twice.

### The retention cache and its eviction policy

`PhotoPayloadCache` keeps one retention window of payload bytes centred on the
selected photo: 3 items before it and 5 after, asymmetric because browsing is
overwhelmingly forward
<!-- evidence: lib/services/image_pipeline/photo_payload_cache.dart:6-10 -->,
and evicts by total resident byte cost against a budget, `kPayloadByteBudget`
= 224 MiB
<!-- evidence: lib/services/image_pipeline/photo_payload_cache.dart:31 -->.

This is a FIFO over that window, not a least-recently-used cache. The only
read operation that used to bump an entry's position on access had no callers
anywhere in the codebase and was deleted; iteration order is therefore
insertion order, and the budget path evicts the oldest entry first when the
window itself is over budget
<!-- evidence: memory.md AD-023 -->
<!-- evidence: lib/services/image_pipeline/photo_payload_cache.dart:54-60 -->.
The reason a plain FIFO is the right design here, rather than a missing
feature: access to this cache is a moving cursor advancing through a sorted
list, not random access into a keyed store. Under that access pattern,
insertion order and recency of use are the same ordering — whichever item
entered the window least recently is also, structurally, the one the user is
currently furthest from — so tracking last-access time on top of that would
add bookkeeping without changing which entry gets evicted.

### The image cache budget

Flutter's own `ImageCache` byte ceiling is derived from physical memory
rather than hardcoded: a quarter of physical memory, clamped to a floor of
256 MiB and a ceiling of 768 MiB
<!-- evidence: lib/services/image_pipeline/cache_budget.dart:32-38 -->.
The floor is the point below which this pipeline's no-re-decode guarantee
stops holding; the ceiling is the size this app's desktop target currently
ships with. `dart:io` on the Dart version this project builds against exposes
no platform-neutral total-physical-memory API, so the derivation function
takes physical memory as an optional injected parameter and falls back to the
768 MiB ceiling as its default when no reading is supplied
<!-- evidence: lib/services/image_pipeline/cache_budget.dart:4-10 -->.

The 224 MiB payload budget and the 768 MiB `ImageCache` ceiling are sized
against opposite sample corpora and are not interchangeable proof of each
other: the payload budget is sized against the expensive, no-embedded-preview
RAW corpus (window-resolution RGBA pixels, ~22.4 MiB per item measured), while
the `ImageCache` ceiling is sized against the cheap, preview-bearing corpus,
where a single item holds a full native-size tier-two entry (~91.55 MiB at 24
MP) alongside a separate tier-one entry
<!-- evidence: memory.md AD-019 -->
<!-- evidence: lib/services/image_pipeline/cache_budget.dart:18-25 -->.
Simplifying either number using the other as a reference silently breaks the
one not being looked at.

### The cache key identity pitfall

Both the tier-one and tier-two provider factories, `tierOneProviderFor` and
`fullSizeProviderFor`, must be called with the same `bytes` object identity —
and, for tier one, the same `width`/`height` — everywhere they are used to
display or precache a given payload
<!-- evidence: lib/services/image_pipeline/image_preload_controller.dart:23-44 -->.
Flutter's `ImageProvider` cache key (`ResizeImageKey` for tier one, the
`MemoryImage` itself for tier two) is only equal — and therefore only resolves
as a cache hit — when all of those inputs match exactly; a caller that
rebuilds a provider from a copy of the bytes, or with a different target size,
gets a silent second decode into a second cache entry instead of a hit on the
existing one. This is why both provider factories are kept side by side as
free functions rather than being constructed ad hoc at each call site, and why
`TierTwoScheduler` receives `fullSizeProviderFor` as an injected supplier
closure rather than rebuilding its own copy
<!-- evidence: lib/services/image_pipeline/tier_two_scheduler.dart:29-37 -->.
Anyone extending this pipeline with a new call site for either tier must reuse
the same payload object and the same factory function, not reconstruct an
equivalent-looking provider.

### Summary

| Cache | Lane | Holds | Sized by | Eviction |
|---|---|---|---|---|
| Sidebar byte cache (`_thumbCache`) | Sidebar thumbnails | Small encoded bytes (passthrough or re-encoded JPEG q80) per visible+prefetch id | Visible range + `thumbnailPrefetchMargin` (20) rows on each side <!-- evidence: lib/services/image_pipeline/image_preload_controller.dart:53 --> | Pruned to exactly the currently-needed id set on every batch <!-- evidence: lib/services/image_pipeline/image_preload_controller.dart:795-796 --> |
| `PhotoPayloadCache` | Main image, both tiers | Retained `SourcePayload` bytes/pixels, one per photo id | -3..+5 item window, `kPayloadByteBudget` = 224 MiB total <!-- evidence: lib/services/image_pipeline/photo_payload_cache.dart:6-10,31 --> | FIFO by insertion order once over budget; hard window sweep drops anything outside -3..+5 regardless of budget <!-- evidence: memory.md AD-023 --> |
| `TierTwoRegistry` state | Main image, tier two | Bookkeeping only: which id has a resident tier-2 `ImageCache` entry, for which payload object, and whether it is ready | ±`kTierTwoRadius` (2) window <!-- evidence: lib/services/image_pipeline/prefetch_scheduler.dart:32 --> | Explicit `evict()` per id when it leaves the window, or `clear()` on reset <!-- evidence: lib/services/image_pipeline/tier_two_registry.dart:221-240 --> |
| Flutter `ImageCache` | Both tiers, decoded frames | Decoded `ui.Image` frames keyed by provider identity | Derived from physical memory, clamped to [256 MiB, 768 MiB] <!-- evidence: lib/services/image_pipeline/cache_budget.dart:32-38 --> | Flutter's own LRU-by-byte-budget engine; entries also explicitly evicted when their tier-1/tier-2 bookkeeping id leaves its window |

<!-- evidence: lib/services/image_pipeline/image_preload_controller.dart:699-707 -->
