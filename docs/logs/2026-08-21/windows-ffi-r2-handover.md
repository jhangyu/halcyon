# Windows FFI R2（W1-W9 首輪）— Session Handover

> **建立時間**：2026-08-21 02:30 前後（Asia/Taipei）
> **交接目的**：讓 05:30 排程 session（cron `9245ecc1`）接續 R2 剩餘工作，終態是「契約 §5b 全部 macOS 側 AC 完成，Windows 側工作收斂進 runbook 交使用者」。
> **目前判定**：進行中——W1-W9 已落地並提交，**唯一在途缺口是 W7b（critical path）**。
> **可信版本錨點**：Halcyon `main` @ `a866648`；上游 flutter_dng_decoder @ `e007418`。本檔結論全部對應這兩個 commit。

## 0. 接手速讀（60 秒）

- **目標**：dng_processor_ffi 支援 Windows 全尺寸 RAW 解碼（Vulkan backend，使用者已裁決）。
- **目前位置**：macOS 可做的 9 項中 8 項全交付（W1-W6、W8、W9 [C]；W7 [P]）；打包（W10/W11/W13）與 runbook 也已交付。全部已 commit。
- **唯一阻斷（P0）**：**W7b**——Stage4 拆分 kernel 在 Windows 會被生成、連結、但**永不被呼叫**（caller 側 21 處 `#if defined(__ANDROID__)` guard 未泛化）。後果：Halide v21 SPIR-V Tuple R==G bug（風險 R2）在 Windows 未被緩解。
- **下一個動作**：照 §3 P0 實作 W7b（設計提案已寫好：`scripts/tmp/verify/W7b_host_bridge_gap.md`）。
- **紅線**：`dng_processor/native/build*/` 是活建置樹不可動；macos-metal 回歸 + `test_cfa_color` 是必跑閘；Halcyon 樹上 `lib/views/rename_dialog.dart` 是另一 session 在途檔不可碰；禁全樹 git 操作，commit 顯式 add。

## 1. 接手啟動序列

1. Read `docs/logs/2026-08-21/windows-raw-r1r2-contract.md` §5b — 凍結的 R2 AC 與使用者五項裁決（Vulkan / clang-cl / prebuilt DLL / 筆電純驗證 / 首次解碼 1s 硬門檻）。
2. Read `scripts/tmp/verify/W7b_host_bridge_gap.md` — W7b 的缺口分析與 `DNG_STAGE4_SPLIT_KERNEL` macro 設計提案（實作者 impl-native-opus 留下，含逐處 guard 分類原則）。
3. Run `git -C /Users/jhangyu/project/flutter_dng_decoder log --oneline -3` — 預期 top 為 `e007418`；`git -C /Users/jhangyu/project/Halcyon log --oneline -2` — 預期 top 為 `a866648`。不符＝有其他 session 動過，先重驗前提。
4. Start at `dng_processor/native/src/dng_render_halide.cpp`（唯一要改的檔，見 §3 P0 行號）。
5. Verify with §5 驗收命令（macos-metal build + test_cfa_color 實跑）。

## 2. 狀態總表

