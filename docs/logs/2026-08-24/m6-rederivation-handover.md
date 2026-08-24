# M6 重推導交接（自 M5 後的現行樹）

> **建立**：2026-08-24，m6-clarify-opus（m5-team，TaskList #7）
> **查證對象**：主樹 `/Users/jhangyu/project/Halcyon`，`main` 程式碼 @ `c2ae385`（docs tip `518efe9`）
> **性質**：**釐清與提案，未凍結任何契約，零程式改動**。所有行號皆為**現行樹**實際開檔核對值，與較舊文件不一致處已標明。
> **本檔不做**：實作、benchmark 重跑（引用既有預註冊 artifact）、UI/RSS 量測。

---

## 0. 六十秒速讀

- M6 原 delete list 的三個前提，在現行樹上**逐項複驗仍為假**：variant 是活邏輯、凍結檔構造點互斥、Swift 抽取器是承重路徑（94–183 倍實測）。M5 沒有改變其中任何一項。
- **M5 讓情況更緊，不是更鬆**：`test/image_preload_dual_window_m5_test.dart` 新增 **6 個** `NativeImageNeedsRawDecode` 構造點，全樹構造點自 round 2 的 21 個增為 **27 個**（凍結檔內仍是 12 個，未變）。
- **發現一項與上級 framing 相反的事實**：`memory.md:92`（AD-010 的 2026-08-22 修訂）宣稱「改由 Dart 端自行建構此 variant，orientation 來自 `DngPreviewExtractor.readOrientationFromFile`」——**該符號在現行樹不存在，該 Dart 建構點也不存在**。現行樹 `lib/` 內唯一構造點是 `native_thumbnail_service.dart:127`，來源是 macOS channel error。詳見 §1.5，這是本次最重要的新發現。
- 上述事實的後果：**刪掉 macOS 的 `NO_EMBEDDED_PREVIEW` 發射，等於讓 `DngFullDecoder`（FFI RAW 解碼）在所有平台成為死碼**——包括 M5 剛建立的 RAW 全解析度 tier-2。這比 round 2 記載的殘差嚴重一級。
- 建議：**採 Opt-B（事實對齊版 M6）**，正式撤銷刪除案、只做文件與註解對齊，零 `lib/` 行為改動；把「Dart 抽取器升主通道」拆成獨立的效能契約，不掛在 M6 清理名下。

---

## 0.1 接手啟動序列（下一團隊照此開工）

1. Read 本檔全文（180+ 行）——§1.5 的文件失實發現與 §3 選項空間是決策核心。
2. Read `docs/logs/2026-08-24/m5-round-handoff.md` §5–6——M5 剛落地什麼、與 M6 的界線。
3. Run `git -C /Users/jhangyu/project/Halcyon log --oneline -3`——預期 tip 為 `451e9c4` 或其後、含 `c2ae385` M5 合併。
4. Run 本檔 §末「驗收命令」區塊——確認前提查證的機械事實仍成立（構造點數、凍結 sha、失實符號零命中）。
5. **開工前提：§4 的裁決 1（M6 終態是否重新定義）必須先由使用者拍板**——本檔為 [D] 待決狀態，不構成任何選項的執行授權。

## 0.2 版本與工作樹狀態（2026-08-24 交付當下）

- Branch `main`；程式碼錨點 `c2ae385`（M5 合併）；docs tip `451e9c4`（本檔 commit）。
- Working tree：乾淨（untracked 僅 gitignored scratch：`scripts/tmp/`、`local_data`、`.claude/` 等，非本輪產物）。
- 無在途 worktree／分支／team／背景程序：m5-team 已按 shutdown protocol 四步關閉（drain `live_panes: []`）；halcyon-m5／halcyon-m6 worktree 與分支皆已刪除。
- 參考 patch（勿直接套用）：`scripts/tmp/20260823T174141Z-m6-parked-macos-half.patch`、`…-dart-half.patch`（gitignored，主樹持有）。

## 1. 前提查證（逐項對現行樹）

### 1.1 第三個 variant 還活著嗎？——是，且比 round 2 更活

生產鏈完整且單一：

