# Round 3b — 以 flutter_dng_decoder 承接「無內嵌全尺寸 JPEG」的 DNG — Session Handover

> **建立時間**：2026-08-16 22:20（UTC+8）
> **交接目的**：讓下一個 session 進行移植，終態是**沒有內嵌全尺寸 JPEG 的 DNG 也能在 5x 放大時清晰、且單張端到端 <1 秒**。
> **目前判定**：3a 已完成並經使用者實測；3b 方向已定、前置實測完成、尚未動工。
> **可信版本錨點**：branch `main`；HEAD `3cbc5ffa32e744d7a6520e258a83def9fd6e3e97`；**3a 成果與埋點皆為未提交的 working tree 改動**（清單見 §3）。
> **使用者裁決**：3b 必做（2026-08-16）。A2/A3 的殘留分析議題**不影響實作方向，已停止投入**。

## 0. 接手速讀（60 秒）

- **目標**：DNG 分兩條路——檔案內有全尺寸 JPEG 就直接抽（3a 已完成），沒有就用 `flutter_dng_decoder` 真解碼（本輪）。
- **現況**：3a 上線後，有內嵌 JPEG 的 DNG 從 109.8ms 降到 1.8ms；**沒有內嵌 JPEG 的檔案仍走舊的 ImageIO 完整解碼，實測 245–414ms**。
- **已證明**：`flutter_dng_decoder` 解該類檔案 **cold 87ms / warm 40ms**，比舊路徑快約 3–15 倍。
- **下一個動作**：把 decoder 接進 Halcyon（pubspec path 依賴 + macOS dylib 打包），先讓 `decodeOnWorker` 在 Halcyon 內跑通。
- **最大風險**：decoder 有一個**已確認的顏色缺陷**（非 RGGB 相機 R/B 對調），修復不在本專案內。見 §8 P0。

## 1. 接手啟動序列

1. Read 本檔 §2、§4、§8。
2. Read `docs/logs/2026-08-16/round-3-implementation-plan.md` §B0 — 前置實測數據與顏色 blocker 全文。
3. Read `/Users/jhangyu/project/flutter_dng_decoder/docs/logs/2026-08-16/cfa-pattern-hardcode-handover.md` — 顏色缺陷的修復交接（**另一個 session 的工作**）。
4. Run `git status --short -- lib/ macos/` — 預期看到 §3 的未提交清單，確認 3a 成果仍在樹上。
5. Run `bash scripts/tmp/run_probe_extract.sh` — 預期 exit 0、ALL PASS，確認 3a 的抽取邏輯未被破壞。
6. Start at `lib/services/image_preload_controller.dart` 的 tier-2 分支與 `macos/Runner/AppDelegate.swift:101-119` 的統一 passthrough 出口。

## 2. 目的、現象與根因狀態

### 目的
使用者匯入的 DNG 在 5x 放大時清晰度與 JPEG 同級，且任何操作停頓不超過 1 秒。

### 現象（3b 要解決的）
- 條件：DNG 檔案內沒有任何全尺寸內嵌 JPEG（手機直出的 Bayer CFA 檔屬此類）。
- 實際：落回 `AppDelegate.swift` 的 CIRAWFilter 完整解碼，且輸出被 2800px 上限截斷 → 放大糊、且慢。
- 證據：`IMG_20251112_092839.dng`（vivo PD2337）nativeTotal 中位數 245.3ms（n=4，profile build），ImageIO 冷啟單次量到 1305ms。

### 根因（已確認，非假設）
該類檔案結構上就沒有可抽的預覽：
```
IFD0 : 4096x3072  Uncompressed  PhotometricInterpretation = Color Filter Array
       DefaultCropSize = 4080 3056   Orientation = Horizontal
無 SubIFD、無 PreviewImage、無 JpgFromRaw、無 ThumbnailImage
```
3a 的抽取器對它正確回傳 nil 並落回舊路徑（已驗證，見 §7）。**要解決只能真解碼**，這就是 3b。

