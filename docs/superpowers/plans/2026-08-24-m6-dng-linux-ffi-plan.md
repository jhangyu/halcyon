# M6 DNG Linux FFI Decoder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build, package, and verify the existing Vulkan DNG decoder as `libdng_decoder_native.so` for x86-64 Linux so Halcyon displays valid preview-less DNGs.

**Architecture:** Extend the existing Windows Vulkan backend guards to Linux, add one native CMake preset, and mirror the plugin's Windows bundled-library packaging. Halcyon's Linux runner already installs FFI bundled libraries under `<bundle>/lib`, so no hand-written Halcyon Linux runner code is needed.

**Tech Stack:** C++17, CMake/Ninja, Halide 21 Vulkan AOT, Linux Vulkan loader, Flutter Linux, Dart FFI.

---

All native builds and runtime tests in this plan run on an x86-64 Linux machine with Vulkan 1.1+, `libvulkan-dev`, `zlib1g-dev`, NASM or yasm, GTK3 development files, CMake, and Ninja.

### Task 1: Add Linux Vulkan backend selection

**Files:**
- Modify: `../flutter_dng_decoder/dng_processor/native/src/dng_halide_device.cpp:9-48`
- Test: `../flutter_dng_decoder/dng_processor/native/tests/test_decode.cpp`

- [ ] **Step 1: Capture the current red backend result**

On Linux, configure the current source with a temporary ordinary build and run the decoder:

```bash
cd ../flutter_dng_decoder/dng_processor/native
cmake -S . -B build-linux-red -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build-linux-red --target test_decode
./build-linux-red/test_decode ../../image_samples/lossless_dng_sample.dng; echo RC=$?
```

Expected: nonzero or `gpu unavailable` because `__linux__` resolves to `GpuBackend::kUnsupported`.

- [ ] **Step 2: Extend all three Vulkan guards**

Use the same predicate at include, backend selection, and interface dispatch:

```cpp
#if defined(__APPLE__)
#include "HalideRuntimeMetal.h"
#elif defined(__ANDROID__) || defined(_WIN32) || defined(__linux__)
#include "HalideRuntimeVulkan.h"
#endif
```

```cpp
#if defined(__APPLE__)
    return GpuBackend::kMetal;
#elif defined(__ANDROID__) || defined(_WIN32) || defined(__linux__)
    return GpuBackend::kVulkan;
#else
    return GpuBackend::kUnsupported;
#endif
```

```cpp
#if defined(__ANDROID__) || defined(_WIN32) || defined(__linux__)
    case GpuBackend::kVulkan:
        return halide_vulkan_device_interface();
#endif
```

- [ ] **Step 3: Commit backend selection**

```bash
cd ../flutter_dng_decoder
git add dng_processor/native/src/dng_halide_device.cpp
git commit -m "feat(native): select Vulkan backend on Linux"
```

### Task 2: Add Linux AOT target, Vulkan linking, and preset

**Files:**
- Modify: `../flutter_dng_decoder/dng_processor/native/CMakeLists.txt:480-495,739-779`
- Modify: `../flutter_dng_decoder/dng_processor/native/CMakePresets.json`

- [ ] **Step 1: Verify the intended preset is absent**

```bash
cd ../flutter_dng_decoder/dng_processor/native
cmake --preset linux-vulkan; echo RC=$?
```

Expected: nonzero because `linux-vulkan` is not defined.

- [ ] **Step 2: Make the Linux artifact self-contained for JPEG decode**

After rebasing on the iOS CMake change, extend its vendored JPEG condition:

```cmake
if(ANDROID OR WIN32 OR DNG_IOS OR (UNIX AND NOT APPLE))
    if(NOT DNG_IOS AND NOT (UNIX AND NOT APPLE))
        find_package(JPEG QUIET)
    endif()
    if(DNG_IOS OR (UNIX AND NOT APPLE) OR NOT JPEG_FOUND)
```

Keep the existing NASM/yasm branch for Linux x86 SIMD. This statically links vendored libjpeg-turbo into the decoder and avoids a distro-specific `libjpeg.so` runtime requirement.

- [ ] **Step 3: Add the strict Linux Vulkan AOT target**

Insert before the generic host fallback:

```cmake
elseif(UNIX AND NOT APPLE)
    set(AOT_TARGET "x86-64-linux-vulkan-vk_int8-vk_int16-vk_int64-no_asserts-no_bounds_query")
else()
    set(AOT_TARGET "host-no_asserts-no_bounds_query")
endif()
```

- [ ] **Step 4: Link the Linux Vulkan loader**

Insert after the Windows branch:

