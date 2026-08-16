# 給 flutter_dng_decoder 團隊：`libdng_decoder_native.dylib` 在 sandbox 化的宿主 App 內無法載入

> **建立時間**：2026-08-17（UTC+8）
> **提出方**：Halcyon（`/Users/jhangyu/project/Halcyon`），round 3b 整合輪
> **嚴重度**：**P0 阻斷**。不是發行期問題，是**開發機上、現在**就讓功能完全不可用。
> **狀態**：根因已由 Halcyon 端**實驗確認**（非推測）；修法已由 Halcyon 端在 `.app` 副本上**實測驗證有效**。本文請 decoder 專案在**產出端**落實同一修法。

---

## 0. 一句話

`libdng_decoder_native.dylib` 以**絕對路徑**連結 Homebrew 的 `libjpeg.8.dylib`，且該相依未隨附。任何啟用 App Sandbox 的宿主 App 都讀不到 `/opt/homebrew`，於是 `dlopen` 失敗、解碼器完全無法使用。請改為 `@rpath` 並隨 dylib 一起交付 `libjpeg.8.dylib`。

---

## 1. 症狀（Halcyon 端實測）

Halcyon 是 Flutter macOS App，entitlements 含 `com.apple.security.app-sandbox = true`（Flutter macOS 範本預設值，非 Halcyon 自行加的）。

以 release build 執行、開啟一張無內嵌預覽的 Bayer CFA DNG 時：

```
PERF|2830983|rawDecode.fail|cfa_1|dur=57274|Bad state: Could not load native library from any of:
  libdng_decoder_native.dylib
  /Users/jhangyu/project/Halcyon/build/macos/Build/Products/Release/Halcyon.app/Contents/MacOS/../Frameworks/libdng_decoder_native.dylib
  /Users/jhangyu/Library/Containers/com.jhangyu.halcyon/Data/../native/dist/libdng_decoder_native.dylib
  /Users/jhangyu/Library/Containers/com.jhangyu.halcyon/Data/../native/build/libdng_decoder_native.dylib
```

**注意**：第 2 個候選（`Contents/Frameworks/`）就是你們 `dng_bindings.dart:249-266` 設計的正式路徑。它**被嘗試了而且失敗**——檔案確實存在於該路徑（`ls` 確認 1,456,592 bytes），所以這不是缺檔、不是路徑算錯。

---

## 2. 根因（已排除的可能 + 已確認的成因）

### 2.1 機械排除的可能性

| 可能原因 | 排除依據 |
|---|---|
| 檔案不存在 | `ls .../Contents/Frameworks/libdng_decoder_native.dylib` → 存在，1,456,592 bytes |
| 路徑計算錯誤（`Platform.resolvedExecutable` → `$execDir`） | 錯誤訊息中該路徑字面正確，可直接 `ls` 到 |
| Hardened Runtime 的 Library Validation | App flags `0x2 (adhoc)`、dylib flags `0x2 (adhoc)`，兩者皆**未**帶 runtime 旗標 |
| 簽章損毀 | `codesign -v -vvv` 對嵌入副本回報 valid on disk 且滿足 Designated Requirement |
| 嵌入的不是同一個 artifact | `dwarfdump --uuid` 兩端皆 `E05D64C4-EB95-35E3-B217-B31493803F53 (arm64)` |
| sandbox 拒絕存取 App 自身 bundle | `log show` 無相關 denial |

### 2.2 真正的成因——dyld 的原話，非推論

以 `DYLD_PRINT_SEARCHING=1` 執行沙箱化的 release `.app`：

```
dyld: <E05D64C4-EB95-35E3-B217-B31493803F53> .../Halcyon.app/Contents/Frameworks/libdng_decoder_native.dylib
dyld: find path "/opt/homebrew/opt/jpeg-turbo/lib/libjpeg.8.dylib"
dyld:   found: dylib-from-disk: "/opt/homebrew/opt/jpeg-turbo/lib/libjpeg.8.dylib"
dyld:   found: dylib-from-disk-error: "/opt/homebrew/..." => "file system sandbox blocked open()"
dyld:   not found: "/opt/homebrew/opt/jpeg-turbo/lib/libjpeg.8.dylib"
```

這段輸出同時確立兩件事：

1. **你們的 dylib 本身載入是成功的**——第一行是 dyld 從 `Contents/Frameworks/` 成功映射它、UUID 相符（透過 FlutterMacOS 的 `LC_RPATH @loader_path/../../..` 解析）。打包與路徑計算都沒有問題。
2. **失敗發生在下一跳**：解析 libjpeg 時被拒，理由字面就是 **`file system sandbox blocked open()`**。

