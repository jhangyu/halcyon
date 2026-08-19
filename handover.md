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

**本輪（2026-08-19）｜唯讀資料夾警告 + StatusLine（commit `123727b`）**

已落地：
- `PhotoStatusStore.isWritable(Directory)`：建立再刪除 `.halcyon_write_probe` 探測資料夾可寫性（exFAT `noowners` 掛載下權限位不可靠，唯讀掛載如 SD 卡防寫鎖只能實測）。
- `AppState.loadFolder()` 偵測到資料夾唯讀時，透過新增的 `StatusMessage` / `showStatus()` / `status` / `statusSeq` 推送一次警告，文字中 `*…*` 標示重點字。
- 新增 `lib/views/status_line.dart`（`StatusLine` widget）取代 SnackBar：2.5s 全不透明 → 0.5s 淡出 → 3.0s 移除；反相對比配色，emphasis span 為隨底色翻轉的琥珀色。
- `lib/views/batch_delete_feedback.dart` 的批次刪除成功訊息改走 status line；失敗仍為阻斷式 `AlertDialog`。
- 補上先前已被 import 卻未被 commit 的 `lib/services/trash_service.dart`（乾淨 checkout 之前無法建置）。
- `flutter test`：84 個測試通過（exit code 0），新增/重寫 `test/status_line_test.dart`、`test/batch_delete_feedback_test.dart`、`test/app_state_test.dart`、`test/sidebar_view_test.dart`。

**注意（本檔上一版遺留缺口）**：本檔在 2026-05-05 到 2026-08-19 間未持續更新，期間主線已完成回收模式（`.trash` 批次刪除）、DNG 全尺寸解碼整合（`flutter_dng_decoder`）、影像切換延遲多輪優化（tier-1/tier-2 sliding preload）、Finder「開啟方式」冷啟動等功能（詳見 `git log --oneline`），這些內容尚未逐條補回 `task.md` / `plan.md` 的 Phase 矩陣與 Task 清單，屬於既有文件落差，非本輪交付範圍。

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

**已確認完成、原列於此處的舊項目**：Task 12（Trash MethodChannel，`flutter test` 已通過含 trash 案例）、Task 15（`test/photo_file_actions_test.dart` 已存在於 `git ls-files`）。以下為本次同步時仍待辦或需人工核實的項目：

1. **`task.md` / `plan.md` 回溯同步**（高，文件債）：`task.md` 的 ACTIVE 區塊與 Task 16/17/19/20 狀態自 2026-05-05 起未更新，且回收模式、DNG 解碼整合、影像切換延遲多輪優化等主線工作完全未登錄為 Task；下一輪應派工逐一核對樹上事實後補登，而非直接信任本檔舊記載。
2. **Task 20 — sidebar iconColor Quick Win**（低）：`sidebar_view.dart` iconColor 重複邏輯是否已在後續回收模式改動中處理，需重新核實現狀再排入。
3. **Task 19 — Zoom 狀態下沉**（中）：`main_detail_view.dart` 反向寫入 AppState 欄位（G-010）是否仍存在，需重新核實現狀再排入。
4. **G-005（Auto-advance Toggle off 行為）**：`test/app_state_test.dart` 尚無 toggle-off 不前進的測試案例（見 `unit_test.md` TC-014），仍待與使用者確認預期行為。

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
- 狀態訊息一律走 `AppState.showStatus()` + `StatusLine`，不再使用 SnackBar
- `flutter test` 最新一次全套執行結果：84 個測試通過（exit code 0）
