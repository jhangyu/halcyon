# Independent adversarial review — M0 (`m0-extractor`, worktree /Users/jhangyu/project/halcyon-m0)

Reviewer: reviewer agent. All evidence below was produced by me in this session.
Scratch/probes: /Users/jhangyu/project/halcyon-m0-reviewtmp/bin/probe{1..6}.dart, sweep.txt, fuzz/.
Nothing in halcyon-m0, halcyon-m0-red or Halcyon was modified. No write-side git command was run.

## VERDICT: CONFIRMED (against AC1–AC10 as written), with 1 false-premise escalation and 5 findings.

AC1–AC10 hold under evidence I produced. The broader prose claim in the contract's terminal
state — "today's full-size behaviour byte-identical" — has exactly one reproducible
counterexample (F4), on crafted input only; every one of the 14 real samples is byte-identical.

## What I ran

1. `flutter analyze` in halcyon-m0 -> "No issues found! (ran in 0.6s)".
2. `flutter test -j 1 test/dng_preview_extractor_test.dart test/dng_extractor_swift_test.dart
   test/dng_preview_extractor_m0_test.dart` -> "00:04 +44: All tests passed!"
   (25 frozen + 19 new; AC1's 25 intact).
3. `flutter test -j 1` (full suite) -> "+181: All tests passed!", EXIT=0. (AC9)
4. `git diff 48bb934 -- test/dng_preview_extractor_test.dart | wc -l` -> 0. (AC1)
5. `grep -n readAsBytes lib/services/dng_preview_extractor.dart` -> no output. (AC7)
6. probe1 — old (halcyon-m0-red, pristine 48bb934) vs new, ALL 14 samples:
   - file path: `old.extractFullSizeEmbeddedJpegFromFile` vs `new.extractFullSizeEmbeddedJpegFromFile`
     -> 14/14 identical length+hash, mismatches=0 (13 previews + 1 null).
     This is a stronger check than AC3's 13 and it exercises the real longEdge==null path.
   - in-memory `extractFullSizeEmbeddedJpeg(data)` -> 14/14 identical content.
   - orientation: `old.readDngOrientation` / `old.readOrientationFromFile` vs
     `new.extractEmbeddedJpeg(..).orientation` -> agree on 13/14; the 14th is F1 below.
7. probe2 — selector sweep, all 14 samples x longEdge in
   {-1,0,1,100,170,171,172,255,256,257,683,684,1024,1025,2048,2800,4000,4001,5999,6000,6001,100000}.
   Full output: /Users/jhangyu/project/halcyon-m0-reviewtmp/sweep.txt
8. probe3 — 16 malformed/crafted containers (empty, 7 bytes, header-only, bad magic, MM,
   IFD0 offset 0xFFFFFFFF, IFD0 offset 6, 65535-entry claim, count 0xFFFFFFFF, count 99999,
   self-referential SubIFD, strip offset past EOF, SubIFD offset into the middle of a JPEG
   strip, strip ending exactly at EOF, no DefaultCropSize).
9. probe4 — crafted divergence + read-amplification + EOF/page-boundary cases.
10. probe5 — event-loop stall comparison old vs new.
11. probe6 — differential fuzz: 19 truncations + 400 random 3-byte-flip mutants of a real DNG,
    old vs new across file path / in-memory / orientation.
    Result: `cases=419 divergences=0 throwsNew=0 throwsOld=0`.

## Selector boundary behaviour (aim point 2) — CORRECT

Sample 2026-02-15-19-37-38.dng carries candidates 256x171, 1024x683, 6000x4000:
  longEdge<=256 -> 256x171 (9525 B);  257..1024 -> 1024x683 (40411 B);
  1025..6000 -> 6000x4000 (983589 B);  6001 and 100000 -> 6000x4000 (largest fallback).
Exactly "smallest candidate with max(w,h) >= longEdge, else largest". This is the
discrimination AC3 could not provide (no sample has a candidate between 2800 and full size);
longEdge=257 -> 1024x683 rules out "largest wins" independently of the squad's mutation run.
Same pattern on all 12 three-candidate samples; 2026-08-07-17-52-54.dng has one candidate and
returns 6000x4000 at every longEdge; IMG_20251112_092839.dng returns null at every longEdge.
Edge values 0 and -1 take the sized path (smallest candidate) — consistent with the contract
("longEdge != null"), but note `longEdge: 0` is silently "give me the tiniest", not "full size".

## onDiskRead honesty (aim point 5) — HONEST

The only physical reads in the diff are in `_FileSource._readDirect`
(`dng_preview_extractor.dart:525-535`); it reports `bytes.length` on every call, including
short reads, before the length check. Page-cache hits are not reported because no read occurs.
Two independent confirmations that it cannot under-report:
 - probe4 CASE C: 40,110-byte file, reported total = 40,110 exactly (4x8192 + 7342).
 - probe4 CASE B: reported 41,771,008 on a 20 MB file, i.e. it *does* count re-reads of
   evicted pages (199.2%), so cached-page under-counting is ruled out.
AC4 is therefore not vacuous.

## Negative-space answer: what this diff removes or stops handling

1. **`readOrientationFromFile(String path)` is gone, and nothing replaces it for the
   no-preview case.** See F1 — highest-value finding.
2. **`extractFullSizeEmbeddedJpeg(Uint8List)` now returns a VIEW, not a copy.** See F3.
3. **Candidates with `StripByteCounts == 0` are now skipped instead of selected-then-rejected**,
   which changes the longEdge==null result. See F4.
4. **The `DefaultCropSize` (0xC620) abort no longer applies to sized requests**, so a DNG with
   no DefaultCropSize now yields a preview at `longEdge != null` where the old code (and the
   still-live full-size path) yields null. Untested. See F5.
5. **All byte reads are now synchronous (`setPositionSync`/`readSync`) on the calling isolate**,
   where the old code used one `await File.readAsBytes()`. See F6.
6. No IFD-chain following was added, so no loop vector was introduced: `_readIFD0` discards the
   next-IFD pointer and SubIFDs are read one level deep, non-recursively. A SubIFD pointing back
   at IFD0 terminates (probe3 case "SubIFD -> IFD0 (loop)" -> null, no hang).
7. No integer-overflow vector: TIFF offsets/counts are u32 and Dart ints are 64-bit, so
   `offset + byteCount` cannot wrap; every candidate is checked against `source.length`
   (`:246-251`) and every `_ByteSource.read` re-checks (`:462`, `:486`).
8. The "never throws" contract holds: 419 fuzz cases + 16 crafted containers produced zero
   throws from any new entry point (`extractEmbeddedJpeg`, `extractFullSizeEmbeddedJpegFromFile`,
   `extractFullSizeEmbeddedJpeg`, `readDngOrientation`).

## Findings

### F1 — SHOULD-FIX / ESCALATE (false premise in the frozen contract)
`round-1-m0-contract.md:78-80` justifies deleting `readOrientationFromFile` with "its job is now
covered by `DngEmbeddedJpeg.orientation` from the single walk". **That is false precisely where
the function was going to be used.** When there is no embedded JPEG, `extractEmbeddedJpeg`
returns `null`, so there is no `DngEmbeddedJpeg` and therefore no orientation.
Reproduction (probe1, last line):
  `IMG_20251112_092839.dng   oldMem=1  oldFile=1  new=null`
Who depended on it: the documented, still-open **P0** Windows fix —
`docs/logs/2026-08-22/windows-port-session-handover.md:98` and
`docs/logs/2026-08-22/thumbnail-dart-first-plan.md:81` both specify
`_needsRawDecode[id] = await DngPreviewExtractor.readOrientationFromFile(path)` for exactly the
`.dng`-with-no-embedded-preview case, i.e. exactly the case that now has no API.
The only surviving route is `readDngOrientation(Uint8List)`, which requires slurping the whole
file — reintroducing `readAsBytes()` on a 25 MB DNG, the thing M0 exists to remove.
Not an AC violation (the contract ordered the deletion), but the stated reason is wrong, so
this is a user-visible decision, not a squad decision.

### F2 — SHOULD-FIX (read amplification: "bounded reads" is not bounded on adversarial input)
`_FileSource` (`dng_preview_extractor.dart:470-536`) has a 48-page x 8 KiB LRU. A DNG whose
IFD0 SubIFD array (tag 0x014A) lists many scattered offsets makes the walk re-read evicted
pages without limit. probe4 CASE B: a crafted 20,971,520-byte file with 5,000 SubIFD pointers,
`longEdge: 200`, **result null, `onDiskRead` total = 41,771,008 bytes = 199.2% of the file**,
25 ms. Expected per the milestone's terminal state: bounded reads well under file size.
Memory is fine (the LRU caps residency at ~384 KB); this is I/O amplification, not a leak, and
no real DNG has 5,000 SubIFDs — hence SHOULD-FIX, not BLOCKER. The cheap guard is a cumulative
`onDiskRead` budget or a cap on `0x014A` count (it is currently only bounded by the generic
`entry.count >= 100000` check at `:622`).
Repro: `dart run bin/probe4.dart` in /Users/jhangyu/project/halcyon-m0-reviewtmp.

### F3 — SHOULD-FIX (aliasing + retention: copy became view)
`_MemorySource.read` (`:461-464`) returns `Uint8List.sublistView(_data, ...)`; the old code used
`data.sublist(...)` (`halcyon-m0-red/.../dng_preview_extractor.dart:206`), which copies.
Evidence (probe1, in-memory section), e.g. 2026-02-15-19-37-38.dng:
  old -> `offsetInBytes=0, buffer.lengthInBytes=983589`
  new -> `offsetInBytes=208788, buffer.lengthInBytes=4058644`
Consequences: (a) the returned preview keeps the entire 4–25 MB source buffer alive;
(b) mutating the source buffer silently mutates the returned "extracted" bytes;
(c) any consumer doing `bytes.buffer.asUint8List()` / `bytes.buffer.asByteData()` now gets the
whole DNG instead of the JPEG. I grepped `lib/` for `.buffer.` and found no such consumer today,
and the file-path path is unaffected (fresh buffers), so this is latent, not live.
Note it only bites the `longEdge == null` in-memory API, which the frozen legacy tests use.

### F4 — NIT (the one counterexample to "full-size behaviour byte-identical")
New line `:247` adds `byteCount <= 0` to the candidate rejection test. Old code let a
zero-length strip win on area and then bailed out of the whole extraction
(`halcyon-m0-red/...:203-205`, `sliceStart >= sliceEnd -> null`).
probe4 CASE A2, crafted 92,188-byte DNG: IFD0 candidate 4000x3000 with StripByteCounts=0,
SubIFD candidate 3800x2900 with a valid 2,000-byte strip, DefaultCropSize 4000x3000.
  expected (48bb934 behaviour): null      actual (M0): a 2,000-byte JPEG (3800x2900)
Both the file path and the in-memory path diverge. Arguably a bug fix, but it is an
undocumented, untested change to the frozen path — it should be either reverted or written down.

### F5 — NIT (untested new path)
`:200` — `if (longEdge == null && cropMax <= 0) return null;` means a sized request on a DNG
with no DefaultCropSize now returns a candidate where the old code always returned null.
probe3 case "no DefaultCropSize, sized request": `longEdge:null -> null`, `longEdge:200 ->
400x300`. I judged this **correct, not nonsense**: candidates are still gated on
Compression==7 AND PhotometricInterpretation==6 (`:205-217`), so a CFA/RAW mosaic IFD can never
be selected; the worst case is a legitimately small JPEG rendition. No fixture covers it —
every sample carries 0xC620 — so it is behaviour with zero assertions behind it.

### F6 — NIT (unproven; flagged for honesty, not as a defect I can demonstrate)
Every byte read in the new file path is `setPositionSync` + `readSync` (`:527-528`) inside an
`async` method that never awaits during the walk; the sole production caller
(`image_preload_controller.dart:661`) runs on the root isolate with no `compute()`
(I grepped: no `Isolate`/`compute(` in that file). The old path used one `await
File.readAsBytes()`, which yields.
I tried to measure it (probe5, worst event-loop stall): warm page cache gives
NEW 3.84/1.31/0.03 ms vs OLD 2.44/2.18/2.02 ms on a 9.1 MB sample, and NEW 0.10 ms vs
OLD 3.60 ms on the 25 MB no-preview file — i.e. **new is not worse warm, and I could not
produce a cold-cache or slow-volume (SMB/USB) measurement** without root. The risk is real for
this app's use case (photo folders on external media) but I did not demonstrate it. Reporting
as a caveat only.

## What I could NOT check

- Cold-cache / removable-media I/O behaviour (F6) — no way to purge the page cache without sudo.
- The Swift extractor (`macos/Runner/DngPreviewExtractor.swift`) was out of scope and unchanged;
  I did not verify that the Dart selector still mirrors it for `longEdge != null` (Swift has no
  such mode, so there is nothing to mirror).
- I did not test a DNG whose embedded JPEG already carries its own EXIF Orientation
  (`_jpegHasExifOrientation`); that code is unchanged from 48bb934 and my old-vs-new comparison
  covers it indirectly on all 14 samples.
- AC10's red run: I confirmed the artefacts exist (`scripts/tmp/verify/ac10-red-pre-w1.log`,
  `m0-ac10-red-precompile.txt`, `mutation-2-red.log`) but I did not re-create a red run myself,
  since doing so would require editing files in the worktree.
