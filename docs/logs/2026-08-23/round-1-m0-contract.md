# Round 1 — M0 Convergence Contract (FROZEN)

> Frozen 2026-08-23 06:35 by the orchestrator. **Only the user may change this document.**
> Source of truth for scope: `docs/logs/2026-08-23/image-pipeline-redesign-handover.md` §6 "M0 — 抽取器".
> Worktree: `/Users/jhangyu/project/halcyon-m0` (branch `m0-extractor`, based on `48bb934`).

## Terminal state (one sentence)

`DngPreviewExtractor` selects an embedded JPEG **by requested long edge**, reads it via
**bounded byte-range disk reads instead of loading the whole file**, and returns the IFD0
orientation from the **same single walk** — with today's full-size behaviour byte-identical.

## In scope

| # | Deliverable | Owner |
|---|---|---|
| W1 | Rewrite `lib/services/dng_preview_extractor.dart`: random-access/byte-range reads, `longEdge` candidate selection, orientation returned from the single walk, `readOrientationFromFile` deleted | `extractor-impl-1-opus` |
| W2 | New test file `test/dng_preview_extractor_m0_test.dart` asserting AC2–AC7 below, written against the frozen API in §"Frozen API" **before** W1 lands (red→green evidence required) | `extractor-impl-2-sonnet` |

## Out of scope (do NOT touch this round)

- `lib/services/image_preload_controller.dart` — its existing call site at `:661` must keep compiling and behaving identically, but the file itself is **not edited**.
- Any `macos/`, `windows/`, `linux/`, `android/` file. `DngPreviewExtractor.swift` stays.
- `test/dng_preview_extractor_test.dart` — **frozen, not one character**. It is the behaviour-preservation oracle.
- `test/dng_extractor_swift_test.dart`, `scripts/tmp/dng_extractor_tests.swift`, `scripts/tmp/fixtures/*` — the Swift suite and its `0.90 * cropMax` rejection assertion stay exactly as they are.
- M1–M6 work of any kind. `PhotoSource`, `PhotoPayloadCache`, `PrefetchScheduler` do not exist yet.
- `memory.md`, `task.md`, `unit_test.md`, `CLAUDE.md` — the orchestrator updates docs at round close.

## Frozen API (the interface contract; W2 codes against this before W1 exists)

```dart
/// Result of a single IFD walk: the selected embedded JPEG plus the metadata
/// that walk already had in hand.
class DngEmbeddedJpeg {
  const DngEmbeddedJpeg({
    required this.bytes,
    required this.width,
    required this.height,
    required this.orientation,
  });

  /// JPEG bitstream, with EXIF orientation injected exactly as today when
  /// `orientation != 1` and the bitstream does not already declare one.
  final Uint8List bytes;
  final int width;
  final int height;
  /// IFD0 tag 0x0112 as read; 1 when absent.
  final int orientation;
}

class DngPreviewExtractor {
  /// Selects an embedded JPEG from [path].
  ///
  /// [longEdge] == null  -> full-size request: TODAY'S EXACT RULE, unchanged.
  ///                        Candidate must satisfy maxDim >= 0.90 * cropMax;
  ///                        largest area wins.
  /// [longEdge] != null  -> the SMALLEST candidate whose max(width, height)
  ///                        >= longEdge. The 0.90 * cropMax floor does NOT
  ///                        apply. If no candidate reaches longEdge, the
  ///                        LARGEST available candidate is returned.
  ///
  /// [onDiskRead] is invoked once per physical read with the byte count read;
  /// it exists so tests can assert the byte-range budget. Never throws.
  static Future<DngEmbeddedJpeg?> extractEmbeddedJpeg(
    String path, {
    int? longEdge,
    void Function(int byteCount)? onDiskRead,
  });

  /// Unchanged signature and unchanged behaviour. Thin wrapper over
  /// extractEmbeddedJpeg(path, longEdge: null).
  static Future<Uint8List?> extractFullSizeEmbeddedJpegFromFile(String path);

  /// Unchanged. In-memory variants stay for the frozen legacy tests.
  static Uint8List? extractFullSizeEmbeddedJpeg(Uint8List data);
  static int readDngOrientation(Uint8List data);

  // DELETED this round: readOrientationFromFile(String path).
  // It has zero callers in lib/ and zero tests; its job is now covered by
  // DngEmbeddedJpeg.orientation from the single walk.
}
```

## Acceptance criteria (mechanically checkable; verbatim, not to be re-worded)

Baseline recorded before any edit: `flutter analyze` = "No issues found!";
`flutter test -j 1 test/dng_preview_extractor_test.dart test/dng_extractor_swift_test.dart`
= exit 0, "All tests passed!", **25 tests**.