```cmake
elseif(UNIX AND NOT APPLE)
    find_library(VULKAN_LIBRARY NAMES vulkan)
    if(NOT VULKAN_LIBRARY)
        message(FATAL_ERROR
            "Vulkan loader not found. Install libvulkan-dev; the DNG pipeline has no CPU fallback.")
    endif()
    message(STATUS "Linking Vulkan loader: ${VULKAN_LIBRARY}")
    target_link_libraries(dng_decoder_native ${VULKAN_LIBRARY})
endif()
```

- [ ] **Step 5: Add configure and build presets**

Add to `configurePresets`:

```json
{
  "name": "linux-vulkan",
  "displayName": "Linux Vulkan (native)",
  "generator": "Ninja",
  "binaryDir": "${sourceDir}/build-linux",
  "cacheVariables": {
    "CMAKE_BUILD_TYPE": "Release",
    "DNG_DIAGNOSTIC_BUILD": "OFF",
    "DNG_VK_PIPELINE_CACHE": "OFF"
  }
}
```

Add to `buildPresets`:

```json
{
  "name": "linux-vulkan",
  "configurePreset": "linux-vulkan"
}
```

- [ ] **Step 6: Configure and commit**

```bash
bash scripts/fetch_halide_v21_dist.sh
cmake --preset linux-vulkan; echo RC=$?
```

Expected: `RC=0` and output names the strict x86-64 Linux Vulkan target.

```bash
cd ../flutter_dng_decoder
git add dng_processor/native/CMakeLists.txt \
  dng_processor/native/CMakePresets.json
git commit -m "feat(native): add Linux Vulkan decoder build"
```

### Task 3: Build and verify the Linux native decoder

**Files:**
- Generated: `../flutter_dng_decoder/dng_processor/native/build-linux/libdng_decoder_native.so`

- [ ] **Step 1: Build the decoder and native harnesses**

```bash
cd ../flutter_dng_decoder/dng_processor/native
cmake --build --preset linux-vulkan --target \
  dng_decoder_native dng_ffi_harness test_decode test_cfa_color; echo RC=$?
```

Expected: `RC=0`.

- [ ] **Step 2: Run real-file native smoke tests**

```bash
./build-linux/test_decode ../../image_samples/lossless_dng_sample.dng; echo DECODE_RC=$?
./build-linux/dng_ffi_harness ../../image_samples/lossless_dng_sample.dng; echo FFI_RC=$?
```

Expected: both RCs zero; decoded dimensions are `4080x3056`.

- [ ] **Step 3: Verify architecture, dynamic dependencies, and C ABI**

```bash
readelf -h build-linux/libdng_decoder_native.so | grep 'Machine:'
nm -D --defined-only build-linux/libdng_decoder_native.so | grep ' T dng_'
readelf -d build-linux/libdng_decoder_native.so | grep -E 'NEEDED|RPATH|RUNPATH'
ldd build-linux/libdng_decoder_native.so
```

Expected: x86-64, DNG C symbols present, Vulkan/zlib dependencies resolvable, no `libjpeg.so` or Halide shared dependency, and no developer-machine absolute RPATH.

### Task 4: Add Linux packaging to `dng_processor_ffi`

**Files:**
- Modify: `../flutter_dng_decoder/dng_processor_ffi/pubspec.yaml`
- Modify: `../flutter_dng_decoder/dng_processor_ffi/.gitignore`
- Modify: `../flutter_dng_decoder/dng_processor_ffi/lib/src/dng_bindings.dart:385-386`
- Create: `../flutter_dng_decoder/dng_processor_ffi/linux/CMakeLists.txt`
- Create: `../flutter_dng_decoder/dng_processor_ffi/linux/Libraries/libdng_decoder_native.so`

- [ ] **Step 1: Declare Linux and add the packaging CMake file**

Add to `pubspec.yaml`:

```yaml
      linux:
        ffiPlugin: true
```

Create `linux/CMakeLists.txt`:

```cmake
cmake_minimum_required(VERSION 3.14)
project(dng_processor_ffi_library LANGUAGES CXX)

set(dng_processor_ffi_bundled_libraries
  "${CMAKE_CURRENT_SOURCE_DIR}/Libraries/libdng_decoder_native.so"
  PARENT_SCOPE
)
```

The variable name and `PARENT_SCOPE` are the Flutter tooling contract; changing either silently omits the library.

- [ ] **Step 2: Copy and unignore the verified binary**

```bash
cd ../flutter_dng_decoder/dng_processor_ffi
mkdir -p linux/Libraries
cp ../dng_processor/native/build-linux/libdng_decoder_native.so \
  linux/Libraries/
printf '\n!linux/Libraries/*.so\n' >> .gitignore
```

- [ ] **Step 3: Replace the one-name Linux loader with existing `_openFirst` behavior**

Replace the Linux branch in `DngNativeBindings.load()` with:

