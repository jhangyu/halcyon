# Windows v1.0.15 雙擊啟動即崩潰 — Session Handover

> **【已結案 2026-10-01 23:15】** 根因＝H1 細化版：`RedirectMissingOutputToNul()` 在真雙擊時呼叫 engine `FlutterDesktopResyncOutputStreams()`，該函式寫死開 `CONOUT$`，無 console 必失敗後 `_dup2(-1,…)` → UCRT fastfail 0xC0000409/arg5（A/B 單變數 build + H2–H4 證偽定讞）。且舊修法連 errno 6 也修不到——engine DLL 靜態連結自己的 CRT，DLL 載入時（早於 wWinMain）即綁定 stdio。正解（c0492fc）：`/DELAYLOAD` engine+plugin DLL + wWinMain 先 `SetStdHandle(NUL)`（`EnsureStdOutputHandles`，支援 `HALCYON_STDIO_LOG`），刪除舊函式；CI gate `H-ENGINE-DELAYLOAD` 防回歸。v1.0.16 已發佈為 Latest，發佈 zip 通過雙擊等價驗收（啟動 + RAF 解碼）。全部證據：`scripts/tmp/debug2/`；教訓：`~/.claude/rules/lessons-learned.md` 2026-10-01「雙擊崩潰根因定讞」條。本文件其餘內容為歷史紀錄。

> **建立時間**：2026-10-01 20:00（UTC+8）
> **交接目的**：讓下一個 session 接續「Halcyon Windows 雙擊啟動崩潰」，終態是：**以雙擊（Explorer）方式啟動的 CI 發佈版 Halcyon 可正常開啟並解碼 RAF，修正後重新發佈。**
> **目前判定**：阻塞（根因未確認，只有高信心假設）；v1.0.15 release 已刪除，Latest = v1.0.13（見 §8 P0）
> **可信版本錨點**：halcyon `main` HEAD `0e6c5b0`（= tag v1.0.15）；ceyx `main` HEAD `b9248f1`（= tag v0.1.29）

## 0. 接手速讀（60 秒）

- **目標**：Windows 使用者雙擊 halcyon.exe 能啟動；RAF 能開。
- **現象**：使用者雙擊 CI 發佈的 v1.0.15 → 啟動時立刻崩潰。Event 1000：`flutter_windows.dll`、`0xC0000409`、offset `0xf99a68`。用我的方式（從 shell 呼叫 `Start-Process`）啟動同一個資料夾**不會**崩潰。
- **目前位置**：還沒重現雙擊啟動的條件，也還沒取得 call stack。
- **主要假設（未證實，信心中高）**：`windows/runner/utils.cpp:30-43` 的 `RedirectMissingOutputToNul()` 只有在「真的沒有 stdio」時才會走到 `freopen_s("NUL")` + `FlutterDesktopResyncOutputStreams()`。真正雙擊時才會進入這條路徑，可能在引擎自己的 CRT 裡觸發 invalid-parameter → `__fastfail`（0xC0000409）。這段程式碼從 v1.0.14（`0031cdf`）起就存在，而我們所有的「無 stdio」驗證都經由 shell 啟動，**從來沒有走到這條路徑**。
- **下一個動作**：讀 WER dump 的 call stack（§1 步驟 3），並用「真正無 stdio」的方式重現（§8 P1）。
- **紅線**：判斷是否崩潰，不得再用 shell 的 `Start-Process` 結果。螢幕鎖定時不做截圖驗證。

## 1. 接手啟動序列

1. Read 本檔 §2、§9，以及 `windows/runner/utils.cpp:24-43`、`windows/runner/main.cpp:10-20`。後兩者是 stdio 處理的進入點。
2. Run `git -C C:/Users/User/project/halcyon log --oneline -3`，預期 HEAD 為 `0e6c5b0 chore(release): bump version 1.0.14 -> 1.0.15`。
3. 取 call stack：WER 已把 dump 存在 `C:\ProgramData\Microsoft\Windows\WER\ReportArchive\AppCrash_halcyon.exe_*`（最新 4 筆，19:51–19:53）。若只有 .wer 沒有 .dmp，就在 HKCU 設 `Software\Microsoft\Windows\Windows Error Reporting\LocalDumps\halcyon.exe`（`DumpType=2`），請使用者雙擊一次，取得 dump 後用 `cdb -z <dmp> -c "!analyze -v; kb; q"` 分析。用完後還原登錄。前一個 debugger 也曾回報 HKCU LocalDumps 沒產生 dump，若同樣失敗，改用步驟 4。
4. 重現雙擊條件（不需要使用者）：`explorer.exe "C:\Users\User\Downloads\Halcyon-windows-x64-v1.0.15\halcyon.exe"`，預期出現新的 Event 1000，模組為 `flutter_windows.dll`。如果不崩潰，見 §9 第 1 列的替代方法。
5. 修復後的驗證：用步驟 4 的方式啟動，加上開 RAF，同時檢查畫面（螢幕必須未鎖定，`Get-Process LogonUI` 查無結果）。

