# M3 Seam Review Verdict — probeOrientation() vs single-probe ProbeResult

> Reviewer: m3-seam-review-sonnet (static review only, no build/test run)
> Subject: uncommitted `lib/services/photo_source.dart` + `lib/services/image_preload_controller.dart`
> Worktree: `/Users/jhangyu/project/halcyon-m3` @ `1ba170a` + uncommitted WIP

## VERDICT: REFUTED-SEAM

The two-call shape (`probe()` then, separately, `probeOrientation()`) is functionally
correct for the execution-model invariants (Q3, Q4) but is architecturally unsound
against the design authority's own "walk the IFD once" framing (Q1) and it silently
escapes the AC14 disk-budget instrumentation (Q2). The seam should be replaced with a
single bounded `PhotoSource.probe` returning `{cost, orientation}` from one IFD walk,
per the design authority's alternative.

## Per-question answers

**Q1 — Can a single bounded probe return both cost and orientation from one IFD walk?**
YES, and the current code already proves it's mechanically trivial. `DngPreviewExtractor.largestCandidateLongEdge`
(`lib/services/dng_preview_extractor.dart:208-242`) already parses `ifd0` at line 221
(`final ifd0 = _readIFD0(reader);`) before gathering candidates at line 226. Orientation is
just `_orientationOf(reader, ifd0)` (`dng_preview_extractor.dart:187-193`), which is exactly
what `_walk()` already does inline at `dng_preview_extractor.dart:255` in the SAME walk used
for real extraction. `largestCandidateLongEdge` throws away `ifd0` after building `candidates`
instead of also returning orientation — nothing structural blocks folding it in.

