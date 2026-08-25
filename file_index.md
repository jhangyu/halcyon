---
date: 2026-08-25
title: "Halcyon — 專案檔案地圖與目錄對照 (File Index)"
---

## 🧭 檔案維護政策

**用途**：全專案唯一檔案與目錄對照表，AI 應優先依此定位檔案，避免無謂全域搜索。

**更新時機**：
- 新增、搬移、刪除核心檔案/資料夾時，**必須同次提交**更新目錄樹與說明。
- 任務結束前確認本檔同步正確。

**必填欄位**：`date`（YYYY-MM-DD）、`title`、目錄樹（含專案根目錄絕對路徑）、檔案說明。

**跨檔同步對象**：
- `plan.md` 的交付物清單需與本檔一致。
- `task.md` 的子任務路徑需與本檔一致。

---

## 📁 專案根目錄

`/Users/jhangyu/project/Halcyon/`

```
Halcyon/
├── rule.md                        # 開發標準作業程序（SOP）
├── memory.md                      # 全域知識庫與 Gotchas
├── task.md                        # 任務真實狀態看板
├── handover.md                    # 短期交接摘要
├── plan.md                        # 中長期里程碑與路線圖
├── file_index.md                  # 本檔（檔案地圖）
├── unit_test.md                   # 測試策略與品質門檻
├── README.md                      # 專案整體說明文件
├── scripts/
│   ├── build_apps.py              # 統一 build 入口（native + Flutter，六平台）
│   ├── package_windows.sh         # 打包 Windows 交付 zip
│   └── windows/README_WINDOWS.md  # 該 zip 的收件說明
│
├── (project root)                 # Flutter 主線版本（主要開發分支）
│   ├── pubspec.yaml               # Flutter 依賴管理
│   ├── analysis_options.yaml      # Dart linter 設定
│   ├── lib/
│   │   ├── main.dart              # ChangeNotifierProvider + MaterialApp 主題設定
│   │   ├── models/
│   │   │   ├── photo_item.dart    # PhotoItem + PhotoStatus enum（Flutter 版）
│   │   │   ├── supported_photo_formats.dart  # 支援格式 registry 與載入優先順序
│   │   │   └── rename_rule.dart   # EXIF 檔名模板純函式渲染（ExifMetadata、RenameRule、presets、variableGroups；2026-08-25 從 `services/` 移入，見 memory.md AD-030）
│   │   ├── perf/
│   │   │   ├── perf_driver.dart   # 效能埋點驅動（env 變數 gate，debug/release 皆可編譯）
│   │   │   └── perf_log.dart      # 效能埋點記錄與輸出格式
│   │   ├── providers/
│   │   │   └── app_state.dart     # AppState（ChangeNotifier）狀態管理；含 StatusMessage / showStatus() 與唯讀資料夾警告
│   │   ├── services/                          # 四個目的分類子資料夾，無散落檔案（2026-08-25 structure refactor，見 memory.md AD-030）
│   │   │   ├── image_pipeline/                # tier-1/tier-2 sliding preload、DNG 解碼、image cache 相關（18 檔）
│   │   │   │   ├── image_preload_controller.dart  # 主圖/縮圖 sliding window cache（tier-1/tier-2 decode）
│   │   │   │   ├── decoded_rgba_image_provider.dart  # 已解碼 RGBA 緩衝轉 Flutter `ui.Image` provider
│   │   │   │   ├── dng_decode_contract.dart       # DngFullDecoder / DecodedRgba 解碼介面契約
│   │   │   │   ├── dng_decode_service.dart        # DNG 全尺寸解碼服務（flutter_dng_decoder 整合）
│   │   │   │   ├── dart_image_loader.dart          # `dartImageLoad`：純 Dart 生產實作，取代已刪除的 native thumbnail MethodChannel（M6 C-1/C-2，無 Platform 分支）
│   │   │   │   ├── image_source_types.dart         # `NativeImageLoad` seam 的純型別（`ImageRequestPurpose`、`NativeImageResult` 3 變體）；M6 P3.3 從舊 native_thumbnail_service.dart 拆出
│   │   │   │   ├── photo_source.dart               # `PhotoSource.probe`：從內容量測來源成本（`SourceCost`），供 scheduler 消費
│   │   │   │   ├── prefetch_scheduler.dart         # 排程常數：expensive source 啟動半徑、tier-2 precache 半徑
│   │   │   │   ├── photo_payload.dart              # `PhotoPayload`：單張照片可保留的最便宜形式；`byteCost` 是 cache 唯一可見介面
│   │   │   │   ├── photo_payload_cache.dart        # 保留窗口 cache（`kRetentionBefore`=3／`kRetentionAfter`=5），依 `byteCost` 總量驅逐
│   │   │   │   ├── raw_pixels_image.dart           # `RawPixelsImage`：以保留的 RGBA8 像素為後盾的 `ImageProvider`（M3，取代已刪除的 decoded-image provider）
│   │   │   │   ├── raw_full_res_image.dart         # `RawFullResImage`：一次性 `ImageProvider`，交出已解碼全尺寸 `ui.Image`（RAW tier-2 對應）
│   │   │   │   ├── dng_embedded_jpeg_extractor.dart      # `macos/Runner/DngPreviewExtractor.swift`（上游已移除）的純 Dart 移植；讀取 DNG TIFF SubIFD 內嵌 JPEG 縮圖
│   │   │   │   ├── exif_orientation.dart           # 全專案唯一 EXIF Orientation 對照表（8 態旋轉/鏡射），供匯出與 RGBA provider 共用
│   │   │   │   ├── sidebar_thumbnail_codec.dart    # 側邊欄 byte cache 邊界策略（M6 F-10 half 2，re-encode threshold）
│   │   │   │   ├── cache_budget.dart               # 依實體記憶體推導 image-cache 預算（M6 F-25/P5.1，256–768 MiB 夾限）
│   │   │   │   ├── tier_two_registry.dart          # tier-2（全尺寸）ImageCache 記帳；`isReady` 四項合取的唯一來源（AD-027）
│   │   │   │   └── tier_two_scheduler.dart         # tier-2 排程（±2 視窗、250ms debounce、序列化佇列）單一持有者（AD-028）
│   │   │   ├── library/                        # 資料夾掃描、狀態持久化、檔案操作、匯出（4 檔）
│   │   │   │   ├── photo_library_scanner.dart     # 資料夾掃描與分組服務
│   │   │   │   ├── photo_status_store.dart        # `.halcyon_status.json` 讀寫服務；含 `isWritable()` 資料夾可寫性探測
│   │   │   │   ├── photo_file_actions.dart        # copy/move/trash 檔案操作服務；回收模式批次刪除
│   │   │   │   └── photo_export_service.dart      # 星號照片批次匯出縮圖（長邊 ≤ 2048px、bounded concurrency 4、EXIF 保留）
│   │   │   ├── rename/                         # EXIF 重新命名子系統（3 檔）
│   │   │   │   ├── rename_service.dart             # 無碰撞重新命名規劃（planRenames）+ 套用與 JSONL undo journal（applyRenames/undoLastRename）
│   │   │   │   ├── exif_metadata_service.dart      # `halcyon/exif` batch reader（macOS 原生優先，`exif` package fallback）
│   │   │   │   └── rename_coordinator.dart         # RenameCoordinator：EXIF 重新命名/undo/規則記憶（D2 從 AppState 抽出，見 memory.md AD-026；2026-08-25 從 `providers/` 移入，見 AD-030）
│   │   │   └── platform/                       # 平台 MethodChannel 橋接（2 檔）
│   │   │       ├── open_with_channel.dart         # Finder「開啟方式」冷啟動 MethodChannel
│   │   │       └── trash_service.dart             # macOS Trash MethodChannel contract（`.trash` 回收與 sibling 分組移動）
│   │   └── views/
│   │       ├── main_screen.dart       # Scaffold + 鍵盤快捷鍵 + 側邊欄拖曳調整
│   │       ├── sidebar_view.dart      # 側邊欄列表 + 縮圖預載 + 回收模式狀態圖示 + Rename by EXIF... 選單項
│   │       ├── main_detail_view.dart  # ZoomableImageView + 浮動操作列
│   │       ├── zoom_controller.dart   # View 層縮放狀態（由 MainScreen 持有並 dispose；跨照片保留）
│   │       ├── photo_action_bar.dart  # 浮動操作列（星號/刪除/回收模式切換按鈕）
│   │       ├── status_line.dart       # 取代 SnackBar 的自訂狀態列 widget：2.5s 全不透明 → 0.5s 淡出 → 3.0s 移除；重點字反相對比配色；支援重新命名 undo/cancel 按鈕
│   │       ├── batch_delete_feedback.dart  # 批次刪除回饋：成功走 status line，失敗走阻斷式 AlertDialog
│   │       ├── rename_dialog/                # 2026-08-25 起自身即為 feature folder，見 memory.md AD-030
│   │       │   ├── rename_dialog.dart   # 兩窗格 EXIF 重新命名對話框骨架（scaffold/header，222 行；子元件同層）
│   │       │   ├── rule_editor.dart     # RuleEditor：preset 清單、規則模板欄位、插入變數 chip 群組
│   │       │   ├── preview_list.dart    # RenamePreviewList：重擲控制 + 5 檔即時預覽卡片
│   │       │   ├── actions.dart         # RenameActions：頁尾檔案數 + 取消/執行按鈕
│   │       │   └── section_label.dart   # renameSectionLabel()：RuleEditor 與 RenamePreviewList 共用的小型大寫標題
│   │       ├── theme_tokens.dart      # HalcyonTokens（ThemeExtension）：main.dart ThemeData／舊 rename_dialog _Tokens／sidebar_view 內聯 Colors.* 三套色彩系統的單一來源
│   │       └── settings_dialog.dart   # Auto-advance + Overwrite-existing 設定
│   ├── test/                     # 鏡射 lib/ 新結構（2026-08-25 structure refactor，見 memory.md AD-030）
│   │   ├── providers/
│   │   │   ├── app_state_test.dart   # AppState 掃描、狀態、導航、request purpose、唯讀資料夾警告測試
│   │   │   └── app_state_open_with_test.dart  # AppState「開啟方式」整合測試
│   │   ├── services/
│   │   │   ├── image_pipeline/
│   │   │   │   ├── image_preload_controller_test.dart  # sliding window cache 驅逐與 tier-1/tier-2 raw-decode 測試
│   │   │   │   ├── image_preload_controller_m3_amend3_test.dart  # M3 amend3：preload controller 追加行為測試
│   │   │   │   ├── image_preload_dual_window_m5_test.dart  # M5 dual-window（tier-1/tier-2 並行）測試
│   │   │   │   ├── image_preload_scheduling_m4_test.dart  # M4 preload 排程測試
│   │   │   │   ├── image_preload_window_test.dart  # preload window 邊界測試
│   │   │   │   ├── sidebar_thumbnail_codec_test.dart  # 側邊欄縮圖 byte cache 邊界測試
│   │   │   │   ├── decoded_rgba_image_provider_test.dart  # RGBA provider 測試
│   │   │   │   ├── dng_decoder_smoke_test.dart   # DNG 解碼 smoke test
│   │   │   │   ├── dng_nav_probe_m3_test.dart    # M3：DNG 導覽 probe 測試
│   │   │   │   ├── dng_embedded_jpeg_extractor_test.dart  # DngEmbeddedJpegExtractor 基礎行為測試
│   │   │   │   ├── dng_embedded_jpeg_extractor_m0_test.dart  # M0：位元組範圍讀取與候選選取測試
│   │   │   │   ├── dng_embedded_jpeg_extractor_f3_test.dart  # F3：DngEmbeddedJpegExtractor 追加測試
│   │   │   │   ├── dng_embedded_jpeg_extractor_endian_test.dart  # TIFF endian 處理測試
│   │   │   │   ├── dart_image_loader_test.dart   # dartImageLoad 生產實作測試
│   │   │   │   ├── photo_source_test.dart        # PhotoSource.probe 成本量測測試
│   │   │   │   ├── photo_source_probe_test.dart  # PhotoSource probe 行為測試
│   │   │   │   ├── photo_source_single_probe_test.dart  # 單一 probe 呼叫語意測試
│   │   │   │   ├── photo_payload_cache_test.dart  # PhotoPayloadCache 保留窗口與驅逐測試
│   │   │   │   ├── raw_pixels_image_test.dart    # RawPixelsImage provider 測試
│   │   │   │   ├── cache_budget_test.dart        # CacheBudget 記憶體預算推導測試
│   │   │   │   ├── exif_orientation_test.dart    # EXIF Orientation 8 態轉換測試
│   │   │   │   ├── tier_two_registry_test.dart   # TierTwoRegistry isReady 四項合取測試
│   │   │   │   └── tier_two_scheduler_test.dart  # TierTwoScheduler 排程測試
│   │   │   ├── library/
│   │   │   │   ├── photo_file_actions_test.dart  # PhotoFileActions trash/copy/move 行為測試
│   │   │   │   ├── photo_status_store_test.dart  # PhotoStatusStore 規則持久化與 key remap 測試（TC-041~TC-044）
│   │   │   │   └── photo_export_service_test.dart  # PhotoExportService 匯出行為測試（bounded concurrency、EXIF 保留、進度回報）
│   │   │   ├── rename/
│   │   │   │   ├── rename_service_test.dart      # planRenames/applyRenames/undoLastRename 測試（TC-031~TC-040）
│   │   │   │   ├── rename_coordinator_test.dart  # RenameCoordinator 測試
│   │   │   │   └── exif_metadata_service_test.dart  # ExifMetadataService batch reader 測試（TC-045~TC-048）
│   │   │   └── platform/
│   │   │       └── open_with_channel_test.dart   # OpenWithChannel push-only 行為測試
│   │   ├── models/
│   │   │   ├── photo_item_test.dart  # PhotoItem 與格式 registry 測試
│   │   │   └── rename_rule_test.dart         # RenameRule 模板渲染測試（TC-024~TC-030）
│   │   ├── views/
│   │   │   ├── zoom_controller_test.dart  # ZoomController 上下限、≤1.05 歸零、焦點選擇測試（TC-023）
│   │   │   ├── photo_action_bar_test.dart    # 浮動操作列按鈕與回收模式切換測試
│   │   │   ├── status_line_test.dart         # StatusLine widget 時序與配色測試
│   │   │   ├── sidebar_view_test.dart        # 側邊欄回收模式狀態圖示與選單測試
│   │   │   ├── sidebar_view_m1_test.dart     # M1：側邊欄縮圖相關測試
│   │   │   ├── rename_dialog_test.dart       # RenameDialog widget 測試（TC-052~TC-054）
│   │   │   ├── theme_tokens_test.dart        # HalcyonTokens fallback / lerp 測試（TC-229/TC-229b）
│   │   │   └── main_detail_view_test.dart    # MainDetailView spinner 分支測試（TC-230）
│   │   ├── perf/
│   │   │   └── perf_log_build_stamp_test.dart  # perf_log build stamp 測試
│   │   ├── m6_bridge_free_test.dart      # M6：驗證產出無 MethodChannel/native bridge 依賴（C-3）
│   │   ├── main_test.dart        # main() 啟動流程測試
│   │   ├── widget_test.dart      # 有效 widget smoke test
│   │   └── support/
│   │       └── synthetic_dng.dart  # 測試用合成 DNG bytes 產生器（非測試檔本身；不隨鄰近測試移動，路徑不變）
│   ├── macos/                    # Flutter macOS Runner（MethodChannel native bridge）
│   │   └── Runner/
│   │       └── AppDelegate.swift  # getThumbnail handler + preview/thumbnail native logic；`halcyon/exif` batch EXIF 讀取 handler（header-only、native-parallel）
│   ├── ios/                      # Flutter iOS Runner（參考實作）
│   │   └── Runner/
│   │       └── AppDelegate.swift  # MethodChannel handler 參考
│   ├── android/                  # Flutter Android Runner 原始碼與 Gradle / AGP / Kotlin 設定
│   │   ├── settings.gradle.kts    # AGP / Kotlin plugin 版本
│   │   ├── gradle.properties      # AGP 9 相容旗標與 Gradle JVM 設定
│   │   ├── gradle/wrapper/        # Gradle 9.1.0 wrapper
│   │   └── app/
│   │       ├── build.gradle.kts   # Android app module、NDK、Kotlin compilerOptions
│   │       └── proguard-rules.pro # R8 / ProGuard 專案規則
│   ├── web/                      # Flutter Web Runner 與靜態入口
│   ├── windows/                  # Flutter Windows Runner 原始碼與 CMake 設定
│   ├── linux/                    # Flutter Linux Runner 原始碼與 CMake 設定
│   └── ...
│
├── build/                        # Flutter build outputs（git ignored）
│   ├── macos/                    # macOS release/debug/profile 產物
│   ├── app/outputs/              # Android APK/AAB 產物
│   ├── web/                      # Web release 產物
│   ├── windows/                  # Windows desktop 產物
│   └── linux/                    # Linux desktop 產物
│
├── docs/
│   └── logs/                     # Unified Task Log 存放處
│       └── YYYY-MM-DD/
│           └── Task_*.md         # 單一任務日誌
│
├── assets/
│   └── icons/
│       ├── icon.png              # 專案層級 bitmap 圖示來源
│       └── icon.svg              # 專案層級 vector 圖示來源
│
├── artifacts/                    # 本機封存與 build cache（git ignored）
│   ├── archives/                 # 例如舊版 `PhotoSelector.zip`
│   └── build_cache/              # 例如已退役 SwiftPM `.build`
│
└── local_data/                   # 本機測試照片與狀態檔（git ignored）
    └── photo_samples/
        ├── DNG/
        └── JPG/
```

