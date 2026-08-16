---
date: 2026-05-05T09:42:08
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
- **已完成**: Flutter `TrashService` contract、macOS `halcyon/trash` handler、`PhotoFileActions.deleteTrashed()` Trash service 串接、trash 成功/失敗 Dart 測試草案。
- **下一步**: 在非沙盒終端機執行 `flutter test --no-pub` / `flutter build macos --release --no-pub`，並手動驗證真實照片進入 Trash。
- **待確認**: 是否需要在 iOS/Windows/Linux 補平台 fallback；目前 contract 在非 macOS 會以 `MissingPluginException` 失敗並保留原檔。

### 2026-05-05 — Implementation

- 新增 `lib/services/trash_service.dart`：
  - `MethodChannel('halcyon/trash')`
  - `trashFile(File file)` 呼叫 native `trashFile` method
  - 將 `PlatformException` / `MissingPluginException` 包成 `TrashException` 往上拋，避免靜默永久刪除或錯誤清狀態
- 修改 `lib/services/photo_file_actions.dart`：
  - 新增 `TrashFile` typedef 與 constructor injection
  - `deleteTrashed()` 改用 `_trashFile(file)`，不再呼叫 `file.delete()`
  - AppleDouble sidecar 若存在也走 trash service
- 修改 `macos/Runner/AppDelegate.swift`：
  - 新增 `FlutterMethodChannel(name: "halcyon/trash")`
  - `trashFile` method 檢查 path 與存在性後呼叫 `FileManager.default.trashItem`
  - 失敗回傳 `FlutterError(code: "TRASH_FAILED")`
- 新增 `test/photo_file_actions_test.dart`：
  - trash 成功：只處理 trashed item，且 sidecar 一併進入 trash callback
  - trash 失敗：callback 拋錯時來源檔仍存在

### 2026-05-05 — Verification

- `dart format lib/services/trash_service.dart lib/services/photo_file_actions.dart test/photo_file_actions_test.dart`：未執行成功，容器回報 `/bin/bash: line 1: dart: command not found`
- `flutter test`：未執行成功，容器回報 `/bin/bash: line 1: flutter: command not found`
- `scripts/build.sh` 已檢查，仍依賴 PATH 中的 `flutter`；目前環境無法完成 `flutter analyze` / `flutter test` / `flutter build macos`

### 2026-05-05 09:42 — Sandbox Verification

- 找到 Flutter SDK：`/Users/jhangyu/project/flutter/bin/flutter`，因沙盒不可寫 SDK cache，改複製到 `/tmp/halcyon_flutter_sdk` 執行。
- `flutter pub get --offline`：✅ 通過（使用 `/tmp/halcyon_pub_cache`）。
- `dart format --set-exit-if-changed lib test`：⚠️ 發現格式差異並已套用格式化。
- `flutter analyze --no-pub`：✅ 通過，`No issues found!`。
- `flutter test --no-pub`：⚠️ 未能進入測試斷言；test runner 載入階段被沙盒禁止建立 `127.0.0.1:0` server socket，所有 test file 均回報 `Failed to create server socket (OS Error: Operation not permitted)`。
- `flutter build macos --release --no-pub`：
  - 使用 `/tmp` HOME 時，CocoaPods 因網路受限無法 clone `https://cdn.cocoapods.org/` trunk。
  - 改用原 HOME 讀取既有 CocoaPods repo 後，`pod install` 通過，但 `xcodebuild` 在沙盒內回報 `macos/Runner.xcworkspace is not a workspace file`；同時可用 `xcodebuild -list -project macos/Runner.xcodeproj` 讀取 project，顯示 Xcode 可啟動但 workspace build 仍受目前環境限制。

## 4. Walkthrough

實作已完成，Dart analyzer 已通過。正式 Walkthrough 尚需在非沙盒 macOS 終端機完成 `flutter test --no-pub`、`flutter build macos --release --no-pub` 與真實 Trash 手動驗證。
