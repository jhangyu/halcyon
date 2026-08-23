# M3 unaccepted lineage audit (0e6407e .. 867b6ee)

> Date: 2026-08-23
> Auditor: m3-lead-opus (read-only audit; no lib/ or test/ file was modified by this task)
> Worktree: `/Users/jhangyu/project/halcyon-m3`, branch `m3-cache`, HEAD `1ba170a`
> Tree state at audit time: clean apart from gitignored `scripts/tmp/` entries. The two-call
> seam WIP named in the takeover handover §2 (`M lib/services/image_preload_controller.dart`,
> `M lib/services/photo_source.dart`) is **no longer present** — it was discarded by the
> orchestrator into `scripts/tmp/verify/20260823-two-call-seam-wip-discarded.patch`.
> Authority audited against: frozen contract + Amendments 1–3 in
> `docs/logs/2026-08-23/m3-midround-handover.md`, user clarifications in
> `docs/logs/2026-08-23/m3-round-1-sonnet-takeover-handover.md` §1, and the orchestrator-relayed
> user ruling that the probe seam MUST be a SINGLE `PhotoSource` probe returning BOTH the cost
> rung and EXIF orientation from ONE bounded IFD walk.

## 0. Scope correction: the audit list was incomplete

The assigned list was `0e6407e, ebc59dc, 1ba1bee, be9e05e, cb2175f, 867b6ee`. `git log` shows
**four further test-only commits** between `cb2175f` and `867b6ee` that are equally unaccepted and
are part of the same base:

```
cb2175f docs(logs): freeze Amendment 3 repair checkpoint
0f053a8 test(services): complete translated M3 P1 and P3 probes
f04ef67 test(services): extend translated M3 P4 controls
911bc7e test(services): add Amendment 3 scheduling controls
9f1547d test(services): add real probe-first scheduling controls
867b6ee test(services): cover Amendment 3 probe and retention boundaries
```

They are audited below together with `867b6ee`, since their combined result is exactly the two
frozen test blobs.

## 1. Frozen-blob hash verification (required by takeover handover §4)

Verified with `shasum -a 256` against the current working tree at `1ba170a`:

| File | Required SHA256 | Observed | Verdict |
|---|---|---|---|
| `test/dng_nav_probe_m3_test.dart` | `be3a595d6cc49c48d9f4bd29e91ecf5827261c50ae6b5d1c18e911e8b47d2341` | identical | **MATCH** |
| `test/image_preload_controller_m3_amend3_test.dart` | `fcdd564ea168039b68ae63a3497d784a9824d5fb141885777bfc3fb3e44c019c` | identical | **MATCH** |
| `scripts/tmp/dng_nav_probe_test.dart` (AC1 oracle) | `05565d3347f6e7e3746a8e2702c45ff854a52e1a80bb181c581f8eee4051f77f` | identical | **MATCH** |

