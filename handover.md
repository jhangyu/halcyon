---
date: 2026-08-26
title: "Halcyon — 短期交接摘要 (Handover)"
---

## 🧭 檔案維護政策

**用途**：記錄當前衝刺最重要的中斷點、已完成項目、下一步。作為 AI 快速恢復上下文的第一入口。

**更新時機**：
- 每次 Task 階段結束或主動中斷對話前。
- 完成任何 `下一步` 中的子步驟後同步更新。

**必填欄位**：`date`（YYYY-MM-DD）、`title`、`下一步`（僅保留 3-5 個可立即執行項）。

**跨檔同步對象**：
- `task.md` 的 ACTIVE 區塊須與 `下一步` 一致。
- Bug 結案後長期知識移入 `memory.md`。

---

## 當前任務

**本輪（2026-08-26）｜結構落塵清理**

AD-030 的 structure refactor 只動了 `lib/`／`test/`；本輪清掉輔助檔案的落網之魚。稽核 `docs/logs/2026-08-26/structure-audit2-{dart,docs,infra}.md`，契約 `docs/logs/2026-08-26/cleanup-convergence-contract.md`（18 條驗收條件＋四項偏差裁決），決策全文 `memory.md` AD-031。

已落地：
- `scripts/tmp/` 42 個追蹤檔全數移除。其中 9 個 Swift 探針／突變腳本與 6 個合成 DNG 素材的受測目標 `macos/Runner/DngPreviewExtractor.swift` 已於 2026-08-24 隨 DNG 解碼轉純 Dart 而刪除，1 個腳本驗證的 `AppDelegate.swift` `EXPORT-CORE` 區塊亦不存在——是無法編譯的死檔，不是可重用的暫存。`.gitignore` 早已宣告該目錄，此後宣告與現實一致。
- `assets/icons/` 整個子目錄刪除（`icon.png` 與 `assets/icon.png` 位元組相同，`icon.svg` 是內容不同的舊版）；保留 `assets/icon.svg` 為唯一向量母檔。**AD-006 寫的「圖示放在 `assets/icons/`」自此失效。**
- 文件：陳舊的 `docs/flutter_app_README.md`（引用早已刪除的舊建置腳本、同步路徑指向不存在的目錄）與落單的 `.txt` 日誌刪除；新增 `docs/logs/INDEX.md`，覆蓋全部 120 個歷史日誌，每檔一行用途取自各檔檔頭。
- 測試：8 個帶里程碑代號（m0/f3/m3/m3_amend3/m4/m5/m6/m1）的檔名改為描述受測主題；`test/widget_test.dart`（範本預設檔名）唯一案例併入 `test/main_test.dart`。
- 建置與分析入口：CI 的 macOS 建置改呼叫 `python3 scripts/build_apps.py`（原先直接 `flutter build` 會靜默跳過強制色彩閘）；`analysis_options.yaml` 排除範圍由 `scripts/**` 收窄為 `scripts/tmp/**`，讓仍在服役的 `gen_windows_associations.dart` 重回靜態分析涵蓋（產出 `.reg` 位元組不變）；`windows/runner/halcyon_associations.reg` 脫離追蹤並加入忽略清單。
- 保留（使用者裁決）：`scripts/check_dng_ffi_artifacts.py` 是 M7 的手動驗收關卡，檢查相鄰 `../ceyx/` 各平台動態庫是否匯出 `dng_decode_and_process_sized`——相鄰套件改名／重建時唯一會示警的機制，已在檔頭補上定位說明。
- 驗證：`flutter analyze` `No issues found!` RC=0；`flutter test -j 1` `+356: All tests passed!` RC=0（artifact 內自捕），`[E]` 標記 0。**磁碟上 45 個測試檔在 log 中全數出現，零靜默跳過**；測試數與清理前一致（`widget_test.dart` 移除 1 案例、`main_test.dart` 增加 1 案例，淨零）。

