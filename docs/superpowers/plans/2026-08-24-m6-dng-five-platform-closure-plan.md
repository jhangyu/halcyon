# M6 DNG Five-Platform Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the approved DNG contract on macOS, Windows, Android, iOS, and Linux, then delete the obsolete macOS/Windows DNG policy and close M6.

**Architecture:** Treat the Dart cutover and five FFI binaries as prerequisites. Add corpus-level contract coverage, verify each release artifact independently, run the preregistered Dart performance gate, and only then remove native DNG signals/extraction in separately revertible commits.

**Tech Stack:** Flutter/Dart tests, CMake native artifacts, platform release builds, Python 3 standard-library verification, existing M6 benchmark scripts.

---

Do not start this plan until the Dart, iOS, and Linux plans are merged. Anchor the run by recording both Halcyon and `../flutter_dng_decoder` commit hashes.

### Task 1: Synchronize the authoritative M6 documents

**Files:**
- Modify: `docs/logs/2026-08-24/m6-feature-platform-matrix.md`
- Modify: `docs/logs/2026-08-24/m6-spec-contract.md`
- Modify: `docs/logs/2026-08-24/m6-execution-plan.md`
- Verify: `docs/superpowers/specs/2026-08-24-m6-cross-platform-dng-design.md`

- [ ] **Step 1: Add a failing consistency checker**

Create `scripts/check_m6_dng_contract.py`:

```python
from pathlib import Path

files = {
    'matrix': Path('docs/logs/2026-08-24/m6-feature-platform-matrix.md').read_text(),
    'contract': Path('docs/logs/2026-08-24/m6-spec-contract.md').read_text(),
    'plan': Path('docs/logs/2026-08-24/m6-execution-plan.md').read_text(),
}
required = (
    'macOS, Windows, Android, iOS, Linux',
    'preview-less',
    'iOS',
    'Linux',
    'FFI',
)
for name, text in files.items():
    missing = [term for term in required if term not in text]
    assert not missing, f'{name}: missing {missing}'
    assert 'iOS/Linux decoder port is out of scope' not in text
    assert 'unsupported is acceptable for a valid preview-less DNG' not in text
print('M6_DNG_CONTRACT_SYNC_OK')
```

- [ ] **Step 2: Run red**

```bash
python3 scripts/check_m6_dng_contract.py; echo RC=$?
```

Expected: nonzero because the older DNG sections still allow platform demotion or leave Linux/iOS decoder work open/out of scope.

- [ ] **Step 3: Apply only the approved DNG supersession**

In all three documents state exactly:

```text
Supported DNG targets: macOS, Windows, Android, iOS, Linux; web excluded.
A valid preview-less DNG must render on every supported target.
Dart owns extraction, candidate selection, orientation, cost, signal, defer,
and fallback policy. The RAW algorithm remains native behind one FFI contract.
iOS and Linux decoder ports and packaging are M6 blockers.
A failed Dart performance gate requires optimisation and re-gating; it never
permits a Swift accelerator.
```

Preserve unrelated feature rulings.

- [ ] **Step 4: Run green and commit**

```bash
python3 scripts/check_m6_dng_contract.py; echo RC=$?
git add scripts/check_m6_dng_contract.py \
  docs/logs/2026-08-24/m6-feature-platform-matrix.md \
  docs/logs/2026-08-24/m6-spec-contract.md \
  docs/logs/2026-08-24/m6-execution-plan.md
git commit -m "docs(m6): synchronize five-platform DNG contract"
```

Expected: `M6_DNG_CONTRACT_SYNC_OK`, `RC=0`.

### Task 2: Close corpus gaps in Dart contract tests

**Files:**
- Modify: `test/dng_preview_extractor_m0_test.dart`
- Test: `test/dart_image_loader_test.dart`

- [ ] **Step 1: Add big-endian and truncated fixtures in the test**

