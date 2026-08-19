---
date: 2026-08-19
title: "Halcyon — 全域知識庫與避坑指南 (Memory)"
---

## 🧭 檔案維護政策

**用途**：存放長期有效的架構決策、踩坑紀錄 (Gotchas) 與技術債說明。作為 AI 跨對話斷點的上下文橋接。

**更新時機**：
- 每輪對話結束前必更新。
- 發現新 Gotcha 或做出架構決策時立即同步，**不得等到對話結束**。

**必填欄位**：`date`（YYYY-MM-DD，反映最後有效更新）、`title`、本文內容。

**跨檔同步對象**：`task.md`（ACTIVE 狀態同步）、`plan.md`（里程碑層級同步）。

---

## 架構決策紀錄 (Architecture Decisions)

### AD-001｜滑動視窗預載策略（Sliding Window Preload）
- **日期**：2026-04-29
- **決策**：圖片與縮圖皆採用滑動視窗（sliding window）預載策略。
  - 大圖（Image Cache）：current ± 3~5 張，視窗外圖片立即驅逐。
  - 側邊欄縮圖（Thumb Cache）：current ± 20 張，100ms 防抖（debounce）保護。
- **依據**：避免一次全量載入造成 OOM，同時保持流暢瀏覽體驗。
- **Flutter**：`_preloadImages()`（AppState） + `preloadThumbnails()`（AppState）。
- **SwiftUI**：已退役；此策略後續只維護 Flutter 主線。

### AD-002｜RAW 檔案優先載入策略
- **日期**：2026-04-29
- **決策**：同一张照片群組（base name 相同）有多個副檔名時，優先載入 JPG/HEIC，RAW（ARW/RW2/DNG）作為降級。
- **Flutter**：`PhotoItem.bestFileToLoad`（`.photo_item.dart`）。
- **SwiftUI**：已退役；後續只維護 Flutter `PhotoItem.bestFileToLoad`。
- **依據**：JPG 提取更快、更省記憶體，RAW 需要完整解碼才能得到 Preview。

### AD-003｜Flutter 主線 + Native Bridge，SwiftUI 退役
- **日期**：2026-04-29
- **決策**：專案主線收斂為 Flutter app（專案根目錄）+ macOS/iOS native bridge；SwiftUI macOS 原型（`Sources/PhotoSelector/`）自 Task 7 起退役並刪除。
- **依據**：Flutter 版本已承接主要 UI、狀態、縮圖/主圖載入與設定；SwiftUI 版本未被主線引用且功能落後，持續維護會造成格式支援、文件與測試矩陣雙軌同步成本。
- **注意**：後續不要新增 SwiftUI 對齊任務；平台原生能力應優先透過 Flutter Runner 的 MethodChannel 實作。

### AD-004｜狀態持久化格式
- **日期**：2026-04-29
- **決策**：使用 `.halcyon_status.json` 存放於當前資料夾，格式為 `{ photoId: "starred"|"trashed"|"unmarked", _last_viewed_id: "..." }`。
- **Flutter**：讀寫由 `AppState._saveStatusCache()` / `_saveLastViewedId()` 管理。
- **SwiftUI**：已退役，不再補建持久化。
- **依據**：不需要資料庫，JSON 檔直接放在照片目錄中方便遷移與版本控制。

### AD-005｜AppState 協調層化
- **日期**：2026-04-29
- **決策**：Flutter 主線將 `AppState` 收斂為 UI 狀態協調層；資料夾掃描、狀態 JSON、影像預載/cache、檔案 copy/move/delete 分別交由 `PhotoLibraryScanner`、`PhotoStatusStore`、`ImagePreloadController`、`PhotoFileActions`。
- **依據**：Phase 4 模組化目標要求核心流程可測，避免 `AppState` 持續膨脹。
- **驗證**：`flutter test` 11 個測試通過；`flutter analyze` 0 issues；`flutter build macos` 成功。

