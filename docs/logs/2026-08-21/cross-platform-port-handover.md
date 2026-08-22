# 跨平台移植（macOS → Windows / Android / iOS）— Session Handover

> **建立時間**：2026-08-21 01:25（Asia/Taipei）
> **交接目的**：讓下一個 session 接續「Halcyon 跨平台移植」的架構方向與 P0 收尾，終態是「共通層 P0 全部落地並經機械驗證；Windows 原生端由使用者在 Windows 機器上驗收；行動端存取模型取得使用者裁決」。
> **目前判定**：進行中（共通層 P0 大致落地但**未 commit、未整合驗收**）＋ Windows 原生端**未編譯過**＋三項產品決策**待使用者裁決**。
> **可信版本錨點**：branch `main`；HEAD `1048dde732648d2b6061aa2897c6f88f027e4453`（"docs: record EXIF rename decisions..."）。
> **本檔所有程式碼結論的驗證對象是 working tree（未提交），不是 HEAD。** HEAD 本身尚不含任何跨平台改動。

---

## 0. 接手速讀（60 秒）

- **目標**：Halcyon 從 macOS 單平台變成「Windows 優先、Android/iOS 次之」的多平台 app，且原生依賴不再靠開發機絕對路徑。
- **現況**：共通層 P0（D1 dng_processor plugin 化 / D2 thumbnail 降級 / D3 Android 編譯修復）已寫進 working tree；Windows 四個原生橋接（WIC 縮圖、Recycle Bin、Open With）已寫但**從未編譯**。全部**未 commit**。
- **最大的架構結論**：**不需要新增抽象層**。既有兩條接縫已足夠，且已被 Windows 那批程式碼實證——加一個平台只寫原生端，Dart 端零改動。詳見 §4。
- **下一個動作**：§8 P0-1（跑整合驗收命令，見 §12）→ P0-2（把 working tree 切成兩批 commit，見 §3）。
- **最大風險／紅線**：這棵樹**同時另有兩個 session 在寫**（跨平台 P0 team、rename-dialog UI 對齊 cron）。禁止 `git stash` / `reset` / `checkout --` / `clean`；commit 一律顯式 `git add <指定檔>`。

---

## 1. 接手啟動序列

1. Read `docs/logs/2026-08-21/cross-platform-p0-contract.md` — 這輪的收斂契約：終態、in/out-of-scope、驗收條件（AC1-8 ＋ Windows 的 AC9a/9b）、parking lot、已被使用者批准的契約修訂。**它比 2026-08-20 的盤點文件更新，衝突時以它為準。**
2. Read `docs/logs/2026-08-21/windows-verification-runbook.md:1-60` — Windows 那批程式碼「從未編譯過」的自白＋逐步驗證程序。使用者要在自己的 Windows 機器上跑它。
3. Run `git status --porcelain && git diff --stat` — 預期看到 §3 那 15 個 modified／1 個 deleted，其中 `lib/views/rename_dialog.dart` 不屬於跨平台工作。
4. Run §12 的驗收命令組 — 目前**沒有任何一條被證實在最終樹上跑過**（見 §8 P0-1）。
5. Start at `lib/main.dart:23-25`（composition root，唯一該做平台選擇的地方）與 `windows/runner/halcyon_channels.cpp`。

必讀就這 5 個入口。2026-08-20 的盤點文件**不必再讀**——它的結論已被三份 premise audit ＋ 兩份 findings 修正並吸收進本檔 §9（原始引文留在那五份檔，本檔只留裁決）。

---

## 2. 目的、現象與根因狀態

### 目的
讓 Halcyon 在 macOS 以外的平台可建置、可執行、且缺原生能力時降級而不是崩潰；並讓 RAW 解碼的原生庫由 build 系統打包，而不是依賴建置機上另一個 repo 的 CMake build 目錄。

### 現象（改動前，2026-08-20 觀測）
- 條件：在 Windows/Android/iOS 執行。
- 實際：`halcyon/thumbnail` 丟 `MissingPluginException`，穿過 `lib/services/image_preload_controller.dart:730` 的 `catch (_) { rethrow; }`，每張圖一個 uncaught async error，畫面全空。
- 預期：像 `trash_service.dart:15` / `exif_metadata_service.dart:50` 一樣降級。
- 證據：`docs/logs/2026-08-21/premise-audit-channels.md` A 節（四個 channel 的降級行為逐一查證）。

### 根因（已確認）
兩個獨立根因，不是同一個：
1. **降級缺口**：`MissingPluginException` 不繼承 `PlatformException`，所以既有的 `on PlatformException` catch 抓不到，需要獨立 clause。已修（`lib/services/native_thumbnail_service.dart:122-135`，working tree）。
2. **原生庫打包**：原以為「dylib 沒被打包」，**這個前提是錯的**——`macos/Runner.xcodeproj/project.pbxproj` 早就有 "Embed DNG Native Dylib" run-script phase。真正的缺陷是「打包硬性依賴建置機上存在 sibling repo 的 `native/build/` 目錄」。契約 AC2 已因此整條重寫（見 `cross-platform-p0-contract.md:36-41`）。

---

## 3. 範圍與版本控制狀態

