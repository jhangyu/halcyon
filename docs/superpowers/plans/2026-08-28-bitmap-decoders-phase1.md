# Bitmap Decoders — Phase 1 (WebP + TIFF) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use podium:team-spawn (recommended) or podium:team-fable to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `.webp`, `.tif` and `.tiff` files appear in Halcyon's sidebar and detail view through the existing image pipeline — same star/trash marks, same preload window, same export path — instead of being filtered out at folder scan.

**Architecture:** WebP is registry-only: it joins the engine-decodable bitstream set and flows through the existing `NativeImageBytes` arm untouched. TIFF has no cheap encoded bitstream, so it enters through the **existing** `NativeImageNeedsRawDecode` → `DngFullDecoder` seam; a new dispatching decoder (`lib/services/image_pipeline/full_decoder_dispatch.dart`) routes `.tif`/`.tiff` to `package:image`'s `decodeTiff` on a worker isolate and everything else to the existing Ceyx RAW decode. No fourth `NativeImageResult` variant, no second decoder typedef.

**Tech Stack:** Flutter 3.35.1 / Dart, `package:image ^4.9.2` (already a dependency), `package:path`, `package:exif ^3.3.0`, `flutter_test`.

**Source spec:** `docs/superpowers/specs/2026-08-28-bitmap-decoders-design.md` (signed off). Sections 4, 5, 6, 9, 10 are phase-1 relevant. Do not reopen spec decisions.

## Global Constraints

- **Working tree:** `/Users/jhangyu/project/Halcyon-decoders` (git worktree, branch `feature/bitmap-decoders`). Never touch `/Users/jhangyu/project/Halcyon` except read-only reads of `docs/sop/`.
- **`flutter analyze` must report 0 issues**, over `lib/`, `test/` **and** `tool/` — all three roots are covered by static analysis.
- **`flutter test -j 1` must end with `All tests passed!`**, `RC=0`, and declared test count == executed count.
- **No new pub dependencies in phase 1.** `image: ^4.9.2` and `exif: ^3.3.0` are already in `pubspec.yaml:49-50`; adding anything else is a plan violation.
- **`NativeImageResult` keeps exactly three variants** (`NativeImageBytes`, `NativeImageNeedsRawDecode`, `NativeImageFailure`). `lib/services/image_pipeline/image_source_types.dart` must be **unchanged** by this plan — `git diff --stat` must not list it.
- **The sidebar never receives `NativeImageNeedsRawDecode`.** `dartImageLoad` emits that variant only for `purpose == ImageRequestPurpose.preview`, never for `sidebarThumbnail`, never for `export`.
- **AD-021 and AD-022 gates stay on `isDecodablePath`.** The `minLongEdge` strict-preview floor and the `declaredPreviewsUnreadable` finding remain gated on `SupportedPhotoFormats.isDecodablePath`, not on the new `hasFullDecodeRoute`.
- **Decoded-pixel budget: `1500000000` bytes** (`w * h * 4 > 1500000000` is a refusal). It moves with the widened escape hatch and therefore now covers TIFF; the sized sidebar decoder must apply the same ceiling itself.
- **`dart_image_loader.dart` stays free of `dart:io` `Platform` checks** (contract C-3).
- **Format lists are derived, never restated.** `decodableExtensions` derives from `kSupportedDecodeExtensions`; the loader's bitstream branch must test set membership, not `endsWith` literals.
- **`.heic`/`.heif` are phase 2 and must NOT appear anywhere in phase-1 code.** `grep -rn "heic\|heif" lib/` must return nothing.
- **No renaming** of `DngFullDecoder` / `DngSizedDecoder` / `DecodedRgba` (parked by the 2026-08-26 contract).
- **Commits are pathspec'd only:** `git commit -- <paths>`. `git stash`, `git reset`, `git checkout --`, `git clean` and `git add -A` are **forbidden** in every step of this plan; the tree is shared.
- **SOP docs (`memory.md`, `unit_test.md`, `file_index.md`) live at `/Users/jhangyu/project/Halcyon/docs/sop/`, are gitignored, and are edited in place at MERGE time only (Task 6)** — never during worktree work, never in a commit.
- Test names must literally contain their `TC-3NN` identifier so `flutter test` output is greppable for acceptance.

---

## File Structure

| Path | Responsibility | Task |
|---|---|---|
| `lib/models/supported_photo_formats.dart` | Format policy: which extensions are scanned, which are engine bitstreams, which have a full-decode route | 1 |
| `lib/services/image_pipeline/dng_decode_contract.dart` | Adds `kDecodedPixelBudgetBytes` so loader and dispatcher share one number | 2 |
| `lib/services/image_pipeline/dart_image_loader.dart` | Bitstream branch derives from the registry; new bitmap-container branch before the RAW preview walk | 2 |
| `lib/services/image_pipeline/full_decoder_dispatch.dart` | **NEW.** Dispatching `DngFullDecoder`/`DngSizedDecoder`: TIFF arm + RAW arm + `UnsupportedError` | 3 |
| `lib/providers/app_state.dart`, `lib/main.dart` | Composition root wires the dispatching decoders | 4 |
| `lib/services/image_pipeline/image_preload_controller.dart` | Sidebar sized-decode gate widens to `hasFullDecodeRoute` | 4 |
| `test/support/synthetic_dng.dart` | Adds `buildSyntheticTiffHeader` (IFD0-only TIFF with declared extent + orientation) | 2 |
| `test/models/supported_photo_formats_test.dart` | TC-302, TC-304 | 1 |
| `test/services/image_pipeline/dart_image_loader_test.dart` | TC-303, TC-305, TC-306, TC-307, TC-313 | 2 |
| `test/services/image_pipeline/full_decoder_dispatch_test.dart` | **NEW.** TC-308, TC-309 | 3 |
| `test/services/image_pipeline/bitmap_decode_wiring_test.dart` | **NEW.** Task-4 wiring pins | 4 |
| `test/services/image_pipeline/photo_source_test.dart` | TC-310 | 5 |
| `test/services/image_pipeline/decoded_rgba_image_provider_test.dart` | TC-311 | 5 |
| `test/services/library/photo_export_service_test.dart` | TC-312 | 5 |
| `README.md`, `README.zh-TW.md` | Supported-formats sections | 6 |

---

## Task 1: Format registry — WebP bitstream set, TIFF bitmap-decode set

**Files:**
- Modify: `lib/models/supported_photo_formats.dart:30-50` (add sets and predicates), `:34-38` (`preferredLoadExtensions`)
- Test: `test/models/supported_photo_formats_test.dart`

**Interfaces:**
- Consumes: `SupportedPhotoFormats.decodableExtensions` (existing, derived from `kSupportedDecodeExtensions`), `SupportedPhotoFormats.rawExtensions` (existing).
- Produces:
  ```dart
  static const Set<String> engineBitstreamExtensions; // {'.jpg', '.jpeg', '.png', '.webp'}
  static const Set<String> bitmapDecodeExtensions;    // {'.tif', '.tiff'}
  static final Set<String> fullDecodeExtensions;      // decodableExtensions ∪ bitmapDecodeExtensions
  static bool isEncodedBitstreamPath(String path);
  static bool isBitmapDecodePath(String path);
  static bool hasFullDecodeRoute(String path);
  ```
  `supportedExtensions` becomes `engineBitstreamExtensions ∪ bitmapDecodeExtensions ∪ rawExtensions`. `preferredLoadExtensions` becomes `['.jpg', '.jpeg', '.png', '.webp']`.

**Behavior:**
`engineBitstreamExtensions` is the single definition of "the Flutter engine's own codec can read this file's bytes directly". It is consumed both by the folder-scan whitelist (`supportedExtensions`) and by `dart_image_loader.dart`'s bitstream branch (Task 2), so the two cannot desync — the same derive-don't-restate rule the 2026-08-26 contract imposed on the RAW list.

`bitmapDecodeExtensions` is "already-rendered bitmap container with no cheap encoded bitstream, but a full decoder can turn it into RGBA". Phase 1 contains `.tif`/`.tiff` only; `.heic`/`.heif` join it in phase 2 and **must not be added here now**.

`preferredLoadExtensions` is the sibling-group preference order used by `bestFileToLoad`. `.webp` is appended **after** `.png`: a WebP sibling of a RAW should be preferred over the RAW (it is a rendered bitstream), but a JPEG or PNG sibling stays preferred over WebP because those are what cameras and prior exports produce. `.tif`/`.tiff` are deliberately **not** in `preferredLoadExtensions` — a TIFF sibling must not outrank a JPEG sibling; `bestFileToLoad`'s existing "any supported file" fallback (`supported_photo_formats.dart:64-71`) already picks it up when the group is TIFF-only.

Edge case — `bestFileToLoad` with `['a.dng', 'a.webp']`: the preference loop matches `.webp` and returns it; the fallback branch is not reached. This is the only reason `.webp` must be in `preferredLoadExtensions` rather than relying on the fallback, whose `supported.first` is list-order dependent and would return the DNG.

Edge case — extension case: every predicate lowercases via `p.extension(path).toLowerCase()`, so `A.WEBP` and `B.TIF` are matched. Unchanged from existing behaviour.

**Constraints:**
- `engineBitstreamExtensions` and `bitmapDecodeExtensions` are `static const`; the derived sets stay `static final` + `Set.unmodifiable` (folder scans call these predicates per directory entry — they must not re-allocate per call, and callers must not be able to corrupt process-global format policy via `.add`).
- `decodableExtensions` stays derived from `kSupportedDecodeExtensions`. Do not hand-write RAW extensions.
- No `.heic`/`.heif` anywhere.
- D2 browse-only extensions (`.cr2`, `.iiq`, `.mrw`) keep their existing membership: in `rawExtensions` and `supportedExtensions`, not in `decodableExtensions`, and now also not in `fullDecodeExtensions`.

**Acceptance criteria:**
- [ ] `test/models/supported_photo_formats_test.dart` contains tests named with `TC-302` and `TC-304` and both pass.
- [ ] `flutter test test/models/supported_photo_formats_test.dart` prints `All tests passed!`.
- [ ] `grep -n "webp" lib/models/supported_photo_formats.dart` shows `.webp` in `engineBitstreamExtensions` and in `preferredLoadExtensions`, and nowhere else.
- [ ] `grep -n "bitmapDecodeExtensions" lib/models/supported_photo_formats.dart` shows `{'.tif', '.tiff'}`.
- [ ] `grep -rn "heic\|heif" lib/` returns no matches.
- [ ] `flutter analyze` reports 0 issues.

**Steps:**

- [ ] **Step 1: Write the failing tests**

Append to `test/models/supported_photo_formats_test.dart`, inside the existing `void main() { … }` body:

```dart
  group('phase-1 bitmap formats', () {
    test('TC-302: .webp/.tif/.tiff are supported, .xyz is not', () {
      for (final path in ['a.webp', 'b.tif', 'c.tiff', 'D.WEBP', 'E.TIF']) {
        expect(
          SupportedPhotoFormats.isSupportedPath(path),
          isTrue,
          reason: '$path must survive the folder scan whitelist',
        );
      }
      expect(SupportedPhotoFormats.isSupportedPath('d.xyz'), isFalse);
      expect(SupportedPhotoFormats.isSupportedPath('e.heic'), isFalse,
          reason: 'HEIC is phase 2 and must not be claimed yet');
    });

    test('TC-302: .webp is an engine bitstream, .tif/.tiff are bitmap-decode',
        () {
      expect(SupportedPhotoFormats.isEncodedBitstreamPath('a.webp'), isTrue);
      expect(SupportedPhotoFormats.isBitmapDecodePath('a.webp'), isFalse);
      expect(SupportedPhotoFormats.isEncodedBitstreamPath('b.tif'), isFalse);
      expect(SupportedPhotoFormats.isBitmapDecodePath('b.tif'), isTrue);
      expect(SupportedPhotoFormats.isBitmapDecodePath('c.tiff'), isTrue);
      expect(SupportedPhotoFormats.bitmapDecodeExtensions, {'.tif', '.tiff'});
    });

    test('TC-302: hasFullDecodeRoute covers RAW and TIFF but not D2/bitstream',
        () {
      expect(SupportedPhotoFormats.hasFullDecodeRoute('b.tif'), isTrue);
      expect(SupportedPhotoFormats.hasFullDecodeRoute('c.tiff'), isTrue);
      expect(SupportedPhotoFormats.hasFullDecodeRoute('a.dng'), isTrue);
      for (final path in ['x.cr2', 'y.iiq', 'z.mrw']) {
        expect(
          SupportedPhotoFormats.hasFullDecodeRoute(path),
          isFalse,
          reason: 'D2 browse-only containers have no decode route',
        );
      }
      expect(SupportedPhotoFormats.hasFullDecodeRoute('a.webp'), isFalse);
      expect(SupportedPhotoFormats.hasFullDecodeRoute('a.jpg'), isFalse);
    });

    test('TC-304: bestFileToLoad prefers .jpg over .webp, .webp over .dng', () {
      File f(String name) => File(name);
      expect(
        SupportedPhotoFormats.bestFileToLoad([f('a.webp'), f('a.jpg')])!.path,
        'a.jpg',
      );
      expect(
        SupportedPhotoFormats.bestFileToLoad([f('a.png'), f('a.webp')])!.path,
        'a.png',
      );
      // The DNG is listed FIRST: a fallback that returns `supported.first`
      // would return the DNG, so this only passes if .webp is in
      // preferredLoadExtensions.
      expect(
        SupportedPhotoFormats.bestFileToLoad([f('a.dng'), f('a.webp')])!.path,
        'a.webp',
      );
      // TIFF is deliberately NOT preferred over a JPEG sibling.
      expect(
        SupportedPhotoFormats.bestFileToLoad([f('a.tif'), f('a.jpg')])!.path,
        'a.jpg',
      );
    });
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/models/supported_photo_formats_test.dart`
Expected: FAIL — compile errors `The getter 'isEncodedBitstreamPath' isn't defined for the type 'SupportedPhotoFormats'` (and the same for `isBitmapDecodePath`, `hasFullDecodeRoute`, `bitmapDecodeExtensions`).

