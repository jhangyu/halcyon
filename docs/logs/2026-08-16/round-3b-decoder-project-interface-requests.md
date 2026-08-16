# 給 flutter_dng_decoder 團隊的介面請求（來自 Halcyon round 3b）

> **建立時間**：2026-08-16
> **來源專案**：Halcyon（`/Users/jhangyu/project/Halcyon`，branch `main`）
> **目標專案**：flutter_dng_decoder（`/Users/jhangyu/project/flutter_dng_decoder`，HEAD `80c565e`）
> **性質**：跨專案介面請求。本文由使用者手動轉交，Halcyon 端**不會**、也**無權**修改 decoder 專案的任何檔案。
> **⚠️ 嚴重性更正（2026-08-17，實測後改寫）**：議題 A（libjpeg 絕對路徑）原先被判定為「散佈階段才會踩到」，因此裁決為「接受、記錄轉交」。**這個判斷是錯的。**
> 實測證明：**在 macOS App Sandbox 下，該相依讓 `dlopen` 直接失敗，功能當場不可用**——不是未來散佈給使用者才壞，是**開發機上、今天、release build 就壞**。
> Halcyon 的 RAW 解碼功能因此完全無法運作（已驗證的回退機制讓畫面仍出得來，但走的是舊的低解析度路徑）。證據見 §1.2。
> 議題 B 維持原判定：不阻擋，但造成下游必須 import 私有路徑並自建打包步驟。

---

## 0. 一句話摘要

Halcyon 已把 `dng_processor` 以 pub `path:` 依賴的形式接進 macOS app 並跑通真解碼。過程中遇到兩個**與解碼正確性無關、純屬封裝與發佈面**的缺口：(1) 產出的 dylib 以**絕對路徑**連結 Homebrew 的 libjpeg，使 `.app` 無法在沒有相同 Homebrew 佈局的機器上執行；(2) package 沒有 barrel export、也沒有 `flutter: plugin:` 宣告，導致下游必須 import `src/` 私有路徑，並自行複製一份「把 dylib 塞進 .app」的 Xcode build phase。

---

## 1. 議題 A — `libdng_decoder_native.dylib` 以絕對路徑連結 libjpeg，而該 dylib 未隨附

### 1.1 問題描述

`libdng_decoder_native.dylib` 對 jpeg-turbo 的相依是寫死的 **Homebrew 絕對路徑**，不是 `@rpath`／`@loader_path` 相對形式；而該 `libjpeg.8.dylib` 本身**不會**被打包進任何 `.app`。

**最重要的後果（實測，非推論）：App Sandbox 直接封鎖。**
macOS App Sandbox 預設不允許讀取 `/opt/homebrew`。任何啟用 `com.apple.security.app-sandbox` 的 app（Flutter macOS 預設就是）載入這個 dylib 時，dyld 能找到 `libdng_decoder_native.dylib` 本身，但**解析它的相依 `libjpeg.8.dylib` 時被沙盒擋下**，於是整個 `dlopen` 失敗。

這代表：
- **在開發機上就壞**，即使 Homebrew 已安裝、檔案確實存在、路徑完全正確。**檔案存在與否不是重點，沙盒不讓讀才是。**
- 沙盒外的測試（例如 `flutter test`、`dart run`、任何獨立 CLI 程序）**會通過**，因為它們不受沙盒限制。這使該缺陷在一般測試中**完全隱形**——Halcyon 就是這樣一路綠燈到最後才發現。
- 錯誤訊息**不會提到 libjpeg**。dyld 只回報最後一個候選路徑的失敗，呼叫端看到的是「找不到 libdng_decoder_native.dylib」，指向完全錯誤的方向。這點對除錯成本影響很大。

次要後果（原本以為是唯一後果）：
- Intel Mac 的 Homebrew 前綴是 `/usr/local`，路徑不存在 → 失敗。
- 一般使用者機器沒有 Homebrew → 失敗。

### 1.2 證據（`otool -L`）

對 `dng_processor/dist/libdng_decoder_native.dylib` 執行 `otool -L`：

```
/Users/jhangyu/project/flutter_dng_decoder/dng_processor/dist/libdng_decoder_native.dylib:
	@rpath/libdng_decoder_native.dylib (compatibility version 0.0.0, current version 0.0.0)
	/opt/homebrew/opt/jpeg-turbo/lib/libjpeg.8.dylib (compatibility version 8.0.0, current version 8.3.2)   <-- 問題在這行
	/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation
	/System/Library/Frameworks/CoreServices.framework/Versions/A/CoreServices
	/System/Library/Frameworks/Metal.framework/Versions/A/Metal
	/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation
	/usr/lib/libz.1.dylib
	/usr/lib/libc++.1.dylib
	/usr/lib/libSystem.B.dylib
	/usr/lib/libobjc.A.dylib
```

