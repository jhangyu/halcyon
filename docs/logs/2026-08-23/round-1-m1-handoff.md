# Round 1 — M1 Handoff

> Written at round close, 2026-08-23. Commit `25005d1` on branch `m1-sidebar`, parent `40dc5fc`.
> Design authority: `docs/logs/2026-08-23/image-pipeline-redesign-handover.md` §6 M1.
> Prior round: `docs/logs/2026-08-23/round-1-m0-handoff.md`.

## Outcome

**AC1–AC6 all PASS. Independent adversarial review: CONFIRMED, zero blockers, five non-blocking
findings.** Two files changed, 209 insertions, 2 deletions.

| File | Change |
|---|---|
| `lib/views/sidebar_view.dart` | `_buildListThumbnail`: decode-time cap via `ResizeImage(..., policy: fit)` |
| `test/sidebar_view_m1_test.dart` | new, 1 test (AC2 + AC3 in one discriminating case) |

Suite 188 → 189, delta exactly +1. `flutter analyze` clean.

### The change

`sidebar_view.dart:281-294`. `Image.memory(bytes, width: 32, height: 32)` became:

```dart
final cap = (32 * MediaQuery.of(context).devicePixelRatio).round();
Image(image: ResizeImage(MemoryImage(bytes), width: cap, height: cap,
                         policy: ResizeImagePolicy.fit))
```

Layout `width/height: 32`, `BoxFit.cover`, `gaplessPlayback: true` and the `ClipRRect(4)` are
unchanged. `width`/`height` on `Image.memory` were only ever LAYOUT constraints — the decoder
still produced a full-resolution bitmap. This caps the DECODE.

**This milestone buys nothing visible today.** Both platforms already cap `sidebarThumbnail`
natively at 200 px, so 41 rows cost ~4.4 MB either way. It is a precondition for M3, where the
unified cache can hand this widget a full-size image and the old code would decode ~96 MB/row.

## Evidence

All artifacts in `tmp/verify/` (gitignored; paths recorded here because the round record must
name where the evidence lived, not because it survives).

| AC | Result | Evidence |
|---|---|---|
| AC1 oracle untouched | PASS | `git diff 40dc5fc -- test/dng_preview_extractor_test.dart` = 0 lines; `m1-signoff-20260823-061525.txt` |
| AC2 longest edge ≤ 32×dpr+1 | PASS | RED `Expected: <=97 / Actual: <400>`, TestFailure at `sidebar_view_m1_test.dart:163`, EXIT=1 — `sidebar_m1_RED.log`, reproduced by reviewer in `review-RED.txt` |
| AC3 aspect within 1% | PASS | same test; mutation `fit`→`exact` fails it (`review-mutation-exact.txt`) |
| AC4 analyze | PASS | `No issues found! (ran in 0.6s)` — `m1-signoff...txt:51`, `review-analyze.txt` |
| AC5 suite 188+1 | PASS | `00:26 +189: All tests passed!` — `m1-signoff...txt:306`; reviewer measured base=188 in a separate worktree (`review-base-suite.txt`) so the delta is anchored outside the freeze |
| AC6 file boundary | PASS | `git diff --name-only 40dc5fc` = exactly the two files |

Reviewer report: `tmp/verify/review-m1-adversarial.txt`. Verdict CONFIRMED, all evidence
self-produced, including a detached review worktree at `40dc5fc`, two mutations, and a
dpr × source-size probe.

### Correction to the signoff record

My signoff cited `lead-sidebar_m1_RED.log` and `sidebar_m1_RED.log` as **two-party
corroboration**. That was wrong. The files are byte-identical
(md5 `b338bc634415b14cb6859903a6fa8f12`) *including the `00:00` timing prefixes*, and their
mtimes differ by 16.8 ms — two real `flutter test` runs, each with a pub-get preamble, cannot
land 17 ms apart. One is a copy of the other. Caught by the reviewer (F5).

