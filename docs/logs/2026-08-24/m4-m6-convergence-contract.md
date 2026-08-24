# M4／M6 收斂契約（凍結 2026-08-24）

> 設計權威：`docs/logs/2026-08-23/image-pipeline-redesign-handover.md`（§6、§12、§12.1）
> 交接依據：`docs/logs/2026-08-23/m4-m6-remaining-handover.md`
> 凍結後只有使用者能修改本契約。每輪 kickoff 逐字重貼終態與驗收條件。

## 終態（一句話）

M4（排程統一）與 M6（variant 收攏＋runner 清理）完成並合併回 `main`，全套測試在 `main` 上綠，且 JPEG 切換延遲相對基線不退步。

## In-scope 交付物

1. **M4**：共用 permanent-miss 集合擴及側欄縮圖（永久失敗恰好請求一次）；`preloadImages` 預覽路徑 generation guard；步驟 3b fallback 寫入 miss 集合的專屬測試；[U-1] JPEG 切換延遲 A/B。
2. **M6**（M4 全綠後才開工）：`NativeImageNeedsRawDecode`＋`kNoEmbeddedPreviewCode` 刪除、`macos/Runner/AppDelegate.swift:371-402` 發射刪除、`macos/Runner/DngPreviewExtractor.swift` 整檔刪除、`memory.md` AD-010/AD-011 修訂——同一個 commit 內完成。

## Out-of-scope（一律入 parking-lot，不升級為驗收條件）

- M5（RAW 全解析度 tier-2）；P-1（便宜組 RSS 量測）；P-2（應用內版本戳記）；P-3（無預覽 RAW 遠格空窗）；P-4（532.3 MiB 殘差歸因）；[U-2]/[U-4]/[U-6]/[U-7]。
- 上游 `flutter_dng_decoder` 任何改動。
- Windows runner 程式碼（設計權威 §7：只記帳不動碼）。
- macOS `isRaw` 分支（`AppDelegate.swift:313-318`、`:426-472`）——**明確保留，禁刪**。
- `PhotoSource.probe()` 一行投影（`photo_source.dart:301`）——**明確保留，禁刪**。
- 三個凍結測試檔的任何改動（未經使用者授權）。

## 驗收條件（逐條，機械可查）

### M4（Round 1）
- AC1：新測試——loader 永久失敗的縮圖在三次 `preloadThumbnails` sweep 中，loader 對該檔被呼叫**恰好 1 次**（計數斷言）。
- AC2：新測試——`preloadImages` 預覽路徑 generation guard：資料夾重載／範圍變更後，stale await 恢復不得寫入新 generation 的狀態。
- AC3：新測試——步驟 3b fallback 失敗時寫入 permanent-miss（spinner-forever 不變式 T1，設計權威 §3.4）。
- AC4：**（使用者 2026-08-24 修訂）** UI 切換延遲／記憶體量測改由**使用者親自量測**；agent 不得執行 UI 驅動量測（perf_driver UI 切換、RSS 掃描），僅允許純後台 headless 解碼命令基準。已登錄的基線數字保留於 baseline-registry；after 腿交由使用者自量。
  **→ 2026-08-24 使用者簽收 AC4**（使用者行使量測所有權裁定通過）。紀錄不變：agent 側無「M4 未退步 JPEG 切換延遲」的驗證宣稱，簽收依據為使用者自身判斷。
- AC5：`flutter analyze` 0 issues；`flutter test -j 1` 全綠且「執行數」≥ 238＋新增測試數（預註冊執行數，不用宣告數）。
- AC6：三個凍結閘門 sha256 不變：`test/dng_nav_probe_m3_test.dart` `59b1f3c7…`、`test/image_preload_controller_m3_amend3_test.dart` `fcdd564e…`、`scripts/tmp/dng_nav_probe_test.dart` `05565d33…`（後者為 gitignored scratch，從主樹複製比對）。
- AC7：`grep -c "EncodedPayload\|PixelPayload" lib/services/photo_payload_cache.dart` == 0（D4 持續成立）。