| AC | Condition | How it is checked |
|---|---|---|
| **AC1** | `test/dng_preview_extractor_test.dart` is byte-identical to `48bb934` and its 24 tests still pass; the Swift-suite test still passes. Total for those two files stays **25 passed, exit 0**. | `git diff 48bb934 -- test/dng_preview_extractor_test.dart` is empty; `flutter test -j 1 <both files>` exit 0 + "All tests passed!" + "+25" |
| **AC2** | `extractEmbeddedJpeg('local_data/photo_samples/DNG/2026-02-15-19-37-38.dng', longEdge: 200)` returns width 256, height 171, `bytes.length == 9525`, orientation 1. | assertion in the new test file |
| **AC3** | For each of the 13 preview-bearing samples, `extractEmbeddedJpeg(path, longEdge: 2800)!.bytes` is **byte-identical** (length + SHA-256 or element-wise equality) to `extractFullSizeEmbeddedJpegFromFile(path)` on the same file. | assertion in the new test file |
| **AC4** | Byte budget: for every one of the **14** `.dng` files in `local_data/photo_samples/DNG/`, at `longEdge: 200`, the sum of `onDiskRead` byte counts is `<= selectedCandidateByteCount + 300_000`, and for `IMG_20251112_092839.dng` (25,192,232 bytes, no candidate) the sum is `< 300_000`. The test enumerates `*.dng` and asserts the count is exactly **14**, so a vanished sample fails loudly instead of passing vacuously. | assertion in the new test file |
| **AC5** | `extractEmbeddedJpeg('.../2026-08-07-17-52-54.dng', longEdge: 200)` returns the 6000x4000 candidate (only candidate present) with `orientation == 6` and an injected APP1 marker at bytes[2..3] == 0xFF,0xE1. | assertion in the new test file |
| **AC6** | `extractEmbeddedJpeg('.../IMG_20251112_092839.dng', longEdge: 200)` returns null; a nonexistent path returns null; a plain-JPEG file returns null. No throw in any case. | assertion in the new test file |
| **AC7** | The whole file is never slurped: `grep -c "readAsBytes()" lib/services/dng_preview_extractor.dart` == **0** for the file-reading path, and `grep -c "readOrientationFromFile" lib/` == **0**. | orchestrator grep |
| **AC8** | `flutter analyze` = "No issues found!" | test-runner |
| **AC9** | Full suite `flutter test -j 1` exit 0, declared test count == executed test count, "All tests passed!" | test-runner |
| **AC10** | The new test file was seen RED before it was seen green: a saved run showing AC2–AC6 failing against the pre-W1 extractor, and a saved run showing them passing after. | two artefact files under `scripts/tmp/verify/` |

## AC11 — added 2026-08-23 by USER DECISION after the reviewer found a false premise

The contract's §"Frozen API" justified deleting `readOrientationFromFile` with "its job is now
covered by `DngEmbeddedJpeg.orientation`". **That was false.** For a DNG with no embedded JPEG
— the exact case `NativeImageNeedsRawDecode` exists to represent — `extractEmbeddedJpeg`
returns `null`, so there is no `DngEmbeddedJpeg` and no orientation. The only surviving route
was `readDngOrientation(Uint8List)`, i.e. slurping the whole 25 MB file, which is the behaviour
M0 exists to delete. The AC7 doc-comment rewrite made this worse, not better: it replaced a
comment naming a deleted method with a comment describing a route that cannot work.

Remedy: restore the capability on the new byte-range reader, so it is strictly cheaper than
48bb934 rather than merely restored.

```dart
/// IFD0 tag 0x0112 for [path], read through the same bounded byte-range walk.
/// Returns 1 when the tag is absent or the file cannot be parsed. Never throws.
/// Works whether or not the file carries an embedded JPEG.
static Future<int> readOrientation(
  String path, {
  void Function(int byteCount)? onDiskRead,
});
```

| AC | Condition | How it is checked |
|---|---|---|
| **AC11a** | `readOrientation('local_data/photo_samples/DNG/2026-08-07-17-52-54.dng')` == **6**. This is the discriminating case: 6 is not the failure default, so a stubbed or broken implementation cannot pass it. | assertion in the M0 oracle |
| **AC11b** | `readOrientation('local_data/photo_samples/DNG/IMG_20251112_092839.dng')` == 1 **and** the summed `onDiskRead` byte count is `< 300_000` against a 25,192,232-byte file. This is the load-bearing case — no embedded preview, and it must be cheap. | assertion in the M0 oracle |
| **AC11c** | A nonexistent path returns 1 and does not throw. | assertion in the M0 oracle |
| **AC11d** | `lib/services/native_thumbnail_service.dart` names `readOrientation` truthfully, or names nothing at all. `grep -c "DngEmbeddedJpeg.orientation" lib/services/native_thumbnail_service.dart` == 0. | orchestrator grep |
| **AC11e** | Mutation: make `readOrientation` return the default 1 unconditionally; AC11a must go RED. Revert, hashes before/after must match. | three artefacts |

## AC12 — added 2026-08-23 by USER DECISION after the AC11 delta review

