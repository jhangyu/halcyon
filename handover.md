---
date: 2026-08-19
title: "Halcyon — 短期交接摘要 (Handover)"
---

## 🧭 檔案維護政策

**用途**：記錄當前衝刺最重要的中斷點、已完成項目、下一步。作為 AI 快速恢復上下文的第一入口。

**更新時機**：
- 每次 Task 階段結束或主動中斷對話前。
- 完成任何 `下一步` 中的子步驟後同步更新。

**必填欄位**：`date`（YYYY-MM-DD）、`title`、`下一步`（僅保留 3-5 個可立即執行項）。

**跨檔同步對象**：
- `task.md` 的 ACTIVE 區塊須與 `下一步` 一致。
- Bug 結案後長期知識移入 `memory.md`。

---

## 當前任務

**本輪（2026-08-19）｜Sidebar 縮圖預載改為 itemBuilder 驅動（commit `d0eb855`）**

已落地：
- `SidebarView` 移除 `ScrollController` scroll listener，改由 `ListView.builder` 的 `itemBuilder` 逐格回報建置到的 index，一幀結束後彙整成「純可視範圍」呼叫 `AppState.preloadThumbnails()`。修正的 bug：回收/刪除/複製/移動觸發 `loadFolder()` 重載資料夾、清空縮圖快取後，捲動離開頂端的清單只靠 scroll listener 觸發重新請求，結果持續空白直到使用者再次捲動。
- `ImagePreloadController` 接手 prefetch margin（新常數 `thumbnailPrefetchMargin = 20`），請求順序改為「可視列優先 → 視窗邊緣向外交錯」；新增 `_thumbBatchGeneration` 計數器，過期批次（快速捲動、資料夾重載）在下一次 await 前自我中止。
- `sidebar_view.dart` 選取列背景改用 `ListTile.selectedTileColor`，外層容器由 `Container` 改為 `Material`，消除 framework 的 ListTile 背景色/ink splash 斷言警告。
- `flutter test`：85 個測試通過（exit code 0），新增 `test/sidebar_view_test.dart` 的「every visible row is requested again after a folder reload」迴歸測試；`flutter analyze lib test`：0 issues。

**上一輪（2026-08-19）｜唯讀資料夾警告 + StatusLine（commit `123727b`）**：`PhotoStatusStore.isWritable(Directory)` 探測可寫性、`AppState` 新增 `StatusMessage`/`showStatus()`、`lib/views/status_line.dart` 取代 SnackBar、批次刪除成功訊息改走 status line、補上先前未 commit 的 `lib/services/trash_service.dart`。

**文件債狀態**：`task.md` / `plan.md` 在本輪已補回 2026-05-05 至今主線完成的回收模式（`.trash` 批次刪除，Task 25）、DNG 全尺寸解碼整合（Task 22）、影像切換延遲 tier-1/tier-2 sliding preload（Task 23）、Finder「開啟方式」冷啟動（Task 24），逐條登錄並附 commit hash 證據，文件債已清償。

---

## 已完成項目

