---
date: 2026-04-29
title: "Photo Selector — 中長期里程碑與路線圖 (Plan)"
---

## 🧭 檔案維護政策

**用途**：紀錄高階目標與各 Phase 進度，不作為即時進度看板。

**更新時機**：
- 每個 Phase 完成後。
- 重大目標或里程碑變更時。
- 每輪對話結束前同步檢查。

**必填欄位**：`date`（YYYY-MM-DD）、`title`、Phase 狀態矩陣。

**跨檔同步對象**：
- `task.md` 的 Task 狀態應與 Phase 矩陣一致。
- `memory.md` 只保留里程碑層級摘要。

---

## 專案願景

一個高效的 RAW/JPG 照片快速分類工具。主線採 Flutter app，搭配 macOS/iOS native bridge 處理平台原生能力。支援星號標記、刪除分類，並一鍵複製/移動已標記照片到指定資料夾。核心特點：

- **滑動視窗預載**：永不 OOM，永不卡頓。
- **原生縮圖支援**：macOS/iOS 直接解 RAW，不需完整解碼。
- **Flutter 主線**：UI、狀態與跨平台流程集中維護；平台能力透過 native MethodChannel 擴充。

---

## Phase 矩陣

| Phase | 名稱 | 狀態 | 主要交付物 |
|-------|------|------|-----------|
| 0 | 環境初始化與規則建立 | ✅ 已完成 | `rule.md`、7 大核心文件（本次）|
| 1 | 基礎版本可运行 | ✅ 已完成 | Flutter 基礎 UI、縮圖載入、狀態標記 |
| 2 | Flutter macOS 原生整合 | ✅ 已完成 | macOS MethodChannel 實作、語意化影像 request contract |
| 3 | 單元測試覆蓋 | ✅ 已完成 | `app_state_test.dart`、`photo_item_test.dart`、widget smoke test |
| 4 | Flutter 架構模組化 | ✅ 已完成 | AppState 拆分、影像 request contract、格式 registry |
| 5 | 生產力增強 | 🔲 待辦 | Trash 操作、CLI 工具、CI/CD |
| 6 | 影像載入相容性修正 | ✅ 已完成 | JPG 主圖高解析載入、RW2 掃描支援 |
| 7 | Flutter 主線整理 | ✅ 已完成 | SwiftUI 退役、文件與任務收斂 |
| 8 | 專案結構整理 | ✅ 已完成 | `apps/`、`assets/`、`artifacts/`、`local_data/` 分層 |

---

## Phase 0 — 環境初始化 ✅ 已完成

**時間**：2026-04-29

**交付物**：
- `rule.md`：開發標準作業程序與 Unified Task Log 規範
- `memory.md`：全域知識庫與 Gotchas
- `task.md`：任務狀態看板（含 ACTIVE 區塊）
- `handover.md`：短期交接摘要
- `plan.md`：本檔
- `file_index.md`：專案檔案地圖
- `unit_test.md`：測試策略與成功標準
- `README.md`：專案入口文件

**關鍵決策**：
- 採用 Unified Task Log（日誌置於 `docs/logs/YYYY-MM-DD/`）
- 核心文件皆以 YAML frontmatter + `## 🧭 檔案維護政策` 開頭

---

## Phase 1 — 基礎版本可运行 ✅ 已完成

**時間**：2026-04-29 前

**交付物**：
- `apps/photo_selector_flutter/app/`：Flutter 跨平台版本（含 AppState、MainScreen、SidebarView、MainDetailView、SettingsDialog）
- 支援副檔名：JPG, JPEG, ARW, DNG, HEIC, PNG
- 鍵盤快捷鍵：← →（導航）、↑ ↓（縮放）、S（星號）、X（刪除）
- 側邊欄可拖曳調整（180px–600px）
- macOS Day/Night Theme 完整對應

**驗證結果**：
- Flutter 版本可執行（macOS 原生 MethodChannel 已可編譯，待實機照片資料夾視覺驗證）

---

## Phase 2 — Flutter macOS 原生整合 ✅ 已完成

**目標**：在 Flutter macOS Runner 中實作原生縮圖提取 MethodChannel handler，解除縮圖依賴，並修正主圖/縮圖尺寸契約。

**主要交付物**：
- `macos/Runner/AppDelegate.swift`：含 `FlutterMethodChannel` handler
- `NativeThumbnailService` 在 macOS 上完整可用
- JPG 主圖請求回傳高解析/全尺寸輸出，sidebar 請求維持 200px 縮圖
- Flutter 支援 `.rw2` RAW 掃描

**子任務**（詳見 `task.md` Task 1）：
1. 建立 `macos/Runner/AppDelegate.swift` handler
2. 參考 `ios/Runner/AppDelegate.swift` 既有實作
3. 驗證 `flutter run -d macos` 縮圖正常
4. Task 6：修正 JPG 主圖高解析載入與 RW2 支援

**Task 6 驗證結果**：
- `flutter analyze`：0 issues
- `flutter test`：通過 1 個 widget smoke test
- `flutter build macos`：成功產出 release app
- 待使用者以真實 JPG/RW2 資料夾做視覺覆核

