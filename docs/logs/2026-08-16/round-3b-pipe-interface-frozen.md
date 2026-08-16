# Round 3b — pipe squad frozen design (set by pipe-lead-opus before implementation)

Only the squad lead may change this document. Members must not renegotiate any
item here mid-flight; if something here is wrong, STOP and report to the lead.

## 1. Frozen integration type — ALREADY LANDED

`lib/services/native_thumbnail_service.dart` already contains the frozen types,
written by the lead so the two implementers cannot race on them:

```dart
sealed class NativeImageResult {}
class NativeImageBytes         extends NativeImageResult { final Uint8List bytes; }
class NativeImageNeedsRawDecode extends NativeImageResult { final int exifOrientation; } // 1..8
class NativeImageFailure       extends NativeImageResult { final String code; final String? message; }

const int    kDefaultExifOrientation  = 1;
const String kNoEmbeddedPreviewCode   = 'NO_EMBEDDED_PREVIEW';
const String kAllowRawDecodeSignalArg = 'allowRawDecodeSignal';

static Future<NativeImageResult> NativeThumbnailService.requestImage(
    String path, {ImageRequestPurpose purpose, int? targetSize, bool allowRawDecodeSignal = true});
static Future<Uint8List?>        NativeThumbnailService.getThumbnail(...); // legacy, sends allowRawDecodeSignal=false
```

Mapping rules (frozen):

| channel outcome | result |
|---|---|
| non-null `Uint8List` | `NativeImageBytes` |
| null | `NativeImageFailure('NULL_RESULT', ...)` |
| `PlatformException(code == 'NO_EMBEDDED_PREVIEW')` | `NativeImageNeedsRawDecode(exifOrientation: details as int if 1..8, else 1)` |
| any other `PlatformException` | `NativeImageFailure(e.code, e.message)` |
| `MissingPluginException` | NOT caught — propagates, exactly as today |

`getThumbnail` keeps its old `Future<Uint8List?>` signature **because
`lib/perf/perf_driver.dart:191` is a RED-LINE file that calls it**. It also
forces `allowRawDecodeSignal: false`, so the round-3a perf harness keeps
measuring the exact same native path it measured before.

## 2. Why there is a `allowRawDecodeSignal` flag (the no-regression rule)

Turning "DNG with no embedded preview" from *slow but working* into *hard
failure* is not acceptable. So:

- Native emits `NO_EMBEDDED_PREVIEW` **only** when
  `purpose == "preview"` AND `.dng` AND extraction returned nil AND
  `allowRawDecodeSignal != false`.
- Dart, when it has **no** `DngFullDecoder` injected, or when the decoder
  **throws**, re-requests the same path with `allowRawDecodeSignal: false`,
  which reproduces the pre-round-3b behaviour byte-for-byte (CIRAWFilter,
  2800px cap, slow). Degraded, but never blank.

This fallback is mandatory, not optional.

## 3. File ownership inside the squad

| Owner | Files |
|---|---|
| pipe-impl-1-sonnet | `macos/Runner/AppDelegate.swift`, `macos/Runner/DngPreviewExtractor.swift` (ADD read-only orientation accessor ONLY), `lib/services/native_thumbnail_service.dart`, `test/native_thumbnail_service_test.dart` (new) |
| pipe-impl-2-opus | `lib/services/decoded_rgba_image_provider.dart` (new), `lib/services/image_preload_controller.dart`, `lib/providers/app_state.dart`, `lib/views/main_detail_view.dart`, `test/decoded_rgba_image_provider_test.dart` (new), `test/image_preload_controller_test.dart`, `test/app_state_test.dart` |
| pipe-test-haiku | writes only under `tmp/verify/r3b/` |

Nobody else's files. No `git stash/reset/checkout --/clean` — the pkg squad has
uncommitted work in this same tree.

## 4. Frozen Dart-side API for the decode/display half

