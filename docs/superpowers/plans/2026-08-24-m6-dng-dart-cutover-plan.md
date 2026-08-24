# M6 DNG Dart Cutover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make one request-aware Dart TIFF/IFD walk the sole source of DNG candidate, orientation, valid-miss, and parse-failure decisions, and remove macOS-only fallback semantics from `PhotoSource`.

**Architecture:** Extend the existing `DngPreviewExtractor` seam with one inspection result rather than adding a service hierarchy. `dartImageLoad` maps that result into the existing three image variants; `PhotoSource` defers or invokes the injected FFI decoder exactly once and never re-requests an OS thumbnail.

**Tech Stack:** Dart 3.12, Flutter test, `dart:io`, existing `DngPreviewExtractor`, `PhotoSource`, and `DngFullDecoder` seams.

---

### Task 1: Capture a reproducible tracked-code baseline

**Files:**
- Verify: `test/dng_preview_extractor_m0_test.dart`
- Verify: `test/dart_image_loader_test.dart`
- Verify: `test/photo_source_test.dart`
- Verify: `test/image_preload_controller_test.dart`

- [ ] **Step 1: Assert required tracked inputs exist**

```bash
test -f ../flutter_dng_decoder/dng_processor_ffi/macos/Libraries/libdng_decoder_native.dylib
test -f local_data/photo_samples/DNG/2024-07-03-18-52-26.dng
test -f test/dng_preview_extractor_m0_test.dart
echo RC=$?
```

Expected: `RC=0`. Stop if the sibling decoder checkout or canonical corpus is absent; do not substitute another library or sample silently.

- [ ] **Step 2: Run the current focused baseline**

```bash
flutter test test/dng_preview_extractor_m0_test.dart \
  test/dart_image_loader_test.dart \
  test/photo_source_test.dart \
  test/image_preload_controller_test.dart; echo RC=$?
```

Expected: `RC=0`. The five-platform performance gate is deliberately deferred to the tracked closure-plan verdict rather than depending on gitignored `scripts/tmp` harnesses.

### Task 2: Add one-walk request-aware DNG inspection

**Files:**
- Modify: `lib/services/dng_preview_extractor.dart:24-41,50-92,281-316,436-459`
- Test: `test/dng_preview_extractor_m0_test.dart:54-229`

- [ ] **Step 1: Write failing inspection tests**

Add to `test/dng_preview_extractor_m0_test.dart`:

```dart
test('inspection distinguishes candidate, valid miss, and parse failure', () async {
  final hit = await DngPreviewExtractor.inspectEmbeddedJpeg(
    '${sampleDir.path}/2026-02-15-19-37-38.dng',
    longEdge: 200,
  );
  expect(hit, isNotNull);
  expect(hit!.candidate, isNotNull);
  expect(hit.candidate!.width, 256);
  expect(hit.orientation, 1);

  final validMiss = await DngPreviewExtractor.inspectEmbeddedJpeg(
    '${sampleDir.path}/$noPreviewFile',
    longEdge: 2800,
  );
  expect(validMiss, isNotNull);
  expect(validMiss!.candidate, isNull);
  expect(validMiss.orientation, inInclusiveRange(1, 8));

  final malformed = await File(
    '${Directory.systemTemp.path}/m6_malformed.dng',
  ).writeAsBytes(const [0x49, 0x49, 0x2A]);
  addTearDown(() => malformed.delete());
  expect(
    await DngPreviewExtractor.inspectEmbeddedJpeg(
      malformed.path,
      longEdge: 2800,
    ),
    isNull,
  );
});

test('request-aware selection rejects a real but undersized candidate', () async {
  final inspected = await DngPreviewExtractor.inspectEmbeddedJpeg(
    'test/fixtures/m6_dng/synth_too_small.dng',
    longEdge: 2800,
  );
  expect(inspected, isNotNull);
  expect(inspected!.candidate, isNull);
});

test('orientation is clamped to 1..8 in Dart inspection', () async {
  final original = await File(
    'test/fixtures/m6_dng/synth_orient8.dng',
  ).readAsBytes();
  const marker = [0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00];
  int markerOffset(List<int> bytes) {
    for (var i = 0; i <= bytes.length - marker.length; i++) {
      var match = true;
      for (var j = 0; j < marker.length; j++) {
        if (bytes[i + j] != marker[j]) match = false;
      }
      if (match) return i;
    }
    throw StateError('Orientation entry not found');
  }
  for (final (raw, expected) in const [(0, 1), (1, 1), (8, 8), (9, 1)]) {
    final bytes = Uint8List.fromList(original);
    final offset = markerOffset(bytes);
    bytes[offset + 8] = raw;
    bytes[offset + 9] = 0;
    final file = await File(
      '${Directory.systemTemp.path}/m6_orientation_$raw.dng',
    ).writeAsBytes(bytes);
    addTearDown(() => file.delete());
    final inspected = await DngPreviewExtractor.inspectEmbeddedJpeg(
      file.path,
      longEdge: 200,
    );
    expect(inspected!.orientation, expected);
  }
});

test('corrupt-only JPEG candidate is parse failure, not valid miss', () async {
  final bytes = await File(
    'test/fixtures/m6_dng/synth_too_small.dng',
  ).readAsBytes();
  const marker = [0x11, 0x01, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00];
  var entry = -1;
  for (var i = 0; i <= bytes.length - marker.length; i++) {
    var match = true;
    for (var j = 0; j < marker.length; j++) {
      if (bytes[i + j] != marker[j]) match = false;
    }
    if (match) {
      entry = i;
      break;
    }
  }
  expect(entry, greaterThanOrEqualTo(0));
  bytes.setRange(entry + 8, entry + 12, const [0xFF, 0xFF, 0xFF, 0x7F]);
  final file = await File(
    '${Directory.systemTemp.path}/m6_bad_offset.dng',
  ).writeAsBytes(bytes);
  addTearDown(() => file.delete());
  expect(
    await DngPreviewExtractor.inspectEmbeddedJpeg(
      file.path,
      longEdge: 2800,
    ),
    isNull,
  );
});
```

