# Windows port review, unified build script, cross-platform thumbnails — Session Handover

> **建立時間**：2026-08-22 23:15（UTC+8）
> **交接目的**：讓下一個 session 把 **Windows 縮圖顯示不出來** 這件事真正修好。分析與計畫已完成，**程式碼一行都還沒寫**。
> **目前判定**：merge 已完成並通過閘門；**原始需求「讓 thumbnails 全平台通用」尚未達成**。
> **可信版本錨點**：Halcyon `main` @ `a8ae038`；flutter_dng_decoder `main` @ `d36e1bd`。

## 0. 接手速讀（60 秒）

- **⚠️ 主線需求未完成**：使用者最初要的是「讓 thumbnails 脫離 macOS 後全平台通用」。本輪**只做到分析與計畫**（`thumbnail-dart-first-plan.md` 的 R1–R4），**沒有寫任何實作程式碼**。Windows 上今天仍是：
  - 沒有內嵌預覽的 DNG → **主畫面顯示不出來**（`halcyon_image.cpp:392` 短路，`DngFullDecoder` 永遠不被呼叫）
  - **每一個 RAW 檔的側欄縮圖都是空白灰塊，且靜默失敗**（`image_preload_controller.dart:836` 丟掉非 bytes 結果且不留失敗標記）
- **下一個動作**：實作 R1（約 10 行，在 `native_thumbnail_service.dart` 已存在的 `case NativeImageFailure()` 裡），這一階就能讓主畫面那條路活過來。驗收條件見 plan §2 R1-AC1..AC5。
- **已達成**：兩個 `windows-port` 分支經 6 名 opus reviewer 審查後合併，0 blocker，閘門三條全過（analyze 0 issues／`test -j 1` 162 passed／exit 0）。`build_apps.py` 取代三支舊建置腳本。Windows 匯出 EXIF 遺失已修（但未編譯）。
- **最大風險／紅線**：`windows/runner/halcyon_image.cpp` 的 EXIF 修復**從未被編譯過**，而 `windows/CMakeLists.txt:42` 是 `/W4 /WX`，任何警告都是硬失敗。

## 1. 接手啟動序列

1. Read 本檔 §3（工作樹）與 §8（待解議題）。
2. Read `docs/logs/2026-08-22/windows-port-review-contract.md` §Parking lot —— 11 項延後事項與其證據狀態。
3. Read `docs/logs/2026-08-22/thumbnail-dart-first-plan.md` §2 —— R1–R4 四階計畫，R1 是下一段實作。
4. Run `git log --oneline -1 && git status --short` —— 預期 `a8ae038` 與 §3 的清單一致。
5. Run `flutter analyze && flutter test -j 1` —— 預期 `No issues found!` 與 `+162: All tests passed!`。162 是硬性數字，不是約略值。

## 2. 目的、現象與根因狀態

### 目的
讓 Halcyon 在 Windows 上真正可用，並讓建置與縮圖管線不再是 macOS 形狀。

### 已確認的根因（本輪最重要的一條）
Windows 上 DNG 顯示不了，**不是**因為 thumbnail channel 缺席。三個 channel 早在 `2af5243` 就以 WIC 實作完成（`windows/runner/halcyon_channels.cpp:67,109,143`）。真正的繞過是 `windows/runner/halcyon_image.cpp:392-403`：`IsRawExtension` 在任何解碼之前短路，**刻意**回 `RAW_UNSUPPORTED` 而非 `NO_EMBEDDED_PREVIEW`，好讓 Dart 建 `NativeImageFailure` 而非 `NativeImageNeedsRawDecode`、永不觸及 `DngFullDecoder`。其註解寫下的理由「Windows 沒有 native decoder build」已於 2026-08-22 失效。

**被否證的來源，不得再信**：`CLAUDE.md` 的「Native bridges」段、`native_thumbnail_service.dart:122-129` 的舊註解（後者已於本輪改寫）。第一份契約就是照這兩份散文寫的，整段前提錯誤，靠 reviewer 抽查才發現。

## 3. 範圍與版本控制狀態

- Branch / HEAD：Halcyon `main` @ `a8ae038`；decoder `main` @ `d36e1bd`。兩者皆為 fast-forward，無 merge commit。
- **Halcyon modified（未提交）**：