The AC2 red is nonetheless real and **more** strongly attested than I claimed: single-party
capture **plus independent reviewer reproduction in a separate worktree at base**. Do not cite
the byte-identical pair as dual evidence.

Method note worth keeping: byte-identity across "independent" runs is a smell, not a
confirmation. Deterministic output makes the check weak; the discriminator is a run-specific
artifact (mtime spacing, durations, a nonce), not the content.

## Known limitations — parking lot

Nothing below blocks the merge. Trigger conditions say when each stops being deferrable.

| # | Finding | Trigger |
|---|---|---|
| **F1** | **dpr term has no discriminating assertion.** Mutation `cap = (32*dpr).round()` → `cap = 32` is **GREEN**. Per M0 structural finding #2, that half of the gate is decorative. An upper bound can never catch under-sizing; a refactor dropping the dpr factor ships half-resolution blurry thumbnails on every retina display, silently. Fix: a second case at dpr 1.0 asserting decoded longest edge **equals** 32, or parameterize dpr over {1.0, 3.0} and assert the edge tracks it. | **Before M3 builds on the cap** |
| F2 | "aspect within 1%" is a property of the fixture, not the implementation. Reviewer counterexample: dpr 1.5, source 200×133 → decoded 48×31, **2.97%** error, from Flutter's integer truncation (`targetHeight = targetWidth ~/ aspectRatio`). Not the `exact`-policy squash (100% off), and `BoxFit.cover` in a 32×32 box hides it — shipped behaviour is fine, the AC text was over-claimed. Restate the bound as **"no distortion beyond integer rounding"**. | Whenever the AC text is reused |
| F3 | `sidebar_view.dart:281` uses `MediaQuery.of(context)`, registering a dependency on the **whole** `MediaQueryData`. SidebarView had none before this diff. Every window resize, text-scale, inset or brightness change now rebuilds the entire sidebar list. Fix: `MediaQuery.devicePixelRatioOf(context)` (`media_query.dart:1652`), aspect-scoped. | **Next time `sidebar_view.dart` is touched** |
| F4 | `cap = (32*dpr).round()` has no `> 0` guard. `Image.memory` asserts `cacheWidth > 0`; the raw `ResizeImage` path does not. dpr < 0.016 yields cap 0. Unreachable on supported platforms; noted only because the assert was dropped with the named constructor. | If a non-display/synthetic dpr source appears |
| F5 | The two RED logs are a copy, not independent runs (see correction above). | Closed — recorded |
| L1 | Test pins dpr to 3.0 (subsumed by F1). | — |
| L2 | No assertion that the cap holds on the **real** native thumbnail path; fixture is synthetic, injected via a fake `thumbnailLoader`. Native caps at 200 px today, so M1's value is latent until M3. | M3 |
| L3 | AC5's "189" is an environment property, not a commit property (see P1/P2). | Every future contract |

### Process parking lot

**P1 — Worktree provisioning must carry gitignored test material.** `local_data/` is gitignored
(`.gitignore:14`), so `git worktree add` did not carry it and ~40 tests failed on missing
samples — including `app_state_test` TC-049, which read as a real collision-handling bug and was
not one. Cost the round a full diagnosis cycle. Fix applied here, and the shape matters: a bare
`local_data` **symlink** does NOT match the pattern `local_data/` (trailing slash = directory
only) and shows as `?? local_data`, breaking AC6. Use a **real directory containing an inner
symlink** to `photo_samples`; verify with `git check-ignore -v local_data`. Orchestrator has
accepted this for M2 onward.

**P2 — A frozen baseline count must name the tree it was measured in.** "+188 all green" held in
the main repo and not in the fresh worktree. The reviewer did this correctly: measured base in
its own detached worktree so the +1 delta is anchored independently.

