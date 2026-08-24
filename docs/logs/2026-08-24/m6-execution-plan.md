# M6 Cross-Platform Parity Implementation Plan

> **For agentic workers:** Execute task-by-task; each task ends with an independently verifiable deliverable. Steps use checkbox (`- [ ]`) syntax for tracking. Workers see only their own task plus the header — the **Interfaces** blocks are how neighbouring tasks' names and types are learned.

**Goal:** Halcyon's photo behaviour (which files load, what pixels appear, what a delete does, what an export produces) is implemented once in Dart and produces the same observable result on every supported platform; native runners keep app shell, window plumbing, and the enumerated exceptions only (Trash F-12, Open With transport F-16, file association F-18).

**Architecture:** `PhotoSource` becomes the byte source for all three purposes (detail view, sidebar, export). The production `NativeImageLoad` seam implementation moves from the `halcyon/thumbnail` MethodChannel to a new pure-Dart producer (`dart_image_loader.dart`) built on `DngPreviewExtractor`; the seam itself is kept as the test-injection point. Native image/EXIF paths are deleted only after the benchmark gate loop closes (P-8: optimise and re-gate on FAIL, never keep a macOS-only path).

**Tech Stack:** Flutter 3.35.1 / Dart ^3.9.0, `dng_processor_ffi` (FFI RAW decode; macOS/Windows/Android only), `exif` package (isolate fallback), to be added: `image` (pure-Dart export encode), `desktop_drop` (F-17), Android/iOS Open-With handler package (F-16, candidate `open_file_handler` — verify before adopting).

**Spec:** `docs/logs/2026-08-24/m6-feature-platform-matrix.md` (MASTER — per-item RULED verdicts), `docs/logs/2026-08-24/m6-spec-contract.md` (contract C-1…C-8, design shape §2.1, evidence §3). Update flow: matrix first, then sync this plan and the spec.

## Global Constraints

Copied verbatim from `m6-spec-contract.md` §1 (every task implicitly includes these):

- **C-2 parity rule:** No behaviour may exist on a subset of the supported platform set. Declared exceptions (closed list, nothing else may cite them as precedent): F-12 system Trash (mac+win native), F-16 Open With (macOS/Windows/Android/iOS; Linux excluded), F-18 file association (Windows+macOS).
- **C-3:** `Platform.isX`, `kIsWeb`, `defaultTargetPlatform`, conditional imports, shelled-out platform binaries are forbidden in `lib/`. Enumerated exception: the one F-19 reveal site may use `Process.run` with per-platform commands, awaited error handling, excluded from the grep guard by file.
- **C-4:** A test asserting single-platform semantics is deleted with its reason recorded; frozen-file seal lifted only for those tests; new sha256 re-registered in the same commit (`baseline-registry.md`).
- **C-5 / P-8:** Gate runs before any native deletion. On FAIL: optimise and re-gate — never keep the Swift path.
- **C-6 scope-out:** no new features, no UI redesign, no `dng_processor_ffi` native build work beyond declaring needs (P-2), **no UI latency or memory measurement by agents** (user-run only).
- **C-7:** parking-lot discipline — findings during a round do not become acceptance criteria for that round.
- **C-8 / P-1:** per-feature preference cascade — all platforms > mac/win/linux/android > mac/win/linux > mac/win minimum; structural blockers demote per feature, not globally.
- **House rules:** every verification command's exit code self-captured as `RC=$?` inside the artifact on the next line; rewritten/new tests must be seen red before green; commits follow Conventional Commits; two agents never edit the same file concurrently; no full-tree git ops (`stash`/`reset`/`checkout --`/`clean`); the tree carries an external ` D docs/logs/2026-08-24/m6-rederivation-handover.md` — do not touch or restore it.

## Phase-1 gate outcomes this plan is built on (measured 2026-08-24, task #2 signed off)

- **G1/V1 PASS** (same-isolate Dart extraction; median ratio 0.580, worst 1.542) → all extraction call sites in this plan use the **same-isolate V1 variant**. G1/V2 (per-call `Isolate.run`) FAIL by one sample at 2.111×. **UI-jank question RESOLVED (2026-08-24 5th pass, user, matrix P-9): synchronous read accepted.**
- **G2 FAIL** (JPEG `File.readAsBytes` 2.3–9.2× slower than native passthrough; bytes/dims identical; absolute worst 0.506 ms) → **RESOLVED (2026-08-24 5th pass, user, matrix P-10): sub-millisecond gap accepted.** The Dart read path ships as-is; G2 is closed and needs NO re-gate — P2.6 is G3′-only.
- **G3 HARD FAIL is an instrument-route artifact:** the pre-registered Dart route used the full-size entry point; the 13 nulls are exactly the no-full-preview DNGs whose small thumbnail `extractEmbeddedJpeg(path, longEdge: 200)` is documented to find. The JPEG 16× latency gap is real (full decode vs DCT-scaled decode) and is addressed by decode-time downscale (`instantiateImageCodecWithSize` long-edge cap) in Task P2.5, then re-gated in Task P2.6. Artifacts: `scripts/tmp/20260824T084906Z-m6-g1.txt`, `…085119Z-m6-g2.txt`, `…085320Z-m6-g3.txt`.

## Task index

- **P2 — unified Dart byte source (additive; nothing deleted):**
  P2.1 pure-Dart producer `dart_image_loader.dart` (F-04/F-06/F-07 core) · P2.2 non-DNG RAW coverage in the producer + `fallbackAfterNativeFailure` de-extension-gating (F-08) · P2.3 composition-root switch + bridge-free tests (ACs 4/5) · P2.4 sidebar 200 px source through the producer (F-10, half 1: bytes) · P2.5 sidebar decode-time long-edge downscale (F-10, half 2: pixels) · P2.6 gate re-run G2′/G3′ against the shipped routes (P-8 loop) · P2.7 phase verification batch + commit
- **P3 — deletion sweep + convergence (gated on P2.6 PASS):**
  P3.1 macOS thumbnail/EXIF native deletion · P3.2 Windows `halcyon_image.cpp` deletion · P3.3 Dart channel-service reduction + affected-test rewrite · P3.4 F-14 EXIF isolate-only · P3.5 F-05 HEIC removal + preference-bug fix · P3.6 F-11 export via `image` package · P3.7 F-20 oversized-image guard · P3.8 phase verification batch (incl. release build) + commit
- **P4 — OS integration:** P4.1 F-17 `desktop_drop` · P4.2 F-19 reveal-in-file-manager · P4.3 F-24 non-pointer recycle entry · P4.4 F-18 Windows file association · P4.5 F-16 Open With mobile wiring · P4.6 phase verification + commit
- **P5 — closure:** P5.1 F-25 cache budget · P5.2 test re-baseline audit (C-4, registry) · P5.3 post-merge verification + full G re-run

