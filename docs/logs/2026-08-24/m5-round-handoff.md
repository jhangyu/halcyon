# M5 實作輪收官（m5-team round 1）

> **建立**：2026-08-24（UTC+8），指揮官（主對話）
> **契約**：`docs/logs/2026-08-24/m5-dual-window-design.md` §2＋§3（凍結），六項使用者裁決（Q1 ±2／Q2 嚴格驅逐／Q3 擴欄可動／Q4 生產優先、升級按距離／Q5 P-3 不動／Q6 便宜 DNG 續走 EncodedPayload）
> **結果**：**一輪完成**。AC-M5-1..9 全過；AC-M5-10 屬使用者自量，未跑。
> **版本錨點**：合併前 `main` @ `72afd7a`（docs 疊加 `a0c14a4`）→ 分支 tip `a1f6690` → **合併後 `main` @ `c2ae385`**。

## 1. 前置收官（Round 2，本輪開工前完成）

- 使用者裁決：**Round 2 跳過 review**（該輪僅 parking-lot 修復，無審查價值）。合併 `72afd7a` 由 m6-lead 在退場前完成。
- main 合併後閘：analyze 0 issues、**246 執行／0 skip**（artifact `scripts/tmp/verify/main-post-merge-72afd7a.txt`，RC 自捕）。registry 錨點升格 `72afd7a` 已 commit。
- 舊 fable-team 已由其 lead 自行收掉；殭屍 pane %12 已 kill；halcyon-m6 worktree 與 m6-cleanup 分支已刪（兩份 M6 parked patch 先救至 `scripts/tmp/`，round-2 證物 32 件在 `scripts/tmp/round2-verify/`）。

## 2. 團隊與分工（最大並行，使用者指示）

worktree `/Users/jhangyu/project/halcyon-m5`，branch `m5-dual-window`，自 `a0c14a4` 起。檔案所有權互斥，介面由指揮官先凍結（SourceOutcome 擴欄格式、RawFullResImage key 語意、controller 的兩個 debug accessor）。

| 成員 | model | 交付 | commit |
|---|---|---|---|
| impl-provider-sonnet | sonnet | `lib/services/raw_full_res_image.dart`（新檔，one-shot、buffer-free key） | `9b63970` |
| impl-source-sonnet | sonnet | `photo_source.dart` 單次解碼雙輸出（`fullRes` 擴欄，6 個 null 位點＋2 個 piggyback 位點） | `bf7dbdc` |
| impl-controller-opus | opus | controller 升級分流＋佇列＋簿記＋view/app_state 接線；兩個 debug accessor；TC-079 重錨 | `3973b79`、`3434e55`、`83fa70f` |
| impl-tests-sonnet | sonnet | `test/image_preload_dual_window_m5_test.dart`（M5-DW1..DW6 契約逐字名）＋`unit_test.md` TC-112..117 | `a1f6690` |
| test-runner-haiku | haiku | 兩次 main 閘＋worktree 整合閘 | —（artifacts） |

## 3. 驗收證據

- **Worktree 整合閘 @ `a1f6690`**（artifact `halcyon-m5:tmp/verify/gate-m5-final.txt`，指揮官親抽 RC 行）：AC-M5-1 六 grep 全中（半徑常數僅 2 個）、AC-M5-9 grep==0、凍結三 sha == registry、analyze 0、**252 執行／0 skip／All tests passed!**（246＋6）。
- **main 合併後閘 @ `c2ae385`**：artifact `scripts/tmp/verify/main-post-merge-c2ae385.txt`（見 registry 現行錨點節）。
- M5-DW1..DW6 對應 AC-M5-2..6、AC-M5-9 測試半，單檔與全套皆綠。

## 4. 輪中裁決紀錄（指揮官裁定，需使用者知悉）

1. **TC-079 重錨**（`test/image_preload_controller_test.dart:958`，commit `83fa70f`）：該測試原斷言 pre-M5「RAW 兩 tier 共用一個視窗解析度項」的事實；M5 依契約拆掉共用後，改經 `debugTierTwoProviderFor` 讀全解析度項。**測試意圖（離開 ±2 → 項被驅逐、payload 保留）與兩個斷言原文未動**。性質同 round-1 對 photo_source_test 的處理：需求變更向下流入記錄舊需求的測試。該檔不在凍結清單。
2. **介面凍結修訂**：controller 增加 `@visibleForTesting debugTierTwoKeyIds`（契約 AC-M5-2 要求）與 `debugTierTwoProviderFor`（測試斷言全解析度尺寸用；最終 DW2 改用 probe-provider 技巧自足，accessor 保留無害）。
3. **provider 獨立單元測試裁定不寫**（M5-DW 套件經 controller 全覆蓋，獨立測試冗餘）。

## 5. 已知限制與 parking-lot

- **AC-M5-10 未跑**（使用者自量）：昂貴組峰值 RSS＋JPEG 切換延遲四格 A/B。agent 推算對照值：昂貴組 ImageCache 工作集約 **441–661 MiB**（設計 §2.4，紙上推算非量測）。量測前注意 P-2b 規則：perf log 讀到 build commit `unknown` ＝該次量測作廢；用 `scripts/build_apps.py` 建置以注入真實 commit。
- P-3（從未進 ±1 的昂貴項遠格兩層皆空）維持原樣（Q5，AD-018 紅線）。
- 距離 2 兩格的補升級各需一次真解碼（61–406 ms 級），使用者已知情裁可（Q1）。

## 6. M6 下一步

M6（variant 收攏＋runner 清理）原 delete list 三前提已被推翻（見 `docs/logs/2026-08-24/round-2-m6-handoff.md` §3：variant 是活邏輯、AC8 與凍結檔互斥、刪 Swift extractor 實測 94–183 倍退化），需**從 M5 後的現行樹（`c2ae385`）重推導**。兩份 parked patch 在 `scripts/tmp/2026…-m6-parked-*.patch` 僅供參考，不得直接套用。M6 釐清與交接檔由 fresh 成員撰寫（見 `m6-rederivation-handover.md`，若該檔存在即為其產出）。

## 驗活命令

```bash
git -C /Users/jhangyu/project/Halcyon log --oneline -1        # c2ae385 或其後
flutter test -j 1 test/image_preload_dual_window_m5_test.dart  # 6 tests, All tests passed!
```
