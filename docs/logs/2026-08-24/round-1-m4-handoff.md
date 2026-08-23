# Round 1 (M4 — 排程統一) 交接

> **建立**：2026-08-24，m4-lead-opus（Round 1 squad lead）
> **分支**：`m4-sched`（自 `main` @ `b3b0ddd` 切出）｜**tip**：`611877f`
> **契約**：`docs/logs/2026-08-24/m4-m6-convergence-contract.md`（凍結，AC4 已由使用者修訂）
> **基線登錄**：`docs/logs/2026-08-24/baseline-registry.md`（主樹，指揮官持有）
> **寫作對象**：零脈絡的下一輪。假設你沒讀過本輪任何過程紀錄。

---

## 0. 六十秒速讀

- **AC1、AC2、AC3、AC5、AC6、AC7 全過**，證據逐條在檔、由 lead 親自複驗而非採信回報。
- **AC4 已由使用者於 2026-08-24 簽收**（使用者行使其對 UI 量測的所有權；簽收依據是使用者自身判斷，**不是新增的證據**）。基線腿（兩個資料集、兩個模式）做完並登錄；after 腿**從未執行**。
- **因此：目前不存在任何 agent 驗證過的「M4 沒有讓 JPEG 切換變慢」的主張。** 這是本輪最重要的一句話，別在下一輪把它讀成已驗證。
- 尚未合併回 `main`——合併由指揮官執行，合併後 `main` 上重跑全套（AC12）仍是獨立閘門。

---

## 1. AC 逐條結果

| AC | 結果 | 證據 |
|---|---|---|
| AC1 縮圖永久失敗只請求一次 | **PASS** | TC-100，red 三次呼叫 → green 一次 |
| AC2 preview 路徑 generation guard | **PASS** | TC-101，stale resume 不再搶走 tier-2 排程 |
| AC3 步驟 3b fallback 寫入 permanent-miss | **PASS** | TC-102／TC-103，red 由變異取得後還原 |
| AC4 JPEG 切換延遲 A/B | **使用者簽收**（2026-08-24；使用者自有量測，無 agent 驗證主張——見契約與 §4.1） | 基線在檔；after 腿未執行 |
| AC5 analyze 0＋全套綠＋執行數 | **PASS** | 242 執行（238＋4）、0 skip、`TEST_RC=0` |
| AC6 三個凍結閘門 sha256 不變 | **PASS** | 三值與開輪紀錄逐字元相同 |
| AC7 D4 型別盲 grep == 0 | **PASS** | count=0，lead 於 HEAD 自行重跑 |

### 通過的新測試（`test/image_preload_scheduling_m4_test.dart`）
- `M4-AC1 a permanently failing sidebar thumbnail is requested EXACTLY ONCE across three preloadThumbnails sweeps`
- `M4-AC2 a stale preloadImages resume must not reschedule tier-2 for the window it started with (invariant I4)`
- `M4-AC3 step-3b failure inside PhotoSource.load reports a NON-deferred null payload -- the signal the caller turns into a permanent miss`
- `M4-AC3 the step-3b failure path marks a permanent miss and RELEASES the view from its spinner (invariant T1)`

矩陣登錄於 `unit_test.md` TC-100..TC-103。

---

## 2. 完成的工作與 commit

| commit | 內容 |
|---|---|
| `a1a82df` | `feat(preload)`：permanent-miss 集合擴及側欄；preview 路徑 generation guard；4 個新測試 |
| `9267fd2` | `test(pipeline)`：測試檔改名至約定路徑＋`unit_test.md` TC-100..TC-103 |
| `611877f` | `docs(perf)`：`lib/perf/perf_driver.dart`／`perf_log.dart` 加上「agent 禁用 UI 量測」棄用標頭（指揮官提交，純註解） |