| 檔案 | 誰改的 | 狀態 |
|---|---|---|
| `windows/runner/halcyon_image.cpp` | 本輪 Task #10 | `[U]` 未編譯、未執行。+63 code／+85 comment |
| `lib/services/native_thumbnail_service.dart` | 本輪 AD-010 修訂（使用者已批准） | `[C]` 純註解，analyze 0 issues |
| `memory.md` | 本輪 AD-010 修訂（使用者已批准） | `[C]` AD-010 新增一條「修訂」 |
| `lib/views/rename_dialog.dart` | **其他任務的使用者在途工作** | **不屬於本輪。不得提交、不得還原、不得 stash** |

- **Halcyon 未追蹤（本輪產物）**：`scripts/build_apps.py`（1668 行）、`docs/logs/2026-08-22/` 底下 9 份文件。
- **Halcyon 未追蹤（非本輪）**：`.claude/`、`.codex`、`AGENTS.md`、`CLAUDE.md`、`docs/logs/2026-08-20/cross-platform-port-inventory.md`、`scripts/tmp/*`。
- **decoder working tree**：`.claude/settings.json` modified 與 4 個 untracked 測試二進位，**皆非本輪產生**，勿動。
- 背景狀態：team `halcyon-winport` 8 名成員，10 票全部 signed off + completed。無 tmux／container／dev server 殘留。
- 證據路徑：`tmp/verify/`（gitignored，`/tmp/` 規則）。跨 session 不保證存在。

## 4. 目前邏輯架構（本階段切面）

| 節點 | 責任 | 關鍵符號 | 上游 | 下游 | 不變式／失敗語意 |
|---|---|---|---|---|---|
| `AppState` | 影像請求入口 | `app_state.dart:86` | UI | `NativeThumbnailService.requestImage` | 注入 `ThumbnailLoader` typedef（`:23-27`），測試以此替身 |
| `NativeThumbnailService` | channel 呼叫＋結果分類 | `native_thumbnail_service.dart:97` | `AppState` | `MethodChannel('halcyon/thumbnail')` | 回傳恰三個 variant（AD-010/011 凍結，未破） |
| macOS 原生 | RAW/JPEG 抽取 | `AppDelegate.swift` | channel | bytes 或 `NO_EMBEDDED_PREVIEW` | 唯一會發出 raw-decode 訊號的原生端 |
| Windows 原生 | WIC 抽取 | `halcyon_image.cpp:383` `RequestImage` | channel | bytes 或 `RAW_UNSUPPORTED` | **`:392` 對 6 種 RAW 副檔名短路，先於 purpose 分派** |
| `ImagePreloadController` | tier-1/2 預載 | `image_preload_controller.dart` | `AppState` | `ImageProvider` | 兩層必須共用同一 bytes 物件識別與寬高，否則靜默重複解碼 |
| 側欄 | 縮圖顯示 | `sidebar_view.dart:273-279` | `_thumbCache` | `Image.memory` | **無 `cacheWidth`/`cacheHeight`，在原生解析度解碼** |
| `DngDecoderService` | FFI RAW 解碼 | `dng_decode_service.dart:14` | `DngFullDecoder` | 全解析度 RGBA | **無 target-size 參數**（PL-10）；每次呼叫新開 isolate 並重新 `DynamicLibrary.open` |

## 5. 資料生產消費鏈（Windows，DNG 無內嵌預覽 — 今天壞掉的那條）

`AppState:86` → channel → `halcyon_image.cpp:392` → `Fail("RAW_UNSUPPORTED")` → `native_thumbnail_service.dart:120-121` → `NativeImageFailure` → **鏈結束，永不進入 `DngFullDecoder`**。

側欄另有一條靜默失敗：`image_preload_controller.dart:836` 只收 `NativeImageBytes`，其餘丟棄且**不留失敗標記** → Windows 上每個 RAW 檔的側欄格子是空白灰塊，看起來像壞掉而非「不支援」。

R1 的修法就是在 `case NativeImageFailure()` 這個已存在的分支裡補上 Dart 端合成，約 10 行。

## 6. 型別與介面契約

