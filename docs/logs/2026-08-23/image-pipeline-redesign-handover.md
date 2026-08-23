# 影像管線重新設計 — 執行方向交接

> **建立時間**：2026-08-23（UTC+8）
> **取代**：`docs/logs/2026-08-22/thumbnail-dart-first-plan.md` 的 R1–R4 分階，以及 `docs/logs/2026-08-22/windows-port-session-handover.md` §8 的待解議題表。那兩份的**證據與量測仍然有效**，被取代的只有執行方向。
> **狀態**：**設計與裁決完成，程式碼一行未寫。**
> **版本錨點**：Halcyon `main` @ `a8ae038`；`flutter_dng_decoder` `main` @ `d36e1bd`。
> **上游並行線**：`flutter_dng_decoder/docs/logs/2026-08-23/targetwidth-sized-decode-handover.md`（另一個 session 施工，不擋本線）。

---

## 0. 接手速讀（60 秒）

- **原始需求沒變**：讓 thumbnails 脫離 macOS、全平台通用。**但診斷變了**：問題不是「Windows 缺一塊原生實作」，而是**模組是按執行路徑切的，不是按功能切的**，於是檔案類型決定走哪條路，每條路各自長出一份近似重複的能力。
- **最關鍵的一個數字**：`.dng` 這個副檔名預測「需要昂貴 RAW 解碼」的準確率是 **14 分之 1**（14 個樣本有 13 個內含全尺寸 JPEG，本該走 JPEG 那條路）。整條第二管線是為那個 1/14 蓋的。
- **終態**：三條路徑（側欄縮圖／螢幕尺寸預覽／全尺寸）共用一個 `(path, size)` 模組；快取行為對檔案類型**完全一致**；解碼與快取解耦。
- **下一個動作**：M0（抽取器 byte-range ＋ 依尺寸挑候選 ＋ 單次走訪順便回 orientation）。純 Dart、零管線耦合、可在這台 macOS 上完整驗證，並且當場消滅一個今天就在樹上的隱患。
- **紅線**：JPEG 路徑目前的使用者可見行為是**地板**。瞬間前後切換是本 app 最大賣點，任何讓它變慢的提案直接否決。

---

## 1. 使用者裁決（凍結，只有使用者能改）

| # | 裁決 | 含意 |
|---|---|---|
| D1 | **做到 S4／M6：拆掉舊路** | 不只蓋新路，還要刪掉 macOS 的 `NO_EMBEDDED_PREVIEW` 發射與那塊寫錯的路牌 |
| D2 | **tier-2 現行行為凍結，禁止更動** | perf 提的 F1（改成放大才解）與 F2（±1→±0）**全部作廢**，不進任何一輪。理由：瞬間切換是最大賣點 |
| D3 | **三條路徑解耦、共用元件** | 同一模組收 `(path, size)`，自己判斷 JPEG／內嵌 JPEG／FFI 解碼，解到指定尺寸回傳。**縮圖失敗不得牽連預覽** |
| D4 | **快取行為對檔案類型完全一致** | 「無論 RAW、JPG、有 JPG 的 DNG，快取行為皆須全部一致，禁止有任何 decoupling」 |
| D5 | **收掉第三個 variant，完成 M6** | `NativeImageResult` 三 variant → 兩個。**需要明確的 AD-010/AD-011 修訂，不得默默改** |
| D6 | **上游 `targetWidth` 並行、不擋本線** | 交接單已寫好，另一個 session 施工 |

### D4 的執行讀法（若與使用者理解不符，停下來問）
- **保留（快取）100% 一致**：同一個 `−3..+5` 視窗、同一份 byte 預算、同一條淘汰規則。快取只讀 `payload.byteCost`，**不知道也不能知道**自己裝的是 encoded bytes 還是 RGBA。可機械檢查：快取檔案內 `grep -c "EncodedPayload\|PixelPayload"` == **0**。
- **啟動（排程）依實測成本分兩級**：這一項**不一致，且必須不一致**。理由見 §4.2——若無預覽 DNG 也享有全窗且不 debounce，會出現九個 FFI 解碼齊發、四個並行互搶一台 8 核飽和的機器，直接違反 D2。

