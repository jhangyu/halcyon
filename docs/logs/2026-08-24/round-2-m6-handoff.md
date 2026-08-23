# Round 2 交接（parking-lot 落地；M6 停泊）

> **建立**：2026-08-24，m6-lead-opus（Round 2 squad lead）
> **分支**：`m6-cleanup`（自 `main` @ `2a15d74` 切出）｜**tip**：`99d1c36`
> **契約**：`docs/logs/2026-08-24/m4-m6-convergence-contract.md`（凍結；本輪 AC8 經歷一次修訂後被使用者撤回，見 §3）
> **基線登錄**：`docs/logs/2026-08-24/baseline-registry.md`
> **寫作對象**：零脈絡的下一輪。假設你沒讀過本輪任何過程紀錄。

---

## 0. 六十秒速讀

- **task #7（parking-lot 五項）全部完成並簽收**，5 個 commit，tip `99d1c36`，全套 **245 執行／0 skip／`TEST_RC=0`**。
- **task #6（M6）未動一行，零 commit，經使用者裁定停泊（Opt-3）**。原因不是做不完，是**契約的前提被證明是錯的**。
- **本輪最重要的產出是那份否定結果**：M6 的 delete list 建立在一個從未發生的 M3 計畫之上。詳見 §3——下一輪的 M6 re-contract 應從該節開始，不要從設計權威 §7 重新開始。
- **附帶取得一個本輪最有價值的數字**：`DngPreviewExtractor.swift` 若照原計畫刪除，便宜 DNG 預覽會慢 **94–183 倍**且解析度從 6000x4000 掉到 2800px——實測，非推理，見 §3.4。原計畫把這個檔案當成不可達的死碼。
- 三個凍結閘門 sha256 **不變**，AD-018／AD-019 未動，D4 grep 維持 0。
- **未合併回 `main`**——合併由指揮官執行，合併後在 `main` 上重跑全套仍是獨立閘門。

---

## 1. 完成的工作（task #7）

| commit | 內容 |
|---|---|
| `5361077` | `fix(preload)`：側欄縮圖 loader 拋例外不再中斷整趟 sweep（PL-1／PL-2／PL-10） |
| `9e8bc76` | `test(preload)`：第二道 preview generation guard 的交付測試（PL-7） |
| `013059b` | `docs(unit_test)`：artifact provenance 慣例寫入測試策略節（PL-9） |
| `7b0e323` | `docs(unit_test)`：TC-100..103 → TC-105..108 去撞號；新測試登錄 TC-109／110（PL-8） |
| `99d1c36` | `feat(perf)`：build commit ＋兩個常數寫入 perf log（P-2） |

### 1.1 PL-1／PL-2／PL-10（唯一的生產程式碼改動）

`lib/services/image_preload_controller.dart:913-948`（`preloadThumbnails` 每項迴圈）：
- loader 的 `await` 進 `try`，`_loadingKeys.remove(loadingKey)` 移入 `finally`。
- loader **拋出**時視同非 bytes 結果：寫入 `_thumbPermanentMisses`（且先檢查 `generation == _thumbBatchGeneration`），**迴圈繼續**跑完其餘縮圖。
- 修的是 `b3b0ddd` 就存在的潛伏洞，不是本輪引入的。原行為：例外逸出 for 迴圈 → 該趟 sweep 其餘縮圖全部不被請求，且 `thumb_<id>` 條目洩漏整個 session。

**紅燈證據品質（本輪唯一一次 red-first，值得照抄的樣板）**：`tmp/verify/pl1-red.txt`，`RC=1`，`+0 -1`——**該次執行中唯一失敗的就是新測試**，證明失敗來自反例而非環境。artifact 首行帶 PROVENANCE，載明 base HEAD `2a15d740…` 與內容標記（「此次執行早於 PL-1/2/10 commit，`preloadThumbnails` 迴圈中尚無 try/catch」）。綠燈 `tmp/verify/pl-a-b-final-green.txt`，`RC=0`。

新測試：`test/image_preload_scheduling_m4_test.dart:150-233`，`M6-PL1 a throwing sidebar thumbnail loader must not abort the sweep, must release the in-flight key, and must record a permanent miss like a non-bytes result`。

### 1.2 PL-7 第二道 generation guard

