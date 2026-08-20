# Windows FFI 升級調查（T2 / R1）— dng_processor_ffi + 上游 native

> **建立時間**：2026-08-21（Asia/Taipei）
> **契約**：`docs/logs/2026-08-21/windows-raw-r1r2-contract.md` §2 AC6/AC7；本檔為 T2 唯一交付物。
> **調查範圍**：`/Users/jhangyu/project/Halcyon`（HEAD `ea81871`）＋ sibling repo `/Users/jhangyu/project/flutter_dng_decoder`（上游 `d2035a8`）。全程唯讀，未執行任何 build。
> **標記約定**：`[U]` = 未在樹上或官方文件驗證；其餘結論皆附 `file:line` 或來源 URL。**本檔沒有任何一項在 Windows 上編譯或執行過。**

---

## 0. 60 秒速讀

- **總規模**：14 個工作項（W1–W14），其中 **9 項可在 macOS 上完成**（CMake/C++/Dart/packaging 撰寫），**5 項必須在 Windows 機器上**（configure/compile/link/run/驗收）。
- **最大單一阻斷**：不是 CMake preset，是 **GPU backend 缺口**。`src/dng_halide_device.cpp:21-27` 只認 `__APPLE__`/`__ANDROID__`，Windows 落到 `kUnsupported`；`src/dng_pipeline_v2.cpp:102-110` 的 `requireGpuBackend` 會在 Stage3（`:1007`）、warmup（`:1329`）、decode（`:1503`）三處硬性拒絕，錯誤訊息明寫「No SDK-CPU fallback route available」。**沒有可用的 CPU 退路。**
- **建議 backend**：**Vulkan**（`x86-64-windows-vulkan-vk_int8-vk_int16-vk_int64-...`）。理由與 trade-off 見 §2。
- **第二大阻斷**：production source 直接 include `<sys/mman.h>`/`<unistd.h>` 並呼叫 `mmap`（`dng_pipeline_v2.cpp:59-60,203-209`、`dng_render_halide.cpp:120,1697-1718`），MSVC 無此 header。
- **先問使用者的事**：R1 已經（或即將）落地純 Dart DNG 內嵌 JPEG 預覽。**Windows 到底需不需要「全尺寸 RAW 解碼」？** 若不需要，本檔 14 項全部歸零（見 §6 Q1）。這是唯一能把 scope 從「數週跨平台原生工程」壓到 0 的問題。

---

## 1. 現況機械盤點（每條可覆驗）