Add this helper to `test/dng_preview_extractor_m0_test.dart`:

```dart
Future<File> writeMinimalBigEndianDng(String path) async {
  return File(path).writeAsBytes(const [
    0x4D, 0x4D, 0x00, 0x2A, // MM + TIFF magic
    0x00, 0x00, 0x00, 0x08, // IFD0 offset
    0x00, 0x01,             // one entry
    0x01, 0x12,             // Orientation
    0x00, 0x03,             // SHORT
    0x00, 0x00, 0x00, 0x01,
    0x00, 0x06, 0x00, 0x00, // orientation 6
    0x00, 0x00, 0x00, 0x00, // no next IFD
  ]);
}
```

Add tests:

```dart
test('big-endian valid DNG is a parsed miss with orientation 6', () async {
  final dir = await Directory.systemTemp.createTemp('m6_be_dng');
  addTearDown(() => dir.delete(recursive: true));
  final file = await writeMinimalBigEndianDng('${dir.path}/be.dng');
  final inspected = await DngPreviewExtractor.inspectEmbeddedJpeg(
    file.path,
    longEdge: 2800,
  );
  expect(inspected, isNotNull);
  expect(inspected!.candidate, isNull);
  expect(inspected.orientation, 6);
});

test('truncated big-endian DNG is parse failure', () async {
  final dir = await Directory.systemTemp.createTemp('m6_truncated_dng');
  addTearDown(() => dir.delete(recursive: true));
  final file = await File('${dir.path}/truncated.dng').writeAsBytes(
    const [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08, 0x00],
  );
  expect(
    await DngPreviewExtractor.inspectEmbeddedJpeg(
      file.path,
      longEdge: 2800,
    ),
    isNull,
  );
});
```

- [ ] **Step 2: Run focused tests**

```bash
flutter test test/dng_preview_extractor_m0_test.dart \
  test/dart_image_loader_test.dart; echo RC=$?
```

Expected: all pass and both byte orders are exercised.

- [ ] **Step 3: Commit**

```bash
git add test/dng_preview_extractor_m0_test.dart
git commit -m "test(m6): cover big-endian and truncated DNG contracts"
```

### Task 3: Verify all five FFI artifacts expose the same required ABI

**Files:**
- Create: `scripts/check_dng_ffi_artifacts.py`
- Verify binary locations in `../flutter_dng_decoder/dng_processor_ffi/`

- [ ] **Step 1: Add the artifact checker**

```python
from pathlib import Path

artifacts = {
    'macos': Path('../flutter_dng_decoder/dng_processor_ffi/macos/Libraries/libdng_decoder_native.dylib'),
    'android': Path('../flutter_dng_decoder/dng_processor_ffi/android/src/main/jniLibs/arm64-v8a/libdng_decoder_native.so'),
    'windows': Path('../flutter_dng_decoder/dng_processor_ffi/windows/Libraries/dng_decoder_native.dll'),
    'ios': Path('../flutter_dng_decoder/dng_processor_ffi/ios/Libraries/libdng_decoder_native.a'),
    'linux': Path('../flutter_dng_decoder/dng_processor_ffi/linux/Libraries/libdng_decoder_native.so'),
}
missing = [name for name, path in artifacts.items() if not path.is_file()]
assert not missing, f'missing decoder artifacts: {missing}'
for name, path in artifacts.items():
    assert path.stat().st_size > 100_000, f'{name}: suspiciously small {path}'
    print(f'{name},{path.stat().st_size},{path}')
print('M6_DNG_ARTIFACTS_PRESENT')
```

- [ ] **Step 2: Run presence check**

```bash
python3 scripts/check_dng_ffi_artifacts.py; echo RC=$?
```

Expected: five artifact rows and `RC=0`.

- [ ] **Step 3: Run platform symbol tools**

On macOS:

