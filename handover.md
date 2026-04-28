---
date: 2026-04-29
title: "Photo Selector — 短期交接摘要 (Handover)"
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

**Task 12｜Flutter Trash MethodChannel**（🔲 待辦）

Phase 2/3/4 與 Task 13 專案結構整理已完成：Flutter app 目前位於專案根目錄，macOS MethodChannel 已語意化，Flutter 測試 11 個全數通過，AppState 已拆成掃描、狀態、預載/cache、檔案操作服務。下一步進入 Phase 5，優先做 Trash MethodChannel，避免照片永久刪除。

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

---

## 下一步

1. **建立 Trash MethodChannel contract**：Flutter `TrashService` 與 macOS Runner handler。
2. **將 `PhotoFileActions.deleteTrashed()` 改為移到垃圾桶**：失敗時保留原檔與狀態。
3. **補測試或手動驗證紀錄**：至少覆蓋服務 contract 與錯誤處理。
4. **更新 `unit_test.md` / Task 12 log**：登錄 Trash 行為與成功標準。

---

## 決策摘要

| 編號 | 決策內容 | 依據 |
|------|----------|------|
| AD-001 | 滑動視窗預載策略（±3~5 大圖，±20 縮圖）| 記憶體 / 速度平衡 |
| AD-002 | 優先載入 JPG/HEIC，RAW 降級 | 效能考量 |
| AD-003 | Flutter 主線 + Native Bridge，SwiftUI 退役 | 降低雙軌同步成本 |
| AD-004 | JSON 格式狀態持久化（`.photo_selector_status.json`）| 簡單遷移、無需資料庫 |
| AD-005 | AppState 協調層化 | 核心流程可測、降低維護成本 |
| AD-006 | 專案根目錄分層 | 正式程式碼、本機資料、封存產物分離 |

---

## 待確認事項

- **G-005（Auto-advance Toggle 行為）**：`markCurrent()` 在 Toggle off 時是否應前進？需要使用者確認預期行為。
- **TD-004（永久刪除 → Trash）**：是否緊急需要？目前可延後處理。
- **SwiftUI 版本未來走向**：已決策退役；若未來需要原生 SwiftUI app，需另開新任務重新建立。

---

## 上下文提醒

- Flutter 專案路徑：`/Users/jhangyu/Documents/Photo_Selector/`
- 核心狀態管理：`AppState`（Flutter 協調層；掃描、狀態、預載/cache、檔案操作已拆至服務）
- JSON 狀態檔案：`.photo_selector_status.json`（放在照片目錄根目錄）
- 支援副檔名：`jpg`、`jpeg`、`arw`、`rw2`、`dng`、`heic`、`png`
