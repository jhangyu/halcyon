# Round 3b → 3b-R：等 decoder 修好 libjpeg 後重新整合 — Session Handover

> **建立時間**：2026-08-17 00:55（UTC+8）
> **交接目的**：讓下一個 session 在 `flutter_dng_decoder` 解除 libjpeg sandbox 阻斷後，**重新整合並驗證**已完成的 Halcyon 管路。終態是：無內嵌預覽的 DNG 在 release `.app` 內走真解碼上屏，且 `rawDecode.ready` 在沙箱下實測非零。
> **目前判定**：**阻塞（外部相依）**。Halcyon 端管路已完成、已 commit、已驗證；等對方交付。
> **可信版本錨點**：branch `main`；HEAD `f55915c`；程式碼交付 tip `bcc096b`。所有驗證證據綁定 `bcc096b`（見 §7 註記）。

## 0. 接手速讀（60 秒）

- **目標**：手機直出的 Bayer CFA DNG（無內嵌全尺寸 JPEG）在 5x 放大時清晰，且操作停頓 <1s。
- **現象**：管路正確但**功能不啟動**。`libdng_decoder_native.dylib` 以絕對路徑連結 `/opt/homebrew/.../libjpeg.8.dylib`，沙箱程序讀不到 → `dlopen` 失敗 → 回退舊路徑。
- **目前位置**：Halcyon 端**全部做完**（B1–B5、A1–A5、Z1 通過）。**只差對方一個打包修正。**
- **下一個動作**：跑 §12 的 D1 三行判準，確認對方是否已修；未修就停下回報，不得在 Halcyon 端自救。
- **最大紅線**：**禁止**在 Halcyon 端用 `install_name_tool` 打包 libjpeg。使用者已明確裁決（2026-08-17）。

## 1. 接手啟動序列

1. Read 本檔 §2、§8、§9。
2. Read `docs/logs/2026-08-17/round-3b-close-note.md` §2、§3.5 — path 依賴的活體耦合，以及三條會改變判讀的規則。
3. Run `git -C ../flutter_dng_decoder status --short` — **必須為空**。非空表示對方正在編輯，此時任何紅燈都不可判讀（見 §9）。
4. Run §12 的 D1（`otool -L` 三行）— 判定對方是否已交付。
5. **未修** → 停下回報使用者，結束。**已修** → 跑 §12 的 R1–R4 完整重整合驗證。

## 2. 目的、現象與根因狀態

### 目的
使用者匯入的 DNG 在 5x 放大時清晰度與 JPEG 同級（round 3 系列的既有終態，見 `docs/logs/2026-08-16/round-3b-dng-decoder-integration-handover.md` §2）。

### 現象
- 條件：release build、App Sandbox 啟用（Flutter macOS 範本預設）、開啟無內嵌全尺寸 JPEG 的 DNG。
- 實際：`rawDecode.fail`，回退舊 CIRAWFilter 路徑（慢、2800px 截斷）。**畫面仍有圖**。
- 預期：`rawDecode.ready`，4080×3056 上屏。
- 證據：`tmp/verify/r3b/close_launch4.log`、`~/Library/Containers/com.jhangyu.halcyon/Data/r3c/perf.log`（2026-08-17 00:2x 產生）。

### 根因：**已確認**，非假設

`DYLD_PRINT_SEARCHING=1` 下 dyld 的原話（`tmp/verify/r3b/z3_rootcause.txt`）：

```
dyld: <E05D64C4-...> .../Halcyon.app/Contents/Frameworks/libdng_decoder_native.dylib   <- 我們的 dylib 映射成功
dyld: find path "/opt/homebrew/opt/jpeg-turbo/lib/libjpeg.8.dylib"
dyld:   found: dylib-from-disk-error: "/opt/homebrew/..." => "file system sandbox blocked open()"
```