**下一步**：
1. M5-DW6 flaky 調查（同 HEAD 一紅一綠；斷言「全尺寸升級零增量」可能掩蓋真實快取記帳競態）——待使用者裁決。
2. parking-lot 逐項裁決（見 `docs/logs/2026-08-25/refactor-campaign-handover.md` §8）。

---

**上一輪（2026-08-25）｜全庫技術債清償（30 項，HEAD `5c48c68`）**

已落地（計畫：`docs/logs/2026-08-24/Task_refactor_plan_main.md` + `Task_refactor_plan_D1.md`；完整交接：`docs/logs/2026-08-25/refactor-campaign-handover.md`）：
- 行為缺陷 8 項：批次複製/搬移/刪除逐檔容錯並回報失敗、狀態檔原子寫入＋單槽寫入鏈、損壞 JSON 降級不崩潰、rename undo journal 容錯＋逐批 flush、`currentItem` 失配回 null 不再默選第一張、掃描失敗顯示狀態列。
- 效能 2 項：縮圖匯出與側欄 JPEG 重編碼移入 `Isolate.run`。
- 去重/清理 13 項：sidecar 路徑、EXIF 方向表、JSON 讀取、視窗夾取、typedef、選單常數、快取上限常數各一處定義；PhotoPayloadCache 如實改稱視窗內 FIFO；死碼清除。
- 結構 4 項：`TierTwoRegistry`（tier-2 記帳可單測，變異證明紅→綠）、`RenameCoordinator`、`AppState.displayProvider` + rename_dialog 拆四個子 widget、`HalcyonTokens` ThemeExtension 統一色彩（含新增 `starred`；使用者已外觀驗收）。
- 文件 2 項：CLAUDE.md 原生橋接段改寫為純 Dart 管線事實、main.dart 過時註解修正。
- 驗證：全套件 352 綠、analyze 0（gate artifact `scripts/tmp/final-gate.txt` @ `5c4a9c9`）。TC-230 掛死根因＝testWidgets fake-async zone 內真實 dart:io await，已修（單變數 A/B 證明）。

**下一步**：
1. M5-DW6 flaky 調查（同 HEAD 一紅一綠；斷言「全尺寸升級零增量」可能掩蓋真實快取記帳競態）——待使用者裁決。
2. parking-lot 逐項裁決（見交接檔 §8）。

---

**上一輪（2026-08-20）｜EXIF 重新命名（批次、可 undo，commit `58fe681`，Task 10 文件收尾）**

已落地（`docs/superpowers/plans/2026-08-19-exif-rename.md` Task 1-9）：
- 批次從 EXIF metadata 重新命名資料夾內所有照片：`RenameRule`（純函式模板渲染，含 4 個 preset 與自訂規則）+ `planRenames`（無碰撞規劃，RAW/JPG/sidecar 同群組同新名，碰撞附加 `-1`/`-2`）+ `applyRenames`/`undoLastRename`（`.halcyon_rename_log.jsonl` append-only undo journal，避免 10,000 筆時 O(n²) 重寫陣列）。
- macOS `halcyon/exif` MethodChannel：header-only、`DispatchQueue.concurrentPerform` 平行讀取 EXIF；非 macOS 平台落回 Dart `exif` package（單檔跑在獨立 isolate）。
- `AppState.renameByExif`/`undoRename`：重新命名後透過 `PhotoStatusStore.remapKeys` 把星號、垃圾桶標記與 last-viewed 指標一併轉移到新檔名；自訂規則存進 `.halcyon_status.json` 的 `_rename_rule`（已納入 `reservedKeys`），下次開對話框會預先帶入。
- `lib/views/rename_dialog.dart`：兩窗格對話框（preset/自訂規則/變數 chip 左欄，5 筆隨機樣本即時預覽右欄），從側邊欄選單「Rename by EXIF...」開啟。
- `lib/views/status_line.dart`：重新命名進行中顯示「取消」，完成後顯示「還原」。
- 33 個新測試（TC-024~TC-056），分散在 8 個測試檔，詳見 `unit_test.md` 測試案例矩陣與 `task.md` Task 27。