```dart
// lib/services/decoded_rgba_image_provider.dart
/// Wraps an already-decoded ui.Image so it can be used as Image(image: ...).
class DecodedRgbaImageProvider extends ImageProvider<DecodedRgbaImageProvider> {
  DecodedRgbaImageProvider(this.image, {this.scale = 1.0});
  final ui.Image image;
  final double scale;
  // loadImage MUST hand ImageInfo a `image.clone()`, because ImageInfo.dispose()
  // disposes the image it holds and the provider must keep its own handle alive.
  // == / hashCode: identity of `image` + scale.
}

/// Applies an EXIF orientation (1..8). CALLER OWNS BOTH IMAGES: this function
/// never disposes anything. Returns `src` ITSELF when orientation == 1.
Future<ui.Image> applyExifOrientation(ui.Image src, int orientation);

/// RGBA8 -> oriented ui.Image, end to end.
Future<ui.Image> decodedRgbaToImage(DecodedRgba rgba, {required int exifOrientation});
```

`ImageBytesLoader` in `image_preload_controller.dart` changes to return
`Future<NativeImageResult>`; the 8 existing fake loaders in
`test/image_preload_controller_test.dart` are updated mechanically
(`async => NativeImageBytes(...)`). `ThumbnailLoader` in `app_state.dart`
changes the same way.

The decoder is injected exactly like `ImageBytesLoader`:
`ImagePreloadController({required ImageBytesLoader imageLoader, DngFullDecoder? dngDecoder})`
and `AppState({..., DngFullDecoder? dngDecoder})`. **Do not import
`lib/services/dng_decode_service.dart`** — it belongs to the pkg squad and may
not exist yet. Program against the typedef only.

## 5. ui.Image lifetime (first-class, not cleanup)

- One decode per item serves BOTH tiers. Never decode the same item twice.
- The controller owns the `ui.Image` and disposes it in `_evictTierTwoEntry`
  (and in `reset()`), i.e. when the entry leaves the preload window.
- Anything handed to `ImageInfo` is a `clone()`, so disposing the controller's
  handle is safe while a frame is still on screen.
- 4080x3056 RGBA8 = 49.9 MB per image; window is +/-1 = ~150 MB against a
  500 MB ImageCache cap. Do not widen the window this round.

## 6. Out of scope (forbidden)

No R/B channel swap, no CFA-phase colour correction. Wrong colours on non-RGGB
cameras are a known decoder defect being fixed elsewhere. Do not compensate.


---

# CORRECTION — the implementation deviates from §4/§5 above, deliberately

**The prose in §4 and §5 above is the design as frozen BEFORE implementation.
Where the shipped code differs, the CODE is correct and this document was not
updated in time.** `pipe-impl-2-opus` discovered the mismatches after building
against an earlier brief, offered to refactor to conform, and the squad lead
(`pipe-lead-opus`) ruled **against** conforming. Recorded here so a future
reader does not "restore" the document's version and undo working, tested code.

Reason for the ruling: the frozen document existed for exactly one purpose —
to stop two implementers negotiating a shared interface mid-flight. That
purpose was fully served; the interface landed and both halves compiled
against it. Conforming tested code to prose at the end of a round risks
introducing a real defect in order to remove a cosmetic mismatch.

| # | Document says | Code actually does | Verdict |
|---|---|---|---|
| 1 | `ImageBytesLoader` returns `Future<NativeImageResult>`; one injection point | `ImageBytesLoader` unchanged (`Uint8List?`), plus a second injection point `NativeImageRequester` | Code stands. Two narrow injection points are no worse than one wide one, and it left the pre-existing loader's callers untouched. |
| 2 | Fallback re-requests via `NativeThumbnailService.getThumbnail(...)` | Same — `image_preload_controller.dart:438` calls that static | **No deviation.** The implementer's self-report was pessimistic about its own code; verified by the lead by tracing the call chain. |
| 3 | `applyExifOrientation` public, caller-owns, never disposes | Private `_applyTransform`; `decodedRgbaToImage` disposes its own intermediate | Code stands. The disposal is internal to one function and does not leak the caller-owns question outward. |
| 4 | `decodedRgbaToImage(..., {required int exifOrientation})` | `{int orientation = 1}` | Code stands. Naming only. |
| 5 | Disposal folded into `_evictTierTwoEntry` and `reset()` | Parallel `_disposeDecodedEntry`, swept alongside | Code stands. Merging eviction paths late in a round is how a leak gets introduced; two paths that both run is not a defect. |
| 6 | Tests live in the owned test files | An extra `test/raw_decode_pipeline_test.dart` was created | Code stands. Ownership bookkeeping, not behaviour. |

## A ruling the lead withdrew