- **In scope**：`lib/services/`（channel 降級）、`lib/main.dart`（composition root）、`android/`（編譯修復）、`windows/runner/`（原生橋接）、`macos/`（改用 pod 打包 dylib）、sibling repo `../flutter_dng_decoder/dng_processor_ffi/`。
- **Out of scope（本輪明確不做）**：iOS 原生端、Android SAF／iOS bookmark 存取模型、行動端觸控 UI、DNG 預覽抽取改寫 Dart、Linux。
- **Branch / HEAD**：`main` / `1048dde`。HEAD **不含**任何跨平台改動。
- **Working tree（全部未 commit）**：

| 檔案 | 歸屬 session | 內容 |
|---|---|---|
| `pubspec.yaml`, `pubspec.lock` | 跨平台 P0 | 依賴由 `dng_processor`（app 專案）換成 `dng_processor_ffi`（真 FFI plugin） |
| `lib/services/dng_decode_service.dart` | 跨平台 P0 | import 改 `package:dng_processor_ffi/dng_processor_ffi.dart`，移除 `// ignore: implementation_imports` |
| `lib/services/native_thumbnail_service.dart` | 跨平台 P0 | +13 行 `on MissingPluginException` 降級 |
| `test/native_thumbnail_service_test.dart`, `test/dng_decoder_smoke_test.dart`, `unit_test.md` | 跨平台 P0 | TC-057 及 smoke test 調整 |
| `macos/Podfile.lock`, `macos/Runner.xcodeproj/project.pbxproj`, `macos/Flutter/GeneratedPluginRegistrant.swift` | 跨平台 P0 | 刪 "Embed DNG Native Dylib" phase、改由 `[CP] Embed Pods Frameworks` 打包；`file_picker` 從 registrant 消失（因為不再被 app 專案拖進來） |
| `android/.../photo_selector_flutter/MainActivity.kt`（deleted，staged）＋ untracked `android/app/src/main/kotlin/com/example/halcyon/MainActivity.kt` | 跨平台 P0 | package 對齊修復 |
| `windows/runner/CMakeLists.txt`, `flutter_window.{h,cpp}`, `main.cpp` ＋ untracked `halcyon_native.h`, `halcyon_channels.cpp`, `halcyon_image.cpp`, `halcyon_trash.cpp` | 跨平台 P0（D5） | Windows 原生橋接，**未編譯** |
| **`lib/views/rename_dialog.dart`（+660 行）** | **另一個 session（rename dialog UI vs mockup 對齊 cron）** | **與跨平台無關，不要一起 commit** |

- **另有 1142 個未追蹤的 `AGENTS.md` 樣板檔**（內容是 CLAUDE.md 的複製，非目錄索引）。其中位於 `android/app/src/main/res/**` 的 10 個已在本輪刪除——Android resource merger 只准 `res/**` 放 `.xml`/`.png`，不刪會直接 build fail。剩下 1142 個未處理。
- **背景狀態**：team `halcyon-port-research`（本檔作者所在）＋跨平台 P0 team。無 container／dev server／DB。

---

## 4. 目前邏輯架構（跨平台切面）

### 核心結論：**兩條接縫，各管一種平台差異；不要再造第三條。**

我獨立讀完 `app_state.dart`、`main.dart`、四個 service 後，**確認**盤點文件「抽象接縫已經夠用」的結論，但把它拆得更精確——原文把兩種本質不同的機制混講了：

**接縫 A — 執行期能力降級（MethodChannel + `MissingPluginException`）**
適用於全部四個 channel。Dart 端只有一份實作；原生端註冊了就用原生，沒註冊就降級。**加一個平台＝只寫原生端，Dart 零改動。**
這不是理論——working tree 的 Windows 那批就是實證：新增了 4 個 `.cpp` 加上 CMake 連結，`lib/` 一行沒動。

**接縫 B — Composition root 注入（typedef）**
`ThumbnailLoader`（`lib/providers/app_state.dart:23-27`）與 `DngFullDecoder`（`lib/services/dng_decode_contract.dart:30`），在 `lib/main.dart:23-25` 注入。適用於「必須在同一平台上換掉整個實作」的場合（例如 Android 想用純 Dart `image` package 解 JPEG 而非寫原生端）。目前只有 `dngDecoder` 真的被注入；`thumbnailLoader` 走 `app_state.dart:84-89` 的 inline 預設。第三個同型接縫是 `ThumbnailExportService` 的 `ExportBytesFetch`（`lib/services/thumbnail_export_service.dart:31`），同樣預設接原生、可被注入純 Dart 實作——見 §8 P1-5。

**由此得出的不變式（請寫進 review checklist）**：
> `lib/services/` 與 `lib/providers/` 內**不得出現 `Platform.is*` / `defaultTargetPlatform` 分支**。平台選擇只發生在 `lib/main.dart`（接縫 B）或根本不發生（接縫 A）。
> 目前這條不變式是成立的：`grep -n "Platform.is\|defaultTargetPlatform" lib/services/*.dart lib/providers/*.dart` → 0 hits（2026-08-21 working tree）。保住它。

盤點文件表二「縮圖跨平台實作 → 只換 default wiring」這一列**是誤導**：要不要動 wiring 取決於選哪條接縫。Windows 選了 A（不動 wiring），Android 若選純 Dart fallback 才會動到 B。這是 [D-4]／[D-1] 的下游後果，不是一個已定的動作。