對比說明：
- 第 1 行（自身的 install name）**已經**是 `@rpath` 形式，做法正確。
- 其餘 `/System/Library/...` 與 `/usr/lib/...` 是 macOS 系統內建，絕對路徑是正確且必要的。

#### 1.2.1 沙盒封鎖的直接證據（dyld 原始輸出）

以 `DYLD_PRINT_SEARCHING=1` 啟動已簽章、**沙盒啟用**的 release `.app`，dyld 輸出：

```
dyld: <E05D64C4-EB95-35E3-B217-B31493803F53> .../Halcyon.app/Contents/Frameworks/libdng_decoder_native.dylib
dyld: find path "/opt/homebrew/opt/jpeg-turbo/lib/libjpeg.8.dylib"
dyld:   found: dylib-from-disk: "/opt/homebrew/opt/jpeg-turbo/lib/libjpeg.8.dylib"
dyld:   found: dylib-from-disk-error: "/opt/homebrew/opt/jpeg-turbo/lib/libjpeg.8.dylib"
                => "file system sandbox blocked open()"
dyld:   not found: "/opt/homebrew/opt/jpeg-turbo/lib/libjpeg.8.dylib"
```

第一行證明**你們的 dylib 本身被成功找到並載入**（UUID 相符），打包沒有問題；失敗的是**下一步解析 libjpeg**，原因逐字是 `file system sandbox blocked open()`。

#### 1.2.2 修法有效性的直接證據（對複本做的診斷，非交付）

把 `libjpeg.8.dylib` 複製進 `.app/Contents/Frameworks/`，用 `install_name_tool -change` 把相依改成 `@loader_path/libjpeg.8.dylib`，重新簽章（**保留原 entitlements，沙盒仍啟用**）後，同一支 app：

```
[DngNativeBindings] loaded: libdng_decoder_native.dylib
rawDecode.ready x7      （修改前為 rawDecode.fail）
image.painted|...|tier=2 x4   （全部走真解碼路徑上屏）
```

即 **`@rpath`／隨附 libjpeg 是充分修法**，且沙盒不是額外障礙——只要相依落在 app bundle 內即可。

- **唯一有問題的就是 `/opt/homebrew/opt/jpeg-turbo/lib/libjpeg.8.dylib` 這一行**——它既非系統庫，又是絕對路徑，又沒有被隨附。
- Halcyon 端在本輪的實際 `.app` 產物上也跑了同一份檢查，輸出存於 `tmp/verify/r3b/otool_embedded.txt`（內容與上表一致）。

### 1.3 具體請求

擇一（依偏好排序）：

1. **靜態連結 jpeg-turbo（最推薦）**
   CMake 改為連結 `libjpeg.a`（或 `libturbojpeg.a`）。這樣 `otool -L` 中該行直接消失，下游零負擔，也不必處理版本相容。體積代價約數百 KB，對本用途可忽略。

2. **改為 `@rpath` 並隨附 dylib**
   - build 時對 native target 設定 `INSTALL_RPATH`／`BUILD_RPATH` 含 `@loader_path`。
   - 將 `libjpeg.8.dylib` 一併複製到 `native/build/`（以及 `dist/`），並在 link 階段讓相依變成 `@rpath/libjpeg.8.dylib`。
   - **同時更新 `native/scripts/build_native_watchdog.py` 的 `embed_macos_dylib()`**（目前只複製 `libdng_decoder_native.dylib` 單一檔案，見該函式），使其複製「dylib 集合」而非單檔，並對每一個都 `codesign`。
   - 這樣下游只要照抄一個 embed 步驟就能得到可散佈的 `.app`。

3. **（不接受的做法，請勿採用）** 要求下游用 `install_name_tool` 事後改寫。
   Halcyon 已明確裁決**不做**這件事：它會讓每個下游各自重新發明簽章與路徑改寫流程，且 `install_name_tool` 之後必須重新 `codesign`，極易在 CI 上以難以診斷的方式壞掉。這屬於**產出方（decoder）**的責任，不是消費方的。

### 1.4 期望的驗收方式

在 decoder 專案內：
```bash
otool -L <產出的 libdng_decoder_native.dylib> | grep -c '/opt/homebrew\|/usr/local/opt'
# 期望輸出 0
```
若採方案 2，另需：`.app/Contents/Frameworks/` 內同時存在 `libdng_decoder_native.dylib` 與 `libjpeg.8.dylib`。