新測試 `test/image_preload_scheduling_m4_test.dart:236-313`（`M6-PL7`）。場景刻意與 AC2 不同：把 stale pass 停在 **window await** 內（受測項落在舊 pass 的保留視窗內、新 pass 的視窗外），才會走到 guard 2（`:406`）。
**一開始就是綠的**（guard 本來就正確，round-1 reviewer 的探針早已顯示這點），所以綠燈本身不構成證據——靈敏度另證：暫時註解掉 guard 2（標記 `MUTATION-MARKER-PL7-TEMP`）→ 紅 `tmp/verify/pl7-mutation-red.txt` `RC=1` → 還原。**現樹已驗 `grep -rn "MUTATION-MARKER" lib/` 無命中**（lead 於 tip 複驗）。

### 1.3 PL-8／PL-9（文件）

- PL-8：`unit_test.md` 的四筆 M4 矩陣條目 TC-100..103 → **TC-105..108**。撞號對象是 `test/image_preload_window_test.dart:335` 已佔用的字面 `TC-100`。
- 實作者**額外**把兩個新測試登錄為 TC-109（M6-PL1）／TC-110（M6-PL7），超出 PL-8 字面範圍並主動標示。**lead 裁定保留**——專案 SOP（`CLAUDE.md`）本來就要求新測試必須有矩陣條目，這是補齊而非擅自擴權。
- PL-9：`unit_test.md` 測試策略節新增「Artifact provenance」小節——已提交狀態引 HEAD hash，未提交狀態引內容標記。實作者已在自己的 artifact 上實踐（見 §1.1）。

### 1.4 P-2 應用內版本戳記

`lib/perf/perf_log.dart:67-69`：`PerfLog.init()` 輸出一行
`build.stamp|commit=<...>|imageCacheMaxBytes=<...>|kPayloadByteBudget=<...>`。

- commit 來源：`const kHalcyonBuildCommit = String.fromEnvironment('HALCYON_BUILD_COMMIT', defaultValue: 'unknown')`（`:28`）。
- `imageCacheMaxBytes` 取自 `PaintingBinding.instance.imageCache.maximumSizeBytes` **而非 import 常數**——避免 `perf_log.dart → main.dart → perf_driver.dart → perf_log.dart` 的 import 循環。lead 認為這反而更好：它報告的是**執行期實際生效值**，正是 provenance 想要的東西。`kPayloadByteBudget` 直接 import 自 `services/photo_payload_cache.dart`（無循環）。
- **結構性 no-op 已驗**：`PerfLog.init` 全樹唯一呼叫點是 `lib/perf/perf_driver.dart:64`，而該處僅在 `PerfDriver.active`（即設了 `HALCYON_PERF_DIR`）時執行。出貨路徑不受影響。

> **⚠ P-2 目前只完成一半，別當成已解決**——見 §5.1。

---

## 2. 驗收與證據（lead 親自複驗，非採信回報）

於 tip `99d1c36`，由 lead 自行重跑：

| 項目 | 值 | 來源 |
|---|---|---|
| `flutter analyze` | `No issues found!`，`ANALYZE_RC=0` | `tmp/verify/pl-final-analyze-tip99d1c36.txt` |
| `flutter test -j 1` | `+245: All tests passed!`，`TEST_RC=0`，**245 執行／0 skip** | `tmp/verify/pl-full-suite-after-all-fixes.txt` |
| 執行數對帳 | 243（基線）＋ M6-PL1 ＋ M6-PL7 = 245 ✓ | 預註冊於執行前 |
| 凍結閘門 sha256 | 三值與登錄檔逐字元相同 | lead 於 tip 自行 `shasum -a 256` |
| D4 grep | `grep -c "EncodedPayload\|PixelPayload" lib/services/photo_payload_cache.dart` == **0** | lead 自跑 |
| AD-018 | `kExpensiveStartupRadius`(1) `:12`、`kTierTwoRadius`(2) `:32` 仍分列 | lead 自跑 |
| 變異殘留 | `grep -rn "MUTATION-MARKER" lib/` 無命中 | lead 自跑 |