| 節點 | 責任 | 關鍵符號 | 上游 | 下游 | 不變式／失敗語意 |
|---|---|---|---|---|---|
| Composition root | 唯一的平台選擇點 | `lib/main.dart:23-25` | `main()` | `AppState` ctor | 是唯一允許出現平台條件的 Dart 位置 |
| `AppState` | 全 app 唯一協調點；建構子注入 | `lib/providers/app_state.dart:66-96` | main.dart / 測試 | scanner/store/actions/preload | 所有協作者可被 fake 取代；不得直接 new 原生服務 |
| `NativeThumbnailService` | `halcyon/thumbnail` 的 Dart 端 | `lib/services/native_thumbnail_service.dart:87` | `ImagePreloadController` | MethodChannel → 各平台原生 | 失敗一律回 `NativeImageFailure`，**永不 throw**（`:119-135` 三個 catch clause） |
| `TrashService` | `halcyon/trash` | `lib/services/trash_service.dart:7,15` | AppState | 原生／無 | 無原生時 throw `TrashException`（呼叫端決定退回 in-folder recycle） |
| `ExifMetadataService` | `halcyon/exif` | `lib/services/exif_metadata_service.dart:23,50` | AppState rename 流程 | 原生／`package:exif` isolate | 無原生時**全功能**純 Dart fallback，欄位完全對等，非降級 |
| `OpenWithChannel` | `halcyon/open_with`，push-only | `lib/services/open_with_channel.dart:22` | 原生（native→Dart） | `appState.openPhotoAtPath` | 冷啟動時 Dart handler 尚未註冊，靠 Flutter 的訊息緩衝；**不得改成 Dart→native pull** |
| `DngFullDecoder` 接縫 | RAW 全尺寸解碼 | `lib/services/dng_decode_contract.dart:30`；adapter `dng_decode_service.dart` | `ImagePreloadController` | `dng_processor_ffi` FFI → isolate worker | 只有 3 個 `NativeImageResult` variant（凍結，見 memory.md AD-010/011）；throw ＝ 退回舊路徑 |
| `PhotoStatusStore` | `.halcyon_status.json` 讀寫 | `lib/services/photo_status_store.dart:23` | AppState | 真實檔案路徑 | **假設真實 `Directory` 路徑**；SAF `content://` 下整個崩塌 → [D-1] |
| `PhotoFileActions` | 刪除／回收／複製搬移 | `lib/services/photo_file_actions.dart:95` | AppState | 真實路徑 `.trash/` | 同上，真實路徑假設 |

---

## 5. 資料生產消費鏈（縮圖／預覽這條，唯一跨平台敏感的）

### Happy path
`ImagePreloadController → ThumbnailLoader typedef → MethodChannel halcyon/thumbnail → 平台原生解碼 → NativeImageBytes → ImageProvider → UI`

| Hop | 輸入 | 輸出 | 驗證／正規化 | 失敗處理 | 證據 |
|---|---|---|---|---|---|
| Controller → Loader | `path`, `ImageRequestPurpose` | `Future<NativeImageResult>` | purpose 決定 targetSize：200 / 2800 / 2048（**三個**，不是盤點文件說的兩個） | — | `lib/services/native_thumbnail_service.dart:5,12,18` |
| Loader → 原生 | method `getThumbnail` | JPEG bytes 或原檔 bytes | macOS `export` 分支刻意繞過 JPEG/DNG raw passthrough，否則 resize 失效 | `PlatformException` → `NativeImageFailure` | `macos/Runner/AppDelegate.swift:329-345` |
| 無原生端 | — | — | — | `MissingPluginException` → `NativeImageFailure('MISSING_PLUGIN')` | `native_thumbnail_service.dart:122-135` |
| Result → Provider | bytes | `MemoryImage` / `ResizeImage` | **tier-1 與 tier-2 必須用同一個 bytes 物件 identity 與同樣 w/h**，否則 ImageProvider cache key 不命中 → 靜默重複解碼 | — | `lib/services/image_preload_controller.dart`；CLAUDE.md 架構節 |

### Failure path
`NativeImageFailure` 由 `image_preload_controller.dart` 收進 `_failedIds`，UI 顯示錯誤而非 spinner（commit `7cc9338` 建立的路徑）。**這條既有路徑不需為跨平台改動**——這正是 D2 只加 13 行就夠的原因。

---

## 6. 型別與介面契約（跨平台會踩到的）

