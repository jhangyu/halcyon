---
date: 2026-08-25
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
- **修訂（2026-08-22，Dart-first 採用後）**：`NativeImageNeedsRawDecode` 不再只由原生端發出。原設計中該 variant 唯一來源是 `AppDelegate.swift` 的 `NO_EMBEDDED_PREVIEW` channel error；Windows 原生端刻意回 `RAW_UNSUPPORTED`（`windows/runner/halcyon_image.cpp:392-403`），因此該訊號在 Windows 永遠不會出現，`DngFullDecoder` 成為死碼。改由 Dart 端在「原生失敗 ＋ `.dng` ＋ 內嵌預覽抽取落空」時自行建構此 variant，orientation 來自 `DngPreviewExtractor.readOrientationFromFile`（`dng_preview_extractor.dart:41`）。**三個 variant 的凍結不變**（AD-011 的 tier-1/tier-2 契約亦不變）；改變的只是「誰建構這個 variant」。此 variant 的語意自此讀作「拿不到便宜的 bytes，且這是解碼器處理得了的 RAW」，與訊號的來源平台無關。
- **勘誤（2026-08-24，M6 spec-contract 稽核發現）**：上一條「改由 Dart 端…自行建構此 variant」的敘述是錯的，原文保留但不可信。實測（`m6-spec-contract.md` §3）：`NativeImageNeedsRawDecode` 至今在整棵樹裡唯一的建構點仍是 `native_thumbnail_service.dart:126-129`（`PlatformException` catch block，`e.code == kNoEmbeddedPreviewCode` 時建構），且此建構點完全被 macOS 原生端的 `NO_EMBEDDED_PREVIEW` 發射閘住（`AppDelegate.swift:396`，條件見 `:391`，orientation 經 `readDngOrientation` `:393`）。程式碼裡不存在一個獨立於此原生訊號、由 Dart 端自行判斷「原生失敗 ＋ .dng ＋ 內嵌預覽抽取落空」就建構此 variant 的邏輯——Windows 端的 `RAW_UNSUPPORTED` 目前只會落到 `NativeImageFailure`（`native_thumbnail_service.dart:132`），不會觸發 `NativeImageNeedsRawDecode`。同一錯誤敘述也曾出現在 `native_thumbnail_service.dart:83-88` 與 `windows/runner/halcyon_image.cpp:533-536` 的註解中，三處已於本次一併修正。
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

### AD-015｜Zoom 狀態下沉至 view 層 `ZoomController`，動畫請求改由通知驅動
- **日期**：2026-08-19
- **決策**：新增 `lib/views/zoom_controller.dart`（`ZoomController extends ChangeNotifier`），持有 `transformCtrl`、`pointerPosition`、`lastKnownCenter`、`targetMatrix`、`shouldAnimateZoom` 與 `stepZoomIn/stepZoomOut/_zoomBy`。**由 `_MainScreenState` 建立與 dispose**，以參數注入 `MainDetailView(zoom: _zoom)`；`AppState` 不再有任何 zoom 狀態。
- **依據**：縮放是純畫面狀態。反向資料流（G-010）的單一成因是「鍵盤入口在父層 `MainScreen`，狀態在子層」，以 provider 當管道；獨立 controller 讓父層變成普通方法呼叫，且縮放邏輯可脫離 widget 做單元測試。方案 A（`GlobalKey` 呼叫子層 State）與方案 C（只搬部分欄位）已由使用者否決。
- **紅線**：controller **必須**由 `MainScreen` 持有——`MainDetailView` 在照片切換時會重建，若 controller 建在其內部，跨照片保留縮放的既有行為會遺失。
- **動畫觸發**：`MainDetailView` 於 `initState` 註冊 `_onZoomRequested` listener，旗標由該 listener 立即消費並清除，動畫在 build 之外啟動；舊版在 `build()` 內讀旗標並用 post-frame callback 清除（等於 build 期間寫 provider）已移除。連按兩次 `↑` 的行為不變：兩次都以尚未動畫的 `transformCtrl.value` 為基準，第二次覆蓋第一次，不累加。
- **不變式**：`lastKnownCenter` / `pointerPosition` 是**不通知**的普通欄位；`lastKnownCenter` 寫在 `LayoutBuilder` 的 builder 內，改成會 `notifyListeners()` 的 setter 即為無窮 rebuild。
- **驗證**：新增 `test/zoom_controller_test.dart`（9 案例，TC-023），以 8 個 mutant 逐一證明鑑別力；`flutter analyze lib test` 0 issues。
- **對應任務**：`task.md` Task 19；關閉 G-010 / TD-011。

### AD-016｜EXIF 重新命名：命名策略與 I/O 分離
- **日期**：2026-08-20
- **決策**：`RenameRule.render`（模板 → 檔名）與 `planRenames`（檔名 → 無碰撞計畫）皆為純函式；只有 `applyRenames` 觸碰檔案系統。整個命名策略因此可在不落地任何照片的情況下完整單元測試，這也是讓 10,000 檔案規模路徑未來能安全變更的關鍵。
- **依據**：重新命名採序列執行——`File.rename` 是同一 volume 內的 metadata 操作，平行化沒有效益，反而會讓 planner 的碰撞規避退化成 race；10,000 張照片真正的成本在讀取 EXIF，那一段才是平行的（macOS 原生端 header-only、每個項目只讀一次而非每個檔案讀一次）。
- **Flutter**：`lib/services/rename_rule.dart`、`lib/services/rename_service.dart`。
- **驗證**：`test/rename_rule_test.dart`（TC-024~TC-030）、`test/rename_service_test.dart`（TC-031~TC-040）。
- **對應任務**：EXIF 重新命名功能（`docs/superpowers/plans/2026-08-19-exif-rename.md` Task 1-3）。

### AD-017｜EXIF 每個項目只讀一次，來源為 JPG sibling
- **日期**：2026-08-20
- **決策**：RAW+JPG 為同一次拍攝，`PhotoItem.bestFileToLoad` 選出 JPG，其 metadata 套用到該群組所有檔案；不重複讀取 RAW header 以避免對相同資料做兩次工。
- **依據**：省去對同一拍攝重複解析 EXIF 的成本；與 AD-002（RAW 優先載入策略中 JPG 優先）方向一致。
- **Flutter**：`lib/providers/app_state.dart:readMetadataFor()`。
- **驗證**：`test/app_state_test.dart`（TC-049~TC-051）。
- **對應任務**：EXIF 重新命名功能（`docs/superpowers/plans/2026-08-19-exif-rename.md` Task 7）。

