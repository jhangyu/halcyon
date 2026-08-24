# M6 DNG iOS FFI Decoder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package the existing DNG decoder as an arm64 iOS static library so Halcyon displays valid preview-less DNGs through the existing Dart FFI service.

**Architecture:** Reuse the decoder's existing two-stage cross-build and `DynamicLibrary.process()` iOS branch. CMake emits a static archive; a packaging-only CocoaPod force-loads it into the Runner binary; Dart and Halcyon service code remain platform-neutral.

**Tech Stack:** C++17, CMake/Ninja, Halide 21 Metal AOT, libjpeg-turbo, CocoaPods, Flutter iOS, Dart FFI.

---

Work in sibling repository `../flutter_dng_decoder` until the Halcyon build gate. First release target is physical-device arm64; simulator support is not required for this plan.

### Task 1: Teach native CMake to emit an iOS static archive

**Files:**
- Modify: `../flutter_dng_decoder/dng_processor/native/CMakeLists.txt:127-206,346,480-495,739-751`

- [ ] **Step 1: Capture the current red configure**

```bash
cd ../flutter_dng_decoder/dng_processor/native
cmake -S . -B build-ios/device -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DCMAKE_BUILD_TYPE=Release \
  -DDNG_CROSS_BUILD=ON \
  -DDNG_PREBUILT_AOT_DIR="$PWD/build-ios/missing"; echo RC=$?
```

Expected: nonzero because no prebuilt AOT directory exists. Preserve the output in `build-ios/configure-red.txt`.

- [ ] **Step 2: Add an explicit iOS predicate and static target**

Near the platform setup add:

```cmake
set(DNG_IOS OFF)
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    set(DNG_IOS ON)
endif()
```

Change the vendored JPEG condition and prevent CMake from accepting a host-macOS JPEG archive during the cross-build:

```cmake
if(ANDROID OR WIN32 OR DNG_IOS)
    if(NOT DNG_IOS)
        find_package(JPEG QUIET)
    endif()
    if(DNG_IOS OR NOT JPEG_FOUND)
        set(ENABLE_SHARED OFF CACHE BOOL "" FORCE)
        set(ENABLE_STATIC ON CACHE BOOL "" FORCE)
        set(WITH_TURBOJPEG OFF CACHE BOOL "" FORCE)
        if(ANDROID OR DNG_IOS)
            set(WITH_SIMD ON CACHE BOOL "" FORCE)
            set(DNG_JPEG_SIMD_NOTE "NEON SIMD")
        else()
```

Close the nested conditions at the same locations as the existing vendored branch. iOS must always compile the vendored source for arm64; it must never link Homebrew JPEG.

Replace the library declaration with:

```cmake
if(DNG_IOS)
    add_library(dng_decoder_native STATIC ${NATIVE_SOURCES})
else()
    add_library(dng_decoder_native SHARED ${NATIVE_SOURCES})
endif()
```

Keep CoreFoundation, Metal, and Foundation on every Apple target. Link CoreServices only when the iOS SDK exposes it, and apply macOS RPATH only outside iOS:

```cmake
find_library(COREFOUNDATION_LIBRARY CoreFoundation REQUIRED)
find_library(CORESERVICES_LIBRARY CoreServices)
find_library(METAL_LIBRARY Metal REQUIRED)
find_library(FOUNDATION_LIBRARY Foundation REQUIRED)
target_link_libraries(dng_decoder_native
    ${COREFOUNDATION_LIBRARY}
    ${METAL_LIBRARY}
    ${FOUNDATION_LIBRARY}
)
if(CORESERVICES_LIBRARY)
    target_link_libraries(dng_decoder_native ${CORESERVICES_LIBRARY})
endif()
if(NOT DNG_IOS)
    set_target_properties(dng_decoder_native PROPERTIES
        FRAMEWORK FALSE
        MACOSX_RPATH TRUE
    )
endif()
```

- [ ] **Step 3: Run existing macOS configuration as a regression check**

```bash
cmake --preset macos-metal; echo RC=$?
```

Expected: `RC=0`; target remains a dylib on macOS.

- [ ] **Step 4: Commit the native build support**

```bash
git add dng_processor/native/CMakeLists.txt
git commit -m "feat(ffi): add iOS static decoder target"
```

