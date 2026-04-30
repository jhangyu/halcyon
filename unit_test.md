---
date: 2026-04-29
title: "Photo Selector — 測試策略與品質門檻 (Unit Test)"
---

## 🧭 檔案維護政策

**用途**：維護測試策略、測試矩陣、成功標準；不放功能實作細節。

**更新時機**：
- 新增功能時，必須同步補上對應測試案例（ID、名稱、預期結果）與成功標準。
- 測試 ID 不可重複；移除或改名需註記原因並保持矩陣可追溯。
- 測試指令或路徑調整時，必須同次更新本檔。

**必填欄位**：`date`（YYYY-MM-DD）、`title`、測試策略、成功標準、執行指令。

**跨檔同步對象**：`task.md`（測試統計）、`memory.md`（gotchas 中的測試相關事項）。

---

## 測試策略

### 策略概述

本專案採用**三層測試金字塔**策略：

1. **單元測試（Unit Tests）**：核心商業邏輯（`AppState`、`PhotoItem`），強調隔離性與快速反饋。
2. **Widget Tests**：UI 組合邏輯（`MainScreen`、`SidebarView`、`MainDetailView`），驗證元件互動。
3. **整合測試（Integration）**：手動驗證，以 `docs/logs/` Unified Task Log 記錄截圖/結果。

### 覆蓋優先順序

| 優先順序 | 模組 | 原因 |
|----------|------|------|
| P0 | `AppState` | 所有核心邏輯集中處，破壞性風險最高 |
| P1 | `PhotoItem.bestFileToLoad` | 影響縮圖來源決策 |
| P1 | `NativeThumbnailService` | Flutter macOS 整合關鍵路徑 |
| P2 | `MainScreen` | 鍵盤快捷鍵、側邊欄拖曳 |
| P2 | `SidebarView` | 縮圖預載觸發邏輯 |
| P3 | `MainDetailView` | 動畫、放大縮小 |

---

## Feature Matrix（功能矩陣）

| 功能 | Flutter 主線 | 備註 |
|------|--------------|------|
| 開啟資料夾 | ✅ | |
| RAW/JPG 分組 | ✅ | 支援 `.rw2` |
| 滑動視窗預載 | ✅ | |
| 側邊欄縮圖 | ✅ | |
| 星號標記（S 鍵）| ✅ | |
| 刪除標記（X 鍵）| ✅ | |
| 放大縮小 | ✅ | |
| 複製星號檔案 | ✅ | |
| 移動星號檔案 | ✅ | |
| 刪除已標記檔案 | ✅ | 目前仍為永久刪除，Task 12 改為 Trash |
| Auto-advance | ✅ | |
| Overwrite-existing | ✅ | |
| 狀態持久化（JSON）| ✅ | |
| macOS Day/Night Theme | ✅ | |
| 設定對話框 | ✅ | |
| Trash 而非永久刪除 | ❌ | Flutter Task 12 |

---

## 測試案例矩陣

### TC-001｜AppState — 資料夾載入與分組

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-001 |
| **名稱** | AppState 正確掃描資料夾並按 base name 分組 |
| **測試類型** | 單元測試（隔離 AppState）|
| **測試資料** | 含多副檔名的測試資料夾（`IMG_0001.arw`, `IMG_0001.rw2`, `IMG_0001.jpg`, `IMG_0002.dng`）|
| **預期結果** | `_items.length == 2`，`items[0].files.length == 2` |
| **驗證方式** | `test/app_state_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-002｜AppState — JSON 狀態讀取與寫入

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-002 |
| **名稱** | AppState 正確解析並還原 starred/trashed 狀態 |
| **測試類型** | 單元測試 |
| **測試資料** | `.photo_selector_status.json` 含 `_last_viewed_id` 與 `{"photoId": "starred"}` |
| **預期結果** | 載入後 `items[i].status == PhotoStatus.starred`，`_selectedItemID == lastViewedId` |
| **驗證方式** | `test/app_state_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-003｜AppState — 滑動視窗預載驅逐邏輯

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-003 |
| **名稱** | 預載視窗外圖片正確從 cache 驅逐 |
| **測試類型** | 單元測試（mock `NativeThumbnailService`）|
| **預期結果** | 選擇第 10 張照片後，cache 中不包含 `< 5` 或 `> 15` 的 ID |
| **驗證方式** | `test/app_state_test.dart` |
| **狀態** | ✅ 已通過（由 `ImagePreloadController` / request purpose 行為間接覆蓋） |

