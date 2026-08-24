---
date: 2026-08-19
title: "Halcyon — 中長期里程碑與路線圖 (Plan)"
---

## 🧭 檔案維護政策

**用途**：紀錄高階目標與各 Phase 進度，不作為即時進度看板。

**更新時機**：
- 每個 Phase 完成後。
- 重大目標或里程碑變更時。
- 每輪對話結束前同步檢查。

**必填欄位**：`date`（YYYY-MM-DD）、`title`、Phase 狀態矩陣。

**跨檔同步對象**：
- `task.md` 的 Task 狀態應與 Phase 矩陣一致。
- `memory.md` 只保留里程碑層級摘要。

---

## 專案願景

一個高效的 RAW/JPG 照片快速分類工具。主線採 Flutter app，搭配 macOS/iOS native bridge 處理平台原生能力。支援星號標記、刪除分類，並一鍵複製/移動已標記照片到指定資料夾。核心特點：

- **滑動視窗預載**：永不 OOM，永不卡頓。
- **原生縮圖支援**：macOS/iOS 直接解 RAW，不需完整解碼。
- **Flutter 主線**：UI、狀態與跨平台流程集中維護；平台能力透過 native MethodChannel 擴充。

---

## Phase 矩陣

| Phase | 名稱 | 狀態 | 主要交付物 |
|-------|------|------|-----------|
| 0 | 環境初始化與規則建立 | ✅ 已完成 | `rule.md`、7 大核心文件（本次）|
| 1 | 基礎版本可运行 | ✅ 已完成 | Flutter 基礎 UI、縮圖載入、狀態標記 |
| 2 | Flutter macOS 原生整合 | ✅ 已完成 | macOS MethodChannel 實作、語意化影像 request contract |
| 3 | 單元測試覆蓋 | ✅ 已完成 | `app_state_test.dart`、`photo_item_test.dart`、widget smoke test |
| 4 | Flutter 架構模組化 | ✅ 已完成 | AppState 拆分、影像 request contract、格式 registry |
| 5 | 生產力增強 | 🔲 進行中 | Trash MethodChannel（Task 12，自動化驗證通過）、PhotoFileActions 測試（Task 15 待辦）、CI/CD（Task 18 待辦）|
| 6 | 影像載入相容性修正 | ✅ 已完成 | JPG 主圖高解析載入、RW2 掃描支援 |
| 7 | Flutter 主線整理 | ✅ 已完成 | SwiftUI 退役、文件與任務收斂 |
| 8 | 專案結構整理 | ✅ 已完成 | `assets/`、`artifacts/`、`local_data/` 分層 |
| 9 | Android build toolchain 升級 | ✅ 已完成 | Gradle 9.1.0、AGP 9.0.1、Kotlin 2.3.21、JDK 25 build |
| 10 | 技術債清償 | 🔲 待辦 | Auto-advance 修正（Task 16）、AppDelegate 強化（Task 17）、Zoom 狀態下沉（Task 19）、sidebar 重複邏輯（Task 20）|
| 11 | 影像切換延遲與 DNG 解碼整合 | ✅ 已完成 | Tier-1/tier-2 sliding preload（Task 23）、DNG 全尺寸解碼整合（Task 22）、Finder 開啟方式冷啟動（Task 24）、回收模式（`.trash`）批次刪除（Task 25）、唯讀資料夾 status line 警告（Task 21）、sidebar itemBuilder 驅動預載（Task 26）|
| 12 | 全庫技術債清償（4-reviewer 掃描 → 30 項修繕） | ✅ 已完成（2026-08-25） | 行為缺陷 A1-A8、UI isolate 卸載 B1-B2、去重/命名 C1-C13、結構重構 D1（TierTwoRegistry）/D2（RenameCoordinator）/D3（view 拆分）/D4（HalcyonTokens 主題統一）、文件 E1-E2；計畫檔 `docs/logs/2026-08-24/Task_refactor_plan_{main,D1}.md`；交接 `docs/logs/2026-08-25/refactor-campaign-handover.md`。殘留：M5-DW6 flaky 調查（待裁決） |

---

## Phase 0 — 環境初始化 ✅ 已完成

