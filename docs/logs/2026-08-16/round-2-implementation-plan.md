# Round 2 — Implementation Plan（接手啟動介面）

> **建立時間**：2026-08-16 12:45（UTC+8）
> **交接目的**：讓執行 team 的 fresh agent 依本檔直接開工，終態見 `round-2-plan.md` 驗收條件 1–8。
> **目前判定**：待實作（設計已由使用者核准，未動任何程式碼）
> **可信版本錨點**：branch `main`；HEAD `7c33194`；tracked 樹乾淨（untracked 檔見 §3）

## 0. 接手速讀（60 秒）

- **目標**：切換=貼圖上屏成本（≤30ms）、5x 放大清晰、spinner 永久卡死消失、RAW 預載追上連按。
- **現象**：切換 127.5ms（97% 是 UI 端 24MP 解碼）；in-flight 選中 → spinner 永卡；RAW native 209ms/張。
- **方案**：R3 notify 補發｜tier-1 視窗解析度預解碼 5 張｜tier-2 停頓後全尺寸 3 張、兩層並存｜ImageCache 500MB｜R4 native RAW 抽取尺寸如實。
- **下一個動作**：WP1（R3，`lib/services/image_preload_controller.dart:77-94`）。
- **最大紅線**：共用主樹禁全樹 git 操作；precache 與顯示的 provider key 必須逐位元一致，否則 R2 白做。

## 1. 接手啟動序列

1. Read `docs/logs/2026-08-16/round-2-plan.md`（契約與驗收條件）。
2. Read `lib/services/image_preload_controller.dart`（全檔 ~150 行）與 `lib/views/main_detail_view.dart:160-205`。
3. Run `git log --oneline -4` — 預期 tip `7c33194`；`git status --porcelain --untracked-files=no` — 預期空。
4. Run `flutter test` — 預期 `+14: All tests passed!`（基線）。
5. 從 WP1 開始（§6 依賴鏈）。

## 2. 目的、現象與根因狀態

### 根因（已確認，證據閉合）
在切換照片時，`Image.memory` 令引擎於顯示關鍵路徑全幅解碼 6000×4000 JPEG，實測 124.1ms，佔切換 127.5ms 的 97%；預載只快取 bytes、從不解碼。
證據：`perf-measurement-report.md` 階段表（A+B+C=128.7ms vs 實測 127.5ms，誤差 1%）；`tmp/verify/perf/*.summary.txt`。

### 伴生 bug（已確認）
`_loadPreview` 對 in-flight 項 early-return 且窗口預載帶 `notifyLoaded: null` → bytes 17ms 進快取但 UI 永不重繪。
證據：`image_preload_controller.dart:77-81`＋`:70`；burst trace 4/20 鍵、20s 未上屏。

### RAW（已確認）
`AppDelegate.swift` 以 `max(targetSize, 8000)` 抽 embedded preview（123ms）再 q0.8 重編碼（82.7ms）。
證據：`AppDelegate.swift:119-124`、`:181-182`；`PERFNATIVE|` log（`tmp/verify/perf/dng_*.stdout.log`）。

## 3. 範圍與版本控制狀態

- In scope 檔案：`lib/services/image_preload_controller.dart`、`lib/views/main_detail_view.dart`、`lib/providers/app_state.dart`、`lib/main.dart`、`lib/services/native_thumbnail_service.dart`、`macos/Runner/AppDelegate.swift`、`test/image_preload_controller_test.dart`（＋必要新測試檔）。
- Out of scope：`dart_test.yaml`、Android 一切、`lib/services/trash_service.dart`、sidebar 縮圖路徑（`preloadThumbnails`）。
- Branch/HEAD：`main` / `7c33194`；tracked 樹乾淨。
- Untracked 但在用（不可誤刪）：`test/photo_file_actions_test.dart`（跑在套件內）、`lib/services/trash_service.dart`、`tmp/verify/`、`scripts/tmp/perf/`、`.claude/tmp/`。
- 背景狀態：無 team、無 tmux 殘留（round-1 與量測 team 均已 verify ok）。

## 4. 目前邏輯架構（本階段切面）