```dart
} else if (Platform.isLinux) {
  final execDir = File(Platform.resolvedExecutable).parent.path;
  final scriptPath = Platform.script.toFilePath(windows: false);
  final scriptParent = File(scriptPath).parent.path;
  final nativeBuildDir = Platform.environment['DNG_NATIVE_BUILD_DIR'];
  lib = _openFirst([
    'libdng_decoder_native.so',
    '$execDir/lib/libdng_decoder_native.so',
    if (nativeBuildDir != null)
      '$nativeBuildDir/libdng_decoder_native.so',
    '$scriptParent/../native/build-linux/libdng_decoder_native.so',
  ]);
```

- [ ] **Step 4: Commit plugin packaging and binary**

```bash
cd ../flutter_dng_decoder
git add dng_processor_ffi/pubspec.yaml \
  dng_processor_ffi/.gitignore \
  dng_processor_ffi/lib/src/dng_bindings.dart \
  dng_processor_ffi/linux/CMakeLists.txt \
  dng_processor_ffi/linux/Libraries/libdng_decoder_native.so
git commit -m "feat(ffi): package DNG decoder for Linux"
```

### Task 5: Add a Linux plugin smoke test

**Files:**
- Create: `../flutter_dng_decoder/dng_processor_ffi/test/dng_linux_smoke_test.dart`

- [ ] **Step 1: Write the test before copying the `.so` on the implementation branch**

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dng_processor_ffi/src/dng_bindings.dart';
import 'package:dng_processor_ffi/src/dng_decoder_service.dart';

void main() {
  test(
    'Linux packaged library exports the ABI and decodes the real sample',
    () async {
      final library = File(
        'linux/Libraries/libdng_decoder_native.so',
      ).absolute;
      final sample = File(
        '../image_samples/lossless_dng_sample.dng',
      ).absolute;
      expect(library.existsSync(), isTrue, reason: library.path);
      expect(sample.existsSync(), isTrue, reason: sample.path);

      final bindings = DngNativeBindings.fromPath(library.path);
      expect(bindings.sizedDecodeAvailable, isTrue);

      final decoded = await DngDecoderService(
        libraryPath: library.path,
      ).decodeOnWorker(sample.path);
      expect(decoded.width, 4080);
      expect(decoded.height, 3056);
      expect(decoded.rgbaData.length, 4080 * 3056 * 4);
    },
    skip: !Platform.isLinux,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
```

- [ ] **Step 2: Run red then green on Linux**

Before the binary copy, expect file-existence failure. After Task 4:

```bash
cd ../flutter_dng_decoder/dng_processor_ffi
flutter test test/dng_linux_smoke_test.dart \
  test/dng_bindings_openfirst_test.dart; echo RC=$?
```

Expected: `RC=0`, no skipped Linux smoke.

- [ ] **Step 3: Commit the test**

```bash
cd ../flutter_dng_decoder
git add dng_processor_ffi/test/dng_linux_smoke_test.dart
git commit -m "test(ffi): cover packaged Linux DNG decode"
```

### Task 6: Verify the Halcyon Linux release bundle

**Files:**
- Generated: `linux/flutter/generated_plugins.cmake`
- Generated: `build/linux/x64/release/bundle/lib/libdng_decoder_native.so`
- Create: `docs/logs/2026-08-24/m6-linux-dng-smoke.md`
- Modify: `../flutter_dng_decoder/dng_processor_ffi/README.md`

- [ ] **Step 1: Regenerate plugin metadata and build release**

```bash
cd ../Halcyon
flutter pub get
flutter build linux --release; echo RC=$?
```

Expected: `RC=0`; generated plugin CMake lists `dng_processor_ffi` under `FLUTTER_FFI_PLUGIN_LIST`.

- [ ] **Step 2: Verify bundle contents**

```bash
test -f build/linux/x64/release/bundle/lib/libdng_decoder_native.so; echo LIB_RC=$?
ldd build/linux/x64/release/bundle/lib/libdng_decoder_native.so
```

Expected: `LIB_RC=0` and all runtime libraries resolve.

- [ ] **Step 3: Run the app against the canonical preview-less DNG**

```bash
./build/linux/x64/release/bundle/photo_selector_flutter
```

Open `local_data/photo_samples/DNG/2024-07-03-18-52-26.dng`. Expected: visible image with orientation 1; no `RAW_UNSUPPORTED`, no blank/permanent miss.

- [ ] **Step 4: Record and commit evidence**

Record distro, kernel, GPU, Vulkan driver, Halcyon/decoder commits, sample SHA-256, displayed dimensions, and all RCs in `docs/logs/2026-08-24/m6-linux-dng-smoke.md`.

```bash
cd ../flutter_dng_decoder
git add dng_processor_ffi/README.md
git commit -m "docs(ffi): document Linux decoder requirements"

cd ../Halcyon
git add docs/logs/2026-08-24/m6-linux-dng-smoke.md
git commit -m "test(m6): record Linux preview-less DNG smoke"
```