**開輪基線（動任何碼之前先驗）**：worktree 於 `2a15d74` 重現登錄基線 **243 執行／0 skip／analyze 0 issues**，artifact `tmp/verify/03-baseline-suite.txt`（預註冊寫在結果之上、自記 HEAD）。
**樣本閘門確實執行**（非 skip 偽裝成 pass）：`TC-089 real preview-bearing DNG content probe…` 與 `photo_source_test: sample directory has both required fixtures` 皆按名出現。lead 另複驗 artifact 中所有 `skip` 字樣——僅兩處，均為**測試名稱裡的英文字 "skips"**，非 skip 標記。

---

## 3. M6 為什麼停泊（下一輪從這裡開始讀，不要從設計權威 §7 開始）

**裁定：使用者 2026-08-24 選擇 Opt-3，M6 本輪停泊，零改動零 commit。** 契約 AC8 曾一度被修訂為 Option B，隨後因前提被證偽而由使用者**撤回**。

### 3.1 契約的前提是錯的

設計權威 §7 的 delete list 假設：M3 會整檔刪掉 `image_preload_controller.dart`，之後 Dart 端就不再需要 `NativeImageNeedsRawDecode`。**M3 實際交付的是相反的東西**——`memory.md:92`（AD-010 的 2026-08-22 修訂）明寫 Dart 端現在會**構造**這個 variant，且「三個 variant 的凍結不變」。D5 因此編碼了一個已被取代的計畫。契約沿用它而未重新查證，round 1 沒有理由注意到。

### 3.2 兩個獨立的阻斷，疊加

**阻斷一（編譯期）**：三個 hash 凍結測試檔在 **12 個構造點**直接建構該 variant——
`test/dng_nav_probe_m3_test.dart`（`59b1f3c7…`）:118, :211, :290, :334；
`test/image_preload_controller_m3_amend3_test.dart`（`fcdd564e…`）:46, :85；
`scripts/tmp/dng_nav_probe_test.dart`（`05565d33…`）:106, :146, :203, :242, :313, :346（另 :6 註解）。
三者皆 `import 'package:halcyon_flutter/services/native_thumbnail_service.dart'`。

> **關鍵論證（實作者提出，比「就是不行」有用得多）**：`package:` URI **只解析到 `lib/` 之內**。因此任何「能讓凍結檔繼續編譯」的定義，必然被 AC8 的 `lib/` grep 數到。符號存在 ⇒ AC8 ≠ 0；符號不存在 ⇒ 三個不可修改的檔案編譯失敗 ⇒ AC11 不可達。**兩者互斥，不是不方便而已。**
>
> **`PhotoSource.probe()` 的先例不適用**：`probe()` 能活下來是因為**沒有任何閘門禁止它的名字**；AC8 則是直接禁止該識別字出現在 `lib/`。兩種閘門性質不同。
>
> 存在一個字面上的漏洞——把類別放進 `lib/` 之外的 Dart `part` 檔，grep 歸零而類別照樣出貨。**實作者主動記錄並明確反對**：滿足字面、反轉意圖，且會誤導下一個 session。此處保留是為了讓下一輪知道它被考慮過並被否決，不是為了讓人去用。

**阻斷二（設計）**：即使授權修改凍結檔，該 variant 仍承載**活的** cost／orientation 語義（`photo_source.dart:126` 是通往 RAW decoder、`deferred: true` 昂貴階與 step-3b 的唯一分支；`:187-196` 的 `loadExpensive` 存在的唯一理由就是消費它帶出的 orientation，即不變式 I6）。刪除它等於重新設計 `photo_source.dart` 的 cost seam——**跨檔案所有權的重設計，不是一次刪除**。

**所以：授權修改凍結檔是必要但不充分條件。** 這是下一輪最容易誤讀的一句話。

### 3.3 一個被提出又被雙方各自撤回的錯誤警報（記錄以防重演）

lead 曾主張：刪掉 macOS 的 NO_EMBEDDED_PREVIEW 發射會讓無預覽 DNG 被靜默重分類為 cheap，造成九路併發 CIRAWFilter 解碼（D2 違規）。**該主張是錯的，lead 與實作者各自獨立推翻了它。**