- [ ] **Step 3: Implement the registry change**

Replace `lib/models/supported_photo_formats.dart:30-50` (from `static final Set<String> supportedExtensions` through the closing brace of `isDecodablePath`) with:

```dart
  /// Formats the Flutter engine's own codec (Skia/Impeller `SkCodec`) reads
  /// directly from the file's bytes. ONE definition, consumed both by the
  /// folder-scan whitelist below and by `dart_image_loader.dart`'s
  /// encoded-bitstream branch, so the two cannot desync (the same
  /// "derive, don't restate" rule the 2026-08-26 contract imposed on the RAW
  /// list). Animated WebP is decoded to its first frame only; Halcyon is a
  /// still-photo triage tool.
  static const Set<String> engineBitstreamExtensions = {
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
  };

  /// Already-rendered bitmap containers with no cheap encoded bitstream that a
  /// full decoder can still turn into RGBA. Phase 1 is TIFF via
  /// `package:image`; `.heic`/`.heif` join this set in phase 2 (native
  /// libheif) and must NOT be added before that decoder exists.
  static const Set<String> bitmapDecodeExtensions = {'.tif', '.tiff'};

  static final Set<String> supportedExtensions = Set.unmodifiable(
    engineBitstreamExtensions.union(bitmapDecodeExtensions).union(rawExtensions),
  );

  /// Everything with a route to RGBA through the `DngFullDecoder` seam:
  /// engine-decodable RAW plus the bitmap containers above. Deliberately
  /// distinct from [decodableExtensions] — AD-021's `minLongEdge` floor and
  /// AD-022's malformed-container finding stay gated on THAT set, because both
  /// are statements about embedded previews in a RAW container.
  static final Set<String> fullDecodeExtensions = Set.unmodifiable(
    decodableExtensions.union(bitmapDecodeExtensions),
  );

  /// `.webp` sits AFTER `.png`: a WebP sibling of a RAW should win (it is a
  /// rendered bitstream), but a JPEG or PNG sibling stays preferred because
  /// those are what cameras and prior exports produce. `.tif`/`.tiff` are
  /// absent on purpose — a TIFF must not outrank a JPEG sibling, and
  /// [bestFileToLoad]'s supported-file fallback already picks it up when the
  /// whole group is TIFF.
  static const preferredLoadExtensions = <String>[
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
  ];

  static bool isSupportedPath(String path) {
    return supportedExtensions.contains(p.extension(path).toLowerCase());
  }

  static bool isRawPath(String path) {
    return rawExtensions.contains(p.extension(path).toLowerCase());
  }

  static bool isDecodablePath(String path) {
    return decodableExtensions.contains(p.extension(path).toLowerCase());
  }

  static bool isEncodedBitstreamPath(String path) {
    return engineBitstreamExtensions.contains(p.extension(path).toLowerCase());
  }

  static bool isBitmapDecodePath(String path) {
    return bitmapDecodeExtensions.contains(p.extension(path).toLowerCase());
  }

  static bool hasFullDecodeRoute(String path) {
    return fullDecodeExtensions.contains(p.extension(path).toLowerCase());
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/models/supported_photo_formats_test.dart`
Expected: PASS — output ends with `All tests passed!`.

- [ ] **Step 5: Verify the whole suite and the analyzer are still clean**

Run: `flutter analyze`
Expected: `No issues found!`

Run: `flutter test -j 1`
Expected: `All tests passed!` — if an existing test asserted `supportedExtensions` or `preferredLoadExtensions` by exact literal, update that assertion to include `.webp`/`.tif`/`.tiff`; do not narrow the production sets to satisfy it.

- [ ] **Step 6: Commit**

```bash
git -C /Users/jhangyu/project/Halcyon-decoders commit \
  -m "feat(formats): add .webp bitstream and .tif/.tiff bitmap-decode sets" \
  -- lib/models/supported_photo_formats.dart \
     test/models/supported_photo_formats_test.dart
git -C /Users/jhangyu/project/Halcyon-decoders status --porcelain
```

