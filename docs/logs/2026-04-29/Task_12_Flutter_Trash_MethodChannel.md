---
date: 2026-04-29T00:00:00
task: "12 — Flutter Trash MethodChannel"
status: in_progress
---

## 🧭 檔案維護政策

**用途**：Unified Task Log，記錄 Task 12 的 Trash MethodChannel 後續開發。

**更新時機**：開始實作 Trash service、native handler、測試或手動驗證時更新。

**必填欄位**：`date`、`task`、`status`、Summary、Implementation Plan、Execution Log、Walkthrough。

---

## 1. Summary

Phase 2/3/4 已完成，下一個高風險功能是將 `PhotoFileActions.deleteTrashed()` 從永久刪除改為 macOS Trash，避免不可逆刪除照片。

## 2. Implementation Plan

1. 建立 Flutter `TrashService` / MethodChannel contract。
2. 在 macOS Runner 實作移到 Trash 的 native handler。
3. 將 `PhotoFileActions.deleteTrashed()` 改為呼叫 Trash service，失敗時不清除原狀態。
4. 補上測試或手動驗證紀錄，更新 `unit_test.md`。

## 3. Execution Log

### ⏹️ 中斷點快照 (Breakpoint Snapshot)
- **已完成**: 尚未開始實作；已建立 Task 12 log 作為下一輪入口。
- **下一步**: 設計 Trash MethodChannel contract。
- **待確認**: 是否只支援 macOS Trash，或同步規劃 iOS/其他平台 fallback。

## 4. Walkthrough

（任務完成後填寫）
