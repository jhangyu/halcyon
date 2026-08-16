---
date: 2026-05-05
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
│   │   ├── providers/
│   │   │   └── app_state.dart     # AppState（ChangeNotifier）狀態管理
│   │   ├── services/
│   │   │   ├── native_thumbnail_service.dart  # MethodChannel 影像 request contract
│   │   │   ├── photo_library_scanner.dart     # 資料夾掃描與分組服務
│   │   │   ├── photo_status_store.dart        # `.halcyon_status.json` 讀寫服務
│   │   │   ├── image_preload_controller.dart  # 主圖/縮圖 sliding window cache
│   │   │   ├── photo_file_actions.dart        # copy/move/trash 檔案操作服務
│   │   │   └── trash_service.dart             # macOS Trash MethodChannel contract
│   │   └── views/
│   │       ├── main_screen.dart       # Scaffold + 鍵盤快捷鍵 + 側邊欄拖曳調整
│   │       ├── sidebar_view.dart      # 側邊欄列表 + 縮圖預載
│   │       ├── main_detail_view.dart  # ZoomableImageView + 浮動操作列
│   │       └── settings_dialog.dart   # Auto-advance + Overwrite-existing 設定
│   ├── test/
│   │   ├── app_state_test.dart   # AppState 掃描、狀態、導航、request purpose 測試
│   │   ├── image_preload_controller_test.dart  # sliding window cache 驅逐測試
│   │   ├── photo_item_test.dart  # PhotoItem 與格式 registry 測試
│   │   ├── photo_file_actions_test.dart  # PhotoFileActions trash/copy/move 行為測試
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
| `PhotoFileActions` | `lib/services/photo_file_actions.dart` | copy/move/trash 檔案操作 |
| `TrashService` | `lib/services/trash_service.dart` | `halcyon/trash` MethodChannel contract，將檔案移入 macOS Trash |
| `NativeThumbnailService` | `lib/services/native_thumbnail_service.dart` | `preview` / `sidebarThumbnail` MethodChannel request contract |
| `SupportedPhotoFormats` | `lib/models/supported_photo_formats.dart` | 支援副檔名與載入優先順序 registry |

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