**待使用者手動驗收（未執行、非本輪代理可做）**：本專案禁止 agent-driven UI 驗證（模擬點擊/osascript/截圖），plan Task 6 Step 4 / Task 8 Step 6 要求的 `flutter run -d macos` 實機操作未執行。請開一個含 JPG+RAW sibling 的真實資料夾，執行：重新命名整批（確認 preview 顯示真實 camera/lens/日期值）→ 確認 RAW+JPG 對得到同一新檔名 → 確認已加星的照片在新檔名下仍是星號 → 點「還原」確認檔名與星號都回復 → 重開對話框確認上次用過的自訂規則被記住。

**刻意排除範圍（out of scope，非遺漏）**：Windows/Android/Linux 原生 EXIF 讀取（僅有 Dart `exif` package fallback，未做原生 handler）；重新命名資料夾內的子集（一律全資料夾）；把檔案搬到別的資料夾（只在原地重新命名）；任何超出 `docs/mockups/exif-rename/variant-2-twopane.html` 的 UI 改版。

**其他已知限制**：`{direction}`（GPS image direction）沒有含 GPS 資料的樣本照片可驗證，端到端未曾實測；`AppState.cancelRename()`/`isRenaming` 與 `readMetadataFor` 的 >500 筆 chunking 在 AppState 層無直接測試（service 層由 TC-040、TC-047 覆蓋）。文件更正（計畫文件寫錯的兩個 gotcha 引註編號、實際 toolchain 版本與 `RadioGroup` 寫法）已記入 `memory.md` G-012~G-014。

---

**上一輪（2026-08-19）｜Sidebar 縮圖預載改為 itemBuilder 驅動（commit `d0eb855`）**

已落地：
- `SidebarView` 移除 `ScrollController` scroll listener，改由 `ListView.builder` 的 `itemBuilder` 逐格回報建置到的 index，一幀結束後彙整成「純可視範圍」呼叫 `AppState.preloadThumbnails()`。修正的 bug：回收/刪除/複製/移動觸發 `loadFolder()` 重載資料夾、清空縮圖快取後，捲動離開頂端的清單只靠 scroll listener 觸發重新請求，結果持續空白直到使用者再次捲動。
- `ImagePreloadController` 接手 prefetch margin（新常數 `thumbnailPrefetchMargin = 20`），請求順序改為「可視列優先 → 視窗邊緣向外交錯」；新增 `_thumbBatchGeneration` 計數器，過期批次（快速捲動、資料夾重載）在下一次 await 前自我中止。
- `sidebar_view.dart` 選取列背景改用 `ListTile.selectedTileColor`，外層容器由 `Container` 改為 `Material`，消除 framework 的 ListTile 背景色/ink splash 斷言警告。
- `flutter test`：85 個測試通過（exit code 0），新增 `test/sidebar_view_test.dart` 的「every visible row is requested again after a folder reload」迴歸測試；`flutter analyze lib test`：0 issues。

**上一輪（2026-08-19）｜唯讀資料夾警告 + StatusLine（commit `123727b`）**：`PhotoStatusStore.isWritable(Directory)` 探測可寫性、`AppState` 新增 `StatusMessage`/`showStatus()`、`lib/views/status_line.dart` 取代 SnackBar、批次刪除成功訊息改走 status line、補上先前未 commit 的 `lib/services/trash_service.dart`。

**文件債狀態**：`task.md` / `plan.md` 在本輪已補回 2026-05-05 至今主線完成的回收模式（`.trash` 批次刪除，Task 25）、DNG 全尺寸解碼整合（Task 22）、影像切換延遲 tier-1/tier-2 sliding preload（Task 23）、Finder「開啟方式」冷啟動（Task 24），逐條登錄並附 commit hash 證據，文件債已清償。

---

## 已完成項目