The lead earlier instructed the implementer to **add a branch to
`isFullSizeReady`** for the decoded path. The implementer instead used a
separate `decodedProviderFor(id)` accessor and left `isFullSizeReady`
completely untouched. **The lead withdrew its own instruction and kept the
implementer's version**, because a separate accessor makes it *structurally
impossible* for the decoded path to affect the three-way conjunction that
round-2 review BLOCKER 1 and BLOCKER 3 both came from. Do not "finish" the
lead's original idea by folding the decoded path into that predicate.

---

# WARNING — a measured population changed meaning in round 3b

**Read this before comparing any round-3a DNG performance number against a
round-3b or later one.** This is not a nit; it is a silent redefinition of the
metric that round 3a's headline figures are expressed in.

## What changed

`macos/Runner/AppDelegate.swift` emits a perf event
`result.dispatch|<file>|nativeTotal=<microseconds>` at the point where the
native side hands a result back to Dart. `nativeTotal` is measured from
`perfEnqueue`, i.e. the moment the method-channel handler was entered, so it
has always meant "total native time for this request".

For one specific population — **preview-purpose requests on a `.dng` whose
embedded full-size JPEG extraction returns nil** (bare CFA captures, e.g. the
vivo PD2337 sample; called the "DNG miss" subgroup in the round-3a analysis) —
the *work being timed* is now different:

| | Before (round 3a, commit `b557261`) | After (round 3b) |
|---|---|---|
| What happens on a miss | Falls through to the CIRAWFilter full RAW decode + JPEG re-encode, then dispatches bytes | Returns early with `FlutterError(code: "NO_EMBEDDED_PREVIEW")` carrying EXIF orientation; no decode at all |
| What `nativeTotal` covers | TIFF walk + full RAW decode + re-encode | TIFF walk + a second read of the file for the Orientation tag |
| Typical magnitude | 245–414 ms | sub-millisecond to a few ms |
| Does an image reach the screen from this call? | Yes | **No** — the image is produced later, by the Dart-side RAW decoder |

The new event additionally carries a bare trailing token `noEmbeddedPreview`
(no `=`), which is how you can identify these records. `scripts/tmp/perf/parse_r2.py`
builds its field dictionary only from tokens containing `=` (`parse_r2.py:24-30`),
so the token is ignored by the parser and no existing field was renamed or
removed.

## Why this will mislead someone

For the DNG miss subgroup, `nativeTotal` dropped by roughly two orders of
magnitude **without the user-visible operation getting faster by that amount**.
The decode did not disappear; it moved to the Dart side, into
`DngFullDecoder` / `decodeOnWorker`, where this metric does not see it.

So a naive round-3a-vs-round-3c comparison of the DNG `nativeTotal`
distribution will show a large apparent improvement that is mostly an artefact
of the measurement boundary moving. The tail statistics are affected worst:
round 3a's DNG `p95`/`max` were dominated by exactly these miss-path full
decodes, and those samples are now sub-millisecond.

## What to do instead

Any round-3c comparison involving DNGs must either:

1. **Segment the population** — report the miss subgroup separately from the
   passthrough-hit subgroup, and never pool them across the 3a/3b boundary; or
2. **Measure end-to-end instead of native-only** — for the miss subgroup the
   honest quantity is time-to-pixels-on-screen (`PERF` side:
   `channel.preview` -> `image.resolved` / `image.painted`), because
   `nativeTotal` no longer contains the decode for that path.

This compounds a caveat already recorded in the round-3b handover §10: round-2
and round-3 DNG sample sets already differ in composition (r2 was 100% full
decodes, zero passthrough). Round 3b adds a third, differently-shaped
population. Treat "DNG nativeTotal" as three non-comparable series across
r2 / r3a / r3b+, not one time series.

---

# KNOWN LIMITATION — memory behaviour is barely measured (one real-size run, 2026-08-17)

**Do not read the green test suite as covering this.**

Every fixture in the round-3b pipe tests is **2x2 or 2x3 pixels**. No automated
test has ever exercised a real 4080x3056 RGBA8 buffer (49.9 MB). The memory
reasoning in this round — a tier-2 window of ±1, three resident decoded images,
~150 MB against the 500 MB `ImageCache` cap — is **analytical, not measured**.

This is a deliberate scoping decision, not an oversight:

- The `ui.Image.onCreate` / `onDispose` **balance test** detects handle
  imbalance at *any* buffer size. Leaking a handle is the failure mode a unit
  test can genuinely own, and it is owned.