| 環節 | 現行樹位置 |
|---|---|
| 發射（macOS 原生） | `macos/Runner/AppDelegate.swift:396` `FlutterError(code: "NO_EMBEDDED_PREVIEW", …)`，條件在 `:391`（`extracted == nil && allowRawDecodeSignal`），orientation 於 `:393` 由 `readDngOrientation(url:)` 取得並 clamp |
| 常數 | `lib/services/native_thumbnail_service.dart:89` `kNoEmbeddedPreviewCode = 'NO_EMBEDDED_PREVIEW'` |
| 構造（Dart，唯一） | `lib/services/native_thumbnail_service.dart:126-129`（`PlatformException` catch 內比對 code） |
| 消費（Dart，唯一） | `lib/services/photo_source.dart:136` `case NativeImageNeedsRawDecode(:final exifOrientation):` |

> **與 briefing 的行號差異**：briefing 稱消費點在 `photo_source.dart:126`，現行樹是 **`:136`**（M5 的 `fullRes` 擴欄使檔案位移）。結論不變。

該 case 分支是通往三條路的唯一入口：`decoder == null` → 舊 CIRAWFilter bytes（`:139-150`）；`!allowExpensive` → `deferred: true` 並把 orientation 帶出（`:151-160`，即不變式 I6）；否則真解碼（`:161-186`）。**M5 的改動就落在這條分支裡**：`:171-174` 的 `_fullResFrom(decoded, …)` 與 `:180` 的 `fullRes: fullRes` 是 M5 單次解碼雙輸出的 piggyback 點（`_fullResFrom` 定義於 `:263-274`）。`loadExpensive`（`:211`）同理，其存在理由仍是消費該 variant 帶出的 orientation。

**結論**：不但仍是活邏輯，M5 的新功能（RAW 全解析度 tier-2）就長在這條分支上。

### 1.2 現在有幾個構造點？在哪些檔？哪些是凍結檔？

`grep -c "NativeImageNeedsRawDecode(" `（現行樹，`test/` ＋ `scripts/tmp/*.dart`）：

| 檔案 | 構造點數 | 凍結？ |
|---|---|---|
| `test/dng_nav_probe_m3_test.dart` | 4（:118, :211, :290, :334） | **凍結** `59b1f3c7…` |
| `test/image_preload_controller_m3_amend3_test.dart` | 2（:46, :85） | **凍結** `fcdd564e…` |
| `scripts/tmp/dng_nav_probe_test.dart` | 6（:106, :146, :203, :242, :313, :346） | **凍結** `05565d33…`（gitignored，主樹持正本） |
| `test/image_preload_controller_test.dart` | 11 | 否 |
| `test/image_preload_dual_window_m5_test.dart` | **6（M5 新增）** | 否 |
| `test/image_preload_scheduling_m4_test.dart` | 2（:402, :444） | 否 |
| `test/image_preload_window_test.dart` | 2（:239 TC-098「AC6 killer」、:297） | 否 |
| 合計 | **27**（凍結內 12／凍結外 15） | — |

`test/native_thumbnail_service_test.dart` 不直接構造，但以型別斷言（`:24-25, :56-57, :67-68`）與 `PlatformException(code: 'NO_EMBEDDED_PREVIEW')`（`:19, :51, :62`）**映射該機制本身**——刪除 variant 時這幾個測試是整條刪除，不是編輯。

**凍結三檔 sha256 於本檔撰寫當下實跑複驗，與 `baseline-registry.md:49-51` 登錄值逐字元相同**（`59b1f3c711…`／`fcdd564ea1…`／`05565d3347…`），即 M5 未動凍結面。

**round 2 的互斥論證在現行樹依然成立且未被稀釋**：`package:` URI 只解析到 `lib/` 之內，凍結三檔皆 `import 'package:halcyon_flutter/services/native_thumbnail_service.dart'`；符號存在 ⇒ 原 AC8（`lib/` grep == 0）不可達，符號不存在 ⇒ 三個不可修改的檔案編譯失敗。M5 只是把凍結外的代價從 15 個構造點推高（新增 6 個且其中含 M5 的核心交付測試）。

### 1.3 Swift 抽取器還是承重的便宜 DNG 路徑嗎？——是，未變

`macos/Runner/AppDelegate.swift:373` 於 `isPreviewRequest && isDng` 分支（`:370`）呼叫 `extractFullSizeEmbeddedJpeg(url:)`（定義 `macos/Runner/DngPreviewExtractor.swift:49`），命中即在 `:405-412` 直通回原始內嵌 JPEG 位元組。刪除後唯一剩餘路徑仍是 `:426` `if isRaw` → `CGImageSourceCreateThumbnailAtIndex`（`FromImageIfAbsent: false`、maxPixelSize = targetSize=2800）→ `:484` 起的 `NSBitmapImageRep` 重編碼。

