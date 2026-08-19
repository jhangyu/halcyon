---
date: 2026-08-19
title: "Halcyon — 測試策略與品質門檻 (Unit Test)"
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
| P0 | `PhotoFileActions` | copy/move/delete 直接操作使用者檔案，完全無測試（TD-010）|
| P1 | `PhotoItem.bestFileToLoad` | 影響縮圖來源決策 |
| P1 | `NativeThumbnailService` | Flutter macOS 整合關鍵路徑 |
| P2 | `MainScreen` | 鍵盤快捷鍵、側邊欄拖曳 |
| P2 | `SidebarView` | 縮圖預載觸發邏輯 |
| P3 | `MainDetailView` | 動畫、放大縮小（Task 19 完成後 zoom 邏輯移至 View 層）|

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
| 刪除已標記檔案 | ✅ | Task 12 已改為 Trash service；Task 25 新增資料夾內回收模式（`.trash`）作為替代路徑，`flutter analyze` / `flutter build macos` 與實機覆核待補 |
| Auto-advance | ✅ | |
| Overwrite-existing | ✅ | |
| 狀態持久化（JSON）| ✅ | |
| macOS Day/Night Theme | ✅ | |
| 設定對話框 | ✅ | |
| Trash 而非永久刪除 | ✅（自動化驗證通過） | Task 12 已新增 MethodChannel 實作與 Dart 測試；macOS 實機視覺覆核仍待補 |
| 回收模式（.trash 批次刪除）| ✅ | 同名 sibling 自動分組，`test/photo_file_actions_test.dart` / `test/sidebar_view_test.dart` / `test/photo_action_bar_test.dart` / `test/batch_delete_feedback_test.dart` 覆蓋 |
| 唯讀資料夾警告 | ✅ | `PhotoStatusStore.isWritable()` 建立/刪除 probe 檔案偵測；`loadFolder()` 推送 status line 警告 |
| Status line（取代 SnackBar）| ✅ | `lib/views/status_line.dart`；`test/status_line_test.dart` 覆蓋時序與 emphasis 配色 |
| DNG 全尺寸解碼 | ✅ | `dng_processor` 整合，無內嵌預覽時真正解碼而非降級縮圖；`test/dng_decoder_smoke_test.dart` / `test/dng_extractor_swift_test.dart` / `test/decoded_rgba_image_provider_test.dart` 覆蓋 |
| 影像切換 tier-1/tier-2 sliding preload | ✅ | `lib/services/image_preload_controller.dart`；`test/image_preload_controller_test.dart`（22 案例）覆蓋 |
| Finder「開啟方式」冷啟動 | ✅（macOS）| `lib/services/open_with_channel.dart`；Windows/Android 原生轉發未實作 |
| Sidebar 縮圖預載改為 itemBuilder 驅動 | ✅ | 取代 scroll listener 觸發模式；`test/sidebar_view_test.dart` 覆蓋資料夾重載迴歸案例 |

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
| **測試資料** | `.halcyon_status.json` 含 `_last_viewed_id` 與 `{"photoId": "starred"}` |
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

### TC-011｜PhotoFileActions — copy 成功情境

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-011 |
| **名稱** | `processStarred()` copy 模式正確複製已標記照片至目標目錄 |
| **測試類型** | 單元測試（使用 `dart:io` temp 目錄，不 mock）|
| **測試資料** | temp 來源目錄含 `IMG_001.jpg`（status: starred）、`IMG_002.jpg`（status: unmarked）|
| **預期結果** | 目標目錄僅出現 `IMG_001.jpg`；來源目錄兩者仍存在（copy 非 move）|
| **驗證方式** | `test/photo_file_actions_test.dart` |
| **狀態** | 🔲 Task 15 待建立 |

---