**完成結果**：Task 1 / Task 8 已完成；macOS bridge 以 `purpose` 分流 preview 與 sidebar thumbnail；`flutter analyze` / `flutter test` / `flutter build macos` 通過。

---

## Phase 3 — 單元測試覆蓋 ✅ 已完成

**目標**：建立有意義的自動化測試，確保核心邏輯不被破壞。

**主要交付物**：
- `test/app_state_test.dart`：AppState 單元測試（5+ 案例）
- `test/photo_item_test.dart`：PhotoItem 邏輯測試
- 更新 `test/widget_test.dart`：有意義的 smoke test
- `unit_test.md` 測試矩陣完整

**測試覆蓋目標**：

| 模組 | 覆蓋類型 | 目標案例數 |
|------|----------|-----------|
| AppState | 單元測試 | 5 |
| PhotoItem | 單元測試 | 3 |
| MainScreen | Widget Test | 2 |

**完成結果**：`flutter test` 11 個測試通過（exit code = 0）。

---

## Phase 4 — Flutter 架構模組化 ✅ 已完成

**目標**：降低 Flutter 主線維護成本，將影像載入、檔案掃描、狀態持久化與檔案操作拆成可測服務。

**主要交付物**：
- `ImageRequestPurpose` 或等價 request contract：區分 sidebar thumbnail 與 preview/full-size image
- `PhotoLibraryScanner`：集中掃描與分組邏輯
- `PhotoStatusStore`：集中 JSON 狀態讀寫
- `ImagePreloadController`：集中主圖/縮圖 cache 與 sliding window
- `PhotoFileActions`：集中 copy/move/trash 檔案操作
- `SupportedPhotoFormats` registry：集中副檔名與優先順序

**拆分檢查清單**：
- [x] Native image request contract 不再只靠 `targetSize` 判斷用途
- [x] `AppState` 不直接負責資料夾掃描細節
- [x] `AppState` 不直接負責 JSON 讀寫細節
- [x] `AppState` 不直接負責檔案 copy/move/delete 細節
- [x] 檔案格式新增時只需更新 registry 與測試

---

## Phase 7 — Flutter 主線整理 ✅ 已完成

**目標**：退役未被主線引用的 SwiftUI package，移除雙軌同步成本，將後續開發集中在 Flutter app + native bridge。

**主要交付物**：
- 移除 `Sources/PhotoSelector/`
- 移除根目錄 `Package.swift`
- 核心文件、README、測試矩陣移除 SwiftUI 主線待辦
- 新增架構改善任務：Task 8~12

**決策依據**：
- SwiftUI 版本功能落後 Flutter，缺少持久化、設定與行為對齊。
- Flutter macOS native bridge 已可編譯，主線已能承接原生縮圖/預覽能力。
- 雙軌維護會持續造成支援格式、測試矩陣、文件與功能狀態不同步。

**驗證結果**：
- `flutter analyze`：0 issues
- `flutter test`：通過 1 個 widget smoke test
- `flutter build macos`：成功產出 release app

---

## Phase 5 — 生產力增強 🔲 待辦

**目標**：提升工具可用性與長期維護性。

**交付物**：
- Trash 操作（取代永久刪除）
- CLI 工具：`scripts/batch_tag.dart`（批次標記腳本）
- 效能分析：記憶體使用報告
- CI/CD：GitHub Actions 自動化測試腳本

---

## Phase 8 — 專案結構整理 ✅ 已完成

**目標**：整理根目錄與正式程式碼位置，讓開發入口、應用程式、本機資料、封存產物與文件各自有清楚責任。

**完成結果**：
- Flutter 主線移至 `apps/photo_selector_flutter/app/`
- 專案層級圖示移至 `assets/icons/`
- 本機照片樣本移至 `local_data/photo_samples/` 並由 `.gitignore` 排除
- 封存 zip 與退役 build cache 移至 `artifacts/` 並由 `.gitignore` 排除
- 核心 SOP 文件維持在根目錄，避免破壞 Startup Protocol

**驗證結果**：
- `flutter test`：11 tests passed
- `flutter analyze`：0 issues
- `flutter build macos`：成功

---

## 路線圖總覽

```
Phase 0 ✅ ─────────────────────────────────────── 2026-04-29
  └── Phase 1 ✅
        └── Phase 2 ✅
              └── Phase 7 ✅
                    └── Phase 3 ✅
                          └── Phase 4 ✅
                                └── Phase 8 ✅
                                      └── Phase 5 🔲 ←───── 下一個焦點
```

---

## 成功標準

| 標準 | 描述 |
|------|------|
| 功能完整性 | 所有 Phase 交付物完成並驗證 |
| 測試覆蓋 | Phase 3 完成後，`flutter test` 至少 5 個案例通過 |
| 架構可維護性 | Phase 4 完成後，AppState 職責拆分且核心服務可測 |
| 效能目標 | 滑動視窗記憶體峰值 < 500MB（含 8K 原圖）|
