# Round 2 — Re-review of the B1/B2 fix batch (pass 2)

- Reviewed HEAD: `bbde9602c48d1c8c01eccf60e451a3cfd61fb476`; scope `git diff 5a8684e bbde960` (3 files) only
- Tree clean at start and end of this pass (verified twice)
- New artifacts: `tmp/verify/r2/probe/p_out_bbde960.txt` (B1 probe re-run), `mutant2.dart` + `m3b2_test.dart` + `m3b2_out.txt` (B2 mutation), `p3_test.dart` + `p3_out.txt` (pending-entry semantics), `tmp/verify/r2/reviewer-flutter-test-bbde960.txt`

## Verdict

**1 new blocker (B3). B1 and B2 are genuinely fixed — verified by re-running my own probes, not by reading the diff.** The B1 fix, in replacing the completion flag with a read-time cache check, dropped the "decode has COMPLETED" condition: `ImageCache.containsKey` is also true for a still-pending decode, so `isFullSizeReady` now returns true from the instant a full-size decode STARTS.

## B1 — FIXED (re-verified)

Re-ran the original probe `tmp/verify/r2/probe/p_test.dart` unchanged against bbde960 (`p_out_bbde960.txt`):

```
before (5a8684e): PROBE same_bytes=false ready=true hasCurrent=false hasOld=true
after  (bbde960): PROBE same_bytes=false ready=true hasCurrent=true  hasOld=false
```

The item is re-decoded against its new bytes object and the orphaned old-bytes entry is gone. The identity gate (`image_preload_controller.dart:96-105`) does short-circuit before `containsKey` can consult a stale key, and the `droppedIds` sweep (`:158-171`) plus `_evictTierTwoEntry` (`:266-273`) plus `reset()` eviction (`:114-116`) close the orphan paths. No remaining path found where the display's provider (built from `_imageCache[id]`, the same object the identity check compares) MISSES while readiness reads true — see B3 for the different problem that remains.

## B2 — FIXED (independently mutation-verified)

I did not reuse the old mutant: it is a copy of the PRE-fix controller, so it cannot discriminate the new test. I regenerated `tmp/verify/r2/probe/mutant2.dart` from the bbde960 controller with exactly one change (debounce 250ms -> 0ms; verified by a reverse-diff that the file is otherwise identical to lib/), and replayed the NEW AC3b body against it (`m3b2_out.txt`):

```
MUT2 after step 2 ready(2)=true
Expected: false / Actual: <true>   (mid-burst check at step 2)
Some tests failed.
```

It fails at the FIRST burst step and passes against the shipped code. The rewrite is discriminating; the implementer's claim holds.

## BLOCKER 3 (NEW, introduced by the fix diff) — readiness now reports true while the full decode is still PENDING

**Location:** `lib/services/image_preload_controller.dart:96-105` (`isFullSizeReady`), enabled by `:249-260` (`_decodeFullSizeIntoImageCache`); consumed at `lib/views/main_detail_view.dart:202-203`.

**What the diff removed.** Pre-fix, readiness meant "the decode listener fired" (`_tierTwoReadyIds`, set only on completion). The new `isFullSizeReady` does NOT consult `_tierTwoReadyIds` at all — it returns `key != null && identical(bytes) && imageCache.containsKey(key)`. The completion condition is gone.

**Why that is not equivalent — mechanically established:**
1. `ImageCache.containsKey` returns true for PENDING entries: `return _pendingImages[key] != null || _cache[key] != null;` (SDK image_cache.dart:456-458). Confirmed empirically by `tmp/verify/r2/probe/p3_test.dart`, which inserts a never-completing completer and reads back `PROBE3 containsKey_while_pending=true` (`p3_out.txt`).
2. The key/bytes bookkeeping is registered at decode START, not completion: `MemoryImage.obtainKey` returns a `SynchronousFuture` (SDK image_provider.dart:1694-1696), so the `.then` at `:257-260` runs synchronously right after `provider.resolve` has already inserted the pending entry.

Therefore `isFullSizeReady(id)` flips to true the moment the ~124ms full-frame decode BEGINS.