- How a real 49.9 MB allocation behaves against the cap under real navigation
  is a property of the **running application**, not of the code in isolation. A
  synthetic 50 MB fixture would be slower, flakier, and still would not be the
  real thing.

**Therefore the real-machine check by the user is load-bearing, not
ceremonial.** It is the only step that closes this gap.

Status (updated 2026-08-17, after Z3): **exercised once at real size, in a
patched build, without observed failure — still not measured under sustained
navigation.** The Z3 run decoded six real 4080x3056 images through the preload
window with `image.painted tier=2` and no failure or stall. That is the first
time genuine 49.9 MB buffers passed through this controller, so the claim is no
longer purely analytical — but one clean run is not a memory verification.
Treat sustained-navigation memory behaviour as still unproven.

Related known limitation carried from round 3a: the EXIF orientation injection
was validated against real samples only for orientation 1 and 6. Round 3b's
`applyExifOrientation` covers 1..8 with per-pixel assertions, but against
*synthetic* fixtures — no real-world sample exists in the test set for
orientations 2,3,4,5,7,8.

---

# WHAT WORKED — freeze the seam before either side starts

Recorded because it was the cheapest thing done this round and the reason the
two squads never blocked each other.

`lib/services/dng_decode_contract.dart` (`DecodedRgba` +
`typedef DngFullDecoder`) was frozen and committed at `8e6a1cf` **before either
squad began implementation**. Consequences:

- The `pkg` squad built the real decoder adapter and the `pipe` squad built the
  entire display pipeline **in parallel, in the same working tree**, with
  neither waiting on the other. `pipe` programmed against the typedef with a
  fake decoder throughout, exactly as the pre-existing `ImageBytesLoader`
  injection already did.
- When the adapter finally landed, it exposed
  `const DngFullDecoder halcyonDngFullDecoder = decodeDngFull;`
  (`lib/services/dng_decode_service.dart:39`) and the composition-root wiring
  was **two lines with no adaptation layer** — because both sides had been
  compiling against the same frozen type all along.

The same technique applied *within* the pipe squad: the `NativeImageResult`
sealed type was written by the squad lead into
`lib/services/native_thumbnail_service.dart` **before** either implementer was
assigned, so the two halves could not negotiate it mid-flight. One implementer
proposed an in-band sentinel (a zero-length `Uint8List` compared by
`identical()`); freezing the type first meant that never became a discussion.

Cost: one file, ~30 lines, written before any implementation. Do this again.

---

# THE RECURRING HAZARD OF ROUND 3B — asynchronous delivery, not carelessness

Every control that failed in this round failed the same way: **a claim was
accurate when written and stale when read.** Not one failure was a discipline
problem. Listing them because the pattern is the lesson, not any single case.

| Control | How it failed |
|---|---|
| Orchestrator's staleness call | Concluded a build predated a Swift edit, inferred from two agents' *chat message timestamps*, which say nothing about the tree. It had in fact compiled. |
| Squad lead's all-clear | Certified a tree as compile-clean while an unanswered "do NOT certify on this, say hold and I will stop" message from its own implementer sat unread in its inbox. |
| The commit-hash binding rule | Every artifact recorded `8e6a1cf`, *including the pre-change baseline*, because nothing in the round was committed. The rule read as satisfied while proving nothing. |
| A content marker | `_disposeDecodedEntry` was chosen as a marker and then deleted by a refactor. A marker taken from actively-restructured code is a bad marker. |
| Squad lead's code trace | Reported the fallback safe via `app_state.dart:40` wiring `getThumbnail`. It wires `requestImage` (flag defaults **true**). The lead read the pre-refactor file. Conclusion held; mechanism was false. |
| Mutation-safety handshake | Authorisation and the handshake requirement were sent in **separate messages**. A correct actor executed the first while the second was still in flight, so a deliberate regression was live on a shared tree unannounced for ~1 minute. |

## What actually worked

1. **Content markers over commit hashes, when work is uncommitted.** The only
   guard that ever fired: a test-runner was told to expect
   `_disposeDecodedEntry` = 5, found 6, and stopped before running a single
   test. A hash would have read `8e6a1cf` and sailed through. Rule adopted
   team-wide: an artifact must carry *either* the commit hash if the work is
   committed, *or* a named symbol introduced by the change that the run
   demonstrably exercised.
