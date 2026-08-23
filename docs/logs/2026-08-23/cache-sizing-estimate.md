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
