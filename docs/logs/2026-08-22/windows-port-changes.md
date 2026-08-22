# Windows port — source changes for upstream integration

> 建立：2026-08-22。承接 `windows-build-handover.md`（同目錄）。
> 用途：把這台 Windows 機器上的修改帶回真正的 `flutter_dng_decoder` / `Halcyon` git repo。
> 本地 git 基準：`bc60837`（本目錄 2026-08-22 `git init` 的 baseline commit，非上游歷史）。

## 狀態：建置全綠

`python build_windows.py` → `EXIT=0`，`DONE with 2 warning(s)`。
證據：`tmp/verify/clean-2.txt`（刪除整個 `Halcyon/build` 後的乾淨建置）。

- **Phase 1（W12，原生 DLL）：通過。** `dng_decoder_native.dll` 1,906,688 bytes。
- **Phase 2（W14，Flutter app）：通過。** `✓ Built build\windows\x64\runner\Release\halcyon.exe`
- **runbook S5 打包需求：滿足。** `Halcyon/build/windows/x64/runner/Release/` 下 `halcyon.exe`（151,552 bytes）與 `dng_decoder_native.dll` 並存。
- **cold start 可重現**：`tmp/verify/clean-1.txt` 為連 native `build-windows/` 一併刪除的全清建置，
  Phase 1 從零重編亦通過。

**⚠️ 建置成功不等於功能正確。** DLL 能否正確解出 DNG、色彩是否正確，至今**完全未驗證**。
這是此平台第一次成功編譯，最容易把「編譯過」誤讀為「能用」。由使用者自行驗證。

### 兩個 [warn]（皆非阻塞）

1. `nasm not found - libjpeg-turbo will build with WITH_SIMD=OFF`。**只影響效能，不影響正確性。**
   nasm 確實已安裝於 `C:\Program Files\NASM\nasm.exe`，但不在 PATH 上，所以 Phase 0 找不到。
   舊 handover §11 預測「下次乾淨重跑會自動抓到」——**該預測不成立**，需手動把該目錄加進 PATH。
2. `colour gate skipped: no --cfa-sample-dng given` — runbook S4 色彩 gate 需要真實 blue-sky DNG 樣本，
   以 `--cfa-sample-dng <path>` 傳入。

## 要帶回上游的改動

### 1. `native/third_party/dng_sdk/source/dng_pthread.h`（Adobe DNG SDK vendored）
移除 `struct dng_timespec` 自訂型別與無 guard 的 `#define timespec dng_timespec`，改用 CRT 原生 `struct timespec`；`#include <time.h>` 置於 `qWinOS` 分支內、`extern "C"` 之前（:53）。

原巨集會污染 `dng_pthread.h` 之後 include 的**每一個**系統標頭；現代 UCRT（10.0.26100.0）已自帶 `struct timespec`，於是 `<time.h>` 的宣告被文字替換而與手寫型別撞名。加 guard 只會留下雙型別模式（`dng_pthread_now` 與 `dng_pthread_cond_timedwait` 可能逐 TU 不一致），故選擇整個移除。改後 Windows 分支與 POSIX 分支一致。

外部呼叫端只有 `dng_mutex.cpp:336-346`，它本來就寫 `struct timespec now;` 並只讀 `.tv_sec`/`.tv_nsec`，**零改動**——它只是不再被巨集改寫。

**這是移除既有的平台不一致，不是引入新的**：`dng_pthread.h:250` 的 `dng_pthread_now(struct timespec *)` 位於 `qWinOS` 區塊**之外**（共用區），原始碼本來就寫原生 `timespec`；舊巨集只在 Windows 上把它悄悄改寫成 `dng_timespec`，導致同一個函式在不同平台意義不同。改後兩平台一致。

**版面變動已證明無害**（上游 review 會問這點）：舊 `dng_timespec` 是 `{long, long}` = 8 bytes，Win64 原生 `timespec` 是 `{time_t, long}` = 16 bytes，`tv_sec` 由 32 位元加寬為 64 位元。全 repo grep 任何對 timespec 的 `sizeof`/`memcpy`/`memset`/`memcmp`：**0 筆**。無呼叫端序列化、逐位元組複製或依賴其大小；欄位順序不變（`tv_sec` 在前），兩個呼叫端都只用具名成員。故大小改變是惰性的。

