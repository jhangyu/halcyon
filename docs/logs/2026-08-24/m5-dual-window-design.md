# M5 雙窗設計 — 現況查證與 RAW 全解析度 tier-2 架構規劃

> **建立**：2026-08-24，m5-plan-2-fable（架構規劃，唯讀查證，未寫任何程式碼）
> **查證錨點**：`main` @ `2a15d74`（M4 round-1 合併後）
> **契約效力**：依 `docs/logs/2026-08-24/m4-m6-convergence-contract.md`「M5 契約條款」，本檔「§2 M5 設計」與「§3 建議驗收條件」於交付後即為 M5 凍結契約條款；「§4 開放問題」須使用者逐項裁決後方可凍結。
> **設計權威**：`docs/logs/2026-08-23/image-pipeline-redesign-handover.md`（§3、§4 不變式 I1–I8、§12.1 凍結修訂）。
> **尺寸推算依據**：`docs/logs/2026-08-23/cache-sizing-estimate.md`（§A.2–A.6）。

---

## 1. 現況查證

### 1.1 三個視窗、三個快取層（先立座標）

| 視窗 | 常數 | 值 | 出處 |
|---|---|---|---|
| Payload 保留視窗 | `kRetentionBefore`／`kRetentionAfter` | −3..+5 | `lib/services/photo_payload_cache.dart:6,:10`；視窗定義 `:129-138` |
| Tier-1（視窗解析度）預解視窗 | 由保留常數導出 | −3..+5 | `lib/services/image_preload_controller.dart:771-778` |
| Tier-2（全尺寸）解碼視窗 | `kTierTwoRadius` | ±2 | `lib/services/prefetch_scheduler.dart:32`；套用於 `image_preload_controller.dart:452-459` |
| 昂貴 RAW 啟動資格 | `kExpensiveStartupRadius` | ±1 | `prefetch_scheduler.dart:12`；閘在 `image_preload_controller.dart:627-634` |

三個快取層：payload 快取（`PhotoPayloadCache`，224 MiB 預算，`photo_payload_cache.dart:31`）、tier-1 ImageCache 項（`_tierOneKeys`）、tier-2 ImageCache 項（`_tierTwoKeys`，獨立 key namespace，`image_preload_controller.dart:96-121`）。ImageCache 總上限 768 MiB（`lib/main.dart:25-28`）。

### 1.2 距離帶 × 快取項表 — 便宜（含內嵌預覽）項目，導航靜止 ≥250 ms 後的穩態

| 距離 | payload 快取項 | tier-1 ImageCache 項（視窗解析度） | tier-2 ImageCache 項（全解析度） | ImageCache 額度 |
|---|---|---|---|---|
| 0 | ✔（cheap rung 全窗預取：`prefetch_scheduler.dart:41-47`；視窗迴圈 `image_preload_controller.dart:383-398`） | ✔（`:766-801`，跨度 −3..+5） | ✔（`:447-504`，跨度 ±2） | **2** |
| ±1 | ✔（同上） | ✔（同上） | ✔（同上） | **2** |
| ±2 | ✔（同上） | ✔（同上） | ✔（同上，`:460-462` 邊界含 ±2） | **2** |
| −3 | ✔（`retentionWindowIds`，`photo_payload_cache.dart:135-137`） | ✔（`:771-778` 跨度含 −3） | ✘（`:498-503` 離開 ±2 即被 stale sweep 驅逐） | **1** |
| +3 | ✔ | ✔ | ✘（同上） | **1** |
| +4 | ✔ | ✔ | ✘ | **1** |
| +5 | ✔ | ✔ | ✘ | **1** |
| ±4 以外（−4/−5、+6…） | ✘（`retainOnly` 掃出，`image_preload_controller.dart:352-354`） | ✘（`:792-800` 驅逐） | ✘（`:352-354` 連動 `_evictTierTwoEntry`） | 0 |