| 契約 | Producer | Consumer 假設 | 不變式 | 證據 |
|---|---|---|---|---|
| `NativeImageResult` | 原生 channel ＋（R1 後）Dart | 恰三個 variant | AD-010/011 凍結**未破**；R1 只改「誰建構」 | `native_thumbnail_service.dart:36-69`；`memory.md` AD-010 修訂 |
| `dng_processor_ffi_bundled_libraries` | `dng_processor_ffi/windows/CMakeLists.txt:48-51` | `flutter_plugins.dart:732-734` 解參考 | 變數名必須逐字相符，錯了會**靜默不打包** | 已驗證正確 |
| `decodeOnWorker(String)` | `dng_decode_service.dart:14` | 呼叫端要求縮圖 | **無尺寸參數，恆回全解析度** | PL-10 |

## 7. 已完成事項

| 結果 | 產物 | 驗證 | 錨點 |
|---|---|---|---|
| [C] decoder `windows-port` 合併 | `d36e1bd` | DLL sha256 `a82b5f83…d205c2e` 與 reviewer 記錄相符 | `d36e1bd` |
| [C] Halcyon `windows-port` 合併 | `a8ae038` | `analyze` exit 0；`test -j 1` exit 0 **+162** | `a8ae038` |
| [C] 六份審查全簽收，0 blocker | `docs/logs/2026-08-22/review-*.md`（5 份）＋ decoder repo `docs/`（2 份，該 repo `/docs/` 為 gitignore） | 每份逐條驗收＋主對話抽查 | `a8ae038` |
| [C] `scripts/build_apps.py` | 1668 行，未追蹤 | 真跑 clean build → `Halcyon.app` **arm64-only**，24MB（原 47.2MB universal） | working tree |
| [C] AD-010 修訂 | `memory.md`＋`native_thumbnail_service.dart` 兩處註解 | `analyze` exit 0 | working tree |
| [U] Windows 匯出 EXIF 修復 | `windows/runner/halcyon_image.cpp` | **未編譯未執行**；驗證協定見 `windows-export-exif-verification.md` | working tree |

## 8. 待解議題（依賴順序）

**這張表的第一列就是原始需求本身，它還沒被做。** 前面幾輪產出的是分析與計畫，不是修復。

| 優先 | 狀態 | 議題 | 下一動作 | 完成條件 |
|---|---|---|---|---|
| **P0** | [B] | **Windows 上沒有內嵌預覽的 DNG 顯示不出來** —— 這是使用者原始需求，尚未修復 | 實作 R1：在 `native_thumbnail_service.dart` 已存在的 `case NativeImageFailure()` 分支中，對 `.dng` ＋ 內嵌預覽抽取落空的情況自行建構 `NativeImageNeedsRawDecode`，orientation 取自 `DngPreviewExtractor.readOrientationFromFile`（`dng_preview_extractor.dart:41`，目前無任何呼叫點）。約 10 行，全程可在 macOS 上單元測試 | plan §2 R1-AC1..AC5 逐條過 |
| **P0** | [B] | **Windows 上每個 RAW 檔的側欄縮圖是空白灰塊，且靜默失敗** | R2（側欄解碼上限）→ R3（側欄 DNG fallback）。R2 必須用 `ResizeImagePolicy.fit`，不可用 `Image.memory` 的 `cacheWidth`/`cacheHeight`（見 §9） | plan §2 R2/R3 |
| **P1** | [U] | 測量 M1：`DngPreviewExtractor` 掃一輪 41 格側欄的讀取位元組數 | 在此 macOS 上量，很便宜。commit 規則：<1s 且 <500MB → R3 照原樣出貨；否則 byte-range 改寫納入 R3 | 有數字。**這是 R3 唯一的閘** |
| **P1** | [D] | R4：`warmupForSize` ＋ `setPipelineCachePath` 在 composition root 接線 | 這兩個 API 存在、適用於 Windows 的 Vulkan 建置，`lib/` 與 `test/` 呼叫點皆為 **0**。R2 交接文件為此編列了一整輪上游工作，但 Dart 側就是 `main.dart` 一行 | 有呼叫點且冷啟數字有改善 |
| **P2** | [D] | Windows 冷啟首次解碼實際毫秒數 vs 1 秒天花板 | 只有使用者的 Windows 機器量得到。無法用「先解小張」緩解，該 API 不存在（PL-10） | 有數字 |
| **P2** | [U] | EXIF 修復從未編譯（`/W4 /WX`，任何警告即硬失敗） | 照 `windows-export-exif-verification.md` 的 C1–C7 在 Windows 上驗 | C1–C7 全過 |
| **P3** | [D] | Parking lot 11 項 | 見契約 §Parking lot | — |

