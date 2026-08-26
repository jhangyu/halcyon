## 挑選工作流程（triage workflow）

這是核心迴圈：開啟一個資料夾、瀏覽它、標記照片、繼續下一張。以下描述的是攝影師面對一整張裝滿
RAW 與 JPG 檔案的記憶卡時，這個 app 實際會做的事。

### 開啟資料夾

`PhotoLibraryScanner.scan()` 用 `dir.list(followLinks: false)` 列出該目錄的直接內容，
不會遞迴進入子目錄——只有直接放在所選資料夾內的檔案會被抓到。
<!-- evidence: lib/services/library/photo_library_scanner.dart:8 -->

每個項目在被視為照片之前都會經過篩選：必須是一般檔案、名稱不能以 `.` 開頭
（dotfile／AppleDouble 側寫檔會被跳過），且副檔名必須在支援清單內。
<!-- evidence: lib/services/library/photo_library_scanner.dart:11-16 -->

支援的副檔名為 `.jpg`、`.jpeg`、`.arw`、`.rw2`、`.dng`、`.png`、`.cr2`、`.nef`、`.orf`。
<!-- evidence: lib/models/supported_photo_formats.dart:6-16 -->

符合的檔案會被分組（見下節）成 `PhotoItem`，最終清單依 id 排序，且不分大小寫。
<!-- evidence: lib/services/library/photo_library_scanner.dart:22-26 -->

### RAW 與 JPG 的 sibling 分組

分組鍵是去除副檔名後的檔名——`SupportedPhotoFormats.photoIdFor()` 回傳
`p.basenameWithoutExtension(file.path)`。所有共用同一個檔名主體的檔案，無論副檔名為何，
都會歸入同一個鍵下的 `List<File>`。
<!-- evidence: lib/models/supported_photo_formats.dart:41-43 -->
<!-- evidence: lib/services/library/photo_library_scanner.dart:14-19 -->

這個分組後的清單會變成單一個 `PhotoItem(id: entry.key, files: entry.value)`——不論群組內有
多少檔案，都只有一個側邊欄項目、一個 `PhotoStatus`、一列供使用者互動的資料。
<!-- evidence: lib/services/library/photo_library_scanner.dart:22-24 -->
<!-- evidence: lib/models/photo_item.dart:7-16 -->

app 實際載入哪個檔案來顯示，由 `bestFileToLoad()` 決定：它依固定的優先順序
（`.jpg`、`.jpeg`、`.png`）尋找，回傳第一個相符者；若群組內沒有這些副檔名，則退回群組中第一個
支援的檔案；只有在整個群組都不受支援時，才會退回任意一個檔案。
<!-- evidence: lib/models/supported_photo_formats.dart:45-61 -->

在下游行為上，只要資料夾內存在任何多檔案群組（也就是任何 RAW+JPG 配對），app 就會預設使用
資源回收模式刪除而非永久刪除，理由是：正在被挑選的記憶卡不該因為一次誤點就連 RAW 一起丟失。
<!-- evidence: lib/providers/app_state.dart:285-287 -->

標記或刪除是作用在 `PhotoItem` 上的，所以一次星號或垃圾桶動作會套用到群組內的每一個檔案——
RAW 與其 JPG sibling 會作為同一個單位一起移動。
<!-- evidence: lib/models/photo_item.dart:10 -->

### 標記

除了「未標記」之外還有兩種標記狀態：`starred`（星號）與 `trashed`（垃圾桶）
（`PhotoStatus` enum）。`markCurrent(status)` 是切換式的：再次按下同一個標記會清回
`unmarked`；按下不同的標記則會設定它。**切換關閉**時不會自動前進；**設定新標記**時，
若已啟用自動前進，則會前進。
<!-- evidence: lib/providers/app_state.dart:367-381 -->
<!-- evidence: memory.md G-005 -->

自動前進是一個會被持久化的使用者偏好設定（`SharedPreferences` 鍵值 `autoAdvance`，
預設為 `false`），透過 `setAutoAdvance()` 切換。
<!-- evidence: lib/providers/app_state.dart:139,151,405-409 -->