### 程式碼改動實質（`lib/services/image_preload_controller.dart`，唯一改動的生產檔）
- `:137` 共用 `_permanentMisses`；`:891` 側欄跳過檢查；`:916` 非 bytes 結果寫入。
- `:167` 新增 `_previewGeneration`，於 `preloadImages`（`:301`）與 `reset()`（`:257`）遞增，兩個 await 之後各檢查一次（`:305-311`、`:371-377`）。
- `photo_source.dart` **完全未動**（對 `b3b0ddd` diff 為空）——AC3 本來就成立，沒有為了湊驗收而捏造改動。

---

## 3. 下一輪依賴的介面契約（M6 動手前必讀）

1. **側欄與預覽各有自己的 permanent-miss 集合——這是修正後的形態，不要合併回一個。**
   - 預覽：`_permanentMisses`（`:129`），只由預覽路徑以**裸 id** 讀寫（`:227` `hasFailed`、`:577`、`:679`、`:685`）。
   - 側欄：`_thumbPermanentMisses`（`:149`），只由側欄以**裸 id** 讀寫（`:906`、`:931`）。
   - `reset()` 兩個都清（`:275-276`）——「問一次、記到重載為止」的**政策**是共用的（不變式 I8），**容器不是**。
   - **禁止用前綴／哨符把兩者塞回同一個 Set。** id 空間是使用者控制的檔名，任何 in-band 前綴只是把碰撞搬家。

   > **本輪 review 推翻的錯誤主張（保留原文以警示）**：本檔初版宣稱側欄用 `thumb_<id>` 鍵、預覽用裸 id，兩者「不相交」，並稱已驗證。**該主張是錯的，已被 reviewer 以反例推翻。** `PhotoItem.id` 是 `basenameWithoutExtension`（`supported_photo_formats.dart:44`，於 `photo_library_scanner.dart:23` 當分組鍵），因此同時含 `IMG_01.jpg` 與 `thumb_IMG_01.jpg` 的資料夾會讓「`IMG_01` 的側欄鍵」與「`thumb_IMG_01` 的預覽鍵」變成同一個字串——側欄縮圖失敗會把 `thumb_IMG_01.jpg` 永久標成不可讀直到重載。
   > **錯在哪裡值得記住**：當時驗證的是「兩條程式路徑使用不同的鍵形式」，然後把它當成「鍵集合不相交」。後者要成立必須是「沒有任何合法 id 會等於 `thumb_` ＋另一個合法 id」，而 id 是使用者控制的檔名。**驗證了機制，卻誤以為驗證了主張。** 修正後兩個集合是**由構造而不相交**，不再依賴任何關於鍵形狀的論證。

2. **`_previewGeneration` 與 `_thumbBatchGeneration` 是兩個計數器，不可合併。** 前者管預覽路徑，後者管側欄批次。
3. **AD-018／AD-019 紅線未變**：`kTierTwoRadius`(2) 與 `kExpensiveStartupRadius`(1) 仍分列於 `prefetch_scheduler.dart:12`／`:32`，不得合併；768 MiB 與 224 MiB 出自相反樣本組，不得互驗。
4. **D4 型別盲**：`photo_payload_cache.dart` 的 `EncodedPayload|PixelPayload` grep 必須維持 0。
5. **`PhotoSource.probe()`（`photo_source.dart:301`）零呼叫點投影原樣保留**，它讓 hash 凍結的測試檔能繼續編譯。

---

## 4. 已知限制（明確列出，不藏）

### 4.1 AC4：使用者 2026-08-24 修訂並簽收 —— 最重要的一條

> **簽收狀態**：AC4 已由使用者簽收（2026-08-24）。簽收的依據是使用者對 UI 量測的所有權與其自身判斷，**不是本輪新增的任何量測證據**。以下事實記錄不因簽收而改變——簽收是疊加在事實之上，不是取代事實。
UI 切換延遲與記憶體／RSS 量測**改由使用者親自執行**；agent 不得執行 UI 驅動量測（`perf_driver` UI 切換、RSS 掃描），僅允許純 headless 解碼命令基準。AC11（M6 輪）同樣修訂。

