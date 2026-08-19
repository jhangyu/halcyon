---
date: 2026-08-19
title: "Halcyon — 任務真實狀態來源 (Task)"
---

## 🧭 檔案維護政策

**用途**：管理所有任務清單與執行狀態，是「現在要做什麼」與「做到哪裡」的唯一真實來源。

**更新時機**：
- 每次切換 ACTIVE 任務時。
- 每個 Task 完成或階段性推進後。
- 發現子任務完成後，應同步更新摘要。

**必填欄位**：`date`（YYYY-MM-DD）、`title`、頂部 `🔴 現在進行中 (ACTIVE)` 區塊。

**跨檔同步對象**：
- `handover.md` 的 `下一步` 需與 ACTIVE Task 一致。
- `memory.md` 的 Gotchas / 架構決策需同步更新。
- `plan.md` 的對應 Phase 狀態需同步更新。

---

## 🔴 現在進行中 (ACTIVE)

- **Task**: 19 — Zoom 狀態下沉至 View 層（`ZoomController`）✅ **已完成並驗收**（commit `6d74cd4`，2026-08-19）
- **中斷點與交接 (Handover)**: 新增 `lib/views/zoom_controller.dart`；`MainScreen` 建立/釋放並注入 `MainDetailView(zoom:)`；`AppState` 已無 zoom 欄位與方法。`flutter analyze lib test` 0 issues、`flutter test` 115 綠（新增 11 案例 = TC-023，以 9 個 mutant 證明鑑別力）、`flutter build macos --release` 成功。使用者已用 release build 完成 `docs/logs/2026-08-19/zoom-state-extraction-handover.md` §12 的 7 項手動驗收，**全數通過**。收斂契約與 parking-lot 見 `docs/logs/2026-08-19/task19-convergence-contract.md`。
- **下一個子步驟**: 無。下一個任務由使用者指定；parking-lot 五項（listener 的 widget 級測試、`transformCtrl.dispose()` 斷言、`MainDetailView` 的 `const`、`maxScale` 與字面 5.0 未綁定、controller 生命週期縮短）待裁決。

- **前一個 Task**: 26 — Sidebar 縮圖預載改為 itemBuilder 驅動（commit `d0eb855`）
- **中斷點與交接 (Handover)**: 已完成。`SidebarView` 不再用 `ScrollController` listener 計算可視範圍，改由 `ListView.builder` 的 `itemBuilder` 逐格回報建置到的 index，一幀結束後彙整成範圍呼叫 `AppState.preloadThumbnails()`；`ImagePreloadController` 接手 prefetch margin（`thumbnailPrefetchMargin = 20`）並新增 generation 計數器讓過期批次自我中止。`flutter test` 85 個測試通過（exit code 0，2026-08-19 重跑），`flutter analyze lib test` 0 issues。詳見 `handover.md` 本輪交接摘要。
- **下一個子步驟**: 無立即待辦；`git status --short` 除本次文件同步與非 in-scope 目錄外無其他改動。

**文件債狀態**：本檔此前長期停留在 Task 12，Task 22~26（DNG 解碼整合、影像切換延遲 tier-1/tier-2 sliding preload、Finder 開啟方式、回收模式、sidebar itemBuilder 預載）已於本輪對照 `git log` 逐一核實並補登於下方任務清單，文件債已清償。

---

## 任務清單

### Task 1｜Flutter macOS 原生 MethodChannel 實作 ✅ 已完成

**目標**：在 Flutter macOS Runner 中建立原生縮圖提取 MethodChannel handler，使 `NativeThumbnailService.getThumbnail()` 在 macOS 上可用。

**子任務**：
- [x] 1.1 建立 `macos/Runner/AppDelegate.swift` 中的 `FlutterMethodChannel` handler（含 CGImageSource thumbnail 邏輯）
- [x] 1.2 參考 `ios/Runner/AppDelegate.swift` 中既有實作，確保 `targetSize` 參數正確傳遞
- [x] 1.3 驗證：`flutter analyze` / `flutter test` / `flutter build macos` 通過；request purpose 測試覆蓋 sidebar 200px 與 preview 10000px 分流
- [x] 1.4 更新 `memory.md` 的 G-004 為「已修復」

**驗收標準**：macOS native bridge 可編譯；Flutter request contract 以明確 purpose 區分 sidebar thumbnail 與 preview；`flutter analyze` / `flutter test` / `flutter build macos` 皆通過。真實照片資料夾視覺覆核仍建議由使用者在本機資料夾補做。

---

### Task 2｜SwiftUI 版本狀態持久化實作 🗑️ 已退役

**退役原因**：SwiftUI 版本不再作為主線產品維護；專案收斂為 Flutter app + macOS/iOS native bridge。原持久化需求由 Flutter JSON 狀態機制承接。