```bash
nm -gU ../flutter_dng_decoder/dng_processor_ffi/macos/Libraries/libdng_decoder_native.dylib | grep dng_decode_and_process_sized
nm -gU ../flutter_dng_decoder/dng_processor_ffi/ios/Libraries/libdng_decoder_native.a | grep dng_decode_and_process_sized
```

On Linux:

```bash
nm -D --defined-only ../flutter_dng_decoder/dng_processor_ffi/linux/Libraries/libdng_decoder_native.so | grep dng_decode_and_process_sized
```

On Windows:

```powershell
dumpbin /exports ..\flutter_dng_decoder\dng_processor_ffi\windows\Libraries\dng_decoder_native.dll | findstr dng_decode_and_process_sized
```

On Android build host:

```bash
nm -D --defined-only ../flutter_dng_decoder/dng_processor_ffi/android/src/main/jniLibs/arm64-v8a/libdng_decoder_native.so | grep dng_decode_and_process_sized
```

Expected: every artifact exports the sized and full decode entry points. Rebuild any stale binary from the same decoder commit before proceeding.

- [ ] **Step 4: Commit the checker**

```bash
git add scripts/check_dng_ffi_artifacts.py
git commit -m "test(m6): verify five packaged DNG decoders"
```

### Task 4: Run the preregistered Dart extraction and sidebar gates

**Files:**
- Create: `tool/m6_dng_gate/g1_dart.dart`
- Create: `tool/m6_dng_gate/g1_native.swift`
- Create: `tool/m6_dng_gate/iso_probe.dart`
- Create: `tool/m6_dng_gate/dng_list.txt`
- Create: `tool/m6_dng_gate/run_g1.sh`
- Create: `scripts/verdict_m6_dng_extract.py`
- Artifact: `scripts/tmp/m6-r1-verify/g1-final.txt`

- [ ] **Step 1: Promote the preregistered G1 harness into tracked tooling**

```bash
test -f scripts/tmp/m6-r1-bench/g1_dart.dart
test -f scripts/tmp/m6-r1-bench/g1_native.swift
test -f scripts/tmp/m6-r1-bench/iso_probe.dart
test -f scripts/tmp/m6-r1-bench/dng_list.txt
test -f scripts/tmp/m6-r1-bench/run_g1.sh
mkdir -p tool/m6_dng_gate
cp scripts/tmp/m6-r1-bench/g1_dart.dart tool/m6_dng_gate/
cp scripts/tmp/m6-r1-bench/g1_native.swift tool/m6_dng_gate/
cp scripts/tmp/m6-r1-bench/iso_probe.dart tool/m6_dng_gate/
cp scripts/tmp/m6-r1-bench/dng_list.txt tool/m6_dng_gate/
cp scripts/tmp/m6-r1-bench/run_g1.sh tool/m6_dng_gate/
```

In `g1_dart.dart`, change the import to `../../lib/services/dng_preview_extractor.dart` and replace both call functions:

```dart
Future<Uint8List?> callV1(String path) async =>
    (await DngPreviewExtractor.inspectEmbeddedJpeg(
      path,
      longEdge: 2800,
    ))?.candidate?.bytes;

Future<Uint8List?> callV2(String path) => Isolate.run(
      () async => (await DngPreviewExtractor.inspectEmbeddedJpeg(
        path,
        longEdge: 2800,
      ))?.candidate?.bytes,
    );
```

In `run_g1.sh`, set:

```bash
B=tool/m6_dng_gate
W=scripts/tmp/m6_dng_gate/work
```

This makes the benchmark measure the production request-aware Dart contract instead of the obsolete full-size API.

- [ ] **Step 2: Add a verdict that uses Swift only as a timing baseline**

Create `scripts/verdict_m6_dng_extract.py`:

```python
import csv
import sys

native = {row['file']: row for row in csv.DictReader(open(sys.argv[1]))}
dart = {row['file']: row for row in csv.DictReader(open(sys.argv[2]))}
failures = []
for name, baseline in sorted(native.items()):
    if baseline['found'] != 'true':
        continue
    actual = dart[name]
    if actual['found'] != 'true':
        failures.append(f'{name}: Dart returned no candidate')
        continue
    native_ms = float(baseline['warm_median_ms'])
    dart_ms = float(actual['warm_median_ms'])
    dims = tuple(int(part) for part in actual['sof_dims'].split('x'))
    if dart_ms > native_ms * 2:
        failures.append(f'{name}: latency ratio {dart_ms / native_ms:.3f} > 2.0')
    if max(dims) < 2800:
        failures.append(f'{name}: selected long edge {max(dims)} < 2800')
if failures:
    print('M6_DNG_EXTRACT_FAIL')
    print('\n'.join(failures))
    raise SystemExit(1)
print('M6_DNG_EXTRACT_PASS')
```

This deliberately does not compare candidate byte identity or dimensions with Swift; the approved Dart request-aware contract is the output oracle.

- [ ] **Step 3: Run G1 and the new verdict**

```bash
cat > scripts/tmp/m6-r1-verify/g1-final.txt <<'EOF'
M6 final Dart extraction gate
Rule: V1 Dart warm median <= 2x Swift timing baseline per applicable sample.
Rule: Dart selected candidate long edge >= 2800.
Rule: Swift bytes and candidate identity are not output oracles.
EOF
bash tool/m6_dng_gate/run_g1.sh \
  scripts/tmp/m6-r1-verify/g1-final.txt; echo RUNNER_RC=$?
python3 scripts/verdict_m6_dng_extract.py \
  scripts/tmp/m6_dng_gate/work/g1_native.csv \
  scripts/tmp/m6_dng_gate/work/g1_dart_v1.csv | \
  tee -a scripts/tmp/m6-r1-verify/g1-final.txt
```

Expected: `RUNNER_RC=0` and `M6_DNG_EXTRACT_PASS`.

- [ ] **Step 4: Commit the tracked harness and verdict**

```bash
git add tool/m6_dng_gate scripts/verdict_m6_dng_extract.py
git commit -m "test(m6): gate request-aware Dart DNG extraction"
```

- [ ] **Step 5: Run the tracked sidebar RAW contract tests with the vendored decoder**

```bash
DNG_NATIVE_BUILD_DIR=../flutter_dng_decoder/dng_processor_ffi/macos/Libraries \
flutter test test/sidebar_thumbnail_codec_test.dart \
  test/image_preload_controller_test.dart \
  test/image_preload_dual_window_m5_test.dart; echo RC=$?
```

Expected: `RC=0`; embedded sidebar requests do not RAW-decode, preview-less sidebar requests decode once, and M5 full-resolution reuse remains green.

- [ ] **Step 6: Stop on failure**

Do not start native deletion if extraction or sidebar gates fail. Optimise the shared Dart extractor, FFI sized decode, or sidebar encoding and rerun the unchanged tracked gate.

### Task 5: Remove DNG channel semantics and neutralize result ownership

**Files:**
- Create: `lib/services/image_source_types.dart`
- Modify: imports in `lib/services/dart_image_loader.dart`, `photo_source.dart`, `image_preload_controller.dart`, tests
- Modify: `lib/services/native_thumbnail_service.dart`
- Test: `test/native_thumbnail_service_test.dart`
- Test: `test/m6_bridge_free_test.dart`

- [ ] **Step 1: Move the existing shared types without renaming variants**

Create `image_source_types.dart` with the neutral shared declarations:

```dart
import 'dart:typed_data';

enum ImageRequestPurpose {
  sidebarThumbnail(targetSize: 200, platformValue: 'sidebarThumbnail'),
  preview(targetSize: 2800, platformValue: 'preview'),
  export(targetSize: 2048, platformValue: 'export');

  const ImageRequestPurpose({
    required this.targetSize,
    required this.platformValue,
  });

  final int targetSize;
  final String platformValue;
}

sealed class NativeImageResult {
  const NativeImageResult();
}

class NativeImageBytes extends NativeImageResult {
  const NativeImageBytes(this.bytes);
  final Uint8List bytes;
}

class NativeImageNeedsRawDecode extends NativeImageResult {
  const NativeImageNeedsRawDecode({required this.exifOrientation});
  final int exifOrientation;
}

class NativeImageFailure extends NativeImageResult {
  const NativeImageFailure(this.code, this.message);
  final String code;
  final String? message;
}

const int kDefaultExifOrientation = 1;
```

`native_thumbnail_service.dart` imports and re-exports the neutral file temporarily:

```dart
export 'image_source_types.dart';
import 'image_source_types.dart';
```

- [ ] **Step 2: Run analyze before deleting channel semantics**

```bash
flutter analyze; echo RC=$?
```

Expected: `RC=0`.

- [ ] **Step 3: Delete DNG signal negotiation from the service**

Remove:

```dart
kNoEmbeddedPreviewCode
kAllowRawDecodeSignalArg
allowRawDecodeSignal
_parseOrientation
```

`requestImage` maps every `PlatformException` to `NativeImageFailure`; it no longer constructs `NativeImageNeedsRawDecode`. Update the channel argument map to only `path`, `purpose`, and `targetSize`.

- [ ] **Step 4: Replace signal-mapping tests with a negative producer test**

```dart
test('native service never produces the Dart decode-required variant', () async {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('halcyon/thumbnail'),
          (call) async {
    throw PlatformException(code: 'NO_EMBEDDED_PREVIEW', details: 6);
  });
  final result = await NativeThumbnailService.requestImage('/x.dng');
  expect(result, isA<NativeImageFailure>());
  expect(result, isNot(isA<NativeImageNeedsRawDecode>()));
});
```

- [ ] **Step 5: Run and commit**

```bash
flutter test test/native_thumbnail_service_test.dart \
  test/dart_image_loader_test.dart \
  test/m6_bridge_free_test.dart; echo RC=$?
git add lib/services/image_source_types.dart \
  lib/services/native_thumbnail_service.dart \
  lib/services/dart_image_loader.dart \
  lib/services/photo_source.dart \
  lib/services/image_preload_controller.dart \
  test/native_thumbnail_service_test.dart \
  test/dart_image_loader_test.dart \
  test/m6_bridge_free_test.dart
git commit -m "refactor(m6): move DNG result ownership out of native service"
```

### Task 6: Delete the macOS Swift DNG path

**Files:**
- Modify: `macos/Runner/AppDelegate.swift:302-516`
- Delete: `macos/Runner/DngPreviewExtractor.swift`
- Modify: `macos/Runner.xcodeproj/project.pbxproj`

- [ ] **Step 1: Prove production already bypasses the path**

```bash
grep -R "halcyon/thumbnail" lib/services/dart_image_loader.dart \
  lib/services/photo_source.dart; echo DART_CHANNEL_RC=$?
grep -R "extractFullSizeEmbeddedJpeg\|readDngOrientation" \
  macos/Runner/AppDelegate.swift
```

Expected: Dart grep RC is 1; Swift grep still finds the obsolete call sites.

- [ ] **Step 2: Remove only DNG extraction/signal code**

Delete the `isDng` embedded extraction branch, `NO_EMBEDDED_PREVIEW` result, orientation call, and `allowRawDecodeSignal` argument handling from `AppDelegate.swift`. Preserve unrelated JPEG/export/OS integration code.

Delete `DngPreviewExtractor.swift` and its file/build references from `project.pbxproj`.

- [ ] **Step 3: Build and verify zero call sites**

```bash
flutter build macos --release; echo BUILD_RC=$?
grep -R "NO_EMBEDDED_PREVIEW\|allowRawDecodeSignal\|extractFullSizeEmbeddedJpeg\|readDngOrientation" \
  lib macos; echo DNG_NATIVE_GREP_RC=$?
```