Tier-1 在 ±2 內**不因 tier-2 存在而略過**（`:781-790` 迴圈無 tier-2 檢查；兩 tier key 不同，`cache-sizing-estimate.md` §A.2 Fact 2）——這就是 5 格「共存費」（每格 91.55+18.54 MiB，`cache-sizing-estimate.md:300-307`）。

### 1.3 對照表 — 昂貴（無內嵌預覽 RAW）項目，現況

| 距離 | payload（視窗解析度 `PixelPayload`） | tier-1 | tier-2 全解析度 | ImageCache 額度 |
|---|---|---|---|---|
| 0、±1 | ✔（啟動限 ±1：`image_preload_controller.dart:627-634`＋`prefetch_scheduler.dart:127-128`；經 250 ms debounce 循序佇列 `:524-553`） | ✔ 與 tier-2 **共用同一項**（兩 tier 對 `PixelPayload` 回同一個 `RawPixelsImage`，`:808-828`；key 依 buffer identity，`raw_pixels_image.dart:67-75`） | ✘ **不存在**——所謂 tier-2 就是那個視窗解析度項 | **1** |
| ±2..±3、+4/+5（曾進過 ±1 而保留） | ✔（保留與啟動分離，設計權威 §3.3） | ✔（共用項） | ✘ | **1** |
| ±2..+5（從未進過 ±1） | ✘（AD-018 已知限制：`memory.md:161`，即 P-3） | ✘ | ✘ | 0 |

### 1.4 裁決

1. **雙窗規則對便宜項目「已經成立」**（穩態）。全解析度項只存在於 −2..+2（`kTierTwoRadius` 掃描 `:452-462`），離開 ±2 由 `:498-503` 的 stale sweep 確定性驅逐，−3 與 +3..+5 只剩 tier-1 視窗解析度項（`:766-801`）。**這一半不需要發明工作。**
2. **「每項佔兩個 ImageCache 額度」的 round-1 敘述對全窗而言是錯的**：便宜組九格中只有 −2..+2 的 **5 格**各佔 2 項，−3 與 +3..+5 的 4 格各佔 1 項（合計 14 項，非 18 項）。`memory.md` AD-019（`:167`）「一個 `EncodedPayload` 佔兩個」應讀作**限 ±2 帶內成立**；768 MiB 的推導本來就是按「5×兩項＋4×一項」算的（`cache-sizing-estimate.md:302` 的 626.22 MiB），所以常數無誤，錯的只是那句話的量詞。
3. **兩個有界例外**（穩態之外）：(a) 連續導航期間 debounce 不斷被取消（`:429-432`），stale sweep 不跑，舊 ±2 的 tier-2 項會殘留到「下次 debounce 觸發」或「離開 −3..+5 保留窗」（後者由 `:352-354` 立即驅逐）——殘留有界於保留窗；(b) 冷啟動後、首次 250 ms 靜止前，±2 帶尚無任何 tier-2 項。兩者皆為現行凍結行為，非 M5 要修的對象。
4. **雙窗規則唯一真正破的地方是 RAW**：`PixelPayload` 兩 tier 共用同一個視窗解析度項（`:808-828`），**全解析度層根本不存在**——放大檢視無法超過視窗解析度。這就是 M5 的缺口，也是本設計的全部工作。

---

## 2. M5 設計

**一句話**：為 `PixelPayload` 項目補上真正的全解析度 tier-2 ImageCache 項，限 −2..+2、走既有 250 ms debounce 循序佇列、由既有 tier-2 簿記驅逐；payload 快取、兩個 byte 預算、啟動資格 ±1、便宜路徑**一律不動**。

### 2.1 視窗規則（沿用，不新增常數)

RAW 全解析度視窗**就是既有的 `kTierTwoRadius`（±2）**，不新增第三個半徑常數。AD-018 的兩常數分立原樣保留：±1 仍只管「payload 生產（FFI 解碼）啟動資格」（`prefetch_scheduler.dart:12,:127-128`），±2 管「全尺寸解碼視窗」（`:32`）——M5 只是讓 ±2 這個語意對 `PixelPayload` 也兌現。

