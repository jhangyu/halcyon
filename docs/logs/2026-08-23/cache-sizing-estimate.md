# Cache sizing estimate — `kPayloadByteBudget` and `imageCacheMaxBytes`

> Date: 2026-08-23 · Author: m3-impl-1-opus · **Estimate only. No code was changed.**
> The user sets both constants personally; this is the arithmetic to set them from.

**UNITS: MiB throughout** (÷ 1 048 576), declared once here. Raw byte counts are pinned
for everything load-bearing. Where the brief's figures (48.8 / 96) are quoted they are
**decimal MB**; their MiB equivalents are 48.0 and 91.55, and this document uses the MiB
forms. RGBA is 4 bytes/pixel everywhere.

---

## 1. The constants today

| Constant | Value | Source |
|---|---|---|
| `imageCacheMaxBytes` | `500 << 20` = 500 MiB (524 288 000 B) | `lib/main.dart:12`, applied `:15` |
| `kPayloadByteBudget` | `256 * 1024 * 1024` = 256 MiB (268 435 456 B) | `lib/services/photo_payload_cache.dart:19` |
| Retention window | −3 .. +5 = **9 slots** | `photo_payload_cache.dart:6,10`, applied `:123-124` |
| Sidebar prefetch margin | 20 each side | `image_preload_controller.dart:53` |

Composed admissible total before any eviction is obliged to fire: **756 MiB**.

## 2. Measured pixel dimensions for THIS corpus

Not quoted — read from the files with `exiftool`.

| Group | Count | Pixels | Note |
|---|---|---|---|
| Xiaomi 2304FPN6DC (`2024-07-*`) | 12 | 4096 × 3072 = 12 582 912 (12.6 MP) | no embedded preview → RAW decode |
| vivo V2337A (`IMG_20251112`) | 1 | 4096 × 3072 = 12 582 912 | no embedded preview |
| Panasonic DC-S9 (`2026-*`) | 13 | **embedded preview 6000 × 4000 = 24 000 000 (24 MP)** | cheap rung |

**The worst-case tier-2 entry comes from the CHEAP corpus, not the expensive one.** The
preview-bearing files carry a 24 MP embedded JPEG; the no-preview files are 12.6 MP.

## 3. Per-entry cost, each cited to code

### 3.1 Tier-2 (full size) — two different costs, by payload kind

`_fullSizeProviderForPayload` (`image_preload_controller.dart:747-751`) branches:

| Payload kind | Provider | Decoded bitmap | Per entry |
|---|---|---|---|
| `EncodedPayload` (JPEG / preview-bearing) | `fullSizeProviderFor` → **`MemoryImage`, no resize** (`:44`, `:749`) | full native size | 6000×4000×4 = 96 000 000 B = **91.55 MiB** |
| same, were the JPEG 4096×3072 | as above | full native size | 50 331 648 B = **48.0 MiB** |
| `PixelPayload` (no-preview RAW) | `RawPixelsImage(payload)` (`:750`) | already window-sized | = payload byteCost, **22.4 MiB** measured |

This is the single most important line in the table: a no-preview RAW does **not** cost a
48 MiB tier-2 entry, because its payload was already downscaled to the window. A
preview-bearing DNG costs **91.55 MiB**, four times more.

### 3.2 Tier-1 (window resolution)

`tierOneProviderFor` = `ResizeImage(..., policy: fit)` (`image_preload_controller.dart:28-39`);
the view computes the target as `constraints.maxWidth/Height × devicePixelRatio`
(`lib/views/main_detail_view.dart:257-259`).

**DPR assumption stated explicitly: DPR = 2.0**, the value measured during the AC8 runs
(display 3840×2160 presenting a 1920×1080 UI). Window 1440×900 logical → 2880×1800 target box.

| Source aspect | Fitted | Pixels | Cost |
|---|---|---|---|
| 3:2 (6000×4000) | 2700×1800 | 4 860 000 | 19 440 000 B = **18.54 MiB** |
| 4:3 (4096×3072) | 2400×1800 | 4 320 000 | 17 280 000 B = **16.48 MiB** |

