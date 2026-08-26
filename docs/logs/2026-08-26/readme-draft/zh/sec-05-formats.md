## RAW 格式支援與解碼路由

有兩個獨立的問題，決定一張照片會不會出現、以及它如何被轉換成像素：Halcyon 的資料夾掃描
器究竟列出了哪些檔案，以及這些檔案裡有多少是姊妹解碼引擎 Ceyx 真正知道如何解碼的。這兩個
集合並不相同，而兩者之間的落差，對任何把 Halcyon 指向一個相機原始檔資料夾的人都很重要。

### Halcyon 掃描並列出哪些檔案

側欄只會顯示副檔名出現在 `SupportedPhotoFormats.supportedExtensions` 裡的檔案，這個檢查
在資料夾掃描時對每一個目錄項目各做一次：

| 副檔名 | 分類 |
|---|---|
| `.jpg`, `.jpeg` | 已編碼位元流 |
| `.png` | 已編碼位元流 |
| `.dng` | RAW |
| `.cr2` | RAW |
| `.nef` | RAW |
| `.arw` | RAW |
| `.rw2` | RAW |
| `.orf` | RAW |

<!-- evidence: lib/models/supported_photo_formats.dart:6-16 -->

`PhotoLibraryScanner.scan` 會在任何目錄項目被分組成 `PhotoItem` 之前，先丟掉未通過
`SupportedPhotoFormats.isSupportedPath` 的項目，因此一個不在清單上的副檔名永遠不會進入
應用程式後續的任何階段，不論是不是解碼。
<!-- evidence: lib/services/library/photo_library_scanner.dart:11-16 -->

在共用同一個檔名（basename）的同組檔案中（例如同一次快門寫出的一張 JPG 與一張 RAW），
`SupportedPhotoFormats.preferredLoadExtensions`（依序為 `.jpg`、`.jpeg`、`.png`）決定哪
一個檔案優先載入；純 RAW 的組別則退回為該組中第一個受支援的檔案。
<!-- evidence: lib/models/supported_photo_formats.dart:18-22,45-61 -->

歷史備註：Panasonic 的 `.rw2` 曾經一度漏列在這份白名單裡，因而被靜默地排除在掃描之外；
這個缺口已經修補，`.rw2` 目前存在於上表的清單中。
<!-- evidence: memory.md G-007 -->

### Ceyx 能解碼哪些格式

RAW 解碼能力歸屬於 Ceyx，不屬於 Halcyon。它靠探測檔案表頭將每個檔案路由到兩個前端之一
——絕不是靠比對副檔名：

| 路由 | 容器 | 前端 |
|---|---|---|
| DNG | 以 TIFF 為基礎、IFD0 中帶有 `DNGVersion` 標籤 | Adobe DNG SDK |
| 通用 RAW | CR2、CR3、NEF、ARW、RAF、ORF、RW2、PEF、IIQ、MRW、X3F 及其他廠商容器 | LibRaw，並以 RawSpeed3 作為優先解碼後端 |

<!-- evidence: ceyx README.md:69-76 -->

非 TIFF 容器是靠魔數位元組比對（Fujifilm RAF、Minolta MRW、Canon CR3、Phase One IIQ、
Foveon X3F）；以 TIFF 為基礎的容器只有在 IFD0 於探測視窗內帶有 `DNGVersion` 標籤時才路由
到 DNG 前端，否則路由到通用前端。
<!-- evidence: ceyx README.md:95-105 -->

檔案被解包之後，Ceyx 的 GPU 派工是依據感光元件的排列方式決定，而不是依廠牌或容器格式：

| 排列方式 | 感光元件範例 |
|---|---|
| Bayer 2×2 | 絕大多數 RGGB 家族感光元件 |
| X-Trans 6×6 | Fujifilm X-Trans |
| 線性 RGB／無彩色濾鏡陣列 | Foveon X3F |

<!-- evidence: ceyx README.md:107-117 -->

### 「列出的格式」與「可解碼的格式」之間的落差

Halcyon 列出的每一個 RAW 副檔名（`.dng`、`.cr2`、`.nef`、`.arw`、`.rw2`、`.orf`）都在 Ceyx
記載的能力範圍內，但 Ceyx 記載能解碼的格式集合實質上更大——包含 Fujifilm RAF（X-Trans
感光元件）、Canon CR3、Pentax PEF、Phase One IIQ、Minolta MRW，以及 Sigma 的 Foveon
X3F——這些格式沒有一個出現在 Halcyon 的掃描白名單裡，**因此不論 Ceyx 有沒有能力解碼，這些
格式的檔案完全不會出現在側欄裡**。
<!-- evidence: lib/models/supported_photo_formats.dart:6-16; ceyx README.md:73-76 -->

第二個、也更重要的落差，藏在 Halcyon *確實*列出的格式內部。目前唯一接上 Halcyon Dart 程式
碼的 Ceyx 進入點是 DNG 完整解碼器（`DngDecoderService.decodeOnWorker`，包裝為
`halcyonDngFullDecoder`）；`lib/` 裡沒有任何呼叫點使用 Ceyx 的通用 RAW 進入點。
`dart_image_loader.dart` 裡的 RAW 解碼備援只會針對 `.dng` 觸發；一個沒有可用內嵌預覽的
`.cr2`、`.nef`、`.arw`、`.rw2` 或 `.orf` 檔案會回傳 `RAW_NO_EMBEDDED_PREVIEW` 失敗，而不是
被送進解碼器——也就是說，**目前非 DNG 的 RAW 檔案只有在其內嵌預覽可用時才會顯示，永遠不會
走完整的 RAW 解碼**。
<!-- evidence: lib/services/image_pipeline/dng_decode_service.dart:5-34; lib/services/image_pipeline/dart_image_loader.dart:12-15,114-119 -->