2. **State which version of the tree a claim describes.** The implementer did
   this habitually and it is what caught the lead's false mechanism.
3. **Put mutually-dependent instructions in ONE message.** An instruction and
   its precondition delivered separately will be executed out of order by a
   correct actor. This is the only fix that works; "be careful" is not.
4. **Re-audit after any change, never reuse a spot-check.** Two of the lead's
   own rulings were reversed by re-auditing a tree it knew had moved.
5. **Red-then-green, always.** A test that has only ever passed is a claim, not
   evidence. Applied to the fallback assertion (2/2 mutants killed), to the
   leak-balance test (`Actual: <3>` → `<0>`), and to the invariant guard.
   The leak-balance test found a **real** 3-handle / ~150 MB leak that B4 was
   green over the entire time.
6. **Disclose process gaps even when the outcome was clean.** The unannounced
   mutation window was reported by the implementer who could have stayed
   silent behind a sha256-verified restore. Nothing would have looked
   different. That disclosure is what makes the rest of this round's evidence
   worth trusting.

---

# ⚠ READ THIS BEFORE CHANGING `tierTwoNavigationDebounce` — addressed to round 3c

**Round 3c is the performance round. Shortening or removing a 250 ms debounce
is exactly the kind of thing a performance round does without a second thought.
Do not do it to this one until you have read this section and re-run the two
named tests below.**

## The instruction

Before changing `tierTwoNavigationDebounce`
(`lib/services/image_preload_controller.dart:45`), or making the tier-2 sweep
synchronous, **re-run both of these and require them green**:

```
flutter test test/image_preload_controller_test.dart \
  --plain-name 'a raw item is requested from the native loader exactly ONCE across repeated in-window passes'

flutter test test/image_preload_controller_test.dart \
  --plain-name 'every decoded ui.Image handle is disposed across a window sweep'
```

Both live in `test/image_preload_controller_test.dart`, in the `raw-decode
path` group (as of round 3b: the request-once guard at ~:932, the
create/dispose balance guard at ~:1035, and the cancellation-path balance
guard at ~:1078).

## Why — the raw-decode path's safety currently depends on losing a race

An in-window raw-decode item reaches `neededIds` only via `_needsRawDecode`
(`_decodeTierTwoWindow`, the branch that starts the decode). It therefore
*looks* as though clearing `_needsRawDecode` once a decode succeeds would make
the next sweep evict and dispose the image that just landed.

**It does not — and the reason is ordering, not structure.**
`_requestPreviewBytes` repopulates `_needsRawDecode[id]` during the next
`preloadImages` pass, and that pass completes **before** the sweep, because the
sweep sits behind the 250 ms debounce scheduled at the end of `preloadImages`.
By the time the sweep computes `neededIds`, the id is back.

This was established by mutation, not by reading: adding
`_needsRawDecode.remove(id)` to the success path of `_runRawDecode` produced a
**surviving mutant** — no eviction, no disposal, the image stayed alive. The
real cost of that mutation is a native channel round-trip per navigation per
raw item, which is what the request-once test detects.

**The consequence for you:** that protection is a timing coincidence. Remove
the debounce, shorten it below the preload round-trip, or make the sweep
synchronous, and the disposal described above stops being hypothetical. The
symptom would be **an image vanishing after it had already appeared on
screen** — and nobody debugging that has any reason to suspect a debounce
constant. That is why this warning is in the handoff and not only in a comment
at the call site: the person shortening a debounce is not reading that line.

Evidence: `tmp/verify/r3b/leak_fix.txt` (leak FAIL → fix PASS → mutant 2
SURVIVED → replacement baseline PASS → mutant 3 KILLED → restored PASS).

---

# EPISTEMIC NOTE — reading code produces claims, not evidence, regardless of who reads it

Round 3b produced **three** confident lifetime claims about
`image_preload_controller.dart`. All three were tested. **All three were
false.**

| Claim | Made by | Fate |
|---|---|---|
| "If an item leaves the window mid-decode, the in-flight marker is cleared and the late image disposes itself." | The implementer, about code it had just written | **False.** The marker was cleared only by a method every caller reached via collections an in-flight id is absent from. Real leak: 3 handles, ~150 MB, with B4 green throughout. |
| "Clearing `_needsRawDecode` on success would make the next sweep dispose the image that just landed; it would present as flicker." | The squad lead, dictated to the implementer; endorsed by the orchestrator | **False.** Mutant survived — repopulation wins the race against the debounced sweep. |
| The first invariant-guard test, written to protect claim 2 | The implementer, at the lead's instruction | **Worthless.** It asserted an outcome the mutation could not change, so it could never fail. |

