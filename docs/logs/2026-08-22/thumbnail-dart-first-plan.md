# Dart-first thumbnail/preview — sequenced implementation plan

> Author: `arch-thumb-b-opus` (Task #9). Reconciles `thumbnail-cross-platform-analysis-a.md` (slot A) and `-b.md` (slot B) into one plan after the user adopted Dart-first.
> Anchor: Halcyon `main` @ `5e35d39`. **Planning only — no code was written.**
> Evidence: `tmp/verify/thumb-b-01..07`.

---

## 1. Reconciliation — where the two analyses actually differ

Both documents recommended the same architecture (native channel stays first on every platform; the fallback becomes Dart's job; the raw-decode signal gets synthesised in Dart). Slot A called it **Dart Fallback Chain**, I called it **DartRawRouter**. That is vocabulary. Below are the **substantive** differences, each settled on merit.

| # | Topic | Slot A | Slot B (me) | **Chosen** |
|---|---|---|---|---|
| **D1** | Sidebar decode cap | Add `cacheWidth`/`cacheHeight` to `sidebar_view.dart:273`. Framed as **OOM-class**: ~48 MB decoded per row × up to 41 in-flight rows against a 500 MB `ImageCache` (`main.dart:12`) | `ResizeImage(MemoryImage(bytes), width: 200)`. Framed as I/O cost | **A's diagnosis, with a correction to A's prescription.** See §1.1 |
| **D2** | Where the chain lives | Implements the existing `ThumbnailLoader` typedef (`app_state.dart:23-27`), drops into the seam already at `app_state.dart:83-89` — no new seam, no new injection point | New file called from inside `ImagePreloadController` | **A's.** Strictly better: tests already fake that typedef, `AppState`'s constructor already accepts it, and no new injection point has to be justified |
| **D3** | Dart-extraction latency | **3.79 ms** median / 8.56 ms max, freshly benchmarked across 14 real samples (`tmp/verify/thumb-a-dart-extract-bench.txt`) | 4.49 ms median, cited from commit `8ef9bc7`'s message | **A's.** A fresh measurement beats a citation of someone else's |
| **D4** | Sidebar cap mechanism, second placement | *Also* proposes `instantiateImageCodec(targetWidth: 200)` inside the chain's sidebar rung | Cap at the widget only | **B's.** A's chain-level cap is **wrong as specified** — see §1.2 |
| **D5** | Duplication response | Do not unify; **stop adding**. Leave both working native paths untouched | Orientation → add tests; extraction → **delete `DngPreviewExtractor.swift`** | **A's.** I withdraw my deletion proposal — see §1.3 |
| **D6** | AD-010/AD-011 | Freeze not broken, but the *prose* becomes false; recommends an amendment, user to confirm | Freeze not broken, full stop | **A's diagnosis.** A is right that I under-called it. Settled with exact wording in §5 |
| **D7** | `setPipelineCachePath` | Lists it as available; flags **[U]** whether `warmupForSize`'s own isolate warms the later decode isolate | Ties it to the Windows build being the **Vulkan** preset (`CMakePresets.json:50`), which is what makes it applicable at all (it returns -1 on macOS/Metal) | **Both — combined.** A's isolate question is the sharper risk; my Vulkan link is the missing half of why it is worth doing |
| **D8** | Sequencing | One candidate = one change set | One candidate = one change set | **Neither.** Split into independently shippable rungs — §2 |
| **D9** | Non-DNG RAW, export EXIF, Native Parity | Parked | Parked | Agreed, parked — §6 |

### 1.1 (D1) A's diagnosis is right and better than mine; A's prescription would distort every non-square thumbnail

A found what I missed. `sidebar_view.dart:273-280` is:

```
273	      child: Image.memory(
274	        thumbBytes,
275	        width: 32,
276	        height: 32,
277	        fit: BoxFit.cover,
278	        gaplessPlayback: true,
279	      ),
```

No `cacheWidth`/`cacheHeight` — so the decode happens at the JPEG's native resolution and `width: 32` only scales at paint time. Today macOS hands this a 200 px JPEG, so nobody noticed. Feed it a 4000 px embedded preview and it is ~48 MB of decoded pixels per row. **That is an OOM-class regression, not a slowdown**, and my "I/O cost" framing understated it. A's framing is adopted verbatim.

**But the literal prescription needs one correction.** `Image.memory(..., cacheWidth: w, cacheHeight: h)` funnels into `ResizeImage(provider, width: w, height: h)` with `ResizeImage`'s **default** policy, which is `ResizeImagePolicy.exact` — it resizes to exactly those dimensions and **does not preserve aspect ratio**. Passing both `32, 32` would squash every landscape and portrait thumbnail into a square, and `BoxFit.cover` cannot undo a distortion already baked into the decode. This repo already knows the answer: `tierOneProviderFor` (`image_preload_controller.dart:25-36`) explicitly passes `policy: ResizeImagePolicy.fit` for exactly this reason.

**Adopted form** — matches house style, preserves aspect:

```
ResizeImage(
  MemoryImage(thumbBytes),
  width: side, height: side,
  policy: ResizeImagePolicy.fit,
)
```

with `side = (32 * devicePixelRatio).round()`. One-line alternative if the extra wrapper is unwanted: pass **`cacheWidth` only** (aspect is then preserved by construction). Either is fine; both must be tested, and the test is dimensional, not visual (§2, R2-AC2).

### 1.2 (D4) A's chain-level `instantiateImageCodec(targetWidth: 200)` is not viable

A's sidebar rung proposes capping inside the chain via `dart:ui`. That cannot work as specified: `instantiateImageCodec` yields a `ui.Image` (pixels), but the sidebar cache is `final Map<String, Uint8List> _thumbCache` (`image_preload_controller.dart:69`), `thumbnailBytesFor` returns `Uint8List?` (`:133`), and the render is `Image.memory` (`sidebar_view.dart:273`). Returning pixels would require changing the cache type, the accessor, and the widget — and would then need a JPEG re-encode to get back to bytes, which `dart:ui` cannot do.

**The chain must return encoded JPEG bytes, unchanged, for every purpose.** The cap belongs at the widget (§1.1), where it also covers macOS's existing 200 px thumbnails. One mechanism, one place.

### 1.3 (D5) I withdraw my "delete `DngPreviewExtractor.swift`" proposal

My analysis argued the Swift extractor (348 lines) is now redundant because the Dart port is parity-verified, measured, and already the Windows path — so macOS could stop extracting natively and the Swift file could be deleted.

A's cost test defeats it: deleting a working native path spends the scarcest resource in this project — **verification capacity on a host that cannot build or measure the platform being changed** — for a failure that does not exist today. Both extractors produce correct pixels. The concrete risk I named (silent drift between two copies) is real but is a *future* hazard with a cheap detector (`test/dng_extractor_swift_test.dart` already exists for exactly this), whereas the deletion is an immediate change to a path on the measured macOS hot path.

A's formulation is the one to adopt: **do not unify, do not delete — stop adding.** Concretely, that is a standing rule for this plan: no new orientation reader and no new TIFF walker in any language. The duplication count stops where it is instead of rising. My proposal is moved to the parking lot (§6) where it can be reconsidered if drift is ever actually observed.

---

## 2. The rungs

Ordered so that **user-visible value lands first** and **each rung's value survives if every later rung is cut**. Every rung is independently shippable, independently revertable, and has its own mechanical acceptance condition.

One deliberate departure from both analyses (D8): neither of us should bundle the chain extraction with the headline fix. The headline fix is ~10 lines inside an `if` that already exists. Extracting a shared chain is justified **when the second consumer arrives** (R3), not before — otherwise R1 pays for an abstraction with one caller. Writing the fix in place and relocating it in R3 costs one mechanical move, protected by a green suite.

### R1 — Dart-emitted raw-decode signal (the headline fix)

**Fixes:** Windows preview-less DNGs are permanently unreadable (`halcyon_image.cpp:401` returns `RAW_UNSUPPORTED`, so `NativeImageNeedsRawDecode` is never constructed, so the decoder injected at `main.dart:25` is dead code on Windows).

**Change.** In `image_preload_controller.dart`'s existing `case NativeImageFailure():` branch (`:651-666`), after `extractFullSizeEmbeddedJpegFromFile` returns null for a `.dng`, record `_needsRawDecode[id] = await DngPreviewExtractor.readOrientationFromFile(path)` and return null — which is precisely the shape `:639-650` already uses for the native-signalled case. `readOrientationFromFile` (`dng_preview_extractor.dart:41`) exists, is unit-tested, and is currently **unused in production**.

Scope note: this rung touches the `preview` purpose only, which is where `NO_EMBEDDED_PREVIEW` is defined to apply on macOS too (`AppDelegate.swift:319`, `:371`). No behaviour change on macOS: the branch is only reachable after a `NativeImageFailure`, which macOS does not produce for these formats.

**Files.** `lib/services/image_preload_controller.dart`, `test/image_preload_controller_test.dart`, `unit_test.md`.

**Acceptance (mechanical).**
- **R1-AC1** New test: a fake `ImageBytesLoader` returning `NativeImageFailure('RAW_UNSUPPORTED', …)` for the real preview-less sample `local_data/photo_samples/DNG/IMG_20251112_092839.dng` causes the controller to call the injected `DngFullDecoder` exactly once, with the orientation read from the file. Must be seen red before green (mutate `readOrientationFromFile` → constant 1, or delete the `_needsRawDecode` write) and the red output kept in `tmp/verify/`.
- **R1-AC2** Existing test "a raw item is requested from the native loader exactly ONCE" still passes (invariant I6, `image_preload_controller.dart:397-404`).
- **R1-AC3** `flutter analyze` exit 0; `flutter test -j 1` exit 0 with **declared count == executed count** and ≥162 tests (the post-merge gate in the contract).
- **R1-AC4** `grep -rn "Platform.is\|defaultTargetPlatform" lib/services/ lib/providers/` → 0 hits.
- **R1-AC5** `grep -c "extends NativeImageResult" lib/services/native_thumbnail_service.dart` → 3.

**1-second ceiling:** **ships without the number.** Today the alternative is a permanent error screen; a slow picture strictly dominates no picture. The decode is already off the UI isolate and off the tier-2 debounce (`unawaited` at `:447`), so a slow decode delays the image, it does not stall the app. Ship R4 alongside so we are not knowingly shipping an unwarmed cold start.

### R2 — Cap the sidebar decode (prerequisite for R3)

**Fixes:** a latent OOM that R3 would otherwise trigger (§1.1), plus a small existing waste on macOS (200 px JPEGs decoded at full size to paint at 32 logical px).

**Change.** `sidebar_view.dart:271-280` — wrap in `ResizeImage(..., policy: ResizeImagePolicy.fit)` sized to `32 × devicePixelRatio`, per §1.1.

**Files.** `lib/views/sidebar_view.dart`, `test/sidebar_view_test.dart`, `unit_test.md`.

**Acceptance (mechanical).**
- **R2-AC1** New test: resolving the sidebar provider for a large (≥2000 px) real JPEG yields a `ui.Image` whose max dimension ≤ `32 × dpr + 1`. Red-first against the current code.
- **R2-AC2** Aspect ratio preserved: for a non-square source, `decoded.width / decoded.height` equals the source ratio within 1 %. **This is the test that catches the `policy: exact` distortion trap** — without it, the naive `cacheWidth + cacheHeight` fix passes R2-AC1 and silently squashes every thumbnail.
- **R2-AC3** `flutter analyze` 0; full suite green per R1-AC3.

**1-second ceiling:** unaffected — ships without the number.

### R3 — Extract the chain, and give the sidebar its DNG fallback

**Fixes:** every RAW row in the Windows sidebar is blank **with no error marker** (`image_preload_controller.dart:836` drops every non-`NativeImageBytes` result silently). This is the nastiest symptom in the matrix — it looks like a broken app rather than a limitation.

**Change.** Create `lib/services/image_source_chain.dart` implementing `ThumbnailLoader` (D2: it drops into the existing seam at `app_state.dart:83-89`, no new injection point). Move R1's in-place logic into it unchanged, and add the `sidebarThumbnail` rung: on `NativeImageFailure` for a `.dng`, return the extractor's bytes. The chain returns **encoded JPEG bytes for every purpose** (D4/§1.2); the size cap lives at the widget from R2.

**Measurement taken — see §3.3.** The byte half of M1 is done and the verdict is split (293 MB typical / 985 MB worst case against a 500 MB gate). **R3 is therefore no longer blocked, but its content grew**: it now includes the byte-range rewrite of `DngPreviewExtractor` (mandatory, with M2 parity) and a thumbnail-path miss set (R3-AC6). Both are contained changes; R3 is still one rung.

**Files.** New `lib/services/image_source_chain.dart`, `test/image_source_chain_test.dart`. Edited: `lib/providers/app_state.dart` (`:83-89`), `lib/services/image_preload_controller.dart` (relocate `:651-666`, add the fallback at `:836`), `unit_test.md`, `memory.md` (the AD-010 amendment from §5).

**Acceptance (mechanical).**
- **R3-AC1** Relocation preserves ordering: a `.dng` whose loader returns `NativeImageFailure` still yields extractor bytes for `preview`. (This is the rung's biggest risk — `:651-666` is currently the *only* thing keeping Windows DNG previews alive. A's catch.)
- **R3-AC2** New test: a `.dng` whose loader returns `NativeImageFailure` for `sidebarThumbnail` populates `_thumbCache`.
- **R3-AC3** **Bytes-identity regression test** (invariant I3 / AD-011): resolving tier-1 then tier-2 for one item produces exactly **2** `ImageCache` entries, not 3+. Red-first by making the chain return a fresh `Uint8List` copy — if that mutation does not turn it red, the test has no discriminating power and must be rewritten.
- **R3-AC4** Generation guard still honoured: the sidebar fallback re-checks `generation != _thumbBatchGeneration` **after** the Dart rung, not only after the channel call (invariant I7).
- **R3-AC5** `flutter analyze` 0; full suite green per R1-AC3; R1-AC4/AC5 still hold.

**1-second ceiling:** ships without the *Windows decode* number (it never invokes the decoder), but is blocked on its own read-volume measurement (§3.2).

### R4 — Warm the decoder and persist its pipeline cache

**Fixes:** nothing user-visible on its own; it is the only available mitigation for the top unknown. `warmupForSize` (`dng_decoder_service.dart:143`), `setPipelineCachePath` (`:161`) and `savePipelineCache` (`:174`) all exist and **Halcyon calls none of them** — verified 0 call sites across `lib/` and `test/` by both analyses independently. Compounding it, `decodeOnWorker` spawns a fresh isolate per call and `_decodeFileToTransferable:284` does `DngDecoderService()..initialize()` inside it, i.e. a fresh `DynamicLibrary.open` every decode.

The R2 handover budgets a whole upstream round for this ("P3: 首次解碼 >1s → VkPipelineCache fork 泛化輪"). The Dart-side call is a one-liner at the composition root that was simply never made.

**Change.** In `lib/main.dart`, after `configureImageCache()`: set the pipeline-cache path to a writable per-app location, then fire `warmupForSize()` unawaited so startup is not blocked. Both must be wrapped so a failure can never break launch (`setPipelineCachePath` is documented never to throw; `warmupForSize` **does** throw on a non-zero result, `:148-150`).

**Files.** `lib/main.dart`, `test/` (a smoke test that a throwing warmup does not propagate), `unit_test.md`.

**Acceptance (mechanical).**
- **R4-AC1** App starts normally with a decoder whose warmup throws — test with an injected failing warmup; no exception escapes `main`.
- **R4-AC2** Startup is not blocked: the warmup future is not awaited before `runApp`.
- **R4-AC3** On macOS, `pipelineCacheStatus` is logged once at startup. Expected value is `-1` (unsupported on Metal) — **that is a pass, not a failure**; the assertion is that the call returns rather than what it returns.
- **R4-AC4** `flutter analyze` 0; full suite green.

**1-second ceiling:** this rung *is* the ceiling work. It ships without the number and is what makes the number worth taking afterwards.

### If rungs are cut

| Ship only | User-visible result |
|---|---|
| R1 | Windows preview-less DNGs display. The headline gap closes. |
| R1+R2 | Same, plus the sidebar OOM trap is disarmed before anything can trigger it. |
| R1+R2+R3 | Plus Windows DNG sidebar thumbnails appear — no more column of grey squares. |
| R1+R2+R3+R4 | Plus the first Windows decode is warmed and its pipeline cache persists across launches. |

No rung depends on a later one for its value. R3 depends on R2 for *safety*, which is why R2 precedes it despite being the smaller improvement.

---

## 3. The two structural constraints neither analysis can design around

### 3.1 `decodeOnWorker` has no target-size entry point

`decodeOnWorker(String filePath)` (`dng_decoder_service.dart:194`) takes a path and nothing else; `DngImage` is always full-resolution (`:28-36`). Both analyses found this independently and both concluded it constrains every candidate identically. There is no scaled, half-size or capped decode at any layer, so the usual mitigation — decode small first, refine later — does not exist.

**How this plan handles it: by never routing the sidebar through the decoder.** That is a design decision, not a measurement, and it has a stated cost:

> **Accepted limitation.** On Windows, a DNG with **no** embedded preview gets a working main-pane image (R1) and **no sidebar thumbnail** (its row stays a grey placeholder). Giving it one would cost a ~50 MB full-resolution decode per row. macOS gets one today only because ImageIO produces a cheap RAW thumbnail — a capability the FFI does not expose.

This must be stated to the user as a known gap, because "the sidebar is fixed" (R3) will otherwise be read as covering all DNGs. Nothing to measure; the upstream feature request (a `targetWidth` on `decodeOnWorker`) is recorded in §6.

### 3.2 `DngPreviewExtractor` reads the whole DNG

`extractFullSizeEmbeddedJpegFromFile` does `File(path).readAsBytes()` (`dng_preview_extractor.dart:30`) — the **entire file** — to slice out a preview whose offset and length it computes at `:181-182`/`:201-206`. For `preview` (one file at a time) that is fine and measured. For the sidebar it is a 41-row sweep (`thumbnailPrefetchMargin = 20`, `:50`).

I flagged the byte-range rewrite as a prerequisite but labelled the judgement unmeasured. **The byte half is now measured — see §3.3, which corrects a figure I asserted in an earlier draft of this section.** Here is what must be measured, and where.

**Measure on macOS, not Windows.** The binding quantity is *bytes read per sweep*, which is host-independent and exactly countable here. Wall-clock differs between a macOS SSD and a Windows laptop disk, but if the byte volume is acceptable the wall-clock question is a scaling factor, not an unknown; if the byte volume is not acceptable, no host makes it acceptable.

**Measurement M1 — sidebar sweep read volume.**
- Host: this macOS host. Samples: `local_data/photo_samples/DNG/` only (red line: `test-only-with-photo-samples`).
- Method: a throwaway harness (not a committed test — memory `throwaway-test-for-trivial-fixes`) that calls `extractFullSizeEmbeddedJpegFromFile` over 41 DNG paths sequentially, summing `File.length()` and wall-clock, with a warm and a cold-ish pass. Output to `tmp/verify/`.
- Record: total bytes read, median and max per-file wall-clock, total sweep wall-clock.

**Commit rule.**
- If total sweep wall-clock **< 1 s** on macOS *and* total bytes **< 500 MB** → ship R3 with the whole-file read; open the byte-range rewrite as a follow-up.
- Otherwise → the byte-range rewrite (`RandomAccessFile`: read the header + IFD chain, then `setPosition(offset)` + `read(byteCount)`) becomes part of R3 and must land before the sidebar rung. The change is contained: the parser already computes both numbers; only the buffer source changes.
- Either way, the number goes in the plan's record before R3 is committed to.

**Measurement M2 — byte-range rewrite parity (if the rewrite happens).** The rewritten extractor must return **byte-identical** output to the current one across all 14 samples, and identical `null` for the preview-less one. This is the same parity bar `8ef9bc7` used against the Swift reference, so the harness already exists in shape.

### 3.3 M1, byte half — TAKEN. Split verdict, and it changes the recommendation

Taken with read-only `stat` over `local_data/photo_samples/DNG/` — no code written, nothing run against the pipeline. Raw output: `tmp/verify/thumb-b-09-M1-bytes.txt`.

| | Value |
|---|---|
| Samples | 14 DNGs |
| Total | 99.9 MB |
| Mean / min / max | **7.14 MB** / 3.22 MB / **24.03 MB** |
| 41-row sweep at mean | **293 MB** → **PASS** (< 500 MB gate) |
| 41-row sweep at max | **985 MB** → **FAIL** |

**Correction to my own earlier text.** I wrote "the entire 25-60 MB file". That is wrong for this sample set: the mean is **7.14 MB** and only the single outlier reaches 24 MB. I overstated the per-file cost. The corrected figures are above.

**But the verdict is split, and that is the actionable result.** The whole-file read is comfortably fine for phone-sized DNGs (~3-9 MB, 13 of 14 samples) and blows the gate for large-sensor DNGs. A full-frame card of 24 MB DNGs is not a strawman — file sizes cluster per camera, so a real card is homogeneous, and "which camera" decides whether the feature is acceptable. **"It depends on the user's camera" is not a shippable answer**, and a size-threshold workaround would just make the sidebar silently inconsistent.

**Revised commit rule (supersedes §3.2's):** do the byte-range rewrite **as part of R3**, not as a follow-up. The measurement moved this from an unmeasured judgement to a measured conditional, and the rewrite is the contained change that removes the condition entirely — it collapses mean case, worst case, and the waste below to a few KB of IFD walk plus the preview's own bytes. M2 (byte-identical parity) becomes mandatory rather than conditional.

**A second defect this measurement exposed, which neither analysis had.** The largest file in the set — `IMG_20251112_092839.dng`, 24 MB — is the **preview-less** one (the sample `8ef9bc7` records as returning `null` in both implementations). So under R3 as I originally specified it, the biggest read in the sweep returns nothing, and it repeats: `_thumbCache` stores only successes (`image_preload_controller.dart:836-838`) and the skip guard at `:818` only tests `containsKey`, so there is **no negative cache on the thumbnail path** — unlike the preview path, which has `_failedIds` (`:119`). A permanent-miss DNG would be re-read in full on every sweep that includes it, forever.

**Added to R3 as a required element:** a miss set (e.g. `Set<String> _thumbMissIds`, mirroring `_failedIds`) consulted alongside `_thumbCache.containsKey` at `:818` and cleared by `reset()`. New acceptance condition:

- **R3-AC6** A `.dng` for which both the native loader and the Dart extractor return nothing is requested **exactly once** across repeated `preloadThumbnails` sweeps over the same range. Red-first by deleting the miss-set check. (This is the sidebar analogue of the existing preview-path invariant I6.)

---

## 4. macOS re-benchmark plan

Dart-first touches the measured macOS perf path, so this must be stated rather than assumed. It is cheap to bound because **macOS native stays the first rung in every purpose** — every macOS request hits the same native branch it hits today, and macOS does not reach the `NativeImageFailure` fallback for these formats. The re-benchmark exists to *prove* that, not to explore it.

**Harness (already exists, no new tooling).** `lib/perf/perf_driver.dart`, gated on `HALCYON_PERF_DIR`; `PerfLog` writes `PERF|<us>|<name>|key=value` (`perf_log.dart:1-7`) and the shape is a contract consumed by `scripts/tmp/perf/parse_r2.py` — do not reshape events. Run in **profile or release**, never debug (memory `flutter-test-needs-j1-sequential` and the AC3b precedent both require non-debug semantics). Photos: `local_data/photo_samples/` only.

**Baselines to compare against** (all pre-existing, no new baseline run needed unless the tree has moved):

| Metric | Event | Baseline | Source |
|---|---|---|---|
| JPEG switch latency | `selectItem.*` → image ready, paced pass | **2.8 ms** (was 127.5 ms pre-round-2) | memory `image-switch-latency-round2-shipped` |
| macOS DNG full decode | `rawDecode.ready … dur=` | **~109.8 ms** | memory `image-switch-latency-round2-shipped` (deferred to round 3) |
| Native channel round-trip | `micro.channel … roundtrip=` | current run | `perf_driver.dart:191-198` |
| Engine decode, full vs capped | `micro.decode`, `micro.decode1800` | current run | `perf_driver.dart:202-221` |
| Dart extraction | n/a (offline bench) | **3.79 ms** median / 8.56 ms max | slot A, `tmp/verify/thumb-a-dart-extract-bench.txt` |

**Per-rung obligations and abort thresholds.**

| Rung | Re-take | Abort if |
|---|---|---|
| **R1** | `micro.channel` roundtrip + paced-pass switch latency for macOS JPEG and DNG-with-preview; `rawDecode.ready` dur for macOS DNG-without-preview | Any median regresses **> 10 %** vs the same run's pre-change baseline. R1 is in a branch macOS never enters, so the expected delta is **0**; a non-zero delta means the branch guard is wrong, which is the real thing this check is for |
| **R2** | `micro.decode` vs `micro.decode1800` to size the win; sidebar-populated `ImageCache.currentSizeBytes` after a 41-row sweep | Decoded sidebar bytes do not *fall*. R2 should strictly improve macOS; no change means the cap is not being applied |
| **R3** | Full paced + rapid pass. Specifically the **tier-1 → tier-2 transition**: exactly one tier-1 and one tier-2 decode per item | Switch-latency median regresses **> 10 %**, **or** R3-AC3 shows a third `ImageCache` entry (the silent-duplicate-decode failure AD-011 exists to prevent). Either aborts the rung |
| **R4** | Time from `main()` to first frame; `rawDecode.ready` dur for the first macOS DNG decode after launch | Startup stall **> 250 ms** attributable to warmup. On macOS the pipeline cache is unsupported (Metal) so the decode number should not move; if it moves, warmup is doing something unintended |

**Scope bound.** No re-benchmark is required for rungs that do not touch a macOS-reachable code path — but the run is cheap enough (one paced + one rapid pass) that R1 and R3 should each get one regardless, precisely because "macOS never enters this branch" is the assumption under test.

---

## 5. AD-010 / AD-011 — settled

**Does the adopted design break the freeze? No.** `NativeImageResult` keeps exactly three variants; `DngFullDecoder` and `DecodedRgba` are untouched; both tier factories are untouched. R1-AC5 checks this mechanically.

**Does it need a `memory.md` amendment? Yes.** Slot A called this correctly and I under-called it. The *type* is unchanged, but three pieces of prose assert a native-only origin for the raw-decode signal, and R1 makes all three false. Prose that lies is worse than no prose, because the next session will trust it — exactly how the stale `native_thumbnail_service.dart:122-129` comment misled the drafting of this contract in the first place (contract PL-4).

Draft replacement wording follows, for the commander to take to the user.

### 5.1 `memory.md` — append to AD-010 (file is Traditional Chinese; wording matches)

Insert after the existing `- **依據**：…` line of AD-010 (`memory.md:91`):

```
- **修訂（2026-08-22，Dart-first 採用後）**：`NativeImageNeedsRawDecode` 不再只由原生端發出。
  原設計中該 variant 唯一來源是 `AppDelegate.swift` 的 `NO_EMBEDDED_PREVIEW`
  channel error；Windows 原生端刻意回 `RAW_UNSUPPORTED`
  （`windows/runner/halcyon_image.cpp:392-403`），因此該訊號在 Windows 永遠不會出現，
  `DngFullDecoder` 成為死碼。改由 Dart 端在「原生失敗 + `.dng` + 內嵌預覽抽取落空」時
  自行建構此 variant，orientation 來自
  `DngPreviewExtractor.readOrientationFromFile`（`dng_preview_extractor.dart:41`）。
  **三個 variant 的凍結不變**（AD-011 的 tier-1/tier-2 契約亦不變）；改變的只是
  「誰建構這個 variant」。此 variant 的語意自此讀作「拿不到便宜的 bytes，且這是
  解碼器處理得了的 RAW」，與訊號的來源平台無關。
```

### 5.2 `lib/services/native_thumbnail_service.dart:52-54` — replace the doc comment

Current (asserts a native origin):

```
/// [exifOrientation] is the IFD0 Orientation tag value read natively, in the
/// range 1..8; it is [kDefaultExifOrientation] when the tag is absent or
/// unparseable. The decoder does not apply EXIF orientation, so Halcyon must.
```

Replacement:

```
/// [exifOrientation] is the IFD0 Orientation tag value, in the range 1..8; it
/// is [kDefaultExifOrientation] when the tag is absent or unparseable. It may
/// be read natively (macOS, via the [kNoEmbeddedPreviewCode] channel error) or
/// in Dart (via `DngPreviewExtractor.readOrientationFromFile`, on platforms
/// whose native bridge does not emit that code). The decoder does not apply
/// EXIF orientation, so Halcyon must.
```

### 5.3 `lib/services/native_thumbnail_service.dart:75-77` — replace the doc comment

Current (asserts macOS is the only emitter):

```
/// Native error code signalling [NativeImageNeedsRawDecode]. Emitted by
/// `macos/Runner/AppDelegate.swift` only for `purpose == "preview"` on a
/// `.dng` whose embedded-JPEG extraction returned nil.
```

Replacement:

```
/// Native error code signalling [NativeImageNeedsRawDecode]. Emitted by
/// `macos/Runner/AppDelegate.swift` only for `purpose == "preview"` on a
/// `.dng` whose embedded-JPEG extraction returned nil. It is NOT the only
/// source of [NativeImageNeedsRawDecode]: `windows/runner/halcyon_image.cpp`
/// deliberately returns `RAW_UNSUPPORTED` instead, and the Dart pipeline
/// synthesises the variant itself in that case (see AD-010's 2026-08-22
/// amendment). Do not reintroduce an assumption that this code is the only
/// way the raw-decode path can be entered.
```

**Recommendation to the user:** record this as an **amendment to AD-010**, not a new AD and not a break of the freeze. The decision AD-010 made (a `DngFullDecoder`/`DecodedRgba` integration seam so the pipeline is unit-testable without the native library) is unchanged and is in fact what makes R1 possible at all.

---

## 6. What stays out

| Item | Status | Owner / where |
|---|---|---|
| Windows JPEG export strips all EXIF (`halcyon_image.cpp:171-272` encodes pixels only vs `AppDelegate.swift:265-282`) | **Separate ticket — referenced, not planned here** | **Task #10**, another member |
| Windows RAW export (all four RAW rows in the export matrix) | Parked | Needs either Task #10's encoder plus a Dart resizer, or Native Parity |
| Non-DNG RAW on Windows (`.arw/.cr2/.nef/.orf/.rw2`) | Parked | No Dart extractor exists; the Dart fallback is gated on `.dng` (`image_preload_controller.dart:659`) |
| Native Parity / candidate C (WIC RAW, C++ TIFF walker) | Parked | Also blocked by the §1.3 standing rule: no new TIFF walker in any language |
| Delete `macos/Runner/DngPreviewExtractor.swift` | **Withdrawn by me** (§1.3) | Reconsider only if extractor drift is actually observed |
| A `targetWidth` parameter on `decodeOnWorker` | **Upstream feature request** | `flutter_dng_decoder`; unblocks a sidebar thumbnail for preview-less DNGs (§3.1) |
| HEIC on Windows (needs the optional HEIF Image Extensions package, `halcyon_image.cpp:287-289`) | Parked | Slot A's finding; needs its own row in a future contract |
| iOS / Linux / Android (`MissingPluginException` at `native_thumbnail_service.dart:122` **is** live there) | Out of scope | Slot A's finding; this plan's Dart-first shape is what would pay off there |

Per the convergence-contract rule, nothing in this table enters the current round, becomes an acceptance condition, or jumps the queue.

---

## 7. The 1-second ceiling, per rung

The number nobody has: **cold first-decode wall-clock for a preview-less DNG on Windows.** W14 was never run (`windows-ffi-r2-handover.md` §2, `[W] 未動`). The user's confirmation that the DLL renders correctly is not a timing. Both analyses named this as the top unknown.

**The plan does not hinge on it.**

| Rung | Can it ship before the number exists? | Why |
|---|---|---|
| **R1** | **Yes** | The alternative today is a permanent error screen. A slow picture strictly dominates no picture. The decode is `unawaited` off the tier-2 debounce (`:447`), so a slow decode delays an image, it does not stall the app or block navigation |
| **R2** | **Yes** | Never touches the decoder |
| **R3** | **Yes** for the ceiling — but **blocked on its own measurement M1** (§3.2), which is takeable here, today, on macOS |
| **R4** | **Yes** | This rung is the mitigation. Shipping it before the measurement is what makes the measurement worth taking |

**What to do with the number once it exists.** Measure on the user's Windows machine after R1+R4 land, using the existing `HALCYON_PERF_DIR` harness (`rawDecode.ready … dur=`), first decode after a cold launch and again after a second launch (to see whether the pipeline cache produced a cross-launch hit — `pipelineCacheStatus` bit 4). Then:
- **< 1 s** → done; record it and close the R2-handover P3 item.
- **≥ 1 s on first launch but < 1 s on second** → the pipeline cache is working; decide with the user whether a first-run-only stall is acceptable, or whether warmup should move earlier.
- **≥ 1 s on both** → escalate to the R2 handover's P3 (VkPipelineCache fork generalisation), which that document already says requires its own handover and user decision. **That is a new round, not a blocker on R1.**

---

## 8. Open items I could not settle

1. **[U] Whether `warmupForSize`'s own isolate warms the later decode isolate.** Slot A's catch, and it is the sharper form of the question. `dng_decoder_service.dart:144-147` runs warmup inside `Isolate.run`; the neighbouring `setPipelineCachePath` comment (`:156-157`) asserts native state is process-global, which implies yes — but that is an inference from a comment about a different function, untested on any platform. If it is false, R4's warmup half is a no-op (the pipeline-cache half still works). Falsifiable on Windows by comparing `rawDecode.ready` dur with and without R4.
2. **[U] Whether the shipped Windows DLL was built with `DNG_VK_PIPELINE_CACHE=ON`.** If not, `setPipelineCachePath` returns -1 and half of R4 evaporates. Checkable in one line on the user's machine via `pipelineCacheStatus` (bit 1 = enabled).
3. **[MEASURED — byte half done, §3.3]** M1's byte volume is taken: mean 7.14 MB/file → 293 MB per 41-row sweep (passes), max 24.03 MB → 985 MB (fails). Split verdict; resolved by making the byte-range rewrite part of R3. **Still open: the wall-clock half**, which needs a throwaway harness this planning-only task could not write. It is now a confirmation rather than a gate — the byte-range rewrite makes the wall-clock question moot for the sidebar, so the harness is only needed if the rewrite is deferred against my recommendation.
4. **[U] Whether R2's cap changes any macOS thumbnail visibly.** The dimensional tests (R2-AC1/AC2) prove correctness, not aesthetics, and UI-driven verification is banned. If the user wants a visual confirmation it has to be their own eyes on a build.
5. **[TASTE — R6.1] Whether "one Dart chain" or "each runner implements the contract" is the right long-run shape.** Slot A named this and I agree it is a taste call. Both of us argued from verifiability, which is fact-shaped; a reviewer who weighs "native platforms should look native in their own language" would land elsewhere. The user has now chosen Dart-first, so this is recorded as settled-by-decision, not settled-by-argument.
6. **[SETTLED by §3.3, was: whether R3 should ship at all if M1 fails badly.]** M1 did not fail badly — it failed *conditionally*, on camera sensor size. The byte-range rewrite removes the condition and is contained (the parser already computes `offset`/`byteCount`; only the buffer source changes), so R3 ships with the rewrite included. The fallback option I had held in reserve — leave the rows blank but give them an explicit **error marker** instead of a silent grey square — is still worth doing on its own merits for the case in §3.1 (preview-less DNGs, which get no sidebar thumbnail under any candidate). Recommend folding that marker into R3 as a UI affordance; it is the difference between "this file has no thumbnail" and "this app is broken". Not added as an acceptance condition, since it is a visual affordance and this project bans UI-driven verification — flagging it for the user to decide.