---

## 📄 核心文件速查

| 檔案 | 用途 | 緊急度 |
|------|------|--------|
| `rule.md` | 開發 SOP / Startup Protocol | 高 |
| `task.md` | 當前任務看板（ACTIVE）| 高 |
| `handover.md` | 短期交接摘要 | 高 |
| `memory.md` | 架構決策 / Gotchas | 中 |
| `plan.md` | Phase 里程碑進度 | 中 |
| `file_index.md` | 本檔 | 中 |
| `unit_test.md` | 測試策略 | 中 |
| `README.md` | 專案入口 | 中 |

---

## 🔧 程式碼邏輯對照

### Flutter 版 — 核心模組

| 模組 | 檔案位置 | 功能 |
|------|----------|------|
| `AppState` | `lib/providers/app_state.dart` | UI 狀態協調、選取、標記、設定與服務呼叫 |
| `PhotoLibraryScanner` | `lib/services/library/photo_library_scanner.dart` | 掃描資料夾、忽略隱藏檔、依 base name 分組 |
| `PhotoStatusStore` | `lib/services/library/photo_status_store.dart` | `.halcyon_status.json` 讀寫與 orphan cleanup |
| `ImagePreloadController` | `lib/services/image_pipeline/image_preload_controller.dart` | 大圖/縮圖 sliding window cache、debounce、驅逐 |
| `TierTwoRegistry` | `lib/services/image_pipeline/tier_two_registry.dart` | tier-2（全尺寸）ImageCache 記帳：哪個 id 有條目、為哪個 payload 物件解的、解碼是否已完成、該 payload 的全解析升級是否已失敗。`isReady` 的四項合取只存在於此（AD-027）。不含排程 |
| `PhotoFileActions` | `lib/services/library/photo_file_actions.dart` | copy/move/trash 檔案操作；回收模式（`.trash`）批次刪除與 sibling 分組移動 |
| `TrashService` | `lib/services/platform/trash_service.dart` | `halcyon/trash` MethodChannel contract，將檔案移入 macOS Trash 或資料夾內 `.trash` |
| `dartImageLoad` | `lib/services/image_pipeline/dart_image_loader.dart` | 純 Dart 影像位元組生產實作，取代已刪除的 native thumbnail MethodChannel；`ImageRequestPurpose` 決定目標長邊（sidebarThumbnail 200px／preview 2800px／export 2048px） |
| `PhotoSource` / `PrefetchScheduler` | `lib/services/image_pipeline/photo_source.dart`、`lib/services/image_pipeline/prefetch_scheduler.dart` | `PhotoSource.probe` 從內容量測來源成本；排程常數控制 expensive source 啟動半徑與 tier-2 precache 半徑 |
| `PhotoPayload` / `PhotoPayloadCache` | `lib/services/image_pipeline/photo_payload.dart`、`lib/services/image_pipeline/photo_payload_cache.dart` | 單張照片可保留的最便宜形式（`byteCost` 為 cache 唯一可見介面）；保留窗口 cache（`kRetentionBefore`=3／`kRetentionAfter`=5） |
| `RawPixelsImage` / `RawFullResImage` | `lib/services/image_pipeline/raw_pixels_image.dart`、`lib/services/image_pipeline/raw_full_res_image.dart` | RAW tier-1（保留像素現解）/ tier-2（已解碼全尺寸）兩個 `ImageProvider`（M3） |
| `CacheBudget` | `lib/services/image_pipeline/cache_budget.dart` | 依實體記憶體推導 image-cache 預算，256–768 MiB 夾限（M6 F-25/P5.1） |
| `DngEmbeddedJpegExtractor` | `lib/services/image_pipeline/dng_embedded_jpeg_extractor.dart` | `DngPreviewExtractor.swift` 的純 Dart 移植，讀取 DNG TIFF SubIFD 內嵌 JPEG 縮圖 |
| `ExifOrientation` | `lib/services/image_pipeline/exif_orientation.dart` | 全專案唯一 EXIF Orientation 對照表（8 態），匯出與 RGBA provider 共用 |
| `PhotoExportService` | `lib/services/library/photo_export_service.dart` | 星號照片批次縮圖匯出（長邊 ≤ 2048px、bounded concurrency 4、保留 EXIF、進度回報） |
| `SupportedPhotoFormats` | `lib/models/supported_photo_formats.dart` | 支援副檔名與載入優先順序 registry |
| `DngDecodeService` / `DngDecodeContract` | `lib/services/image_pipeline/dng_decode_service.dart`、`lib/services/image_pipeline/dng_decode_contract.dart` | DNG 全尺寸解碼服務與介面契約（`flutter_dng_decoder` 整合） |
| `DecodedRgbaImageProvider` | `lib/services/image_pipeline/decoded_rgba_image_provider.dart` | 已解碼 RGBA 緩衝轉 `ui.Image` provider |
| `OpenWithChannel` | `lib/services/platform/open_with_channel.dart` | Finder「開啟方式」冷啟動 MethodChannel |
| `StatusLine` | `lib/views/status_line.dart` | 取代 SnackBar 的自訂狀態列 widget（唯讀資料夾警告、批次刪除成功訊息、重新命名 undo/cancel） |
| `RenameRule` / `planRenames` / `applyRenames` | `lib/models/rename_rule.dart`、`lib/services/rename/rename_service.dart` | EXIF 檔名模板純函式渲染 + 無碰撞規劃 + 套用與 JSONL undo journal |
| `ExifMetadataService` | `lib/services/rename/exif_metadata_service.dart` | `halcyon/exif` batch 讀取（macOS 原生優先、`exif` package fallback），chunk 大小 `kExifChunkSize = 500` |
| `RenameDialog` | `lib/views/rename_dialog/rename_dialog.dart` | 兩窗格 EXIF 重新命名對話框；`kRenameMenuValue` 常數與 `sidebar_view.dart` 選單共用 |
| `RenameCoordinator` | `lib/services/rename/rename_coordinator.dart` | EXIF 重新命名/undo/規則記憶（D2 從 AppState 抽出，2026-08-25 從 `providers/` 移入 `services/rename/`，見 memory.md AD-026/AD-030） |
| `TierTwoScheduler` | `lib/services/image_pipeline/tier_two_scheduler.dart` | tier-2 排程（±2 視窗、250ms debounce、序列化佇列）單一持有者（AD-028） |

