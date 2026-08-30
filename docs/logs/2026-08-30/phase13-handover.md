# Phase 13 交接檔 — RAW payload 重編碼（一緩衝區、原生 libjpeg-turbo）＋ 清理輪 ＋ ceyx v0.1.4 釋出

日期：2026-08-30。撰寫時 ceyx v0.1.4 四平台 CI 仍在跑（見「未完成」節）。
計畫：`docs/logs/2026-08-30/plan-payload-reencode.md`（spec 同目錄）。AD 記錄：`docs/sop/memory.md` AD-040。

## 終態（已達成）

無預覽 RAW 經一次 FFI 解碼後，全解析度像素以 ceyx 原生 libjpeg-turbo 重編碼為 q80 JPEG，
以單一 `EncodedPayload` 發佈一次（publish-once），tier-1/tier-2 與 JPG 同路徑；
tier-2 重建不再需要第二次 FFI 解碼（TC-366，含紅燈證明）。編碼失敗一律退回 `PixelPayload`（維持 Phase 13 前行為）。

## 使用者裁決（依時序）

1. **一緩衝區**（否決 two-buffer `fullSizeBytes` 設計）；q80 出貨。
2. Task 0 閘門觸發（純 Dart encodeJpg q80 全幅中位數 4102ms > 500ms）→ **STOP**。
3. 裁決：**libjpeg-turbo 為主路徑**（CLI 實測 62ms vs libwebp 2876ms）；**libwebp 也編入 ceyx**（能力對齊，不擋主線）。
4. 授權：清 parking-lot 1+2+3+5（sonnet）、ceyx 釋出＋pin 更新（opus）、寫本交接檔。

## Commits

### Halcyon（main，未推送）
| hash | 內容 |
|---|---|
| aeff7b4 / b244eec | Task 0 預註冊量測（STOP 判定證據） |
| fc514b3 | Task 0b CLI 編碼器比較（cjpeg 62ms / cwebp 2876ms） |
| 595c5ff | 程序內原生編碼重測：q80 中位數 89ms PASS（`native-encode-inprocess.txt`） |
| ee8725f | Task 1：共用 isolate JPEG 編碼器抽取（TC-360） |
| 89ee22c | Task 2：`payload_reencoder.dart` 降級階梯（TC-361..363） |
| 7da596b | Task 3：PhotoSource 兩解碼路徑接編碼 seam（TC-364/364b/365） |
| 41e8424 | Task 4：控制器整合、piggyback guard 放寬、tier-2 免二次 FFI（TC-366/367＋紅燈 artifact） |
| e121647 | Task 5：AD-040 修正註記＋baton-2 |
| 624df21 | 清理輪：rgba 長度守門（TC-368）＋TC-366 解析度斷言強化 |
| （待落地） | ceyx v0.1.4 pin 重釘（release 成員完成後，本地 commit、不推送） |

### ceyx（main，**已推送** github.com/jhangyu/ceyx，tag v0.1.4 已上）
| hash | 內容 |
|---|---|
| 1764a8f | C ABI encode FFI：`ceyx_encode_{jpeg_rgba8,webp_rgba8,free,error_name}`，vendored 靜態 libwebp 1.6.0（pinned dist＋PROVENANCE），harness 8/8 |
| 04aa709 | Dart 綁定：`plugin/lib/src/encode_bindings.dart` / `encode_service.dart`（`CeyxEncodeService.encodeJpegNative/encodeWebpNative`） |
| fd18306 | volatile row_scratch across setjmp；移除死的長度 out-param |
| f2bf987 | **FFI_EXPORT 補上四個 encode 符號**（Windows DLL 匯出缺陷，release 成員審查攔獲） |
| bfd4c43 | CI 符號存在閘門（linux/windows workflow；先於 v0.1.3 舊資產驗證會亮紅） |
| 0be87d6 | plugin 版本 bump 0.1.4 |

