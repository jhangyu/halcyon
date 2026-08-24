# 共用基線登錄檔（baseline-registry.md）

> **用途**：跨輪次／跨 session 的正典基線。任何任務開工前**先查此檔**；已登錄且錨點未變的基線**禁止重量**——直接引用登錄值與 artifact 路徑。
> **更新規則**：每輪合併回 `main` 並通過合併後驗證時，把該輪**已驗證的 after 數字升格為新基線**（換錨點 hash、換 artifact 路徑），由該輪 lead 在 handoff 中登錄、指揮官簽收後寫入本檔。量測方法不變就不重跑。
> **失效條件**：僅當（a）錨點 commit 之後**受測表面**的程式碼有變動，或（b）量測機器／toolchain 更換時，該條基線才需重量。文件改動不使基線失效。
> **量測紀律**：一律遵守 `docs/logs/2026-08-23/m4-m6-remaining-handover.md` §6（自捕 `$?`、binary provenance、`stat -L`、`-j 1`）。

## 現行錨點：`main` @ `c2ae385`（M5 合併：RAW 全解析度 tier-2 雙窗，2026-08-24 升格）

### 測試套件（合併後於 main 實測，test-runner-haiku 執行、指揮官抽查簽收，2026-08-24）
| 項目 | 值 |
|---|---|
| `flutter analyze` | 0 issues（RC_ANALYZE=0） |
| `flutter test -j 1`（單次全跑） | RC_TEST=0，**EXECUTED=252 / PASSED=252 / SKIPPED=0**（246＋M5-DW 6） |
| 凍結三 sha | 與本檔登錄值逐字元相同（RC_SHASUM=0） |
| 證據 | `scripts/tmp/verify/main-post-merge-c2ae385.txt`；worktree 閘 `gate-m5-final.txt`（副本 `scripts/tmp/m5-verify/`） |

## 前錨點：`main` @ `72afd7a`（Round 2 合併：parking-lot＋P-2/P-2b provenance stamp；review 經使用者裁決跳過，2026-08-24 升格）

### 測試套件（合併後於 main 實測，test-runner-haiku 執行、指揮官抽查簽收，2026-08-24；量測時 HEAD `a0c14a4` 為 docs-only 疊加，程式碼同 `72afd7a`）
| 項目 | 值 |
|---|---|
| `flutter analyze` | 0 issues（ANALYZE_RC=0） |
| `flutter test -j 1`（單次全跑） | TEST_RC=0，**EXECUTED=246 / PASSED=246 / SKIPPED=0**（243＋Round 2 新增 3） |
| 證據 | `scripts/tmp/verify/main-post-merge-72afd7a.txt`（HEAD 與 RC 自捕於 artifact 內） |

## 前錨點：`main` @ `2a15d74`（M4 round-1 合併，2026-08-24 升格）

### 測試套件（合併後於 main 實測，指揮官親跑，2026-08-24）
| 項目 | 值 |
|---|---|
| `flutter analyze` | 0 issues（ANALYZE_RC=0） |
| `flutter test -j 1`（三塊分跑） | 各塊 RC=0，**EXECUTED=243 / PASSED=243 / SKIPPED=0**（238＋4 個 M4 測試＋1 個碰撞回歸測試） |
| 證據 | 三塊 tail 輸出（+142／+65／+36 All tests passed!，RC 自捕）；artifact 副本 `scripts/tmp/m4-round1-verify/` |

## 前錨點：`main` @ `b3b0ddd`（M3 收盤，2026-08-23；latency 基線仍屬此錨點）

### 測試套件（lead 已簽收，2026-08-23T16:34Z）
| 項目 | 值 |
|---|---|
| `flutter analyze` | 0 issues（ANALYZE_RC=0） |
| `flutter test -j 1` | TEST_RC=0，**EXECUTED=238 / PASSED=238 / SKIPPED=0** |
| 樣本閘門實跑證明 | TC-089（dng_nav_probe_m3）與 photo_source fixture 檢查確實執行 |
| artifact | 副本存 `scripts/tmp/m4-round1-verify/`（原 worktree 已清理） |

### 凍結測試閘門 sha256（改動需使用者授權）
| 檔案 | sha256 |
|---|---|
| `test/dng_nav_probe_m3_test.dart` | `e93cfb9247d7541d9bd36184893c47b8fb6b9469b92a0a0cb7da72d9e2234133`（2026-08-25 P4b 重新登錄，理由見下） |
| `test/photo_source_probe_test.dart` | `f32e20f9ed6241ad4d165732033df07d2cff7e2216c139c83eb16ccf387631ce`（2026-08-25 P4b 重新登錄，理由見下） |
| `test/image_preload_controller_m3_amend3_test.dart` | `d624da3ce92e4ee6ad7e8e689a09c29391ddccc224699e8ad4ade121ace5239f`（2026-08-24 P3.3 重新登錄，理由見下） |
| ~~`scripts/tmp/dng_nav_probe_test.dart`（主樹持有正本）~~ | **2026-08-24 R3 使用者決議刪除**（`git rm`，見下方 R3 附記）——此列凍結 sha 已隨檔案一併作廢，不再代表任何現存檔案 |