| 項 | 狀態 | 證據 |
|---|---|---|
| W1 fetch 腳本 OS/arch 化 | [C] | `scripts/tmp/verify/w1/w1_fetch_script.txt`；5 模擬 host 的 asset 名經 GitHub API 對照 v21.0.0 release 確認存在 |
| W2a zlib（find_package→FetchContent 1.3.1，SHA256 已親驗） | [C] | `w2/zlib_sha256.txt`、`w2/macos_configure.log` |
| W2b libjpeg vendored 分支 `ANDROID OR WIN32`（NASM 探測→SIMD OFF fallback） | [C] | 同上 |
| W3 toolchain：NOMINMAX/LEAN_AND_MEAN、`/clang:-ffp-contract=off`、**cl.exe 直接 FATAL_ERROR**（escape hatch `DNG_ALLOW_MSVC_FP_CONTRACT`）、CMP0091 NEW | [C] | `dng_processor/native/CMakeLists.txt` @ `e007418` |
| W4 POSIX 移植（mman/unistd → `_WIN32` guard + VirtualAlloc/VirtualFree） | [C] | `mechanical_checks.txt`；三處 include site 由 lead 親驗 guard |
| W5 backend guard 三處放寬 `__ANDROID__ \|\| _WIN32` | [C] | `dng_halide_device.cpp` @ `e007418` |
| W6a AOT target `x86-64-windows-vulkan-vk_int8-vk_int16-vk_int64-...` | [C] | `w7/cfg_win_aot.log` |
| W6b `.a` → `${DNG_AOT_LIB_EXT}`（67→0，68 refs；改前副本 `w2/CMakeLists.pre_w6b.txt`） | [C] | lead 親驗 grep 計數 |
| W7 拆分 kernel 泛化 — CMake + DngRenderGenerator 側 | [C] | `DNG_STAGE4_SPLIT_KERNEL` var；android=ON 不變、macOS=OFF 不變（`w7/cfg_android_stage1.log`） |
| **W7b 拆分 kernel 的 caller 側（host bridge）** | **[C] 2026-08-21 簽收** | 上游 `4d4c314`；證據 `scripts/tmp/verify/w7b/`（pp 等價 IDENTICAL、B-R=132.41 PASS 位元一致、Android configure ON）；`:906` ensureSafeHueSatMap 判為 kernel-variant 已核可；剩餘 P2 交使用者照 runbook |
| W8 vulkan-1.lib link 分支（VULKAN_SDK hint + override + FATAL_ERROR） | [C] | CMakeLists @ `e007418` |
| W9 `windows-vulkan` 單階段 preset（Ninja + clang-cl + static CRT） | [C] | CMakePresets.json @ `e007418`；JSON parse 過 |
| W10/W11/W13 打包 + README | [C] | 上游 `60a5427`；變數名 `dng_processor_ffi_bundled_libraries` PARENT_SCOPE 由 lead 親驗 |
| Runbook（AC-R2-7） | [C] | Halcyon `a866648`：`windows-ffi-build-runbook.md`（明載未曾在 Windows 執行） |
| macos-metal 回歸 + 真 DNG 解碼 | [C] | build exit 0；`test_cfa_color` 對 `IMG_20251112_092839.dng` → `B-R=132.41 [PASS]` backend=metal（`w2/macos_cfa_color.log`） |
| W12 DLL 產出、W14 端到端 | [W] 未動 | 只能在使用者 Windows 筆電，照 runbook |
| **全部 Windows 側 compile/link/run** | **[U]** | 本機無 Windows toolchain；clang-cl flag 接受度、Halide COFF `.lib`、dng_sdk qWinOS 首編、vulkan link 全未驗 |

## 3. 待解議題（依賴排序）

