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

## 3.5 關閉前兩位 lead 各留下一條，都比它們表面看起來重要

### (a) 那個阻斷不是壞運氣——它寫在我們自己的契約裡

`pipe-impl-2-opus` 指出：libjpeg 絕對路徑**就列在本輪收斂契約的 out-of-scope 清單裡**（「本輪接受 homebrew 絕對路徑」），第一天就凍結了。A3 文件的存在正是因為它。所以擋住終態的那個決定，是我們自己刻意做並且寫下來的。

記為規則而非軼事：

> **一個直接坐落在「通往宣稱終態」關鍵路徑上的緩議項，不是緩議項，是一個沒有排程的阻斷。**

後果：B1–B5、A1–A3、Z1 每一條都可以通過（而且都通過了），而那句一行終態在**每一台機器上**都不可達。

**下輪檢查法**：對每一個 out-of-scope 項目問一句——如果它永遠不落地，終態還可達嗎？若否，它就不是 out-of-scope，是一個**沒有 owner 的相依**。本輪把它跟 Android、原生 RAW 這些真正正交的項目並列，是分類錯誤；緩議本身仍然可辯護，但應該記成「除非 X 落地否則終態不可達」。

### (b) `orient=1` 不能被讀成方向功能已驗證

同一位成員指出：Z3 實測輸出的 `orient=1` 是**恆等變換**，八個 case 裡最弱的一個——那張真實樣本剛好是正的。orientation 2–8 仍然只對合成 2×3 fixture 驗證過，而**它們才是壞掉時會被肉眼看見的那幾個**。

原始的 Z3 段落寫法暗示了比實際更高的覆蓋率。這與本文件花一整節警告的失效模式是同一種（真實陳述授權了錯誤推論），寫在那份文件裡尤其諷刺，已修正。

### (c) 紅燈的歧義：triage 規則

`pipe-lead-opus` 與 `pkg-lead-opus` 各自獨立提出同一件事——本文 §2 的耦合會讓**紅燈的意義變得歧義**：正常情況下紅燈代表「我們弄壞了東西」，這裡它可能代表「別人正在編輯」。未來的 session 在日誌裡看到本輪那次 post-commit 紅燈，沒有任何辦法把它和真實迴歸區分開。

**round 3c 二擇一，要刻意選，不要預設落入其一：**

1. **把依賴釘在某個 commit** — 相依變成可重現，我們的紅燈永遠代表我們的程式碼。
2. **保留 path 依賴並採用 triage 規則** — 任何 stack 起源於 `/Users/jhangyu/project/flutter_dng_decoder` 的失敗，在對方樹靜止前一律不可行動；debug 任何東西之前先跑 `git -C ../flutter_dng_decoder status --short` 確認為空。

`pkg-lead-opus` 補充：這讓 A3 文件裡的建議 B-3（decoder 宣告為 ffiPlugin + 提供 podspec）從「整理」升格為**承重**——已發佈或釘選的套件能徹底解耦，`path:` 依賴在結構上做不到。建議與 libjpeg 修復一起進 3c 範圍，因為兩者是同一批 decoder 端打包工作，合做比分做便宜。

## 4. 本輪未關閉的驗收條件

| ID | 狀態 |
|---|---|
| A1–A5、B1–B5、Z1 | 全數通過，證據見兩份 squad 交接文件 |
| **Z2** | **FAIL，成因外部（見 §1）**。decoder 樹乾淨後需重跑 |
| **Z3** | **FAIL，成因外部**。已證明修法有效（patched `.app` 副本：`rawDecode.ready` ×9、4080×3056、61–406ms） |
| 使用者真機確認 | **未執行**。是「功能可用」與「記憶體行為可接受」兩項主張的唯一憑據 |