`otool -L` 對應的相依宣告：

```
$ otool -L libdng_decoder_native.dylib
	@rpath/libdng_decoder_native.dylib
	/opt/homebrew/opt/jpeg-turbo/lib/libjpeg.8.dylib   <-- 絕對路徑，非 @rpath，未隨附
	/System/Library/Frameworks/CoreFoundation.framework/...
	/System/Library/Frameworks/Metal.framework/...
	/usr/lib/libz.1.dylib  /usr/lib/libc++.1.dylib  /usr/lib/libSystem.B.dylib  /usr/lib/libobjc.A.dylib
```

來源：`dng_processor/native/CMakeLists.txt:58-61`（註解為「macOS/host: use system libjpeg (typically Homebrew libjpeg-turbo)」）。

**沙箱程序無法讀取 `/opt/homebrew`。** `dlopen` 解析相依失敗，因此我們自己的 dylib 一併載入失敗。錯誤訊息之所以沒指出這點，是因為 `dng_bindings.dart:201-206` 的 `_openFirst` 只保留**最後一個**候選的錯誤字串，前面候選的真實失敗原因被丟棄了（見 §5 附帶建議）。

### 2.3 為什麼一般測試抓不到

未沙箱化的獨立 Dart 程序做 `DynamicLibrary.open('<絕對路徑>')` **會成功**——我們先前正是這樣驗證過「嵌入的 dylib 可載入」，得到綠燈。**沙箱是綠與紅之間唯一的差別。** 任何在 `dart run` / `flutter test` 下做的載入驗證都不會重現這個問題，因為那些程序不套用 App Sandbox。

---

## 3. 修法已被實測驗證（Halcyon 端在 `.app` 副本上做的實驗）

我們**沒有**把這個改動放進 Halcyon 的出貨路徑——這是產出方的責任。以下純為證明修法有效：

```bash
# 對 .app 的副本操作，不動原始 build
cp -R Halcyon.app <copy>
cp /opt/homebrew/opt/jpeg-turbo/lib/libjpeg.8.dylib <copy>/Contents/Frameworks/
install_name_tool -id     @rpath/libjpeg.8.dylib  <copy>/Contents/Frameworks/libjpeg.8.dylib
install_name_tool -change /opt/homebrew/opt/jpeg-turbo/lib/libjpeg.8.dylib \
                          @rpath/libjpeg.8.dylib  <copy>/Contents/Frameworks/libdng_decoder_native.dylib
install_name_tool -add_rpath @loader_path         <copy>/Contents/Frameworks/libdng_decoder_native.dylib
codesign --force -s - <copy>/Contents/Frameworks/libjpeg.8.dylib
codesign --force -s - <copy>/Contents/Frameworks/libdng_decoder_native.dylib
codesign --force -s - --entitlements <ents.plist> <copy>     # 保留 app-sandbox entitlement
```

修改後 `otool -L`：

```
	@rpath/libdng_decoder_native.dylib
	@rpath/libjpeg.8.dylib          <-- 已改
	...
```

**執行結果（同一支沙箱化 App、同一批 6 張 bare-CFA DNG、release build）：**

```
[DngNativeBindings] loaded: libdng_decoder_native.dylib     ×9
rawDecode.ready                                             ×9      失敗 0 次
PERF|3023298|rawDecode.ready|cfa_6|4080x3056|orient=1|dur=244377
PERF|6828616|rawDecode.ready|cfa_2|4080x3056|orient=1|dur=61438
PERF|6860203|rawDecode.ready|cfa_1|4080x3056|orient=1|dur=93067
PERF|10826418|rawDecode.ready|cfa_3|4080x3056|orient=1|dur=64489
```

修法生效前 `rawDecode.fail` ×N、生效後 `rawDecode.ready` ×9 且輸出 4080×3056 全解析度。**這是同一支 App、同一批樣本、只差這一處連結方式的對照。**

（順帶提供：解碼耗時 warm 約 61–93ms、cold 約 244–406ms，供你們自己的效能基準參考。）

---

## 4. 請求：在 decoder 專案端要做什麼

### 4.1 必做（P0）

**在產出 `libdng_decoder_native.dylib` 的建置流程中，把 libjpeg 改成可重定位的相依，並把它一起交付。**

具體有兩個方向，你們自行選擇，我們不指定實作：