**從未進過 ±1 的昂貴項目維持兩層皆空**（P-3 現況，AD-018 已知限制）：全解析度升級**只消費既有 payload，從不生產 payload**——`_decodeTierTwoWindow` 對 `payload == null` 的項目仍走 `_enqueueTierTwoLoad`（`:465-485`），距離 2 者仍被 `allowsExpensiveWork` 拒絕（`:627-634`）。這保住 `test/image_preload_window_test.dart` 的 AD-018 killer test。

### 2.2 生產路徑：單次解碼、雙輸出（凍結測試強迫的設計，非偏好)

昂貴項目的 payload 生產本來就發生在 debounce 後的循序佇列（`:524-553` → `loadExpensive`，`photo_source.dart:190-225`），解碼器回傳的是**全解析度** RGBA（`decoded_rgba_image_provider.dart:84-87`），現在被 `decodedRgbaToPixelPayload` 縮成視窗解析度後丟棄。M5 改為**同一次解碼產出兩份**：

1. 視窗解析度 `PixelPayload` → 進 payload 快取（與今日逐位元相同的保留行為）。
2. 全解析度、已套 orientation 的像素 → **直接上傳 ImageCache 成為 tier-2 項，緩衝即棄**（見 §2.3）。全解析度縮放路徑已存在：`decodedRgbaToPixelPayload` 的 `longEdge <= 0` 即不縮放（`decoded_rgba_image_provider.dart:107-109`）。

**為什麼必須 piggyback 而不是事後補一次解碼**：hash 凍結的 `test/dng_nav_probe_m3_test.dart` P3/P4（`:285-327`、`:329-365`）斷言昂貴項目在 8→9→8 與 8→9→10→9→8 導航（每步等 350 ms，debounce 每次觸發，全程不離 ±2）後 `decoder 呼叫次數 == 1`。若全解析度靠第二次 `decoder(path)` 取得，次數變 2，凍結閘直接紅。單次解碼雙輸出之下 P3/P4 維持綠（已逐段核對：P1 的 `currentSize == 9`／`== 0` 斷言皆在 debounce 觸發**前**量測，`:93-130`，不受 M5 影響）。

**補升級路徑**（piggyback 之外唯一的全解析度生產點）：對「已有 payload、在 ±2 內、尚無有效 tier-2 項」的 `PixelPayload` 項目（滑窗進入距離 2 者、離窗回窗者），`_decodeTierTwoWindow` 的 `payload != null` 分支（`:487-495`）按 payload 種類分流——`EncodedPayload` 照舊同步解碼（今日行為，`:495`）；`PixelPayload` 改為 enqueue 到**同一條** `_tierTwoQueue` 循序執行：`decoder(path)` 一次 → 全解析度 orientation 套用（orientation 取自 `_exifOrientations` memo，`:160`，folder 生命週期不失憶）→ 上傳 ImageCache → 丟棄視窗解析度副產物（**不得**替換既有 payload 物件——替換會使 tier-1 key 與 P3/P4 的 `identical` 斷言失效）。佇列既有的 `_tierTwoWindowIds` 再檢查（`:533,:545`）原樣沿用，滑窗後的過期任務自動放棄。

### 2.3 全解析度 provider 與記憶體所有權（本設計最重的一條裁決)

