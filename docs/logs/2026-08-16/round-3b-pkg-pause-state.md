# Round 3b — pkg squad pause state（2026-08-16 暫停時落檔）

> 目的：這輪 pkg 的結論已散在對話中，暫停後不應假設任何人還記得。以下只記**不在別處的東西**；A1–A5 的逐條狀態與 parking-lot 已記於 task #1 描述與 orchestrator 的紀錄，不重複。
> 寫檔者：pkg-lead-opus。凍結中，未跑任何 build。

## 1. dylib 載入的關鍵事實（決定了 A2 為何能過）

`flutter test` 下，`dng_processor` 的 dylib 搜尋候選 #1（裸檔名 `libdng_decoder_native.dylib`）**必定失敗**——dyld 對不含斜線的名稱不搜尋 cwd；候選 #2（`$execDir/../Frameworks/`）對 `flutter_tester` 也不存在。

實測結論（本輪開工前由 lead 親自探測，勿再重推）：
```
LEAF_FAIL_COLD        裸檔名冷開，失敗
ABS_OK                絕對路徑開，成功
LEAF_OK_AFTER_PRELOAD 絕對路徑載入後，裸檔名再開即成功（dyld 比對已載入 image）
```
dlopen 狀態是 **process-wide**，因此涵蓋 `decodeOnWorker` 內的 `Isolate.run` worker。

`test/dng_decoder_smoke_test.dart` 的 preload 就是靠這個機制，路徑由 `.dart_tool/package_config.json` 的 `rootUri` 解析，**無硬編 home 路徑**。`lib/services/dng_decode_service.dart` 刻意不含此 workaround。

## 2. 一個必須防止的誤讀（重要）

smoke test log 中的 `[DngNativeBindings] loaded: libdng_decoder_native.dylib` 是**裸檔名**，代表上節的 preload 生效，**不是** production `Contents/Frameworks/` 路徑的證據。任何人不得引用該行當作 Z3。

## 3. pkg 證明了什麼、沒證明什麼

- **已證明**：嵌入 `.app` 的 dylib 是正確產物（Mach-O UUID `E05D64C4-EB95-35E3-B217-B31493803F53` 與來源一致）、簽章有效（codesign 通過 Designated Requirement）、且可從 production 路徑字串載入（`DynamicLibrary.open` OK）。
- **未證明（刻意）**：running app 自己會以 `Platform.resolvedExecutable` → `$execDir` 算出該路徑。這一環只有 Z3 能關。

## 4. Z3（round-close 存活驗證）的三個陷阱

以 `HALCYON_PERF_DIR` 驅動 release binary 無頭跑決定可行——`lib/perf/perf_driver.dart:29` 僅以 env 判斷，`lib/perf/` 內**無** `kReleaseMode`/`kProfileMode` gate。但：

1. **`HALCYON_PERF_OUT` 預設是絕對路徑**（`perf_driver.dart:33-35`），`PerfLog.init` 立刻 `createSync(recursive:true)`，sandbox 下丟 `PathAccessException`。該例外落入 `runZonedGuarded`，而其 handler 呼叫 `PerfLog.log`＋`flushSync`——**錯誤處理依賴剛剛初始化失敗的子系統**，於是 driver 靜默死亡、不解碼、不印任何 dylib 行，外觀與「production 路徑壞掉」完全相同。**必須顯式給相對路徑。**
2. **容器路徑**：bundle id `com.jhangyu.halcyon`，Data dir 為 `/Users/jhangyu/Library/Containers/com.jhangyu.halcyon/Data`。樣本需鏡像進去，`HALCYON_PERF_DIR` / `HALCYON_PERF_OUT` 皆須相對。
3. **預設 `N=24`、`MODE=both`、`PACE=1200`** 會把兩秒能看到的事拖成一分鐘以上。Z3 只需一次解碼，設 `N=1`、`MODE=paced`。

### 前置證偽檢查（必須先跑，不可事後才拿來解釋失望結果）
```bash
CONT=/Users/jhangyu/Library/Containers/com.jhangyu.halcyon/Data
grep -c 'perf.init' "$CONT/r3b/perf.log"
```
注意 `perf.log` 在**容器內**，不在 repo；查 repo 相對路徑會得到「檔案不存在」，恰好偽裝成「driver 沒跑」。
- `>=1` → driver 有跑，缺 `[DngNativeBindings] loaded:` 才是真訊號。
- `0` 或檔案不存在 → driver 沒起來，Z3 **inconclusive，不是 failed**，不得據此向使用者升級。

## 5. 本輪教訓（值得帶走的一條）

**負面結果只有在確認「儀器指對地方」之後才算證據。** 不存在、半寫入狀態、錯的 cwd、過期快照，四者產生的輸出長得一模一樣。本輪五次「看起來對其實不對」：
1. 依 chat 訊息時間戳推論 build 過期（實際 `AppDelegate.o` mtime 證明已編譯）。
2. `_disposeDecodedEntry` 未定義（實際是隊友半存檔，35 秒後方法就在 line 444）。
3. sha256 embedded vs source MISMATCH（Xcode re-sign 必然改變 sha256，判準本身錯；正解是 Mach-O UUID）。
4. orchestrator 的 grep 在過期 shell cwd 下回 "No such file"（讀起來像檔案消失）。
5. lead 自己把 `// ignore:` 放在說明註解上方——Dart 的 ignore 只作用於**緊接的下一行**，中間夾註解會靜默失效，`dart analyze` 才驗出來。

## 6. 暫停時的紀律

不 revert、不 stash、不 reset、不 checkout。樹上留著他人未提交工作是常態。凍結（不得跑 macOS build）在暫停後依然有效，直到 orchestrator 明確 all-clear。
