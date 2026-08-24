# 指揮官交接檔（2026-08-24 11:45 UTC+8 更新；原為用量閘交接）

## ⚡ 最新中斷點（2026-08-24 11:45，取代下方 §中斷點狀態 的過時部分）

1. **M5 已全部落定**：設計簽收（task #8 關）、契約凍結（AC-M5-1..10）、六個開放問題使用者已裁決（Q1 ±2／Q2 嚴格驅逐／Q3–Q6 預設）、M6 裁決＝M5 實作後從現行樹重推導（task #6 已更新）。m5-plan-2-fable 已關閉。
2. **Round 2 只剩 P-2b（task #9）**：pl-impl-1-sonnet 有**未提交**進度（`M scripts/build_apps.py`＋新檔 `test/perf_log_build_stamp_test.dart`，tip 仍 1956710），成員停在半途；已令 lead 喚醒，兩次無果則 lead bypass 親自完成。**證明必須 headless**（禁啟動 app）：flutter test --dart-define sentinel＋build 命令行/40字元 hash grep；『perf log 讀到 unknown ＝ 該次量測作廢』規則須文件化。
3. **P-2b 簽收後的收官序**：lead 交最終 tip＋commit 清單 → 派 round-2 reviewer（opus，唯讀，審 2a15d74..tip，提示：全輪唯一生產行為改動是 5361077 的 try/catch/finally，注意力放它與 P-2b commit）→ CONFIRMED 後 merge --no-ff 進 main → main 上重跑（預期 245＋P-2b 新測試數，-j 1）→ baseline-registry 錨點升格 → worktree/分支清理 → 成員關閉。
4. **殭屍清理**：pane %10（m5-arch-1-fable，無工具無法回應握手）與 %12（不明 shell pane）需在 TeamDelete 前走 snapshot→drain→kill-pane；socket /tmp/tmux-501/claude-swarm-31874。
5. **教訓待入帳**（收官時寫 lessons-learned，查重後）：用量閘當下寫的交接檔本身會被閘掉——成員回報的 handoff 路徑可能根本不存在，先 `ls` 驗證；恢復交接檔開工前先寫。
6. **Round 3 提案待使用者確認**：M5 實作（契約已凍結）。

> 寫給接續 session 的指揮官。權威文件：`m4-m6-convergence-contract.md`（全部使用者裁決）、`baseline-registry.md`、`round-1-m4-handoff.md`、`round-2-m6-handoff.md`。team：fable-team。

## 中斷點狀態

1. **M5 設計已交付**：`docs/logs/2026-08-24/m5-dual-window-design.md`（m5-plan-2-fable，READY_FOR_SIGNOFF，task #8 未關）。
   - 核心結論：雙窗規則對便宜項**已成立**（tier-2 限 ±2 於 controller :452-462、離窗驅逐 :498-503；tier-1 全窗 :766-801）；「每項兩額度」說法錯誤（14 entries/窗，非 18）；768 MiB 常數本來就按 5×2+4×1 推導，只有量詞錯。規則只對 RAW 破——PixelPayload 無全解析度層，即 M5 缺口。
   - 關鍵設計決策：RAW 全解析度只活在 ImageCache（buffer-free key 的 ui.Image），來源 RGBA buffer 為暫態；單次解碼雙輸出（piggyback）是**被凍結測試強制的**（dng_nav_probe_m3 P3/P4 斷言解碼次數==1）。
   - **我的抽查未完成**（被用量閘打斷）：需驗 file:line 宣稱（controller :452-462/:498-503、凍結測試 :285/:329）與檔案本體。
   - **6 個開放問題需使用者裁決後 M5 契約才可凍結**（Q1 升級半徑、Q2 嚴格驅逐 vs LRU、Q3 SourceOutcome 擴欄、Q4 佇列順序、Q5 P-3 不變、Q6 M6 邊界）。使用者已裁定：設計的「M5 設計」＋「建議驗收條件」節原文即 M5 契約條款。

2. **Round 2 收官待辦**（依序）：
   a. **P-2b 狀態對帳**：我批准了 P-2b（build_apps.py 注入真實 build commit，因預設 stamp 是字面 'unknown'），但授權訊息與 lead 報告交錯，**未收到執行確認**。問 m6-lead-opus。
   b. P-2b 落定後：派 **round-2 reviewer**（opus，team-reviewer，唯讀，對抗式）審 `2a15d74..<最終tip>` on branch m6-cleanup（worktree /Users/jhangyu/project/halcyon-m6）。已知 commits：task#7 五個＋handoff d07a388＋1956710，tip 曾報 99d1c36（以 lead 最終回報為準）。
   c. CONFIRMED 後：merge --no-ff 進 main → main 上重跑套件（預期 245 執行/0 skip，flutter test -j 1，有 90 秒通道）→ 基線升格登錄 → worktree 清理（halcyon-m6；porcelain 應只有 local_data symlink 與 scripts/tmp 兩個 untracked）→ 分支刪除。
   d. 成員關閉。**注意：m5-arch-1-fable（pane %10）是無工具殭屍**（architect 類型無 Write/SendMessage，無法回應 shutdown 握手），需走 team-shutdown-protocol 的 snapshot→drain→kill-pane 流程強制清；socket = /tmp/tmux-501/claude-swarm-31874。

3. **M6 = 未排程 blocker（非緩議）**，task #6 PARKED。重裁決包三事實：①variant 是活邏輯（photo_source.dart:126）；②AC8 與凍結檔互斥（12 個建構點）；③刪 DngPreviewExtractor.swift = 便宜 DNG 預覽 **94–183 倍**退化＋解析度掉到 2800px q0.8（headless 實測，預註冊，artifact 在 halcyon-m6/tmp/verify/）。delete list 三個前提全錯——lead 建議 M6 範圍從現行樹重推導。патch 留檔：halcyon-m6/tmp/verify/20260823T174141Z-m6-parked-macos-half.patch＋…-dart-half.patch。**與 M5 開放問題 Q6 一併請使用者重訂契約。**

## 常備規則（違反即壞）
- UI 效能/RSS 量測**僅限使用者親跑**；agent 只准 headless 解碼基準（memory: halcyon-user-measures-ui-perf）。
- 基線引用 baseline-registry.md，錨點未變禁止重量；現錨 main @ 2a15d74（套件 243；m6-cleanup tip 上為 245）。
- flutter test 一律 -j 1；exit code 只信 artifact 內自捕 $?；三個凍結測試檔不可動（sha 見 registry）。
- ctx 85% 指令：見到 context 摘要通知即令成員 checkpoint＋idle，停止新派工。
- kTierTwoRadius(2)/kExpensiveStartupRadius(1) 不可合併（AD-018）；兩個 byte 預算不可互驗（AD-019）。

## Cron
- `a584e7de`（durable，05:30 局部時間一次性）：原接續 prompt（內容較舊，本檔為準）。
- 新排 05:25 接續 cron 指向本檔（見 scheduled_tasks.json）。
