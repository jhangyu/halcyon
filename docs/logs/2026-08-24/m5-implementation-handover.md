# M5 雙窗實作（RAW 全解析度 tier-2）— Session Handover

> **建立時間**：2026-08-24 12:00（UTC+8）
> **交接目的**：讓下一個 session 完成 **Round 2 收官**（P0）並接續 **M5 實作**，終態是 AC-M5-1..10 逐條通過並合併回 `main`。
> **目前判定**：M5 設計凍結完成、實作未開始；Round 2 收官進行中（P-2b 半落地）。
> **可信版本錨點**：`main` @ `2a15d74`；worktree `/Users/jhangyu/project/halcyon-m6` branch `m6-cleanup` @ `1956710`（P-2b 未提交改動在其工作樹上）。
> **設計權威**：`docs/logs/2026-08-24/m5-dual-window-design.md`（§2＋§3 已由使用者凍結為契約）；裁決總帳：`docs/logs/2026-08-24/m4-m6-convergence-contract.md`。

## 0. 接手速讀（60 秒）

- **目標**：RAW 項目獲得全解析度 tier-2（現況兩層共用一個視窗解析度項），且嚴格雙窗——全解析度僅存在於 ±2，−3/+3..+5 只有視窗解析度 tier-1。
- **現況裁定**（fable 設計查證，指揮官抽查核可）：雙窗規則對便宜項**已成立**；「每項兩額度」量詞錯（14 entries／9 格窗）；**缺口只在 RAW**。
- **目前位置**：設計＋契約＋使用者六項裁決全部凍結；程式碼零改動。Round 2（task #7 五項修復）已在 `m6-cleanup` 落地未合併，P-2b 半途。
- **下一個動作**：P0——完成 Round 2 收官（見 §8），才輪到 M5 實作。
- **紅線**：AD-018 兩半徑不可合併、AD-019 兩預算不可互驗、三個凍結測試檔不可動、JPEG 行為是地板、UI/RSS 量測僅限使用者親跑（agent 只准 headless）。

## 1. 接手啟動序列

1. Read `docs/logs/2026-08-24/orchestrator-usage-gate-handover.md`（⚡最新中斷點節）— Round 2 收官七步序與殭屍 pane 清單。
2. Read `docs/logs/2026-08-24/m5-dual-window-design.md` 全文（145 行）— 契約本體。
3. Run `git -C /Users/jhangyu/project/halcyon-m6 status --porcelain && git -C /Users/jhangyu/project/halcyon-m6 log --oneline -3` — 預期 `M scripts/build_apps.py`＋`?? test/perf_log_build_stamp_test.dart`（P-2b 未提交）、tip `1956710`。
4. TaskList — task #9（P-2b）in_progress、#6 PARKED（M6 改道）、其餘 completed。
5. Start at §8 P0；M5 實作起點是 `lib/services/image_preload_controller.dart:808-828`（PixelPayload 雙層共用一項的分支）。

## 2. 目的與缺口（非 bug，是設計缺口）

- **目的**：昂貴（無內嵌預覽）RAW 在 ±2 內放大檢視時看到全解析度，不再只有視窗解析度。
- **缺口證據**：`image_preload_controller.dart:808-828`——PixelPayload 的 tier-1/tier-2 共用同一視窗解析度項，全解析度層根本不存在（設計 §1.3/§1.4，錨 `2a15d74` 逐行核對）。
- **便宜項無缺口**：tier-2 限 ±2（`:452-462`）、離窗確定性驅逐（`:498-503`）、tier-1 全窗（`:766-801`）。

## 3. 範圍與版控狀態

- In scope：`lib/services/image_preload_controller.dart`、`photo_source.dart`（SourceOutcome 擴欄，Q3 已裁定非凍結面）、新 provider（設計建議 `raw_full_res_image.dart`）、新測試檔 `test/image_preload_dual_window_m5_test.dart`。
- Out of scope：M6（task #6，M5 完成後從現行樹重推導）、`prefetch_scheduler.dart` 的常數（AD-018）、`photo_payload_cache.dart` 的預算與型別盲（D4）、三個凍結檔。
- `main` @ `2a15d74` 乾淨（untracked 為 docs 與既有雜項）；`m6-cleanup` @ `1956710`＋P-2b 未提交改動（見 §1 步 3）。
- 背景狀態：team fable-team 存活成員 m6-lead-opus（%6）、pl-impl-1-sonnet（%7）、m6-impl-1-opus（%8，已 stand down）、m6-test-haiku（%9）；殭屍 %10（無工具 architect，shutdown 握手不可達，需 kill-pane）、%12（不明 shell）。socket `/tmp/tmux-501/claude-swarm-31874`。cron `a584e7de` 可能已消耗。

## 4. 本階段邏輯架構（M5 切面）