The historical-RED gate condition ("a future reviewer must verify these test bytes remain
identical") is therefore **satisfied at `1ba170a`**.

## 2. Per-commit disposition

| Commit | Kind | Disposition |
|---|---|---|
| `0e6407e` refactor(services): unify image payload pipeline | production + tests | **RETAIN AS BASE, NEEDS REWORK** by m3-impl-1-opus (two named conflicts, §3) |
| `ebc59dc` docs: M3 mid-round hold handover | docs only | **RETAIN AS-IS** |
| `1ba1bee` docs: correct M3 hold state | docs only | **RETAIN AS-IS** |
| `be9e05e` docs: record M3 user correction (Amendment 3) | docs only | **RETAIN AS-IS** — carries the authoritative user correction |
| `cb2175f` docs: freeze Amendment 3 repair checkpoint | docs only | **RETAIN AS-IS, with a caveat** (§4) |
| `0f053a8`, `f04ef67`, `911bc7e`, `9f1547d`, `867b6ee` | test only | **RETAIN AS-IS (frozen, byte-verified)** — but they *constrain* the new probe API (§3.3) |

None of these commits needs to be reverted. The reworks are forward edits inside
`0e6407e`'s files, which keeps the "no destructive history operation" red line intact.

## 3. `0e6407e` against the frozen contract

### 3.1 What passes, mechanically (checked at `1ba170a`, read-only)

| AC | Command | Result |
|---|---|---|
| AC3 | `grep -c "EncodedPayload\|PixelPayload" lib/services/photo_payload_cache.dart` | `0` — **PASS** |
| AC4 | same grep as contract over controller / scheduler / cache | `0` for all three files — **PASS** |
| AC5 | grep in `lib/` for `DecodedRgbaImageProvider`, `_needsRawDecode`, `decodedImageFor`, `decodedProviderFor`, `debugDisposed`, `_decodedImages`, `_fallbackToLegacyBytes`, `readOrientationFromFile` | `0` hits each — **PASS** |
| AC6 (static half) | `grep -n "dispose()" lib/services/*.dart` | only `decoded_rgba_image_provider.dart:31,37,129,130,184` (transient `ui.Image` inside the RGBA conversion, not a cached payload) and `image_preload_controller.dart:254` (the controller's own `dispose`). No cached-payload disposal — **PASS** |
| AC11 | `git diff e234182 -- lib/views/main_detail_view.dart` | only an import swap and the `DecodedRgbaImageProvider? -> RawPixelsImage?` parameter retype; the call sites at `main_detail_view.dart:280-281` (`fullSizeProviderFor` / `tierOneProviderFor`) are unchanged — **PASS** |
| AC13 | `grep -n tierOneProviderFor/fullSizeProviderFor` | both still defined in `image_preload_controller.dart:28,44`; no DecodeTiers file — **PASS** |

Uniform retention is genuinely type-blind: `retentionWindowIds` (`photo_payload_cache.dart:117-126`)
computes `-kRetentionBefore..+kRetentionAfter` from index only, and `preloadImages`
(`image_preload_controller.dart:288-294`) applies it to every item with no type or cost branch.
Amendment 3 item 1 (**uniform retention/cache for every file**) is **SATISFIED**.
`±1` appears only as `kExpensiveStartupRadius` / `allowsExpensiveWork(distance:)`
(`prefetch_scheduler.dart:12,93`), never in the retention path — the user's
"`±1`: expensive RAW STARTUP eligibility only, never a retention boundary" is **SATISFIED**.

### 3.2 CONFLICT 1 — probe is deliberately skipped for the selected item and ±1

`image_preload_controller.dart:486-495`:

```
if (cost == null && !_scheduler.allowsExpensiveWork(distance: distance)) {
  // Content probe, and ONLY here. It is deliberately not run for the
  // selected item or its immediate neighbours: those are about to ask the
  // bridge anyway ...
  cost = await _scheduler.classify(id, file.path, longEdge: _longEdge);
}
```

This is a **location-dependent classification**: at `distance <= 1` the item is *not* probed, so
`_ensurePayload` falls through to `_source.load(...)` (`:517`), which calls the native bridge at
`photo_source.dart:98`. This is precisely the framing Amendment 3 item 2 rejects verbatim —
"Content probe FIRST for EVERY image … Location-dependent 'hot-window bridge first'
classification is rejected; it was erroneous framing, not a user decision."

It is also exactly what the historical RED captured against this same predecessor
(takeover handover §4): *"selected real no-preview DNG: expected bridge calls 0, actual 1"* and
*"+1 real no-preview DNG: expected bridge calls 0, actual 1"*, and it is what frozen test
`test/dng_nav_probe_m3_test.dart` TC-088 asserts at distances 0, 1 and 3.

**Verdict: NEEDS REWORK.** The probe must run first for every item regardless of distance.

### 3.3 CONFLICT 2 — orientation comes from the bridge, not from the probe

The current seam carries EXIF orientation forward from the bridge answer:
`photo_source.dart:108-128` returns `exifOrientation` out of `NativeImageNeedsRawDecode`; the
controller stores it in `_deferredOrientations` (`image_preload_controller.dart:510,523-525`) and
the debounced pass then calls `PhotoSource.loadExpensive(..., exifOrientation:)`
(`photo_source.dart:172-207`, controller `:511-516`).

That design *requires* one bridge round trip before an expensive item can be decoded, which is the
mechanical cause of CONFLICT 1. The user's single-probe ruling replaces it: orientation must come
out of the same bounded IFD walk that decides the rung, so an expensive item needs **zero** bridge
calls before its debounced RAW decode.

`PhotoSource.probe` today returns `SourceCost?` only (`photo_source.dart:236-256`) and reaches only
`DngPreviewExtractor.largestCandidateLongEdge` (`dng_preview_extractor.dart:208`); orientation lives
in a *separate* walk, `DngPreviewExtractor.readOrientation` (`:109`). Both open the file, build a
reader and parse IFD0 independently — calling them in sequence would be the two-walk shape the user
rejected. They must be merged at the `reader + ifd0` level, where `_orientationOf` (`:187`) and
`_gatherCandidates` (`:286`) already share the same inputs.

**Verdict: NEEDS REWORK.** `_deferredOrientations` and the bridge-sourced orientation path are
superseded; `loadExpensive`'s `exifOrientation` should be fed from the probe.

### 3.4 CONFLICT 3 (lower severity) — expensive RAW decodes still fan out

`image_preload_controller.dart:402-413` launches the debounced expensive loads with `unawaited(...)`
inside the `tierStart..tierEnd` loop, so up to three `±1` RAW decodes can run concurrently. The
historical RED recorded *"three RAW decodes: expected max concurrency 1, actual 3"*, and the user
clarification requires "no embedded JPEG -> **sequential** RAW decode after unchanged 250 ms
debounce". **NEEDS REWORK** (already in the implementer's kickoff §7c/§7d).

### 3.5 API constraint imposed by the frozen test blobs

`test/dng_nav_probe_m3_test.dart:147` and `:180` call `await PhotoSource.probe(path, longEdge: 2800)`
and compare the result **directly** to `SourceCost.expensive` / `SourceCost.cheap`. Those bytes are
hash-frozen (§1). Changing `probe`'s return type to a record therefore breaks compilation of a file
that may not be edited.

Resolution directed to the implementer (and flagged to the orchestrator): make the canonical
entry point return both values from the one walk (e.g. `probeSource(...) -> ({SourceCost? cost,
int? exifOrientation})`) and keep `probe(...)` as a **projection of that same single walk**
(`(await probeSource(...)).cost`). The user ruling constrains the number of IFD *walks*, not the
number of identifiers; a projection performs no additional walk. If the orchestrator prefers a
single identifier instead, that requires authorization to edit the frozen blobs — which would
invalidate the §4 historical-RED byte-identity gate, so it is not taken unilaterally.

## 4. Docs commits — caveat on `cb2175f`

`cb2175f` freezes an "Amendment 3 recovery checkpoint" naming
`tmp/verify/amend3-current-controller-wip.patch` (SHA `eeffcba2…`) and
`tmp/verify/amend3-current-preserve-status.txt` (SHA `de94c46e…`) as the preserved controller WIP.
That WIP has since been discarded by the orchestrator under the single-probe ruling, and the
checkpoint's "STOP/PRESERVE-only" instruction is **superseded**. The commit is retained as an
accurate historical record; its instruction must not be followed as a live order. Recorded here so
a later reader does not resurrect the two-call WIP from it.

`ebc59dc`/`1ba1bee`/`be9e05e` are the durable carriers of the frozen contract and Amendment 3 and
are retained unchanged.

## 5. Acceptance status carried forward

No commit in this lineage produces acceptance evidence. Per takeover handover §3 all prior
batteries (including `bggsobn3g`, the `+33` targeted run, and the withdrawn `N=31`/`N=25` counts)
remain invalid. The static ACs in §3.1 are **audit observations at `1ba170a`**, not signoff: they
must be re-run hash-bound against the post-rework HEAD by m3-test-haiku before signoff. AC1's
oracle hash is verified; AC2/AC7/AC9/AC10/AC12/AC14 are unrun; AC8 (RSS < 350 MB) stays **BLOCKED**
on ≥9 user-supplied real no-preview DNG samples and is sequenced last.

## 6. Rework items handed to m3-impl-1-opus

1. Probe FIRST for every item at every distance — remove the `distance <= 1` probe skip
   (`image_preload_controller.dart:486-495`).
2. Single bounded IFD walk returning cost + EXIF orientation; retire the bridge-sourced
   `_deferredOrientations` path (`:510,:523-525`, `photo_source.dart:108-128,172-207`).
3. Sequential expensive RAW decode in the debounced pass (`:402-413`).
4. Keep `test/dng_nav_probe_m3_test.dart` and
   `test/image_preload_controller_m3_amend3_test.dart` byte-identical; satisfy them by keeping a
   `probe()` projection over the single walk.

## 7. Orchestrator ruling on the probe API (2026-08-23, post-audit)

The §3.5 question was escalated and ruled. **The lead's default is APPROVED**: the user's ruling
constrains the number of IFD **walks** (one walk yields both the cost rung and EXIF orientation), not
the number of identifiers. Editing the hash-frozen blobs to collapse to a single identifier would
invalidate the §4 byte-identity gate, which is strictly worse.

Two constraints are BINDING and become acceptance gates:

1. **`probe()` is a pure delegation.** It calls the canonical entry point and projects the cost
   field. It must contain no walk logic, no branch, and no file open of its own — so a caller that
   needs both values is structurally incapable of triggering a second walk.
2. **No production caller of the projection.** `image_preload_controller.dart`,
   `prefetch_scheduler.dart` and `photo_source.dart`'s own internals call ONLY the canonical entry
   point. Mechanical gate added to the acceptance battery: grep of `probe(` call sites in `lib/`
   shows ZERO production callers of the projection. (`prefetch_scheduler.dart:71` is the one call
   site that must move.) The projection exists solely to keep
   `test/dng_nav_probe_m3_test.dart:147,:180` compiling against frozen bytes.

**Note for M5/M6 leads: do NOT "clean up" the `probe()` projection.** It is not redundancy; it is
what keeps the frozen historical-RED test blob byte-identical. Removing it requires user
authorization to edit those blobs, which retires the §4 gate.

The orchestrator also confirmed the §3.2–§3.4 rework conflicts as consistent with the user's
clarifications (probe-first for EVERY item including the selected item and ±1; orientation from the
probe rather than the bridge; sequential expensive decodes), and acknowledged AC8 as blocked on
user-supplied samples, sequenced last.
