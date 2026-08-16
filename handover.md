---
date: 2026-05-05
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

**Task 12｜Flutter Trash MethodChannel**（實作完成，待驗證）

技術債評估（2026-05-04）與架構健康審查（2026-05-04）已完成：
- Phase 10 技術債清償計畫已制定（Task 15–20）
- 新識別：G-010（`main_detail_view.dart` 反向寫入 AppState 欄位）、TD-014（`sidebar_view.dart` 重複 iconColor）
- Task 19 目標從「提取 ZoomState provider」調整為「zoom 狀態下沉至 View 層」（更簡單且正確的修法）

當前執行優先序：Task 12 驗證 → Task 15 → Task 20（Quick Win）→ Task 16 → Task 19。

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
- **Task 12 實作完成（待驗證）**：新增 `lib/services/trash_service.dart`、macOS `halcyon/trash` MethodChannel handler，`PhotoFileActions.deleteTrashed()` 已改用 Trash service；新增 `test/photo_file_actions_test.dart` 覆蓋 trash 成功與失敗保留原檔。

---

## 下一步

1. **Task 12 — Trash MethodChannel 驗證**（Phase 5，緊急）：在具備 Flutter SDK 的 macOS 環境執行 `flutter analyze` / `flutter test` / `flutter build macos`，並用真實照片資料夾確認檔案移入 Trash。
2. **Task 15 — PhotoFileActions 測試**（Phase 5，高）：Task 12 完成後立即補 `test/photo_file_actions_test.dart`，覆蓋 copy/move/trash 三條路徑的成功與失敗情境（目標 5+ 案例）。
3. **Task 20 — sidebar iconColor Quick Win**（Phase 10，低，30 分鐘內完成）：提取 `_iconColor()` helper，消除 `sidebar_view.dart` 三處重複並統一色值。
4. **Task 19 — Zoom 狀態下沉**（Phase 10，中）：將 `app_state.dart:67-73` 的 zoom 欄位還給 `_MainDetailViewState`，消除 `main_detail_view.dart:94/177/181/184` 四處反向 setter。

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

---

## 待確認事項

- **G-005（Auto-advance Toggle 行為）**：`markCurrent()` 在 Toggle off 時是否應前進？Task 16 執行前需使用者確認。
- **Task 15 測試策略**：`PhotoFileActions` 測試應使用 `dart:io` 操作真實 temp 目錄（避免 mock 與實際行為脫鉤），還是需要抽象 FileSystem 介面？建議前者，與 unit_test.md 排查方向一致。
- **Task 19 鍵盤縮放銜接**：zoom 邏輯移出 AppState 後，`main_screen.dart` 的 `↑` / `↓` 鍵盤縮放需要一個新的觸發路徑（callback / GlobalKey）。實作前需確認偏好方式。
- **Task 20 色值統一**：`sidebar_view.dart:114-117` title color（`32,32,32`）是否應對齊 icon color（`59,59,59`）？或兩者本應有差異需保留？

---

## 上下文提醒

- Flutter 專案路徑：`/Users/jhangyu/project/Halcyon/`
- Android toolchain：Gradle 9.1.0、AGP 9.0.1、Kotlin 2.3.21 相容模式，JDK 優先使用 Temurin 25
- 核心狀態管理：`AppState`（Flutter 協調層；掃描、狀態、預載/cache、檔案操作已拆至服務）
- JSON 狀態檔案：`.halcyon_status.json`（放在照片目錄根目錄）
- 支援副檔名：`jpg`、`jpeg`、`arw`、`rw2`、`dng`、`heic`、`png`