### AD-006｜專案根目錄分層
- **日期**：2026-04-29
- **決策**：正式 Flutter app 放在專案根目錄；專案層級圖示放在 `assets/icons/`；本機照片樣本放在 `local_data/photo_samples/` 並忽略；封存與退役 build cache 放在 `artifacts/` 並忽略。
- **保留**：`rule.md`、`memory.md`、`task.md`、`handover.md`、`plan.md`、`file_index.md`、`unit_test.md`、`README.md` 維持根目錄入口，符合 Startup Protocol。
- **驗證**：搬移後 `flutter test`、`flutter analyze`、`flutter build macos` 皆通過。

### AD-007｜Android Toolchain 支援 JDK 25
- **日期**：2026-05-01
- **決策**：Android build toolchain 升級為 Gradle 9.1.0 + Android Gradle Plugin 9.0.1 + Kotlin Gradle Plugin 2.3.21，並在 macOS build script 中優先使用 Temurin JDK 25。
- **相容策略**：Flutter 3.35.1 的 `dev.flutter.flutter-gradle-plugin` 尚未相容 AGP 9 new DSL / built-in Kotlin，因此目前保留 `android.newDsl=false`、`android.builtInKotlin=false` 與 `org.jetbrains.kotlin.android` plugin。
- **驗證**：`./scripts/build.sh android` 使用 JDK 25 成功產出 `build/app/outputs/flutter-apk/app-release.apk`；`flutter test` 11 個測試通過。
- **後續**：等 Flutter 升級到支援 AGP 9 new DSL 後，再移除相容旗標並改用 built-in Kotlin。

### AD-008｜Trash 操作透過 macOS MethodChannel
- **日期**：2026-05-05
- **決策**：Flutter 刪除已標記照片時不再直接 `File.delete()`，改由 `TrashService` 呼叫 `halcyon/trash` MethodChannel，macOS 端使用 `FileManager.default.trashItem`。
- **Flutter**：`lib/services/trash_service.dart` 定義 contract；`PhotoFileActions.deleteTrashed()` 透過可注入 `TrashFile` callback 呼叫，方便單元測試。
- **macOS**：`macos/Runner/AppDelegate.swift` 註冊 `halcyon/trash` channel 與 `trashFile` method。
- **驗證狀態**：`flutter test` 已通過對應 trash 測試案例（Task 12 自動化驗證）；`flutter analyze` / `flutter build macos` 與真機垃圾桶視覺覆核仍待使用者補做（見 TD-004）。
- **後續**：Task 25（回收模式）已在此之上新增資料夾內 `.trash` 批次刪除路徑，見 AD-013。

### AD-009｜StatusLine 取代 SnackBar，可寫性以實際 create+delete 探測
- **日期**：2026-08-19
- **決策**：新增自訂 `lib/views/status_line.dart`（StatusLine widget）取代 Material SnackBar 作為所有狀態訊息（唯讀資料夾警告、批次刪除成功）的顯示載體；時序固定為 2.5s 全不透明 → 0.5s 淡出 → 3.0s 移除，並使用反相對比配色與翻色的琥珀色 emphasis span（深色主題 `#ECECEE` 底 `#17171A` 字、淺色主題 `#26262A` 底白字，emphasis `#A85D00` / `#FFD34D`）。
- **依據**：SnackBar 的淡出時間硬編碼 250ms 無法調整，且 Material 3 預設配色與 app 表面對比不足。
- **決策**：`PhotoStatusStore.isWritable(Directory)` 以建立再刪除 `.halcyon_write_probe` 檔案的方式探測資料夾可寫性，`AppState.loadFolder()` 偵測到唯讀時透過 `showStatus()` 推送一則警告。
- **依據**：exFAT 以 `noowners` 掛載，Unix 權限位不可信；唯讀掛載（例如記憶卡防寫鎖）只能用實際寫入操作驗證。
- **Flutter**：`lib/services/photo_status_store.dart:isWritable()`、`lib/providers/app_state.dart`（`StatusMessage`、`showStatus()`、`status`、`statusSeq`）。
- **驗證**：`flutter test` 84 個測試通過（`test/status_line_test.dart`、`test/app_state_test.dart` 新增案例）。
- **附帶修復**：`lib/services/trash_service.dart` 先前已被 import 但未被 commit，同一輪一併補上，否則乾淨 checkout 無法建置。