| 契約 | Producer 定義 | Consumer 假設 | 不變式 | 錯誤語意 | 證據 |
|---|---|---|---|---|---|
| `halcyon/thumbnail` | 原生 `getThumbnail(path, targetSize)` → JPEG/原檔 bytes | `NativeThumbnailService.requestImage` | 三個 purpose 尺寸 200/2800/2048 | 三種：成功 bytes／`PlatformException`／無 handler | `native_thumbnail_service.dart:5-18,87,119-135`；`AppDelegate.swift:302-516` |
| `NativeImageResult` | sealed，**恰 3 個 variant** | preload controller 窮舉 | 加第 4 個 variant 前必查 memory.md AD-010/AD-011 | — | CLAUDE.md 架構節 |
| `DngFullDecoder` | `Future<DecodedRgba> Function(String path)` | `ImagePreloadController` | `rgba.length == width*height*4`；**已由 decoder 裁到 DefaultCropSize，不可再裁** | throw ＝ 退回舊路徑，非致命 | `lib/services/dng_decode_contract.dart:12-30` |
| `dng_processor_ffi` plugin | `flutter: plugin: platforms:` → **只有 `macos` 與 `android`**，皆 `ffiPlugin: true` | Halcyon `pubspec.yaml` path dep | **沒有 `ios:` / `windows:` / `linux:` 條目** | Windows/iOS 上 `DynamicLibrary.open` 找不到產物 | `../flutter_dng_decoder/dng_processor_ffi/pubspec.yaml:22-29` |
| 縮圖匯出（`ImageRequestPurpose.export` @2048px） | 原生分支自行 JPEG 編碼（macOS `CGImageDestination`，`AppDelegate.swift:254-300`；Windows WIC encoder） | `ThumbnailExportService`，透過 `ExportBytesFetch` 接縫（`thumbnail_export_service.dart:31,36-41`） | **無純 Dart 編碼 fallback**，`image` package 也不是本專案依賴 | 無原生端時 `getThumbnail`（`:143-155`）委派給 `requestImage`，繼承 `MissingPluginException` catch → 回 null → 該張記入 `failures`，**批次不中斷、不崩潰** | `native_thumbnail_service.dart:143-155`；`thumbnail_export_service.dart:88-95` |
| `halcyon/open_with` | 原生 `invokeMethod("openFile", path)`，**無 incoming handler** | `OpenWithChannel.listen` | 方向固定 native→Dart；冷啟動靠 Flutter 訊息緩衝 | 不可改成 pull | `open_with_channel.dart:22`；`AppDelegate.swift:80-86`；Windows `flutter_window.cpp` OnCreate |

---

## 7. 已完成事項

⚠️ 以下全部是 **working tree 狀態，未 commit**；且 §8 P0-1 未跑完前，這些 `[C]` 的整合驗收是 `[U]`。

| 結果 | 改動／產物 | 驗證 | 錨點 |
|---|---|---|---|
| [C] D1：RAW 原生庫改由真 FFI plugin 打包，移除對 sibling repo `native/build/` 的建置期依賴 | `../flutter_dng_decoder/dng_processor_ffi/`；Halcyon `pubspec.yaml`、`macos/Podfile.lock`、`project.pbxproj`（"Embed DNG Native Dylib" phase 刪除，改 `[CP] Embed Pods Frameworks`） | 契約 AC1（`grep -A6 '^flutter:' .../dng_processor_ffi/pubspec.yaml` 含 `plugin: platforms:` macos+android）→ 已見於樹上 | working tree |
| [C] D2：thumbnail channel `MissingPluginException` 降級 | `lib/services/native_thumbnail_service.dart:122-135`、`test/native_thumbnail_service_test.dart`、`unit_test.md` TC-057 | 契約 AC5，**先紅後綠留證**：`scripts/tmp/verify/d2-before-fix.txt` / `d2-after-fix.txt` | working tree |
| [C] D3：Android MainActivity package 對齊 | `android/app/src/main/kotlin/com/example/halcyon/MainActivity.kt`（新）；舊路徑已 staged deleted | 契約 AC3：`find android/app/src/main -name MainActivity.kt` 只回一個 halcyon 路徑 → 已確認 | working tree |
| [C] 盤點文件前提複查（3 份） | `docs/logs/2026-08-21/premise-audit-{channels,native,platforms}.md` | 見 §9 | 2026-08-21 |
| [U] D5：Windows 三個原生橋接 | `windows/runner/halcyon_{native.h,channels.cpp,image.cpp,trash.cpp}` ＋ 4 個既有檔修改 | **從未編譯過**。驗證程序在 `windows-verification-runbook.md` | working tree |

---

## 8. 待解議題（依賴排序）