The `-m` MUST come before `--`; anything after `--` is a pathspec. Both files are already tracked, so no `git add` is needed. The `status --porcelain` check confirms neither file is left half-staged (2026-08-25 lesson). Never run `git add -A`, `git stash`, `git reset`, `git checkout --` or `git clean` — teammates have uncommitted work in this tree.
```

---

## Task 2: Loader — derive the bitstream branch, add the bitmap-container branch

**Files:**
- Modify: `lib/services/image_pipeline/dng_decode_contract.dart` (append `kDecodedPixelBudgetBytes`)
- Modify: `lib/services/image_pipeline/dart_image_loader.dart:38-42` (bitstream test), `:44-57` (insert bitmap branch), `:174` (use the constant)
- Modify: `test/support/synthetic_dng.dart` (append `buildSyntheticTiffHeader`)
- Test: `test/services/image_pipeline/dart_image_loader_test.dart`

**Interfaces:**
- Consumes: `SupportedPhotoFormats.isEncodedBitstreamPath`, `SupportedPhotoFormats.isBitmapDecodePath` (Task 1); `DngEmbeddedJpegExtractor.readImageDimensions(String) → Future<({int width, int height})?>`; `DngEmbeddedJpegExtractor.readOrientation(String) → Future<int?>`.
- Produces:
  ```dart
  // lib/services/image_pipeline/dng_decode_contract.dart
  const int kDecodedPixelBudgetBytes = 1500000000;

  // test/support/synthetic_dng.dart
  Uint8List buildSyntheticTiffHeader({
    required int width,
    required int height,
    int orientation = 1,
    bool bigEndian = false,
  });
  ```
  `dartImageLoad`'s signature is unchanged: `Future<NativeImageResult> dartImageLoad(String path, {required ImageRequestPurpose purpose})`.

**Behavior:**
Two edits to `dartImageLoad`, in this order.

1. **Bitstream branch derives from the registry.** Replace the three hard-coded `lower.endsWith(...)` calls with `SupportedPhotoFormats.isEncodedBitstreamPath(path)`. The `final lower = path.toLowerCase();` local becomes unused and must be deleted (otherwise `flutter analyze` flags it). Net effect: `.webp` now takes the `NativeImageBytes(await File(path).readAsBytes())` arm for **all three** purposes, exactly as `.jpg` does.

2. **New bitmap-container branch**, placed *after* the bitstream return and *before* the `sidebarThumbnail` embedded-preview branch:
   - `purpose != ImageRequestPurpose.preview` → `NativeImageFailure('NO_THUMBNAIL', 'no embedded candidate')`. This is what preserves the invariant that the sidebar never sees `NativeImageNeedsRawDecode`; the sidebar's own sized-decode fallback (Task 4) is the only TIFF thumbnail route.
   - Otherwise read the declared extent with `readImageDimensions`; if `dims != null && dims.width * dims.height * 4 > kDecodedPixelBudgetBytes` → `NativeImageFailure('IMAGE_TOO_LARGE', 'decode exceeds the decoded-pixel budget')`. A `null` extent (unreadable IFD0) waves through, matching the existing RAW behaviour at `:173-182`.
   - Otherwise `NativeImageNeedsRawDecode(exifOrientation: await readOrientation(path) ?? kDefaultExifOrientation)`, with `declaredPreviewsUnreadable` left at its `false` default.

   Placing the branch **before** the preview walk is what implements the spec's "no embedded-preview walk" for TIFF: `DngEmbeddedJpegExtractor` is a RAW-preview walker, and a scanner TIFF's IFD0 *is* the image, so "extract the embedded preview" is meaningless there. It also means `probe.malformed` is never computed for a TIFF, so `declaredPreviewsUnreadable` is structurally always `false` for bitmap containers — which is exactly what keeps AD-022's two RAW-specific end states untouched.

`readImageDimensions` and `readOrientation` already perform a bounded IFD0 walk on TIFF-structured files (tags `0x0100`/`0x0101`/`0x0112`) and work on a plain TIFF unchanged. No new parser.

The AD-021 `strictPreview` guard at `:126-128` and the RAW `NativeImageNeedsRawDecode` return at `:171-195` are **not touched** — both stay gated on `isDecodablePath`.

`buildSyntheticTiffHeader` emits a minimal TIFF: byte-order marker, magic 42, IFD0 offset 8, then exactly three IFD0 entries in ascending tag order — `0x0100` ImageWidth (LONG), `0x0101` ImageLength (LONG), `0x0112` Orientation (SHORT) — then a zero next-IFD offset. It deliberately writes **no** `0x0103` Compression tag, so the extractor's candidate walk skips IFD0 (the same property `buildSyntheticDng` relies on) and it carries **no** pixel data, so `img.decodeTiff` on it returns null — which is precisely the "corrupt TIFF" input Task 5 needs. It reuses the existing private `_Writer` in that file.

**Constraints:**
- No `dart:io` `Platform` check may be introduced (contract C-3).
- `dartImageLoad` still never throws: every failure is a `NativeImageFailure`; the outer `try`/`catch` stays.
- `lib/services/image_pipeline/image_source_types.dart` must remain byte-identical.
- The budget literal `1500000000` must exist in exactly one place after this task (`kDecodedPixelBudgetBytes`); `dart_image_loader.dart:174` references the constant.
- Nothing in `lib/` may import `test/support/synthetic_dng.dart`.

**Acceptance criteria:**
- [ ] `test/services/image_pipeline/dart_image_loader_test.dart` contains tests named with `TC-303`, `TC-305`, `TC-306`, `TC-307`, `TC-313`, and all pass.
- [ ] `flutter test test/services/image_pipeline/dart_image_loader_test.dart` prints `All tests passed!`.
- [ ] `grep -n "isDecodablePath" lib/services/image_pipeline/dart_image_loader.dart` still shows the `strictPreview` guard and the RAW `NativeImageNeedsRawDecode` branch.
- [ ] `grep -c "1500000000" lib/services/image_pipeline/dart_image_loader.dart` returns `0`.
- [ ] `git diff --stat -- lib/services/image_pipeline/image_source_types.dart` produces no output.
- [ ] `grep -c "class .* extends NativeImageResult" lib/services/image_pipeline/image_source_types.dart` returns `3`.
- [ ] `flutter analyze` reports 0 issues.

**Steps:**

- [ ] **Step 1: Add the shared budget constant**

Append to `lib/services/image_pipeline/dng_decode_contract.dart`:

```dart
/// The app's only defence against an OOM from a container header that claims
/// an absurd extent: refuse when `width * height * 4` exceeds this many bytes.
///
/// It lives here, next to the decoder seam, because TWO layers must agree on
/// it: `dart_image_loader.dart` checks it before returning
/// [NativeImageNeedsRawDecode] on the preview path, and the TIFF arm of
/// `full_decoder_dispatch.dart` checks it again on the sized sidebar path,
/// which the loader's check never reaches. Two spellings of the same number
/// is how one of them silently drifts.
const int kDecodedPixelBudgetBytes = 1500000000;
```

- [ ] **Step 2: Add the synthetic TIFF builder**

Append to `test/support/synthetic_dng.dart`:

```dart
/// Builds a minimal IFD0-only TIFF: byte-order marker, magic 42, IFD0 at
/// offset 8, three ascending-tag entries (ImageWidth 0x0100 LONG, ImageLength
/// 0x0101 LONG, Orientation 0x0112 SHORT), then a zero next-IFD offset.
///
/// Two properties are load-bearing and must not be "fixed":
///  - NO Compression tag (0x0103), so `DngEmbeddedJpegExtractor`'s candidate
///    walk skips IFD0 exactly as it does for [buildSyntheticDng].
///  - NO pixel data, so `img.decodeTiff` returns null on it — this is the
///    "corrupt TIFF" input the permanent-miss tests need, and it is what lets
///    a 30000x30000 extent be declared in 26 bytes.
Uint8List buildSyntheticTiffHeader({
  required int width,
  required int height,
  int orientation = 1,
  bool bigEndian = false,
}) {
  const headerLength = 8;
  const entryCount = 3;
  final total = headerLength + 2 + entryCount * 12 + 4;
  final out = Uint8List(total);
  final w = _Writer(out, bigEndian);

  final marker = bigEndian ? 0x4D : 0x49;
  out[0] = marker;
  out[1] = marker;
  w.u16(2, 42);
  w.u32(4, headerLength);

  w.u16(headerLength, entryCount);
  var entryPos = headerLength + 2;
  entryPos = w.entryLongInline(entryPos, 0x0100, width);
  entryPos = w.entryLongInline(entryPos, 0x0101, height);
  entryPos = w.entryShortInline(entryPos, 0x0112, [orientation]);
  w.u32(entryPos, 0); // next-IFD offset: none

  return out;
}
```

- [ ] **Step 3: Write the failing loader tests**

Append to `test/services/image_pipeline/dart_image_loader_test.dart`, inside `void main() { … }`:

```dart
  group('phase-1 bitmap formats', () {
    late Directory tmp;

    setUpAll(() {
      tmp = Directory.systemTemp.createTempSync('halcyon_bitmap_loader');
    });
    tearDownAll(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    Future<String> writeBytes(String name, Uint8List bytes) async {
      final file = File('${tmp.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    }

    test('TC-303: a .webp takes the encoded-bitstream branch for all three '
        'purposes and returns the file\'s own bytes', () async {
      // Content need not be a valid WebP: this branch never decodes, it only
      // hands the bytes to the engine. Using a marker payload proves the
      // returned buffer is the FILE's bytes, not something re-encoded.
      final marker = Uint8List.fromList([
        0x52, 0x49, 0x46, 0x46, 0xDE, 0xAD, 0xBE, 0xEF,
      ]);
      final path = await writeBytes('a.webp', marker);
      for (final purpose in ImageRequestPurpose.values) {
        final result = await dartImageLoad(path, purpose: purpose);
        expect(result, isA<NativeImageBytes>(), reason: 'purpose $purpose');
        expect((result as NativeImageBytes).bytes, marker);
      }
    });

    test('TC-305: a .tif at preview returns NeedsRawDecode with the IFD0 '
        'orientation and declaredPreviewsUnreadable == false', () async {
      final path = await writeBytes(
        'b.tif',
        buildSyntheticTiffHeader(width: 800, height: 600, orientation: 6),
      );
      final result =
          await dartImageLoad(path, purpose: ImageRequestPurpose.preview);
      expect(result, isA<NativeImageNeedsRawDecode>());
      final signal = result as NativeImageNeedsRawDecode;
      expect(signal.exifOrientation, 6);
      expect(
        signal.declaredPreviewsUnreadable,
        isFalse,
        reason: 'a bitmap container is never preview-probed, so AD-022 '
            'cannot apply to it',
      );
    });

    test('TC-305: a .tif with no Orientation tag falls back to 1', () async {
      final path = await writeBytes(
        'b_noorient.tif',
        buildSyntheticTiffHeader(width: 800, height: 600),
      );
      final result =
          await dartImageLoad(path, purpose: ImageRequestPurpose.preview);
      expect(
        (result as NativeImageNeedsRawDecode).exifOrientation,
        kDefaultExifOrientation,
      );
    });

    test('TC-306: a .tif at sidebarThumbnail is a failure and NEVER '
        'NeedsRawDecode', () async {
      final path = await writeBytes(
        'c.tiff',
        buildSyntheticTiffHeader(width: 800, height: 600, orientation: 6),
      );
      final result = await dartImageLoad(
        path,
        purpose: ImageRequestPurpose.sidebarThumbnail,
      );
      expect(result, isNot(isA<NativeImageNeedsRawDecode>()));
      expect(result, isA<NativeImageFailure>());
      expect((result as NativeImageFailure).code, 'NO_THUMBNAIL');
    });

    test('TC-307: a TIFF header declaring 30000x30000 is IMAGE_TOO_LARGE',
        () async {
      final path = await writeBytes(
        'huge.tif',
        buildSyntheticTiffHeader(width: 30000, height: 30000),
      );
      // 30000 * 30000 * 4 == 3.6e9 > 1.5e9. The file is 26 bytes long, so a
      // result other than IMAGE_TOO_LARGE would prove the check ran after a
      // decode attempt rather than before one.
      final result =
          await dartImageLoad(path, purpose: ImageRequestPurpose.preview);
      expect(result, isA<NativeImageFailure>());
      expect((result as NativeImageFailure).code, 'IMAGE_TOO_LARGE');
    });

    test('TC-307: a TIFF just under the budget still routes to the decoder',
        () async {
      // 19364 * 19364 * 4 == 1_499_857_984 < 1_500_000_000. Pins that the
      // comparison is a strict `>` on the budget, not an off-by-one refusal.
      final path = await writeBytes(
        'nearlimit.tif',
        buildSyntheticTiffHeader(width: 19364, height: 19364),
      );
      final result =
          await dartImageLoad(path, purpose: ImageRequestPurpose.preview);
      expect(result, isA<NativeImageNeedsRawDecode>());
    });

    test('TC-313: NativeImageResult still has exactly three variants after '
        'the bitmap-format widening', () {
      // Exhaustive switch with NO default clause: a fourth variant makes this
      // file stop compiling. The counter proves all three arms are live.
      final results = <NativeImageResult>[
        NativeImageBytes(Uint8List(0)),
        const NativeImageNeedsRawDecode(
          exifOrientation: kDefaultExifOrientation,
        ),
        const NativeImageFailure('NO_THUMBNAIL', 'no embedded candidate'),
      ];
      final seen = <String>{};
      for (final r in results) {
        switch (r) {
          case NativeImageBytes():
            seen.add('bytes');
          case NativeImageNeedsRawDecode():
            seen.add('needsRawDecode');
          case NativeImageFailure():
            seen.add('failure');
        }
      }
      expect(seen, {'bytes', 'needsRawDecode', 'failure'});
    });
  });
```

Add `import '../../support/synthetic_dng.dart';` if the file does not already have it (it does, at the existing import block — verify rather than duplicating).

- [ ] **Step 4: Run the tests to verify they fail**

Run: `flutter test test/services/image_pipeline/dart_image_loader_test.dart`
Expected: FAIL — `buildSyntheticTiffHeader` is undefined (until Step 2 lands) and, once it is defined, TC-303 fails with `NativeImageFailure` (`RAW_NO_EMBEDDED_PREVIEW`) instead of `NativeImageBytes`, and TC-305/306/307 fail with `RAW_NO_EMBEDDED_PREVIEW`.

- [ ] **Step 5: Derive the bitstream branch from the registry**

In `lib/services/image_pipeline/dart_image_loader.dart`, replace lines 38-42:

```dart
  final lower = path.toLowerCase();
  final isEncodedBitstream =
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.png');
```

with:

```dart
  // Derived, never restated: the SAME set the folder-scan whitelist uses
  // (`SupportedPhotoFormats.engineBitstreamExtensions`), so a format added to
  // the scan cannot silently miss this branch and fall through to the RAW
  // path. `.webp` joins here in phase 1 — the Flutter engine's codec reads it
  // natively on every platform.
  final isEncodedBitstream = SupportedPhotoFormats.isEncodedBitstreamPath(path);
```

The `lower` local is now unused and MUST be deleted, or `flutter analyze` reports `unused_local_variable`.

- [ ] **Step 6: Add the bitmap-container branch**

In the same file, immediately after the `if (isEncodedBitstream) { return NativeImageBytes(await File(path).readAsBytes()); }` block and **before** the `if (purpose == ImageRequestPurpose.sidebarThumbnail)` block, insert:

```dart
    // Already-rendered bitmap containers (phase 1: TIFF). No embedded-preview
    // walk runs for these at all: `DngEmbeddedJpegExtractor` is a RAW-preview
    // walker, and a scanner TIFF's IFD0 IS the image, so "extract the embedded
    // preview" is meaningless here. Placing the branch above the walk is what
    // makes that structural rather than a comment — and it is also why
    // `declaredPreviewsUnreadable` is always false for a TIFF, leaving
    // AD-022's two RAW-specific end states untouched.
    if (SupportedPhotoFormats.isBitmapDecodePath(path)) {
      if (purpose != ImageRequestPurpose.preview) {
        // The AD-010 invariant, preserved verbatim: NeedsRawDecode is emitted
        // for the preview purpose ONLY. The sidebar's own sized-decode
        // fallback (image_preload_controller.dart) is the only thumbnail
        // route for these files.
        return const NativeImageFailure(
          'NO_THUMBNAIL',
          'no embedded candidate',
        );
      }
      final dims = await DngEmbeddedJpegExtractor.readImageDimensions(path);
      if (dims != null &&
          dims.width * dims.height * 4 > kDecodedPixelBudgetBytes) {
        // The budget moves WITH the escape hatch, so it now covers TIFF. This
        // is stricter than JPEG/WebP on purpose: the TIFF decode happens on
        // the Dart heap in an isolate, where the failure mode is a process
        // OOM rather than an engine-side decode error. A null extent
        // (unreadable IFD0) waves through, exactly as on the RAW path below.
        return const NativeImageFailure(
          'IMAGE_TOO_LARGE',
          'decode exceeds the decoded-pixel budget',
        );
      }
      final orientation = await DngEmbeddedJpegExtractor.readOrientation(path);
      return NativeImageNeedsRawDecode(
        exifOrientation: orientation ?? kDefaultExifOrientation,
        // Structurally false: no preview probe ran, so the container cannot
        // have "declared previews that were all unreadable" (AD-022).
      );
    }
```

Add `import 'dng_decode_contract.dart';` to the file's import block (it currently imports `dng_embedded_jpeg_extractor.dart` and `image_source_types.dart` only).

- [ ] **Step 7: Point the RAW budget check at the shared constant**

In the same file, at the existing RAW branch, replace:

```dart
        if (dims != null && dims.width * dims.height * 4 > 1500000000) {
```

with:

```dart
        if (dims != null &&
            dims.width * dims.height * 4 > kDecodedPixelBudgetBytes) {
```

Nothing else in that branch changes: the `strictPreview` guard and the `purpose == preview && isDecodablePath` gate around the RAW `NativeImageNeedsRawDecode` return stay exactly as they are.

- [ ] **Step 8: Run the tests to verify they pass**

Run: `flutter test test/services/image_pipeline/dart_image_loader_test.dart`
Expected: PASS — `All tests passed!`

- [ ] **Step 9: Verify the frozen-seam and gate invariants mechanically**

```bash
cd /Users/jhangyu/project/Halcyon-decoders
grep -c "class .* extends NativeImageResult" lib/services/image_pipeline/image_source_types.dart   # expect 3
git diff --stat -- lib/services/image_pipeline/image_source_types.dart                              # expect no output
grep -c "1500000000" lib/services/image_pipeline/dart_image_loader.dart                             # expect 0
grep -n "isDecodablePath" lib/services/image_pipeline/dart_image_loader.dart                        # expect the strictPreview guard AND the RAW NeedsRawDecode gate
flutter analyze
flutter test -j 1
```
Expected: the four greps produce the stated values, `No issues found!`, `All tests passed!`.

- [ ] **Step 10: Commit**

```bash
git -C /Users/jhangyu/project/Halcyon-decoders commit \
  -m "feat(loader): route .webp through the bitstream branch and .tif/.tiff through the decode seam" \
  -- lib/services/image_pipeline/dart_image_loader.dart \
     lib/services/image_pipeline/dng_decode_contract.dart \
     test/support/synthetic_dng.dart \
     test/services/image_pipeline/dart_image_loader_test.dart
git -C /Users/jhangyu/project/Halcyon-decoders status --porcelain
```

All four files are tracked, so no `git add` is required.

---

## Task 3: `full_decoder_dispatch.dart` — the dispatching full/sized decoder

**Files:**
- Create: `lib/services/image_pipeline/full_decoder_dispatch.dart`
- Test: `test/services/image_pipeline/full_decoder_dispatch_test.dart` (new)

**Interfaces:**
- Consumes: `DecodedRgba`, `DngFullDecoder`, `DngSizedDecoder`, `kDecodedPixelBudgetBytes` (Task 2) from `dng_decode_contract.dart`; `halcyonDngFullDecoder`, `halcyonDngSizedDecoder` from `dng_decode_service.dart`; `SupportedPhotoFormats.isBitmapDecodePath`, `.isDecodablePath` (Task 1); `DngEmbeddedJpegExtractor.readImageDimensions`.
- Produces:
  ```dart
  typedef TiffBytesDecoder =
      Future<DecodedRgba> Function(Uint8List bytes, {int? maxDim});

  Future<DecodedRgba> decodeTiffBytes(Uint8List bytes, {int? maxDim});

  Future<DecodedRgba> decodeTiffFull(
    String path, {
    TiffBytesDecoder decodeBytes,
  });

  Future<DecodedRgba> decodeTiffSized(
    String path, {
    required int maxDim,
    TiffBytesDecoder decodeBytes,
  });

  Future<DecodedRgba> dispatchFullDecode(
    String path, {
    DngFullDecoder rawArm,
    DngFullDecoder tiffArm,
  });

  Future<DecodedRgba> dispatchSizedDecode(
    String path, {
    required int maxDim,
    DngSizedDecoder rawArm,
    DngSizedDecoder tiffArm,
  });

  const DngFullDecoder halcyonFullDecoder = dispatchFullDecode;
  const DngSizedDecoder halcyonSizedDecoder = dispatchSizedDecode;
  ```

**Behavior:**
`dispatchFullDecode` / `dispatchSizedDecode` route on extension:
```
ext in bitmapDecodeExtensions (.tif/.tiff) -> tiffArm
ext in decodableExtensions   (.dng/.arw/…) -> rawArm
otherwise                                   -> throw UnsupportedError
```
The `UnsupportedError` is the spec's designated degradation path: `photo_source.dart`'s step-3b `catch` converts any decoder throw into the uniform permanent miss (`payload: null, deferred: false, failureCode: null`), and the sidebar's `catch (_)` at `image_preload_controller.dart:1082-1087` converts it into a permanent thumbnail miss. The D3 `kNoNativeDecoderCode` state stays reserved for `dngDecoder == null` and is not reachable from here.

The `rawArm` / `tiffArm` / `decodeBytes` named parameters exist **only** so tests can inject fakes without loading the real Ceyx dylib or writing multi-gigabyte fixtures. Production always uses the defaults. Because they are optional named parameters, the tear-offs `dispatchFullDecode` / `dispatchSizedDecode` are still subtypes of `DngFullDecoder` / `DngSizedDecoder`, which is what lets `halcyonFullDecoder` / `halcyonSizedDecoder` be plain `const` aliases with no wrapper closure.

`decodeTiffBytes` runs `img.decodeTiff` inside `Isolate.run` (the pattern `photo_export_service.dart:88-127` already uses — pure CPU on `package:image` must not block the UI isolate). Page 0 only: `decodeTiff` defaults to `frame: null`, which yields the first frame; a multi-page fax TIFF shows its first page. It then, when `maxDim != null && maxDim > 0` and the frame exceeds it, `img.copyResize`s with the long edge set to `maxDim` and the other side left null so the aspect ratio is preserved. It returns `frame.getBytes(order: img.ChannelOrder.rgba)` as the RGBA8 buffer. 16-bit and 32-bit TIFF samples are down-converted to 8-bit by `getBytes`; that is what the display path takes anyway.

Error paths, each named explicitly:
- `img.decodeTiff` returns null (not a TIFF, truncated, or an unsupported compression such as CCITT G3/G4 or JPEG2000-in-TIFF) → the isolate returns null and `decodeTiffBytes` throws `StateError('TIFF_DECODE_FAILED: package:image could not decode this TIFF')`. No fallback chain is added.
- `img.decodeTiff` throws inside the isolate → `Isolate.run` rethrows into `decodeTiffBytes`'s caller unchanged. Also a permanent miss downstream.
- The decoded frame disagrees with its own buffer (`rgba.length != width * height * 4`) → throw `StateError('TIFF length mismatch: …')`, mirroring `decodeDngFull`'s check at `dng_decode_service.dart:16-23`. `PixelPayload`'s assert and `_imageFromPixels`'s invariant both depend on this holding.
- `decodeTiffFull` / `decodeTiffSized` apply the decoded-pixel ceiling **before** reading or decoding anything: `readImageDimensions(path)`, and if `dims != null && dims.width * dims.height * 4 > kDecodedPixelBudgetBytes` throw `StateError('IMAGE_TOO_LARGE: TIFF extent exceeds the decoded-pixel budget')`. On the sized (sidebar) path this is a hard requirement, not a nicety: the loader's budget check is never reached for `purpose == sidebarThumbnail` (Task 2's branch returns `NO_THUMBNAIL` first), so a 30000×30000 scan would otherwise be decoded on the Dart heap and OOM the process. On the full path it is a cheap second line for direct callers such as `PhotoExportService.exportBytesFor`, which invokes the decoder itself.
- File missing / unreadable → `File(path).readAsBytes()` throws `FileSystemException`, which propagates as a decoder throw. Downstream it is the same permanent miss.

**Constraints:**
- `dispatchFullDecode`'s TIFF check must use `SupportedPhotoFormats.isBitmapDecodePath`, and the RAW check `SupportedPhotoFormats.isDecodablePath` — **not** `isRawPath`. `isRawPath` also matches D2 browse-only containers (`.cr2`/`.iiq`/`.mrw`) which the engine cannot decode; routing one of those to the RAW arm would be a guaranteed-failing FFI round trip instead of the immediate `UnsupportedError` the D2 ruling wants.
- `halcyonFullDecoder` and `halcyonSizedDecoder` must be `const` tear-off aliases, not closures — a closure would break the `const` wiring in `app_state.dart`.
- Only sendable values may be captured by the `Isolate.run` closure (a `Uint8List` and a nullable `int`).
- No new pub dependency.
- No `.heic`/`.heif` arm.

**Acceptance criteria:**
- [ ] `lib/services/image_pipeline/full_decoder_dispatch.dart` exists.
- [ ] `test/services/image_pipeline/full_decoder_dispatch_test.dart` contains tests named with `TC-309` and `TC-308`, and both pass.
- [ ] `flutter test test/services/image_pipeline/full_decoder_dispatch_test.dart` prints `All tests passed!`.
- [ ] `grep -n "isRawPath" lib/services/image_pipeline/full_decoder_dispatch.dart` returns no matches.
- [ ] `grep -n "const DngFullDecoder halcyonFullDecoder\|const DngSizedDecoder halcyonSizedDecoder" lib/services/image_pipeline/full_decoder_dispatch.dart` returns both lines.
- [ ] `flutter analyze` reports 0 issues.

**Steps:**

- [ ] **Step 1: Write the failing dispatcher tests**

Create `test/services/image_pipeline/full_decoder_dispatch_test.dart`:

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/full_decoder_dispatch.dart';

import '../../support/synthetic_dng.dart';

/// A 4x2 RGBA buffer whose first pixel is a distinct marker, so a test cannot
/// pass by receiving "some" DecodedRgba.
DecodedRgba _fakeDecoded({int width = 4, int height = 2}) {
  final rgba = Uint8List(width * height * 4);
  rgba[0] = 0xA5;
  return DecodedRgba(rgba: rgba, width: width, height: height);
}

void main() {
  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('halcyon_dispatch');
  });
  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<String> write(String name, Uint8List bytes) async {
    final file = File('${tmp.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// A real, decodable 4x2 TIFF with a distinguishable pixel pattern.
  Uint8List realTiff({int width = 4, int height = 2}) {
    final image = img.Image(width: width, height: height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        image.setPixelRgb(x, y, (x * 30) & 0xFF, (y * 60) & 0xFF, 7);
      }
    }
    return img.encodeTiff(image);
  }

  group('dispatchFullDecode', () {
    test('TC-309: routes .tif and .tiff to the TIFF arm', () async {
      final calls = <String>[];
      Future<DecodedRgba> tiffArm(String path) async {
        calls.add(path);
        return _fakeDecoded();
      }

      Future<DecodedRgba> rawArm(String path) async =>
          fail('the RAW arm must not be called for a TIFF');

      for (final name in ['a.tif', 'b.TIFF']) {
        final decoded = await dispatchFullDecode(
          '${tmp.path}${Platform.pathSeparator}$name',
          rawArm: rawArm,
          tiffArm: tiffArm,
        );
        expect(decoded.rgba[0], 0xA5);
      }
      expect(calls, hasLength(2));
    });

    test('TC-309: routes .dng and .arw to the engine arm', () async {
      final calls = <String>[];
      Future<DecodedRgba> rawArm(String path) async {
        calls.add(path);
        return _fakeDecoded();
      }

      Future<DecodedRgba> tiffArm(String path) async =>
          fail('the TIFF arm must not be called for a RAW container');

      for (final name in ['a.dng', 'b.arw']) {
        await dispatchFullDecode(
          '${tmp.path}${Platform.pathSeparator}$name',
          rawArm: rawArm,
          tiffArm: tiffArm,
        );
      }
      expect(calls, hasLength(2));
    });

    test('TC-309: throws UnsupportedError for an unroutable extension',
        () async {
      Future<DecodedRgba> never(String path) async => fail('must not run');
      for (final name in ['a.xyz', 'b.jpg', 'c.webp', 'd.cr2']) {
        await expectLater(
          dispatchFullDecode(
            '${tmp.path}${Platform.pathSeparator}$name',
            rawArm: never,
            tiffArm: never,
          ),
          throwsUnsupportedError,
          reason: '$name has no full-decode route',
        );
      }
    });
  });

  group('dispatchSizedDecode', () {
    test('TC-309: routes .tif to the TIFF arm and .dng to the engine arm',
        () async {
      var tiffCalls = 0;
      var rawCalls = 0;
      Future<DecodedRgba> tiffArm(String path, {required int maxDim}) async {
        expect(maxDim, 200);
        tiffCalls++;
        return _fakeDecoded();
      }

      Future<DecodedRgba> rawArm(String path, {required int maxDim}) async {
        rawCalls++;
        return _fakeDecoded();
      }

      await dispatchSizedDecode(
        '${tmp.path}${Platform.pathSeparator}a.tif',
        maxDim: 200,
        rawArm: rawArm,
        tiffArm: tiffArm,
      );
      await dispatchSizedDecode(
        '${tmp.path}${Platform.pathSeparator}a.dng',
        maxDim: 200,
        rawArm: rawArm,
        tiffArm: tiffArm,
      );
      expect(tiffCalls, 1);
      expect(rawCalls, 1);
    });
  });

  group('TIFF arm', () {
    test('decodes a real TIFF to a self-consistent RGBA buffer', () async {
      final path = await write('good.tif', realTiff());
      final decoded = await decodeTiffFull(path);
      expect(decoded.width, 4);
      expect(decoded.height, 2);
      expect(decoded.rgba.length, 4 * 2 * 4);
    });

    test('honours maxDim as a downscale request', () async {
      final path = await write('big.tif', realTiff(width: 400, height: 200));
      final decoded = await decodeTiffSized(path, maxDim: 100);
      expect(decoded.width, 100);
      expect(decoded.height, 50);
      expect(decoded.rgba.length, 100 * 50 * 4);
    });

    test('throws StateError on a TIFF package:image cannot decode', () async {
      // buildSyntheticTiffHeader carries no pixel data: decodeTiff -> null.
      final path = await write(
        'corrupt.tif',
        buildSyntheticTiffHeader(width: 800, height: 600),
      );
      await expectLater(decodeTiffFull(path), throwsStateError);
    });

    test('TC-308: the sized arm refuses an over-budget extent BEFORE any '
        'decode is attempted', () async {
      var decodeAttempts = 0;
      Future<DecodedRgba> spy(Uint8List bytes, {int? maxDim}) async {
        decodeAttempts++;
        return _fakeDecoded();
      }

      final path = await write(
        'huge_sidebar.tif',
        buildSyntheticTiffHeader(width: 30000, height: 30000),
      );
      await expectLater(
        decodeTiffSized(path, maxDim: 200, decodeBytes: spy),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('IMAGE_TOO_LARGE'),
          ),
        ),
      );
      expect(
        decodeAttempts,
        0,
        reason: 'the ceiling must be checked before the decode, not after — '
            'the sidebar path never reaches the loader\'s budget check',
      );
    });

    test('TC-308: an in-budget TIFF still reaches the decoder on the sized '
        'path', () async {
      var decodeAttempts = 0;
      Future<DecodedRgba> spy(Uint8List bytes, {int? maxDim}) async {
        decodeAttempts++;
        return _fakeDecoded();
      }

      final path = await write('small_sidebar.tif', realTiff());
      await decodeTiffSized(path, maxDim: 200, decodeBytes: spy);
      expect(decodeAttempts, 1);
    });
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/services/image_pipeline/full_decoder_dispatch_test.dart`
Expected: FAIL — `Error: Error when reading 'lib/services/image_pipeline/full_decoder_dispatch.dart': No such file or directory`.

- [ ] **Step 3: Write the dispatcher**

Create `lib/services/image_pipeline/full_decoder_dispatch.dart`:

```dart
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../models/supported_photo_formats.dart';
import 'dng_decode_contract.dart';
import 'dng_decode_service.dart';
import 'dng_embedded_jpeg_extractor.dart';

/// One production implementation of [DngFullDecoder]/[DngSizedDecoder] for
/// every format Halcyon can turn into RGBA, so that `dart_image_loader.dart`
/// and `photo_source.dart` need no format knowledge beyond the registry
/// predicate. Routing (phase 1):
///
///   .tif/.tiff -> package:image decodeTiff on a worker isolate
///   RAW        -> the existing Ceyx engine decode (unchanged)
///   otherwise  -> UnsupportedError
///
/// The `UnsupportedError` is a designed degradation path, not an accident:
/// `photo_source.dart`'s step-3b catch turns any decoder throw into the
/// uniform permanent miss, and the sidebar's catch turns it into a permanent
/// thumbnail miss. The D3 `kNoNativeDecoderCode` state stays reserved for a
/// null decoder and is unreachable from here.

/// Injection seam for the pure-CPU half of the TIFF arm. Production always
/// uses [decodeTiffBytes]; tests substitute a spy to prove the decoded-pixel
/// ceiling is checked BEFORE a decode is attempted.
typedef TiffBytesDecoder =
    Future<DecodedRgba> Function(Uint8List bytes, {int? maxDim});

/// Decodes [bytes] as TIFF on a worker isolate and returns RGBA8.
///
/// Page 0 only (`decodeTiff`'s default frame): a multi-page fax TIFF shows its
/// first page. 16/32-bit samples are down-converted to 8-bit by `getBytes`,
/// which is what everything downstream of [DecodedRgba] takes anyway.
///
/// [maxDim] > 0 caps the LONG edge, aspect ratio preserved; it is a request,
/// not a guarantee (see [DngSizedDecoder]) — callers read the returned
/// dimensions back.
Future<DecodedRgba> decodeTiffBytes(Uint8List bytes, {int? maxDim}) async {
  // Only sendable values cross the isolate boundary: a Uint8List and an int?.
  final decoded =
      await Isolate.run<({Uint8List rgba, int width, int height})?>(() {
    final frame0 = img.decodeTiff(bytes);
    // Null covers "not a TIFF", truncated data, and any compression
    // package:image refuses (CCITT G3/G4, JPEG2000-in-TIFF, old-style
    // JPEG-in-TIFF). No fallback chain: it becomes an ordinary decode failure.
    if (frame0 == null) return null;
    var frame = frame0;
    if (maxDim != null &&
        maxDim > 0 &&
        (frame.width > maxDim || frame.height > maxDim)) {
      frame = img.copyResize(
        frame,
        width: frame.width >= frame.height ? maxDim : null,
        height: frame.height > frame.width ? maxDim : null,
        interpolation: img.Interpolation.linear,
      );
    }
    return (
      rgba: frame.getBytes(order: img.ChannelOrder.rgba),
      width: frame.width,
      height: frame.height,
    );
  });
  if (decoded == null) {
    throw StateError(
      'TIFF_DECODE_FAILED: package:image could not decode this TIFF',
    );
  }
  final expectedLength = decoded.width * decoded.height * 4;
  if (decoded.rgba.length != expectedLength) {
    // Mirrors decodeDngFull's check: PixelPayload's assert and
    // _imageFromPixels' invariant both depend on this holding.
    throw StateError(
      'TIFF length mismatch: rgba.length=${decoded.rgba.length} but '
      'width*height*4=$expectedLength (width=${decoded.width}, '
      'height=${decoded.height})',
    );
  }
  return DecodedRgba(
    rgba: decoded.rgba,
    width: decoded.width,
    height: decoded.height,
  );
}

/// Refuses a declared extent that would blow the decoded-pixel budget.
///
/// Required on the SIZED path: the sidebar purpose returns `NO_THUMBNAIL` from
/// the loader before its budget check runs, so without this a 30000x30000 scan
/// would be decoded on the Dart heap and OOM the process. Kept on the full
/// path too because `PhotoExportService.exportBytesFor` invokes the decoder
/// directly. A null extent (unreadable IFD0) waves through, matching the
/// loader.
Future<void> _refuseOverBudget(String path) async {
  final dims = await DngEmbeddedJpegExtractor.readImageDimensions(path);
  if (dims != null &&
      dims.width * dims.height * 4 > kDecodedPixelBudgetBytes) {
    throw StateError(
      'IMAGE_TOO_LARGE: TIFF extent ${dims.width}x${dims.height} exceeds the '
      'decoded-pixel budget of $kDecodedPixelBudgetBytes bytes',
    );
  }
}

/// [DngFullDecoder]-shaped TIFF arm. A missing/unreadable file throws
/// [FileSystemException] from `readAsBytes`, which downstream treats as the
/// same permanent miss as any other decoder throw.
Future<DecodedRgba> decodeTiffFull(
  String path, {
  TiffBytesDecoder decodeBytes = decodeTiffBytes,
}) async {
  await _refuseOverBudget(path);
  return decodeBytes(await File(path).readAsBytes());
}

/// [DngSizedDecoder]-shaped TIFF arm (sidebar thumbnails).
Future<DecodedRgba> decodeTiffSized(
  String path, {
  required int maxDim,
  TiffBytesDecoder decodeBytes = decodeTiffBytes,
}) async {
  await _refuseOverBudget(path);
  return decodeBytes(await File(path).readAsBytes(), maxDim: maxDim);
}

/// `isDecodablePath`, NOT `isRawPath`: the latter also matches D2 browse-only
/// containers (.cr2/.iiq/.mrw) the engine cannot decode, and routing one of
/// those to the engine arm would be a guaranteed-failing FFI round trip
/// instead of the immediate refusal the D2 ruling wants.
Future<DecodedRgba> dispatchFullDecode(
  String path, {
  DngFullDecoder rawArm = halcyonDngFullDecoder,
  DngFullDecoder tiffArm = decodeTiffFull,
}) async {
  if (SupportedPhotoFormats.isBitmapDecodePath(path)) return tiffArm(path);
  if (SupportedPhotoFormats.isDecodablePath(path)) return rawArm(path);
  throw UnsupportedError('no full-decode route for $path');
}

Future<DecodedRgba> dispatchSizedDecode(
  String path, {
  required int maxDim,
  DngSizedDecoder rawArm = halcyonDngSizedDecoder,
  DngSizedDecoder tiffArm = decodeTiffSized,
}) async {
  if (SupportedPhotoFormats.isBitmapDecodePath(path)) {
    return tiffArm(path, maxDim: maxDim);
  }
  if (SupportedPhotoFormats.isDecodablePath(path)) {
    return rawArm(path, maxDim: maxDim);
  }
  throw UnsupportedError('no sized-decode route for $path');
}

/// The composition root's entry points. Plain `const` tear-offs, not closures:
/// the optional named arms are extra parameters, so each tear-off is still a
/// subtype of the seam typedef.
const DngFullDecoder halcyonFullDecoder = dispatchFullDecode;
const DngSizedDecoder halcyonSizedDecoder = dispatchSizedDecode;
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/services/image_pipeline/full_decoder_dispatch_test.dart`
Expected: PASS — `All tests passed!`

If `const DngFullDecoder halcyonFullDecoder = dispatchFullDecode;` is rejected by the analyzer, do **not** wrap it in a closure (that breaks the `const` wiring in `app_state.dart`). Change the declaration to `final` and report the deviation; nothing else in the plan depends on it being `const`.

- [ ] **Step 5: Verify the analyzer and the routing invariant**

```bash
cd /Users/jhangyu/project/Halcyon-decoders
grep -n "isRawPath" lib/services/image_pipeline/full_decoder_dispatch.dart   # expect no output
grep -rn "heic\|heif" lib/                                                    # expect no output
flutter analyze
```
Expected: two empty greps, `No issues found!`.

- [ ] **Step 6: Commit**

```bash
git -C /Users/jhangyu/project/Halcyon-decoders add \
  lib/services/image_pipeline/full_decoder_dispatch.dart \
  test/services/image_pipeline/full_decoder_dispatch_test.dart
git -C /Users/jhangyu/project/Halcyon-decoders commit \
  -m "feat(image-pipeline): add the dispatching full/sized decoder with a TIFF arm" \
  -- lib/services/image_pipeline/full_decoder_dispatch.dart \
     test/services/image_pipeline/full_decoder_dispatch_test.dart
git -C /Users/jhangyu/project/Halcyon-decoders status --porcelain
```

Both files are NEW, so the explicit `git add` of exactly those two paths is required first. Never `git add -A` — teammates have untracked work in this tree.

---

## Task 4: Wiring — composition root and the sidebar sized-decode gate

**Files:**
- Modify: `lib/providers/app_state.dart:85-92` (`dngDecoder` comment + `sidebarRawDecoder`)
- Modify: `lib/main.dart:34-36` (composition root)
- Modify: `lib/services/image_pipeline/image_preload_controller.dart:1049-1050` (sidebar gate)
- Test: `test/services/image_pipeline/bitmap_decode_wiring_test.dart` (new)

**Interfaces:**
- Consumes: `halcyonFullDecoder`, `halcyonSizedDecoder` (Task 3); `SupportedPhotoFormats.hasFullDecodeRoute` (Task 1).
- Produces: no new public API. After this task, `AppState`'s injected `DngFullDecoder` is the dispatching decoder for the preview path, the export path and the sidebar sized path.

**Behavior:**
- `lib/main.dart` passes `dngDecoder: halcyonFullDecoder` (the dispatcher) instead of `halcyonDngFullDecoder` (RAW only). This single change is what makes TIFF reach pixels in the detail view **and** in the export path, because `AppState` forwards the same value into `PhotoExportService(decoder: dngDecoder)` (`app_state.dart:73-74`) and into `ImagePreloadController(dngDecoder: dngDecoder)`.
- `lib/providers/app_state.dart` swaps `halcyonDngSizedDecoder` for `halcyonSizedDecoder` in the `sidebarRawDecoder` argument. The `dngDecoder == null ? null : …` guard is preserved verbatim: a build or test with no decoder keeps the uniform explicit miss.
- `image_preload_controller.dart`'s sidebar fallback gate widens from `SupportedPhotoFormats.isDecodablePath(file.path)` to `SupportedPhotoFormats.hasFullDecodeRoute(file.path)`. This is the one line that lets a TIFF thumbnail exist at all: the loader answers `NO_THUMBNAIL` for the sidebar purpose (Task 2), the `else if` then runs `_sidebarRawDecoder(path, maxDim: 200)`, reads orientation via `DngEmbeddedJpegExtractor.readOrientation`, and hands the result to the existing `jpegFromOrientedPixels`, so the sidebar cache keeps storing encoded bytes exactly as it does for RAW. D2 browse-only containers stay excluded because `hasFullDecodeRoute` is `decodableExtensions ∪ bitmapDecodeExtensions` and contains none of `.cr2`/`.iiq`/`.mrw`.
- Existing behaviour that must not change: the stale-generation guards after every `await` (`image_preload_controller.dart:1069`, `:1078`), and the `catch (_)` that records a permanent miss when the sized decode fails.

**Constraints:**
- Do not change `ImagePreloadController`'s constructor signature; only the gate expression on the `else if`.
- Do not remove the `dngDecoder == null` guard in `app_state.dart`.
- `lib/main.dart` must still import from `dng_decode_service.dart` only if something else there needs it; otherwise remove the now-unused import to keep `flutter analyze` at 0.

**Acceptance criteria:**
- [ ] `grep -n "halcyonFullDecoder" lib/main.dart` returns a match and `grep -n "halcyonDngFullDecoder" lib/main.dart` returns none.
- [ ] `grep -n "halcyonSizedDecoder" lib/providers/app_state.dart` returns a match and `grep -n "halcyonDngSizedDecoder" lib/providers/app_state.dart` returns none.
- [ ] `grep -n "hasFullDecodeRoute" lib/services/image_pipeline/image_preload_controller.dart` returns exactly one match.
- [ ] `test/services/image_pipeline/bitmap_decode_wiring_test.dart` passes, including a test that a `.tif` reaches the sidebar sized decoder and a test that a `.cr2` does not.
- [ ] `flutter test test/services/image_pipeline/image_preload_controller_test.dart test/services/image_pipeline/bitmap_decode_wiring_test.dart` prints `All tests passed!`.
- [ ] `flutter analyze` reports 0 issues.

**Steps:**

- [ ] **Step 1: Write the failing wiring test**

Create `test/services/image_pipeline/bitmap_decode_wiring_test.dart`:

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';

import '../../support/synthetic_dng.dart';

DecodedRgba _tinyDecoded() {
  final rgba = Uint8List(2 * 2 * 4);
  for (var i = 3; i < rgba.length; i += 4) {
    rgba[i] = 255; // opaque
  }
  return DecodedRgba(rgba: rgba, width: 2, height: 2);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('halcyon_wiring');
  });
  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<File> writeContainer(String name) async {
    final file = File('${tmp.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(
      buildSyntheticTiffHeader(width: 800, height: 600, orientation: 1),
      flush: true,
    );
    return file;
  }

  /// Drives one sidebar thumbnail sweep over a single item and records which
  /// paths the sized decoder was asked for.
  Future<List<String>> sizedDecoderCallsFor(String name) async {
    final file = await writeContainer(name);
    final calls = <String>[];
    final controller = ImagePreloadController(
      imageLoader: (path, {required purpose}) async =>
          const NativeImageFailure('NO_THUMBNAIL', 'no embedded candidate'),
      sidebarRawDecoder: (path, {required int maxDim}) async {
        calls.add(path);
        expect(maxDim, 200);
        return _tinyDecoded();
      },
    );
    final items = [PhotoItem(id: 'a', files: [file])];
    await controller.loadThumbnailsForRange(
      items: items,
      firstIndex: 0,
      lastIndex: 0,
      notifyLoaded: () {},
    );
    return calls;
  }

  test('a .tif reaches the sidebar sized decoder', () async {
    expect(await sizedDecoderCallsFor('a.tif'), hasLength(1));
  });

  test('a D2 browse-only .cr2 does NOT reach the sidebar sized decoder',
      () async {
    expect(await sizedDecoderCallsFor('a.cr2'), isEmpty);
  });

  test('a .webp does NOT reach the sidebar sized decoder', () async {
    expect(await sizedDecoderCallsFor('a.webp'), isEmpty);
  });
}
```

**Before running:** open `test/services/image_pipeline/image_preload_controller_test.dart` and copy the exact constructor arguments and thumbnail-sweep entry point that file already uses. `ImagePreloadController`'s constructor and its sidebar sweep method name are pre-existing API this task must not change — if the real names differ from `loadThumbnailsForRange(items:firstIndex:lastIndex:notifyLoaded:)`, use the real ones verbatim and keep the assertions identical. Do not add parameters to the controller to make this test compile.

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/services/image_pipeline/bitmap_decode_wiring_test.dart`
Expected: FAIL — the `.tif` case reports `Expected: an object with length of <1> / Actual: []`, because the sidebar gate is still `isDecodablePath` and a `.tif` is not engine-decodable. The `.cr2` and `.webp` cases pass already; they are the negative controls that stop the fix from being "widen the gate to everything".

- [ ] **Step 3: Widen the sidebar gate**

In `lib/services/image_pipeline/image_preload_controller.dart`, at the sidebar fallback branch, replace:

```dart
            } else if (_sidebarRawDecoder != null &&
                SupportedPhotoFormats.isDecodablePath(file.path)) {
```

with:

```dart
            } else if (_sidebarRawDecoder != null &&
                SupportedPhotoFormats.hasFullDecodeRoute(file.path)) {
```

and extend the comment block directly above it with:

```dart
              // 2026-08-28 (bitmap decoders phase 1): the gate widens from
              // `isDecodablePath` to `hasFullDecodeRoute` so a TIFF gets a
              // thumbnail at all -- the loader answers NO_THUMBNAIL for the
              // sidebar purpose by design (the AD-010 invariant), making this
              // sized decode the ONLY TIFF thumbnail route. D2 browse-only
              // containers stay excluded: `hasFullDecodeRoute` is
              // decodableExtensions + bitmapDecodeExtensions and contains
              // none of .cr2/.iiq/.mrw.
```

Nothing else in the branch changes — the stale-generation guards after every `await` and the `catch (_)` permanent-miss recording stay exactly as they are.

- [ ] **Step 4: Run the test to verify it passes**

Run: `flutter test test/services/image_pipeline/bitmap_decode_wiring_test.dart`
Expected: PASS — `All tests passed!`

- [ ] **Step 5: Wire the composition root**

In `lib/providers/app_state.dart`, replace:

```dart
             sidebarRawDecoder: dngDecoder == null
                 ? null
                 : halcyonDngSizedDecoder,
```

with:

```dart
             // Dispatching sized decoder (2026-08-28 phase 1): routes .tif to
             // package:image and everything else to the Ceyx engine. The
             // `dngDecoder == null` guard is unchanged -- a build or test with
             // no decoder keeps the uniform explicit miss.
             sidebarRawDecoder: dngDecoder == null
                 ? null
                 : halcyonSizedDecoder,
```

and update the import so `halcyonSizedDecoder` resolves:

```dart
import '../services/image_pipeline/full_decoder_dispatch.dart';
```

If `dng_decode_service.dart` is now unimported-from `app_state.dart`, remove that import — `flutter analyze` flags unused imports.

In `lib/main.dart`, replace:

```dart
  final appState = AppState(
    dngDecoder: halcyonDngFullDecoder,
  ); // PERF-INSTRUMENTATION
```

with:

```dart
  // The DISPATCHING decoder, not the RAW-only one: this single argument is
  // what makes TIFF reach pixels in the detail view AND in the export path,
  // because AppState forwards the same value into PhotoExportService and into
  // ImagePreloadController.
  final appState = AppState(
    dngDecoder: halcyonFullDecoder,
  ); // PERF-INSTRUMENTATION
```

and swap the import of `dng_decode_service.dart` for `full_decoder_dispatch.dart` (keep both only if something else in `main.dart` still needs the former).

- [ ] **Step 6: Verify the wiring mechanically**

```bash
cd /Users/jhangyu/project/Halcyon-decoders
grep -n "halcyonFullDecoder" lib/main.dart                                                # expect 1 match
grep -n "halcyonDngFullDecoder" lib/main.dart                                             # expect no output
grep -n "halcyonSizedDecoder" lib/providers/app_state.dart                                # expect 1 match
grep -n "halcyonDngSizedDecoder" lib/providers/app_state.dart                             # expect no output
grep -c "hasFullDecodeRoute" lib/services/image_pipeline/image_preload_controller.dart    # expect 1
flutter analyze
flutter test -j 1
```
Expected: the greps produce the stated values, `No issues found!`, `All tests passed!`.

If `flutter test -j 1` now fails in `image_preload_controller_test.dart` or `app_state_test.dart`, read the failure before changing anything: a test that asserted "a `.tif` gets no thumbnail" is asserting the old behaviour and should be updated; a test that asserted "a `.cr2` gets no thumbnail" is a real regression and means the gate was widened past `hasFullDecodeRoute`.

- [ ] **Step 7: Commit**

```bash
git -C /Users/jhangyu/project/Halcyon-decoders add \
  test/services/image_pipeline/bitmap_decode_wiring_test.dart
git -C /Users/jhangyu/project/Halcyon-decoders commit \
  -m "feat(image-pipeline): wire the dispatching decoder and widen the sidebar decode gate" \
  -- lib/main.dart \
     lib/providers/app_state.dart \
     lib/services/image_pipeline/image_preload_controller.dart \
     test/services/image_pipeline/bitmap_decode_wiring_test.dart
git -C /Users/jhangyu/project/Halcyon-decoders status --porcelain
```

Only the new test file needs `git add`; the three `lib/` files are tracked.

---

## Task 5: End-to-end pins — permanent miss, orientation, export

**Files:**
- Modify: `test/services/image_pipeline/photo_source_test.dart` (append TC-310)
- Modify: `test/services/image_pipeline/decoded_rgba_image_provider_test.dart` (append TC-311)
- Modify: `test/services/library/photo_export_service_test.dart` (append TC-312)
- No `lib/` changes are expected. If any of these three tests fails, the defect is in Tasks 1–4 and must be fixed there, not papered over here.

**Interfaces:**
- Consumes: everything produced by Tasks 1–4, plus `PhotoSource.load`, `decodedRgbaToPixelPayload(DecodedRgba, {required int exifOrientation, required int longEdge})`, `PhotoExportService.exportBytesFor(String path, {DngFullDecoder? decoder})`.
- Produces: no production API. This task's deliverable is three pinned behaviours.

**Behavior:**
- **TC-310 — corrupt TIFF is an ordinary permanent miss, not `DNG_PARSE_FAILED`.** A `PhotoSource` built with a loader that returns `NativeImageNeedsRawDecode(exifOrientation: 1)` (i.e. `declaredPreviewsUnreadable: false`, which is structurally guaranteed for every TIFF because Task 2's branch never runs the preview probe) and a throwing decoder must return `(payload: null, deferred: false, failureCode: null)`. The `failureCode: 'DNG_PARSE_FAILED'` arm stays reachable only from a RAW container whose declared previews were all unreadable — a second assertion in the same test pins that the arm still works, so the test cannot pass by the arm having been deleted.
- **TC-311 — TIFF orientation is applied exactly once.** A real TIFF is built with `img.encodeTiff` at 2×3, decoded through `decodeTiffBytes`, and pushed through `decodedRgbaToPixelPayload` with `exifOrientation: 6`. Orientation 6 is a 90° clockwise rotation, so the resulting `PixelPayload` must be 3 wide × 2 high. Shape alone cannot distinguish 90CW from 90CCW, so the test also asserts the R-channel marker grid, matching the discriminating-marker technique already used in that file.
- **TC-312 — TIFF export.** `PhotoExportService.exportBytesFor(tiffPath, decoder: fakeDecoder)` with a fake returning a 3000×2000 RGBA `DecodedRgba` and an EXIF Orientation of 1 must produce a JPEG whose long edge is ≤ 2048 and whose `Orientation` tag is 1. The path exercised is the existing `NativeImageNeedsRawDecode` arm at `photo_export_service.dart:68-79` — reached because Task 2's loader branch returns that variant for a `.tif` at `purpose: preview`, which is the purpose the export service deliberately uses.

**Constraints:**
- No real Ceyx dylib, no real photo library, no network. Fakes only — that is the seam's entire purpose (`dng_decode_contract.dart:4-8`).
- Temp files go in a `Directory.systemTemp.createTempSync(...)` created in `setUpAll` and deleted in `tearDownAll`; nothing is written into the repo.
- Do not weaken or delete any existing assertion in these three files.

**Acceptance criteria:**
- [ ] Tests named with `TC-310`, `TC-311`, `TC-312` exist in the three named files and pass.
- [ ] `flutter test test/services/image_pipeline/photo_source_test.dart test/services/image_pipeline/decoded_rgba_image_provider_test.dart test/services/library/photo_export_service_test.dart` prints `All tests passed!`.
- [ ] `git diff --stat -- lib/` shows no change introduced by this task.
- [ ] `flutter analyze` reports 0 issues.

**Steps:**

- [ ] **Step 1: Write TC-310 (corrupt TIFF is an ordinary permanent miss)**

Append to `test/services/image_pipeline/photo_source_test.dart`, inside `void main() { … }`:

```dart
  group('TC-310: a corrupt TIFF is an ordinary permanent miss', () {
    test('a throwing decoder on a TIFF yields failureCode null, NOT '
        'DNG_PARSE_FAILED', () async {
      final source = PhotoSource(
        // What Task 2's loader branch returns for a .tif at preview:
        // declaredPreviewsUnreadable is structurally false because no preview
        // probe ever runs for a bitmap container.
        loader: (path, {required purpose}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        dngDecoder: (path) async =>
            throw StateError('TIFF_DECODE_FAILED: package:image returned null'),
      );
      final outcome = await source.load('/tmp/broken.tif', longEdge: 2800);
      expect(outcome.payload, isNull);
      expect(outcome.deferred, isFalse);
      expect(
        outcome.failureCode,
        isNull,
        reason: 'DNG_PARSE_FAILED is reserved for a RAW container whose '
            'declared previews were all unreadable (AD-022)',
      );
      expect(outcome.observedCost, SourceCost.expensive);
    });

    test('the DNG_PARSE_FAILED arm is still reachable for a RAW container '
        'with unreadable declared previews', () async {
      // Negative control: without this, the test above would also pass if the
      // DNG_PARSE_FAILED arm had simply been deleted.
      final source = PhotoSource(
        loader: (path, {required purpose}) async =>
            const NativeImageNeedsRawDecode(
              exifOrientation: 1,
              declaredPreviewsUnreadable: true,
            ),
        dngDecoder: (path) async => throw StateError('decode failed'),
      );
      final outcome = await source.load('/tmp/broken.dng', longEdge: 2800);
      expect(outcome.failureCode, 'DNG_PARSE_FAILED');
    });
  });
```

Match the `PhotoSource` construction and the `loader` closure signature to what the surrounding file already uses; do not introduce a new fake type if one exists there.

- [ ] **Step 2: Run TC-310 to verify it passes**

Run: `flutter test test/services/image_pipeline/photo_source_test.dart`
Expected: PASS — `All tests passed!`

This test pins existing behaviour rather than driving new code, so it should be green immediately. If it is **red**, the defect is in Task 2 (the loader is setting `declaredPreviewsUnreadable` for a bitmap container) — fix it there, not here.

- [ ] **Step 3: Write TC-311 (TIFF orientation applied exactly once)**

Append to `test/services/image_pipeline/decoded_rgba_image_provider_test.dart`, inside `void main() { … }`:

```dart
  test('TC-311: a TIFF with Orientation 6 renders 90 degrees clockwise, '
      'swapping width and height exactly once', () async {
    // A real 2x3 TIFF whose six pixels carry six distinct R-channel markers.
    // Shape alone cannot separate 90CW from 90CCW (both give 3x2), so the
    // marker grid is what makes this test discriminating.
    const rows = <List<int>>[
      [a, b],
      [c, d],
      [e, f],
    ];
    final source = img.Image(width: 2, height: 3);
    for (var y = 0; y < 3; y++) {
      for (var x = 0; x < 2; x++) {
        source.setPixelRgb(x, y, rows[y][x], 0, 0);
      }
    }
    final tmp = Directory.systemTemp.createTempSync('halcyon_tiff_orient');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final path = '${tmp.path}${Platform.pathSeparator}orient6.tif';
    File(path).writeAsBytesSync(img.encodeTiff(source));

    // The real TIFF arm: package:image does NOT bake orientation, so applying
    // it downstream is required, not belt-and-braces.
    final decoded = await decodeTiffFull(path);
    expect(decoded.width, 2);
    expect(decoded.height, 3);

    final payload = await decodedRgbaToPixelPayload(
      decoded,
      exifOrientation: 6,
      longEdge: 2800,
    );
    expect(payload.width, 3, reason: 'orientation 6 swaps the axes');
    expect(payload.height, 2);
    expect(payload.rgba.length, 3 * 2 * 4);

    // Orientation 6 = rotate 90 clockwise:
    //   A B          E C A
    //   C D    ->    F D B
    //   E F
    final grid = <List<int>>[];
    for (var y = 0; y < 2; y++) {
      final row = <int>[];
      for (var x = 0; x < 3; x++) {
        row.add(payload.rgba[(y * 3 + x) * 4]);
      }
      grid.add(row);
    }
    expect(grid, [
      [e, c, a],
      [f, d, b],
    ]);
  });
```

Add the imports this test needs to the file's import block if absent: `dart:io`, `package:image/image.dart' as img`, and `package:halcyon_flutter/services/image_pipeline/full_decoder_dispatch.dart`. The `a`…`f` marker constants already exist at the top of that file.

If `decodedRgbaToPixelPayload` returns a payload whose `rgba` is not directly readable in this file, use the file's existing `_markerGrid(ui.Image)` helper against the payload's image instead — reuse the file's own read-back technique rather than inventing a second one.

- [ ] **Step 4: Run TC-311 to verify it passes**

Run: `flutter test test/services/image_pipeline/decoded_rgba_image_provider_test.dart`
Expected: PASS — `All tests passed!`

A failure showing the grid `[[b, d, f], [a, c, e]]` means orientation was applied 90° counter-clockwise; a failure showing `[[a, b], [c, d], [e, f]]` unswapped means it was not applied at all (the defect would be in Task 3's TIFF arm baking it prematurely, or in the caller passing orientation 1).

- [ ] **Step 5: Write TC-312 (TIFF export)**

Append to `test/services/library/photo_export_service_test.dart`, inside `void main() { … }`:

```dart
  test('TC-312: exporting a TIFF produces a JPEG with long edge <= 2048 and '
      'Orientation == 1', () async {
    final tmp = Directory.systemTemp.createTempSync('halcyon_tiff_export');
    addTearDown(() => tmp.deleteSync(recursive: true));
    // A real TIFF file must exist at this path: exportBytesFor calls
    // dartImageLoad, whose bitmap branch reads the IFD0 extent and
    // orientation from the file before returning NeedsRawDecode, and
    // _attachSourceExif re-reads the same file with package:exif.
    final path = '${tmp.path}${Platform.pathSeparator}scan.tif';
    File(path).writeAsBytesSync(
      img.encodeTiff(img.Image(width: 60, height: 40)),
    );

    // 3000x2000 forces the resize; the fake decoder stands in for the
    // dispatching decoder so the test never loads a real dylib.
    final rgba = Uint8List(3000 * 2000 * 4);
    for (var i = 3; i < rgba.length; i += 4) {
      rgba[i] = 255; // opaque
    }
    final jpeg = await PhotoExportService.exportBytesFor(
      path,
      decoder: (p) async =>
          DecodedRgba(rgba: rgba, width: 3000, height: 2000),
    );

    expect(jpeg, isNotNull);
    final out = img.decodeJpg(jpeg!)!;
    expect(out.width, lessThanOrEqualTo(2048));
    expect(out.height, lessThanOrEqualTo(2048));
    expect(out.width == 2048 || out.height == 2048, isTrue,
        reason: 'the long edge is capped AT 2048, not below it');
    expect(out.exif.imageIfd['Orientation'], 1,
        reason: 'pixels are already rotated; the tag must not double-apply');
  });
```

Reuse the file's existing imports where present (`dart:io`, `dart:typed_data`, `package:image/image.dart' as img`, `PhotoExportService`, `DecodedRgba`) and add only what is missing.

- [ ] **Step 6: Run TC-312 to verify it passes**

Run: `flutter test test/services/library/photo_export_service_test.dart`
Expected: PASS — `All tests passed!`

A `jpeg` of `null` means `dartImageLoad` did not return `NativeImageNeedsRawDecode` for the `.tif` — the defect is in Task 2's branch placement, not here.

- [ ] **Step 7: Verify no production code drifted**

```bash
cd /Users/jhangyu/project/Halcyon-decoders
git diff --stat -- lib/     # expect no output: this task changes tests only
flutter analyze
flutter test -j 1
```
Expected: empty diff, `No issues found!`, `All tests passed!`.

- [ ] **Step 8: Commit**

```bash
git -C /Users/jhangyu/project/Halcyon-decoders commit \
  -m "test(image-pipeline): pin TIFF permanent-miss, orientation and export behaviour" \
  -- test/services/image_pipeline/photo_source_test.dart \
     test/services/image_pipeline/decoded_rgba_image_provider_test.dart \
     test/services/library/photo_export_service_test.dart
git -C /Users/jhangyu/project/Halcyon-decoders status --porcelain
```

All three files are tracked; no `git add` needed.

---

## Task 6: Gate run, README updates, and the merge-time SOP checklist

**Files:**
- Modify: `README.md` (supported-formats section)
- Modify: `README.zh-TW.md` (supported-formats section)
- Create: `docs/logs/2026-08-28/bitmap-decoders-phase1-gate.md` (gate artifact, committed)
- **Merge-time only, never committed:** `/Users/jhangyu/project/Halcyon/docs/sop/memory.md`, `.../unit_test.md`, `.../file_index.md`

**Interfaces:**
- Consumes: the completed Tasks 1–5.
- Produces: the phase-1 acceptance artifact.

**Behavior:**
The full-suite gate runs here, once, with the exit code captured **inside** the artifact on the line immediately after each command (`RC=$?`) — never read from a harness notification, per the 2026-08-23 lesson. `flutter test -j 1` is mandatory: parallel runs overwrite the progress line and lose the declared-vs-executed count.

README changes are content-equivalent but independently authored: `README.zh-TW.md` is written as Chinese prose, not translated sentence-by-sentence from the English (2026-08-27 precedent). Both gain WebP and TIFF in the supported-formats list. TIFF's stated limitations, which must appear in both files: first page only for multi-page TIFF, and exotic compressions (CCITT G3/G4, JPEG2000-in-TIFF) are not supported. WebP's stated limitation: the first frame only for animated WebP, and EXIF orientation in a WebP `EXIF` chunk is not applied (spec §5.5, accepted for phase 1). HEIC must **not** be mentioned as supported.

**The SOP docs are edited in place at `/Users/jhangyu/project/Halcyon/docs/sop/` and are gitignored** (`.gitignore:49-53`, per `docs/logs/2026-08-26/sop-relocation-contract.md`). They must be edited **at merge time, as the final action of this task**, and must never appear in a `git add` or `git commit`. Editing them earlier risks clobbering concurrent sessions working on `main` in that directory. Required edits, as a single checklist:
1. `memory.md` — a new `### AD-035` heading: "already-rendered bitmap formats route through the existing three-variant seam". It records the §4 routing argument (why no fourth variant), the `hasFullDecodeRoute` vs `isDecodablePath` split, and the explicit statement that AD-021 and AD-022 stay gated on `isDecodablePath`.
2. `unit_test.md` — TC-matrix rows for TC-302 … TC-313, each naming its test file.
3. `file_index.md` — a row for `lib/services/image_pipeline/full_decoder_dispatch.dart`.

**Constraints:**
- No `git add`/`git commit` may name any path under `/Users/jhangyu/project/Halcyon/docs/sop/`.
- The gate artifact must contain the literal command lines, their output, and an `RC=` line captured with `RC=$?` immediately after each command.
- Do not use `--no-colour-gate`, `flutter test -j` with any value other than 1, or a re-run with different arguments to obtain a green (pre-registration discipline: the judgement rule below is fixed before the numbers exist).
- **Pre-registered pass rule, fixed before the run:** phase 1 passes iff (a) `flutter analyze` output ends with `No issues found!` and `RC=0`; (b) `flutter test -j 1` output contains `All tests passed!` and `RC=0`; (c) the artifact contains all twelve strings `TC-302` … `TC-313`. Any other outcome is a failure to be reported, not re-run.

**Acceptance criteria:**
- [ ] `docs/logs/2026-08-28/bitmap-decoders-phase1-gate.md` exists and contains `RC=0` for both commands, `No issues found!`, and `All tests passed!`.
- [ ] `grep -c "TC-30[2-9]\|TC-31[0-3]" docs/logs/2026-08-28/bitmap-decoders-phase1-gate.md` returns at least `12`.
- [ ] `grep -in "webp" README.md README.zh-TW.md` returns matches in both files.
- [ ] `grep -in "tif" README.md README.zh-TW.md` returns matches in both files.
- [ ] `grep -in "heic" README.md README.zh-TW.md` returns no matches claiming support.
- [ ] `git status --porcelain` lists no path under `docs/sop/`.
- [ ] `grep -n "AD-035" /Users/jhangyu/project/Halcyon/docs/sop/memory.md` returns a match.
- [ ] `grep -n "full_decoder_dispatch.dart" /Users/jhangyu/project/Halcyon/docs/sop/file_index.md` returns a match.
- [ ] `grep -c "TC-30[2-9]\|TC-31[0-3]" /Users/jhangyu/project/Halcyon/docs/sop/unit_test.md` returns at least `12`.

**Steps:**

- [ ] **Step 1: Update `README.md`**

In `README.md`'s supported-formats section, add WebP and TIFF alongside the existing JPEG/PNG/RAW entries. Exact content to add (adapt only the surrounding markdown to the file's existing table/list style — do not restate the RAW list, which is derived):

```markdown
- **WebP** (`.webp`) — decoded by the Flutter engine on every platform.
  Animated WebP shows its first frame only. EXIF orientation carried in a
  WebP `EXIF` chunk is not applied; files written by phones with a non-1
  Orientation tag may display rotated.
- **TIFF** (`.tif`, `.tiff`) — decoded with `package:image`. Stripped and
  tiled TIFF, 8/16/32-bit samples, LZW/PackBits/Deflate and uncompressed are
  supported; 16-bit is down-converted to 8-bit for display. Multi-page TIFF
  shows page 1 only. Exotic compressions (CCITT G3/G4, JPEG2000-in-TIFF,
  old-style JPEG-in-TIFF) are not supported and appear as an unreadable file.
```

Do **not** mention HEIC/HEIF as supported anywhere — it is phase 2 and no code for it exists.

- [ ] **Step 2: Update `README.zh-TW.md`**

Write the same two entries as Chinese prose, authored independently rather than translated sentence-by-sentence from Step 1 (2026-08-27 precedent). The facts that must survive into the Chinese text: WebP is decoded by the engine on all platforms, animated WebP shows only the first frame, WebP EXIF orientation is not applied; TIFF is decoded with `package:image`, supports the common compressions and bit depths, is down-converted to 8-bit, shows page 1 of a multi-page file, and does not support CCITT G3/G4 or JPEG2000-in-TIFF.

Punctuation check before committing (2026-08-27 lesson — hard line wraps defeat adjacency-based checks, so use a width-pairing check instead of a neighbour check):

```bash
cd /Users/jhangyu/project/Halcyon-decoders
python3 - <<'PY'
import re
text = open('README.zh-TW.md', encoding='utf-8').read()
# Strip fenced code blocks and inline code: half-width punctuation is correct there.
text = re.sub(r'```.*?```', '', text, flags=re.S)
text = re.sub(r'`[^`]*`', '', text)
opens = text.count('（') + text.count('(')
bad = [m for m in re.finditer(r'（[^）\n]*\)|\([^)\n]*）', text)]
print('mixed-width bracket pairs:', len(bad))
for m in bad[:20]:
    print(' ', m.group(0)[:60])
PY
```
Expected: `mixed-width bracket pairs: 0`. A non-zero count means a full-width open bracket was paired with a half-width close (or vice versa) — fix each one.

- [ ] **Step 3: Run the phase-1 gate and write the artifact**

```bash
cd /Users/jhangyu/project/Halcyon-decoders
mkdir -p docs/logs/2026-08-28
{
  echo "# Bitmap decoders phase 1 — acceptance gate"
  echo
  echo "Pre-registered pass rule (fixed before this run, per the plan's Task 6):"
  echo "  (a) flutter analyze ends with 'No issues found!' and RC=0"
  echo "  (b) flutter test -j 1 contains 'All tests passed!' and RC=0"
  echo "  (c) this artifact contains all of TC-302 .. TC-313"
  echo "Any other outcome is a REPORTED FAILURE, not a re-run with different arguments."
  echo
  echo "commit: $(git rev-parse HEAD)"
  echo
  echo '## $ flutter analyze'
  echo '```'
  flutter analyze 2>&1
  RC=$?
  echo "RC=$RC"
  echo '```'
  echo
  echo '## $ flutter test -j 1'
  echo '```'
  flutter test -j 1 2>&1
  RC=$?
  echo "RC=$RC"
  echo '```'
} > docs/logs/2026-08-28/bitmap-decoders-phase1-gate.md 2>&1
```

`RC=$?` sits on the line immediately after each command and is captured **inside** the artifact. Do not read the exit code from a harness/background-task notification and do not use `${PIPESTATUS[0]}` — both have lied in this repo before (2026-08-23 lesson).

- [ ] **Step 4: Judge the gate against the pre-registered rule**

```bash
cd /Users/jhangyu/project/Halcyon-decoders
A=docs/logs/2026-08-28/bitmap-decoders-phase1-gate.md
grep -c "^RC=0$" "$A"                        # expect 2
grep -c "No issues found!" "$A"              # expect >= 1
grep -c "All tests passed!" "$A"             # expect >= 1
grep -o "TC-3[01][0-9]" "$A" | sort -u       # expect TC-302 .. TC-313, twelve lines
grep -o "TC-3[01][0-9]" "$A" | sort -u | wc -l   # expect 12
```

If any check fails, STOP and report the failure with the artifact path. Do not re-run with different arguments (no `-j` other than 1, no test-file subsetting) to obtain a green.

- [ ] **Step 5: Commit the README changes and the gate artifact**

```bash
git -C /Users/jhangyu/project/Halcyon-decoders add \
  docs/logs/2026-08-28/bitmap-decoders-phase1-gate.md
git -C /Users/jhangyu/project/Halcyon-decoders commit \
  -m "docs: state WebP and TIFF support and record the phase-1 acceptance gate" \
  -- README.md \
     README.zh-TW.md \
     docs/logs/2026-08-28/bitmap-decoders-phase1-gate.md
git -C /Users/jhangyu/project/Halcyon-decoders status --porcelain
```

The gate artifact is new and needs `git add`; both READMEs are tracked.

- [ ] **Step 6: MERGE TIME ONLY — update the SOP docs in place**

Do this **after** the branch is merged, as the last action, and **never** inside a `git add`/`git commit`. The three files are gitignored and shared with sessions working on `main`; editing them earlier risks clobbering concurrent work.

`/Users/jhangyu/project/Halcyon/docs/sop/memory.md` — append:

```markdown
### AD-035: already-rendered bitmap formats route through the existing three-variant seam

Date: 2026-08-28. Phase 1 (WebP + TIFF); HEIC is phase 2.

WebP is registry-only: it joins `SupportedPhotoFormats.engineBitstreamExtensions`
and takes `dart_image_loader.dart`'s existing `NativeImageBytes` arm, because the
Flutter engine's own codec reads it on every platform.

TIFF has no cheap encoded bitstream, so it enters through the EXISTING
`NativeImageNeedsRawDecode` -> `DngFullDecoder` seam rather than a fourth
`NativeImageResult` variant. AD-010's 2026-08-22 revision already restated that
variant's meaning as "cannot get cheap bytes, and this is a file the decoder can
handle" — deliberately independent of container family — and the 2026-08-26
contract widened its gate for the same reason. A fourth variant was rejected
(every `switch` over the sealed class would need a new arm and the D3/AD-022
reasoning would be duplicated per arm); transcoding inside the loader was
rejected (the loader is documented as never decoding, which is what lets AD-022's
verdict be formed later by `photo_source.dart`, and it would lose the `fullRes`
tier-2 piggyback); a second `BitmapFullDecoder` typedef was rejected (the
signature `Future<DecodedRgba> Function(String)` is already format-neutral).

The one structural edit is a SECOND, ADDITIVE predicate. `hasFullDecodeRoute` =
`decodableExtensions` + `bitmapDecodeExtensions` gates the escape hatch and the
sidebar's sized-decode fallback. `isDecodablePath` is UNCHANGED and still gates
BOTH AD-021 (the uneven `minLongEdge` floor: strict on preview, lenient on
sidebar) and AD-022 (the `declaredPreviewsUnreadable` finding) — both are
statements about embedded previews inside a TIFF-structured RAW container, and a
bitmap container is never preview-probed at all, so neither concept applies to
it and neither gate changes meaning.

Dispatch lives in `lib/services/image_pipeline/full_decoder_dispatch.dart`, so
`dart_image_loader.dart` and `photo_source.dart` need no format knowledge beyond
the predicate. An arm whose backing library is absent throws `UnsupportedError`,
which `photo_source.dart`'s step-3b catch already converts into the uniform
permanent miss; the D3 `NO_NATIVE_DECODER` state stays reserved for
`dngDecoder == null`.

The decoded-pixel budget (1,500,000,000 bytes) moves with the escape hatch and
therefore now covers TIFF — stricter than JPEG/WebP on purpose, because a TIFF
decode happens on the Dart heap in an isolate where the failure mode is a
process OOM rather than an engine-side decode error. The sidebar's sized path
never reaches the loader's check, so the sized TIFF decoder applies the same
ceiling itself before reading or decoding anything.

Accepted, stated limitations: WebP EXIF-chunk orientation is not applied;
animated WebP shows frame 1; multi-page TIFF shows page 1; exotic TIFF
compressions become ordinary decode failures with no fallback chain.
```

`/Users/jhangyu/project/Halcyon/docs/sop/unit_test.md` — add twelve TC-matrix rows:

| TC | Case | Test file |
|---|---|---|
| TC-302 | `.webp`/`.tif`/`.tiff` surface via `isSupportedPath`; `.xyz` and `.heic` do not | `test/models/supported_photo_formats_test.dart` |
| TC-303 | `.webp` returns `NativeImageBytes` with the file's own bytes for all three purposes | `test/services/image_pipeline/dart_image_loader_test.dart` |
| TC-304 | `bestFileToLoad` prefers `.jpg` over `.webp`, `.webp` over `.dng` | `test/models/supported_photo_formats_test.dart` |
| TC-305 | `.tif` at preview returns `NeedsRawDecode` with IFD0 orientation, `declaredPreviewsUnreadable == false` | `test/services/image_pipeline/dart_image_loader_test.dart` |
| TC-306 | `.tif` at sidebarThumbnail returns `NativeImageFailure`, never `NeedsRawDecode` | `test/services/image_pipeline/dart_image_loader_test.dart` |
| TC-307 | A TIFF declaring 30000×30000 yields `IMAGE_TOO_LARGE` before any decode | `test/services/image_pipeline/dart_image_loader_test.dart` |
| TC-308 | The sized sidebar path applies the same ceiling and refuses before decoding | `test/services/image_pipeline/full_decoder_dispatch_test.dart` |
| TC-309 | Dispatch routes `.tif`→TIFF arm, `.dng`/`.arw`→engine arm, else `UnsupportedError` | `test/services/image_pipeline/full_decoder_dispatch_test.dart` |
| TC-310 | A corrupt TIFF gives `payload: null, deferred: false, failureCode: null` | `test/services/image_pipeline/photo_source_test.dart` |
| TC-311 | A TIFF with Orientation 6 renders with axes swapped, applied exactly once | `test/services/image_pipeline/decoded_rgba_image_provider_test.dart` |
| TC-312 | TIFF export produces a JPEG with long edge ≤2048 and `Orientation == 1` | `test/services/library/photo_export_service_test.dart` |
| TC-313 | Exhaustive `switch` over `NativeImageResult` still compiles with exactly three arms | `test/services/image_pipeline/dart_image_loader_test.dart` |

`/Users/jhangyu/project/Halcyon/docs/sop/file_index.md` — add one row:

| `lib/services/image_pipeline/full_decoder_dispatch.dart` | Dispatching `DngFullDecoder`/`DngSizedDecoder`: TIFF via `package:image`, RAW via Ceyx, `UnsupportedError` otherwise |

- [ ] **Step 7: Verify the SOP edits landed and nothing leaked into git**

```bash
cd /Users/jhangyu/project/Halcyon-decoders
git status --porcelain | grep "docs/sop" ; echo "leak-check RC=$?"   # expect no match, RC=1
grep -c "AD-035" /Users/jhangyu/project/Halcyon/docs/sop/memory.md   # expect >= 1
grep -c "full_decoder_dispatch.dart" /Users/jhangyu/project/Halcyon/docs/sop/file_index.md  # expect >= 1
grep -o "TC-3[01][0-9]" /Users/jhangyu/project/Halcyon/docs/sop/unit_test.md | sort -u | wc -l  # expect >= 12
```
Expected: no `docs/sop` path in git status, and the three greps at or above their stated counts.

- [ ] **Step 8: Report the manual check the user owns**

Phase-1 acceptance criterion 9 is **user-run only** and must NOT be attempted by an agent (standing rule: UI performance and visual checks belong to the user). Report to the user, verbatim:

> Remaining manual check: open a folder containing one WebP and one TIFF. Both should appear in the sidebar and render in the detail view.

---