### AD-010｜DNG 全尺寸解碼整合（`dng_processor` 套件）
- **日期**：2026-08-16
- **決策**：無內嵌可用全尺寸 JPEG 預覽的 DNG 檔案，改由 `dng_processor` package 提供真正的原生 RAW 解碼，取代降級顯示縮圖。以 `DngFullDecoder` / `DecodedRgba`（`lib/services/dng_decode_contract.dart`）作為整合縫（integration seam），讓管線可用 fake decoder 單元測試，不必載入原生 dylib。
- **依據**：`dng_processor` 目前無 barrel export，只能 import 其 `src/`（`lib/services/dng_decode_service.dart:1` `// ignore: implementation_imports`），待該套件補上 `lib/dng_processor.dart` 後再清理。
- **Flutter**：`dng_decode_contract.dart`、`dng_decode_service.dart`、`decoded_rgba_image_provider.dart`。
- **驗證**：`test/dng_decoder_smoke_test.dart`、`test/dng_extractor_swift_test.dart`、`test/decoded_rgba_image_provider_test.dart` 通過（2026-08-19 重跑）。
- **對應任務**：`task.md` Task 22。

### AD-011｜影像切換延遲：Tier-1/Tier-2 Sliding Preload
- **日期**：2026-08-16
- **決策**：在既有 AD-001 滑動視窗預載基礎上新增第二層快取：tier-1 是視窗解析度預解碼快取（搭配 500MB `ImageCache`），tier-2 是全尺寸解碼層，兩者並存而非互斥。修正三個 review 發現的問題：BLOCKER 1（過期 tier-2 ready flag）、B2、BLOCKER 3（tier-2 completion flag 必須是「與 tier-1 共同構成」的必要條件，不可單獨省略任一方向）。
- **依據**：單層預載不足以同時滿足「切換不卡頓」與「記憶體安全」；BLOCKER 3 的迴歸測試（`3cbc5ff`）刻意驗證兩個方向，防止未來重構只顧一邊。
- **Flutter**：`lib/services/image_preload_controller.dart`。
- **驗證**：`test/image_preload_controller_test.dart` 22 個測試通過（2026-08-19 重跑），涵蓋滑動視窗驅逐、raw-decode 路徑、decode/dispose handle 平衡。
- **對應任務**：`task.md` Task 23。

### AD-012｜Finder「開啟方式」冷啟動走 Push-only MethodChannel
- **日期**：2026-08-17
- **決策**：`lib/services/open_with_channel.dart` 的 `halcyon/open_with` channel 設計為單向 push（native → Dart），不提供 Dart 主動詢問原生端「有沒有待處理檔案」的介面。
- **依據**：冷啟動時 Dart 詢問原生端會與 Flutter engine 初始化競速，原生端 handler 可能尚未註冊，呼叫會死於 `MissingPluginException`；反之 platform → Dart 方向 Flutter 的 channel 會緩衝訊息直到 handler 註冊，因此 push-only 在啟動時序上更可靠。
- **平台狀態**：macOS 已實作（`macos/Runner/AppDelegate.swift`）；Windows 需 runner 轉發 `argv[1]`；Android 需先由原生端解析 `content://` URI（`ACTION_VIEW` 場景）才能呼叫 Dart 端，這兩者皆未實作，`OpenWithChannel.listen()` 在其上恆為 no-op。
- **對應任務**：`task.md` Task 24。

