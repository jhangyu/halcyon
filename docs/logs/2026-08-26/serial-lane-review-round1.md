# Round-1 fresh review — serial-lane unification (reviewer-1, 2026-08-27)

Scope: uncommitted working tree vs `docs/logs/2026-08-26/serial-lane-unification-contract.md`.
Dimensions: correctness + negative space. No edits made.

## 1. Per-criterion verdict

| # | Verdict | Evidence (mine) |
|---|---|---|
| 1 | PASS | `grep -rn "kExpensiveStartupRadius\|allowsExpensiveWork" lib test tool` → 0 hits. Only remaining prose is `image_preload_window_test.dart:12,258`, which states the radius is GONE/retired. |
| 2 | PASS | TC-098a `image_preload_window_test.dart:262-308`; asserts all 9 slots `payloadFor != null` AND `decodeCalls.toSet()` hasLength 9 (binds both directions: full fill + no double decode). Ran green. |
| 3 | PASS (with caveat, see F-1) | TC-098b `:310-375`; `maxInFlight == 1` for the RAW controller and `cheapMaxInFlight > 1` for the JPEG controller — both halves bind. Caveat: the counter is on `dngDecoder` only; `sidebarRawDecoder` is a second, uncounted FFI producer. |
| 4 | PASS | TC-098c `:377-416` asserts full list equality of decoder call paths against `[0,1,-1,2,-2,3,-3,4,5]`. A list-equality assertion cannot pass under any other order. Order is produced by `image_preload_controller.dart:505-519` + `serial_decode_lane.dart:174-178`. |
| 5 | PASS | TC-098d `:418-494`: gate-parked first decode, jump 5→20, `starts` stays length 1 (nothing overtakes in-flight), next start is index 20, and none of the abandoned window 2..10 ever starts. Deterministic (Completer, not wall-clock). Lane body re-check at `image_preload_controller.dart:781`. |
| 6 | PASS | TC-095/096/097/099/100 + TC-239..242 all green in my own run (`flutter test -j 1 test/services/image_pipeline/` → RC=0, 254 tests, "All tests passed!"). TC-240 was updated to near-to-far order, which is the contract-permitted "updated only where they encoded the radius". |
| 7 | PASS | Gate artifact `docs/logs/2026-08-26/full-gate-round1.log`: complete (final `TEST_RC=0` present at line 1667). `ANALYZE_RC=0` at line 4; `01:11 +406: All tests passed!` at line 1666. 406 executed is plausible vs a ~290+ baseline plus this round's additions; no failure/skip lines. |
| 8 | PASS (one nit, F-4) | `docs/sop/memory.md:157` AD-018 titled `〔已被推翻，2026-08-26，見 AD-033〕`; AD-033 recorded at `:352-363`. `docs/sop/unit_test.md:1360-1368` covers TC-098a~d incl. a red→green mutation record; `:1351` updates TC-240. |

## 2. Findings

### F-1 [should-fix] Sidebar RAW decoder is a second FFI producer outside the lane
`image_preload_controller.dart:1027-1045` — `_sidebarRawDecoder(file.path, maxDim: 200)` runs inside the sidebar sweep, which is itself sequential (`await` per loop iteration at `:1012`, `:1042`), but it is NOT on `SerialDecodeLane`. So the pipeline's real ceiling is TWO concurrent RAW decodes, not one.
Pre-existing (this call site is untouched by the diff — `git diff` shows no hunk there). **But the diff materially widens the exposure**: previously the lane-equivalent produced at most 3 expensive payloads behind a 250ms debounce; now a settle queues up to 9 back-to-back decodes, so the odds of overlapping a sidebar RAW thumbnail decode go from occasional to routine on an all-RAW folder.
Why it matters: contract criterion 3's stated intent is "at most ONE expensive decode in flight"; TC-098b constructs its controller without a `sidebarRawDecoder`, so the hole is invisible to the battery.
Suggested fix: route the sidebar decode through the same `SerialDecodeLane` with a third `LaneTaskKind.sidebarThumb` and a priority base above `kFullResPriorityBase` (thumbnails are the least urgent pixels). If out of scope for this round, record it explicitly in AD-033 as a known second producer rather than leaving the "one decode in flight" claim unqualified.

### F-2 [should-fix] Near-to-far insertion makes the SELECTED item the byte-budget's first eviction victim
`photo_payload_cache.dart:112-119` evicts `_entries.keys.first` — FIFO over insertion order, explicitly justified at `:54-60` on the grounds that "the -3..+5 sweep already drops everything outside the window, so arrival order is as good a victim as recency".
That justification held while arrival order was index order (old loop `for (var i = startIdx; i <= endIdx; i++)`). The new loop `image_preload_controller.dart:473` walks near-to-far, and the priority load at `:438` also targets `currentIndex` first, so **index 0 (the item the user is looking at) is now the oldest entry and the first victim**.
Second half of the same finding: before this change an all-RAW folder could only ever hold ~3 `PixelPayload`s, so `_enforceBudget` was practically unreachable; now all 9 slots are RAW, and the sizing comment at `photo_payload_cache.dart:17-31` puts a full window at 201.59 MiB against a 224 MiB budget — 11% headroom. Any corpus/display combination above that (larger `_longEdge`, taller aspect, a mixed window) crosses the budget for the first time, and when it does it drops the selected item, whose next window pass re-enqueues a full RAW decode → visible stall, potentially per navigation event.
Suggested fix (cheap): in `_enforceBudget`, skip the currently selected id as a victim, or make `put` insert non-selected items ahead of the selected one. Alternatively re-derive the budget for the worst-case long edge rather than the measured 22.4 MiB row.

