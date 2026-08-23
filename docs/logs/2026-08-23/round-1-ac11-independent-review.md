# Independent adversarial review — AC11 delta only (m0-extractor)

Reviewer: second independent reviewer. All evidence below produced by me in this session.
Probes: /Users/jhangyu/project/halcyon-m0-reviewtmp/ac11/{p1,p2,p3,p4,runac}.dart, mut/{m1..m4}.dart, p2.out
Nothing in halcyon-m0, halcyon-m0-red or Halcyon was modified. No write-side git command was run.

NOTE ON SCRATCH LOCATION: the brief said "/tmp/ ONLY", but a global hook
(`~/.claude/hooks/global-tmp-guard`) blocks all writes under /tmp. I used
`halcyon-m0-reviewtmp/ac11/` instead — a fourth tree, none of the three red-lined ones.

## VERDICT: CONFIRMED

AC11a–AC11e all hold under evidence I produced. I tried to refute the delta on five fronts
(correctness divergence, hostile input, fd/permission handling, gate vacuity, doc honesty) and
could not. 4 NITs, 0 BLOCKERs, 0 SHOULD-FIXes.

## Preconditions

Frozen hashes verified before starting — all three match the brief exactly:
```
627fc503...f126  lib/services/dng_preview_extractor.dart
4e066a40...8b1e  lib/services/native_thumbnail_service.dart
0217cc6d...b2e3  test/dng_preview_extractor_m0_test.dart
```
`git log --oneline -1` -> 48bb934. Working tree modifications limited to the two lib files
plus the untracked oracle test.

## What I ran

1. `shasum -a 256` on the three frozen files -> match.
2. `flutter analyze` in halcyon-m0 -> "No issues found! (ran in 0.7s)", exit 0.
3. `flutter test -j 1 test/dng_preview_extractor_m0_test.dart test/dng_preview_extractor_test.dart
   test/dng_extractor_swift_test.dart` -> "+47: All tests passed!", exit 0.
4. `flutter test -j 1` (full suite) -> "+184: All tests passed!", exit 0.
   (Previous reviewer measured +181; +3 AC11 tests = 184. Consistent.)
5. `grep -c "DngEmbeddedJpeg.orientation" lib/services/native_thumbnail_service.dart` -> 0 (AC11d).
6. probe p1 — differential, all 14 samples: new `readOrientation(path)` vs 48bb934
   `readOrientationFromFile(path)` (pristine halcyon-m0-red).
7. probe p2 — 655 hostile inputs (see below).
8. probe p3 — no-preview correctness + duplicate-walk cost.
9. probe p4 — permission-denied file, fd-leak sweep (10,000 calls).
10. runac.dart — my own re-derivation of AC11a/b/c run against the real impl and 4 mutants.

## Aim point 1 — does readOrientation discharge the obligation? YES, and it is 3000x cheaper

probe p1, the load-bearing sample:
```
IMG_20251112_092839.dng  old=1 new=1 OK  size=25192232  newRead=8192 (0.033%)  newUs=240  oldUs=8616
```
One 8 KiB page against a 25,192,232-byte file. 48bb934 read all 25,192,232 bytes and allocated
them. Warm-cache wall time 240 us vs 8,616 us (36x). This is not theatre.

Every one of the 14 samples costs exactly 8192 bytes — a single page — regardless of file size
(0.033% .. 0.243%). The walk touches the TIFF header and IFD0 only, both of which live in page 0
of every real sample.

**The decisive test the AC suite does not contain.** AC11b's sample has orientation 1, which is
also the failure default, so it cannot distinguish "read correctly" from "gave up". I built the
missing fixture (p3): I patched IFD0 tag 0x0112 of the real 25 MB no-preview DNG to 6 and re-ran:
```
CRAFTED no-preview + orientation=6 -> new.readOrientation=6 (read=8192 B)  old=6
                                      extractEmbeddedJpeg=null (no preview, as expected)
```
This is the exact scenario `NativeImageNeedsRawDecode` exists for: `extractEmbeddedJpeg` returns
null (so `DngEmbeddedJpeg.orientation` genuinely does not exist), and `readOrientation` still
returns the true orientation for 8 KiB. The obligation F1 raised is discharged.

