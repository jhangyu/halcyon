---
date: 2026-05-01
title: "Halcyon Flutter — 套件說明文件"
---

## 🧭 檔案維護政策

**用途**：Flutter 套件說明文件，涵蓋 Flutter 版的功能、安裝、架構。

**更新時機**：Flutter 版重大功能變更後同步更新。

**必填欄位**：`date`（YYYY-MM-DD）、`title`。

**跨檔同步對象**：`/Users/jhangyu/Documents/Halcyon/README.md`（專案總覽）、`/Users/jhangyu/Documents/Halcyon/file_index.md`（目錄結構）。

---

# Halcyon — Flutter 跨平台版

一個 Flutter 跨平台 RAW / JPG 照片快速分類工具（macOS/iOS/Android/Web）。

## ✨ 功能

- 📁 支援 RAW（JPG+ARW+RW2+DNG+HEIC）與標準圖片自動分組
- 🔍 滑動視窗預載（記憶體永遠安全）
- ⭐ `S` 鍵星號，`X` 鍵刪除
- 📋 一鍵複製/移動星號檔案
- 🔄 Auto-advance 模式
- 🔎 `↑` / `↓` 放大縮小（最大 5x）
- 🌙 macOS Day/Night Theme

## 安裝

```bash
flutter pub get
flutter run -d macos   # macOS
flutter run -d iphone   # iOS 模擬器
flutter run -d chrome   # Web
```

## 建置

```bash
./scripts/build.sh          # 預設 macOS release
./scripts/build.sh android  # Android APK
./scripts/build.sh web      # Web release
./scripts/build.sh all      # 目前主機可支援的目標
```

`windows` 與 `linux` 需在對應作業系統上建置。
Android build 在 macOS 上會優先使用 Temurin JDK 25，找不到時退回 Homebrew `openjdk@21` / `openjdk@17`。
目前 Android toolchain 使用 Gradle 9.1.0 + Android Gradle Plugin 9.0.1 + Kotlin 2.3.21 相容模式。

建置產物集中於專案根目錄 `build/`。平台資料夾（例如 `macos/`、`android/`、`web/`）是 Flutter runner 原始碼與平台設定，不是 build output。

## 依賴

| 套件 | 版本 | 用途 |
|------|------|------|
| `provider` | ^6.1.5+1 | 狀態管理 |
| `file_selector` | ^1.1.0 | 資料夾選擇對話框 |
| `path_provider` | ^2.1.5 | 路徑工具 |
| `shared_preferences` | ^2.5.4 | 設定持久化 |

## 核心檔案

| 檔案 | 用途 |
|------|------|
| `lib/main.dart` | 入口、MaterialApp、主題設定 |
| `lib/models/photo_item.dart` | PhotoItem + PhotoStatus |
| `lib/models/supported_photo_formats.dart` | 支援格式與載入優先順序 registry |
| `lib/providers/app_state.dart` | AppState (ChangeNotifier) UI 協調層 |
| `lib/services/photo_library_scanner.dart` | 資料夾掃描與照片分組 |
| `lib/services/photo_status_store.dart` | JSON 狀態檔讀寫 |
| `lib/services/image_preload_controller.dart` | 主圖/縮圖 sliding window cache |
| `lib/services/photo_file_actions.dart` | copy/move/delete 檔案操作 |
| `lib/services/native_thumbnail_service.dart` | MethodChannel 影像載入服務 |
| `lib/views/main_screen.dart` | Scaffold + 鍵盤快捷鍵 |
| `lib/views/sidebar_view.dart` | 側邊欄列表 + 縮圖預載 |
| `lib/views/main_detail_view.dart` | 圖片檢視 + 浮動操作列 |
| `lib/views/settings_dialog.dart` | 設定對話框 |

## 鍵盤快捷鍵

| 按鍵 | 功能 |
|------|------|
| `←` / `→` | 上一張 / 下一張 |
| `↑` / `↓` | 放大 / 縮小 |
| `S` | 標記 / 取消星號 |
| `X` | 標記 / 取消刪除 |