| 事實 | 證據 |
|---|---|
| `dng_processor_ffi` 只宣告 macos + android | `dng_processor_ffi/pubspec.yaml:22-28` |
| 它是**打包用 plugin**，不在 host build 內編譯原生碼；binary 是 commit 進去的 prebuilt | `dng_processor_ffi/README.md:3,14-17,23-25`；`macos/dng_processor_ffi.podspec:1-5,26`（`vendored_libraries`）；`android/build.gradle:1-2,25-29`（`jniLibs`） |
| Windows 分支已存在於 Dart 端，開的是**裸檔名** | `dng_processor_ffi/lib/src/dng_bindings.dart:338-339`（`DynamicLibrary.open('dng_decoder_native.dll')`）。**注意**：handover §9 引用的 `:343` 已過時，以 `:338-339` 為準 |
| CMake 無任何 WIN32 分支（link 區塊只有 APPLE/ANDROID） | `dng_processor/native/CMakeLists.txt:518-541` |
| CMakePresets 只有 3 個 preset，全是 macos-metal / android | `dng_processor/native/CMakePresets.json:8-49` |
| 非 Apple/Android 的 AOT target 落到 CPU host | `CMakeLists.txt:338-340`（`host-no_asserts-no_bounds_query`） |
| AOT artifact 路徑硬編 `.a` 副檔名（約 30 處） | `CMakeLists.txt:366-467`, `:504-517`, `:748-750`, `:810-812`, `:843`, `:864`, `:880` |
| 向量化的 Halide 是 **arm-64-osx** 二進位發行版 | `native/third_party/halide/VERSION`；`native/scripts/fetch_halide_v21_dist.sh:19`（ASSET 硬編 `Halide-21.0.0-arm-64-osx-...tar.gz`） |
| Halcyon 的 Windows runner **從不** `add_subdirectory(native)`；FFI plugin 清單目前是空的 | `windows/flutter/generated_plugins.cmake:9-10,21-24` |
| Halcyon Windows runner 的 `/W4 /WX` 只作用在 runner target，不會套到 plugin 的 DLL | `windows/CMakeLists.txt:42`（`target_compile_options(${TARGET} ...)`，`${TARGET}` 是 runner） |
| Adobe DNG SDK **有** Windows 分支且已被 `qWinOS=1` 打開 | `CMakeLists.txt:28-29`；SDK 內 `dng_pthread.cpp:26,54,1105`、`dng_date_time.cpp:31`、`dng_string.cpp:29`、`dng_utils.cpp:39` 皆 `#include <windows.h>` |
| Generator **已有** CPU schedule 分支（不是只會 GPU） | `src/DngDemosaicGenerator.cpp:39`、`src/DngRenderGenerator.cpp:426,840,931`、`src/DngDemosaicWarpGenerator.cpp:86`（皆 `if (get_target().has_gpu_feature())` … else CPU） |
| FFI export macro **已有** `_WIN32` 分支 | `src/dng_ffi_api.cpp:14-18`（`__declspec(dllexport)`）——這一項無需改動 |
| `DNG_VK_PIPELINE_CACHE` 的 Halide runtime fork 是 Android 專屬，且用 `CMAKE_OBJCOPY --weaken` + `-ffreestanding` | `CMakeLists.txt:545`（`if(ANDROID AND DNG_CROSS_BUILD)`）、`:673-708`。Windows 走不到，但也**拿不到它的冷啟動加速**（見 §5 R1） |
| `dng_extract_preview_jpeg` 只依賴 dng_sdk，不碰 Halide/GPU | `src/dng_ffi_api.cpp:159-200` |

---

## 2. Halide backend 建議與 trade-off

### 結論：**Vulkan**（首選）；CPU host **不建議**；D3D12 **不建議**