**全解析度像素只活在 ImageCache 裡（`ui.Image`），來源緩衝一律瞬態。** 理由：全解析度 RGBA 約 47.56 MiB（4080×3056，`decoded_rgba_image_provider.dart:19`）至 91.55 MiB（6000×4000，`cache-sizing-estimate.md:293`）。若仿照便宜路徑讓 provider key 保留來源緩衝（`MemoryImage` 模式），每個 ±2 RAW 項常駐成本翻倍（緩衝＋`ui.Image`），24 MP 均勻語料下 5×(91.55×2+22.4)+4×22.4 ≈ 1,117 MiB，**單獨就爆掉 768 MiB**，且 ImageCache 只記帳 `ui.Image` 那一半，LRU 對緩衝無感——RSS 靜默膨脹。便宜路徑無此問題是因為它的 key 保留的是 payload 快取**本來就持有的同一個**壓縮 bytes 物件（`image_preload_controller.dart:44`），零額外副本；RAW 沒有這個免費午餐。

因此新 provider（暫名 `RawFullResImage`，新檔 `lib/services/raw_full_res_image.dart`）規格：

- **Key 語意**：等值判準為「視窗解析度 payload 的 `identical` 識別＋全解析度寬高」，仿 `RawPixelsImage` 的 identity 規則（`raw_pixels_image.dart:67-75`）；**key 內不持有任何大緩衝**。payload 被替換（離保留窗再回來）即天然得到新 key，round-2 BLOCKER 1 的防復活語意原樣成立。
- **影像交付**：解碼完成後由 controller 在**同一個函式本體內**完成「建 provider → resolve → `loadImage` 領取全解析度影像 → ImageCache 接管所有權」；任何提前退出路徑（視窗再檢查失敗、resolve 失敗）就地釋放，**不得**把全解析度影像或緩衝存進任何跨 turn 的欄位。交付後 controller 手上不留 handle——I5「無主 ~50MB 影像」的解除狀態不得回退。
- **view 端取用**：`isFullSizeReady` 的三重合取原樣沿用（`:250-258`），其中 `_tierTwoSources[id]` 登記的是**該次升級所依據的視窗解析度 payload 物件**——`identical(decodedFor, _cache.peek(id))` 檢查因此對 RAW 與 JPEG 同義。view 只在 `containsKey` 為真時選用 tier-2 provider（與便宜路徑同構，`main_detail_view.dart:262-286` 的既有註解邏輯），check 與 resolve 同一同步路徑、無 async 間隙，所以「一次性 provider」不會被要求二次生產；萬一被要求（防禦），回錯誤 stream，由 `:298-299` 的 errorBuilder 兜底，不 crash。
- **view 分支調整**：現行 `decodedProvider` 無條件勝出且被標記為全解析度（`main_detail_view.dart:277-289`）。M5 後：pixel 項目在 `currentItemHasFullSize` 為真時改用 controller 的全解析度 provider（`AppState` 加一個對應 accessor，仿 `app_state.dart:186-187`），否則沿用視窗解析度 `RawPixelsImage`（此後在 perf 標記中誠實地算 tier 1）。

### 2.4 驅逐所有權：確定性視窗為主、LRU 為兜底（與 768 MiB 的共存敘事)