- **Flutter 專案初始化**：完整的 `main_screen.dart` + `sidebar_view.dart` + `main_detail_view.dart` + `settings_dialog.dart`
- **AppState 核心邏輯**：`loadFolder`、`selectItem`、`markCurrent`、`processStarred`、`deleteTrashed`、雙層 LRU Cache（圖片 + 縮圖）
- **NativeThumbnailService MethodChannel 定義**：`lib/services/native_thumbnail_service.dart`（Flutter 端）
- **滑動視窗預載策略**：大圖 ±3~5，縮圖 ±20，100ms debounce
- **SwiftUI 版本基礎實作**：曾作為早期原型存在；Task 7 起退役，不再作為待辦主線
- **Phase 0 完成**：所有核心文件補建完成（rule.md, memory.md, task.md, handover.md, plan.md, file_index.md, unit_test.md, README.md）
- **Task 6 完成**：Flutter/SwiftUI `.rw2` 掃描支援、macOS JPG 主圖高解析載入分流、Swift build error 修正、widget smoke test 修正；`flutter analyze` / `flutter test` / `flutter build macos` 皆通過。
- **Task 7 完成**：刪除 `Sources/PhotoSelector/` 與根目錄 `Package.swift`；文件改為 Flutter 主線；Task 8~12 已登錄；`flutter analyze` / `flutter test` / `flutter build macos` 皆通過。
- **Phase 2/3/4 完成**：Task 1 / 3 / 8 / 9 / 10 / 11 已完成；新增 `SupportedPhotoFormats`、`PhotoLibraryScanner`、`PhotoStatusStore`、`ImagePreloadController`、`PhotoFileActions`；`flutter analyze` / `flutter test`（11 tests）/ `flutter build macos` 皆通過。
- **Task 13 完成**：專案結構整理完成；Flutter app 整併至專案根目錄，圖示移至 `assets/icons/`，本機資料與封存產物分別移至 `local_data/`、`artifacts/` 並維持 git ignored。
- **Task 14 完成**：Android toolchain 升級完成；Gradle 9.1.0 + AGP 9.0.1 + Kotlin 2.3.21 相容模式可在 Temurin JDK 25 下成功產出 `build/app/outputs/flutter-apk/app-release.apk`。
- **Task 12 完成（自動化驗證通過）**：新增 `lib/services/trash_service.dart`、macOS `halcyon/trash` MethodChannel handler，`PhotoFileActions.deleteTrashed()` 已改用 Trash service；新增 `test/photo_file_actions_test.dart` 覆蓋 trash 成功與失敗保留原檔。
- **Task 22 完成**：DNG 全尺寸解碼整合（`dng_processor` package，`lib/services/dng_decode_contract.dart` / `dng_decode_service.dart` / `decoded_rgba_image_provider.dart`）。
- **Task 23 完成**：影像切換延遲 tier-1/tier-2 sliding preload（`lib/services/image_preload_controller.dart`，22 個測試覆蓋）。
- **Task 24 完成**：Finder「開啟方式」冷啟動（`lib/services/open_with_channel.dart`，macOS 已實作，Windows/Android 未實作）。
- **Task 25 完成**：回收模式（`.trash`）批次刪除（`PhotoFileActions.recycleTrashed()`，同名 sibling 自動分組、碰撞附加後綴、失敗清單回報）。
- **Task 26 完成**：Sidebar 縮圖預載改由 `itemBuilder` 驅動，取代 scroll listener（詳見本檔「當前任務」）。
- **Task 27 完成**：EXIF 重新命名（批次、可 undo）——`RenameRule`/`planRenames`/`applyRenames`/`undoLastRename`、macOS `halcyon/exif` channel、`AppState.renameByExif`/`undoRename`、兩窗格對話框、status line undo/cancel，33 個新測試（TC-024~TC-056）。使用者手動驗收未執行，見本檔「當前任務」。

---

## 下一步

**現行待辦請以本檔最上方「當前任務」節（2026-08-25 全庫技術債清償）為準**：M5-DW6 flaky 調查（待使用者裁決）、parking-lot 逐項裁決（見 `docs/logs/2026-08-25/refactor-campaign-handover.md` §8）。以下為 2026-08-24 M6 收尾輪遺留清單，供歷史脈絡參考，未逐項核實是否已被後續輪次處理：