| 優先 | 狀態 | 議題 | 入口／下一動作 | 完成條件 |
|---|---|---|---|---|
| **P0-1** | [U] | 共通層 P0 的整合驗收（契約 AC4/6/7/8）未在最終樹上跑過。個別交付各自綠燈，但那是**改動陸續落地過程中**的證據，不等於最終組合綠 | 依序跑 §12 全部命令 | 四條全綠且 `flutter test` 宣告數==執行數 |
| **P0-2** | [P] | 全部工作未 commit，且樹上混有 rename-dialog cron 的 660 行改動 | 分兩批：跨平台批（§3 表除 `rename_dialog.dart`）＋ cron 批。**顯式 `git add <檔>`，禁 `git add -A`** | 兩個 commit，`git show --stat` 檔案清單與 §3 表一致 |
| **P0-3** | [B] | Windows 那批**從未編譯**。`/W4 /WX` 開著，任一 conversion warning 即硬錯。契約已把它拆成 AC9a（macOS 上可做的靜態檢查）／**AC9b（只有使用者能驗）**，並明訂「9b 完成前 D5 一律記為『已交付、未驗收』，不得計入完成」 | 使用者在 Windows 機器上跑 `windows-verification-runbook.md` | `flutter build windows` exit 0 且 runbook 逐條過 |
| **P0-4** | [B] | **最高風險單點**：Windows 回收站的旗標組合 `FOF_ALLOWUNDO \| FOFX_RECYCLEONDELETE`（`windows/runner/halcyon_trash.cpp`）未經執行。旗標錯了的後果是**永久刪除而非進回收站**——不可逆的使用者資料損失 | 在 Windows 上先用**可拋棄的測試檔**驗證，確認檔案真的出現在回收站，再碰任何真實照片 | 刪除後在資源回收筒中肉眼看到該檔並可還原 |
| **P1-1** | [B] | **Windows/iOS 沒有 RAW 解碼路徑**。`dng_processor_ffi/pubspec.yaml:22-29` 只宣告 macos+android；`dng_processor/native/CMakeLists.txt` 的 link 區塊（512-541）根本沒有 WIN32 分支；iOS 連一條壞掉的路徑都沒有 | 解除條件＝[D-4] 裁決。若要做：上游 `native/CMakePresets.json` 加 windows preset ＋ link 區塊補 WIN32 ＋ `dng_processor_ffi/pubspec.yaml` 加 `windows: ffiPlugin: true` ＋ `windows/` plugin 目錄 | `flutter build windows` 產物內有 `dng_decoder_native.dll`，且 `dng_bindings.dart:343` 的裸檔名 `DynamicLibrary.open` 找得到 |
| **P1-2** | [D] | Android/iOS 的資料夾存取模型（見 §11 [D-1]/[D-2]）。已盤清**恰 7 個 `dart:io` 真實路徑消費點**，全部在 `flutter-side-findings.md` §1 表中逐一列出並附行號：`app_state.dart:214`（`openFolder`）、`app_state.dart:223-229`（`openPhotoAtPath`）、`photo_status_store.dart:22-24`（`statusFileFor`）、`photo_status_store.dart:30-38`（`isWritable` 寫入探測）、`photo_file_actions.dart:39,60,64,97`（copy/rename/recycle）、`app_state.dart:547,553` + `rename_service.dart`（`listSync`/`statSync`/rename）、`app_state.dart:627`（`undoRename` journal）。**沒有任何一個能靠「加一個 fallback 分支」修好** | 使用者裁決 | — |
| **P1-3** | [U] | Android 只有 arm64 `.so`，x86_64 模擬器無原生庫 → RAW 在模擬器必失敗 | 標為已知限制或請上游補 x86_64 | 明確記入 README／memory.md |
| **P1-4** | [C] | Android 端**完全沒有任何原生 MethodChannel 實作**：`MainActivity.kt` 是 3 行的 `FlutterActivity()` 空殼，`android/app/src/main/` 下無其他 `.kt`。所以 Android 上三個 channel 全走降級路徑（縮圖＝`MISSING_PLUGIN` 錯誤、trash＝`TrashException`、open_with＝無來源）。這是**現況陳述不是缺陷**——先做 [D-1] 才知道 Android 值不值得寫原生端 | 依 [D-1] 裁決 | — |
| **P1-5** | [C] | **縮圖匯出在無原生端的平台上等於整批失敗**（每張都進 `failures`），因為 JPEG 編碼沒有純 Dart fallback，且 `image` package 不在 `pubspec.yaml`。Windows 已由 D5 的 WIC encoder 覆蓋（未編譯驗證）；Android/iOS 未覆蓋。**降級是安全的（不崩潰），但功能歸零** | 若 [D-1] 決定做 Android：在 `thumbnail_export_service.dart:31` 既有的 `ExportBytesFetch` 接縫後面注入純 Dart 實作（＝接縫 B），並新增 `image` 依賴。**不要**改 `ThumbnailExportService` 本體 | 無原生端平台上 `exportStarred` 產出 `exportedCount == starred 數量`、`failures` 為空 |
| **P2-1** | [P] | 1142 個未追蹤 `AGENTS.md` 樣板檔。`res/**` 那 10 個已刪（會讓 Android build fail）；其餘未處理。生成器未找到，全 repo 無任何一個 mtime 新於 2026-08-20 → 研判是過去批次產物，非持續生成 | 加進 `.gitignore` 或一次刪除 | `git status --porcelain | grep -c AGENTS.md` → 0 |
| **P3**（行動端則為 P0） | [D] | 行動端觸控 UI（見 [D-3]）。逐項缺口：**(1) 完全無替代**——`main_screen.dart:84-113` 的方向鍵導覽與上下鍵縮放，螢幕上零對應控制項；**(2) 無替代**——`photo_action_bar.dart:59-69` 的 `onSecondaryTap` 回收模式切換，觸控無 secondary button；**(3) 目標過小**——`main_screen.dart:52-65` 側欄拖曳把手寬 5px（`onPanUpdate` 對觸控本來就有效，但 5px 遠低於 44pt/48dp 準則）；**(4) 軟性降級，不必修**——`main_detail_view.dart:309-315` 的 hover 縮放中心，`zoom_controller.dart:78` 已 fallback 到 `lastKnownCenter`；**(5) 已可用**——`main_detail_view.dart:316-320` 的 `InteractiveViewer` 原生支援捏放與拖曳平移，`sidebar_view.dart` 的 `ListView`/`onTap`、`photo_action_bar.dart:49-56` 的 `IconButton` 亦然 | 使用者裁決 [D-3] 後才動 | — |