**狀態**：已由 Task 7 關閉，未實作子任務不再追蹤。

---

### Task 3｜Flutter 單元測試覆蓋 ✅ 已完成

**目標**：建立有意義的單元測試與 widget test，取代預設 `widget_test.dart` smoke test。

**子任務**：
- [x] 3.1 建立 `test/app_state_test.dart`：測試 `AppState`（詳見 `unit_test.md` TC-001 ~ TC-004 / TC-009 / request purpose）
- [x] 3.2 建立 `test/photo_item_test.dart`：測試 `PhotoItem.bestFileToLoad` 與格式 registry
- [x] 3.3 更新 `test/widget_test.dart`：保留有效 empty-folder smoke test
- [x] 3.4 執行 `flutter test` 確認全部通過

**驗收標準**：`flutter test` 全部通過；目前 11 個測試通過。

---

### Task 4｜SwiftUI 版本功能對齊 🗑️ 已退役

**退役原因**：SwiftUI 版本不再作為主線產品維護；避免持續雙軌同步 auto-advance、overwrite-existing、Settings UI 與 markCurrent 行為。

**狀態**：已由 Task 7 關閉，未實作子任務不再追蹤。

---

### Task 5｜刪除操作改為 Trash 而非永久刪除 ✅ 已由 Task 12 / Task 25 取代完成

**原目標**：將 Flutter `AppState.deleteTrashed()` 從 `file.delete()`（永久刪除）改為移到垃圾桶。

**現況**：Task 12 已建立 `TrashService`（`lib/services/trash_service.dart:6`，`halcyon/trash` MethodChannel）取代永久刪除；Task 25（回收模式）在此之上新增資料夾內 `.trash` 路徑（`lib/services/photo_file_actions.dart:91` `recycleTrashed()`），兩條路徑皆不再使用裸 `file.delete()`。本任務原始子任務已被後續任務吸收，不再單獨追蹤。

---

### Task 6｜修正 JPG 主圖全尺寸載入與 RW2 支援 ✅ 已完成

**目標**：修正 Flutter 版開啟 JPG 資料夾時主圖只顯示縮圖的問題，並讓 Flutter/SwiftUI 掃描流程支援 Panasonic RAW `.rw2`。

**子任務**：
- [x] 6.1 在 Flutter `AppState.loadFolder()` 支援 `.rw2`
- [x] 6.2 在 SwiftUI `AppState.loadFolder()` 支援 `rw2`
- [x] 6.3 調整 macOS `AppDelegate.swift`：非 RAW 主圖請求使用高解析/全尺寸輸出，小圖請求保留縮圖路徑
- [x] 6.4 修正 `AppDelegate.swift` 既有 `CGImage?` optional unwrap 編譯錯誤
- [x] 6.5 驗證：`flutter analyze`、`flutter test`、`flutter build macos`

**驗收標準**：`.rw2` 可被掃描進照片清單；JPG 主圖以主圖 targetSize（10000）取得高解析輸出，不再退化成 sidebar 縮圖；macOS build 不再出現 `CGImage?` optional unwrap error。

**驗證結果**：`flutter analyze` 0 issues；`flutter test` 全通過；`flutter build macos` 成功產出 release app。實機 JPG/RW2 視覺覆核仍需使用者以真實照片資料夾確認。

---

### Task 7｜Flutter 主線架構整理與 SwiftUI 退役 ✅ 已完成

**目標**：將專案定位收斂為 Flutter app + macOS/iOS native bridge，退役未被主線引用且功能落後的 SwiftUI package，並登錄下一階段架構改善任務。

**子任務**：
- [x] 7.1 更新 `task.md` / `plan.md` / `memory.md` / `handover.md` 的專案定位
- [x] 7.2 更新 `file_index.md` / `unit_test.md` / README，移除 SwiftUI 主線引用
- [x] 7.3 刪除 `Sources/PhotoSelector/` 與根目錄 `Package.swift`
- [x] 7.4 新增後續架構改善任務（Task 8~12）
- [x] 7.5 驗證：`flutter analyze`、`flutter test`、`flutter build macos`

**驗收標準**：SwiftUI package 不再存在於專案檔案地圖；核心文件不再把 SwiftUI 功能對齊列為待辦；Flutter 驗證三項通過。

**驗證結果**：`flutter analyze` 0 issues；`flutter test` 全通過；`flutter build macos` 成功產出 release app。

---

### Task 8｜影像載入 Request Contract 語意化 ✅ 已完成

**目標**：將 `NativeThumbnailService.getThumbnail()` 的用途從單一 `targetSize` 推斷，改為明確 request purpose（sidebar thumbnail / preview image），降低主圖退化為縮圖的風險。