### Task 2: Produce and validate the arm64 device archive

**Files:**
- Generated: `../flutter_dng_decoder/dng_processor/native/build-ios/host-generators/`
- Generated: `../flutter_dng_decoder/dng_processor/native/build-ios/device/libdng_decoder_native.a`

- [ ] **Step 1: Generate iOS Metal AOT objects on the host**

```bash
cd ../flutter_dng_decoder/dng_processor/native
cmake -S . -B build-ios/host-generators \
  -DCMAKE_BUILD_TYPE=Release \
  -DDNG_HOST_GENERATORS_ONLY=ON \
  -DDNG_AOT_TARGET_OVERRIDE="arm-64-ios-metal-no_asserts-no_bounds_query"
cmake --build build-ios/host-generators; echo RC=$?
```

Expected: `RC=0` and `build-ios/host-generators/halide_generated/` contains `.a` and `.h` outputs.

- [ ] **Step 2: Cross-compile the static decoder**

```bash
cmake -S . -B build-ios/device -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DCMAKE_BUILD_TYPE=Release \
  -DDNG_CROSS_BUILD=ON \
  -DDNG_PREBUILT_AOT_DIR="$PWD/build-ios/host-generators/halide_generated"
cmake --build build-ios/device --target dng_decoder_native; echo RC=$?
```

Expected: `RC=0` and `build-ios/device/libdng_decoder_native.a` exists.

- [ ] **Step 3: Verify architecture and ABI exports**

```bash
lipo -info build-ios/device/libdng_decoder_native.a
nm -gU build-ios/device/libdng_decoder_native.a | \
  grep -E 'dng_decode_and_process$|dng_decode_and_process_sized$|dng_extract_preview_jpeg$|dng_free_result$'
```

Expected: `arm64` and all four symbols. Run `strip -x build-ios/device/libdng_decoder_native.a` only after symbol verification.

### Task 3: Add iOS packaging to `dng_processor_ffi`

**Files:**
- Modify: `../flutter_dng_decoder/dng_processor_ffi/pubspec.yaml`
- Modify: `../flutter_dng_decoder/dng_processor_ffi/.gitignore`
- Create: `../flutter_dng_decoder/dng_processor_ffi/ios/dng_processor_ffi.podspec`
- Create: `../flutter_dng_decoder/dng_processor_ffi/ios/Classes/dng_processor_ffi.c`
- Create: `../flutter_dng_decoder/dng_processor_ffi/ios/Libraries/libdng_decoder_native.a`

- [ ] **Step 1: Declare iOS first and verify the expected red build**

Add under `flutter.plugin.platforms`:

```yaml
      ios:
        ffiPlugin: true
```

Run:

```bash
cd ../flutter_dng_decoder/dng_processor
flutter pub get
flutter build ios --debug --no-codesign; echo RC=$?
```

Expected: nonzero because the iOS podspec/library is not present yet.

- [ ] **Step 2: Add the packaging podspec**

Create `dng_processor_ffi/ios/dng_processor_ffi.podspec`:

```ruby
Pod::Spec.new do |s|
  s.name             = 'dng_processor_ffi'
  s.version          = '0.0.1'
  s.summary          = 'Prebuilt dng_decoder_native library for host apps.'
  s.description      = 'Statically links the DNG decoder into iOS host apps.'
  s.homepage         = 'https://github.com/jhangyu/flutter_dng_decoder'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'flutter_dng_decoder' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.vendored_libraries = 'Libraries/libdng_decoder_native.a'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'OTHER_LDFLAGS' => '$(inherited) -force_load "${PODS_TARGET_SRCROOT}/Libraries/libdng_decoder_native.a"'
  }
end
```

Flutter's official FFI guidance requires C symbols to be `extern "C"`, default-visible, and marked used. The existing `FFI_EXPORT` already provides C/default visibility; the force-load gate below proves archive inclusion.

- [ ] **Step 3: Add the required pod source and tracked binary**

Create `ios/Classes/dng_processor_ffi.c`:

```c
#include <stdint.h>

__attribute__((visibility("default"))) __attribute__((used))
int32_t dng_processor_ffi_ios_packaging_tag(void) {
  return 1;
}
```

Copy and unignore the archive:

```bash
cd ../flutter_dng_decoder/dng_processor_ffi
mkdir -p ios/Classes ios/Libraries
cp ../dng_processor/native/build-ios/device/libdng_decoder_native.a \
  ios/Libraries/libdng_decoder_native.a
printf '\n!ios/Libraries/*.a\n' >> .gitignore
```

- [ ] **Step 4: Build the decoder example app and prove force-load**

```bash
cd ../flutter_dng_decoder/dng_processor
flutter clean
flutter pub get
flutter build ios --debug --no-codesign; echo RC=$?
nm build/ios/iphoneos/Runner.app/Runner | \
  grep 'dng_decode_and_process'; echo NM_RC=$?
```

Expected: build and `NM_RC` are zero. If build passes but `NM_RC=1`, the archive was dead-stripped; fix the podspec force-load path rather than changing Dart.

- [ ] **Step 5: Commit plugin packaging and binary**

```bash
cd ../flutter_dng_decoder
git add dng_processor_ffi/pubspec.yaml \
  dng_processor_ffi/.gitignore \
  dng_processor_ffi/ios/dng_processor_ffi.podspec \
  dng_processor_ffi/ios/Classes/dng_processor_ffi.c \
  dng_processor_ffi/ios/Libraries/libdng_decoder_native.a
git commit -m "feat(ffi): package DNG decoder for iOS arm64"
```

### Task 4: Verify Halcyon iOS packaging

**Files:**
- Verify: `ios/Podfile`
- Verify: `ios/Runner.xcodeproj/project.pbxproj`
- Generated: `ios/Podfile.lock`, `ios/Pods/`, `build/ios/`

- [ ] **Step 1: Build without signing**

```bash
cd ../Halcyon
flutter clean
flutter pub get
flutter build ios --debug --no-codesign; echo RC=$?
```

Expected: `RC=0`.

- [ ] **Step 2: Verify the final Runner contains the FFI entry points**

```bash
nm build/ios/iphoneos/Runner.app/Runner | \
  grep -E 'dng_decode_and_process$|dng_extract_preview_jpeg$|dng_free_result$'
otool -L build/ios/iphoneos/Runner.app/Runner | \
  grep libdng_decoder_native; echo DYNAMIC_DNG_RC=$?
```

Expected: all symbols are found; `DYNAMIC_DNG_RC=1` because the decoder is statically linked, not an app-bundle dylib.

- [ ] **Step 3: Do not commit generated CocoaPods/build output**

```bash
git status --short ios build
```

Expected: only normal generated files. Restore none with full-tree commands; stage no generated output.

### Task 5: Physical-device smoke and release record

**Files:**
- Create: `docs/logs/2026-08-24/m6-ios-dng-smoke.md`
- Modify: `../flutter_dng_decoder/THIRD_PARTY_LICENSES.md`
- Modify: `../flutter_dng_decoder/dng_processor_ffi/README.md`

- [ ] **Step 1: Update package documentation and licenses**

Document iOS arm64 support, static linking, iOS 13 minimum, and the Adobe DNG SDK/libjpeg-turbo/Halide components included in the archive.

- [ ] **Step 2: Run on a physical device**

```bash
flutter devices
read -r -p "Physical iOS device id: " IOS_DEVICE_ID
flutter run -d "$IOS_DEVICE_ID"
```

Open `local_data/photo_samples/DNG/2024-07-03-18-52-26.dng` after copying it into an app-readable location through the app's supported file ingestion. Expected: visible image, orientation 1, no `NO_EMBEDDED_PREVIEW`, no blank/permanent miss.

- [ ] **Step 3: Record exact evidence**

Write `docs/logs/2026-08-24/m6-ios-dng-smoke.md` with device model, iOS version, Halcyon commit, decoder commit, sample SHA-256, displayed dimensions, and captured run/build RCs. Do not write `PASS` unless the physical-device image was visible.

- [ ] **Step 4: Commit docs in their owning repositories**

```bash
cd ../flutter_dng_decoder
git add THIRD_PARTY_LICENSES.md dng_processor_ffi/README.md
git commit -m "docs(ffi): document iOS decoder packaging"

cd ../Halcyon
git add docs/logs/2026-08-24/m6-ios-dng-smoke.md
git commit -m "test(m6): record iOS preview-less DNG smoke"
```
