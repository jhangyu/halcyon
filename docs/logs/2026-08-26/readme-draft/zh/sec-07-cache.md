## 快取與記憶體管理

### 問題所在

現代感光元件全尺寸解碼後的影格非常大——以 24 MP RAW 為例，解碼後大約是
91.55 MiB 的 RGBA 像素
<!-- evidence: lib/services/image_pipeline/cache_budget.dart:20 -->。
攝影師在瀏覽資料夾時，經常按住方向鍵不放，每秒切換數十張照片。若每次按鍵都
以全尺寸重新解碼一次，瀏覽迴圈會卡頓；若完全不設驅逐（eviction）策略，任何
稍具規模的資料夾都會耗盡記憶體。Halcyon 的影像管線的存在目的，就是讓連續、
全視窗的瀏覽在這兩種失效模式之間都不發生——做法是採用數個各自獨立、各自量身
訂定大小的快取，而不是單一個通用快取。

### 側邊欄縮圖層

側邊欄縮圖的預載並非由 `ScrollController` 監聽器驅動，而是由 `ListView.builder`
的 `itemBuilder` 驅動——它每一幀回報自己實際建置到的索引範圍，
`ImagePreloadController` 再把這些回報彙整成可視範圍，並依此發出請求
<!-- evidence: memory.md AD-014 -->。
較早的 scroll-listener 設計只有在使用者實際捲動時才會重新計算所需範圍，因此
資料夾重新載入後（標星／垃圾桶標記／複製／搬移都會觸發重新載入資料夾）若清單
沒有回到頂端，就會維持空白，直到使用者再次捲動；而 `itemBuilder` 每次重建都
會免費重新算出範圍，讓側邊欄在快取被清空後的重新載入中能夠自我修復
<!-- evidence: memory.md AD-014 -->。
一個 100ms 的防抖（debounce）計時器仍會緩衝這些請求（`_thumbnailDebounceTimer`），
現在還搭配一個批次世代（generation）計數器：一旦某個批次因快速捲動或資料夾
重新載入而被取代，它會在下一次 `await` 之前就自我中止，不再為已不存在的清單
浪費一次 channel 往返
<!-- evidence: lib/services/image_pipeline/image_preload_controller.dart:779-781 -->
<!-- evidence: memory.md G-001 -->。

請求順序是先由上到下取可視列，再向視窗兩側外擴 `thumbnailPrefetchMargin`
＝20 列的 prefetch margin，方向為下方一列、上方一列交錯進行
<!-- evidence: lib/services/image_pipeline/image_preload_controller.dart:53 -->
<!-- evidence: lib/services/image_pipeline/image_preload_controller.dart:783-793 -->。
抓取到的縮圖位元組存放在一個記憶體內的位元組快取（`_thumbCache`，一個以照片
id 為 key 的普通 `Map<String, Uint8List>`），並在每個批次都修剪成恰好目前所需
的範圍——可視範圍加上 margin
<!-- evidence: lib/services/image_pipeline/image_preload_controller.dart:91 -->
<!-- evidence: lib/services/image_pipeline/image_preload_controller.dart:795-796 -->。

小於等於 512 KiB 的內容會原樣進入這個快取——內嵌 DNG 預覽候選本身就已經是
縮圖大小。超過這個門檻的內容則會被解碼一次，縮小到 200px 長邊，並以品質 80
重新編碼為 JPEG
<!-- evidence: lib/services/image_pipeline/sidebar_thumbnail_codec.dart:26-30 -->。
選用 JPEG 而非 PNG，是針對照片內容特有的選擇：在這個專案用來比對的真實 DNG
樣本上，JPEG q80 的體積大約只有 PNG 的四分之一到六分之一。但有一份由純色色塊
組成的合成測試圖，卻讓結論反轉——PNG 在那份 fixture 上贏過 JPEG——原因是
大面積平坦色塊接近 PNG 的 filter+deflate 步驟的理想輸入，而尖銳的合成邊緣則
接近 JPEG DCT 步驟的最差輸入；這個反轉是那份 fixture 內容本身的性質，並不是
對側邊欄實際顯示的真實照片而言，JPEG 選擇有誤的證據
<!-- evidence: memory.md G-016 -->。

### 主圖層——兩個層級

