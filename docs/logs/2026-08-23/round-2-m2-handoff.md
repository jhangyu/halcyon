# Round 2 — M2 + F3 Handoff

> Written at round close, 2026-08-23. Commits `b1fd3d4` and `f81ad9a` on branch `m2-source`,
> base `fe098b7`. Worktree `/Users/jhangyu/project/halcyon-m2`.
> Design authority: `docs/logs/2026-08-23/image-pipeline-redesign-handover.md` §3.1 PhotoSource,
> §6 M2, frozen user decisions D1–D6.
> Prior rounds: `docs/logs/2026-08-23/round-1-m0-handoff.md`, `docs/logs/2026-08-23/round-1-m1-handoff.md`.

## Outcome

**AC-A1–A5 and AC-B1–B3 all PASS. Independent adversarial review: CONFIRMED, no behavioral
counterexample, one Medium test-quality finding (parked, not a fix-cycle trigger).**

| Commit | Change |
|---|---|
| `b1fd3d4` | `fix(services): restore copy semantics in DNG extractor in-memory source` — `dng_preview_extractor.dart` +4/−1, `dng_preview_extractor_f3_test.dart` new (65 lines, 1 test) |
| `f81ad9a` | `refactor(services): extract file-type source selection into PhotoSource` — `photo_source.dart` new (34), `image_preload_controller.dart` 20 changed, `photo_source_test.dart` new (137, 4 tests) |

Suite 189 → 194, delta exactly +5. `flutter analyze` clean. No existing test file touched.

### The changes

**M2** — the controller's only type-aware branch was the `.dng` embedded-JPEG last resort inside
`_requestPreviewBytes`'s `NativeImageFailure` case (was `image_preload_controller.dart:659`, with
a `.dng` mention in the comment at `:654`). It now delegates in one line to
`PhotoSource.fallbackAfterNativeFailure(path)`; the import swapped from `dng_preview_extractor.dart`
to `photo_source.dart`.

Behavior preservation is provable by reading, not only by test. Old:
`if (dng) { b = extract(); if (b != null) return b; } return null`. New:
`if (!dng) return null; return extract()`. Identical in all three cases — non-dng → null,
dng + hit → bytes, dng + miss → null.

The design doc prose says 「控制器不動」 while its own acceptance is
`grep -c "\.dng\|isRaw" image_preload_controller.dart == 0`, which *requires* touching the
controller. Resolved in favour of the mechanical AC; the prose means "no behavior change in the
controller". Recording this so M3 does not re-litigate it.

**F3** — `_MemorySource.read` (`dng_preview_extractor.dart:511`) returned
`Uint8List.sublistView(...)`, a **view** into the caller's buffer, where pre-M0 base `48bb934`
returned `sublist`, a **copy**. A view pins the whole source DNG buffer alive and aliases it.
Restored to `_data.sublist(offset, offset + count)`.

**M2 bought nothing visible today, and neither did F3.** M2 relocates one branch so M3 can vary
source strategy without touching the controller. F3 is prospective hardening — see the verbatim
reviewer note below.

## Evidence

Artifacts in `tmp/verify/` (gitignored; paths recorded because the round record must name where
the evidence lived, not because it survives).

| AC | Verdict | Evidence |
|---|---|---|
| A1 full suite unchanged | PASS | `git diff fe098b7 -- test/ --name-only` → only the 2 new files |
| A2 grep == 0 | PASS | verified by squad lead directly; reviewer swept a wider pattern (below) |
| A3 analyze clean | PASS | `20260823T064232Z-battery-analyze.txt` — "No issues found!" |
| A4 suite green, 189 + N | PASS | `20260823T064506Z-battery-full-rerun.txt` — "+194: All tests passed!"; N = 5 isolated in `20260823T064239Z-battery-newfiles.txt` |
| A5 observe outside the seam | PASS | `photo_source_test.dart` never imports `photo_source.dart`; drives `ImagePreloadController` with a fake loader returning `NativeImageFailure`, asserts on `imageBytesFor` / `hasFailed` |
| B1 discriminating RED first | PASS | `f3-red.log` — genuine content assertion failure at base, not a compile error; `f3-green.log` after fix |
| B2 oracles untouched | PASS | diff vs `fe098b7` for `dng_preview_extractor_test.dart` and `..._m0_test.dart` is 0 lines |
| B3 suite green + analyze | PASS | same 194 run |

Worktree baseline: `worktree-baseline-fe098b7-189.log`, "+189: All tests passed!" (provenance
caveat under Process deviations).

### Reviewer's strongest evidence — full report `tmp/verify/review2-findings.txt`

The reviewer built its own detached worktrees rather than trusting this squad's tree.

1. **Behavior preservation, demonstrated not asserted.** `photo_source_test.dart` copied into a
   detached worktree at base `fe098b7` → **all 4 GREEN**. The same observable behavior exists
   pre- and post-M2, seen from outside the seam. This is the finding that makes the extraction
   trustworthy: the tests are not passing because behavior moved and its observer moved with it.
2. **F3 test is a genuine killer.** `dng_preview_extractor_f3_test.dart` at base → **RED**, view
   semantics directly observed ("at location [0] is <170> instead of <255>").
3. **MUTANT-1 killed.** `fallbackAfterNativeFailure` mutated to return null unconditionally →
   **RED** on the named assertion at `photo_source_test.dart:74`. Delegation is genuinely observed,
   not assumed.
4. **Wider grep sweep** on the controller for
   `.dng|isRaw|.jpg|.jpeg|.arw|.cr2|.nef|.orf|.rw2|extension|isJpeg|toLowerCase` → **0 hits**.
   Nothing type-aware was left behind under a different spelling.