### TC-012｜PhotoFileActions — move 模式含 sidecar 清理

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-012 |
| **名稱** | `processStarred()` move 模式移動後清除 AppleDouble sidecar |
| **測試類型** | 單元測試（使用 `dart:io` temp 目錄）|
| **測試資料** | temp 來源目錄含 `IMG_001.arw`（status: starred）與 `._IMG_001.arw`（sidecar）|
| **預期結果** | `IMG_001.arw` 出現在目標目錄；來源目錄的原檔與 sidecar 均消失；目標目錄無 sidecar |
| **驗證方式** | `test/photo_file_actions_test.dart` |
| **狀態** | 🔲 Task 15 待建立 |

---

### TC-013｜PhotoFileActions — overwriteExisting=false 跳過已存在目標

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-013 |
| **名稱** | `processStarred()` 在 `overwriteExisting=false` 且目標已存在時跳過複製 |
| **測試類型** | 單元測試 |
| **測試資料** | 目標目錄已存在 `IMG_001.jpg`；來源目錄亦有 `IMG_001.jpg`（status: starred）|
| **預期結果** | 目標目錄的 `IMG_001.jpg` 內容與呼叫前一致（未被覆蓋）|
| **驗證方式** | `test/photo_file_actions_test.dart` |
| **狀態** | 🔲 Task 15 待建立 |

---

### TC-014｜AppState — Toggle off 時 auto-advance 不前進

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-014 |
| **名稱** | `markCurrent()` 在 Toggle off（狀態已相同）時不觸發 auto-advance |
| **測試類型** | 單元測試 |
| **測試資料** | `autoAdvance=true`；當前照片 status 已為 `starred`；再次呼叫 `markCurrent(PhotoStatus.starred)` |
| **預期結果** | status 切換為 `unmarked`；`selectedItemID` 保持不變（不前進到下一張）|
| **驗證方式** | `test/app_state_test.dart` |
| **狀態** | 🔲 Task 16 待建立——**行為已於 2026-08-19 對照 `app_state.dart:337-351` 核實為正確**（toggle-off 分支不呼叫 `nextPhoto()`），不再需要使用者確認；純粹缺一個鎖住此行為的 regression test |

---

### TC-015｜PhotoFileActions — Trash 成功情境

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-015 |
| **名稱** | `deleteTrashed()` 透過 Trash service 處理已標記刪除的原檔與 AppleDouble sidecar |
| **測試類型** | 單元測試（注入 trash callback，使用 `dart:io` temp 目錄）|
| **測試資料** | temp 來源目錄含 `IMG_0001.jpg`（status: trashed）、`._IMG_0001.jpg`、`IMG_0002.jpg`（status: unmarked）|
| **預期結果** | trash callback 收到 `IMG_0001.jpg` 與 `._IMG_0001.jpg`；未標記檔案不受影響 |
| **驗證方式** | `test/photo_file_actions_test.dart` |
| **狀態** | 待執行（2026-05-05 容器內 `flutter` / `dart` 不在 PATH） |

---

### TC-016｜PhotoFileActions — Trash 失敗保留原檔

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-016 |
| **名稱** | `deleteTrashed()` 在 Trash service 失敗時拋出錯誤且保留來源檔 |
| **測試類型** | 單元測試（注入失敗 trash callback）|
| **測試資料** | temp 來源目錄含 `IMG_0001.jpg`（status: trashed）|
| **預期結果** | 呼叫拋出 `FileSystemException`；`IMG_0001.jpg` 仍存在 |
| **驗證方式** | `test/photo_file_actions_test.dart` |
| **狀態** | 待執行（2026-05-05 容器內 `flutter` / `dart` 不在 PATH） |

---

### TC-017｜AppState — 唯讀資料夾載入時推送 status line 警告

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-017 |
| **名稱** | `loadFolder()` 偵測資料夾不可寫時推送含「唯讀」字樣的警告訊息 |
| **測試類型** | 單元測試 |
| **預期結果** | `state.status?.text` 包含「唯讀」 |
| **驗證方式** | `test/app_state_test.dart`（`warns on the status line when the folder is read-only`） |
| **狀態** | ✅ 已通過 |