**Area scales with DPR², and this is the term most likely to surprise whoever sets the
number later.** Same 1440×900 window: DPR 1.0 → 4.63 MiB (3:2); DPR 2.0 → 18.54 MiB;
DPR 3.0 → 41.7 MiB. A future 3× display multiplies the whole tier-1 row by 2.25 against
today's figures with no code change at all.

### 3.3 Payload window (`byteCost` sum)

| Corpus | Per payload | 9 slots |
|---|---|---|
| No-preview RAW (**measured**, `tmp/verify/ac8-perf.log`) | 23 486 400 B = 22.4 MiB, and 16 263 400 B = 15.5 MiB | **201.6 MiB** worst |
| Preview-bearing (encoded JPEG bytes, measured by extraction) | 800 935 – 2 701 482 B = 0.76 – 2.58 MiB | **23.2 MiB** worst |

The two differ by ~9×: a RAW payload holds decoded RGBA, a JPEG payload holds compressed bytes.

### 3.4 Sidebar, ~60 thumbnails

**The two figures are different LAYERS, not a contradiction, and both cost memory — in
different pools.** Both are line items below; each was verified from code rather than
assumed, because including an encoded term that is actually dropped, or omitting one that
is actually retained, is a silent factor-of-N error in either direction.

| Layer | Size | Source | 60 entries |
|---|---|---|---|
| Encoded bytes, **retained** | **200 px** long edge, JPEG | `native_thumbnail_service.dart:5` (`sidebarThumbnail(targetSize: 200)`) | ~15 KiB each → **~0.9 MiB** (estimate: encoded size is not instrumented) |
| Decoded bitmap in ImageCache | **32 × DPR** = 64 px long edge at DPR 2.0 | `lib/views/sidebar_view.dart:284-289` (`ResizeImage`, `policy: fit`) | 64×43×4 ≈ 11 KiB each → **~0.66 MiB** |

**VERIFIED — the encoded bytes ARE retained, and they ARE bounded.** They live in
`Map<String, Uint8List> _thumbCache` (`image_preload_controller.dart:84`), written at
`:841`, read at `:182`. The map is not unbounded: `:812` prunes it every batch with
`removeWhere((key, _) => !neededThumbIds.contains(key))`, against the id set built at
`:803-811` from the visible range plus `thumbnailPrefetchMargin` (20, `:53`) on each side.
So the encoded row is a real line item and it is capped at the 20 + visible + 20 set — it
does **not** grow with folder size. It is additionally cleared wholesale on reset (`:231`).

**VERIFIED — the M1 decoded cap is present on the only sidebar decode path.**
`sidebar_view.dart` constructs exactly one image (`:284-289`), and it is
`ResizeImage(MemoryImage(thumbBytes), …, policy: ResizeImagePolicy.fit)` under the
`32 × devicePixelRatio` cap computed at `:281`. There is no second, uncapped path: a grep
for `Image(`/`MemoryImage`/`ResizeImage`/`thumbnailBytesFor` across that file returns only
those lines. Nothing decodes sidebar thumbnails at the full 200 px. (File read-only here;
nothing in it was changed.)

**Finding: the sidebar is ~1.6 MiB total across BOTH pools and is not a driver of either
budget.** Even if every thumbnail decoded at the full 200 px it would be ~9.8 MiB — still
not a driver. Anyone sizing these constants can ignore the sidebar; it is three orders of
magnitude below the tier-2 row. The DPR² scaling applies here too, but on a term this small
it is immaterial: at DPR 3.0 the decoded row is ~1.5 MiB rather than ~0.66 MiB.

### 3.5 Engine / raster remainder — a RESIDUAL, not a measurement

From the AC8 M3 run (6 payloads resident, all no-preview RAW):

```
accounted bitmaps = 6 × (payload 22.4 + tier-2 22.4 + tier-1 16.48) = 367.7 MiB
measured peak                                                       = 900.0 MiB
RESIDUAL (unattributed)                                             = 532.3 MiB
```

