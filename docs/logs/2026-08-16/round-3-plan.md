# Round 3 — DNG tier-2 真解碼（引入 flutter_dng_decoder）交接

> **建立時間**：2026-08-16（UTC+8）；**2026-08-16 修訂**：依使用者實測結果收斂範圍與前提。
> **狀態**：方向已定，待排程實作。
> **前置**：round 2（兩層解碼）落地。
> **範圍限定**：**只處理 DNG**。不處理 RW2／ARW／CR2／NEF／ORF 等原生 RAW（使用者 2026-08-16 拍板）。
> **整合面研究依據**：對 `/Users/jhangyu/project/flutter_dng_decoder` 與 Halcyon 接點的實地盤點，file:line 為盤點當下。

## 0. 使用者已實測確認的前提（不再重新驗證）

以下三點由使用者親自驗證，本輪直接採信，**不列為待確認項**：

1. **畫質可用**：`flutter_dng_decoder` 解出的結果與參考相比，肉眼無法察覺差異。
   （附註供後人理解出處：該專案文件裡的 102.72dB 是 Halide 管線 Stage 3 的 GPU vs CPU 數值精度回歸閘，`explainer_gpu_bitexact_psnr999.md:22-26`，本來就不是畫質對照指標。畫質可用這件事的依據是使用者實測，不是那個數字。）
2. **速度可用**：實際解碼比該專案文件記載的更快。文件裡的 cold ~500ms 是 Android/Vulkan 數字（`Task_round3_wrapup.md:36-38`），不適用於 macOS/Metal，也不需要再引用——以實測為準。
3. **範圍只到 DNG**：原生 RAW 格式不在本輪，因此該專案的 Panasonic／Sony 標籤支援度、RW2 樣本缺失等問題全部**不成立為阻礙**，直接移出。

## 0.5 專案硬性上限（使用者 2026-08-16 訂立，適用全專案）

**任何操作的時間間隔不得超過 1 秒。** 超過 1 秒沒有回應即代表該操作本身效能不及格，應退回尋找 root cause——不是接受、不是等它跑完、不是在文件裡記成「已知較慢」。

對本輪的具體意義：DxO 直出 DNG 走真解碼路徑時，從使用者停頓到全尺寸上屏的整段必須守住這條線。若 `decodeOnWorker` 的實測成本讓單張無法在 1 秒內完成，那是要追根因的缺陷（prewarm？isolate 複製成本？中間緩衝配置？），不是可以寫進「已知限制」的東西。

例外只有一種：量測 harness 為了模擬使用者行為而**刻意**插入的等待（例如 paced pass 的 pacing）。那是被量測情境的一部分，但報告中必須標明為刻意 pacing，不得與「系統回應慢」混為一談。

## 1. 終態（一句話）

DNG 在 5x 放大時清晰度與 JPEG 同級；瀏覽速度不因此退化。

## 1.5 round 3 要打敗的基線（round-2 實測，綁定 HEAD `3cbc5ff`）

| 指標 | 現況 | 目標 |
|---|---|---|
| JPEG 切換（tier-1 命中／tier-2 直落） | 中位數 2.8–4.4ms，max 5.4ms | 不得退化 |
| **RAW native 單張總成本** | **中位數 109.8ms**（`rawExtractDecode` 91.1＋`reencode` 15.1，p95 120.9、max 221.5） | **≤60ms**（round 2 未達標，使用者裁決順延本輪） |

證據：`tmp/verify/r2/dng_profile_r2b.report.txt`、`jpg_profile_r2b.report.txt`。

**這組數字直接指向第一段的價值**：91.1ms 幾乎全是「ImageIO 為了產出 2800px 而先解碼內嵌全尺寸 JPEG 再降採樣」的成本。內嵌 JPEG 直接透傳完全不需要這一步，連 15.1ms 的重編碼也一併省掉——對 Lightroom 轉譯過的 DNG，native 成本應該掉到接近讀檔時間。**先做第一段的理由不只是風險低，而是它就是這個數字的根因解。**

（對照：DxO 直出的 DNG 沒有全尺寸內嵌預覽，今天走的是 CIRAWFilter 完整解碼，成本更高且不在上表的 84 次取樣代表性內——第二段要打敗的是那條路徑，實測值需於 round 3 另行取得。）

## 2. 為什麼要做

round 2 把 DNG preview 的 native 抽取降到約 2800px（`native_thumbnail_service.dart:5-12`），瀏覽夠用，但那是這條路徑的畫質上限——tier-2 只是把**同一份 2800px bytes** 以原尺寸再解一次（見 §4.3），放大到 5x 必然糊。JPEG 走 passthrough 能拿到 6000×4000 原始資料，DNG 目前拿不到。

## 2.5 素材來源決定了兩條分支都必須做（使用者 2026-08-16 提供）

專案裡的 DNG 有兩種來源，內嵌預覽的狀況完全不同：

