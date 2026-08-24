# M6 Cross-Platform DNG — Design Spec

> **Status:** Approved by user on 2026-08-24
>
> **Scope:** macOS, Windows, Android, iOS, Linux; web excluded
>
> **Decision:** Dart owns DNG semantics and embedded-preview extraction; native code is allowed only behind the cross-platform FFI RAW decoder adapter.

## Goal

Every valid supported DNG must display an image on macOS, Windows, Android, iOS, and Linux through one Dart-owned control flow. No platform error code, runner branch, or OS codec may decide whether the file is cheap, needs RAW decode, or can be displayed.

## Frozen decisions

| Decision | Ruling |
|---|---|
| Supported targets | macOS, Windows, Android, iOS, Linux. Web is outside this M6 contract. |
| Preview-less valid DNG | Must produce an image on every supported target. `unsupported` is not an acceptable terminal state. |
| Embedded-preview parser | Pure Dart `DngPreviewExtractor` is authoritative on every target. |
| Candidate selection | Dart request-aware policy is authoritative; Swift candidate parity is not a goal. |
| RAW decode implementation | The decode algorithm may remain native behind FFI. Reimplementing RAW decode in Dart is explicitly not required. |
| Semantic ownership | Candidate selection, orientation, cost, decode-required state, defer, fallback order, and terminal result belong to Dart. |
| Swift accelerator | Rejected. A failed performance gate means optimise Dart and re-run the gate, not retain a macOS-only path. |
| Existing result type | Keep `NativeImageNeedsRawDecode` as a compatibility name during M6; Dart becomes its producer. |
| Native cleanup | macOS `NO_EMBEDDED_PREVIEW`, `allowRawDecodeSignal`, and `DngPreviewExtractor.swift` are removed after Dart and FFI gates pass. |

Only the user may change these decisions.

## Supersession

For DNG features F-06/F-07/F-09, this document supersedes any earlier statement that:

- permits per-feature platform demotion below the five supported targets;
- treats iOS or Linux RAW decode as optional or out of scope;
- accepts `unsupported` for a valid preview-less DNG;
- retains Swift extraction after a Dart performance failure; or
- uses Swift full-size candidate selection as the target contract.

In particular, the DNG-related portions of `docs/logs/2026-08-24/m6-feature-platform-matrix.md`, `m6-spec-contract.md`, and `m6-execution-plan.md` must be synchronized with this design before further M6 closure work. Their unrelated feature decisions remain unchanged.

## Architecture

### 1. Dart semantic core

The existing seams remain; no new service hierarchy or capability registry is introduced.

#### `DngPreviewExtractor`

Owns one bounded TIFF/IFD walk that returns enough information to distinguish:

1. a usable embedded JPEG, including bytes, dimensions, and orientation;
2. a valid DNG with no candidate meeting the request; and
3. malformed, unreadable, or unsupported content.

Candidate selection is request-aware:

- choose the smallest valid embedded candidate whose long edge meets the requested long edge;
- use deterministic tie-breaking in the existing Dart implementation;
- if no candidate meets the requested size, classify the request as expensive and use RAW decode rather than treating an undersized preview as the final image.

The same Dart rules apply to detail preview and sidebar requests, with their respective requested long edges. No Swift output is an oracle for candidate selection.

#### `dartImageLoad` / `PhotoSource`

Owns the shared result and control flow:

- embedded candidate → `NativeImageBytes` / encoded payload, `SourceCost.cheap`;
- valid DNG without a sufficient candidate → Dart constructs `NativeImageNeedsRawDecode` with the Dart-read orientation;
- malformed or unreadable content → shared failure/permanent miss;
- `allowExpensive == false` → deferred result with zero decoder calls;
- `allowExpensive == true` → exactly one FFI RAW decode.

`NativeImageNeedsRawDecode` remains a three-variant compatibility type. Its `Native` prefix is known naming debt, not a reason to add an alias or a fourth variant.

