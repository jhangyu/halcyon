# Round 1 — M0 Handoff

> Written at round close, 2026-08-23. Commit `d4c97f5` on branch `m0-extractor`, based on `48bb934`.
> Contract: `docs/logs/2026-08-23/round-1-m0-contract.md` (frozen, amended twice by user decision).

## Outcome

**AC1–AC12 all PASS**, 20 conditions. Two independent reviews CONFIRMED. Three files changed:

| File | Change |
|---|---|
| `lib/services/dng_preview_extractor.dart` | rewritten: bounded byte-range reads, `longEdge` selection, `readOrientation` |
| `test/dng_preview_extractor_m0_test.dart` | new, 26 tests |
| `lib/services/native_thumbnail_service.dart` | one doc comment (twice corrected — see below) |

Full suite 162 → 188 (delta 26, exactly the new oracle). `flutter analyze` clean.

**The number that justifies the milestone:** reading the orientation of a 25,192,232-byte
preview-less DNG costs **8,192 bytes** — one page covering header + IFD0. The path it replaced
read all 25 MB for the same integer. 3,075× cheaper, and 36× under the 300,000-byte budget.

## Structural findings — five

None was found by a test failing. All five came from asking what a green result would look like
if the thing underneath were broken. A defective gate's whole signature is that it looks exactly
like a working one.

1. **A gate whose expected value equals the failure default is not a gate.** Demonstrated, not
   argued: under a stub returning `1`, AC11b and AC11c stayed green while AC11a (expecting 6)
   went red. Had AC11 asserted only against the no-preview file — whose true orientation is 1 —
   a permanently broken `readOrientation` would have passed with three green checks behind it.
2. **One discriminating assertion per capability; the rest are non-discriminating by
   construction.** AC2 for the selector, AC11a for orientation. AC3/AC4/AC5/AC6 and AC11b/AC11c
   pass a stub or a wrong selection for free. When writing a gate, name in advance which single
   assertion fails if the capability is absent. If you cannot name one, the gate is decorative.
3. **AC4's budget is self-scaling.** It is `selectedCandidateByteCount + 300_000` — derived from
   the very thing under test, so a mutation selecting a 2 MB candidate instead of a 9 KB one grew
   the budget with it and the assertion could not fire. Only the absolute clause
   (`IMG_20251112_092839.dng < 300_000`) does real work.
4. **AC9's "declared == executed" is blind to a test that ceased to exist.** It is a within-run
   invariant; a vanished test violates nothing inside the run that no longer contains it. Remedy:
   a full-suite count taken at the base commit, with the delta equal to the tests the round
   intended to add. For M0: 162 at `48bb934`, 188 after, delta 26. Take the baseline from outside
   the freeze — once a tree is frozen for a battery it can no longer produce one.