#### P4b 重新登錄理由（2026-08-25，P2–P4 remediation contract AC-4）
`PhotoSource.probe()`（`lib/services/photo_source.dart:332` 舊行號）是零生產呼叫者的投影，僅為讓上列兩個凍結測試檔編譯而保留（`docs/logs/2026-08-23/m4-m6-remaining-handover.md` items 1、5）。使用者本次「團隊修復 P2–P4 所有議題」指令即為修改凍結檔之明確授權，範圍僅限 `probe()` 呼叫點的等價改寫：
- `test/dng_nav_probe_m3_test.dart`（TC-088 sanity 斷言，舊 `:152`）：`PhotoSource.probe(path, longEdge: n)` → `(await PhotoSource.probeSource(path, longEdge: n)).cost`，斷言目標（`SourceCost` 期望值、fixture）逐字未動，僅換呼叫面。
- `test/photo_source_probe_test.dart`（TC-072/073/074/075/076，共 8 處呼叫點）：同樣的等價改寫，`onDiskRead` 回呼與所有斷言（含 TC-075 的 300KB／2-byte 預算、TC-076 的 `isNull` 分辨）逐字未動。
- `lib/services/photo_source.dart`：刪除 `probe()` 方法本體與其上整段 doc-comment（原 `:319-338`），`probeSource()` 之上的既有 doc-comment未提及 `probe()`，無需另外修訂。
- `lib/services/prefetch_scheduler.dart:98`：註解原文引用「`probe()` 投影」作為反面對照，已改寫為說明 `probe()` 已不存在、其僅存呼叫者（凍結測試）已改呼叫 `probeSource` 本身，語意不變（不得直接呼叫 cost-only 投影）。
- 驗證：`grep -rn "static Future<SourceCost?> probe" lib/` → 0 命中；`flutter test test/dng_nav_probe_m3_test.dart test/photo_source_probe_test.dart -j 1` → 12/12 passed，RC=0（`scripts/tmp/p2p4/impl2-targeted-tests.txt`）。

#### C-4 封印解除理由（M6 P3.3，2026-08-24）
- **觸發原因**：三檔皆 `import 'package:halcyon_flutter/services/native_thumbnail_service.dart';` —— 該檔案本輪整檔刪除（型別搬到 `lib/services/image_source_types.dart`，`NativeThumbnailService`/`kNoEmbeddedPreviewCode`/`kAllowRawDecodeSignalArg` 隨通道一併刪除）。三檔皆需改 import 才能編譯，此為 C-4 定義下「衝突案例」，非任意修改。
- `test/dng_nav_probe_m3_test.dart`：僅改 import 一行；另**刪除 TC-089**（`180-204` 舊行號，`test('TC-089 real preview-bearing DNG content probe cheap leads to immediate loader work', ...)`）——該案已由計畫 Appendix B 列為 P3.3 刪除項；TC-088 原樣保留。斷言邏輯（除 TC-089 刪除外）逐字未動。
- `test/image_preload_controller_m3_amend3_test.dart`：僅改 import 一行，斷言邏輯逐字未動（Appendix B：Keep unchanged 指內容/斷言，import 因來源檔刪除被迫更新）。
- `scripts/tmp/dng_nav_probe_test.dart`：僅改 import 一行；本檔自述「THROWAWAY DIAGNOSTIC PROBE -- not part of the test suite」（`:1`），非 `flutter test` 套件成員；`flutter analyze` 對它另外回報 pre-existing（本輪之前就存在）的 `decodedImageFor`/`decodedProviderFor` API 過期錯誤（M3 後期已刪除該二方法，`image_preload_controller_test.dart` 內有對應「FORCED TRANSLATION」註解為證），與本輪改動無關，不在 P3.3 範圍內修復，如實記錄於此。
- `test/dng_extractor_swift_test.dart`（**刪除，非重新登錄**——本檔不在上表凍結清單內，經 grep 核實，故無需 sha 儀式）：2026-08-24 lead 授權範圍追加。本檔透過 `scripts/tmp/run_dng_extractor_tests.sh` shell out 編譯 `macos/Runner/DngPreviewExtractor.swift`；該 Swift 檔已被平行成員的 P3.1（macOS 原生刪除）任務刪除，其受測實作已不存在。Dart 側等效覆蓋率已存在於 `test/dng_preview_extractor_test.dart`。整檔刪除（C-4：受測主體消失，非任意修改）。