**Q2 — Does the two-call shape cause a double TIFF/IFD walk or violate the ≤300KB probe budget?**
YES to the double walk, and it breaks the AC14 accounting mechanism specifically.
`PhotoSource.probe()` (`photo_source.dart:244-264`) calls `_readHead` (own `File.open()`) then
`DngPreviewExtractor.largestCandidateLongEdge` (its own second `File.open()` + header +
IFD0 parse, `dng_preview_extractor.dart:212-220`). The new `probeOrientation()`
(`photo_source.dart:241-242`) calls `DngPreviewExtractor.readOrientation`
(`dng_preview_extractor.dart:109-132`), which is a THIRD, fully independent `File.open()` +
header/byte-order detect + IFD0 parse for the same file. This is a genuine third redundant
walk of IFD0 for every item the scheduler measures `expensive`, not "the same bounded walk"
the `photo_source.dart:236-240` docstring claims.
More importantly: AC14 ("probe disk reads <= 300 KB per file, made checkable by threading the
existing onDiskRead callback", `docs/logs/2026-08-23/m3-midround-handover.md:230-231`) is wired
through `probe`'s `onDiskRead` parameter (`photo_source.dart:246-247`, `dng_preview_extractor.dart:210`).
`probeOrientation()` (`photo_source.dart:241-242`) and its callee `readOrientation`
(`dng_preview_extractor.dart:109-112`) accept an `onDiskRead` parameter too, but
`PhotoSource.probeOrientation` never forwards a callback and
`ImagePreloadController._classifyItem` (`image_preload_controller.dart:449`) calls it with none —
so every byte `probeOrientation` reads is invisible to whatever future AC14 gate exists. The
budget could read "green" while total real disk I/O for a probed item is silently ~2x what
AC14 measures. In absolute bytes this is likely still small (IFD0-only, no strip read), so it is
not expected to blow past 300 KB in practice, but the instrumentation gap itself is the defect:
AC14 as wired cannot currently prove the combined probe+probeOrientation footprint is inside budget.

**Q3 — At-most-one ImageBytesLoader/bridge call per item on selected/+1 real no-preview DNG and fake/unreadable paths?**
PRESERVED (verified by static trace, not executed).
For a real no-preview DNG: `_classifyItem` (`image_preload_controller.dart:439-454`) resolves cost via
the pure-Dart `_scheduler.classify` → `PhotoSource.probe` (no bridge call) and, for `expensive`,
via `PhotoSource.probeOrientation` (also pure-Dart, no bridge call) — storing the result in
`_deferredOrientations`. In `_ensurePayload` (`image_preload_controller.dart:461-605`), for
distance 0 and 1 on the immediate (non-debounced) pass, the gate at
`image_preload_controller.dart:528-532` (`cost == expensive && !allowExpensive && _deferredOrientations.containsKey(id)`)
returns BEFORE calling `_source.load`/`_source.loadExpensive` — so the immediate pass makes ZERO
bridge calls for a real no-preview DNG. The debounced +/-1 pass (`_decodeTierTwoWindow`,
`image_preload_controller.dart:409-414` → `_ensurePayload(..., allowExpensive: true)`) then hits
`_source.loadExpensive` (`photo_source.dart:172-207`), which calls `dngDecoder` directly and never
calls `loader`/`ImageBytesLoader` at all. Net: 0 bridge calls total for a real no-preview DNG whose
probe is conclusive — inside the "at most one" bound.
For fake/unreadable paths: `PhotoSource.probe`'s `_readHead` (`photo_source.dart:266-285`) fails to
open the file and returns `null`; `classify` does not memoize a null result
(`prefetch_scheduler.dart:69-73`), and `_classifyItem`'s `cost == SourceCost.expensive` check
(`image_preload_controller.dart:448`) is false for a null cost, so `probeOrientation` is never called.
Later, `_ensurePayload` (distance 0/1) falls through to exactly one `_source.load` call
(`image_preload_controller.dart:546-550`), which is the existing single-bridge-call fallback path
(design A-§2 rule 2). Confirmed at most one.

**Q4 — Preserves common -3..+5 retention, 250ms debounce, sequential RAW, cheap parallel work?**
PRESERVED.
- Retention: `kRetentionBefore=3` / `kRetentionAfter=5` (`photo_payload_cache.dart:6,10`), used
  unchanged by `retentionWindowIds` (`photo_payload_cache.dart:117-124`) and by the new
  classify-sweep's own `startIdx`/`endIdx` (`image_preload_controller.dart:299-303`), which is
  computed from the SAME constants — the classify sweep runs over the retention window, not a
  narrower one, matching Amendment 3 clause 1/2 ("EVERY item... content probe FIRST").
- 250ms debounce: `tierTwoNavigationDebounce` unchanged (`image_preload_controller.dart:49`);
  `_scheduleTierTwoDecode` (`image_preload_controller.dart:360-369`) still cancels/reschedules a
  single `Timer`, only wrapped in `unawaited(...)` instead of a bare call — same fire condition.
- Sequential RAW: `_decodeTierTwoWindow` (`image_preload_controller.dart:376-437`) replaced the old
  `unawaited(_ensurePayload(...).then(...))` fire-and-forget per-item loop with a synchronous
  `await _ensurePayload(...)` inside the `for` loop (`image_preload_controller.dart:409-417`). This
  literally serializes any RAW decode work across the (at most 3-item, `kExpensiveStartupRadius=1`)
  tier-2 window instead of firing them concurrently — directly implements Amendment 3 clause 2
  ("no embedded JPEG -> sequential RAW decode") and fixes the historical RED capture ("three RAW
  decodes: expected max concurrency 1, actual 3", `m3-round-1-sonnet-takeover-handover.md:124`).
- Cheap parallel work: the classify sweep (`Future.wait([...])`,
  `image_preload_controller.dart:316-318`) and the immediate-pass window loads
  (`Future.wait(pendingLoads)`, `image_preload_controller.dart:331-341`) are both still
  `Future.wait`-parallel, unchanged in shape.

**Q5 — Is photo_source.dart otherwise scope-clean?**
MOSTLY. The diff to `photo_source.dart` is exactly the 9-line `probeOrientation` addition
(`photo_source.dart:241-242` plus its doc comment `:236-240`); no other lines changed. It does not
touch `load`, `loadExpensive`, `probe`, or the DELETE-list items. The scope issue is not "extra
code moved in" but the architectural shape of what was added: a second, disk-I/O-duplicating
static method that the design authority's §3.1 step 2 describes as a single walk ("走一次 IFD"),
and whose caller (`image_preload_controller.dart:449`) invokes it as a second awaited call rather
than folding it into the same probe result. This is the seam under review, and it is the reason
for the REFUTED verdict above — not an unrelated scope violation.

## Negative-space check

What this diff removes/stops handling, and who depends on it: nothing pre-existing is removed.
The change is additive (new method, new call sites in the controller) and the immediate-pass
early-return at `image_preload_controller.dart:528-532` is new gating that did not exist before,
not a removal of prior gating. The one behavior change worth flagging explicitly: tier-2 RAW
decodes for multiple items in the +/-1 window now run strictly one-after-another instead of
concurrently, which can delay the LATER item's landing (e.g. two consecutive no-preview DNGs at
-1 and +1 now take ~2x as long combined to both become ready as before). This is the intended,
user-mandated trade (Amendment 3 clause 2, D2), not an accidental regression, but it is a real
latency change for that specific multi-neighbor-RAW scenario and should be named as such in any
acceptance battery, not silently assumed equivalent to the old fire-and-forget behavior.

## Acceptance criteria status

1. Verdict file exists at `docs/logs/2026-08-23/m3-seam-review-verdict.md` with one verdict line
   and five per-question answers, each with file:line citations. PASS (this file).
2. `git status --porcelain` after this review shows only the pre-existing entries plus this new
   verdict file. PASS — verified below.
3. `scripts/tmp/dng_nav_probe_test.dart` untouched, sha256 unchanged. PASS — verified below, file
   not read/written by this review.