### AD-013｜回收模式（`.trash`）：sibling 分組批次移動、碰撞附加後綴
- **日期**：2026-08-17
- **決策**：新增資料夾內回收模式，`PhotoFileActions.recycleTrashed()`（`lib/services/photo_file_actions.dart:91`）將已標記刪除項目的所有檔案（含同名 sibling RAW，如 `.cr2`/`.nef`/`.orf`）與其 AppleDouble sidecar 一併移入 `<dir>/.trash/`；同名碰撞時附加 `-1`、`-2` 後綴（`_availablePath()`），絕不覆蓋既有回收批次。回傳 `RecycleOutcome`（`movedCount` + `failures` 清單），失敗項目必須被使用者看見，不可靜默吞掉。
- **依據**：同一 volume 內的 rename 是瞬時操作，在 macOS 系統垃圾桶 API 不可用（例如某些外接卡）的情況下仍可用；批次操作中任何單一檔案失敗不應中斷整批。
- **Flutter**：`photo_file_actions.dart`、`photo_action_bar.dart`（mode-aware 刪除按鈕，右鍵切換模式）、`sidebar_view.dart`（mode-aware 狀態圖示）、`batch_delete_feedback.dart`（成功走 status line，失敗走阻斷式 `AlertDialog` 列出 failures）。
- **驗證**：`test/photo_file_actions_test.dart`、`test/sidebar_view_test.dart`、`test/photo_action_bar_test.dart`、`test/batch_delete_feedback_test.dart` 通過（2026-08-19 重跑）。
- **對應任務**：`task.md` Task 25。

### AD-014｜Sidebar 縮圖預載改由 `itemBuilder` 驅動，取代 scroll listener（取代 AD-001 側邊欄部分／G-001）
- **日期**：2026-08-19
- **決策**：`SidebarView` 不再用 `ScrollController` 監聽器換算可視範圍後 ±20 呼叫 `preloadThumbnails`；改為 `ListView.builder` 的 `itemBuilder` 每格回報建置到的 index，一幀結束後彙整範圍，回報「純可視範圍」給 `AppState.preloadThumbnails()`。prefetch margin（`thumbnailPrefetchMargin = 20`）下沉到 `ImagePreloadController` 自己決定，並改為「可視列優先（上到下）→ 視窗邊緣向外交錯」的請求順序，避免線性掃過整個 `start-20..end+20` 時，使用者實際看到的列排在 20 個畫面外列之後才被請求。
- **依據**：`ListView.builder` 本來就只建置可視列（加上 `cacheExtent`），任何 rebuild 都會免費重新算出範圍——這讓側邊欄在 `AppState.loadFolder()` 清空縮圖快取後（回收/刪除/複製/移動皆會重載資料夾）自我修復；舊的 scroll-listener 模型只在使用者剛好捲動時才重新請求，捲動離開頂端後回來的清單會持續空白直到再次捲動。
- **附帶機制**：`ImagePreloadController` 新增 `_thumbBatchGeneration` 計數器，`reset()` 與每次新範圍呼叫都會遞增；正在執行的批次一旦偵測到 generation 不符（快速捲動、或資料夾重載清空 `_thumbCache`）就在下一次 await 前自我中止，不再為已不存在的清單浪費 channel 往返或寫入快取。
- **附帶修復**：`sidebar_view.dart` 選取列背景改用 `ListTile.selectedTileColor`，外層容器由 `Container` 改為 `Material`，消除「ListTile 背景色/ink splash 可能不可見」的 framework 斷言警告。
- **Flutter**：`sidebar_view.dart`、`app_state.dart:preloadThumbnails()`、`image_preload_controller.dart`。
- **驗證**：新增 `test/sidebar_view_test.dart`「every visible row is requested again after a folder reload」；`flutter test` 85 個測試通過，`flutter analyze lib test` 0 issues（2026-08-19）。
- **對應任務**：`task.md` Task 26。