排他性證據——已機械排除：缺檔（`ls` 存在 1,456,592 bytes）、路徑計算錯誤（dyld 印出的路徑字面正確）、Library Validation（app 與 dylib flags 皆僅 `0x2 adhoc`，無 runtime 旗標）、簽章損毀（`codesign -v -vvv` valid）、artifact 不符（`dwarfdump --uuid` 兩端相同）。

**修法已實測驗證**：在 `.app` 副本上把 libjpeg 打包進 `Frameworks/` 並改為 `@rpath`、保留 sandbox entitlement 重簽章後 → `rawDecode.ready` ×9、4080×3056、61–406ms（`tmp/verify/r3b/probe_launch.log`）。**libjpeg 是唯一阻斷點。**

## 3. 範圍與版本控制狀態

- **In scope（下一輪）**：驗證對方交付、重跑整合驗證、必要時調整 `macos/Runner.xcodeproj/project.pbxproj` 的嵌入步驟（僅當對方選「隨附 libjpeg」而非靜態連結）。
- **Out of scope**：非 RGGB 顏色（decoder 端 `bb6f5e7` 疑似已修，未驗）、原生 RAW（RW2/ARW/CR2/NEF/ORF）、Android、效能調優（round 3c）。
- Branch / HEAD：`main` / `f55915c`
- **Working tree：本輪成果全部已 commit。** 殘留未追蹤檔**皆非本輪產生**，勿一併處理：
  ```
  ?? lib/services/trash_service.dart          非本輪
  ?? test/photo_file_actions_test.dart        非本輪
  ?? scripts/tmp/fixed_controller.dart.bak    scratch 殘留
  ?? .claude/ .codex artifacts/ android/.kotlin/ **/swiftpm/  工具與 IDE 產物
  ?? **/AGENTS.md                             其他工具產生
  ```
- 相關 commits：
  - `b557261` — round 3a：內嵌全尺寸 JPEG passthrough + 永久 gated 埋點
  - `8e6a1cf` — 凍結整合介面 `DecodedRgba` / `DngFullDecoder`
  - `bcc096b` — **round 3b 實作**（程式碼交付 tip）
  - `6d7b8bd`、`f55915c` — 收尾註記與補錄
- 背景狀態：team `halcyon-r3b` 已關閉（7 名成員全部 `shutdown_approved` + `teammate_terminated`，tmux server 已死，`TeamDelete` 成功，無殘存進程）。cron `e429e8d4` 排定 2026-08-17 05:41 自動複驗（durable，寫入 `.claude/scheduled_tasks.json`）。

## 4. 目前邏輯架構（本階段切面）

| 節點 | 責任 | 關鍵符號 | 上游 | 下游 | 不變式／失敗語意 |
|---|---|---|---|---|---|
| Composition root | 注入真解碼器 | `lib/main.dart:24` `dngDecoder: halcyonDngFullDecoder` | — | AppState | **未注入時整條 raw 路徑靜默不啟用**（round 3b 曾因此 inert） |
| Dart 取圖入口 | 主請求，**opt-in** raw 訊號 | `lib/providers/app_state.dart:40` → `requestImage(...)` | 預載控制器 | channel | `allowRawDecodeSignal` 預設 **true**；若強制 false，native 永不發訊號、raw 路徑永不啟用 |
| Native 訊號 | 無內嵌預覽時明確告知 | `macos/Runner/AppDelegate.swift`（`NO_EMBEDDED_PREVIEW` + orientation） | channel | Dart | 僅 `purpose=="preview"` 且 `.dng` 且抽取回 nil 且 flag 為 true 時發出；flag 為 false 時行為與 3a 逐位元組相同 |
| 3a 抽取器 | 找內嵌全尺寸 JPEG；**唯讀 orientation** | `macos/Runner/DngPreviewExtractor.swift`（`readDngOrientation` 為 3b 新增，純附加） | 上者 | 上者 | **抽取判準為 mutation 驗證過的 3a 程式碼（9/9 KILLED），不得修改** |
| Dart sentinel | 區分「該真解碼」與「一般失敗」 | `lib/services/native_thumbnail_service.dart:78,95`；`sealed NativeImageResult` | channel | 控制器 | `getThumbnail()` 保留為 `Uint8List?` wrapper 且**硬寫 flag=false**，讓 `lib/perf/` 量到與 3a 相同的 native 路徑 |
| 真解碼 | RGBA8 → `ui.Image` | `lib/services/dng_decode_service.dart:17,39`；`decodeOnWorker` | 控制器 | provider | 拋錯即回退（見下列） |
| Fallback | 保證什麼都沒被移除 | `image_preload_controller.dart:438`、`:562` → `getThumbnail`（flag=false） | 解碼失敗／無 decoder | 舊 ImageIO 路徑 | **這是 2026-08-17 真實 dylib 故障時唯一讓畫面有圖的東西** |
| 上屏 | `ui.Image` → ImageProvider | `lib/services/decoded_rgba_image_provider.dart`（`OneFrameImageStreamCompleter`，每次 `ImageInfo` 交 `image.clone()`） | 控制器 | `main_detail_view.dart` | clone 是**同一塊 buffer 的第二個 handle**；master `debugDisposed==true` 不代表已釋放 |
| 生命週期 | `ui.Image` 釋放 | `image_preload_controller.dart:107,226,400`（`_rawDecodesInFlight`） | 掃描／dispose | — | stale 掃描取 `_tierTwoKeys` ∪ `_decodedProviders` ∪ `_rawDecodesInFlight` 三者聯集；缺任一者會孤立 |