- **誰驅逐**：與今日完全同一套簿記。離開 ±2 → `_decodeTierTwoWindow` 的 stale sweep（`:498-503`）；離開 −3..+5 → `retainOnly` 回傳掃出清單連動 `_evictTierTwoEntry`（`:352-354`）；`reset()`／`dispose()` 全清（`:267-271`、`:295-313`）。RAW 全解析度項進的就是 `_tierTwoKeys` 這套簿記，**不新增第二套驅逐機制**。
- **再進入**：payload 仍在（−3..+5 保留），tier-1 立即命中；全解析度項已被驅逐，於下次 debounce 靜止後由補升級路徑重解一次——代價一次 FFI 解碼（實測 61–406 ms 量級，`photo_source.dart:25`）＋一次 GPU 上傳（18–19.9 ms，`raw_pixels_image.dart:20-22`）。這是雙窗規則的固有代價（`cache-sizing-estimate.md` §A.7 對便宜項同樣成立），期間 view 顯示 tier-1，無 spinner。
- **如何防止「九格全窗 × 兩項」**：全解析度項的存在集合恆等於 `_tierTwoKeys.keys`，而該集合被 `:498-503` 限制在 ±2——−3 與 +3..+5 **由構造**只可能有 tier-1 項。§1.4-3 的連續導航殘留例外對 RAW 同樣有界（保留窗兜底驅逐 `:352-354`）。
- **LRU（768 MiB）的角色是兜底不是機制**：穩態工作集推算（均勻 6000×4000 假設，同 `cache-sizing-estimate.md` §A.4 口徑）——便宜組維持 626.22 MiB 不變；昂貴組從現況 203.19 MiB 變為 5×(91.55+22.4)+4×22.4+1.6 ≈ **660.95 MiB**；套用同一份 15% headroom 政策 660.95×1.15 ≈ 760.1 ≤ 768，**兩個常數皆不需改**（AD-019 的「不可互驗」紅線不觸碰）。以正典昂貴樣本實際尺寸（4080×3056）算則約 441.0 MiB。**此為紙上推算非量測**，實測屬使用者自量（見 §3）。若 LRU 仍在 ±2 內驅逐了全解析度項：`isFullSizeReady` 的 `containsKey` 合取翻 false → view 無縫回落 tier-1，下次 debounce 觸發時補升級——降級路徑與冷啟動路徑同一條，無新狀態。

### 2.5 失敗模式（逐條)

| 情境 | 行為 | 為什麼不退步 |
|---|---|---|
| 全解析度解碼失敗（step-3b 類比） | 保留 tier-1 顯示；**不寫** `_permanentMisses`（該集合語意是「連 payload 都產不出」，`:123-129`）；以「per-payload 識別」memo 失敗，同一 payload 不再重試（防每次 debounce 重試風暴）；payload 被替換後 memo 天然失效可再試 | view 的 spinner 條件（`main_detail_view.dart:235-238`）只看 payload 層，M5 全程不碰 |
| 滑窗重解風暴 | 每次 250 ms 靜止至多升級「±2 內缺 tier-2 的 PixelPayload 項」數（≤5，通常 1–2），循序佇列一次一個，導航中 debounce 取消、佇列內 `_tierTwoWindowIds` 再檢查丟棄過期任務 | 與今日昂貴 payload 生產同一節流結構（D2 的九併發禁令不觸碰） |
| Spinner 回歸 | 結構性不可能：M5 是純升級分支，不動 payload 生產、不動 `_permanentMisses`、不動 T1 的三出口（設計權威 §3.4） | — |
| 升級完成前的空窗 | 顯示 tier-1 視窗解析度（今日的「全部」），`gaplessPlayback` 保持無閃爍（`main_detail_view.dart:296-297`） | 只多不少 |
| 佇列中途 payload 被替換 | `_tierTwoSources` 綁舊 payload → `isFullSizeReady` 的 `identical` 合取為 false，簿記由既有 BLOCKER-1 路徑清理 | 沿用 `:250-258` 既有防護 |

### 2.6 保留的既有不變式（逐條宣告)

- **I1**（bytes/buffer identity 即 key）：兩個新舊 pixel provider 皆 identity 鍵。**I2**（tier key namespace 分立）：RAW 首次真正擁有兩個 namespace。**I3**（tier-2 就緒三重合取）：原樣，且 RAW 不再有共用項造成的「假 tier-2」。**I4**（await 後 generation 再檢查）：升級任務走既有佇列與視窗再檢查。**I5 解除狀態**：不回退，全解析度影像由 ImageCache 擁有。**I6**（每項對原生恰好一次）：piggyback 使升級不加解碼次數；orientation 用 memo 不回頭問 bridge。**I7**（debounce 純效能職責）：不變。**I8**／M4 兩個 permanent-miss 集合與兩個 generation 計數器：不碰。AD-018/AD-019：兩常數對、兩預算對，皆原樣。JPEG／便宜 DNG 路徑：零行為變更（M5 對 `EncodedPayload` 分支逐字保留）。
- 需改動的檔案封閉集合：`image_preload_controller.dart`（tier-2 分流＋簿記）、`photo_source.dart`（`loadExpensive`/`load` 步驟 3 的雙輸出欄位；`SourceOutcome` record 擴欄——**非凍結面**；`NativeImageResult` 三 variant 與 `DngFullDecoder` typedef **不動**，AD-010/011 不觸發）、`raw_full_res_image.dart`（新檔）、`main_detail_view.dart`＋`app_state.dart`（provider 選擇）、測試新檔。**不碰**：`photo_payload_cache.dart`、`prefetch_scheduler.dart`、`raw_pixels_image.dart`、三個凍結測試檔、macOS runner。