5. **Verify the sentences you act on — including motivating ones, and especially those you pass
   to someone else.** The claim "the always-`1` mutant passed every gate under the old `int`
   signature" was false. `ac11e-2-red.log` shows AC11a killing it with `Expected: <6> / Actual:
   <1>`. That log had been run, quoted in a report, and filed by the same people who later
   repeated the false claim — orchestrator, lead and implementer all missed it.

   > **"Evidence in hand is not the same as evidence brought to bear."** — `extractor-impl-1-opus`

   This is the failure mode that survives every process built this round, because it does not
   look like a missing check. It looks like a check that already passed.

## Corrected mutation analysis — carry this verbatim

The value split and the discriminating fixture kill **different classes of defect**. Neither is a
cheaper substitute for the other. Stated by `extractor-impl-1-opus`:

> **AC12d (the discriminating fixture) catches "gave up on hard input"; AC12a/AC12c/AC12h (the
> value split) catch "answered with a plausible default"; AC12b catches the mirror-image
> degenerate answer the split itself introduces. Drop any one of the three and a specific mutant
> class walks.**

Evidence, from `ac12g-i-2-red.log` and `ac12g-ii-2-red.log`:

| Mutant | Kills | Note |
|---|---|---|
| always `1` | AC11a, AC12a, AC12c, AC12d, AC12h | AC11a already caught it pre-AC12; AC12a/AC12c/AC12h are the split's **new** kill power |
| always `null` | AC11a, AC11b, AC12b, AC12d | **AC12b is load-bearing** — without it the split trades one degenerate answer for another |
| bail out over 10 MB, return `1` (reviewer2's) | AC12d only | passed all three AC11 gates; the fixture is the only thing that catches it |

## The doc comment that was wrong twice

`native_thumbnail_service.dart:55` sits on `NativeImageNeedsRawDecode` — the class that exists
*only* for "DNG with no embedded preview".

1. Originally named `readOrientationFromFile`, a method this round deleted. Caught by AC7's grep.
2. Rewritten to name `DngEmbeddedJpeg.orientation` — which in that class's one and only case is
   `null`, because `extractEmbeddedJpeg` returns null for a preview-less DNG. It passed its check
   and was still false. Caught by review 1, which is what produced AC11.
3. Now names `readOrientation` and states why `null` matters at that call site.

Both earlier versions passed their mechanical check. The bar is not "free of a banned token" —
it is "would actually stop someone making the mistake".

## Parked — F2–F6 (reviewer 1), untouched by user decision

- **F2** — I/O amplification to 199% of file size on a crafted 5,000-SubIFD container.
- **F3** — `_MemorySource.read` returns a `sublistView` where `48bb934` returned a `sublist`
  copy, pinning the whole source buffer. No live consumer in `lib/`.
  **Trigger condition, from `extractor-impl-1-opus`:** *"becomes live the moment an M1 caller
  caches a returned `Uint8List`, so it should be ruled on before M1 lands, not after."*
  A parked item with a named trigger and a deadline is a scheduled decision; without one it is a
  graveyard entry.
- **F4** — `byteCount <= 0` candidates now skipped rather than selected-then-aborted; differs
  from `48bb934` only on crafted input.
- **F5, F6** — see `docs/logs/2026-08-23/round-1-ac11-independent-review.md`.

## Dropped — NOT parked, not debt

**N2** (unclamped return vs the "range 1..8" prose) and **N3** (duplicate IFD0 walk) were
**dropped by user decision**. They are not carried forward and must not reappear as debt items.

## Untested paths and honest limits

- **Sized requests with no DefaultCropSize (0xC620).** The abort is now guarded by
  `longEdge == null`, so a sized request no longer fails when the tag is absent. Every sample
  carries the tag, so no assertion covers that branch — it rests on reasoning alone.
- **AC3, AC5, AC6, AC11b are proven to RUN, not proven to DISCRIMINATE.** Only AC2, AC11a and
  the AC12 set have mutations behind them.
- **`readDngOrientation` and `readOrientation` are deliberately inconsistent.** The former keeps
  `int` with `1` on failure because `test/dng_preview_extractor_test.dart:158-163` asserts it and
  AC1 forbids touching that file; the latter returns `int?`. `_orientationOf` returns `int?` and
  three call sites resolve it differently: `readOrientation` propagates, `readDngOrientation`
  folds `?? 1`, and `_walk` folds `?? 1` because `DngEmbeddedJpeg.orientation` is non-nullable in
  the frozen API. **Do not "harmonise" the two signatures** — it fails AC1.
- **`/Users/jhangyu/project/halcyon-m0-red`** is a registered git worktree with a broken gitdir
  link, from a recursive delete run by the squad lead without listing the target first. No commit,
  ref or reflog was affected. Left as-is by orchestrator decision; not repo corruption.

## Process notes that earned their keep

- **Bind every artefact to a hash.** Batteries began with a hash precondition and stopped on
  mismatch. An artefact that cannot tell you it was produced against a moved tree is worse than
  no artefact, because it reads like evidence.
- **Prove reverts by hash, not by assertion.** Every mutation captured `shasum` before and after;
  "I edited it back" is a claim, a matching hash is a fact. Stronger still: a file never opened
  during a step was never in a position to move, which endpoint equality alone does not show.
- **Re-run the whole battery, never patch one artefact.** A partially re-run battery is bound to
  two different trees and is worth less than no battery. Three full batteries were run.
- **Pre-register expected counts before the run.** 162, then 26/188/25 — locked in with named
  falsifiers, so no result could be rationalised after the fact.
- **When two reports disagree, first ask whether they describe different moments rather than
  different facts.** Five crossed-message incidents, all benign, all resolved by arithmetic or a
  hash rather than by adjudicating anyone's intent. A stale report and a wrong report look
  identical; the timestamp and the derivation tell them apart.
- **Read the artefact, not the message.** A test-runner reported `+20` where the log said `+19`.
  Nothing depended on it, but a tally drifting by one is indistinguishable from the signal used to
  detect a tree that moved mid-run.
