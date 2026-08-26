---
date: 2026-08-26
title: "Baton — dart_image_loader.dart, handing off at cap"
from: impl-loader-opus (tasks T2, T8)
tree state: HEAD d78b23a
---

## Contract, quoted verbatim

From `docs/logs/2026-08-26/raw-support-contract.md`, terminal state:

> Every RAW container the Ceyx engine can decode is browsable in Halcyon and renders at
> full size — via its embedded preview when one exists, via the engine's generic-RAW
> decode entry point when one does not — and on platforms with no native library the
> file still appears and reports an explicit "cannot decode on this platform" state.

Constraint you cannot negotiate, quoted verbatim from the same file:

> `NativeImageResult` keeps exactly three variants (memory.md AD-010/AD-011). The new
> D3 platform state must be expressed as a `NativeImageFailure` with its own code, NOT
> as a fourth variant.

> The two "no preview" terminal states stay distinguishable (memory.md AD-022):
> "container declares previews but none are readable" stays a broken-file report.

Note the tension: the second quote is what the user has now overridden. **The user's new
ruling wins** — a container whose declared previews are all unreadable must be routed to
the decoder FIRST and reported broken only if the decode also fails. AD-022's *pre-empt*
is what dies. What must NOT die is that the two states remain **distinguishable** at the
end — "no preview, decoded fine" and "previews broken and decode failed" must still be
tellable apart. Do not read the override as permission to collapse them.

Basis for the override, per the lead: such a file decodes fine in 383ms today while the
loader reports it broken. I did not measure this myself; I am relaying it.

---

## 1. Current shape of the malformed branch

`lib/services/image_pipeline/dart_image_loader.dart:159-166`, verbatim:

```dart
    if (probe.malformed && SupportedPhotoFormats.isDecodablePath(path)) {
      return const NativeImageFailure(
        'DNG_PARSE_FAILED',
        'every embedded preview the container declares is unreadable',
      );
    }
```

Its position in the flow matters more than its body. Reading `dart_image_loader.dart`:

- `:126` `strictPreview` — decides whether an undersized candidate counts as a miss.
- `:129-134` `probeEmbeddedJpeg` — returns `(jpeg, malformed)`.
- `:136` `if (full != null) return NativeImageBytes(full);` — the hit path.
- `:159` **the malformed pre-empt (above). This is what the user's ruling removes.**
- `:169-177` the `IMAGE_TOO_LARGE` budget guard (F-20). Leave it alone; it is a
  header-claims-absurd-extent guard, unrelated to preview readability.
- `:180` `return NativeImageNeedsRawDecode(exifOrientation: ...)` — the decode route.
- `:189` `RAW_NO_EMBEDDED_PREVIEW` — the browse-only / non-decodable terminal state.

The mechanical shape of the change the ruling implies: delete or bypass `:159-166` so a
malformed container falls through to `:180`. The verdict then has to be re-formed
*after* the decode, which happens in a different file (see §3).

`probe.malformed` semantics, from `memory.md` AD-022 — true **only** when the walker
parsed the container and *every declared candidate* was unreadable. One bad strip beside
one good one is not malformed. Three things are deliberately NOT malformed, each with a
test that fails if the line moves: a genuinely preview-less container; a G-2 undersized
but intact candidate; a file that fails before IFD0 is readable.

---

## 2. Every test that pins it, by name

All in `test/services/image_pipeline/dart_image_loader_test.dart`. The first two are the
ones that will go red the moment you remove the pre-empt — that is expected and correct,
not a regression to route around.

| Line | Test name (verbatim prefix) | What it pins |
|---|---|---|
| 443 | `(a) preview on a container whose every declared candidate is unreadable fails fast instead of entering RAW decode` | **The pre-empt itself.** Asserts `DNG_PARSE_FAILED`. Directly contradicts the new ruling — this is the test the user's decision overrides. Its `reason:` string says "previously this returned NativeImageNeedsRawDecode", which is where you are heading back to. |
| 537 | `AD-022 generalised: an engine-decodable non-DNG RAW whose every declared candidate is unreadable is BROKEN, not preview-less` | Same pre-empt on `.arw`. Asserts `DNG_PARSE_FAILED`. Mine, added in 771e61e. |
| 550 | `AD-022 NOT generalised to browse-only RAW: a corrupt .cr2 keeps the uniform unsupported state, because there is no decode to pre-empt` | A corrupt `.cr2` → `RAW_NO_EMBEDDED_PREVIEW`. **Should still pass unchanged** — browse-only RAW has no decode to route to, so the ruling does not reach it. If this one goes red you have over-reached. |
| 457 | `(c) the sidebar branch is unchanged: still NO_THUMBNAIL` | The sidebar never sees any of this. Must stay green. |
| 466 | `(b) a real preview-less DNG still yields NeedsRawDecode — the valid-miss path did not regress` | The valid-miss path. Must stay green. |
| 489 | `the G-2 undersized rejection is NOT malformed — an intact but small candidate keeps routing to RAW decode` | The `malformed == false` boundary for undersized-but-intact. Must stay green. |
| 507 | `probe: a corrupt container reports malformed, an intact one does not, and a non-TIFF file is not malformed either` | Extractor-level, not loader-level. Should stay green regardless — you are changing what the loader DOES with `malformed`, not what the walker reports. If this goes red you changed the wrong layer. |
| 569 | `a non-TIFF engine-decodable RAW (.cr3/.raf/.x3f) is never reported as a parse failure; it reaches the decoder` | See §4. Must stay green. |
| 25 | `AC3: NativeImageResult has exactly three variants and the D3 platform state is a failure CODE, not a fourth variant` | See §3. |