### F-3 [nit] Parked notify callbacks are never released on the two window-refusal returns
`image_preload_controller.dart:781-785` (lane body, item left the window) and `:663` (`if (!_retentionIds.contains(id)) return;` after a successful decode) both return without `_flushPendingNotifies(id)`. Entries accumulate in `_pendingPreviewNotifies` until `reset()` (`:338`).
Not a stranded spinner: the item is out of the retention window, so it is not on screen, and navigating back re-enters `_ensurePayload`, which flushes on the cached/resolved paths (`:563`, `:714`). The `:663` return is pre-existing; the `:781` one is new. Bounded by item count and only leaks closures.
Suggested fix: none required; if desired, drop the parked list for an id at the same moment `retainOnly` evicts it.

### F-4 [nit] Two historical AD "關聯" lines still assert the two-constant rule in the present tense
`docs/sop/memory.md:252` and `:265` read `AD-018（kTierTwoRadius 與 kExpensiveStartupRadius 仍是兩個常數）`. `kExpensiveStartupRadius` no longer exists. memory.md's own policy (`:320`) is that historical entries are not rewritten, and AD-018's own title now carries the overturn marker, so criterion 8 is met — but a future reader grepping for the constant lands on a present-tense claim first.
Suggested fix: append `〔見 AD-033〕` to those two 關聯 clauses.

## 3. Negative space

**(a) Can anything now start two decodes concurrently?**
Mostly no, one exception (F-1). Proof for each probed path:
- *Non-lane callers*: `_ensurePayload` sets `canDoExpensive = onSerialLane` (`:631`) and `onSerialLane` defaults false (`:550`); with `allowExpensive: false` `PhotoSource.load` returns `deferred: true` with a null payload and never touches the decoder (`photo_source.dart:168-177`). The `NativeImageFailure` arm (`:229-241`) only runs the pure-Dart JPEG walker. So a decoder call is reachable only from `photo_source.dart:179` / `loadExpensive`, both gated on `onSerialLane == true`.
- *Only two callers pass `onSerialLane: true`*: `image_preload_controller.dart:791` (lane body) and `tier_two_scheduler.dart:329` (`_runLoadAndChainTierTwo`, itself a lane body via `_enqueueLoad` at `:308-312`). Both are lane task bodies, and `SerialDecodeLane._pump` (`serial_decode_lane.dart:120-138`) awaits each body to completion before taking the next, with `_running` re-entrancy guard at `:121`. → single flight.
- *Piggyback*: `image_preload_controller.dart:724-736` consumes `outcome.fullRes` already produced by the decode that just ran; `publishPiggybackFullRes` starts no decoder.
- *Tier-2 catch-up upgrades*: `_enqueueFullResUpgrade` (`tier_two_scheduler.dart:365-383`) is enqueued on the same lane under a distinct key kind, so it serialises with payload production instead of racing it. The `(kind, id)` record key (`serial_decode_lane.dart:11-20`) correctly avoids the string-prefix collision class it documents.
- *Deferred re-enqueue*: `:701-707` enqueues rather than decodes; the re-enqueue happens while the original call is still inside its `try`, but that call did no decode (deferred ⇒ `allowExpensive` was false).
- *Duplicate decode via re-enqueue of an in-flight key*: the lane treats an in-flight key as not pending (`serial_decode_lane.dart:74-76`), so a second entry can be created. I traced it: the duplicate body re-enters `_ensurePayload`, hits `_cache.contains(id)` (`:553`) or `_loadingKeys.contains(id)` (`:574`) and returns without decoding. TC-098a's `decodeCalls.toSet() hasLength 9` is exactly the regression guard for this. No double decode.
- *Sidebar*: see F-1 — the one real second producer.

**(b) Generation / staleness — can a serial task write into a cleared cache or resurrect an evicted id?**
No. Three independent guards, all re-checked after the awaits:
- `_ensurePayload:663` refuses the `_cache.put` unless `_retentionIds.contains(id)`; `reset()` sets `_retentionIds = {}` (`:341`) and `preloadImages` reassigns it synchronously at `:418` before any await.
- `_precacheTierOneFor:803-804` re-checks retention AND `identical(_cache.peek(id), payload)` before decoding into ImageCache, so a dead folder cannot get a tier-1 entry.
- Piggyback at `:725-729` requires `identical(_cache.peek(id), payload)` — after `reset()` the cache is empty, so it is false.
- `reset()`/`dispose()` call `_serialLane.clearPending()` (`:341`, `:368`), so only the one in-flight task survives a folder change, and it is neutralised by the above.
One asymmetry worth noting (not a finding): `TierTwoScheduler._windowIds` is NOT cleared by `cancelDebounce()`/reset, so it can hold dead-folder ids. Harmless because every consumer of it also requires a live payload (`tier_two_scheduler.dart:335`, `:376`), which the cleared cache denies.

