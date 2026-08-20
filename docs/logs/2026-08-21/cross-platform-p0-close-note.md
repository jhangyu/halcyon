# 跨平台 P0 R1 收尾（halcyon-xplat-p0）

契約：`cross-platform-p0-contract.md`（含 R1 修訂）。輪次用 1／3。**尚未 commit**，等使用者裁決。

## 驗收條件逐條

| AC | 內容 | 結果 | 證據 |
|---|---|---|---|
| 1（修訂） | `dng_processor_ffi/pubspec.yaml` 有 `plugin: platforms:`（macos/android，`ffiPlugin: true`）；`dng_processor/pubspec.yaml` **不得**宣告 platforms | PASS | `d1-final-ac1-and-harness.txt`；後者僅剩註解行 44/47 提及 |
| 2（修訂・可否證） | `native/build/` 改名移開時，RED：改動前建置失敗於 embed phase；GREEN：改動後 exit 0 且 bundle 內有 dylib | PASS | `d1-ac2-red.txt:8`（EXIT=1）／`d1-final-build-macos.txt`（EXIT=0）。溯源：bundle 內與 vendored 副本 UUID 同為 `24D734DC-8A4D-3416-A474-09657EA9B423` |
| 3 | MainActivity 只在 `com/example/halcyon/`，package 相符 | PASS | lead 親驗 |
| 4 | `flutter build apk --debug` exit 0 | PASS | `d3-final-apk-noflag.txt`；APK 152MB 實際存在 |
| 5 | thumbnail `MissingPluginException` 測試，須親眼見過紅→綠 | PASS | `d2-before-fix.txt`（真紅）／`d2-after-fix.txt` |
| 6 | `flutter analyze` 0 issues | PASS | 獨立批 `final-battery-2.txt` |
| 7 | `flutter test -j 1` 全綠，宣告數==執行數 | PASS | 獨立批 `final-battery-3.txt`，138/138 |
| 8 | `flutter build macos` exit 0 **＋ 手動開啟後行為與改動前一致** | **部分 PASS** | 建置 PASS（`d3-final-macos.txt`）。**行為比對未做**——見下方缺口 1 |
| 9a（新增） | Windows 本機可查項 | PASS | lead 親驗字串面與 RAW 路由 |
| 9b（新增） | 使用者在自有 Windows 機器上跑 runbook | **未過** | 待使用者 |

## 兩個未閉合的缺口（誠實標註）

**缺口 1：新的 pod 嵌入路徑從未實際解碼過一張 RAW。**
dylib 在 bundle 裡、UUID 對得上、APK 裡的 `.so` 也在，但**沒有任何一次真實解碼**經由新路徑跑過。使用者規則禁止 agent 做 UI 驅動驗證，所以 AC8 後半只有使用者能驗。
這個專案有前例：round 3b 的 sentinel 6/6 觸發、看起來全綠，實際解碼卻被 libjpeg sandbox 擋住（見 memory `image-switch-latency-round3-shipped`）。**「二進位在正確位置」不等於「解碼會成功」。**

**缺口 2：Windows 全部未編譯。** 見契約 AC9b 與 `windows-verification-runbook.md` 的 U0–U11。最高風險 U5：回收站旗標組合未經執行，錯誤後果是永久刪除而非進回收站。

## Parking lot（本輪不處理，待使用者裁決）

1. `app_state_test.dart` TC-049 不穩定測試（`-1` 碰撞後綴）。隔離跑會過、重跑會過、本輪最後兩次全套皆未重現。疑似 fixture 目錄未唯一命名或失敗時未清理。證據：`d1-tc049-flake-note.md`。
2. `dng_processor_ffi/lib/src/dng_bindings.dart:338-346`：iOS 分支是 `DynamicLibrary.process()` 但無任何機制靜態連結該庫（不可行）；Windows/Linux 為無 fallback 的裸單行，與 macOS 的多層 `_openFirst` 不對等。
3. `windows/runner/utils.cpp:48-51` `Utf8FromUtf16`：`WideCharToMultiByte` 失敗回 0 時 `-1` 下溢為 `UINT_MAX`，後續 `> max_size()` 守衛抓不到。純 Flutter 範本既有碼；D5 的 `WM_DROPFILES` 是新的呼叫方。實務風險低（shell 提供的路徑必為合法 UTF-16）。
4. 預編譯二進位**無過期檢查**：有人重建 native 後忘了更新 vendored 副本，宿主 app 會靜默出貨舊二進位。`dngNativeLibraryTag` 可作為未來自動檢查的抓手。
5. 全 repo 尚有 1142 個未追蹤 `AGENTS.md` 樣板檔（本輪只刪了 `android/**/res/` 下擋建置的 10 個）。生成器未找到，本輪期間無新生成。
6. `package:exif` 純 Dart fallback 與原生 EXIF 讀取只驗到程式碼形狀對等，**未驗真實 DNG 檔上的行為對等**。
7. iOS 原生端整體（表一「同 macOS」的說法已被證偽——`AppDelegate.swift:501-502` 的 `NSBitmapImageRep` 是 AppKit-only）。

## 盤點文件的前提稽核結果

三份報告：`premise-audit-channels.md`／`premise-audit-native.md`／`premise-audit-platforms.md`。33 條檢查，4 條 FALSE，全部集中在 dng_processor／原生建置區；Dart 與 channel 層 13/13 全對。

已修正的下游文件：`CLAUDE.md`（補 `ImageRequestPurpose.export` @2048 與其專屬原生分支）。
