# 圖片切換延遲改善方案 R1–R4 說明（繁體中文）

依據：`perf-measurement-report.md`（2026-08-16，136 次真實切換量測，main @ 7c33194）。
現況瓶頸：切換中位數 127.5ms（profile build），其中 **124.1ms（97%）是 UI 端引擎解碼 6000×4000 全幅 JPEG**；channel 往返與 native 處理合計 <2ms。

---

## R3｜修復 in-flight 載入的永久 spinner（先做：是正確性 bug，不是優化）

**問題原理**
`_loadPreview` 開頭檢查 `_loadingKeys`：若該圖已有一個載入在途，直接 early-return（`lib/services/image_preload_controller.dart:79-81`）。而窗口預載發起的載入一律帶 `notifyLoaded: null`（`:70`）。組合結果：使用者連按方向鍵、剛好選中一張「窗口預載已在途」的圖時，early-return 丟掉了 notify 需求——bytes 之後正常進快取（實測 17ms 就到），但 `notifyListeners()` 永遠不會補發，UI 停在 spinner 直到下一次任意重繪。一輪 20 鍵 DNG burst 實測出現 4 次、單次卡超過 20 秒。這是「有時卡很久」的主因。

**修法**
把「誰要收完成通知」與「誰負責發請求」解耦。最小改法：`_loadingKeys` 從 `Set<String>` 改為 `Map<String, List<VoidCallback>>`（或另設 `_pendingNotifies`）——
1. 發現已在途時，不再靜默 return，而是把非 null 的 `notifyLoaded` 掛到該 key 的回呼清單。
2. 載入完成寫入快取後（`:91-94`），除了呼叫自己的 notify，也 flush 該 key 掛著的所有回呼，然後清掉 entry。

**預期效益**：消除 500ms～數十秒級的長尾卡頓（正確性修復，無數字上限）。
**風險/注意**：回呼 flush 要在 `_loadingKeys.remove` 之前後順序想清楚，避免 flush 期間重入再掛回呼；補一條「選中在途項→完成後有通知」的 completer 測試。

---

## R1｜`Image.memory` 加 `cacheWidth`（解碼降採樣，省約 50%）

**問題原理**
`main_detail_view.dart:192-199` 的 `Image.memory(bytes, ...)` 沒有給 `cacheWidth`/`cacheHeight`，引擎按原始像素解碼：24MP → 實測解碼 121.4ms、產生 96MB RGBA 貼圖；上傳 GPU 時 raster 中位數 18-20ms，是 jank 的另一來源。但螢幕實際只需要視窗大小（例如 ~1800px 寬）。

**修法**
1. 用 `LayoutBuilder`（該檔已有）取得顯示區邏輯尺寸，乘上 `MediaQuery.devicePixelRatioOf(context)` 得到目標像素寬，取整傳給 `Image.memory(..., cacheWidth: targetWidth)`。
2. 因為介面支援 `maxScale: 5.0` 縮放，直接用視窗寬會讓放大後模糊。取捨二選一：
   - **簡單版**：`cacheWidth = 視窗像素寬 × 2`（兼顧 2x 內縮放清晰，仍省大半成本）；
   - **完整版**：平時用視窗寬解碼，進入縮放手勢時背景補解全幅、解好後無縫換圖（多一步，本輪可不做，列 parking-lot）。

**量測依據**：`targetWidth: 1800` 實測解碼 121.4ms → **54.8ms**，貼圖 96MB → **8.6MB**（raster jank 同步消失）。
**風險/注意**：`cacheWidth` 改變 ImageCache 的快取 key（bytes+尺寸），R2 的 precache 必須用**完全相同**的尺寸參數，否則 cache 對不上、白做。

---

## R2｜預載窗口做 `precacheImage` 預解碼（切換降至 ~5ms；依賴 R1）

**問題原理**
現在的預載（`image_preload_controller.dart:43-96`）只把**原始 bytes** 抓進 Dart Map，從不解碼。解碼被推遲到 `Image.memory` 首次上屏，正好落在切換的關鍵路徑上——這就是那 124ms。

**修法**
1. 在 `_loadPreview` 拿到 bytes 之後，對窗口內每張圖建立與顯示端**同參數**的 provider（`ResizeImage(MemoryImage(bytes), width: targetWidth)`，等價於顯示端的 `cacheWidth`），呼叫 `precacheImage(provider, context)`（或不依賴 context 的 `ImageProvider.resolve` + listener），讓引擎在背景先解碼進 Flutter `ImageCache`。
2. 顯示端命中 `ImageCache` 後，切換成本只剩 build+raster，實測推估 **~5ms**。
3. 需要一條把顯示尺寸傳進 preload controller 的通道（constructor 參數或 setter，視窗 resize 時更新）。

**為什麼依賴 R1**：Flutter `ImageCache` 預設上限 100MB。不做 R1 時一張解碼圖就是 96MB——快取只裝得下一張，鄰圖 precache 完立刻被逐出，等於沒做。R1 之後每張 ~8.6MB，9 張窗口共 ~77MB，放得下（也可順手把 `ImageCache.maximumSizeBytes` 調到 ~200MB 加保險）。
**風險/注意**：precache 與顯示的解碼參數必須逐位元一致（同 width、同 bytes 物件）；注意 bytes 物件重建會導致 key 不同——`_imageCache` 保存的 `Uint8List` 要直接沿用，不可複製。

---

## R4｜RAW 原生預覽抽取降本（每張省約 200ms 預載預算）

**問題原理**
RAW（DNG/RW2 等）在 native 端走 embedded-preview 抽取：`AppDelegate.swift:119-124` 用 `kCGImageSourceThumbnailMaxPixelSize: max(targetSize, 8000)`（targetSize=10000 → 8000px）抽出超大預覽，實測 **123ms**；接著 `:181-182` 還要 NSBitmapImageRep 重編碼 q0.8 JPEG，再花 **82.7ms**——合計 209ms/張。預載 9 張窗口要 ~1.9 秒，追不上連按速度，所以 DNG burst 出現 spinner（20 鍵 6 次），JPEG 則 0 次。

**修法**
1. preview 用途的 RAW 抽取尺寸從 8000px 降到與顯示需求匹配（例如 2400–3000px，與 R1 的目標尺寸同源；可由 Dart 端把實際需要的 targetSize 傳真值，不再用 10000 當「不限制」的哨兵）。
2. 抽出的預覽若本身已是 JPEG 資料（embedded preview 常見情況），比照方案 C 直接回傳，跳過重編碼；否則維持重編碼但尺寸已小、成本大降。

**預期效益**：209ms → 估 <50ms/張，預載吞吐超過 key-repeat 速率，消除 RAW 瀏覽的 spinner。
**風險/注意**：`CGImageSourceCreateThumbnailAtIndex` 若 embedded preview 小於要求尺寸會退回小圖——要保留「預覽過小→退全幅解碼」的既有 fallback 判斷；RW2 分支（CIRAWFilter）本輪量測無樣本未驗證，改動後需以真實 RW2 檔抽測一次。

---

## 建議施工順序與依賴

```
R3（bug 修復，獨立）──┐
R1（cacheWidth）────→ R2（precacheImage，依賴 R1）
R4（native RAW，獨立，可與上並行）
```

預期綜合效果：JPEG 切換 127.5ms → **~5ms**（R1+R2），長尾卡死消失（R3），RAW 瀏覽不再出現 spinner（R4）。
所有數字出處與原始 log：`tmp/verify/perf/`、報告 `perf-measurement-report.md`。