The transferable lesson is **not** "be careful". It is that **reading code
produces claims of the same epistemic status regardless of who is reading** —
the author, the reviewer, the lead who wrote the verification rule, and the
orchestrator who endorsed it were all wrong here, in that order. Seniority,
review, and having personally authored the standard confer no additional
truth-value on an unexecuted claim.

On this controller specifically, a plausible-sounding lifetime claim has been
wrong **three times out of three**. The only thing that separated true from
false in every case was running the mutation and watching the test go red.

Practical rule: **a lifetime claim about this file is not evidence until a
mutation has made a test fail.** Comments asserting lifetime behaviour here
should cite the artifact that demonstrates it, as the current ones now do.

## If you carry one line from round 3b, carry this one

> **Run the thing that should fail, and watch it fail.**

Not "write more tests", not "review more carefully", not "be careful with
lifetimes". One cheap, mechanical rule, applied four times in round 3b, cost a
few minutes each time, and overturned a claim **every** time:

| Applied to | Outcome |
|---|---|
| The fallback's `allowRawDecodeSignal` assertion | 2/2 mutants killed — the assertion was real |
| The `ui.Image` create/dispose balance | Found a genuine 3-handle / ~150 MB leak that `B4` was green over the entire time |
| The first `_needsRawDecode` guard test | Mutant **survived** — the test could not fail, and was replaced |
| The lead's "clearing it would cause disposal/flicker" mechanism | Falsified — the protection is an ordering race, not structure |

Two of the four overturned claims belonged to the implementer, one to the
squad lead, and one was endorsed by the orchestrator. **This is a property of
the procedure, not of any individual's carefulness** — which is precisely why
it is worth carrying: it works regardless of who is wrong, and it does not
require anyone to suspect themselves first.

---

# WHAT THE ROUND-3B BATTERY DID AND DID NOT PROVE

Recorded because a future reader will find a fully green round-close battery in
the logs and reasonably assume it covered the feature. **It did not.**

## Proved by the battery

| Gate | Proved |
|---|---|
| G1 | `flutter build macos --release` succeeds with the decoder referenced from the app's main path (`main.dart` → `dng_decode_service.dart` → `dng_processor`) |
| G2/G3 | `libdng_decoder_native.dylib` is embedded in `Halcyon.app/Contents/Frameworks/`; `otool` shows `@rpath` for the dylib itself and a known absolute `/opt/homebrew` path for jpeg-turbo (accepted this round; recorded as an interface request to the decoder project) |
| G4 | Full `flutter test` green, declared == executed |
| G5 | Round 3a's extraction logic intact (`ALL PASS`, 12 samples) |

## NOT proved by the battery — and specifically not by G6

**G6 (the perf-driver live-load check) cannot exercise the round-3b feature at
all.** `lib/perf/perf_driver.dart:191` calls
`NativeThumbnailService.getThumbnail`, and that entry point hard-codes
`allowRawDecodeSignal: false` (`native_thumbnail_service.dart:133`). That is
deliberate — it keeps the perf harness measuring the identical native path
round 3a measured — but the consequence is that the driver takes the **legacy
CIRAWFilter route** for every bare-CFA DNG. It never emits
`NO_EMBEDDED_PREVIEW`, never reaches `DngFullDecoder`, and never loads the
native dylib.

Two traps follow, and both were nearly walked into:

1. A **green** G6 proves the app launches and loads images. It is a launch
   smoke test. It is **not** evidence that the raw-decode path works.
2. An **absent** `[DngNativeBindings] loaded:` line in a G6 run is the
   *expected* result, and is indistinguishable from a genuine production
   packaging failure. Do not escalate it as one without first checking which
   entry point the driver used.

**Z3 — the only end-to-end proof that a DNG with no embedded preview reaches
the screen through a real decode — is the user's real-machine check.** No
automated gate in this round covers it. Neither does the `dng_decoder_smoke_test`,
which exercises `decodeOnWorker` directly and proves the decoder works, but
does not go through Halcyon's pipeline.

