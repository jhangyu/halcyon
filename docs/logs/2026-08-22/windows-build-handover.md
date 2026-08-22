# Windows native build (W12) — Session Handover

> ## ⚠️ 已過時（2026-08-22 稍晚）— 先讀 [`windows-port-changes.md`](./windows-port-changes.md)
>
> **P0 與 P1 都已修好。`dng_decoder_native.dll` 已建置並就位，Phase 1 整段通過。**
>
> 本文件以下內容仍描述建置為阻塞狀態，**已不成立**，保留僅供診斷過程參考：
> - 「現象 P0 / 根因 P0」「現象 P1 / 根因 P1」：問題描述正確，但兩者皆已修復
> - §8 待解議題表的 P0/P1 兩列：已解除；P2（DLL 未產出）亦已解除
> - §11「P0/P1 的候選修法均未實作、未測試」：已實作並驗證
> - §0「下一個動作」與 §1「接手啟動序列」：照做會重新診斷已解決的問題
>
> 仍然有效的部分：§9 嘗試與裁決（禁止重踩清單）、libjpeg-turbo stub 檔的紅線、
> §11 關於「編譯過 ≠ 行為正確」的警告（DLL 行為正確性至今仍未驗證）。
>
> 當前狀態、完整改動清單與剩餘工作見 `windows-port-changes.md`。

> **建立時間**：2026-08-22（本機時區）
> **交接目的**：讓下一個 session 接續 halcyon Windows 版 `dng_decoder_native` 原生 DLL 建置，終態是 `flutter build windows --release` 成功產出可執行的 halcyon.exe + dng_decoder_native.dll，並完成 runbook S5/S6 手動驗證。
> **目前判定**：阻塞（native 編譯階段，兩個獨立、根因已確認的問題）
> **可信版本錨點**：無 git 歷史（`C:\Users\User\project\halcyon` 及 `flutter_dng_decoder` 均非 git repo，是 `Halcyon/scripts/package_windows.sh` 產出的「僅含已提交原始碼」靜態封裝，`git rev-parse --is-inside-work-tree` 對兩者皆回傳 fatal）。所有狀態以下方「工作樹狀態」表列的檔案清單為準。

## 0. 接手速讀（60 秒）

- **目標**：在這台 Windows 機器上完整跑通 `Halcyon/docs/logs/2026-08-21/windows-ffi-build-runbook.md` 的 W12+W14 流程，驗證 app 能建置執行。
- **現象**：`cmake --build --preset windows-vulkan --target dng_decoder_native` 在 130/147 左右失敗，有兩個獨立根因（見下）。
- **目前位置**：工具鏈（VS2022 Build Tools 2026 + clang-cl、CMake、Ninja、Vulkan SDK、Flutter、NASM）已全部就緒且驗證可用；CMake configure 已能通過；已修掉 3 個 configure/link 階段問題；卡在 `dng_sdk` 原始碼的 C++17 相容性 bug + Halide generator 執行期 DLL 找不到。
- **下一個動作**：先修 P0（`dng_pthread.h:182` 的 `#define timespec dng_timespec` 巨集在現代 UCRT 下的重定義衝突），再修 P1（讓 `dng_demosaic_generator.exe` 等 6 個 generator 執行時能找到 `third_party/halide/bin/Release/Halide.dll`）。
- **最大風險／紅線**：`third_party/libjpeg-turbo/{release,win}/` 下的 7 個 stub 檔是刻意留白的暫時繞過（見「嘗試與裁決」），不要誤刪；`build_windows.ps1`（原始 PowerShell 版本）已刻意保留未動，供比對用，本次改用新寫的 `build_windows.py`。

## 1. 接手啟動序列

1. Read `C:\Users\User\project\halcyon\build_windows.py` — 這次改用的 Python 版建置腳本，已內建環境自舉（讀登錄檔刷新 PATH、自動找 vswhere/vcvars64.bat）。
2. Read `flutter_dng_decoder\dng_processor\native\third_party\dng_sdk\source\dng_pthread.h:60-188` 與 `dng_pthread.cpp:310-340` — P0 根因所在。
3. Run（只讀狀態確認）：`python build_windows.py` 於 `C:\Users\User\project\halcyon`，預期立刻重現本文件記錄的兩個失敗（Phase 0/0b 會全綠跳過，直接進 Phase 1 ninja build 並在 dng_pthread.cpp 處失敗）。
4. 從 `dng_pthread.h:182` 開始修 P0；修完後同一次 `python build_windows.py` 會自動繼續嘗試 P1（generator DLL 找不到）。
5. 兩個都修完後，驗證命令見「12. 驗收命令」。