**驗收標準**：Flutter 與 macOS native bridge 以 `ImageRequestPurpose.preview` / `sidebarThumbnail` 明確表示載入用途；AppState 測試覆蓋 preview 與 sidebar request。

---

### Task 9｜拆分 Flutter AppState 職責 ✅ 已完成

**目標**：將掃描、狀態持久化、影像快取/預載、檔案操作從 `AppState` 拆出成可測服務，讓 `AppState` 只負責協調 UI 狀態。

**驗收標準**：已建立 `PhotoLibraryScanner`、`PhotoStatusStore`、`ImagePreloadController`、`PhotoFileActions`；核心流程測試不依賴完整 UI。

---

### Task 10｜支援格式 Registry 統一化 ✅ 已完成

**目標**：集中定義支援副檔名與優先順序，避免 Flutter 掃描、`PhotoItem.bestFileToLoad`、native RAW 判斷與文件不同步。

**驗收標準**：Flutter 端支援格式由 `SupportedPhotoFormats` 定義；掃描與 `PhotoItem.bestFileToLoad` 共同使用 registry；測試覆蓋 `.rw2`。

---

### Task 11｜檔案掃描與 PhotoItem 單元測試補強 ✅ 已完成

**目標**：補上 `.rw2`、AppleDouble、隱藏檔、RAW/JPG 分組、best file priority 等低成本高價值測試。

**驗收標準**：`flutter test` 新增掃描/狀態/PhotoItem/registry/request purpose 測試，覆蓋 `unit_test.md` TC-001、TC-002、TC-004、TC-005、TC-006、TC-009。

---

### Task 12｜Flutter Trash MethodChannel ✅ 已完成（自動化驗證通過）

**目標**：將 Flutter `deleteTrashed()` 從永久刪除改為 macOS Trash，避免不可逆刪除照片。

**子任務**：
- [x] 12.1 評估方案：Swift `FileManager.trashItem` 透過 MethodChannel（`halcyon/trash` channel）
- [x] 12.2 新增 `lib/services/trash_service.dart`：Flutter 端 MethodChannel 呼叫介面
- [x] 12.3 在 `macos/Runner/AppDelegate.swift` 新增 `trash_service` handler
- [x] 12.4 修改 `PhotoFileActions.deleteTrashed()` 改呼叫 `TrashService`；失敗時保留原檔與狀態
- [x] 12.5 補充 Task log、`unit_test.md`；新增 Dart trash 行為測試
- [x] 12.6 驗證：`flutter test` 84 個測試通過（exit code 0，含 trash 行為案例）。**未確認**：`flutter analyze` / `flutter build macos` 與真實照片資料夾手動移入垃圾桶的視覺覆核，本輪同步未重跑，狀態沿用既有紀錄。

**驗收標準**：已標記 trashed 的檔案移入 macOS Trash；失敗時保留錯誤訊息且不清除狀態；`flutter analyze` / `flutter test` / `flutter build macos` 通過。

**目前狀態**：自動化 `flutter test` 已通過（2026-08-19 重跑，84 個測試，exit code 0）。`flutter analyze` / `flutter build macos` 與實機垃圾桶覆核仍待下一輪確認並記錄。

---

### Task 15｜PhotoFileActions 單元測試補強 🔲 待辦

**目標**：補上 `PhotoFileActions` copy/move/delete 的單元測試，消除資料操作無測試保護的風險（TD-010）。

**子任務**：
- [ ] 15.1 建立 `test/photo_file_actions_test.dart`
- [ ] 15.2 測試 `processStarred()` — copy 成功、目的地已存在、來源不存在（各一案例）
- [ ] 15.3 測試 `processStarred()` — move 模式成功、sidecar AppleDouble 清理
- [ ] 15.4 測試 `deleteTrashed()`（Task 12 完成後）— Trash 成功、失敗保留狀態
- [ ] 15.5 更新 `unit_test.md` 登錄新測試案例

**驗收標準**：`flutter test` 新增 5+ 測試案例且全數通過；覆蓋 copy/move/trash 三條路徑的成功與失敗情境。

---

### Task 16｜G-005 Toggle-off 缺測試覆蓋 🔲 待辦（行為已確認正確，僅缺回歸測試）

**現況**（2026-08-19 對照 `lib/providers/app_state.dart:337-351` 核實）：`markCurrent()` 的 toggle-off 分支（`item.status == status` 時，`app_state.dart:340-341`）只執行 `item.status = PhotoStatus.unmarked`，**不會**呼叫 `nextPhoto()`；`_autoAdvance` 判斷式（`app_state.dart:344`）只存在於「設定新狀態」的 else 分支內。也就是說 G-005 原先描述的「toggle off 時不論如何都會前進」的行為**目前不成立**——程式碼已是預期行為（toggle off 不前進）。原始 Task 16 的子任務 16.1/16.2（確認並修正行為）已無需執行。