真相：**cost 分級根本不來自 native 訊號。** `PhotoSource.probeSource`（`photo_source.dart:255-286`）以純 Dart 的 TIFF/IFD walk（`DngPreviewExtractor.probeContent`）決定階級，`content.largestLongEdge < longEdge` 時回 `SourceCost.expensive`（`:280-283`），且早已是生產路徑（`prefetch_scheduler.dart:105`）。`:252-254` 的註解直說這個 cost half **取代**了 M3 之前那個「14 次錯 13 次」的副檔名判斷。`probeSource` 同時回傳 `exifOrientation`（`:284`），正是 I6 在保存的那個值。實作者另補：`image_preload_controller.dart:~601` 對每一項在每個距離都先跑 Dart content probe，而 `prefetch_scheduler.dart:74-77` 的 `observe()` 是 `putIfAbsent`，所以 probe 是階級的**第一個寫入者**，昂貴閘仍擋住 ±1 之外的工作。

**真正的殘差（採用實作者的版本，比 lead 的準確）**：一個 probe 找不到 IFD0 orientation（或檔案本身不可量測）的昂貴項，會拿到 CIRAWFilter bytes 而非該 variant，因而**繞過 FFI decoder**（`main.dart:38`）走「慢但有圖」的路徑——**降級，絕不空白**。附帶好處：現行生產對這種檔案要花**兩趟** round trip（先 variant，再以 `allowRawDecodeSignal:false` 重問一次），移除發射會變成**一趟**。

> **教訓**：兩個人各自先喊了同一個錯誤警報，又各自靠讀碼推翻它。能收斂是因為兩邊都把「我上次說錯了」往上報，而不是安靜地讓對的結論蓋掉錯的過程。**否定結果先驗儀器、也先驗自己。**

### 3.4 `DngPreviewExtractor.swift` 不能刪——已用實測數字回答，不再是懸而未決的問題

本輪原本只把這列為「動手前要先查清楚」的風險。實作者查了，**答案是不能刪，而且有數字**。

`macos/Runner/AppDelegate.swift:373` 呼叫 `extractFullSizeEmbeddedJpeg(url:)`，這是 **macOS 便宜 DNG 的內嵌預覽直通路徑**，服務 13 個便宜正典樣本的每一次 DNG 預覽請求。**它不是任務書假設的不可達檔案。**
刪掉該檔後，便宜 DNG 的預覽只剩一條路：`AppDelegate.swift:417` `CGImageSourceCreateWithURL` → `:410-437` isRaw 分支（`CGImageSourceCreateThumbnailAtIndex`，`FromImageIfAbsent:false`，maxPixelSize 2800）→ `:484-486` `NSBitmapImageRep` 以 q0.8 重編碼 JPEG。
**Dart 孿生救不了**：`photo_source.dart:317` `fallbackAfterNativeFailure` 以 `NativeImageFailure` 為前提，而此處 native 會**成功**，所以它永遠不會執行。

**實測（headless Swift benchmark，無 UI、無 RSS；預測與判讀規則寫在數字存在之前、同檔在上；`COMPILE_RC=0`／`RUN_RC=0`；三個便宜 `2026-*` 正典樣本，best-of-3）**
artifact：`tmp/verify/20260823T173937Z-risk1-cheap-dng-bench.txt`；原始碼：`scripts/tmp/bench_dng_passthrough.swift`（對**出貨版** extractor 編譯）

| 樣本 | A：現行直通 | B：刪除後僅存路徑 |
|---|---|---|
| `2026-02-15-20-57-15.dng` | 0.7 ms／800,935 B／6000x4000 | 112.3 ms／373,130 B／2800x1867 |
| `2026-02-15-21-53-33.dng` | 1.2 ms／1,780,370 B／6000x4000 | 129.7 ms／769,699 B／2800x1867 |
| `2026-08-07-17-52-54.dng` | 1.2 ms／2,030,586 B／6000x4000 | 219.3 ms／484,759 B／1867x2800 |

**每張預覽慢 94–183 倍，且解析度從完整 6000x4000 內嵌 JPEG 掉到 2800px q0.8 重編碼**——發生在使用者親手走的那 13 個便宜樣本上，發生在契約自己稱為效能地板的路徑上。實作者**預註冊**的判讀規則（>2 倍，或尺寸縮小 ⇒ 不得夾在 cleanup commit 裡出貨）兩條同時觸發。