**M6 R2 收尾（2026-08-24，tree @ `8418c7e`）**：M6 全契約（C-1…C-8）完成——P4 OS 整合五項＋P5 收尾三項落地，套件 280/280、雙平台 release 建置綠、G″″ 回歸 gate 33/33 PASS。與 ACTIVE 一致的待辦：(a) 使用者關閉 P5.3 票；(b) P-2（Linux FFI `.so`）仍開放；(c) Windows 端 `.reg` 匯入與 `explorer /select,` 為 trust-on-first-use，建議首次真機驗證；(d) 手機端 Open With 僅接線，端到端流程 parked 於 F-02（資料夾掃描）。第 4 點「重跑整套測試」已由本輪 P5.3 完成（280/280，`scripts/tmp/m6-r2-verify/p5-3-verify.txt`）。

**已確認完成、原列於此處的舊項目**：Task 12（Trash MethodChannel，`flutter test` 已通過含 trash 案例）、Task 15（`test/photo_file_actions_test.dart` 已存在於 `git ls-files`）、Task 19（Zoom 狀態下沉，已驗收關閉）。以下為本次同步時仍待辦或需人工核實的項目：

1. **EXIF 重新命名使用者手動驗收**（高，見本檔「當前任務」）：`flutter run -d macos` 對真實資料夾操作，本專案禁止代理執行，只能由使用者完成。
2. **Task 20 — sidebar iconColor Quick Win**（低）：`sidebar_view.dart` iconColor 重複邏輯是否已在後續回收模式改動中處理，需重新核實現狀再排入。
3. **G-005（Auto-advance Toggle off 行為）**：行為已核實正確（`app_state.dart:337-351`），不需使用者確認；`test/app_state_test.dart` 仍缺對應 regression test（`unit_test.md` TC-014）。
4. **重跑 `flutter test`/`flutter analyze` 確認 EXIF 重新命名整套仍綠**：本輪文件同步 worker 無執行環境，各測試檔案的 TC 數量已用 `grep -c` 核對，但未實際執行整套測試。

---

## 決策摘要

| 編號 | 決策內容 | 依據 |
|------|----------|------|
| AD-001 | 滑動視窗預載策略（±3~5 大圖，±20 縮圖）| 記憶體 / 速度平衡 |
| AD-002 | 優先載入 JPG/HEIC，RAW 降級 | 效能考量 |
| AD-003 | Flutter 主線 + Native Bridge，SwiftUI 退役 | 降低雙軌同步成本 |
| AD-004 | JSON 格式狀態持久化（`.halcyon_status.json`）| 簡單遷移、無需資料庫 |
| AD-005 | AppState 協調層化 | 核心流程可測、降低維護成本 |
| AD-006 | 專案根目錄分層 | 正式程式碼、本機資料、封存產物分離 |
| AD-007 | Android JDK 25 toolchain | Gradle 9.1.0 + AGP 9.0.1 相容模式可支援 Temurin JDK 25 |
| AD-008 | Trash 操作透過 macOS `halcyon/trash` MethodChannel | 避免不可逆刪除 |
| AD-009 | StatusLine 取代 SnackBar；`isWritable()` 以 create+delete 探測可寫性 | SnackBar 淡出時間不可調；exFAT 權限位不可信 |
| AD-010 | DNG 全尺寸解碼整合 `dng_processor` package | 無內嵌預覽的 DNG 需要真正 RAW 解碼，而非降級縮圖 |
| AD-011 | 影像切換 tier-1/tier-2 sliding preload | 單層預載不足以兼顧不卡頓與記憶體安全 |
| AD-012 | Finder 開啟方式走 push-only MethodChannel | 冷啟動時 Dart 詢問原生端會輸掉與 engine 初始化的競速 |
| AD-013 | 回收模式（`.trash`）sibling 分組、碰撞附加後綴 | 同 volume rename 瞬時可用；批次失敗需個別回報不中斷整批 |
| AD-014 | Sidebar 縮圖預載改由 `itemBuilder` 驅動，取代 scroll listener | `ListView.builder` 重建即免費重算可視範圍，資料夾重載後自我修復 |
| AD-016 | EXIF 重新命名：命名策略純函式化，只有 `applyRenames` 碰檔案系統，序列執行 | 整條命名邏輯可不落地照片單元測試；rename 是同 volume metadata 操作，平行化沒有效益反而製造 race |
| AD-017 | EXIF 每個項目只讀一次，來源為 JPG sibling | 避免對同一次拍攝的 RAW+JPG 重複解析 EXIF |