## 關鍵架構事實（後續 session 必知）

- 生產編碼器綁定：`image_preload_controller.dart` 預設 `PayloadEncoder` = `_encodeJpegNative` → `CeyxEncodeService().encodeJpegNative`（ceyx plugin）。純 Dart `encodeJpegFromRgba`（`jpeg_encoder.dart`）只服務 sidebar codec 與測試。
- **Halcyon 依賴是 `ceyx: path: ../ceyx/plugin`**。任何 `dng_processor` / `../flutter_dng_decoder` 字樣都是 2026-08-26 改名前遺跡（CLAUDE.md 本地已修，該檔在此 repo 為 gitignored）。
- 凍結決策全數未動：AD-010/011（NativeImageResult 三變體）、D4（cache 不認 payload 子類）、AD-033/034（lane/窗口）、AD-027/028（registry 容器）。tier_two_registry 本來就是 SourcePayload 型別，僅 scheduler 參數放寬。
- 計畫的 TC-366 導航腳本 0→9→0 **不可滿足**（index 9 連 retention 都逐出 payload）；出貨測試用 0→3→0（僅逐出 tier-2），理由在測試檔頭註解。
- docs/sop/ 與 CLAUDE.md 在 Halcyon 均為 gitignored（repo 慣例：本地維護）；AD-040、TC-360..368 矩陣列已寫入本地檔。
- 全套件驗證方式：`flutter test -j 1` 全套超過前景 timeout → 枚舉 57+ 測試檔分批跑、逐批自捕 RC、檔數對帳（artifacts `tmp/verify/task3-*`、`cleanup-*`）。

## 未完成 →（後記 2026-08-30：全數完成）

1. ceyx v0.1.4 **四平台 CI 全綠**（Windows 首次接觸一次過，含新 AC-W4 匯出閘門）。資產獨立驗證：Linux `nm -D` 四符號＋符號位址與 CI log 逐位元組一致；Windows 以 PE export directory 解析（非 strings），並以 v0.1.3 舊 DLL 做負對照——差集恰為四個 encode 符號。
2. Halcyon pin 重釘完成：commit `22cb75b`（僅 `scripts/ceyx_release_pin.json`，digest 與手算逐位元組相符，**本地未推送**）。
3. 誠實界定：Windows/Linux 的證據＝CI 閘門綠＋資產符號檢驗；未在任何機器上實際呼叫過那兩平台的 runtime encode。

## Parking lot（無人排程，僅記錄）

- **Halcyon 本地 main 領先 origin/main 23 個 commit**——一次 `git push` 會全部發佈，需使用者刻意決定（本輪任何成員都未推 Halcyon）。
- `scripts/ceyx_release_pin.json` 的 `_comment` 散文仍說 digest 來自 v0.1.1（機讀欄位正確，散文過時）。

- `heif_ffi_api.cpp` 有與 encode 相同的缺 FFI_EXPORT 問題（Windows 因 HEIF=OFF 未爆；新 CI 閘門不涵蓋它）。
- 每次 RAW 編碼重新 spawn isolate 探測可用性（reviewer nit，效能型，需量測後再議）。
- combined-memory 重量測：等 parallel-decode-lane（`plan-parallel-decode-lane.md`，另一 worktree `Halcyon-decode-lane` 進行中）落地後，app 側備妥情境、**使用者親量 RSS/UI**（本專案鐵律：agent 不量 UI/RSS）。
- 已知限制：v0.1.4 Windows/Linux 的 WebP 編碼符號存在但回 `kCeyxEncodeErrUnsupported`（無 libwebp dist，設計性降級，release notes 已記）。

## 白話總結（給未跟完整過程的讀者）

**這輪解決的問題**：某些 RAW 照片檔裡沒有內嵌的預覽圖，每次要看它都得重新做一次很貴的「原始感光資料→圖像」轉換。這輪改成：轉換一次之後，立刻把結果壓成一張普通的 JPEG 留在記憶體裡，之後不管怎麼翻頁、放大，都直接用這張 JPEG——跟瀏覽一般 JPG 檔完全同一條路、同樣快。