### AD-018｜Tier-2 解碼視窗與昂貴 RAW 啟動資格必須是兩個常數（禁止再合併）
- **日期**：2026-08-23
- **決策**：新增 `kTierTwoRadius = 2`（`lib/services/prefetch_scheduler.dart:32`）專司 tier-2 全尺寸解碼視窗；`kExpensiveStartupRadius` 維持 `1`，只管昂貴 RAW 的啟動資格（`allowsStartup` / `allowsExpensiveWork`）。**兩者不得再合併回同一個常數。**
- **依據**：原本一個常數同時承擔兩種語意。使用者的凍結釐清是「±1 只代表昂貴 RAW 的啟動資格，永遠不是保留邊界」，另一條裁決是「循序 RAW 解碼維持不變」。要同時滿足這兩條，只有拆開一途。若直接放寬共用常數，會把循序 RAW 那一級從三個項目變成五個——依實測每次昂貴切換 8.5 秒計，冷啟動安定時間從約 25 秒變成約 42 秒。**危險之處在於它看起來像是忠實實作**：tier-2 需求達成了，卻同時靜默違反上述兩條裁決。
- **保護**：`test/image_preload_window_test.dart` 有一條專門的 killer test——距離 2 的昂貴項目必須拿不到 payload 且解碼器呼叫次數為 0。任何人把兩個常數合併，這條會紅。
- **已知限制**：因為昂貴項目只在 ±1 內取得 payload，而 tier-1 預快取只消費 payload、從不生產（`image_preload_controller.dart:707-708` peek 到 null 就跳過），所以**在「無內嵌預覽的 RAW」資料夾上，距離 2..5 的格子兩層快取都是空的**。九格保證只對有預覽的檔案成立。這是拆分的設計後果，不是缺陷。
- **對應任務**：M3 round 2（commit `f9869db`）。

### AD-019｜兩個快取常數以相反的樣本組計算，不可互相驗算
- **日期**：2026-08-23
- **決策**：`imageCacheMaxBytes = 768 << 20`（805,306,368 bytes，`lib/main.dart:25`）；`kPayloadByteBudget = 224 * 1024 * 1024`（234,881,024 bytes，`lib/services/photo_payload_cache.dart:31`）。單位一律 MiB（bytes / 1048576），載重數字一律釘原始位元組。
- **依據**：兩個常數**是照相反的樣本組算出來的**——ImageCache 上限照「便宜（含內嵌預覽）」樣本組算，payload 預算照「昂貴（無預覽）」樣本組算。原因是 tier-2 成本會反轉排程器對「昂貴」的直覺：`EncodedPayload` 走 `MemoryImage` 且是原生全尺寸（本樣本組 24 MP 約 91.55 MiB），`PixelPayload` 走 `RawPixelsImage` 且已是視窗尺寸（約 22.4 MiB）。**貴的快取項來自便宜那一級。** 另外 `PixelPayload` 在兩層切換回傳同一個 provider，所以一個 RAW 只佔一個快取項，而一個 `EncodedPayload` 佔兩個。
- **後果**：**任何一方都無法為另一方做健全性檢查。** 想「簡化」這一對常數的人，會靜默弄壞其中一個。
- **實測**：round-2 的 AC8 量到 kernel max RSS 996,392,960 bytes = 950.2 MiB，低於 pre-M3 基線 1,043,218,432 bytes = 994.9 MiB（使用者採相對判準）。**但那次量測掃的是昂貴樣本組**，也就是九格保證不成立的那一組；便宜樣本組（上限真正據以計算、且每項佔兩個快取項的那一組）**至今未量測**。
- **對應任務**：M3 round 2（commit `f9869db`）。

### AD-020｜M6 契約：影像行為統一於 Dart 核心，三個宣告例外之外禁止平台分歧
- **日期**：2026-08-24
- **決策**：Halcyon 的照片行為（哪些檔案能載入、畫面上出現哪些像素、刪除做什麼、匯出產出什麼）只用 Dart 實作一次，在每個支援平台產生相同的可觀察結果；native runner 只保留 app shell、視窗管線，以及三個封閉清單的例外：**F-12 系統 Trash**（macOS/Windows 原生）、**F-16 Open With 傳輸層**（macOS/Windows/Android/iOS，Linux 排除）、**F-18 檔案關聯**（Windows/macOS）。清單封閉——任何新的平台分歧都不得援引這三項為先例。
- **依據**：`docs/logs/2026-08-24/m6-spec-contract.md` §1 C-2/C-3；`lib/` 內禁止 `Platform.isX`/`kIsWeb`/`defaultTargetPlatform`/條件匯入/shell 出去的平台指令（唯一例外：F-19 reveal-in-file-manager 的一處 `Process.run`，已從 grep 護欄的檔案清單排除）。production `NativeImageLoad` seam 的實作從 `halcyon/thumbnail` MethodChannel 搬到純 Dart producer（`dart_image_loader.dart`，基於 `DngPreviewExtractor`）；seam 本身保留作為測試注入點。
- **能力損失（U-11/U-12，使用者已裁決，非靜默降級）**：**U-12** 是本輪最大的一次架構轉向——`photo_source.dart` 的 `_legacyBytes` CIRAWFilter 降級路徑整個刪除，一張無內嵌預覽又無可用解碼器的 DNG，現在是**立即、統一、不可恢復**的 permanent miss（不再有「退化到原生 bytes」這條路可走，因為那條路本身就是要刪除的原生橋接）；U-11 是與 F-05（HEIC 移出支援集，見 commit `68308c4`）配套的能力收斂。兩者皆為使用者在 matrix 上明確裁決的結果，寫在 round 報告中而非埋在程式碼裡。
- **測試面（C-4，見 baseline-registry.md）**：任何斷言單平台語意的既有測試，隨受測 channel/類型一起刪除或改寫，同一 commit 內把理由與（若為凍結檔）新 sha256 記入 `docs/logs/2026-08-24/baseline-registry.md`。Appendix B（`m6-execution-plan.md:1092-1105`）是本輪測試處置的權威清單，P5.2（2026-08-24）稽核過全部 10 列，逐列核對 commit 與 baseline-registry 同步登錄，發現的殘留問題（TC-057 受測檔已刪除但矩陣未標註、TC-049 測試 ID 在兩個測試檔重複）記在 `unit_test.md` 對應條目，未回頭改動 `test/`（P5.2 owned files 不含 `test/`）。
- **對應任務**：M6 P2–P4（commits `90ca085`…`3a7a2b2`…`c20e0ce`），P5.2 稽核（本條）。

### AD-021｜內嵌預覽的「退回最大張」不再無條件：預覽路徑改用 `minLongEdge` 拒絕，側欄與匯出維持寬鬆
- **日期**：2026-08-24
- **決策**：`DngPreviewExtractor.extractEmbeddedJpeg` 新增 `int? minLongEdge`（預設 `null`）。它是**選完之後的拒絕**，不是換一個選擇：`_select` 完全沒動，只有在選中的候選 `max(width, height) < minLongEdge` 時改回傳 `null`。兩種選擇模式（`longEdge == null` 全尺寸、`longEdge != null` 側欄）都適用。預設 `null` 等於改動前的行為，所以每一個既有呼叫端都沒有位移。
- **依據**：M7 使用者裁決 G-2——一張 DNG 的內嵌候選若達不到請求的長邊，應進入真正的 RAW 解碼，而不是被端上一張放不大的縮圖。原本的文件（本檔案舊版與 `dng_preview_extractor.dart` 的說明）把「退回最大張」寫成無條件，現已改寫。
- **只在有 RAW 解碼可進的地方收緊（Decision Log A-6）**：唯一傳入非 null 的呼叫點是 `dart_image_loader.dart` 的非側欄分支，且守衛是 `purpose == preview && lower.endsWith('.dng')`，比「preview 全體」更窄。理由是 loader 的 RAW 解碼逃生口本身就以 `.dng` 為條件（`dart_image_loader.dart:54`）：
  - **側欄**維持寬鬆（P-11/P-13），它的 smallest-then-largest 行為未動；
  - **匯出**維持寬鬆——那條路上沒有 RAW 解碼，收緊只會把「匯出一張略小的圖」變成「匯出失敗」；
  - **非 DNG RAW**（`.cr2`/`.nef`/`.arw`）維持寬鬆，理由與匯出完全相同：拒絕之後掉進的是 `RAW_NO_EMBEDDED_PREVIEW` 失敗，不是解碼。G-2 是一條 DNG 裁決，就讓它留在 DNG。
