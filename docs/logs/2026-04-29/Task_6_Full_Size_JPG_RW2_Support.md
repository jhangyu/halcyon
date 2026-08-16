---
date: 2026-04-29T00:30:27
task: "6 — 修正 JPG 主圖全尺寸載入與 RW2 支援"
status: success
---

## 🧭 檔案維護政策

**用途**：Unified Task Log，記錄 JPG 主圖全尺寸載入與 RW2 RAW 支援修正的評估、計畫、執行與驗證。

**更新時機**：
- 每次修改程式碼、文件或驗證結果後追加紀錄。
- 中斷點快照需反映最新完成狀態與下一步。

**必填欄位**：`date`、`task`、`status`（YAML frontmatter）、`## 1. Summary`、`## 2. Implementation Plan`、`## 3. Execution Log`、`## 4. Walkthrough`。

---

## 1. Summary

### 使用者回報
1. 開啟內含 JPG 的資料夾時，JPG 大圖區域也會變成只顯示縮圖，而不是全尺寸 JPG。
2. RAW 檔目前似乎只讀取 `.arw`，不讀取 `.rw2`。

### 初步評估
- Flutter `AppState.loadFolder()` 的 `allowedExts` 目前為 `.jpg`, `.jpeg`, `.arw`, `.dng`, `.heic`, `.png`，確實漏列 Panasonic RAW `.rw2`。
- SwiftUI `AppState.loadFolder()` 的 `allowedExts` 也漏列 `rw2`，若維持雙版本功能對齊，應一併補上。
- macOS 原生端 `AppDelegate.swift` 的 RAW 判斷已包含 `.rw2`，但 Flutter 掃描階段漏掉 `.rw2`，導致 `.rw2` 無法進入照片清單。
- Flutter 大圖與側邊欄縮圖都透過 `NativeThumbnailService.getThumbnail()`，差異只靠 `targetSize`（主圖 10000、縮圖 200）。macOS 原生端目前即使處理 JPG，也走 `CGImageSourceCreateThumbnailAtIndex`，需明確讓大圖請求使用足夠大的原圖導出路徑，避免主圖拿到嵌入縮圖或過小縮圖。
- `artifacts/logs/flutter/build_error.log` 顯示 macOS build 目前曾卡在 `AppDelegate.swift` line 69 optional `CGImage?` 未解包；本任務需順手修正，否則無法驗證影像修正。

### 驗收標準
- Flutter 版開啟只有 `.rw2` 的資料夾時，照片可被掃描並出現在側邊欄。
- Flutter 版開啟 JPG 資料夾時，主圖請求使用全尺寸/高解析輸出，不再只顯示 sidebar 等級縮圖。
- SwiftUI 版掃描支援 `rw2`，維持功能矩陣一致。
- macOS build 至少通過 Swift 編譯階段，不再出現 `CGImage?` optional unwrap error。

---

## 2. Implementation Plan

### 修改檔案
1. `lib/providers/app_state.dart`
   - 將 `.rw2` 加入 Flutter 掃描副檔名白名單。
2. `Sources/PhotoSelector/ViewModels/AppState.swift`
   - 將 `rw2` 加入 SwiftUI 掃描副檔名白名單。
3. `macos/Runner/AppDelegate.swift`
   - 修正 RAW embedded thumbnail optional unwrap 編譯錯誤。
   - 將 JPG/PNG/HEIC 等非 RAW 的大圖請求改為優先 `CGImageSourceCreateImageAtIndex`，保留 EXIF 方向轉換後輸出 JPEG bytes。
   - 小尺寸請求仍使用 `CGImageSourceCreateThumbnailAtIndex` 以維持 sidebar 效能。
4. 核心文件
   - 同步更新 `task.md`、`handover.md`、`plan.md`、`memory.md`、`file_index.md`、`unit_test.md`。

### 驗證計畫
1. 執行 `flutter analyze`，確認 Dart 變更無 analyzer error。
2. 執行 `flutter test`，確認既有測試狀態。
3. 執行 `flutter build macos`，確認 macOS 原生端 Swift 可編譯。
4. 若本機無測試照片，將以程式碼路徑與 build 結果驗證；實機視覺確認留待使用者用 JPG/RW2 資料夾覆核。