## 3. 範圍與版本控制狀態

- **In scope**：`lib/services/image_preload_controller.dart`（tier-2 取得 bytes 的分支）、`macos/Runner/AppDelegate.swift`（回傳「無內嵌預覽」訊號）、`pubspec.yaml`、`macos/Runner.xcodeproj`（dylib 打包）。
- **Out of scope**：原生 RAW（RW2/ARW/CR2/NEF/ORF）；Android；3a 的抽取邏輯（勿改）；decoder 專案本身的修復。
- Branch / HEAD：`main` / `3cbc5ff`
- **Working tree（3a 成果與埋點皆未提交，勿以為已 commit）**：
  ```
  M lib/main.dart                              埋點接線
  M lib/providers/app_state.dart               埋點
  M lib/services/image_preload_controller.dart 埋點
  M lib/views/main_detail_view.dart            埋點（image.resolved）
  M macos/Runner.xcodeproj/project.pbxproj     註冊 DngPreviewExtractor.swift
  M macos/Runner/AppDelegate.swift             3a 統一 passthrough 出口 + 埋點
  ?? macos/Runner/DngPreviewExtractor.swift    3a 核心（TIFF/SubIFD 走訪 + EXIF 方向注入）
  ?? lib/perf/                                 永久 gated 埋點
  ?? test/dng_extractor_swift_test.dart        3a 測試接線
  ?? scripts/tmp/                              probe / 閘門 / mutation 工具
  ```
  `lib/services/trash_service.dart`、`test/photo_file_actions_test.dart`、兩個 `swiftpm/` 目錄**非本輪產生**，勿一併處理。
- 背景狀態：team `halcyon-r3a` 正在關閉；容器內的量測鏡像已清空。

## 4. 目前邏輯架構（本階段切面）

| 節點 | 責任 | 關鍵符號 | 上游 | 下游 | 不變式／失敗語意 |
|---|---|---|---|---|---|
| Dart 取圖入口 | 要求 preview bytes | `NativeThumbnailService.getThumbnail`（`lib/services/native_thumbnail_service.dart`） | 預載控制器 | method channel | 失敗回 null |
| **統一 passthrough 出口** | JPEG 與 DNG 共用單一回傳點 | `AppDelegate.swift:101-119` | channel | Dart | JPEG 讀不到＝錯誤；**DNG 抽不到＝不是錯誤，往下落** |
| 3a 抽取器 | 找出並回傳內嵌全尺寸 JPEG | `macos/Runner/DngPreviewExtractor.swift` | 上者 | 上者 | 判準：`Compression==7 && Photometric==6 && 單strip && 長邊≥0.90×DefaultCropSize`，取面積最大者；無候選回 nil |
| **舊解碼路徑（3b 要取代的）** | CIRAWFilter 完整解碼 + q0.8 重編碼 | `AppDelegate.swift`（原 :135-154 區段） | 抽取器回 nil | Dart | 慢、且受 2800px 上限截斷 |
| 兩層解碼 | tier-1 視窗解析度、tier-2 全尺寸 | `image_preload_controller.dart` `_decodeTierTwoWindow` / `fullSizeProviderFor` | Dart bytes cache | ImageCache | tier-2 目前只把**同一份 bytes** 原尺寸再解一次 |

**3b 的接點就在最後兩列**：tier-2 需要一個**新的 bytes／pixel 來源**，不是把解析度調大就好。

## 5. 資料生產消費鏈（3b 需新增的 hop）

現況：`DNG → AppDelegate 抽取 → JPEG bytes → Dart → ResizeImage(tier1) / MemoryImage(tier2)`

3b 需要：`DNG（無內嵌）→ decodeOnWorker → RGBA8 → ui.decodeImageFromPixels → tier-2 上屏`