---

## 2. 診斷：為什麼是「一堆 patch」而不是一個 bug

三位獨立 reviewer（architecture／performance／全域 audit）加一次紅隊對質後的收斂結論。

### 2.1 範圍其實很小
「按路徑切而非按功能切」的診斷成立，但**只涵蓋影像取得／解碼／快取子系統加兩個 runner，約 1600 行**。repo 其餘部分（`photo_library_scanner.dart`、`photo_file_actions.dart`、`photo_status_store.dart`、`rename_service.dart`、`thumbnail_export_service.dart`）是按功能切的、對檔案類型無感、運作正常。**要動的就那一塊，不要擴散。**

### 2.2 重複能力盤點（實測）

| 能力 | 份數 | 惡化細節 |
|---|---|---|
| 抽取內嵌 JPEG | **4** | `dng_preview_extractor.dart:78-213`（只要全尺寸）／`macos/Runner/DngPreviewExtractor.swift`（實測 14/14 byte-identical 孿生）／ImageIO（唯一支援尺寸的）／上游 `dng_ffi_api.cpp:159-201`（**只要縮圖**，篩選條件與 Dart 恰好相反，且 Halcyon **0 個呼叫點**）。**四份沒有一份能回答「≥ N px 的最便宜 JPEG」** |
| 讀 EXIF orientation | **6** | 其中 `dng_preview_extractor.dart:41-48` 為了一個整數把整個檔案重讀一次，而 `:94-99` 在抽取那趟裡早就解析過了 |
| 套用 EXIF orientation | **4 種機制** | Dart canvas／CoreImage／ImageIO 隱式／WIC，加上 `_injectExifOrientation` 這個把責任丟回 Flutter 的旁路 |
| 「這檔能不能讀」 | **2 套互不相通的政策** | preview 有 `_failedIds`（`:119`）；側欄**完全沒有**（`:818` 只測 `containsKey`）→ 永久失敗的檔案每次 sweep 都重問，直到天荒地老 |
| 尺寸封頂 | **6 處** | 而真正需要旋鈕的兩個——抽取器與 `DngFullDecoder`——**一個都沒有** |
| 格式表 | **3 份** | 且 `supported_photo_formats.dart:26-41` 的 `rawExtensions`/`isRawPath` 在 `lib/` 下**0 個呼叫點**（純死碼，存在只是為了讓兩個 runner 各自再抄一次） |

### 2.3 快取為什麼會分家（實測，非推論）

**組織原則：快取只能放「重新產生很便宜」的東西；昂貴的必須先化簡再快取。**

- JPEG 遵守：兩層倉庫。解碼結果掉了沒關係，encoded bytes 還在 `−3..+5` 窗裡，就地重解且**不受 debounce 限制**（`:324` 同步呼叫）。
- RAW 違反：唯一的形式就是那張 **49.87 MB** 的 `ui.Image`，重建要一次 **61–406 ms** 的 FFI 呼叫，而 `:568-574` 直接 `dispose()`——不是釋放快取，是不可回收的銷毀。然後用窄視窗＋專屬 eviction＋所有權契約＋in-flight set＋25 行警告去補償。

**實測邊界**（`scripts/tmp/dng_nav_probe_test.dart`，6 個探針全綠，我親自複跑過）：

| 探針 | 現況 |
|---|---|
| P1 | JPEG 抵達時有 **5** 個 tier-1 快取項；RAW **0** 個（`:593-594` 因 `bytes == null` 結構性跳過） |
| P2 | 9 步 60 ms 連按期間，RAW 解碼啟動 **0** 次（debounce 每次被取消）；同期 JPEG 預解已完成 |
| P3 | 走 1 步再回來：RAW 圖還在，0 次重解 |
| P4 | **走 2 步再回來：已 dispose，重解一次**；同一段路 JPEG 的 bytes `identical` 存活 |
| P6 | 銷毀者是 ±1 的 stale-union sweep（`:421-428`），不是 `−3..+5` 那個 |

