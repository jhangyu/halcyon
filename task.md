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

- **Task**: 21 — 唯讀資料夾警告 + StatusLine（commit `123727b`）
- **中斷點與交接 (Handover)**: 已完成。`PhotoStatusStore.isWritable()` 探測可寫性、`AppState` 新增 `StatusMessage`/`showStatus()`、`lib/views/status_line.dart` 取代 SnackBar、批次刪除成功訊息改走 status line；`flutter test` 84 個測試通過（exit code 0）。詳見 `handover.md` 本輪交接摘要。
- **下一個子步驟**: 無立即待辦；`git status` 顯示樹上乾淨（除本次文件同步外）。

**文件債提醒**：本區塊此前（2026-05-05）停留在 Task 12，期間主線已完成 Task 12 自動化驗證、回收模式（`.trash` 批次刪除，見 `9520ab4`~`307afec`）、DNG 解碼整合（`bcc096b` 等）、影像切換延遲多輪優化（`3cbc5ff` 等）、Finder 開啟方式（`aefad64`）等工作，但未逐項在下方任務清單登錄或關閉對應 Task。下一輪應派工對照 `git log` 逐一核實並補登 Task 狀態，而非直接信任下方清單的 🔲/✅ 標記。

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

### Task 5｜刪除操作改為 Trash 而非永久刪除 🔲 待辦

**目標**：將 Flutter `AppState.deleteTrashed()` 從 `file.delete()`（永久刪除）改為移到垃圾桶。

**子任務**：
- [ ] 5.1 評估方案：使用 Swift FFI 或等待 `file_selector` 支援 `trash`（詳見 `memory.md` TD-004）
- [ ] 5.2 若需要 Native Plugin，評估建立 `trash_service.dart` + MethodChannel
- [ ] 5.3 更新 `memory.md` TD-004 狀態

**驗收標準**：刪除檔案進入 macOS 垃圾桶而非永久消失。

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

### Task 16｜G-005 Auto-advance Toggle 行為確認與修正 🔲 待辦

**目標**：釐清並修正 `markCurrent()` 在 Toggle off 時是否應自動前進的行為（G-005）。

**子任務**：
- [ ] 16.1 與使用者確認預期行為：Toggle off 時不應前進（待確認）
- [ ] 16.2 若確認不前進，修改 `AppState.markCurrent()` 邏輯
- [ ] 16.3 在 `test/app_state_test.dart` 新增 toggle-off 不前進的測試案例
- [ ] 16.4 更新 `memory.md` G-005 狀態為已修復

**驗收標準**：G-005 行為已確認並記錄；測試覆蓋 toggle-off 情境；`flutter test` 全數通過。

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

### Task 19｜Zoom 狀態下沉至 View 層（消除反向資料流）🔲 待辦

**目標**：將 `AppState` 中的 zoom/animation 純 View 狀態還給 `_MainDetailViewState`，消除 view 直接寫入 provider 的反向資料流（G-010、TD-011）。

**背景**：架構審查（2026-05-04）確認以下欄位屬於純 View 層，不應存在 business provider：
- `app_state.dart:67` `transformCtrl`（`TransformationController`）
- `app_state.dart:68` `pointerPosition`（mouse hover 位置）
- `app_state.dart:69` `lastKnownCenter`（layout 中心，LayoutBuilder 每幀寫入）
- `app_state.dart:72` `targetMatrix`（動畫目標矩陣，one-shot 旗標）
- `app_state.dart:73` `shouldAnimateZoom`（one-shot 觸發旗標）

並確認以下反向寫入需消除：
- `main_detail_view.dart:94` `shouldAnimateZoom = false`（view 直接關閉 provider 旗標）
- `main_detail_view.dart:177` `lastKnownCenter = center`（LayoutBuilder callback 每次 rebuild 寫入）
- `main_detail_view.dart:181` `pointerPosition = event.localPosition`
- `main_detail_view.dart:184` `pointerPosition = null`

**子任務**：
- [ ] 19.1 在 `_MainDetailViewState` 新增 zoom 欄位：`_transformCtrl`、`_pointerPosition`、`_lastKnownCenter`
- [ ] 19.2 將 `_zoomBy()` 邏輯（`app_state.dart:187-216`）搬入 `_MainDetailViewState`，以本地 `setState()` 驅動動畫，不再透過 `AppState.shouldAnimateZoom`
- [ ] 19.3 keyboard zoom（S/X 由 `main_screen.dart` 轉發）改為直接呼叫 `_MainDetailViewState` 的 `stepZoomIn()` / `stepZoomOut()` 公開方法（或透過 GlobalKey / callback 傳遞）
- [ ] 19.4 `AppState` 移除五個 zoom 欄位與 `stepZoomIn()`、`stepZoomOut()`、`_zoomBy()`；`dispose()` 移除 `transformCtrl.dispose()`
- [ ] 19.5 `flutter analyze` / `flutter test` 全數通過；更新 `file_index.md`

**驗收標準**：`AppState` 不再持有任何 zoom/animation 欄位；`main_detail_view.dart` 不再對 `AppState` 做 setter 操作；`flutter test` 全數通過；無功能回歸。

---

### Task 20｜SidebarView iconColor 重複邏輯提取 🔲 待辦

**目標**：消除 `sidebar_view.dart` 中三處重複且色值不一致的 iconColor 判斷邏輯（TD-014），提取為私有 helper（Quick Win，1–2 小時）。

**背景**：架構審查（2026-05-04）發現以下三處重複，且 title color（`32,32,32`）與 icon color（`59,59,59`）存在不一致：
- `sidebar_view.dart:114-117`：header title color（`32,32,32`）
- `sidebar_view.dart:229-231`：`_buildTopActions` iconColor（`59,59,59`）
- `sidebar_view.dart:250-252`：`_buildActionMenu` iconColor（`59,59,59`，完全重複）

**子任務**：
- [ ] 20.1 在 `_SidebarViewState` 新增私有 helper `Color _iconColor(BuildContext context)`，統一使用 `59,59,59` 作為 light mode icon 色值
- [ ] 20.2 將 Line 229-231 與 Line 250-252 改呼叫 `_iconColor(context)`
- [ ] 20.3 確認 Line 114-117 的 title color 是否應與 icon color 一致（如是，一同修正；如否，加 comment 說明差異）
- [ ] 20.4 `flutter analyze` / `flutter test` 通過

**驗收標準**：`sidebar_view.dart` 中 iconColor 邏輯只定義一次；`flutter analyze` 0 issues；無視覺回歸。

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

**驗證結果**：`flutter test` 84 個測試通過（exit code 0，2026-08-19）。`flutter analyze` / `flutter build macos` 本輪未重跑。

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
| 現有測試數（`flutter test` 實跑，2026-08-19）| 84 |
| 目標測試數（Task 15/16 完成後）| 18+（已達成）|
| 已通過測試數 | 84（exit code 0）|
| 測試覆蓋缺口 | Task 16（G-005 toggle-off 行為）尚無對應測試；DNG/回收模式/perf 相關測試檔未逐條登錄於 `unit_test.md` TC 矩陣 |
| 測試覆蓋策略 | 詳見 `unit_test.md` |