**時間**：2026-04-29

**交付物**：
- `rule.md`：開發標準作業程序與 Unified Task Log 規範
- `memory.md`：全域知識庫與 Gotchas
- `task.md`：任務狀態看板（含 ACTIVE 區塊）
- `handover.md`：短期交接摘要
- `plan.md`：本檔
- `file_index.md`：專案檔案地圖
- `unit_test.md`：測試策略與成功標準
- `README.md`：專案入口文件

**關鍵決策**：
- 採用 Unified Task Log（日誌置於 `docs/logs/YYYY-MM-DD/`）
- 核心文件皆以 YAML frontmatter + `## 🧭 檔案維護政策` 開頭

---

## Phase 1 — 基礎版本可运行 ✅ 已完成

**時間**：2026-04-29 前

**交付物**：
- 專案根目錄：Flutter 跨平台版本（含 AppState、MainScreen、SidebarView、MainDetailView、SettingsDialog）
- 支援副檔名：JPG, JPEG, ARW, DNG, HEIC, PNG
- 鍵盤快捷鍵：← →（導航）、↑ ↓（縮放）、S（星號）、X（刪除）
- 側邊欄可拖曳調整（180px–600px）
- macOS Day/Night Theme 完整對應

**驗證結果**：
- Flutter 版本可執行（macOS 原生 MethodChannel 已可編譯，待實機照片資料夾視覺驗證）

---

## Phase 2 — Flutter macOS 原生整合 ✅ 已完成

**目標**：在 Flutter macOS Runner 中實作原生縮圖提取 MethodChannel handler，解除縮圖依賴，並修正主圖/縮圖尺寸契約。

**主要交付物**：
- `macos/Runner/AppDelegate.swift`：含 `FlutterMethodChannel` handler
- `NativeThumbnailService` 在 macOS 上完整可用
- JPG 主圖請求回傳高解析/全尺寸輸出，sidebar 請求維持 200px 縮圖
- Flutter 支援 `.rw2` RAW 掃描

**子任務**（詳見 `task.md` Task 1）：
1. 建立 `macos/Runner/AppDelegate.swift` handler
2. 參考 `ios/Runner/AppDelegate.swift` 既有實作
3. 驗證 `flutter run -d macos` 縮圖正常
4. Task 6：修正 JPG 主圖高解析載入與 RW2 支援

**Task 6 驗證結果**：
- `flutter analyze`：0 issues
- `flutter test`：通過 1 個 widget smoke test
- `flutter build macos`：成功產出 release app
- 待使用者以真實 JPG/RW2 資料夾做視覺覆核

**完成結果**：Task 1 / Task 8 已完成；macOS bridge 以 `purpose` 分流 preview 與 sidebar thumbnail；`flutter analyze` / `flutter test` / `flutter build macos` 通過。

---

## Phase 3 — 單元測試覆蓋 ✅ 已完成

**目標**：建立有意義的自動化測試，確保核心邏輯不被破壞。

**主要交付物**：
- `test/app_state_test.dart`：AppState 單元測試（5+ 案例）
- `test/photo_item_test.dart`：PhotoItem 邏輯測試
- 更新 `test/widget_test.dart`：有意義的 smoke test
- `unit_test.md` 測試矩陣完整

**測試覆蓋目標**：

| 模組 | 覆蓋類型 | 目標案例數 |
|------|----------|-----------|
| AppState | 單元測試 | 5 |
| PhotoItem | 單元測試 | 3 |
| MainScreen | Widget Test | 2 |

**完成結果**：`flutter test` 11 個測試通過（exit code = 0）。

---

## Phase 4 — Flutter 架構模組化 ✅ 已完成

**目標**：降低 Flutter 主線維護成本，將影像載入、檔案掃描、狀態持久化與檔案操作拆成可測服務。

**主要交付物**：
- `ImageRequestPurpose` 或等價 request contract：區分 sidebar thumbnail 與 preview/full-size image
- `PhotoLibraryScanner`：集中掃描與分組邏輯
- `PhotoStatusStore`：集中 JSON 狀態讀寫
- `ImagePreloadController`：集中主圖/縮圖 cache 與 sliding window
- `PhotoFileActions`：集中 copy/move/trash 檔案操作
- `SupportedPhotoFormats` registry：集中副檔名與優先順序