## 5. 資料生產消費鏈

### Happy path（修好後應成立）
`DNG 檔 → AppDelegate 抽取回 nil → NO_EMBEDDED_PREVIEW(+orientation) → Dart sentinel → decodeOnWorker → RGBA8 → ui.decodeImageFromPixels → 套 EXIF → DecodedRgbaImageProvider → tier-1/tier-2 共用同一張 ui.Image`

| Hop | 輸入 | 輸出 | 失敗處理 | 證據 |
|---|---|---|---|---|
| native → Dart | 抽取器 nil | `PlatformException(NO_EMBEDDED_PREVIEW, details=orientation)` | flag=false 時不發，走舊路徑 | `AppDelegate.swift` |
| Dart → decoder | 檔案路徑 | `DecodedRgba{rgba,width,height}` | 拋錯 → 以 flag=false 重送 → 舊路徑 bytes | `dng_decode_service.dart:17` |
| decoder → 上屏 | RGBA8 4080×3056 ≈ 49.9MB | `ui.Image` | — | `decoded_rgba_image_provider.dart` |
| 上屏 → 釋放 | 離開預載視窗 | `dispose()` | 解碼途中離開 → 旗標被清 → 遲到影像自我釋放 | `image_preload_controller.dart:400` |

### Failure path（2026-08-17 實際發生的）
`decodeOnWorker` 拋 `StateError: Could not load native library` → `rawDecode.fail` → 以 `allowRawDecodeSignal:false` 重送 → 舊 ImageIO bytes → `image.resolved|tier=1` → `image.painted|tier=1`。**使用者看到慢的低解析度圖，不是黑畫面。**

## 6. 型別與介面契約

| 契約 | Producer | Consumer 假設 | 不變式 | 證據 |
|---|---|---|---|---|
| `DngFullDecoder` | `dng_decode_service.dart:39` `const DngFullDecoder halcyonDngFullDecoder = decodeDngFull;` | 控制器只對此 typedef 編程 | 凍結於 `8e6a1cf`，改需雙方同意 | `lib/services/dng_decode_contract.dart` |
| `NativeImageResult` | `native_thumbnail_service.dart` sealed class | `NativeImageBytes` / `NativeImageNeedsRawDecode(exifOrientation)` / `NativeImageFailure` | `getThumbnail()` 仍回 `Uint8List?`，**不得改簽章**（`lib/perf/perf_driver.dart:191` 依賴它） | 同左 |
| `allowRawDecodeSignal` | channel 參數，預設 true | 僅兩個 fallback 站點顯式送 false | **主請求必須 true，否則 raw 路徑永不啟用**——這是反直覺處 | `native_thumbnail_service.dart:95` |
| `decodeOnWorker` | `../flutter_dng_decoder/dng_processor/lib/src/dng_decoder_service.dart:194` | 唯一可用入口 | **不可改用 `decode()`**（同步、零拷貝、禁跨 isolate） | 同左 |
| dylib 載入 | `dng_bindings.dart:249-266` 候選順序 | production 走 `$execDir/../Frameworks/` | **成功訊息印的是候選字串不是解析路徑**，不能拿它驗證來源 | 同左 |