具體後果，請逐字讀：
- **M4 的 after 腿從未執行**。沒有建過 M4 binary，沒有跑過任何 M4 的 PerfDriver。
- **因此不存在任何 agent 驗證過的「M4 不使 JPEG 切換退步」的證據。** 六條 AC 綠燈不構成這個結論。
- 依程式碼推理，M4 每次導航新增的成本是：側欄迴圈一次記憶體 Set 查找、`preloadImages` 兩次整數比較。無新 IO、無新 channel 呼叫、無常數改動。**這是推理，不是量測**，不要當成量測引用。
- **拒絕以 headless 解碼基準替代**：AC4 的量測對象是 `selectItem.enter`→`image.painted`，橫跨排程、預載視窗、debounce、precache 與實際 paint；CLI 解碼基準只量吞吐量。那會是一個「對另一個問題精確正確」的數字，掛在 AC4 標題下被未來 session 讀成「已證明不退步」。**沒有數字好過誤導的數字。**

### 4.2 AC4 基線的採樣數之爭（已裁決，記錄經過以防重演）
**結論先講：基線登錄檔與本檔一致，採 n=12（原始已登錄遍歷數）。** 下表即定版值：

| 資料集／模式 | 中位數 | 門檻 |
|---|---|---|
| A paced（字面 JPEG） | 3.928 ms | ≤ 6.013 ms |
| A rapid | 3.270 ms | ≤ 59.024 ms |
| B paced（便宜 DNG） | 4.264 ms | ≤ 5.949 ms |
| B rapid | 7.987 ms | ≤ 55.086 ms |

判準：`band_mode = max(p95_mode - median_mode, 1.5ms)`；`PASS_mode iff after_median_mode <= baseline_median_mode + band_mode`；paced／rapid 永不合池；**四格全過才算 AC4 通過**。
出處：`tmp/verify/baseline_permode_final.stats.txt`。同一顆 leg-A binary、錨點 `b3b0ddd`、無 rebuild、baseline 樹無原始碼改動（由量測成員書面確認）。

**經過（值得記住的部分不是數字，是流程如何差點失守）**：lead 先下 n≥36 加樣令 → 使用者建立基線登錄檔並禁止重量已登錄基線 → lead 撤回加樣令 → 撤回與執行在途交錯，成員已完成 n=36 → 成員依登錄檔規則改以原始遍歷數重算 n=12 → 指揮官在收到 lead 撤回前一度採納 n=36 並改寫登錄檔 → lead 主動回報該筆採納已被自己的撤回作廢 → 指揮官撤銷 n=36，登錄檔改回 n=12。
n≥36 的 uplift 產物（`baseline_dngB_run2/3`、`baseline_jpgA_run3-6`、`baseline_permode.stats.txt`）**保留在磁碟並標記為 out-of-scope，未刪除**——刪掉的資料無法稽核。

**教訓**：本輪沒有任何一方隱瞞或取巧，數字之爭純由訊息交錯造成；能收斂是因為每一步都往上報而不是默默採用較好看的那組。跨 agent 的規則變更要當成有延遲的分散式狀態處理：下了指令不代表對方收到，**收到回報時先確認對方基於哪一版指令行動**。

### 4.3 量測靈敏度：`rapid` 模式是粗閘
`paced` 是承重閘門（約 2.8ms 帶寬 vs 約 3ms 中位數，靈敏）。`rapid` 的 55–60ms 帶寬**是該模式的固有性質**——刻意跑贏預載器本來就會產生偶發的即時解碼，那個離散度是工作負載的真實訊號而非量測噪音。**`rapid` 通過只代表沒有嚴重退步，不是強證據。** 本輪未為 `rapid` 發明更緊的統計量：一個沒有在已知好／已知壞版本上驗證過的統計量，比一個誠實標註為粗糙的統計量更糟。