#### Scheduler and M5 full-resolution output

The existing expensive-work scheduling remains authoritative:

- an immediate pass may discover and defer expensive work;
- the debounced pass receives the previously discovered orientation without another platform call;
- one RAW decode produces both the window-sized payload and M5 full-resolution payload;
- no target may perform a second RAW decode for the full-resolution result.

### 2. Cross-platform FFI RAW decoder adapter

The native RAW decoder is mechanics only. Its contract is:

```text
decode(path) -> RGBA bytes + width + height, or a decode error
```

It must not:

- select an embedded preview;
- classify cost;
- emit `NO_EMBEDDED_PREVIEW` or an equivalent product signal;
- choose defer or fallback policy;
- apply platform-specific output sizing; or
- turn library absence into an ordinary product capability difference.

The same decoder implementation must be packaged and callable on all five supported targets. Current macOS/Windows/Android support is insufficient: iOS and Linux ports, packaging, and runtime smoke tests are M6 blockers.

Library absence on a supported target is a build/release failure, not a normal runtime outcome. A valid corpus DNG that fails only on one target fails the parity gate.

### 3. Platform runners

Platform runners retain only app-shell and OS-integration mechanics. The DNG main path must not depend on:

- macOS ImageIO/CoreImage DNG policy;
- Windows `RAW_UNSUPPORTED`;
- missing `halcyon/thumbnail` handlers;
- platform-specific re-encode quality; or
- platform-specific legacy fallback.

OS-specific thumbnail code may remain temporarily only as rollback scaffolding during migration. It is not part of the terminal architecture.

## End-to-end data flow

```text
DNG path + requested long edge
  -> Dart bounded content walk
     -> malformed/unreadable
        -> shared failure
     -> embedded candidate meets request
        -> Dart returns encoded JPEG bytes
        -> cheap, zero platform calls, zero RAW decodes, zero re-encodes
     -> valid DNG, no sufficient candidate
        -> Dart reads/defaults orientation
        -> Dart constructs NativeImageNeedsRawDecode
           -> expensive work disallowed: deferred, zero decodes
           -> expensive work allowed: cross-platform FFI decode exactly once
              -> orient once
              -> window payload + M5 full-resolution payload
              -> display image on every supported target
```

## Error handling

- Missing files, malformed TIFF structures, corrupt offsets, and unreadable data may produce the same shared failure on every target.
- A valid preview-less DNG may not become `unsupported`, blank, or a permanent miss because of its target OS.
- FFI decoder initialization or packaging failure must fail platform verification before release.
- A decoder error for a valid canonical sample fails M6 acceptance; it must not fall back to CIRAWFilter, WIC, or another single-platform path.
- Orientation is clamped/defaulted in Dart and applied exactly once.

## Migration phases

### Phase 0 — Contract synchronization

- Make this document the DNG authority.
- Update the existing M6 matrix, contract, and execution plan where they conflict.
- Preserve unrelated feature rulings.

### Phase 1 — Dart path completion

- Finish the pure-Dart producer for detail and sidebar DNG requests.
- Ensure valid miss and parse failure are distinct.
- Make Dart the sole producer of the decode-required result.
- Keep native code temporarily for rollback, but prove the production route does not call it.

### Phase 2 — Five-platform FFI coverage

- Retain verified macOS, Windows, and Android adapters.
- Add and package the same decoder for iOS and Linux.
- Add a real-file smoke test and release-build packaging check for every target.
- Do not declare the phase complete while any supported target cannot render a preview-less canonical DNG.

### Phase 3 — Native DNG path removal

After all functional and performance gates pass:

- remove macOS `NO_EMBEDDED_PREVIEW` emission;
- remove `allowRawDecodeSignal` and its channel negotiation;
- remove `DngPreviewExtractor.swift` and Xcode target membership;
- remove Windows DNG rejection from the production path;
- remove CIRAWFilter/native-thumbnail fallback claims and stale comments;
- keep `NativeImageNeedsRawDecode` until a separate naming cleanup is approved.