**拆分檢查清單**：
- [x] Native image request contract 不再只靠 `targetSize` 判斷用途
- [x] `AppState` 不直接負責資料夾掃描細節
- [x] `AppState` 不直接負責 JSON 讀寫細節
- [x] `AppState` 不直接負責檔案 copy/move/delete 細節
- [x] 檔案格式新增時只需更新 registry 與測試

---

## Phase 7 — Flutter 主線整理 ✅ 已完成

**目標**：退役未被主線引用的 SwiftUI package，移除雙軌同步成本，將後續開發集中在 Flutter app + native bridge。

**主要交付物**：
- 移除 `Sources/PhotoSelector/`
- 移除根目錄 `Package.swift`
- 核心文件、README、測試矩陣移除 SwiftUI 主線待辦
- 新增架構改善任務：Task 8~12

**決策依據**：
- SwiftUI 版本功能落後 Flutter，缺少持久化、設定與行為對齊。
- Flutter macOS native bridge 已可編譯，主線已能承接原生縮圖/預覽能力。
- 雙軌維護會持續造成支援格式、測試矩陣、文件與功能狀態不同步。

**驗證結果**：
- `flutter analyze`：0 issues
- `flutter test`：通過 1 個 widget smoke test
- `flutter build macos`：成功產出 release app

---

## Phase 5 — 生產力增強 🔲 進行中

**目標**：消除資料安全風險、強化測試防護、建立 CI/CD 自動化。

**交付物**：

| Task | 說明 | 優先級 | 狀態 |
|------|------|--------|------|
| Task 12 | Trash MethodChannel（`deleteTrashed()` 改為 macOS Trash）| 🔴 緊急 | ✅ 自動化驗證通過（`flutter analyze`/`flutter build macos` 與實機 Trash 覆核仍待使用者補做，見 `memory.md` TD-004）|
| Task 15 | `PhotoFileActions` copy/move/delete 單元測試補強 | 🔴 高 | 🔲 待辦 |
| Task 18 | CI/CD GitHub Actions（`flutter analyze` + `flutter test` + `flutter build macos`）| 🟡 中 | 🔲 待辦 |
| — | 統一建置入口 `scripts/build.sh` | ✅ 已完成 | 支援 macOS / Android / Web / all |
| — | CLI 工具 `scripts/batch_tag.dart` | 🟢 低 | 🔲 待辦（後排）|

**驗收標準**：
- Task 12 完成後，照片刪除流程不再永久移除檔案
- Task 15 完成後，`flutter test` 測試數 ≥ 16，覆蓋 copy/move/trash 三條路徑
- Task 18 完成後，每次 push 到 main 自動執行完整驗證

---

## Phase 8 — 專案結構整理 ✅ 已完成

**目標**：整理根目錄與正式程式碼位置，讓開發入口、應用程式、本機資料、封存產物與文件各自有清楚責任。

**完成結果**：
- Flutter 主線移至專案根目錄
- 專案層級圖示移至 `assets/icons/`
- 本機照片樣本移至 `local_data/photo_samples/` 並由 `.gitignore` 排除
- 封存 zip 與退役 build cache 移至 `artifacts/` 並由 `.gitignore` 排除
- 核心 SOP 文件維持在根目錄，避免破壞 Startup Protocol

**驗證結果**：
- `flutter test`：11 tests passed
- `flutter analyze`：0 issues
- `flutter build macos`：成功

---

## Phase 9 — Android build toolchain 升級 ✅ 已完成

**目標**：讓 Android build 可使用 Temurin JDK 25，並維持 Flutter 3.35.1 專案可編譯。

**完成結果**：
- Gradle wrapper 升級至 9.1.0
- Android Gradle Plugin 升級至 9.0.1
- Kotlin Gradle Plugin 升級至 2.3.21
- Android app 指定 NDK 28.2.13676358
- 新增 `android/app/proguard-rules.pro`
- `scripts/build.sh` 在 macOS 上優先使用 Temurin JDK 25，找不到時退回 JDK 21 / 17