## 2. 目的、現象與根因狀態

### 目的
雙擊啟動的 Windows 發佈版能正常運作。這是使用者唯一的實際使用方式。

### 現象
- **條件**：使用者在 Explorer 雙擊 `C:\Users\User\Downloads\Halcyon-windows-x64-v1.0.15\halcyon.exe`。這是從 CI release 下載的 zip。
- **實際**：立刻崩潰。Event 1000 共 4 筆：
  - 19:51:08 pid 23852
  - 19:51:16 pid 21968
  - 19:51:27 pid 9076
  - 19:53:18 pid 24724
  - 4 筆的特徵都是 `flutter_windows.dll|c0000409|0xf99a68`。
- **對照**：從 shell 執行 `Start-Process`，啟動同一資料夾、v1.0.13、v1.0.14 CI 版、本機 build 的 v1.0.15，**全部存活**（`scripts/tmp/startup_ab.txt`，19:54 那一段）。
- 19:53:18 那一筆可能是我的第一次重現，也可能是使用者又雙擊了一次，**未確認**。

### 根因／假設
- **已確認**：與 AVX-512 那個 bug 無關。崩潰模組不同，而且是在開檔之前就崩潰。DLL 的 sha 與已驗證的 `f0649c10` 相同。
- **主要假設 H1（未證實）**：雙擊時 stdout/stderr 無效 → `RedirectMissingOutputToNul()` 執行 `freopen_s("NUL")` 並呼叫 `FlutterDesktopResyncOutputStreams()` → 引擎 CRT 對無效 fd 做 dup/fileno → CRT invalid parameter → fastfail 0xC0000409，所以出事位置在 `flutter_windows.dll` 內。
  - 支持 H1 的證據：shell 啟動會繼承有效的 handle，`reopened` 為 false，整段被跳過，所以不會崩潰。這與目前的觀察一致。
- **替代假設**：
  - **H2**：PATH 或環境變數不同，導致 DLL 搜尋結果不同。shell 的 PATH 含有 VS/LLVM/flutter 路徑，Explorer 的沒有。
  - **H3**：cwd 不同。
  - **H4**：Intel Vulkan/GPU 驅動的初始化路徑不同。
- **辨識實驗**：
  - (a) 讀 dump 的 stack：若 top frames 有 `_invalid_parameter` 或 `_dup2`，且來自 `FlutterDesktopResyncOutputStreams` → H1。
  - (b) 用 `explorer.exe` 啟動 → 會崩潰。
  - (c) 在 runner 加一個 env 開關跳過 `RedirectMissingOutputToNul`，用本機 build 雙擊 → 不崩潰即證實 H1。

## 3. 範圍與版本控制狀態

- **In scope**：
  - `windows/runner/main.cpp`
  - `windows/runner/utils.cpp`、`windows/runner/utils.h`
  - Flutter engine `FlutterDesktopResyncOutputStreams` 的行為
  - 雙擊條件下的驗證方法
- **Out of scope**：ceyx（v0.1.29 已驗證）；kvazaar AVX2（parking）。
- **halcyon**：`main` @ `0e6c5b0`，已 push。
  - Working tree：7 個 `generated_plugin*` 檔（linux/macos/windows）顯示為 M，但只是 `flutter pub get` 產生的 CRLF 變動，`git diff` 內容為空。不是本次改動，不要 commit。
- **ceyx**：`main` @ `b9248f1`。`image_samples/raw_corpus/README.md` 有既有的未提交修改，不是本 session 改的，不要碰。
- **相關 commits**：
  - halcyon `0031cdf`（在 v1.0.14 內）：加入 `RedirectMissingOutputToNul`，是 H1 的嫌疑點。
  - ceyx `b9248f1`：RawSpeed3 portable baseline + Windows AVX-512 gate（已修好 RAF 的 0xC000001D）。
  - halcyon `8fc2bfd`：repin 到 ceyx v0.1.29；`0e6c5b0`：版本 1.0.15。
- **背景狀態**：無。team 已全數關閉，cron 已清，worktree 已刪。

## 4. 目前邏輯架構（本階段切面）

