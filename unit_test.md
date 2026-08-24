---
date: 2026-08-20
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

### Artifact provenance（round-1 parking-lot PL-9）

Red/green 證據檔（`tmp/verify/*.txt` 等）**必須自帶它實際跑在哪份 `lib/` 之上**，不能只憑檔名或報告文字裡的宣稱：

- **已提交狀態**：artifact 內記一行 HEAD hash（例如 `git rev-parse HEAD` 的輸出，跑在 test 之前或緊接在同一次呼叫內取得），而不是事後憑記憶回填。
- **未提交的工作狀態**（改動尚未 commit，這在共用 worktree 是常態）：commit hash 綁不住它——改用**內容標記**：一段本輪新引入、且該次執行確實走過的可 grep 字串（例如新測試的完整名稱、或暫時性變異標記如 `MUTATION-MARKER-*`），並在報告中註明「以內容標記而非 hash 綁定」。
- 目的：讓下一輪或審查者能在不重跑的情況下，僅憑 artifact 本身判斷它證明的是哪一份程式碼的行為——這正是 2026-08-23 M3 教訓（見 `~/.claude/rules/lessons-learned.md`）要求的「先證明 binary／測試跑的是受測碼」在文件產物上的對應規則。
- 本輪示例：`tmp/verify/pl1-red.txt`／`pl7-mutation-red.txt` 均以此規則自證。

### 應用內版本戳記：哪條路徑蓋真戳、哪條蓋 unknown（round-2 P-2b）

`lib/perf/perf_log.dart` 的 `kHalcyonBuildCommit` 是 `String.fromEnvironment('HALCYON_BUILD_COMMIT', defaultValue: 'unknown')`——**編譯期**常數，只有編譯當下傳入 `--dart-define` 才會生效，執行期無法補救。哪條路徑蓋哪種值：

| 建置路徑 | `build.stamp` 的 `commit=` 值 |
|---|---|
| `python3 scripts/build_apps.py <target>`（`build_flutter()` 已自動注入，見 `git_build_commit()`） | 真實 40-char git commit hash；工作樹有未提交改動時附 `-dirty` 後綴 |
| 手動 `flutter run` / `flutter build ...`（未帶 `--dart-define=HALCYON_BUILD_COMMIT=...`） | 字面字串 `unknown` |
| 手動帶正確 `--dart-define=HALCYON_BUILD_COMMIT=<hash>` 呼叫 `flutter run`/`build` | 呼叫者傳入的值（原樣，不驗證格式） |
| git metadata 不可得（非 git checkout、`git` 逾時或缺失） | `unknown`（`git_build_commit()` 刻意退化成誠實的「不知道」，絕不猜一個看似合理但錯的 hash） |

**操作規則（P-2 存在的真正安全性質，不是「永遠知道」而是「絕不假裝知道」）**：任何 perf log 的 `build.stamp` 行若讀到 `commit=unknown`，**該次量測必須視為作廢，不得被解讀成任何結論**——不是「缺乏資訊仍可湊合判讀」，是直接不採信這次跑出來的數字。`-dirty` 後綴的 hash 仍是已知程式碼＋已知改動的組合，可以判讀但需在報告中註記工作樹不乾淨。

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
| EXIF 重新命名（批次、可 undo）| ✅ | 模板渲染＋碰撞規劃為純函式、JSONL undo journal、macOS `halcyon/exif` 原生 batch channel、兩窗格對話框、status line undo/cancel；Windows/Android 只有 `exif` package fallback，實機視覺覆核待補（見 `memory.md` TD-015） |

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

### TC-030｜DngPreviewExtractor — 純 Dart DNG 內嵌 JPEG 預覽抽取（Windows/無原生橋接降級路徑）

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-030 |
| **名稱** | `lib/services/dng_preview_extractor.dart`（純 Dart 移植 `macos/Runner/DngPreviewExtractor.swift` 的 TIFF/IFD byte parsing）從真實 DNG 樣本抽出最大內嵌全尺寸 JPEG 預覽；截斷/非 DNG/malformed 輸入一律回傳 `null`，不 throw；`ImagePreloadController` 在原生縮圖回 `NativeImageFailure` 且副檔名為 `.dng` 時改走此抽取器 |
| **測試類型** | 單元測試（真實樣本，`local_data/photo_samples/DNG/`）+ 邊界值測試（合成 malformed bytes） |
| **背景** | Windows 原生橋接對 DNG 一律回 `RAW_UNSUPPORTED`（`windows/runner/halcyon_image.cpp:392-402`）；本抽取器讓任何缺原生縮圖橋接的平台仍能顯示 DNG 內嵌預覽。契約：`docs/logs/2026-08-21/windows-raw-r1r2-contract.md` §2 AC1-AC5 |
| **驗證方式** | `test/dng_preview_extractor_test.dart`（24 個案例：13 個真實樣本抽出可解碼 SOI/EOI JPEG、1 個無預覽樣本回傳 null、1 個 EXIF orientation=6 注入驗證、9 個 malformed/truncated/non-DNG 邊界案例） |
| **鑑別力證據** | 紅→綠：先以永遠回傳 `null`/`1` 的 stub 取代抽取器實作跑該測試檔，14 個案例轉紅（`scripts/tmp/verify/dng_preview_extractor_red.txt`）；還原實作後同批全綠（`scripts/tmp/verify/dng_preview_extractor_green.txt`）。另以獨立編譯的 Swift 參考實作對全部 14 個真實樣本逐一比對抽出 bytes 長度與 orientation，結果完全一致（`scripts/tmp/verify/dng_preview_extractor_dart_vs_swift.txt`） |
| **效能（AC3b，2026-08-21 使用者增補）** | `scripts/tmp/bench_dng_extract.dart`（Stopwatch）對全部 14 個真實樣本各跑 1 次 cold + 5 次 warm，逐檔逐次數字見 `scripts/tmp/verify/dng_perf_bench_raw.txt`。以「每檔 5 次 warm 的中位數」再取跨檔中位數 = 3.79ms；70 個 warm 樣本點的最大值 = 8.56ms（`IMG_20251112_092839.dng`，25MB、無內嵌預覽仍掃描全檔）；cold-run（本 process 對該檔首次觸碰，非強制清 OS page cache）最大 12.51ms。皆遠低於 55ms 中位數目標與 1s 硬上限，AC3b PASS。現行實作（`File.readAsBytes()` 整檔讀入後純記憶體 IFD walk）已達標，未進行 `RandomAccessFile` byte-range 讀取優化 |
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