**This 532.3 MiB is a subtraction, not an observation.** Nothing was profiled; it is
whatever the measured peak exceeded the bitmaps I could account for. It may contain engine
and raster arenas, Metal driver allocations, the native RAW decoder's working buffers,
transient decode copies, and allocator slack that never returned to the OS. Carrying it
into a budget as if it were a measured constant is exactly how an unverified number becomes
load-bearing, so it is quarantined in its own row below and marked. The independent cache
analysis reached only ~275–370 MB of decoded bitmaps against ~1 GiB measured, i.e. it hit
the same wall from the other direction.

## 4. Totals for the user's target scenario

Scenario: **9 resident tier-2 entries, full-size instant back-and-forth, no re-decode**,
plus tier-1 across the window, plus the payload window, plus 20+visible+20 sidebar.

### 4.1 Worst-case corpus — all 9 slots preview-bearing (24 MP each)

| Component | Arithmetic | MiB |
|---|---|---|
| Tier-2 × 9 | 9 × 91.55 | **823.97** |
| Tier-1 × 9 | 9 × 18.54 | 166.86 |
| Payload window | 9 × 2.58 | 23.24 |
| Sidebar (both pools) | 0.9 + 0.66 | 1.56 |
| **Bitmaps subtotal** | | **1015.6** |
| Residual *(unattributed)* | | *532.3* |
| **Indicative total** | | **~1548** |

### 4.2 Typical corpus — the real 26-file mix, ~5 cheap + 4 expensive in a window

| Component | Arithmetic | MiB |
|---|---|---|
| Tier-2 | 5 × 91.55 + 4 × 22.4 | **547.35** |
| Tier-1 | 5 × 18.54 + 4 × 16.48 | 158.62 |
| Payload window | 5 × 2.58 + 4 × 22.4 | 102.50 |
| Sidebar | | 1.56 |
| **Bitmaps subtotal** | | **810.0** |
| Residual *(unattributed)* | | *532.3* |
| **Indicative total** | | **~1342** |

## 5. Recommended pairs, and what breaks first if set lower

| Case | `kPayloadByteBudget` | `imageCacheMaxBytes` |
|---|---|---|
| Worst-case corpus | **32 MiB** | **1024 MiB** |
| Typical corpus | **128 MiB** | **768 MiB** |
| Expensive-heavy (9 no-preview RAW) | **224 MiB** | **384 MiB** |

- **Worst-case (32 / 1024):** what breaks first if the ImageCache is set lower is the
  *instant back-and-forth guarantee itself* — below ~991 MiB the LRU must evict a tier-2
  entry that is still inside the −3..+5 window, so stepping back re-decodes a 24 MP JPEG
  (91.55 MiB re-allocated, plus decode latency) at exactly the moment the user expects an
  instant frame.
- **Typical (128 / 768):** what breaks first is *asymmetric back-navigation* — the mixed
  window fits going forward, but the cheap 91.55 MiB entries evict the RAW ones ahead of
  schedule, so backward steps onto no-preview files re-enter the sequential RAW rung and
  the spinner returns for ~8.5 s per item (measured settle, `tmp/verify/ac8-perf.log`).
- **Expensive-heavy (224 / 384):** what breaks first is the *payload budget*, not the image
  cache — below ~202 MiB a RAW payload is evicted while still inside the retention window,
  and re-entering it costs a full sequential RAW decode rather than a cache hit, which is
  the one cost M3's retention design exists to avoid.

Payload budgets are set just above the row they must hold (201.6 / 102.5 / 23.2 MiB) rather
than at a round larger number, because unused payload budget is not free: it is headroom the
LRU will happily fill before evicting anything.

## 6. The answer the arithmetic actually gives

**The user's stated target does not fit in any budget that could be called modest, and the
reason is one line of code.** Nine resident full-size entries cost **823.97 MiB of ImageCache
alone** in the worst case — before tier-1, before payloads, before the 532 MiB residual —
because tier-2 is a bare `MemoryImage` with no resize (`image_preload_controller.dart:44`)
and this corpus's embedded previews are 24 MP. Raising `imageCacheMaxBytes` to ~1 GiB would
buy the scenario as specified, at a process footprint around 1.5 GiB.

Stating this plainly as instructed rather than designing around it: **this scenario costs
~1.5 GiB worst case and ~1.3 GiB typical, and that is large.** What to do about it is the
user's decision. For completeness, the arithmetic shows the dominant term is tier-2 decode
size and not entry *count* — which is why the constants alone cannot make this scenario cheap.