## Aim point 2 — correctness across all 14 samples: 14/14 agree, and I could not construct a divergence

probe p1: MISMATCHES=0 across all 14, including the discriminating `2026-08-07-17-52-54.dng`
(old=6 new=6).

I did not rely on that 13-of-14 default agreement. Reading the code, `readOrientation`,
`readDngOrientation` and `_walk` all call the *same three* helpers — `_readerFor` (:153),
`_readIFD0` (:162), `_orientationOf` (:170) — and `_orientationOf` is a byte-for-byte
transliteration of 48bb934's inline block (halcyon-m0-red/...:67-71). The only thing that differs
between the old and new orientation path is the byte source (`_FileSource` paged reads vs a
whole-file `Uint8List`). So a divergence can only come from the paged reader, and I attacked that
directly:
- 600 random 3-byte-flip mutants of a real DNG concentrated in the first 70 KB: 0 divergences.
- 29 truncations at every page/IFD boundary (1,2,...,8,4095,4096,4097,8191,8192,8193,16384,...):
  0 divergences.
- crafted case `orient-out-of-line-page-straddle`: an out-of-line SHORT[4] Orientation array whose
  value offset is 8191, i.e. deliberately straddling the reader's 8192-byte page boundary.
  Result: 7 (correct), no divergence. This is the single most likely paged-reader bug and it is
  absent.
- big-endian (`MM`) container with orientation 8 -> 8, matching old.

**I cannot construct a case where they disagree.** 655/655 agree.

## Aim point 3 — hostile input: 655 cases, 0 throws, 0 divergences

`cases=655 mutants=600 throwsNew=0 divergences=0` (full log: ac11/p2.out).

Coverage: nonexistent path, a directory, the empty string, a symlink to nowhere, a zero-byte file,
7 bytes, exactly 8 bytes, bad magic, a plain JPEG, a text file, `/dev/null`, an 8 MB random file,
an 8 MB random file with a forged TIFF header, 29 truncations of a real DNG, 600 3-byte-flip
mutants, and 13 crafted containers (count=0, count=0xFFFFFFFF, count=99999 with offset past EOF,
type=0, type=99, IFD0 offset 0xFFFFFFFF, self-referential IFD0 offset, 65535-entry claim,
big-endian, page-straddling out-of-line value).

Plus probe p4:
- permission-denied file (chmod 000) -> returns 1, no throw.
- fd leak: `fds before=21 afterGood=21 afterBad=21 (delta=0)` after 5,000 successful and 5,000
  failing calls. The `finally { await raf?.close(); }` at :115-121 holds on every exit path,
  including the early `return 1` at :106/:108/:110.

The "returns 1 and never throws" invariant holds.

## Aim point 4 — AC11d honesty: the comment is now TRUE

Current text, `lib/services/native_thumbnail_service.dart:52-59`:
> [exifOrientation] ... may be read natively (macOS, via the [kNoEmbeddedPreviewCode] channel
> error) or in Dart (via `DngPreviewExtractor.readOrientation`, a bounded byte-range IFD0 walk
> that works on exactly this case -- a DNG with no embedded preview -- on platforms whose native
> bridge does not emit that code).

Judged on substance, not grep. Every factual claim checks out:
- `DngPreviewExtractor.readOrientation` exists (`dng_preview_extractor.dart:99`).
- "bounded byte-range IFD0 walk" — true: 8192 bytes measured, and it calls `_readIFD0` only,
  never `_walk`, so it never reaches strip reads.