### M6（Round 2）
- AC8：**（使用者 2026-08-24 二次修訂，Opt-3）** M6 **本輪擱置**。裁決過程：先選 B（留死符號），後經 m6-lead 深度稽核推翻前提——variant 是活的生產邏輯（`photo_source.dart:126` 唯一通往 RAW 解碼的分支）、`DngPreviewExtractor.swift` 是現役 macOS 便宜 DNG 通道，只刪發射會靜默違反 D2（九併發 CIRAWFilter）。M6 的成本 seam 重設計與 M5 雙窗設計同屬一個子系統，**待 M5 設計定稿後與使用者重訂契約再議**。設計權威 §7 delete list 的 D5 前提（M3 會整檔移除控制器）已過時，此為根因，記錄在案。AC9–AC12 隨 M6 一併擱置。
- AC9：`memory.md` AD-010/AD-011 已修訂（記錄 variant 3→2 與理由）。
- AC10：`isRaw` 分支與 `PhotoSource.probe()` 投影原樣保留（grep 可證）。
- AC11：**（使用者 2026-08-24 修訂）** 全套測試綠（同 AC5 標準）＋真的 `flutter run -d macos` 走一遍 26 個正典樣本（13 昂貴＋13 便宜）。macOS 效能基準的 UI／記憶體部分改由**使用者親自量測**；agent 僅允許純後台 headless 解碼基準。
- AC12：合併回 `main` 後在 `main` 上重跑全套測試綠（合併後驗證為獨立閘）。

## 共用基線（使用者 2026-08-24 指示新增）

基線數字一律引用 `docs/logs/2026-08-24/baseline-registry.md`，錨點未變的基線**禁止重量**。每輪合併後由 lead 把已驗證的 after 數字升格為新基線登錄進該檔。AC4／AC11 的「基線」以登錄檔為準。

## Round 2 追加裁決（使用者 2026-08-24，round-1 收官後）

Parking-lot 處置：**修** PL-1/2/10（縮圖 loader try/catch＋finally 釋放）、PL-7（第二道 generation guard 交付測試）、PL-8（TC 編號去歧義）、PL-9（artifact provenance 慣例）、P-2（應用內版本戳記）；**刪**（不做，出帳）PL-6、P-1、P-3、P-4。Hook 的 flutter test 90 秒通道已授權並落地。
M5 與 M6 同輪並行：M6 照原驗收開工；M5 本輪先由 Fable 成員做**架構規劃**（不實作）——需求：全解析度快取只限 −2..+2，−3 與 +3..+5 只留視窗解析度（雙窗覆蓋），並與既有 LRU 驅逐配合；先查證現行實作是否已有此邏輯，再出設計。M4 手上的「每項佔兩個 ImageCache 額度」敘述由此規劃一併查證。

## M5 契約條款（使用者 2026-08-24 裁定）

M5 的契約內容**以設計文件結論為準**：`docs/logs/2026-08-24/m5-dual-window-design.md`（m5-plan-2-fable 交付，指揮官 2026-08-24 抽查簽收——±2 視窗計算 :452-462、離窗驅逐 :498-503、凍結 P3/P4 decodes-once 斷言逐字核對吻合）。**其 §2「M5 設計」與 §3「建議驗收條件」（AC-M5-1..10）即日凍結為 M5 契約條款**；AC-M5-10 為使用者自量項。§4 六個開放問題已由使用者於 2026-08-24 裁決併入：**Q1 升級半徑 ±2**（使用者確認，並已釐清「±2 邊緣補解碼」係因快取僅存視窗解析度、全解析度需重解，無便車可搭）；**Q2 嚴格驅逐**；**Q3–Q6 全部照設計預設**（SourceOutcome 擴欄非凍結面／佇列順序 payload 優先、升級按距離／P-3 維持原狀／M5 假設便宜 DNG 走 EncodedPayload、macOS 通道歸 M6）。**M6 裁決：M5 實作完成後從現行樹重推導範圍、出新設計文件再訂契約**（delete list 三前提全被推翻：variant 活邏輯、AC8 與凍結檔互斥、刪 Swift extractor 實測 94–183 倍退化——證據見 round-2-m6-handoff.md §3.4 與兩份 parked patch）。核心查證結論記錄在案：雙窗規則對便宜項已成立（14 entries／9 格窗，非 18），「每項兩額度」量詞錯誤，768 MiB 常數推導本就按 5×2+4×1，僅 RAW 缺全解析度層——即 M5 的全部缺口。M6（已擱置）之後與 M5 開放問題 Q6 一併重訂。

## 輪次預算

**3 輪**（R1=M4、R2=M6、R3=修復緩衝）。預算用盡而驗收未全過 → 停下向使用者報告失敗軌跡，禁止自行開下一輪。

## 樣本正典（防呆）

26 個檔案：昂貴組 13（十二個 `2024-07-*` ＋ `IMG_20251112_092839.dng`）；便宜組 13（`2026-*` 系列）。mtime 不可用於判斷樣本。worktree 無 `local_data/`，需 symlink 主樹樣本並先跑未變異測試證明真的執行（skip 看起來像通過）。