**唯一剩餘缺口**：`test/app_state_test.dart` 沒有對應的 regression test 鎖住這個行為（見 `unit_test.md` TC-014），若日後重構 `markCurrent()` 沒有測試會發現迴歸。

**子任務**：
- [x] 16.1 確認預期行為：對照 `app_state.dart:337-351` 核實，toggle off 已不前進，無需再問使用者（原子任務 16.1「待確認」已解除）
- [x] 16.2 修改邏輯：不需要，現況已正確
- [ ] 16.3 在 `test/app_state_test.dart` 新增 toggle-off 不前進的 regression test（TC-014）
- [x] 16.4 更新 `memory.md` G-005 狀態為已確認正確（本輪已更新）

**驗收標準**：`test/app_state_test.dart` 新增 TC-014 對應案例並通過；`flutter test` 全數通過。

---

### Task 17｜macOS AppDelegate.swift 錯誤處理強化 🔲 待辦

**目標**：強化 `macos/Runner/AppDelegate.swift` 的錯誤處理，防止 CIContext/CIFilter 邊界情況導致 native crash（TD-012）。

**子任務**：
- [ ] 17.1 在 `CIContext.init`、`CIFilter.init` 加入 optional guard 或 try-catch 等效防護
- [ ] 17.2 在 EXIF orientation enum cast（`Int32`）加入範圍驗證（有效值：1–8）
- [ ] 17.3 評估大型 RAW 檔案（>100MB）解碼時是否需要記憶體上限保護
- [ ] 17.4 驗證 `flutter build macos` 通過；記錄 Task log

**驗收標準**：native 端對無效輸入回傳明確 `FlutterError`，不 crash；`flutter build macos` 成功；`memory.md` TD-012 更新。

---

### Task 18｜CI/CD GitHub Actions 自動化 🔲 待辦

**目標**：建立 GitHub Actions workflow，每次 push 自動執行 `flutter analyze`、`flutter test`、`flutter build macos`，防止回歸（Phase 5 交付物）。

**子任務**：
- [ ] 18.1 建立 `.github/workflows/ci.yml`：triggers on push/PR to main
- [ ] 18.2 Job 1：`flutter analyze` + `flutter test`（在 macOS runner）
- [ ] 18.3 Job 2：`flutter build macos --release`（artifact upload 可選）
- [ ] 18.4 在 `unit_test.md` 登錄 CI 執行命令
- [ ] 18.5 更新 `file_index.md` 加入 `.github/` 目錄

**驗收標準**：PR 頁面顯示 CI 狀態；`flutter analyze` + `flutter test` 必須通過才可合併。

---

### Task 19｜Zoom 狀態下沉至 View 層（消除反向資料流）✅ 已完成（2026-08-19，待使用者手動驗收）

**目標**：將 `AppState` 中的 zoom/animation 純 View 狀態移至 view 層，消除 view 直接寫入 provider 的反向資料流（G-010、TD-011）。

**實作結果（方案 B，與下方原始子任務規劃不同——已由使用者拍板）**：狀態沒有搬進 `_MainDetailViewState`，而是搬進獨立的 `lib/views/zoom_controller.dart`（`ZoomController extends ChangeNotifier`），由 `_MainScreenState` 建立與 dispose 並注入 `MainDetailView(zoom: _zoom)`。原因：controller 若建在 `MainDetailView` 內，照片切換重建時會遺失縮放狀態；獨立 controller 另使縮放邏輯可脫離 widget 做單元測試。詳見 `memory.md` AD-015 與 `docs/logs/2026-08-19/zoom-state-extraction-handover.md`。

**現況核實（2026-08-19，取代 2026-05-04 架構審查行號）**：以下欄位確認仍存在於 `AppState` 且仍是純 View 層狀態：
- `app_state.dart:113` `transformCtrl`（`TransformationController`）
- `app_state.dart:114` `pointerPosition`（mouse hover 位置）
- `app_state.dart:115` `lastKnownCenter`（layout 中心，`LayoutBuilder` 每幀寫入）
- `app_state.dart:118` `targetMatrix`（動畫目標矩陣，one-shot 旗標）
- `app_state.dart:119` `shouldAnimateZoom`（one-shot 觸發旗標）
- `app_state.dart:298-334` `stepZoomIn()`/`stepZoomOut()`/`_zoomBy()` 目前仍是 `main_screen.dart:99,102`（`↑`/`↓` 鍵）呼叫的唯一入口

