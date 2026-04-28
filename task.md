---
date: 2026-04-29
title: "Photo Selector — 任務真實狀態來源 (Task)"
---

## 🧭 檔案維護政策

**用途**：管理所有任務清單與執行狀態，是「現在要做什麼」與「做到哪裡」的唯一真實來源。

**更新時機**：
- 每次切換 ACTIVE 任務時。
- 每個 Task 完成或階段性推進後。
- 發現子任務完成後，應同步更新摘要。

**必填欄位**：`date`（YYYY-MM-DD）、`title`、頂部 `🔴 現在進行中 (ACTIVE)` 區塊。

**跨檔同步對象**：
- `handover.md` 的 `下一步` 需與 ACTIVE Task 一致。
- `memory.md` 的 Gotchas / 架構決策需同步更新。
- `plan.md` 的對應 Phase 狀態需同步更新。

---

## 🔴 現在進行中 (ACTIVE)

- **Task**: 12 — Flutter Trash MethodChannel
- **Log File**: [Task_12_Flutter_Trash_MethodChannel.md](docs/logs/2026-04-29/Task_12_Flutter_Trash_MethodChannel.md)
- **中斷點與交接 (Handover)**: Phase 2/3/4 與 Task 13 專案結構整理皆已完成；Flutter app 目前位於 `apps/photo_selector_flutter/app/`，本機資料與封存產物已分離到 ignored 目錄。`flutter analyze` / `flutter test` / `flutter build macos` 皆通過。
- **下一個子步驟**: 進入 Phase 5，將 `deleteTrashed()` 從永久刪除改為 macOS Trash MethodChannel。

---

## 任務清單

### Task 1｜Flutter macOS 原生 MethodChannel 實作 ✅ 已完成

**目標**：在 Flutter macOS Runner 中建立原生縮圖提取 MethodChannel handler，使 `NativeThumbnailService.getThumbnail()` 在 macOS 上可用。

**子任務**：
- [x] 1.1 建立 `macos/Runner/AppDelegate.swift` 中的 `FlutterMethodChannel` handler（含 CGImageSource thumbnail 邏輯）
- [x] 1.2 參考 `ios/Runner/AppDelegate.swift` 中既有實作，確保 `targetSize` 參數正確傳遞
- [x] 1.3 驗證：`flutter analyze` / `flutter test` / `flutter build macos` 通過；request purpose 測試覆蓋 sidebar 200px 與 preview 10000px 分流
- [x] 1.4 更新 `memory.md` 的 G-004 為「已修復」

**驗收標準**：macOS native bridge 可編譯；Flutter request contract 以明確 purpose 區分 sidebar thumbnail 與 preview；`flutter analyze` / `flutter test` / `flutter build macos` 皆通過。真實照片資料夾視覺覆核仍建議由使用者在本機資料夾補做。

---

### Task 2｜SwiftUI 版本狀態持久化實作 🗑️ 已退役

**退役原因**：SwiftUI 版本不再作為主線產品維護；專案收斂為 Flutter app + macOS/iOS native bridge。原持久化需求由 Flutter JSON 狀態機制承接。

**狀態**：已由 Task 7 關閉，未實作子任務不再追蹤。

---

### Task 3｜Flutter 單元測試覆蓋 ✅ 已完成

**目標**：建立有意義的單元測試與 widget test，取代預設 `widget_test.dart` smoke test。

**子任務**：
- [x] 3.1 建立 `test/app_state_test.dart`：測試 `AppState`（詳見 `unit_test.md` TC-001 ~ TC-004 / TC-009 / request purpose）
- [x] 3.2 建立 `test/photo_item_test.dart`：測試 `PhotoItem.bestFileToLoad` 與格式 registry
- [x] 3.3 更新 `test/widget_test.dart`：保留有效 empty-folder smoke test
- [x] 3.4 執行 `flutter test` 確認全部通過

**驗收標準**：`flutter test` 全部通過；目前 11 個測試通過。

---

### Task 4｜SwiftUI 版本功能對齊 🗑️ 已退役

**退役原因**：SwiftUI 版本不再作為主線產品維護；避免持續雙軌同步 auto-advance、overwrite-existing、Settings UI 與 markCurrent 行為。

**狀態**：已由 Task 7 關閉，未實作子任務不再追蹤。

---

### Task 5｜刪除操作改為 Trash 而非永久刪除 🔲 待辦

**目標**：將 Flutter `AppState.deleteTrashed()` 從 `file.delete()`（永久刪除）改為移到垃圾桶。

**子任務**：
- [ ] 5.1 評估方案：使用 Swift FFI 或等待 `file_selector` 支援 `trash`（詳見 `memory.md` TD-004）
- [ ] 5.2 若需要 Native Plugin，評估建立 `trash_service.dart` + MethodChannel
- [ ] 5.3 更新 `memory.md` TD-004 狀態

**驗收標準**：刪除檔案進入 macOS 垃圾桶而非永久消失。

---

### Task 6｜修正 JPG 主圖全尺寸載入與 RW2 支援 ✅ 已完成

**目標**：修正 Flutter 版開啟 JPG 資料夾時主圖只顯示縮圖的問題，並讓 Flutter/SwiftUI 掃描流程支援 Panasonic RAW `.rw2`。

**子任務**：
- [x] 6.1 在 Flutter `AppState.loadFolder()` 支援 `.rw2`
- [x] 6.2 在 SwiftUI `AppState.loadFolder()` 支援 `rw2`
- [x] 6.3 調整 macOS `AppDelegate.swift`：非 RAW 主圖請求使用高解析/全尺寸輸出，小圖請求保留縮圖路徑
- [x] 6.4 修正 `AppDelegate.swift` 既有 `CGImage?` optional unwrap 編譯錯誤
- [x] 6.5 驗證：`flutter analyze`、`flutter test`、`flutter build macos`