Round review after each phase (task list #4/#6/#8): one reviewer, correctness + negative-space, max 2 review→fix cycles, no new acceptance criteria.

## Execution status ledger (R1, as of 2026-08-24 session 2 close — every row lead-signed against artifacts)

| Plan task | Status | Commit(s) | Notes |
|---|---|---|---|
| Phase 0 errata | ✅ signed off | 13023aa | AD-010 erratum + 2 comment fixes |
| Phase 1 gates G1/G2/G3 | ✅ signed off | — (artifacts `scripts/tmp/20260824T08*-m6-g*.txt`) | G1/V1 PASS; G2 FAIL→accepted (P-10); G3 chain → P-13 |
| P2.1 producer | ✅ | 90ca085 | + lead-approved NOT_FOUND guard |
| P2.2 F-08 | ✅ | 7b1678a | + Step-2b C-4 inverted-test ruling |
| P2.3 root switch | ✅ | 1d1fb74, 03ebd40 | AC4/AC5 tests in `test/m6_bridge_free_test.dart` |
| P2.4 sidebar proof | ✅ | 318840a | Appendix-B premise was stale; net-new proof test |
| P2.5 sidebar codec | ✅ | c422571 | |
| P2.5b RAW fallback | ✅ | ce7983a | P-12 ruling; sized FFI decode |
| P2.6 gate re-run | ✅ CLOSED | — (G3′/G3″/G3‴ artifacts) | PASSED by P-13 ruling (75 ms floor) |
| P2.7 exit batch | ✅ | — (`p2-exit.txt`) | 269-count bank; C-3 grep clean |
| P2 round review | ✅ MERGEABLE | 251f3fb (blocker fix) | generation guard + NOT_FOUND hoist |
| P3.5 HEIC | ✅ | 68308c4 | + supported-first fallback (review-flagged, accepted) |
| P3.6 export | ✅ | dd1edcb | + P-14 EXIF restore in 2f01a6b |
| P3.7 guard | ✅ | d2c4469 | |
| P3.1 macOS deletion | ✅ | ce5a81c | + ratified EXPORT-CORE scope expansion; build green |
| P3.2 Windows deletion | ✅ | 12a98df | + ratified halcyon_native.h cleanup |
| P3.3 Dart reduction | ✅ | 3a7a2b2, 86d12ee | types → `image_source_types.dart`; U-12 in effect |
| P3.4 EXIF isolate-only | ✅ | 36dfc37 | channel constant deleted (AC-over-sample ruling) |
| P3.8 exit batch | ✅ | 476a2f0 | 271/271 reconciled; macOS+Android builds green |
| P3 round review | ✅ MERGEABLE (2/2 cycles) | 2f01a6b (EXIF fix) | oracle probe 8/8; independent Orientation verify |
| P4.1 desktop_drop | ✅ (R2) | 8455772 | + review fix b7ece89 (DropTarget disabled under modal routes) |
| P4.2 reveal | ✅ (R2) | 2283e45 | + review fix cad41b1 (explorer exit-code quirk; single-arg `/select,`) |
| P4.3 R-key recycle | ✅ (R2) | 532570f | tooltips updated |
| P4.4 Win association | ✅ (R2) | bd62aeb | + eb7ea91 (REG_EXPAND_SZ) + eee83a5 (CRLF); registry route, MSIX rejected; TOFU on a real Windows host |
| P4.5 Open With mobile | ✅ (R2) | 4e71cad | + review fix 43a078c (image/* filter, BROWSABLE dropped); flow parked on F-02 |
| P4.6 exit batch | ✅ (R2) | — (`p4-exit.txt`) | 278/278; mac+android builds green; C-3 greps clean |
| P4 round review | ✅ MERGEABLE (2/2 cycles) | — (`round-p4-review.md`) | 0 blockers; 4 should-fix all fixed in-round; nits/parking-lot recorded |
| P5.1 cache budget | ✅ (R2) | c20e0ce | seam only; no platform-neutral memory API exists (honest default) |
| P5.2 re-baseline audit | ✅ (R2) | bcc5cba, 8418c7e | Appendix B 10/10 verified; AD-020 + G-015; TC-120 renumber (was colliding TC-049) |
| P5.3 final verify + G″″ | ✅ (R2) | — (`p5-3-verify.txt`, `g3-regress-p53.txt`) | 280/280 @ 8418c7e; regression gate 33/33 PASS (bare-CFA samples improved to 31.6–63.1 ms, all under the 75 ms floor); final closure = USER |

---

## P2.1 Pure-Dart producer: `dart_image_loader.dart` (F-04, F-06, F-07 core)

**Files:**
- Create: `lib/services/dart_image_loader.dart`
- Test: `test/dart_image_loader_test.dart`

**Interfaces:**
- Consumes: `DngPreviewExtractor.extractFullSizeEmbeddedJpegFromFile(path)` (`dng_preview_extractor.dart:87`, returns `Future<Uint8List?>`, never throws), `DngPreviewExtractor.extractEmbeddedJpeg(path, {int? longEdge})` (`:60`, returns `Future<DngEmbeddedJpeg?>` with `.bytes/.width/.height/.orientation`), `DngPreviewExtractor.readOrientation(path)` (`:109`, `Future<int?>`, null = could-not-read), `NativeImageResult` variants + `ImageRequestPurpose` + `kDefaultExifOrientation` (`native_thumbnail_service.dart:4-79`).
- Produces: **`Future<NativeImageResult> dartImageLoad(String path, {required ImageRequestPurpose purpose})`** — a top-level function structurally matching the `NativeImageLoad` seam (`photo_source.dart:76-80`). P2.3 injects it at the composition root; P2.4 relies on its `sidebarThumbnail` branch; P3.6 reuses its full-size branch for export bytes.

Behaviour contract (mirrors the native producer's invariants — the sidebar's permanent-miss logic at `image_preload_controller.dart:1179-1196` depends on never seeing the raw-decode signal for `sidebarThumbnail`):
- `.jpg/.jpeg/.png` → `NativeImageBytes(File(path).readAsBytes())` (F-04; Flutter's codec honours EXIF).
- TIFF-container files, `purpose == sidebarThumbnail` → `extractEmbeddedJpeg(path, longEdge: 200)` (smallest candidate ≥ 200, falls back to largest — the G3-correct route); null → `NativeImageFailure('NO_THUMBNAIL', …)`.
- TIFF-container files, other purposes → `extractFullSizeEmbeddedJpegFromFile`; hit → bytes (F-06); miss on a `.dng` with `purpose == preview` → `NativeImageNeedsRawDecode(exifOrientation: readOrientation(path) ?? kDefaultExifOrientation)` (F-07, ruling b); miss otherwise → `NativeImageFailure('RAW_NO_EMBEDDED_PREVIEW', …)` (F-08's explicit unsupported state, U-11).
- Never throws: any exception → `NativeImageFailure('DART_LOADER_ERROR', '$e')`.
- Known interim state: `.heic` falls into the TIFF branch, fails the magic check and becomes an explicit failure from the moment P2.3 switches production — this is the ruled F-05 end-state arriving early; P3.5 removes HEIC from the supported set. Any test asserting HEIC preview via channel mocks is rewritten under Appendix B in P3.3.

- [ ] **Step 1: Write the failing test**

`test/dart_image_loader_test.dart` — real samples per repo red line (photos only from `local_data/photo_samples/DNG/`, pattern of `test/dng_preview_extractor_test.dart:19-34`):

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/services/dart_image_loader.dart';
import 'package:halcyon_flutter/services/dng_preview_extractor.dart';
import 'package:halcyon_flutter/services/native_thumbnail_service.dart';

void main() {
  final sampleDir = Directory('local_data/photo_samples/DNG');
  List<File> dngs() => sampleDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.dng'))
      .toList();

  test('jpeg returns its exact bytes without decoding', () async {
    final dir = await Directory.systemTemp.createTemp('dart_image_loader');
    addTearDown(() => dir.delete(recursive: true));
    final jpeg = File('${dir.path}/a.jpg');
    await jpeg.writeAsBytes(const [0xFF, 0xD8, 0xFF, 0xD9]); // SOI+EOI only
    final result =
        await dartImageLoad(jpeg.path, purpose: ImageRequestPurpose.preview);
    expect(result, isA<NativeImageBytes>());
    expect((result as NativeImageBytes).bytes, const [0xFF, 0xD8, 0xFF, 0xD9]);
  });

  test('preview-bearing DNGs return exactly the extractor bytes', () async {
    var covered = 0;
    for (final f in dngs()) {
      final expected =
          await DngPreviewExtractor.extractFullSizeEmbeddedJpegFromFile(f.path);
      if (expected == null) continue;
      covered++;
      final result =
          await dartImageLoad(f.path, purpose: ImageRequestPurpose.preview);
      expect(result, isA<NativeImageBytes>(), reason: f.path);
      expect((result as NativeImageBytes).bytes, expected, reason: f.path);
    }
    expect(covered, greaterThan(0), reason: 'sample set must exercise the hit path');
  });

  test('no-preview DNGs yield NeedsRawDecode with the walked orientation', () async {
    var covered = 0;
    for (final f in dngs()) {
      final full =
          await DngPreviewExtractor.extractFullSizeEmbeddedJpegFromFile(f.path);
      if (full != null) continue;
      covered++;
      final result =
          await dartImageLoad(f.path, purpose: ImageRequestPurpose.preview);
      expect(result, isA<NativeImageNeedsRawDecode>(), reason: f.path);
      final walked = await DngPreviewExtractor.readOrientation(f.path);
      expect((result as NativeImageNeedsRawDecode).exifOrientation,
          walked ?? kDefaultExifOrientation, reason: f.path);
    }
    expect(covered, greaterThan(0), reason: 'sample set must exercise the miss path');
  });

  test('sidebar purpose never returns the raw-decode signal', () async {
    for (final f in dngs()) {
      final result = await dartImageLoad(f.path,
          purpose: ImageRequestPurpose.sidebarThumbnail);
      expect(result is! NativeImageNeedsRawDecode, isTrue, reason: f.path);
    }
  });

  test('missing file is a failure, not a throw', () async {
    final result = await dartImageLoad('/nonexistent/x.dng',
        purpose: ImageRequestPurpose.preview);
    expect(result, isA<NativeImageFailure>());
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `flutter test test/dart_image_loader_test.dart 2>&1 | tail -5; echo RC=$?` (artifact: `scripts/tmp/m6-r1-verify/p2-1-red.txt`)
Expected: FAIL — `Error: Couldn't resolve the package 'halcyon_flutter/services/dart_image_loader.dart'` (file does not exist yet).

- [ ] **Step 3: Implement `lib/services/dart_image_loader.dart`**

```dart
import 'dart:io';

import 'dng_preview_extractor.dart';
import 'native_thumbnail_service.dart';

/// Pure-Dart production implementation of the `NativeImageLoad` seam
/// (photo_source.dart:76-80). Replaces the `halcyon/thumbnail` channel as the
/// production byte producer (M6 C-1/C-2); the channel service remains only
/// until P3 deletes it. Free of Platform checks by construction (C-3).
///
/// Invariants carried over from the native producer:
/// - [NativeImageNeedsRawDecode] is emitted ONLY for
///   `purpose == ImageRequestPurpose.preview` on a `.dng`; the sidebar's
///   permanent-miss logic (image_preload_controller.dart:1179-1196) depends
///   on never seeing it for sidebarThumbnail.
/// - Never throws: every failure is a [NativeImageFailure].
Future<NativeImageResult> dartImageLoad(
  String path, {
  required ImageRequestPurpose purpose,
}) async {
  final lower = path.toLowerCase();
  final isEncodedBitstream = lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.png');
  try {
    if (isEncodedBitstream) {
      return NativeImageBytes(await File(path).readAsBytes());
    }
    if (purpose == ImageRequestPurpose.sidebarThumbnail) {
      // Smallest embedded candidate reaching the sidebar edge (G3 finding:
      // the full-size entry point wrongly refuses small-thumbnail DNGs).
      final candidate = await DngPreviewExtractor.extractEmbeddedJpeg(
        path,
        longEdge: purpose.targetSize,
      );
      return candidate == null
          ? const NativeImageFailure('NO_THUMBNAIL', 'no embedded candidate')
          : NativeImageBytes(candidate.bytes);
    }
    final full =
        await DngPreviewExtractor.extractFullSizeEmbeddedJpegFromFile(path);
    if (full != null) return NativeImageBytes(full);
    if (purpose == ImageRequestPurpose.preview && lower.endsWith('.dng')) {
      // Ruling (b): the raw-decode signal is constructed in Dart from an
      // extraction miss + the walker's own orientation read.
      final orientation = await DngPreviewExtractor.readOrientation(path);
      return NativeImageNeedsRawDecode(
        exifOrientation: orientation ?? kDefaultExifOrientation,
      );
    }
    // Non-DNG RAW (or any non-TIFF) with no embedded preview: the explicit
    // uniform unsupported state (matrix F-08, accepted loss U-11).
    return const NativeImageFailure(
      'RAW_NO_EMBEDDED_PREVIEW',
      'no embedded preview and no decoder for this format',
    );
  } catch (e) {
    return NativeImageFailure('DART_LOADER_ERROR', '$e');
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `flutter test test/dart_image_loader_test.dart 2>&1 | tail -3; echo RC=$?` (append to the same artifact)
Expected: `All tests passed!`, `RC=0`.

- [ ] **Step 5: Commit**

```bash
git add lib/services/dart_image_loader.dart test/dart_image_loader_test.dart
git commit -m "feat(m6): pure-Dart image producer for the NativeImageLoad seam (F-04/F-06/F-07)"
```

## P2.2 Non-DNG RAW through the same walker (F-08)

**Files:**
- Modify: `lib/services/photo_source.dart:364-367` (`fallbackAfterNativeFailure`)
- Test: `test/dart_image_loader_test.dart` (extend), `test/photo_source_test.dart` (one added case)

**Interfaces:**
- Consumes: P2.1's `dartImageLoad` (behaviour already covers non-DNG RAW via the extension-blind walker — `photo_source.dart:300-301`: the walker keys on TIFF magic, never the extension).
- Produces: `PhotoSource.fallbackAfterNativeFailure(path)` loses its `.dng`-only gate; signature unchanged (`static Future<Uint8List?>`).

- [ ] **Step 1: Write the failing tests**

Append to `test/dart_image_loader_test.dart` (a real DNG copied under a non-DNG RAW extension is a byte-identical TIFF container — exactly what a `.arw/.nef` is for the walker):

```dart
  test('non-DNG RAW: embedded preview is served, no-preview is an explicit'
      ' unsupported state (never the raw-decode signal)', () async {
    final dir = await Directory.systemTemp.createTemp('dart_image_loader_raw');
    addTearDown(() => dir.delete(recursive: true));
    var hits = 0, misses = 0;
    for (final f in dngs()) {
      final full =
          await DngPreviewExtractor.extractFullSizeEmbeddedJpegFromFile(f.path);
      final asArw = File('${dir.path}/${f.uri.pathSegments.last}.arw');
      await f.copy(asArw.path);
      final result =
          await dartImageLoad(asArw.path, purpose: ImageRequestPurpose.preview);
      if (full != null) {
        hits++;
        expect(result, isA<NativeImageBytes>(), reason: asArw.path);
      } else {
        misses++;
        expect(result, isA<NativeImageFailure>(), reason: asArw.path);
        expect((result as NativeImageFailure).code, 'RAW_NO_EMBEDDED_PREVIEW');
      }
    }
    expect(hits, greaterThan(0));
    expect(misses, greaterThan(0));
  });
```

Add to `test/photo_source_test.dart`, mirroring that file's existing fake-loader style:

```dart
  test('fallbackAfterNativeFailure recovers a non-DNG RAW with an embedded'
      ' preview (extension gate removed)', () async {
    final dir = await Directory.systemTemp.createTemp('photo_source_f08');
    addTearDown(() => dir.delete(recursive: true));
    final samples = Directory('local_data/photo_samples/DNG')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.dng'));
    File? withPreview;
    for (final f in samples) {
      if (await DngPreviewExtractor.extractFullSizeEmbeddedJpegFromFile(f.path)
          != null) { withPreview = f; break; }
    }
    expect(withPreview, isNotNull);
    final asNef = File('${dir.path}/sample.nef');
    await withPreview!.copy(asNef.path);
    expect(await PhotoSource.fallbackAfterNativeFailure(asNef.path), isNotNull);
  });
```

- [ ] **Step 2: Run to verify the `photo_source_test` case fails**

Run: `flutter test test/photo_source_test.dart 2>&1 | tail -5; echo RC=$?` (artifact: `scripts/tmp/m6-r1-verify/p2-2-red.txt`)
Expected: the new case FAILS (returns null — `.nef` is rejected by the extension gate at `photo_source.dart:365`); the `dart_image_loader` case already passes (P2.1 wrote the behaviour) — that is expected and stated here, not a red-first violation: the RED evidence for this task is the `photo_source` case.

**Step 2b (lead ruling, 2026-08-24, discovered in execution):** the pre-existing case `photo_source_test.dart:128-169` ("extension gate holds through the seam") is a mutation-killer for exactly the gate this task removes. It is NOT in `baseline-registry.md`'s frozen list. Disposition = REWRITE inverted under C-4, reason recorded in the commit message (registry untouched): (case A) its fixture — real DNG bytes under a `.jpg` extension with a failing injected loader — must now RECOVER an `EncodedPayload` with `observedCost` cheap (red before the gate removal, green after: this doubles as the task's red-first evidence); (case B) add the negative twin — non-TIFF garbage bytes under `.jpg`, failing loader → null payload permanent miss (the walker's magic check, not the extension, discriminates).

**P2.1 erratum (lead-approved deviation):** the plan's verbatim `dartImageLoad` misclassified a MISSING file as `NativeImageNeedsRawDecode` (both extractor calls return null for unopenable files). The shipped code adds a `File(path).exists()` guard returning `NativeImageFailure('NOT_FOUND', …)` before the TIFF branch — matching the plan's own "missing file is a failure" test. Round reviewer: check that guard specifically.

- [ ] **Step 3: Remove the extension gate**

In `lib/services/photo_source.dart`, replace the body of `fallbackAfterNativeFailure` (`:364-367`):

```dart
  static Future<Uint8List?> fallbackAfterNativeFailure(String path) async {
    // Extension gate removed (M6 F-08): the walker keys on the TIFF magic and
    // self-rejects anything else, so .arw/.cr2/.nef/.orf/.rw2 embedded
    // previews are recoverable on every platform. Non-TIFF input returns
    // null exactly as before.
    return DngPreviewExtractor.extractFullSizeEmbeddedJpegFromFile(path);
  }
```

Update the doc comment above it (`:356-363`): drop the "Only a `.dng` gets a second try" sentence.

- [ ] **Step 4: Run both test files, verify green**

Run: `flutter test test/photo_source_test.dart test/dart_image_loader_test.dart 2>&1 | tail -3; echo RC=$?`
Expected: `All tests passed!`, `RC=0`.

- [ ] **Step 5: Commit**

```bash
git add lib/services/photo_source.dart test/photo_source_test.dart test/dart_image_loader_test.dart
git commit -m "feat(m6): serve non-DNG RAW embedded previews in Dart everywhere (F-08)"
```

## P2.3 Composition-root switch + bridge-free proof tests (Phase-2 ACs 4 & 5)

**Files:**
- Modify: `lib/providers/app_state.dart:80-94` (constructor default for `imageLoader`)
- Create: `test/m6_bridge_free_test.dart`

**Interfaces:**
- Consumes: `dartImageLoad` (P2.1), `PhotoSource` (`photo_source.dart:87`), `DngFullDecoder`/`DecodedRgba` (`dng_decode_contract.dart` — construct a fake decoder exactly the way `test/image_preload_controller_m3_amend3_test.dart` does).
- Produces: production `ImagePreloadController` is constructed with `imageLoader: thumbnailLoader ?? dartImageLoad` — after this task NO production code path reaches `MethodChannel('halcyon/thumbnail')` for preview/sidebar (export still does until P3.6; that is the only remaining production caller and is listed here so P3.6 can grep for it).

- [ ] **Step 1: Write the failing tests**

`test/m6_bridge_free_test.dart`:

```dart
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/services/dart_image_loader.dart';
import 'package:halcyon_flutter/services/dng_preview_extractor.dart';
import 'package:halcyon_flutter/services/photo_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sampleDir = Directory('local_data/photo_samples/DNG');

  late int channelCalls;
  setUp(() {
    channelCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('halcyon/thumbnail'),
            (call) async {
      channelCalls++;
      throw MissingPluginException(); // the Android/Linux condition (AC 5)
    });
  });

  Future<File?> sample({required bool withPreview}) async {
    for (final f in sampleDir.listSync().whereType<File>()) {
      if (!f.path.toLowerCase().endsWith('.dng')) continue;
      final full = await DngPreviewExtractor
          .extractFullSizeEmbeddedJpegFromFile(f.path);
      if ((full != null) == withPreview) return f;
    }
    return null;
  }

  test('AC4: preview DNG produces bytes with ZERO channel-seam calls',
      () async {
    final f = await sample(withPreview: true);
    expect(f, isNotNull);
    final source = PhotoSource(loader: dartImageLoad);
    final outcome = await source.load(f!.path, longEdge: 2800);
    expect(outcome.payload, isNotNull);
    expect(channelCalls, 0);
  });

  test('AC5: with the channel throwing MissingPluginException, cheap AND'
      ' no-preview DNGs still behave', () async {
    final cheap = await sample(withPreview: true);
    final dear = await sample(withPreview: false);
    expect(cheap, isNotNull);
    expect(dear, isNotNull);
    // Fake decoder: 1x1 RGBA pixel, the m3_amend3 pattern.
    Future<DecodedRgba> fakeDecoder(String path) async =>
        (rgba: Uint8List.fromList([0, 0, 0, 255]), width: 1, height: 1);
    final source = PhotoSource(loader: dartImageLoad, dngDecoder: fakeDecoder);
    final cheapOut = await source.load(cheap!.path, longEdge: 2800);
    expect(cheapOut.payload, isNotNull);
    expect(cheapOut.observedCost, SourceCost.cheap);
    final dearOut = await source.load(dear!.path, longEdge: 2800);
    expect(dearOut.payload, isNotNull); // decoded via the fake, no channel
    expect(dearOut.observedCost, SourceCost.expensive);
  });
}
```

NOTE for the implementer: `DecodedRgba`'s actual shape lives in `lib/services/dng_decode_contract.dart` — if it is a class rather than a record, construct it the way `test/image_preload_controller_m3_amend3_test.dart:46/:85` does; the assertions stay identical.

- [ ] **Step 2: Run to verify AC5 red**

Run: `flutter test test/m6_bridge_free_test.dart 2>&1 | tail -6; echo RC=$?` (artifact: `scripts/tmp/m6-r1-verify/p2-3-red.txt`)
Expected before the composition-root change: AC4 already passes (PhotoSource is constructed directly with `dartImageLoad` in the test), AC5 passes too — BUT the no-preview branch would today reach `_legacyBytes` → the channel → `MissingPluginException` if the fake decoder were absent. The genuinely red half of this task is the next step's production wiring, proven by Step 4's grep; run the file anyway to pin the tests green before the wiring change.

- [ ] **Step 3: Switch the composition root**

In `lib/providers/app_state.dart`, replace the default loader closure (`:83-89`):

```dart
             imageLoader: thumbnailLoader ?? dartImageLoad,
```

Add `import '../services/dart_image_loader.dart';` and REMOVE the now-unused `import '../services/native_thumbnail_service.dart';` only if nothing else in the file references it (grep first — `ThumbnailLoader` typedef and other symbols may still need it; if referenced, keep the import and note it for P3.3).

- [ ] **Step 4: Mechanical proof of the switch**

Run and append to the artifact:
```bash
grep -n "NativeThumbnailService.requestImage" lib/providers/app_state.dart; echo GREP_RC=$?
```
Expected: no output, `GREP_RC=1` (the only production `requestImage` call site is gone).

- [ ] **Step 5: Full-file regression + M5 gate**

Run: `flutter test test/m6_bridge_free_test.dart test/app_state_test.dart test/image_preload_dual_window_m5_test.dart 2>&1 | tail -3; echo RC=$?`
Expected: `All tests passed!`, `RC=0`. If `app_state_test.dart` fails on HEIC or channel-mock expectations, STOP and report — those rewrites belong to P3.3/Appendix B, and pulling them forward needs the lead's sign-off, not a silent scope expansion.

- [ ] **Step 6: Commit**

```bash
git add lib/providers/app_state.dart test/m6_bridge_free_test.dart
git commit -m "feat(m6): production loader is the pure-Dart producer; bridge-free proof tests (P2 AC4/AC5)"
```

## P2.4 Sidebar byte source through the producer (F-10 half 1)

**Context (read first):** the sidebar sweep already calls the injected seam — `_source.loader(file.path, purpose: ImageRequestPurpose.sidebarThumbnail)` at `image_preload_controller.dart:1182` — so P2.3's composition-root switch ALREADY routes it through `dartImageLoad`. This task adds the proof, not new wiring. The render site (`sidebar_view.dart:281-295`) caps the DECODE at `32 × devicePixelRatio` via `ResizeImage(policy: fit)`, so a larger-than-200px cached byte payload cannot cause a full-resolution decode; the byte-size question is P2.5's.

**Files:**
- Test: `test/sidebar_view_test.dart` (rewrite the channel-mock case at `:119` — this is the Appendix-B rewrite for this file, deliberately pulled into P2.4 because the mock it uses died with P2.3; note the pull-forward in the commit message)

**Interfaces:**
- Consumes: `ImagePreloadController.preloadThumbnails({required List<PhotoItem> items, required int startIdx, required int endIdx, required VoidCallback notifyLoaded})` (`image_preload_controller.dart:1117`), `thumbnailBytesFor(String id)` (`:265`), `AppState(thumbnailLoader: …)` injection (`app_state.dart:71`), `dartImageLoad` (P2.1).
- Produces: nothing new — a pinned behaviour: sidebar bytes come from the Dart producer; items with no embedded candidate become permanent misses exactly as before (`:1190-1196`).

- [ ] **Step 1: Rewrite the `sidebar_view_test.dart:119` channel-mock case, seen red under the old mock**

Replace the `MethodChannel('halcyon/thumbnail')` mock with a counting wrapper around the real producer (keep the rest of the file's harness untouched):

```dart
  // M6 P2.4: the sidebar's byte source is the pure-Dart producer. The old
  // channel mock is meaningless after the composition-root switch (P2.3).
  var loaderCalls = 0;
  Future<NativeImageResult> countingLoader(String path,
      {required ImageRequestPurpose purpose}) {
    loaderCalls++;
    expect(purpose, ImageRequestPurpose.sidebarThumbnail,
        reason: 'sidebar sweep must request sidebar purpose only');
    return dartImageLoad(path, purpose: purpose);
  }
```

Drive the sweep against real samples (same directory red line as P2.1) through the controller the harness already constructs, then assert:

```dart
  await controller.preloadThumbnails(
    items: items, startIdx: 0, endIdx: items.length - 1,
    notifyLoaded: () {});
  // let the 100ms debounce timer fire inside fakeAsync/pump per the file's
  // existing pattern — do NOT add a real sleep.
  expect(loaderCalls, greaterThan(0));
  final anyBytes = items.any((i) => controller.thumbnailBytesFor(i.id) != null);
  expect(anyBytes, isTrue,
      reason: 'preview-bearing samples must yield sidebar bytes via Dart');
```

- [ ] **Step 2: Run, verify the OLD case fails / new case passes**

Run: `flutter test test/sidebar_view_test.dart 2>&1 | tail -5; echo RC=$?` (artifact: `scripts/tmp/m6-r1-verify/p2-4.txt`) — run once BEFORE the rewrite (old mock case must now FAIL against the switched composition root: that failure is the red evidence Appendix B demands) and once AFTER (green).

- [ ] **Step 3: Commit**

```bash
git add test/sidebar_view_test.dart
git commit -m "test(m6): sidebar byte source proven through the Dart producer (F-10; Appendix-B rewrite of sidebar_view_test pulled into P2.4)"
```

## P2.5 Sidebar decode-time long-edge downscale (F-10 half 2)

**Problem this task exists for:** for `.jpg/.jpeg/.png` the producer returns ORIGINAL file bytes; the native branch used to return a ~200 px re-encoded JPEG (~tens of KB). `_thumbCache` (`image_preload_controller.dart:87`, `Map<String, Uint8List>`) holds one entry per visible+margin row, so multi-MB originals × ~30 rows is a real (bounded but fat) regression. Decode cost is already capped at the render site; the CACHED BYTES are not.

**Files:**
- Modify: `lib/services/image_preload_controller.dart` (sidebar sweep success branch, `:1187-1189`)
- Create: `lib/services/sidebar_thumbnail_codec.dart`
- Test: `test/sidebar_thumbnail_codec_test.dart`

**Interfaces:**
- Produces: **`Future<Uint8List> sidebarCacheBytes(Uint8List encoded, {int longEdge = 200, int reencodeThreshold = 512 * 1024})`** in `sidebar_thumbnail_codec.dart` — returns `encoded` unchanged when `encoded.length <= reencodeThreshold` (embedded DNG candidates are already small; re-encoding them buys nothing), otherwise decodes with a long-edge cap and re-encodes to PNG via `dart:ui` (no new dependency; the `image` package only arrives in P3.6).
- Consumed by: the sweep at `:1188` becomes `_thumbCache[id] = await sidebarCacheBytes(result.bytes);`.

- [ ] **Step 1: Write the failing test**

`test/sidebar_thumbnail_codec_test.dart`:

```dart
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/services/sidebar_thumbnail_codec.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Uint8List> bigPng() async {
    // Synthesize a 1200x800 image and PNG-encode it: a >512KB-ish encoded
    // payload with known dims, no sample-file dependency.
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final paint = ui.Paint();
    for (var x = 0; x < 1200; x += 10) {
      paint.color = ui.Color.fromARGB(255, x % 256, (x * 7) % 256, 99);
      canvas.drawRect(ui.Rect.fromLTWH(x.toDouble(), 0, 10, 800), paint);
    }
    final img = await recorder.endRecording().toImage(1200, 800);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  test('small payloads pass through untouched (identity, same object)', () async {
    final small = Uint8List.fromList(List.filled(1024, 7));
    expect(identical(await sidebarCacheBytes(small), small), isTrue);
  });

  test('oversized payloads are re-encoded with the long edge capped at 200',
      () async {
    final src = await bigPng();
    final out = await sidebarCacheBytes(src, reencodeThreshold: 1024);
    expect(out.length, lessThan(src.length));
    final codec = await ui.instantiateImageCodec(out);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 200);   // landscape: width is the long edge
    expect(frame.image.height, 133);  // 800 * 200 / 1200 rounded
  });
}
```

- [ ] **Step 2: Run to verify it fails** — `flutter test test/sidebar_thumbnail_codec_test.dart 2>&1 | tail -3; echo RC=$?` → FAIL, unresolved import. Artifact: `scripts/tmp/m6-r1-verify/p2-5-red.txt`.

- [ ] **Step 3: Implement `lib/services/sidebar_thumbnail_codec.dart`**

```dart
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Bounds what the sidebar byte cache stores (M6 F-10 half 2).
///
/// The native 200px branch used to re-encode; the Dart producer returns
/// original bytes for encoded bitstreams. Payloads at or under
/// [reencodeThreshold] pass through untouched (embedded DNG candidates are
/// already thumbnail-sized). Larger ones are decoded ONCE with the long edge
/// capped at [longEdge] and re-encoded as PNG through dart:ui — no external
/// codec dependency.
///
/// ponytail: PNG (not JPEG) because dart:ui only encodes PNG; P3.6 adopts the
/// `image` package for export — if sidebar memory ever matters more, switch
/// this to JPEG-q80 there.
Future<Uint8List> sidebarCacheBytes(
  Uint8List encoded, {
  int longEdge = 200,
  int reencodeThreshold = 512 * 1024,
}) async {
  if (encoded.length <= reencodeThreshold) return encoded;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(encoded);
    final codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (int width, int height) {
        if (width <= longEdge && height <= longEdge) {
          return ui.TargetImageSize(width: width, height: height);
        }
        return width >= height
            ? ui.TargetImageSize(width: longEdge)
            : ui.TargetImageSize(height: longEdge);
      },
    );
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    if (data == null) return encoded;
    return data.buffer.asUint8List();
  } catch (_) {
    // Undecodable input: cache the original rather than dropping the row.
    return encoded;
  }
}
```

- [ ] **Step 4: Wire the sweep** — at `image_preload_controller.dart:1188` replace `_thumbCache[id] = result.bytes;` with `_thumbCache[id] = await sidebarCacheBytes(result.bytes);` and add the import. No other call sites (`grep -n "thumbCache\[" lib/` must show exactly one writer).

- [ ] **Step 5: Green + regression** — `flutter test test/sidebar_thumbnail_codec_test.dart test/sidebar_view_test.dart test/sidebar_view_m1_test.dart 2>&1 | tail -3; echo RC=$?` → `All tests passed!`.

- [ ] **Step 6: Commit** — `git add lib/services/sidebar_thumbnail_codec.dart lib/services/image_preload_controller.dart test/sidebar_thumbnail_codec_test.dart && git commit -m "feat(m6): bound sidebar byte cache via decode-time long-edge downscale (F-10)"`

## P2.5b Sidebar RAW-decode fallback for bare-CFA DNGs (matrix P-12, user ruling option B)

**Why (G3′ finding, 2026-08-24):** 13 sample DNGs carry NO embedded JPEG at any size (bare CFA captures); macOS native served their sidebar thumbnails via its own RAW decode. The Dart sidebar route never decodes by design — so those files would regress to blank tiles. User ruled: add a sized RAW-decode fallback. The FFI layer already supports it: `DngDecoderService.decodeOnWorker(path, maxDim: …)` requests a decode whose longest edge is ~`maxDim`, and the vendored `dng_processor_ffi/macos/Libraries/libdng_decoder_native.dylib` EXPORTS `dng_decode_and_process_sized` (verified with `nm -gU`; the comment in `dng_bindings.dart:48-49` claiming otherwise is stale — do not trust it, trust the symbol table; note `maxDim` is silently ignored by libraries without the symbol, so always read the returned dims).

**Files:**
- Modify: `lib/services/dng_decode_contract.dart` (ADD a typedef — do NOT touch `DecodedRgba` or the existing `DngFullDecoder`; the 3-variant `NativeImageResult` freeze is unaffected, flag to reviewer regardless)
- Modify: `lib/services/dng_decode_service.dart` (sized adapter)
- Modify: `lib/services/sidebar_thumbnail_codec.dart` (PNG-from-pixels helper)
- Modify: `lib/services/image_preload_controller.dart` (constructor param + sweep fallback branch)
- Modify: `lib/providers/app_state.dart` (wire the production sized decoder)
- Test: `test/sidebar_thumbnail_codec_test.dart`, `test/sidebar_view_test.dart` (extend both)

**Interfaces:**
- New typedef in `dng_decode_contract.dart`: `typedef DngSizedDecoder = Future<DecodedRgba> Function(String path, {required int maxDim});`
- New adapter in `dng_decode_service.dart` (mirror `decodeDngFull`'s length-check pattern exactly):

```dart
Future<DecodedRgba> decodeDngSized(String path, {required int maxDim}) async {
  final service = DngDecoderService();
  final image = await service.decodeOnWorker(path, maxDim: maxDim);
  final expectedLength = image.width * image.height * 4;
  if (image.rgbaData.length != expectedLength) {
    throw StateError('dng_processor sized decode length mismatch');
  }
  return DecodedRgba(rgba: image.rgbaData, width: image.width, height: image.height);
}

const DngSizedDecoder halcyonDngSizedDecoder = decodeDngSized;
```

- New helper in `sidebar_thumbnail_codec.dart`: `Future<Uint8List> pngFromOrientedPixels(DecodedRgba decoded, {required int exifOrientation, int longEdge = 200})` — run the pixels through the EXISTING `decodedRgbaToPixelPayload(decoded, exifOrientation: …, longEdge: longEdge)` (orientation-baking + downscale already live there — reuse, do not reimplement), then encode PNG: `ui.ImageDescriptor.raw` over an `ImmutableBuffer` of the payload's rgba with `PixelFormat.rgba8888` → `instantiateCodec` → frame → `toByteData(png)`; dispose the image.
- Controller: `ImagePreloadController` gains optional `DngSizedDecoder? sidebarRawDecoder`. In the sweep's non-bytes branch (currently → permanent miss), BEFORE recording the miss: if the failure is not bytes AND `SupportedPhotoFormats.isRawPath(file.path)` AND `sidebarRawDecoder != null`, then `try { final decoded = await sidebarRawDecoder!(file.path, maxDim: 200); final orientation = await DngPreviewExtractor.readOrientation(file.path) ?? kDefaultExifOrientation; _thumbCache[id] = await pngFromOrientedPixels(decoded, exifOrientation: orientation); notifyLoaded(); } catch (_) { /* fall through to permanent miss */ }`. The sweep is already serial (one awaited item at a time) so no extra throttle is needed; generation guard applies as for the bytes branch.
- `app_state.dart`: pass `sidebarRawDecoder: dngDecoder == null ? null : halcyonDngSizedDecoder` (sized fallback only exists where the app has a decoder at all — Linux/iOS stay on the uniform explicit miss).

- [ ] **Step 1 (red):** two tests first: (a) codec test — `pngFromOrientedPixels` on a 4×2 two-colour `DecodedRgba` with orientation 6 returns a decodable 2×4 PNG with the colours transposed as expected; (b) sidebar test — counting fake `sidebarRawDecoder` + a loader forced to `NativeImageFailure`: a `.dng` item populates the cache with decodable PNG bytes and the fake was called with `maxDim: 200`; a throwing fake → permanent miss (no crash, no retry); a `.jpg` item → fake NOT called. Watch both fail on missing symbols; artifact `scripts/tmp/m6-r1-verify/p2-5b-red.txt`.
- [ ] **Step 2:** implement per the interfaces above.
- [ ] **Step 3:** green: the two extended test files + `test/image_preload_dual_window_m5_test.dart` + `flutter analyze`, RCs in artifact.
- [ ] **Step 4:** commit `feat(m6): sidebar RAW-decode fallback via FFI sized decode (P-12 ruling, bare-CFA DNGs)`.

## P2.6 Re-gate G3′ against the shipped sidebar route (P-8 optimise-and-re-gate)

> **FINAL STATUS (2026-08-24, matrix P-13): GATE CLOSED — PASSED BY USER RULING** after G3″ (`scripts/tmp/20260824T095155Z-m6-g3second.txt`) and the instrument-corrected G3‴ (`scripts/tmp/20260824T100530Z-m6-g3third.txt`, production dylib, sized path proven by dims marker): null clause 13/13, dims native-exact, latency 55.6–100.2 ms accepted. **Standing rule for every later gate in this plan (P5.3 included): any per-sample decode under 75 ms passes outright regardless of ratio.** The JPEG latency item is CLOSED by the same ruling (P3.6 no longer carries a re-gate obligation for it). **P3 is UNBLOCKED.**
>
> Superseded history: **STATUS (2026-08-24): EXECUTED — HARD FAIL** (artifact `scripts/tmp/20260824T093358Z-m6-g3prime.txt`): the 13 samples are bare-CFA DNGs with no embedded JPEG at any size — real gap, Phase-1's route-mismatch diagnosis falsified by direct probe; embedded-candidate DNGs PASS 50–100× faster than native; portrait dims fixed; JPEG latency clause still failing (22× at ~25 ms absolute). User ruling (matrix P-12): implement P2.5b, then run **G3″** — same discipline, same comparator, expectation: the 13 now produce thumbnails via the sized-decode fallback. The JPEG latency item rides the same optimise-and-re-gate loop (P3.6's JPEG encoder is the named optimisation candidate; escalate with numbers only if it still fails after that).

**This is a gate task — Appendix A discipline applies in full** (fresh pre-registration block ABOVE any number, route changes frozen in it, `RC=$?` self-captured, no parameter-chasing after the run starts). It is the sanctioned "optimise and re-gate" round for the Phase-1 sidebar FAIL; the route corrections below are exactly what P2.1–P2.5 shipped, so this measures production reality, not a friendlier benchmark. **G2 needs NO re-gate — its FAIL was accepted by the user (matrix P-10); this task is G3′ only.**

**Files:** Create `scripts/tmp/<UTC>-m6-g3prime.txt` (+ harness under `scripts/tmp/m6-r1-bench/`, reusing the Phase-1 harness code — its numbers stay inadmissible).

**Pre-registered route corrections (freeze verbatim in the artifact):**
- G3′ Dart route = `DngPreviewExtractor.extractEmbeddedJpeg(path, longEdge: 200)` for DNGs (the P2.1 sidebar branch) and `sidebarCacheBytes` over `File.readAsBytes` for JPEGs (the P2.5 decode-time-downscale pipeline, ruled in by matrix P-11), long-edge-cap dims semantics (`TargetImageSize`, matching `kCGImageSourceThumbnailMaxPixelSize`). The Phase-1 HARD FAIL's 13 nulls are expected to vanish (those DNGs carry small thumbnails the corrected entry point finds); state this expectation in the block.
- Comparator stays the Phase-1 native harness binaries (content-marker pinned) — after P3 deletes the native branch there is nothing shipped to compare against, so this is the LAST possible native-baselined run.

**Decision rule:** Appendix A verbatim. On G3′ PASS → P3 unblocks. On G3′ FAIL → do NOT iterate silently: report the per-sample table to the lead; the lead escalates to the user with the numbers. The Swift path is never retained either way (P-8).

**Harness handoff notes (from bench-gates-opus, the Phase-1 measurer — routes not to rediscover):**
1. G3's Dart side CANNOT use `dart compile exe` (`dart:ui` decoding is unavailable to it). `scripts/tmp/m6-r1-bench/g3_dart_test.dart` runs under `flutter test -j 1` and writes results to the CSV named by the `G3_OUT` env var — read results from that file, never scrape the self-overwriting progress line. This JIT bias runs AGAINST Dart and must be re-declared in the fresh pre-registration block.
2. The longEdge-route change is exactly ONE function: `sourceBytes` in `g3_dart_test.dart` → `extractEmbeddedJpeg(path, longEdge: 200)` and take `.bytes`. Native harness, verdict script and sample lists stay unchanged — that is what keeps the Phase-1 numbers a valid comparator.
3. The dims clause needs the LONG-EDGE cap, not `targetWidth: 200`, or the single portrait sample fails again for a non-extractor reason; the Phase-1 artifact's variant-B column already shows the corrected value (133x200, matching native).
4. Entry points: `run_g1.sh` / `run_g2.sh` / `run_g3.sh` take the artifact path as `$1` and handle RC capture; `verdict_g1.py` / `verdict_simple.py` compute the frozen rule mechanically.

- [ ] Step 1: write the pre-registration block (artifact file on disk before any run)
- [ ] Step 2: run G3′ (DNG half + JPEG half), `RC=$?` after each command
- [ ] Step 3: compute verdicts mechanically (reuse `verdict_g1.py` pattern), append PASS/FAIL per sample
- [ ] Step 4: report verdict + artifact path to the lead; no commit (scripts/tmp is gitignored)

## P2.7 P2 verification batch + commit

Phase-2 exit — all six frozen ACs, measured in this order, each with `RC=$?` in `scripts/tmp/m6-r1-verify/p2-exit.txt`:

- [ ] Step 1: **Pre-change count is already banked** — the executed-test count MUST have been measured before P2.1 started (`flutter test -j 1 2>&1 | tail -2; echo RC=$?` on the untouched tree; the dispatcher runs this at kickoff and records it in the artifact header). If it was not, record the omission honestly; do not backfill from `baseline-registry.md:42` (238) or the handover (252) — they disagree, which is why measuring was mandated.
- [ ] Step 2: `flutter analyze; echo ANALYZE_RC=$?` → 0 issues, `ANALYZE_RC=0`.
- [ ] Step 3: `flutter test -j 1 2>&1 | tail -2; echo TEST_RC=$?` → `All tests passed!`, `TEST_RC=0`, skipped 0, executed ≥ the banked count.
- [ ] Step 4: `grep -rn "Platform\.is\|kIsWeb\|defaultTargetPlatform\|Process\.run" lib/ | grep -v "perf_driver.dart" | grep -v "status_line.dart"; echo GREP_RC=$?` → no output, `GREP_RC=1`. (`status_line.dart` hosts the pre-existing F-19 site; P4.2 owns it.)
- [ ] Step 5: `flutter test -j 1 test/image_preload_dual_window_m5_test.dart 2>&1 | tail -2; echo M5_RC=$?` → green (AC 6).
- [ ] Step 6: `git add` the P2 file list explicitly (never `-A`) and `git commit -m "feat(m6): P2 unified Dart byte source complete (F-04/06/07/08/09/10)"`; record `git rev-parse HEAD` in the artifact — verification evidence binds to this hash.

## P3.1 Delete macOS native thumbnail path (gated on P2.6)

**Entry condition (hard):** P2.6's G3′ verdict is PASS, or the user has explicitly accepted the FAIL numbers. Never start this task on an un-gated tree (C-5).

**Ordering note:** P3.6 (export) still calls `NativeThumbnailService.getThumbnail(purpose: export)` until it lands. **P3.6 and P3.7 execute BEFORE P3.1–P3.3 in dispatch order** (the task numbering groups by theme, not sequence): deleting the native export branch first would leave export broken on macOS mid-phase. Dispatcher: run P3.5 → P3.6 → P3.7 → P3.1 → P3.2 → P3.3 → P3.4 → P3.8.

**Files:**
- Delete: `macos/Runner/DngPreviewExtractor.swift`
- Modify: `macos/Runner/AppDelegate.swift` — remove the `thumbnailChannel` declaration (`:25-26`) and its `setMethodCallHandler` block (`:30…` through the end of the thumbnail handler, includes the export branch `:330-345`, the DNG branches `:373-424`, CIRAWFilter `:426-433`, and the `IMAGE_TOO_LARGE` emission at `:461`), plus now-orphaned statics (`renderCGImage:192`, `maxDecodedPixelBytes:178`, `exifOrientation(from:)`, `readDngOrientation`) — after the removal `grep -n "thumbnail\|DngPreview\|CIRAW" macos/Runner/AppDelegate.swift` must return 0 rows. **Keep untouched:** `trashChannel` (`:27-28`), the `halcyon/open_with` wiring (`:80-100`), and the `halcyon/exif` channel (P3.4 owns it).
- Modify: `macos/Runner/` Xcode project references to the deleted Swift file (`project.pbxproj`) so the target still builds.

**ACs (from the frozen Phase-3 list):**
- [ ] `grep -rn "halcyon/thumbnail" macos/ ; echo RC=$?` → no rows, `RC=1`
- [ ] `grep -rc "NO_EMBEDDED_PREVIEW" macos/ | grep -v ":0" ; echo RC=$?` → no rows while `kNoEmbeddedPreviewCode` still exists in Dart (`native_thumbnail_service.dart:93` until P3.3)
- [ ] `python3 scripts/build_apps.py 2>&1 | tail -3; echo BUILD_RC=$?` → macOS release build succeeds, `BUILD_RC=0` (artifact `scripts/tmp/m6-r1-verify/p3-1-build.txt`)
- [ ] `flutter test -j 1 2>&1 | tail -2; echo RC=$?` → green (Dart side untouched by this task; a failure here means a test still mocks the deleted channel — STOP and hand to P3.3, do not fix inline)
- [ ] Commit: `git add -u macos/ && git commit -m "refactor(m6)!: delete macOS native thumbnail path (gate G1/G3' closed)"`

## P3.2 Delete Windows native image path

**Files:**
- Delete: `windows/runner/halcyon_image.cpp` (self-labelled `UNCOMPILED AND UNTESTED` at `:3` — deletion removes unverified surface, AC 5)
- Modify: `windows/runner/halcyon_channels.cpp` — remove the `thumbnail_` channel construction (`:66-67`) and its handler wiring; **keep** `trash_` (`:108-109`) and `open_with_` (`:142-143`). Remove `halcyon_image` from `windows/runner/CMakeLists.txt` sources and delete any `#include "halcyon_image.h"`.

- [ ] `grep -rn "halcyon_image\|halcyon/thumbnail" windows/ ; echo RC=$?` → no rows, `RC=1`
- [ ] `grep -rn "halcyon/trash\|halcyon/open_with" windows/ | wc -l` → unchanged from pre-task count (record both counts in the artifact)
- [ ] Windows build is NOT runnable on this host (CLAUDE.md: windows builds on Windows only) — state this in the report as the known limitation; the CMake edit is verified by inspection + the P5.3 first-contact note.
- [ ] Commit: `git add -u windows/ && git commit -m "refactor(m6)!: delete Windows native image path (unverified surface removed)"`

## P3.3 Reduce the Dart channel service + rewrite affected tests

**Files:**
- Modify: `lib/services/native_thumbnail_service.dart` — the channel dies; the TYPES live. Move `ImageRequestPurpose`, `NativeImageResult` + 3 variants, `kDefaultExifOrientation` into a new `lib/services/image_source_types.dart` (pure types, no `flutter/services` import); delete `NativeThumbnailService`, `kNoEmbeddedPreviewCode`, `kAllowRawDecodeSignalArg`, and the file itself once every importer is repointed (`grep -rln "native_thumbnail_service" lib/ test/`).
- Modify: `lib/services/photo_source.dart` — `_legacyBytes` (`:282-288`) loses its channel call: the U-12 ruling replaces "degraded via CIRAWFilter" with the uniform explicit miss. Replace the method body with `return null;`? NO — delete `_legacyBytes` entirely and replace its three call sites (`:143-148`, `:181-187`, `:216-222`, `:242-249`) with the null-payload permanent-miss return the surrounding code already documents (`payload: null, observedCost: SourceCost.expensive, deferred: false`). The oracle test protecting degrade-never-blank (`image_preload_controller_test.dart:1118-1120`) asserts single-platform semantics (macOS CIRAWFilter) and is REWRITTEN under Appendix B to assert the new uniform outcome: null payload marked as permanent miss, never an unresolved spinner.
- Rewrite tests per Appendix B: `native_thumbnail_service_test.dart` (delete file — replacement already exists as `test/dart_image_loader_test.dart` from P2.1), `image_preload_controller_test.dart:743/:762/:1204/:1216` + `:1118-1120`, `image_preload_scheduling_m4_test.dart:389-436`, `dng_nav_probe_m3_test.dart:180-203` (TC-089 case only; TC-088 stays), `exif_metadata_service_test.dart` channel half moves to P3.4. Every rewrite seen red first; each deletion's reason recorded in `baseline-registry.md` in the SAME commit with re-registered sha256 (C-4).

- [ ] Step 1: repoint importers to `image_source_types.dart`; `flutter analyze` after each file, not at the end
- [ ] Step 2: rewrite/delete the Appendix-B tests for this scope, red→green evidence per file in `scripts/tmp/m6-r1-verify/p3-3-tests.txt`
- [ ] Step 3: `grep -rn "halcyon/thumbnail\|NativeThumbnailService\|kNoEmbeddedPreviewCode" lib/ test/ ; echo RC=$?` → no rows, `RC=1`
- [ ] Step 4: `flutter test -j 1 2>&1 | tail -2; echo RC=$?` → green, skipped 0
- [ ] Step 5: `git add` the explicit file list + `baseline-registry.md` and commit `refactor(m6)!: channel service deleted; types survive as image_source_types (U-12 uniform miss)`

## P3.4 F-14 EXIF: isolate path becomes the only path

**Files:**
- Modify: `lib/services/exif_metadata_service.dart:40-56` · Modify: `macos/Runner/AppDelegate.swift` (remove the `halcyon/exif` channel + handler + its helpers) · Test: `test/exif_metadata_service_test.dart`

- [ ] **Step 1 (red):** in `test/exif_metadata_service_test.dart`, delete the channel-mock cases; add one case, run it, watch it fail before Step 2:

```dart
  test('readBatch never touches a platform channel', () async {
    var channelCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ExifMetadataService.channel, (call) async {
      channelCalls++;
      return null;
    });
    await ExifMetadataService.readBatch(const []); // shape only; and:
    // one real path through the isolate parser — reuse the file's existing
    // isolate-fallback fixture paths unchanged.
    expect(channelCalls, 0);
  });
```

- [ ] **Step 2:** `_readChunk` (`:40-56`) becomes the isolate path unconditionally:

```dart
  static Future<List<ExifMetadata?>> _readChunk(List<String> chunk) {
    // M6 F-14: the native channel is deleted; the package/isolate path —
    // formerly the fallback and always the reference implementation — is the
    // only path (matrix F-14, parity gold standard per m6-spec-contract §3).
    return Future.wait(chunk.map(readWithPackage));
  }
```

  Keep `channel`, `metadataFromMap` only if tests still pin the map shape — if nothing references them after the rewrite, delete both (`grep -rn "metadataFromMap\|ExifMetadataService.channel" lib/ test/`).
- [ ] **Step 3:** remove the exif channel/handler block from `AppDelegate.swift` (declaration near `:67`, handler at `:543+`); `grep -rn "halcyon/exif" macos lib ; echo RC=$?` → `RC=1`
- [ ] **Step 4:** `flutter test -j 1 test/exif_metadata_service_test.dart 2>&1 | tail -2; echo RC=$?` → green; then `python3 scripts/build_apps.py 2>&1 | tail -2; echo RC=$?` → macOS build still green
- [ ] **Step 5:** commit `refactor(m6)!: EXIF reads are isolate-only everywhere (F-14)`

## P3.5 F-05 HEIC removal + `bestFileToLoad` preference fix

**Files:** Modify `lib/models/supported_photo_formats.dart:6-24` · Test: `test/photo_item_test.dart` or the existing formats coverage (locate with `grep -rln "supportedExtensions\|bestFileToLoad" test/`).

- [ ] **Step 1 (red):** add the test first:

```dart
  test('HEIC is not scanned, and never preferred over a decodable sibling', () {
    expect(SupportedPhotoFormats.isSupportedPath('/x/a.heic'), isFalse);
    final files = [File('/x/a.heic'), File('/x/a.arw')];
    // A HEIC that slipped into an item (pre-removal folder state) must not
    // win preference — the old list preferred the one file that cannot
    // decode anywhere (supported_photo_formats.dart:47-56 bug).
    expect(SupportedPhotoFormats.bestFileToLoad(files)!.path, '/x/a.arw');
  });
```

- [ ] **Step 2:** remove `'.heic'` from `supportedExtensions` (`:12`) and from `preferredLoadExtensions` (`:23`). Nothing else changes — `bestFileToLoad`'s loop then falls through to `files.first` only for all-RAW groups, which is correct.
- [ ] **Step 3:** `grep -rn "heic" lib/ ; echo RC=$?` → `RC=1`; `grep -rln "heic" test/` → only files asserting the ABSENCE (this new test); anything else gets the Appendix-B treatment with its reason recorded.
- [ ] **Step 4:** green + commit `feat(m6)!: drop HEIC from the supported set (F-05; decoder returns as a future contract)`

## P3.6 F-11 Export: decode → resize → encode via `image` (runs BEFORE P3.1 — see ordering note)

**Files:** Modify `pubspec.yaml` (add `image: ^4.3.0`) · Modify `lib/services/thumbnail_export_service.dart:31-47` · Modify `lib/providers/app_state.dart:79` (pass the decoder through) · Test: `test/thumbnail_export_service_test.dart` (Appendix-B rewrite, pulled in here because the seam it mocks changes now).

**Interfaces:**
- Produces: `ThumbnailExportService({ExportBytesFetch? fetchBytes, DngFullDecoder? decoder})` — the seam SIGNATURE `typedef ExportBytesFetch = Future<Uint8List?> Function(String path)` is unchanged, so existing fake-injection tests keep compiling; only the DEFAULT implementation moves off the channel.

- [ ] **Step 1:** `flutter pub add image` then `flutter pub get; echo RC=$?` → `RC=0` (record the resolved version in the artifact).
- [ ] **Step 2 (red):** rewrite `test/thumbnail_export_service_test.dart`'s default-fetch case: inject NO fetchBytes, point it at a real preview-bearing DNG sample, mock `halcyon/thumbnail` to throw (proving no channel), assert the written file decodes as JPEG with long edge ≤ 2048. Watch it fail (`scripts/tmp/m6-r1-verify/p3-6-red.txt`).
- [ ] **Step 3:** implement the default fetch:

```dart
import 'package:image/image.dart' as img;
// ...
  static Future<Uint8List?> exportBytesFor(
    String path, {
    DngFullDecoder? decoder,
  }) async {
    // Byte source = the same producer the detail view uses (P2.1). Purpose is
    // PREVIEW deliberately: that branch returns full-size bytes OR the
    // raw-decode signal for a no-preview DNG (the export purpose never emits
    // the signal, P2.1 invariant); export sizing is this function's own job.
    final result =
        await dartImageLoad(path, purpose: ImageRequestPurpose.preview);
    img.Image? frame;
    if (result is NativeImageBytes) {
      frame = img.decodeImage(result.bytes);
      // Pixels rotated per EXIF, Orientation forced to 1 — the native export
      // branch's documented contract (ImageRequestPurpose.export docs in
      // native_thumbnail_service.dart:13-18; the type moves to
      // image_source_types.dart later, in P3.3).
      if (frame != null) frame = img.bakeOrientation(frame);
    } else if (result is NativeImageNeedsRawDecode && decoder != null) {
      final decoded = await decoder(path);
      frame = img.Image.fromBytes(
        width: decoded.width, height: decoded.height,
        bytes: decoded.rgba.buffer, numChannels: 4,
      );
      // FFI output is unrotated; bake from the signal's orientation. The
      // image package rotates by angle: map EXIF 3/6/8 -> 180/90/270 and
      // flip for 2/4/5/7 (write the 8-case switch out; do not special-case
      // only the common values).
      frame = bakeExifOnDecoded(frame, result.exifOrientation);
    }
    if (frame == null) return null;
    if (frame.width > 2048 || frame.height > 2048) {
      frame = img.copyResize(frame,
          width: frame.width >= frame.height ? 2048 : null,
          height: frame.height > frame.width ? 2048 : null,
          interpolation: img.Interpolation.linear);
    }
    return Uint8List.fromList(img.encodeJpg(frame, quality: 90));
  }
```

  `bakeExifOnDecoded` is a ~20-line pure function in the same file: orientation 1→identity, 2→flipH, 3→rotate180, 4→flipV, 5→rotate90+flipH, 6→rotate90, 7→rotate270+flipH, 8→rotate270 (`img.copyRotate`/`img.flipHorizontal`/`img.flipVertical`). Unit-test it with a 2×1 two-colour image asserting pixel positions for all 8 values — that is the check that fails if the mapping is wrong.
  Wire: `_defaultFetch` becomes `(path) => exportBytesFor(path, decoder: _decoder)` with `_decoder` from the new constructor param; `app_state.dart:79` passes `exportService ?? ThumbnailExportService(decoder: dngDecoder)`.
- [ ] **Step 4:** run the rewritten tests + `flutter analyze`; green; commit `feat(m6): export is decode->resize->encode in Dart via image package (F-11)`

## P3.7 F-20 Oversized-image guard in Dart (runs BEFORE P3.1)

**Files:** Modify `lib/services/dng_preview_extractor.dart` (one new public: `readImageDimensions`) · Modify `lib/services/dart_image_loader.dart` (guard at the NeedsRawDecode construction) · Test: `test/dart_image_loader_test.dart` (extend).

- [ ] **Step 1:** `readImageDimensions(String path)` → `Future<({int width, int height})?>`: identical bounded walk to `readOrientation` (`:109-132`), reading IFD0 tags 0x0100 (ImageWidth) and 0x0101 (ImageLength), SHORT or LONG typed, null when unparseable. Follow the file's never-throws convention.
- [ ] **Step 2:** guard in `dartImageLoad` before constructing the signal, same constant and code the native path used (`AppDelegate.swift:178` `maxDecodedPixelBytes = 1_500_000_000`, check `w × h × 4`):

```dart
    if (purpose == ImageRequestPurpose.preview && lower.endsWith('.dng')) {
      final dims = await DngPreviewExtractor.readImageDimensions(path);
      if (dims != null && dims.width * dims.height * 4 > 1500000000) {
        // F-20: same budget the deleted native guard enforced
        // (formerly AppDelegate.swift renderCGImage). A header claiming an
        // absurd extent must be an error result, never an OOM.
        return const NativeImageFailure(
            'IMAGE_TOO_LARGE', 'decode exceeds the decoded-pixel budget');
      }
      final orientation = await DngPreviewExtractor.readOrientation(path);
      ...
```

- [ ] **Step 3 (red-first):** test with a handcrafted minimal TIFF header (little-endian `II*\0`, one IFD0 with SHORT tags 0x0100=40000, 0x0101=40000, no strips — ~60 bytes built with `ByteData`) asserting `NativeImageFailure('IMAGE_TOO_LARGE')`; plus a real sample asserting the guard does NOT fire. Red first: write the test before Step 1-2 code lands, watch it fail on the missing symbol.
- [ ] **Step 4:** green + commit `feat(m6): oversized-image guard in Dart (F-20, same 1.5GB decoded-pixel budget)`

## P3.8 P3 verification batch + commit

Order check first: P3.5, P3.6, P3.7 landed BEFORE P3.1-P3.3 (see P3.1 ordering note). Then, each with `RC=$?` into `scripts/tmp/m6-r1-verify/p3-exit.txt`:

- [ ] `grep -rn "halcyon/thumbnail\|halcyon/exif" macos windows lib ; echo RC=$?` → `RC=1` (frozen AC 1; `halcyon/trash` stays — F-12 keep ruling)
- [ ] `flutter analyze; echo RC=$?` → 0 issues
- [ ] `flutter test -j 1 2>&1 | tail -2; echo RC=$?` → green, skipped 0, count ≥ P2.7's banked count minus deletions recorded in `baseline-registry.md` (list each with its reason — the count delta must be fully explained, not waved at)
- [ ] `python3 scripts/build_apps.py 2>&1 | tail -3; echo RC=$?` → macOS release build green. Other P-1-cascade platforms: android build if the host toolchain allows (`python3 scripts/build_apps.py android --release`); windows/linux recorded as not-buildable-on-this-host per CLAUDE.md.
- [ ] `test/image_preload_dual_window_m5_test.dart` green (standing regression gate)
- [ ] Commit any stragglers; record `git rev-parse HEAD` in the artifact.

## P4.1 F-17 drag-drop via `desktop_drop`

**Files:** Modify `pubspec.yaml` (add `desktop_drop: ^0.6.1` — confirm latest with `flutter pub add desktop_drop`) · Modify `lib/views/main_screen.dart` (wrap the screen body) · Modify `windows/runner/flutter_window.cpp` (delete the native drop implementation: registration `:56`, WM handling `:104-110`, teardown `:131`; **keep** the Open-With push at `:45-49` and `:87`) · Test: `test/main_test.dart` (extend).

**Interfaces:** Consumes `AppState.openPhotoAtPath(String)` — the exact handler `OpenWithChannel.listen` already uses (`main.dart:42`), so a dropped file behaves identically to an OS "Open With".

- [ ] **Step 1 (red):** widget test: pump the main screen inside the file's existing provider harness, find `DropTarget` — fails (no such widget yet):

```dart
  testWidgets('main screen accepts file drops through DropTarget', (t) async {
    await t.pumpWidget(harness()); // the file's existing builder
    final drop = find.byType(DropTarget);
    expect(drop, findsOneWidget);
    final widget = t.widget<DropTarget>(drop);
    expect(widget.onDragDone, isNotNull);
  });
```

- [ ] **Step 2:** in `main_screen.dart`'s `build`, wrap the existing top-level child:

```dart
    return DropTarget(
      onDragDone: (detail) {
        if (detail.files.isEmpty) return;
        // Same entry as OS Open-With: load the folder, select that photo.
        context.read<AppState>().openPhotoAtPath(detail.files.first.path);
      },
      child: /* existing child unchanged */,
    );
```

- [ ] **Step 3:** delete the Windows native drop code (`flutter_window.cpp:56`, `:104-110`, `:131`); `grep -n "DragAcceptFiles\|WM_DROPFILES\|DragQueryFile" windows/ -r ; echo RC=$?` → `RC=1`.
- [ ] **Step 4:** green + `flutter analyze` 0 + commit `feat(m6): drag-drop unified via desktop_drop on mac/win/linux (F-17)`.

## P4.2 F-19 reveal in file manager (`Process.run`, the C-3 enumerated exception)

**Files:** Modify `lib/views/status_line.dart:158-161` · Test: `test/status_line_test.dart` (extend).

- [ ] **Step 1 (red):** the current `_openInFinder` discards the `Process.run` Future and is macOS-only. Test the new seam first (a `runProcess` injection so the test never spawns a real process):

```dart
  test('reveal builds the right command per OS and surfaces failure', () async {
    final calls = <(String, List<String>)>[];
    Future<ProcessResult> fake(String cmd, List<String> args) async {
      calls.add((cmd, args));
      return ProcessResult(1, 1, '', 'boom'); // nonzero: must be surfaced
    }
    final failed = await revealInFileManager('/p/photo.jpg',
        os: 'macos', runProcess: fake);
    expect(calls.single, ('open', ['-R', '/p/photo.jpg']));
    expect(failed, isNotNull); // human-readable failure string
    calls.clear();
    await revealInFileManager(r'C:\p\photo.jpg', os: 'windows', runProcess: fake);
    expect(calls.single.$1, 'explorer');
    expect(calls.single.$2, ['/select,', r'C:\p\photo.jpg']);
    calls.clear();
    await revealInFileManager('/p/photo.jpg', os: 'linux', runProcess: fake);
    expect(calls.single, ('xdg-open', ['/p'])); // folder-open only, per ruling
  });
```

- [ ] **Step 2:** implement in `status_line.dart` (this file is the ONE C-3 exception site — the grep guard in P2.7/P3.8 already excludes it by file):

```dart
/// M6 F-19. The single C-3 enumerated exception: per-platform commands via
/// Process.run, awaited, errors surfaced (the old fire-and-forget discarded
/// the Future AND the failure). Returns null on success, else a message for
/// the status line.
Future<String?> revealInFileManager(
  String path, {
  String? os,
  Future<ProcessResult> Function(String, List<String>)? runProcess,
}) async {
  final system = os ?? Platform.operatingSystem;
  final run = runProcess ?? (c, a) => Process.run(c, a);
  final (cmd, args) = switch (system) {
    'macos' => ('open', ['-R', path]),          // selects the file
    'windows' => ('explorer', ['/select,', path]), // selects the file
    _ => ('xdg-open', [File(path).parent.path]),   // folder only (ruling)
  };
  try {
    final result = await run(cmd, args);
    return result.exitCode == 0 ? null : 'Reveal failed: $cmd exited ${result.exitCode}';
  } on ProcessException catch (e) {
    return 'Reveal failed: ${e.message}';
  }
}
```

  Call site: replace `_openInFinder(path)` with an awaited call whose non-null return feeds the status-line's existing one-time warning surface (same mechanism as the writability warning).
- [ ] **Step 3:** green; confirm the exception stays contained: `grep -rn "Process\.run" lib/ | grep -v perf_driver | grep -v status_line ; echo RC=$?` → `RC=1`.
- [ ] **Step 4:** commit `fix(m6): reveal-in-file-manager awaited, per-OS, failure surfaced (F-19)`.

## P4.3 F-24 non-pointer recycle-mode entry

**Files:** Modify `lib/views/main_screen.dart:84-113` (key handler) · Modify `lib/views/photo_action_bar.dart:65-67` (tooltip mentions the key) · Test: `test/main_test.dart` (extend).

- [ ] **Step 1 (red):** `await tester.sendKeyEvent(LogicalKeyboardKey.keyR);` inside the existing main-screen harness, assert the provided fake/real `AppState.recycleMode` toggled (the getter `photo_action_bar.dart` already reads).
- [ ] **Step 2:** add to the `onKeyEvent` chain in `main_screen.dart` (pattern of `:94-103`):

```dart
          } else if (event.logicalKey == LogicalKeyboardKey.keyR) {
            state.toggleRecycleMode();
            return KeyEventResult.handled;
```

  Update both tooltip strings in `photo_action_bar.dart` to `'… — right-click or R: switch …'`.
- [ ] **Step 3:** green + commit `feat(m6): keyboard route into recycle mode (F-24)`.

## P4.4 F-18 Windows file association

The repo has no Windows installer/packaging step, so "declaration" needs a mechanism decision — this task RESEARCHES then implements; it does not guess.

- [ ] **Step 1 (research, output = a decision paragraph in the task report):** determine the supported way to declare file associations for an unpackaged Flutter Windows exe vs. an MSIX. Sources to check: Microsoft "Default Programs / file association" registry docs (`HKCU\Software\Classes` ProgID pattern) and the `msix` pub package manifest (`file_extension` support). Decide: registry-script route (works for the loose exe `build_apps.py` produces today) vs. adopting `msix` packaging (bigger change — needs lead sign-off before choosing).
- [ ] **Step 2 (default route unless overruled):** add `windows/runner/halcyon_associations.reg` declaring ProgID `Halcyon.Photo` with `shell\open\command "<exe> \"%1\""` for the supported extension list GENERATED from `SupportedPhotoFormats.supportedExtensions` (write a 20-line `scripts/gen_windows_associations.dart` that emits the .reg so the two can never drift; run it in the build via `build_apps.py`'s windows phase), plus a README section describing import. The opened file arrives through the existing `flutter_window.cpp:45-49` launch path — F-16's transport, already verified end to end.
- [ ] **Step 3:** proof: `dart run scripts/gen_windows_associations.dart | grep -c "\\."; echo RC=$?` — count equals `supportedExtensions.length` (post-F-05, HEIC-free). Green + commit `feat(m6): Windows file-association declaration generated from the supported set (F-18)`.

## P4.5 F-16 Open With: Android/iOS handler wiring

**Consistency gate (from the matrix ruling):** the Android/iOS halves only make sense where the folder-scan core works (P-1 cascade tier 2). F-02 does NOT work on Android/iOS today (no storage permission / no picker override). So this task wires the HANDLER (manifest/Info.plist + Dart listener) and verifies delivery mechanically, but the end-to-end mobile flow stays parked until the folder-scan core lands there — state this in the report, do not silently claim mobile support.

- [ ] **Step 1 (research):** verify `open_file_handler` (the `m6-pkg-verification.md` §F-16 candidate) is maintained and exposes a stream/callback for "file opened with this app" on Android+iOS. If unsuitable, fall back to writing the two platform declarations only (intent-filter in `android/app/src/main/AndroidManifest.xml` with `ACTION_VIEW` + our extensions; `CFBundleDocumentTypes` in `ios/Runner/Info.plist`) and route through the EXISTING `halcyon/open_with` push-only channel pattern (`macos/Runner/AppDelegate.swift:80-100` is the reference: native pushes, Dart buffers — cold-start-safe by design). Report which route was taken and why.
- [ ] **Step 2:** wire the chosen route into `OpenWithChannel.listen` (`lib/services/open_with_channel.dart`) so ALL platforms funnel into the one `appState.openPhotoAtPath` entry (`main.dart:42`).
- [ ] **Step 3:** proof: `flutter build apk --debug 2>&1 | tail -2; echo RC=$?` compiles with the manifest change (host has the Temurin JDK per CLAUDE.md); iOS declaration is inspection-only on this host. Dart-side delivery test: push a mock method call onto the `halcyon/open_with` channel per the existing channel test pattern and assert `openPhotoAtPath` fires.
- [ ] **Step 4:** commit `feat(m6): Open With declarations + unified Dart delivery for Android/iOS (F-16, flow parked on P-1 tier-2)`.

## P4.6 P4 verification batch + commit

- [ ] `flutter analyze; echo RC=$?` → 0 · `flutter test -j 1 2>&1 | tail -2; echo RC=$?` → green, skipped 0, count ≥ P3.8's
- [ ] C-3 guard: `grep -rn "Platform\.is\|kIsWeb\|defaultTargetPlatform" lib/ | grep -v perf_driver ; echo RC=$?` → `RC=1`; `Process\.run` additionally allowed in `status_line.dart` only
- [ ] `python3 scripts/build_apps.py 2>&1 | tail -2; echo RC=$?` → macOS green; `python3 scripts/build_apps.py android --release 2>&1 | tail -2; echo RC=$?` → android green
- [ ] `test/image_preload_dual_window_m5_test.dart` green · artifact `scripts/tmp/m6-r1-verify/p4-exit.txt`, HEAD hash recorded

## P5.1 F-25 memory-derived image-cache budget

**Honest constraint stated up front:** `dart:io` (3.9) exposes no platform-neutral total-physical-memory API (`ProcessInfo` is RSS-only). The ruling forbids `Platform.isAndroid` branches. So this task ships the derivation FUNCTION with an injectable memory source, defaulting to the current constant when no source exists — the seam is the deliverable; a future memory probe plugs in without violating C-3. If the implementer finds a real platform-neutral source, use it and cite it; do NOT fake one.

**Files:** Modify `lib/main.dart:25-29` · Create `lib/services/cache_budget.dart` · Test: `test/cache_budget_test.dart`.

- [ ] **Step 1 (red):**

```dart
  test('budget derivation: floor 256MiB, ceiling 768MiB, quarter of physical',
      () {
    expect(imageCacheBudgetBytes(physicalMemoryBytes: null), 768 << 20);
    expect(imageCacheBudgetBytes(physicalMemoryBytes: 32 * (1 << 30)),
        768 << 20); // capped at the measured-corpus ceiling (main.dart docs)
    expect(imageCacheBudgetBytes(physicalMemoryBytes: 2 * (1 << 30)),
        512 << 20); // 2GiB/4
    expect(imageCacheBudgetBytes(physicalMemoryBytes: 512 << 20),
        256 << 20); // floor: below this the M5 no-re-decode guarantee dies
  });
```

- [ ] **Step 2:** implement `imageCacheBudgetBytes({int? physicalMemoryBytes})` as the pure clamp above (`null → 768<<20`, else `(physical/4).clamp(256<<20, 768<<20)`); `configureImageCache()` calls it with `physicalMemoryBytes: null` and a comment naming the missing-API fact + this task ID. The 768 MiB ceiling keeps `docs/logs/2026-08-23/cache-sizing-estimate.md` §A.4/§A.6 sizing valid on desktop.
- [ ] **Step 3:** green + commit `feat(m6): image-cache budget behind a memory-derivation seam (F-25)`.

## P5.2 Test re-baseline audit (C-4)

- [ ] Sweep Appendix B: every row's disposition executed in P2.4/P3.3/P3.4/P3.6 — verify each with `git log --oneline -- <test file>` and confirm `baseline-registry.md` carries: per-deleted-case reason, new sha256 for every changed frozen file, in the SAME commit as the change (`git show --stat` the relevant commits into the artifact).
- [ ] `scripts/tmp/dng_nav_probe_test.dart` (frozen `05565d33…`, gitignored): inspect NOW — delete only cases conflicting with parity, re-register its sha in `baseline-registry.md`.
- [ ] Unchanged frozen files still match their registered sha: run the registry's own verification command list; `RC=$?` per file into `scripts/tmp/m6-r1-verify/p5-baseline.txt`.
- [ ] `unit_test.md`: TC matrix updated — deleted cases marked with reasons, new cases (P2.1/P2.3/P2.5/P3.7 tests) registered with TC numbers.
- [ ] `memory.md`: new AD entry recording the M6 contract (unified Dart core, the three declared exceptions, U-11/U-12 losses) + G-entry for the G3 instrument lesson (route mismatch produced a false HARD FAIL). Commit `docs(m6): re-baseline registry + AD entry`.

## P5.3 Post-merge verification + full gate re-run

- [ ] Branch-side: full `flutter analyze` + `flutter test -j 1` green with `RC` lines in the artifact.
- [ ] **Merge is a user decision** — present the round summary and wait; never self-merge (task list's final task is user-closed).
- [ ] After the user merges: re-run BOTH on `main` (lessons-learned 2026-08-16: in-branch green does not prove cross-branch composition) — same commands, fresh artifact, HEAD hash recorded.
- [ ] Gate re-run against the SHIPPED build: the native comparator no longer exists, so G′′ is a REGRESSION gate against P2.6's own Dart numbers: same sample set, same routes, pre-registered rule "every per-sample median ≤ 1.5 × its P2.6 median" (drift detection, not parity). Provenance by content marker: `git rev-parse HEAD` + the P2.1 producer's presence proven by a test-run marker, never mtime (lessons-learned 2026-08-23).
- [ ] Round report to the user: AC table per phase, parking-lot (accumulated), capability losses restated (U-11/U-12), P-2 still open (Linux `.so`). (The synchronous-read and JPEG sub-ms questions were ruled on 2026-08-24 5th pass — matrix P-9/P-10 — and are closed.)

---

## Appendix A — Gate methodology (carried forward, authoritative for every gate run in this plan)

> **User amendment (2026-08-24 7th pass, matrix P-13):** the decision rule gains an absolute floor — **any per-sample decode latency under 75 ms PASSES outright, regardless of the 2.0× ratio clause**. The ratio clause only bites at ≥75 ms absolute.

Pre-registration block written into the artifact **above** any number, before the run: sample list with sizes; content marker proving which build of each implementation was measured (never mtime); metric = per-sample median of best-of-N warm runs plus the cold first-touch run reported separately; `dart compile exe` where `dart:ui` is not needed (state which was used). Decision rule, verbatim, before numbers exist: **PASS** iff for every sample `dart_median_ms <= 2.0 × native_median_ms` **and** `dart_output_bytes >= native_output_bytes` (vacuous for decoded-pixel outputs — the dims clause constrains those) **and** `dart_dims == native_dims`. **HARD FAIL** (no aggregation, no re-run) if any sample where native produces an image yields null in Dart. `RC=$?` self-captured inside the artifact on the line immediately after each command. No re-running with different parameters until it passes; a second run only for a stated instrument-bias question, both runs stay in the artifact. Re-gate rounds (P2.6, P5.3) re-freeze their route/parameter changes in a fresh pre-registration block before running.

## Appendix B — Test disposition table (C-4; applied inside P3.3/P5.2)

| Test | Disposition |
|---|---|
| `test/native_thumbnail_service_test.dart` (whole file) | **Delete file** — channel under test is deleted. Replace with a Dart test that the extractor-miss path yields the variant with the probe's orientation (written in P2.1) |
| `test/dng_nav_probe_m3_test.dart:180-203` (TC-089, frozen) | **Delete this case only**; TC-088 (`:144-176`) stays; re-register file sha256 |
| `scripts/tmp/dng_nav_probe_test.dart` (frozen, gitignored) | Inspect at P3.3 time; delete only conflicting cases, re-register sha |
| `test/image_preload_controller_test.dart:743`, `:762`, `:1204`, `:1216` | **Rewrite** channel mocks to the Dart source seam; degrade-never-blank behaviour must survive |
| `test/image_preload_scheduling_m4_test.dart:389-436` | **Rewrite**, keep scheduling assertions |
| `test/sidebar_view_test.dart:119` | ~~Rewrite against the unified sidebar path~~ **PREMISE STALE (found in P2.4 execution):** the `:119` channel mock belongs to the EXPORT test in that file, not the sidebar; no sidebar channel-mock ever existed (the file's `stateForFolder` helper injects a fake loader). P2.4 added a net-new proof test instead (commit 318840a). The `:119` export mock is rewritten with P3.6, whose seam change owns it |
| `test/thumbnail_export_service_test.dart` | **Rewrite** with P3.6's encoder seam |
| `test/exif_metadata_service_test.dart` (channel half) | **Delete channel cases**, keep isolate-fallback cases |
| `test/image_preload_controller_m3_amend3_test.dart` (frozen) | **Keep unchanged** — programs against the type, not the platform |
| `test/image_preload_dual_window_m5_test.dart` | **Keep; regression gate in every phase** |

## Appendix C — Risks (carried forward)

R-1 Dart cheap-DNG slower than Swift → G1/V1 already PASS; R-3 sync reads on UI isolate jank → V1 chosen by frozen cascade, UI question escalated to user (parked); R-4 FFI absent on Linux/iOS → uniform explicit no-decoder state (P-2 open); R-5 capability losses are user-ruled, never silent; R-6 test deletions only under the one-platform-assertion rule; R-7 oversized guard re-implemented (P3.7); R-8 scope beyond budget → phases P4/P5 items deferrable as separate contracts; R-9 package non-existence (F-05/F-12/F-16) already resolved by rulings/verification.