### 2.7 與 M6（已擱置）的界線

M5 只按 **payload 種類**（`EncodedPayload`／`PixelPayload`）分流，不感知 bytes 來自哪條通道。M6 若日後刪除 macOS 便宜 DNG 通道（`macos/Runner/DngPreviewExtractor.swift` 的 `extractFullSizeEmbeddedJpeg:49`／`readDngOrientation:23`，呼叫點 `AppDelegate.swift:374,:394`，發射 `:396`），便宜 DNG 必須改由純 Dart 抽取器升為主通道供 bytes（現僅為 native 全敗後的 fallback，`photo_source.dart:317-320`）——**該重接線屬 M6 重訂契約的範圍，明確不在 M5 in-scope**。M5 對 M6 的唯一依賴聲明：「便宜 DNG 持續以 `EncodedPayload` 到達」；只要 M6 維持這一點，兩者互不干涉。

---

## 3. 建議驗收條件（交付後即凍結；標【使用者自量】者 agent 不得執行)

- **AC-M5-1（常數與紅線不動，全部機械 grep）**：
  `grep -c "kExpensiveStartupRadius = 1" lib/services/prefetch_scheduler.dart` == 1；`grep -c "kTierTwoRadius = 2" lib/services/prefetch_scheduler.dart` == 1；`grep -cE "const int k[A-Za-z]*Radius" lib/services/*.dart` 合計 == 2（禁止第三個半徑常數）；`grep -c "EncodedPayload\|PixelPayload" lib/services/photo_payload_cache.dart` == 0；`grep -c "224 \* 1024 \* 1024" lib/services/photo_payload_cache.dart` == 1；`grep -c "768 << 20" lib/main.dart` == 1。