| Backend | AOT target 字串 | 優點 | 缺點 / 風險 | 判定 |
|---|---|---|---|---|
| **Vulkan** | `x86-64-windows-vulkan-vk_int8-vk_int16-vk_int64-no_asserts-no_bounds_query` | ①Halide 官方文件把 **Windows 列為 Vulkan backend 的「全部 correctness test 通過」平台**（[Halide doc/Vulkan.md](https://github.com/halide/Halide/blob/main/doc/Vulkan.md)、[halide-lang.org Vulkan docs](https://halide-lang.org/docs/md_doc_2_vulkan.html)）②codebase **已經有一條 Vulkan 路徑**（`dng_halide_device.cpp:6-8,23-24,43-46`），Windows 只需把 `__ANDROID__` guard 放寬為 `defined(__ANDROID__) \|\| defined(_WIN32)` ③Android 一路踩出來的 Vulkan kernel workaround 可直接複用 ④GPU 併發量能夠撐住 §5 R1 的 1s ceiling | ①需要 Vulkan SDK（build 期）與 Vulkan 1.1+ driver（執行期）②Android 專屬的 Stage4 三通道拆分 kernel 目前**只在 `os == Android` 時生成**（`CMakeLists.txt:408`、`src/DngRenderGenerator.cpp:40,53,408`），Windows-Vulkan 會落到 Tuple 版 Stage4——正是當初為了繞開 Halide v21 SPIR-V R==G bug 才拆的（`CMakeLists.txt:406-407`）→ **W7 必做** ③首次 shader 編譯成本無 VkPipelineCache fork 可用 | **採用** |
| **CPU host** | `x86-64-windows-no_asserts-no_bounds_query`（已是 `CMakeLists.txt:339` 的預設 else 分支） | ①CMake 幾乎不用改 target 字串 ②generator 已有 CPU schedule（見 §1）③無 driver/SDK 依賴 | ①**pipeline 會直接拒絕執行**：`requireGpuBackend`（`dng_pipeline_v2.cpp:102-110`）在 `dng_halide_gpu_available()` 為 false 時回 false，並在 `:1007`/`:1329`/`:1503` 中止，訊息自陳「No SDK-CPU fallback route available」。要做 CPU 路徑＝**新寫一條 host-buffer 路徑**，不是改 config：`dng_opcodelist2_halide.cpp` 有 41 處、`dng_render_halide.cpp` 13 處 device buffer 呼叫（`grep -c "device_dirty\|copy_to_device\|copy_to_host\|device_malloc\|device_free"`）②效能：24MP 全尺寸 demosaic+warp+render 走 CPU，對照 macOS Metal 的 ~110ms（memory: image-switch-latency-round2/3），**極可能突破使用者的 1s 硬上限**（memory: one-second-operation-ceiling）[U — 未實測] | **不採用**（可作為 W5 失敗後的降級議題，但需重新立契約） |
| **D3D12Compute** | `x86-64-windows-d3d12compute-...` | ①Windows 原生、無需額外 SDK（Windows SDK 內建）②理論上驅動覆蓋率最廣 | ①Halide 該 backend 成熟度最低：HLSL 三角函數精度無明確文件、buildbot 曾在舊 GPU 上 crash、SM5.1 32KB shared memory 上限（[Halide PR #2755](https://github.com/halide/Halide/pull/2755)、[Issue #5552](https://github.com/halide/Halide/issues/5552)）②codebase **完全沒有** D3D12 路徑，`HalideRuntimeD3D12Compute.h` 雖在發行版內（`third_party/halide/include/`）但要新寫 device 分支 ③本專案的色彩正確性合約建立在 `-ffp-contract=off` 的 byte-exact 對照上（`CMakeLists.txt:206-218`），HLSL 精度不確定性直接威脅 `test_cfa_color` 這類 gate | **不採用** |

**副結論（重要，影響 scope）**：`dng_extract_preview_jpeg`（`src/dng_ffi_api.cpp:159-200`）**完全不碰 Halide 與 GPU**，只用 dng_sdk。若目標僅是「Windows 顯示 DNG 預覽」，一顆只含 dng_sdk + zlib + libjpeg 的 Windows DLL 就夠——但 **R1 的純 Dart 抽取已經覆蓋同一需求**，所以這條路徑價值為零。全尺寸解碼才是本檔存在的理由。

---

## 3. 依賴排序工作項（W1–W14）

標記：**[M]** = 可在這台 macOS 上完成並驗證；**[M-auth]** = 可在 macOS 上撰寫，但驗證需 Windows；**[W]** = 必須 Windows 機器。

### 階段 0 — 決策閘

| # | 工作項 | 入口 | 前置 | 機械完成判準 | 機器 |
|---|---|---|---|---|---|
| **W0** | 使用者裁決：Windows 是否需要全尺寸 RAW 解碼（見 §6 Q1/Q2） | — | R1 T1 落地 | 契約文件出現一行裁決記錄 | **[M]** |

### 階段 1 — 建置材料（可平行）

| # | 工作項 | 入口 | 前置 | 機械完成判準 | 機器 |
|---|---|---|---|---|---|
| **W1** | Halide v21 Windows 發行版取得腳本 | `native/scripts/fetch_halide_v21_dist.sh:19-20`（ASSET/URL 硬編 arm-64-osx） | W0 | 腳本依 OS/arch 選 `Halide-21.0.0-x86-64-windows-b629c80de18f1534ec71fddd8b567aa7027a0876.zip`（**該 asset 確認存在於 v21.0.0 release**，[GitHub releases API](https://api.github.com/repos/halide/Halide/releases/tags/v21.0.0)）；Windows 上執行後 `third_party/halide/lib/Halide.lib` 與 `find_package(Halide)` configure 成功 | **[M-auth]** |
| **W2a** | zlib：Windows 無系統 zlib，`find_package(ZLIB REQUIRED)` 會 fail | `CMakeLists.txt:54-56`（`third_party/` 內**無** vendored zlib，僅 dng_sdk / halide / libjpeg-turbo） | W0 | 選定並落地一種取得方式（vcpkg manifest / vendored subdirectory / FetchContent）；Windows configure 不再 FATAL_ERROR，`ZLIB::ZLIB` target 存在 | **[M-auth]** |
| **W2b** | libjpeg：非 Android/Apple 走 `find_package(JPEG REQUIRED)`，Windows 無系統 libjpeg | `CMakeLists.txt:139-142`；可複用的 vendored build 模板在 `:70-88`（`third_party/libjpeg-turbo/` 已存在） | W0 | 把 `if(ANDROID)` 的 vendored 分支條件擴為 `if(ANDROID OR WIN32)`；configure 輸出出現 "Building vendored libjpeg-turbo"，且 `DNG_USE_LIBJPEG=ON`。SIMD 需 NASM，否則 `WITH_SIMD=OFF` | **[M-auth]** |
| **W3** | Toolchain 判定：**建議 clang-cl**（見下方說明） | `CMakeLists.txt:218`（`-ffp-contract=off`，GNU 風格 flag） | W0 | preset 內顯式指定 compiler；Windows configure 不出現 "unknown option '-ffp-contract'"；`test_color_accuracy` 在 Windows 上通過 | **[M-auth]** |

**W3 說明（toolchain 取捨）**
- `-ffp-contract=off`（`CMakeLists.txt:218`）**是載重的**，不是風格選擇：`:206-217` 記載整個 Stage4 byte-exact 合約建立在它之上。MSVC 不接受此 flag；最接近的是 `/fp:strict`，但語義不等價 **[U]**。`clang-cl` 直接接受 `-ffp-contract=off`。
- ABI：FFI 邊界是純 C（`include/dng_ffi_api.h`），理論上 MinGW 也可行，但會拖進 `libstdc++`/`libwinpthread` DLL 依賴 → 需一併打包。**clang-cl + 靜態 CRT（`/MT`）** 讓產出的 DLL 對 host app 零額外 runtime 依賴，與 macOS 上「靜態連 libjpeg 以消除外部依賴」的既有政策一致（`CMakeLists.txt:60-69`）。
- Halcyon runner 的 `/W4 /WX`（`windows/CMakeLists.txt:42`）**不構成約束**：packaging 走 prebuilt（§1），native 樹不會被 `add_subdirectory` 進 Flutter build。

### 階段 2 — 上游 native 原始碼移植（前置：W1–W3）

| # | 工作項 | 入口 | 前置 | 機械完成判準 | 機器 |
|---|---|---|---|---|---|
| **W4** | 移除 POSIX-only 依賴 | `src/dng_pipeline_v2.cpp:59-60`（`<sys/mman.h>`/`<unistd.h>`）、`:203-209`（`mmap`/`munmap` process pool）；`src/dng_render_halide.cpp:120`、`:1697-1718`（MAP_ANON lazy-zero scratch，**已有 calloc fallback 於 `:1710`**） | W3 | `grep -n "sys/mman.h\|unistd.h" src/*.cpp` 的每一處都落在 `#if !defined(_WIN32)` 內；Windows 分支用 `VirtualAlloc(MEM_RESERVE\|MEM_COMMIT, PAGE_READWRITE)`/`VirtualFree`（lazy-commit 語義對應 MAP_ANON），或退回既有 calloc 路徑 | **[M-auth]** |
| **W5** | **GPU backend Windows 分支（核心阻斷）** | `src/dng_halide_device.cpp:4-8`（include guard）、`:21-27`（`resolve_backend`）、`:39-46`（`dng_halide_gpu_device_interface` 的 switch case guard） | W4 | 三處 `__ANDROID__` guard 擴為 `defined(__ANDROID__) \|\| defined(_WIN32)`；Windows 上 `dng_ffi_harness` 印出 `backend=vulkan` 且**不再**觸發 `dng_pipeline_v2.cpp:102-110` 的 capability gate 錯誤字串 | **[M-auth]** |
| **W6a** | AOT target 字串加 WIN32 分支 | `CMakeLists.txt:330-341`（`else()` 目前是 CPU host） | W5 | 新增 `elseif(WIN32)` → `x86-64-windows-vulkan-vk_int8-vk_int16-vk_int64-no_asserts-no_bounds_query`（在 Windows 機器上原生 build 亦可用 `host-vulkan-...`）；configure 期 `message(STATUS)` 印出的 AOT_TARGET 含 `vulkan` | **[M-auth]** |
| **W6b** | AOT artifact 副檔名參數化（`.a` → `.lib`） | `CMakeLists.txt` 約 30 處硬編 `.a`：`:366-404`, `:409-449`, `:454-467`, `:504-517`, `:567-576`, `:610-618`, `:646-654`, `:748-750`, `:810-812`, `:843`, `:864`, `:880` | W6a | **機械事實**：Halide 對 windows target 產出 `.lib`/`.obj`，非 `.a`/`.o` — 見 `third_party/halide/lib/cmake/HalideHelpers/HalideGeneratorHelpers.cmake:998-1013` 與 `:190,195` 註解。引入 `set(DNG_AOT_LIB_EXT ".a")` / WIN32 `".lib"` 並全面代入；`grep -c '\.a"' CMakeLists.txt` 在 AOT 區塊為 0；Windows build 產出 `halide_generated/halide_runtime.lib` | **[M-auth]** |
| **W7** | Stage4 kernel 變體選擇條件：Android → Vulkan | `CMakeLists.txt:406-426`（`if(ANDROID OR ... MATCHES "android")` 才生成三通道拆分 kernel）、`:512-517`（只有 ANDROID 才 link）；`src/DngRenderGenerator.cpp:40,53,408`（`get_target().os == Target::Android`） | W6b | 條件從「Android」泛化為「target 含 vulkan」；Windows 上 `test_cfa_color`（藍天 B >> R，`tests/test_cfa_color.cpp`）通過。**這是 §5 R2 的直接對策** | **[M-auth]** |
| **W8** | Windows link libraries 分支 | `CMakeLists.txt:518-541`（只有 APPLE/ANDROID） | W6a | 新增 `elseif(WIN32)`：link `$ENV{VULKAN_SDK}/Lib/vulkan-1.lib`；link 成功且 `dumpbin /dependents dng_decoder_native.dll` 列出 `vulkan-1.dll` | **[M-auth]** |
| **W9** | 新增 `windows-vulkan` CMake preset | `CMakePresets.json:8-49`（configure）、`:50-65`（build） | W1–W8 | `cmake --preset windows-vulkan && cmake --build --preset windows-vulkan --target dng_decoder_native` exit 0，且 `build-windows/dng_decoder_native.dll` 存在。單階段（generator 在 Windows 上原生跑），**不需**照 Android 那樣拆 stage1/stage2——理由見下 | **[M-auth]** |

**W9 說明（單階段 vs 兩階段）**：Android 之所以拆兩階段（`CMakePresets.json:19-48`），是因為 generator 是 host 執行檔而 target 是 arm64 交叉編譯。Windows 上 generator 可以原生跑在同一台機器，**單階段即可**。理論上也能在 macOS 上跑 stage1 交叉產生 windows AOT（`DNG_HOST_GENERATORS_ONLY` + `DNG_AOT_TARGET_OVERRIDE`，`CMakeLists.txt:160-172`），但產出的 `.lib` 仍需 Windows link 步驟，收益只有「AOT 步驟在 macOS 跑」——**[U]** macOS 主機的 Halide 是否能正確 emit COFF `.lib`（副檔名邏輯顯示會這樣命名，但未實跑驗證）。不建議走這條。

### 階段 3 — Plugin 打包（前置：W9 產出 DLL）

| # | 工作項 | 入口 | 前置 | 機械完成判準 | 機器 |
|---|---|---|---|---|---|
| **W10** | pubspec 宣告 Windows | `dng_processor_ffi/pubspec.yaml:22-28` | W9 | 加 `windows:\n        ffiPlugin: true`；`flutter build windows` 後 Halcyon 的 `windows/flutter/generated_plugins.cmake` 的 `FLUTTER_FFI_PLUGIN_LIST` 含 `dng_processor_ffi`（該檔為 generated，會自動重寫） | **[M-auth]** |
| **W11** | 新增 `dng_processor_ffi/windows/CMakeLists.txt`（prebuilt DLL 模式） | 新檔；對照物 `macos/dng_processor_ffi.podspec:26`、`android/build.gradle:25-29` | W10 | 檔案含 `cmake_minimum_required(VERSION 3.14)`、`project(dng_processor_ffi_library LANGUAGES CXX)`，並 `set(dng_processor_ffi_bundled_libraries "<絕對路徑>/Libraries/dng_decoder_native.dll" PARENT_SCOPE)`。**變數名必須精確等於 pubspec package 名 + `_bundled_libraries`，且必須 `PARENT_SCOPE`**——`generated_plugins.cmake:21-24` 用 `${${ffi_plugin}_bundled_libraries}` 解參照，漏了就是**靜默無 DLL**（[Flutter windows plugin template](https://github.com/flutter/flutter/blob/master/packages/flutter_tools/templates/plugin/windows.tmpl/CMakeLists.txt.tmpl)、[FFI plugins PR #96225](https://github.com/flutter/flutter/pull/96225)） | **[M]**（檔案可在 macOS 撰寫並用 grep 驗結構） |
| **W12** | commit prebuilt `dng_processor_ffi/windows/Libraries/dng_decoder_native.dll` | 新檔 | W9, W11 | 檔案存在且 `git add --dry-run` 顯示會進 commit（非 gitignore）。**名稱必須恰為 `dng_decoder_native.dll`**：CMake 對 Windows 的 `add_library(dng_decoder_native SHARED)`（`CMakeLists.txt:250`）預設無 `lib` 前綴 → 輸出即 `dng_decoder_native.dll`，與 `dng_bindings.dart:339` 的裸檔名**對齊，Dart 端零改動** | **[W]**（DLL 只能在 Windows 產出） |
| **W13** | 更新 `dng_processor_ffi/README.md` 平台表與 refresh 指令 | `README.md:14-17`（表）、`:19-25`（已知限制）、`:27-36`（refresh 指令） | W12 | 表新增 Windows 列；refresh 區塊新增 Windows `copy` 指令；已知限制新增「Windows 需 Vulkan 1.1+ driver」 | **[M]** |

### 階段 4 — 整合驗收

| # | 工作項 | 入口 | 前置 | 機械完成判準 | 機器 |
|---|---|---|---|---|---|
| **W14** | Halcyon 端端到端驗收 | `windows/CMakeLists.txt:64,71-72,84-88`（install 規則）；`lib/services/dng_decode_service.dart:34` | W12 | ①`flutter build windows --release` 後 `build/windows/x64/runner/Release/dng_decoder_native.dll` 與 `halcyon.exe` **同目錄**（`INSTALL_BUNDLE_LIB_DIR` = `CMAKE_INSTALL_PREFIX` = `$<TARGET_FILE_DIR:${BINARY_NAME}>`，`windows/CMakeLists.txt:64,71-72`）②app 啟動後對 `local_data/photo_samples/DNG/` 的樣本可全尺寸解碼，`DngResult.errorCode == 0` 且 `decodeMs + processMs < 1000`（memory: one-second-operation-ceiling） | **[W]** |

**W14 載入路徑對齊檢查（AC6-e）**：`dng_bindings.dart:338-339` 走裸檔名 `DynamicLibrary.open('dng_decoder_native.dll')`。Windows 標準搜尋順序中，**「應用程式載入所在的資料夾」排在系統資料夾之前（unpackaged app 第 7 順位，先於 system32 的第 8）**（[Microsoft Learn — Dynamic-link library search order](https://learn.microsoft.com/en-us/windows/win32/dlls/dynamic-link-library-search-order)）。DLL 被 install 到 exe 同目錄 → **裸檔名可解析，Dart 端不需要像 macOS `_openFirst`（`:195-217,325-337`）那樣的候選清單**。macOS 端的 `_imagePathViaDladdr` 已對 Windows 直接回 null（`:249`），無副作用。

---

## 4. macOS vs Windows 分界總表

| 可在 macOS 上完成 **[M] / [M-auth]**（9 項） | 必須 Windows 機器 **[W]**（5 項判準） |
|---|---|
| W0 決策、W1 腳本、W2a/W2b 依賴接線、W3 toolchain 選型、W4 mman 移植、W5 backend guard、W6a/W6b target+副檔名、W7 kernel 條件、W8 link 分支、W9 preset、W10 pubspec、W11 plugin CMake、W13 README | W1 的 configure 驗證、W2–W9 的 **compile/link** 驗證、W12 產出 DLL、W14 端到端執行與 <1s 效能驗收、W7 的 `test_cfa_color` 實跑 |

**CI 選項（可能性，非承諾）**：GitHub Actions `windows-latest` runner 可涵蓋 W1–W9 + W12 的 compile/link，需額外步驟：安裝 Vulkan SDK、下載 ~540MB Halide 發行版、安裝 NASM（若 libjpeg SIMD 開啟）。**無法涵蓋 W14 的 GPU 執行驗收**——GitHub 託管 runner 無實體 GPU，Vulkan 只能走 software（lavapipe/SwiftShader），效能數字無參考價值。**[U]** 未驗證 lavapipe 是否滿足 `vk_int8/vk_int16/vk_int64` 這組 Halide 要求。

---

## 5. 風險清單

| # | 風險 | 依據 | 緩解 |
|---|---|---|---|
| **R1** | **效能撞 1s 硬上限**。Android Vulkan 當初必須做 VkPipelineCache 跨啟動持久化（`CMakeLists.txt:663-708`、`halide_runtime_fork/`）才壓下首次 shader 編譯成本；該 fork 由 `if(ANDROID AND DNG_CROSS_BUILD)`（`:545`）圈住，**Windows 拿不到**。首次解碼可能 >1s（memory: one-second-operation-ceiling） | 上述 file:line ＋ memory: image-switch-latency-round2/3（macOS Metal RAW ~110ms） | W14 必須量測首次與後續解碼；若首次 >1s，考慮把 fork 的 guard 一併泛化（新增工作項，不在本清單） |
| **R2** | **Halide v21 SPIR-V Tuple R==G bug**。Windows-Vulkan 預設會用 Tuple 版 Stage4，正是被 Android 拆分繞開的那顆 | `CMakeLists.txt:406-407` 註解；`src/DngRenderGenerator.cpp:40,53,408` | W7 已列為必做項；驗收綁 `test_cfa_color` 的通道關係斷言 |
| **R3** | **`-ffp-contract=off` 在 MSVC 下無等價物**，色彩 byte-exact 合約可能在 Windows 上不成立 **[U]** | `CMakeLists.txt:206-218` | W3 選 clang-cl；若被迫用 MSVC，需重新定義 Windows 的色彩驗收門檻並經使用者批准 |
| **R4** | **dng_sdk 的 Windows 分支從未在本樹編譯過**。`windows.h` 會拖進 `min`/`max` 巨集，與 SDK 的 `Min_uint32`/STL 可能衝突，常見需要 `NOMINMAX` / `WIN32_LEAN_AND_MEAN` **[U]** | SDK 內 `dng_pthread.cpp:39`、`dng_date_time.cpp:31`、`dng_string.cpp:29`、`dng_utils.cpp:39` 皆 include `<windows.h>` | W3/W4 期間預留 `add_compile_definitions(NOMINMAX WIN32_LEAN_AND_MEAN)`；首次 compile 錯誤量可能很大，排程要留 buffer |
| **R5** | **執行期 driver 依賴**。使用者的 Windows 機器若無 Vulkan 1.1+ driver 或不支援 `vk_int8/int16/int64`，整條路徑在該機上不可用 | Halide Vulkan 文件的型別可選性說明（[doc/Vulkan.md](https://github.com/halide/Halide/blob/main/doc/Vulkan.md)：除 32-bit float/int 外所有型別皆為 optional） | §6 Q2 先問清目標機器 GPU；必要時放寬 target 的 vk_* 需求並重測色彩 |
| **R6** | **libjpeg-turbo SIMD 需 NASM**，Windows 建置環境多一項外部依賴 | `CMakeLists.txt:78`（`WITH_SIMD ON`）＋ `third_party/libjpeg-turbo/BUILDING.md` | 先以 `WITH_SIMD=OFF` 打通，再視 JPEG 解碼耗時決定是否補 NASM |
| **R7** | **每一條 compile/run 判準都在 Windows 上**。macOS 這端只能做到「語法與結構可 grep 驗證」，無法證明可編譯——與跨平台 P0 那輪 Windows runner 碼「從未編譯過」是同一類風險 | handover §10「在 macOS 上驗證 Windows 程式碼＝不可能」 | R2 kickoff 前先確認 Windows 機器/CI 的可用性（§6 Q4） |
| **R8** | **AOT 副檔名改動觸及約 30 處**，漏改一處就是 link 期缺檔，且錯誤訊息指向 build 目錄而非 CMakeLists | `CMakeLists.txt` 各 link 區塊（W6b 已列舉行號） | W6b 的判準用 `grep -c` 機械計數，不靠肉眼 |

---

## 6. 待決問題（Open questions）

| # | 問題 | 為何非問不可 | 影響 |
|---|---|---|---|
| **Q1** | **Windows 到底需不需要全尺寸 RAW 解碼？** R1 的純 Dart 內嵌 JPEG 抽取已能顯示 DNG 預覽；`dng_extract_preview_jpeg`（`src/dng_ffi_api.cpp:159-200`）在功能上與之重疊 | 若「預覽夠用」，本檔 14 項全部不做 | **scope 從 14 項 → 0** |
| **Q2** | 目標 Windows 機器的 GPU 與 Vulkan driver 版本？是否支援 `vk_int8/vk_int16/vk_int64`？ | 決定 backend 選擇是否成立（R5） | backend 可能被迫改變 |
| **Q3** | 打包沿用「commit prebuilt DLL」還是改成 host build 時從源碼編譯？ | 既有政策是 prebuilt（`README.md:23-25`：在每個 host build 內建 Halide AOT + DNG SDK + libjpeg「不可行」） | 建議沿用 prebuilt；若改變，W11/W12 全部重寫 |
| **Q4** | Windows 建置環境由誰提供——使用者本機、還是接受 GitHub Actions windows runner？ | 決定 W1–W9/W12 的驗收能否自動化 | 影響 R2 輪次規劃 |
| **Q5** | Windows 上若首次解碼 >1s（R1），是否接受？或需一併泛化 VkPipelineCache fork？ | fork 的泛化是獨立的一大塊工程（`halide_runtime_fork/` 全套 weak-symbol 機制） | 可能新增 3–5 個工作項 |

---

## 7. 本檔未能確定的事（誠實條款）

1. **任何編譯結果**。本調查全程唯讀、零 build。所有「Windows 上會/不會 compile」的陳述都是靜態閱讀推論，標 **[U]** 者尤然。
2. **MSVC 的 `/fp:strict` 是否等價於 `-ffp-contract=off`**（R3）——未查到明確一對一映射的官方陳述。
3. **macOS 主機的 Halide 能否正確交叉產出 windows COFF `.lib`**（W9）——CMake helper 的副檔名邏輯（`HalideGeneratorHelpers.cmake:998-1013`）顯示命名會是 `.lib`，但未實跑。建議不依賴此路徑。
4. **GitHub Actions 上的 software Vulkan（lavapipe/SwiftShader）是否滿足 `vk_int8/int16/int64`**（§4）。
5. **`windows.h` 與 dng_sdk/STL 的巨集衝突具體規模**（R4）——只確認了 4 個 SDK 檔會 include `<windows.h>`，未逐檔評估衝突。
6. **CPU host 路徑的真實效能數字**（§2）——「極可能 >1s」是基於 macOS Metal ~110ms 的外推，非實測。