- **實測後果為零位移**：本輪對 `local_data/photo_samples/DNG` 全部 26 個樣本機械分類（`scripts/tmp/m7-t2/newly-routed.txt`），**NEWLY_ROUTED=0**——13 個今天就沒有合格候選（本來就走 RAW），13 個的最大候選本來就超過 2800。也就是說這條規則在現有樣本組上不會把任何檔案新推進解碼，plan 中「重跑 gate」的驗收條件在此樣本組上是空集合。**這也表示現有樣本組無法測到這個行為**，所以驗收測試一律用合成容器（`test/support/synthetic_dng.dart`），不是真實照片。
- **順帶（M7 裁決 E）**：新增 `_sanitizeOrientation(int?)`，把 IFD0 tag 0x0112 夾到 EXIF 合法的 1..8，超出範圍與 null 都變 1。檔案內四個方位讀取點全部改走它，`?? 1` 已不存在。注意 `readOrientation` 與 `probeContent` 的三態契約（null = 讀不到）**必須保留**——只有「讀到的值」才夾範圍，把 null 一起夾掉會讓「讀不到」和「不旋轉」再度無法區分，那正是 AC12h 當初特意拆開的東西。
- **對應任務**：M7 Task 2。

---

### AD-022｜「容器宣告了預覽但全部讀不到」與「容器沒宣告預覽」是兩個不同的終局狀態
- **日期**：2026-08-24
- **背景**：`DngPreviewExtractor._gatherCandidates` 遇到 strip 位移或長度落在檔案範圍外的候選就跳過。它原本回傳一個裸 list，於是在呼叫端「容器沒宣告任何候選」與「容器宣告的候選全都讀不到」是同一個空 list——結構壞掉的 `.dng` 因此被當成單純沒有預覽圖，交給 RAW 解碼器慢慢失敗，最後吐一個泛用的解碼錯誤。
- **決策**：改回傳 `_CandidateScan {candidates, unreadable}`，且**只有邊界檢查那一種拒絕**計入 `unreadable`。缺 Compression/Photometric/尺寸/strip 標籤、非 JPEG 壓縮、或未達全尺寸的 `0.90 * cropMax` 下限，一律仍是「不是候選」——那是缺席，不是損壞。把這兩者合併會讓每一張普通的無預覽 DNG 都被報成損毀。
- **介面**：新增 `DngPreviewProbe {jpeg, malformed}` 與 `probeEmbeddedJpeg`，由 `dartImageLoad` 的非側欄分支消費，回傳 `NativeImageFailure('DNG_PARSE_FAILED', …)`，並以 `.dng` 為條件（同 A-6 理由：非 DNG RAW 維持統一的 `RAW_NO_EMBEDDED_PREVIEW`，矩陣 F-08）。
- **`malformed` 的界線**：只有在**沒有任何**宣告的候選可讀時才為真——一個壞 strip 旁邊還有一個好的，不算容器損壞。三種情況刻意**不算** malformed，每一種都有一條測試會在界線被移動時失敗：真正無預覽的 DNG（裁決 (b)：仍回 `NeedsRawDecode` 並帶走 walker 讀到的方位）；G-2 判定尺寸不足但本身完好的候選（那是一次刻意的 miss，仍走 RAW 解碼——把它標成 malformed 的突變會讓 Task 2 的路徑轉紅，界線是被驗證出來的而非用斷言宣稱的）；以及在 IFD0 可讀之前就失敗的截斷檔（照舊走到 `null`）。
- **A-1 以否定收斂**：外部計畫是用單次走訪的 `inspectEmbeddedJpeg` 取代雙呼叫形狀來交付這個能力。契約 §2.1 刻意選了雙呼叫，因此 `extractEmbeddedJpeg` 的簽章與回傳型別完全不動，`probeEmbeddedJpeg` 加在它旁邊，沒有遷移任何呼叫端。實作上兩者共用同一個私有 `_probeWalk`，`_walk` 以 `strictBitstream: false` 委派過去，所以兩個入口不可能漂移；唯一的行為差異是 probe 另外要求選中的 strip 以 JPEG SOI 標記開頭。單次走訪是對一個有意識選擇的設計做效能重構，不是行為缺口，在有人量出足以重開 §2.1 的代價之前不進範圍。
- **已知未覆蓋**：strip 位移在範圍內、但內容不是 JPEG 位元流的那條分支（`_readStrip` 的 `strictBitstream` 限）目前沒有測試——合成容器產生器已凍結、產不出這個形狀。該分支經檢視為正確但未經實測，列為 parking-lot，不列為已驗證。
- **對應任務**：M7 Task 3。

---

### AD-023｜PhotoPayloadCache 是「視窗內 FIFO」，不是 LRU
唯一會更新使用順序的讀取介面 `operator []` 從來沒有 lib 呼叫者，所以驅逐一直是
插入順序。M7 Task 3 的決定是刪掉那個介面、把文件改成 FIFO，而**不是**補上 LRU：
`retainOnly` 的 -3..+5 掃描已經把視窗外的東西丟掉了，預算路徑只會在使用者即將
看到的項目之間挑犧牲者，此時到達順序與最近使用一樣好。行為刻意零變更（`_enforceBudget`
本體未動）；`test/photo_payload_cache_test.dart` 的 TC-061 原本用 `operator []`
示範 LRU 行為，已改寫為示範 FIFO（讀取不再保護條目不被驅逐）。

### AD-024｜EXIF Orientation 只有一張表
`exif_orientation.dart` 的 `exifTransformFor` 是全 codebase 唯一的 8 case 對照表；
`package:image` 側（`thumbnail_export_service.dart` 的 `bakeExifOnDecoded`）與
`dart:ui` 側（`decoded_rgba_image_provider.dart` 的 `_ExifTransform.forOrientation`）
都只做「把 `(quarterTurnsCw, mirrored)` 翻譯成該函式庫的操作」。順序固定為先旋
轉、後水平鏡射；改順序等同改語意。這修掉了 A7：舊的 `img.Image.fromBytes` 呼叫
沒帶 `bytesOffset`/`order`，FFI 解碼器回傳的 view（非零 `offsetInBytes`）會被從
buffer 起點讀錯位置——`imageFromDecodedRgba` 現在統一補上這兩個參數，並在
`decoded.rgba.length` 與 `width*height*4` 不符時回傳 `null` 而非組出錯位影像。

### AD-025｜匯出與側欄縮圖的 package:image 運算跑在 worker isolate
`Isolate.run` 只能捕捉可傳送值：路徑、`Uint8List`、`int`、`bool`。RAW FFI 解碼
與 `package:exif` 讀檔留在呼叫端 isolate（前者是 FFI，後者要 mutate 不可傳送的
`img.Image`）。匯出路徑因此在 isolate 回來後才重新掛 EXIF、re-encode 一次；側
欄縮圖的 JPEG encode 整段搬進 `Isolate.run`。凍結的 tier-1/tier-2 provider
identity 與 `NativeImageResult` 三變體不受影響——這是 CPU 搬運，不是介面變更。