| Hop | 輸入 | 輸出 | 待決 | 失敗處理 |
|---|---|---|---|---|
| native → Dart | 抽取器回 nil | **訊號待設計**：目前僅是靜默落回舊路徑，Dart 不知道 | 需一個明確訊號讓 Dart 知道「該走真解碼」 | — |
| Dart → decoder | 檔案路徑 | `DngImage` | 走 `decodeOnWorker`（isolate 安全），**不可用 `decode()`**（同步、零拷貝、禁跨 isolate） | `DngDecodeException(errorCode, message)` |
| decoder → 上屏 | RGBA8 4080×3056 ≈ 49.9MB | `ui.Image` | 方向須自套；通道須處理（§8 P0） | — |

**記憶體**：單張 RGBA8 約 50MB（4080×3056×4，已實測 `rgba_len=49,873,920`）。tier-2 窗口是 ±1（3 張）＝約 150MB，需與已設的 500MB `ImageCache` 上限一起算。round-2 已因 LRU 壓力吃過一個 blocker。

## 6. 型別與介面契約

| 契約 | Producer 定義 | Consumer 假設 | 不變式 | 證據 |
|---|---|---|---|---|
| `decodeOnWorker(path) → Future<DngImage>` | `dng_decoder_service.dart:194`，走 `Isolate.run`，跨界前複製為 `TransferableTypedData` | Halcyon 唯一可用入口 | **不可改用 `decode()`**：同步、零拷貝、明文禁跨 isolate | `dng_decoder_service.dart:194`、:271-276 |
| `DngImage.rgbaData` | 宣稱 RGBA8 interleaved | 直接餵給 Flutter | **排列正確，但非 RGGB 相機的 R/B 內容互換**（§8 P0） | `dng_ffi_api.h:19` |
| `DngImage.width/height` | 回傳 **DefaultCropSize**，非感光器尺寸 | 4080×3056（vivo 樣本） | 解碼器已內部裁切，**Halcyon 不需再裁** | 實測 `rgba_len` 對齊 |
| orientation | **不存在此欄位** | — | 解碼器不讀也不套 EXIF Orientation，**Halcyon 端必須自行套用** | `dng_bindings.dart:23-40` |
| dylib 打包 | 非 pub 套件、非 plugin、**無 podspec** | Halcyon 是第一個外部宿主 | macOS 靠 Xcode Run Script 呼叫 `native/scripts/build_native_watchdog.py` 產出並嵌入 `libdng_decoder_native.dylib`；Dart 端五段 fallback 搜尋含 `DNG_NATIVE_BUILD_DIR` | `dng_bindings.dart:249-266` |

## 7. 已完成事項（3a，本輪）

| 結果 | 產物 | 驗證 | 版本錨點 |
|---|---|---|---|
| [C] 內嵌全尺寸 JPEG 直出 | `DngPreviewExtractor.swift`、`AppDelegate.swift:101-119` | 13 檔全數 6000×4000；vivo 檔回 nil，兩方向同次執行皆觸發 | working tree @ `3cbc5ff` |
| [C] EXIF 方向注入 | 同上 | DxO 檔輸出 orientation=6，與 IFD0 相符 | 同上 |
| [C] 抽取邏輯有鑑別力 | `scripts/tmp/dng_extractor_tests.swift`（25 斷言，與**出貨碼**同編） | mutation 9/9 KILLED，盲區 0 | `tmp/verify/r3/mutation_dng_extractor.txt` |
| [C] 量測有效性閘 | `scripts/tmp/perf/validate_run.py` | 自我測試 15/15 KILLED；round-2 基線 ACCEPT 並重現數字 | `tmp/verify/r3/gate_selftest.txt` |
| [C] A2 效能 | — | passthrough hit n=54 中位數 **1.8ms**（目標 ≤20，基線 109.8）；全 purpose n=72 中位數 2.6ms、**p95 141.8ms**、max 413.9ms | `tmp/verify/r3/perf_verdict_r3a.md`、`perf_verdict_review.md` |
| [C] A3 無退化 | — | JPG nativeTotal 0.4→0.8ms（次毫秒漂移） | 同上 |
| [C] A6 使用者實測 | — | 使用者 2026-08-16 回報 5x 清晰、速度足夠 | 對話紀錄 |
| [C] 埋點永久化 | `lib/perf/`、`AppDelegate.swift:75,77` | `HALCYON_PERF_DIR` 未設時為 no-op | working tree |

