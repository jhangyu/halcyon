---
date: 2026-04-29T00:00:00
task: "13 — 專案資料夾結構整理"
status: success
---

## 🧭 檔案維護政策

**用途**：Unified Task Log，記錄專案結構整理、路徑同步與驗證結果。

**更新時機**：新增、搬移、刪除核心資料夾或調整 repo layout 時更新。

**必填欄位**：`date`、`task`、`status`、Summary、Implementation Plan、Execution Log、Walkthrough。

---

## 1. Summary

根目錄原本同時放置核心文件、Flutter app、本機照片樣本、封存 zip、SwiftPM build cache 與圖示來源，閱讀與維護成本偏高。本任務將正式原始碼、本機資料與封存產物分層。

## 2. Implementation Plan

1. 將 Flutter 主線整併到專案根目錄。
2. 將根目錄圖示搬到 `assets/icons/`。
3. 將本機照片樣本搬到 `local_data/photo_samples/` 並保持 git ignored。
4. 將封存 zip 與退役 build cache 搬到 `artifacts/` 並保持 git ignored。
5. 更新所有核心 Markdown 文件與 Task logs 的路徑。
6. 執行 Flutter 測試、分析與 macOS build。

## 3. Execution Log

### ⏹️ 中斷點快照 (Breakpoint Snapshot)
- **已完成**: repo layout 已整理；Markdown 路徑已同步；Flutter 驗證三項通過。
- **下一步**: 回到 Task 12，實作 Trash MethodChannel。
- **待確認**: 若未來需要納入示範照片，需另建小型 fixture，不使用 `local_data/` 的私人照片樣本。

### 2026-04-29
- `photo_selector_flutter/` → 專案根目錄
- `icon.png` / `icon.svg` → `assets/icons/`
- `DNG/` / `JPG/` → `local_data/photo_samples/`
- `PhotoSelector.zip` → `artifacts/archives/`
- `.build/` → `artifacts/build_cache/swiftpm/`
- `.gitignore` 更新以忽略本機資料與封存/build cache。

## 4. Walkthrough

- `flutter test`：11 tests passed。
- `flutter analyze`：0 issues。
- `flutter build macos`：成功產出 release app。