---

## Gotchas（踩坑紀錄）

### G-001｜側邊欄 Scroll Debounce（觸發機制已由 AD-014 取代，debounce 本身仍在）
- **嚴重程度**：中
- **問題**：快速滾動側邊欄時，會觸發大量 `preloadThumbnails` 請求導致 Isolate 阻塞。
- **解法**：`ImagePreloadController.preloadThumbnails()` 仍使用 100ms debounce timer 緩衝請求（`image_preload_controller.dart` 內 `_thumbnailDebounceTimer`）。**觸發來源已變**：2026-08-19（Task 26 / AD-014）前是 `SidebarView` 的 `ScrollController` 監聽器；現在是 `ListView.builder` 的 `itemBuilder` 逐格回報＋每幀彙整，debounce 機制與新增的 generation 計數器共同防止過期批次浪費請求。
- **驗證**：`test/image_preload_controller_test.dart`、`test/sidebar_view_test.dart` 通過（2026-08-19）。

### G-002｜已退役 SwiftUI NSScrollView 滾動門檻值
- **嚴重程度**：低
- **問題**：已退役 SwiftUI 原型曾有 `ZoomableImageView` 觸控板誤觸問題。
- **解法**：不再維護 SwiftUI 原型；Flutter 主線另以 `InteractiveViewer` 管理縮放。
- **狀態**：已關閉（退役）。

### G-003｜SwiftUI 版本缺少狀態持久化
- **嚴重程度**：高
- **問題**：`Sources/PhotoSelector/` SwiftUI 版本目前無 `UserDefaults` 或 JSON 持久化，關閉後狀態全失。
- **解法**：已由 Task 7 決策退役 SwiftUI package，不再補建。Flutter JSON 狀態檔為唯一主線。
- **狀態**：已關閉（退役）。

### G-004｜Flutter NativeThumbnailService MethodChannel 未實作 macOS
- **嚴重程度**：高
- **問題**：`lib/services/native_thumbnail_service.dart` 定義了 MethodChannel，但 macOS 原生端（`macos/Runner/AppDelegate.swift`）曾缺少實作。
- **解法**：已在 `macos/Runner/AppDelegate.swift` 建立 `FlutterMethodChannel` handler，並改為 `ImageRequestPurpose.preview` / `sidebarThumbnail` 語意化分流。
- **狀態**：已修復（Task 1 / Task 8）。`flutter analyze` / `flutter test` / `flutter build macos` 通過。

### G-005｜Auto-advance 與 Status Toggle 邏輯（已確認正確，僅缺測試）
- **嚴重程度**：低（原標記中，本輪核實後降級）
- **現況**（2026-08-19 對照 `lib/providers/app_state.dart:337-351` 核實）：`markCurrent()` 的 toggle-off 分支（`item.status == status`，`app_state.dart:340-341`）只設定 `unmarked`，不呼叫 `nextPhoto()`；`_autoAdvance` 判斷（`app_state.dart:344`）只存在於「設定新狀態」的 else 分支。**Toggle off 時已不會前進**，本檔原記載的問題不成立。
- **狀態**：行為已確認正確，不需修改邏輯。剩餘缺口是 `test/app_state_test.dart` 缺少對應 regression test（`unit_test.md` TC-014），見 `task.md` Task 16。

### G-006｜exFAT / 網路磁碟 AppleDouble 副作用
- **嚴重程度**：低
- **問題**：在 exFAT 或網路磁碟上操作時，macOS 會自動產生 `._<filename>` AppleDouble 側寫檔，可能殘留於目的地。
- **解法**：在 `processStarred()` 中主動偵測並刪除 `.<basename>` 側寫檔（Flutter 版本已實作）。

