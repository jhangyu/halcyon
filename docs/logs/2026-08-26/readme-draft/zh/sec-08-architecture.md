## 架構

Halcyon 分層為 `views/` → `providers/app_state.dart` → `services/` → `models/`，
相依方向單向流動。本節說明這個分層在程式碼中如何維繫、貢獻者不可隨意打破的兩道
縫，以及每樣東西在硬碟上的位置。

### 分層與相依方向

`views/` 建構 UI 並持有 view 本地狀態——鍵盤快捷鍵、縮放變換、對話框骨架。它透過
`provider` 套件讀取 `AppState` 並呼叫其方法；它不應該知道照片是如何被掃描、解碼或
刪除的。

`providers/app_state.dart` 定義了 `AppState extends ChangeNotifier`
（`lib/providers/app_state.dart:61`），是應用程式邏輯的唯一協調點——資料夾載入、
選取、星標/垃圾桶標記、設定，以及派送到服務層。它透過建構子注入來組合協作者，
而非把它們寫死成欄位：

<!-- evidence: lib/providers/app_state.dart:62-104 -->
```dart
AppState({
  PhotoLibraryScanner? scanner,
  PhotoStatusStore? statusStore,
  PhotoFileActions? fileActions,
  ImagePreloadController? preloadController,
  NativeImageLoad? imageLoader,
  DngFullDecoder? dngDecoder,
  PhotoExportService? exportService,
  ExifBatchReader? exifReader,
})
```

每個參數在省略時都會退回到真實實作（例如
`_scanner = scanner ?? PhotoLibraryScanner()`），所以正式環境的程式碼免費取得真實
的協作者，同時測試可以把其中任何一個替換成假物件。
<!-- evidence: lib/providers/app_state.dart:71-91 -->

這正是讓協調層可測試、不需要碰真實檔案系統或平台通道的原因。
`test/providers/app_state_test.dart` 透過 `_testState()` 輔助函式建構每一個受測的
`AppState`，注入一個回傳固定 bytes 的假 `imageLoader` closure 來取代真的解碼檔案，
同一檔案中其他地方也注入 `PhotoFileActions(trashFile: (file) async { ... })` 來記錄
呼叫而非真的觸碰系統垃圾桶，以及一個 `PhotoLibraryScanner` 子類別（`_FixedScanner`、
`_ThrowingScanner`），依需求回傳固定項目清單或拋出例外，而不是走訪目錄。
<!-- evidence: test/providers/app_state_test.dart:577-597 -->
<!-- evidence: test/providers/app_state_test.dart:420 -->

`services/` 實作實際的工作——檔案系統掃描、狀態持久化、影像解碼/快取、檔案操作、
EXIF/重新命名，以及兩個平台橋接——並且禁止回頭直接呼叫 `views/` 或 `AppState`；
它只被呼叫，不會回呼，除非透過 `AppState` 明確交付的 callback/supplier 參數（見下方
`RenameCoordinator` 的說明）。`models/` 持有純粹的資料形狀與無 I/O 的純函式——
`PhotoItem`、格式註冊表，以及 `RenameRule` 的樣板渲染——並且不應該從 `services/` 或
`views/` 匯入。

**反向資料流危害。** `docs/sop/memory.md` G-010 記錄了 `main_detail_view.dart` 曾經從 widget
的 build/callback 程式碼直接寫入 `AppState` 的公開縮放欄位
（`context.read<AppState>().pointerPosition = event.localPosition` 之類），打破了
單向流動——一個 view 在方法呼叫之外變動 provider 狀態。修法是抽出一個獨立的
`ZoomController extends ChangeNotifier`（`lib/views/zoom_controller.dart`），由
`MainScreen` 持有並負責釋放，現在 `AppState` 完全不再帶有任何縮放欄位。目前的規則
是：view 本地、由動畫驅動的狀態（縮放、指標位置、變換矩陣）應該放在 view 持有的
controller 裡，而不是 `AppState`；`AppState` 只保存代表應用程式相簿模型的狀態。
<!-- evidence: docs/sop/memory.md G-010 -->

**四個服務子資料夾。** `services/` 被拆成四個按用途命名的子資料夾，而不是留成一個
扁平的目錄：

| 資料夾 | 負責範圍 |
|---|---|
| `image_pipeline/` | 第一層/第二層滑動視窗預載、DNG 解碼整合、影像快取記帳（18 個檔案） |
| `library/` | 資料夾掃描、狀態持久化、檔案複製/搬移/丟垃圾桶、星標照片匯出 |
| `rename/` | EXIF 驅動的重新命名規劃、EXIF 中繼資料讀取、重新命名協調器 |
| `platform/` | 兩個 macOS `MethodChannel` 橋接 |