> **這是使用者決策，不是清理。** 未來 re-contract 的選項：(a) 正式豁免該刪除（保留 Swift 檔）；(b) 先把 DNG 的擷取搬到 Dart，讓孿生真的服務便宜路徑——這是 `photo_source.dart` seam 的真實設計改動；(c) 接受退步（僅使用者可決定，實作者與 lead 均不建議）。
>
> **方法論值得照抄**：這是本輪唯一一個「agent 可以合法量測」的效能問題——純 headless、不碰 UI、不掃 RSS，因此不違反使用者對量測的所有權裁定。想量效能又受該裁定限制時，先問「能不能把它化約成一個 headless 命令基準」。

### 3.5 已停泊工作的去向（實際經過，非我原本下的令）

**最終狀態：工作樹零修改，M6 零 commit，tip `d07a388`（本交接文件）直接疊在 `99d1c36` 之上，pl-impl 的五個 commit 完好。**

經過需要照實記錄，因為它是本輪第二次分散式狀態事故：
- lead 的撤回令依據一份**過時的 `git status` 快照**，只點名三個檔案（`AppDelegate.swift`、`DngPreviewExtractor.swift`、`memory.md`）。實際上樹上有**五個**修改檔——Option B 的 Dart 半邊（`lib/services/native_thumbnail_service.dart`、`test/native_thumbnail_service_test.dart`）也在其中。
- **實作者沒有把破壞性命令擴及未被點名的檔案**，而是照令還原三個、回報清單不符、等待授權後才還原另外兩個。**這是正確處置**：擅自擴大還原範圍與擅自不還原，都是把單方判斷加在破壞性操作上。
- 兩份 patch 皆在還原前存檔：`tmp/verify/20260823T174141Z-m6-parked-macos-half.patch`（319 行，實際涵蓋全部五檔——實作者擴大了**捕捉**範圍而非還原範圍）與 `tmp/verify/20260823T174359Z-m6-parked-dart-half.patch`（186 行）。

> **後者的開頭有 13 行 `#` 註解警語**，載明這是**已撤回方案**的產物：在 Opt-3 之下發射**回來了**、variant **確實會被產生**，patch 內所有相反的宣稱在寫下當時即為假。同時分離出「無論樹如何都成立」的部分——`package:` URI 只解析到 `lib/` 之內，故 12 個凍結構造點迫使該符號必須留在 `lib/`。`git apply` 會略過前導註解，patch 仍可套用。
>
> **為什麼特地留這份 patch**：其中 `NativeImageNeedsRawDecode` 的 deprecation 註解是本輪品質最高的產物——它對零脈絡讀者解釋了「這段看似死碼為何不能刪」，點名 12 個凍結構造點與 `package:` 機制，正面攔截「順手清掉死碼」的反射。**未來 M6 re-contract 應從 patch 復原它並近乎逐字重用，不要重寫。** 但復原時必須先改掉那幾句關於樹的現況宣稱。

### 3.6 實作者拒絕寫入假紀錄（兩次）

- **`memory.md`**：拒絕寫「3 variants → 2」，理由是那不是樹上的事實。
- **同一個陷阱換了地點**：Option B 的 deprecation 註解裡確實寫了「發射已消失、只產生兩個 variant」。在 Option B 成立時那是真的；Opt-3 一撤回就變假。**lead 要求把警語寫進 patch 頂端**，正是因為源碼註解和 memory.md 一樣會被未來 session 當成現況描述來讀。

**通則**：紀錄「計畫」與紀錄「現況」必須在文字上可區分。一份描述已撤回計畫的產物，若沒有自述它是計畫，下一個讀者就會把它讀成現況。

---

## 4. 下一輪依賴的介面契約（未變，仍然有效）

1. **側欄與預覽各有自己的 permanent-miss 集合，由構造而不相交。** 預覽 `_permanentMisses`、側欄 `_thumbPermanentMisses`，兩者皆以**裸 id** 讀寫，`reset()` 兩個都清。**禁止用前綴／哨符塞回同一個 Set**——id 是使用者控制的檔名，任何 in-band 前綴只是把碰撞搬家。本輪 PL-1 只在側欄自己的集合外圍加了 catch/finally，未改變此形態。
2. **`_previewGeneration` 與 `_thumbBatchGeneration` 是兩個計數器，不可合併。**
3. **AD-018／AD-019 紅線未變**：`kTierTwoRadius`(2) 與 `kExpensiveStartupRadius`(1) 不得合併；768 MiB 與 224 MiB 出自相反樣本組，不得互驗。
4. **D4 型別盲**：`photo_payload_cache.dart` 的 `EncodedPayload|PixelPayload` grep 維持 0。
5. **`PhotoSource.probe()`（`photo_source.dart:301`）零呼叫點投影原樣保留。**
6. **macOS `isRaw` 分支保留**（`AppDelegate.swift:313` 宣告、`:410` 分支、`:433` CIRAWFilter）——`.arw/.cr2/.nef/.orf/.rw2` 唯一的讀取者，解封需先解決 [U-2]。