`.cpp` 側的改動限於 `qWinOS` 區塊內 2 個 hunk（:313-320、:659-669），`dng_pthread_now` 的函式本體逐位元組相同——**非 Windows 建置的預處理結果不變**，既有 macOS/Android 產物不受影響。

### 2. `native/third_party/dng_sdk/source/dng_pthread.cpp`（同上）
`:316-317` `std::auto_ptr` → `std::unique_ptr`（C++17 已移除 `auto_ptr`）。`<memory>` 原已 include（:42）；`.get()`/`.release()` 在 `unique_ptr` API 相同；`:383/442` 的 `delete resultHolder` 仍對應單物件 `new`。原本 316/317 衍生的約 15 個連鎖錯誤隨之消失，未逐行修補。

### 3. `native/CMakeLists.txt`（三處，前兩處為前一 session）
- `:372` `find_package(Halide REQUIRED COMPONENTS Halide)` — 預設會帶 PNG/JPEG 選用元件，本機無系統 libpng/libjpeg 會導致 Generate 失敗。
- `:386-387` / `:427` — generator target 暫時改用 `MultiThreadedDLL`（`/MD`）後還原。Halide 官方預編譯 lib 是 `/MD`，專案全域 `/MT`，`lld-link /failifmismatch` 會拒絕連結。
- `:437-461`（本次新增）— `dng_stage_halide_dll`：`add_custom_command(OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/Halide.dll ... copy_if_different)` + `add_custom_target`，再以 `foreach` 對 6 個 generator（`DNG_DIAGNOSTIC_BUILD` 時 8 個）`add_dependencies`。

  Halide v21 Windows 發行包只有 shared targets，generator `.exe` **執行時**需要 `Halide.dll` 在同目錄或 PATH，否則 `0xC0000135 STATUS_DLL_NOT_FOUND`。刻意**不用**每個 target 各自 `POST_BUILD copy`：6 個 target 並行寫同一個目的檔會撞 Windows sharing violation。也**不用** PATH 注入：那樣只有走 `build_windows.py` 才有效，裸 `cmake --build` 仍會壞。

  排序證據：`build.ninja` 的 CUSTOM_COMMAND edge 帶 `|| dng_demosaic_generator.exe dng_stage_halide_dll`（order-only），即 ninja 必須先完成 staging 才**執行** generator——不只是連結前。

### 4. `build_windows.py`（新檔，取代 `build_windows.ps1`）
PowerShell 5.1 的 `Expand-Archive` 對 Halide zip 內 Doxygen 超長檔名會炸，且 `$LASTEXITCODE` 不可靠。新增 `--native-target TARGET...` 旗標（只 configure + 建指定 target，跳過 DLL placement/Phase 2）。

### 6. `build_windows.py:200-224` — `.BAT` 啟動修正
`run_checked()` 改為先用 `shutil.which()` 解析出真實路徑，若副檔名為 `.bat`/`.cmd` 則對 `Popen` 加 `shell=True`（仍傳 argv list，由 Python 的 `list2cmdline` 處理引號，避開 §9 記錄過的手動引號組字串陷阱）。

Windows `CreateProcess` 不能直接執行批次檔，而 flutter 在本機解析為 `C:\tools\flutter\bin\flutter.BAT` → `FileNotFoundError [WinError 2]`。修在共用 helper 而非個別 call site：兩個 `.bat` 呼叫點（`:538`/`:539`，`flutter pub get` 與 `flutter build windows --release`）都走這個 helper；cmake/ninja/vswhere 皆為 `.exe`，維持 `shell=False` 行為不變。

exit code 傳遞未被破壞——已由實際失敗證明：`flutter pub get` 因其他原因 exit 1，腳本正確回報 `ERROR in Phase 2 ... (exit code 1)` 與 `EXIT=1`。

