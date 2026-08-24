# Halcyon 跨平台移植盤點（macOS → Windows / Android / iOS）

日期：2026-08-20　範圍：唯讀盤點，未修改任何程式碼。

## 結論先行

1. **四個 MethodChannel 只有 macOS 有原生實作**。其他平台全部 `MissingPluginException`。其中只有 `halcyon/trash` 與 `halcyon/exif` 有正確的降級處理，`halcyon/thumbnail` 沒有 → 這是「換平台就整個看不到圖」的單點。
2. **真正的阻斷不是抽象層不夠，是 `dng_processor` 根本不是 Flutter plugin**（`../flutter_dng_decoder/dng_processor/pubspec.yaml` 無 `flutter: plugin:` 區塊，只是一個被當 path dependency 用的 app 專案），原生庫靠 `DynamicLibrary.open` 加寫死的開發機路徑載入（`dng_bindings.dart:339`）。這件事不修，RAW 解碼在任何平台（含 macOS 正式出貨）都不可靠。
3. **Android 現在連編都編不起來**：`MainActivity.kt` 在 `com/example/photo_selector_flutter/`，但 `android/app/build.gradle.kts:11,22` 的 namespace/applicationId 是 `com.example.halcyon`，manifest 用 `.MainActivity` 相對解析 → class not found。
4. 抽象接縫**已經夠用**（AppState 建構子注入、`DngFullDecoder`、`ThumbnailLoader`、`ExifBatchReader`、`NativeImageResult`）。移植不需要新設計一套抽象，只需要把現有 default 實作換成「按平台選 implementation」，並補上各平台的原生端。不要為此再造抽象層。
5. 真正需要使用者裁決的不是技術，是**產品形態**：Android/iOS 的 scoped storage / sandbox 讓「自由瀏覽任意資料夾 + 在資料夾裡寫 `.halcyon_status.json`」這個核心前提站不住。這是移植的主要設計風險。

---

## 表一：原生能力 × 平台

| 能力 | Channel / 檔案 | macOS 現況 | Windows 替代 | Android 替代 | iOS 替代 |
|---|---|---|---|---|---|
| 縮圖 / 預覽解碼 | `halcyon/thumbnail`（`native_thumbnail_service.dart:87`；原生 `AppDelegate.swift:302-516`） | CGImageSource + CIRAWFilter | WIC (`IWICBitmapDecoder`) 或直接用 dng_processor | `BitmapFactory` + `inSampleSize`；RAW 走 dng_processor | 同 macOS（ImageIO/CoreImage 在 iOS 可用，Swift 碼可共用） |
| RAW / DNG 全尺寸解碼 | `DngFullDecoder`（`dng_decode_contract.dart:30`） | dng_processor FFI | dng_processor（`native/CMakeLists.txt` 有，未驗證 build） | dng_processor（`dist/` 有 arm64 `.so`，未接進 Halcyon build） | 未驗證，`dng_bindings.dart` iOS 分支未確認 |
| DNG 內嵌 JPEG 抽取 | `DngPreviewExtractor.swift` | 純 TIFF byte parsing | **可直接改寫成 Dart**，不需原生 | 同左 | 同左 |
| 移到垃圾桶 | `halcyon/trash`（`trash_service.dart:7`） | `FileManager.trashItem` | `IFileOperation` + `FOF_ALLOWUNDO`（回收站） | 無系統垃圾桶 → 用現有 in-folder `.trash/` recycle mode | 無 → 同 Android |
| Open With（Finder 開檔） | `halcyon/open_with`（push-only，`open_with_channel.dart:22`） | `NSApplication.application(_:openFile:)` | `WM_DROPFILES` / argv | `ACTION_VIEW` intent | `application(_:open:options:)` |
| EXIF 批次讀取 | `halcyon/exif`（`exif_metadata_service.dart:23`） | `CGImageSourceCopyPropertiesAtIndex` | **不必做**——已有純 Dart fallback（`exif_metadata_service.dart:50-51`） | 同左 | 同左 |
| 縮圖匯出（JPEG 編碼） | `AppDelegate.swift:254-300` | `CGImageDestination` | Dart `image` package 或 WIC encoder | Dart `image` package | 同 macOS |

**觀察**：真正需要每平台原生實作的只有兩項——**縮圖解碼**與**RAW 解碼**。Trash / Open With / EXIF / 匯出 都能用既有 Dart 路徑或既有 in-app recycle mode 頂掉。

---

## 表二：建議動作（不是「新增抽象層」，是把既有接縫接上）