**(c) `updateWindow` advancing the tier-2 id set before the debounce.**
`image_preload_controller.dart:427` calls it synchronously inside `preloadImages`, between the generation bump (`:403`) and the first await (`:438`) — so it always reflects the newest navigation and can never be applied out of order by a stale pass. `updateWindow` (`tier_two_scheduler.dart:129-138`) computes the same ±`kTierTwoRadius` set that `_decodeWindow` recomputes at `:208`, so the two never disagree for the same index.
- *Can it publish a full-res entry the old debounced sweep would have refused?* Yes, and that is the intended fix: a decode landing before the 250ms fires now sees a truthful window and keeps free full-resolution pixels instead of dropping them and paying a second FFI decode later. The published entry is always for an id within ±2 of the CURRENT selection, i.e. one the sweep would have decoded anyway. The only behavioural delta is timing, plus the case where the user navigates away again before the debounce — then an entry exists for an item now outside ±2, which the next `_decodeWindow` stale sweep evicts (`tier_two_scheduler.dart:~289`).
- *Can it evict something early?* No. `updateWindow` only assigns `_windowIds`; every eviction path (`_registry.evict` for stale ids, `_tierTwo.evict` on payload drop at `image_preload_controller.dart:419-421`) is untouched and still runs at its old moment.

**(d) Pending-notify fix — double-notify or leak?**
No double-notify. The two producers of a parked callback are mutually exclusive with the direct `notifyLoaded?.call()`:
- `_enqueueSerialLoad:774-776` parks the callback and the lane body then calls `_ensurePayload` with `notifyLoaded: null` (`:790`), so the same closure cannot be invoked as both.
- `_loadingKeys` branch at `:579-581` parks and returns immediately.
- `_flushPendingNotifies` (`:529-534`) `remove`s before iterating, so a second flush finds nothing.
- The `catch` arm at `:745-750` is a functionally identical inline copy of `_flushPendingNotifies`, kept separate only to preserve the rethrow ordering — same remove-then-call shape, no double fire.
Leak: bounded and benign, see F-3.

**(e) Unbounded memory — is `kPayloadByteBudget` eviction still effective?**
Mechanically yes: `put` calls `_enforceBudget` on every write (`photo_payload_cache.dart:91`) and the loop drains until under budget (`:112-119`), so residency is hard-capped at ~224 MiB + one oversized payload regardless of how many RAW slots the lane fills. Nothing in the diff bypasses `put`.
What changed is that the budget path is now *reachable* — 9 RAW payloads ≈ 201.59 MiB against a 224 MiB ceiling (11% headroom) where the old ±1 radius kept it at ~3 — and that its victim selection is now hostile. That is F-2. Steady-state RSS for an all-RAW folder legitimately rises by roughly 135 MiB; the contract sanctions that (the budget was sized for the full window at `photo_payload_cache.dart:17-22`), so it is a consequence, not a defect.

## 4. Parking lot (outside the contract, no severity, no effect on verdict)

- P-1: `_enqueueSerialLoad` captures `distance` at enqueue time and hands the stale value to `_ensurePayload` on execution. Harmless today (the value is only re-used for a deferred re-enqueue's rank, and a fresh nav pass re-enqueues with a correct rank anyway), but it is a latent staleness if `distance` ever acquires a second meaning.
- P-2: `SerialDecodeLane._takeNext` (`:140-151`) is an O(n) linear scan of `_pending`. Fine at n≤~11; would want a heap if the lane ever carries sidebar thumbnails (F-1's fix) at viewport scale.
- P-3: TC-098b's cheap-parallelism assertion is `greaterThan(1)`, which is the weakest form that still binds. A folder-size-derived expectation would catch a regression from 9-way to 2-way parallelism.
- P-4: The gate log carries ~1600 lines of `EXIF package read failed for /nonexistent/...` noise from a fixture-less test; it makes artifact auditing harder than it needs to be.

## 5. Verdict

**Mergeable.** All eight in-scope criteria pass on evidence I produced myself (targeted suite RC=0 self-captured, 254 tests; gate artifact complete with `ANALYZE_RC=0` / `TEST_RC=0` / 406 tests). No blocker found: I could not construct a path to a double decode, a stale-cache write, an early eviction, or a double-notify.
Two should-fix items (F-1 sidebar decoder outside the lane, F-2 selected-item-first FIFO eviction under a now-reachable byte budget) are correctness-adjacent but neither violates a frozen criterion; the lead should route them as follow-ups or accept them explicitly in AD-033.