### G-007｜Panasonic RW2 掃描白名單漏列
- **嚴重程度**：高
- **問題**：Flutter 資料夾掃描白名單曾漏列 Panasonic RAW `.rw2`，因此 `.rw2` 在進入 native decoder 前就被排除。Task 6 當時也同步處理了尚未退役的 SwiftUI 原型。
- **解法**：在 Flutter `AppState.loadFolder()` 補上 `.rw2`。
- **狀態**：已修復（Task 6）。已通過 `flutter analyze` / `flutter test` / `flutter build macos`，實機 RW2 視覺覆核待使用者以真實資料夾確認。

### G-008｜JPG 主圖請求不可退化為 sidebar 縮圖
- **嚴重程度**：高
- **問題**：Flutter 主圖與 sidebar 縮圖共用 `NativeThumbnailService.getThumbnail()`，只靠 `targetSize` 區分；若 macOS 原生端對 JPG 大圖請求仍走縮圖路徑，主圖可能只顯示小尺寸 preview。
- **解法**：macOS 原生端需根據 `targetSize` 分流：小圖保留 `CGImageSourceCreateThumbnailAtIndex`，主圖/高解析請求優先使用原圖輸出並保留方向修正。
- **狀態**：已修復（Task 6）。非 RAW 且 `targetSize > 4000` 的請求改用 `CGImageSourceCreateImageAtIndex` + CoreImage orientation 修正；實機 JPG 視覺覆核待使用者確認。

### G-010｜View 層直接寫入 AppState 欄位（反向資料流，仍存在，2026-08-19 重新核實行號）
- **嚴重程度**：中
- **現況**：`main_detail_view.dart` 有至少 5 處在 widget build/callback 中直接對 `AppState` 的 public 欄位做 setter，破壞單向資料流（原記載 4 處，本輪多發現 1 處）：
  - `main_detail_view.dart:32`：`_animController` listener 每個動畫 tick 寫入 `context.read<AppState>().transformCtrl.value = _zoomAnimation!.value`（本輪新記錄，頻率高於下列 4 處）
  - `main_detail_view.dart:99`：`context.read<AppState>().shouldAnimateZoom = false`（view 直接關閉 provider 旗標）
  - `main_detail_view.dart:220`：`context.read<AppState>().lastKnownCenter = center`（`LayoutBuilder` 每次 rebuild 寫入）
  - `main_detail_view.dart:282`：`context.read<AppState>().pointerPosition = event.localPosition`（`MouseRegion.onHover`）
  - `main_detail_view.dart:285`：`context.read<AppState>().pointerPosition = null`（`MouseRegion.onExit`）
- **根因**：`app_state.dart:113-119` 的 zoom/animation 欄位（`transformCtrl`、`pointerPosition`、`lastKnownCenter`、`targetMatrix`、`shouldAnimateZoom`）屬於純 View 層狀態，不應放在 business provider；`stepZoomIn()`/`stepZoomOut()`/`_zoomBy()`（`app_state.dart:298-334`）目前仍是 `main_screen.dart:99,102` 鍵盤縮放（`↑`/`↓`）的唯一入口。
- **解法**：Task 19 將 zoom 相關欄位與 `_zoomBy()` 邏輯移至 `_MainDetailViewState`，由 `AnimationController` 本身驅動，不再依賴 provider 旗標；鍵盤縮放改透過 widget 方法觸發。
- **待辦**：Task 19（Phase 10）。

### G-009｜JDK 25 需要 Gradle 9.1+，且 Flutter Gradle Plugin 暫需 AGP 9 相容模式
- **嚴重程度**：中
- **問題**：舊 toolchain（Gradle 8.12 / AGP 8.9.1 / Kotlin 2.1.0）在 Temurin JDK 25 下會於 Gradle Kotlin DSL 階段失敗，錯誤為 `IllegalArgumentException: 25.0.2`。
- **解法**：升級至 Gradle 9.1.0、AGP 9.0.1、Kotlin 2.3.21；因 Flutter 3.35.1 的 Gradle plugin 在 AGP 9 new DSL 下會 NPE，目前使用 AGP 9 相容模式。
- **狀態**：已修復（Task 14）。`./scripts/build.sh android` 使用 JDK 25 成功。