- **AC-M5-2（雙窗覆蓋，全類型）**：新測試檔 `test/image_preload_dual_window_m5_test.dart`，測試名 `M5-DW1 tier-2 keys equal the +/-2 band after settle, for encoded and pixel payloads alike`——經 `@visibleForTesting` 的 tier-2 key id 集合 getter 斷言：靜止後該集合恆等於 ±2 的 id 集合；−3 與 +3..+5 有 tier-1 key、無 tier-2 key。便宜與昂貴兩種 fake 各跑一輪。
- **AC-M5-3（RAW 全解析度真的到位）**：測試名 `M5-DW2 a pixel-backed item at distance 0 gets a FULL-resolution tier-2 entry distinct from its window-resolution tier-1 entry`——fake decoder 回已知尺寸（如 400×300），視窗目標 200×150：tier-2 resolved 影像尺寸 == 400×300，tier-1 == 視窗尺寸，`isFullSizeReady == true`，且兩 key 不相等。
- **AC-M5-4（單次解碼雙輸出）**：測試名 `M5-DW3 payload production and full-res tier-2 for a RAW item inside +/-1 cost exactly ONE decoder call`——decoder 呼叫計數斷言 == 1。
- **AC-M5-5（離窗／回窗）**：測試名 `M5-DW4 leaving +/-2 evicts the full-res entry; re-entering re-upgrades with exactly one extra decoder call and an identical retained payload`——驅逐後 `containsKey == false`；回窗靜止後計數 +1、payload 物件 `identical` 不變。
- **AC-M5-6（升級失敗降級）**：測試名 `M5-DW5 a failing full-res decode keeps tier-1 display, writes NO permanent miss, and is not retried for the same payload`——`hasFailed == false`，兩次 debounce 觸發後失敗 decoder 的全解析度嘗試計數 == 1。
- **AC-M5-7（AD-018 killer 與凍結閘不動）**：`test/image_preload_window_test.dart` 不修改且綠；三個凍結閘 sha256 與 `docs/logs/2026-08-24/baseline-registry.md` 登錄值逐字元相同（`59b1f3c7…`／`fcdd564e…`／`05565d33…`）。
- **AC-M5-8（全套）**：`flutter analyze` 0 issues；`flutter test -j 1` 全綠、0 skip、執行數 ≥ 243＋本輪新增測試數（預註冊執行數；退出碼一律 artifact 內自捕 `$?`）。
- **AC-M5-9（全解析度緩衝不常駐）**：`grep -cE "final +Uint8List" lib/services/raw_full_res_image.dart` == 0（provider 不持大緩衝）；測試名 `M5-DW6 a full-res upgrade adds ZERO bytes to the payload cache`——升級前後 `retainedByteCost` 相等。
- **AC-M5-10【使用者自量】**：昂貴樣本組（13 檔正典）峰值 RSS 與 JPEG 切換延遲四格 A/B（基線見 baseline-registry；判準 `band_mode = max(p95−median, 1.5ms)` 四格全過）。agent 僅得提供 §2.4 的推算值作對照預期（昂貴組 ImageCache 工作集約 441–661 MiB），不得代跑。合併回 `main` 後於 `main` 重跑 AC-M5-7/8 為獨立閘。

---

## 4. 開放問題（未凍結，逐項待使用者裁決)

1. **RAW 全解析度升級半徑**：本設計按使用者雙窗模型取 ±2（與 `kTierTwoRadius` 同一常數）。代價：全昂貴資料夾每次靜止至多 5 個循序全解析度上傳位於佇列中（piggyback 使 ±1 三格免加解碼；距離 2 兩格各需一次補解碼，每次 61–406 ms 量級）。替代案：升級半徑收成 ±1 或僅距離 0（省補解碼，但 ±2 帶 RAW 放大檢視回落視窗解析度）。**預設 ±2，請確認。**
2. **離窗即驅逐 vs. 留給 LRU**：本設計嚴格執行「離開 ±2 即驅逐」（使用者規則的字面義），代價是 3 步以上外出再回來必補一次解碼。替代案：離窗只除簿記、項目留給 768 MiB LRU 自然汰換（省重解，但 −3..+5 可能短暫存在全解析度項，違反嚴格雙窗）。**預設嚴格驅逐，請確認。**
3. **`SourceOutcome` record 擴欄**（`photo_source.dart:37-42`，載明雙輸出欄位）不屬凍結面（凍結的是 `NativeImageResult` 三 variant 與凍結測試檔）——請確認此認定。
4. **佇列內順序**：建議「payload 生產（使用者看得見的空格）優先於全解析度升級；升級按距離 0 → ±1 → ±2」。請確認或指定其他順序。
5. **P-3（從未進 ±1 的昂貴項目遠格兩層皆空）維持原樣**：M5 明確不為 ±1 外的 RAW 新增 payload 生產路徑（AD-018 紅線）。如要處理屬另一契約。
6. **M6 界線**（§2.7）：M5 假設便宜 DNG 持續以 `EncodedPayload` 到達；macOS 通道刪除與 Dart 抽取器升主通道歸 M6 重訂契約。請確認此切分。

---

## 附：查證方法聲明

本檔全部斷言出自 `main` @ `2a15d74` 的原始碼與已凍結文件逐行閱讀（引用行號皆經實際開檔核對），未執行任何測試或量測；§2.4 的記憶體數字是沿用 `cache-sizing-estimate.md` 口徑的算術推算，非量測值。