### AD-026｜Rename 領域搬進 `RenameCoordinator`，以 supplier callback 讀取即時狀態（不複製）
`renameByExif`/`undoRename`/`loadSavedRenameRule`/`isRenaming`/`cancelRename` 與其私有狀態
（`_isRenaming`、`_renameCancelled`、`_lastRenameIdMap`）從 `AppState` 搬到新檔
`lib/providers/rename_coordinator.dart` 的 `RenameCoordinator`。`readMetadataFor` 留在
`AppState`（重新命名對話框的 5 檔預覽會直接呼叫它），以 `readMetadata` callback 傳入協調器。
**關鍵規則**：協調器建構時只接收 `itemsOf`/`dirOf`/`selectedIdOf` 三個 supplier callback，
從不在建構時複製 `_items`/`_currentDir`/`_selectedItemID` 的當下值——`renameByExif` 執行中會呼叫
`reloadFolder`（即 `AppState.loadFolder`）整批替換 `_items`，`undoRename` 必須讀到 reload 後的
最新狀態，複製快照會讀到過期資料。`_lastRenameIdMap` 的 undo↔status-remap 契約（空批次的早退
必須發生在指派新 map 之前，否則會清掉前一批的 undo 記錄）原樣搬入協調器，行為不變。`AppState`
保留五個同簽章的 thin forwarder，view 與既有測試無感。新增 `AppState.displayProvider` getter
（Task 9 依賴）：回傳 `currentFullResProvider` 或 `currentDecodedProvider` 的**同一個物件**，
絕不自建 provider（凍結的 tier-1/tier-2 cache-key identity 規則）。

### AD-027｜tier-2 就緒性合取由 `TierTwoRegistry` 單一持有（2026-08-24, D1）

- **決策**：`_tierTwoKeys` / `_tierTwoSources` / `_tierTwoReadyIds` / `_fullResFailures` 四個容器與 `isFullSizeReady` 的四項合取，全部搬出 `ImagePreloadController`，改由 `lib/services/tier_two_registry.dart` 的 `TierTwoRegistry` 單一持有。控制器只保留排程（±2 視窗、250ms debounce、序列化佇列）與兩個 provider 工廠。
- **理由**：round-2 BLOCKER 1（id-keyed 記帳描述的是 payload-object-keyed 的 ImageCache 條目）與 BLOCKER 3（`containsKey` 對 pending 條目也回 true）過去只有註解在守；抽出後這四項只存在一處，且可在沒有 controller、payload cache、假 photo source 的情況下直接單元測試（TC-231~238）。
- **不可再拆**：四個容器必須留在同一個類別內。任何一個被搬回控制器或搬進第三個類別，合取就重新散落，兩個 BLOCKER 就重新變成只靠註解守的東西。
- **關聯**：AD-010 / AD-011（`NativeImageResult` 三變體不變，registry 不得 import 該契約）、AD-018（`kTierTwoRadius` 與 `kExpensiveStartupRadius` 仍是兩個常數）。
- **`publishEncoded` 與 `publishFullRes` 的註冊順序相反，且兩者都是刻意的**：前者先 `resolve()`+`addListener` 再於 `obtainKey().then` 內註冊（同步化會讓 `isReady` 比今天更早翻真，正是 BLOCKER 3 守的方向）；後者先同步註冊再 `resolve()`（讓並行的升級決策立即看得到條目，AC-M5-4）。
- **實作偏差**：D1 計畫草稿假設下一個可用編號是 AD-023，但落地時 AD-023~026 已被其他並行任務（main 整治計畫）佔用；本條實際編號為 AD-027。計畫內的 verbatim 程式碼區塊照抄不受影響，僅文件編號順移。
- **已知缺口**：`lib/providers/app_state.dart:200-214` 是 `fullResProviderFor` 的唯一消費者，沒有 null-vs-provider 的直接測試。本次重構沒有讓它更糟，但也沒有補上。

### AD-028｜tier-2 排程由 `TierTwoScheduler` 單一持有（2026-08-25, P4a）

- **決策**：D1 計畫刻意延後的 8 個排程符號（`_tierTwoWindowIds`、`_tierTwoQueue`、`_scheduleTierTwoDecode`、`_decodeTierTwoWindow`、`_enqueueTierTwoLoad`、`_enqueueFullResUpgrade`、`_upgradeFullRes`、`_publishPiggybackFullRes`）全部搬出 `ImagePreloadController`，改由 `lib/services/tier_two_scheduler.dart` 的 `TierTwoScheduler` 持有。控制器只保留 payload 生產、tier-1、側邊欄縮圖、方向備忘錄與兩個 provider 工廠。
- **三個單元，不是兩個**：`TierTwoScheduler` 是**第三個**類別，不是 `TierTwoRegistry` 的擴充。registry 是純狀態（四個容器＋一個查詢 closure，無 async、無 timer）；scheduler 全是相反的東西（timer、視窗、序列化 future chain、FFI 解碼）。把排程狀態併回 registry，等於把 AD-027 好不容易抽離的就緒性合取重新黏回排程狀態上，兩個 BLOCKER 又變回只靠註解守。
- **`_tierTwoDebounceTimer` 一起搬（8 符號清單的必然補項）**：D1 計畫的清單漏了這個欄位，但它就是 `_scheduleTierTwoDecode` 所武裝的那個 debounce，留在控制器則搬走的方法無從操作它。控制器的 `reset()`／`dispose()` 改呼叫 `TierTwoScheduler.cancelDebounce()`，時機與行為不變。
- **協作者一律 closure 注入，不持有物件**：`currentPayloadFor`（綁 `PhotoPayloadCache.peek`）、`fullSizeProviderFor`、`ensurePayload`、`dngDecoder` supplier、`exifOrientationFor`。scheduler 不持有 payload cache、photo source、prefetch scheduler 或控制器本身，所以保留策略、來源選擇與 rung 政策各自維持單一擁有者。**`fullSizeProviderFor` 必須是 supplier 而非複製**：tier-1／tier-2 兩個 provider 工廠必須並排留在控制器內，那個並排本身就是「同一 payload 物件 identity ＝ 同一 ImageCache key」（I1）的可見宣告；在 scheduler 內重建 provider 會出現第二個決定 cache key 的地方。（與 AD-027 的 `currentPayloadFor` 注入同一條規則。）
- **回到控制器的只有兩條薄轉發**：`isInWindow(id)`（payload 生產路徑決定要不要走 piggyback 時問的）與 `publishPiggybackFullRes(...)`（產生那批像素的解碼就跑在控制器的生產路徑上）。`ImagePreloadController` 的公開簽章零變更，`lib/providers/app_state.dart` 零 diff。
- **`tierTwoNavigationDebounce` 以建構參數注入而非 import**：常數留在 `image_preload_controller.dart`（測試與文件都指向那裡），scheduler 收 `navigationDebounce` 參數，避免兩檔互相 import 形成循環。副作用是單元測試可注入 `Duration.zero`，不必為了測 debounce 付出真實 250ms 牆鐘等待。
- **關聯**：AD-027（registry 四容器不可再拆，亦不可與排程重新合併）、AD-018（`kTierTwoRadius` 與 `kExpensiveStartupRadius` 仍是兩個常數）。
- **驗證**：既有 preload 測試檔零編輯全綠（6 檔 54 測試，前後同數同綠）＋新 TC-239~242 四項變異測試留證（`scripts/tmp/p2p4/impl3-mutation.txt`）。

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
- **歷史備註（2026-08-25）**：本條描述的 `NativeThumbnailService` MethodChannel（`halcyon/thumbnail`）與 `AppDelegate.swift` 側的對應 handler 已於 M6（AD-020）整體移除——影像載入現為純 Dart（`dart_image_loader.dart`），macOS 原生端只剩 `halcyon/trash`、`halcyon/open_with` 兩個 channel。本條保留作為歷史紀錄，不代表目前架構。

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
- **歷史備註（2026-08-25）**：本條描述的原生 `targetSize` 分流機制已隨 M6（AD-020）整個移除；主圖/縮圖分流現由純 Dart `dart_image_loader.dart` 依 `ImageRequestPurpose`（`sidebarThumbnail`/`preview`/`export`，見「重要約定」第 3 條）決定，不再有 macOS 原生 MethodChannel 這一層。本條保留作為歷史紀錄。