## 2. 目的、現象與根因狀態

### 目的
讓 `flutter build windows --release` 在這台機器上成功產出可執行的 Halcyon Windows app（DLL 正確打包進 Release 目錄），而不只是「建置腳本能跑」。

### 現象 P0：dng_pthread.cpp 編譯失敗（qWinOS 分支第一次真正被編譯）
- 條件：`cmake --build --preset windows-vulkan --target dng_decoder_native`，clang-cl，C++17（`native/CMakeLists.txt:26-27`）。
- 實際：20 個編譯錯誤，`fatal error: too many errors emitted, stopping now`。
- 預期：`dng_sdk.dir/third_party/dng_sdk/source/dng_pthread.cpp.obj` 正常編譯。
- 證據：`C:\Program Files (x86)\Windows Kits\10\include\10.0.26100.0\ucrt\time.h(45,12): error: redefinition of 'dng_timespec'`；`dng_pthread.cpp(316,8): error: no member named 'auto_ptr' in namespace 'std'`（同段落連鎖出 ~15 個衍生錯誤，都是 auto_ptr 消失後 `args`/`resultHolder` 型別推導失敗的連帶效應，不是獨立問題）。

### 根因 P0 — 已確認（雙因）
1. **`dng_timespec` 重定義**：`dng_pthread.h:182` 的 `#define timespec dng_timespec` 沒有任何 guard（不像同檔案其他巨集有 `#undef`/`#if defined` 保護），在 `qWinOS` 分支無條件生效。`dng_pthread.h` 在 `dng_pthread.cpp:14` 最早被 include，之後 `<windows.h>` 等系統標頭會傳遞 include 到 UCRT 的 `<time.h>`；此時巨集已生效，UCRT 自己的 `struct timespec` 宣告被文字替換成 `struct dng_timespec`，與 `dng_pthread.h:65` 手寫的 `struct dng_timespec { long tv_sec; long tv_nsec; };` 撞名。2012 年這支檔案寫的時候舊版 MSVC 沒有 `struct timespec`，這個巨集是為了補上；現代 UCRT（10.0.26100.0）已經有了，巨集反而變成 bug。
2. **`std::auto_ptr` 已移除**：`dng_pthread.cpp:316-317` 用 `std::auto_ptr<trampoline_args>` / `std::auto_ptr<void *>`，C++17 標準函式庫已移除此型別（`native/CMakeLists.txt:26` 強制 `CMAKE_CXX_STANDARD 17`）。第 319/322/323/333/336 行的錯誤都是這兩行的型別推導失敗導致的連鎖（`args`、`resultHolder` 變成未宣告識別字），修好 auto_ptr 那兩行後這些應該一併消失，不需要逐一修。
- **仍待辨識**：`dng_timespec` 的最小修法有兩種候選，尚未評估哪個更安全：(a) 幫 182 行的 `#define` 加 `#ifndef _TIMESPEC_DEFINED` 一類的 guard（風格上跟現有 codebase 其他巨集一致）；(b) 直接砍掉 `dng_timespec` 自訂型別與該巨集，改用 UCRT 原生 `struct timespec`（更乾淨但要確認 `dng_pthread_cond_timedwait` 等簽名跟呼叫端不會因型別改名而炸）。下一個 session 應先讀完整個 `qWinOS` 分支（`dng_pthread.cpp:54-700` 附近）再決定，不要只看報錯行盲改。