**驗收標準**：`.rw2` 可被掃描進照片清單；JPG 主圖以主圖 targetSize（10000）取得高解析輸出，不再退化成 sidebar 縮圖；macOS build 不再出現 `CGImage?` optional unwrap error。

**驗證結果**：`flutter analyze` 0 issues；`flutter test` 全通過；`flutter build macos` 成功產出 release app。實機 JPG/RW2 視覺覆核仍需使用者以真實照片資料夾確認。

---

### Task 7｜Flutter 主線架構整理與 SwiftUI 退役 ✅ 已完成

**目標**：將專案定位收斂為 Flutter app + macOS/iOS native bridge，退役未被主線引用且功能落後的 SwiftUI package，並登錄下一階段架構改善任務。

**子任務**：
- [x] 7.1 更新 `task.md` / `plan.md` / `memory.md` / `handover.md` 的專案定位
- [x] 7.2 更新 `file_index.md` / `unit_test.md` / README，移除 SwiftUI 主線引用
- [x] 7.3 刪除 `Sources/PhotoSelector/` 與根目錄 `Package.swift`
- [x] 7.4 新增後續架構改善任務（Task 8~12）
- [x] 7.5 驗證：`flutter analyze`、`flutter test`、`flutter build macos`

**驗收標準**：SwiftUI package 不再存在於專案檔案地圖；核心文件不再把 SwiftUI 功能對齊列為待辦；Flutter 驗證三項通過。

**驗證結果**：`flutter analyze` 0 issues；`flutter test` 全通過；`flutter build macos` 成功產出 release app。

---

### Task 8｜影像載入 Request Contract 語意化 ✅ 已完成

**目標**：將 `NativeThumbnailService.getThumbnail()` 的用途從單一 `targetSize` 推斷，改為明確 request purpose（sidebar thumbnail / preview image），降低主圖退化為縮圖的風險。

**驗收標準**：Flutter 與 macOS native bridge 以 `ImageRequestPurpose.preview` / `sidebarThumbnail` 明確表示載入用途；AppState 測試覆蓋 preview 與 sidebar request。

---

### Task 9｜拆分 Flutter AppState 職責 ✅ 已完成

**目標**：將掃描、狀態持久化、影像快取/預載、檔案操作從 `AppState` 拆出成可測服務，讓 `AppState` 只負責協調 UI 狀態。

**驗收標準**：已建立 `PhotoLibraryScanner`、`PhotoStatusStore`、`ImagePreloadController`、`PhotoFileActions`；核心流程測試不依賴完整 UI。

---

### Task 10｜支援格式 Registry 統一化 ✅ 已完成

**目標**：集中定義支援副檔名與優先順序，避免 Flutter 掃描、`PhotoItem.bestFileToLoad`、native RAW 判斷與文件不同步。

**驗收標準**：Flutter 端支援格式由 `SupportedPhotoFormats` 定義；掃描與 `PhotoItem.bestFileToLoad` 共同使用 registry；測試覆蓋 `.rw2`。

---

### Task 11｜檔案掃描與 PhotoItem 單元測試補強 ✅ 已完成

**目標**：補上 `.rw2`、AppleDouble、隱藏檔、RAW/JPG 分組、best file priority 等低成本高價值測試。

**驗收標準**：`flutter test` 新增掃描/狀態/PhotoItem/registry/request purpose 測試，覆蓋 `unit_test.md` TC-001、TC-002、TC-004、TC-005、TC-006、TC-009。

---

### Task 12｜Flutter Trash MethodChannel 🔲 待辦

**目標**：將 Flutter `deleteTrashed()` 從永久刪除改為 macOS Trash，避免不可逆刪除照片。

**驗收標準**：已標記 trashed 的檔案移入 macOS Trash；失敗時保留錯誤訊息且不清除狀態；測試或手動驗證記錄於 Task log。

### Task 13｜專案資料夾結構整理 ✅ 已完成

**目標**：整理根目錄與 Flutter app 位置，讓正式程式碼、本機資料、封存產物與文件責任更清楚。

**子任務**：
- [x] 13.1 將 Flutter 主線移至 `apps/photo_selector_flutter/app/`
- [x] 13.2 將專案層級圖示移至 `assets/icons/`
- [x] 13.3 將本機照片樣本移至 `local_data/photo_samples/`（git ignored）
- [x] 13.4 將封存與退役 build cache 移至 `artifacts/`（git ignored）
- [x] 13.5 更新 `README.md`、`file_index.md`、`handover.md`、`plan.md`、`memory.md`、`unit_test.md` 與 Task logs 中的路徑
- [x] 13.6 驗證 `flutter test`、`flutter analyze`、`flutter build macos`

**驗收標準**：根目錄只保留核心入口文件與清楚分類的一級目錄；Flutter app 可在新路徑完成測試、分析與 macOS build。

---

## 已完成摘要

### Phase 1 以前（含 Phase 1）
- SwiftUI macOS 版本曾作為早期原型存在，Task 7 起退役並收斂為 Flutter 主線
- Flutter 專案初始化與核心 UI（Scaffold / Sidebar / Detail View）
- 縮圖滑動視窗預載機制
- 狀態標記（星號/刪除）與快速鍵
- RAW 檔案群組與最佳化載入邏輯
- macOS Day/Night Theme 完整對應

> 若已完成事項超過 2 個迭代，請將摘要沉澱至 `memory.md` 或 `plan.md`。

---

## 測試統計

| 指標 | 數值 |
|------|------|
| 現有測試數 | 11 |
| 目標測試數 | 5+ |
| 已通過測試數 | 11 |
| 測試覆蓋策略 | 詳見 `unit_test.md` |
