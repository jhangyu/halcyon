## 依 EXIF 重新命名

攝影師依拍攝日期、相機、鏡頭或序號為檔案命名，而命名格式通常是自家慣例，不會是相機寫入
記憶卡的原始檔名。Halcyon 的重新命名功能是一套針對 EXIF 與檔案系統中繼資料的小型樣板引擎：
寫一次樣板、套用到整個資料夾，每個 RAW 檔、它的 JPG 對應檔，以及任何側車檔（AppleDouble
格式的 `._DSC_0431.NEF` 之類）都會一起改成相同的新基底檔名。
<!-- evidence: lib/models/rename_rule.dart:30-35 -->

### 樣板模型

規則就是一個字串樣板，例如 `{YYYY}-{MM}-{DD}-{hh}-{mm}-{ss}`。渲染樣板是純函式——完全不
碰檔案系統——因此整套命名策略無需在硬碟上放任何照片就能單元測試。
<!-- evidence: lib/models/rename_rule.dart:30-39 -->

渲染器認得的每個 `{token}`，分組方式與規則編輯器「Insert variable」面板完全一致：
<!-- evidence: lib/views/rename_dialog/rule_editor.dart:70-90 -->

| 分組 | 變數 | 對應內容 | 範例 |
|---|---|---|---|
| Date/time | `{YYYY}` | 拍攝年份，4 位數 | `2026` |
| Date/time | `{MM}` | 拍攝月份，2 位數 | `08` |
| Date/time | `{DD}` | 拍攝日期，2 位數 | `26` |
| Date/time | `{hh}` | 拍攝小時，2 位數 | `14` |
| Date/time | `{mm}` | 拍攝分鐘，2 位數 | `07` |
| Date/time | `{ss}` | 拍攝秒數，2 位數 | `33` |
| Camera | `{camera}` | EXIF 相機型號，缺值為空字串 | `Z 8` |
| Camera | `{lens}` | EXIF 鏡頭型號，缺值為空字串 | `NIKKOR Z 24-70mm f_2.8 S` |
| Camera | `{make}` | EXIF 相機製造商，缺值為空字串 | `NIKON CORPORATION` |
| Camera | `{artist}` | EXIF artist/copyright 標籤，缺值為空字串 | `J. Chen` |
| Shooting | `{f}` | 光圈值，格式為 `f<數值>`，缺值為空字串 | `f2.8` |
| Shooting | `{focal}` | 焦距，格式為 `<數值>mm`，缺值為空字串 | `35mm` |
| Shooting | `{iso}` | ISO 值，格式為 `ISO<數值>`，缺值為空字串 | `ISO400` |
| Shooting | `{shutter}` | 快門速度，依 EXIF 印出的原始寫法，缺值為空字串 | `1/250` |
| Shooting | `{direction}` | GPS 拍攝方向，四捨五入至整數度，缺值為空字串 | `187` |
| File | `{seq}` | 在套用 `{seq}` 前渲染結果相同（會碰撞）的檔案之間，依 1 起算的序號；支援補零寬度，如 `{seq:3}` → `007` | `1` |
| File | `{orig}` | 原始檔名的基底（不含副檔名） | `DSC_0431` |
<!-- evidence: lib/models/rename_rule.dart:50-124 -->

當 EXIF 沒有拍攝日期（或整個 EXIF 讀取失敗）時，日期/時間欄位會退回使用檔案的檔案系統
修改時間——渲染器一定有「某個」日期可用，只是在這種情況下不一定是實際拍攝日期。
<!-- evidence: lib/models/rename_rule.dart:96 -->

任何沒有 EXIF 值的欄位會渲染為空字串，而不是佔位符——重新命名對話框的預覽清單也明白寫著
「缺失的中繼資料會渲染為空字串」。
<!-- evidence: lib/models/rename_rule.dart:107-119 -->
<!-- evidence: lib/views/rename_dialog/preview_list.dart:87-92 -->

樣板中若含有這張表以外的任何 token，在能執行之前就會被拒絕：編輯器會顯示「Unknown
variable {name}」，且「Run」按鈕會被停用。
<!-- evidence: lib/models/rename_rule.dart:65-77 -->
<!-- evidence: lib/views/rename_dialog/actions.dart:52-53 -->