### TC-024｜RenameRule — 預設模板渲染零填日期與時間

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-024 |
| **名稱** | default template renders zero-padded date and time |
| **測試類型** | 單元測試（純函式）|
| **預期結果** | `RenameRule.kDefaultTemplate` 渲染出 `2026-04-07-09-03-05` |
| **驗證方式** | `test/rename_rule_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-025｜RenameRule — `{seq}` 預設 1 位數，`{seq:3}` 零填 3 位

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-025 |
| **名稱** | `{seq}` defaults to one digit, `{seq:3}` zero-pads to three |
| **測試類型** | 單元測試 |
| **預期結果** | `{seq}` 對 seq=7 輸出 `7`；`{seq:3}` 對 7 輸出 `007`、對 1234 輸出 `1234`（不截斷）|
| **驗證方式** | `test/rename_rule_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-026｜RenameRule — 缺 capture date 退回檔案 mtime

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-026 |
| **名稱** | missing capture date falls back to file mtime |
| **測試類型** | 單元測試 |
| **預期結果** | `meta.captureDate == null` 或 `meta == null` 時，日期欄位改用 `fileModified` |
| **驗證方式** | `test/rename_rule_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-027｜RenameRule — 非日期變數渲染，缺值時輸出空字串

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-027 |
| **名稱** | non-date variables render, missing ones render empty |
| **測試類型** | 單元測試 |
| **預期結果** | `{camera}`/`{lens}`/`{make}`/`{artist}`/`{f}`/`{focal}`/`{iso}`/`{shutter}`/`{direction}`/`{orig}` 各自渲染正確值；缺值變數輸出空字串而非拋錯 |
| **驗證方式** | `test/rename_rule_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-028｜RenameRule — 路徑不合法字元被取代、頭尾修剪

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-028 |
| **名稱** | path-hostile characters are replaced, edges trimmed |
| **測試類型** | 單元測試 |
| **預期結果** | `/`、`:` 等字元換成 `_`；頭尾空白與 `.` 被修剪 |
| **驗證方式** | `test/rename_rule_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-029｜RenameRule — 未知變數與空結果回報為錯誤

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-029 |
| **名稱** | unknown variable and empty result are reported as errors |
| **測試類型** | 單元測試 |
| **預期結果** | `{fstop}`（未知變數）與空模板的 `.error` 非 null；合法模板 `.error` 為 null |
| **驗證方式** | `test/rename_rule_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-030｜RenameRule — 每個 preset 皆為合法模板，預設排第一

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-030 |
| **名稱** | every preset is a valid template and the default is first |
| **測試類型** | 單元測試 |
| **預期結果** | `RenameRule.presets.first.template == kDefaultTemplate`；每個 preset 的 `.error` 皆為 null |
| **驗證方式** | `test/rename_rule_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-031｜planRenames — sibling RAW + JPG + sidecar 共用同一新 base

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-031 |
| **名稱** | sibling RAW + JPG + sidecar all get the same new base |
| **測試類型** | 單元測試（純函式）|
| **預期結果** | 同一 `PhotoItem` 的 NEF/JPG/`._` sidecar 全部渲染同一新 base；moves 順序為「每個檔案後面緊跟它自己的 sidecar」|
| **驗證方式** | `test/rename_service_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-032｜planRenames — 同秒項目依原始檔名順序編號 `{seq}`

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-032 |
| **名稱** | same-second items with `{seq}` number in original-name order |
| **測試類型** | 單元測試 |
| **預期結果** | 兩張同秒拍攝的照片依 id 字母序取得 `_001`/`_002`，與掃描順序無關 |
| **驗證方式** | `test/rename_service_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-033｜planRenames — 無 `{seq}` 時碰撞退回 `-1`/`-2` 後綴

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-033 |
| **名稱** | collision without `{seq}` falls back to -1/-2 |
| **測試類型** | 單元測試 |
| **預期結果** | 三張同秒照片渲染同名時，第二、三張分別得到 `-1`、`-2` 後綴 |
| **驗證方式** | `test/rename_service_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-034｜planRenames — 資料夾內已存在的檔名永不重用

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-034 |
| **名稱** | a name already in the folder is never reused |
| **測試類型** | 單元測試 |
| **預期結果** | `existingNames` 內已有的目標名會被跳過，改附加 `-1` 後綴 |
| **驗證方式** | `test/rename_service_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-035｜planRenames — 已符合命名規則的項目不產生任何 move

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-035 |
| **名稱** | an item already named correctly produces no moves |
| **測試類型** | 單元測試 |
| **預期結果** | 渲染結果與現有 id 相同的項目被跳過（不進 `plans`），避免 undo log 記錄無意義的 no-op |
| **驗證方式** | `test/rename_service_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-036｜planRenames — 缺 metadata 仍能命名，改用檔案 mtime

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-036 |
| **名稱** | missing metadata still renames, using file mtime |
| **測試類型** | 單元測試 |
| **預期結果** | `metadata[id] == null` 時仍成功規劃重新命名，日期取自 `fileModified` |
| **驗證方式** | `test/rename_service_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-037｜applyRenames — 重新命名每個檔案並回報進度

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-037 |
| **名稱** | renames every file and reports progress |
| **測試類型** | 單元測試（`dart:io` temp 目錄）|
| **預期結果** | 兩個 plan 全部檔案成功改名；`onProgress` 依序回報 `[1, 2]`；`outcome.renamedCount == 2`、`failures` 為空 |
| **驗證方式** | `test/rename_service_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-038｜undoLastRename — 還原每個原始檔名並刪除 log

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-038 |
| **名稱** | undo restores every original name and drops the log |
| **測試類型** | 單元測試（`dart:io` temp 目錄）|
| **預期結果** | 呼叫 `undoLastRename` 後所有檔案恢復原名；`kRenameLogName` 檔案被刪除 |
| **驗證方式** | `test/rename_service_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-039｜applyRenames — 來源檔案不存在算失敗，不中斷整批

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-039 |
| **名稱** | a missing source is a failure, not an aborted batch |
| **測試類型** | 單元測試 |
| **預期結果** | 一個 plan 的來源檔不存在時計入 `failures`（含檔名），其餘 plan 仍正常完成 |
| **驗證方式** | `test/rename_service_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-040｜applyRenames — 取消會停止批次並留下可重播的 log

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-040 |
| **名稱** | cancel stops the batch and leaves a replayable log |
| **測試類型** | 單元測試 |
| **預期結果** | `isCancelled` 在第二個 plan 前回傳 true 時，`outcome.cancelled == true` 且只完成一個 plan；隨後 `undoLastRename` 仍可正確還原已完成的部分 |
| **驗證方式** | `test/rename_service_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-041｜PhotoStatusStore — 自訂規則可完整往返讀寫

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-041 |
| **名稱** | a custom rule survives a round trip |
| **測試類型** | 單元測試 |
| **預期結果** | `saveRenameRule` 存入後 `loadRenameRule` 讀回相同字串；存 `null` 會刪除該 key |
| **驗證方式** | `test/photo_status_store_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-042｜PhotoStatusStore — saveStatuses 保留 `_last_viewed_id` 與 `_rename_rule`

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-042 |
| **名稱** | saveStatuses preserves `_last_viewed_id` and `_rename_rule` |
| **測試類型** | 單元測試 |
| **預期結果** | 呼叫 `saveStatuses` 重建 map 後，先前存入的 `_rename_rule`、`_last_viewed_id` 仍存在 JSON 中 |
| **驗證方式** | `test/photo_status_store_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-043｜PhotoStatusStore — applySavedStatuses 不把 `_rename_rule` 當成過期 key

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-043 |
| **名稱** | applySavedStatuses does not treat `_rename_rule` as a stale key |
| **測試類型** | 單元測試 |
| **預期結果** | 過期 key 清理邏輯不會誤刪 `reservedKeys` 內的 `_rename_rule` |
| **驗證方式** | `test/photo_status_store_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-044｜PhotoStatusStore — remapKeys 一併搬移標記與 last-viewed id

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-044 |
| **名稱** | remapKeys moves marks and the last-viewed id to new ids |
| **測試類型** | 單元測試 |
| **預期結果** | `remapKeys` 後舊 id 的星號/垃圾桶標記與 `_last_viewed_id` 全部轉移到新 id；`_rename_rule` 不受影響 |
| **驗證方式** | `test/photo_status_store_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-045｜ExifMetadataService — 完整解碼原生 map

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-045 |
| **名稱** | decodes a full native map |
| **測試類型** | 單元測試 |
| **預期結果** | `metadataFromMap` 正確解出 `captureDate`/`camera`/`lens`/`make`/`artist`/`shutter`/`aperture`/`focalLength`/`gpsImgDirection`/`iso` |
| **驗證方式** | `test/exif_metadata_service_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-046｜ExifMetadataService — null map、缺日期、垃圾日期皆優雅降級

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-046 |
| **名稱** | a null map, a missing date and a junk date all degrade |
| **測試類型** | 單元測試 |
| **預期結果** | `metadataFromMap(null)` 回傳 null；空 map 回傳非 null 但欄位皆 null；無法解析的日期字串回傳 `captureDate == null` 而非拋錯 |
| **驗證方式** | `test/exif_metadata_service_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-047｜ExifMetadataService — readBatch 分批且保持順序 ❌ 已刪除（M6 F-14, P5.2 audit）

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-047 |
| **名稱** | readBatch chunks the paths and preserves order |
| **測試類型** | 單元測試（mock `MethodChannel`）|
| **預期結果** | 1200 個路徑依 `kExifChunkSize`（500）分成 `[500, 500, 200]` 三批呼叫；結果與輸入順序一致 |
| **驗證方式** | ~~`test/exif_metadata_service_test.dart`~~（已刪除） |
| **狀態** | ❌ **已刪除**（commit `36dfc37`, F-14：`halcyon/exif` channel 讀取路徑整個刪除，EXIF 讀取改為 isolate-only；本案例釘住的是舊 channel-mock 的分批行為，受測對象消失，屬 C-4 單平台語意斷言）。刪除理由記於 `test/exif_metadata_service_test.dart:46-53` 的原始碼註解；未列入 `baseline-registry.md` 凍結 sha256 清單，故無需 sha 重新登錄儀式。分批行為由 **TC-120**（原誤編 TC-049，P5.2 後由 lead 重編號）改對真實 isolate 路徑驗證 |

---

### TC-048｜ExifMetadataService — channel 失敗回傳 null 而非拋錯 ❌ 已刪除（M6 F-14, P5.2 audit）

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-048 |
| **名稱** | a channel failure yields nulls rather than throwing |
| **測試類型** | 單元測試（mock `MethodChannel` 拋 `PlatformException`）|
| **預期結果** | `readBatch` 回傳與輸入等長、全為 null 的清單，不向上拋出例外 |
| **驗證方式** | ~~`test/exif_metadata_service_test.dart`~~（已刪除） |
| **狀態** | ❌ **已刪除**（同 TC-047，commit `36dfc37`, F-14——mock 的是已刪除的 channel 失敗路徑，受測對象消失）。降級為 null 的行為由 TC-120 的「找不到的路徑一律降級為 null」子斷言覆蓋 |

---

> **測試 ID 衝突（P5.2 audit 發現，2026-08-24；已修復）**：commit `3a7a2b2`（M6 P3.3/C-4）曾在 `test/exif_metadata_service_test.dart` 新增一個與下方 `renameByExif` 案例同名編號 `TC-049` 的測試（`readBatch never touches a platform channel`），違反本檔「測試 ID 不可重複」政策。P5.2 稽核發現後由 lead 將 exif 側重編號為 **TC-120**（見該條目），`test/app_state_test.dart:386` 的 TC-049 維持原語意不動。

### TC-049｜AppState — renameByExif 重新命名並把星號帶到新 id

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-049 |
| **名稱** | renames files and moves the star to the new id |
| **測試類型** | 單元測試（`dart:io` temp 目錄，注入 fake `exifReader`）|
| **預期結果** | RAW+JPG 對與另一張單檔皆被重新命名；已加星的項目在新 id 下仍為 `starred`；`selectedItemID` 跟著換成新 id |
| **驗證方式** | `test/app_state_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-050｜AppState — undoRename 還原原始檔名與星號

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-050 |
| **名稱** | undo restores the original names and the star |
| **測試類型** | 單元測試 |
| **預期結果** | `undoRename()` 後檔案恢復原名，`items.single.id`/`status` 皆還原 |
| **驗證方式** | `test/app_state_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-051｜AppState — 自訂規則會被儲存，改回 preset 會清除

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-051 |
| **名稱** | a custom rule is saved; a preset clears it |
| **測試類型** | 單元測試 |
| **預期結果** | `isCustom: true` 呼叫後 `loadSavedRenameRule()` 回傳該模板；之後以 `isCustom: false` 呼叫內建 preset 後 `loadSavedRenameRule()` 回傳 null |
| **驗證方式** | `test/app_state_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-052｜RenameDialog — 每個 preset 與每個變數 chip 都會渲染

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-052 |
| **名稱** | every preset and every variable chip is rendered |
| **測試類型** | Widget Test |
| **預期結果** | `RenameRule.presets` 每個 label、`Custom...`、`RenameRule.variableGroups` 每個 token 皆能在畫面上找到 |
| **驗證方式** | `test/rename_dialog_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-053｜RenameDialog — 不合法規則停用 Rename 按鈕並顯示原因

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-053 |
| **名稱** | an invalid rule disables Rename and shows the reason |
| **測試類型** | Widget Test |
| **預期結果** | 輸入 `{fstop}` 後畫面顯示含「Unknown variable」的錯誤文字；`FilledButton.onPressed` 為 null |
| **驗證方式** | `test/rename_dialog_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-054｜RenameDialog — 點擊 chip 會把 token 附加到規則欄位

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-054 |
| **名稱** | tapping a chip appends its token to the rule |
| **測試類型** | Widget Test |
| **預期結果** | 輸入 `{YYYY}` 後點擊 `{camera}` chip，`TextField.controller.text` 變成 `{YYYY}{camera}` |
| **驗證方式** | `test/rename_dialog_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-055｜SidebarView — 用共用常數觸發 onSelected 會開啟對話框

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-055 |
| **名稱** | onSelected with the shared constant opens the dialog |
| **測試類型** | Widget Test |
| **背景** | `testWidgets` 中對 `PopupMenuItem` tap 會在 `FakeAsync` 下掛住（見 `memory.md` G-013），改直接呼叫 `PopupMenuButton.onSelected!`；同時驗證選單 `value` 與呼叫端共用 `kRenameMenuValue`（見 `memory.md` G-012） |
| **預期結果** | 呼叫 `button.onSelected!(kRenameMenuValue)` 後 `find.byType(RenameDialog)` 找到一個 widget |
| **驗證方式** | `test/sidebar_view_test.dart` |
| **狀態** | ✅ 已通過 |

---

### TC-056｜StatusLine — 帶 action 的訊息渲染按鈕且只觸發一次

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-056 |
| **名稱** | an action message renders a button that fires once |
| **測試類型** | Widget Test |
| **預期結果** | `StatusMessage(actionLabel: '還原', onAction: ...)` 渲染出「還原」按鈕；點擊一次後 callback 恰好觸發一次 |
| **驗證方式** | `test/status_line_test.dart` |
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

### TC-089｜dng_nav_probe_m3_test — real preview-bearing DNG probe cheap leads to immediate loader work ❌ 已刪除（M6 C-4, P5.2 audit 補登）

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-089 |
| **名稱** | real preview-bearing DNG content probe cheap leads to immediate loader work |
| **測試類型** | 單元測試 |
| **驗證方式** | ~~`test/dng_nav_probe_m3_test.dart:180-204`~~（已刪除） |
| **狀態** | ❌ **已刪除**（commit `3a7a2b2`, M6 P3.3, Appendix B 列項；`baseline-registry.md` 已於同一 commit 記錄 sha256 重新登錄與 C-4 理由）。TC-088（`:144-176`）保留不動。本條在 M5 前從未進過本檔矩陣（僅見於 `docs/logs/2026-08-24/m6-execution-plan.md` Appendix B 與 `test/image_preload_scheduling_m4_test.dart` 背景說明的旁引），P5.2 audit 一併補登以求矩陣完整可追溯 |

---

### TC-057｜NativeThumbnailService — MissingPluginException 退化為 NativeImageFailure ⚠️ 受測主體已刪除，行為由 TC-030-AC5 接手（M6 U-12, P5.2 audit 補註）

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-057 |
| **名稱** | halcyon/thumbnail channel 無 native handler（跨平台 P0）時不拋出，退化為 `NativeImageFailure` |
| **測試類型** | Unit Test |
| **背景** | Windows/Android/iOS 尚無 `halcyon/thumbnail` 的 native 實作，mock messenger 拋出 `MissingPluginException`（不是 `PlatformException` 的子類，需獨立 catch）。修復前會一路 rethrow 穿過 `image_preload_controller.dart` 的 `_loadPreview`，讓整個 preload pipeline 崩潰、UI 全黑 |
| **預期結果** | `requestImage` catch `MissingPluginException` 並回傳 `NativeImageFailure(code: 'MISSING_PLUGIN', ...)`，不拋出；`image_preload_controller.dart` 既有的 `NativeImageFailure` → `_failedIds` 錯誤顯示路徑不需改動即可正確處理 |
| **驗證方式** | ~~`test/native_thumbnail_service_test.dart`~~（**整檔已刪除**，commit `3a7a2b2`，Appendix B 列項：`NativeThumbnailService` 本體隨 `halcyon/thumbnail` channel 一併刪除）。等效行為現由 `test/m6_bridge_free_test.dart` 的 `AC5: with the channel throwing MissingPluginException, cheap AND no-preview DNGs still behave` 覆蓋——但語意已從「退化為 `NativeImageFailure` 特例」升級為 U-12 裁定的「一律立即統一 miss」，不再有 `MISSING_PLUGIN` 這個特殊 code 分支 |
| **狀態** | ⚠️ **此條目描述的具體實作已不存在**；不標記刪除是因為它記錄的行為意圖（channel 不可用時優雅降級、不讓 pipeline 崩潰）仍然成立，只是承載測試與實作機制換了。`m6_bridge_free_test.dart` AC4/AC5 兩案例 `flutter test test/m6_bridge_free_test.dart` 本輪未重新登記獨立 TC 號（P5.2 audit 未在 owned 範圍內新增更多矩陣條目，僅記錄本條的失效狀態） |

---

### TC-105｜ImagePreloadController — 永久失敗的側欄縮圖三次 sweep 只請求一次

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-105 |
| **名稱** | M4-AC1 a permanently failing sidebar thumbnail is requested EXACTLY ONCE across three preloadThumbnails sweeps |
| **測試類型** | Unit Test |
| **背景** | 設計權威 §2.2：「這檔能不能讀」原本是兩套互不相通的政策——preview 有 `_permanentMisses`，側欄只測 `containsKey`，所以永久失敗的檔案每次 sweep 都重問（不變式 I8） |
| **預期結果** | 三次 range 不同的 sweep 之後，failing path 的 loader 呼叫次數 == 1；可載入的縮圖仍然落地（反空洞斷言） |
| **驗證方式** | `test/image_preload_scheduling_m4_test.dart` |
| **狀態** | ✅ 已通過（改動前紅燈 `tmp/verify/ac_red_baseline.txt`，RC=1；改動後綠燈 `tmp/verify/ac_green_m4file.txt`，RC=0） |

---

### TC-104｜ImagePreloadController — 側欄縮圖失敗不得污染同名前綴檔案的 preview 狀態

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-104 |
| **名稱** | M4-AC1b a failed sidebar thumbnail must not poison the PREVIEW state of a file whose own name happens to be "thumb_" + another file's name |
| **測試類型** | Unit Test |
| **背景** | `PhotoItem.id` 是 `basenameWithoutExtension`（`supported_photo_formats.dart:44`，於 `photo_library_scanner.dart:23` 當分組鍵），也就是**使用者可控的檔名**。TC-105 的第一版把側欄的 miss 以 `thumb_<id>` 前綴寫進 preview 的 `_permanentMisses`；同一資料夾若同時有 `IMG_01.jpg` 與 `thumb_IMG_01.jpg`，一個字串就有兩種意義。id 空間無限制，任何前綴／跳脫都救不了，只能分成兩個容器 |
| **預期結果** | `IMG_01` 的縮圖永久失敗後，`hasFailed('thumb_IMG_01')` 仍為 false；且 `thumb_IMG_01` 的縮圖仍正常載入（反空洞斷言） |
| **驗證方式** | `test/image_preload_scheduling_m4_test.dart` |
| **狀態** | ✅ 已通過（分容器修復前紅燈 `tmp/verify/20260824-impl-collision-red.txt`，RC=1；修復後綠燈 `tmp/verify/20260824-impl-collision-green.txt`，RC=0） |

---

### TC-106｜ImagePreloadController — preview 路徑 generation guard（不變式 I4）

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-106 |
| **名稱** | M4-AC2 a stale preloadImages resume must not reschedule tier-2 for the window it started with |
| **測試類型** | Unit Test（`testWidgets` + `tester.runAsync`，需真實 timer 與真實引擎解碼） |
| **背景** | `preloadImages` 過去沒有 generation guard。`_scheduleTierTwoDecode` 會先 cancel debounce timer 再重排，所以過期的 pass 恢復時不只是多做白工，而是把全尺寸解碼從使用者當下正在看的項目手上搶走 |
| **預期結果** | 舊 pass 恢復後，新 generation 的 tier-2 仍然完成（`isFullSizeReady(items[9])` 為 true），且被放棄的視窗沒有任何解碼 |
| **驗證方式** | `test/image_preload_scheduling_m4_test.dart` |
| **狀態** | ✅ 已通過（改動前紅燈 `tmp/verify/ac_red_baseline.txt`，RC=1；改動後綠燈 `tmp/verify/ac_green_m4file.txt`，RC=0） |

---

### TC-107｜PhotoSource — 步驟 3b 失敗回報 non-deferred 空 payload

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-107 |
| **名稱** | M4-AC3 step-3b failure inside PhotoSource.load reports a NON-deferred null payload |
| **測試類型** | Unit Test |
| **背景** | 設計權威 §3.4 不變式 T1。`photo_source.dart:160-170`（`load()` 自己的 3b catch）在此之前沒有專屬測試；樹上既有的 TC-085 走的是 `loadExpensive` 的 catch（`:217`） |
| **預期結果** | decoder 丟例外且 legacy CIRAWFilter 也回 null 時，`payload == null` 且 `deferred == false`——`deferred: true` 會讓呼叫端等一個已經跑完的 ±1 pass，spinner 永不解除 |
| **驗證方式** | `test/image_preload_scheduling_m4_test.dart` |
| **狀態** | ✅ 已通過（既有行為即正確，紅燈以變異取得：把該處改成 `deferred: true`，見 `tmp/verify/ac3_mutantA.txt`，RC=1；變異已還原） |

---

### TC-108｜ImagePreloadController — 步驟 3b 失敗寫入 permanent-miss 並解除 spinner

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-108 |
| **名稱** | M4-AC3 the step-3b failure path marks a permanent miss and RELEASES the view from its spinner |
| **測試類型** | Unit Test |
| **預期結果** | `hasFailed(id)` 轉為 true、`payloadFor(id)` 為 null，且 `notifyLoaded` 至少被呼叫一次（只記 miss 不通知，畫面仍會停在 spinner 直到別的事件重繪） |
| **驗證方式** | `test/image_preload_scheduling_m4_test.dart` |
| **狀態** | ✅ 已通過（既有行為即正確，紅燈以變異取得：移除 `_permanentMisses.add(id)`，見 `tmp/verify/ac3_mutantB.txt`，RC=1；變異已還原） |

---

### TC-109｜ImagePreloadController — 側欄縮圖 loader 拋例外不得中斷整趟 sweep（PL-1/PL-2/PL-10）

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-109 |
| **名稱** | M6-PL1 a throwing sidebar thumbnail loader must not abort the sweep, must release the in-flight key, and must record a permanent miss like a non-bytes result |
| **測試類型** | Unit Test |
| **背景** | Round-1 parking-lot PL-1/PL-2/PL-10：`preloadThumbnails` 的逐項迴圈原本沒有 `try`/`catch`，`_loadingKeys` 的移除也不在 `finally` 裡。loader **拋例外**（而非回傳 `NativeImageFailure`）時，例外會直接讓 `for` 迴圈中斷，該趟 sweep 其餘尚未請求的項目全部被靜默跳過，且拋出者的 `thumb_<id>` in-flight 鍵永久洩漏，之後每趟 sweep 都把它誤判為「仍在載入中」而永不重問也永不解除 |
| **預期結果** | (1) loader 對第一項拋例外後，同趟 sweep 後續項目仍被請求並成功落地；(2) 拋例外的鍵在 `finally` 中被釋放；(3) 拋例外的項目被視同非 bytes 結果寫入 `_thumbPermanentMisses`，往後三趟不同 range 的 sweep 中，該路徑的 loader 呼叫次數恰好為 1 |
| **驗證方式** | `test/image_preload_scheduling_m4_test.dart` |
| **狀態** | ✅ 已通過（修復前紅燈 `tmp/verify/pl1-red.txt`，RC=1，唯一失敗即新測試；修復後綠燈 `tmp/verify/pl-a-b-final-green.txt`，RC=0，同檔全 7 個測試皆過） |

---

### TC-110｜ImagePreloadController — preview 路徑第二道 generation guard（window await 之後，:406）

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-110 |
| **名稱** | M6-PL7 the SECOND generation guard (after the window await, :406) must discard a stale resume too, not only the priority-load guard (:381) |
| **測試類型** | Unit Test（`testWidgets` + `tester.runAsync`，需真實 timer 與真實引擎解碼） |
| **背景** | Round-1 parking-lot PL-7：TC-106（AC2）交付的測試只讓 stale pass 卡在**優先載入**（`:365` 的 await），因此只驗證了第一道 guard（`:381`）。程式碼註解稱第二道 guard（`:406`，window await 之後）才是「load-bearing」的那道——它會取消並改排 tier-2 debounce timer——但 round-1 從未交付能實際走到那條路徑的測試（reviewer 探針 `scripts/tmp/m4-round1-verify/reviewer_guard2_probe_test.dart` 只證明 guard 本身正確，不是交付測試） |
| **預期結果** | 把 stale pass 卡在 **window 迴圈**（`Future.wait(pendingLoads)`，而非優先載入）以確保第一道 guard 未觸發、真正到達第二道 guard；釋放後 stale pass 不得改排新一代的 tier-2 schedule：目前世代（index 10）的 `isFullSizeReady` 為 true，被放棄的世代（index 0）為 false |
| **驗證方式** | `test/image_preload_scheduling_m4_test.dart` |
| **狀態** | ✅ 已通過（既有行為即正確，故此測試預期立即綠燈：`tmp/verify/pl7-green.txt`，RC=0；靈敏度以區域變異驗證——暫時移除第二道 guard 得紅燈 `tmp/verify/pl7-mutation-red.txt`，RC=1，變異已還原並以 `grep -c MUTATION-MARKER-PL7-TEMP` == 0 確認） |

---

### TC-111｜PerfLog — kHalcyonBuildCommit 反映編譯期 --dart-define（round-2 P-2b）

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-111 |
| **名稱** | P-2b kHalcyonBuildCommit reflects HALCYON_BUILD_COMMIT at compile time |
| **測試類型** | Unit Test（一般 suite 成員，裸跑與帶 `--dart-define` 跑都是有效驗證） |
| **背景** | Round-2 parking-lot P-2b：`scripts/build_apps.py` 現在會在呼叫 `flutter build` 時自動注入 `--dart-define=HALCYON_BUILD_COMMIT=<真實 hash>`（工作樹不乾淨時附 `-dirty`），取代原本一律蓋 `unknown` 的預設。此測試驗證的是「define 真的傳到 Dart 常數」這條 plumbing，不驗證 `scripts/build_apps.py` 本身（那是 proof half 2，Python 子行程層級的證據，見 `tmp/verify/p2b-build-half2.txt`／`p2b-binary-grep2.txt`，不在此測試檔覆蓋範圍） |
| **預期結果** | 裸跑 `flutter test`（無 `--dart-define`）時 `kHalcyonBuildCommit == 'unknown'`（文件化預設值）；帶 `--dart-define=HALCYON_BUILD_COMMIT=<sentinel>` 跑時 `kHalcyonBuildCommit == <sentinel>` 且不等於 `'unknown'` |
| **驗證方式** | `test/perf_log_build_stamp_test.dart` |
| **狀態** | ✅ 已通過（裸跑：`tmp/verify/p2b-sentinel-default.txt`，RC=0；帶 sentinel `deadbeefcafef00d0000000000000000sentinel` 跑：`tmp/verify/p2b-sentinel-defined.txt`，RC=0） |

---

### TC-112..117｜M5 雙窗：RAW 全解析度 tier-2 升級（AC-M5-2..6、AC-M5-9）

契約：`docs/logs/2026-08-24/m5-dual-window-design.md` §3。六個測試名稱為契約凍結逐字文本，不可改名。

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-112 |
| **名稱** | `M5-DW1 tier-2 keys equal the +/-2 band after settle, for encoded and pixel payloads alike`（AC-M5-2） |
| **測試類型** | Unit Test |
| **背景** | Encoded 子案例照既有 TC-097 模式單次 settle 即可覆蓋整個 ±2 帶；Pixel 子案例受 AD-018 限制（RAW 只在曾經進過自己 ±1 的位置才有 payload），核心宣稱用 `[5,7,3,5]` 走位一次滿足（保留窗寬 9 與 ±2 帶寬 5 差距足夠讓五格 payload 同時存活到最終 settle），四個邊界點（-3/+3/+4/+5）改用個別短走位驗證——保留窗寬 9 與所需跨度（-3..+5）恰好相等，任何單一走位不可能同時讓左右兩端 payload 存活，故拆開驗證而非合併，見測試檔內註解 |
| **預期結果** | `debugTierTwoKeyIds` 恆等於 ±2 的 id 集合（encoded 與 pixel 各驗一次）；-3 與 +3..+5 有 tier-1 key、無 tier-2 key |
| **驗證方式** | `test/image_preload_dual_window_m5_test.dart` |
| **狀態** | ✅ 已通過（`tmp/verify/m5-dw-test-run4.txt`，RC=0） |

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-113 |
| **名稱** | `M5-DW2 a pixel-backed item at distance 0 gets a FULL-resolution tier-2 entry distinct from its window-resolution tier-1 entry`（AC-M5-3） |
| **測試類型** | Unit Test |
| **背景** | 沒有凍結的 accessor 可直接讀回已 resolve 的 tier-2 影像尺寸或其 ImageCache key。改用「探針」`RawFullResImage`：以相同的 `payloadIdentity`（controller 的 `PixelPayload`）＋相同尺寸（400x300）建構一個新 provider 實例——`RawFullResImage.operator==` 只比對 `identical(payloadIdentity)+width+height`（`raw_full_res_image.dart`，凍結），resolve 時會命中已存在的 ImageCache 項而非重新解碼，藉此讀回真實尺寸且不需新增 controller API |
| **預期結果** | tier-2 resolve 影像尺寸 == 400x300；tier-1（`pixelsProviderFor`）== 視窗尺寸 200x150；`isFullSizeReady == true`；tier-1/tier-2 兩個 key 的 runtime type 不同（provider 種類不同，結構上不可能相等） |
| **驗證方式** | `test/image_preload_dual_window_m5_test.dart` |
| **狀態** | ✅ 已通過（`tmp/verify/m5-dw-test-run4.txt`，RC=0） |

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-114 |
| **名稱** | `M5-DW3 payload production and full-res tier-2 for a RAW item inside +/-1 cost exactly ONE decoder call`（AC-M5-4） |
| **測試類型** | Unit Test |
| **背景** | 驗證單次解碼雙輸出（piggyback，design §2.2）：payload 生產與全解析度 tier-2 上傳必須共用同一次 FFI 解碼呼叫，不得因為 M5 多解一次 |
| **預期結果** | 距離 0 的 fake decoder 呼叫計數 == 1 |
| **驗證方式** | `test/image_preload_dual_window_m5_test.dart` |
| **狀態** | ✅ 已通過（`tmp/verify/m5-dw-test-run4.txt`，RC=0） |

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-115 |
| **名稱** | `M5-DW4 leaving +/-2 evicts the full-res entry; re-entering re-upgrades with exactly one extra decoder call and an identical retained payload`（AC-M5-5） |
| **測試類型** | Unit Test |
| **背景** | 驗證離窗／回窗的補升級路徑：payload 保留在 -3..+5，全解析度項僅存在於 ±2，離開後由既有簿記驅逐、回窗後由 catch-up 佇列補一次解碼且不替換保留的 payload 物件 |
| **預期結果** | 距離 3（-3..+5 內、±2 外）時 `debugTierTwoKeyIds` 不含該 id，payload 仍非 null；回到距離 2 後 decoder 呼叫數 +1（總計 2），`identical(payloadFor(id), 原物件) == true` |
| **驗證方式** | `test/image_preload_dual_window_m5_test.dart` |
| **狀態** | ✅ 已通過（`tmp/verify/m5-dw-test-run4.txt`，RC=0） |

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-116 |
| **名稱** | `M5-DW5 a failing full-res decode keeps tier-1 display, writes NO permanent miss, and is not retried for the same payload`（AC-M5-6） |
| **測試類型** | Unit Test |
| **背景** | 全解析度升級失敗（design §2.5）與「整個 payload 都產不出」的 permanent miss 是兩件事：前者只影響 tier-2、以「per-payload」記憶失敗不重試；fake decoder 對目標項第一次呼叫（piggyback）成功、第二次起（catch-up 補升級）拋例外 |
| **預期結果** | `hasFailed == false`；catch-up 失敗嘗試後 `isFullSizeReady == false`（tier-1 顯示不受影響）；再觸發兩次 debounce settle 後目標路徑總呼叫數維持 2（1 次成功 + 1 次失敗，不重試） |
| **驗證方式** | `test/image_preload_dual_window_m5_test.dart` |
| **狀態** | ✅ 已通過（`tmp/verify/m5-dw-test-run4.txt`，RC=0） |

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-117 |
| **名稱** | `M5-DW6 a full-res upgrade adds ZERO bytes to the payload cache`（AC-M5-9） |
| **測試類型** | Unit Test |
| **背景** | 全解析度像素只活在 ImageCache（`ui.Image`），來源緩衝一律瞬態（design §2.3）——payload 快取的 `retainedByteCost` 不應因為 tier-2 升級而多算任何位元組 |
| **預期結果** | 升級前 `retainedByteCost == 0`（尚未解碼）；升級後 `retainedByteCost` 恰等於 ±1 帶內每個 `PixelPayload.byteCost` 的總和，不含任何全解析度緩衝的額外位元組 |
| **驗證方式** | `test/image_preload_dual_window_m5_test.dart` |
| **狀態** | ✅ 已通過（`tmp/verify/m5-dw-test-run4.txt`，RC=0） |

---

### TC-118｜cache_budget — image-cache 記憶體衍生預算夾在 256–768 MiB（F-25）

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-118 |
| **名稱** | budget derivation: floor 256MiB, ceiling 768MiB, quarter of physical |
| **測試類型** | 單元測試（純函式） |
| **背景** | P5.1（F-25）：Dart 無法查詢實際物理記憶體，`imageCacheBudgetBytes({int? physicalMemoryBytes})` 是留給未來补上真實查詢的衍生縫（seam）；`physicalMemoryBytes: null` 時回退到 768 MiB 上限，這條上限維持 `docs/logs/2026-08-23/cache-sizing-estimate.md` §A.4/§A.6 的估算有效 |
| **預期結果** | `null` → 768 MiB；32 GiB 物理記憶體 → 仍夾在 768 MiB 上限；2 GiB → 512 MiB（1/4）；512 MiB 物理記憶體 → 256 MiB 下限（低於此值 M5 no-re-decode 保證會失效） |
| **驗證方式** | `test/cache_budget_test.dart` |
| **狀態** | ✅ 已通過（`flutter test test/cache_budget_test.dart`，RC=0，2026-08-24 P5.2 audit 重跑確認） |

---

### TC-120｜ExifMetadataService — readBatch 永不觸碰 platform channel（F-14, isolate-only）

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-120（原誤編 TC-049，與 `app_state_test.dart` 的 renameByExif 案例衝突，P5.2 稽核後由 lead 重編號） |
| **名稱** | readBatch never touches a platform channel |
| **測試類型** | 單元測試（以名稱 mock `MethodChannel('halcyon/exif')` 作探針計數）|
| **背景** | commit `3a7a2b2`／`36dfc37`（M6 F-14）刪除 `halcyon/exif` channel 路徑後，取代被刪除的 TC-047/048：對真實 isolate 解析路徑驗證分批與失敗容忍，並以 channel 探針證明呼叫數為 0 |
| **預期結果** | `readBatch` 完成後 channel mock 的呼叫計數為 0；找不到的路徑一律降級為 null；結果與輸入等長且順序一致 |
| **驗證方式** | `test/exif_metadata_service_test.dart` |
| **狀態** | ✅ 已通過（重編號後 `flutter test test/exif_metadata_service_test.dart` 重跑確認，2026-08-24） |

---

### TC-119｜OpenWithChannel — 推播式 openFile 送達監聽者（F-16, Android/iOS 統一 Dart 交付）

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-119 |
| **名稱** | a pushed openFile call is delivered to the listener / an empty path is ignored / an unrecognised method is ignored |
| **測試類型** | 單元測試（3 案例，mock `MethodChannel('halcyon/open_with')`） |
| **背景** | P4.5（F-16）：Android/iOS 的 manifest/Info.plist 宣告＋原生推播已補上，但 Dart 側契約不變——原生推 `openFile` method call，`OpenWithChannel.listen()` 把路徑交給呼叫端。此測試只證明這條 Dart 交付機制，**不**涵蓋 Android/iOS 實機／模擬器（本機無裝置），也**不**宣稱行動端 end-to-end 已可用——資料夾掃描（F-02）在 Android/iOS 仍是 parked 狀態，見 `test/open_with_channel_test.dart:6-11` 檔頭註解 |
| **預期結果** | 推播 `openFile('/tmp/example.dng')` 後監聽者收到該路徑；空字串路徑被忽略；未知 method 名被忽略 |
| **驗證方式** | `test/open_with_channel_test.dart` |
| **狀態** | ✅ 已通過（`flutter test test/open_with_channel_test.dart`，RC=0，2026-08-24 P5.2 audit 重跑確認；4 個測試共同一次執行，見上方 TC-118 指令輸出） |

---

### TC-160~163｜AppState.openPhotoAtPath — 不存在的路徑不得清空使用者正在檢視的資料夾（M7 Task 4）

> 編號說明：本組沿用實作者已寫入測試名稱並提交（`d4796ec`）的 TC-160~163。TC-121~159 為未使用的空號，後續新增測試請從 TC-164 起編，勿回填空號以免與已提交的測試名稱衝突。

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-160 / TC-161 / TC-162 / TC-163 |
| **名稱** | keeps the loaded folder when the file does not exist / keeps the loaded folder when the parent directory is missing / still opens a real file and selects it / ignores unsupported extensions |
| **測試類型** | 單元測試（4 案例，真實暫存目錄，無 platform channel） |
| **背景** | M7 Task 4：`openPhotoAtPath` 原本只用副檔名過濾，就直接呼叫 `loadFolder`，而 `loadFolder` 會**先**清空 `_currentDir`／`_items`／preload／選取狀態**才**掃描（`lib/providers/app_state.dart:251-255`）。任何「只是結尾像照片副檔名」的字串因此會抹掉使用者正在挑片的資料夾，換成一個不存在目錄的空掃描。Android `ACTION_VIEW` 的 `content://` URI 不透明片段（例如 `/document/image:1234.jpg`）正是這種字串。修法是在動任何狀態前檢查檔案與其父目錄是否存在（`:246-249`），純檔案系統檢查、無平台分支（C-3） |
| **預期結果** | TC-160／TC-161：`currentDir`、items、選取狀態與呼叫前完全相同；TC-162：真實檔案仍會載入其資料夾並選中該照片；TC-163：不支援的副檔名被忽略且不清空資料夾 |
| **驗證方式** | `flutter test test/app_state_open_with_test.dart` |
| **狀態** | ✅ 已通過（紅→綠留證：`scripts/tmp/m7-t4/red.log` 修補前 TC-160 實得 `/nonexistent/dir`、TC-161 實得 `.../no_such_subdir`，自捕 `RC=1`；`green.log` 修補後 `All tests passed!`、自捕 `RC=0`、4/4） |