---

## 3. Execution Log

### ⏹️ 中斷點快照 (Breakpoint Snapshot)
- **已完成**: 已補上 Flutter/SwiftUI `.rw2` 掃描；macOS native handler 已讓非 RAW 主圖請求使用原圖輸出路徑；已修正 Swift build error、Flutter analyzer/test 舊阻塞與 sidebar overflow。
- **下一步**: 使用者可用實際 JPG/RW2 照片資料夾做視覺覆核；專案可回到 Task 1 的 macOS MethodChannel 實機驗證。
- **待確認**: 實機 JPG/RW2 資料夾視覺驗證需使用者本機照片資料確認。

### 2026-04-29T00:30:27+08:00 — 文件同步
- 建立本 Task log，完成 Summary 與 Implementation Plan。
- `task.md` ACTIVE 切換至 Task 6，新增 Task 6 子任務與驗收標準。
- `handover.md` 下一步改為本任務的 4 個立即行動項。
- `memory.md` 新增 G-007（RW2 白名單漏列）與 G-008（JPG 主圖尺寸契約）。
- `plan.md` Phase 2 納入主圖/縮圖尺寸契約與 RW2 支援。
- `file_index.md` 與 README 文件同步支援副檔名加入 `.rw2`。
- `unit_test.md` 新增 TC-009、TC-010 作為後續測試矩陣。

### 2026-04-29T00:45:00+08:00 — 程式修正
- `lib/providers/app_state.dart`：掃描白名單加入 `.rw2`。
- `Sources/PhotoSelector/ViewModels/AppState.swift`：掃描白名單加入 `rw2`。
- `macos/Runner/AppDelegate.swift`：
  - 匯入 `CoreImage`。
  - 非 RAW 且 `targetSize > 4000` 的主圖請求改用 `CGImageSourceCreateImageAtIndex`，並透過 CoreImage 保留 EXIF orientation。
  - 小圖/RAW fallback 保持 `CGImageSourceCreateThumbnailAtIndex` 快速路徑。
  - 新增 `applicationSupportsSecureRestorableState` 解除 Flutter macOS migration 建議訊息。
- `test/widget_test.dart`：替換無效 `MyApp` counter smoke test，改為 `PhotoSelectorApp` 空資料夾畫面 smoke test。
- `lib/views/sidebar_view.dart`：修正預設 sidebar 寬度下頂部工具列 13px overflow。
- `pubspec.yaml`：將 `path` 從 transitive 依賴提升為 direct dependency，解除 analyzer `depend_on_referenced_packages`。
- 另外清理 analyzer 阻塞項：`print` 改 `debugPrint`、移除 unused import/variable、更新 deprecated API、補 flow-control braces。

### 2026-04-29T00:55:00+08:00 — 驗證結果
- `flutter analyze`：通過，`No issues found!`
- `flutter test`：通過，`All tests passed!`
- `flutter build macos`：通過，輸出 `build/macos/Build/Products/Release/halcyon_flutter.app (39.8MB)`

---

## 4. Walkthrough

### 完成項目
- Flutter 與 SwiftUI 版本皆支援掃描 `.rw2` / `rw2`。
- JPG/PNG/HEIC 等非 RAW 檔案在主圖請求（`targetSize=10000`）時會走原圖輸出路徑，不再與 sidebar 200px 縮圖共用同一縮圖分支。
- macOS 原生端 Swift 編譯成功，既有 `CGImage?` optional unwrap build error 已解除。
- 無效 widget test 已更新為可執行 smoke test，並修正 sidebar 頂部 overflow。

### 驗證證明
- `flutter analyze`：0 issues。
- `flutter test`：1 個 widget smoke test 通過。
- `flutter build macos`：成功產生 macOS release app。

### 剩餘事項
- 需使用真實 JPG/RW2 資料夾做視覺覆核，確認主圖顯示符合攝影工作流期待。