**Impact.** `main_detail_view.dart:202` then selects `fullSizeProviderFor(bytes)` for an image whose full decode is still running, even though its tier-1 entry is already decoded and resident. With `gaplessPlayback: true` the widget keeps showing the PREVIOUS image until the full-size decode lands, so the perceived switch latency for that image becomes the remaining full-decode time (measured at 124.1ms in perf-measurement-report.md) instead of a tier-1 blit. Reachable on an ordinary browsing rhythm: rest >=250ms (tier-2 starts decoding current+-1), then press next while the neighbour's decode is in flight — the +-1 batch is exactly the images the user is about to navigate to. This is not a cache miss and causes no double decode (the widget joins the same pending completer), but it lands on the same metric the round exists to fix, and it did NOT exist before this diff.

**Why no test catches it:** every test decodes a 1x1 PNG, which completes within a microtask, so the pending window is unobservable there.

**Fix (one line):** re-add the completion condition, e.g. `if (!_tierTwoReadyIds.contains(id)) return false;` at the top of `isFullSizeReady` — keep the identity + containsKey checks (they are what fixed B1), just AND them with the completion flag rather than replacing it. The N1 comment at `main_detail_view.dart:196-202` ("actually resident") should be corrected in the same edit: with the current code "resident" includes "pending".

**Confidence:** mechanism reproduced (probes p3 + SDK source). The user-visible latency figure is inferred from the round's own measurement report, not re-measured — if you prefer, WP5 can bound it, but the code-level defect stands on its own.

## S1 and N1 — confirmed against the code

**S1 CONFIRMED.** `image_preload_controller.dart:367-381`: a `catch (_)` around the loader flushes `_pendingPreviewNotifies[id]` and then `rethrow`s, with `finally` still clearing `_loadingKeys`. Error propagation to `preloadImages` -> `AppState._preloadImages()` is unchanged (still an un-awaited async error, pre-existing). The `bytes == null` carve-out at `:364-366` still drops pending callbacks without calling them — preserved deliberately per your instruction, noted not re-litigated.

**N1 PARTIALLY CONFIRMED.** The comment at `main_detail_view.dart:196-202` now correctly describes a read-time re-check rather than a standing flag, and "the check itself is bookkeeping, not a resolve" is accurate. But "true only when the tier-2 entry for these exact bytes is actually resident" is not accurate while a decode is pending — see B3. Correct it with the B3 fix.

## New should-fix from this pass (parking lot, not gating)

**S5. An LRU-evicted tier-2 entry is never re-decoded while the item stays in the window.** `image_preload_controller.dart:221-229`: the skip gate is `_tierTwoReadyIds.contains(id) && identical(...)`, which does not consult `containsKey`. If ImageCache drops a completed entry under 500MB pressure, `isFullSizeReady` correctly returns false (display safely falls back to tier-1 — no miss, no double decode), but the sweep will keep skipping the re-decode until the item leaves and re-enters the +-1 window. Degradation only, self-healing.

## AC status after this pass

| AC | Verdict |
|---|---|
| AC1 | PASS (S1 now also closed) |
| AC2 | PASS (unchanged, cleared at 5a8684e) |
| AC3a | PASS |
| AC3b | PASS — rewritten test is discriminating, mutation-verified against mutant2 |
| AC3c | PASS |
| AC4 | PASS (unchanged) |
| AC5 | PASS (unchanged; lead's build log at this hash) |
| AC6 | PASS — my own run at bbde960: exit 0, "All tests passed!", 22 executed == 22 declared (6+2+3+9+1+1). No test skipped or weakened; the new BLOCKER-1 regression test wraps its body in `tester.runAsync`. |

**Note on the new B1 regression test** (`test/image_preload_controller_test.dart:477-556`): its final assertion is conditional (`if (isReady) { expect(containsKey(currentKey), isTrue); }`), so a future regression that makes readiness always false would pass it vacuously. AC3a/AC3c both assert `isFullSizeReady == true` elsewhere, so the suite as a whole still pins that direction — noted, not a finding.

## Not verified

- AC7/AC8 (WP5). B3's latency cost in particular would only appear in a measurement run that navigates 250-600ms after a rest; a fixed-cadence harness may miss it entirely.
- Still parked, not re-examined: S3, S4, N2, N3, tier-1 side of reset(), the two earlier WP2 items.