| 方案 | 做法 | 取捨 |
|---|---|---|
| **A. 動態連結 + 隨附（對應本文已驗證的修法）** | CMake 連結後把 libjpeg 的 install name 改為 `@rpath/libjpeg.8.dylib`，並讓建置產物同時輸出 `libjpeg.8.dylib`；`build_native_watchdog.py --embed-macos-dylib-only` 一併嵌入兩個檔案；dylib 加上 `@loader_path` 的 rpath | 與現況最接近，已被實測證明可行；但多一個要交付的檔案 |
| **B. 靜態連結 libjpeg-turbo** | CMake 改連結 `libjpeg.a`（libjpeg-turbo 的靜態版），完全消除該外部相依 | 交付單一檔案、下游零負擔；dylib 體積增加；需確認 libjpeg-turbo 授權與靜態連結相容（BSD 類，通常可） |

**我們的偏好是 B（靜態連結）**，而且有一個具體理由，不只是「乾淨」：

我們讀了 `native/scripts/build_native_watchdog.py`，**它目前只嵌入／發佈單一檔案**，檔名寫死在兩個函式裡：

```
embed_macos_dylib()   :153  來源  native/build/libdng_decoder_native.dylib
                      :173  目的  <Frameworks>/libdng_decoder_native.dylib
                      :174  單一 shutil.copy2 + :175 單一 codesign
publish_macos_dist()  :185, :197  同樣的單檔假設
```

所以若採方案 A（隨附 libjpeg），**這兩個函式都要改**，而且**每一個下游宿主自己的嵌入步驟也都要跟著改**——Halcyon 這邊的 Xcode Run Script 就是其中之一。方案 B 則對嵌入路徑零改動，你們的 repo 與我們的 repo 都不用動。

（範圍聲明：我們讀的是 `build_native_watchdog.py` 這兩個函式，並在該腳本內 grep 過 `.dylib` / `shutil.copy` / `glob`。我們**沒有**稽核你們的 podspec、CI 或該腳本以外的打包路徑，所以上述是「至少要改這些」，不是「只要改這些」。）

若你們仍選 A，請在回覆中明確告知，並且**讓 `build_native_watchdog.py` 成為唯一的真實來源**（例如讓 `--embed-macos-dylib-only` 自己處理全部應嵌入的檔案），而不是讓每個消費者各自維護一份檔案清單——那份清單遲早會有人漏更新。

### 4.2 驗收條件（請以此自驗，我們也會用同一組檢查）

```bash
# 1. 不得再有任何非系統路徑的絕對相依
otool -L libdng_decoder_native.dylib | grep -v '^\s*/System/\|^\s*/usr/lib/\|@rpath\|@loader_path'
# 期望輸出：空（除了第一行的檔名本身）

# 2. 若採方案 A，交付物需含 libjpeg
ls <dist>/libjpeg.8.dylib          # 期望存在
otool -D <dist>/libjpeg.8.dylib    # 期望 @rpath/libjpeg.8.dylib

# 3. 沙箱實測（這一項最重要，前兩項過了它仍可能不過）
#    在一個 entitlements 含 com.apple.security.app-sandbox=true 的宿主 App 內
#    實際呼叫一次 decodeOnWorker，確認回傳成功而非 dlopen 失敗
```

**第 3 項是唯一有鑑別力的檢查。** 請不要只用 `dart run` 或 `flutter test` 驗證——那些程序不套 App Sandbox，這個 bug 在那裡是隱形的。這正是本問題直到端到端實測才浮現的原因。

### 4.2.1 你們可以在**自己的 repo 內**一行重現這個 bug

我們查了為什麼這個問題從未在你們那端出現，答案不是疏忽，是**你們的測試環境在結構上無法表達這個失敗條件**：

```
dng_processor/macos/Runner/DebugProfile.entitlements : com.apple.security.app-sandbox = false
dng_processor/macos/Runner/Release.entitlements      : com.apple.security.app-sandbox = false
```

debug 與 release **兩個組態都是 false**。你們的 demo app 在任何 build 模式下都不啟用沙箱，因此 `/opt/homebrew` 的讀取永遠會成功。

**重現步驟（不需要 Halcyon 參與）：**

1. 把 `dng_processor/macos/Runner/Release.entitlements` 的 `com.apple.security.app-sandbox` 改成 `<true/>`
2. 重新建置並執行你們自己的 demo app
3. 它會**載入不了自己的原生函式庫**

這就是那個 bug，在你們的專案裡。修好之後這一步會通過——建議把這個組態保留下來當成回歸測試，否則同類相依日後還會再溜進去而沒有人發現。

（附帶說明為什麼這值得設為常態：Flutter 的 macOS 專案範本**預設啟用** App Sandbox。也就是說絕大多數消費你們套件的宿主 App 會是沙箱化的，而你們的 demo app 是那個少數例外。）

### 4.3 其他兩項（非 P0，但同源，一併處理最省事）

