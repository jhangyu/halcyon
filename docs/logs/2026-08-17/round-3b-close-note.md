# Round 3b 收尾註記（orchestrator，2026-08-17 00:45）

Commit：`bcc096b`。squad 交接文件見 `round-3b-pkg-handoff.md` 與 `../2026-08-16/round-3b-pipe-interface-frozen.md`。

## 1. Z2（post-commit 全套重跑）：FAIL，但成因在**另一個專案的活體工作樹**

commit 後立即重跑 `flutter test` 得 `EXIT=1`，4 個測試檔編譯失敗：

```
../flutter_dng_decoder/dng_processor/lib/src/dng_bindings.dart:204:42:
  Error: Method not found: '_resolvedImagePath'.
```

錯誤**不在 Halcyon 的任何檔案內**。取證：

| 事實 | 依據 |
|---|---|
| 出錯檔案屬於 decoder 專案 | 路徑 `../flutter_dng_decoder/...` |
| 該檔正被編輯中 | mtime `00:42:44`，晚於本輪 G4 綠燈（`+58 All tests passed!`，同一棵 Halcyon 樹） |
| 半成品狀態 | `_resolvedImagePath(lib, path)` 已被呼叫，函式尚未寫出 |
| Halcyon 端未變 | commit 前後 `git status` 一致；G4 與此次之間 Halcyon 無任何改動 |

**判定：不是本輪缺陷，commit 成立。** 本輪的 G4 是在同一棵 Halcyon 樹上綠的，唯一變數是外部 repo。

## 2. 這暴露一個比 Z2 失敗本身更重要的結構問題

`pubspec.yaml` 以 **path 依賴**指向 `../flutter_dng_decoder/dng_processor`，因此 **Halcyon 的測試套件會編譯另一個團隊的 Dart 原始碼**。後果：

- 對方樹上任何半成品，都會讓我們的測試套件變紅，且錯誤訊息指向我們無權編輯的檔案。
- 我們的 CI／驗收在時間上與另一個團隊的編輯耦合。這與「共用工作樹上兩個 agent 互相踩」是同一種危害，只是跨了專案邊界。
- 原本記在 parking-lot 的「相對路徑依賴要求兩個 repo 是同層目錄」，實際嚴重度比預期高一級：問題不只是**換機器會斷**，而是**同一台機器上、對方正在工作時就會斷**。

**給 round 3c 或任何後續輪次的建議**（未實作，僅記錄）：在 decoder 專案穩定後，改用釘選版本的依賴（git ref／發佈的 package／vendored 產物），而不是指向對方活體工作樹的 path 依賴。在那之前，任何 Halcyon 的驗收批次都應先確認 `git -C ../flutter_dng_decoder status --short` 是乾淨的，否則紅燈可能與自己無關。

## 3. decoder 團隊已在處理（觀察，非承諾）

收尾當下 `git -C ../flutter_dng_decoder status` 顯示他們正在改動的檔案，與我們送出的請求逐項對應：

| 他們的改動 | 對應請求 |
|---|---|
| `lib/src/dng_bindings.dart` | 印出解析後的絕對路徑（handover §5） |
| **新檔** `lib/dng_processor.dart` | barrel export（介面請求 B） |
| `macos/Runner/Release.entitlements` | 沙箱重現組態（handover §4.2.1） |
| `native/CMakeLists.txt` | libjpeg 連結方式（handover §4.1） |
| 已 commit `bb6f5e7` | CFA 相位改讀 `CFAPattern`，即非 RGGB 顏色缺陷 |

顏色相位修復看來已經落地。**但這些都尚未經 Halcyon 驗證**——已排 cron（`e429e8d4`，2026-08-17 05:41）依 handover §4.2 的機械判準複驗，判準第三項（在沙箱宿主內實測）是唯一有鑑別力的一項。

## 4. 本輪未關閉的驗收條件

| ID | 狀態 |
|---|---|
| A1–A5、B1–B5、Z1 | 全數通過，證據見兩份 squad 交接文件 |
| **Z2** | **FAIL，成因外部（見 §1）**。decoder 樹乾淨後需重跑 |
| **Z3** | **FAIL，成因外部**。已證明修法有效（patched `.app` 副本：`rawDecode.ready` ×9、4080×3056、61–406ms） |
| 使用者真機確認 | **未執行**。是「功能可用」與「記憶體行為可接受」兩項主張的唯一憑據 |