## 7. 已完成事項

| 結果 | 產物 | 驗證 | 版本錨點 |
|---|---|---|---|
| [C] A1 dylib 嵌入 release `.app` | `macos/Runner.xcodeproj/project.pbxproj` Run Script | `flutter build macos --release` EXIT=0；`Frameworks/` 含 dylib | `bcc096b` |
| [C] A2 `decodeOnWorker` 實跑 | `lib/services/dng_decode_service.dart`、`test/dng_decoder_smoke_test.dart` | `+1 All tests passed!`，4080×3056、rgba 49,873,920 | `bcc096b` |
| [C] A3/A5 打包證據 | `docs/logs/2026-08-16/round-3b-decoder-project-interface-requests.md`（237 行） | UUID 相符、codesign valid、production 路徑可 dlopen | `bcc096b` |
| [C] B1–B5 管路 | `AppDelegate.swift`、`native_thumbnail_service.dart`、`decoded_rgba_image_provider.dart`、`image_preload_controller.dart`、`app_state.dart`、`main_detail_view.dart`、`main.dart` | `flutter test` EXIT=0 `+58`，宣告數＝執行數 | `bcc096b` |
| [C] 150MB 洩漏修復 | `image_preload_controller.dart:226,400` | 紅轉綠實測：`Expected:<0> Actual:<3>` → `All tests passed!` | `bcc096b` |
| [C] Native 訊號 production 驗證 | — | release `.app` 內 `noEmbeddedPreview` 觸發 6/6 | `bcc096b` |

**證據時效註記**：以上皆綁定 `bcc096b` 的 Halcyon 樹。**Z1（`flutter test`）在對方樹非靜止時會失敗**，那不是本輪迴歸（見 §9）。

## 8. 待解議題

| 優先 | 狀態 | 議題 | 解除條件 | 下一動作 | 完成條件 |
|---|---|---|---|---|---|
| **P0** | **[B]** | decoder 的 libjpeg 絕對路徑連結 | 對方改為靜態連結或 `@rpath`＋隨附 | 跑 §12 D1 | `otool -L` 無 `/opt/homebrew` 行 |
| P1 | [U] | 重整合驗證 | P0 解除 | 跑 §12 R1–R4 | `rawDecode.ready` 非零、零 `rawDecode.fail`、輸出 4080×3056 |
| P1 | [U] | 若對方選「隨附 libjpeg」而非靜態連結 | 對方回覆方案 | 檢查 `--embed-macos-dylib-only` 是否嵌入兩個檔；否則改 `project.pbxproj` 的 Run Script | `Frameworks/` 同時含 dylib 與 `libjpeg.8.dylib` |
| P1 | [D] | **使用者真機視覺確認** | P1 通過 | 請使用者實際開圖 | 使用者確認清晰度與速度 |
| P2 | [U] | 非 RGGB 顏色 | decoder `bb6f5e7` 已 commit 但**我方未驗** | 真機確認時一併看 | 藍天是藍的 |
| P2 | [U] | orientation 2–8 | — | 僅合成 2×3 fixture 驗證過；`orient=1` 是恆等變換，**不能當作方向功能已驗證** | 取得真實非正立樣本 |
| P2 | [U] | 記憶體持續行為 | — | fixture 皆 2×2/2×3；真實 49.9MB buffer 只在 patched build 走過一次 | 真機持續導航無抖動 |
| P3 | [D] | path 依賴的活體耦合 | round 3c 決策 | 二擇一：釘 commit，或保留＋triage 規則 | 見 §9 |
| P3 | [ ] | 3c debounce 陷阱 | — | 改 `tierTwoNavigationDebounce` 前必須重跑洩漏平衡與 request-once 測試 | 見 `round-3b-pipe-interface-frozen.md` |