### G-009｜JDK 25 需要 Gradle 9.1+，且 Flutter Gradle Plugin 暫需 AGP 9 相容模式
- **嚴重程度**：中
- **問題**：舊 toolchain（Gradle 8.12 / AGP 8.9.1 / Kotlin 2.1.0）在 Temurin JDK 25 下會於 Gradle Kotlin DSL 階段失敗，錯誤為 `IllegalArgumentException: 25.0.2`。
- **解法**：升級至 Gradle 9.1.0、AGP 9.0.1、Kotlin 2.3.21；因 Flutter 3.35.1 的 Gradle plugin 在 AGP 9 new DSL 下會 NPE，目前使用 AGP 9 相容模式。
- **狀態**：已修復（Task 14）。`./scripts/build.sh android` 使用 JDK 25 成功。

### G-010｜View 層直接寫入 AppState 欄位（反向資料流，✅ 已解決，2026-08-19 Task 19）
- **嚴重程度**：中
- **現況**：`main_detail_view.dart` 有至少 5 處在 widget build/callback 中直接對 `AppState` 的 public 欄位做 setter，破壞單向資料流（原記載 4 處，本輪多發現 1 處）：
  - `main_detail_view.dart:32`：`_animController` listener 每個動畫 tick 寫入 `context.read<AppState>().transformCtrl.value = _zoomAnimation!.value`（本輪新記錄，頻率高於下列 4 處）
  - `main_detail_view.dart:99`：`context.read<AppState>().shouldAnimateZoom = false`（view 直接關閉 provider 旗標）
  - `main_detail_view.dart:220`：`context.read<AppState>().lastKnownCenter = center`（`LayoutBuilder` 每次 rebuild 寫入）
  - `main_detail_view.dart:282`：`context.read<AppState>().pointerPosition = event.localPosition`（`MouseRegion.onHover`）
  - `main_detail_view.dart:285`：`context.read<AppState>().pointerPosition = null`（`MouseRegion.onExit`）
- **根因**：`app_state.dart:113-119` 的 zoom/animation 欄位（`transformCtrl`、`pointerPosition`、`lastKnownCenter`、`targetMatrix`、`shouldAnimateZoom`）屬於純 View 層狀態，不應放在 business provider；`stepZoomIn()`/`stepZoomOut()`/`_zoomBy()`（`app_state.dart:298-334`）目前仍是 `main_screen.dart:99,102` 鍵盤縮放（`↑`/`↓`）的唯一入口。
- **解法（已實施，方案 B）**：新增 `lib/views/zoom_controller.dart`（`ZoomController extends ChangeNotifier`），持有全部五個欄位與 `stepZoomIn/stepZoomOut/_zoomBy`，並自行建立/釋放 `transformCtrl`。由 `_MainScreenState` 建立與 dispose（**不可**由 `MainDetailView` 持有，否則照片切換時縮放狀態會遺失），以參數注入 `MainDetailView(zoom: _zoom)`。鍵盤 `↑`/`↓` 變成對 controller 的普通方法呼叫，不再經過 provider。
- **狀態**：✅ 已解決（Task 19）。`AppState` 已無任何 zoom 欄位/方法；`main_detail_view.dart` 僅剩 `openFolder()` 與 `setViewportSize()` 兩處與 zoom 無關的 `AppState` 呼叫。

### G-011｜`.halcyon_status.json` 以檔名為 key，重新命名必須 remap
- **嚴重程度**：高
- **問題**：每一個星號、垃圾桶標記與 last-viewed 指標都存在 `PhotoItem.id`（即 basename）底下；任何會重新命名檔案的功能，若不呼叫 `PhotoStatusStore.remapKeys`，標記會被靜默孤立（orphan）。
- **相關陷阱**：`saveStatuses()` 會從頭重建整個 map，只把 `PhotoStatusStore.reservedKeys` 內的 key 帶過去；新增一個非照片 key 卻忘記加進該 set，下一次標星就會把它沖掉。
- **解法**：EXIF 重新命名（`AppState.renameByExif` / `undoRename`）在套用/還原批次後皆呼叫 `remapKeys`；`_rename_rule` 已加入 `reservedKeys`。
- **驗證**：`test/photo_status_store_test.dart`（TC-041~TC-044）、`test/app_state_test.dart`（TC-049~TC-051）。

### G-012｜`PopupMenuItem` 的 `value` 與 `onSelected` 以字串比對，寫錯字面量會讓選單項目靜默失效
- **嚴重程度**：中
- **問題**：`PopupMenuItem` 的 `value` 與 `onSelected` 分支是用字串比對配對；兩邊字面量若不一致，選單項目會靜默失效，且若測試也硬寫字面量，測試本身也抓不到這個 bug。
- **解法**：`kRenameMenuValue`（定義於 `lib/views/rename_dialog.dart`）由選單定義與 `sidebar_view.dart` 的 `onSelected` 分支共用同一常數；`test/sidebar_view_test.dart` 的 TC-055 也引用同一常數而非硬寫 `'rename'`，確保常數改名時測試會一起失敗。
- **驗證**：`test/sidebar_view_test.dart`（TC-055）。
- **注意（文件更正）**：EXIF 重新命名的實作計畫（`docs/superpowers/plans/2026-08-19-exif-rename.md` Task 8）在要求寫入的程式碼註解中引用「memory.md G-005」描述此陷阱，但該編號在本檔實際指向另一件事（Auto-advance / Status Toggle，見上）；正確編號是本條 G-012。經全文 grep `lib/`、`test/` 確認，實作並未真的落地這個錯誤引註字串，僅計畫文件本身寫錯。

