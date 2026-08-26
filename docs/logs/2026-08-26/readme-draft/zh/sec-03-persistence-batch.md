## 持久化、還原與批次操作

### 一次篩選作業永遠不會遺失

在資料夾整理到一半時關閉 Halcyon，之後再重新開啟同一個資料夾，畫面會回到原本瀏覽的
那張照片，所有星號與垃圾桶標記都完好無缺。標記不是只存在記憶體裡：每一次變動都會寫入
照片旁的一個狀態檔，而上次瀏覽到的照片也會在下次開啟時被還原。

#### 狀態檔

Halcyon 開啟的每個資料夾都有自己專屬的 `.halcyon_status.json`，寫在該資料夾的根目錄，
與照片放在一起。
<!-- evidence: lib/services/library/photo_status_store.dart:22-24 -->
它是一個扁平的 JSON 物件：每個照片 id（其檔名）對應到 `"starred"` 或 `"trashed"`——
未標記的照片單純不會出現在裡面，而不是寫成 `"unmarked"`——另外加上兩個保留鍵：
`_last_viewed_id` 用於還原瀏覽位置，`_rename_rule` 用於儲存該資料夾的重新命名規則。
<!-- evidence: lib/services/library/photo_status_store.dart:18,132-148 -->
選擇純 JSON 而非資料庫，是為了讓這個檔案直接放在照片資料夾裡，複製到別台機器或備份時
會一起跟著走，而且在 diff 中也能被人直接讀懂。
<!-- evidence: memory.md AD-004 -->

因為這個檔案存在資料夾內部而非集中式的 app 資料庫，每個資料夾的標記都是自成一體的：
開啟第二個資料夾會建立第二份、獨立的 `.halcyon_status.json`，不同拍攝場次之間的標記
不會互相污染。
<!-- evidence: lib/services/library/photo_status_store.dart:22-24 -->

損毀或無法讀取的狀態檔會降級為空白標記集合，而不是連整個資料夾都打不開——遺失標記
是可以復原的，但無法存取照片就不行了。
<!-- evidence: lib/services/library/photo_status_store.dart:34-53 -->

#### 重新開啟時還原

重新開啟資料夾時，Halcyon 會還原先前選取的照片：如果沒有指定明確的選取目標，就會退回
使用 `_last_viewed_id` 底下記錄的 id，前提是那張照片在剛掃描完的資料夾裡仍然存在。
<!-- evidence: lib/providers/app_state.dart:291-316 -->
瀏覽位置會在導覽動作穩定五秒後才寫入，這個防彈跳設計讓快速用方向鍵瀏覽時不會每按一次
就寫入一次。
<!-- evidence: lib/providers/app_state.dart:342-343,394-400 -->

#### 耐用性：原子寫入、同一時間只有一條寫入鏈

App 裡有兩個獨立的計時器都可能想寫入這個檔案——一個對應星號/垃圾桶標記，一個對應上次
瀏覽位置指標——而兩者都是先讀再改再寫。把所有寫入都串成單一佇列，代表先開始的那次寫入
絕不可能比另一個計時器晚結束、進而覆蓋掉對方已經寫入的變動。
<!-- evidence: memory.md G-019 -->
<!-- evidence: lib/services/library/photo_status_store.dart:55-66 -->
每一次寫入本身都是透過「先寫暫存檔、再更名」完成，所以就算拔卡或在寫入途中當機，也絕不會
留下寫到一半的狀態檔——資料夾裡永遠只會是舊的完整檔案，或新的完整檔案，不會是撕裂中的
半成品。
<!-- evidence: lib/services/library/photo_status_store.dart:68-76 -->

#### 誠實偵測唯讀資料夾

某些掛載方式下，目錄的權限位元並不可靠——一張 exFAT 記憶卡可能回報看似可寫的權限模式，
但實體防寫鎖卻讓每一次寫入都失敗。Halcyon 不相信這些權限位元：它會實際在資料夾裡建立
並刪除一個小檔案來探測可寫性，唯有確認資料夾真的是唯讀時，才會顯示一次性警告。
<!-- evidence: lib/services/library/photo_status_store.dart:78-91 -->
<!-- evidence: memory.md AD-009 -->
<!-- evidence: memory.md G-006 -->

#### 重新命名與標記

標記是以檔名為 key，沒有其他身分識別依據。如果照片是透過不經過 Halcyon 內建重新命名
功能的工具改名，綁在舊檔名上的標記就會被靜默孤立——它們不再對應資料夾裡任何一張照片。
Halcyon 自己的重新命名功能會在重新命名操作的同時，把狀態檔裡的每一個 key 都重新對應
到新檔名，藉此避免這個問題，因此星號、垃圾桶標記與瀏覽位置指標都能在 app 內完成的重新
命名之後存活下來。
<!-- evidence: memory.md G-011 -->
<!-- evidence: lib/services/library/photo_status_store.dart:185-203 -->

### 批次操作

#### 複製與移動已加星號的照片

