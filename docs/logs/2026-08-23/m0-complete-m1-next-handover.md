# 影像管線重新設計 M0 完成 / M1 待開工 — Session Handover

> **建立時間**：2026-08-23 11:50（UTC+8）
> **交接目的**：讓下一個 session 接續 M1，終態是「側欄縮圖在解碼階段就被限制尺寸，且長寬比不變形」。
> **目前判定**：M0 已完成並合併；M1 尚未開工，無在途工作。
> **可信版本錨點**：branch `main`；HEAD `40dc5fc`；所有驗證對象皆為該 hash 或其祖先。

---

## 0. 接手速讀（60 秒）

- **上位目標**：讓縮圖／預覽脫離 macOS 原生實作、全平台通用。診斷是「模組按執行路徑切而非按功能切」，解法是 M0–M6 六階（見 §13 必讀 1）。
- **M0 已完成並合併進 main**：DNG 抽取器改為 byte-range 讀取、依請求尺寸挑候選、orientation 由同一趟走訪回傳。
- **現在的位置**：M0 邊界結束，樹乾淨，**沒有任何在途實作工作**。
- **下一個動作**：M1 — 在 `lib/views/sidebar_view.dart:273` 的 `Image.memory` 加上解碼期尺寸限制。
- **最大紅線**：`test/dng_preview_extractor_test.dart` 是行為保持 oracle，**一字不可改**；`tier-2` 現行行為凍結（使用者裁決 D2），任何讓瞬間前後切換變慢的提案直接否決。

---

## 1. 接手啟動序列

1. Read `docs/logs/2026-08-23/image-pipeline-redesign-handover.md` §1（使用者裁決 D1–D6）與 §6（M0–M6 分階）— 這是被凍結的執行方向，**注意它目前未進版控**（見 §3）。
2. Run `git log --oneline -4 && git status --short` — 預期 HEAD `40dc5fc`，`lib/` 與 `test/` 乾淨。
3. Run `flutter analyze && flutter test -j 1` — 預期 `No issues found!` 與 `+188: All tests passed!`。
4. Read `lib/views/sidebar_view.dart:271-281` — M1 的唯一改動點。
5. Read `docs/logs/2026-08-23/round-1-m0-handoff.md` §結構性發現 — M1 的驗收條件要照那五條設計，否則會重蹈 M0 的覆轍。

---

## 2. 目的、現象與根因狀態

### 目的
側欄縮圖在**解碼**階段就被限制尺寸。不是修今天的 bug，是 M3 的前置條件。

### 現象
- 條件：側欄每格顯示 32×32 邏輯點的縮圖。
- 實際：`sidebar_view.dart:273-279` 的 `Image.memory(thumbBytes, width: 32, height: 32, ...)` 中，`width`/`height` 是**版面**約束，不是**解碼**約束。Flutter 仍以來源 bytes 的原始尺寸解碼成點陣。
- 預期：解碼時即縮到 `32 × devicePixelRatio`。
- **今天為何沒事**：原生端把 `sidebarThumbnail` 請求封頂在 200 px，所以送進來的 bytes 本來就小，41 列約 4.4 MB。這是外部條件擋著，不是側欄自己有防護。

### 根因（已確認）
側欄從未聲明自己需要多大。M3 的整個目的是三條路徑共用同一個快取；共用之後側欄拿到的可能是快取裡的全尺寸影像。一張 24 MP 影像解成點陣約 96 MB，41 列約 3.94 GB。

**證據**：`lib/views/sidebar_view.dart:273`（無解碼期約束）；原生端 200 px 封頂見 §13 必讀 1 的 §6「M1」註記。

---

## 3. 範圍與版本控制狀態

- **In scope（M1）**：`lib/views/sidebar_view.dart`，加對應測試。
- **Out of scope**：`image_preload_controller.dart`（M3 才動，846 行）、`dng_preview_extractor.dart`（M0 已完成，720 行）、任何原生檔。
- **Branch / HEAD**：`main` / `40dc5fc`
- **Working tree（`lib/`、`test/` 乾淨）**：

| 檔案 | 狀態 | 來源 |
|---|---|---|
| `docs/logs/2026-08-23/image-pipeline-redesign-handover.md` | **untracked** | 前一個 session；**這是整條線的設計權威，卻不在版控** |
| `docs/logs/2026-08-22/windows-port-session-handover.md` | modified | 前一個 session，非本次改動 |
| `docs/logs/2026-08-20/cross-platform-port-inventory.md` | untracked | 前一個 session |
| `scripts/tmp/**` | untracked | scratch 車道，含本輪全部驗證 artefact |

