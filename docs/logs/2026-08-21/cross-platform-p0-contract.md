# 收斂契約：跨平台 P0（共通層）

日期：2026-08-21　來源：`docs/logs/2026-08-20/cross-platform-port-inventory.md`
使用者裁決：(1) 目標＝Windows 優先＋全平台共通 P0；(2) dng_processor 上游可改、做 plugin 化；
(3) **這輪只做能在 macOS 上機械驗證的項目**——Windows / iOS 原生端不寫。

## 終態（一句話）

Halcyon 的原生依賴不再靠開發機絕對路徑，Android 能編譯出 debug APK，缺原生 channel 的平台會顯示錯誤而不是丟 uncaught async error，且 macOS 現有功能零回歸。

## In-scope 交付物

| ID | 交付物 | 檔案邊界（所有權互斥） |
|---|---|---|
| D1 | `dng_processor` 改造成真正的 Flutter plugin：`pubspec.yaml` 加 `flutter: plugin: platforms:`，補 macOS podspec / Android gradle+CMake build hook，使原生庫由 build 系統打包，不再依賴 `DNG_DEV_FALLBACK` 絕對路徑 | `../flutter_dng_decoder/dng_processor/**`（獨立 repo，與 Halcyon 樹無交集） |
| D2 | `halcyon/thumbnail` 補 `MissingPluginException` 降級：回傳 `NativeImageFailure`，不再讓 `image_preload_controller.dart:728` rethrow 成 uncaught async error | `lib/services/native_thumbnail_service.dart`、`test/**` 新增測試檔 |
| D3 | Android 編譯修復：`MainActivity.kt` 由 `com/example/photo_selector_flutter/` 移到 `com/example/halcyon/` 並改 package 宣告 | `android/**` |
| D4 | 整合驗證（lead 簽收） | 不改碼 |

## Out-of-scope（明確不做）

- ~~Windows / iOS 的任何原生端實作（WIC、IFileOperation、Swift 複用）~~
  **[2026-08-21 R1 修訂 / 使用者批准]** Windows 已改為 **in-scope**（見修訂紀錄 (ii) 與交付物 D5）：WIC 縮圖、`IFileOperation` 回收站、Open With 皆已實作。**iOS 原生端仍為 out-of-scope。** 上方「使用者裁決 (3)」那句「Windows / iOS 原生端不寫」同此修訂，僅 iOS 仍成立。
  Windows 的 RAW/DNG 解碼**維持 out-of-scope 且不可達**——稽核證實 `dng_processor/native/` 沒有任何 Windows 建置路徑（零 CMake preset、`CMakeLists.txt` 無 WIN32 分支、`windows/CMakeLists.txt` 不引用 `native/`）。Windows 版本出貨時無 RAW 支援。
- Android SAF / iOS security-scoped bookmark 存取模型
- 行動端觸控分揀 UI
- DNG 預覽抽取改寫成 Dart（P2）
- Linux
- `ThumbnailLoader` 的 Dart `image` package fallback 實作（本輪只做降級不崩，不做替代解碼）

**out-of-scope 可達性檢查**：以上每一項若永不落地，本輪終態仍可達。

## 驗收條件（逐條機械檢查）

1. ~~`grep -A6 '^flutter:' ../flutter_dng_decoder/dng_processor/pubspec.yaml` 含 `plugin:` 與 `platforms:` 區塊。~~
   **[2026-08-21 修正 / 使用者批准]** 改為：`grep -A6 '^flutter:' ../flutter_dng_decoder/dng_processor_ffi/pubspec.yaml` 含 `plugin:` 與 `platforms:`（macos + android，`ffiPlugin: true`）。
   路徑改變原因：採用選項 B，新開 `dng_processor_ffi/` plugin package，`dng_processor` 以 path dependency 引用。**不得**在 `dng_processor/pubspec.yaml` 宣告 platforms——那會把 app-style 的 `dng_processor/android/`（`include(":app")`、`evaluationDependsOn(":app")`）拖進 Halcyon 的 Gradle graph 並弄壞 D3。
