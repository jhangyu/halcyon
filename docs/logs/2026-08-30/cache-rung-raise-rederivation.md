# Cache-rung raise re-derivation (512/384/256 MiB)

> Date: 2026-08-30 · Author: impl-cache-rungs-sonnet
> Re-walks docs/logs/2026-08-28/cache-sizing-rederivation.md §2 for the raised
> payload-budget rung values. User ruling: raise the three rung budgets from
> 384/304/224 MiB to 512/384/256 MiB (task dispatch IS the authorization for
> exactly these numbers). Only the payload byte budgets change; `before`,
> `after`, the RAM triggers, and the ImageCache ceiling (§2.1/§2.2 of the
> 08-28 doc) are unchanged and not re-derived here.

## Trigger

docs/logs/2026-08-30/shared-payload-fill-report.md measured that the shipped
embedded-JPEG-normalised path needs **316.61 MiB** for a top-60 set — this
exceeds both the previous mid rung (304 MiB) and the previous floor rung
(224 MiB).

## 1. What changed, what didn't

| Constant | Old | New | File:line |
|---|---|---|---|
| floor (`kPayloadByteBudget`) | 224 MiB (234,881,024 B) | **256 MiB (268,435,456 B)** | `photo_payload_cache.dart:35` |
| mid (`RetentionTier.balanced`) | 304 MiB (318,767,104 B) | **384 MiB (402,653,184 B)** | `retention_policy.dart:106` |
| high (`RetentionTier.generous`) | 384 MiB (402,653,184 B) | **512 MiB (536,870,912 B)** | `retention_policy.dart:112` |

`before`/`after`/RAM triggers/ImageCache ceiling: unchanged (still 3/{5,8,11},
12 GiB / 32 GiB, 768 MiB fixed ceiling). §2.1/§2.2 of the 08-28 doc (ImageCache
sizing) are **not** affected by this change — that pool is sized independently
of the payload byte budget (08-28 doc's own framing: "the payload tier is not
the problem; the ImageCache ceiling is"). No formula in the 08-28 doc derives
the ImageCache ceiling FROM the payload budget, so nothing there needed
updating.

## 2. Re-walked §2.3 arithmetic (payload byte budget — the pool this raise touches)

Same formula as 08-28 §2.3: expensive-corpus payload row = `slots × 22.4 MiB`.
Slot counts are unchanged (`before` + `after` + 1 = 9 / 12 / 15).

| Rung | slots | payload required | OLD budget | OLD headroom | NEW budget | NEW headroom |
|---|---|---|---|---|---|---|
| floor | 9 | 201.6 MiB | 224 MiB | 11.1 % | **256 MiB** | **27.0 %** |
| mid | 12 | 268.8 MiB | 304 MiB | 13.1 % | **384 MiB** | **42.9 %** |
| high | 15 | 336.0 MiB | 384 MiB | 14.3 % | **512 MiB** | **52.4 %** |

The raise widens headroom on the expensive (no-preview RAW) corpus at every
rung, which is a strict improvement for that corpus's ~8.5 s re-decode
avoidance guarantee — no formula here breaks or needs a different shape.

## 3. Accepted floor-rung limitation (KNOWN, not fixed)

The 316.61 MiB measured top-60 fill (shared-payload-fill-report.md) is the
**embedded-JPEG-normalised** path, which is a *different* corpus from the
`slots × 22.4 MiB` no-preview-RAW row this budget's formula is derived
against (see `photo_payload_cache.dart:17-22`: "opposite corpus from the one
that sizes `imageCacheBudgetBytes`"). Checked directly against the new floor:

    316.61 MiB / 256 MiB = 123.7%

The floor rung (256 MiB) still does not fully cover a 316.61 MiB top-60 fill.
This is **accepted, not fixed**, by explicit plan ruling **E-M5: no proactive
shrink eviction**. The existing eviction-on-overflow mechanism
(`PhotoPayloadCache._enforceBudget`, `photo_payload_cache.dart:152-164`)
absorbs the excess by evicting the farthest-from-selection entries — it is a
byte-LRU-style cap, not a hard failure, so exceeding the budget degrades to
"fewer items retained, no re-decode-avoidance guarantee for the excess" rather
than any error or memory-limit violation. The mid (384 MiB) and high (512 MiB)
rungs both clear 316.61 MiB comfortably (121% and 161% of it respectively),
so this residual gap is a floor-rung-only, low-RAM-machine case.

## 4. Limits

This is the same class of static byte arithmetic as the 08-28 doc: it re-reads
constants from HEAD code and re-applies the already-established formula. No
new measurement was taken; the 316.61 MiB figure is cited from
shared-payload-fill-report.md, not re-measured here. Live RSS / UI memory
measurement remains user-owned per project rule.