---

### TC-164~171｜DngPreviewExtractor — big-endian（MM）讀取路徑差分覆蓋（M7 Task 1）

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-164（產生器決定性，`:53`）／TC-165（`:69`）／TC-166（`:80`）／TC-167（longEdge:200 選中尺寸 MM==II，`:100`）／TC-168（longEdge:null 選中尺寸 MM==II，`:116`）／TC-169（取出的 bytes MM==II，`:135`）／TC-170（orientation MM==II，`:151`）／TC-171（`corruptOffsets` 容器目前行為，`:161`） |
| **測試類型** | 單元測試（8 案例，容器由 `test/support/synthetic_dng.dart` 在記憶體中組出後寫入暫存目錄，無 committed binary fixture） |
| **背景** | 稽核發現 `_detectByteOrder`／`_readerFor` 宣稱支援 big-endian，但 `test/` 下沒有任何 `MM` 輸入，整條大端分支從未被執行過。刻意採**差分**設計：同一個邏輯容器分別以 `bigEndian: false` 與 `true` 各建一份，斷言兩者結果相同——若改斷言絕對值，一個「錯得前後一致」的 reader 也會通過 |
| **預期結果** | 兩種位元組序在四個面向完全一致：longEdge:200 的選中尺寸、longEdge:null 的選中尺寸、取出的 JPEG bytes（`Uint8List` 完全相等）、orientation |
| **驗證方式** | `flutter test -j 1 test/dng_preview_extractor_endian_test.dart`（宣告 8 == 實跑 +8，RC=0 自捕） |
| **狀態** | ✅ 已通過，且**未發現位元組序缺陷**——`lib/services/dng_preview_extractor.dart` 未被修改。此否定結果由突變測試背書而非目視：把 `_TIFFReader.u32` 的大端分支（`:757`）改成小端寫法後，5 條涉及 MM 的斷言全紅、3 條只走 II 的維持綠（`scripts/tmp/m7-t1/red-m1.txt`），突變已還原 |