- **相關 commits**：
  - `d4c97f5` — M0 實作：byte-range 讀取、依尺寸挑候選、`readOrientation` 回 `int?`
  - `c7706f1` — M0 round handoff（五條結構性發現、修正後的 mutation 分析）
  - `0ca6ba4` — merge M0 進 main
  - `40dc5fc` — 凍結契約 + 兩份獨立複驗報告
- **背景狀態**：team `m0-extractor` 已依 shutdown protocol 關閉並驗證（`ok=true`, `live_panes=[]`）。**無在途 agent、無背景程序。**
- **殘留 worktree（未刪，刻意）**：
  - `/Users/jhangyu/project/halcyon-m0` @ `c7706f1` — M0 分支工作樹
  - `/Users/jhangyu/project/halcyon-m0-red` @ `48bb934` detached — **gitdir link 已損壞**（M0 期間 squad lead 誤刪重建所致）。內容經 sha256 驗證與 `48bb934` 一致，可用但 git metadata 半殘。要清理用 `git worktree prune`，不要 `rm -rf` 後才想起要確認歸屬。

---

## 4. 目前邏輯架構（M1 切面）

| 節點 | 責任 | 關鍵符號 | 上游 | 下游 | 不變式／失敗語意 |
|---|---|---|---|---|---|
| 側欄列表 | 依可見範圍驅動縮圖載入（非 scroll listener） | `sidebar_view.dart` `itemBuilder` | `AppState` | 縮圖 widget | 見 `memory.md` AD-014／G-001 |
| 縮圖 widget | 把 bytes 畫成 32×32 | `sidebar_view.dart:271-281` | `thumbBytes` | Flutter ImageCache | **M1 要加的不變式：解碼後最長邊 ≤ `32×dpr`，且長寬比不變** |
| 縮圖來源 | 原生端取 200 px 預覽 | `NativeThumbnailService` `ImageRequestPurpose.sidebarThumbnail` | 平台 channel | `thumbBytes` | 目前是尺寸上限的**唯一**來源，M3 後不再是 |

**M1 不碰的兩層**：`ImagePreloadController`（tier-1／tier-2 預載）與 `PhotoSource`（尚不存在，M2 才建）。

---

## 5. 資料生產消費鏈（M1 相關）

### Happy path
`原生 channel → thumbBytes (Uint8List) → Image.memory → ImageCache → 螢幕`

| Hop | 輸入 | 輸出 | 驗證／正規化 | 身分／去重鍵 | 失敗處理 | 證據 |
|---|---|---|---|---|---|---|
| 原生 → Dart | path + purpose | JPEG bytes ≤200 px | 原生端封頂 | photo id | 回 null → 顯示佔位方塊 | `sidebar_view.dart:265-269` |
| bytes → 點陣 | `Uint8List` | `ui.Image` | **目前無解碼期約束（M1 缺口）** | (bytes 物件識別, width, height) | — | `sidebar_view.dart:273` |

### Failure path
`thumbBytes` 為 null 時走 `:265-269` 的灰色佔位方塊。M1 不改這條。

**M3 才會出現的風險**：共用快取後上游可能不再封頂 200 px，此時 hop 2 的缺口才會致命。

---

## 6. 型別與介面契約（M0 產出，M1 需知道但不改）

| 契約 | Producer 定義 | Consumer 假設 | 不變式 | 錯誤語意 | 證據 |
|---|---|---|---|---|---|
| `extractEmbeddedJpeg(path, {longEdge, onDiskRead})` | 回 `DngEmbeddedJpeg?` | `longEdge: null` 與舊行為 byte-identical | 選最小的 `maxDim ≥ longEdge`；都不夠大時選最大 | 畸形輸入回 `null`，**永不 throw** | `dng_preview_extractor.dart:109` 起 |
| `readOrientation(path)` | 回 `Future<int?>` | `null` = 判斷不出來；`1` = 確實不旋轉 | 只讀 header + IFD0，實測 8,192 bytes | 檔案不存在／解析失敗／tag 存在但值壞掉 → `null` | `dng_preview_extractor.dart:109` |
| `readDngOrientation(bytes)` | 回 `int`（**非** `int?`） | 失敗退化為 `1` | **禁止與上者統一** | 永遠回 int | `dng_preview_extractor.dart:137`，`?? 1` 在 `:146` |
| `DngEmbeddedJpeg.orientation` | `final int`（非 nullable） | 抽取路徑用它注入 EXIF | `_walk` 在 `:206` 以 `?? 1` 折回 | — | 凍結 API |

**⚠️ 最可能被踩的雷**：`readOrientation` 是 `int?`、`readDngOrientation` 是 `int`，這個不對稱是**刻意的**。統一它們會讓 `test/dng_preview_extractor_test.dart:158-163` 失敗，而該檔一字不可改。程式碼裡已有註解說明，不要「順手整理」。

---

## 7. 已完成事項