| 節點 | 責任 | 關鍵符號 | 上游 | 下游 | 不變式／失敗語意 |
|---|---|---|---|---|---|
| 鍵盤入口 | Arrow → next/previous | `lib/views/main_screen.dart:67-98` | 使用者 | AppState | — |
| AppState | 選擇狀態＋觸發預載 | `app_state.dart:150-176`（selectItem）、`:269-278` | main_screen | PreloadController、notifyListeners | `_preloadImages()` un-awaited（錯誤成 unhandled async；既有行為） |
| PreloadController | bytes 窗口快取 -3..+5、當前優先＋並行 | `image_preload_controller.dart:43-72`、guard `:77-81` | AppState | NativeThumbnailService | 淘汰=窗口外即刪 `:61`；**R3 改這裡的 notify 語意** |
| NativeThumbnailService | MethodChannel 'halcyon/thumbnail' | `native_thumbnail_service.dart:17-37`；targetSize enum `:4-15` | PreloadController | AppDelegate | PlatformException→null（呼叫端以 null 靜默處理） |
| AppDelegate (macOS) | JPEG passthrough／HEIC 解碼／RAW 抽取 | passthrough `AppDelegate.swift:91-103`；RAW `:119-124`、re-encode `:181-182` | channel | 檔案系統 | 背景 queue 處理、main queue 回 result、result 恰一次；**R4 改抽取尺寸** |
| 顯示 | Image.memory(gaplessPlayback) or spinner | `main_detail_view.dart:165-205`；`Image.memory :192-199` | AppState.currentImageBytes `app_state.dart:89-90` | 引擎解碼 | **目前無 cacheWidth、無 precache——R1/R2/tier-2 改這裡與 controller** |
| Flutter ImageCache | 解碼結果 LRU | 引擎全域；未調參 | Image/precacheImage | GPU | 預設 100MB——**改 500MB（main.dart）** |

## 5. 資料生產消費鏈（目標態）

### Happy path（tier-1）
`鍵盤 → AppState.selectItem → PreloadController(bytes 窗口 ±3/±5) → provider 工廠(ResizeImage fit @視窗px) → precacheImage(±2) → ImageCache → Image(同 provider) 上屏`

| Hop | 輸入 | 輸出 | 驗證/正規化 | 身分鍵 | 失敗處理 | 證據/落點 |
|---|---|---|---|---|---|---|
| channel→bytes 快取 | path+targetSize | Uint8List | native 端 | item.id | null→不入快取 | `image_preload_controller.dart:85-92` |
| bytes→tier-1 解碼 | 同一 Uint8List 物件 | ImageCache entry | ResizeImage fit | **bytes 物件識別＋尺寸參數**（key） | 解碼失敗→log、顯示端 errorBuilder | 新增於 controller |
| tier-1→顯示 | provider | 貼圖 | — | 同上 key | miss→現場解碼（退化不壞） | `main_detail_view.dart:192` |
| 停頓→tier-2 | 同 bytes | 全尺寸 entry | MemoryImage 無 resize | bytes 物件識別 | 出窗跳過；不可取消已開始者 | 新增 |

### Failure path
- 載入拋錯：`_loadPreview` 需 try/finally 保證 `_loadingKeys` 清除＋掛起回呼 flush（吸收前輪 parking-lot「permanent stranding」）。
- ImageCache 逐出（LRU 500MB）：顯示端 miss 只是回到現場解碼，功能不壞、僅變慢——不可因此崩潰或空白。

## 6. 待解議題＝工作包依賴鏈

```
WP1 (R3)          — 獨立，先做（P0：修 bug）
WP2 (tier-1 R1+R2) — 依賴 WP1 的 notify 語意
WP3 (tier-2 全尺寸) — 依賴 WP2 的 provider 工廠與尺寸通道
WP4 (R4 native)    — 獨立，可與 WP1-3 並行（不同檔）
WP5 (量測復驗＋post-merge gate) — 依賴全部
```

### WP1 — R3 notify 補發（P0）
- **入口**：`image_preload_controller.dart:77-94`。
- **做法**：`_loadingKeys: Set<String>` → `Map<String, List<VoidCallback>>`（或並存 `_pendingNotifies`）。in-flight 命中且 `notifyLoaded != null` → 掛回呼；載入完成寫快取後 flush 該 key 全部回呼再移除 entry；全程 try/finally。
- **完成條件**：契約 AC1；既有 2 測試不回歸。