## 7. What this estimate does not establish

1. The 532.3 MiB residual is unattributed. Every total carrying it is indicative, not predicted.
2. The 200 px thumbnail's encoded size (~15 KiB) is an estimate; it is not instrumented.
   That it is RETAINED and BOUNDED is verified from code (§3.4); only the per-entry byte
   size is estimated, and it is far too small to affect any recommendation.
3. All figures assume DPR 2.0 and a 1440×900 logical window. Tier-1 scales with DPR².
4. Real peaks depend on eviction timing, which no static arithmetic captures — the analysis
   sizes what may be *resident*, not what the allocator returns to the OS.
5. No measurement here is new: this is arithmetic over the AC8 artifacts in `tmp/verify/`
   and code constants, not a fresh run.

---

# Addendum — revised guarantee (window −3..+5 no re-decode, FULL-SIZE only −2..+2)

> Added 2026-08-23 by m3-impl-1-opus at the user's direction. Doc-only; no constant touched.
> **Once the user confirms a number from §A.4, THIS ADDENDUM — not §5 above — is the
> authoritative sizing section, and the three pairs in §5 are superseded.** §5 is retained
> because it sizes a different (all-9-full-size) guarantee and is the comparison that shows
> what the revision buys.

Same conventions: **MiB**, raw bytes pinned, DPR **2.0**, logical window 1440×900, RGBA 4 B/px.
**All photos assumed 6000×4000 (24 MP)** per the user's instruction. Recomputed, not quoted.

| Quantity | Arithmetic | Value |
|---|---|---|
| Full-size tier-2 entry | 6000×4000×4 = 96 000 000 B | **91.55 MiB** |
| Screen-resolution tier-1 entry | 3:2 fitted into 2880×1800 → 2700×1800×4 = 19 440 000 B | **18.54 MiB** |

## A.1 User correction — full-size is FIVE

The user has resolved the count: **"5 full-size, I had missed counting the currently-displayed
one."** Full-size therefore spans −2..+2 **inclusive of current = 5 entries**. The A/B/C reading
split from the first draft of this addendum is closed; only a smaller question remains (§A.3).

## A.2 TWO CODE FACTS THAT CHANGE THE ARITHMETIC — verified, not assumed

Both were checked in the source before being used. Each moves the answer by more than the
question they were checked for.

### Fact 0 — the requested guarantee needs BOTH spans widened; it is a CODE change

| Layer | Span the code does TODAY | Span the revised guarantee needs |
|---|---|---|
| Screen-resolution (tier-1) | **±2 = 5 slots** (`:701-702`) | −3..+5 = **9 slots** |
| Full-size (tier-2) | **±1 = 3 slots** (`:393-397`, `kExpensiveStartupRadius = 1`, `prefetch_scheduler.dart:12`) | ±2 = **5 slots** |

**Neither span can be changed by setting a constant.** `imageCacheMaxBytes` and
`kPayloadByteBudget` govern how much may be RETAINED, not how far the precache reaches. The
revised guarantee therefore requires widening `_precacheTierOneWindow` and the tier-2 span in
`_decodeTierTwoWindow` — a code change, out of scope here, and something the user should know
before these numbers become the spec. The totals below size the guarantee **as requested**,
i.e. they describe the state after that code change, not today's behaviour.

### Fact 1 — tier-1 is precached across **±2**, NOT the whole −3..+5 window

`_precacheTierOneWindow` (`image_preload_controller.dart:696-724`) iterates
`tierStart = currentIndex − 2` to `tierEnd = currentIndex + 2` (`:701-702`) — **five slots** —
and then **EVICTS** the tier-1 entry of every id outside that span (`:716-724`).

Consequence: **the outer window slots (−3, +3, +4, +5) hold NO ImageCache entry at all today.**
They retain a payload and nothing more. So the revised guarantee's "screen-resolution for the
remaining slots" is **not what the code currently does**, and it cannot be obtained by setting
constants — `_precacheTierOneWindow`'s ±2 span would have to be widened, which is a code change
and out of scope here. This is flagged, not designed around.

