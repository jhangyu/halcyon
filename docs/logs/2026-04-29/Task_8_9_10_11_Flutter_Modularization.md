---
date: 2026-04-29T00:00:00
task: "8/9/10/11 — Flutter 架構模組化與掃描測試補強"
status: success
---

## 🧭 檔案維護政策

**用途**：Unified Task Log，記錄 Phase 4 相關 Task 8/9/10/11 的集中迭代。

**更新時機**：新增服務、調整 AppState 職責、變更格式 registry 或測試覆蓋時更新。

**必填欄位**：`date`、`task`、`status`、Summary、Implementation Plan、Execution Log、Walkthrough。

---

## 1. Summary

Phase 4 目標是讓 Flutter 主線從大型 `AppState` 收斂為可測、可維護的服務化架構，同時修正影像載入 request 只靠 `targetSize` 推斷用途的風險。

## 2. Implementation Plan

1. 建立 `ImageRequestPurpose`，讓 preview/sidebar thumbnail 以語意傳遞至 native bridge。
2. 建立 `SupportedPhotoFormats` registry，集中副檔名與載入優先順序。
3. 建立 `PhotoLibraryScanner`、`PhotoStatusStore`、`ImagePreloadController`、`PhotoFileActions`。
4. 調整 `AppState` 只協調 UI 狀態與服務呼叫。
5. 補上掃描、狀態、格式與 request purpose 測試。

## 3. Execution Log

### ⏹️ 中斷點快照 (Breakpoint Snapshot)
- **已完成**: Task 8/9/10/11 完成；Phase 4 檢查清單全部打勾。
- **下一步**: Phase 5 Task 12，將 `deleteTrashed()` 改為 Trash MethodChannel。
- **待確認**: 真實照片資料夾視覺覆核仍建議補做。

### 2026-04-29
- 新增 `lib/models/supported_photo_formats.dart`。
- 新增 `lib/services/photo_library_scanner.dart`、`photo_status_store.dart`、`image_preload_controller.dart`、`photo_file_actions.dart`。
- `AppState` 改為透過服務處理掃描、狀態、預載/cache、檔案操作。
- macOS `AppDelegate.swift` 改讀 `purpose` 參數，preview request 走主圖/高解析邏輯。

## 4. Walkthrough

- `flutter analyze`：0 issues。
- `flutter test`：11 tests passed。
- `flutter build macos`：成功產出 `build/macos/Build/Products/Release/photo_selector_flutter.app`。