以下反向寫入確認仍存在（行號已更新）：
- `main_detail_view.dart:99` `context.read<AppState>().shouldAnimateZoom = false`（view 直接關閉 provider 旗標）
- `main_detail_view.dart:220` `context.read<AppState>().lastKnownCenter = center`（`LayoutBuilder` callback 每次 rebuild 寫入）
- `main_detail_view.dart:282` `context.read<AppState>().pointerPosition = event.localPosition`（`MouseRegion.onHover`）
- `main_detail_view.dart:285` `context.read<AppState>().pointerPosition = null`（`MouseRegion.onExit`）
- 額外發現（本輪新記錄，2026-05-04 審查未列）：`main_detail_view.dart:32` `_animController` 的 listener 每個動畫 tick 都寫入 `context.read<AppState>().transformCtrl.value = _zoomAnimation!.value`，是比上述 4 處更高頻的反向寫入。

**子任務**：
- [x] 19.1 新增 `lib/views/zoom_controller.dart`，持有五個 zoom 欄位並自行建立/釋放 `transformCtrl`（取代原規劃的「欄位放進 `_MainDetailViewState`」）
- [x] 19.2 `_zoomBy()` 邏輯搬入 `ZoomController`；動畫改由 controller 的 listener（`_onZoomRequested`）觸發，不再於 `build()` 內讀旗標、不再用 post-frame callback 清旗標
- [x] 19.3 keyboard zoom（`main_screen.dart`）改為直接呼叫 `_zoom.stepZoomIn()` / `_zoom.stepZoomOut()`（未使用 GlobalKey）
- [x] 19.4 `AppState` 已移除五個 zoom 欄位與 `stepZoomIn()`、`stepZoomOut()`、`_zoomBy()`；`dispose()` 已移除 `transformCtrl.dispose()`
- [x] 19.5 `flutter analyze lib test` 0 issues；`flutter test` 全綠（新增 `test/zoom_controller_test.dart` 9 案例 = TC-023）
- [ ] 19.6 使用者手動驗收（`docs/logs/2026-08-19/zoom-state-extraction-handover.md` §12 七項清單）——自動化測試涵蓋不到連續互動，此項未做完不算收尾

**驗收標準**：`AppState` 不再持有任何 zoom/animation 欄位；`main_detail_view.dart` 不再對 `AppState` 做 zoom setter 操作（僅剩 `openFolder()` 與 `setViewportSize()` 兩處與 zoom 無關的呼叫）；`flutter test` 全數通過；無功能回歸。

---

### Task 20｜SidebarView iconColor 重複邏輯提取 🔲 待辦

**目標**：消除 `sidebar_view.dart` 中三處重複且色值不一致的 iconColor 判斷邏輯（TD-014），提取為私有 helper（Quick Win，1–2 小時）。

**現況核實（2026-08-19，取代 2026-05-04 架構審查行號——回收模式改動後行號已全部位移，且重複處從 3 處增至 4 處）**：
- `sidebar_view.dart:150`：header title color（`32,32,32`，與其餘處不同值）
- `sidebar_view.dart:197`：清單選取列 title color（`59,59,59`，內嵌於 `itemBuilder` 的 `TextStyle`）
- `sidebar_view.dart:266-268`：`_buildTopActions()` 內 `iconColor`（`59,59,59`）
- `sidebar_view.dart:287-289`：`_buildActionMenu()` 內 `iconColor`（`59,59,59`，與上一處完全重複）
- `sidebar_view.dart:322-324`：`_buildActionMenu()` 的 `itemBuilder` 閉包內 `actionTextColor`（`59,59,59`，第四處重複）

（讀取時另一 session 正對本檔做未提交的 flicker-fix，上列行號取自本輪讀取當下的檔案內容，非最終落地版本；下一輪核對時請重新抓行號。）

**子任務**：
- [ ] 20.1 在 `_SidebarViewState` 新增私有 helper `Color _iconColor(BuildContext context)`，統一使用 `59,59,59` 作為 light mode icon/文字色值
- [ ] 20.2 將 197、266-268、287-289、322-324 四處改呼叫 `_iconColor(context)`
- [ ] 20.3 確認 Line 150 的 header title color（`32,32,32`）是否應與其餘 `59,59,59` 一致（如是，一同修正；如否，加 comment 說明差異）
- [ ] 20.4 `flutter analyze` / `flutter test` 通過

**驗收標準**：`sidebar_view.dart` 中 iconColor 邏輯只定義一次；`flutter analyze` 0 issues；無視覺回歸。

---

### Task 22｜DNG 全尺寸解碼整合（`flutter_dng_decoder`）✅ 已完成

**目標**：為沒有內嵌可用全尺寸 JPEG 預覽的 DNG 檔案提供真正的全尺寸 RAW 解碼路徑，取代降級顯示縮圖。