Expected: `BUILD_RC=0`, `DNG_NATIVE_GREP_RC=1`.

- [ ] **Step 4: Commit independently**

```bash
git add macos/Runner/AppDelegate.swift \
  macos/Runner.xcodeproj/project.pbxproj \
  macos/Runner/DngPreviewExtractor.swift
git commit -m "refactor(m6): remove macOS native DNG policy"
```

### Task 7: Remove Windows DNG negotiation residue

**Files:**
- Modify: `windows/runner/halcyon_channels.cpp`
- Modify: `windows/runner/halcyon_image.cpp`
- Modify: `windows/runner/halcyon_native.h`

- [ ] **Step 1: Remove the unused `allowRawDecodeSignal` argument and stale DNG comments**

The Windows channel must no longer read or describe `allowRawDecodeSignal`. Keep non-DNG legacy image mechanics only if another in-scope feature still calls them; DNG production must remain bridge-free.

- [ ] **Step 2: Build on Windows**

```powershell
flutter pub get
flutter build windows --release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
```

Expected: release build succeeds.

- [ ] **Step 3: Verify no DNG signal literals remain and commit**

```powershell
git grep -n "NO_EMBEDDED_PREVIEW\|allowRawDecodeSignal"
if ($LASTEXITCODE -eq 0) { exit 1 }
git add windows/runner/halcyon_channels.cpp windows/runner/halcyon_image.cpp windows/runner/halcyon_native.h
git commit -m "refactor(m6): remove Windows DNG channel negotiation"
```

### Task 8: Run five-platform release and visible-image gates

**Files:**
- Create/update: `docs/logs/2026-08-24/m6-macos-dng-smoke.md`
- Create/update: `docs/logs/2026-08-24/m6-windows-dng-smoke.md`
- Create/update: `docs/logs/2026-08-24/m6-android-dng-smoke.md`
- Require: `docs/logs/2026-08-24/m6-ios-dng-smoke.md`
- Require: `docs/logs/2026-08-24/m6-linux-dng-smoke.md`

- [ ] **Step 1: Run shared Dart gates**

```bash
flutter analyze; echo ANALYZE_RC=$?
flutter test -j 1; echo TEST_RC=$?
```

Expected: both zero.

- [ ] **Step 2: Build each release artifact on its owning host**

```bash
flutter build macos --release
flutter build apk --release
```

```powershell
flutter build windows --release
```

```bash
flutter build ios --release
flutter build linux --release
```

Expected: all builds succeed and package their decoder artifact.

- [ ] **Step 3: Display the same canonical valid preview-less sample**

Use `local_data/photo_samples/DNG/2024-07-03-18-52-26.dng` on all five targets. Each smoke record must include platform/OS/device/GPU, both repo commits, sample SHA-256, dimensions, orientation, visible-image confirmation, and build/run RCs.

- [ ] **Step 4: Enforce completion mechanically**

```bash
python3 scripts/check_m6_dng_contract.py
python3 scripts/check_dng_ffi_artifacts.py
git grep -n "NO_EMBEDDED_PREVIEW\|allowRawDecodeSignal\|extractFullSizeEmbeddedJpeg(url:\|readDngOrientation(url:"
```

Expected: both scripts print success; grep has no matches and returns 1.

- [ ] **Step 5: Commit final closure docs**

```bash
git add docs/logs/2026-08-24/m6-*-dng-smoke.md \
  docs/logs/2026-08-24/m6-feature-platform-matrix.md \
  docs/logs/2026-08-24/m6-spec-contract.md \
  docs/logs/2026-08-24/m6-execution-plan.md
git commit -m "docs(m6): close five-platform DNG migration"
```

M6 closes only if all five smoke records say the valid preview-less sample visibly rendered. Compile-only evidence is insufficient.
