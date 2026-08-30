# 交接 Plan — Windows HEIF 支援（libheif/libde265 散發包 → DLL 出貨 → FFI_EXPORT 修復）

狀態：**未排程**（parking lot 升級為交接計畫，2026-08-30）。工作全在 ceyx repo。
背景：`docs/logs/2026-08-30/phase13-handover.md` parking lot 第 2 項——Windows 目前以
`-DDNG_ENABLE_HEIF=OFF` 建置（`windows_build.yml:266` 註解：HEIC 路線只有 macOS 版散發包），
Linux/Android 同因關閉。`heif_ffi_api.cpp` 另有缺 `FFI_EXPORT` 的潛伏缺陷（grep 為 0），
目前無害純因功能未開。三步有嚴格順序：散發包不存在時，後兩步無意義。

## 既有事實（避免重查）

- 散發包由 `native/scripts/fetch_heif_deps.sh` 產生：libheif **1.23.2** + libde265 **1.1.1**
  （上游 tarball URL＋SHA-256 記錄在 `native/third_party/heif-dist/PROVENANCE.md`）。
- **刻意動態連結**：兩者皆 LGPL-3.0-or-later，以獨立共享庫動態載入滿足 LGPL-3 §4(d)(1)
  （使用者可自行替換該庫）。靜態連進 `libdng_decoder_native` 會觸發 §4(d)(0)
  「隨每次釋出提供可重連結目的檔」義務——**不要改成靜態**。
- 建置為 decode-only：`WITH_X265=OFF`（x265 是 GPL-2.0，不可誤開）、所有 encoder 關閉。
- `heif.cmake` 支援 arch 後綴散發包目錄（`heif-dist-<arch>`），Windows 沿用此機制即可。
- 同型前例可抄：encode 功能的 libwebp 靜態 dist（`fetch_libwebp_dist.sh`＋PROVENANCE）與
  macOS heif dist 的 fetch/hash 驗證模式；CI 符號閘門前例是 `AC-W4`/`AC-L5`（bfd4c43）。

## Step 1 — Windows 版 libheif/libde265 散發包

- 擴充 `fetch_heif_deps.sh`（或建 `fetch_heif_deps_windows.ps1`/CI job）：同版本、同
  decode-only flags，以 clang-cl 建出 `heif.dll` + `de265.dll`（含 import lib），
  寫入 `native/third_party/heif-dist-windows/`（沿用 arch/平台後綴慣例）。
- PROVENANCE.md 補 Windows 段：版本、hash、configure flags、LGPL 動態連結理由照抄現有段落。
- 驗收：dist 目錄含兩個 DLL＋import lib；dumpbin 確認 `heif_context_alloc`（或現行
  macOS dist 驗證用的符號）存在；hash 與上游 tarball 一致。

## Step 2 — DLL 隨附出貨

- `windows_build.yml`：Configure 拿掉 `-DDNG_ENABLE_HEIF=OFF`，heif.cmake 指向 Windows dist；
  staging/上傳步驟把兩個 DLL 與 `libdng_decoder_native.dll` **一起**放進 release 資產
  （動態依賴，缺一即載入失敗）。
- Halcyon 側 `build_apps.py` 的 fetch 邏輯與 pin 檔需認得多檔資產（目前每平台單檔）——
  這是跨 repo 影響面，動工前先盤點 `scripts/ceyx_release_pin.json` 的 assets 結構。
- LGPL 義務落地：release notes 註明兩庫版本與對應原始碼 tarball 出處（照 PROVENANCE 格式）。
- 驗收：Windows CI 綠；資產清單含三個 DLL；乾淨 Windows 環境（無系統 heif）能載入。

## Step 3 — 修 `heif_ffi_api.cpp` 缺 FFI_EXPORT

- 照 f2bf987 的樣式：定義同款 `FFI_EXPORT` 巨集（`__declspec(dllexport)` / visibility）
  套到全部 heif FFI 進入點。**在 Step 1/2 之前做也無害，但無法驗證**——只有 Windows
  真的編出 heif 路徑，dumpbin 才能證明匯出生效。
- 同時把 heif 符號加入 `AC-W4`/`AC-L5` 閘門（目前明確不涵蓋 heif；Linux 若同輪開啟也一併）。
- 驗收：CI 閘門對 heif 符號亮綠，且對 Step 1 之前的舊 DLL 亮紅（負對照，照 v0.1.3 前例）。

## 風險與提醒

- 08-28 教訓直接適用：新平台首次接觸必然逐層剝洋蔥，判準是「每輪失敗點是否前移」；
  guard 要寫在真前提（runner 沒有系統 libheif）而非動機平台。
- 別接受「關掉功能就轉綠」的捷徑——那正是現狀，本計畫的目的就是移除它。
- Android/Linux 的 HEIF 同樣關閉；本計畫完成後它們是自然的下一步（同 dist 機制、不同工具鏈）。