- **Flutter 專案初始化**：完整的 `main_screen.dart` + `sidebar_view.dart` + `main_detail_view.dart` + `settings_dialog.dart`
- **AppState 核心邏輯**：`loadFolder`、`selectItem`、`markCurrent`、`processStarred`、`deleteTrashed`、雙層 LRU Cache（圖片 + 縮圖）
- **NativeThumbnailService MethodChannel 定義**：`lib/services/native_thumbnail_service.dart`（Flutter 端）
- **滑動視窗預載策略**：大圖 ±3~5，縮圖 ±20，100ms debounce
- **SwiftUI 版本基礎實作**：曾作為早期原型存在；Task 7 起退役，不再作為待辦主線
- **Phase 0 完成**：所有核心文件補建完成（rule.md, memory.md, task.md, handover.md, plan.md, file_index.md, unit_test.md, README.md）
- **Task 6 完成**：Flutter/SwiftUI `.rw2` 掃描支援、macOS JPG 主圖高解析載入分流、Swift build error 修正、widget smoke test 修正；`flutter analyze` / `flutter test` / `flutter build macos` 皆通過。
- **Task 7 完成**：刪除 `Sources/PhotoSelector/` 與根目錄 `Package.swift`；文件改為 Flutter 主線；Task 8~12 已登錄；`flutter analyze` / `flutter test` / `flutter build macos` 皆通過。
- **Phase 2/3/4 完成**：Task 1 / 3 / 8 / 9 / 10 / 11 已完成；新增 `SupportedPhotoFormats`、`PhotoLibraryScanner`、`PhotoStatusStore`、`ImagePreloadController`、`PhotoFileActions`；`flutter analyze` / `flutter test`（11 tests）/ `flutter build macos` 皆通過。
- **Task 13 完成**：專案結構整理完成；Flutter app 整併至專案根目錄，圖示移至 `assets/icons/`，本機資料與封存產物分別移至 `local_data/`、`artifacts/` 並維持 git ignored。
- **Task 14 完成**：Android toolchain 升級完成；Gradle 9.1.0 + AGP 9.0.1 + Kotlin 2.3.21 相容模式可在 Temurin JDK 25 下成功產出 `build/app/outputs/flutter-apk/app-release.apk`。
- **Task 12 完成（自動化驗證通過）**：新增 `lib/services/trash_service.dart`、macOS `halcyon/trash` MethodChannel handler，`PhotoFileActions.deleteTrashed()` 已改用 Trash service；新增 `test/photo_file_actions_test.dart` 覆蓋 trash 成功與失敗保留原檔。
- **Task 22 完成**：DNG 全尺寸解碼整合（`dng_processor` package，`lib/services/dng_decode_contract.dart` / `dng_decode_service.dart` / `decoded_rgba_image_provider.dart`）。
- **Task 23 完成**：影像切換延遲 tier-1/tier-2 sliding preload（`lib/services/image_preload_controller.dart`，22 個測試覆蓋）。
- **Task 24 完成**：Finder「開啟方式」冷啟動（`lib/services/open_with_channel.dart`，macOS 已實作，Windows/Android 未實作）。
- **Task 25 完成**：回收模式（`.trash`）批次刪除（`PhotoFileActions.recycleTrashed()`，同名 sibling 自動分組、碰撞附加後綴、失敗清單回報）。
- **Task 26 完成**：Sidebar 縮圖預載改由 `itemBuilder` 驅動，取代 scroll listener（詳見本檔「當前任務」）。

---

## 下一步

**已確認完成、原列於此處的舊項目**：Task 12（Trash MethodChannel，`flutter test` 已通過含 trash 案例）、Task 15（`test/photo_file_actions_test.dart` 已存在於 `git ls-files`）。以下為本次同步時仍待辦或需人工核實的項目：

1. **`task.md` / `plan.md` 回溯同步** — ✅ 已於 2026-08-19 本輪完成：Task 22~26（DNG 解碼整合、tier-1/tier-2 preload、Finder 開啟方式、回收模式、sidebar itemBuilder 預載）已逐條登錄並附 commit hash 證據。
2. **Task 20 — sidebar iconColor Quick Win**（低）：`sidebar_view.dart` iconColor 重複邏輯是否已在後續回收模式改動中處理，需重新核實現狀再排入。
3. **Task 19 — Zoom 狀態下沉**（中）：`main_detail_view.dart` 反向寫入 AppState 欄位（G-010）是否仍存在，需重新核實現狀再排入。
4. **G-005（Auto-advance Toggle off 行為）**：行為已核實正確（`app_state.dart:337-351`），不需使用者確認；`test/app_state_test.dart` 仍缺對應 regression test（`unit_test.md` TC-014）。

---

## 決策摘要