**Dart 孿生今日仍救不了**：`photo_source.dart:364-367` 的 `fallbackAfterNativeFailure` 只在 `case NativeImageFailure()`（`:190`）被呼叫，而便宜 DNG 的 native 是**成功**的，該分支永不執行。（M5 設計 §2.7 引用的 `:317-320` 已因 M5 位移為 `:364-367`。）

實測數字沿用 round 2 的**預註冊** headless benchmark（`scripts/tmp/round2-verify/20260823T173937Z-risk1-cheap-dng-bench.txt`，原始碼 `scripts/tmp/bench_dng_passthrough.swift`，`COMPILE_RC=0`／`RUN_RC=0`，三個便宜正典樣本 best-of-3）：**0.7–1.2 ms／6000x4000 → 112.3–219.3 ms／2800px q0.8**，即**慢 94–183 倍且解析度下降**。本輪未重跑（紅線），該 artifact 所量的 Swift 程式碼在現行樹未被修改，故仍有效。

### 1.4 M5 有沒有改變上述任何一項？

沒有。M5 的改動集中在 `photo_source.dart` 的 `fullRes` 擴欄（`:104`、`:180`、`:240`、`_fullResFrom :263-274`）、新檔 `lib/services/raw_full_res_image.dart`、controller 的 tier-2 升級分流與兩個 debug accessor。**便宜 DNG 的位元組來源通道一行未動**，符合 M5 設計 §2.7 的唯一依賴聲明（「便宜 DNG 持續以 `EncodedPayload` 到達」）。

### 1.5 ⚠ 與上級 framing／既有文件相反的事實（本輪最重要的新發現）

`memory.md:92`（AD-010 的 2026-08-22 修訂）寫：

> 「改由 Dart 端在『原生失敗 ＋ `.dng` ＋ 內嵌預覽抽取落空』時自行建構此 variant，orientation 來自 `DngPreviewExtractor.readOrientationFromFile`（`dng_preview_extractor.dart:41`）」

**現行樹不支持這段描述**：
- `grep -rn "readOrientationFromFile" lib/` **零命中**。`lib/services/dng_preview_extractor.dart` 只有 `readOrientation`（`:109`）與 `readDngOrientation`（`:137`），且 `lib/` 內**沒有任何呼叫點**（`DngPreviewExtractor.` 在 `lib/` 只被呼叫兩次：`photo_source.dart:319` `probeContent`、`:366` `extractFullSizeEmbeddedJpegFromFile`）。
- `photo_source.dart:190-201` 的 `NativeImageFailure` 分支**不建構該 variant**，只回 `EncodedPayload` 或 null。
- 因此 `lib/` 內該 variant 的**唯一**構造點就是 `native_thumbnail_service.dart:127`，來源只有 macOS channel error。

**後果（比 round 2 §3.3 記載的殘差嚴重一級）**：Windows 原生刻意回 `RAW_UNSUPPORTED`（`windows/runner/halcyon_image.cpp:538`，其 `:533-536` 註解自述「`NO_EMBEDDED_PREVIEW` 才會讓 Dart 建構 `NativeImageNeedsRawDecode`」）。所以今日 macOS 是該 variant 的**唯一**生產者。若刪除 macOS 發射而不同時補上 AD-010 所設想的 Dart 建構點，則：
1. `DngFullDecoder` FFI 解碼路徑（`main.dart:38` 注入的 `halcyonDngFullDecoder`）在**所有平台**變成死碼；
2. **M5 剛交付的 RAW 全解析度 tier-2 一併失效**——它只在該分支的 `fullRes` 輸出上產生（`photo_source.dart:171-180`）；
3. 無內嵌預覽的 DNG 退化為 CIRAWFilter 2800px 路徑（round 2 §3.3 稱之為「降級但不空白」——該判斷仍對，但當時未計入 M5 的損失）。

> round 2 §3.1 曾以 `memory.md:92` 為據論證「M3 交付了與計畫相反的東西」。該結論（前提是錯的、M6 不能照原案執行）**仍然成立**，但其引用的那句 memory.md 描述的是**未落地的計畫**，不是樹上的事實。這正是 round 2 §3.6 自己歸納的通則被違反的一次實例：紀錄「計畫」與紀錄「現況」必須在文字上可區分。**AD-010 的這段修訂需要勘誤，且不論 M6 走哪個選項都需要。**