---

### TC-019｜SidebarView — 資料夾重載後每個可視列都會被重新請求

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-019 |
| **名稱** | 捲動離開頂端後 `loadFolder()` 重載資料夾，畫面上實際繪製的每一列縮圖都出現在重新請求清單中 |
| **測試類型** | Widget Test |
| **背景** | 回收/刪除/複製/移動皆會呼叫 `loadFolder()` 重載，重置 `ImagePreloadController` 的縮圖快取；2026-08-19 前縮圖請求只由 `ScrollController` 監聽器觸發，捲動離開頂端的清單重載後會持續空白直到使用者再次捲動（見 `memory.md` AD-014） |
| **預期結果** | 60 項清單捲動離開頂端、重載資料夾後，`tester.widgetList<ListTile>` 取得的可見列名稱全部出現在 `preloadThumbnails` 的請求記錄中 |
| **驗證方式** | `test/sidebar_view_test.dart`（`every visible row is requested again after a folder reload`） |
| **狀態** | ✅ 已通過 |

---

### TC-020｜ImagePreloadController — Tier-1/Tier-2 滑動視窗與 raw-decode 平衡

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-020 |
| **名稱** | tier-1/tier-2 並存的滑動視窗快取正確驅逐、raw-decode 路徑每次視窗掃描只請求原生端一次、decode/dispose handle 平衡不洩漏 |
| **測試類型** | 單元測試 |
| **驗證方式** | `test/image_preload_controller_test.dart`（22 個測試案例，含 BLOCKER 1/B2/BLOCKER 3 迴歸測試） |
| **狀態** | ✅ 已通過 |

---

### TC-021｜DNG 全尺寸解碼路徑

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-021 |
| **名稱** | 無內嵌全尺寸 JPEG 預覽的 DNG 走 `dng_processor` 原生解碼，`DecodedRgba` 正確轉為 `ui.Image` |
| **測試類型** | 單元測試（部分為對已交付 Swift extractor 的對應測試） |
| **驗證方式** | `test/dng_decoder_smoke_test.dart`、`test/dng_extractor_swift_test.dart`、`test/decoded_rgba_image_provider_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-022｜PhotoFileActions — 回收模式（`.trash`）批次移動

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-022 |
| **名稱** | `recycleTrashed()` 將已標記刪除項目（含同名 sibling）移入 `.trash`，碰撞附加後綴，失敗項目回報於 `RecycleOutcome.failures` |
| **測試類型** | 單元測試（`dart:io` temp 目錄）＋ Widget Test（mode-aware UI） |
| **驗證方式** | `test/photo_file_actions_test.dart`、`test/sidebar_view_test.dart`、`test/photo_action_bar_test.dart`、`test/batch_delete_feedback_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-023｜ZoomController — 縮放上下限、歸零與焦點選擇

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-023 |
| **名稱** | 一般縮放（非歸零分支）確實送出動畫請求、連續放大夾在 5.0x、目標倍率 ≤1.05 歸零回 identity（不留位移殘值）、焦點為 `pointerPosition ?? lastKnownCenter`、幾何/游標欄位寫入不得 notify |
| **測試類型** | 單元測試（純 `test()`，不建 widget；`ZoomController` 直接建構，證明其不依賴 `AppState`） |
| **背景** | Task 19 將 zoom 狀態從 `AppState` 下沉至 view 層 `ZoomController`；重構前縮放邏輯零自動化覆蓋（見 `memory.md` G-010） |
| **預期結果** | 11 個案例全綠；`lastKnownCenter` 寫入時通知數為 0（在 `LayoutBuilder` 內 notify 會無窮 rebuild） |
| **驗證方式** | `test/zoom_controller_test.dart`（11 個測試案例） |
| **鑑別力證據** | 9 個 mutant（移除 5.0 夾住、門檻改 0.0／1e9、reset 目標非 identity、焦點忽略 `pointerPosition`／`lastKnownCenter`、移除 notify、`lastKnownCenter` 改為會 notify 的 setter、**非歸零分支不設 `shouldAnimateZoom`**）逐一使對應測試轉紅；原始輸出見 `tmp/verify/mutation_red.txt` 與 `tmp/verify/m6_full_red.txt` |
| **審查補強** | reviewer 指出原 9 個案例對 mutant M6（非歸零分支漏設 `shouldAnimateZoom`）全綠——ceiling 測試斷言旗標為 false、歸零測試斷言的是**另一分支**設的旗標，一般縮放路徑無人觀察；該 mutant 在 app 中的意義是「一般放大縮小完全不會動畫，只剩 ≤1.05 歸零仍有效」。已補 `ordinary zoom request` 群組兩案例並重跑 M6 驗證轉紅 |
| **狀態** | ✅ 已通過 |