先前 Halcyon 已備妥的介面請求文件 `docs/logs/2026-08-16/round-3b-decoder-project-interface-requests.md` 中的兩項仍然有效，而且與本問題**根因相同**（`dng_processor` 未宣告自己是可被消費的套件）：

1. **沒有 barrel export**：`lib/` 內沒有 `dng_processor.dart`，下游必須 `import 'package:dng_processor/src/dng_decoder_service.dart'`，觸發 `implementation_imports` lint。請提供一個 `lib/dng_processor.dart` 並以 `show` 明列公開符號。
2. **沒有 `flutter: plugin:` 宣告**：因此 Flutter 的 plugin 機制完全不會為它運作，宿主必須自行在 Xcode 專案內加一個 Run Script 去嵌入 dylib。若 `dng_processor` 宣告為 **ffiPlugin 並提供 podspec**，上述 1、2 與本文的 dylib 交付問題會被同一個改動一次解決。

---

## 5. 附帶建議（會省下下一個人的時間，非請求）

`dng_bindings.dart:201-206` 的 `_openFirst` 目前只保留最後一個候選的錯誤：

```dart
throw StateError('Could not load native library from any of:\n  <paths>\nLast error: $lastError');
```

本次診斷之所以花掉一整輪，是因為**真正失敗的是第 2 個候選，但訊息只印出第 4 個候選的錯誤**——看起來像「路徑都找不到」，實際是「找到了但相依解析失敗」。而且錯誤全文**從頭到尾沒有出現過 `libjpeg` 這個字**，把除錯者指向完全錯誤的方向。建議改為逐候選記錄各自的錯誤字串。這會把同類問題的診斷從一輪縮短到一眼。

另一項（影響下游驗收的寫法）：`dng_bindings.dart:194` 的成功訊息印的是**候選字串**而非解析後的實際路徑——

```dart
stderr.writeln('[DngNativeBindings] loaded: $path');   // $path 是候選字串，不是實際載入的路徑
```

所以即使實際是從 `Contents/Frameworks/` 載入，該行仍可能只印出 `libdng_decoder_native.dylib`。我們一度把驗收條件訂為「該行必須包含 `/Contents/Frameworks/`」——那個條件**在任何情況下都不可能被滿足**，與正確與否無關。建議改印解析後的絕對路徑，這樣下游才有辦法驗證「究竟從哪裡載入的」。

---

## 6. Halcyon 端現況（供你們判斷影響範圍）

- Halcyon round 3b 的其他部分**已完成並通過驗證**：native 端「無內嵌預覽」訊號、Dart sentinel、RGBA8 → `ui.Image` provider、EXIF 方向自套、tier-1/2 接線、`ui.Image` 生命週期（含一個實測抓到的 150MB 洩漏已修復）。全套測試 58 綠。
- Halcyon **不會**在自己這端做 `install_name_tool` 改寫作為出貨方案：那會讓每個下游各自重新發明簽章與路徑改寫流程，且改寫後必須重新 codesign，極易在 CI 上以難以診斷的方式壞掉。這屬於產出方的責任。
- 目前 Halcyon 的行為：解碼失敗時**自動回退**到舊的 ImageIO/CIRAWFilter 路徑，影像仍會上屏（只是慢、且放大會糊）。所以這不是黑畫面，是「新功能靜默缺席」。**這也代表如果你們不修，症狀不會顯眼——沒有人會收到錯誤回報。**
- 修好之後 Halcyon 這邊不需要任何改動即可生效：pubspec 已用 path 依賴指向 `../flutter_dng_decoder/dng_processor`，Xcode Run Script 已呼叫你們的 `build_native_watchdog.py --embed-macos-dylib-only`。若採方案 A，請確認該 flag 也會嵌入 libjpeg，否則我們這端需要對應調整——**若需要我們配合改動，請在回覆中明確說明**。

---

## 7. 證據檔（Halcyon repo 內，需要時可索取）

| 內容 | 路徑 |
|---|---|
| 修法生效前後的完整 launch log | `tmp/verify/r3b/close_launch4.log`（fail）、`tmp/verify/r3b/probe_launch.log`（ready） |
| 沙箱容器內的 perf log | `~/Library/Containers/com.jhangyu.halcyon/Data/r3c/perf.log` |
| 嵌入 dylib 的 codesign / UUID / otool 檢查 | `tmp/verify/r3b/embedded_dylib_checks.txt`、`tmp/verify/r3b/close_otool.txt` |
| 先前的介面請求文件（barrel export / plugin 宣告） | `docs/logs/2026-08-16/round-3b-decoder-project-interface-requests.md` |

（`tmp/` 為 gitignore 目錄，不會進版控；需要請直接索取內容。）