**已落地**（`8e6a1cf`、`b557261`、`bcc096b`、`6d7b8bd`、`f55915c`、`61c48fa`、`87d8463`，2026-08-16）：
- `lib/services/dng_decode_contract.dart`：`DecodedRgba` / `DngFullDecoder` 介面契約，讓解碼路徑可用 fake decoder 測試而不必載入原生 dylib。
- `lib/services/dng_decode_service.dart`：整合 `dng_processor` package（`package:dng_processor/src/dng_decoder_service.dart`，見檔頭 `// ignore: implementation_imports` 註記）。
- `lib/services/decoded_rgba_image_provider.dart`：已解碼 RGBA 緩衝轉 `ui.Image` provider。
- `lib/perf/perf_driver.dart`、`lib/perf/perf_log.dart`：永久保留、`HALCYON_PERF_DIR` 環境變數 gate 的效能埋點（`test/dng_decoder_smoke_test.dart`、`test/dng_extractor_swift_test.dart`、`test/decoded_rgba_image_provider_test.dart` 覆蓋）。

**驗收標準**：DNG 檔案在無內嵌全尺寸 JPEG 時可透過 `dng_processor` 解碼顯示；`flutter test` 通過對應測試檔；效能埋點在未設定 `HALCYON_PERF_DIR` 時為結構性 no-op。

**驗證結果**：本輪重跑 `flutter test`（85 個測試，含上述三個測試檔）與 `flutter analyze lib test`（0 issues）皆通過（2026-08-19）。`flutter build macos` 本輪未重跑。

---

### Task 23｜影像切換延遲 Tier-1/Tier-2 Sliding Preload ✅ 已完成

**目標**：降低圖片切換延遲，在維持記憶體安全的滑動視窗前提下新增全尺寸解碼快取層。

**已落地**（`adfa624`、`e64b7aa`、`d574a9b`、`be38953`、`de7cf5b`、`5a8684e`、`bbde960`、`1339a25`、`3cbc5ff`，2026-08-16）：
- `lib/services/image_preload_controller.dart`：tier-1（視窗解析度預解碼快取，500MB `ImageCache`）與 tier-2（全尺寸解碼層，與 tier-1 並存）。
- 修正 BLOCKER 1（過期 tier-2 ready flag）、B2、BLOCKER 3（tier-2 completion flag 需為必要條件而非可省略）三個 review 發現的問題。
- `test/image_preload_controller_test.dart`：22 個測試涵蓋滑動視窗驅逐、tier-1/tier-2 raw-decode 路徑、decode/dispose 平衡。

**驗收標準**：`flutter test` 通過 `image_preload_controller_test.dart` 全部案例；tier-2 完成旗標須與 tier-1 共同構成完整條件（BLOCKER 3 迴歸測試覆蓋兩個方向）。

**驗證結果**：本輪重跑 `flutter test` 該檔 22 個測試全數通過（2026-08-19）。

---

### Task 24｜Finder「開啟方式」冷啟動 ✅ 已完成

**目標**：支援使用者從 Finder「打開方式」直接啟動 Halcyon 並開啟指定照片所在資料夾。

**已落地**（`aefad64`，2026-08-17）：
- `lib/services/open_with_channel.dart`：`halcyon/open_with` MethodChannel，Push-only 設計（避免冷啟動時 Dart 詢問原生端而輸掉與 Flutter engine 初始化的競速）。
- macOS 端：`macos/Runner/AppDelegate.swift` 已實作；Windows／Android 尚未實作原生轉發（見檔頭註記）。
- 沙箱設定移除：macOS entitlements 移除 sandbox 限制以支援任意路徑的 Finder 開啟請求。

**驗收標準**：從 Finder 對支援格式的照片選擇「打開方式 → Halcyon」可正確開啟其所在資料夾並選取該照片。

**已知限制**：Windows／Android 平台轉發未實作，`OpenWithChannel.listen()` 在這些平台上目前恆為 no-op（尚無對應原生呼叫）。真機 macOS 冷啟動視覺覆核建議由使用者補做。

---

### Task 25｜回收模式（`.trash`）批次刪除 ✅ 已完成

**目標**：新增資料夾內回收模式，將已標記刪除的照片（含同名 sibling RAW 檔）批次移入資料夾內 `.trash` 子目錄，而非（或除了）macOS 系統垃圾桶。