> Task 3 注意：TC-171 斷言的是**目前**對 `corruptOffsets: true` 容器的行為（兩種位元組序皆自 `extractEmbeddedJpeg` 得到 `null`）。malformed 偵測改以 `probeEmbeddedJpeg` 新增 API 交付時，只要 `extractEmbeddedJpeg` 的簽章與回傳契約真的沒變，這條期望就仍成立。若發現非改這行不可，代表 API 是被遷移而非新增，應回報 lead 而非逕行修改。

---

### TC-180~193｜預覽圖尺寸不足改走 RAW 解碼 + 方向值範圍夾限（M7 Task 2）

| 欄位 | 內容 |
|------|------|
| **測試 ID** | 方向值夾限 TC-180（原始值 0→1）／TC-181（1→1，下界保留）／TC-182（8→8，上界保留）／TC-183（9→1）／TC-184（無法判定時 `readDngOrientation` 折成 1、`readOrientation` 保留 null）；`minLongEdge` 規則 TC-185（`longEdge:null`）／TC-186（`longEdge:200`，證明兩種選取模式都套用）／TC-187（是拒絕而非改選：有合格候選時仍取最大者）／TC-188（預設 null，顯式 null 與寬鬆包裝函式結果一致）；載入器行為 TC-189（尺寸不足的 `.dng` + 預覽用途 → 進 RAW 解碼）／TC-190（同檔 + 側欄縮圖 → 仍直接給 bytes，P-11/P-13 維持寬鬆）／TC-191（同檔 + 匯出 → 仍直接給 bytes）／TC-192（尺寸不足的**非 DNG** RAW + 預覽用途 → 仍給 bytes，不是失敗）／TC-193（預覽圖已達 2800 的 `.dng` 不受影響） |
| **測試類型** | 單元測試（14 案例，跨 `test/dng_preview_extractor_test.dart` 與 `test/dart_image_loader_test.dart`，容器由 Task 1 的合成產生器建出） |
| **背景** | 使用者裁決 G-2：內嵌預覽圖沒有任何一張達到要求尺寸時，該檔改走 RAW 解碼，而不是拿一張過小的預覽圖充數。作用範圍經 A-5／A-6 兩次收斂：只套用在**預覽路徑且限 `.dng`**。側欄維持寬鬆（P-11/P-13）；匯出維持寬鬆（該路徑沒有 RAW 解碼可退，嚴格化會把「匯出一張略小的圖」變成「匯出失敗」）；非 DNG 的 RAW 同理，因為載入器的 RAW 解碼逃生口本身就只對 `.dng` 開放。方向值部分：原本只做 null 預設，任何超出 EXIF 合法範圍 1..8 的值都會原封不動流進下游的方向烘焙 |
| **預期結果** | 如上逐條 |
| **狀態** | ✅ 已通過（`+46: All tests passed!`，RC=0 自捕，`scripts/tmp/m7-t2/green-both.txt`）。四次突變驗證各自只讓對應斷言轉紅：拿掉範圍檢查只紅 0 與 9 兩列、1 與 8 維持綠；拿掉尺寸拒絕只紅兩條 `minLongEdge` 斷言；拿掉載入器接線只紅 TC-189；把守衛改成不限 `.dng` 只紅 TC-192，實得 `NativeImageFailure`——這一條把 A-6 從紙上論證變成實測結果。突變全部還原 |