### 現象 P1：Halide generator 執行期找不到 DLL（P0 修好後才會走到，但根因已獨立確認）
- 條件：修好 CRT runtime library 不匹配後（見「已完成事項」第 3 項），6 個 `dng_*_generator.exe` 成功連結為 `/MD` 動態 CRT。ninja 接著把它們當 custom command 執行以產生 Halide AOT `.lib`/`.h`。
- 實際：`[code=3221225781]`（= `0xC0000135` `STATUS_DLL_NOT_FOUND`），例如 `dng_demosaic_generator.exe -r halide_runtime -o ... target=...` 直接崩潰。
- 預期：generator 執行後在 `build-windows/halide_generated/` 產出 `.lib`/`.h`。
- 證據：完整失敗指令見本文件底部附件 A；`third_party/halide/bin/Release/Halide.dll` 確實存在（`ls` 已確認），但 ninja 執行 generator 時的 PATH 不含這個目錄，且 `native/CMakeLists.txt` 目前沒有任何 post-build 把 `Halide.dll` 複製到 generator.exe 旁邊的邏輯。

### 根因 P1 — 已確認
Halide v21.0.0 這份 Windows 官方發行包只有 `Halide-shared-targets.cmake`，沒有 static 變體（`lib/cmake/Halide/` 目錄下沒有 `Halide-static-targets.cmake`），所以 `find_package(Halide)` 必然解析成動態 `Halide::Halide`（`Halide.lib` 只是 import lib，真正符號在 `bin/Release/Halide.dll`）。Generator 執行檔連結時用 import lib 沒問題，但**執行時** Windows 載入器找不到 `Halide.dll`（不在 PATH、不在 generator.exe 同目錄）。P0 的 CRT `/MD` 修正是必要的（否則連結階段就先炸），但改成 `/MD` 之後才讓建置真正走到「執行 generator.exe」這一步，把這個原本被 P0 擋住、看不見的問題暴露出來——不是 P0 的修法造成的新 bug，是本來就存在、順序上更下游的問題。
- **候選修法（未實作，留給下一個 session 評估）**：(a) 在 `build_windows.py` 呼叫 `cmake --build` 前，把 `third_party/halide/bin/Release` 加進子行程的 `PATH`；(b) 在 `native/CMakeLists.txt` 對 6 個 generator target 加 `add_custom_command(TARGET <gen> POST_BUILD COMMAND ${CMAKE_COMMAND} -E copy_if_different <Halide.dll路徑> $<TARGET_FILE_DIR:<gen>>)`。(a) 改動範圍小、不動 CMakeLists；(b) 更貼近 CMake 慣例但要對 6 個 target 各加一次或寫個迴圈。兩者都沒試過，不要預設哪個能一次成功。

## 3. 範圍與版本控制狀態