## 9. 嘗試、裁決與禁止重踩

| 嘗試／方案 | 結果 | 裁決理由 | 可重試 |
|---|---|---|---|
| **Halcyon 端 `install_name_tool` 打包 libjpeg** | 實測**可行**（`rawDecode.ready` ×9） | **使用者裁決不採用**（2026-08-17）：會累積一個沒有人會執行拆除日期的 workaround；且 fallback 讓等待成本只是慢路徑而非壞掉的 app | **否**，除非使用者改判 |
| 移除 `com.apple.security.app-sandbox` | — | 為繞過打包 bug 而移除安全控制，且斷送 Mac App Store | 否 |
| 用 entitlement 開放 `/opt/homebrew` 讀取 | 不存在此 entitlement | App Sandbox 沒有任意路徑讀取權限 | 否 |
| 用未沙箱化的 `DynamicLibrary.open` 驗證載入 | **綠燈但無效** | 沙箱是綠與紅之間唯一差別。**out-of-process 探針無法驗證 in-process 安全策略** | 否 |
| 以 `[DngNativeBindings] loaded:` 是否含 `/Contents/Frameworks/` 判定 | **判準不可滿足** | 該行印的是候選字串不是解析路徑 | 否 |
| `codesign --force --deep --sign -` 重簽測試用 app | **靜默剝除 entitlements** | app 變成非沙箱執行，測的是另一個程式 | 否，必須 `--entitlements` 保留 |
| 用 perf driver 驗證 raw 路徑 | 需 ≥5 張且全為 bare-CFA | `perf_driver.dart:84` 少於 5 張直接 abort；且 `:191` 走 `getThumbnail`（flag=false） | 可，照 §12 R3 的設定 |
| 用 commit hash 綁定 artifact | **無效** | 工作未提交時前後 artifact 都記同一個 hash。改用**內容標記**（本輪新引入且該次執行確實走過的符號） | 否 |
| 由聊天訊息時間戳推論檔案新舊 | **否證** | 本輪 7 次「否定結果來自儀器而非程式碼」之一。**任何否定結論先重驗儀器** | 否 |

## 10. 未來方向（不阻塞當前交付）

- **decoder 宣告為 ffiPlugin + 提供 podspec**（A3 建議 B-3）：一次解決 barrel export、plugin 機制、dylib 交付、以及 path 依賴的活體耦合。觸發條件：round 3c 或 decoder 團隊排程時。
- **釘選依賴版本**：當 decoder 穩定後。觸發條件：libjpeg 修復落地。

## 11. 已知限制與不確定性

- **已知限制**：orientation 2/3/4/5/7/8 僅合成 fixture 驗證。真實樣本 `orient=1` 是恆等變換，覆蓋率最弱。
- **已知限制**：記憶體推論為分析性；真實 49.9MB buffer 只在 2026-08-17 的 patched build 走過一次、無觀察到失敗，未在持續導航下量測。
- **已知限制**：`readDngOrientation` 在 miss 路徑會第二次完整讀取 DNG（約 20MB 重讀）。正確但浪費，round 3c 候選。
- **未驗證**：decoder 的 `bb6f5e7`（CFA 相位顏色修復）我方完全未驗。
- **未驗證**：`--embed-macos-dylib-only` 是否需改動以隨附 libjpeg——已讀 `build_native_watchdog.py:153,173,185,197` 確認目前只嵌單一硬寫檔名，但**未稽核** podspec／CI／該腳本外的打包路徑。
- **需使用者決策**：真機視覺確認（唯一憑據）；path 依賴的長期處理方式。

## 12. 驗收命令