> 效能驗收條件在本樣本集上為**空集合**：26 個樣本中 0 個因這條規則改變路徑（13 個本來就走 RAW 解碼、13 個預覽圖本來就達標），證據 `scripts/tmp/m7-t2/newly-routed.txt`。這是這份樣本集的性質，不是「世上不存在這種檔案」的證明——一張內嵌預覽只有 1024 像素的 DNG 就會被新導向。

---

### TC-172~176｜側欄 RAW 退路的快取編碼由 PNG 改為 JPEG q80（M7 Task 5）

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-172（恰好等於重編門檻的輸入原樣通過，邊界為 `<=`）／TC-173（超過門檻者重編為 JPEG：斷言 SOI 標記 `FF D8`、且能反解回長邊 ≤ 200 的影像）／TC-174（無法解碼的超門檻輸入仍退回原始 bytes，不讓該列消失）／TC-175（`jpegFromOrientedPixels` 把 EXIF 方向 6 烘進可解碼的 JPEG）／TC-176（品質參數可調且確實改變體積，q30 < q95） |
| **測試類型** | 單元測試（`test/sidebar_thumbnail_codec_test.dart`） |
| **背景** | 原始碼註解自己記著當初選 PNG 的理由：`dart:ui` 只能編 PNG，等匯出功能引入 `image` 套件後就可改 JPEG。該前提已成立，這是把 M6 的緩議項目兌現。兩個函式的結構不變（同一次解碼、同樣的方向烘焙與長邊縮放），只換編碼那一步 |
| **預期結果** | 如上逐條；PNG 路徑必須完全移除而非並存（`grep -rn "pngFromOrientedPixels\|ImageByteFormat.png" lib/` 無列，RC=1） |
| **狀態** | ✅ 已通過（全套 311 測試 `All tests passed!`，RC=0 自捕，`scripts/tmp/m7-t5/fullsuite2.log:1554-1555`）。紅→綠留證：修改前兩個函式實得 `[137, 80]`（PNG magic）而非預期的 `[255, 216]`，RC=1 自捕 |