| 編號 | 決策內容 | 依據 |
|------|----------|------|
| AD-001 | 滑動視窗預載策略（±3~5 大圖，±20 縮圖）| 記憶體 / 速度平衡 |
| AD-002 | 優先載入 JPG/HEIC，RAW 降級 | 效能考量 |
| AD-003 | Flutter 主線 + Native Bridge，SwiftUI 退役 | 降低雙軌同步成本 |
| AD-004 | JSON 格式狀態持久化（`.halcyon_status.json`）| 簡單遷移、無需資料庫 |
| AD-005 | AppState 協調層化 | 核心流程可測、降低維護成本 |
| AD-006 | 專案根目錄分層 | 正式程式碼、本機資料、封存產物分離 |
| AD-007 | Android JDK 25 toolchain | Gradle 9.1.0 + AGP 9.0.1 相容模式可支援 Temurin JDK 25 |
| AD-008 | Trash 操作透過 macOS `halcyon/trash` MethodChannel | 避免不可逆刪除 |
| AD-009 | StatusLine 取代 SnackBar；`isWritable()` 以 create+delete 探測可寫性 | SnackBar 淡出時間不可調；exFAT 權限位不可信 |
| AD-010 | DNG 全尺寸解碼整合 `dng_processor` package | 無內嵌預覽的 DNG 需要真正 RAW 解碼，而非降級縮圖 |
| AD-011 | 影像切換 tier-1/tier-2 sliding preload | 單層預載不足以兼顧不卡頓與記憶體安全 |
| AD-012 | Finder 開啟方式走 push-only MethodChannel | 冷啟動時 Dart 詢問原生端會輸掉與 engine 初始化的競速 |
| AD-013 | 回收模式（`.trash`）sibling 分組、碰撞附加後綴 | 同 volume rename 瞬時可用；批次失敗需個別回報不中斷整批 |
| AD-014 | Sidebar 縮圖預載改由 `itemBuilder` 驅動，取代 scroll listener | `ListView.builder` 重建即免費重算可視範圍，資料夾重載後自我修復 |

---

## 待確認事項

- ~~**G-005（Auto-advance Toggle 行為）**~~ — ✅ 已於 2026-08-19 對照 `app_state.dart:337-351` 核實：toggle off 已不前進，不需使用者確認。剩餘缺口是測試覆蓋，見 `task.md` Task 16、`unit_test.md` TC-014。
- ~~**Task 15 測試策略**~~ — ✅ 已由既成事實回答：`test/photo_file_actions_test.dart` 全檔皆用 `dart:io` 操作真實 temp 目錄（`Directory.systemTemp.createTemp()`），未使用抽象 FileSystem 介面，且此模式已延續到後續所有資料操作測試（回收模式、trash）。視為既定方向，不再是開放問題。
- **Task 19 鍵盤縮放銜接**：`main_screen.dart:99,102` 目前呼叫 `state.stepZoomIn()` / `state.stepZoomOut()`（定義於 `app_state.dart:298-334`），zoom 邏輯移出 AppState 後需要新的觸發路徑（callback / GlobalKey）。**這是產品/架構決策，不是可從樹上驗證的事實**——實作前需確認偏好方式。
- **Task 20 色值統一**：`sidebar_view.dart:150` header title color（`32,32,32`）是否應對齊其餘 4 處的 icon/text color（`59,59,59`，見 `sidebar_view.dart:197,266-268,287-289,322-324`）？或兩者本應有差異需保留？**這是視覺設計意圖判斷，不是可從樹上驗證的事實**——留給使用者裁決。

---

## 上下文提醒

- Flutter 專案路徑：`/Users/jhangyu/project/Halcyon/`
- Android toolchain：Gradle 9.1.0、AGP 9.0.1、Kotlin 2.3.21 相容模式，JDK 優先使用 Temurin 25
- 核心狀態管理：`AppState`（Flutter 協調層；掃描、狀態、預載/cache、檔案操作已拆至服務）
- JSON 狀態檔案：`.halcyon_status.json`（放在照片目錄根目錄）
- 支援副檔名：`jpg`、`jpeg`、`arw`、`rw2`、`dng`、`heic`、`png`
- 狀態訊息一律走 `AppState.showStatus()` + `StatusLine`，不再使用 SnackBar
- 側邊欄縮圖預載觸發來源：`ListView.builder` 的 `itemBuilder`（不再是 scroll listener），prefetch margin 由 `ImagePreloadController.thumbnailPrefetchMargin` 決定
- `flutter test` 最新一次全套執行結果：85 個測試通過（exit code 0，2026-08-19，commit `d0eb855`）；`flutter analyze lib test`：0 issues