### Fact 2 — tier-1 and tier-2 coexist **only for encoded payloads**

| Payload kind | tier-1 provider | tier-2 provider | Same ImageCache key? |
|---|---|---|---|
| `EncodedPayload` | `ResizeImage(MemoryImage(bytes), …)` (`:28-39`, via `:738-742`) | bare `MemoryImage(bytes)` (`:44`, `:749`) | **NO — two entries coexist** |
| `PixelPayload` | `RawPixelsImage(payload)` (`:744`) | `RawPixelsImage(payload)` (`:750`) | **YES — ONE shared entry** |

The pixel case is deliberate and documented in-source at `:726-730`: pixels are already at
window resolution, so "both tiers use the same provider for that kind, which also means they
share one ImageCache entry instead of decoding the same pixels twice."

So the coexistence term is real — but it applies to **preview-bearing files only**, and the
span over which it applies is ±2, not 9. A no-preview RAW costs **one** 22.4 MiB entry serving
both tiers, not two.

## A.3 The remaining reading split, and it is small

The user says the screen-resolution remainder is "1+2" (3 entries); the −3..+5 window leaves
**four** non-full-size slots (−3, +3, +4, +5). Both computed. Note that under Fact 1 **neither
is what runs today** — today the outer slots have no entry at all.

## A.4 ImageCache totals — all photos 6000×4000, DPR 2.0, sidebar 1.6 MiB included

Per-entry (recomputed): full-size **91.55 MiB** (96 000 000 B) · screen-res **18.54 MiB**
(19 440 000 B) · RAW shared entry **22.4 MiB** (23 486 400 B, measured).

**Cheap-heavy — every file preview-bearing (the expensive case for memory):**

| Configuration | Arithmetic | ImageCache |
|---|---|---|
| **As the code behaves TODAY** — tier-2 ±1 (3 slots), tier-1 ±2 (5 slots), coexisting | 3 × 91.55 + 5 × 18.54 + 1.6 | **368.95 MiB** |
| Guarantee as requested, 3 outer screen-res *(needs the Fact 0 code change)* | 5 × (91.55 + 18.54) + 3 × 18.54 + 1.6 | **607.68 MiB** |
| Guarantee as requested, 4 outer screen-res — **covering** *(same code change)* | 5 × (91.55 + 18.54) + 4 × 18.54 + 1.6 | **626.22 MiB** |

The `5 × (91.55 + 18.54)` term is the **coexistence charge**: each of the five full-size slots
also holds its own screen-resolution entry, because the two are different ImageCache keys and
the tier-2 sweep "never touches `_tierOneKeys`" (`:385-388`). That is **+92.70 MiB** over a
naive "5 full-size + 4 screen-res" model, and it is what moves the recommendation.

**Expensive-heavy — every file no-preview RAW (one shared entry per item):**

| Configuration | Arithmetic | ImageCache |
|---|---|---|
| As today (±2) | 5 × 22.4 + 1.6 | **113.59 MiB** |
| + 3 outer | 8 × 22.4 + 1.6 | **180.79 MiB** |
| + 4 outer | 9 × 22.4 + 1.6 | **203.19 MiB** |

A ~3× spread between corpora at the same pixel dimensions, because the rung decides whether an
item costs two entries or one.

## A.5 Payload row — 9 slots (unchanged by the full-size split)

| Mix | Retained | Per slot | 9 slots |
|---|---|---|---|
| Cheap-heavy | encoded JPEG bytes | 0.76 – 2.58 MiB measured | **23.22 MiB** |
| Expensive-heavy | window-sized RGBA | 22.4 MiB measured | **201.59 MiB** |

Fixing the pixel dimensions does **not** fix the rung; a budget sized for the cheap mix evicts
in-window RAW payloads and the symptom is a spinner, not an error.

## A.6 RECOMMENDED PAIR — the future spec

# `kPayloadByteBudget = 224 MiB` · `imageCacheMaxBytes = 768 MiB`