> **體積結論與其適用範圍**（`scripts/tmp/m7-t5/size-comparison.md`，8 個真實 DNG 樣本）：JPEG q80 相對 PNG 為 4.15×–6.38×、整體 5.06×（354,159 B → 69,929 B），僅量位元組，未量 UI 延遲或記憶體（C-6 屬使用者自量）。**但這個優勢是照片類內容的性質，在低熵的人工合成影像上會反轉**——實測條紋圖 PNG 5,739 B 勝過 JPEG 14,634 B。因此本組刻意**沒有**寫「JPEG 比較小」的斷言：那只會證明測試圖被挑對了。未來若有人用產生的測試圖做基準而得到相反結論，請先讀這段再決定是否翻案（同 memory.md G-016）。

---

### TC-200~205｜結構損毀的 DNG 與「單純沒有預覽圖」必須分開（M7 Task 3）

| 欄位 | 內容 |
|------|------|
| **測試 ID** | TC-200（損毀容器 + 預覽用途 → `DNG_PARSE_FAILED`，不再進 RAW 解碼）／TC-201（同一損毀容器 + 側欄 → 仍是 `NO_THUMBNAIL`，側欄分支未動）／TC-202（`local_data/photo_samples/DNG` 中每一張真正無預覽的 DNG 仍回 `NeedsRawDecode`；迴圈斷言 `covered > 0`，空樣本集無法矇混通過）／TC-203（G-2 判定尺寸不足但完好的候選 probe 出 `jpeg == null, malformed == false`——刻意的 miss 不是損壞）／TC-204（`probeEmbeddedJpeg` 三態：損毀 → malformed；完好 → 有 jpeg；非 TIFF 垃圾檔在 IFD0 之前就失敗 → 兩者皆否）／TC-205（`extractEmbeddedJpeg` 與其全尺寸包裝函式對同一損毀輸入仍回 `null`——新 API 是「加上去」而非「遷移」） |
| **測試類型** | 單元測試（`test/dart_image_loader_test.dart`，損毀容器由合成產生器以「IFD0 仍可走訪、但每個 strip 位移都指到檔尾之外」的方式建出） |
| **背景** | 稽核發現結構壞掉的 `.dng` 會被當成單純沒有預覽圖，交給 RAW 解碼器慢慢失敗後吐一個泛用錯誤。根因是候選蒐集函式對「不是候選」與「候選讀不到」用同一個 `continue`，在呼叫端無法區分。詳見 memory.md AD-022 |
| **預期結果** | 如上逐條 |
| **狀態** | ✅ 已通過（全套 317 測試 `All tests passed!`，宣告數 == 實跑數，RC=0 自捕，紀錄自 `+0` 起連續無中斷）。三次突變各自只讓預期的斷言轉紅；其中最有價值的一次是把 G-2 的尺寸不足 miss 強制標成 malformed，結果讓 Task 2 的路徑轉紅——代表若把損壞的定義擴大一行，會無聲吃掉前一項任務的裁決，而測試會當場喊出來 |