- [ ] **Step 2: Promote the deterministic undersized fixture and run red**

```bash
mkdir -p test/fixtures/m6_dng
cp scripts/tmp/fixtures/synth_too_small.dng \
  test/fixtures/m6_dng/synth_too_small.dng
cp scripts/tmp/fixtures/synth_orient8.dng \
  test/fixtures/m6_dng/synth_orient8.dng
test -s test/fixtures/m6_dng/synth_too_small.dng
test -s test/fixtures/m6_dng/synth_orient8.dng; echo FIXTURE_RC=$?
flutter test test/dng_preview_extractor_m0_test.dart; echo TEST_RC=$?
```

Expected: `FIXTURE_RC=0`; test compilation fails because `inspectEmbeddedJpeg` does not exist. The committed fixture makes the regression reproducible without the gitignored generator.

- [ ] **Step 3: Add the inspection value type and public method**

Add beside `DngEmbeddedJpeg`:

```dart
class DngPreviewInspection {
  const DngPreviewInspection({
    required this.candidate,
    required this.orientation,
  });

  final DngEmbeddedJpeg? candidate;
  final int orientation;
}
```

Add to `DngPreviewExtractor` and make `extractEmbeddedJpeg` delegate to it:

```dart
static Future<DngPreviewInspection?> inspectEmbeddedJpeg(
  String path, {
  required int longEdge,
  void Function(int byteCount)? onDiskRead,
}) async {
  RandomAccessFile? raf;
  try {
    raf = await File(path).open();
    final length = await raf.length();
    if (length < 8) return null;
    return _inspect(
      _FileSource(raf, length, onDiskRead),
      longEdge,
    );
  } catch (_) {
    return null;
  } finally {
    try {
      await raf?.close();
    } catch (_) {}
  }
}

static Future<DngEmbeddedJpeg?> extractEmbeddedJpeg(
  String path, {
  int? longEdge,
  void Function(int byteCount)? onDiskRead,
}) async {
  if (longEdge != null) {
    return (await inspectEmbeddedJpeg(
      path,
      longEdge: longEdge,
      onDiskRead: onDiskRead,
    ))?.candidate;
  }
  RandomAccessFile? raf;
  try {
    raf = await File(path).open();
    final length = await raf.length();
    if (length < 8) return null;
    return _walk(_FileSource(raf, length, onDiskRead), null);
  } catch (_) {
    return null;
  } finally {
    try {
      await raf?.close();
    } catch (_) {}
  }
}
```

Refactor `_walk` through this helper:

```dart
static DngPreviewInspection? _inspect(_ByteSource source, int longEdge) {
  final reader = _readerFor(source);
  if (reader == null) return null;
  final ifd0 = _readIFD0(reader);
  if (ifd0 == null) return null;
  final orientation = _sanitizeOrientation(_orientationOf(reader, ifd0));
  final gathered = _gatherCandidates(reader, source, ifd0, longEdge);
  if (gathered == null) return null;
  if (gathered.candidates.isEmpty && gathered.malformedCandidate) return null;
  final best = _select(gathered.candidates, longEdge);
  if (best == null) {
    return DngPreviewInspection(candidate: null, orientation: orientation);
  }
  final jpeg = source.read(best.offset, best.byteCount);
  if (jpeg == null || jpeg.length != best.byteCount) return null;
  final bytes = orientation == 1
      ? jpeg
      : (_injectExifOrientation(jpeg, orientation) ?? jpeg);
  return DngPreviewInspection(
    candidate: DngEmbeddedJpeg(
      bytes: bytes,
      width: best.width,
      height: best.height,
      orientation: orientation,
    ),
    orientation: orientation,
  );
}

static int _sanitizeOrientation(int? value) =>
    value != null && value >= 1 && value <= 8 ? value : 1;

static DngEmbeddedJpeg? _walk(_ByteSource source, int? longEdge) {
  if (longEdge != null) return _inspect(source, longEdge)?.candidate;
  // Keep the existing full-size body here for compatibility callers.
  final reader = _readerFor(source);
  if (reader == null) return null;
  final ifd0 = _readIFD0(reader);
  if (ifd0 == null) return null;
  final orientation = _sanitizeOrientation(_orientationOf(reader, ifd0));
  final gathered = _gatherCandidates(reader, source, ifd0, null);
  if (gathered == null) return null;
  if (gathered.candidates.isEmpty && gathered.malformedCandidate) return null;
  final best = _select(gathered.candidates, null);
  if (best == null) return null;
  final jpeg = source.read(best.offset, best.byteCount);
  if (jpeg == null || jpeg.length != best.byteCount) return null;
  final bytes = orientation == 1
      ? jpeg
      : (_injectExifOrientation(jpeg, orientation) ?? jpeg);
  return DngEmbeddedJpeg(
    bytes: bytes,
    width: best.width,
    height: best.height,
    orientation: orientation,
  );
}
```

Change `_gatherCandidates` to return a private result instead of silently merging corrupt offsets with a genuine empty candidate set:

```dart
class _CandidateGather {
  const _CandidateGather(this.candidates, this.malformedCandidate);
  final List<_Candidate> candidates;
  final bool malformedCandidate;
}
```

Change its return type to `_CandidateGather?`, initialize `var malformedCandidate = false`, set it to true before continuing on an invalid offset/count, and return:

```dart
return _CandidateGather(candidates, malformedCandidate);
```

Update `probeContent` to iterate `gathered.candidates`; return `null` when the list is empty and `malformedCandidate` is true. This keeps a corrupt-only candidate table out of the RAW-decode path.

Use `_sanitizeOrientation` in `_inspect`, `_walk`, and `probeContent`. Add a table-driven test that patches `synth_orient8.dng`'s Orientation SHORT to values `0, 1, 8, 9` and expects `1, 1, 8, 1`, respectively.

Change request-aware `_select` to reject undersized candidates:

```dart
if (longEdge == null) return largest;
_Candidate? smallestReaching;
for (final candidate in candidates) {
  if (candidate.maxDim < longEdge) continue;
  if (smallestReaching == null || candidate.area < smallestReaching.area) {
    smallestReaching = candidate;
  }
}
return smallestReaching;
```

- [ ] **Step 4: Run focused tests**

```bash
flutter test test/dng_preview_extractor_m0_test.dart \
  test/dng_preview_extractor_test.dart \
  test/dng_preview_extractor_f3_test.dart; echo RC=$?
```

Expected: all pass; bounded-read AC remains green.

- [ ] **Step 5: Commit**

```bash
git add lib/services/dng_preview_extractor.dart \
  test/dng_preview_extractor_m0_test.dart \
  test/fixtures/m6_dng/synth_too_small.dng \
  test/fixtures/m6_dng/synth_orient8.dng
git commit -m "feat(m6): add request-aware one-walk DNG inspection"
```

### Task 3: Make `dartImageLoad` consume the inspection result

**Files:**
- Modify: `lib/services/dart_image_loader.dart:17-75`
- Test: `test/dart_image_loader_test.dart`