- In scope：`C:\Users\User\project\halcyon\build_windows.py`（新建）、`flutter_dng_decoder\dng_processor\native\CMakeLists.txt`、`flutter_dng_decoder\dng_processor\native\third_party\{halide,libjpeg-turbo}\*`。
- Out of scope（本次未碰）：`Halcyon\` 下的 Flutter/Dart 原始碼（Phase 2 W14 尚未跑到）、macOS/Android 建置路徑、`build_windows.ps1`（原始版本，刻意保留不動）。
- Branch / HEAD：不適用（無 git repo，見文件開頭）。
- Working tree（相對於 zip 解壓後的原始狀態，全部由本 session 產生）：
  - 新增：`C:\Users\User\project\halcyon\build_windows.py`
  - 新增：`flutter_dng_decoder\dng_processor\native\third_party\halide\`（整個目錄，手動從官方 v21.0.0 Windows 發行包解壓補齊，含 `VERSION` 檔標註 local_note）
  - 新增（7 個空白 stub 檔，見下方「嘗試與裁決」）：
    `flutter_dng_decoder\dng_processor\native\third_party\libjpeg-turbo\test\croptest.in`
    `...\release\installer.nsi.in`、`...\release\maketarball.in`、`...\release\libjpeg.pc.in`、`...\release\Config.cmake.in`
    `...\win\projectTargets.cmake.in`、`...\win\vc\projectTargets-release.cmake.in`
  - 修改：`flutter_dng_decoder\dng_processor\native\CMakeLists.txt`（兩處，見「已完成事項」第 2、3 項的精確行號）
  - 建置產物（非原始碼，`build-windows/` 底下，可安全刪除重跑）：CMake configure 快取 + 部分 ninja object 檔（130/147），無最終 DLL。
- 背景狀態：無 team／tmux／container；本 session 所有子行程均已結束（background bash task 均已 completed/failed，無殘留常駐程序）。

## 4. 目前建置依賴鏈（本階段切面）

| 節點 | 責任 | 關鍵符號 | 上游 | 下游 | 不變式／失敗語意 |
|---|---|---|---|---|---|
| `build_windows.py` | 環境自舉＋跑 Phase 0-3 | `ensure_msvc_env()`, `main()` | 使用者手動執行 | 呼叫 cmake/ninja/flutter | 找不到 MSVC 環境即 `fail()` 中止，不猜 |
| CMake configure | 解析 CMakeLists、找 Halide/JPEG/ZLIB | `native/CMakeLists.txt:372` `find_package(Halide REQUIRED COMPONENTS Halide)` | build_windows.py 呼叫 `cmake --preset windows-vulkan` | 產生 build-windows/build.ninja | 元件解析失敗＝全專案 Generate 失敗，不只失敗的 target |
| Halide generator 執行檔 | build 期執行以產生 Halide AOT `.lib/.h` | `native/CMakeLists.txt:378-421`（6 個 `add_executable(dng_*_generator)`） | 連結 `Halide::Generator`（→`Halide_GenGen.lib`+`Halide.lib`） | ninja custom command 執行它們，產出 `halide_generated/*.lib` | 連結需 CRT 對齊 `/MD`（已修）；**執行**需 `Halide.dll` 在 PATH 或同目錄（未修，P1） |
| `dng_sdk` 靜態庫 | 編譯 Adobe DNG SDK 原始碼 | `third_party/dng_sdk/source/dng_pthread.cpp`, `dng_pthread.h:182` | `native/CMakeLists.txt` `file(GLOB_RECURSE DNG_SOURCES ...)` | `dng_decoder_native` DLL、`test_decode`/`test_device_handoff` | qWinOS 分支是本次第一次編譯到，C++17 相容性未驗證（P0） |
| `dng_decoder_native.dll` | 最終原生 DLL | `native/CMakeLists.txt:352` | `dng_sdk` + JPEG_LIBRARIES + Halide AOT `.lib` | 複製進 `flutter_dng_decoder/dng_processor_ffi/windows/Libraries/` | 尚未產出（P0 擋住） |
| Flutter build windows | W14，打包最終 app | `Halcyon\` (`flutter build windows --release`) | 依賴上面的 DLL 已 place 好 | `Halcyon/build/windows/x64/runner/Release/` | 完全未執行到（Phase 1 沒過） |

## 5. 資料生產消費鏈

不適用——這是原生建置管線問題，不是執行期資料流／API 契約問題。相關的「產出物鏈」已在上表列出。

## 6. 型別與介面契約

不適用（同上，非 API/schema 類任務）。唯一需要注意的「契約」是 P0 修法選項 (b) 若把 `dng_timespec` 整個換成 UCRT 原生 `timespec`，`dng_pthread.h` 對外宣告的函式簽名（`dng_pthread_cond_timedwait` 等）會變，要確認呼叫端（grep 全 repo `dng_pthread_cond_timedwait`／`dng_timespec`）沒有假設舊型別的欄位順序或大小。

## 7. 已完成事項

| 結果 | 改動／產物 | 驗證 | 版本錨點 |
|---|---|---|---|
| [C] 完整工具鏈就緒（VS Build Tools 2026 18.9.1 + VCTools workload + clang-cl、CMake 4.4.2、Ninja 1.13.2、Vulkan SDK 1.4.350、Flutter 3.41.9、NASM 3.2.0） | 系統層級安裝，非本 repo 檔案 | `python build_windows.py` 的 Phase 0 全部 `[ok]` | working tree at 2026-08-22 |
| [C] Python 版建置腳本，取代 PowerShell 版（Expand-Archive 長路徑 bug + `$LASTEXITCODE` 不可靠） | `build_windows.py`（新檔，~420 行） | 已跑過 5 輪，Phase 0/0b/Phase1-configure 穩定通過 | working tree |
| [C] Halide v21.0.0 手動補齊（原腳本用 `Expand-Archive` 對這份 zip 的長檔名會炸；改用 Python `zipfile` 篩選解壓＋官方發行包把 `Halide.lib` 放在 `lib\Release\` 而非腳本預期的 `lib\Halide.lib`，已鏡射一份） | `native/third_party/halide/`（含 `lib/Halide.lib`、`lib/Release/Halide.lib`、`bin/Release/Halide.dll`、`VERSION`） | `Test-Path` 等效檢查通過，Phase 0b `[ok] already present` | working tree |
| [C] libjpeg-turbo CPack 樣板檔缺失（`.gitignore` 排除了 `native/third_party/libjpeg-turbo/{release,win}/`，但其 `CMakeLists.txt:2072` 的 `include(cmakescripts/BuildPackages.cmake)` 沒有頂層專案 guard，無條件需要這些檔案） | 7 個空白 stub `.in` 檔（見「範圍」段落列表） | CMake configure 不再報這 7 個 `configure_file` 錯誤 | working tree |
| [C] `find_package(Halide REQUIRED)` 預設帶 PNG/JPEG 選用元件，這台機器沒系統 libpng/libjpeg 導致 `test_device_handoff`/`test_decode` Generate 失敗 | `native/CMakeLists.txt:372`：改成 `find_package(Halide REQUIRED COMPONENTS Halide)` | `-- Configuring done` / `-- Generating done` 均成功（先前這兩步任一都會報錯） | working tree |
| [C] Generator 執行檔 CRT runtime library 不匹配（專案全域 `/MT`，Halide 官方預編譯 lib 是 `/MD`，`lld-link /failifmismatch` 直接拒絕連結） | `native/CMakeLists.txt:386-387`（進入前存舊值並設 `MultiThreadedDLL`）與 `:427`（離開後還原） | 6 個 generator `.exe` 全部連結成功，不再出現 `/failifmismatch` 錯誤 | working tree |

## 8. 待解議題

| 優先 | 狀態 | 議題／缺口 | 解除條件 | 下一動作 | 完成條件 |
|---|---|---|---|---|---|
| P0 | [B] | `dng_pthread.h:182` 巨集在現代 UCRT 下與 `<time.h>` 撞名；`dng_pthread.cpp:316-317` 用已移除的 `std::auto_ptr` | 見「根因 P0」兩個候選修法擇一 | 讀完 `dng_pthread.cpp` 的整個 `qWinOS` 分支，選定 (a) 加 guard 或 (b) 換用原生 `timespec`；`std::auto_ptr`→`std::unique_ptr`（注意 `.release()`/`.get()` API 相容，`std::unique_ptr` 兩者都有，應可直接替換） | `dng_pthread.cpp.obj` 編譯成功、0 error |
| P1 | [B]（P0 解除後才會實際卡到，但根因已確認可提前修） | Generator `.exe` 執行時找不到 `third_party/halide/bin/Release/Halide.dll` | 見「根因 P1」兩個候選修法擇一 | 選 PATH 注入（改 `build_windows.py`）或 CMake POST_BUILD copy（改 `CMakeLists.txt`）擇一實作 | `halide_generated/*.lib` 與對應 `.h` 全部產出，ninja 該步驟不再有 `code=3221225781` |
| P2 | [U] | `dng_decoder_native.dll` 尚未產出，DLL 是否正確被 Flutter 打包（runbook S5）完全未驗證 | P0+P1 解除，`cmake --build --preset windows-vulkan --target dng_decoder_native` 成功 | `python build_windows.py`（不加任何 skip 旗標） | `flutter_dng_decoder\dng_processor_ffi\windows\Libraries\dng_decoder_native.dll` 存在且 `Halcyon\build\windows\x64\runner\Release\dng_decoder_native.dll` 存在 |
| P3 | [U] | Runbook S4 色彩正確性 gate（`test_cfa_color`，需要真實 blue-sky DNG 樣本）與 S5/S6 手動驗證（含 1 秒首解碼硬性門檻）完全未跑 | P2 完成 | 需使用者提供或指定 `local_data\photo_samples\DNG\` 樣本路徑，帶 `--cfa-sample-dng` 重跑 | 依 runbook S4/S5/S6 逐條過 |
| P4 | [D] | 本次在這份本機副本上直接改了 `native/CMakeLists.txt`（P0/P1 兩個 CMake 層級修法都會需要），但這是「僅含已提交原始碼」的靜態封裝，沒有 git 歷史可以帶回上游 | 使用者決定 | 待整個 Windows 移植跑通後，把 `native/CMakeLists.txt` 的三處改動（COMPONENTS Halide、generator CRT override、以及 P0/P1 完成後新增的修法）與 7 個 stub 檔決定要不要真的補進 libjpeg-turbo vendoring，一併帶回真正的 `flutter_dng_decoder` git repo（可能在 macOS host 上）補 commit | 不適用（人的決策，非機械條件） |

## 9. 嘗試、裁決與禁止重踩

| 嘗試／方案 | 結果 | 被否證假設／不採用理由 | 是否可重試 | 證據 |
|---|---|---|---|---|
| 直接跑原始 `build_windows.ps1` | 失敗：Windows PowerShell 5.1 內建 `Expand-Archive` 對 Halide zip 裡 Doxygen 產生的超長檔名（`share/doc/Halide/html/*.html`）拋 `Remove-Item` 錯誤，整支腳本中止 | 這是 PowerShell 5.1 已知限性，非腳本邏輯錯；使用者已決定改寫 Python（見 `build_windows.py`） | 否——已用 Python `zipfile` 篩選解壓取代 | 見「已完成事項」第 3 項 |
| `cmd.exe /c "..."` 透過 Bash 工具直接呼叫 | 只印出 cmd 版本橫幅，指令從未真正執行 | 一開始誤判為「這個沙箱環境攔截 cmd.exe」；後來查明是 MSYS/Git-Bash 把裸露的 `/c` 參數當 POSIX 路徑轉譯成 `C:\`，跟沙箱無關。Python 內部呼叫 `subprocess` 不受此影響 | 不需要——已確認是 shell 邊界問題，`build_windows.py` 內部呼叫 `cmd.exe` 一律用 argv list 或 `shell=True` 走 Python 自己的子行程，不受影響 | 對照組：`powershell -NoProfile -Command "..."` 同一 session 正常執行 |
| `subprocess.run(["cmd.exe","/c", f'"{vcvars}" \&\& set'])`（argv-list 模式） | 失敗：`不是內部或外部命令`——cmd.exe 收到帶內嵌引號的單一參數，Windows 命令列引號規則跟 argv-list 模式的自動跳脫衝突 | Windows `cmd /c` 的引號解析與 Python `list2cmdline` 對「內含空白與引號的單一參數」的跳脫方式不相容 | 不需要——已改用 `shell=True` 傳整串字串，驗證可用 | `build_windows.py` 的 `ensure_msvc_env()` 現用寫法 |
| 7 個空白 stub `.in` 檔繞過 libjpeg-turbo CPack 缺檔 | 成功讓 configure 過關 | 這些檔案只在真的執行 `cpack`/`cmake --install` 時才被讀取內容，本專案的建置流程從未觸發那兩者，留白不影響任何已編譯產物；但這是**繞過**而非修正真正的 vendoring 缺口（`.gitignore` 排除了整個 `release/`、`win/` 目錄），標記待上游決策（見 P4） | 可接受長期保留，除非上游決定把 `release/`、`win/` 真正 un-ignore 補回完整原始碼 | Configure log 不再出現這 7 個檔案的 `configure_file` 錯誤 |

## 10. 未來方向（不阻塞當前交付）

- 若 Halide 之後改用**靜態**變體（避免整個 P1 這類 DLL 搜尋路徑問題），需等 Halide 官方 Windows 發行包提供 `Halide-static-targets.cmake`；目前 v21.0.0 沒有，觸發條件：Halide 上游發版變動。

## 11. 已知限制與不確定性

- **已知限制**：nasm 已裝好（3.2.0），但目前 configure log 仍顯示 `WITH_SIMD OFF`——因為那份 log 來自 nasm 裝好**之前**跑的 configure；下一次乾淨重跑應該會自動抓到 nasm 並開 SIMD，屬於良性差異，不影響功能正確性，只影響 libjpeg-turbo 效能。
- **未驗證**：P0/P1 的候選修法均未實作、未測試，兩者各有至少一個未評估的替代方案（見「根因」段落「仍待辨識」）。
- **未驗證**：即使 P0+P1 修好，`dng_decoder_native.dll` 本身的正確性（是否真的能解出 DNG、色彩是否正確）完全沒驗證過——這是全新平台的第一次成功編譯，不能假設編譯過＝行為正確。
- **需使用者決策**：P4（是否要把這些 CMakeLists.txt 修法與 stub 檔帶回真正的 git repo）。

## 12. 驗收命令

```bash
# 由窄到寬
cd C:\Users\User\project\halcyon
python build_windows.py
# 預期（P0/P1 修好後）：Phase 1 印出 "[ok] placed: ...\dng_decoder_native.dll"，接著進 Phase 2
# 完整成功的最終關鍵輸出："DONE - no warnings." 或 "DONE with N warning(s)"（N 應只剩 nasm 相關，若 nasm 已被抓到則 0）
```

## 13. 參考入口

- 必讀：`flutter_dng_decoder\dng_processor\native\third_party\dng_sdk\source\dng_pthread.h:60-188` — P0 的巨集與型別定義全貌
- 必讀：`flutter_dng_decoder\dng_processor\native\third_party\dng_sdk\source\dng_pthread.cpp:296-345` — P0 的 `dng_pthread_create` 完整函式（`std::auto_ptr` 兩處用法）
- 必讀：`flutter_dng_decoder\dng_processor\native\CMakeLists.txt:360-427` — Halide find_package + generator 定義區塊（P0 之後 P1 也要改這附近或 `build_windows.py`）
- Artifact：本文件「附件 A」— P1 完整失敗指令原文（原始 log 為 Claude Code session 暫存檔，session 結束後會被清除，故完整轉錄於此）
- 相關決策／文件：`Halcyon\docs\logs\2026-08-21\windows-ffi-build-runbook.md` — 本次工作對應的權威 runbook；`Halcyon\docs\logs\2026-08-21\windows-ffi-build-runbook.md` 的「四個最可能的 first-contact 問題」清單中**沒有涵蓋** P0/P1，屬於這次新發現、runbook 尚未記錄的問題，建議下一個 session 修完後回頭補進 runbook

---

## 附件 A：P1 完整失敗指令原文

```
[124/147] Generating standalone Halide runtime...
FAILED: [code=3221225781] halide_generated/halide_runtime.lib C:/Users/User/project/halcyon/flutter_dng_decoder/dng_processor/native/build-windows/halide_generated/halide_runtime.lib
C:\WINDOWS\system32\cmd.exe /C "cd /D C:\Users\User\project\halcyon\flutter_dng_decoder\dng_processor\native\build-windows && C:\Users\User\project\halcyon\flutter_dng_decoder\dng_processor\native\build-windows\dng_demosaic_generator.exe -r halide_runtime -o C:/Users/User/project/halcyon/flutter_dng_decoder/dng_processor/native/build-windows/halide_generated target=x86-64-windows-vulkan-vk_int8-vk_int16-vk_int64-no_asserts-no_bounds_query"

[125/147] Generating Halide AOT Stage3 Demosaic...
FAILED: [code=3221225781] halide_generated/dng_demosaic_bilinear.lib halide_generated/dng_demosaic_bilinear.h C:/Users/User/project/halcyon/flutter_dng_decoder/dng_processor/native/build-windows/halide_generated/dng_demosaic_bilinear.lib C:/Users/User/project/halcyon/flutter_dng_decoder/dng_processor/native/build-windows/halide_generated/dng_demosaic_bilinear.h
C:\WINDOWS\system32\cmd.exe /C "cd /D C:\Users\User\project\halcyon\flutter_dng_decoder\dng_processor\native\build-windows && C:\Users\User\project\halcyon\flutter_dng_decoder\dng_processor\native\build-windows\dng_demosaic_generator.exe -g dng_demosaic_bilinear -f dng_demosaic_bilinear -o C:/Users/User/project/halcyon/flutter_dng_decoder/dng_processor/native/build-windows/halide_generated target=x86-64-windows-vulkan-vk_int8-vk_int16-vk_int64-no_asserts-no_bounds_query-no_runtime"
```

code=3221225781 = 0xC0000135 = `STATUS_DLL_NOT_FOUND`。`third_party/halide/bin/Release/Halide.dll` 存在於磁碟上，問題純粹是 PATH／執行檔同目錄沒有這份 DLL。