Also live, outside my files: `test/services/image_pipeline/raw_coverage_wiring_test.dart`
(T4's) and `test/services/library/photo_export_service_test.dart`. Run
`flutter test -j 1 test/services/library/ test/services/image_pipeline/` — that pairing
is what I used and it catches the export path, which is easy to forget.

---

## 3. The result type is frozen at three variants

`NativeImageBytes`, `NativeImageNeedsRawDecode`, `NativeImageFailure`, in
`lib/services/image_pipeline/image_source_types.dart:48-87`. AD-010/AD-011 freeze this,
and the contract restates it. **You cannot add a fourth.** `dart_image_loader_test.dart:25`
enforces it with a `switch` that has no `default` clause, so a fourth variant fails to
compile rather than failing an assertion.

### Can the malformed signal ride on `NativeImageNeedsRawDecode` as a field?

**Yes, mechanically — I checked the readers.** It currently carries exactly one field,
`exifOrientation`. Every reader in `lib/`:

- `lib/services/image_pipeline/photo_source.dart:143` —
  `case NativeImageNeedsRawDecode(:final exifOrientation):`. Destructures one field by
  name; adding another field does not break it.
- `lib/services/library/photo_export_service.dart:68` —
  `} else if (result is NativeImageNeedsRawDecode && decoder != null) {`, then reads
  `result.exifOrientation` at `:76`. A type test; adding a field does not break it.

No exhaustive positional destructuring anywhere, so a new field **with a default** is
source-compatible with both call sites. Nothing else in `lib/` constructs or matches it.

**But consider whether you want it at all.** The decode already happens in
`photo_source.dart:169-190`, inside a `try` whose `catch (_)` is at `:190`. The natural
home for a post-decode verdict is that catch, not a field threaded from the loader — the
loader would be shipping a flag whose only purpose is to be read back after an operation
the loader does not perform. A field earns its place only if the catch needs to tell
"decode failed on a container with broken previews" (→ report broken) apart from
"decode failed on an otherwise fine container" (→ generic failure). If the user is content
with one failure code for both, you need no field and no loader change beyond deleting
the pre-empt. **Ask before building the field.** `photo_source.dart` is not my file and
was not mine to change; it belonged to `impl-wiring-sonnet`.

### Correction to something I said earlier, so you do not inherit it

In my T2 report I justified keeping the string `DNG_PARSE_FAILED` on the grounds it "is
consumed outside this file". **That was an over-claim and it is wrong.** I grepped again
while writing this: the only occurrences anywhere are the loader that emits it
(`dart_image_loader.dart:161`) and two assertions in my own test file (`:454`, `:547`).
No consumer in `lib/` branches on it. The only failure code any consumer inspects is
`kNoNativeDecoderCode`, at `image_preload_controller.dart:602`. So the string is free to
change or disappear — do not preserve it because I said it was load-bearing. It is not.
What *is* load-bearing is the contract's requirement that the two states stay
distinguishable, which is about behaviour, not about that literal.

---

## 4. The load-bearing pin and why it exists

`dart_image_loader_test.dart:569` — `a non-TIFF engine-decodable RAW (.cr3/.raf/.x3f) is
never reported as a parse failure; it reaches the decoder`. Marked LOAD-BEARING in a
comment above it.

When I widened the pre-empt from `.dng` to every engine-decodable extension in 771e61e,
the whole safety argument was: widening cannot misclassify CR3/RAF/X3F because those are
not TIFF at all, so the walker bails before IFD0 and reports `malformed == false` — they
fall through to the decoder rather than being called broken. That is an argument about
walker behaviour, made from outside the walker, so I pinned the fact itself: the test
asserts `probe.malformed == false` directly, then asserts the loader returns
`NativeImageNeedsRawDecode`.

Its comment instructs that if the walker ever starts parsing those containers, this is
where the argument must be **re-examined**, and that the correct response is not to widen
the expectation to match. Defend that instruction if anyone hits it.

The clock on it is already running: `890cecb` taught the same walker a second container
flavour this round (Panasonic RW2, TIFF version word 85). It stayed true — that widened
the accepted version word, it did not teach the walker to parse non-TIFF containers — but
that is the direction of travel.

**Relevance to your task:** if you remove the pre-empt entirely, this pin becomes much
less critical, because "misclassified as broken" stops being a reachable outcome at the
loader. Do not delete the test on that reasoning — it still pins that these containers
reach the decoder, which is exactly what the contract's terminal state requires. Its
justification narrows; its assertion stays useful.

Known limitation, stated when I wrote it: the test uses junk bytes with those extensions,
not real CR3/RAF/X3F files. It proves the walker declines to parse them. It does not
prove behaviour on genuine files of those formats. The contract accepts this — real
samples exist only for Panasonic, Sony, Fujifilm and Sigma. Do not fabricate sample files.

---

## 5. Failure traces — tried and rejected, do not retry

Honest scope note: T2 and T8 went green without a long failure trail, so this list is
short. I am not padding it with hypotheticals. These are real decisions I made and the
evidence that settled each.

1. **Rejected: making `photo_export_service.dart` pass `ImageRequestPurpose.export`.**
   This is the obvious-looking fix to the "export should be lenient" problem and it is
   wrong. The loader never emits `NativeImageNeedsRawDecode` for the `export` purpose, so
   the branch at `photo_export_service.dart:68` would go dead and exporting a preview-less
   RAW would start returning `null`. That service documents its `preview` choice as
   deliberate at `:43-46` for exactly this reason, and the test `a no-preview DNG with an
   injected decoder exports via the raw-decode branch` pins the live branch. Settled in
   T8; the comment was corrected instead, in `d78b23a`.

2. **Rejected: mechanically swapping the `.dng` predicate for `isDecodablePath` in the
   `strictPreview` guard.** The lead explicitly asked for a re-derivation, and it matters:
   the old guard's stated premise was "the escape hatch is gated on `.dng`", which is the
   exact premise the contract removed. Re-deriving from A-6's actual principle — be strict
   only where a rejection lands in a real decode — gives a *different* answer for
   browse-only RAW (`.cr2`/`.iiq`/`.mrw`), which must stay lenient because the engine
   cannot decode it. A mechanical swap would have got that wrong.

3. **Rejected: renaming `DNG_PARSE_FAILED` to something format-neutral.** Correct in
   principle, but the contract's parking lot forbids renaming the seam vocabulary this
   round. See the §3 correction: my stated reason for keeping it was wrong, the parking-lot
   reason is the real one.

4. **Rejected: deciding D3 inside the loader.** The loader is `Platform`-free by
   construction (C-3) and cannot know whether a native decoder exists. I defined
   `kNoNativeDecoderCode` in `image_source_types.dart:96-108` but deliberately never emit
   it; `photo_source.dart:143-158` decides it, before invoking any decoder, never inferred
   from a caught exception. If your work tempts you to have the loader answer "can this
   platform decode", that is the wrong file.

5. **Process trace, so you do not repeat it.** Two existing tests used `.arw` as the
   stand-in for "a RAW with no escape hatch". My change moved `.arw` out of that class, so
   the stand-in became factually wrong while the assertion stayed correct. The right move
   was to rehome each assertion to `.cr2` (where the premise still holds) and add an
   `.arw` twin for the new behaviour — **not** to edit the old test's expectation. I
   stopped and got the lead's ruling before touching them. Expect the same shape of
   problem: the tests at `:443` and `:537` are about to become factually wrong in the same
   way, and the same discipline applies. Get the ruling; do not quietly flip an assertion.

6. **Instrumentation traces worth inheriting.** (a) I produced the red run before the
   green one and kept it — `tmp/verify/t2-loadertest-01.txt`, `RC=1`, `+17 -2`, exactly the
   two predicted failures. A test never observed failing is not evidence it tests anything.
   (b) Capture exit codes inside the artifact with `RC=$?` on the very next line; do not
   trust harness notifications. The test-runner on this team had three counts contradicted
   by its own artifacts — read the artifact, not its summary line. (c) Record
   `git rev-parse HEAD` and `git status --porcelain` at the top of the artifact so it names
   its own tree state. (d) `date -Is` fails on this machine's BSD `date`; use
   `date -u +%FT%TZ`. I shipped an artifact with an empty date line because of this.
   (e) I once asserted a commit had landed before someone's test run by reading
   `git log --oneline` order. Commit order is not a timestamp; I was wrong and had to
   retract.

---

## 6. State at handoff

- `flutter analyze` → 0 issues. `flutter test -j 1 test/services/library/
  test/services/image_pipeline/` → RC=0, `+289: All tests passed!`. Artifact:
  `tmp/verify/t8-gate.txt` (HEAD `e78a401` at run time; `d78b23a` is the commit after).
- My commits: `771e61e` (T2, the generalisation), `d78b23a` (T8, the export-claim
  correction).
- Files I owned and touched: `lib/services/image_pipeline/dart_image_loader.dart`,
  `lib/services/image_pipeline/image_source_types.dart`,
  `test/services/image_pipeline/dart_image_loader_test.dart`. Owned but untouched:
  `test/services/image_pipeline/dart_image_loader_no_method_channel_test.dart`.
- Open parking-lot items I raised, not fixed: the junk-byte stand-in for real
  CR3/RAF/X3F containers; the now-stale DNG-only helper names in
  `dart_image_loader_no_method_channel_test.dart`; the narrow no-decoder export window
  (needs a sensor long edge under roughly 3111px — fix belongs in the export service, not
  the loader); `unit_test.md` TC-matrix entries for my new cases, which belong to T5.
