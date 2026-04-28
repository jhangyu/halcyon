---
date: 2026-04-29
title: "Photo Selector — 專案檔案地圖與目錄對照 (File Index)"
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

`/Users/jhangyu/Documents/Photo_Selector/`

```
Photo_Selector/
├── rule.md                        # 開發標準作業程序（SOP）
├── memory.md                      # 全域知識庫與 Gotchas
├── task.md                        # 任務真實狀態看板
├── handover.md                    # 短期交接摘要
├── plan.md                        # 中長期里程碑與路線圖
├── file_index.md                  # 本檔（檔案地圖）
├── unit_test.md                   # 測試策略與品質門檻
├── README.md                      # 專案整體說明文件
│
├── photo_selector_flutter/         # Flutter 主線版本（主要開發分支）
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
│   │   │   ├── photo_status_store.dart        # `.photo_selector_status.json` 讀寫服務
│   │   │   ├── image_preload_controller.dart  # 主圖/縮圖 sliding window cache
│   │   │   └── photo_file_actions.dart        # copy/move/delete 檔案操作服務
│   │   └── views/
│   │       ├── main_screen.dart       # Scaffold + 鍵盤快捷鍵 + 側邊欄拖曳調整
│   │       ├── sidebar_view.dart      # 側邊欄列表 + 縮圖預載
│   │       ├── main_detail_view.dart  # ZoomableImageView + 浮動操作列
│   │       └── settings_dialog.dart   # Auto-advance + Overwrite-existing 設定
│   ├── test/
│   │   ├── app_state_test.dart   # AppState 掃描、狀態、導航、request purpose 測試
│   │   ├── image_preload_controller_test.dart  # sliding window cache 驅逐測試
│   │   ├── photo_item_test.dart  # PhotoItem 與格式 registry 測試
│   │   └── widget_test.dart      # 有效 widget smoke test
│   ├── macos/                    # Flutter macOS Runner（MethodChannel native bridge）
│   │   └── Runner/
│   │       └── AppDelegate.swift  # getThumbnail handler + preview/thumbnail native logic
│   ├── ios/                      # Flutter iOS Runner（參考實作）
│   │   └── Runner/
│   │       └── AppDelegate.swift  # MethodChannel handler 參考
│   └── ...
│
├── docs/
│   └── logs/                     # Unified Task Log 存放處
│       └── YYYY-MM-DD/
│           └── Task_*.md         # 單一任務日誌
│
├── icon.png / icon.svg           # 應用程式圖示
└── PhotoSelector.zip             # (打包產物，暫存)
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

### Flutter 版 — AppState 核心方法

| 方法 | 檔案位置 | 功能 |
|------|----------|------|
| `loadFolder()` | `lib/providers/app_state.dart` | 掃描資料夾、分組、排序、讀取 JSON 狀態 |
| `selectItem()` | `lib/providers/app_state.dart` | 選中照片、更新 _last_viewed_id |
| `markCurrent()` | `lib/providers/app_state.dart` | Toggle 狀態（starred/trashed）|
| `processStarred()` | `lib/providers/app_state.dart` | 複製/移動星號照片到目標資料夾 |
| `deleteTrashed()` | `lib/providers/app_state.dart` | 刪除標記為 trashed 的照片 |
| `_preloadImages()` | `lib/providers/app_state.dart` | 大圖滑動視窗預載（±3~5）|
| `preloadThumbnails()` | `lib/providers/app_state.dart` | 縮圖滑動視窗預載（±20，100ms debounce）|
| `getThumbnail()` | `lib/services/native_thumbnail_service.dart` | MethodChannel 縮圖提取 |

## 重要路徑約定

| 約定 | 路徑/值 |
|------|---------|
| 照片支援副檔名 | `.jpg`, `.jpeg`, `.arw`, `.rw2`, `.dng`, `.heic`, `.png` |
| JSON 狀態檔 | `{folder}/.photo_selector_status.json` |
| 側邊欄縮圖 targetSize | `200`（px）|
| 主圖 targetSize | `10000`（px，高解析/全尺寸預覽）|
| 側邊欄寬度範圍 | 180px – 600px（預設 270px）|
| Flutter macOS Runner | `photo_selector_flutter/macos/Runner/` |
| SwiftUI 版本 | 已於 Task 7 退役，不再維護 `Sources/PhotoSelector/` |