### G-013｜`testWidgets` 中對 `PopupMenuItem` 執行 tap 會在 FakeAsync 下掛住
- **嚴重程度**：中
- **問題**：在 `testWidgets` 內對 `PopupMenuButton` 開出的 `PopupMenuItem` 執行 `tester.tap()` 後等待其消失（dismiss animation），會在 `FakeAsync` zone 下永久掛住。
- **解法**：測試改為直接抓 widget 拿到 `PopupMenuButton<String>` 實例，手動呼叫其 `onSelected!(value)`，不透過 tap 觸發選單互動。
- **驗證**：`test/sidebar_view_test.dart`（TC-055，`button.onSelected!(kRenameMenuValue)`）。
- **注意（文件更正）**：實作計畫在要求寫入的程式碼註解中引用「memory.md G-009」描述此陷阱，但該編號在本檔實際指向另一件事（JDK 25 / Gradle 相容性，見上）；正確編號是本條 G-013。經全文 grep `lib/`、`test/` 確認，實作並未真的落地這個錯誤引註字串，僅計畫文件本身寫錯。

### G-014｜實際 toolchain 是 Flutter 3.44.6 / Dart 3.12.2，`RadioListTile.groupValue`/`onChanged` 已棄用
- **嚴重程度**：低
- **問題**：EXIF 重新命名的實作計畫標注 tech stack 為「Flutter 3.35 / Dart 3.9」，但本機實際安裝的 toolchain 是 **Flutter 3.44.6 / Dart 3.12.2**；`RadioListTile` 的 `groupValue`/`onChanged` 參數在 Flutter 3.32 之後已棄用。
- **解法**：`lib/views/rename_dialog.dart`（`rename_dialog.dart:178` 起）改用 `RadioGroup<String>` 祖先 widget 包裹一組 `RadioListTile`，而非計畫文件中字面給出的 `groupValue`/`onChanged` 寫法。
- **注意**：不要把這裡「修回」計畫文件中的舊寫法——那是已棄用的 API，日後升級 Flutter 版本前都應保持 `RadioGroup` 寫法。

### G-015｜量測儀器打錯進入點會產生假 HARD FAIL：G3 量的是全尺寸解碼，不是側欄縮圖抽取
- **嚴重程度**：高（差點誤判一個 PASS 的實作為 FAIL，若真的據此回頭改實作方向會是白工）
- **問題**：M6 P2.6 前的 G3 量測跑出 HARD FAIL——13 個樣本在 Dart 路徑回傳 null，而 native 路徑產出影像，照 Appendix A 判定規則這是「無聚合、無重跑」的硬失敗。但這 13 個 null 剛好精準對應「沒有全尺寸內嵌預覽」的 DNG：預先登記的 Dart 路由呼叫的是**全尺寸進入點**，但那些樣本本來就該用 `extractEmbeddedJpeg(path, longEdge: 200)` 這個側欄縮圖進入點才找得到縮小版預覽——量測腳本打錯了進入點，不是實作真的漏掉這批樣本。
- **根因**：`DngPreviewExtractor` 有兩個進入點（全尺寸 vs `longEdge: 200` 的側欄縮圖），量測腳本的預註冊路由只接了全尺寸那一個，卻拿它去跑本來就該走側欄縮圖進入點的樣本組。
- **識讀方式**：13 個 null 不是隨機分布，而是**精準等於**「無全尺寸內嵌預覽」的樣本子集——這個「完美對應」本身就是路由錯誤的訊號，不是實作缺陷的訊號（真正的實作 bug 通常不會產生這麼乾淨的子集邊界）。
- **解法**：P2.5（decode-time 長邊降尺寸／`instantiateImageCodecWithSize`）+ P2.6 重新用正確進入點跑 G2′/G3′，而不是去改 `dart_image_loader.dart` 的實作去「補上」原本就存在的側欄縮圖路徑。
- **教訓**：任何 HARD FAIL 或看似整齊的失敗子集，先問「量測腳本打的是不是正確的進入點／API」，再假設實作有洞——尤其當失敗樣本的邊界精確符合某個已知的業務語意分類（此處是「有無內嵌預覽」）時，這通常是儀器打錯路由的指紋，而非巧合的真實 bug 分布。這是 `~/.claude/rules/lessons-learned.md` 2026-08-17「否定結果先驗儀器」條目在 M6 的一次具體重演，值得單獨記錄因為它差點造成方向性誤判（若真去改 P2.1 的核心實作而非量測路由，會是白工且引入不必要複雜度）。
- **對應任務**：M6 P2.6（`m6-execution-plan.md:30`「G3 HARD FAIL is an instrument-route artifact」段落）。Artifacts：`scripts/tmp/20260824T084906Z-m6-g1.txt`、`…085119Z-m6-g2.txt`、`…085320Z-m6-g3.txt`。

### G-016｜編碼器的體積優劣取決於內容類型；合成 fixture 會把結論反過來
- **⚠️ 先讀這句**：側欄改用 JPEG q80 的體積優勢是**照片內容的性質**，不是編碼器的普遍性質。**在低熵合成影像（純色塊、條紋、漸層、測試圖卡）上這個結論會反轉，PNG 會贏。** 若你正拿程式產生的測試圖案量這條路徑並看到 JPEG 比較大，那是預期行為，**不是** codec 選錯，也不是實作退步——不要據此改回 PNG，請改用 `local_data/photo_samples/` 的真實照片重量。
- **嚴重程度**：中（會讓一個正確的改動看起來像退步，或讓一個測試假裝證明了它沒證明的事）
- **背景**：M7 Task 5 把側欄快取的重新編碼從 PNG 換成 JPEG q80（`sidebar_thumbnail_codec.dart`）。原本的 PNG 選擇不是設計偏好，而是 `dart:ui` 只能編 PNG；`image` 套件在 P3.6（`dd1edcb`）落地後前提消失，M7 兌現這筆 M6 parking-lot。
- **問題**：既有測試的 fixture `bigPng()` 是 10px 寬的純色直條紋。改成 JPEG 後 `expect(out.length, lessThan(src.length))` 立刻失敗——PNG 5,739 B vs JPEG 14,634 B，**PNG 反而小 2.55 倍**。乍看像是新實作退步了。
- **根因**：這不是實作缺陷，是 fixture 的內容類型剛好站在 PNG 最有利、JPEG 最不利的一端。大面積平坦色塊是 filter+deflate 的理想輸入；銳利條紋邊緣是 DCT 的最壞輸入（高頻能量）。真實照片內容則相反：8 張真實 DNG 樣本上 PNG/JPEG 比值為 4.15x–6.38x，整體 5.06x（`scripts/tmp/m7-t5/size-comparison.md`）。
- **解法**：測試裡**不**斷言體積關係（TC-173 明確寫下不斷言的理由），體積主張改由真實樣本 artifact 承擔；測試只驗它該驗的——SOI marker、decode-back 成功、長邊 <= 200。
- **教訓**：(a) 任何「換編碼器／換壓縮參數」的改動，體積主張必須在**代表真實負載的內容**上量，合成 fixture 只能驗正確性不能驗效益；(b) 遇到合成資料與真實資料結論相反時，先問「這個 fixture 的內容類型是否剛好偏袒某一方」，不要急著改實作，也不要把斷言調鬆到剛好通過——後者是 `judgment-rubrics.md` R4 第 3 點「繞過驗證」的變形；(c) 反面證據要留在 artifact 裡，不是刪掉。
- **對應任務**：M7 Task 5。Artifacts：`scripts/tmp/m7-t5/size-comparison.md`（含反例欄位）、`scripts/tmp/m7-t5/red.log`。