浮動的操作列（action bar）呼叫的是同一組方法——星號與垃圾桶／回收模式按鈕都呼叫
`AppState.markCurrent()`，且垃圾桶圖示的圖形與提示文字會依回收模式在「刪除」與
「從垃圾桶還原」之間切換。
<!-- evidence: lib/views/photo_action_bar.dart:49-69 -->

每次標記變更都會即時寫入磁碟（`_saveStatusCache()`）；儲存格式與復原（resume）行為留待
本文件其他章節說明。
<!-- evidence: lib/providers/app_state.dart:378 -->

### 導覽與縮放

`←`／`→` 在目前排序好的清單中依索引移動到上一張／下一張，並有邊界檢查（頭尾皆不會循環）。
<!-- evidence: lib/providers/app_state.dart:351-365 -->

縮放完全獨立於 `AppState` 之外，由 `MainScreen` 建立並釋放的專屬 `ZoomController` 持有——
刻意不放在 detail view，因為 detail view 在每次切換照片時都會重建，若放在其內部，
使用者按左右鍵切換照片時縮放層級就會被重置。
<!-- evidence: lib/views/zoom_controller.dart:10-15 -->
<!-- evidence: memory.md AD-015 -->

每次縮放都以固定倍率 `1.25` 乘除目前的縮放比例，上限為 `5.0×`。縮小到 `1.05×` 或以下時，
會直接吸附回單位矩陣（identity matrix），而不是停在剛好超過 `1.0×` 的位置，藉此避免殘留的
平移偏移。
<!-- evidence: lib/views/zoom_controller.dart:44,50-58,60-75 -->

### 鍵盤快捷鍵

觸發挑選流程的所有鍵盤處理都集中在同一處——`MainScreen` 內單一個 `Focus` widget 的
`onKeyEvent` callback。這是 app 註冊的完整按鍵集合；`lib/` 底下沒有其他檔案掛接鍵盤處理。
<!-- evidence: lib/views/main_screen.dart:97-135 -->

| 按鍵 | 動作 |
|---|---|
| `←` | 上一張照片 |
| `→` | 下一張照片 |
| `↑` | 放大（每次 ×1.25，最高 5×）|
| `↓` | 縮小（每次 ×1.25，縮到約 1.05× 以下會吸附回原尺寸）|
| `S` | 切換目前照片的星號標記 |
| `X` | 切換目前照片的垃圾桶標記 |
| `R` | 切換回收模式（資料夾內的 `.trash/` vs. 永久／系統刪除）|

<!-- evidence: lib/views/main_screen.dart:104-129 -->

回收模式也可以透過右鍵點擊操作列中的垃圾桶圖示來切換；左鍵點擊該圖示則維持它原本
「標記這張照片」的意思。
<!-- evidence: lib/views/photo_action_bar.dart:60-68 -->

### 挑選過程中的畫面回饋

即時狀態訊息由自訂的 `StatusLine` widget 顯示（位於視窗底部），它取代了 Flutter 的
`SnackBar`，改用固定且明確的時序：完全顯示 2.5 秒，接著 0.5 秒淡出，然後移除。
<!-- evidence: lib/views/status_line.dart:25-26 -->
<!-- evidence: memory.md AD-009 -->

挑選流程本身會直接觸發兩則回饋訊息：

- 開啟資料夾時，若發現該資料夾不可寫入，會顯示一次性警告——每次呼叫 `loadFolder()`
  只出現一次，而非每次標記都出現。可寫性的檢查方式是實際建立再刪除一個探測檔案，而非讀取
  Unix 權限位元，因為在以 `noowners` 掛載的 exFAT 記憶卡上，權限位元並不可靠。
  <!-- evidence: lib/providers/app_state.dart:288-289 -->
  <!-- evidence: memory.md AD-009 -->
- 若資料夾掃描本身拋出例外（例如遍歷目錄時發生的權限錯誤），會顯示錯誤訊息，並附上底層
  例外文字。
  <!-- evidence: lib/providers/app_state.dart:324-326 -->