### Phase 4 — Closure

- Run the full cross-platform corpus and build gates.
- Re-register only intentionally changed frozen tests.
- Update handovers and architecture memory to describe the Dart producer and five-platform decoder requirement.

## Acceptance criteria

### Shared contract

For the same file and requested long edge, all five targets must agree on:

- selected embedded candidate and returned bytes;
- cheap versus expensive classification;
- orientation and output dimensions;
- deferred versus executed state;
- decoder call count;
- terminal success or malformed/unreadable failure; and
- M5 full-resolution availability.

### Required corpus

At minimum:

- embedded-preview DNG with multiple candidates;
- preview smaller than requested long edge;
- preview-less valid DNG;
- little- and big-endian TIFF/DNG;
- orientation 1–8, absent, invalid, and existing JPEG EXIF orientation;
- truncated headers and out-of-bounds offsets;
- decoder initialization failure and decode error negative tests; and
- JPEG/non-DNG regression samples.

### Mechanical gates

- Embedded path: zero RAW decodes, zero platform-channel calls, zero re-encodes.
- Deferred path: zero decoder calls.
- Expensive path: exactly one decoder call and one orientation transform.
- M5 full-resolution output comes from that same decode.
- Every supported target builds with the decoder packaged and passes a real-file smoke test.
- A preview-less canonical DNG visibly renders on macOS, Windows, Android, iOS, and Linux.
- Production has zero dependencies on `NO_EMBEDDED_PREVIEW` and `allowRawDecodeSignal` before those symbols are deleted.
- Swift extractor call sites are zero before deleting the file.

### Performance gates

- Dart embedded extraction must remain within the preregistered 2× baseline.
- A selected embedded preview must meet the requested long edge. If none does, the request must enter RAW decode instead of returning an undersized final image; Swift candidate dimensions are not the oracle.
- Metadata reads remain bounded; no whole-file DNG slurp.
- Failure means optimise Dart and re-run the gate. It never permits restoring a macOS-only accelerator.

## Testing strategy

1. **Pure Dart unit tests:** parser bounds, candidate selection, orientation, hit/miss/failure distinction.
2. **PhotoSource contract tests:** deferred zero-decode, executed exactly-once decode, failure mapping, M5 full-resolution reuse.
3. **Bridge-negative tests:** production DNG routes succeed while native thumbnail handlers are absent or configured to fail if called.
4. **FFI integration tests:** identical real-file corpus on each supported target, checking dimensions, orientation, pixel checksum, and decode count.
5. **Packaging tests:** release artifacts contain and load the decoder library on all five targets.
6. **Performance artifacts:** cold/warm p50/p95, bounded read volume, output dimensions, and captured exit codes.

## Out of scope

- Web support.
- Rewriting the RAW decoder algorithm in Dart.
- HEIC support.
- Non-DNG RAW formats without an embedded preview.
- Rename of `NativeImageNeedsRawDecode`.
- General UI redesign or unrelated platform-integration work.

## Risks

- iOS and Linux FFI packaging may be larger than the original cleanup milestone; this is accepted because five-platform image output is a terminal requirement.
- Dart extraction can regress latency or block the isolate; the response is to optimise the bounded Dart implementation, not restore Swift.
- Existing M6 documents and partially completed commits encode an older platform-demotion rule; they must be reconciled before closure to avoid testing the wrong contract.
- Pixel checksums can expose platform-specific decoder drift; any tolerated variance must be explicitly approved rather than silently weakening the parity rule.

## Completion definition

M6 is complete only when the Dart path owns every DNG semantic decision, valid preview-less DNGs render on all five supported targets through the cross-platform FFI decoder, and the macOS/Windows native DNG policy paths have been removed. File deletion alone is not completion, and no supported target may close with an `unsupported` outcome for a valid DNG.
