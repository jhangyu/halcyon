# 收斂契約 — Halcyon 全平台統一 Python CI scripts（凍結 2026-08-31 00:29）

## 終態（一句話）
Halcyon 的 CI 建置流程由一套全平台統一的 Python CI scripts 驅動（取代分散於 YAML 內聯步驟與零散腳本的邏輯），所有平台 CI 全綠並 merge 回 main。

## In-scope 交付物
1. `docs/logs/2026-08-31/Spec_ci_rewrite.md` — 需求確認與規格（opus 撰寫，參照 ceyx 三文件）。
2. `docs/logs/2026-08-31/Plan_ci_rewrite.md` — 實作計畫（另一名 opus 讀 spec 後以 writing-plans 方法撰寫）。
3. 統一 Python CI scripts 落地（scripts/ 下），`.github/workflows/ci.yml`、`release.yml` 改為薄殼呼叫該 scripts。
4. CI 迴圈跑到所有平台全綠，merge 回 main。

## Out-of-scope
- ceyx repo 本身的 build rewrite（另有其契約）。
- 任何第三方函式庫版本釘選變更（載體中立）。
- app 程式碼行為變更（僅允許 CI/build 腳本所需的改動）。
- release tag 實發（release.yml 的驗證以 CI 可驗證的方式進行，不實際發版）。

## 驗收條件（逐條）
- AC1. Spec 檔存在，逐條對照 ceyx `Requirements_ci_rewrite.md` R-1~R-8 聲明「適用於 Halcyon / 不適用＋理由」，且涵蓋 Halcyon 特有約束（sibling ceyx checkout、ceyx_release_pin、build_apps.py 單一入口）。
- AC2. Plan 檔存在，含分階段步驟、每步驗證方式、檔案清單。
- AC3. 統一 Python CI scripts 存在；workflows 中除 checkout/setup-flutter/cache 等環境動作外，建置/測試/打包/驗證邏輯皆經該 scripts；Windows job 無 `shell: bash` 建置步驟。
- AC4. 所有平台 CI jobs 於工作分支上全綠（`gh run list` conclusion==success，判空顯式比對字串）。
- AC5. merge 回 main 後，main 上的 CI run 全綠（合併後驗證是獨立閘，08-16 家族）。
- AC6. 本機 `flutter analyze` 0 issues、`flutter test -j 1` 全綠（機械證據：exit code artifact 內自捕 RC=$?）。

## 輪次預算
- Spec/Plan/實作：各 1 輪，重做上限各 +1。
- CI 修復迴圈：使用者明示「一路執行迴圈直到全綠」——迴圈輪次不設上限，但同一錯誤第三次出現（R4）→ 停下向使用者報告失敗軌跡。
- CI 迴圈流程（使用者指定，逐字）：主對話不下場修復/除錯/寫 code，僅確認 CI「狀態」後分配任務。若 CI 狀態非綠 → 派一名 debug opus 確認 root cause → 另一名 opus impl 收到 root cause 寫修復 code 並重新推送 CI → 主對話確認系統時間後 cron 8 分鐘後 task 確認本輪 CI 狀態。

## Parking-lot
（輪中新發現一律入此，收尾呈報）