## 重要路徑約定

| 約定 | 路徑/值 |
|------|---------|
| 照片支援副檔名 | `.jpg`, `.jpeg`, `.arw`, `.rw2`, `.dng`, `.heic`, `.png` |
| JSON 狀態檔 | `{folder}/.halcyon_status.json` |
| 影像請求長邊（`ImageRequestPurpose`） | sidebarThumbnail 200px／preview 2800px／export 2048px（`lib/services/image_pipeline/image_source_types.dart`）|
| 側邊欄寬度範圍 | 180px – 600px（預設 270px）|
| Flutter macOS Runner | `macos/Runner/` |
| Android build toolchain | Gradle 9.1.0 + AGP 9.0.1 + Kotlin 2.3.21（AGP 9 相容模式）|
| Android JDK | macOS 上 `scripts/build_apps.py` 優先使用 Temurin JDK 25，fallback 至 Homebrew JDK 21 / 17 |
| SwiftUI 版本 | 已於 Task 7 退役，不再維護 `Sources/PhotoSelector/` |
| Status line 時序 | 2.5s 全不透明 → 0.5s 淡出 → 3.0s 移除（取代 SnackBar 250ms 淡出）|
| 資料夾可寫性探測 | `PhotoStatusStore.isWritable()`：建立再刪除 `.halcyon_write_probe`（exFAT noowners 掛載下權限位不可靠，僅能實測）|
| 回收模式 | 同名 sibling（`.cr2`/`.nef`/`.orf`…）自動分組，批次刪除移入資料夾內 `.trash`，碰撞時附加後綴 |
| EXIF 重新命名 undo log | `{folder}/.halcyon_rename_log.jsonl`（append-only，JSON Lines 而非陣列，避免 10,000 筆時 O(n²) 重寫） |
| EXIF 讀取 channel | `halcyon/exif`（macOS 原生，header-only、`DispatchQueue.concurrentPerform` 平行讀取）；chunk 大小 `kExifChunkSize = 500` |