**已落地**（`9520ab4` spec、`01694dc` plan、`3cc1e79` 收斂契約、`8646f86`、`128be52`、`bd38051`、`eb6d282`、`1cc846e`、`ffeae4e`、`307afec`，2026-08-17～2026-08-18）：
- `lib/services/photo_file_actions.dart:91` `recycleTrashed()`：同名 sibling（`.cr2`/`.nef`/`.orf` 等）自動分組移入 `<dir>/.trash/`，同檔名碰撞附加 `-1`、`-2` 後綴（`_availablePath()`），回傳 `RecycleOutcome`（`movedCount` + `failures` 清單，見 `photo_file_actions.dart:14`）。
- `lib/views/photo_action_bar.dart`：mode-aware 刪除按鈕，右鍵切換回收模式／永久刪除模式。
- `lib/views/batch_delete_feedback.dart`：批次刪除成功走 status line，失敗則為阻斷式 `AlertDialog`（列出 `failures`）。
- `lib/views/sidebar_view.dart`：mode-aware 側邊欄狀態圖示與選單標籤。
- `680acb4`（2026-08-17，非本任務主線但相依）：修正 CR2/NEF/ORF 掃描分組邏輯，確保 sibling RAW 能正確與 JPG 同組。

**驗收標準**：回收模式下刪除已標記照片會移入 `.trash` 而非消失；失敗的檔案（例如權限拒絕）需在 `failures` 中回報且不中斷其餘批次；`test/photo_file_actions_test.dart`、`test/sidebar_view_test.dart`、`test/photo_action_bar_test.dart`、`test/batch_delete_feedback_test.dart` 覆蓋。

**驗證結果**：本輪重跑 `flutter test` 上述測試檔全數通過（2026-08-19）。

---

### Task 26｜Sidebar 縮圖預載改為 itemBuilder 驅動 ✅ 已完成

**目標**：修正回收/刪除/複製/移動觸發 `loadFolder()` 重新整理資料夾後，側邊欄縮圖快取被清空但捲動監聽器不會主動重新請求，導致捲動離開頂端的清單縮圖持續空白直到使用者再次捲動的問題。

**已落地**（`d0eb855`，2026-08-19）：
- `lib/views/sidebar_view.dart`：移除 `ScrollController` 監聽器（`_onScroll`），改由 `ListView.builder` 的 `itemBuilder` 呼叫 `_noteBuiltIndex(index)` 逐格記錄本幀建置到的 index，於 `addPostFrameCallback` 彙整成範圍後呼叫 `AppState.preloadThumbnails(first, last)`（回報「可視範圍」，不含 prefetch margin）。
- `lib/providers/app_state.dart:preloadThumbnails()`：文件註解更新為「呼叫端傳入可視範圍，margin 由 controller 決定」；初始化呼叫改為 `preloadThumbnails(0, 0)`（先前為硬編碼 `(0, 20)`），因為 sidebar 尚未 layout 完成時的暖身視窗現在由 controller 的 margin 提供。
- `lib/services/image_preload_controller.dart`：新增 `thumbnailPrefetchMargin`（20）常數；請求順序改為「可視列（由上到下）→ 視窗上下邊緣向外交錯」而非線性掃過整個 `start-20..end+20` 範圍，避免使用者實際看到的列排在 20 個畫面外列之後才被請求；新增 `_thumbBatchGeneration` 計數器，`reset()` 與每次新範圍呼叫都會遞增，讓過期批次（快速捲動或資料夾重載）在下一次 await 前自我中止，不再浪費 channel 往返或寫入已不存在清單的縮圖。
- `sidebar_view.dart`：選取列背景由外層 `Container` 改為 `ListTile.selectedTileColor`，容器本身改用 `Material`（而非 `Container`）以提供最近的 Material 祖先，消除 framework 對「ListTile 背景色/ink splash 可能不可見」的斷言警告（`test/sidebar_view_test.dart` 的 `drainListTileWarning()` 因此改為逐一排空而非只清一次）。

**新增測試**：`test/sidebar_view_test.dart`「every visible row is requested again after a folder reload」— 60 項清單捲動離開頂端後觸發 `loadFolder()`，斷言重新繪製的每一列都出現在重新請求清單中。

**驗收標準**：資料夾重載後，畫面上實際可見的縮圖列必定會被重新請求，不依賴使用者主動捲動；`flutter test` 全數通過。

**驗證結果**：`flutter test` 85 個測試通過（exit code 0，2026-08-19）；`flutter analyze lib test` 0 issues。`flutter build macos` 與真機視覺覆核本輪未重跑。

---

### Task 13｜專案資料夾結構整理 ✅ 已完成

**目標**：整理根目錄與 Flutter app 位置，讓正式程式碼、本機資料、封存產物與文件責任更清楚。

