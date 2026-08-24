# 全庫技術債清償 — Session Handover

> **建立時間**：2026-08-25 02:15（Asia/Taipei）
> **交接目的**：讓下一個 session 接續技術債清償收尾——終態是 parking-lot 逐項裁決完成、M5-DW6 flake 有結論。
> **目前判定**：主體已完成；殘留待決項見 §8
> **可信版本錨點**：branch `main`；HEAD `5c48c68`；驗證對象 `5c4a9c9`（其後兩個 commit 為 D4 refactor `7a2b190` 與純文件 `5c48c68`，D4 已由使用者外觀驗收＋sidebar 測試綠）

## 0. 接手速讀（60 秒）

- **目標**：4-reviewer 掃描出的 30 項技術債（A1-A8/B1-B2/C1-C13/D1-D4/E1-E2）全數修繕——**已完成**。
- **目前位置**：全部落地並簽收；全套件 352 綠、analyze 0。
- **下一個動作**：等使用者裁決 M5-DW6 flake 是否開工（§8 P1）；其餘 parking-lot 逐項呈報裁決。
- **最大風險／紅線**：凍結接縫未變更也不得變更——`NativeImageResult` 3 變體、tier-1/tier-2 provider 同 bytes 物件同寬高、兩個獨立 permanent-miss 集合、tier-2 串行佇列、`TierTwoRegistry.publishEncoded` 的**非同步** key 註冊順序（改成同步＝重開 BLOCKER-3）。

## 1. 接手啟動序列

1. Read `handover.md` 當前任務節 + 本檔 §8 — 剩餘工作全貌
2. Run `git log --oneline -12` — 預期看到 `5c48c68` 至 `d17d267` 的清償 commit 鏈
3. Run `flutter analyze` — 預期 `No issues found!`
4. 若接 M5-DW6：start at `test/image_preload_dual_window_m5_test.dart`（搜 `M5-DW6`），先讀 §8 P1 的既有證據
5. Verify with `flutter test -j 1`（全套件，預期 352；注意 M5-DW6 間歇紅）

## 2. 目的、現象與根因狀態

### 目的
消除四名獨立 reviewer（2×sonnet＋2×opus）掃出的資料遺失風險、靜默失敗、重複實作與結構債；D1-D4 使核心不變量從註解約束變成可單測。

### 已確認根因（本輪修掉的最大兩個）
- **批次操作靜默失敗**：`processStarred`/`deleteTrashed` 首錯中止整批且只 debugPrint——已改逐檔 try/catch＋`BatchFileOutcome` 回報（`lib/services/photo_file_actions.dart`）。
- **TC-230 測試掛死**（耗掉三棒）：testWidgets 的 fake-async zone 內直接 await 真實 dart:io（`Directory.createTemp`）→ 微任務永不排空、零 CPU 凍結；`--timeout` 也是 fake-async 計時器所以永不觸發。修法＝全部真實 I/O 包進 `tester.runAsync`＋never-completing loader 釘住空狀態（`test/main_detail_view_test.dart:29`）。單變數 A/B 證明：`scripts/tmp/tc230-ab-io-outside-runasync.log`。

### 仍待辨識
- **M5-DW6 間歇失敗**：見 §8 P1。假設 A＝測試時序 flake；假設 B＝全尺寸升級的快取記帳存在真實競態。辨識實驗：同 HEAD 連跑該檔 20 次計紅率，紅時保留完整輸出對照斷言的位元組計數。

## 3. 範圍與版本控制狀態