---

## 2. 議題 B — 沒有 barrel export，也沒有 `flutter: plugin:` 宣告

### 2.1 現況

`dng_processor/lib/` 的實際內容：

```
lib/
  main.dart          <-- 一個 demo app 的 entry point
  src/
    dng_bindings.dart
    dng_decoder_service.dart
    dng_image_widget.dart
```

- **`lib/` 底下沒有任何 `dng_processor.dart`**，也沒有任何 `export` 敘述（`grep -rn '^export' lib/` 回傳空）。
- `pubspec.yaml` 的 `flutter:` 區塊只有 `uses-material-design: true`，**沒有 `plugin:` 宣告**。

### 2.2 Halcyon 因此被迫做的 workaround

**W1：import 私有路徑。**
Halcyon 必須寫

```dart
import 'package:dng_processor/src/dng_decoder_service.dart';
```

依 Dart 慣例，`lib/src/` 是**私有實作**，import 它等於宣告「我依賴你的內部結構」。這代表 decoder 團隊只要重新命名或搬動 `lib/src/dng_decoder_service.dart`，Halcyon 就會編譯失敗，而你們**沒有任何機制會察覺**——因為從 package 作者的角度看，動 `src/` 底下的東西本來就不算 breaking change。這是目前最脆弱的一點。

**W2：自行複製一份 dylib 打包邏輯。**
因為沒有 `flutter: plugin:` 宣告，Flutter 的 plugin 機制對 `dng_processor` **完全不會啟動**：不會有 podspec、不會有自動的 framework 嵌入、`flutter build macos` 不會知道有原生產物要處理。Halcyon 只好在自己的 `macos/Runner.xcodeproj/project.pbxproj` 裡新增一個 `Embed DNG Native Dylib` 的 Run Script phase，內容是「從 `../../flutter_dng_decoder/dng_processor/native/build/` 複製 dylib 到 `${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}` 再 codesign」。

這份邏輯與 decoder 專案自己的 `dng_processor/macos/Runner.xcodeproj/project.pbxproj:396-417`（`Embed DNG Native Dylib` phase，呼叫 `build_native_watchdog.py --embed-macos-dylib-only`）在做同一件事。也就是說**同一段打包知識現在存在兩個 repo、兩份實作**，往後任一方改了產物路徑或檔名，另一方會靜默壞掉。

附帶問題：Halcyon 的 Run Script 目前必須用**相對路徑跨出自己的 repo**（`$SRCROOT/../../flutter_dng_decoder/...`）去撈檔案。這只在「兩個 repo 是同層兄弟目錄」時成立，換一台機器或換 CI 佈局就壞。這是「沒有 plugin 宣告」直接導致的後果——正常的 Flutter plugin 由 pub 解析路徑，消費方不需要知道對方在檔案系統的哪裡。

### 2.3 乾淨的公開介面應該長什麼樣

**B-1：加一個 barrel export（成本最低、效益最大，建議優先做）**

新增 `lib/dng_processor.dart`：

```dart
/// Public API surface of the dng_processor package.
library dng_processor;

export 'src/dng_decoder_service.dart'
    show DngDecoderService, DngImage, DngDecodeException;
export 'src/dng_image_widget.dart' show DngImageWidget;
// 注意：dng_bindings.dart 屬於實作細節，刻意不 export。
```

如此下游只寫 `import 'package:dng_processor/dng_processor.dart';`，而你們保有隨意重構 `src/` 的自由。`show` 清單本身就成為「什麼算 public」的白紙黑字契約。

**B-2：把 demo app 從 `lib/` 移走**

`lib/main.dart` 是 demo 的 entry point，卻位於 package 的公開命名空間中（`package:dng_processor/main.dart`）。建議移到 `example/lib/main.dart`（標準 Flutter package 佈局）。這同時能讓 `dependencies:` 中的 `file_picker: ^8.0.0` 從**函式庫的相依**降級為**example 的相依**——目前只要有人依賴 `dng_processor`，就會被迫一併吞下 `file_picker` 這個 macOS plugin 及其 CocoaPods 相依，而 decode API 根本用不到它。Halcyon 本輪就吃到了這一項。

**B-3：宣告成真正的 FFI plugin（較大工程，但是正解）**

在 `pubspec.yaml` 加：

```yaml
flutter:
  plugin:
    platforms:
      macos:
        ffiPlugin: true
```

並補上 `macos/dng_processor.podspec`，由 podspec 負責 vendored library 的嵌入與簽章。這樣任何下游 app 只要 `flutter pub add dng_processor`，dylib 就會自動進 `.app/Contents/Frameworks/`——**消費方零 Xcode 設定**，W2 與跨 repo 相對路徑的問題一併消失。