| 優先 | 議題 | 入口 | 完成條件 |
|---|---|---|---|
| **P0** | **W7b**：`dng_processor/native/src/dng_render_halide.cpp` 的 21 處 `#if defined(__ANDROID__)` 泛化為 `DNG_STAGE4_SPLIT_KERNEL`（`__ANDROID__ \|\| _WIN32`）。關鍵位置：header include `:137-138`；call sites `:1034`、`:1306`；buffer-shape 選擇 `:953-975`、`:1234-1256`；RGBA scratch/D2H `:1003-1031`、`:1292-1303`、`:1103`、`:1375`。**逐處分類**：kernel-variant guard（改新 macro）vs NEON/平台 guard（保留 `__ANDROID__`，`arm_neon.h` 與 `stripRgbaToRgbMT` NEON body 需給 x86 scalar fallback）。設計論證：`__ANDROID__` 蘊含新 macro、macOS 兩者皆未定義 → 對兩既有平台 preprocessor-equivalent，非回歸可機械驗證 | `W7b_host_bridge_gap.md` | ①`grep -c "defined(__ANDROID__)" src/dng_render_halide.cpp` 只剩真正平台專屬處，且每處可說明歸類理由 ②macOS preprocessor 等價（如 `clang -E` diff 或 macro 未定義論證）③§5 回歸命令全綠 |
| **P1** | W7b 後回歸：macos-metal build + `test_cfa_color` 實跑 | §5 命令 | build exit 0；`B-R` PASS exit 0 |
| **P2** | 使用者在 Windows 筆電照 runbook 跑 W12（產 DLL、commit 進 `dng_processor_ffi/windows/Libraries/`）+ W14（端到端 + 首次/後續解碼計時） | `docs/logs/2026-08-21/windows-ffi-build-runbook.md` | runbook §7 Results 填上實測數字 |
| **P3**（條件觸發） | 首次解碼 >1s → VkPipelineCache fork 泛化輪（`halide_runtime_fork/` 的 `if(ANDROID AND DNG_CROSS_BUILD)` guard，CMakeLists `:545` 附近；係獨立大工程）。**開工前必須另立 handover（使用者裁決 Q5）** | findings §5 R1 | 首次解碼 <1s |

## 4. 嘗試、裁決與禁止重踩

| 事項 | 裁決 |
|---|---|
| W7b 為何沒做 | 實作者正確自停：越出任務檔案範圍、且 2000 行 perf-critical 色彩路徑無法在本輪帶判準收尾。**不是遺漏，勿當缺陷追究，直接續作** |
| findings §3 W4 的兩處前提錯誤 | ①漏列 `dng_warp_halide.cpp:128-129`（已補港）②`dng_render_halide.cpp:120,1697-1718` 本已在 `__ANDROID__` 內不需改——AC-R2-3 字面是 `!defined(_WIN32)`，該處由更嚴 guard 滿足，**下一 session 勿「修正」它** |
| cl.exe FATAL_ERROR | 刻意設計（byte-exact 色彩合約不可默默失守），勿放寬；escape hatch 是 `DNG_ALLOW_MSVC_FP_CONTRACT` |
| Parking-lot | ①`getOrGrowZeroBuf` calloc fallback 被 munmap/VirtualFree 釋放的既有 latent leak（兩平台皆有，未動）②行動端 [D-1]/[D-2]/[D-3]③非 DNG RAW 格式④1142 AGENTS.md |
| 上游 repo 既有髒污 | `.claude/settings.json` modified 與 4 個 `test_metal_*`/`test_pipeline_zero_copy` untracked binaries **先於本輪存在，不屬本工作，勿清理勿 commit** |

## 5. 驗收命令（W7b 完成後必跑）

```bash
cd /Users/jhangyu/project/flutter_dng_decoder/dng_processor/native
cmake --preset macos-metal          # 預期 exit 0
cmake --build --preset macos-metal -j 8   # 預期 exit 0、無 error 行
# test_cfa_color 實跑（實際命令與 build 產物路徑見 scripts/tmp/verify/w2/macos_cfa_color.log 開頭）
# 預期：backend=metal、B-R 值 PASS、exit 0
# Android 非回歸（configure 級）：對照 w7/cfg_android_stage1.log 的 "Stage4 split kernel: ON"
```

Windows 側驗收一律走 `docs/logs/2026-08-21/windows-ffi-build-runbook.md`（使用者執行）。

## 6. 參考入口

- 契約（凍結 AC + 使用者裁決）：`docs/logs/2026-08-21/windows-raw-r1r2-contract.md` §5b
- W7b 設計提案：`scripts/tmp/verify/W7b_host_bridge_gap.md`
- 工作項定義：`docs/logs/2026-08-21/windows-ffi-upgrade-findings.md` §3
- 本輪全部驗證 artifacts：`scripts/tmp/verify/{w1,w2,w7}/`、`mechanical_checks.txt`
- Runbook（使用者的 Windows 步驟）：`docs/logs/2026-08-21/windows-ffi-build-runbook.md`