渲染出來的檔名會經過檔案系統安全性清理：`/`、`:`、`\` 與 NUL 一律替換為 `_`（`:` 之所以
重要，是因為它在傳統 Mac OS 層是路徑分隔符，在 Finder 裡仍會顯示成 `/`，而 `1/250` 這類
未經處理的快門速度渲染結果，本會建立出一個子目錄），並移除頭尾的空白與句點。
<!-- evidence: lib/models/rename_rule.dart:128-134 -->

### 預設樣板

應用程式內建四組預設樣板，可在對話框的預設清單中選取。以一張 2026-08-26 14:07:33 拍攝、
基底檔名為 `DSC_0431`、且不與其他項目在中繼資料上碰撞（`{seq}` = 1）的檔案為例，渲染結果
如下：

| 預設 | 樣板 | 渲染範例 |
|---|---|---|
| Date & time | `{YYYY}-{MM}-{DD}-{hh}-{mm}-{ss}` | `2026-08-26-14-07-33` |
| Compact | `{YYYY}{MM}{DD}_{hh}{mm}{ss}` | `20260826_140733` |
| Camera-style | `IMG_{YYYY}{MM}{DD}_{hh}{mm}{ss}` | `IMG_20260826_140733` |
| Date + sequence | `{YYYY}-{MM}-{DD}_{seq}` | `2026-08-26_1` |
<!-- evidence: lib/models/rename_rule.dart:43-48 -->

「Date & time」同時也是全新對話框開啟時的預設樣板。
<!-- evidence: lib/models/rename_rule.dart:41 -->
<!-- evidence: lib/views/rename_dialog/rename_dialog.dart:33-35 -->

在選取某個預設樣板的狀態下編輯樣板文字（或插入變數 chip），選取狀態會切換到名為
`Custom...` 的偽預設項目；只有自訂規則會依資料夾記住，重新開啟一個最後一次是以自訂規則
重新命名過的資料夾時，會還原成當初那個確切的樣板。
<!-- evidence: lib/views/rename_dialog/rename_dialog.dart:61-70 -->
<!-- evidence: lib/views/rename_dialog/rename_dialog.dart:101-113 -->

### 對話框與即時預覽

對話框分為兩個窗格：左側是預設選擇器、規則文字欄位與變數 chip（`RuleEditor`），右側是
即時預覽清單（`RenamePreviewList`）。開啟對話框時會從目前資料夾隨機抽取五個項目，並讀取
一次它們的 EXIF；規則欄位每次按鍵都會針對這已讀取的中繼資料重新渲染這五列預覽，不會重新
讀取 EXIF。
<!-- evidence: lib/views/rename_dialog/rename_dialog.dart:72-84 -->
<!-- evidence: lib/views/rename_dialog/preview_list.dart:98-107 -->

「Re-roll」控制項會重新抽取五個隨機項目並重新讀取一次中繼資料。每一列預覽會顯示目前檔名
（加上刪除線）、一個箭頭、渲染後的新基底檔名加上副檔名、該項目擁有的每個附屬副檔名各一個
徽章（讓使用者在送出前就能看到 RAW+JPG 這類配對會一起移動），以及當樣板引用 `{camera}`
而此項目沒有該標籤時的「no camera tag」徽章。
<!-- evidence: lib/views/rename_dialog/preview_list.dart:98-116 -->

只要目前樣板有驗證錯誤（未知變數、空樣板，或渲染結果為空字串的樣板），「Run Rename」按鈕
就會被停用，因此無效規則無法被套用。
<!-- evidence: lib/models/rename_rule.dart:73-87 -->
<!-- evidence: lib/views/rename_dialog/actions.dart:52-53 -->

此對話框只能套用到整個資料夾——沒有逐項選取，頁尾也明白寫著項目數量是套用到整個資料夾。
<!-- evidence: lib/views/rename_dialog/rename_dialog.dart:200 -->
<!-- evidence: lib/views/rename_dialog/actions.dart:29-34 -->

### EXIF 從哪裡來，以及成本模型

EXIF 是以「每個項目一次」而非「每個檔案一次」讀取：`PhotoItem.bestFileToLoad` 選出要讀取
EXIF 的來源檔案，執行重新命名時，這單一一次讀取結果會套用到該群組中的每一個附屬檔案（RAW、
JPG、側車檔）。
<!-- evidence: memory.md AD-017 -->
<!-- evidence: lib/providers/app_state.dart:547-564 -->

`bestFileToLoad` 在有 `.jpg`/`.jpeg`/`.png` 對應檔時會優先選它，而不是 RAW 檔本身；找不到
時退回本應用程式可解碼的第一個檔案，若群組內完全沒有可解碼的檔案，再退回該群組的第一個檔案。
<!-- evidence: lib/models/supported_photo_formats.dart:18-22 -->
<!-- evidence: lib/models/supported_photo_formats.dart:45-61 -->

使用者可見的後果是：對於沒有 JPG 對應檔的 RAW 拍攝，EXIF 會直接透過 `exif` 套件從 RAW 檔
自己的檔頭讀取，且因為解析 RAW 檔頭需要掃描數 MB 的資料，這個讀取會在 UI isolate 之外執行。
若這次讀取失敗，或該 RAW 格式的檔頭不是 `exif` 套件能解析的格式，該項目的中繼資料就會是
`null`，樣板中的每個 EXIF token 對它而言都會渲染為空字串——只有日期/時間 token 仍會解出
結果，退回使用該檔案的修改時間。
<!-- evidence: lib/services/rename/exif_metadata_service.dart:66-75 -->
<!-- evidence: lib/models/rename_rule.dart:96 -->

EXIF 讀取以每批 500 個路徑為單位分批進行，讓大型資料夾仍能回報漸進式進度，而不是卡在單一
巨大批次上；對話框會將此進度顯示為狀態列文字「讀取 EXIF *done/total*…」。
<!-- evidence: lib/services/rename/exif_metadata_service.dart:18-42 -->
<!-- evidence: lib/services/rename/rename_coordinator.dart:86-91 -->

### 如何套用重新命名

命名策略與檔案 I/O 是兩個各自獨立的函式：`planRenames` 在完全不碰硬碟的情況下計算每一步
搬移動作，只有 `applyRenames` 才會真正執行 `File.rename` 呼叫。`planRenames` 是純函式，因此
整套碰撞規避策略無需在硬碟上放任何照片就能測試。
<!-- evidence: memory.md AD-016 -->
<!-- evidence: lib/services/rename/rename_service.dart:32-41 -->

重新命名以序列方式逐一計畫執行。`File.rename` 是同一 volume 內的中繼資料操作，平行化沒有
效益，反而會讓 planner 的碰撞規避退化成 race。
<!-- evidence: lib/services/rename/rename_service.dart:143-146 -->

**實作中的碰撞規則。** 項目先依它們在 `{seq}` = 1 時會渲染出的結果分組；同一組內每個彼此
碰撞的項目，會依排序後的項目 id 取得其在組內的位置，指派一個確定性的、1 起算的序號——因此
編號結果不受掃描順序影響。若最終候選檔名仍與資料夾中已存在的檔名（或本批次中已被稍早項目
佔用的檔名）碰撞，就會附加數字後綴 `-1`、`-2`……直到取得未被佔用的檔名為止。若某項目最終
渲染出的檔名與它目前的檔名相同，就會從計畫中剔除——沒有實際變化的重新命名不會產生一筆
undo 紀錄。
<!-- evidence: lib/services/rename/rename_service.dart:58-85 -->

屬於同一個項目的所有檔案——RAW 檔、JPG 對應檔，以及資料夾中若存在的 AppleDouble 側車檔
（`._<name>`）——都會改成相同的新基底檔名，各自保留原本的副檔名，因此 RAW+JPG 配對或
RAW+側車檔配對在重新命名過程中絕不會被拆散。
<!-- evidence: lib/services/rename/rename_service.dart:87-105 -->

每一步搬移動作在完成的當下就會被附加寫入資料夾中的 `.halcyon_rename_log.jsonl`（這是一個
只附加、一行一個 JSON 物件的日誌，而不是每次重寫整個陣列，因此批次執行到一半當機也不會
損毀或遺失先前的搬移紀錄），這也是對話框「Undo」動作背後的機制——日誌會被倒著重播，然後
刪除。
<!-- evidence: lib/services/rename/rename_service.dart:123-192 -->
<!-- evidence: lib/services/rename/rename_service.dart:194-244 -->

因為 `.halcyon_status.json`（星號、垃圾桶標記、最後檢視的 id）是以檔名為 key，協調器會在
每次重新命名批次完成後、以及每次還原（undo，方向相反）之後，立即重新映射每一個變動過的
key——否則每一個標記都會靜默地孤立在一個已不存在的檔名底下。
<!-- evidence: memory.md G-011 -->
<!-- evidence: lib/services/rename/rename_coordinator.dart:136-141 -->
<!-- evidence: lib/services/rename/rename_coordinator.dart:182-189 -->

若 Halcyon 已判定某資料夾無法寫入，重新命名對話框本身就無法被開啟——對話框自己的頁尾也
明白寫著這一點。
<!-- evidence: lib/views/rename_dialog/actions.dart:29-34 -->

### 已知限制

- 沒有對應 EXIF 標籤的欄位——或整個 EXIF 根本讀取失敗的照片——會在檔名該位置渲染為空
  字串；樣板不會退回使用其他欄位。
  <!-- evidence: lib/models/rename_rule.dart:107-119 -->
- 只有 RAW、沒有 JPG 對應檔的項目，其 EXIF 完全仰賴 `exif` 套件能否解析該 RAW 檔自己的
  檔頭；這條路徑上沒有專用的 RAW EXIF 解析器，若某個 RAW 格式是該套件無法解析的，該項目
  就得不到任何中繼資料，而不是部分讀取結果。
  <!-- evidence: lib/services/rename/exif_metadata_service.dart:66-93 -->