| 節點 | 責任 | 關鍵符號 | 上游 | 下游 | 不變式／失敗語意 |
|---|---|---|---|---|---|
| PrefetchScheduler | 成本分級＋啟動資格 | `prefetch_scheduler.dart:105 probeSource`、`:119 kExpensiveStartupRadius` | preloadImages | PhotoSource | 昂貴啟動限 ±1（AD-018）；probe memo 每項一次 |
| PhotoSource | (path,size)→payload；唯一知檔型 | `photo_source.dart:126`（variant 活分支）、`:255-286 probeSource`、`:37-42 SourceOutcome` | scheduler | payload cache | 步驟 3b fallback 寫 miss（T1）；Q3：擴欄非凍結面 |
| PhotoPayloadCache | 保留（型別盲） | `photo_payload_cache.dart:31 kPayloadByteBudget` | PhotoSource | tiers | 只讀 byteCost；grep EncodedPayload\|PixelPayload == 0（D4） |
| DecodeTiers（controller） | tier-1/tier-2 provider＋視窗驅逐 | `image_preload_controller.dart:452-462`（±2 集合）、`:498-503`（驅逐）、`:808-828`（**M5 改造點**） | payload cache | ImageCache | bytes 物件識別＋寬高全中才命中；tier-2 debounce 250ms 凍結 |
| ImageCache（Flutter） | LRU 兜底 | `imageCacheMaxBytes` 768 MiB | tiers | GPU | 確定性視窗驅逐為主、LRU 為兜底（設計 §2.4） |

## 5. 資料鏈（M5 新增的昂貴項 happy path，設計 §2.2）

`FFI 解碼（±1 內 payload 生產，本來就要跑）→ 同一趟雙輸出：視窗解析度 RGBA（入 payload cache）＋全解析度 ui.Image（直入 ImageCache，buffer-free key）→ tier-2 provider 顯示`

| Hop | 關鍵約束 | 證據 |
|---|---|---|
| 解碼→雙輸出 | **piggyback 是凍結測試強制的**：P3/P4 斷言 decoder 呼叫數==1（`test/dng_nav_probe_m3_test.dart:285,:329`） | 指揮官逐字核對 |
| 距離 2 兩格 | 無便車可搭（payload 生產限 ±1；快取只有視窗解析度小圖，不能放大）→ 各補一次真解碼（61–406ms 級），使用者已知情裁可 | 設計 §4 Q1＋使用者釐清 |
| 全解析度→ImageCache | ui.Image 由 ImageCache 獨占，來源 RGBA buffer 暫態不留（否則 24MP 每項 ~183 MiB 爆 768） | 設計 §2.3 |
| 離窗 | 嚴格驅逐（Q2 裁定）；回窗補一次解碼＋payload `identical` 不變 | AC-M5-5 |
| Failure | 全解析度解碼失敗：保 tier-1 顯示、**不寫 permanent miss**、同 payload 不重試 | AC-M5-6 |

## 6. 契約（凍結，AC-M5-1..10 全文見設計 §3）

| 契約 | 要點 | 證據 |
|---|---|---|
| AC-M5-2..6 | 新測試檔 `test/image_preload_dual_window_m5_test.dart`，測試名 M5-DW1..DW5 已在契約指定逐字 | 設計 :120-124 |
| AC-M5-7 | `image_preload_window_test.dart` 不修改且綠；三凍結閘 sha256 同 registry | 設計 :125 |
| AC-M5-9 | provider 不持 Uint8List 大緩衝（grep==0）＋升級前後 `retainedByteCost` 相等（M5-DW6） | 設計 :127 |
| AC-M5-10 | 【使用者自量】RSS＋四格延遲 A/B；agent 僅供推算對照（441–661 MiB） | 設計 :128 |
| 使用者六裁決 | Q1 ±2／Q2 嚴格驅逐／Q3 擴欄可動／Q4 payload 優先、升級按距離／Q5 P-3 不動／Q6 便宜 DNG 續走 EncodedPayload | 契約「M5 契約條款」節 |

## 7. 已完成事項