5. **Copy-semantics coverage sweep** of `dng_preview_extractor.dart`: the only byte-source escapes
   are `_MemorySource.read` (now a copy) and `_FileSource.read` (`count < 64KB` copies into a fresh
   `out`; `count >= 64KB` goes to `_readDirect` → fresh `readSync` buffer; the LRU page-cache buffer
   never escapes `read()`). `_injectExifOrientation` returns either `BytesBuilder` output or the
   already-copied `jpeg`. **No sibling path still hands out a view** — F3 was not a whack-a-mole fix.

## Reviewer notes worth recording verbatim

> `extractFullSizeEmbeddedJpeg` (in-memory API) currently has **NO production caller in `lib/`** —
> the F3 fix is prospective hardening for M3, not a live-path bug fix today.

Corollary the reviewer drew out: copy semantics costs **one extra full-size JPEG allocation per
in-memory extraction**. That is intended and irrelevant until M3, but M3 is exactly where the call
volume appears — if M3 caches these, the copy is what makes caching safe, and the allocation is
the price of not pinning a ~25 MB DNG buffer per cached preview.

## Known limitations — parking lot

Nothing below blocked the merge. Trigger conditions say when each stops being deferrable.

| # | Finding | Trigger |
|---|---|---|
| **M1** *(Medium)* | **Vacuous "extension gate holds through the seam" test** (`photo_source_test.dart:109-136`). MUTANT-2 — deleting the gate `if (!path...endsWith('.dng')) return null;` — **survives, all 4 GREEN**. The test uses `/tmp/not-real.jpg`, a path that does not exist, so the extractor returns null with or without the gate. The test's name claims a guarantee it does not provide. Fix shape: a **real** file with a `.jpg` extension containing DNG bytes, assert `imageBytesFor` stays null. | **Before M3 turns the gate into content sniffing** — at that point the gate's behavior actually changes and an undiscriminating test will bless the change silently |
| **M2** | **TC-049 flake**, root cause now confirmed **twice independently**. `app_state_test.dart:378` keys the fake exif reader on `path.contains('A')` over the **full** path; the folder is `Directory.systemTemp.createTemp('halcyon_rename_state_')` (`:360`) whose random 6-char suffix contains an uppercase `A` in ~8.7% of runs (reviewer probed 300 runs → 26 hits; squad lead measured 1 failure in 8 valid isolated iterations). When it hits, `B.JPG` inherits `A`'s capture date, all three fixtures collapse to one timestamp, and the rename collides into the `-1` suffix. Pre-existing, independent of both commits. Fix: `p.basename`-based matching at `app_state_test.dart:378`. | **Next round that may edit existing tests** — needs user approval, since it touches an existing test file |
| M3 | `photo_source.dart` is currently one static method. The design doc's full `(path, longEdge) -> SourcePayload?` content-sniffing selector is M3 work. | M3 |
| M4 | One of the 4 new `photo_source_test.dart` tests is a fixture-presence assertion, not a behavior assertion. Harmless, but it inflates the apparent test count; the byte-identical recovery assertion is the real killer. | Whenever the count is cited as coverage |

### Process deviations — disclosed, not buried

**P4 — Crossed dispatch bypassed two gates.** Both implementers acted on an earlier, less detailed
dispatch before the squad lead's full briefs landed. Consequences: the `GO-FLUTTER` gate (a
`pub get` serialization device) was moot, and **N was not pre-registered** — the counts arrived
with the reports. Accepted only because the committed diff independently shows exactly 4 `test(`
calls in `photo_source_test.dart` and 1 in the F3 test, which is the check pre-registration was
standing in for. A re-enacted RED capture for F3 was **declined**: re-running a red assertion
against an already-fixed tree is theatre, not evidence. The genuine capture happened once, against
a genuinely unmodified tree, and that condition cannot be recreated.

**P5 — The ordered baseline was never delivered by the test-runner.** The runner went idle without
producing T0. The in-worktree 189 exists only because `m2-impl-1-sonnet` independently measured it
at session start on a clean `fe098b7` tree, and it lived in a session-scoped temp path that can
vanish; it was copied into `tmp/verify/worktree-baseline-fe098b7-189.log`. **Provenance is that
member's observed `git status` at that moment, not something the squad lead witnessed.** Cite it
accordingly. This is the second round in a row where the baseline's provenance needed a footnote
(see M1's P2).

**P6 — A post-hoc renamed duplicate of the F3 red log was created and deleted.** Same bytes under a
timestamped name implies a run that never happened. `f3-red.log` is the sole citable artifact.
This is M1's F5 recurring: byte-identical logs are not two-party corroboration.

## Notes for the incoming M3 lead

- **F3 is done, which unblocks M3.** Caching the in-memory extractor's output is now safe — that
  was the whole point. The extra allocation per extraction is the intended cost.
- **The M1 F1 dpr-assertion parking item has trigger "before M3 builds on the cap"** — that trigger
  fires now. M1's decode cap has no discriminating assertion on the `dpr` term; a refactor dropping
  the factor ships half-resolution thumbnails silently.
- **Parking item M1 above (vacuous extension-gate test) also fires now**, for the same structural
  reason: M3 changes what the gate does.
- **M1's P3 still stands**: a real 100 ms `Timer` at `image_preload_controller.dart:791` defeats
  `FakeAsync`. Any M3 widget test touching the preload path needs `tester.runAsync()` plus a real
  wall-clock delay.
- **D2 remains frozen**: no change to tier-2 timing/debounce/window behavior. Neither round-2 diff
  touches a timing line. Any slowdown of instant back/forward navigation is an automatic veto.