> **YES — THE COEXISTENCE TERM CROSSES A CONSTANT BOUNDARY. 640 MiB IS NOT ENOUGH; USE 768.**
> Without the +92.70 MiB coexistence charge the requirement is ~533 MiB and 640 MiB would have
> looked sufficient. With it the requirement is **626.22 MiB**, which leaves 640 MiB only 2.2%
> of headroom — a cache sized that close to its working set evicts the entry the guarantee just
> promised. This single term is the difference between the right constant and a confidently
> wrong one.

**Does the 3-versus-4 outer-entry split additionally cross a boundary? NO — under a consistent
headroom policy.** 607.68 × 1.15 = 698.8 and 626.22 × 1.15 = 720.1; both land on **768 MiB**. The single
extra entry does *not* move the recommendation. (It would matter only under a bare-minimum
policy: 607.68 fits inside 640 MiB with 5% headroom, 626.22 does not. 640 MiB is not
recommended either way — a cache sized within ~3% of its working set thrashes at the boundary,
evicting the entry the guarantee just promised.)

**What breaks first if set lower:**
- **`imageCacheMaxBytes` below ~626 MiB** — the LRU evicts a full-size entry from inside ±2,
  which is precisely the span the revised guarantee promises re-decode-free. The guarantee
  fails before any other symptom is visible, and it fails on the preview-bearing corpus first
  because those items hold two entries each.
- **`kPayloadByteBudget` below ~202 MiB** — an in-window RAW payload is dropped, and re-entering
  that slot costs a full sequential RAW decode (~8.5 s measured) rather than a cache hit.
  224 MiB carries ~11% headroom over the 201.59 MiB expensive-heavy row. 32 MiB would serve a
  purely preview-bearing corpus, but fails hard on a folder of phone RAWs.

> **THE TWO CONSTANTS ARE SIZED AGAINST DIFFERENT WORST CASES, AND NEITHER CAN BE
> SANITY-CHECKED AGAINST THE OTHER.** `imageCacheMaxBytes` is driven by the **cheap**
> (preview-bearing) mix, because those files decode a 24 MP bitmap and hold two cache entries
> each. `kPayloadByteBudget` is driven by the **expensive** (no-preview RAW) mix, because those
> retain 22.4 MiB of pixels per slot while a JPEG payload retains ~2.6 MiB. A single pair must
> therefore take the maximum of each independently. Anyone later "simplifying" the pair by
> reasoning about one corpus — or by scaling one constant from the other — will get one of the
> two wrong, and the failure will be silent until it is a spinner or a re-decode.

## A.7 What the revised guarantee gives up

Stepping to ±3..±5 and back re-decodes tier-2 for that item:
- **91.55 MiB** re-allocated per re-decode.
- **~119 ms** for a 24 MP JPEG — scaled from a REAL measurement in our artifacts,
  `tmp/verify/ac8-baseline-stdout.txt`: `micro.decode|0|2800x2097|total=29112`, i.e. **29.1 ms
  measured** at 5 871 600 px. 24 MP is 4.09× that. **The 29.1 ms is measured; the 4.09× scaling
  to 119 ms is an inference** — decode is not perfectly linear in pixels.
- On a **no-preview RAW** the same excursion costs a full sequential RAW decode instead:
  **~8.5 s measured** (`tmp/verify/ac8-perf.log`). Two orders of magnitude worse. The revised
  guarantee is cheap for JPEG-backed files and expensive for RAW ones.
- Under Fact 1, today those outer slots additionally have no screen-resolution entry to fall
  back on, so the excursion return is a full decode rather than a resolution step-down.

## A.8 Versus §5, and what is still unattributed

| | All 9 full-size (§5) | Revised guarantee (A.4 covering, cheap-heavy) |
|---|---|---|
| ImageCache required | ~991 MiB | **~626 MiB** |
| Recommended constant | 1024 MiB | **768 MiB** |
| Bitmaps + payload | 1015.6 MiB | 626.22 + 23.22 = **649.4 MiB** |
| Indicative process total | ~1548 MiB | **~1182 MiB** |

Both totals carry the **unattributed 532.3 MiB residual** (§3.5) — a subtraction, not a
measurement, and still the largest single term in each. The revision saves ~365 MiB of
ImageCache requirement against the all-9-full-size guarantee.