| 結果 | 改動／產物 | 驗證 | 版本錨點 |
|---|---|---|---|
| [C] 抽取器改 byte-range 讀取 | `lib/services/dng_preview_extractor.dart` | 25 MB 無預覽 DNG 取 orientation 只讀 **8,192 bytes**（舊路讀全檔） | `d4c97f5` |
| [C] 依請求尺寸挑候選 | 同上 | `longEdge:200` → 256×171/9,525 bytes；`longEdge:2800` 與舊行為在 **14/14** 樣本 byte-identical | `d4c97f5` |
| [C] orientation 語意拆分 | 同上 `:109`,`:146`,`:187`,`:206` | 兩個 mutant 各被 5／4 條斷言殺死；還原前後 hash 相同 | `d4c97f5` |
| [C] 合併進 main 並通過合併後閘 | — | main 上 `flutter test -j 1` → `+188`，`flutter analyze` → clean | `40dc5fc` |
| [C] 測試基線帳 | `test/dng_preview_extractor_m0_test.dart`（26 tests） | 162（`48bb934`）→ 188，差額 26 恰等於新增數 | `40dc5fc` |
| [C] 兩輪獨立複驗皆 CONFIRMED | `docs/logs/2026-08-23/round-1-m0-independent-review.md`（175 行）／`round-1-ac11-independent-review.md`（238 行） | 合計 1,074 個敵意輸入，0 例外、0 分歧 | `40dc5fc` |

---

## 8. 待解議題

| 優先 | 狀態 | 議題／缺口 | 解除條件 | 下一動作 | 完成條件 |
|---|---|---|---|---|---|
| **P0** | [ ] | **M1：側欄解碼上限** | — | 在 `sidebar_view.dart:273` 的 `Image.memory` 加解碼期尺寸限制，尺寸 `32 × devicePixelRatio` | ①解碼後最長邊 ≤ `32×dpr + 1` ②**長寬比維持在 1% 內** ③`flutter analyze` 0 issues ④全套綠且測試數 = 188 + 新增數 |
| **P1** | [D] | **F3 必須在 M3 開工前裁決**：in-memory API 現在回傳 `sublistView`（view）而非 `sublist`（copy），會釘住整份來源 DNG buffer | 使用者裁決：修或不修 | 觸發條件是「有呼叫端快取回傳的 `Uint8List`」，M1 不觸發，**M3 會** | 已裁決並落檔 |
| **P2** | [ ] | M2：把來源選擇搬進 `photo_source.dart`，控制器不動 | M1 完成 | 見必讀 1 §6 M2 | 全套測試不改即通過；`grep -c "\.dng\|isRaw" lib/services/image_preload_controller.dart` == 0 |
| **P3** | [ ] | M3：probe + 成本閘 + 統一快取 + DELETE 區塊 | M2 完成、F3 已裁決 | 見必讀 1 §6 M3 | 見必讀 1 §6 M3 逐條 |
| **P4** | [ ] | M4／M5／M6 | 依序 | 見必讀 1 §6 | 見必讀 1 §6 |
| **P4** | [D] | `image-pipeline-redesign-handover.md` 未進版控 | 使用者決定是否 commit | 這是整條線的設計權威，遺失即失去 D1–D6 裁決紀錄 | 已 commit 或明確決定不 commit |

---

## 9. 嘗試、裁決與禁止重踩

| 嘗試／方案 | 結果 | 被否證假設／裁決理由 | 是否可重試 | 證據 |
|---|---|---|---|---|
| 契約宣稱刪掉 `readOrientationFromFile` 後「其職責由 `DngEmbeddedJpeg.orientation` 涵蓋」 | **假前提** | 無預覽的 DNG 抽取回 `null`，根本沒有 orientation。撐過 4 次閱讀與一整套全綠 battery，被獨立複驗抓到 | 否 | `round-1-m0-independent-review.md` F1 |
| 用「有無預覽」描述驗收缺口 | 錯誤的軸 | `readOrientation` 沒有任何與預覽相關的分支。真正的軸是檔案大小／IFD0 位置；兩者在樣本集裡碰巧共變 | 否 | `dng_preview_extractor.dart:109-121` |
| 宣稱「永遠回 1 的 mutant 在舊簽章下通過全部閘門」 | **講過頭** | AC11a 一直抓得到它。真正溜過去的是「大檔就放棄」那個 mutant | 否 | `ac11e-2-red.log` |
| N2（orientation 值不做 1..8 範圍檢查）、N3（重複走訪 IFD0） | **使用者裁決刪除** | 不是 parked，不是技術債，不要再提出 | 否 | 本次 session 使用者裁決 |
| 在 worktree 裡跑 `rm -rf` 後才確認歸屬 | 刪掉了 orchestrator 的驗證樹 | 只因為刪的是衍生產物才零成本；規矩是「先列出目標並確認是自己的，再遞迴刪除」 | 否 | `halcyon-m0-red` 的損壞 gitdir |

