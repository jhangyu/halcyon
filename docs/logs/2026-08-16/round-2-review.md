# Round 2 — Adversarial Review of WP1-4 (task #7)

- Reviewed HEAD: `5a8684e447d53ca4712d4d6e998a134fbf30a684` (range 7c33194..5a8684e)
- Tree state at review start AND end: `git status --porcelain --untracked-files=no` empty (verified twice)
- Reviewer: reviewer-opus. Scope: AC1-AC6 only. No code edited.
- Probe artifacts: `tmp/verify/r2/probe/` (p_test.dart, p_out.txt, mutant.dart, m3b_test.dart, m3b_out.txt), `tmp/verify/r2/reviewer-flutter-test.txt`, `tmp/verify/r2/reviewer-macos-build.txt`

## Verdict

**REFUTED — 2 blockers.** The central key-identity claim (AC2) holds and is confirmed by my own probe. But (1) tier-2's ready flag can be true while no ImageCache entry exists for the item's current bytes, which reintroduces the exact full-frame decode on the display path this round exists to remove, and (2) the AC3b test passes unchanged against a controller with the debounce entirely removed, so it does not prove what AC3(b) requires.

## BLOCKER 1 — `_tierTwoReadyIds` outlives its ImageCache entry; display then does a full-frame decode

**Location:** `lib/services/image_preload_controller.dart:67,82,131,181` + `lib/views/main_detail_view.dart:196-202`

`_tierTwoReadyIds` is keyed by item id, but the ImageCache entry it claims to describe is keyed by the *bytes object identity* (`MemoryImage.==` compares `bytes` by identity — SDK `image_provider.dart:1723-1727`). `preloadImages` drops bytes for items leaving the -3..+5 window (`:131`) without clearing the tier-2 bookkeeping. When such an item re-enters the window, a NEW Uint8List is fetched, so the old entry's key no longer matches — yet `_decodeTierTwoWindow` skips re-decoding because `_tierTwoReadyIds.contains(id)` is still true (`:181`), and `isFullSizeReady` keeps reporting true.

**Reproduced (not inferred).** Probe `tmp/verify/r2/probe/p_test.dart`, real timings under `tester.runAsync`, public API only. Rest at index 5 (tier-2 lands), then a burst 5->10->5 with no 250ms pause, then settle 350ms. Output (`p_out.txt`):

```
PROBE same_bytes=false ready=true hasCurrent=false hasOld=true
```

i.e. the flag says ready, the cache has NO entry for the current bytes, and the stale entry under the old bytes key is still resident.

**Impact:** `main_detail_view.dart:200-201` then selects `fullSizeProviderFor(bytes)` for the current item on the very next build. The comment at `:196-199` ("already known to be cached ... never triggers a decode on this build/UI path") is false in this state: it is a cache miss, so the display path runs the ~124ms full-frame 24MP decode the contract's terminal state promises to eliminate, plus it leaves a duplicate ~96MB entry resident. Invisible to every existing test.

**Trigger:** any fast direction reversal spanning more than the bytes window (>=4 steps out and back) with gaps under 250ms — a plausible arrow-key over-scroll-and-return. A second, rarer route: ImageCache LRU evicting a tier-2 entry under the 500MB budget; nothing ever clears the flag in that case either (see should-fix S2).