若短期內只能做一項，請做 **B-1**（10 行、無風險）；B-3 是解決打包問題的唯一乾淨解，建議排入後續。

---

## 3. Halcyon 目前呼叫的符號（請勿破壞）

以下是 Halcyon round 3b 實際依賴的完整表面。若這些要改名、改簽章或改語意，請事先通知，或至少走一次 deprecation。

| 符號 | 目前位置 | Halcyon 如何使用 |
|---|---|---|
| `DngDecoderService`（class） | `lib/src/dng_decoder_service.dart:117` | 建構一個實例；不使用單例假設 |
| `DngDecoderService.initialize()` | 同上 `:133` | 允許被惰性自動呼叫，Halcyon 不強制先呼叫 |
| `DngDecoderService.decodeOnWorker(String filePath) → Future<DngImage>` | 同上 `:194` | **主要進入點**。Halcyon 只用這一個解碼 API（不使用 zero-copy 路徑） |
| `DngImage.rgbaData` (`Uint8List`) | 同上 `:30` | 直接餵給 `ui.decodeImageFromPixels`，假設為 **RGBA8 interleaved、無 padding、length == width*height*4** |
| `DngImage.width` / `DngImage.height` (`int`) | 同上 `:33` / `:36` | 假設**已裁切到 `DefaultCropSize`**（Halcyon 不會再裁一次） |
| `DngImage.decodeMs` / `DngImage.processMs` (`double`) | 同上 `:39` / `:42` | 僅用於效能埋點，非必要 |
| `DngDecodeException(int errorCode, String message)` | 同上 `:76` | 以 `catch` 判定「解碼失敗 → 回退舊路徑」。依賴其為 `Exception` 子型別 |
| dylib 檔名 `libdng_decoder_native.dylib` | `native/build/` 與 `dist/` | Halcyon 的 Xcode Run Script 依此檔名複製 |
| dylib 搜尋順序中的 `$execDir/../Frameworks/` 候選 | `lib/src/dng_bindings.dart:249-266` | **production 唯一可行的解析路徑**。這個候選若被移除，Halcyon 的 release build 立刻壞掉 |

明確**不**依賴的東西（可自由更動）：`DngImageWidget`、zero-copy／`NativeFinalizer` 路徑、`getPreviewJpeg()`、`pipelineCacheStatus`、`DNG_DEV_FALLBACK` 與 `DNG_NATIVE_BUILD_DIR` 環境變數（Halcyon 的測試用 `DynamicLibrary.open` 絕對路徑預載，不走 env）。

### 3.1 一個具體的行為契約請求

`decodeOnWorker` 目前的成功語意是「回傳一個 `DngImage`」，失敗語意是「拋 `DngDecodeException`」。Halcyon 依賴這個二分法。請求：**不要新增「回傳尺寸為 0 或空 buffer 的 `DngImage`」這種第三種狀態**——若解碼不成立，請一律拋例外。Halcyon 端已加了 `rgba.length == width * height * 4` 的斷言作為保險，但那是防禦性檢查，不應該是常態路徑。

---

## 4. 已知但**不**在本文請求範圍的事項

- **非 RGGB 相機的 R/B 通道對調（顏色缺陷）**：已知，且已有另一份交接文件（`flutter_dng_decoder/docs/logs/2026-08-16/cfa-pattern-hardcode-handover.md`）在處理。Halcyon 端**不會**在輸出端交換通道（使用者裁決：治標且掩蓋根因，且對 GRBG/GBRG 相位無效）。
- **EXIF orientation**：已確認 decoder 不處理方向，Halcyon 端自行套用。這是合理的分工，**不請求變更**。

---

## 5. 附錄：本文結論的取得方式（供 decoder 團隊複驗）

```bash
# 議題 A 的證據
otool -L /Users/jhangyu/project/flutter_dng_decoder/dng_processor/dist/libdng_decoder_native.dylib

# 議題 B 的證據
ls /Users/jhangyu/project/flutter_dng_decoder/dng_processor/lib
grep -rn '^export' /Users/jhangyu/project/flutter_dng_decoder/dng_processor/lib/
grep -n -A5 '^flutter:' /Users/jhangyu/project/flutter_dng_decoder/dng_processor/pubspec.yaml

# Halcyon 端 .app 內實際嵌入的 dylib（本輪產物）
otool -L /Users/jhangyu/project/Halcyon/build/macos/Build/Products/Release/Halcyon.app/Contents/Frameworks/libdng_decoder_native.dylib
```
