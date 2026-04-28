---
date: 2026-04-29
title: "Photo Selector — 全域知識庫與避坑指南 (Memory)"
---

## 🧭 檔案維護政策

**用途**：存放長期有效的架構決策、踩坑紀錄 (Gotchas) 與技術債說明。作為 AI 跨對話斷點的上下文橋接。

**更新時機**：
- 每輪對話結束前必更新。
- 發現新 Gotcha 或做出架構決策時立即同步，**不得等到對話結束**。

**必填欄位**：`date`（YYYY-MM-DD，反映最後有效更新）、`title`、本文內容。

**跨檔同步對象**：`task.md`（ACTIVE 狀態同步）、`plan.md`（里程碑層級同步）。

---

## 架構決策紀錄 (Architecture Decisions)

### AD-001｜滑動視窗預載策略（Sliding Window Preload）
- **日期**：2026-04-29
- **決策**：圖片與縮圖皆採用滑動視窗（sliding window）預載策略。
  - 大圖（Image Cache）：current ± 3~5 張，視窗外圖片立即驅逐。
  - 側邊欄縮圖（Thumb Cache）：current ± 20 張，100ms 防抖（debounce）保護。
- **依據**：避免一次全量載入造成 OOM，同時保持流暢瀏覽體驗。
- **Flutter**：`_preloadImages()`（AppState） + `preloadThumbnails()`（AppState）。
- **SwiftUI**：已退役；此策略後續只維護 Flutter 主線。

### AD-002｜RAW 檔案優先載入策略
- **日期**：2026-04-29
- **決策**：同一张照片群組（base name 相同）有多個副檔名時，優先載入 JPG/HEIC，RAW（ARW/RW2/DNG）作為降級。
- **Flutter**：`PhotoItem.bestFileToLoad`（`.photo_item.dart`）。
- **SwiftUI**：已退役；後續只維護 Flutter `PhotoItem.bestFileToLoad`。
- **依據**：JPG 提取更快、更省記憶體，RAW 需要完整解碼才能得到 Preview。

### AD-003｜Flutter 主線 + Native Bridge，SwiftUI 退役
- **日期**：2026-04-29
- **決策**：專案主線收斂為 Flutter app（專案根目錄）+ macOS/iOS native bridge；SwiftUI macOS 原型（`Sources/PhotoSelector/`）自 Task 7 起退役並刪除。
- **依據**：Flutter 版本已承接主要 UI、狀態、縮圖/主圖載入與設定；SwiftUI 版本未被主線引用且功能落後，持續維護會造成格式支援、文件與測試矩陣雙軌同步成本。
- **注意**：後續不要新增 SwiftUI 對齊任務；平台原生能力應優先透過 Flutter Runner 的 MethodChannel 實作。

### AD-004｜狀態持久化格式
- **日期**：2026-04-29
- **決策**：使用 `.photo_selector_status.json` 存放於當前資料夾，格式為 `{ photoId: "starred"|"trashed"|"unmarked", _last_viewed_id: "..." }`。
- **Flutter**：讀寫由 `AppState._saveStatusCache()` / `_saveLastViewedId()` 管理。
- **SwiftUI**：已退役，不再補建持久化。
- **依據**：不需要資料庫，JSON 檔直接放在照片目錄中方便遷移與版本控制。

### AD-005｜AppState 協調層化
- **日期**：2026-04-29
- **決策**：Flutter 主線將 `AppState` 收斂為 UI 狀態協調層；資料夾掃描、狀態 JSON、影像預載/cache、檔案 copy/move/delete 分別交由 `PhotoLibraryScanner`、`PhotoStatusStore`、`ImagePreloadController`、`PhotoFileActions`。
- **依據**：Phase 4 模組化目標要求核心流程可測，避免 `AppState` 持續膨脹。
- **驗證**：`flutter test` 11 個測試通過；`flutter analyze` 0 issues；`flutter build macos` 成功。

### AD-006｜專案根目錄分層
- **日期**：2026-04-29
- **決策**：正式 Flutter app 放在專案根目錄；專案層級圖示放在 `assets/icons/`；本機照片樣本放在 `local_data/photo_samples/` 並忽略；封存與退役 build cache 放在 `artifacts/` 並忽略。
- **保留**：`rule.md`、`memory.md`、`task.md`、`handover.md`、`plan.md`、`file_index.md`、`unit_test.md`、`README.md` 維持根目錄入口，符合 Startup Protocol。
- **驗證**：搬移後 `flutter test`、`flutter analyze`、`flutter build macos` 皆通過。

---

## Gotchas（踩坑紀錄）

### G-001｜側邊欄 Scroll Debounce
- **嚴重程度**：中
- **問題**：快速滾動側邊欄時，會觸發大量 `preloadThumbnails` 請求導致 Isolate 阻塞。
- **解法**：使用 100ms debounce timer（`Timer(const Duration(milliseconds: 100))`）緩衝請求。
- **驗證**：已在 `AppState.preloadThumbnails()` 中確認實作。

### G-002｜已退役 SwiftUI NSScrollView 滾動門檻值
- **嚴重程度**：低
- **問題**：已退役 SwiftUI 原型曾有 `ZoomableImageView` 觸控板誤觸問題。
- **解法**：不再維護 SwiftUI 原型；Flutter 主線另以 `InteractiveViewer` 管理縮放。
- **狀態**：已關閉（退役）。