- "works on exactly this case -- a DNG with no embedded preview" — this is the claim the last
  version got wrong, and it is the one I attacked hardest. It is now true, demonstrated on a real
  25 MB no-preview DNG returning a correct non-default orientation 6 (p3, above).
The comment no longer names anything that cannot work. AC11d passes on merit.

## Aim point 5 — yes, the walk is duplicated (not an AC violation)

`readOrientation` opens its own `RandomAccessFile` and runs its own `_readerFor` + `_readIFD0`;
it does not share state with `extractEmbeddedJpeg`. A caller needing both pays twice:
```
readOrientation=8192 B, extractEmbeddedJpeg(longEdge:200)=2055126 B; combined=2063318 B
```
The overhead is 8,192 bytes and one extra `open`/`close` — 0.4% on that sample. Note that the
duplication is harmless in the case AC11 exists for: when there is no preview, the caller only
ever calls `readOrientation`, never both. When there *is* a preview, `DngEmbeddedJpeg.orientation`
already carries it, so a correct caller does not call both. Recording it for the record only.

## Aim point 6 — the mutation is honest, and all three gates are load-bearing

The squad's `ac11e-*.log` claims stubbing `readOrientation` to return 1 turns AC11a red and
nothing else. I reproduced it independently on copies (never touching the deliverable) and
extended it to four mutants:

```
IMPL                               AC11a                  AC11b                      AC11c
REAL (deliverable)                 GREEN                  GREEN (read=8192)          GREEN
MUT1 stub->1                       RED (got 1, want 6)    GREEN (read=0)             GREEN
MUT2 no catch-all (rethrow)        GREEN                  GREEN (read=8192)          RED (PathNotFoundException)
MUT3 slurp whole file              GREEN                  RED (o=1 read=25192232)    GREEN
MUT4 swallow tag value             RED (got 1, want 6)    GREEN (read=8192)          GREEN
```

MUT1 exactly reproduces the squad's claim — AC11a red, AC11b and AC11c green. Their log
(`ac11e-2-red.log`: `+19 -1` at AC11a, `+21 -1` overall) says the same. Honest.

**No gate is decorative.** AC11b is killed by MUT3 (the regression it exists to prevent —
reverting to `readAsBytes`). AC11c is killed by MUT2 (removing the catch-all). Each of the three
gates kills at least one mutant that the others miss.

AC11e hashes: `ac11e-hash-before.txt` == `ac11e-hash-after.txt` == the frozen hashes. Verified.

## Negative-space answer (mandatory)

**Does the delta discharge the obligation it was created to discharge? Yes.** F1's obligation was
"a cheap orientation read for a DNG with no embedded preview". Measured: correct value in 8192
bytes on a 25,192,232-byte no-preview DNG, versus 25,192,232 bytes at 48bb934. Strictly cheaper
than the function it replaces, as the contract demanded.

**What the delta does NOT handle:**
1. It restores a *capability*, it does not *wire* it. `grep -rn readOrientation lib/` finds
   exactly one hit outside the extractor: the doc comment. The Windows P0 fix
   (`windows-port-session-handover.md:98`) is still open, and `image_preload_controller.dart:649`
   still receives `exifOrientation` only from the native channel path. That is in line with the
   contract's scope, but nobody should read AC11 green as "Windows EXIF is fixed".
2. It does not clamp the tag value to 1..8 (N2 below).
3. It does not reuse `extractEmbeddedJpeg`'s walk (aim point 5).
4. The oracle contains no fixture proving correctness on a no-preview DNG (N1 below) — I supplied
   that proof by hand this session; the repo cannot re-derive it.

**What existing behaviour does the delta remove or weaken? Nothing.** The AC11 delta is purely
additive: one new static method plus a doc-comment rewrite. It does not modify `_readerFor`,
`_readIFD0`, `_orientationOf`, `_walk`, `readDngOrientation` or any extraction entry point, so
the AC1–AC10 evidence base is untouched. `git diff` on `native_thumbnail_service.dart` is 6 lines,
comment-only. The full suite is +184 green with zero regressions against the previous +181.