**過程中的轉折**：原本打算用 Dart 內建的圖片函式庫來壓 JPEG，但開工前的實測閘門（先寫好「超過 0.5 秒就停工」的規則再量）量出來要 4.1 秒，直接停工回報。改用電腦上原生的專業壓縮庫 libjpeg-turbo 後只要 0.089 秒，快了約 46 倍，於是把這個壓縮功能做進共用的原生解碼引擎（ceyx）。使用者同時裁決：另一種壓縮格式 WebP 也一併做進引擎備用（實測較慢，不當主路徑）。

**過程中攔到的最大隱患**：新寫的壓縮功能在 Mac 上測試全綠，但審查發現它的函式名單漏了「對外公開」的標記——在 Windows 上編出來的程式庫會找不到這些函式，等於功能出貨即壞，而且只有 Windows 使用者會發現。出貨前補上了標記，並在自動建置流程加了一道「檢查函式名單真的公開了沒」的關卡，讓同類問題以後在建置階段就會被擋下。最後發佈了引擎的新版本（v0.1.4），四個平台的自動建置全部通過。

## Parking lot 前因後果（白話，各項為何存在、不處理會怎樣）

1. **本機的主分支比雲端多了約 24 筆未發佈的修改。** 前因：本輪所有 Halcyon 修改都只提交在本機，沒有推上雲端（規則就是不推，發佈要人來決定）。後果：哪天隨手一個「推送」就會把 24 筆改動一口氣全部公開，其中可能混有還沒想公開的東西——所以這必須是一個有意識的決定，不能順手做。
2. **HEIF 圖片模組有同一種「忘記公開函式」的病。** 前因：這次抓到壓縮功能漏標記後，回頭掃描發現處理 HEIF 格式的舊模組也一樣漏了。後果：目前沒事，因為 Windows 版本根本沒開 HEIF 功能；但哪天有人把它打開，就會原封不動重演這次的問題，而新加的檢查關卡管不到它。
3. **每壓一張圖就重新開一個工作執行緒去確認「壓縮功能在不在」。** 前因：實作圖省事，每次都重新探測一遍。後果：只是浪費一點點效能，不影響正確性；要不要改，得先量測證明它真的慢才值得動。
4. **記憶體用量的「理論估算」還沒被實際量測取代。** 前因：多張照片同時解碼＋壓縮時的記憶體峰值，目前是用乘法算出來的數字；使用者裁定等另一個功能（可調並行解碼）完成後，由使用者本人跑一次真實情境來量。後果：在那之前，文件裡的峰值數字只是算術，不能當成量過的結果引用。
5. **版本鎖定檔裡的說明文字過期了。** 前因：鎖定檔記錄「該抓哪個版本的引擎、檔案指紋是多少」，機器讀的欄位每次都更新，但人類讀的註解文字停在兩個版本前。後果：機器運作完全正常，只是人看註解會被誤導；順手修一行就好。
6. **Windows/Linux 上的壓縮功能「存在但沒實際跑過」。** 前因：這台 Mac 無法執行 Windows/Linux 程式，證據止於「建置通過＋檔案裡確實有這些函式」。後果：理論上仍可能有只在那兩個平台才會發作的執行期問題；第一個在那些平台實際用到壓縮的人，就是第一次真實測試。

## 驗活命令

```bash
# 原生編碼鏈路（macOS）
cd /Users/jhangyu/project/ceyx && ./native/build/ceyx_encode_harness   # 8/8 PASS
# Halcyon 重編碼測試
cd /Users/jhangyu/project/Halcyon && flutter test -j 1 \
  test/services/image_pipeline/payload_reencoder_test.dart \
  test/services/image_pipeline/image_preload_reencode_tier_two_test.dart
```