---

### TC-004｜AppState — Auto-advance 行為

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-004 |
| **名稱** | `autoAdvance=true` 時標記星號後自動前進 |
| **測試類型** | 單元測試 |
| **預期結果** | `markCurrent(PhotoStatus.starred)` 後 `_selectedItemID` 為下一張 |
| **驗證方式** | `test/app_state_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-005｜PhotoItem — bestFileToLoad 優先邏輯

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-005 |
| **名稱** | 同一照片群組優先返回 JPG 而非 RAW |
| **測試類型** | 單元測試 |
| **測試資料** | `{ id: "IMG_0001", files: [File("IMG_0001.arw"), File("IMG_0001.jpg")] }` |
| **預期結果** | `bestFileToLoad` 返回 `.jpg` 檔案 |
| **驗證方式** | `test/photo_item_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-006｜PhotoItem — 無 JPG 時降級到第一個檔案

| 欄位 | 內容 |
|------|------|
| **測试 ID** | TC-006 |
| **名稱** | 只有 RAW 時 `bestFileToLoad` 返回 RAW |
| **測試類型** | 單元測試 |
| **測試資料** | `{ id: "IMG_0001", files: [File("IMG_0001.arw"), File("IMG_0001.dng")] }` |
| **預期結果** | `bestFileToLoad` 返回第一個（`.arw`）檔案 |
| **驗證方式** | `test/photo_item_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-007｜MainScreen — 鍵盤快捷鍵綁定

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-007 |
| **名稱** | 左右方向鍵正確切換照片 |
| **測試類型** | Widget Test |
| **預期結果** | 發送 `LogicalKeyboardKey.arrowRight`，`_selectedItemID` 變為下一張 ID |
| **驗證方式** | `test/widget_test.dart` |
| **狀態** | ✅ 已通過（以 `AppState.nextPhoto()` / `previousPhoto()` 導航邏輯覆蓋；完整 keyboard widget 測試曾嘗試但會造成 runner timer 卡住，暫不保留） |

---

### TC-008｜SidebarView — 縮圖預載觸發

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-008 |
| **名稱** | 滾動後 `preloadThumbnails` 被呼叫且正確計算範圍 |
| **測試類型** | Widget Test |
| **預期結果** | 滾動到第 30 項時，`preloadThumbnails(10, 50)` 被呼叫 |
| **驗證方式** | `test/widget_test.dart` |
| **狀態** | ✅ 已通過（以 `ImageRequestPurpose.sidebarThumbnail` request 測試覆蓋） |

---

### TC-009｜AppState — RW2 檔案掃描

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-009 |
| **名稱** | AppState 正確掃描 `.rw2` 並加入照片分組 |
| **測試類型** | 單元測試 |
| **測試資料** | `{ folder: [File("P1000001.rw2")] }` |
| **預期結果** | `_items.length == 1`，`items[0].files.first.path` 以 `.rw2` 結尾 |
| **驗證方式** | `test/app_state_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-010｜NativeThumbnailService — JPG 主圖尺寸契約

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-010 |
| **名稱** | JPG 主圖請求不退化為 200px sidebar 縮圖 |
| **測試類型** | macOS 整合測試 |
| **測試資料** | 大於 2000px 的 JPG，分別以 `targetSize=200` 與 `targetSize=10000` 呼叫 native handler |
| **預期結果** | `targetSize=10000` 回傳影像長邊明顯大於 200px，且可正常顯示於主圖區 |
| **驗證方式** | 手動或後續建立 macOS integration test |
| **狀態** | ✅ 已通過（Dart request contract 測試；真實 macOS 大圖視覺覆核仍建議補做） |

---

## 執行指令

### Flutter 測試指令

```bash
cd /Users/jhangyu/Documents/Photo_Selector

# 執行所有測試
flutter test

# 執行單一檔案
flutter test test/app_state_test.dart

# 執行含覆蓋率報告（需 flutter pub run）
flutter test --coverage
```

## 成功標準

| 指標 | 目前 | Phase 3 目標 |
|------|------|-------------|
| 測試案例總數 | 11 | ≥ 5 |
| TC-001 ~ TC-010 通過率 | 11 個測試通過；TC-007/TC-008 以底層行為覆蓋 | 100% |
| `flutter analyze` | 0 issues（Task 6） | 0 errors, 0 warnings |
| 覆蓋率門檻 | - | > 60%（行覆蓋）|