### WP2 — tier-1 視窗層（P1）
- **入口**：`main_detail_view.dart:192-199`（顯示）、`image_preload_controller.dart`（precache）、`app_state.dart:33-39`（注入）、`lib/main.dart`（ImageCache 500MB）。
- **做法**：
  1. `main.dart`：`PaintingBinding.instance.imageCache.maximumSizeBytes = 500 << 20;`
  2. **provider 工廠**（單一函式，controller 與 view 共用）：`ResizeImage(MemoryImage(bytes), width: wPx, height: hPx, policy: ResizeImagePolicy.fit)`；bytes 一律取 `_imageCache` 內同一物件。
  3. 視窗尺寸通道：view 的 LayoutBuilder 尺寸×`devicePixelRatio` 經 AppState setter 傳入 controller（resize 時更新；尺寸變更使舊 key 自然失效，靠 LRU 淘汰即可，不強制清）。
  4. controller 在 bytes 就緒後對 current±2 `precacheImage`（或 provider.resolve+listener，避免傳 context）；照現行窗口規則對出窗項 `imageCache.evict(providerKey)`。
  5. 顯示端 `Image(image: 同工廠 provider, gaplessPlayback: true, ...)`。
- **完成條件**：契約 AC2、AC4。

### WP3 — tier-2 全尺寸層（P2）
- **入口**：controller（排程）＋view（provider 選擇）。
- **做法**：導航事件重置 ~250ms debounce timer；到期且 current 的 tier-1 已上屏 → 對 current±1 以 `MemoryImage(bytes)`（無 resize）precache；佇列出窗即跳過；tier-2 窗口外 evict 全尺寸 entry（**保留 tier-1 entry**）。顯示端：tier-2 已快取 → 用全尺寸 provider，否則 tier-1（gaplessPlayback 保無縫）。判斷「已快取」用 `imageCache.containsKey`／completer 記帳，不得誤觸發現場全幅解碼。
- **完成條件**：契約 AC3。
- **RAW 註記**：RAW 的 bytes 已是 native 抽取的預覽（R4 後 ~2400-3000px），tier-2 對其成本低；5x 放大銳利度受限，屬 out-of-scope 已知限制。

### WP4 — R4 native RAW（可並行）
- **入口**：`AppDelegate.swift:119-124`（`max(targetSize, 8000)`）、`:181-182`（re-encode）；Dart 側 `native_thumbnail_service.dart:4-15`。
- **做法**：native 直接用 Dart 傳入的 targetSize（RAW preview 抽取上限）；Dart 端 preview 用途傳真實需求（視窗長邊×2，約 2400–3000，由 AppState 尺寸通道取得；channel 參數已存在，改語意不改 shape）。重編碼維持但輸入已小；若實作 embedded-JPEG 直傳可再省，擇一並在回報說明。保留「embedded 過小→完整解碼」fallback（`:117-136` CIRAWFilter 路徑不動）。
- **完成條件**：契約 AC5；`PERFNATIVE` 級量測 RAW 單張 ≤60ms（AC7 一併驗）。
- **注意**：JPEG passthrough（`:91-103`）不受影響——diff 不得觸碰該分支。

### WP5 — 量測復驗＋post-merge gate（P3）
- **入口**：`tmp/verify/perf/harness/`（前輪 harness 源碼已歸檔）＋`instrumentation.patch` 可參考插樁點。
- **做法**：profile build 重跑切換量測（≥20 切換）；證據綁 HEAD hash；然後 main 上 `flutter test`＋`flutter build macos --debug`。
- **完成條件**：契約 AC7、AC8。

## 7. 檔案所有權（team 派工用）

| 工作包 | 檔案 | 可並行性 |
|---|---|---|
| WP1→WP2→WP3（同一 worker 串行——共享 controller/view/state 檔） | `image_preload_controller.dart`、`main_detail_view.dart`、`app_state.dart`、`main.dart`、`test/image_preload_controller_test.dart`＋新測試 | 串行鏈，單一 implementer |
| WP4 | `AppDelegate.swift`、`native_thumbnail_service.dart`（僅 targetSize 語意）* | 與上並行 |
| WP5 | `scripts/tmp/perf/`、`tmp/verify/perf/` | 全部完成後 |