> **已知未覆蓋（parking-lot，非通過項）**：strip 位移在範圍內、但內容不是 JPEG 位元流的分支沒有測試——合成容器產生器已凍結、產不出這個形狀。經檢視正確但未實測。

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
| 測試案例總數（EXIF 重新命名新增，commit `58fe681`）| +33（TC-024~TC-056，各檔逐一 `grep -c "test(\|testWidgets("` 核對過與計畫聲稱數一致）| — | — |
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

- `scripts/build_apps.py`：統一 build 入口（native `dng_processor` + Flutter）；取代已刪除的 `build.sh` / `build_windows.ps1` / `build_windows.py`。預設建置 macOS release app，支援 `macos`、`ios`、`android`、`android-apk`、`android-aab`、`web`、`windows`、`linux`、`all`。
  - **範例指令**：`python3 scripts/build_apps.py`、`python3 scripts/build_apps.py android`、`python3 scripts/build_apps.py --check`、`python3 scripts/build_apps.py android-aab --release`
  - **必要輸入**：可選 target；可選 `--debug` / `--profile` / `--release`；可選環境變數 `BUILD_MODE`；`--native auto|always|never`、`--macos-arch`、`--clean`、`--cfa-sample-dng`、`--no-colour-gate`
  - **契約檢查摘要**：檢查 Flutter CLI、target 是否支援、host OS 是否支援該 desktop target（明確指定不支援的 target 會失敗而非略過）；Android 套用 JDK 25 / 21 / 17 fallback；Windows 自行以 vswhere 定位 VS 並注入 vcvars64。`--check` 只跑檢查不建置，缺任一必要工具即 exit 非 0。
  - **失敗語意**：未通過 runbook S4 色彩閘就放置原生庫，會在 Phase 0 被拒絕；`--no-colour-gate` 是明示逃生口且該次執行 exit 2。失敗的執行印 `ABORTED`，不印 `DONE`。
  - **已知限制**：native CMake 路徑（Phase 0b/1）從未實際執行過；所有 Windows-only 分支為推理與單元探針，未在 Windows 上跑過。Halide 的 sha256 為首次信任（TOFU），非獨立驗證的 pin。
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
| 2026-08-20 | EXIF 重新命名（Task 1-9，commit `58fe681`）| — | 本輪僅補文件（Task 10），無執行環境可重跑 `flutter test`/`flutter analyze`；各新增測試檔的 TC 數已用 `grep -c` 逐檔核對與計畫聲稱一致（見上方測試案例矩陣），但整套綠燈狀態沿用各任務自身 commit 訊息與 review 紀錄，未在本輪重新實跑，待下一次有執行環境的 session 或使用者確認 |