## Findings

### N1 — NIT: no gate proves correctness on the case AC11 exists for
`test/dng_preview_extractor_m0_test.dart:232-257`. AC11b's expected orientation is 1, which is
also the value returned on every parse failure, so the assertion is satisfied by any
implementation that gives up. Only the byte-budget half of AC11b is discriminating (it kills MUT3),
and only AC11a proves the value is really read — but AC11a's sample *has* embedded previews, so
the two properties "correct value" and "no preview" are never asserted together.
Repro of the gap: MUT4 (swallow the tag value) is caught, but an implementation that bailed out
early on files > 10 MB would pass AC11a, AC11b and AC11c while being useless for the P0 fix.
Cheap fix: commit the crafted fixture I built in p3 (real no-preview DNG with tag 0x0112 patched
to 6) and assert `readOrientation == 6` on it. That single assertion closes the gap.
I verified by hand this session that the real implementation passes it (returns 6).

### N2 — NIT: `readOrientation` returns the raw tag value unclamped; the comment it was added to says "range 1..8"
`dng_preview_extractor.dart:170-176` returns `vals.first` with no range check. p2 case
`orient-value-huge` -> **65535**. Meanwhile the doc paragraph AC11d rewrote asserts
"[exifOrientation] is the IFD0 Orientation tag value, in the range 1..8"
(`native_thumbnail_service.dart:52`), and the *other* route named in that same sentence does clamp
(`native_thumbnail_service.dart:169-172`, `_parseOrientation` returns `kDefaultExifOrientation`
unless `1 <= details <= 8`). So the sentence names two routes with different guarantees.
Not a regression — 48bb934's `readOrientationFromFile` is identically unclamped (my differential
shows 0 divergences on this case) — and latent, since nothing wires it yet. Downstream is safe:
`applyExifOrientation` (`decoded_rgba_image_provider.dart:43-47`) explicitly degrades unknown
values to identity rather than refusing to show the photo. Flagging because whoever wires the
Windows fix will need `_parseOrientation`-equivalent clamping at the call site, or the invariant
in that comment becomes false in practice.

### N3 — NIT: duplicate IFD0 walk
See aim point 5. A caller needing both orientation and a preview pays two `open`s and two IFD0
reads (+8,192 B, 0.4%). No correct caller needs both, so this is informational.

### N4 — NIT (cosmetic): ragged line wrap left by the rewrite
`native_thumbnail_service.dart:57-58` — the rewrite left `/// preview -- on platforms whose native
bridge does not emit that code). The` / `/// decoder does not apply` / `/// EXIF orientation, so
Halcyon must.` with a short orphan line mid-paragraph. `dart format` will not fix comment prose.
Zero functional impact.

## What I could NOT check

- **Cold-cache behaviour.** All timings are warm-page-cache; I cannot purge the page cache without
  sudo. The 36x wall-time win would very likely be *larger* cold (8 KiB vs 25 MB of real I/O), so
  this caveat does not threaten the verdict — but I did not measure it. Same limitation the first
  reviewer reported as F6.
- **Whether `readOrientation` is correct on a DNG whose IFD0 is not in page 0.** Every one of the
  14 samples puts IFD0 within the first 8192 bytes, so the "one page" result is partly a property
  of the corpus, not solely of the implementation. A DNG with IFD0 at, say, offset 20 MB would
  cost 2 pages, not 1 — still bounded and still trivially cheap, but I have no real sample to
  confirm the AC11b budget holds with margin on such a file. The 300,000-byte budget leaves
  ~36 pages of headroom, so I judge this low risk.
- **Any end-to-end Windows behaviour** — no Windows host, and nothing is wired yet.
- I did not re-review AC1–AC10; per the brief, that budget is spent.