**Fix direction (implementer's call):** clear `_tierTwoReadyIds`/`_tierTwoKeys` (and evict the key) for every id dropped by the `_imageCache.removeWhere` at `:131`; or store the bytes object alongside the flag and treat `!identical(storedBytes, currentBytes)` as not-ready.

## BLOCKER 2 — the AC3b test cannot fail; it passes against code with the debounce removed

**Location:** `test/image_preload_controller_test.dart:343-381`

AC3(b) requires a test proving that continuous navigation never queues an out-of-window item for full-size decode. The test asserts only the END STATE of the ready flag (`isFullSizeReady(items[2].id) == false` at :376). That is also true when index 2 WAS decoded and then evicted by the stale-sweep in `_decodeTierTwoWindow:185-194` — so the assertion cannot distinguish the required behavior from its opposite.

**Mutation-proven.** `tmp/verify/r2/probe/mutant.dart` is a verbatim copy of the shipped controller with only `tierTwoNavigationDebounce` changed to 0ms (i.e. the AC3b behavior deliberately broken); `m3b_test.dart` replays the AC3b test body against it. Output (`m3b_out.txt`):

```
MUT after step2 ready(2)=true      <- index 2 WAS queued and decoded (the forbidden behavior)
MUT final ready(2)=false ready(5)=true
00:00 +1: All tests passed!        <- both AC3b assertions still pass
```

**Impact:** AC3(b) has no valid evidence. The production behavior is in fact correct (the real 250ms debounce does prevent the queueing — the same mutation run makes AC3a fail, see below), so this is an evidence defect, not a product defect. But the contract's AC3 demands a test that proves (b), and this one does not.

**Fix direction:** assert on the intermediate state (e.g. sample `isFullSizeReady` for index 2 mid-burst, where the mutant reads true and the shipped code reads false), or expose/record decode-start counts.

**AC3a is discriminating (good).** The same mutant makes AC3a's `:328/:334` assertions fail (`ready(2)=true` observed 20ms after the pass, whereas AC3a requires false at 0ms and at 100ms). So (a) and (b) are NOT the same assertion twice — (a) is real, (b) is vacuous.

## Should-fix (parking lot — do NOT gate signoff)

**S1. Pending notify callbacks are not flushed on the exception path.** `image_preload_controller.dart:293-312`: the `finally` clears `_loadingKeys` but the pending-notify flush lives only inside the `bytes != null` branch. If `_imageLoader` THROWS (`NativeThumbnailService` catches only `PlatformException` — a `MissingPluginException`, e.g. the empty Android handler, propagates), `_pendingPreviewNotifies[id]` is never invoked and never removed: stranded spinner plus an unbounded map. This is the same class of bug WP1 exists to fix, and the implementation plan §5 Failure path explicitly asked for the flush to be in the try/finally.

**S2. `reset()` clears the key maps without evicting the ImageCache entries.** `:84-96`. On folder switch up to 5 tier-1 + 3 tier-2 entries (several hundred MB) stay resident and unreferenced, consuming the 500MB budget and raising the chance of LRU-evicting fresh entries — which is also the second route into BLOCKER 1's false-positive flag. One `evict` loop over both maps before clearing.

**S3. Stale tier-2 entries are only swept when the debounce timer fires.** `:185-194`. During a long burst nothing is evicted, so the tier-2 footprint transiently exceeds the +/-1 window. Bounded and self-correcting; noted for the memory budget only.

**S4. Ready flag can be set for an already-out-of-window item.** `:206-209` sets `_tierTwoReadyIds` from the decode listener with no re-check that the id is still in the +/-1 window. Self-corrects on the next sweep.

## Nit

**N1.** `main_detail_view.dart:196-199` comment asserts tier-2 is "already known to be cached" — false under BLOCKER 1; the comment should be corrected together with the fix.
**N2.** Degenerate viewport: when `constraints` are 0, the view falls back to `Image.memory` (`:213`) but `setViewportSize(0,0)` is still forwarded (`:194`), so the precache would build `ResizeImage(width:0,height:0)`. Unreachable in the current layout (`Positioned.fill`); a `width>0 && height>0` guard in `updateTargetSize` would close it.
**N3.** Unverified: whether `ResizeImagePolicy.fit` computes its scale from pre- or post-EXIF-rotation dimensions for rotated JPEGs. Cannot cause a key mismatch (both call sites compute identically), at worst a slightly off decode size. Flagged, not measured.

## AC1-AC6 status

| AC | Verdict | Evidence |
|---|---|---|
| AC1 (R3 notify flush) | PASS | `image_preload_controller.dart:277-312`; test `:118-197` is discriminating — against the old early-return `secondNotify` stays 0 and `:179` fails. Caveat S1 (exception path) is a plan deviation, not an AC1 miss. |
| AC2 (one provider factory, identical key) | PASS | Single factory `:20-31` used by precache `:240` and display `main_detail_view.dart:202`. Bytes identity traced: `_imageCache[id]` -> `imageBytesFor` -> `app_state.dart:89-90` -> `main_detail_view.dart:73` -> factory; no copy anywhere (grep for fromList/sublist/asUint8List in lib/ finds none on this path). Independently confirmed the mechanism in the SDK: `ResizeImageKey.==` (`image_provider.dart:814-824`) compares provider key + policy + w/h; `MemoryImage.==` (`:1723-1727`) compares bytes by object identity; MemoryImage ignores ImageConfiguration, so the display's real configuration cannot perturb the key. Tests `:199-301` verify both key equality and a real precache-then-hit. |
| AC3a (debounce before tier-2) | PASS | `:153-162`; test discriminating (mutation with 0ms debounce makes it fail). |
| AC3b (no queueing of out-of-window items) | **FAIL (evidence)** | BLOCKER 2 — the test passes against debounce-removed code. Product behavior appears correct; the proof does not exist. |
| AC3c (two tiers coexist, each own eviction) | PASS with caveat | Test `:383-455` is discriminating and its mock loader DOES return a fresh Uint8List per call (`:389`), so per-item keys are distinct — I confirm the lead's reading; the AC3c evidence is valid. Cross-tier collision is structurally impossible: both `==` implementations reject a differing runtimeType, so an `evict(MemoryImage)` can never hit a `ResizeImageKey` entry. Windows nest correctly: bytes -3..+5 (`:123-124`) superset tier-1 +/-2 (`:229-230`) superset tier-2 +/-1 (`:172-173`); tier evictions call only `imageCache.evict(key)` and never touch `_imageCache`. Caveat: the tier-2 side of this bookkeeping is unsound over time — BLOCKER 1. |
| AC4 (ImageCache 500MB) | PASS | `main.dart:7-12` + called from `main()`; `test/main_test.dart` asserts `500 << 20`. |
| AC5 (native honours Dart targetSize) | PASS | `AppDelegate.swift:121` now `targetSize` (was `max(targetSize, 8000)`); `native_thumbnail_service.dart:12` 10000 -> 2800. `flutter build macos --debug` exit 0, "Built build/macos/Build/Products/Debug/Halcyon.app" (`tmp/verify/r2/reviewer-macos-build.txt`). |
| AC6 (flutter test green) | PASS | My own run at 5a8684e: exit 0, "All tests passed!", 21 executed == 21 declared (6+1+3+8+2+1 across test/*.dart). `tmp/verify/r2/reviewer-flutter-test.txt`. No test skipped, weakened or `markTestSkipped`; no `testWidgets` body awaits a real engine future outside `tester.runAsync` — all five new widget tests wrap their whole body in `runAsync` (`:251,307,347,387`). |

## Negative space — what this diff removes or narrows, and who depended on it

Callers grepped for every changed/added symbol (`currentImageBytes`, `imageBytesFor`, `setViewportSize`, `isFullSizeReady`, `currentItemHasFullSize`, `tierOneProviderFor`, `fullSizeProviderFor`, `updateTargetSize`, `reset`, `preloadImages`): the only consumers are `app_state.dart:89-110` and `main_detail_view.dart:73/106/194/201-202` plus tests. No signature of an existing function changed; all additions.

1. **Display no longer decodes at full resolution by default.** `main_detail_view.dart` went from unconditional `Image.memory(bytes)` to tier-1 `ResizeImage(fit)` at viewport px. Dependent behavior: zoom sharpness. Between selecting an image and tier-2 landing (250ms debounce + decode), a 5x zoom shows an upscaled window-resolution image. This is the contracted design (tier-2 covers it, `gaplessPlayback` hides the swap), and the RAW case is an accepted out-of-scope limit — flagged as intended narrowing, not a finding.
2. **The `Image.memory` path survives only for the degenerate 0-size viewport** (`:213-219`), where its key coincides with tier-2's MemoryImage key — harmless. Error builder and null-bytes spinner branches (`:171-173`, `:210-211`, `:217-218`) are preserved in both branches.
3. **RAW extraction cap 8000 -> 2800.** Who depended on the sentinel: only the isRaw embedded-preview branch (`AppDelegate.swift:121`). I re-derived the lead's finding independently: non-RAW previews never read `targetSize` (they take `createFullSizeImage`, `:159-161`), sidebar thumbnails keep their own 200, and the arg default `?? 4000` (`:24`) is unchanged. So HEIC/PNG/JPEG previews have zero blast radius.
4. **JPEG passthrough untouched.** `AppDelegate.swift:91-103` is byte-identical; `git show d574a9b` touches exactly one line (`:121`).
5. **RAW fallback survives.** The "embedded preview too small -> full decode" guard (`:127-129`, `maxDimension >= 1024 || targetSize <= 256`) and the CIRAWFilter path (`:135-154`) are unchanged. Note the guard's threshold is absolute (1024), so lowering the request cap to 2800 does not narrow the fallback's reach; it only means an accepted embedded preview is now capped at 2800px instead of up to 8000px — which is the point of R4.
6. **Nothing removed from the eviction contract:** `_imageCache` (bytes) eviction is untouched at `:131`; the new tier evictions operate on ImageCache keys only.

## Could not verify / explicitly out of scope

- AC7 (profile-build measurement) and AC8 (post-merge gate) are WP5's; not attempted.
- Real-device behavior of the tier-1/tier-2 swap (visual seamlessness, actual decode timings) — unit tests use a 1x1 PNG; only WP5's measurement can confirm the >=30ms goal. BLOCKER 1 in particular will NOT show up in a normal sequential-navigation measurement run; it needs a deliberate direction reversal.
- N3 (ResizeImagePolicy.fit vs EXIF rotation) — not measured.
- Two lead-parked items (static 2800 targetSize; tier-1 precache running after the byte-window await, and window-resize orphaning entries) were treated as accepted and are not reported as findings.