- In scope（已完成）：lib/services/、lib/providers/、lib/views/、macos/Runner/AppDelegate.swift、CLAUDE.md、SOP 文件
- Out of scope（刻意不碰）：測試覆蓋缺口補強（使用者明示）、TierTwoScheduler 抽取（另立票）
- Working tree：乾淨（僅 scripts/tmp/ 既有 scratch 未追蹤，屬常態）
- 關鍵 commits（結果，非標題）：
  - `d17d267`/`d8626b9`/`2b457a1` — A 組行為缺陷修繕（檔案操作/狀態存儲/rename journal）
  - `1a1a4bd`/`5053503`/`7318e75` — A7 緩衝修正、EXIF 方向單表、isolate 卸載
  - `1e7a921`/`ac64146` — 鍵空間分離、FIFO 重新命名、死碼清理
  - `ac37511` — CLAUDE.md 原生橋接段重寫＋Swift 死碼刪除
  - `bc61a84`/`f75d225`/`0dfdb49` — AppState 錯誤浮現＋分塊去巢狀
  - `315e017`/`b2e0966` — 選單常數、快取上限單一來源（`kImageCacheCeilingBytes`）
  - `81f9306` — typedef 統一為 `NativeImageLoad`
  - `e6616c1` — RenameCoordinator 抽取（既有 rename 測試零改動全綠＝行為保存證明）
  - `19747d1`/`ef7afd4`/`e9fed28`/`17aa6dc` — D1 四連 commit；`ef7afd4` 是唯一行為風險 commit，回滾點 tag `refactor/d1-base`
  - `dd32323` — D3（displayProvider、rename_dialog 拆分、theme_tokens）
  - `7a2b190` — D4（sidebar 色彩 token 化，使用者已驗收外觀）
- 背景狀態：無（team refactor-halcyon 收尾中，worktree 全清，`git worktree list` 僅主樹）

## 4. 目前邏輯架構（本階段切面）

| 節點 | 責任 | 關鍵符號 | 上游 | 下游 | 不變式／失敗語意 |
|---|---|---|---|---|---|
| `TierTwoRegistry` | tier-2 ImageCache 記帳＋readiness 合取 | `lib/services/tier_two_registry.dart` | `ImagePreloadController` | ImageCache | `isReady` 四項合取是唯一判準；`publishEncoded` key 註冊必須維持非同步（BLOCKER-3） |
| `ImagePreloadController` | 排程（視窗/debounce/串行佇列）＋tier-1 | `lib/services/image_preload_controller.dart` | `AppState` | Registry、`PhotoPayloadCache` | 排程狀態（`_tierTwoWindowIds`/`_tierTwoQueue`）刻意不入 Registry |
| `RenameCoordinator` | rename 領域（execute/undo/rule 持久化） | `lib/providers/rename_coordinator.dart` | `AppState`（薄轉發） | `RenameService`、`PhotoStatusStore` | 以 supplier callback 取 `_items` 等活狀態，不持有複本；空批次不得覆蓋前一個 undo map |
| `AppState.displayProvider` | 一次決定顯示用 provider | `lib/providers/app_state.dart:214` | views | controller 的 provider 家族 | 必須回傳與 controller 同一物件（cache-key 同一性） |
| `PhotoStatusStore` | 狀態檔讀寫 | `lib/services/photo_status_store.dart` | AppState/Coordinator | `.halcyon_status.json` | 全部寫入走 `_atomicWrite`（tmp+rename）＋單槽 `_writeChain`；讀取損壞降級為空 |
| `HalcyonTokens` | 主題色 token | `lib/views/theme_tokens.dart` | main.dart ThemeData | 各 view | 13 欄位（含 `starred`）；值搬移自舊 `_Tokens`，未創新色 |

## 5. 資料生產消費鏈（本輪新增的失敗路徑）

批次檔案操作：`AppState.processStarred` → `PhotoFileActions.processStarred`（逐檔 try/catch）→ `BatchFileOutcome{processedCount, failures}` → `AppState` 經 `showStatus`/失敗對話框呈現。失敗檔記 `"<basename>: <error>"`，批次永不中止；sidecar 失敗獨立記項。
狀態持久化：兩個計時器（`_saveStatusCache`/`_saveLastViewedId`）→ 單槽 `_writeChain` 串行 → `_atomicWrite`（同目錄 `.tmp` + rename）→ 讀端 `_readJsonMap` 損壞降級 `{}`＋單次警告。

## 6. 型別與介面契約（本輪新增/變更）

| 契約 | Producer 定義 | Consumer 假設 | 不變式 | 證據 |
|---|---|---|---|---|
| `BatchFileOutcome` | `photo_file_actions.dart` | AppState 讀 `failures` 呈現 | 批次不中止 | TC-206/207 |
| `NativeImageLoad`（唯一 typedef） | `image_source_types.dart:101` | AppState/controller/photo_source 構參 | 結構型別，簽名不變 | 全庫 grep 僅 1 定義 |
| `ExifBatchReader.onProgress` | `exif_metadata_service.dart:15` | AppState 進度顯示 | 分塊只在 reader 一層 | TC-221~225 |
| `TierTwoRegistry` 公開面 | `tier_two_registry.dart` | controller 委派 | §4 不變式 | TC-231~238＋變異證明 `scripts/tmp/d1-mutation.txt` |