主要預覽採用兩個解碼層級，而非單一層級。第一層（tier one）是視窗解析度解碼
——用目前視窗的像素尺寸包裝來源位元組的 `ResizeImage`——用於瀏覽時的即時顯示
<!-- evidence: lib/services/image_pipeline/image_preload_controller.dart:28-39 -->。
第二層（tier two）是同一張照片的全尺寸解碼，會延後到瀏覽動作靜止滿
`tierTwoNavigationDebounce`＝250ms 之後才觸發，讓連續按方向鍵瀏覽時，不會為
那些只是被使用者掃過、並未停留的影像觸發一連串全畫面解碼
<!-- evidence: lib/services/image_pipeline/image_preload_controller.dart:49 -->。
第二層的排程——防抖計時器、±`kTierTwoRadius` 視窗，以及單一序列化解碼佇列
——由 `TierTwoScheduler` 持有
<!-- evidence: lib/services/image_pipeline/tier_two_scheduler.dart:58-73 -->；
就緒性（readiness）的記帳——哪個 id 有一個常駐的第二層 `ImageCache` 條目、
是針對哪一個 payload 物件、以及其解碼監聽器是否已經真的觸發——則獨立存放在
`TierTwoRegistry`，它是純粹的狀態，本身不含任何計時器與非同步邏輯
<!-- evidence: lib/services/image_pipeline/tier_two_registry.dart:26-58 -->。
第二層解碼視窗是以目前照片為中心、`kTierTwoRadius`＝2 個項目
<!-- evidence: lib/services/image_pipeline/prefetch_scheduler.dart:32 -->
（該檔案在目前這棵樹的佈局下位於
`lib/services/image_pipeline/prefetch_scheduler.dart`）。

### 兩個不得合併的視窗常數

有兩個常數看起來可以互換，實際上不行：`kTierTwoRadius`＝2 決定哪些項目要做
全尺寸解碼，`kExpensiveStartupRadius`＝1 則決定哪些項目才允許啟動昂貴的 RAW
解碼
<!-- evidence: lib/services/image_pipeline/prefetch_scheduler.dart:12 -->
<!-- evidence: lib/services/image_pipeline/prefetch_scheduler.dart:32 -->。
在這個拆分之前，兩種語意共用同一個常數，放寬它以擴大全尺寸預覽視窗，會同時
悄悄放寬一次可以啟動多少昂貴 RAW 解碼——從三個循序項目變成五個——在一個沒有
內嵌預覽的 RAW 資料夾上，這實測會讓冷啟動安定時間從大約 25 秒變成大約 42 秒，
以每次昂貴循序解碼實測 8.5 秒計算
<!-- evidence: memory.md AD-018 -->。
這兩個常數也是以相反的樣本組推導出來的，不能互相驗算：`kTierTwoRadius`
不受解碼成本的限制，而 `kExpensiveStartupRadius` 的存在正是為了限制一波瀏覽
動作可以同時觸發多少個昂貴的 FFI 解碼
<!-- evidence: memory.md AD-019 -->
<!-- evidence: lib/services/image_pipeline/prefetch_scheduler.dart:5-12 -->。
哪些項目算「昂貴」是從檔案內容實測出來的，而不是從副檔名推斷——舊的副檔名
分類規則在每 14 個檔案裡大約有 13 個判斷錯誤
<!-- evidence: lib/services/image_pipeline/prefetch_scheduler.dart:44-47 -->。
未來的貢獻者很可能會直覺地把這兩個常數合併回一個，因為它們看起來是同一個
數字；**但不得這樣做**——這是一條設計上的不變式，不是可斟酌的偏好：
「要為多少張照片預先解碼全尺寸預覽」與「一次可以啟動多少個昂貴的 FFI 呼叫」
是兩個不同的問題，只是目前答案的數值剛好接近，並不是同一個問題被問了兩次。

### 保留快取與其驅逐策略

`PhotoPayloadCache` 以目前選取的照片為中心，保留一個 payload 位元組的視窗：
前面 3 張、後面 5 張，之所以不對稱是因為瀏覽行為絕大多數是往前
<!-- evidence: lib/services/image_pipeline/photo_payload_cache.dart:6-10 -->，
並依常駐位元組總成本對一個預算上限做驅逐，`kPayloadByteBudget`＝224 MiB
<!-- evidence: lib/services/image_pipeline/photo_payload_cache.dart:31 -->。

這是一個**視窗內先進先出（window FIFO）**策略，**不是**最近最少使用式的快取。
唯一一個原本會在讀取時更新條目順序的介面，在整個程式碼庫裡完全沒有任何呼叫
端，已經被刪除；因此迭代順序就是插入順序，當視窗本身超出預算時，預算路徑
會先驅逐最早進入的條目
<!-- evidence: memory.md AD-023 -->
<!-- evidence: lib/services/image_pipeline/photo_payload_cache.dart:54-60 -->。
在這裡採用單純的先進先出而非其他策略，並不是少做了什麼，而是有其道理：對
這個快取的存取模式是一支持續前進的游標，走過一份已排序的清單，而不是隨機
存取一個以 key 索引的儲存體。在這種存取模式下，插入順序與最近使用的順序其實
是同一種排序——結構上，最早進入視窗的那個項目，也正是使用者目前距離最遠的
那個項目——因此在其上額外追蹤「最後存取時間」，只會增加記帳負擔，卻不會改變
最終驅逐掉的是哪一個條目。

### 影像快取預算