## 9. 嘗試、裁決與禁止重踩

| 嘗試／方案 | 結果 | 裁決理由 | 可否重試 |
|---|---|---|---|
| 依 `CLAUDE.md`／Dart 註解描述 Windows 原生能力 | 前提整段錯誤 | 兩份散文都落後於程式碼 | **否** —— 讀 `windows/runner/*.cpp` |
| take A 的側欄修法（加 `cacheWidth`/`cacheHeight`） | 會讓每張非正方形縮圖變形 | `resizeIfNeeded` 建構 `ResizeImage` 不帶 policy，預設 `ResizeImagePolicy.exact` 無視長寬比（`image_provider.dart:1266`）。**且會通過尺寸斷言** | 否 —— 用 `ResizeImagePolicy.fit` |
| 刪掉 `DngPreviewExtractor.swift`（348 行） | 提案者自行撤回 | 在編不了該平台的機器上花驗證預算，去修一個今天不存在的失敗 | 需先量 macOS 路徑成本 |
| 候選方案 B（盲寫 WIC C++ 取得 orientation） | 不採用 | 約 40 行不可驗證的 C++ 只為拿一個整數，Dart 免費就能拿到 | 否 |
| 自動化 Halide sha256 的「二次驗證」 | 不採用 | 同機同腳本再下載一次只會重導出同一個 TOFU 值，看似驗證實則什麼都沒證明 | 否 |

## 10. 未來方向（不阻塞）

見契約 §Parking lot PL-1..PL-11。觸發條件都已寫在各列，未達條件前為 YAGNI。

## 11. 已知限制與不確定性

- **`build_apps.py` 的 native CMake 路徑從未執行過**。所有 Windows-only 分支（vcvars 自舉、registry 刷新、vulkaninfo、symlink 前置檢查、DLL 打包）都是推理加單元探針。**第一次在真 Windows 上跑要當首次接觸，不是回歸測試。**
- **Halide 的 sha256 是首次信任（TOFU），不是真 pin**。擋得住未來的 asset 替換，擋不住 2026-08-22 之前就已發生的替換。上游無 checksum／簽章檔（已查證）。升級方式見 PL-8。
- **EXIF 修復從未編譯**。`windows/CMakeLists.txt:42` 用 `/W4 /WX`，任何警告都是硬失敗。最糟的失敗模式是**匯出圖被轉兩次**，驗證協定的 C2+C3 專為抓它而寫。
- **顏色正確性已由使用者驗證完畢**（2026-08-22，在 Windows 機器上與 macOS 逐項比對）。這是已結案事項，不是待驗項，也不要在後續文件裡重新開啟。
- **1 秒天花板未量測，不是達標**。且無法用「先解小張」緩解 —— 那個 API 不存在（PL-10）。
- **需使用者決策**：P0 的 commit 切法、P1 的 Windows 驗證、P2 的 R1 是否開工、以及 parking lot 取捨。

## 12. 驗收命令

```bash
# 窄 → 寬
git log --oneline -1                    # a8ae038
git status --short | grep -v '^??'      # 應只有 §3 表列的 4 個
flutter analyze                          # No issues found! / exit 0
flutter test -j 1                        # +162: All tests passed! / exit 0（162 是硬數字）
python3 scripts/build_apps.py --check    # exit 0
lipo -info build/macos/Build/Products/Release/Halcyon.app/Contents/MacOS/Halcyon
                                         # 應為 arm64（非 fat）
```

## 13. 參考入口（≤5）

- 必讀：`docs/logs/2026-08-22/windows-port-review-contract.md` —— 契約、使用者三輪裁決、11 項 parking lot
- 必讀：`docs/logs/2026-08-22/thumbnail-dart-first-plan.md` —— R1–R4 四階計畫與逐階驗收
- 必讀：`docs/logs/2026-08-22/windows-export-exif-verification.md` —— Windows 上跑的 C1–C7 驗證協定
- 參考：`docs/logs/2026-08-22/windows-port-merge-instructions.md` —— merge 已執行完 §Step 1-3；§Step 4-5 尚未做
- 參考：五份 `review-*.md` 與兩份 `thumbnail-cross-platform-analysis-{a,b}.md` —— 逐條證據，非必讀
