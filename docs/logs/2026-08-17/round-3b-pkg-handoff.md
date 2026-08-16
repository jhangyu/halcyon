# Round 3b — pkg squad handoff（2026-08-17）

> 寫檔者：`pkg-lead-opus`（squad pkg：`pkg-impl-1-sonnet` 實作、`pkg-test-haiku` 獨立驗證）。
> **一句話**：pkg 的驗收條件 **A1–A5 全數通過**，但**功能仍不可用**——被一個外部相依卡死。綠燈 ≠ 功能會動，這份文件存在的主要理由就是防止未來讀者把兩者混為一談。

---

## 0. 先讀這段（防誤讀）

| 問題 | 答案 |
|---|---|
| pkg 的驗收條件過了嗎？ | **全過。** A1 打包、A2 smoke test、A3 介面文件、A4 otool、A5 嵌入產物完整性。 |
| 那 RAW 解碼功能能用嗎？ | **不能。** sandbox 下 `dlopen` 失敗，實測 `rawDecode.fail`。 |
| 為什麼兩者不矛盾？ | pkg 負責「把 dylib 正確放進 `.app` 並可被呼叫」，這件事做到了且有證據。擋住功能的是 **decoder 專案產出的 dylib 以絕對路徑連結 Homebrew libjpeg**，那是別的專案的產物缺陷，本輪無權也不應在 Halcyon 端修。 |
| 使用者看到什麼？ | 圖仍然出得來（走舊的低解析度路徑），不是黑畫面。這靠的是 pipe squad 堅持保留的 fallback。 |

---

## 1. 交付內容

| 檔案 | 內容 |
|---|---|
| `pubspec.yaml` / `pubspec.lock` | `dng_processor` path 依賴（`../flutter_dng_decoder/dng_processor`） |
| `macos/Podfile.lock` | 因 `file_picker`（dng_processor 的傳遞相依，且是 macOS plugin）而變動 |
| `macos/Runner.xcodeproj/project.pbxproj` | 新增一個 `PBXShellScriptBuildPhase`「Embed DNG Native Dylib」（id `A1B2C3D4E5F60718293A0001`），排在 "Bundle Framework" 之後 |
| `lib/services/dng_decode_service.dart` | 實作凍結的 `DngFullDecoder` seam：`decodeDngFull(path)` 包住 `decodeOnWorker`，驗證 `rgba.length == w*h*4`，`DngDecodeException` 直接往上拋（呼叫端視為回退訊號）。對外符號 `halcyonDngFullDecoder` |
| `test/dng_decoder_smoke_test.dart` | 真解碼 smoke test（見 §3 的兩個陷阱） |
| `docs/logs/2026-08-16/round-3b-decoder-project-interface-requests.md` | 跨專案介面請求文件（含已更正的嚴重性） |

## 2. 驗收證據

| ID | 條件 | 結果 | 證據 |
|---|---|---|---|
| A1 | release build 成功且 dylib 已嵌入 | PASS | `tmp/verify/r3b/v_frameworks_ls.txt` |
| A2 | `decodeOnWorker` 對 vivo 樣本跑通（4080×3056、49873920 bytes） | PASS | `tmp/verify/r3b/v_smoke_test.txt` |
| A3 | 介面文件存在且含 libjpeg／barrel export 兩節 | PASS | `docs/logs/2026-08-16/round-3b-decoder-project-interface-requests.md` |
| A4 | 嵌入 dylib 的 `otool -L` | PASS | `tmp/verify/r3b/otool_embedded.txt` |
| A5 | 嵌入產物完整性（codesign 有效／Mach-O UUID 相符／可 `dlopen`） | PASS | `tmp/verify/r3b/embedded_dylib_checks.txt` |
| Z3 | **sandbox 下的實機載入** | **FAIL（外部原因）** | `tmp/verify/r3b/z3_rootcause.txt`、`tmp/verify/r3b/z3diag_dyld.log` |