---

## 10. 未來方向（不阻塞當前交付）

- F2（人造 5,000 SubIFD 檔造成 199% I/O 放大）、F4（零長度 strip 的行為與舊版不同）、F5、F6：全部 parked，重現步驟在兩份複驗報告內。**觸發條件**：只有在真實檔案出現該形狀、或 M3 的成本模型需要它時才值得動。
- 補一個中間尺寸預覽的樣本進 fixture：目前 14 個樣本只有 256/1024/6000 三種候選，`longEdge` 落在 (1024, 6000) 的選擇邏輯沒有樣本能驗。**觸發條件**：M2 或 M3 改動選擇器時。

---

## 11. 已知限制與不確定性

**已知限制（皆已驗證為真，非推測）**
- 尺寸選擇器目前只被 **1 條**斷言真正守住（AC2，單一樣本、單一 `longEdge` 值）。AC3 分不出「最小的 ≥」與「最大的」，因為沒有樣本帶介於 2800 與全尺寸之間的候選；AC4 的預算由選中候選推算、會自我縮放，同樣分不出。
- 「有尺寸請求 ＋ 檔案缺 `DefaultCropSize`(0xC620)」這條分支沒有任何斷言覆蓋，14 個樣本全都帶該 tag。行為是刻意的（該 tag 只服務全尺寸請求的 0.90 門檻），但只有推理支撐。
- `readOrientation` 在 14 個樣本上都只花一頁（8,192 bytes），但這部分是語料性質——所有樣本的 IFD0 都落在第一頁內。IFD0 位置很深的 DNG 會花兩頁，仍在預算內但未經真實檔案確認。

**未驗證**
- 冷快取下的 I/O 差距（複驗者無 root，無法清 page cache）。暖快取實測 36×，冷快取只會更大，但未量測。
- 任何 Windows 端行為。M0 沒有接線任何東西：`grep -rn readOrientation lib/` 在抽取器之外只有一處註解命中。**AC11 全綠不等於 Windows EXIF 已修好。**

**需使用者決策**
- P1（F3）與 P4（設計文件是否進版控），見 §8。

---

## 12. 驗收命令

```bash
# 1. 版本與樹狀態
git log --oneline -1                 # 預期 40dc5fc
git status --short -- lib test       # 預期無輸出

# 2. M0 成果仍在樹上（內容標記，不看 commit message）
grep -c "readAsBytes()" lib/services/dng_preview_extractor.dart          # 預期 0
grep -c "static Future<int?> readOrientation" lib/services/dng_preview_extractor.dart  # 預期 1
git diff 48bb934 -- test/dng_preview_extractor_test.dart | wc -l         # 預期 0

# 3. 全套
flutter analyze                      # 預期 No issues found!
flutter test -j 1                    # 預期 +188: All tests passed!

# 4. M1 完成後另加
flutter test -j 1 test/sidebar_view_test.dart
```

---

## 13. 參考入口

- **必讀 1**：`docs/logs/2026-08-23/image-pipeline-redesign-handover.md` — M0–M6 的設計權威與使用者裁決 D1–D6。**未進版控，見 §8 P4。**
- **必讀 2**：`docs/logs/2026-08-23/round-1-m0-handoff.md` — M0 的五條結構性發現。M1 的驗收條件要照這五條設計。
- **必讀 3**：`docs/logs/2026-08-23/round-1-m0-contract.md` — 凍結契約與其修訂史（含那個假前提如何被發現）。
- Artifact：`docs/logs/2026-08-23/round-1-m0-independent-review.md`（175 行）／`round-1-ac11-independent-review.md`（238 行）— F2–F6 的重現步驟只存在於此。
- Artifact：`scripts/tmp/verify/` — 本輪全部 battery／mutation 原始輸出。**scratch 車道，跨 session 不保證存在。**
- 專案 SOP：`rule.md`、`memory.md`（AD-010/AD-011 待 M6 修訂）、`unit_test.md`（M0 的 26 條測試尚未登錄進測試矩陣）。

---

## 14. 這一輪最該帶走的一條

五個結構性缺陷全部不是被紅燈抓到的，而是靠問「**如果底下那東西壞了，綠燈會長成什麼樣？**」找出來的。壞掉的驗收條件唯一的特徵，就是它看起來跟正常的一模一樣。

其中最尖銳的一句來自實作者本人：**「手上有證據，不等於證據被拿出來用。」** 它跑過那份 log、在自己的報告裡引用過那份 log，兩輪之後假宣稱繞回來時仍然沒有連上——squad lead 沒有，我也沒有。這是唯一一個熬過本輪所有流程的失敗模式，因為它不長得像一個缺少的檢查，它長得像一個已經通過的檢查。