## 8. 待解議題（3b 依賴順序）

| 優先 | 狀態 | 議題 | 下一動作 | 完成條件 |
|---|---|---|---|---|
| **P0** | **[D]** | **decoder 對非 RGGB 相機 R/B 對調** | 由**另一個 session** 在 decoder 專案修復（交接文檔已備妥）。**不能在 Halcyon 端修**：對角相反可靠交換救回，但 GRBG/GBRG 不是交換能還原的 | decoder 讀 `CFAPattern` 後 vivo 檔解出藍天 |
| P1 | [ ] | decoder 接線與打包 | `pubspec.yaml` 加 path 依賴；Xcode Run Script 產出並嵌入 `libdng_decoder_native.dylib` | `flutter build macos --release` 成功且 `.app/Contents/Frameworks/` 內含該 dylib |
| P1 | [ ] | Halcyon 內跑通 `decodeOnWorker` | 對 vivo 檔呼叫，回 width=4080 height=3056 | 腳本／測試實際跑過 |
| P2 | [ ] | native 端「無內嵌預覽」訊號 | 目前抽取器回 nil 是靜默落回舊路徑，Dart 無從得知 | Dart 能區分「該走真解碼」與「一般失敗」 |
| P2 | [ ] | tier-2 改走真解碼 | RGBA8 → `ui.decodeImageFromPixels` → `fullSizeProviderFor` | vivo 檔上屏為全解析度 |
| P2 | [ ] | 方向自套 | decoder 不處理 EXIF，Halcyon 端補 | 已知方向的樣本上屏正確 |
| P3 | [ ] | 記憶體對帳 | 50MB/張 × ±1 窗口 ≈ 150MB vs 500MB ImageCache 上限 | 窗口內不觸發 LRU 抖動 |
| P3 | [U] | JPG paced tier1-HIT 分類翻轉 | round-2 n=2 → round-3 n=0（全部落 tier2-IMMEDIATE）。**使用者裁決不影響實作方向，停止投入** | 若日後 JPEG 路徑有異狀再回頭查 |
| **P1** | **[B]** | **`scripts/tmp/perf/contention_gap.py` 有實質缺陷，3b 開跑前先修** | MISS 路徑的計時器是巢狀的：`dngPassthrough.miss` 的 dur 已包含在 `decoded` 的 dur 之內（兩者共用 `AppDelegate.swift:91` 設定的同一個 `perfStart`，`decoded` 於 :226 從同一原點計時）。現行公式把兩者相加，對 4 筆 MISS 產生**數學上不可能的負差值**（-8.6／-3.4／-3.7／-3.8ms）。修法：丟掉重複的 miss-dur 項，修正後為 0.025–0.033ms。 | 對 MISS 記錄不再出現負差值 |
| P3 | [ ] | harness 自我描述 | 讓 log 自己刻上 build 模式（`kProfileMode` 為編譯期常數）與完整 config，使「用什麼量的」不再依賴人記得保留 stdout | `validate_run.py` 不再需要 `--stdout`／`--build-log` |

## 9. 嘗試、裁決與禁止重踩