### G-017 文件裡的原生橋接宣稱必須用 grep 對照 AppDelegate.swift
`CLAUDE.md` 有整整一個里程碑的時間在描述一個已被刪除的 `halcyon/thumbnail`
channel、一個不存在的 `NativeThumbnailService`，以及一個指向 112 行檔案第
329 行的行號。刪原生程式碼的同一個 commit 必須同步改文件；審查文件對原生層的
宣稱時，判準是 `grep -n "MethodChannel" macos/Runner/AppDelegate.swift`，不是讀
起來合不合理。

### G-018 一個 Set 不可以同時裝兩種 key 形狀
`image_preload_controller.dart` 的 `_loadingKeys` 曾經同時裝裸 id 與
`thumb_$id`，於是縮圖 sweep 進行中時，detail 路徑的 `_loadingKeys.contains(id)`
永遠答錯（正在跑的是縮圖，答案卻說「detail 也在載入」）。M7 Task 3 拆成
`_loadingKeys`（detail，裸 id）與 `_thumbLoadingKeys`（sidebar，裸 id），`reset()`
兩個都要清。TC-218 驗證此行為。

### G-019 狀態檔寫入必須是原子的，且只能有一條寫入鏈
`.halcyon_status.json` 由兩個獨立的 debounce timer 讀改寫（`_saveStatusCache`
與 `_saveLastViewedId`），過去各自 `writeAsString`。兩個後果：拔卡/當機會留下半寫入
的檔案；先開始的寫入後結束時會用舊快照覆蓋掉另一邊的變更。修法是
`PhotoStatusStore` 內部的 tmp+rename 原子寫入，加上單槽 `_writeChain` 把所有
mutator 串成一條。讀取路徑（`applySavedStatuses`）刻意不入鏈，因為它會呼叫
`saveStatuses`，入鏈會自我死鎖。

### G-020｜`testWidgets` 內真實 `dart:io` 必須包 `tester.runAsync`；view 拆分必須保序兩個陷阱

- **陷阱一（fake-async + 真實 I/O 死結）**：`testWidgets` 的 body 在 flutter_test 的
  fake-async zone 下執行；若直接 `await` 一段走真實 `dart:io`（目錄掃描、開檔、寫檔）的
  Future（例如 `AppState.loadFolder`），該 Future 排入 zone 的微任務佇列後不會自動被
  flush，測試會在近乎零 CPU 的狀態下整個掛住，且 **`--timeout` 形同虛設**（原 G-021，
  2026-08-25 併入本條）：`flutter test --timeout <N>` 的逾時 Timer 排程在同一個 fake-async
  zone 裡，也是假時鐘——卡死的 zone 永遠不會讓它觸發，所以不是「逾時後回報卡住」，而是
  無限期掛住、不印堆疊、不吐逾時訊息。**識讀方式**：CPU 使用率長時間趨近零、與換測試檔案
  內容無關（換任何一個含真實 I/O 的檔案都同樣掛）、加了 `--timeout Ns` 仍無任何輸出——
  最後一點是「卡死發生在 fake-async zone 內」的訊號，不是逾時參數設太短。**解法**：把含
  真實 I/O 的那段包進 `tester.runAsync(() async { ... })`，讓它跑在真實（非 fake）zone，
  逾時計時器才管得到它。**根因驗證**：`scripts/tmp/tc230-ab-io-outside-runasync.log`
  （單變數 A/B：唯一變數是真實 `dart:io` 呼叫在不在 `tester.runAsync()` 裡）。TC-230
  (`test/main_detail_view_test.dart`) 三輪 baton 交接才定位到此，早期誤判為「編譯快取損毀」
  （重跑會複現，不符合快取損毀理論會在第二次冷編譯後消失的預測，因此被推翻），完整過程見
  `docs/logs/2026-08-24/Task_refactor_T9_handoff.md`。
- **陷阱二（view 拆分保序）**：`main_detail_view.dart` 的 `_buildZoomableViewer` 拆分/精簡時
  兩處順序陷阱必須原封不動：(1) PERF-INSTRUMENTATION 呼叫 `_perfResetForSwitch(currentId)`
  （每次 build 開頭）與 `_perfSpinner(currentId)`（spinner 分支內）——順序或次數變了會讓
  效能量測重複計數或漏計；(2) `LayoutBuilder` 內 `widget.zoom.lastKnownCenter = center`
  是刻意的**非通知性**欄位寫入，改成經由 `setState`/`notifyListeners` 會讓 `LayoutBuilder`
  在自己的 builder 裡觸發重建，形成無限迴圈。
- **陷阱三（計畫草稿與實際程式碼的兩處落差，已用程式碼證據收斂）**：D3 落地時發現計畫文件的 Step 9.3/9.8 程式碼草稿與既有程式碼有兩處對不上，均以「保留舊行為」收斂，不是照抄草稿：(1) `HalcyonTokens` 欄位數——計畫草稿只給 6 個欄位，但既有私有 `_Tokens` 類別實際有 **12** 個（`pane`/`dialog`/`surface`/`input`/`border`/`borderSoft`/`text`/`textDim`/`textFaint`/`accent`/`success`/`danger`），其中數個無 1:1 對應；`HalcyonTokens` 依計畫本身「有欄位無對應就新增，不要丟色」的指示，保留全部 12 個欄位，數值逐字抄自 `_Tokens.dark`/`_Tokens.light`。(2) `_buildZoomableViewer` 的 provider 選擇——計畫草稿只傳 `state.displayProvider`，但 `displayProvider` 對「byte-backed 項目且 tier-2 尚未就緒」的情況恆為 `null`（`currentDecodedProvider` 只對 pixel-decoded 項目非 null），照字面實作會讓這個常見的導覽中間幀（tier-2 debounce 250ms 內）畫面直接不渲染，違反凍結的 tier-1/tier-2 契約。實際保留 `pixelProvider ?? tierOneProviderFor(bytes!, width: targetWidth, height: targetHeight)` 作為 fallback，與舊版 4-分支邏輯逐案證明等價（pixel/tier-2 就緒、pixel/未就緒、byte/tier-2 就緒、byte/未就緒四種情況皆對應）。
- **對應任務**：Task 9（D3/D4，`docs/logs/2026-08-24/Task_refactor_T9_handoff.md` §2a/§2b）。

### G-021｜（已併入 G-020 陷阱一，2026-08-25 使用者裁決合併）

`flutter test --timeout` 在 fake-async 卡死下完全失效的機制細節，原為獨立條目，內容已全數併入 G-020 陷阱一；本佔位保留編號供既有引用（收斂契約 AC-2、`unit_test.md` 2026-08-24 列）grep 命中。

### 裁決記錄｜P2（tier-1 視窗保留語意）：調查後未發現放寬，維持現狀不回修