| 節點 | 責任 | 關鍵符號 | 上游 | 下游 | 不變式／失敗語意 |
|---|---|---|---|---|---|
| Win32 runner `wWinMain` | 處理程序進入點與 console/stdio 設定 | `windows/runner/main.cpp:13-17` | Explorer / shell | utils、Flutter engine | 雙擊時沒有 console 也沒有 std handle |
| `RedirectMissingOutputToNul` | stdio 無效時把 stdout/stderr 重開到 NUL，並同步給引擎 | `windows/runner/utils.cpp:30-43` | main | `FlutterDesktopResyncOutputStreams` | 只有 `reopened==true` 才會呼叫 resync；**shell 啟動永遠不會進入這段** |
| `FlutterDesktopResyncOutputStreams` | 引擎用自己的 CRT 重新同步 stdout/stderr | `flutter_windows.dll`（sha `a5c880a4…`，與 v1.0.13/14 相同） | runner | 引擎 CRT | 疑似 H1 的崩潰點（0xf99a68） |
| dart:io stdout/stderr | isolate 內的輸出 | ceyx worker isolates | engine | — | handle 無效時會丟 errno 6，殺死 worker isolate（09-30 已知），這正是當初加上 runner 修正的原因 |

## 5. 資料生產消費鏈

不適用：本問題是處理程序啟動時的 stdio handle 生命週期，沒有資料流。關鍵鏈為：
`Explorer CreateProcess（無 std handle）→ runner CRT stdout fd 無效 → freopen NUL（runner CRT）→ Resync（engine CRT）→ dart:io`。
失敗點在 Resync 那一跳（H1）。

## 6. 型別與介面契約

| 契約 | Producer 定義 | Consumer 假設 | 不變式 | 錯誤語意 | 證據 |
|---|---|---|---|---|---|
| `FlutterDesktopResyncOutputStreams()` | Flutter engine（Windows embedder） | runner 假設呼叫一定安全 | 引擎 CRT 的 fd 1/2 必須能對應到有效 handle 才能 dup | 失敗即 CRT invalid param → fastfail，不會回傳錯誤 | 未讀引擎原始碼（**未驗證**）；upstream 範本只在 `CreateAndAttachConsole` 成功後才呼叫（`utils.cpp:10-21`） |

## 7. 已完成事項（本 session）

| 結果 | 改動／產物 | 驗證 | 版本錨點 |
|---|---|---|---|
| [C] RAF 崩潰根因：clang-cl 下 `-march=native` 在 AVX-512 runner 編出 EVEX | `scripts/tmp/debug/root-cause.md` | 崩潰位址的 disasm、per-march 重編 bytes 一致、歷代發佈掃描 | ceyx v0.1.28 |
| [C] ceyx 修復 + Windows AVX-512 gate | ceyx `b9248f1`，tag v0.1.29 | CI 36794250361、36795143750 success；gate 掃 21 libs，EVEX=0 | `b9248f1` |
| [C] v0.1.29 DLL 解 RAF | `scripts/tmp/raf_e2e_test.dart` | v0.1.28 EXIT=79（程序死亡）→ v0.1.29 7752x5178，ASCII 與中文路徑皆 PASS | DLL `f0649c10` |
| [C] halcyon repin + 發佈 v1.0.15 | `8fc2bfd`、`0e6c5b0` | CI 36798220983 success；Release 36798582040 success | `0e6c5b0` |
| [C] v1.0.14 GitHub release 已刪除（tag 保留） | — | `gh release list` 已無 v1.0.14 | tag `6778b9e` |
| [U] v1.0.15 開 RAF 不崩潰 | — | 只在 shell 啟動條件下驗證過，**雙擊條件未驗** | — |

## 8. 待解議題

| 優先 | 狀態 | 議題 | 解除條件 | 下一動作 | 完成條件 |
|---|---|---|---|---|---|
| P0 | [C] | v1.0.15 下架 | — | 2026-10-01 20:05 使用者批准：v1.0.15 與 v1.0.14 的 GitHub release 已**刪除**（tag 保留：v1.0.15=`0e6c5b0`、v1.0.14=`6778b9e`）；v1.0.13 重設為 Latest（`/releases/latest`=v1.0.13；v1.0.15 zip URL 回 404） | 修好後重新發佈**必須升版到 1.0.16**：tag v1.0.15 已存在，Auto-release gate 會 AUTO-RELEASE-SKIP |
| P1 | [B] | 取得崩潰 call stack／可重現的雙擊條件 | 有 dump 或能用 explorer 重現 | §1 步驟 3、4 | stack 的 top frames 能區分 H1–H4 |
| P1 | [U] | v1.0.13（沒有 runner 修正）雙擊會不會崩潰 | — | 用 `explorer.exe` 啟動 `scripts/tmp/debug/var/app13_dll27/halcyon.exe` | v1.0.13 存活 + v1.0.15 崩潰 → 鎖定 `0031cdf` |
| P2 | — | 最小根因修復 | H1 已確認 | 依 dump 決定。候選：不呼叫 Resync 而改用 `SetStdHandle` + `_dup2` 只修 runner 自己的 CRT；或在 Dart 端讓 stdout/stderr 寫入失敗不致命。修法要交給 opus architect 確認 | 雙擊啟動存活，且 RAF 能解碼（errno 6 不再殺死 worker） |
| P3 | — | 驗證儀器 | — | 加一個「雙擊等價」的 launch harness（explorer.exe 或 CreateProcess 不給 std handles），並寫進 release 前的固定驗收 | harness 對 v1.0.15 會紅、修好後轉綠 |
| P4 | [D] | kvazaar `/clang:-mavx2`（無 AVX2 的 CPU 上 HEIC 編碼會崩潰）；igvk64.dll 0xC0000409（v1.0.7–9 的舊崩潰） | 使用者排程 | — | — |