Flutter 自身的 `ImageCache` 位元組上限並非寫死的常數，而是由實體記憶體推導
而來：實體記憶體的四分之一，並夾在下限 256 MiB、上限 768 MiB 之間
<!-- evidence: lib/services/image_pipeline/cache_budget.dart:32-38 -->。
下限是這條管線「不重新解碼」保證會失效的臨界點；上限則是目前這個 app 桌面
目標平台出貨時所配備的記憶體規模。這個專案所建置的 Dart 版本，其 `dart:io`
並未提供跨平台通用的「取得實體記憶體總量」API，因此這個推導函式把實體記憶體
作為一個可選的注入參數，在沒有提供讀數時，預設退回 768 MiB 這個上限
<!-- evidence: lib/services/image_pipeline/cache_budget.dart:4-10 -->。

224 MiB 的 payload 預算與 768 MiB 的 `ImageCache` 上限是依相反的樣本組算出來
的，不能拿其中一個當作另一個的驗算依據：payload 預算是依「昂貴、沒有內嵌
預覽」的 RAW 樣本組估算（每項實測約 22.4 MiB 的視窗解析度 RGBA 像素）；而
`ImageCache` 上限則是依「便宜、有內嵌預覽」的樣本組估算，該樣本組中單一項目
會同時持有一個完整原生尺寸的第二層條目（24 MP 約 91.55 MiB）與另一個獨立的
第一層條目
<!-- evidence: memory.md AD-019 -->
<!-- evidence: lib/services/image_pipeline/cache_budget.dart:18-25 -->。
若有人拿其中一個數字去「簡化」另一個，會在不自覺的情況下弄壞沒被看到的那一個。

### 快取鍵身分陷阱

第一層與第二層的 provider 工廠函式 `tierOneProviderFor` 與 `fullSizeProviderFor`
，在任何用來顯示或預先快取某個 payload 的地方，都必須以完全相同的 `bytes`
物件身分呼叫——就第一層而言，還必須傳入相同的 `width`／`height`
<!-- evidence: lib/services/image_pipeline/image_preload_controller.dart:23-44 -->。
Flutter 的 `ImageProvider` 快取鍵（第一層是 `ResizeImageKey`，第二層則是
`MemoryImage` 本身）只有在上述所有輸入都完全一致時才會相等——也就是說，只有
在這種情況下才會命中快取；若某個呼叫端用一份複製的位元組、或不同的目標尺寸
重新建構一個 provider，得到的會是一次悄悄發生的第二次解碼，寫進第二個快取
條目，而不是命中既有條目。這正是為什麼這兩個 provider 工廠函式被保留成並排
的自由函式，而不是在各個呼叫點臨時建構；也是為什麼 `TierTwoScheduler` 是以
注入的 supplier closure 形式接收 `fullSizeProviderFor`，而不是自行重建一份
副本
<!-- evidence: lib/services/image_pipeline/tier_two_scheduler.dart:29-37 -->。
未來任何要為這兩個層級新增呼叫點的人，都必須重用同一個 payload 物件與同一個
工廠函式，而不是重新建構一個外觀相同的 provider。

### 摘要

| 快取 | 所屬層級 | 內容 | 依據何者決定大小 | 驅逐方式 |
|---|---|---|---|---|
| 側邊欄位元組快取（`_thumbCache`） | 側邊欄縮圖 | 每個可視＋prefetch id 的小型編碼位元組（原樣通過或重新編碼為 JPEG q80） | 可視範圍＋兩側各 `thumbnailPrefetchMargin`（20）列 <!-- evidence: lib/services/image_pipeline/image_preload_controller.dart:53 --> | 每個批次都修剪成目前實際所需的 id 集合 <!-- evidence: lib/services/image_pipeline/image_preload_controller.dart:795-796 --> |
| `PhotoPayloadCache` | 主圖，兩個層級皆適用 | 保留的 `SourcePayload` 位元組／像素，每個照片 id 一份 | -3..+5 項目視窗，`kPayloadByteBudget`＝224 MiB 總量 <!-- evidence: lib/services/image_pipeline/photo_payload_cache.dart:6-10,31 --> | 超出預算時依插入順序先進先出驅逐；硬性視窗掃描則不論預算，直接丟棄視窗外的一切 <!-- evidence: memory.md AD-023 --> |
| `TierTwoRegistry` 狀態 | 主圖，第二層 | 純記帳：哪個 id 有一個常駐的第二層 `ImageCache` 條目、是針對哪一個 payload 物件、以及是否已就緒 | ±`kTierTwoRadius`（2）視窗 <!-- evidence: lib/services/image_pipeline/prefetch_scheduler.dart:32 --> | 項目離開視窗時逐一明確 `evict()`，或在 reset 時整體 `clear()` <!-- evidence: lib/services/image_pipeline/tier_two_registry.dart:221-240 --> |
| Flutter `ImageCache` | 兩個層級，已解碼影格 | 以 provider 身分為 key 的已解碼 `ui.Image` 影格 | 由實體記憶體推導，夾在 [256 MiB, 768 MiB] 之間 <!-- evidence: lib/services/image_pipeline/cache_budget.dart:32-38 --> | Flutter 自身依位元組預算運作的 LRU 引擎；此外，當其第一層／第二層記帳的 id 離開視窗時，也會被明確驅逐 |

<!-- evidence: lib/services/image_pipeline/image_preload_controller.dart:699-707 -->