**已知限制**：TC-019 ~ TC-022 為本輪新增，覆蓋 sidebar 重載迴歸、tier-1/tier-2 preload、DNG 解碼、回收模式，但仍是每個測試檔一條摘要 TC，未逐一案例對應（例如 `image_preload_controller_test.dart` 22 個案例只對應 TC-020 一條）。`flutter build macos` 與 macOS 實機視覺覆核（Trash、`.trash` 回收、Finder 開啟方式冷啟動、DNG 大圖顯示）本輪未重跑，沿用先前紀錄。

**EXIF 重新命名已知限制**（2026-08-20，見 `memory.md` TD-015~TD-018）：plan Task 6 Step 4 / Task 8 Step 6 的實機 `flutter run -d macos` 驗收未執行（agent-driven UI 驗證本專案禁止），改以 headless Swift probe 對 `local_data/photo_samples/` 驗證原生 EXIF 讀取；`{direction}`（GPS）未曾對含 GPS 的真實照片驗證過；`AppState.cancelRename()`/`isRenaming` 與 `readMetadataFor` 的 >500 筆 chunking 在 AppState 層無直接測試（皆由 service 層對應案例覆蓋）。刻意排除範圍：Windows/Android/Linux 原生 EXIF（僅 Dart `exif` package fallback）、重新命名資料夾內子集、跨資料夾搬移檔案。

---

## 常見失敗與排查方向

| 症狀 | 常見原因 | 排查方向 |
|------|----------|---------|
| `flutter test` 全部失敗 | 依賴未 mock（如 `Directory`、`File`）| 使用 `when()` mock 檔案系統 |
| `NativeThumbnailService` 回傳 null | macOS MethodChannel 未實作 | 確認 `macos/Runner/AppDelegate.swift` handler |
| `setState()` / `notifyListeners()` 未觸發 | 非同步時序問題 | 使用 `await tester.pumpAndSettle()` |
| Widget test 找不到 Finder | 測試 ID 變了 | 確認 widget key 或 text label |
| macOS native build 失敗 | Runner Swift / MethodChannel 編譯問題 | 執行 `flutter build macos` 並查看 `macos/Runner/AppDelegate.swift` |
| Android build 在 Gradle Kotlin DSL 階段失敗並顯示 `25.0.2` | 舊版 Gradle/Kotlin toolchain 不支援 JDK 25 | 使用 `scripts/build_apps.py`；目前已升級到 Gradle 9.1.0 + AGP 9.0.1 + Kotlin 2.3.21 相容模式，macOS 上優先套用 Temurin JDK 25 |