---

## 2. 現況地圖：macOS 便宜 DNG 的位元組路徑（現行樹）

```
Dart: PhotoSource.load(path)                              photo_source.dart:120
  └─ loader(path, purpose: preview)
       └─ NativeThumbnailService.requestImage(allowRawDecodeSignal: true)
                                                 native_thumbnail_service.dart:108
            └─ MethodChannel 'halcyon/thumbnail' → getFastThumbnail
                                                          AppDelegate.swift:302
                 ├─ purpose == export        → makeExportJpeg（獨立終端分支 :330-345）
                 ├─ preview && jpeg          → 原始檔位元組直通（:358-369）
                 ├─ preview && dng           → extractFullSizeEmbeddedJpeg(url:)  ← 承重
                 │      ├─ 命中 → 內嵌 JPEG 原始位元組直通（:405-412）      DngPreviewExtractor.swift:49
                 │      └─ 落空 && allowRawDecodeSignal
                 │             → FlutterError NO_EMBEDDED_PREVIEW + orientation（:391-402）
                 └─ 其餘 → CGImageSource（isRaw 分支 :426 / CIRAWFilter :433 / ImageIO :470）
                            → NSBitmapImageRep q0.8 重編碼（:484 起）

Dart 側分流：                                             photo_source.dart:131
  NativeImageBytes          → EncodedPayload, cost=cheap（便宜 DNG 與 JPEG 走這裡）
  NativeImageNeedsRawDecode → decoder==null? 舊 bytes ; !allowExpensive? deferred+orientation ;
                              否則 FFI 解碼 → PixelPayload ＋【M5】fullRes 雙輸出（:161-186）
  NativeImageFailure        → fallbackAfterNativeFailure（純 Dart 抽取器，僅 .dng）（:190-201, :364-367）

成本分級（與上面的位元組路徑正交）：
  PhotoSource.probeSource   → DngPreviewExtractor.probeContent（純 Dart TIFF/IFD walk）
                                                          photo_source.dart:302, :319
  → largestLongEdge < longEdge ⇒ expensive，同時回 IFD0 orientation（:326-330）
```

**兩個要點**：(a) 成本分級**不**來自 native 訊號（round 2 §3.3 的更正結論，現行樹複驗仍對：`probeSource` 是純 Dart content probe）；(b) 純 Dart 抽取器**已存在且成熟**（`dng_preview_extractor.dart:47` 起，含候選挑選 `_gatherCandidates :321`／`_select :436`、orientation 注入 `_injectExifOrientation :473`、分頁讀取 `_pageSize=8192`／`_maxPages=48` `:627-629`），但目前只服務 fallback 與 probe，**未服務便宜 DNG 主通道**。

---

## 3. 選項空間（三個候選，未凍結）

### Opt-A：正式關閉 M6，判定為「已被證偽」，零改動

- **交付物**：一份使用者裁決紀錄（可直接是本檔 §4 的批註），`memory.md` 不動。
- **機械驗收草案**：無程式改動 ⇒ `git diff --stat` 為空；全套仍 252/0 skip。
- **風險**：`memory.md:92` 的失實描述**留在檔上**，下一個零脈絡 session 會再次據此推導出同一個錯誤 delete list（本輪已經是第二次有人被它誤導）。**這是 Opt-A 的主要缺陷。**
- **out-of-scope**：全部。

### Opt-B：事實對齊版 M6（建議）——只改文件與註解，`lib/` 零行為改動

- **交付物**：
  1. `memory.md` AD-010 修訂勘誤：把 2026-08-22 那段標為「當時採納但**未落地**的計畫」，補一行現況（唯一構造點 `native_thumbnail_service.dart:127`、來源 macOS 發射、Windows 回 `RAW_UNSUPPORTED`）。
  2. 新增一則 AD（或 G-NNN gotcha）記錄本檔 §1.3／§1.5：Swift 抽取器是承重路徑（附 94–183 倍 artifact 路徑）、刪除發射會使 FFI 解碼與 M5 全解析度 tier-2 一併死亡。
  3. `native_thumbnail_service.dart` 於 `NativeImageNeedsRawDecode`（`:61`）加一段**反射攔截註解**：說明它看似死碼但不可刪，點名 27 個構造點中的 12 個位於凍結檔、`package:` 只解析到 `lib/`。**素材可自 `scripts/tmp/20260823T174359Z-m6-parked-dart-half.patch` 復原**（round 2 評為該輪品質最高產物），但**必須先剝除其中所有「發射已消失／只剩兩個 variant」的宣稱**——在 Opt-3 撤回後那些句子即為假。
  4. 把 M5 設計 §2.7 的界線正式升格為 memory.md 條目（現在只活在一份任務設計檔裡）。