**A1 刻意未綁定最終 tree**：本輪全程未 commit，且 pipe squad 同時在同一棵樹上編輯，orchestrator 於 round close 另行重綁。

## 3. 兩個必須知道的技術事實

### 3.1 dylib 在測試環境的載入（決定 A2 為何能過）

`flutter test` 下，`dng_processor` 的搜尋候選 #1（裸檔名）**必定失敗**——dyld 對不含斜線的名稱不搜尋 cwd；候選 #2（`$execDir/../Frameworks/`）對 `flutter_tester` 不存在。實測：

```
LEAF_FAIL_COLD / ABS_OK / LEAF_OK_AFTER_PRELOAD
```

即：先以絕對路徑 `DynamicLibrary.open` 載入後，裸檔名再開即成功（dyld 比對已載入 image），且 dlopen 狀態是 **process-wide**，涵蓋 `decodeOnWorker` 的 `Isolate.run` worker。smoke test 的 preload 就用這個機制，路徑由 `.dart_tool/package_config.json` 解析，**無硬編 home 路徑**；`lib/services/dng_decode_service.dart` 刻意**不含**此 workaround。

**⚠️ 不得誤讀**：smoke test log 中的 `[DngNativeBindings] loaded: libdng_decoder_native.dylib` 是**裸檔名**，代表上述 preload 生效，**不是** production `Contents/Frameworks/` 路徑的證據。

### 3.2 `[DngNativeBindings] loaded:` 印的是候選字串，不是解析後路徑

`dng_bindings.dart:194` 記錄的是**嘗試的候選字串**，不是 dyld 實際解析到的絕對路徑。因此「該行必須包含 `/Contents/Frameworks/`」這種驗收條件**在任何情況下都不可能成立**，無論實作正確與否。要判斷實際從哪裡載入，唯一可靠的儀器是 `DYLD_PRINT_SEARCHING=1` 的 dyld 輸出。（已請 decoder 團隊改印解析後絕對路徑。）

## 4. 阻擋原因（外部）

`libdng_decoder_native.dylib` 以**絕對路徑**連結 `/opt/homebrew/opt/jpeg-turbo/lib/libjpeg.8.dylib`，而該檔不隨 `.app` 打包。macOS App Sandbox 不允許讀 `/opt/homebrew`，於是 dyld 找得到我們的 dylib、卻在解析其相依時被擋，整個 `dlopen` 失敗。dyld 原文：

```
dyld: <E05D64C4-EB95-35E3-B217-B31493803F53> .../Halcyon.app/Contents/Frameworks/libdng_decoder_native.dylib
dyld: find path "/opt/homebrew/opt/jpeg-turbo/lib/libjpeg.8.dylib"
dyld:   found: dylib-from-disk-error: "/opt/homebrew/..." => "file system sandbox blocked open()"
dyld:   not found: "/opt/homebrew/opt/jpeg-turbo/lib/libjpeg.8.dylib"
```

第一行同時證明**我們的打包是對的**（UUID 相符，成功從 `Contents/Frameworks/` 映射）。

**修法已驗證有效**（僅在複本上做的診斷，未進交付）：把 libjpeg 放進 `Contents/Frameworks/` 並改成 `@loader_path`、重簽章（保留 entitlements）後，同一支沙盒 app：`rawDecode.ready ×7`、`image.painted|…|tier=2`、零失敗。

**使用者裁決：不在 Halcyon 端自救。** 理由：`install_name_tool` 這層是暫時性的，日後必須拆除，而「有移除期限但沒人會執行」的 workaround 不值得累積；且 fallback 已保證使用者看到的是舊的慢路徑而非壞掉的 app。等 decoder 團隊修（優先靜態連結 jpeg-turbo）。

**為什麼 decoder 團隊從未發現**：`dng_processor/macos/Runner/{DebugProfile,Release}.entitlements` 兩份都是 `app-sandbox = false`，`dist/dng_processor.app` 也無此 entitlement。他們的宿主 app 從不沙盒化，此缺陷在他們專案內**結構性不可觀測**。