**建議平台順序：Windows → Android → iOS → Linux（可能永不做）。**
理由（不是偏好，是可達性）：Windows 是唯一與現有架構**前提相容**的平台——真實檔案路徑、鍵盤、滑鼠 hover、有系統回收站，四項核心假設全部成立，所以 P0 只剩「寫原生端」這種有界的工作，零產品重新定義。Android 打破「真實路徑」（SAF），iOS 同時打破「真實路徑」與「資料夾這個概念」（PhotoKit），兩者都不是移植而是重新設計，且各自被一個未裁決的 [D] 卡住。Linux 連 RAW 原生庫都不存在，且無使用者需求證據 → YAGNI，只在使用者提出時才啟動。

---

## 9. 盤點文件的修正（2026-08-20 那份哪裡不能信）

**下一個 session 不需要重讀 `docs/logs/2026-08-20/cross-platform-port-inventory.md`。** 它的可用結論已吸收進本檔；以下是被推翻或需修正的部分：

| 盤點文件的說法 | 裁決 | 現在的事實 |
|---|---|---|
| `dng_bindings.dart:339` 是「寫死的開發機路徑」 | **兩段修正** | (i) 該分支本來就由 `DNG_DEV_FALLBACK` env gate 保護，不是無條件寫死；(ii) **該分支已於 2026-08-21 的 D1 整段移除**。檔案也搬家了：現在是 `../flutter_dng_decoder/dng_processor_ffi/lib/src/dng_bindings.dart`（355 行），`:339` 現在是 Windows 分支 `DynamicLibrary.open('dng_decoder_native.dll')`。macOS 搜尋順序（`_openFirst`，`:195-217`，候選建於 `:325-337`）現為：DYLD 預設 → app bundle `../Frameworks/` → `DNG_NATIVE_BUILD_DIR` env → 兩個 `Platform.script` 相對的 `dart run` 開發路徑。**無條件的絕對路徑已不存在** |
| dylib「沒被打包」 | **FALSE** | `project.pbxproj` 早有 "Embed DNG Native Dylib" phase，未改動的樹上原驗收條件就是綠的（`scripts/tmp/verify/d1-ac2-before-*.txt`）。契約 AC2 已整條重寫為可否證版本 |
| `ImageRequestPurpose` 只有 2 個尺寸 | **FALSE** | 三個：200 / 2800 / 2048（`native_thumbnail_service.dart:5,12,18`） |
| 「thumbnail 沒有降級處理」 | **已過時** | 撰寫時為真，D2 已修（`native_thumbnail_service.dart:122-135`） |
| iOS「Swift 碼可共用」 | **FALSE（誇大）** | `getFastThumbnail` 的 RAW fallback 用 `NSBitmapImageRep`（`AppDelegate.swift:501-502`），AppKit-only，iOS 無對應。只有**匯出路徑**（254-300，刻意避開 AppKit）真的可共用 |
| RAW 解碼叫 `CIRAWFilter` | **命名不精確** | 實際是 `CIFilter(imageURL:options:)`（`AppDelegate.swift:449`）。`CIRAWFilter` 類需 macOS 12+，而部署目標是 10.15 |
| 「匯出需要 `UTType`，與 10.15 部署目標衝突＝出貨缺陷」 | **FALSE** | 程式碼根本不用 `UTType`，刻意改用字面值 `"public.jpeg"`（`AppDelegate.swift:256-258`）正是為了 10.15 相容。無缺陷 |
| dng_processor 在 Windows/iOS「未驗證是否能 build」 | **已查明：不能** | `native/CMakePresets.json` 只有 macos-metal ＋ 兩個 android-vulkan preset；`native/CMakeLists.txt` 900 行內無任何 `if(IOS)`；link 區塊（512-541）無 WIN32/UNIX 分支；`windows/CMakeLists.txt` 從不 `add_subdirectory(native)` |
| `dng_bindings.dart` iOS 分支「未讀」 | **已讀：不可行** | `DynamicLibrary.process()`（假設靜態連進 host），但 iOS 端沒有任何 build 機制把 `native/src` 連進 Runner，且 `dng_processor_ffi/` 連 `ios/` 目錄都不存在。Windows/Linux 分支也只是裸檔名 `open`，無搜尋路徑。**注意行號**：兩份稽核給出不同行號（`:349-350` vs `:344-345`），因為檔案在稽核之間被 D1 改短（359→355 行）——以 `dng_processor_ffi/lib/src/dng_bindings.dart` 現況為準，勿信任舊行號 |
| `windows/runner/*.cpp`「高機率等同 Flutter 範本」 | **TRUE，已用 `flutter create` 對照確認** | windows/android/ios/linux 四個 runner 目錄改動前皆為純範本（差異全是範本版本漂移＋專案名替換）。這也意味著 D5 新增的 Windows 程式碼是全新手寫碼，無範本可對照 |
| 「抽象接縫已經夠用，不要再造抽象層」 | **確認，但需精確化** | 見 §4：是**兩條**性質不同的接縫，表二「只換 default wiring」的說法誤導 |
| 「hover/touch 只抽樣 3 個檔」 | **補完，且嚴重度被低估** | 兩次獨立全掃：`premise-audit-channels.md` D 節數到 4 檔（把非 widget 的 `zoom_controller.dart` 也計入），`flutter-side-findings.md` §2 數到 3 個**widget 檔**（`main_screen.dart`、`main_detail_view.dart`、`photo_action_bar.dart`）。兩者不衝突，取後者（widget 檔才是需要改 UI 的單位）。更重要的是嚴重度：盤點文件把行動端觸控列為 P1（降級但能跑），但全掃顯示**上一張/下一張導覽本身就只有鍵盤**（`main_screen.dart:84-113`），螢幕上沒有任何對應控制項 → 觸控裝置上 Halcyon 不是「降級的分揀工具」，而是「只能捏放縮圖的檢視器」。對行動端而言這是 P0 |