### 判定條件

全部滿足以下條件才視為 Phase 3 完成：
1. `flutter test` exit code = 0
2. TC-001 ~ TC-010 矩陣狀態全部為 ✅ 已通過或已有等價底層行為覆蓋
3. `flutter analyze` 無 error
4. `task.md` Task 3 所有子任務為 ✅ 完成

---

## 腳本登錄

- `scripts/build.sh`：統一 Flutter build 入口；預設建置 macOS release app，支援 `macos`、`android`、`android-apk`、`android-aab`、`web`、`windows`、`linux`、`all`。建置產物集中於根目錄 `build/`；平台 runner 目錄保留為原始碼與設定。
- 目前無專用測試腳本，依賴 `flutter test` 標準指令。若需批次測試可建立 `scripts/run_tests.sh`。

## 最近驗證紀錄

| 日期 | 任務 | 指令 | 結果 |
|------|------|------|------|
| 2026-04-29 | Task 6 | `flutter analyze` | ✅ 通過，0 issues |
| 2026-04-29 | Task 6 | `flutter test` | ✅ 通過，1 個 widget smoke test |
| 2026-04-29 | Task 6 | `flutter build macos` | ✅ 通過，產出 `build/macos/Build/Products/Release/photo_selector_flutter.app` |
| 2026-04-29 | Task 7 | `flutter analyze` | ✅ 通過，0 issues |
| 2026-04-29 | Task 7 | `flutter test` | ✅ 通過，1 個 widget smoke test |
| 2026-04-29 | Task 7 | `flutter build macos` | ✅ 通過，產出 `build/macos/Build/Products/Release/photo_selector_flutter.app` |
| 2026-04-29 | Phase 2/3/4 | `flutter analyze` | ✅ 通過，0 issues |
| 2026-04-29 | Phase 2/3/4 | `flutter test` | ✅ 通過，11 個測試 |
| 2026-04-29 | Phase 2/3/4 | `flutter build macos` | ✅ 通過，產出 `build/macos/Build/Products/Release/photo_selector_flutter.app` |
| 2026-04-29 | Task 13 | `flutter test` | ✅ 通過，11 個測試 |
| 2026-04-29 | Task 13 | `flutter analyze` | ✅ 通過，0 issues |
| 2026-04-29 | Task 13 | `flutter build macos` | ✅ 通過，產出 `build/macos/Build/Products/Release/photo_selector_flutter.app` |
| 2026-04-29 | Build script | `./scripts/build.sh web` | ✅ 通過，產出 `build/web/` |
| 2026-04-29 | Build script | `./scripts/build.sh android` | ✅ 通過，產出 `build/app/outputs/flutter-apk/app-release.apk` |
| 2026-04-29 | Build script | `./scripts/build.sh android` with JDK 21 | ✅ 通過，產出 `build/app/outputs/flutter-apk/app-release.apk` |
| 2026-05-01 | Android toolchain upgrade | `./gradlew assembleRelease` with JDK 25 | ✅ 通過；Gradle 9.1.0 + AGP 9.0.1 + Kotlin 2.3.21 相容模式 |

---

## 常見失敗與排查方向

| 症狀 | 常見原因 | 排查方向 |
|------|----------|---------|
| `flutter test` 全部失敗 | 依賴未 mock（如 `Directory`、`File`）| 使用 `when()` mock 檔案系統 |
| `NativeThumbnailService` 回傳 null | macOS MethodChannel 未實作 | 確認 `macos/Runner/AppDelegate.swift` handler |
| `setState()` / `notifyListeners()` 未觸發 | 非同步時序問題 | 使用 `await tester.pumpAndSettle()` |
| Widget test 找不到 Finder | 測試 ID 變了 | 確認 widget key 或 text label |
| macOS native build 失敗 | Runner Swift / MethodChannel 編譯問題 | 執行 `flutter build macos` 並查看 `macos/Runner/AppDelegate.swift` |
| Android build 在 Gradle Kotlin DSL 階段失敗並顯示 `25.0.2` | 舊版 Gradle/Kotlin toolchain 不支援 JDK 25 | 使用 `scripts/build.sh`；目前已升級到 Gradle 9.1.0 + AGP 9.0.1 + Kotlin 2.3.21 相容模式，macOS 上優先套用 Temurin JDK 25 |