*`native_thumbnail_service.dart` 兩包都碰的風險：WP4 只改 enum/targetSize 傳值，WP2 不碰此檔——若 WP2 發現需要改，停手回報 orchestrator 協調。

## 8. 型別與介面契約（會影響接續工作者）

| 契約 | Producer 定義 | Consumer 假設 | 不變式 | 錯誤語意 | 證據 |
|---|---|---|---|---|---|
| provider key | 工廠：同 Uint8List＋同 fit 尺寸 | Image/precache/evict 三方同 key | **bytes 不得複製重建** | key 不一致=靜默雙倍解碼 | Flutter ImageCache key 語意 |
| channel getThumbnail | `{path, purpose, targetSize}` `native_thumbnail_service.dart:27-31` | native 端讀同名參數 | shape 不變，僅 targetSize 語意改「如實」 | PlatformException→Dart null | `AppDelegate.swift:74-` |
| 淘汰窗口 | bytes 窗 -3..+5；tier-1 窗 ±2；tier-2 窗 ±1 | 三窗嵌套（tier⊂bytes） | 淘汰 tier 快取不得同時淘汰 bytes | miss=退化為現場解碼 | `image_preload_controller.dart:53-61` |
| 10s 測試上限 | `dart_test.yaml` | 所有新測試 | 不可改此檔 | 超時=測試失敗 | commit `7c33194` |

## 9. 嘗試、裁決與禁止重踩

| 嘗試／方案 | 結果 | 裁決理由 | 可重試 |
|---|---|---|---|
| 全尺寸就緒後丟棄 tier-1 快取（使用者原案） | 改為兩層並存 | tier-2 窗(±1)<tier-1 窗(±2)，每步導航產生重解碼 churn；並存僅多 ~72MB | 否（使用者已採納修正） |
| cacheWidth+cacheHeight 硬指定 | 改用 ResizeImagePolicy.fit | 引擎雙參數不保長寬比 | 否 |
| 在 `testWidgets` 內 await 真實引擎 future | 永久掛死 | FakeAsync zone；必須 `tester.runAsync()` | 否（lessons-learned 已記） |
| grep flutter test 輸出檔名驗測試存在 | 誤報 | reporter 輸出非決定性；用 exit code＋宣告數==執行數 | 否 |

## 10. 已知限制與不確定性

- **未驗證**：`ResizeImagePolicy.fit` 於本專案 Flutter SDK 版本可用性——WP2 第一步先 `flutter analyze` 確認；不可用則以「僅傳 width（橫圖）/height（直圖）擇一」退化實作並回報。
- **未驗證**：`precacheImage` 不傳 context 的 resolve 寫法在本 app 結構的可行性；備案為透過 view 傳 context。
- **已知限制**：RAW 5x 放大銳利度受抽取尺寸上限（out-of-scope，觸發條件見 plan）。
- **已知限制**：tier-2 已開始的解碼不可取消，僅能不排新項。
- **數字預期**：Retina 2x 下 tier-1 解碼約 70-80ms（背景),非量測報告的 1800px/54.8ms；AC 只約束切換上屏 ≤30ms 與 RAW native ≤60ms。

## 11. 驗收命令（由窄到寬）

```bash
# WP1-3 單元／行為測試
flutter test test/image_preload_controller_test.dart   # 預期：全綠（含新測試）
flutter test                                            # 預期：All tests passed（≥14＋新增）
# WP4
flutter build macos --debug                             # 預期：✓ Built ... Halcyon.app
# WP5（樣本：local_data/photo_samples；方法：tmp/verify/perf/harness/）
# profile build 切換量測 ≥20 次 → JPEG hit 中位數 ≤30ms；RAW native ≤60ms；輸出綁 HEAD hash
# post-merge（main tip）
git rev-parse HEAD && flutter test && flutter build macos --debug
```

## 12. 參考入口

- 契約：`docs/logs/2026-08-16/round-2-plan.md`
- 量測報告＋raw log：`docs/logs/2026-08-16/perf-measurement-report.md`、`tmp/verify/perf/`
- 插樁參考：`tmp/verify/perf/instrumentation.patch`（前輪各階段打點位置）
- 修法解說：`docs/logs/2026-08-16/perf-fix-proposals-R1-R4.md`