### 5. libjpeg-turbo 的 7 個空白 stub `.in` 檔
`release/{installer.nsi,maketarball,libjpeg.pc,Config.cmake}.in`、`win/projectTargets.cmake.in`、`win/vc/projectTargets-release.cmake.in`、`test/croptest.in`。
上游 `.gitignore` 排除了 `release/`、`win/`，但 libjpeg-turbo `CMakeLists.txt:2072` 的 `include(cmakescripts/BuildPackages.cmake)` 無條件需要它們。**這是繞過，不是修正**——只在真的跑 `cpack`/`cmake --install` 時才會讀內容，本專案兩者都不觸發。上游需決定是否真正補齊 vendoring。

### 7. `Halcyon/windows/CMakeLists.txt` — 執行檔改名 + 乾淨建置修正

- **改名**：`:3` `project()`、`:7` `BINARY_NAME` → `halcyon`（`BINARY_NAME` 決定 exe 檔名，其餘 20 餘處引用皆走此變數）。
  另同步 `windows/runner/Runner.rc:93-98` 的 FileDescription/InternalName/OriginalFilename/ProductName
  與 `windows/runner/main.cpp:40` 視窗標題——這幾處各自寫死，不同步會讓 exe 內嵌 metadata 與檔名矛盾。
  **改 target 名後必須刪掉 `Halcyon/build/windows` 重新 configure**，CMake 不會就地更新已快取的
  `$<TARGET_FILE_DIR:...>` generator expression（實測：不清就報 `No target "photo_selector_flutter"`）。

- **乾淨建置修正**（`:91-94` 附近，**既有缺陷，非本次引入**）：Flutter 樣板無條件
  `install(DIRECTORY ${NATIVE_ASSETS_DIR})`，但 flutter 工具只在有 package 提供 native assets 時才建立
  `build/native_assets/windows/`；本專案沒有，故**任何真正乾淨的建置都會失敗**於 `file INSTALL cannot find`。
  先前能過純粹因為舊 build 留下該目錄——亦即這個缺陷在任何全新 checkout 上都會發作。
  修法：install 規則前加一行 `file(MAKE_DIRECTORY "${NATIVE_ASSETS_DIR}")`。

  > 診斷提示：MSBuild 會把真正的錯誤藏在 `MSB3073` 批次包裝噪音（`setlocal`/`:cmEnd`/`exit /b`）之後。
  > 在 `Halcyon/build/windows/x64` 直接跑 `cmake -DBUILD_TYPE=Release -P cmake_install.cmake` 才看得到真因。

### 不進 git 的產物
`native/third_party/halide/`（321MB，`build_windows.py` Phase 0b 自動取得）與 `native/build-windows/`（159MB）已寫入根 `.gitignore`。

## 未解

| 優先 | 議題 | 狀態 |
|---|---|---|
| ~~P2~~ | ~~`flutter.BAT` 無法被 `CreateProcess` 直接執行~~ | **已修**，見下方第 6 項 |
| ~~P2b~~ | ~~Flutter 要求 symlink support（Windows 開發人員模式）~~ | **已解**：使用者於 2026-08-22 開啟開發人員模式，Phase 2 隨即通過 |
| P3 | DLL 的**行為**正確性（能否解出 DNG、色彩是否正確）完全未驗證。這是此平台第一次成功編譯，編譯過 ≠ 行為正確 | 未開始 |
| P4 | runbook S4 色彩 gate（`test_cfa_color`，需真實 blue-sky DNG 樣本）與 S5/S6 手動驗證（含 1 秒首解碼門檻） | 未開始 |

## 已知瑕疵（既有、非本次造成、未修）

`dng_mutex.cpp:342` 與 `dng_pthread.cpp:1118` 的 `(long)` cast 會把 `tv_sec` 截成 32 位元，2038 年後失效。原 `dng_timespec.tv_sec` 本來就是 `long`，行為未變；但改用原生 `timespec` 後欄位已是 64-bit `time_t`，該 cast 現在是多餘的。屬獨立改動，未動。