在同一次重新組織中，`rename_rule.dart` 從 `services/` 改分類進了
`models/rename_rule.dart`，因為它是純樣板渲染、沒有 I/O，因此比較符合 `models/`
的定義而非 `services/`。
<!-- evidence: docs/sop/memory.md AD-030 -->

### 縫與不變量

以下是影像管線中承重的限制條件；隨意更動會打破本 README 其他地方描述的
第一層/第二層契約。

**Ceyx 整合縫。** DNG 全尺寸解碼——針對沒有可用內嵌預覽圖的 DNG——透過一個
typedef、而非具體類別，委派給姊妹專案 Ceyx：

<!-- evidence: lib/services/image_pipeline/dng_decode_contract.dart:30 -->
```dart
typedef DngFullDecoder = Future<DecodedRgba> Function(String path);
```

這道縫存在的目的，就是讓影像管線可以針對一個假解碼器做單元測試，而不必載入真正的
native dylib。
<!-- evidence: lib/services/image_pipeline/dng_decode_contract.dart:3-8 -->

與其搭配的，`image_source_types.dart` 宣告了一個恰好有三個變體的 sealed class，
描述任何影像位元組請求的結果：`NativeImageBytes`（已編碼的位元組，正常路徑）、
`NativeImageNeedsRawDecode`（沒有內嵌預覽圖的 DNG——這不是失敗，而是一個訊號，
表示要跑真正的 RAW 解碼器）、以及 `NativeImageFailure`（真正的失敗）。這個型別被
文件明確標記為凍結狀態：「恰好三個變體；未經 squad lead 簽核不得新增第四個。」
<!-- evidence: lib/services/image_pipeline/image_source_types.dart:41-87 -->

**影像載入在每個平台上都是純 Dart。** `dartImageLoad`
（`lib/services/image_pipeline/dart_image_loader.dart:17`）是影像位元組的唯一產生
來源；沒有任何平台存在原生縮圖通道。`docs/sop/memory.md` AD-020 記錄了這個決策背後的契約：
照片相關行為（哪些檔案會被載入、畫面上出現什麼像素、刪除做了什麼、匯出產出什麼）
只在 Dart 中實作一次，且必須在每個支援的平台上產生相同的可觀察結果，唯一的例外是
三個封閉、不可再擴充的原生橋接：系統垃圾桶（macOS/Windows 原生）、Open With 傳輸層
（macOS/Windows/Android/iOS，不含 Linux），以及檔案關聯註冊（Windows/macOS）。
文件明確聲明這份清單是封閉的——不得以這三項作為先例來新增更多平台差異。
<!-- evidence: docs/sop/memory.md AD-020 -->

**單一持有者不變量。** 有兩個類別各自持有恰好一份第二層狀態，使該不變量可以在單一
位置被推理與測試，而不是散落到各個呼叫點：

- `TierTwoRegistry`（`lib/services/image_pipeline/tier_two_registry.dart:26`）是
  第二層*就緒狀態*記帳的唯一持有者——哪些 id 有全尺寸快取項目、它是針對哪個 payload
  物件解碼的，以及該次解碼是否已失敗。
- `TierTwoScheduler`（`lib/services/image_pipeline/tier_two_scheduler.dart:58`）是
  第二層*排程*的唯一持有者——±2 視窗、250ms 導覽 debounce，以及序列化的解碼佇列。

`docs/sop/memory.md` AD-027 與 AD-028 記錄了為何要把這些拆成兩個類別而非一個：在拆分之前，
兩個經審查標記出的 bug（一個過期的就緒旗標，以及一個對仍在處理中的項目回傳 true 的
`containsKey` 檢查）只靠註解來防範；把四個就緒容器抽進自己的類別後，它們可以獨立
測試，而把排程留在另一個第三個類別中，代表若把兩者合併回去會悄悄地重新耦合狀態與
時序。
<!-- evidence: docs/sop/memory.md AD-027 -->
<!-- evidence: docs/sop/memory.md AD-028 -->

**原生橋接。** `macos/Runner/AppDelegate.swift` 恰好註冊了兩個 `MethodChannel`——
以 `grep -n "FlutterMethodChannel(name:" macos/Runner/AppDelegate.swift` 驗證，
回傳兩筆相符結果，`halcyon/trash`（第 23 行）與 `halcyon/open_with`（第 42 行）：
<!-- evidence: macos/Runner/AppDelegate.swift:23,42 -->