**P3 — Real `Timer` inside the preload path defeats FakeAsync.** `AppState.loadFolder` triggers
`preloadThumbnails`, which starts a **real** 100 ms `Timer`
(`image_preload_controller.dart:791`). `tester.pump(Duration)` advances FakeAsync and does **not**
fire it; the test needs `tester.runAsync()` + a real wall-clock delay before thumbnail bytes
land. Documented inline in `sidebar_view_m1_test.dart`. **This will bite any M3/M4 widget test
touching the preload path.**

## Contracts and invariants preserved

Verified by the reviewer's negative-space pass, recorded so M2/M3 do not have to re-derive it:

- **ImageCache identity holds.** `ResizeImageKey` wraps `MemoryImage`'s key (bytes identity) plus
  cap/policy/allowUpscaling. `thumbnailBytesFor` returns the stable `_thumbCache[id]` `Uint8List`,
  so the key is stable across `itemBuilder` rebuilds — **AD-014/G-001 sidebar reuse is preserved,
  no extra decodes.**
- **No tier-1 key collision.** `tierOneProviderFor` also builds `ResizeImage(MemoryImage, w, h, fit)`;
  collision would need the same bytes object AND `width == height == cap`. Thumbnail and preview
  bytes are separate channel results in separate maps. Not reachable.
- **No eviction orphaned.** All `imageCache.evict` calls in `image_preload_controller.dart` key on
  `_tierOneKeys` / `_tierTwoKeys` / `_decodedProviders`; none keyed on the old
  `MemoryImage(thumbBytes)`.
- **No implicit behaviour lost** dropping the named constructor: `Image()` and `Image.memory()`
  constructor defaults are identical (`widgets/image.dart:365-383` vs `748-775`) — repeat,
  alignment, gaplessPlayback, isAntiAlias, `filterQuality.medium`, scale 1.0, loadingBuilder null.
- **No upscaling.** `ResizeImagePolicy.fit` with `allowUpscaling: false` (default) starts
  targetWidth at intrinsic and only shrinks (`image_provider.dart:1349-1420`); confirmed
  empirically (20×10 source → 20×10 at every dpr).
- **Only consumer** of `getThumbnailBytes` is `sidebar_view.dart:260`. No other caller affected.

## Notes for the incoming M2 lead

M2 = move source selection into `photo_source.dart` via the existing seam; controller untouched.
Acceptance per §6: full suite passes **unmodified** (19 raw assertions still green) and
`grep -c "\.dng\|isRaw" lib/services/image_preload_controller.dart` == **0**.

1. **Provision `local_data/` at worktree creation** (P1), real-dir-plus-inner-symlink shape, and
   verify `git check-ignore -v local_data` before anyone runs a suite. Otherwise you will spend
   your first cycle diagnosing ~40 phantom failures.
2. **Measure your own baseline in your own tree** and state which tree (P2). Do not inherit "189".
3. **M2 is behaviour-preserving, so the whole gate is "the unmodified suite still passes."** That
   makes it structurally different from M1: there is no new discriminating assertion to write, and
   the risk is the opposite one — a test that passes because the behaviour moved *and* its
   observer moved with it. Check that the raw assertions still observe from outside the seam.
4. **Do not let M1's F1 ride along silently.** If M2 touches `sidebar_view.dart` for any reason,
   F3 (`devicePixelRatioOf`) is a one-line fix that should go with it.
5. Red lines that held all round and should continue: `test/dng_preview_extractor_test.dart` is
   frozen; `readOrientation` (`int?`) vs `readDngOrientation` (`int`) asymmetry is deliberate,
   do not harmonise; no `git stash`/`reset`/`checkout --`/`clean` in a shared tree.
6. **Coordinate single-file reverts.** In this round the lead and the implementer independently
   ran revert-run-restore on the same file in overlapping windows. It could have committed base
   code under a fix message; it did not, but only by margin. If the lead needs a red capture,
   announce it or ask the owner to produce it.