| 來源 | 內嵌 JPEG | 後果 |
|---|---|---|
| **DxO Optics Pro** 由原生 RAW 轉出的 DNG | **只有縮圖，沒有全尺寸 JPEG** | 抽不到可用的高解析預覽 → **必須真解碼** |
| 上述 DNG 再經 **Lightroom** 重新轉譯 | 內嵌**渲染後的全尺寸 JPEG** | 直接抽出即可，等同 JPEG 路徑 |

**因此第二段不是選配。** 先前「先量覆蓋率、比例高就不必做第二段」的建議作廢——DxO 直出這一整類檔案本來就沒有全尺寸預覽，覆蓋率再高也涵蓋不到它們。兩條分支都要實作，由檔案自身的中繼資料在執行期選路。

附帶說明現況：DxO 直出的 DNG 今天走的是 `AppDelegate.swift:128-129` 的 `maxDimension >= 1024` 檢查——縮圖太小時判定不合格，於是掉進 :135-154 的 CIRAWFilter 完整解碼。也就是說這類檔案目前已經在付昂貴路徑的成本，只是解碼器不是我們挑的那一個。

## 3. 兩段式設計（依成本遞增，建議分段驗收）

### 第一段：全尺寸內嵌 JPEG 直出（Lightroom 轉譯過的 DNG 走這條）
若 DNG 的內嵌預覽已是全尺寸，直接取那份 JPEG 當 tier-2 來源——等同 JPEG 路徑，**不需要 FFI、不需要 dylib、不需要處理方向與色彩**。

兩條取得管道，擇一：
- **ImageIO（現有 native 端）**：把 `AppDelegate.swift:119-124` 的抽取上限改為「不設限或設為感光器長邊」，並在回傳前比對尺寸。
- **`DngDecoderService.getPreviewJpeg(path)`**（`dng_decoder_service.dart:201-235`，另有 `getPreviewJpegOnWorker` :245-257）：直接回傳內嵌 JPEG bytes。若本輪反正要引入這個套件，用它比走 ImageIO 更直接。

**「是否為全尺寸」的判定——這是整輪唯一的新判斷邏輯，也是最容易做錯的地方。**

判準是**檔案自身中繼資料記錄的影像尺寸**，不是螢幕解析度、不是視窗尺寸、更不是 round 2 那個 2800px 的顯示導向上限（使用者明確指示）。兩個數字相比：
- **基準（該影像應有的尺寸）**：`CGImageSourceCopyPropertiesAtIndex(source, 0, nil)` 取頂層 `kCGImagePropertyPixelWidth` / `kCGImagePropertyPixelHeight`（`CGImageProperties.h:65-66`）；DNG 另有 `kCGImagePropertyDNGDictionary` → `kCGImagePropertyDNGDefaultCropSize`（:649）可交叉驗證裁切後的實際輸出尺寸。
- **待測（內嵌預覽的真實尺寸）**：注意陷阱——`CGImageSourceCreateThumbnailAtIndex` 會依 `kCGImageSourceThumbnailMaxPixelSize` **把回傳影像縮到上限**，所以拿目前那條帶 2800 上限的呼叫去量，量到的永遠是 2800，不是預覽的原始尺寸。要嘛用一個足夠大／不設限的上限單獨探測，要嘛改讀預覽 IFD 自身的屬性。**這一步做錯的症狀是所有檔案都被判為「非全尺寸」而全部掉進真解碼**，而且不會有任何錯誤訊息。

閾值：建議 ≥90% 長邊（沿用 round-2 建議，實作時以實際素材校準）。留餘裕是因為 Lightroom 的渲染輸出未必與感光器尺寸完全相同。目前 `AppDelegate.swift` 完全沒有讀這些 key。

### 第二段：沒有全尺寸內嵌 JPEG 時走真解碼（DxO 直出的 DNG 走這條）
**必做，不是選配**——理由見 §2.5。使用 `decodeOnWorker`（見 §4.1 的執行緒注意事項）。

## 4. 整合事實（實作時直接用，不必重查）

### 4.1 對外 API（`dng_processor/lib/src/dng_decoder_service.dart`）
- `initialize()`（:133-140）同步、冪等。
- `decode(path) → DngImage`（:279-356）**同步、在呼叫者 isolate 執行**，`rgbaData` 是直接指向 native 記憶體的零拷貝 view，由 `NativeFinalizer` 於 GC 釋放（:322,336-341），**明文禁止跨 isolate 傳遞**（:271-276）。→ **不可在 UI isolate 直接呼叫，會卡畫面。**
- `decodeOnWorker(path) → Future<DngImage>`（:194-197）走 `Isolate.run`，跨界前複製成 `TransferableTypedData`（:390-395）。**這是 Halcyon 該用的入口。**
- `getPreviewJpeg` / `getPreviewJpegOnWorker`（:201-235 / :245-257）：第一段用。
- `warmupForSize({width, height})`（:143-151）：若實測 cold 首解仍有感，可在 app 啟動時背景呼叫。（`pipelineCachePath` 系列是 Android/Vulkan only，macOS 回傳 -1，不用管——`dng_decoder_service.dart:153-159`。）
- 輸出：`DngImage` 為 RGBA8 interleaved，帶 `width`/`height`/`decodeMs`/`processMs`。**struct 內沒有 orientation 也沒有色彩空間欄位**（`dng_bindings.dart:23-40`）——第二段實作時要確認方向由誰負責，避免轉向錯誤。第一段走內嵌 JPEG 則無此問題（EXIF 由 Flutter/ImageIO 處理，與現行 JPEG 路徑一致）。
- 錯誤：`DngDecodeException(errorCode, message)`，碼表 `DngErrorCode`（:61-73）。