```dart
FlutterMethodChannel(name: "halcyon/trash", ...)
FlutterMethodChannel(name: "halcyon/open_with", ...)
```

`halcyon/open_with` 是純推送式的：由原生端呼叫進 Dart 端來遞送檔案路徑，Dart 端
在這個通道上沒有方法可以主動詢問原生端「有沒有東西還在等待」。原因是冷啟動時序——
在檔案抵達的那一刻，Flutter engine 可能還沒有註冊好 Dart 端的 handler；若在那個
時間窗內由 Dart 端主動發起查詢會拋出例外。Flutter 的通道實作會緩衝原生→Dart 方向
送出的訊息，直到 Dart 端的 handler 註冊完成為止，因此推送式在啟動時是可靠的方向。
在通道物件本身建立之前抵達的事件，會被暫存在一個 `pendingOpenFile` 變數中，並在
通道建立的當下立即被清空送出。
<!-- evidence: macos/Runner/AppDelegate.swift:12-49 -->
<!-- evidence: docs/sop/memory.md AD-012 -->

這個以 grep 驗證的步驟在這裡特別重要，原因是 `docs/sop/memory.md` G-017：這個 repository
自己的文件曾經整整描述過一個里程碑份量的 `halcyon/thumbnail` 通道與一個
`NativeThumbnailService`，而它們其實早就已經被刪除了，其中還包含一個過期的行號
引用。記錄下來的規則是：用 `grep -n "MethodChannel"` 對照 `AppDelegate.swift` 來
檢查原生橋接的說法，而不是憑說法讀起來是否合理來判斷。
<!-- evidence: docs/sop/memory.md G-017 -->

**唯一一份 EXIF 方向表。** `exif_orientation.dart` 的 `exifTransformFor` 是這個
專案唯一的 8 case Orientation 標籤對照表；不論是以 `package:image` 為基礎的匯出
路徑，還是以 `dart:ui` 為基礎的全尺寸 RGBA provider，都是透過這唯一一張表來轉換，
而不是各自實作自己的方向邏輯，而且兩者都以固定的順序先旋轉再鏡像。
<!-- evidence: docs/sop/memory.md AD-024 -->

### 目錄結構

以下是經對照目前實際的樹狀結構驗證過的頂層目錄結構標註——而不是只對照
內部目錄地圖文件（見下方說明），因為它可能落後於同一天內發生的重新組織：

```
Halcyon/
├── lib/
│   ├── main.dart              # ChangeNotifierProvider + MaterialApp setup
│   ├── models/                # PhotoItem, format registry, RenameRule (pure, no I/O)
│   ├── perf/                  # opt-in performance instrumentation
│   ├── providers/
│   │   └── app_state.dart     # AppState: the single coordination point
│   ├── services/
│   │   ├── image_pipeline/    # tier-1/tier-2 preload, DNG decode, cache bookkeeping
│   │   ├── library/           # folder scan, status persistence, file ops, export
│   │   ├── rename/            # EXIF-driven rename planning + coordinator
│   │   └── platform/          # the two macOS MethodChannel bridges
│   └── views/                 # UI, keyboard shortcuts, dialogs
├── test/                      # mirrors the lib/ tree above, plus test/support/
├── macos/ ios/ android/ web/ windows/ linux/   # per-platform runner shells
├── scripts/
│   └── build_apps.py          # the single build entry point for all six targets
├── docs/
│   ├── logs/YYYY-MM-DD/       # dated task logs; recorded measurements live here
│   └── sop/                   # 未受版控追蹤的內部維護文件；全新 clone 不會包含
└── README.md
```
<!-- evidence: docs/sop/file_index.md:44-102 -->

**內部維護文件。** Halcyon 在工作副本（working checkout）的 `docs/sop/` 目錄下維護
一組內部流程文件——架構決策與踩坑經驗、任務追蹤、階段里程碑、短期交接摘要，
以及測試策略與測試案例矩陣。這些文件刻意不受版本控制（已加入 `.gitignore`），
因此全新 clone 這個 repository 不會包含它們。本 README 中的部分陳述
（包含影像管線與原生橋接相關章節）取材自這些文件。

授權與第三方歸屬說明收錄在本文件結尾的
[第三方歸屬](#第三方歸屬)一節。