### 4.4 量測規則本身在本輪被修過一次（記錄以防重蹈）
最初的預註冊用 `max(p95 - median, 5.0)` 當噪音帶，且把 `paced` 與 `rapid` 合池。合池後 B 的帶寬是 42.414ms、中位數 4.264ms——**該規則會把十倍的退步簽成「無退步」**。修正為逐模式分離、各自用自己的離散度、下限 1.5ms。修正發生在 after 數字存在之前，屬合法預註冊，已於量測文件記為 amendment。

### 4.5 其他
- **AC5 的 242 執行數在 `9267fd2` 與 tip `611877f` 皆驗過**（`611877f` 為純註解 commit，但仍實跑一次，因為「註解不會壞事」是合理預期而非證據，且 `flutter analyze` 確實會解析那兩個檔）。
- 樣本閘門測試確實執行（`TC-089 real preview-bearing DNG content probe`、`photo_source_test: sample directory has both required fixtures` 皆按名出現），非 skip 偽裝成 pass。

---

## 5. 基線升格（Round 2 據此，不重跑相同基線）

**新錨點：`m4-sched` @ `611877f`**（合併後改為 `main` 的合併 commit）。

| 項目 | 值 | artifact |
|---|---|---|
| `flutter analyze` | 0 issues，`ANALYZE_RC=0` | `tmp/verify/ac5-m4-20260823T164156Z.txt`（@9267fd2）＋ tip 複驗 |
| `flutter test -j 1` | `TEST_RC=0`，**EXECUTED=242 / SKIPPED=0** | 同上 |
| 凍結閘門 sha256 | 三值不變（同登錄檔） | 同上 |
| JPEG 切換延遲 | **無 after 數字**——使用者自量後才可升格 | 基線見登錄檔 |
| 峰值 RSS | **本輪未量**（AC4 修訂連帶） | — |

**M6（Round 2）的 AC11 因此縮減**：agent 可交付的是全套測試綠與 headless 解碼基準；`flutter run -d macos` 走 26 個正典樣本與效能基準重跑屬 UI／記憶體範疇，**由使用者執行**。M6 開工前請先向使用者確認這部分怎麼安排，不要自行代跑。

---

## 6. 使用者自量 after 腿的操作配方（turnkey）

前置：`m4-sched` @ `611877f`（或合併後的 `main`）。

**1）建 binary**（與基線同一命令，A/B 才成立）
```
cd /Users/jhangyu/project/halcyon-m4
flutter build macos --release; RC=$?; echo "BUILD_RC=$RC"
```
> 基線腿用的是 `flutter build macos --release` 而非 `scripts/build_apps.py`（lead 核准的偏離，理由：本量測完全不碰 native RAW 解碼路徑，而 A/B 有效性取決於兩腿建置方式相同）。**after 腿必須沿用同一命令。**

**2）備資料集**（必須是**實體檔案複本**，不可用 symlink）
> `PhotoLibraryScanner.scan()` 用 `dir.list(followLinks:false)`（`photo_library_scanner.dart:8`），symlink 目錄會被掃成 `items=0`，安靜地量出空結果。
- 資料集 A（字面 JPEG，7 檔）：複製 `local_data/photo_samples/JPG/*.jpg`
- 資料集 B（便宜 DNG，13 檔）：複製 `2026-*` 系列
- macOS 沙箱：路徑須在容器內，基線用的是 `~/Library/Containers/com.jhangyu.halcyon/Data/perf/<name>`

**3）跑**（每個資料集各一次；A 因只有 6 switch/pass，基線是跑兩次併池）
```
HALCYON_PERF_DIR=<資料集路徑> \
HALCYON_PERF_OUT=<輸出log路徑> \
HALCYON_PERF_MODE=both \
HALCYON_PERF_N=<A用6，B用12> \
HALCYON_PERF_PACE=1200 \
open -W build/macos/Build/Products/Release/Halcyon.app
```
環境變數定義在 `lib/perf/perf_driver.dart:20-24`；未設 `HALCYON_PERF_DIR` 時整個 harness 是結構性 no-op。