**所以修法不是「把 RAW 視窗放寬」**（那是 200–300 MB 換一個半吊子），**是讓 RAW 也只保留可便宜重建的東西**——之後同一套政策服務兩者，視窗問題自動消失。這正是 D4。

---

## 3. 目標架構

四層，全部是既有程式碼的**邊界重畫**，不是加層。淨效果：新增 4 檔約 590 行取代 `image_preload_controller.dart` 的 846 行 → **淨 −250 行、−1 檔、零新注入點**。既有的 `ImageBytesLoader`／`ThumbnailLoader`／`DngFullDecoder`／`ExportBytesFetch` 四個 seam 全部不動，所有測試替身照常運作。

```
PrefetchScheduler   何時、依什麼順序去拿（唯一知道「成本」的層）
      ↓
PhotoPayloadCache   保留什麼（對類型與成本皆無感，只讀 byteCost）
      ↓
PhotoSource         (path, longEdge) → SourcePayload?   ← Dart 端唯一知道檔案類型的地方
      ↓
DecodeTiers         tier-1 / tier-2 provider（對類型無感）
```

### 3.1 `PhotoSource` —— 唯一知道檔案類型的地方

寫成**內容判定**，不是副檔名判定：

| 步 | 條件 | 動作 |
|---|---|---|
| 1 | 檔案開頭是 `FF D8` | 檔案本身就是 bitstream |
| 2 | TIFF magic | 走一次 IFD，挑**「≥ longEdge 的最小 JPEG 候選」** |
| 3 | 完全沒有 JPEG | FFI 解碼，**立刻**經既有 canvas 路徑（`decoded_rgba_image_provider.dart:77-112`）縮到 `longEdge` 並在同一趟套用 orientation，dispose 全解析度中間物，回 `PixelPayload` |
| 3b | 解碼器缺席或丟例外 | 退回 CIRAWFilter（`_fallbackToLegacyBytes` 搬家，**不是重寫**） |
| 4 | 以上皆無 | null |

**步驟 2 的副作用是免費的跨格式支援**：抽取器 `:85-86` 只檢查 TIFF magic 42，**從不看副檔名**（我驗過）。`.arw/.cr2/.nef/.orf/.rw2` 今天就走得通，唯一擋著的是 `image_preload_controller.dart:659` 那個 `.dng` 字面量。**[U-2]** 這條需要真實樣本證明，`local_data/photo_samples/` 沒有。

**步驟 3 是讓 RAW 便宜到能遵守同一套政策的關鍵**，也是繞開「FFI 沒有尺寸參數」這個結構限制的方式（S1 的 222 ms 硬地板、`dng_pipeline_v2.cpp:927` 釘死、`dng_render_halide.cpp:1917-1921` 的守衛——見上游交接單）。

### 3.2 `PhotoPayloadCache` —— D4 的載體

- `id → SourcePayload`，**一個** `−3..+5` 視窗，每一種 payload 完全相同。
- 淘汰：離窗，或在 byte 預算下 LRU。**只讀 `payload.byteCost`。**
- **不 dispose 任何東西**——payload 是 `Uint8List`。
- 機械驗收：快取檔內 `grep -c "EncodedPayload\|PixelPayload"` == **0**。
- 成本對照：9 個 `PixelPayload`（視窗解析度）≈ 132 MB；9 個 JPEG ≈ 11 MB。**同一條規則，不同成本**，正是 D4 要的。

`RawPixelsImage` **1 換 1 取代** `DecodedRgbaImageProvider`：用保留下來的 RGBA 走 `ui.decodeImageFromPixels`，產出的 `ui.Image` 由 **ImageCache 自己擁有**，跟其他任何一項一樣——沒有 master handle、沒有 `clone()`、沒有 evict-before-dispose。重建成本是一次 memcpy ＋ GPU 上傳（已量測 18–19.9 ms），不是 FFI 呼叫。

### 3.3 `PrefetchScheduler` —— 唯一知道成本的層