---

## 10. 嘗試、裁決與禁止重踩

| 嘗試／方案 | 結果 | 裁決理由 | 可否重試 |
|---|---|---|---|
| 直接在 `dng_processor/pubspec.yaml` 宣告 `flutter: plugin: platforms:`（選項 A） | **不採用** | 會把 app-style 的 `dng_processor/android/`（含 `include(":app")`、`evaluationDependsOn(":app")`）拖進 Halcyon 的 Gradle graph 並弄壞 D3；也會把 `file_picker`/`path_provider` 等 harness 依賴帶進 app（證據：`GeneratedPluginRegistrant.swift` diff 中 `file_picker` 消失） | **否** |
| 新開 `dng_processor_ffi/` FFI plugin package（選項 B） | 採用，已落地 | FFI 而非 federated MethodChannel plugin：解碼回傳全解析度 RGBA（24MP ≈ 100MB），走 platform message codec 會多一次全緩衝區複製並失去既有的 isolate worker；且 `dng_bindings.dart` 本來就是 `DynamicLibrary` 綁定 | — |
| 契約原 AC2（「release build 產物含 dylib」） | **作廢** | 無鑑別力：未改動的樹上就是綠的。已改為「把 `native/build/` 移開後 RED→GREEN」的可否證版本 | 否（用新版） |
| 在 macOS 上驗證 Windows 程式碼 | 不可能 | 無 Windows 工具鏈，且刻意不安裝。runbook 明說「Nothing in this document says the code works」 | 只能在 Windows 機器上 |

**紅線／禁止事項**
- 禁 `git stash` / `reset` / `checkout --` / `clean`：樹上有其他 session 的未提交工作。
- 不要把 `lib/views/rename_dialog.dart` 併進跨平台 commit。
- 不要在 `lib/services/` 或 `lib/providers/` 加 `Platform.is*`（§4 不變式）。
- 不要為 `NativeImageResult` 加第 4 個 variant（先查 memory.md AD-010/AD-011）。
- 真實照片測試只能用 `local_data/photo_samples/`，禁碰使用者相簿。
- 禁任何 UI 驅動驗證（模擬點擊／osascript／截圖）——使用者明令。

---

## 11. 需使用者決策（[D]）

> **2026-08-21 使用者裁決更新**：[D-1]/[D-2]/[D-3]（行動端整組）**入 parking-lot，暫不處理**；當前主線是 Windows。[D-4] 仍待決。

這四項**不能從需求、程式碼、慣例推導**，全是產品取捨。

**[D-1] Android 要不要放棄「自由瀏覽任意資料夾」**
現況：`app_state.dart:213-217` 用 `file_selector` 的 `getDirectoryPath()` 拿真實路徑；`photo_status_store.dart:23` 與 `photo_file_actions.dart:95` 都在真實路徑上建 `File`/`Directory`。SAF 回的是 `content://` tree URI，不是路徑。
- (a) 只支援 app 專屬目錄／匯入流程 — 工作量小，但等於換一個產品（不能直接讀讀卡機資料夾）。
- (b) 全面改成 URI-based 存取層 — 要抽換 7 個消費點（§8 P1-2 已列全）。好消息：呼叫點**已經收斂**（`photo_status_store.dart` 的 6 個方法全部只透過 `statusFileFor` 開檔；`photo_file_actions.dart:8-9,22-24` 已有 `_moveFile`/`_trashFile` typedef 與 `_availablePath` helper）——注入接縫本來就在。壞消息：接縫後面那個 SAF/`DocumentsContract` 實作**是一個全新子系統，不是切換開關**；而且 `app_state.dart:547,553` 的 `listSync`/`statSync` 在 content resolver 上**根本沒有對應 API**（不是慢，是不存在），必須先改成非同步。這**才是**唯一真的需要「新增抽象層」的地方——§4 說「不要再造抽象層」不適用於這裡。
- (c) `MANAGE_EXTERNAL_STORAGE` — 程式碼幾乎不用改，但 Play 商店審核困難，若不上架則無此問題。
決策差異最大的是 (b) vs (a)/(c)：(b) 才保得住產品定位，代價是最大。

**[D-2] iOS 是不是同一個產品**
iOS sandbox 下沒有「一個裝滿 RAW 的資料夾」；照片在 PhotoKit。選項：(a) 不做 iOS；(b) 做成「從 Files／外接讀卡機匯入」的另一個產品形態；(c) 等 [D-1] 選 (b) 之後複用 URI 存取層。這是產品定義題，不是移植題。

