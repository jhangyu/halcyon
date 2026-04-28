---
date: 2026-04-29
title: "Photo Selector — 專案說明文件 (README)"
---

## 🧭 檔案維護政策

**用途**：專案整體說明文件，是外部開發者與 AI 第一眼看到的入口。需涵蓋功能、安裝、架構與快速上手。

**更新時機**：
- 新增重大功能後。
- 架構變更（如新增資料夾結構）。
- 每次 `phase` 完成後同步更新。

**必填欄位**：`date`（YYYY-MM-DD）、`title`、安裝說明、功能列表、架構概覽。

**跨檔同步對象**：`file_index.md`（目錄結構）、`plan.md`（Phase 進度）。

---

# Photo Selector

一個高效的 **RAW / JPG 照片快速分類工具**。主線採 Flutter app，並透過 macOS/iOS native bridge 取得平台原生影像能力，幫助攝影師快速瀏覽、標記星號或刪除，並一鍵複製/移動已標記照片到指定資料夾。

---

## ✨ 主要功能

| 功能 | 說明 |
|------|------|
| 📁 **資料夾瀏覽** | 支援 RAW（JPG+ARW+RW2+DNG+HEIC）與標準圖片自動分組 |
| 🔍 **滑動視窗預載** | 大圖 ±3~5 張 / 縮圖 ±20 張，記憶體永遠安全 |
| ⭐ **星號 / 刪除標記** | `S` 鍵標星號，`X` 鍵標刪除，狀態自動持久化 |
| 📋 **一鍵複製/移動** | 將所有星號檔案複製或移動到指定資料夾 |
| 🔄 **Auto-advance** | 標記後自動前進下一張，保持工作流不中斷 |
| 🔎 **縮放檢視** | `↑` / `↓` 鍵放大縮小，最大 5x 放大 |
| 🌙 **macOS Day/Night Theme** | 完全適配 macOS 亮色/深色模式 |
| 📱 **Flutter 主線** | Flutter UI + macOS/iOS MethodChannel 原生整合 |

---

## 🏗 專案架構

本專案主線為 Flutter app；平台原生能力由 Flutter Runner 中的 native bridge 提供：

```
Photo_Selector/
├── apps/
│   └── photo_selector_flutter/    # Flutter 主線版
│       ├── lib/
│       │   ├── models/            # PhotoItem 與支援格式 registry
│       │   ├── providers/         # AppState UI 協調層
│       │   ├── services/          # 掃描、狀態、預載/cache、檔案動作、MethodChannel
│       │   └── views/             # MainScreen / SidebarView / DetailView
│       ├── test/                  # Flutter 單元測試與 widget smoke test
│       └── macos/Runner/          # macOS 原生整合（MethodChannel）
├── assets/icons/                  # 專案層級圖示來源
├── docs/logs/                     # Unified Task Logs
├── artifacts/                     # 本機封存與建置暫存（git ignored）
└── local_data/                    # 本機照片樣本（git ignored）
```

---

## 🚀 安裝與執行

### Flutter 版（macOS / iOS / Android / Web）

```bash
cd apps/photo_selector_flutter

# 安裝依賴
flutter pub get

# 執行（macOS）
flutter run -d macos

# 執行（iOS 模擬器）
flutter run -d iphone

# 執行（Web）
flutter run -d chrome
```

---

## ⌨️ 鍵盤快捷鍵（Flutter 版）

| 按鍵 | 功能 |
|------|------|
| `←` / `→` | 上一張 / 下一張照片 |
| `↑` / `↓` | 放大 / 縮小（最大 5x）|
| `S` | 標記星號（再次按 S 取消標記）|
| `X` | 標記刪除（再次按 X 取消標記）|

---

## 📂 支援的檔案格式

| 副檔名 | 說明 | 縮圖策略 |
|--------|------|---------|
| `.jpg` / `.jpeg` | JPEG | 直接解碼，速度快 |
| `.heic` | HEIC/HEIF | iOS/macOS 原生支援 |
| `.arw` | Sony RAW | 原生 CGImageSource |
| `.rw2` | Panasonic RAW | 原生 CGImageSource |
| `.dng` | Adobe DNG RAW | 原生 CGImageSource |
| `.png` | PNG | 直接解碼 |

---

## ⚙️ 設定選項

| 選項 | 說明 | 狀態 |
|------|------|------|
| Auto-advance | 標記後自動前進 | ✅ |
| Overwrite existing | 複製/移動時覆蓋已有檔案 | ✅ |
| 狀態持久化 | 關閉後保留標記狀態 | ✅ |

---

## 📊 開發標準

本專案遵循 `rule.md` 定義的**開發標準作業程序 (S.O.P.)**，核心文件包括：

| 檔案 | 用途 |
|------|------|
| `rule.md` | 開發 SOP 與 Startup Protocol |
| `memory.md` | 架構決策與 Gotchas |
| `task.md` | 任務看板（ACTIVE 區塊）|
| `handover.md` | 短期交接摘要 |
| `plan.md` | Phase 里程碑進度 |
| `file_index.md` | 專案檔案地圖 |
| `unit_test.md` | 測試策略與成功標準 |

---

## 🔧 常見問題

**Q: Flutter 版在 macOS 上縮圖無法顯示？**

A: macOS 平台的 MethodChannel handler 已可編譯，仍需使用真實 RAW/JPG/RW2 資料夾做視覺驗證。若遇到顯示問題，請優先查看 `task.md` ACTIVE 區塊與對應 Task log。

**Q: 刪除的照片去了哪裡？**

A: 目前 Flutter 主線仍為**永久刪除**（`file.delete()`）。移到 macOS Trash 的 MethodChannel 已列入 Task 12 / TD-004。

**Q: 狀態標記如何保存？**

A: 放在照片資料夾根目錄的 `.photo_selector_status.json` 檔案中。JSON 格式，方便版本控制與遷移。

---

## 📄 License

本專案為個人工具專案，版權歸作者所有。