### 4.2 打包（第二段才需要）
不是 pub 套件也不是 plugin，**沒有 podspec**。macOS 端靠 Xcode Run Script 呼叫 `native/scripts/build_native_watchdog.py` 產出並嵌入 `libdng_decoder_native.dylib`（`project.pbxproj:405,412,416`）；Dart 端以五段 fallback 搜尋 dylib，含 app bundle 的 `Frameworks/` 與 `DNG_NATIVE_BUILD_DIR` 環境變數（`dng_bindings.dart:249-266`）。Halcyon 是第一個外部宿主，這段接線要自己寫。

### 4.3 Halcyon 接點（`lib/services/image_preload_controller.dart`）
**tier-2 目前完全不碰 native channel。** `_decodeTierTwoWindow`（:220-275）拿的是 `_imageCache[item.id]` 裡由 `_loadPreview` 取回的**同一份 2800px preview bytes**（:364-369），以 `fullSizeProviderFor`（:36，純 `MemoryImage`）不縮放地再解一次。所以 DNG tier-2 **需要新的 bytes 來源，不是把解析度調大就好**。兩條接法：
- (a) 擴充 `ImageBytesLoader`（:9-13）／`_loadPreview`，讓 DNG 取第二份高解析 bytes 餵給 tier-2；
- (b) 在 `_decodeTierTwoWindow` / `_decodeFullSizeIntoImageCache` 加 DNG 分支，取得 bytes 後再交給 `fullSizeProviderFor`。

記憶體：24MP RGBA8 輸出約 69-92MB（`r4_final_matrix_both_platforms.md:13,545`）。要與 round 2 已設的 500MB `ImageCache` 上限一起算——round 2 已因 LRU 壓力吃過一個 blocker，tier-2 窗口是 ±1（3 張）。

### 4.4 native 現況（`macos/Runner/AppDelegate.swift`）
`getFastThumbnail` :74-192；RAW 副檔名判定 :79-84；內嵌預覽抽取 :116-132，接受條件 `max(寬,高) >= 1024 || targetSize <= 256`（:128-129）；不合格才走 CIRAWFilter 完整解碼 :135-154（EXIF 方向於 :143 套用）；統一 q0.8 JPEG 重編碼 :180-182。

## 5. Out-of-scope
- **原生 RAW 格式（RW2/ARW/CR2/NEF/ORF）**：本輪只做 DNG。現行 native 路徑對這些格式維持不變。
- Android：`flutter_dng_decoder` 的 Vulkan 路徑與 pipeline cache 與本輪無關；Halcyon 的 Android handler 仍是空殼。
- 瀏覽路徑：維持 round 2 的 2800px 快路徑。
- round 2 parking-lot 各項（S3/S4/S5/N2/N3、tier-1 側 reset 不 evict、tier-1 precache 排序、視窗 resize 孤兒 entry）。

## 6. 實作時要留意的三件事

- **選路判定必須用兩類真實素材各驗一次**：一張 DxO 直出的 DNG（預期判為「無全尺寸」→ 走真解碼）、一張經 Lightroom 轉譯的 DNG（預期判為「全尺寸」→ 抽 JPEG）。只驗一類會讓「永遠判成同一邊」的 bug 完全隱形——這正是本專案 round 2 反覆踩到的無鑑別力驗證。驗收時要看到兩個方向都被實際觸發，不是只看「有跑起來」。
- **`decode()` 是同步且零拷貝的**：用 `decodeOnWorker`，並接受其複製成本；不要為了省一次複製把 native view 帶進 UI isolate。
- **方向與色彩**（僅第二段）：`DngImage` 不帶這兩個欄位，第二段落地前先用一張已知方向的 DNG 驗證輸出是否需要自行套 EXIF orientation。

## 7. 參考入口
- round 2 契約與 parking-lot：`docs/logs/2026-08-16/round-2-plan.md`
- round 2 審查（含 mutation 與探針證據）：`round-2-review.md`、`round-2-review-2.md`
- 解碼器專案：`/Users/jhangyu/project/flutter_dng_decoder`（API `dng_processor/lib/src/dng_decoder_service.dart`）