- **日期**：2026-08-25
- **背景**：`docs/logs/2026-08-25/refactor-campaign-handover.md` §8 P2 列宣稱 `ac64146`（"parameterise the retention window"）把 tier-1 視窗保留語意輕微放寬，與計畫 `Task_refactor_plan_main.md:151`「產出的視窗必須與現行 byte-identical」的約束矛盾，需使用者裁決是否回修。
- **調查結果**：逐一機械核對 `ac64146^` 與 `ac64146` 的完整 diff，`lib/services/image_preload_controller.dart` 完全未被該 commit 觸碰；`lib/services/photo_payload_cache.dart` 的 `retentionWindowIds` 唯一改動是把 `kRetentionBefore`/`kRetentionAfter` 兩個寫死常數換成同名預設值的具名參數（`{int before = kRetentionBefore, int after = kRetentionAfter}`），常數本身（3／5）前後不變；`image_preload_controller.dart` 現存三處呼叫點裡，tier-1 的兩處（`:376`、`:977`）皆用全預設 3-arg 形式（與回修前 clamp 算式逐位元組相同），唯一帶顯式 `before/after` 的那處（`:496`）是 tier-2 專用、刻意採用不同半徑 `kTierTwoRadius`，這正是計畫本身 C6 amendment（`Task_refactor_plan_main.md:158`）要求的行為，不是對 tier-1 的放寬。`ac64146` 之後到 HEAD 之間所有觸碰這兩個檔案的 commit（`ef7afd4`／`81f9306`／`b2e0966`）逐一核對，`clamp`/`Retention`/`Radius` 字樣皆無異動。
- **裁決**：使用者裁決——`refactor-campaign-handover.md` §8 P2 該列是文件錯誤（很可能把 M5 時期一個被否決的提案與最終落地的程式碼混淆，見 `m5-implementation-handover.md:96`），不是程式碼問題；**維持現狀，不執行回修**。收斂契約 AC-1 已據此修訂。
- **證據**：`scripts/tmp/p2p4/impl1-task2-p2-investigation.txt`（完整 diff/grep 逐項輸出）。
- **對應任務**：P2–P4 殘留議題修復任務 #2（`docs/logs/2026-08-25/p2-p4-remediation-contract.md`）。

---

## 技術債 (Tech Debt)

| ID | 項目 | 優先順序 | 備註 |
|----|------|----------|------|
| TD-001 | SwiftUI 版本狀態持久化 | 已關閉 | Task 7 退役 SwiftUI，不再實作 |
| TD-002 | Flutter macOS 原生 MethodChannel | 已關閉 | Task 1 / Task 8 已完成 |
| TD-003 | 側邊欄縮圖尺寸 / 載入優先順序優化 | 中 | 可根據視窗大小動態調整縮圖長邊（現行管線見 AD-020：`ImageRequestPurpose` 固定 `sidebarThumbnail`=200px/`preview`=2800px/`export`=2048px，非原生 `targetSize` 參數） |
| TD-004 | 刪除操作移到垃圾桶而非永久刪除 | 低（自動化已驗證，實機待補） | Task 12 已改為 `TrashService` + macOS `FileManager.trashItem`，Task 25 在此之上新增資料夾內 `.trash` 回收模式；`flutter test` 已通過對應案例，`flutter analyze` / `flutter build macos` 與實機 Trash / `.trash` 資料夾視覺覆核仍待使用者補做 |
| TD-005 | `widget_test.dart` 為預設範本，未反映實際 App | 已關閉 | Task 3 已替換為有意義的 smoke test |
| TD-006 | JPG 主圖與縮圖共用 native API 需明確尺寸契約 | 已關閉 | Task 6 / Task 8 修正 macOS 分流 |
| TD-007 | AppState 職責過大 | 已關閉 | Task 9 已拆分掃描、狀態、快取、檔案操作 |
| TD-008 | 支援格式定義分散 | 已關閉 | Task 10 已建立 `SupportedPhotoFormats` registry |
| TD-009 | AGP 9 new DSL / built-in Kotlin 遷移 | 中 | Flutter 3.35.1 相容模式；待 Flutter toolchain 升級後移除相容旗標 |
| TD-010 | `PhotoFileActions` copy/move/delete 完全無單元測試 | **高** | Task 15 待辦；無測試保護下資料操作風險極高 |
| TD-011 | Zoom 狀態（`transformCtrl`、`pointerPosition`）混在 `AppState` | 已關閉 | Task 19 已提取為 view 層 `ZoomController`（AD-015），`AppState` 無殘留 zoom 欄位 |
| TD-012 | macOS `AppDelegate.swift` 缺乏深層錯誤處理 | 中 | CIContext/CIFilter/CGImage 未加 try-catch；無大型 RAW 記憶體上限；Task 17 待辦 |
| TD-013 | `sidebar_view.dart:48` `_itemHeight = 48.0` 硬編碼 | 低 | 主題密度改變時 scroll 位置計算會失準 |
| TD-014 | `sidebar_view.dart` 重複 iconColor 判斷且色值不一致（2026-08-19 重新核實：回收模式改動後已增至 4 處重複，行號全部位移）| 低 | Line 150（`32,32,32`）vs Line 197、266-268、287-289、322-324（皆 `59,59,59`）— 需提取 `_iconColor()` helper；Task 20 待辦。行號取自本輪讀取當下，另一 session 正對此檔做未提交 flicker-fix，下一輪需重新核對 |
| TD-015 | EXIF 重新命名實機驗收未執行 | 中 | plan Task 6 Step 4 / Task 8 Step 6（`flutter run -d macos` 對真實資料夾操作）未執行——本專案禁止 agent-driven UI 驗證；改以 headless Swift probe 對 `local_data/photo_samples/`（一張 SONY JPG、一張 Panasonic DNG）驗證原生 EXIF 讀取回傳真實值。使用者手動驗收（開資料夾、跑重新命名、確認星號保留、undo、確認自訂規則被記住）仍待補 |
| TD-016 | `{direction}`（GPS image direction）未端到端驗證 | 低 | 目前手上沒有任何含 GPS EXIF 的樣本照片；`RenameRule`/`ExifMetadataService` 對 `direction` 的映射邏輯有單元測試覆蓋，但未曾對真實 GPS 資料跑過 |
| TD-017 | `AppState.cancelRename()` / `isRenaming` 無專屬測試 | 低 | 計畫本身未要求此項；取消行為在 service 層由 TC-040 覆蓋，AppState 協調層目前無直接測試 |
| TD-018 | `readMetadataFor` 超過 500 筆的 chunking 在 AppState 層未測試 | 低 | service 層由 TC-047 覆蓋 chunking 行為；AppState 呼叫端把批次串起來的迴圈邏輯目前沒有直接測試 |

---

## 重要約定

1. **JSON 狀態檔**：放在照片目錄根目錄，命名為 `.halcyon_status.json`，以 `.` 開頭確保隱藏。
2. **側邊欄寬度**：預設 270px，可拖曳調整（最小 180px，最大 600px）。
3. **縮圖/影像目標尺寸**（現行，M6 後為純 Dart 管線，見 AD-020）：`ImageRequestPurpose` 決定請求長邊——`sidebarThumbnail` 200px、`preview` 2800px、`export` 2048px；不再有原生端 `targetSize` 分流（原 `NativeThumbnailService` MethodChannel 已隨 M6 移除，見 G-004/G-008 的歷史背景）。
4. **鍵盤快捷鍵**（Flutter）：
   - `←` / `→`：上一張 / 下一張
   - `↑` / `↓`：放大 / 縮小
   - `S`：標記星號
   - `X`：標記刪除