**[D-3] 行動端分揀互動長什麼樣**
桌面核心是方向鍵 + S/X + hover 縮放。手機要 swipe？雙欄？4 個 view 檔含桌面專屬互動點需要對應設計。屬 R6「品味判斷」——建議做 2-3 個候選交使用者拍板，不要讓 agent 自行決定。

**[D-4] Windows 首版要不要有 RAW 解碼**
現況：`halcyon_image.cpp` 的 WIC 路徑「RAW always fails」，且 `dng_processor_ffi` 沒有 windows 條目。
- (a) Windows 首版 JPEG-only，RAW 顯示錯誤 — 現在就能出，但 Halcyon 的核心使用者是 RAW 攝影師，等於半個產品。
- (b) 先補上游 Windows FFI 支援再出 Windows — 阻塞在另一個 repo 的 CMake 工作（link 區塊要補 WIN32 分支，見 P1-1）。
影響差異大，且直接決定 Windows 是否算「移植完成」。

---

## 12. 驗收命令（由窄到寬；**目前沒有一條被證實在最終樹上跑過**）

```bash
# AC3 — Android package 對齊（預期只回一個路徑）
find android/app/src/main -name MainActivity.kt
grep -n '^package' android/app/src/main/kotlin/com/example/halcyon/MainActivity.kt   # 預期 package com.example.halcyon

# AC1 — FFI plugin 宣告（預期含 plugin: / platforms: / macos+android ffiPlugin: true）
grep -A8 '^flutter:' ../flutter_dng_decoder/dng_processor_ffi/pubspec.yaml

# §4 不變式 — 預期 0 hits
grep -n "Platform.is\|defaultTargetPlatform" lib/services/*.dart lib/providers/*.dart

# AC6 — 預期 "No issues found!"（忽略 scripts/tmp/ 噪音）
flutter analyze

# AC7 — 必須 -j 1（預設 runner 會誤算數量）；預期 exit 0 + "All tests passed!" + 宣告數==執行數
flutter test -j 1

# AC4 — 預期 exit 0
flutter build apk --debug

# AC8 — 預期 exit 0
flutter build macos

# AC2（可否證版本）— 先把 ../flutter_dng_decoder/dng_processor/native/build/ 改名移開，
# 且 DNG_DEV_FALLBACK / DNG_NATIVE_BUILD_DIR 皆未設：
#   flutter build macos --debug  → 預期 exit 0（改動前應在 Embed 階段失敗）
#   ls build/macos/Build/Products/Debug/Halcyon.app/Contents/Frameworks/ | grep dng
#     → 預期 libdng_decoder_native.dylib（來源為 pod）
# 驗畢務必把 native/build/ 改名還原並確認還原成功——那是上游團隊的活建置樹。

# Windows（只能在 Windows 機器上）
# flutter build windows   → 見 docs/logs/2026-08-21/windows-verification-runbook.md
```

---

## 13. 參考入口

- 必讀：`docs/logs/2026-08-21/cross-platform-p0-contract.md` — 本輪收斂契約、8 條驗收、parking lot、兩條已批准的契約修訂。
- 必讀：`docs/logs/2026-08-21/windows-verification-runbook.md` — Windows 程式碼的自白與逐步驗證程序（使用者在 Windows 機器上執行）。
- 證據庫：`docs/logs/2026-08-21/premise-audit-{channels,native,platforms}.md` — 盤點文件的逐條複查（§9 是其摘要，細節與引文在這三份）。
- 已過時，勿用作決策依據：`docs/logs/2026-08-20/cross-platform-port-inventory.md` — 見 §9 的修正表。
- 專案架構前提：`CLAUDE.md`（Architecture 節）、`memory.md` AD-010/AD-011/AD-014、`unit_test.md` TC-057。

---

## 14. 已知限制與未驗證項

- **未驗證**：Windows 全部原生程式碼（未編譯）；Android debug APK 是否真的 build 過（契約 AC4 狀態未確認）；`flutter test -j 1` 在最終樹上的結果。
- **已知限制**：Android RAW 為 arm64 device only（上游只有 arm64 `.so`），x86_64 模擬器上必失敗——已知限制而非缺陷。
- **已知限制**：RAW 預覽解碼忽略 `targetSize`，永遠全解析度（`AppDelegate.swift:449` 傳 `options: nil`），約 10x 記憶體；此取捨使用者尚未裁決。
- **本檔的邊界**：本檔作者（arch-direction-opus）read-only，未執行任何 build 或測試；§7/§8 中所有「已跑過」的陳述都轉引自各交付的證據檔路徑，未由本作者親自重跑。
- **已納入**：team `halcyon-port-research` 的 Task#1／#2 產出（`docs/logs/2026-08-21/native-layer-findings.md`、`flutter-side-findings.md`）已於本檔 §8/§9/§11 完成調和。兩份findings 與另一 session 的三份 premise audit 範圍部分重疊，但各自都補到對方沒有的東西（native-findings 補到 D1 已把絕對路徑整段移除、Android 零原生 channel；flutter-findings 補到 7 個儲存消費點與觸控嚴重度重估），**不是純重工**。
- **已知的證據衝突（已裁決）**：`dng_bindings.dart` 的 iOS 分支行號、以及桌面專屬互動的檔案數（4 vs 3），兩處分歧皆源於「稽核期間檔案被改」與「計數單位不同」，非任一方錯誤。裁決結果寫在 §9 對應列。