**相容性說明**：Flutter 3.35.1 的 Gradle plugin 尚未相容 AGP 9 new DSL / built-in Kotlin，因此目前使用 `android.newDsl=false`、`android.builtInKotlin=false` 相容模式。

**驗證結果**：
- `./scripts/build.sh android`：成功，產出 `build/app/outputs/flutter-apk/app-release.apk`
- `flutter test`：11 tests passed

---

## Phase 10 — 技術債清償 🔲 待辦

**目標**：消除技術債評估（2026-05-04）識別出的中低優先架構問題，降低未來維護成本。

**觸發條件**：Phase 5 主要任務（Task 12、Task 15）完成後開始。

**交付物**：

| Task | 說明 | 來源 | 優先級 |
|------|------|------|--------|
| Task 16 | G-005 Auto-advance Toggle off——行為已確認正確（`app_state.dart:337-351`），僅缺 regression test | G-005 | 🟢 低（降級，原判斷有誤）|
| Task 17 | macOS `AppDelegate.swift` CIContext/CIFilter 錯誤處理強化 | TD-012 | 🟡 中 |
| Task 19 | Zoom 狀態下沉至 View 層，消除反向資料流（G-010、TD-011）| G-010 / TD-011 | 🟡 中 |
| Task 20 | `sidebar_view.dart` iconColor 重複邏輯提取（Quick Win）| TD-014 | 🟢 低 |
| — | AGP 9 new DSL 遷移（`android.newDsl=false` 移除）| TD-009 | 🟢 低（等 Flutter 升級）|

**驗收標準**：
- Task 16 完成後，`test/app_state_test.dart` 新增 TC-014 regression test 並通過（行為本身已確認正確，不需再修邏輯）
- Task 17 完成後，native 端對無效輸入回傳 `FlutterError`，不 crash
- Task 19 完成後，`AppState` 不持有任何 zoom/animation 欄位；`main_detail_view.dart` 無反向 setter
- Task 20 完成後，`sidebar_view.dart` iconColor 邏輯只定義一次，色值一致

---

## Phase 11 — 影像切換延遲與 DNG 解碼整合 ✅ 已完成

**目標**：降低圖片切換延遲、補上 DNG 無內嵌預覽時的全尺寸解碼路徑，並收斂本輪新增的資料操作與可靠性功能。

**主要交付物**（詳見 `task.md` 對應 Task）：
- Task 21：唯讀資料夾警告 + StatusLine（commit `123727b`）
- Task 22：DNG 全尺寸解碼整合（`flutter_dng_decoder`，commit `bcc096b` 等）
- Task 23：影像切換延遲 tier-1/tier-2 sliding preload（commit `de7cf5b` 等）
- Task 24：Finder「開啟方式」冷啟動（commit `aefad64`）
- Task 25：回收模式（`.trash`）批次刪除（commit `9520ab4`～`307afec`）
- Task 26：Sidebar 縮圖預載改為 itemBuilder 驅動（commit `d0eb855`）

**驗證結果**：`flutter test` 85 個測試通過（exit code 0，2026-08-19）；`flutter analyze lib test` 0 issues。`flutter build macos` 本階段未重跑。

---

## 路線圖總覽

```
Phase 0 ✅ ─────────────────────────────────────── 2026-04-29
  └── Phase 1 ✅
        └── Phase 2 ✅
              └── Phase 7 ✅
                    └── Phase 3 ✅
                          └── Phase 4 ✅
                                └── Phase 8 ✅
                                      └── Phase 9 ✅ Android toolchain
                                            └── Phase 11 ✅ 影像切換延遲與 DNG 解碼整合
                                                  └── Phase 5 🔲 ←───── 當前焦點
                                                        └── Phase 10 🔲 技術債清償
```

---

## 成功標準

| 標準 | 描述 |
|------|------|
| 功能完整性 | 所有 Phase 交付物完成並驗證 |
| 測試覆蓋 | Phase 3 完成後，`flutter test` 至少 5 個案例通過 |
| 架構可維護性 | Phase 4 完成後，AppState 職責拆分且核心服務可測 |
| 效能目標 | 滑動視窗記憶體峰值 < 500MB（含 8K 原圖）|