## 5. Parking lot（下輪處理，本輪不動）

1. `pubspec.yaml` 用相對路徑 `../flutter_dng_decoder/dng_processor`——只在兩個 repo 為同層兄弟目錄時成立。
2. Xcode run script 以 `$SRCROOT/../../flutter_dng_decoder/...` 跨出 repo——**同一個假設的第二個實例**。只修 pubspec 仍然會壞。
3. decoder 的 demo `lib/main.dart` 位於 package 公開命名空間，導致 `file_picker` 成為函式庫級相依（Halcyon 用不到）。
4. 三個既有的 CocoaPods "did not set base configuration" 警告（本輪之前就有，未調查）。
5. libjpeg 絕對路徑連結——即 §4，已轉交 decoder 團隊。

1–3 共用同一根因與同一解法：**decoder 宣告為 ffiPlugin 並提供 podspec**（介面文件的建議 B-3）。

## 6. Do-not-optimise：那個 Xcode 警告是刻意的

build 時會出現：

> `Run script build phase 'Embed DNG Native Dylib' will be run during every build because it does not specify any outputs.`

**這是刻意的，不要「修好」它。** 加上 `outputPaths` 會重新啟用相依分析，讓過期的 dylib 在重建後存活——正是這個 phase 存在要防止的失敗。

## 7. 兩條方法論規則（比它們保護的發現更值錢）

1. **重簽沙盒 app 來測試時，必須保留 entitlements，否則你測的是另一支程式。**
   實例：驗證修法時先用了 `codesign --force --deep --sign -`，它**靜默移除 entitlements**，app 隨即以非沙盒身分執行，相對的 `HALCYON_PERF_DIR` 改對 cwd 解析、載到 0 個項目，還在 repo 根目錄留下一個 `./r3c/`。那次執行什麼都沒證明，而它看起來像個結果。正確做法：`codesign -d --entitlements :-` 取出原 entitlements，重簽時以 `--entitlements` 帶回，並在採信結果前先確認 `app-sandbox` 仍在。
2. **out-of-process 的探針無法驗證 in-process 的安全策略。**
   A5 check 3 的 `DynamicLibrary.open` 在獨立、**非沙盒**的 Dart 程序中成功；同一件事在沙盒 app 內失敗。兩者差別只有沙盒。凡是驗證對象牽涉沙盒／entitlement／權限的，探針必須跑在**同一個安全脈絡**內。

附帶：本輪共出現七次「儀器錯了，不是程式錯了」——依 chat 時間戳推論 build 過期、隊友半存檔的檔案、對 re-sign 後的檔案比 sha256、過期 shell cwd、`// ignore:` 註解位置、非沙盒探針、以及不可能成立的 Z3 判準。**負面結果只有在確認儀器指對地方之後才算證據。**

## 8. 復現與驗證命令

```bash
# smoke test（非沙盒，會過）
flutter test test/dng_decoder_smoke_test.dart

# 嵌入產物完整性
otool -L build/macos/Build/Products/Release/Halcyon.app/Contents/Frameworks/libdng_decoder_native.dylib
dwarfdump --uuid <上者> <../flutter_dng_decoder/dng_processor/native/build/libdng_decoder_native.dylib>

# 沙盒實機（會失敗，直到 decoder 修好）— 樣本須鏡像進容器，路徑須相對
CONT=/Users/jhangyu/Library/Containers/com.jhangyu.halcyon/Data
DYLD_PRINT_SEARCHING=1 HALCYON_PERF_DIR=r3c HALCYON_PERF_OUT=r3c/perf.log \
HALCYON_PERF_N=1 HALCYON_PERF_MODE=paced \
  build/macos/Build/Products/Release/Halcyon.app/Contents/MacOS/Halcyon 2>&1 | grep -i 'sandbox blocked'
# 判讀前先確認 driver 真的跑過（否則是 inconclusive，不是 failed）：
grep -c 'perf.init' "$CONT/r3c/perf.log"
```