Combined with the fixture-size limitation recorded above (nothing has touched a
real 4080×3056 buffer), the real-machine check is load-bearing for **two**
independent claims: that the feature works at all, and that its memory
behaviour is acceptable. Treat it as a gate, not a formality.

---

# Z3 OUTCOME (2026-08-17) — the feature is correct and is blocked externally

**Z3 FAILED in the shipped app, then was proven to work once an external
dependency was patched. Nothing in `lib/` is at fault.**

Run: release build, six bare-CFA DNGs in the sandbox container, every
navigation forced down the raw-decode path.

## What worked, unmodified

- Precondition `perf.init` present.
- **`noEmbeddedPreview` fired 6/6.** The native signal added this round works
  end to end *in the shipped application*, not merely in tests. That is B1's
  mechanism validated in production, which no unit test could establish.

## What failed, and why it is not ours

`rawDecode.fail`, from a dylib load error. dyld's own words
(`DYLD_PRINT_SEARCHING=1`):

```
dyld: .../Halcyon.app/Contents/Frameworks/libdng_decoder_native.dylib   <- maps fine
dyld: find path "/opt/homebrew/opt/jpeg-turbo/lib/libjpeg.8.dylib"
dyld:   found: dylib-from-disk-error: => "file system sandbox blocked open()"
```

The decoder links libjpeg by **absolute path into `/opt/homebrew`**, which a
sandboxed process cannot read. This is the `@rpath` item already recorded as an
interface request to the decoder project — accepted as out of scope for round
3b, now demonstrated to be a hard blocker rather than a cosmetic one.

## Proof the pipeline itself is correct

Patching a **copy** of the `.app` to bundle libjpeg at `@rpath` makes the whole
round-3b feature work:

```
rawDecode.ready x9   4080x3056   orient=1   61-406 ms   image.painted tier=2
```

Full resolution, correct orientation, on screen. The user has ruled against a
Halcyon-side workaround; we wait for the decoder team.

**Do not read `orient=1` as validating the orientation work.** It is the
identity passthrough — the weakest of the eight cases. The real sample happened
to be upright. Orientations 2-8 remain exercised **only** against synthetic
2x3 fixtures, and they are precisely the cases that would break visibly.

## The single most important thing this run established

**The no-regression fallback held under a genuine, unplanned production
failure.** `rawDecode.fail` was immediately followed by `image.resolved|tier=1`
and `image.painted|tier=1` — the user saw a picture, not a blank screen or an
error.

That fallback exists because the original design direction would have converted
"DNG with no embedded preview" from *slow but working* into a *hard failure*
whenever the decoder was absent or threw. It was added as a squad-lead
correction to the orchestrator's design, made mandatory, and defended with a
mutation proof (2/2 mutants killed) when a code-trace argument was judged
insufficient.

Without it, this round would have shipped an app that shows **nothing** for
bare-CFA DNGs on any machine where the decoder cannot load — which, as of this
run, is *every* machine. Design decisions that only pay off in failure modes
nobody expects are the hardest to justify at the time and the easiest to cut;
this one was tested by reality within a day.

## Traceability — the blocker was not unforeseen. We scheduled it.

The libjpeg `@rpath` problem that blocked Z3 is in the convergence contract's
own **Out-of-scope** list, frozen before any work began:

> 「libjpeg 的 `@rpath` 修復（記入介面文件轉交，本輪接受 homebrew 絕對路徑）」

So the decision that blocked the stated end state is a decision the contract
made deliberately, on day one, and recorded. A3 — the interface-requests
document — exists *because* of it.

**The reusable lesson is about what belongs in out-of-scope.** "Z3 failed on an
external dependency" reads as bad luck. "Z3 failed on the one dependency we
knowingly deferred" is a different statement entirely:

> **A deferral that sits directly on the critical path to the stated end state
> is not a deferral. It is an unscheduled blocker.**

Deferring it was still defensible — it lives in another project and the user
later ruled against a Halcyon-side workaround — but it should have been
recorded as *"the end state cannot be reached this round unless X lands"*,
not as an accepted out-of-scope item alongside genuinely orthogonal ones like
Android support. Every acceptance criterion (B1-B5, A1-A3, Z1) could pass, and
did, while the one-sentence end state remained unreachable on every machine.

Check for next round: for each out-of-scope item, ask whether the stated end
state is reachable if it never lands. If the answer is no, it is not
out-of-scope — it is a dependency with no owner.