| 結果 | 產物 | 驗證 | 錨點 |
|---|---|---|---|
| [C] M4 合併＋回歸 | `main` 245 執行（m6-cleanup tip 為 245；main 為 243）/0 skip | round-1/2 handoff＋registry | `2a15d74` |
| [C] M5 設計＋契約凍結＋六裁決 | 設計檔 145 行＋契約檔 | 指揮官抽查 :452-462/:498-503/P3P4 逐字中 | working tree（docs 未 commit，**收官時記得 commit docs**） |
| [C] Round2 task #7 五項修復 | m6-cleanup 7 commits | lead 簽收 245/0skip | `1956710` |
| [C] M6 改道裁決＋證據包 | round-2-m6-handoff.md §3.4（94–183 倍實測）＋兩份 parked patch（halcyon-m6/tmp/verify/2026…-m6-parked-*.patch，**worktree 清理前先複製到主樹 scripts/tmp/**） | lead 機械查證 | `1956710` |

## 8. 待解議題（依序）

| 優先 | 狀態 | 議題 | 下一動作 | 完成條件 |
|---|---|---|---|---|
| P0 | [P] | P-2b 半落地未提交（build_apps.py＋stamp 測試在 pl-impl 工作樹） | 令 m6-lead 喚醒 pl-impl 完成 headless 雙證明並 commit；兩次無果 lead bypass | task #9 簽收，final tip 出爐 |
| P0 | [U] | Round 2 審查＋合併 | 派 round-2-reviewer-opus（唯讀，審 `2a15d74..tip`；提示：唯一生產行為改動是 `5361077`＋P-2b commit） | CONFIRMED → merge --no-ff → main 重跑（-j 1，預期 245＋P-2b 新測試）→ registry 升格 → worktree/分支清理（patch 先救出）→ 成員關閉（%10/%12 走 snapshot→drain→kill-pane） |
| P0 | [D] | Round 3（M5 實作）開工確認 | 問使用者一聲 go | 使用者確認 |
| P1 | [ ] | M5 實作 | 新 worktree 自新 main；單一交付鏈（controller＋photo_source＋provider＋測試同檔案群）→ 一名 opus implementer＋lead＋test-runner；起點 `image_preload_controller.dart:808-828` | AC-M5-1..9 機械過、AC-M5-8 全套綠 |
| P2 | [ ] | AC-M5-10 使用者自量 | 提供推算對照值與量測步驟（PerfDriver 歸使用者） | 使用者回報 |
| P3 | [D] | M6 重推導 | M5 合併後派 fresh 設計（讀 round-2-m6-handoff §3） | 新設計→使用者訂契約 |

## 9. 嘗試、裁決與禁止重踩

| 嘗試／方案 | 結果 | 理由 | 可重試？ |
|---|---|---|---|
| M6 原 delete list（D5） | [R] 三前提全被推翻 | variant 活邏輯（`photo_source.dart:126`）；AC8 與凍結檔 12 建構點互斥；刪 Swift extractor 實測 94–183 倍退化＋解析度掉 2800px | 否——M5 後從現行樹重推導 |
| 全解析度 RGBA 留 payload cache（MemoryImage 式） | [R] | 24MP 每項 ~183 MiB，爆 768 MiB 且 LRU 看不見 buffer 半邊 | 否（設計 §2.3） |
| RAW 視窗放寬替代方案 | [R] | 200–300 MB 換半吊子（設計權威 §8） | 否 |
| 派 architect 類型做要寫檔的規劃 | [R] | 該類型無 Write/SendMessage，三次沉默 idle | 否——規劃交付用 general-purpose |
| 用量閘當下寫交接檔 | [R] | 交接檔本身被閘掉，成員回報的路徑不存在 | 恢復交接檔開工前先寫並 `ls` 驗證 |

## 10. 未來方向（不阻塞）

- M6 重推導（觸發：M5 合併後）。P-3 遠格空窗（觸發：使用者另訂契約）。

## 11. 已知限制與待決

- **已知限制**：M4 的 AC4 無 agent 驗證的不退步宣稱（使用者簽收依據為自身判斷）；便宜組 RSS 從未量測（P-1 已由使用者裁刪）。
- **未驗證**：P-2b 的兩半證明（見 P0）。
- **需使用者決策**：Round 3 開工（P0 第三項）。

## 12. 驗收命令

```bash
# Round 2 收官後（在 main）：
flutter analyze                                   # 0 issues
flutter test -j 1                                 # All tests passed!，執行數==預註冊值，0 skip，RC 自捕
shasum -a 256 test/dng_nav_probe_m3_test.dart test/image_preload_controller_m3_amend3_test.dart scripts/tmp/dng_nav_probe_test.dart   # == registry 三值
grep -c "EncodedPayload\|PixelPayload" lib/services/photo_payload_cache.dart   # 0
# M5 實作驗收：設計 §3 AC-M5-1..9 逐條（各附機械命令）
```

## 13. 參考入口

- 必讀：`docs/logs/2026-08-24/m5-dual-window-design.md`（契約本體）
- 必讀：`docs/logs/2026-08-24/m4-m6-convergence-contract.md`（全部使用者裁決軌跡）
- 必讀：`docs/logs/2026-08-24/orchestrator-usage-gate-handover.md` ⚡節（Round 2 收官細節）
- `docs/logs/2026-08-24/round-2-m6-handoff.md` §3（M6 重推導時的證據包）
- `docs/logs/2026-08-24/baseline-registry.md`（基線引用，禁重量）
- Team 收尾：`~/.claude/reference/team-shutdown-protocol.md`（%10/%12 殭屍需 drain/kill-pane）