```
enum SourceCost { cheap, expensive }          // 由檔案「內容」量測而來
probe(path, longEdge) → SourceCost            // 只走步驟 1–2：magic ＋ IFD，≤300 KB byte-range
```

`probe` **每個項目 memo 一次**（每資料夾問一次，不是每次導航問一次）。它是 `_needsRawDecode` 的直接後繼，也是「exactly-once」保證的新載體。

| rung | 允許視窗 | debounce | 等同於 |
|---|---|---|---|
| `cheap` | **−3..+5 全窗** | 否 | 今天的 JPEG 行為，逐字 |
| `expensive` | **±1** | 是，250 ms | 今天的 RAW 啟動行為，逐字 |

**這不是換名字的類型分支。** 它鍵在量測出來的成本上。今天是用副檔名選 rung，**14 次錯 13 次**；改成量測內容之後，那 13 個內含 JPEG 的 DNG 升到 `cheap`、享受 JPEG 待遇，`expensive` 的族群從「每個 DNG」縮成「完全沒有 JPEG 的檔案」——**1/14**。收斂是靠讓分支誠實，不是靠刪掉分支。

**保留與啟動分離**：`expensive` 的**啟動**限 ±1，**保留**跟所有人一樣 `−3..+5`。在 8 解碼、導航到 10：離開啟動窗，仍在保留窗，回到 8 **不需要重解**。這就是 P4 從 2 變 1 的機制。

### 3.4 消滅 spinner-forever（不變式 T1，明文化）

每個被納入的項目都會在有限時間內離開 spinner，透過且僅透過三者之一：payload 寫入／`_permanentMisses` 標記／記為 `expensive` 且在 ±1 窗外（**於靜止 250 ms 後解決**）。第三種是有界的 ≥250 ms spinner，即今天無預覽 DNG 的實測行為（約 360 ms 地板），**沒有退步**。

唯一真正新增的 stranding 風險是「步驟 3 丟例外 **且** 步驟 3b 也失敗，而沒有人標記 miss」。今天 `_fallbackToLegacyBytes:509-514` 正是在這條路上寫 `_failedIds`。**那一行是載重的，保留它是 M3 的驗收條件，不是假設。**

### 3.5 視圖三態（取代 `main_detail_view.dart:277-286` 的三向分支）

`payload != null` → 畫（兩種 payload 同一分支）｜`id ∈ _permanentMisses` → 不可讀｜其餘 → spinner。

---

## 4. 不變式：保留、強化、與明確改變的

| # | 不變式 | 處置 |
|---|---|---|
| I1 | bytes 物件識別即 ImageCache key | **保留並強化**——快取是唯一配置者，tier 只讀快取、不讀 source，「每 tier 拿到新 buffer」的隱患結構性消失 |
| I2 | tier-1／tier-2 各自的 key namespace | 逐字保留 |
| I3 | tier-2 就緒是三重合取（`:185-200`） | **保留並補完**——刪掉 `:190` 的 raw 早退，`PixelPayload` 現在也要過三個條件。BLOCKER 1／3 對這個 kind 重新生效 |
| I4 | 每次 await 後重檢 generation | **保留並擴及 preview 路徑**（今天那條沒有 generation guard） |
| I5 | ~50 MB 影像所有權、evict-before-dispose | **刻意解除。** 不再存在被擁有的 master `ui.Image`。替代保證：常駐峰值由「視窗內 Σ byteCost」與 Flutter 的 500 MB 上限雙重機械封頂。遲到的解碼只花 bytes，永遠不會 use-after-dispose，因為沒有東西被 dispose。`_rawDecodesInFlight`、`:471-474` 的自我了斷、`dispose():241-250` 全部刪除 |
| I6 | 每個 raw 項目對原生恰好請求一次 | **一般化**——由 probe memo 承載（不是 `_permanentMisses`），並擴及縮圖與非 raw 失敗，嚴格更強 |
| I7 | tier-2 debounce 的時序是影像生命週期的載重結構（`:396-420` 那 25 行警告） | **不再載重。** debounce 保留它的效能職責，失去它的安全職責，因為沒有東西被 dispose。這是最清楚的結構性勝利 |
| I8 | 縮圖路徑缺負向快取 | 那是缺陷，由共用的 miss set 修好 |