## 7. 已完成事項

30/30 項全過（逐項狀態、severity、修法見兩份計畫檔的逐項覆核表）。驗證錨點：352 測試全綠＋analyze 0 @ `5c4a9c9`（`scripts/tmp/final-gate.txt`，RC=0 為 flutter test 自身退出碼）；D4 追加 sidebar 8 測試綠＋使用者外觀簽核 @ working tree（後 commit 為 `7a2b190`）。

## 8. 待解議題

| 優先 | 狀態 | 議題 | 下一動作 | 完成條件 |
|---|---|---|---|---|
| P1 | [D] | **M5-DW6 間歇失敗**：同 HEAD `5c4a9c9` 全套件紅 1 次、隔離紅 1 次綠 1 次、pre-D3 worktree 綠；兩提交點間該測試 import 鏈 diff 為空→非回歸。斷言「全尺寸升級零增量 payload cache 位元組」可能掩蓋真實記帳競態 | 使用者裁決後：同檔連跑 20 次計紅率，紅時比對位元組計數來源 | 判定 flake（修測試）或真競態（修產品碼），紅率歸零 |
| P2 | [D] | tier-1 視窗保留語意輕微放寬（Batch 1 S4 依計畫片段實作，被評為 harmless 但與「byte-identical」約束矛盾） | 使用者裁決接受或回修 | 裁決記錄入 memory.md |
| P3 | [D] | `--timeout` 是 fake-async 計時器的 gotcha 尚未入 memory.md G 條目 | 一段 G-021 寫入 | grep 可見 |
| P4 | [D] | TierTwoScheduler 後續抽取（D1 計畫 §3.3 刻意遞延）；`PhotoSource.probe()` hash 凍結測試債；podium file-ownership 協議補 commit pathspec 規則 | 各自立票 | 使用者裁決 |

## 9. 嘗試、裁決與禁止重踩

| 嘗試 | 結果 | 裁決 | 可重試？ |
|---|---|---|---|
| TC-230＝pumpAndSettle 撞 spinner | 否證（檔內無此呼叫） | 兩名調查者代碼證據一致 | 否 |
| TC-230＝編譯快取損壞 | 否證（冷快取重現＋掛死零 CPU 而編譯燒 CPU） | 同上 | 否 |
| 背景等待長跑測試 | 三棒共 5+ 次無果，root cause 靠前景 `--timeout` 診斷＋讀碼找到 | 背景執行已全域硬擋（hook＋`CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`） | 否 |
| M5-DW6 判為 D3 回歸 | 否證（兩提交點 services diff 空＋pre-D3 worktree 綠＋同 HEAD 也會綠） | flake 或既有競態 | — |

## 10. 已知限制與不確定性

- `fullResProviderFor` 的 null-vs-provider 無直接 widget 測試（D1 前即如此，未惡化）——D1 計畫 §10 記錄在案。
- `applyRenames` 的 crash 生存保證現以逐批 flush 兌現，效能影響未量測（批次小，判為可忽略）。
- UI 效能（B1/B2 的實際卡頓改善）依專案規則由使用者自量，agent 未做 UI 量測。

## 11. 驗收命令

```bash
flutter analyze                       # No issues found!
flutter test -j 1                     # 預期 352 tests, All tests passed!（M5-DW6 有間歇紅可能，見 §8 P1）
git tag -l 'refactor/*'               # refactor/d1-base（D1 回滾點）
grep -c "typedef NativeImageLoad" lib/services/image_source_types.dart   # 1
```

## 12. 參考入口

- 必讀：`docs/logs/2026-08-24/Task_refactor_plan_main.md`（30 項逐項覆核＋9 任務規格）；`Task_refactor_plan_D1.md`（D1 不變量地圖）
- Artifact：`scripts/tmp/final-gate.txt`（最終閘）、`scripts/tmp/d1-mutation.txt`（變異證明）、`scripts/tmp/tc230-ab-*.log`（TC-230 因果 A/B）、`scripts/tmp/m5dw6-*.txt`（flake 證據鏈）
- 前段交接（TC-230 三棒史）：`docs/logs/2026-08-24/Task_refactor_T9_handoff.md`