- **機械驗收草案**：`grep -c "readOrientationFromFile" memory.md` 的殘留描述已改寫（改為斷言勘誤標記字串存在）；`grep -rn "NativeImageNeedsRawDecode" lib/services/native_thumbnail_service.dart` 註解區含「凍結」與構造點數字；`git diff --name-only` 只含 `memory.md`＋`native_thumbnail_service.dart`（＋文件）；`flutter analyze` 0 issues；`flutter test -j 1` 252 執行／0 skip（註解改動不得改變執行數）。
- **風險**：低。唯一風險是註解本身再次寫成「計畫」被誤讀為「現況」——以 §1.5 的通則自我約束（凡宣稱皆附 file:line）。
- **out-of-scope**：任何 Swift 檔刪除、任何 `lib/` 行為改動、凍結檔改動、Windows runner 改動。

### Opt-C：完整版重接線——Dart 抽取器升為便宜 DNG 主通道，之後才談刪 Swift

- **交付物**：
  1. `photo_source.load` 在 `.dng` 且 preview 時先走純 Dart `extractFullSizeEmbeddedJpegFromFile`（或讓 native 端改呼叫），使 Dart 孿生真正承載便宜路徑；
  2. Dart 端在「抽取落空」時**自行建構** `NativeImageNeedsRawDecode`（orientation 取自 `DngPreviewExtractor.readOrientation`）——即 AD-010 當初設想但從未落地的那件事；**沒有這一步，FFI 解碼與 M5 全解析度 tier-2 會一起死**（§1.5）；
  3. 上述成立後，macOS `NO_EMBEDDED_PREVIEW` 發射與 `DngPreviewExtractor.swift` 才**可能**可刪。
- **硬約束（必須寫進契約，否則不得開工）**：以 `scripts/tmp/bench_dng_passthrough.swift` 同口徑的 **headless 基準閘**（預註冊判讀規則、artifact 內自捕 `RC=$?`）證明便宜 DNG 位元組取得**不超過現行 2 倍且輸出尺寸不縮小**（round 2 預註冊的兩條判準原樣沿用）。Dart 走的是分頁讀檔＋TIFF walk，未經量測前**不得假設**它能匹配 Swift 的 0.7–1.2 ms。
- **機械驗收草案**：基準閘如上；`flutter analyze` 0；全套 ≥252／0 skip；`grep -c "NO_EMBEDDED_PREVIEW" macos/Runner/AppDelegate.swift` 的目標值由使用者裁定；凍結三 sha 不變（除非使用者解封）。
- **風險**：高。跨 Dart／Swift 兩側的 cost seam 重設計；牽動 M5 剛落地的雙輸出；13 個便宜正典樣本是使用者親手走的路徑，退步立即可感；且**即使做完，第三個 variant 仍然存在**（只是換人建構），原 delete list 的 AC8 依舊不可達。
- **out-of-scope**：刪除 variant 本身、動凍結檔、Windows/Android 通道。

### 「什麼都不做」是不是合法選項？

**是——Opt-A 是合法選項，且 Opt-B 是它的低成本強化版。** 但需與 round-2 交接 §7 的一句話對帳：該表把 M6 標為「終態不可達的阻斷」。**該判斷是針對原契約的終態（variant 收攏＋runner 清理）**；若使用者接受「原終態本身建立在錯誤前提上、應予撤銷」，則 Opt-A/B 之後**不存在未排程阻斷**——因為終態被重新定義了。這個重新定義只有使用者能做，這也是 §4 的第一項待決。

---

## 4. 建議與待使用者裁決清單

**建議：Opt-B。** 理由：三個前提在 M5 後複驗仍為假，且 M5 使凍結外代價更高；Opt-C 的唯一實質收益是刪掉一個 Swift 檔，卻要冒 13 個便宜樣本可感退步的風險，並且**做完之後 variant 依然存在**——付出跨層重設計換不到原契約想要的東西。Opt-A 會把 §1.5 的失實記錄留在原地，等下一個 session 再踩一次。Opt-B 花費最小、消除的是**下次重蹈覆轍的機率**，而那正是 M6 這一輪真正剩下的價值。