---

## 5. JPEG 是地板：逐條核對

同一個視窗、同一個 payload 物件、tier-1 ±2 仍不 debounce、tier-2 ±1 仍 250 ms、`tierOneProviderFor`／`fullSizeProviderFor` 與其在 `main_detail_view.dart:280-285` 的呼叫點**完全不動**、macOS 的 JPEG passthrough 仍是一次 `Data(contentsOf:)`、JPEG 熱路徑上的 Dart CPU 為零（步驟 1 讀 2 個 byte 就退出）。

**唯一對 JPEG 可見的改變是排程並行度 9 → 4。** 由 0.8 ms 的 channel 往返推論為安全，但**未量測**——標為 **[U-1]**，並在 M4 以實測 A/B 把關。

---

## 6. 分階與驗收

每一階可獨立出貨、獨立回退，且**全部可在這台 macOS 上驗證**。

### M0 — 抽取器
byte-range 讀（實測每個 strip offset ≤ 292 KB）＋「≥ longEdge 的最小候選」選擇器＋把 `readOrientationFromFile` 併回單次走訪。
- **驗收**：18 個既有斷言不動即通過；`longEdge:200` 回那個 **9,525 bytes 的 256×171** 候選；`longEdge:2800` 與今天 **byte-identical**；每檔讀取 < 200 KB。
- ⚠️ `scripts/tmp/fixtures/synth_too_small.dng` 斷言 `0.90*cropMax` 的拒絕行為——那條斷言要**加一個 purpose 參數，不是刪掉**。
- **當場收益**：消滅今天就在樹上的隱患——`:317-321` 九個並行 `_loadPreview` 在 Windows 上全部落到整檔 `readAsBytes`（平均 7.5 MB → 約 64 MB 瞬時；24 MB 那顆 → 216 MB）。

### M1 — 側欄解碼上限
`sidebar_view.dart:271-280` 加 `ResizeImage(..., policy: ResizeImagePolicy.fit)`，尺寸 `32 × devicePixelRatio`。
- **驗收**：大圖解出後最大邊 ≤ `32×dpr + 1`；**長寬比在 1% 內保持**（這條抓 `policy: exact` 的變形陷阱，沒有它，天真的 `cacheWidth + cacheHeight` 會通過前一條並悄悄壓扁每張縮圖）。
- **註**：今天**不是** OOM 級（兩平台的 `sidebarThumbnail` 都在原生端 200 px 封頂，41 列約 4.4 MB，我驗過）。它是 M3 的前置條件——照舊計畫 R3 寫法會變成 96 MB/列 × 41 = 3.94 GB。

### M2 — 行為保持的抽取
把來源選擇搬進 `photo_source.dart`，走既有 seam，控制器不動。
- **驗收**：全套測試不改即通過（19 個 raw 斷言仍綠）；`grep -c "\.dng\|isRaw" lib/services/image_preload_controller.dart` == **0**。

### M3 — 決定性的一步
probe ＋ 成本閘 ＋ 統一快取 ＋ 步驟 3b ＋ 整個 DELETE 區塊一起落地。
- **驗收：拿 `scripts/tmp/dng_nav_probe_test.dart` 原封不動重跑**，逐 rung 斷言：
  - **P2**：cheap DNG 0 → 非 0；**無預覽 DNG 必須維持 0**。翻掉這條就是整階失敗。
  - **P1**：cheap 0 → 5；expensive 冷抵達維持 0（對著 222 ms 地板無可避免，與今天相同）。
  - **P4**：**兩個 rung 都必須 2 → 1**，且 `disposed=true` 變成不可達。
  - **每一個 JPEG 對照探針不得移動**（P3 `decodes=1`、P4 `bytes survived=true`）。任何 JPEG 退步即整階失敗。
- 步驟 3b 的 `_failedIds` 寫入要有專屬測試（§3.4）。
- 峰值 RSS < 350 MB（9 格全無預覽 DNG 的視窗）。**[U-3]**