**子任務**：
- [x] 13.1 將 Flutter 主線整併至專案根目錄
- [x] 13.2 將專案層級圖示移至 `assets/icons/`
- [x] 13.3 將本機照片樣本移至 `local_data/photo_samples/`（git ignored）
- [x] 13.4 將封存與退役 build cache 移至 `artifacts/`（git ignored）
- [x] 13.5 更新 `README.md`、`file_index.md`、`handover.md`、`plan.md`、`memory.md`、`unit_test.md` 與 Task logs 中的路徑
- [x] 13.6 驗證 `flutter test`、`flutter analyze`、`flutter build macos`

**驗收標準**：根目錄只保留核心入口文件與清楚分類的一級目錄；Flutter app 可在新路徑完成測試、分析與 macOS build。

---

### Task 14｜Android Toolchain JDK 25 升級 ✅ 已完成

**目標**：升級 Android build toolchain，使專案可使用 Temurin JDK 25 編譯 Android APK。

**Log File**：[Task_14_Android_Toolchain_JDK25.md](docs/logs/2026-05-01/Task_14_Android_Toolchain_JDK25.md)

**子任務**：
- [x] 14.1 升級 Gradle wrapper 至 9.1.0
- [x] 14.2 升級 Android Gradle Plugin 至 9.0.1
- [x] 14.3 升級 Kotlin Gradle Plugin 至 2.3.21，並使用 AGP 9 相容模式
- [x] 14.4 補齊 `android/app/proguard-rules.pro` 與 NDK 28.2.13676358 設定
- [x] 14.5 更新 `scripts/build.sh`，Android build 優先使用 Temurin JDK 25
- [x] 14.6 驗證 `./scripts/build.sh android` 與 `flutter test`

**驗收標準**：`./scripts/build.sh android` 使用 JDK 25 成功產出 `build/app/outputs/flutter-apk/app-release.apk`；`flutter test` 全數通過。

---

### Task 21｜唯讀資料夾警告 + StatusLine ✅ 已完成

**目標**：修正記憶卡防寫鎖/唯讀掛載下標記狀態靜默遺失的問題，並以自訂 `StatusLine` widget 取代時序不可調整、配色與 app 表面對比不足的 SnackBar。

**子任務**：
- [x] 21.1 `PhotoStatusStore.isWritable(Directory)`：建立再刪除 `.halcyon_write_probe` 探測可寫性
- [x] 21.2 `AppState` 新增 `StatusMessage` 模型、`showStatus()`、`status`、`statusSeq`；`loadFolder()` 偵測唯讀時推送警告
- [x] 21.3 新增 `lib/views/status_line.dart`：2.5s 全不透明 → 0.5s 淡出 → 3.0s 移除，反相對比配色
- [x] 21.4 `lib/views/batch_delete_feedback.dart` 成功訊息改走 status line，失敗維持 `AlertDialog`
- [x] 21.5 補齊先前未 commit 的 `lib/services/trash_service.dart`
- [x] 21.6 新增/更新測試：`test/status_line_test.dart`（新）、`test/batch_delete_feedback_test.dart`（重寫）、`test/app_state_test.dart`、`test/sidebar_view_test.dart`

**驗收標準**：唯讀資料夾開啟時顯示含「唯讀」字樣的警告；SnackBar 呼叫點清零，改用 `StatusLine`；`flutter test` 全數通過。

**驗證結果**：`flutter test` 84 個測試通過（exit code 0，commit `123727b` 當時）；`flutter analyze` / `flutter build macos` 該輪未重跑。Task 26 落地後（含新增的 sidebar reload 迴歸測試）重跑為 85 個測試通過。

---

## 已完成摘要

### Phase 1 以前（含 Phase 1）
- SwiftUI macOS 版本曾作為早期原型存在，Task 7 起退役並收斂為 Flutter 主線
- Flutter 專案初始化與核心 UI（Scaffold / Sidebar / Detail View）
- 縮圖滑動視窗預載機制
- 狀態標記（星號/刪除）與快速鍵
- RAW 檔案群組與最佳化載入邏輯
- macOS Day/Night Theme 完整對應

> 若已完成事項超過 2 個迭代，請將摘要沉澱至 `memory.md` 或 `plan.md`。

---

## 測試統計

| 指標 | 數值 |
|------|------|
| 現有測試數（`flutter test` 實跑，2026-08-19，commit `d0eb855`）| 85 |
| 目標測試數（Task 15/16 完成後）| 18+（已達成）|
| 已通過測試數 | 85（exit code 0）|
| 測試覆蓋缺口 | Task 16（G-005 toggle-off 行為）尚無對應測試；DNG 解碼/回收模式/perf 相關測試檔已於本輪登錄對應 Task（22/23/25），仍未逐條列入 `unit_test.md` TC 矩陣（該檔的已知限制節有記錄） |
| 測試覆蓋策略 | 詳見 `unit_test.md` |
