---
date: 2026-08-19
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

`/Users/jhangyu/Documents/Halcyon/`

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
│   └── build.sh                   # 統一 Flutter build 入口
│
├── (project root)                 # Flutter 主線版本（主要開發分支）
│   ├── pubspec.yaml               # Flutter 依賴管理
│   ├── analysis_options.yaml      # Dart linter 設定
│   ├── lib/
│   │   ├── main.dart              # ChangeNotifierProvider + MaterialApp 主題設定
│   │   ├── models/
│   │   │   ├── photo_item.dart    # PhotoItem + PhotoStatus enum（Flutter 版）
│   │   │   └── supported_photo_formats.dart  # 支援格式 registry 與載入優先順序
│   │   ├── perf/
│   │   │   ├── perf_driver.dart   # 效能埋點驅動（env 變數 gate，debug/release 皆可編譯）
│   │   │   └── perf_log.dart      # 效能埋點記錄與輸出格式
│   │   ├── providers/
│   │   │   └── app_state.dart     # AppState（ChangeNotifier）狀態管理；含 StatusMessage / showStatus() 與唯讀資料夾警告
│   │   ├── services/
│   │   │   ├── native_thumbnail_service.dart  # MethodChannel 影像 request contract
│   │   │   ├── photo_library_scanner.dart     # 資料夾掃描與分組服務
│   │   │   ├── photo_status_store.dart        # `.halcyon_status.json` 讀寫服務；含 `isWritable()` 資料夾可寫性探測
│   │   │   ├── image_preload_controller.dart  # 主圖/縮圖 sliding window cache（tier-1/tier-2 decode）
│   │   │   ├── photo_file_actions.dart        # copy/move/trash 檔案操作服務；回收模式批次刪除
│   │   │   ├── trash_service.dart             # macOS Trash MethodChannel contract（`.trash` 回收與 sibling 分組移動）
│   │   │   ├── decoded_rgba_image_provider.dart  # 已解碼 RGBA 緩衝轉 Flutter `ui.Image` provider
│   │   │   ├── dng_decode_contract.dart       # DngFullDecoder / DecodedRgba 解碼介面契約
│   │   │   ├── dng_decode_service.dart        # DNG 全尺寸解碼服務（flutter_dng_decoder 整合）
│   │   │   ├── open_with_channel.dart         # Finder「開啟方式」冷啟動 MethodChannel
│   │   │   └── thumbnail_export_service.dart  # 星號照片批次匯出縮圖（長邊 ≤ 2048px、bounded concurrency 4、EXIF 保留）
│   │   └── views/
│   │       ├── main_screen.dart       # Scaffold + 鍵盤快捷鍵 + 側邊欄拖曳調整
│   │       ├── sidebar_view.dart      # 側邊欄列表 + 縮圖預載 + 回收模式狀態圖示
│   │       ├── main_detail_view.dart  # ZoomableImageView + 浮動操作列
│   │       ├── zoom_controller.dart   # View 層縮放狀態（由 MainScreen 持有並 dispose；跨照片保留）
│   │       ├── photo_action_bar.dart  # 浮動操作列（星號/刪除/回收模式切換按鈕）
│   │       ├── status_line.dart       # 取代 SnackBar 的自訂狀態列 widget：2.5s 全不透明 → 0.5s 淡出 → 3.0s 移除；重點字反相對比配色
│   │       ├── batch_delete_feedback.dart  # 批次刪除回饋：成功走 status line，失敗走阻斷式 AlertDialog
│   │       └── settings_dialog.dart   # Auto-advance + Overwrite-existing 設定
│   ├── test/
│   │   ├── app_state_test.dart   # AppState 掃描、狀態、導航、request purpose、唯讀資料夾警告測試
│   │   ├── image_preload_controller_test.dart  # sliding window cache 驅逐與 tier-1/tier-2 raw-decode 測試
│   │   ├── zoom_controller_test.dart  # ZoomController 上下限、≤1.05 歸零、焦點選擇測試（TC-023）
│   │   ├── photo_item_test.dart  # PhotoItem 與格式 registry 測試
│   │   ├── photo_file_actions_test.dart  # PhotoFileActions trash/copy/move 行為測試
│   │   ├── photo_action_bar_test.dart    # 浮動操作列按鈕與回收模式切換測試
│   │   ├── batch_delete_feedback_test.dart  # 批次刪除回饋（status line 成功 / AlertDialog 失敗）測試
│   │   ├── status_line_test.dart         # StatusLine widget 時序與配色測試
│   │   ├── sidebar_view_test.dart        # 側邊欄回收模式狀態圖示與選單測試
│   │   ├── decoded_rgba_image_provider_test.dart  # RGBA provider 測試
│   │   ├── dng_decoder_smoke_test.dart   # DNG 解碼 smoke test
│   │   ├── dng_extractor_swift_test.dart # 已交付 DNG extractor 對應 Swift 測試套件
│   │   ├── native_thumbnail_service_test.dart  # NativeThumbnailService request contract 測試
│   │   ├── thumbnail_export_service_test.dart  # ThumbnailExportService 匯出行為測試（bounded concurrency、EXIF 保留、進度回報）
│   │   ├── main_test.dart        # main() 啟動流程測試
│   │   └── widget_test.dart      # 有效 widget smoke test
│   ├── macos/                    # Flutter macOS Runner（MethodChannel native bridge）
│   │   └── Runner/
│   │       └── AppDelegate.swift  # getThumbnail handler + preview/thumbnail native logic
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
| `PhotoLibraryScanner` | `lib/services/photo_library_scanner.dart` | 掃描資料夾、忽略隱藏檔、依 base name 分組 |
| `PhotoStatusStore` | `lib/services/photo_status_store.dart` | `.halcyon_status.json` 讀寫與 orphan cleanup |
| `ImagePreloadController` | `lib/services/image_preload_controller.dart` | 大圖/縮圖 sliding window cache、debounce、驅逐 |
| `PhotoFileActions` | `lib/services/photo_file_actions.dart` | copy/move/trash 檔案操作；回收模式（`.trash`）批次刪除與 sibling 分組移動 |
| `TrashService` | `lib/services/trash_service.dart` | `halcyon/trash` MethodChannel contract，將檔案移入 macOS Trash 或資料夾內 `.trash` |
| `NativeThumbnailService` | `lib/services/native_thumbnail_service.dart` | `preview` / `sidebarThumbnail` / `export` MethodChannel request contract |
| `ThumbnailExportService` | `lib/services/thumbnail_export_service.dart` | 星號照片批次縮圖匯出（長邊 ≤ 2048px、bounded concurrency 4、保留 EXIF、進度回報） |
| `SupportedPhotoFormats` | `lib/models/supported_photo_formats.dart` | 支援副檔名與載入優先順序 registry |
| `DngDecodeService` / `DngDecodeContract` | `lib/services/dng_decode_service.dart`、`lib/services/dng_decode_contract.dart` | DNG 全尺寸解碼服務與介面契約（`flutter_dng_decoder` 整合） |
| `DecodedRgbaImageProvider` | `lib/services/decoded_rgba_image_provider.dart` | 已解碼 RGBA 緩衝轉 `ui.Image` provider |
| `OpenWithChannel` | `lib/services/open_with_channel.dart` | Finder「開啟方式」冷啟動 MethodChannel |
| `StatusLine` | `lib/views/status_line.dart` | 取代 SnackBar 的自訂狀態列 widget（唯讀資料夾警告、批次刪除成功訊息） |