已加星號的照片可以整批複製或移動到指定的目的地資料夾。
<!-- evidence: lib/services/library/photo_file_actions.dart:50-87 -->
一張 RAW 檔與其同名的 JPG 姐妹檔會被當成同一個單位一起搬動——星號標記是掛在這個項目
上，而不是掛在單一檔案上——而 macOS 在某些磁碟（exFAT、網路磁碟）上自動產生的
AppleDouble 側寫檔，也會一併清除，不會殘留在目的地。
<!-- evidence: lib/services/library/photo_file_actions.dart:63-84 -->
<!-- evidence: memory.md G-006 -->
預設情況下，目的地已存在的檔案會被保留不動（略過，而非覆蓋）；批次作業不會因單一失敗
而中止——其餘每個檔案仍會繼續嘗試，所有失敗都會被收集並顯示給使用者看，而不是被靜默
吞掉。
<!-- evidence: lib/services/library/photo_file_actions.dart:56-70,28-36 -->

#### 社群媒體匯出

已加星號的照片也可以匯出為適合社群媒體的縮圖 JPEG，一個項目對應一個檔案，解碼、縮放、
重新編碼全部在 Dart 端完成。長邊上限為 `2048` px，維持長寬比，輸出以 JPEG 品質 `90`
編碼。
<!-- evidence: lib/services/library/photo_export_service.dart:82,126,141 -->
核心 EXIF 欄位——相機廠牌/型號、拍攝日期、作者、曝光時間、光圈值、焦距、鏡頭型號、ISO
與 GPS 座標——會從原始來源檔重新讀出，並附加回縮放後的輸出檔；這是一組經過篩選的標籤，
不是完整的中繼資料區塊複製。
<!-- evidence: lib/services/library/photo_export_service.dart:144-216 -->
最多同時執行 `4` 個匯出工作，這個上限的考量是：一次完整的 RAW 解碼可能佔用數百 MB
的記憶體，若讓所有已加星號的項目在大批次中同時解碼，會有記憶體耗盡的風險。
<!-- evidence: lib/services/library/photo_export_service.dart:218-223,287-288 -->

#### 兩種刪除路徑

Halcyon 提供兩種截然不同的刪除方式，而且它們確實是兩種不同的產品體驗：

| 路徑 | 作用 | 平台 |
|---|---|---|
| 系統垃圾桶 | 透過原生橋接把檔案移到作業系統的垃圾桶 | macOS、Windows |
| 資料夾內回收模式 | 把檔案移到照片資料夾內的 `.trash` 子資料夾 | 任何平台 |

系統垃圾桶路徑是由 `halcyon/trash` method channel 支撐的。在 macOS 上，它註冊於
`AppDelegate.swift`，呼叫 `FileManager.default.trashItem`；在 Windows 上，它註冊於
`windows/runner/halcyon_channels.cpp`。
<!-- evidence: macos/Runner/AppDelegate.swift:23-24 -->
<!-- evidence: windows/runner/halcyon_channels.cpp:49-51 -->
<!-- evidence: memory.md AD-008 -->
在 Android、iOS、Linux 與 web 這幾個 runner 目錄中搜尋 `halcyon/trash`，找不到任何
註冊，因此系統垃圾桶路徑僅限 macOS 與 Windows。資料夾內回收模式是一個使用者可切換、
以資料夾為單位的預設值（對含有 RAW+JPG 姐妹檔的資料夾會自動開啟），而不是自動的
後備方案；在沒有原生 channel 的平台上，若選擇直接走系統垃圾桶刪除，會拋出
`TrashException`，而不是靜默地什麼都不做。
<!-- evidence: lib/providers/app_state.dart:130,166,287,498-515 -->
<!-- evidence: lib/services/platform/trash_service.dart:9-19 -->

資料夾內回收模式會把已標記刪除項目的每一個檔案——包括其 RAW 姐妹檔與任何 AppleDouble
側寫檔——移到照片旁的 `.trash` 子資料夾，而不經過作業系統。這是同一個磁碟區內的更名
操作，因此即使在系統垃圾桶 API 不可用的記憶卡上也能運作，而且因為不涉及資料複製，
速度是即時的。
<!-- evidence: lib/services/library/photo_file_actions.dart:114-155 -->
<!-- evidence: memory.md AD-013 -->
與先前回收批次的檔名碰撞絕不會被覆蓋：移動程序會依序附加 `-1`、`-2`……直到找到一個
可用的檔名為止。
<!-- evidence: lib/services/library/photo_file_actions.dart:157-171 -->

批次刪除的失敗會擋下流程：任何失敗的檔案都會跳出一個對話框，清楚列出哪些檔案失敗及
原因，因為一次靜默無效的刪除，跟一個壞掉的 app 看起來沒有兩樣。成功的回收模式批次則
會在狀態列顯示一則暫時性訊息，附上移動的檔案數，提醒使用者這些檔案仍在磁碟上的
`.trash` 裡，並未被永久刪除。
<!-- evidence: lib/views/batch_delete_feedback.dart:12-40 -->