Root cause of N1: `readOrientation` returns `1` for two different things — "the file says no
rotation" and "I could not read the file". One value, two meanings, so no assertion can tell a
working implementation from one that gave up. Splitting them is the fix; the N1 fixture is the
belt to that braces.

### A12.1 — split the return value

`readOrientation` becomes `Future<int?>`:

| Situation | Returns |
|---|---|
| File missing, unopenable, shorter than 8 bytes, no `II`/`MM` marker, magic != 42, IFD0 offset unreadable, IFD0 malformed, or any exception | **`null`** — could not determine |
| IFD0 parsed, tag 0x0112 absent | **`1`** — genuinely no rotation (EXIF default) |
| IFD0 parsed, tag 0x0112 present | **its value** |

**`readDngOrientation(Uint8List)` MUST NOT CHANGE.** It keeps returning `int` with `1` on
failure. `test/dng_preview_extractor_test.dart:158-163` asserts exactly that, and AC1 forbids
touching that file. Changing both "for consistency" fails AC1 and fails the round.

### A12.2 — N1 fixture

The gate AC11 was created for, asserted on the axis that actually matters (large file +
non-default value), not on the co-varying one (preview presence).

### A12.3 — N4

Fix the ragged comment wrap at `lib/services/native_thumbnail_service.dart:57-58`. Cosmetic.

### Not doing: N2, N3 — USER DECISION

N2 (unclamped return vs the "range 1..8" prose) and N3 (duplicate IFD0 walk) are **dropped, not
parked**. Do not implement them, do not carry them forward as debt.

| AC | Condition | How it is checked |
|---|---|---|
| **AC12a** | A nonexistent path returns **`null`**, not 1, and does not throw. Replaces AC11c. | assertion in the oracle |
| **AC12b** | A file that parses but carries no 0x0112 tag returns **`1`**. Craft it if no sample qualifies. This is what proves the split is real rather than "null for everything that is not a hit". | assertion in the oracle |
| **AC12c** | Garbage that is not a TIFF container at all (e.g. a plain JPEG, a zero-byte file) returns **`null`**. | assertion in the oracle |
| **AC12d** | **The N1 fixture.** Copy `local_data/photo_samples/DNG/IMG_20251112_092839.dng` (25,192,232 bytes, no embedded preview) to a temp path, patch IFD0 tag 0x0112 to **6**, and assert `readOrientation` returns **6** with summed `onDiskRead` `< 300_000`. Delete the temp copy afterwards. Large file AND non-default value in one assertion. | assertion in the oracle |
| **AC12e** | `readDngOrientation(Uint8List)` still returns `int`, still returns `1` for malformed input, and `test/dng_preview_extractor_test.dart` is still byte-identical to 48bb934. | AC1 re-check |
| **AC12f** | `lib/services/native_thumbnail_service.dart` describes the new `int?` semantics truthfully — null means undetermined — or says nothing about the return type. N4's wrap fixed in the same edit. | orchestrator read, not grep |
| **AC12h** | **Tag present but unreadable → `null`.** A 0x0112 entry whose value field cannot be resolved (bad type, count 0, offset past EOF) is "found it, could not read it" — undetermined, not "no rotation". Required shape: `_orientationOf` returns `int?`, `readOrientation` propagates it, and `readDngOrientation` ends with `?? 1` so its observable behaviour is provably unchanged. Gate: craft such a file and assert **both** in one test — `readOrientation(path)` is `null` **and** `readDngOrientation(bytes)` is `1`. That single assertion proves the split and proves the legacy path did not move. | assertion in the oracle |
| **AC12g** | Mutation, two mutants, both required: **(i)** `readOrientation` returns `null` unconditionally → AC12b and AC12d must both go RED. **(ii)** `readOrientation` returns `1` unconditionally → AC12a, AC12c and AC12d must all go RED. Revert after each; hashes before/after must match. | six artefacts |

Mutant (ii) is the point of the whole amendment: under the old `int` signature that mutant
passed every gate. If it does not go red now, the split bought nothing.

## Parked by USER DECISION — not gates this round

F2 (I/O amplification to 199% of file size on a crafted 5,000-SubIFD container), F3
(`_MemorySource.read` returns a `sublistView` where 48bb934 returned a `sublist` copy, pinning
the whole source buffer; no live consumer in `lib/`), F4 (`byteCount <= 0` candidates now
skipped rather than selected-then-aborted; differs from 48bb934 only on crafted input), F5, F6.
All recorded in the round handoff. The next round decides whether any becomes a gate.

## Round budget

3 rounds max for M0. Budget consumed only by fix cycles after a REFUTED review verdict.

## Parking lot

Anything discovered this round that is not an AC above goes here and is reported to the
user at round close. It does not become an acceptance condition, does not jump the queue.
Sole exception: an R3 trigger (security hole, false premise, irreversible risk) — escalate
immediately.

- (empty at freeze)