- [ ] **Step 1: Rewrite expectations before production code**

Replace full-size extractor comparisons with request-aware inspection and add malformed distinction:

```dart
test('malformed DNG is failure, not raw-decode work', () async {
  final dir = await Directory.systemTemp.createTemp('m6_bad_dng');
  addTearDown(() => dir.delete(recursive: true));
  final bad = await File('${dir.path}/bad.dng').writeAsBytes(
    const [0x49, 0x49, 0x2A],
  );
  final result = await dartImageLoad(
    bad.path,
    purpose: ImageRequestPurpose.preview,
  );
  expect(result, isA<NativeImageFailure>());
  expect((result as NativeImageFailure).code, 'DNG_PARSE_FAILED');
});

test('preview DNG uses the smallest candidate meeting 2800', () async {
  final path = '${sampleDir.path}/2026-02-15-19-37-38.dng';
  final inspected = await DngPreviewExtractor.inspectEmbeddedJpeg(
    path,
    longEdge: ImageRequestPurpose.preview.targetSize,
  );
  final result = await dartImageLoad(
    path,
    purpose: ImageRequestPurpose.preview,
  );
  expect(inspected!.candidate, isNotNull);
  expect(result, isA<NativeImageBytes>());
  expect((result as NativeImageBytes).bytes, inspected.candidate!.bytes);
});
```

- [ ] **Step 2: Run red**

```bash
flutter test test/dart_image_loader_test.dart; echo RC=$?
```

Expected: malformed DNG currently becomes `NativeImageNeedsRawDecode`, so the new test fails.

- [ ] **Step 3: Replace separate extraction/orientation calls with one inspection**

Use this DNG/RAW branch in `dartImageLoad` after encoded-file and existence checks:

```dart
final inspection = await DngPreviewExtractor.inspectEmbeddedJpeg(
  path,
  longEdge: purpose.targetSize,
);
if (inspection == null) {
  return const NativeImageFailure(
    'DNG_PARSE_FAILED',
    'file is not a readable TIFF/DNG container',
  );
}
final candidate = inspection.candidate;
if (candidate != null) return NativeImageBytes(candidate.bytes);
if (purpose == ImageRequestPurpose.preview && lower.endsWith('.dng')) {
  return NativeImageNeedsRawDecode(
    exifOrientation: inspection.orientation,
  );
}
return const NativeImageFailure(
  'RAW_NO_EMBEDDED_PREVIEW',
  'no embedded preview and no decoder for this format',
);
```

Delete the sidebar-only extraction branch, `extractFullSizeEmbeddedJpegFromFile` call, and second `readOrientation` walk.

- [ ] **Step 4: Run loader and bridge-negative tests**

```bash
flutter test test/dart_image_loader_test.dart \
  test/m6_bridge_free_test.dart; echo RC=$?
```

Expected: all pass; production loader never invokes a method channel.

- [ ] **Step 5: Commit**

```bash
git add lib/services/dart_image_loader.dart test/dart_image_loader_test.dart
git commit -m "feat(m6): make Dart inspection the DNG result authority"
```

### Task 4: Remove legacy OS fallback semantics from `PhotoSource`

**Files:**
- Modify: `lib/services/photo_source.dart:87-251,274-287`
- Modify: `lib/services/dng_decode_contract.dart:25-39`
- Test: `test/photo_source_test.dart`
- Test: `test/image_preload_controller_test.dart`

- [ ] **Step 1: Write shared-failure tests that observe the real channel**

Import `dart:typed_data` and `package:flutter/services.dart`, then add:

```dart
test('missing decoder never invokes the legacy thumbnail channel', () async {
  const channel = MethodChannel('halcyon/thumbnail');
  var channelCalls = 0;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    channelCalls++;
    return Uint8List.fromList([1, 2, 3]);
  });
  addTearDown(() => TestDefaultBinaryMessengerBinding.instance
      .defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

  final source = PhotoSource(
    loader: (path, {required purpose}) async =>
        const NativeImageNeedsRawDecode(exifOrientation: 1),
  );
  final outcome = await source.load('/valid.dng', longEdge: 1200);
  expect(channelCalls, 0);
  expect(outcome.payload, isNull);
  expect(outcome.observedCost, SourceCost.expensive);
  expect(outcome.deferred, isFalse);
});

test('throwing decoder never invokes the legacy thumbnail channel', () async {
  const channel = MethodChannel('halcyon/thumbnail');
  var channelCalls = 0;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    channelCalls++;
    return Uint8List.fromList([1, 2, 3]);
  });
  addTearDown(() => TestDefaultBinaryMessengerBinding.instance
      .defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

  final source = PhotoSource(
    loader: (path, {required purpose}) async =>
        const NativeImageNeedsRawDecode(exifOrientation: 1),
    dngDecoder: (_) => throw StateError('decode failed'),
  );
  final outcome = await source.load('/valid.dng', longEdge: 1200);
  expect(channelCalls, 0);
  expect(outcome.payload, isNull);
  expect(outcome.observedCost, SourceCost.expensive);

  final expensive = await source.loadExpensive(
    '/valid.dng',
    longEdge: 1200,
    exifOrientation: 1,
  );
  expect(channelCalls, 0);
  expect(expensive.payload, isNull);
});
```

- [ ] **Step 2: Run red**

```bash
flutter test test/photo_source_test.dart \
  test/image_preload_controller_test.dart; echo RC=$?
```

Expected: existing `_legacyBytes` performs a second loader request or old tests expect legacy bytes.

- [ ] **Step 3: Delete `_legacyBytes` and return one shared failure outcome**

In `load` and `loadExpensive`, replace decoder-null and catch blocks with:

```dart
return (
  payload: null,
  observedCost: SourceCost.expensive,
  deferred: false,
  exifOrientation: null,
  fullRes: null,
);
```

Delete `_legacyBytes`, all `allowRawDecodeSignal` commentary, and the fallback wording in `dng_decode_contract.dart`. Keep `allowExpensive == false` unchanged so it returns deferred with orientation and zero decodes.

Replace the legacy-CIRAWFilter expectations in `test/image_preload_controller_test.dart:1198-1385` and `test/image_preload_scheduling_m4_test.dart:385-431` with the same shared permanent-miss expectation and zero-channel assertion. Do not delete unrelated scheduling assertions.

- [ ] **Step 4: Run focused and M5 tests**

```bash
flutter test test/photo_source_test.dart \
  test/image_preload_controller_test.dart \
  test/image_preload_scheduling_m4_test.dart \
  test/image_preload_dual_window_m5_test.dart; echo RC=$?
```

Expected: all pass; expensive success invokes the fake decoder exactly once and still produces `fullRes` from the same decode.

- [ ] **Step 5: Commit**

```bash
git add lib/services/photo_source.dart \
  lib/services/dng_decode_contract.dart \
  test/photo_source_test.dart \
  test/image_preload_controller_test.dart \
  test/image_preload_scheduling_m4_test.dart
git commit -m "refactor(m6): remove platform RAW fallback from PhotoSource"
```

### Task 5: Dart cutover verification

**Files:**
- Verify: `lib/services/dng_preview_extractor.dart`
- Verify: `lib/services/dart_image_loader.dart`
- Verify: `lib/services/photo_source.dart`
- Artifact: `scripts/tmp/m6-dart-cutover-verify.txt`

- [ ] **Step 1: Run static and focused gates with captured exit codes**

```bash
mkdir -p scripts/tmp
set +e
bash -c '
  set -e
  flutter analyze
  flutter test test/dng_preview_extractor_m0_test.dart \
    test/dart_image_loader_test.dart \
    test/m6_bridge_free_test.dart \
    test/photo_source_test.dart \
    test/image_preload_controller_test.dart \
    test/image_preload_scheduling_m4_test.dart \
    test/image_preload_dual_window_m5_test.dart
  flutter test -j 1
  if grep -q "NativeThumbnailService.getThumbnail" \
      lib/services/photo_source.dart; then
    echo "legacy fallback call remains"
    exit 1
  fi
  echo M6_DART_CUTOVER_PASS
' > scripts/tmp/m6-dart-cutover-verify.txt 2>&1
VERIFY_RC=$?
cat scripts/tmp/m6-dart-cutover-verify.txt
test "$VERIFY_RC" -eq 0
```

Expected: `M6_DART_CUTOVER_PASS` and final shell RC zero. Any analyze/test/grep violation makes the gate nonzero.

- [ ] **Step 2: Confirm scope and commit only if verification required a tracked fix**

```bash
git status --short
git diff --check
```

Expected: no unplanned tracked files. Do not commit generated build files or `scripts/tmp` artifacts.