## 重要路徑約定

| 約定 | 路徑/值 |
|------|---------|
| 照片支援副檔名 | `.jpg`, `.jpeg`, `.arw`, `.rw2`, `.dng`, `.heic`, `.png` |
| JSON 狀態檔 | `{folder}/.halcyon_status.json` |
| 側邊欄縮圖 targetSize | `200`（px）|
| 主圖 targetSize | `10000`（px，高解析/全尺寸預覽）|
| 側邊欄寬度範圍 | 180px – 600px（預設 270px）|
| Flutter macOS Runner | `macos/Runner/` |
| Android build toolchain | Gradle 9.1.0 + AGP 9.0.1 + Kotlin 2.3.21（AGP 9 相容模式）|
| Android JDK | macOS 上 `scripts/build.sh` 優先使用 Temurin JDK 25，fallback 至 Homebrew JDK 21 / 17 |
| SwiftUI 版本 | 已於 Task 7 退役，不再維護 `Sources/PhotoSelector/` |
| Status line 時序 | 2.5s 全不透明 → 0.5s 淡出 → 3.0s 移除（取代 SnackBar 250ms 淡出）|
| 資料夾可寫性探測 | `PhotoStatusStore.isWritable()`：建立再刪除 `.halcyon_write_probe`（exFAT noowners 掛載下權限位不可靠，僅能實測）|
| 回收模式 | 同名 sibling（`.cr2`/`.nef`/`.orf`…）自動分組，批次刪除移入資料夾內 `.trash`，碰撞時附加後綴 |