---

## 技術債 (Tech Debt)

| ID | 項目 | 優先順序 | 備註 |
|----|------|----------|------|
| TD-001 | SwiftUI 版本狀態持久化 | 已關閉 | Task 7 退役 SwiftUI，不再實作 |
| TD-002 | Flutter macOS 原生 MethodChannel | 已關閉 | Task 1 / Task 8 已完成 |
| TD-003 | 側邊欄縮圖尺寸 / 載入優先順序優化 | 中 | 可根據視窗大小動態調整 targetSize |
| TD-004 | 刪除操作移到垃圾桶而非永久刪除 | 低（自動化已驗證，實機待補） | Task 12 已改為 `TrashService` + macOS `FileManager.trashItem`，Task 25 在此之上新增資料夾內 `.trash` 回收模式；`flutter test` 已通過對應案例，`flutter analyze` / `flutter build macos` 與實機 Trash / `.trash` 資料夾視覺覆核仍待使用者補做 |
| TD-005 | `widget_test.dart` 為預設範本，未反映實際 App | 已關閉 | Task 3 已替換為有意義的 smoke test |
| TD-006 | JPG 主圖與縮圖共用 native API 需明確尺寸契約 | 已關閉 | Task 6 / Task 8 修正 macOS 分流 |
| TD-007 | AppState 職責過大 | 已關閉 | Task 9 已拆分掃描、狀態、快取、檔案操作 |
| TD-008 | 支援格式定義分散 | 已關閉 | Task 10 已建立 `SupportedPhotoFormats` registry |
| TD-009 | AGP 9 new DSL / built-in Kotlin 遷移 | 中 | Flutter 3.35.1 相容模式；待 Flutter toolchain 升級後移除相容旗標 |
| TD-010 | `PhotoFileActions` copy/move/delete 完全無單元測試 | **高** | Task 15 待辦；無測試保護下資料操作風險極高 |
| TD-011 | Zoom 狀態（`transformCtrl`、`pointerPosition`）混在 `AppState` | 低 | 應提取為獨立 `ZoomState` Provider；Task 19 待辦 |
| TD-012 | macOS `AppDelegate.swift` 缺乏深層錯誤處理 | 中 | CIContext/CIFilter/CGImage 未加 try-catch；無大型 RAW 記憶體上限；Task 17 待辦 |
| TD-013 | `sidebar_view.dart:48` `_itemHeight = 48.0` 硬編碼 | 低 | 主題密度改變時 scroll 位置計算會失準 |
| TD-014 | `sidebar_view.dart` 重複 iconColor 判斷且色值不一致（2026-08-19 重新核實：回收模式改動後已增至 4 處重複，行號全部位移）| 低 | Line 150（`32,32,32`）vs Line 197、266-268、287-289、322-324（皆 `59,59,59`）— 需提取 `_iconColor()` helper；Task 20 待辦。行號取自本輪讀取當下，另一 session 正對此檔做未提交 flicker-fix，下一輪需重新核對 |

---

## 重要約定

1. **JSON 狀態檔**：放在照片目錄根目錄，命名為 `.halcyon_status.json`，以 `.` 開頭確保隱藏。
2. **側邊欄寬度**：預設 270px，可拖曳調整（最小 180px，最大 600px）。
3. **縮圖目標尺寸**：側邊欄 200px，主圖 10000px（Full Resolution 預覽）；native 端需依 targetSize 分流避免主圖退化為縮圖。
4. **鍵盤快捷鍵**（Flutter）：
   - `←` / `→`：上一張 / 下一張
   - `↑` / `↓`：放大 / 縮小
   - `S`：標記星號
   - `X`：標記刪除