**只有使用者能做的裁決：**

1. **【最重大】M6 的終態是否重新定義？** 正式撤銷「刪除 `NativeImageNeedsRawDecode` ＋ `kNoEmbeddedPreviewCode` ＋ macOS 發射 ＋ `DngPreviewExtractor.swift`」這份 delete list，並將 M6 改為文件／註解對齊（Opt-B）？若否，唯一可行路徑是 Opt-C 並接受其風險與成本。
2. **`DngPreviewExtractor.swift` 是否正式豁免刪除**（寫入 memory.md 作為長期決策），或維持「未來仍要刪」？後者等同要求 Opt-C。
3. **AD-010 的 2026-08-22 修訂如何處置**：勘誤標為未落地計畫（建議）／整段刪除／保留原文另加現況註記。此項不論選 A/B/C 都應處理。
4. **凍結三檔是否解封**：只有 Opt-C 的極端版（真要刪 variant）才需要，Opt-A/B 不需要。目前建議維持凍結。
5. **Opt-C 若被選中**：便宜 DNG 的效能閘門判準（建議沿用 round 2 預註冊的「>2 倍或尺寸縮小即不得出貨」），以及誰跑（headless 基準 agent 可跑；UI 切換延遲仍屬使用者自量）。

**已知未確認事項（不確定，明確標出）：**

- 本檔未執行任何測試或建置，僅原始碼與既有 artifact 逐行閱讀。252/0-skip 與凍結 sha 之外的數字皆引用自 M5 交接與 registry，未重跑。
- `scripts/tmp/round2-verify/` 的 benchmark artifact 我核對了檔案存在與 round-2 交接對它的引述，未逐行重讀其全文數字；引用的三組數字取自 round-2 交接 §3.4 表格。
- Windows/Android/iOS 路徑我只確認了 `RAW_UNSUPPORTED` 的存在與註解自述，未追完其完整分支行為。
- `.arw/.cr2/.nef/.orf/.rw2` 走 `isRaw` 分支（`AppDelegate.swift:313` 宣告、`:426` 分支、`:433` CIRAWFilter），本檔的所有選項皆不觸及它；round-2 §4 第 6 條的 [U-2] 依賴未複查。

---

## 5. 待解議題（依賴排序）

| 優先 | 狀態 | 議題 | 解除條件 | 下一動作 |
|---|---|---|---|---|
| P0 | [D] | M6 終態是否重新定義（§4 裁決 1–4） | 使用者拍板選項 A／B／C | 無——等待裁決，不得先行實作 |
| P1 | [ ] | 裁決後依所選選項執行（B：memory.md 勘誤＋註解；C：另立效能契約） | P0 完成 | B 的機械驗收草案在 §3 Opt-B；C 必須先凍結效能閘 |
| P2 | [ ] | AD-010 勘誤（不論選項皆需，§4 裁決 3） | P0 完成（處置方式隨裁決） | 編輯 `memory.md:92` 一帶，計畫與現況分開標示 |

## 6. 驗收命令（只讀，複驗本檔機械事實）

```bash
git -C /Users/jhangyu/project/Halcyon log --oneline -1                     # 451e9c4 或其後
grep -rn "readOrientationFromFile" lib/ | wc -l                            # 0（§1.5 失實符號）
grep -rn "NativeImageNeedsRawDecode(" test/ scripts/tmp/*.dart | wc -l     # 27 構造點（§1.2）
shasum -a 256 test/dng_nav_probe_m3_test.dart test/image_preload_controller_m3_amend3_test.dart scripts/tmp/dng_nav_probe_test.dart
                                                                           # == baseline-registry.md 三值
flutter test -j 1                                                          # All tests passed!，252 執行／0 skip
```

## 7. 參考入口

- 必讀：`docs/logs/2026-08-24/round-2-m6-handoff.md` §3——三前提被推翻的原始證據包。
- 必讀：`docs/logs/2026-08-24/m5-round-handoff.md` §5–6——M5 交付內容與 M6 界線。
- Artifact：`scripts/tmp/round2-verify/20260823T173937Z-risk1-cheap-dng-bench.txt`——94–183 倍退化的預註冊 benchmark（2026-08-23，Swift 受測碼現行樹未變，仍有效）。
- 基線：`docs/logs/2026-08-24/baseline-registry.md`——現行錨點 `c2ae385`、凍結三 sha、禁止重量規則。