**4）驗與解析**
```
python3 scripts/tmp/perf/validate_run.py <log> --expect-mode release --min-switches 5
python3 scripts/tmp/perf/parse_r2.py <log>
```
任何 `switch.timeout`／`burst.timeout` 使該腿作廢。

**5）判讀**（逐模式，不合池）
`band_mode = max(p95_mode - median_mode, 1.5ms)`；`PASS_mode iff after_median_mode <= baseline_median_mode + band_mode`。**四格（2 資料集 × 2 模式）全過才算 AC4 通過。** 基線值見基線登錄檔。
懷疑觸發條件：任一格改善 >15%（M4 只動排程，不是解碼優化——大幅改善先懷疑 binary 過期或量錯），或中位數差距 <0.5ms 的過度整齊打平。觸發時先重驗 binary 來源，再談程式碼。

---

## 7. Parking lot（本輪未做，逐項附「若永不落地，終態是否仍可達」）

| # | 項目 | 若永不落地？ |
|---|---|---|
| PL-1 | 側欄縮圖 sweep 全無 `try`/`catch`（`image_preload_controller.dart:800-925`）。loader 若**拋例外**而非回傳非 bytes，`_loadingKeys.remove` 與 `_permanentMisses.add` 都不會執行，例外逸出 for 迴圈使該次 sweep 其餘縮圖全部不被請求。**`b3b0ddd` 即已存在，非本輪引入。** AC1 的不變式目前靠洩漏的 `_loadingKeys` 條目「意外地」仍成立 | 終態仍可達。但這是**潛伏**而非死碼——見下 |
| PL-2 | 「不會拋」的保證來自**目前實作**而非契約：生產 loader `NativeThumbnailService.requestImage` 把 `PlatformException` 與 `MissingPluginException` 都轉成回傳值（`native_thumbnail_service.dart:124-146`），但 seam 是裸 typedef（`image_preload_controller.dart:17-21`）無 no-throw 條款，任何注入的 fake 或未來非 macOS bridge 都可能拋；且 `requestImage` 內 `Uint8List?` 綁定（`:117`）在 native 回傳非 `Uint8List` 時會拋未捕獲的 `TypeError` | 終態仍可達，但 **Windows／Android bridge 落地時這條會醒過來**。移植前先處理 |
| PL-3 | `unit_test.md` 矩陣漂移：矩陣只到 TC-057，測試名稱早已用到 TC-099。本輪新增用 TC-100..TC-103 避開碰撞，未回填缺口 | 終態可達，純文件債 |
| PL-4 | AC4 樣本數受登錄檔「禁止重量」規則限制為 n=12/模式（見 §4.2） | 終態可達 |
| PL-5 | 契約既有緩議項未動：M5、P-1（便宜組 RSS）、P-2（應用內版本戳記）、P-3、P-4、[U-2]/[U-4]/[U-6]/[U-7] | 見設計權威 |

> **P-2（應用內版本戳記）值得特別提醒下一輪**：它現在更重要而非更不重要。使用者接手 UI 量測後，「這顆 binary 是哪份程式碼」的保證從 agent 的建置事件紀錄變成使用者的記憶。在便宜樣本組上，過期 binary 產生**偏低**數字，讀起來像好消息，沒有任何規則會觸發。

---

## 8. 給下一輪的注意事項