### 原生解碼器的平台可用性

並非 Halcyon 支援的每一個平台都能使用完整 RAW 解碼。建置腳本的原生函式庫對照表只為 macOS、
Windows 與 Android 建置並封裝 Ceyx 解碼器函式庫；不在這張表裡的目標平台就沒有原生解碼器，
而該表明確點名 iOS、Linux 與 web 就是這樣的目標平台。在這三個平台上，下文的路徑二無法執行
——一個沒有可用內嵌預覽的 RAW 檔案在這些平台上沒有完整解碼的備援，只有內嵌預覽路徑（路徑
一）能產生像素。
<!-- evidence: scripts/build_apps.py:265-290 -->

### 兩條讀取路徑

Halcyon 用兩種方式之一顯示一張 RAW 照片的像素，而選哪一條是在任何 GPU 運算開始之前就決定
好的。下文的路徑二，依賴一個只在 macOS、Windows 與 Android 上才有的原生 Ceyx 函式庫（見上
方「原生解碼器的平台可用性」）；在 iOS、Linux 與 web 上，路徑一是唯一能為 RAW 檔案產生像
素的路徑。

**路徑一——內嵌預覽。** 許多 RAW 容器（尤其是 Lightroom Classic 或 DxO PureRAW 產出的
DNG）在實際的感光元件資料旁還帶有一張或多張 JPEG 成品。當找到一個大小足以滿足請求的候選
圖時，Halcyon 會直接讀取那張 JPEG——一次有邊界檢查的定位讀取（seek）與切片，完全不對 RAW
馬賽克進行影像解碼——並徹底跳過 RAW 解碼。
<!-- evidence: lib/services/image_pipeline/dng_embedded_jpeg_extractor.dart:6-13 -->

**路徑二——完整 RAW 解碼。** 當沒有任何預覽候選圖符合條件時，該檔案會改交給 Ceyx 的 DNG
完整解碼器處理。
<!-- evidence: lib/services/image_pipeline/dart_image_loader.dart:107-112; lib/services/image_pipeline/dng_decode_service.dart:5-14 -->

決定走哪一條路徑的規則是一個最小長邊要求，而且刻意不是統一套用的。`.dng` 檔案的 `preview`
請求用途（長邊 2800px）會把這個值當作 `minLongEdge` 傳入：若選中的候選圖長邊小於
2800px，就直接被拒絕，改把該檔案送進路徑二，而不是端出一張尺寸不足的圖像。
<!-- evidence: lib/services/image_pipeline/image_source_types.dart:19; lib/services/image_pipeline/dart_image_loader.dart:69-77 -->

側欄縮圖路徑與匯出路徑都不套用這個下限。側欄刻意維持「先選最小、再退而求其次選最大」的
寬鬆候選圖選擇邏輯，讓縮圖永遠不會落到需要完整 RAW 解碼的地步；匯出路徑維持寬鬆則是因為
這條路徑上根本沒有 RAW 解碼備援——若在這裡拒絕尺寸不足的候選圖，會把「匯出一張稍小的圖」
變成「匯出失敗」，這是能力上的損失，而不是修正正確性。
<!-- evidence: lib/services/image_pipeline/dng_embedded_jpeg_extractor.dart:86-93; lib/services/image_pipeline/dart_image_loader.dart:41-51,58-68; memory.md AD-021 -->

還有一個與尺寸下限無關、獨立生效的拒絕門檻：如果一個 DNG 宣告的裁切範圍會讓解碼出來的
RGBA 緩衝區超過大約 1.5 GB，就會直接拒絕解碼，藉此限制記憶體使用量的最壞情況。
<!-- evidence: lib/services/image_pipeline/dart_image_loader.dart:96-105 -->

### 兩種不同的「無預覽」結果

一個未能產出可用內嵌預覽的 DNG，會落入以下兩種狀態之一，而 Halcyon 的載入器會把它們區分
開來，而不是把它們併成同一種通用失敗：

- **容器完全沒有宣告任何預覽**（裸感光元件擷取檔，或每一個候選圖都缺席、或都因尺寸不足而
  被拒絕）。這不算錯誤：該檔案會繼續走到路徑二、完整 RAW 解碼，並沿用同一次掃描已經讀到的
  EXIF 方向資訊。
- **容器宣告了一個或多個預覽候選圖，但每一個都讀不到**——例如某個資料條的偏移量或位元組數
  落在檔案範圍之外。這會被視為結構性損毀的檔案：Halcyon 會回報為解碼失敗
  （`DNG_PARSE_FAILED`），而不是靜默地嘗試——並且失敗——對已證實不一致的資料進行 RAW 解碼。

<!-- evidence: memory.md AD-022; lib/services/image_pipeline/dart_image_loader.dart:80-95 -->

一個讀不到的候選圖，若旁邊還有一個讀得到的候選圖，並不會觸發「容器損毀」狀態——只有在*沒
有任何*宣告的候選圖可讀時，才會被判定為 malformed。
<!-- evidence: memory.md AD-022; lib/services/image_pipeline/dng_embedded_jpeg_extractor.dart:44-55 -->
