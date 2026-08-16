# Round 3b — 收斂契約（凍結於 2026-08-16，只有使用者可改）

**基準 commit**：`8e6a1cf`（3a 成果已於 `b557261` 落地並驗證：probe ALL PASS、`flutter test` +24 綠）
**工作模式**：使用者裁決——**共用主工作樹**，不開 worktree，靠檔案所有權 + Git Red Lines 隔離。

## 終態（一句話）

沒有內嵌全尺寸 JPEG 的 DNG，在 Halcyon 內走 `dng_processor` 的真解碼上屏（全解析度、方向正確），且 `flutter build macos --release` 產出的 `.app` 自帶 `libdng_decoder_native.dylib`。

## In-scope 交付物

| # | 交付物 | Squad |
|---|---|---|
| 1 | `dng_processor` path 依賴 + Halcyon Xcode Run Script 打包 dylib | pkg |
| 2 | Halcyon 內 `decodeOnWorker` 實跑通過的 smoke test | pkg |
| 3 | 跨專案介面文件（libjpeg @rpath、barrel export 缺口）落檔待轉交 | pkg |
| 4 | native 端「無內嵌預覽」明確訊號（含 EXIF orientation） | pipe |
| 5 | RGBA8 → `ui.Image` → 可用於 `Image(image:)` 的 ImageProvider | pipe |
| 6 | tier-1/tier-2 接上該路徑，含 ui.Image 生命週期（evict 時 dispose） | pipe |
| 7 | 方向自套（decoder 不處理 EXIF） | pipe |

## Out-of-scope（明確不做）

- **相位翻轉／R-B 對調的顏色修復**——由 decoder 專案的另一團隊處理。本輪**不得**在 Halcyon 端交換通道。
- 原生 RAW（RW2/ARW/CR2/NEF/ORF）、Android、iOS。
- 3a 的抽取判準邏輯（`DngPreviewExtractor.swift` 的 compression/photometric/DefaultCropSize 判斷）——mutation 驗證過，**唯讀**。新增唯讀的 orientation 取值函式除外。
- 效能量測與調優（round 3c）。本輪只求「跑得起來、畫面正確」。
- libjpeg 的 `@rpath` 修復（記入介面文件轉交，本輪接受 homebrew 絕對路徑）。

## 驗收條件（逐條機械可檢查）

| ID | 條件 | 驗證命令 |
|---|---|---|
| A1 | release build 成功且 dylib 已嵌入 | `flutter build macos --release` exit 0；`ls build/macos/Build/Products/Release/Halcyon.app/Contents/Frameworks/ \| grep libdng_decoder_native.dylib` 有輸出 |
| A2 | Halcyon 內 `decodeOnWorker` 對 vivo 樣本跑通 | `flutter test test/dng_decoder_smoke_test.dart` 綠，斷言 width==4080、height==3056、`rgba.length`==49873920 |
| A3 | 介面文件存在 | `docs/logs/2026-08-16/round-3b-decoder-project-interface-requests.md` 存在且含「libjpeg」「barrel export」兩節 |
| B1 | Dart 能區分「無內嵌預覽」與一般失敗 | 單元測試：channel 拋 `PlatformException(code:'NO_EMBEDDED_PREVIEW')` 時 service 回傳專屬 sentinel，非 null |
| B2 | ui.Image ImageProvider 可上屏 | widget test：以合成 `ui.Image` 建 provider，`Image(image: p)` pump 後成功 resolve 出 frame |
| B3 | 方向轉換正確 | 單元測試涵蓋 EXIF orientation 1..8，斷言輸出寬高與角落像素標記 |
| B4 | ui.Image 不洩漏 | 測試：離開預載視窗後該 `ui.Image.debugDisposed == true` |
| B5 | 3a 未被破壞 | `bash scripts/tmp/run_probe_extract.sh` exit 0 且 `ALL PASS` |
| Z1 | 全套測試綠 | `flutter test` → `All tests passed!`，且宣告測試數 == 執行數 |
| Z2 | 合併後在 main 重跑 Z1 + A1 仍綠 | post-merge 閘（lessons-learned 2026-08-16） |

## 輪次預算

**3 輪**。用盡而驗收未全過 → 停下回報失敗軌跡，不自行開下一輪。

## 介面凍結

`lib/services/dng_decode_contract.dart` @ `8e6a1cf`——`DecodedRgba{rgba,width,height}` 與 `typedef DngFullDecoder = Future<DecodedRgba> Function(String path)`。
squad pkg 提供實作（包住 `decodeOnWorker`），squad pipe 只對此型別編程。**改這個檔案需雙方 lead 同意並回報 orchestrator。**

## Parking-lot（輪中新發現一律記於此，不插隊）

- （空）