| 項目 | 動作 | 檔案 | Fallback 策略 |
|---|---|---|---|
| 縮圖降級 | `requestImage` 補 `on MissingPluginException` 分支，回傳 `NativeImageFailure` | `native_thumbnail_service.dart:114` 後 | 抄 `trash_service.dart:15` 的寫法 |
| 縮圖跨平台實作 | 不新增介面——`ThumbnailLoader` typedef 已是接縫（`app_state.dart:23`），只換 default wiring | `app_state.dart:82-89` | 無原生端時用 Dart `image` package 解 JPEG，RAW 交給 dng_processor |
| DNG 預覽抽取 | Swift `TIFFReader` 改寫成 Dart，砍掉一個原生依賴 | 新 `lib/services/dng_preview_extractor.dart` | 純 byte parsing，無平台依賴 |
| dng_processor | 改造成真正的 Flutter plugin（`flutter: plugin:` + 各平台 build hook），移除寫死路徑 | 上游 repo | 沒有 plugin 化就沒有可出貨的 RAW |
| Trash | `TrashService` 在非 macOS 直接走 in-folder recycle mode | `photo_file_actions.dart` 既有邏輯 | 已存在，不必寫新程式 |
| Android 編譯 | MainActivity 移到 `com/example/halcyon/` 並改 package | `android/app/src/main/kotlin/...` | — |
| 資料夾存取 | Android SAF / iOS security-scoped bookmark 需要真正的設計決策 | `app_state.dart:214-216`、`photo_status_store.dart:23` | 見下方裁決點 |
| 觸控操作 | 現在只有鍵盤（`main_screen.dart:84-112`）與 hover（`main_detail_view.dart:309`） | — | 手機需要一整套 gesture 分揀 UI |

---

## 分級

### P0 — 不做就跑不起來
1. `dng_processor` plugin 化 + 移除寫死路徑（`dng_bindings.dart:339`）。影響全部平台。
2. Android MainActivity package 與 namespace 不符。
3. `halcyon/thumbnail` 的 `MissingPluginException` 未捕捉（`native_thumbnail_service.dart:114`；目前靠 `image_preload_controller.dart:728` 的 `catch(_) { rethrow; }` 兜，結果是每張圖丟一個 uncaught async error、完全不顯示）。
4. 各平台的縮圖/解碼原生端（Windows WIC、Android BitmapFactory；iOS 可複用 macOS Swift）。
5. Android/iOS 的資料夾存取模型（見裁決點）。

### P1 — 會跑但功能降級
6. Trash 在 Windows 接 `IFileOperation`；Android/iOS 改走 in-folder recycle。
7. Open With 各平台入口。
8. 縮圖匯出的非 Apple 編碼路徑。
9. 行動端觸控分揀 UI（目前純鍵盤，手機上等於不能用）。
10. `.halcyon_status.json` 寫入權限在 SAF/sandbox 下的降級（寫不進去就退到 app 私有目錄）。

### P2 — 體驗
11. DNG 預覽抽取改 Dart（減一個原生依賴，非必要）。
12. Linux（dng_processor 完全沒有 Linux 支援）。
13. hover 驅動的 UI 在觸控裝置的對應行為。

---

## 需要使用者裁決（不是我能決定的取捨）

1. **Android 要不要放棄「自由瀏覽任意資料夾」**。SAF 回傳的是 `content://` tree URI，不是檔案路徑；現在整個 `dart:io Directory` 掃描（`app_state.dart:216`、`photo_file_actions.dart:95`）都建立在真實路徑上。三選一：(a) 只支援 app 專屬目錄／匯入流程，(b) 全面改寫成 URI-based 存取層（大工程），(c) Android 走 `MANAGE_EXTERNAL_STORAGE`（Play 商店審核困難）。
2. **iOS 是不是同一個產品**。iOS sandbox 下沒有「一個裝滿 RAW 的資料夾」這個概念，照片在 PhotoKit 裡。iOS 版可能是「從 Files/外接讀卡機匯入」而非「瀏覽資料夾」——這是產品定義而非移植。
3. **行動端的分揀互動要長什麼樣**。桌面版核心是方向鍵 + S/X 快速鍵。手機上要 swipe？雙欄？這是設計題，不是移植題。
4. **Windows 是不是第一優先**。Windows 與現有架構最相容（真實檔案路徑、鍵盤、滑鼠、有回收站），P0 只剩 dng_processor + WIC 縮圖。若目標是「先有第二個平台」，Windows 的投入產出比明顯高於 Android/iOS。

---

## 未驗證項（誠實標註）

- dng_processor 在 Windows / iOS 是否真能 build 出可用產物——只確認 `native/CMakeLists.txt`、`windows/CMakeLists.txt` 存在，`dist/` 只有 `.apk` / `.app` / `.dylib`。
- `dng_bindings.dart` 349 行之後的 iOS 載入分支未讀。
- `lib/views/` 未做完整的 hover/touch 對等性審計，只抽樣三個檔。
- Halcyon 的 `windows/runner/*.cpp` 是否 100% 等同 Flutter 範本，diff 未確認（高機率是）。