#### P5.2 稽核附記（2026-08-24）
- Appendix B（`m6-execution-plan.md:1092-1105`）10 列逐列核對：disposition 全數已在對應 commit 執行（`git log --oneline -- <file>`／`git show --stat` 交叉核對），凍結三檔的 sha256 與本檔登錄值逐字元相符（`shasum -a 256`，見 `scripts/tmp/m6-r2-verify/p5-baseline.txt`）。
- `scripts/tmp/dng_nav_probe_test.dart` 本次重新檢視：內容自 P3.3 登錄後未變（sha 相符），未發現任何斷言單平台語意的新案例，**無需刪除任何 case、無需重新登錄 sha**。`flutter analyze` 對它回報的 `decodedImageFor`/`decodedProviderFor` 未定義方法錯誤（10 處）仍是 P3.3 記載的既有問題（`analysis_options.yaml:17-18` 本就把 `scripts/**` 排除在 `flutter analyze` 護欄外，不影響正式 gate），非本輪改動引入，不在 C-4 範圍內修復。
- **文件標籤更正（已由 R3 解決，留存歷史記錄）**：本檔與 `m6-execution-plan.md` 曾稱 `scripts/tmp/dng_nav_probe_test.dart`「gitignored」，但 `git ls-files scripts/tmp/dng_nav_probe_test.dart` 顯示**此檔實際受版控追蹤**（`.gitignore` 未列出它），且 commit `3a7a2b2` 的 diff 確實包含它的 373 行內容。P5.2 當時如實記錄此標籤與事實不符，未擅自處置。

#### R3 附記（2026-08-24）：`scripts/tmp/dng_nav_probe_test.dart` 已刪除
使用者於 M6 P4 review 收尾階段決議直接刪除本檔（`git rm`），理由：明明受版控追蹤卻長期被文件誤稱「gitignored」、內含過期 `decodedImageFor`/`decodedProviderFor` API（M3 後期已刪除的方法）、且不屬於任何 gate（`flutter test` 套件、`flutter analyze` 均排除它）。此舉解決了上一條「文件標籤更正」附記所述的矛盾——不再需要決定是否補進 `.gitignore`，因為檔案本身已不存在。上表凍結 sha 列已標記作廢，不再指向任何現存檔案。

### JPEG 切換延遲（PerfLog `selectItem.enter`→`image.painted`，release，本機 arm64；定版：原始已登錄 traversal 的分模式重算，n=12／格）
**判準（round-1 lead 定版）**：`band_mode = max(p95_mode − median_mode, 1.5ms)`；`PASS_mode ⟺ after_median ≤ baseline_median + band`；paced 與 rapid 分開判定、永不混池；四格（2 資料集 × 2 模式）全過才算過。敏感度註記：paced 是載重閘；rapid 的大 band 是模式本質（超越 preloader 本來就會產生偶發即時解碼），只能抓粗退步。

| 資料集 | 模式 | 中位數 | 門檻（median+band） |
|---|---|---|---|
| A（字面 JPG） | paced | 3.928 ms | ≤ 6.013 ms |
| A（字面 JPG） | rapid | 3.270 ms | ≤ 59.024 ms |
| B（便宜 DNG） | paced | 4.264 ms | ≤ 5.949 ms |
| B（便宜 DNG） | rapid | 7.987 ms | ≤ 55.086 ms |

> 出處：jpgA_run1＋run2、dngB_run1 的原始登錄 traversal 分模式重算（同一 binary @ b3b0ddd）。一批 n=36 的加量重跑因與禁止重量指令訊息交錯而產生，artifact 留存於 `halcyon-m4/tmp/verify/` 但標記 **out-of-scope**，不入正典。
> **2026-08-24 使用者裁定後**：UI 切換延遲／RSS 一律由使用者親自量測；agent 只准純後台 headless 解碼基準。本表僅作為使用者自量時的對照基線。

### 峰值 RSS（歷史，出自設計權威 §12.1；量的是昂貴樣本組）
| 情境 | 值 |
|---|---|
| M3 之前基線 | 1,043,218,432 bytes = 994.9 MiB |
| M3 round-2 收盤 | 996,392,960 bytes = 950.2 MiB |
| 便宜樣本組 | **從未量測**（P-1，需先做 P-2 版本戳記） |

### 常數與樣本正典（引用，不重查）
- `imageCacheMaxBytes` = 768 MiB（805,306,368）；`kPayloadByteBudget` = 224 MiB（234,881,024）——相反樣本組計算，不可互驗（AD-019）。
- `kTierTwoRadius` = 2；`kExpensiveStartupRadius` = 1——不得合併（AD-018）。
- 樣本正典 26 檔：昂貴 13（十二個 `2024-07-*`＋`IMG_20251112_092839.dng`）、便宜 13（`2026-*`）。mtime 不可信。

## 登錄歷史
- 2026-08-24：升格錨點 `c2ae385`（M5 合併後套件 252/0 skip，artifact main-post-merge-c2ae385.txt）。
- 2026-08-24：升格錨點 `72afd7a`（Round 2 合併後套件 246/0 skip，artifact main-post-merge-72afd7a.txt）。
- 2026-08-24：建檔，錨點 `b3b0ddd`。套件／凍結閘門／JPG-A 延遲由 M4 round-1 實測並經 lead 簽收；DNG-B 待 round-1 handoff 定版。