---

## 5. 已知限制（明確列出，不藏）

### 5.1 P-2 只完成一半——別當成 provenance 問題已解決

戳記機制在檔，但**沒有任何東西會自動填入 commit**：
- `HALCYON_BUILD_COMMIT` 需要手動 `--dart-define=HALCYON_BUILD_COMMIT=$(git rev-parse HEAD)`；沒帶就是字串 `unknown`。
- `scripts/build_apps.py` **未接線**（不在該實作者的檔案所有權內，實作者主動標示為他人後續）。

**後果要照字面讀**：P-2 的動機是「使用者接手 UI 量測後，『這顆 binary 是哪份程式碼』從 agent 的建置事件紀錄退化成使用者的記憶」，而在**便宜樣本組**上過期 binary 產生**偏低**數字、讀起來像好消息、沒有規則會觸發。**預設工作流（`flutter build macos --release` 不帶 define）現在戳的是 `unknown`**，也就是這層保護在預設路徑上仍然是空的。誠實地說：它把問題從「無法得知」變成「會明確告訴你不知道」，這是進步但不是解決。
**建議下一輪**：把 define 接進 `scripts/build_apps.py`（單點、小改動），並讓 `unknown` 在量測解析腳本裡直接使 run 作廢。

### 5.2 AC4／AC11 的量測腿仍然沒有 agent 側證據

契約經使用者 2026-08-24 修訂：UI 切換延遲與記憶體／RSS 量測**由使用者親自執行**，agent 不得執行 UI 驅動量測（`perf_driver` UI 切換、RSS 掃描），僅允許純 headless 解碼命令基準。
**因此至今不存在任何 agent 驗證過的「M4／本輪不使 JPEG 切換退步」的主張。** 本輪 task #7 動到的唯一生產檔是 `image_preload_controller.dart`，改動是在既有 `await` 外圍包 try/catch/finally，**成功路徑上沒有新分支、沒有新 per-navigation 工作**——但這是**推理，不是量測**，不要當量測引用。

### 5.3 M6 的既有測試代價（未來刪除時的決策，不是意外）

未來若真的移除該 variant，以下測試**不是機械改一改就好**，必須當成決策明確處置：
- `test/native_thumbnail_service_test.dart`（:17, :39, :51, :62, :71, :84）——這些測試**本身就是** variant／NO_EMBEDDED_PREVIEW 的映射，其中四個是**整條刪除**，不是編輯。
- `test/image_preload_controller_test.dart`（:752 mock 真實 channel error，另 11 個 fake loader）與 `test/image_preload_window_test.dart`（:239 TC-098「AC6 killer」、:297）——該 variant 是這些測試**唯一能讓一個項目透過 loader seam 表現為 expensive 的手段**，刪掉它移除的是它們**表達該情境的能力**，不只是一個引用。
- `test/image_preload_scheduling_m4_test.dart`（:239, :281）同理。

### 5.4 其他

- `CLAUDE.md` **在本 worktree 不存在**（主 repo 中為 untracked）。實作者選擇標示而非自行建立，正確。
- 一顆 macOS release build 曾被 detached 啟動後放棄，**其 exit code 從未被觀察**，本檔不對它做任何宣稱。（未觀察的 exit code 不是通過的 exit code。）

---

## 6. 基線升格（下一輪據此，不重跑相同基線）

**新錨點：`m6-cleanup` @ `99d1c36`**（合併後改為 `main` 的合併 commit）。

| 項目 | 值 | artifact |
|---|---|---|
| `flutter analyze` | 0 issues，`ANALYZE_RC=0` | `tmp/verify/pl-final-analyze-tip99d1c36.txt` |
| `flutter test -j 1` | `TEST_RC=0`，**EXECUTED=245 / SKIPPED=0** | `tmp/verify/pl-full-suite-after-all-fixes.txt` |
| 凍結閘門 sha256 | 三值不變（同登錄檔） | lead 於 tip 自行重跑 |
| JPEG 切換延遲 | **無 after 數字**——使用者自量後才可升格 | 基線見登錄檔 |
| 峰值 RSS | **本輪未量**（AC4／AC11 修訂連帶） | — |