### M4 — 排程統一
- **驗收**：一個永久失敗的縮圖在三次 sweep 中被請求**恰好一次**（今天是三次）；preview 路徑的 generation guard 測試（今天不存在）；**[U-1]** 用既有 `PerfLog` 事件對做 JPEG 切換延遲 A/B，不得退步。

### M5 — RAW 的全解析度 tier-2（選配）
以 M3 的記憶體數字為閘。緊的話直接不做——視窗解析度已經勝過今天的「抵達時什麼都沒有」。

### M6 — variant 收攏 ＋ runner 清理（**使用者已裁決要做**）
同一個 commit 內完成：`NativeImageNeedsRawDecode` ＋ `kNoEmbeddedPreviewCode` 刪除、macOS `AppDelegate.swift:371-402` 的發射刪除、`memory.md` 的 AD-010/AD-011 修訂。
- **驗收**：全套測試 ＋ 真的 `flutter run -d macos` 走一遍樣本 ＋ 重跑 macOS 效能基準。
- **必須排在 M0–M4 全綠之後**，作為最後一步。

---

## 7. DELETE 清單（M3 與 M6）

**Dart**：`image_preload_controller.dart`（整檔 846 行）· `_needsRawDecode:110` · `_decodedProviders:111` · `_rawDecodesInFlight:112` · `_startRawDecode:434-450` · `_runRawDecode:452-494` · `decodedProviderFor:150-151`／`decodedImageFor:155-156` · `:190` 早退 · `_evictTierTwoEntry` 的 dispose 半邊 `:567-574` · `:396-420` 警告區塊 · `.dng` 字面量 `:659` · 第二個 sweep `:291-296` · `DecodedRgbaImageProvider:140-200` · `kAllowRawDecodeSignalArg:92` 與參數 `:109` · **`NativeImageNeedsRawDecode:58-62` ＋ `kNoEmbeddedPreviewCode:86`**（D5）· `rawExtensions:26-33`／`isRawPath:39-41`（已是死碼）· `readOrientationFromFile:41-48`。

**保留（明確不刪）**：`_fallbackToLegacyBytes:500-518` → 搬成 `PhotoSource` 步驟 3b。理由是套件裡寫死的禁令，我驗過原文（`test/image_preload_controller_test.dart:1118-1120`）：

> Turning "slow but working" into a blank screen is not acceptable

**macOS**：`macos/Runner/DngPreviewExtractor.swift` **整檔約 280 行**（平台中立的邏輯放在平台資料夾，其 Dart 孿生實測 14/14 byte-identical；M6 之後它變成不可達）· `AppDelegate.swift:371-402` · `isDng:312` · `isJpeg:320`＋`:360-370` · `sanitizedExifOrientation:156-159`。

**macOS 明確保留**：`AppDelegate.swift:313-318` 的 `isRaw` ＋ `:426-472`。`.arw/.cr2/.nef/.orf/.rw2` 沒有被證明的 Dart walker 覆蓋、也沒有 FFI 解碼器，ImageIO 是真正唯一讀得到它們的東西。**這是整棵樹上唯一一個本質性的類型分支**，只有在步驟 2 對真實 `.arw`/`.cr2` 樣本被證實之後才可刪（**[U-2]**）。

**Windows：只記帳，不改任何程式碼。** 遷移完成後 `IsRawExtension:509-518` 與 JPEG passthrough `:547-556` 由構造上變成死碼，記為「有 Windows 主機時可刪」。理由：`/W4 /WX`、無 Windows 主機、且該檔還壓著一個從未編譯的 EXIF 修復。

**上游：只建議，不動手。** `dng_extract_preview_jpeg` 在 Halcyon 0 個呼叫點且篩選條件相反，建議上游廢棄。

---

## 8. 廢止的既有計畫項目