2. ~~在未設 `DNG_DEV_FALLBACK` 的環境下，Halcyon macOS release build 產物內含 `libdng_decoder_native.dylib`。~~
   **【本條原版無鑑別力，已作廢】** 撰寫時未查 `macos/Runner.xcodeproj/project.pbxproj:339-355`，該處早有一個 "Embed DNG Native Dylib" run-script phase 從 sibling repo 的 `native/build/` 複製 dylib 進 Frameworks 並重簽名。實測未改動的樹上本條就是綠的（`scripts/tmp/verify/d1-ac2-before-*.txt`）。真正的缺陷不是「沒被打包」，而是「打包硬性依賴建置機上存在另一個 repo 的 CMake build 目錄」。
   **[2026-08-21 修正 / 使用者批准]** 改為可否證版本：將 `../flutter_dng_decoder/dng_processor/native/build/` 暫時改名移開、且 `DNG_DEV_FALLBACK`/`DNG_NATIVE_BUILD_DIR` 皆未設時——
   - RED（改動前）：`flutter build macos --debug` 應在該 run-script phase 失敗。
   - GREEN（改動後）：`flutter build macos --debug` exit 0，且 `Halcyon.app/Contents/Frameworks/` 仍含 `libdng_decoder_native.dylib`（來源為 pod）。
   驗畢須把 `native/build/` 改名還原並驗證還原成功——那是上游團隊的活建置樹。
3. `find android/app/src/main -name MainActivity.kt` 只回傳 `com/example/halcyon/MainActivity.kt`，且檔內 `package com.example.halcyon`。
4. `flutter build apk --debug` exit code 0。
5. 新增測試：thumbnail channel 丟 `MissingPluginException` 時，`requestImage` 回傳 `NativeImageFailure` 而非拋出。該測試須被親眼看過**先紅後綠**（留證）。
6. `flutter analyze` 0 issues（忽略 `scripts/tmp/` 噪音）。
7. `flutter test -j 1` 全綠，且宣告測試數 == 執行數。
8. `flutter build macos` exit code 0，macOS app 手動開啟後縮圖與 RAW 解碼行為與改動前一致（lead 抽查）。

9. **[2026-08-21 R1 新增 / 使用者批准]** Windows（D5）——本機無法編譯驗證，故驗收分兩段：
   - **9a（本機可查，已過）**：`windows/runner/` 內三個 channel 已註冊；channel 名／method 名／arg key 與 Dart 端逐字相符；RAW 輸入落到 `NativeImageFailure` 而非 `NativeImageNeedsRawDecode`；`flutter analyze` 0 issues；`docs/logs/2026-08-21/windows-verification-runbook.md` 存在且含 U0–U11 未驗證清單。
   - **9b（僅使用者可驗，未過）**：使用者在自有 Windows 機器上執行該 runbook。**在 9b 完成前，D5 一律記為「已交付、未驗收」，不得計入完成。** 最高風險項為 U5（回收站旗標組合未經執行，旗標錯誤的後果是永久刪除而非進回收站）。

## 輪次預算

3 輪。用盡而驗收未全過 → 停下回報失敗軌跡，不自行開第 4 輪。

## Parking lot

（輪中新發現一律記於此，不進本輪、不升級為驗收條件；收尾一次呈報使用者裁決）

- 盤點文件稱 `dng_bindings.dart:339` 是「寫死路徑」，實測該分支已由 `DNG_DEV_FALLBACK` env gate 保護。
- **Android RAW 為 arm64-device-only**：上游只有 arm64 `.so`，x86_64 模擬器拿不到原生庫。已知限制，非缺陷。
- 全 repo 1152 個未追蹤 `AGENTS.md` 樣板檔（內容為 CLAUDE.md 的複製）。其中 10 個位於 `android/app/src/main/res/**`，會讓 Android resource merger 直接 fail（`res/**` 只准 `.xml`/`.png`）。已於本輪刪除該 10 個；生成器未找到，且全 repo 無任何一個 mtime 新於 2026-08-20，研判為過去批次產物而非持續生成。剩餘 1142 個未處理。
- macOS 目前用 SPM 管 4 個 plugin，`Podfile.lock` 只有 FlutterMacOS。引入 CocoaPods-based plugin 會改動 `Podfile.lock`（可能連帶 pbxproj）。

## 契約修訂紀錄

- **2026-08-21 R1**：AC1 路徑改為 `dng_processor_ffi/pubspec.yaml`（採選項 B）；AC2 整條重寫為可否證版本（原版無鑑別力，見上）。授權 D1 刪除 Halcyon `macos/Runner.xcodeproj/project.pbxproj` 的 "Embed DNG Native Dylib" phase，並 commit 預編譯二進位進上游 `dng_processor_ffi/`。三項均經使用者批准。
- **2026-08-21 R1**：使用者追加兩件 in-scope 工作——(i) 派獨立 team 重新查證盤點文件 `docs/logs/2026-08-20/cross-platform-port-inventory.md` 的所有前提（該文件已證實至少兩處有誤）；(ii) 開 Windows build team，交付未經本機編譯驗證的程式碼，由使用者在自有 Windows 機器上驗收。