```bash
# ---- D1：對方修好了嗎？（先跑這個，未過則停止並回報） ----
git -C ../flutter_dng_decoder status --short          # 必須為空，否則結果不可判讀
otool -L ../flutter_dng_decoder/dng_processor/native/build/libdng_decoder_native.dylib \
  | grep -v '^\s*/System/\|^\s*/usr/lib/\|@rpath\|@loader_path'
# 期望：空（除第一行檔名）。仍見 /opt/homebrew → 未修，停止。

# ---- R1：重建 ----
flutter build macos --release                          # 期望 EXIT=0
ls build/macos/Build/Products/Release/Halcyon.app/Contents/Frameworks/
# 期望含 libdng_decoder_native.dylib（若對方選隨附方案，另需 libjpeg.8.dylib）

# ---- R2：全套測試 ----
flutter test                                           # 期望 EXIT=0 + "All tests passed!" +58 以上
bash scripts/tmp/run_probe_extract.sh                  # 期望 EXIT=0 + ALL PASS（3a 未破壞）

# ---- R3：沙箱端到端（唯一有鑑別力的檢查） ----
CONT=~/Library/Containers/com.jhangyu.halcyon/Data
mkdir -p "$CONT/r3c"
for i in 1 2 3 4 5 6; do cp local_data/photo_samples/DNG/IMG_20251112_092839.dng "$CONT/r3c/cfa_$i.dng"; done
rm -f "$CONT/r3c/perf.log"
HALCYON_PERF_DIR=r3c HALCYON_PERF_OUT=r3c/perf.log HALCYON_PERF_N=4 HALCYON_PERF_MODE=paced \
  build/macos/Build/Products/Release/Halcyon.app/Contents/MacOS/Halcyon > tmp/verify/r3c/relaunch.log 2>&1 &
# 兩個 env 路徑都必須是相對路徑；預設 HALCYON_PERF_OUT 是絕對路徑，沙箱下會拋錯並靜默殺死驅動。
# 需 >=5 張（perf_driver.dart:84），且全為 bare-CFA 才會每次切換都踩 raw 路徑。

# ---- R4：判定（前置條件先跑，不是事後解釋） ----
grep -c 'perf.init' "$CONT/r3c/perf.log"    # 0 或檔案不存在 → INCONCLUSIVE，不是 FAIL
grep -c 'rawDecode.ready' "$CONT/r3c/perf.log"   # 期望 >0
grep -c 'rawDecode.fail'  "$CONT/r3c/perf.log"   # 期望 0
grep 'rawDecode.ready' "$CONT/r3c/perf.log" | head -3   # 期望含 4080x3056
# 2026-08-17 patched-copy 參考值：ready x9、4080x3056、orient=1、61-406ms
```

## 13. 參考入口

- 必讀：`docs/logs/2026-08-17/round-3b-close-note.md` — Z2 外部成因、path 依賴活體耦合、三條關閉前規則
- 必讀：`docs/logs/2026-08-17/handover-to-dng-decoder-team-libjpeg-blocker.md` — 已發給 decoder 團隊的請求全文與驗收條件
- 必讀：`docs/logs/2026-08-16/round-3b-pipe-interface-frozen.md`（584 行）— 凍結介面、六處刻意偏離、指標語意警告、**3c debounce 警告**、epistemic note
- 參考：`docs/logs/2026-08-17/round-3b-pkg-handoff.md`（124 行）— 打包側，開頭有「驗收過了但功能不能用」對照表
- 參考：`docs/logs/2026-08-16/round-3b-convergence-contract.md` — 本輪契約（含那個變成阻斷的 out-of-scope 項）
- Artifact：`tmp/verify/r3b/`（58 檔，792K，**gitignored**）— `z3_rootcause.txt`（dyld 原文）、`close_launch4.log`（fail）、`probe_launch.log`（patched 後 ready）、`embedded_dylib_checks.txt`
- 排程：cron `e429e8d4`，2026-08-17 05:41，durable（`.claude/scheduled_tasks.json`）