### G-003｜SwiftUI 版本缺少狀態持久化
- **嚴重程度**：高
- **問題**：`Sources/PhotoSelector/` SwiftUI 版本目前無 `UserDefaults` 或 JSON 持久化，關閉後狀態全失。
- **解法**：已由 Task 7 決策退役 SwiftUI package，不再補建。Flutter JSON 狀態檔為唯一主線。
- **狀態**：已關閉（退役）。

### G-004｜Flutter NativeThumbnailService MethodChannel 未實作 macOS
- **嚴重程度**：高
- **問題**：`lib/services/native_thumbnail_service.dart` 定義了 MethodChannel，但 macOS 原生端（`macos/Runner/AppDelegate.swift`）曾缺少實作。
- **解法**：已在 `macos/Runner/AppDelegate.swift` 建立 `FlutterMethodChannel` handler，並改為 `ImageRequestPurpose.preview` / `sidebarThumbnail` 語意化分流。
- **狀態**：已修復（Task 1 / Task 8）。`flutter analyze` / `flutter test` / `flutter build macos` 通過。

### G-005｜Auto-advance 與 Status Toggle 邏輯
- **嚴重程度**：中
- **問題**：`markCurrent()` 中，若 `item.status == status`（即標記相同狀態），會 Toggle 回 `unmarked`；若 `autoAdvance` 為 true，**不論是否 Toggle**，都會前進。
- **預期行為澄清**：Toggle off 時不應前進，但目前實作會前進。
- **待使用者確認**：是否修正行為邏輯。

### G-006｜exFAT / 網路磁碟 AppleDouble 副作用
- **嚴重程度**：低
- **問題**：在 exFAT 或網路磁碟上操作時，macOS 會自動產生 `._<filename>` AppleDouble 側寫檔，可能殘留於目的地。
- **解法**：在 `processStarred()` 中主動偵測並刪除 `.<basename>` 側寫檔（Flutter 版本已實作）。

### G-007｜Panasonic RW2 掃描白名單漏列
- **嚴重程度**：高
- **問題**：Flutter 資料夾掃描白名單曾漏列 Panasonic RAW `.rw2`，因此 `.rw2` 在進入 native decoder 前就被排除。Task 6 當時也同步處理了尚未退役的 SwiftUI 原型。
- **解法**：在 Flutter `AppState.loadFolder()` 補上 `.rw2`。
- **狀態**：已修復（Task 6）。已通過 `flutter analyze` / `flutter test` / `flutter build macos`，實機 RW2 視覺覆核待使用者以真實資料夾確認。

### G-008｜JPG 主圖請求不可退化為 sidebar 縮圖
- **嚴重程度**：高
- **問題**：Flutter 主圖與 sidebar 縮圖共用 `NativeThumbnailService.getThumbnail()`，只靠 `targetSize` 區分；若 macOS 原生端對 JPG 大圖請求仍走縮圖路徑，主圖可能只顯示小尺寸 preview。
- **解法**：macOS 原生端需根據 `targetSize` 分流：小圖保留 `CGImageSourceCreateThumbnailAtIndex`，主圖/高解析請求優先使用原圖輸出並保留方向修正。
- **狀態**：已修復（Task 6）。非 RAW 且 `targetSize > 4000` 的請求改用 `CGImageSourceCreateImageAtIndex` + CoreImage orientation 修正；實機 JPG 視覺覆核待使用者確認。

---

## 技術債 (Tech Debt)

| ID | 項目 | 優先順序 | 備註 |
|----|------|----------|------|
| TD-001 | SwiftUI 版本狀態持久化 | 已關閉 | Task 7 退役 SwiftUI，不再實作 |
| TD-002 | Flutter macOS 原生 MethodChannel | 已關閉 | Task 1 / Task 8 已完成 |
| TD-003 | 側邊欄縮圖尺寸 / 載入優先順序優化 | 中 | 可根據視窗大小動態調整 targetSize |
| TD-004 | 刪除操作移到垃圾桶而非永久刪除 | 中 | Flutter `file.delete()` 目前為 unlink |
| TD-005 | `widget_test.dart` 為預設範本，未反映實際 App | 低 | 需替換為有意義的 smoke test |
| TD-006 | JPG 主圖與縮圖共用 native API 需明確尺寸契約 | 高 | Task 6 修正 macOS 分流 |
| TD-007 | AppState 職責過大 | 已關閉 | Task 9 已拆分掃描、狀態、快取、檔案操作 |
| TD-008 | 支援格式定義分散 | 已關閉 | Task 10 已建立 `SupportedPhotoFormats` registry |

---

## 重要約定

1. **JSON 狀態檔**：放在照片目錄根目錄，命名為 `.photo_selector_status.json`，以 `.` 開頭確保隱藏。
2. **側邊欄寬度**：預設 270px，可拖曳調整（最小 180px，最大 600px）。
3. **縮圖目標尺寸**：側邊欄 200px，主圖 10000px（Full Resolution 預覽）；native 端需依 targetSize 分流避免主圖退化為縮圖。
4. **鍵盤快捷鍵**（Flutter）：
   - `←` / `→`：上一張 / 下一張
   - `↑` / `↓`：放大 / 縮小
   - `S`：標記星號
   - `X`：標記刪除