---

## 待確認事項

- ~~**G-005（Auto-advance Toggle 行為）**~~ — ✅ 已於 2026-08-19 對照 `app_state.dart:337-351` 核實：toggle off 已不前進，不需使用者確認。剩餘缺口是測試覆蓋，見 `task.md` Task 16、`unit_test.md` TC-014。
- ~~**Task 15 測試策略**~~ — ✅ 已由既成事實回答：`test/photo_file_actions_test.dart` 全檔皆用 `dart:io` 操作真實 temp 目錄（`Directory.systemTemp.createTemp()`），未使用抽象 FileSystem 介面，且此模式已延續到後續所有資料操作測試（回收模式、trash）。視為既定方向，不再是開放問題。
- **Task 19 鍵盤縮放銜接**：`main_screen.dart:99,102` 目前呼叫 `state.stepZoomIn()` / `state.stepZoomOut()`（定義於 `app_state.dart:298-334`），zoom 邏輯移出 AppState 後需要新的觸發路徑（callback / GlobalKey）。**這是產品/架構決策，不是可從樹上驗證的事實**——實作前需確認偏好方式。
- **Task 20 色值統一**：`sidebar_view.dart:150` header title color（`32,32,32`）是否應對齊其餘 4 處的 icon/text color（`59,59,59`，見 `sidebar_view.dart:197,266-268,287-289,322-324`）？或兩者本應有差異需保留？**這是視覺設計意圖判斷，不是可從樹上驗證的事實**——留給使用者裁決。

---

## 上下文提醒

- Flutter 專案路徑：`/Users/jhangyu/project/Halcyon/`
- Android toolchain：Gradle 9.1.0、AGP 9.0.1、Kotlin 2.3.21 相容模式，JDK 優先使用 Temurin 25
- 核心狀態管理：`AppState`（Flutter 協調層；掃描、狀態、預載/cache、檔案操作已拆至服務）
- JSON 狀態檔案：`.halcyon_status.json`（放在照片目錄根目錄）
- 支援副檔名：`jpg`、`jpeg`、`arw`、`rw2`、`dng`、`heic`、`png`
- 狀態訊息一律走 `AppState.showStatus()` + `StatusLine`，不再使用 SnackBar
- 側邊欄縮圖預載觸發來源：`ListView.builder` 的 `itemBuilder`（不再是 scroll listener），prefetch margin 由 `ImagePreloadController.thumbnailPrefetchMargin` 決定
- `flutter test` 最新一次「實跑並確認」全套執行結果：352 個測試通過（exit code 0，2026-08-25，commit `5c4a9c9`，gate artifact `scripts/tmp/final-gate.txt`）；`flutter analyze`：0 issues。此為全庫技術債清償收尾的驗證錨點，取代先前 85 測試（2026-08-19，commit `d0eb855`）與 EXIF 重新命名新增 33 測試（TC-024~TC-056，commit `58fe681`）時各自回報的結果
- EXIF 重新命名 undo journal：`{folder}/.halcyon_rename_log.jsonl`（JSON Lines、append-only）；重新命名一律呼叫 `PhotoStatusStore.remapKeys` 搬移標記，否則星號/垃圾桶標記會被靜默孤立（`memory.md` G-011）