| 嘗試／方案 | 結果 | 裁決理由 | 可重試 |
|---|---|---|---|
| 提高 ImageIO 抽取上限取得全尺寸 | **否證** | cap=2800 用 108ms、cap=12000 也 108ms——它在解主影像，不是抽 JPEG，省不掉 | 否 |
| 在輸出端交換 R/B 修顏色 | **不採用** | 只對對角相反的相位有效；治標且掩蓋根因 | 否 |
| 用 debug build 的數字對 profile 基線 | **否證** | 得到假的 8 倍 p95 退化。任何對照量測必須同 build 模式 | 否 |
| 沿用口頭轉述的 harness 參數 | **否證** | 實際基線是 DNG `n=20 pace=400`、JPG `n=24 pace=400`。**派量測前先 `grep driver.config <基線 log>`** | 否 |
| 埋點用 apply-patch → 量測 → 還原 | **廢除** | 使用者裁決。埋點已永久化並 env gate | 否 |

## 10. 已知限制與不確定性

- **已知限制**：3a 的方向注入只以 orientation=1 與 6 的真實樣本驗證，2/3/4/5/7/8 未驗。
- **已知限制**：本輪與 round-2 的比較是「重建的 harness vs 原始 harness」（`settleTimeoutMs=900` 未重建，刻意不臆造），且樣本集縮小（DNG 24→14、JPG 30→7，round-2 目錄已不可復原）。倍數不應當真，方向可信。
- **需使用者決策**：P0 的 decoder 顏色修復排程；四種 CFA 相位是否全支援。
- **A2 的範圍是「僅 passthrough hit」**（契約如此），headline 1.8ms 不受全 purpose 數字影響。若日後改採全 purpose 為閘門，**p95 要用 141.8ms**，不是 61.4ms——61.4 是 sidebarThumbnail 子群自身的 max，恰好落在 p95 的插值節點（rank 67/72）而被誤讀過一次。
- **round-2 與 round-3 的 DNG 樣本組成本質不同**：r2 的 84 筆**全數走完整解碼路徑**（零筆 passthrough），r3 是 54 hit／4 miss／14 thumb 的混合。中位數對比仍有意義，但尾端統計（p95/max）比的不是同一種工作負載。r2 檔名已匿名化為 r000–r023，無法回推當時是否含同類 CFA 檔。
- **FIFO 事件關聯已證明無歧義**（非「多半正確」）：兩份 log 中任一檔名的同時在途請求數上限皆為 1，因此分組不可能配錯。

## 11. 驗收命令

```bash
# 3a 未被破壞
bash scripts/tmp/run_probe_extract.sh          # 預期 exit 0, ALL PASS
flutter test                                    # 預期 All tests passed!

# 3b P1 完成後
flutter build macos --release
ls build/macos/Build/Products/Release/Halcyon.app/Contents/Frameworks/ | grep dng_decoder_native

# 效能量測（埋點已永久化，不需套 patch）
# 沙箱：DIR 與 OUT 都必須是相對路徑，樣本先鏡像進 container Data/
python3 scripts/tmp/perf/validate_run.py <log> --stdout <capture> --build-log <build log>
# 必須 ACCEPT 才能餵給 scripts/tmp/perf/parse_r2.py（唯一權威解析器，勿改勿另寫）
```

## 12. 參考入口

- 必讀：`docs/logs/2026-08-16/round-3-implementation-plan.md` §B0、§3 — 前置實測、顏色 blocker、量測陷阱全文
- 必讀：`/Users/jhangyu/project/flutter_dng_decoder/docs/logs/2026-08-16/cfa-pattern-hardcode-handover.md` — P0 的修復交接
- 必讀：`docs/logs/2026-08-16/verification-standards.md` — 驗證產物必備欄位
- Artifact：`tmp/verify/r3/decoder_probe/` — 解碼結果目視對照（錯色與修正後），2026-08-16 產生
- Artifact：`tmp/verify/r3/perf_verdict_r3a.md` — A2/A3 裁決全文
- Decoder API：`/Users/jhangyu/project/flutter_dng_decoder/dng_processor/lib/src/dng_decoder_service.dart:194`（`decodeOnWorker`）
