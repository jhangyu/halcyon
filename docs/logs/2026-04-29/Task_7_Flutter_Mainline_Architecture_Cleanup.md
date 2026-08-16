---
date: 2026-04-29T00:51:00
task: "7 — Flutter 主線架構整理與 SwiftUI 退役"
status: success
---

## 🧭 檔案維護政策

**用途**：Unified Task Log，記錄架構改善建議落地、SwiftUI 去留評估、文件同步與驗證結果。

**更新時機**：
- 每次修改核心文件、刪除/移動專案檔案、完成驗證後追加紀錄。
- 中斷點快照需反映最新完成狀態與下一步。

**必填欄位**：`date`、`task`、`status`（YAML frontmatter）、`## 1. Summary`、`## 2. Implementation Plan`、`## 3. Execution Log`、`## 4. Walkthrough`。

---

## 1. Summary

### 目標
將前一輪架構改善建議寫入下階段任務與路線圖，並評估 SwiftUI 版本是否仍有必要維護。

### 評估結論
- 目前主要可執行與已驗證的主線是專案根目錄，包含 macOS 原生 MethodChannel、Flutter UI、狀態持久化、縮圖與主圖預載。
- SwiftUI 版本位於 `Sources/PhotoSelector/`，由根目錄 `Package.swift` 打包；它沒有被 Flutter 主線引用，也沒有作為 native bridge 的來源。
- SwiftUI 版本功能已落後 Flutter：缺少 JSON 狀態持久化、設定 UI、auto-advance / overwrite-existing 對齊，並在文件中形成 Task 2 / Task 4 的長期雙軌維護壓力。
- 對目前產品目標而言，保留 SwiftUI 版本的收益低於同步成本。建議退役 SwiftUI，將專案定位收斂為 Flutter app + macOS/iOS native bridge。

### 架構改善方向
1. 拆清影像載入契約：將 thumbnail 與 preview/full-size request 語意化，避免只靠 `targetSize` 推斷用途。
2. 拆分 Flutter `AppState`：掃描、狀態儲存、影像快取、檔案操作分離成可測服務。
3. 建立檔案掃描與 `PhotoItem` 單元測試：覆蓋 `.rw2`、AppleDouble、RAW/JPG 分組、best file priority。
4. 統一支援格式定義：避免 Flutter、native、文件各自維護副檔名清單。
5. 推進 Trash MethodChannel：把永久刪除改為移到垃圾桶。

---

## 2. Implementation Plan

### 文件更新
1. `task.md`
   - ACTIVE 切換至 Task 7。
   - 將 SwiftUI Task 2 / Task 4 標記為退役或移除待辦壓力。
   - 新增後續 Task 8~12：影像 request contract、AppState 拆分、格式 registry、測試覆蓋、Trash MethodChannel。
2. `plan.md`
   - 專案願景改為 Flutter 主線 + native bridge。
   - Phase 4 從 SwiftUI 功能對齊改為架構模組化。
3. `memory.md`
   - 更新 AD-003：不再雙平台並行維護，SwiftUI 版本退役。
   - 補充架構決策與 gotcha。
4. `file_index.md`
   - 移除 `Sources/PhotoSelector/` 與根目錄 `Package.swift` 索引。
5. `unit_test.md`
   - Feature Matrix 改為 Flutter 主線；移除 SwiftUI 欄位與 Swift 測試指令。
6. `handover.md` / README
   - 同步下一步與專案定位。

### 檔案刪除
1. 刪除 `Sources/PhotoSelector/`。
2. 刪除根目錄 `Package.swift`。

### 驗證
1. `flutter analyze`
2. `flutter test`
3. `flutter build macos`
4. `rg` 確認核心文件不再把 SwiftUI 當成待辦主線。

---

## 3. Execution Log

### ⏹️ 中斷點快照 (Breakpoint Snapshot)
- **已完成**: 評估 SwiftUI 版本未被 Flutter 主線引用且維護成本高於收益；建立 Task 7 log 與實作計畫；核心文件已切換為 Flutter 主線定位；已刪除 `Sources/PhotoSelector/` 與根目錄 `Package.swift`；Flutter 驗證三項通過。
- **下一步**: 回到 Task 1 實機視覺驗證；接著可依序推進 Task 8~12 架構改善。
- **待確認**: 刪除後若未來需要原生 SwiftUI app，需從歷史備份或重新建立。

### 2026-04-29T00:51:00+08:00 — 文件計畫與退役決策
- 建立 Task 7 Unified Task Log。
- `task.md` ACTIVE 切換至 Task 7。
- `plan.md` 專案願景改為 Flutter 主線 + native bridge，Phase 4 改為 Flutter 架構模組化。
- `memory.md` 更新 AD-003，明確退役 SwiftUI 並關閉 SwiftUI 持久化 gotcha。
- `unit_test.md` Feature Matrix 改為 Flutter 主線，不再追蹤 SwiftUI 欄位。
- README 與 `file_index.md` 移除 SwiftUI 主線說明。

### 2026-04-29T00:55:00+08:00 — SwiftUI package 刪除
- 刪除 `Sources/PhotoSelector/`。
- 刪除根目錄 `Package.swift`。
- 使用 `rg` 檢查殘留引用，保留歷史 Task log 中的 SwiftUI 記錄，核心文件只保留退役說明。

### 2026-04-29T01:05:00+08:00 — 驗證結果
- `flutter analyze`：通過，`No issues found!`
- `flutter test`：通過，`All tests passed!`
- `flutter build macos`：通過，輸出 `build/macos/Build/Products/Release/halcyon_flutter.app (39.8MB)`

---

## 4. Walkthrough

### 完成項目
- 專案定位收斂為 Flutter app + macOS/iOS native bridge。
- SwiftUI package 已退役並刪除：`Sources/PhotoSelector/`、根目錄 `Package.swift`。
- Task 2 / Task 4 由 SwiftUI 待辦改為退役關閉。
- 新增後續架構改善任務：Task 8（影像 request contract）、Task 9（AppState 拆分）、Task 10（格式 registry）、Task 11（掃描/PhotoItem 測試）、Task 12（Trash MethodChannel）。
- `plan.md` Phase 4 改為 Flutter 架構模組化，新增 Phase 7 退役整理。

### 驗證證明
- `flutter analyze`：0 issues。
- `flutter test`：1 個 widget smoke test 通過。
- `flutter build macos`：成功產生 macOS release app。

### 剩餘事項
- Task 1 仍需使用真實 RAW/JPG/RW2 資料夾做視覺驗證。
- 未來若重新需要 SwiftUI 原生 app，需另開新任務重新建立，不再沿用已退役路徑。