## 9. 嘗試、裁決與禁止重踩

| 嘗試／方案 | 結果 | 裁決 | 可否重試 | 證據 |
|---|---|---|---|---|
| 用 shell `Start-Process` 當「無 stdio／雙擊等價」 | 全部存活，與使用者雙擊結果矛盾 | **不是雙擊等價**。從 bash/powershell 啟動會繼承 std handle，`RedirectMissingOutputToNul` 根本不會執行。v1.0.14 當初的「red→green」也是在這個條件下驗的，所以 runner 修正本身**從未在真正的雙擊條件下驗過** | 否 | `scripts/tmp/startup_ab.txt` |
| 螢幕鎖定時用 PrintWindow 截圖判斷是否解碼 | 全部白畫面，連控制組也是 | 鎖定時 DWM 不合成畫面，截圖無效 | 只能在 `Get-Process LogonUI` 查無結果時使用 | `scripts/tmp/fix/shots/ctl_green_*.png` |
| 單次排程 30 分鐘後檢查背景工作 | 工作停擺 | watchdog 間隔不得超過 8 分鐘（已記入 memory） | 否 | — |
| 只核對 release zip 裡的 DLL sha 就當作發佈驗收 | 漏掉啟動崩潰 | 發佈驗收必須用雙擊等價方式啟動**實際發佈的 zip** | 否 | — |

## 10. 未來方向

- release workflow 加一個 Windows「無 std handle 啟動 smoke」job：CreateProcess 時不給 handle，啟動後存活 N 秒才算過。
- 觸發條件：P3 harness 在本機做出來之後。

## 11. 已知限制與不確定性

- **現況限制**：Latest 為 v1.0.13。雙擊開 RAW 會解碼失敗（errno 6），但不會崩潰。下一版發佈前，使用者沒有可正常開 RAW 的 Windows 版本。
- **未驗證**：H1–H4 都還沒驗證；`FlutterDesktopResyncOutputStreams` 的引擎實作還沒讀；WER dump 是否存在還沒查。
- 19:53:18 那筆 crash 是誰觸發的未確認。

## 12. 驗收命令

```bash
# 1) 雙擊等價重現（預期修前：新 Event 1000 flutter_windows.dll c0000409；修後：無）
explorer.exe "C:\\Users\\User\\Downloads\\Halcyon-windows-x64-v1.0.15\\halcyon.exe"
powershell -NoProfile -Command "Get-WinEvent -FilterHashtable @{LogName='Application';Id=1000;StartTime=(Get-Date).AddMinutes(-2)} | ? { \$_.Properties[0].Value -eq 'halcyon.exe' } | % { (\$_.Properties|% Value) -join '|' }"
# 2) RAF headless 解碼回歸（預期 7752x5178 ascii+unicode，All tests passed，EXIT=0）
sh scripts/tmp/run_raf_e2e.sh "<app dir>" raf_check.log
# 3) 靜態分析（預期 CI-SUMMARY failed=0）
python scripts/ci.py verify
```

## 13. 參考入口

- **必讀**：`windows/runner/utils.cpp:24-43` — 嫌疑程式碼及其原始動機（errno 6）。
- **必讀**：`windows/runner/main.cpp:10-20` — 呼叫順序：AttachConsole → Redirect。
- **Artifact**：
  - `scripts/tmp/startup_ab.txt` — shell 啟動 4 個版本全部存活（2026-10-01 19:54）。
  - `scripts/tmp/handover-2026-10-01.md` — 上一段 AVX-512 事件的完整帳。
  - `scripts/tmp/debug/root-cause.md` — RAF 崩潰根因。
  - `scripts/tmp/fix/` — 修復驗證證據。
  - `scripts/tmp/raf_e2e_test.dart` + `run_raf_e2e.sh` — headless RAF 解碼 harness。
- **相關教訓**：`~/.claude/rules/lessons-learned.md` 的 2026-09-30（雙擊＝無 stdio）、2026-10-01（-march=native、鎖屏截圖）。注意：09-30 那條寫的修法（freopen NUL + Resync）正是 H1 的嫌疑點，待確認後要修正該條。