| 原項目 | 處置 |
|---|---|
| R1（Dart 合成 raw-decode 訊號） | **併入 M3**。原本要合成的那個 variant，在 D5 之後不存在了 |
| R2（側欄解碼上限） | **保留為 M1**，內容不變 |
| R3（抽出 chain ＋ 側欄 fallback） | **拆進 M0／M2／M3**。原本的 R3-AC1「搬移是本階最大風險」由 M2 的行為保持抽取消除 |
| R4（warmup ＋ pipeline cache） | 併入 M5 之後或獨立。`setPipelineCachePath` 在 macOS 回 -1 是設計如此，**跳過** |
| perf F1（改成放大才解 tier-2） | **作廢（D2）** |
| perf F2（tier-2 ±1 → ±0） | **作廢（D2）** |
| perf F8（Windows 側欄全解 24 MP） | 由共用模組的尺寸參數解決，不另排 C++ 輪次 |
| 「把 RAW 視窗放寬到 −2..+3」 | **作廢**。那是 200–300 MB 換半個修復；正解是讓 RAW 只保留可便宜重建的東西 |

---

## 9. 未決事項

| # | 未決 | 由什麼解決 | 擋住誰 |
|---|---|---|---|
| **[U-1]** | JPEG 並行度 9→4 是否可量測地變慢 | `lib/perf/perf_driver.dart` 對 `selectItem.enter`→`image.painted` 做 A/B | M4 |
| **[U-2]** | TIFF walker 是否真能在 `.arw/.cr2/.nef/.orf/.rw2` 找到預覽 IFD | 真實樣本。`local_data/photo_samples/` 沒有 | 刪 macOS `isRaw` |
| **[U-3]** | 9 格 `PixelPayload` 視窗的實際峰值記憶體（推導 ~206–306 MB 對 500 MB 上限） | M3 實測 RSS | M3、M5 |
| **[U-4]** | 步驟 3 那次一次性 GPU 縮放的成本（假設 ≪ 它所搭載的 FFI 解碼） | M3 量測 | — |
| **[U-6]** | `preloadImages:253-326` 沒有 generation guard 的潛在競態 | 未能重現；M4 宣稱由構造修好，但該宣稱不可證偽 | — |
| **[U-7]** | byte-range probe 的成本（由整檔 3.79 ms 向下外推，非量測） | M0 完成後實測 | 「每資料夾 ~10 ms」這個數字 |

---

## 10. 證據入口

| 主題 | 路徑 |
|---|---|
| 三路徑視覺化（mermaid） | `scripts/tmp/pipeline-map.html` |
| DNG 快取失效診斷（6 探針，實跑綠） | `scripts/tmp/verify/dng-nav-cache-diagnosis.md` ＋ `scripts/tmp/dng_nav_probe_test.dart` |
| 架構審查（三 variant、seam、不變式） | `scripts/tmp/verify/arch-review-image-pipeline.md` |
| 效能審查（解碼像素才是浪費） | `scripts/tmp/verify/perf-review-image-pipeline.md` |
| 全域類型分歧盤點 ＋ 解耦設計 | `scripts/tmp/verify/arch-audit-filetype-divergence.md` |
| 上游 `targetWidth` 可行性 | `scripts/tmp/verify/upstream-targetwidth-scope.md` |
| **上游施工單** | `flutter_dng_decoder/docs/logs/2026-08-23/targetwidth-sized-decode-handover.md` |

> ⚠️ `scripts/tmp/` 是 gitignored scratch，跨 session 不保證存在。本檔已把所有結論內化，不依賴它們。

---

## 11. 順帶要修的既有文件錯誤

- ~~`CLAUDE.md` 說 `build_apps.py` 的原生 CMake 路徑「從未執行過」。~~ **已於 2026-08-23 修正**（`CLAUDE.md` §Commands）。更正內容：沒跑過的是 `build_apps.py` 的**編排**，不是 CMake 本身——上游 commit `d36e1bd`（2026-08-22）在真實 Windows 機器上跑過 MSVC 建置並提交了 1,906,688 bytes 的 `dng_decoder_native.dll`。該 commit 未記錄 S4 色彩閘，所以 DLL 仍屬 trust-on-first-use。
- `CLAUDE.md` 的「Native bridges」段與 `memory.md` AD-010 的原文都會被 M6 改寫，屆時一併處理。