1. **M6 可以開工了**（M4 全綠是它的前置，本輪已達成——AC4 的改派不構成阻擋，因為它已不是 agent 閘門）。動手前讀交接 §3 兩顆地雷：`isRaw` 分支禁刪、`PhotoSource.probe()` 禁清。
2. **合併後在 `main` 上重跑全套是獨立閘門（AC12）**，分支內全綠證明不了跨分支組合。本輪 tip `611877f` 的 242/0-skip 不能替代它。
3. **本輪四個真實缺陷全部出在儀器，不是程式碼**：detached 執行沒有可捕捉的 exit code；驗收條件被窄化成較方便的資料集；symlink 資料集被掃成 `items=0`；噪音帶無法偵測十倍退步。程式碼每次首檢都是乾淨的。下一輪把稽核力氣放在量測與驗收的定義上，不要只審 diff。
4. **收件先驗儀器**：本輪每一個「否定結果」與每一個「漂亮數字」都先當儀器問題查一次，四次全中。

---

## 9. Review 循環紀錄（cycle 1／上限 2）

**裁決：REFUTED，一個 BLOCKER。**

| 項目 | 內容 |
|---|---|
| 發現 | 側欄 `thumb_<id>` 鍵與預覽裸 id 鍵共用 `_permanentMisses` 而**不相交**；含 `IMG_01.jpg` ＋ `thumb_IMG_01.jpg` 的資料夾會讓側欄失敗污染預覽狀態，該照片永久不可讀直到重載。**本輪引入**（`b3b0ddd` 時沒有任何 `thumb_` 鍵寫入該集合） |
| reviewer 證據 | `tmp/verify/reviewer_namespace_collision_test.dart`（RC=1） |
| 修正 commit | `2476896` — 側欄改用自己的 `_thumbPermanentMisses`，兩集合皆以裸 id 操作，`reset()` 兩者都清 |
| 交付回歸測試 | `M4-AC1b`（實作者獨立撰寫，未開啟 reviewer 的探針檔）。RED：`tmp/verify/20260824-impl-collision-red.txt`（`+4 -1`，RC=1，**該次執行中唯一失敗的就是新測試**，其餘四個同時綠——證明失敗來自反例而非環境）。GREEN：`tmp/verify/20260824-impl-collision-green.txt`（`+5`，RC=0） |
| 修正後全套 | 243 執行（242＋1）、0 skip、`TEST_RC=0`；`flutter analyze` 0 issues；AC6 三雜湊不變；AC7 count=0。lead 複驗紀錄：`tmp/verify/lead-fixcycle1-verify.txt` |

**§3.1 的原主張已更正**（見該節內的警示框），不是抹掉重寫——錯誤的推理過程比結論更值得留給下一輪。

### 本輪新增 parking-lot（reviewer 提出＋修正過程發現，一律未動）
| # | 項目 | 級別 |
|---|---|---|
| PL-6 | 暫時性縮圖失敗現在會被記成「永久到重載為止」——相對 `b3b0ddd` 是行為損失，但超出 AC1 定義範圍 | should-fix |
| PL-7 | AC2 的第二道 guard 沒有交付測試（reviewer 自己的探針顯示 guard 本身正確） | should-fix |
| PL-8 | TC-100 編號與 `image_preload_window_test.dart:335`（AD-018/AD-019 killer test）撞號 | nit |
| PL-9 | 部分 red artifact 缺 provenance 行 | nit |
| PL-10 | `_loadingKeys` 有**同型**命名空間混用（裸 id 於 `:346/:569/:623/:696`，`thumb_$id` 於 `:890/:898/:906`），**`b3b0ddd` 即存在**。爆炸半徑小得多：條目在同一趟被移除，碰撞只造成下一次 sweep 會修正的暫時跳過。**但實作者補充的細節值得注意**——側欄的移除**不在 `finally` 裡**（`:908`），若該 loader 曾拋出，其 `thumb_<id>` 條目會洩漏整個 session，碰撞受害者的預覽會被當成「載入中」跳過一整個 session。這是 PL-1／PL-2 的潛伏拋出洞與本條疊加的結果 | should-fix（疊加後升級） |