> 升格條件：合併回 `main` 且通過合併後全套重跑之後，由指揮官簽收寫入 `baseline-registry.md`。**分支內全綠證明不了跨分支組合**（2026-08-16 教訓），合併後驗證是獨立必要閘。

---

## 7. Parking lot（本輪未做，逐項附「若永不落地，終態是否仍可達」）

| # | 項目 | 若永不落地？ |
|---|---|---|
| PL-6 | 暫時性縮圖失敗被記成「永久到重載為止」——相對 `b3b0ddd` 是行為損失。**使用者已裁定不做（出帳）** | 終態可達 |
| P-2b | `scripts/build_apps.py` 未接 `HALCYON_BUILD_COMMIT` define（見 §5.1） | 終態可達，但**使用者自量的 provenance 保護在預設路徑上仍是空的**——建議優先 |
| M6 | 整項停泊，待與 M5 一起重新立約（使用者指示：同一子系統，一次決策）。**重新立約前必先處置 §3.4 的 94–183 倍退步**——它是 M6 原始 delete list 的一部分 | **終態不可達**——M6 是契約終態的一半。這不是緩議項，是**沒有排程的阻斷**，必須重新排程 |
| P-1／P-3／P-4 | 使用者已裁定不做（出帳） | 見設計權威 |
| [U-2]/[U-4]/[U-6]/[U-7] | 設計權威 §9 未決事項，本輪未觸及 | 見該表 |

> 依 2026-08-17 制度面教訓：**對每個 out-of-scope 項問「若它永遠不落地，終態還可達嗎」，若否就不是 out-of-scope。** M6 的答案是「不可達」，所以它在上表被標為需重新排程的阻斷，而不是安靜地留在緩議清單裡。

---

## 8. 給下一輪的注意事項

1. **M6 re-contract 從 §3 開始，不要從設計權威 §7 開始。** §7 的 delete list 前提已被證偽（§3.1）。使用者已指示 M6 的 cost-seam 重設計要**與 M5 dual-window 設計一起重新立約**——同一個子系統，一次決策。
2. **合併後在 `main` 上重跑全套是獨立閘門。** 本輪 tip `99d1c36` 的 245／0-skip 不能替代它。
3. **task #7 的五個 commit 彼此獨立**，若合併時需要拆分或部分回退，`5361077`（唯一的生產程式碼改動）與其餘四個（測試／文件／perf log）可分開處理。
4. **本輪最有價值的動作是拒絕動手。** 實作者收到任務後先做 read-only audit、確認前提為假、零改動回報 BLOCKED；被原封不動重派一次後**仍然拒絕**執行。若他當時「照做」，交付出來的會是一個編譯不過（或靠 `part` 檔漏洞繞過字面驗收）的 commit，而且 memory.md 裡會多一條假紀錄。**驗收條件寫得再機械，也擋不住前提本身是錯的——收件時要審的是前提，不只是 diff。**
5. **本輪發生兩次「指令與狀態在途交錯」事故，兩次都靠回報而非默默行動而收斂。**
   (a) 使用者裁定 Option B 後又改判 Opt-3，而 lead 的 Option B 派工已經發出；(b) lead 的撤回令依據過時的 `git status`，漏點名兩個檔案。
   **可轉移的做法**：①破壞性操作的目標清單要在**動手當下**重新讀取，不可用記憶或稍早的快照；②收到「範圍不符」的回報時，正確反應是補授權，不是要對方自行判斷擴大範圍；③下了指令不等於對方收到——收到回報時先確認對方是**基於哪一版指令**行動。這與 round 1 的 n=36 事件同類，已是第二次，應視為常態而非意外。
6. **凡「刪除死碼」型任務，動手前先證明它真的死了**：grep 生產呼叫點、grep 測試構造點、grep 其他平台 runner。本輪三項假設（variant 是死碼、Swift extractor 不可達、Dart 孿生已接管）**全部為假**，而三項都是任務書當成既成事實陳述的。
