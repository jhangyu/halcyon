---
date: 2026-04-29
title: "Photo Selector Flutter — 套件說明文件"
---

## 🧭 檔案維護政策

**用途**：Flutter 套件說明文件，涵蓋 Flutter 版的功能、安裝、架構。

**更新時機**：Flutter 版重大功能變更後同步更新。

**必填欄位**：`date`（YYYY-MM-DD）、`title`。

**跨檔同步對象**：`/Users/jhangyu/Documents/Photo_Selector/README.md`（專案總覽）、`/Users/jhangyu/Documents/Photo_Selector/file_index.md`（目錄結構）。

---

# Photo Selector — Flutter 跨平台版

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
| `lib/providers/app_state.dart` | AppState (ChangeNotifier) 核心邏輯 |
| `lib/services/native_thumbnail_service.dart` | MethodChannel 縮圖服務 |
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