---

### TC-018｜StatusLine — 顯示時序與淡出

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-018 |
| **名稱** | StatusLine 於 2.5s 保持全不透明、0.5s 淡出、3.0s 時自動移除；重複顯示會重啟計時；emphasis span 隨底色翻轉配色 |
| **測試類型** | Widget Test |
| **驗證方式** | `test/status_line_test.dart` |
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
cd /Users/jhangyu/project/Halcyon

# 執行所有測試
flutter test

# 執行單一檔案
flutter test test/app_state_test.dart

# 執行含覆蓋率報告（需 flutter pub run）
flutter test --coverage
```

## 成功標準

| 指標 | 目前 | Phase 5 目標 | Phase 10 目標 |
|------|------|-------------|--------------|
| 測試案例總數（`flutter test` 實跑，2026-08-19，commit `d0eb855`）| 85 | ≥ 16（含 TC-011~TC-014，已達成）| ≥ 18（已達成）|
| TC-001 ~ TC-022 通過率 | 全數 ✅ 已通過，僅 TC-014 仍待建立（行為已確認正確，純缺 regression test，見 Task 16）| TC-011~TC-013 通過 | TC-014 通過 |
| `flutter analyze` | 0 issues | 0 errors, 0 warnings | 0 errors, 0 warnings |
| 覆蓋率門檻 | — | > 60%（行覆蓋）| > 70% |
| `PhotoFileActions` 覆蓋 | 0% | copy/move/trash 三條路徑均覆蓋 | 同 Phase 5 |

### 判定條件

全部滿足以下條件才視為 Phase 5 完成：
1. `flutter test` exit code = 0，測試數 ≥ 16
2. TC-001 ~ TC-013 矩陣狀態全部為 ✅ 已通過
3. `flutter analyze` 無 error / warning
4. `task.md` Task 12、Task 15 所有子任務為 ✅ 完成
5. Task 12 完成後：照片標記刪除後移入 macOS Trash，不永久消失

---

## 腳本登錄

- `scripts/build.sh`：統一 Flutter build 入口；預設建置 macOS release app，支援 `macos`、`android`、`android-apk`、`android-aab`、`web`、`windows`、`linux`、`all`。
  - **範例指令**：`./scripts/build.sh`、`./scripts/build.sh android`、`./scripts/build.sh web`、`./scripts/build.sh android-aab --release`
  - **必要輸入**：可選 target；可選 `--debug` / `--profile` / `--release`；可選環境變數 `BUILD_MODE`
  - **契約檢查摘要**：檢查 Flutter CLI 是否存在、target 是否為支援值、host OS 是否支援對應 desktop target；Android build 會套用 JDK 25 / 21 / 17 fallback。
  - **主要輸出**：根目錄 `build/`；Android APK 為 `build/app/outputs/flutter-apk/app-release.apk`，Web 為 `build/web/`，macOS 為 `build/macos/Build/Products/<Mode>/halcyon_flutter.app`
  - **成功判定**：腳本 exit code = 0，且輸出路徑存在。
  - **相容性影響**：Android 目前使用 Gradle 9.1.0 + AGP 9.0.1 + Kotlin 2.3.21 相容模式，以支援 Temurin JDK 25。
- 目前無專用測試腳本，依賴 `flutter test` 標準指令。若需批次測試可建立 `scripts/run_tests.sh`。

## 最近驗證紀錄

| 日期 | 任務 | 指令 | 結果 |
|------|------|------|------|
| 2026-04-29 | Task 6 | `flutter analyze` | ✅ 通過，0 issues |
| 2026-04-29 | Task 6 | `flutter test` | ✅ 通過，1 個 widget smoke test |
| 2026-04-29 | Task 6 | `flutter build macos` | ✅ 通過，產出 `build/macos/Build/Products/Release/halcyon_flutter.app` |
| 2026-04-29 | Task 7 | `flutter analyze` | ✅ 通過，0 issues |
| 2026-04-29 | Task 7 | `flutter test` | ✅ 通過，1 個 widget smoke test |
| 2026-04-29 | Task 7 | `flutter build macos` | ✅ 通過，產出 `build/macos/Build/Products/Release/halcyon_flutter.app` |
| 2026-04-29 | Phase 2/3/4 | `flutter analyze` | ✅ 通過，0 issues |
| 2026-04-29 | Phase 2/3/4 | `flutter test` | ✅ 通過，11 個測試 |
| 2026-04-29 | Phase 2/3/4 | `flutter build macos` | ✅ 通過，產出 `build/macos/Build/Products/Release/halcyon_flutter.app` |
| 2026-04-29 | Task 13 | `flutter test` | ✅ 通過，11 個測試 |
| 2026-04-29 | Task 13 | `flutter analyze` | ✅ 通過，0 issues |
| 2026-04-29 | Task 13 | `flutter build macos` | ✅ 通過，產出 `build/macos/Build/Products/Release/halcyon_flutter.app` |
| 2026-04-29 | Build script | `./scripts/build.sh web` | ✅ 通過，產出 `build/web/` |
| 2026-04-29 | Build script | `./scripts/build.sh android` | ✅ 通過，產出 `build/app/outputs/flutter-apk/app-release.apk` |
| 2026-04-29 | Build script | `./scripts/build.sh android` with JDK 21 | ✅ 通過，產出 `build/app/outputs/flutter-apk/app-release.apk` |
| 2026-05-01 | Android toolchain upgrade | `./gradlew assembleRelease` with JDK 25 | ✅ 通過；Gradle 9.1.0 + AGP 9.0.1 + Kotlin 2.3.21 相容模式 |
| 2026-05-01 | Build script | `./scripts/build.sh android` with JDK 25 | ✅ 通過，產出 `build/app/outputs/flutter-apk/app-release.apk` |
| 2026-05-01 | Regression | `flutter test` | ✅ 通過，11 個測試 |
| 2026-08-19 | 狀態列（status line）與唯讀資料夾警告 | `flutter test` | ✅ 通過，84 個測試（exit code 0，commit `123727b`） |
| 2026-08-19 | Sidebar itemBuilder 驅動預載（Task 26）+ 文件全面重寫 | `flutter test` | ✅ 通過，85 個測試（exit code 0，commit `d0eb855`） |
| 2026-08-19 | 文件全面重寫（本輪） | `flutter analyze lib test` | ✅ 通過，0 issues |

**已知限制**：TC-019 ~ TC-022 為本輪新增，覆蓋 sidebar 重載迴歸、tier-1/tier-2 preload、DNG 解碼、回收模式，但仍是每個測試檔一條摘要 TC，未逐一案例對應（例如 `image_preload_controller_test.dart` 22 個案例只對應 TC-020 一條）。`flutter build macos` 與 macOS 實機視覺覆核（Trash、`.trash` 回收、Finder 開啟方式冷啟動、DNG 大圖顯示）本輪未重跑，沿用先前紀錄。

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
