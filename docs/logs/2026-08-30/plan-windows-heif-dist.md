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

## Step 4 — Windows 原生庫交付硬化（併入自 docs/sop/task.md parking lot，2026-08-30）

來源：win-sidebar-thumbnails 輪的 parking-lot 條目「Windows native library delivery hardening」。
兩項潛在交付風險，皆與側欄空白格症狀無關，但任何 Windows release milestone 前必須解決；
與本計畫同屬 DLL 出貨面，Step 2 動 `windows_build.yml`/staging 時一併處理最省。

- **單一項目的 bundled-libraries 清單**：`ceyx/plugin/windows/CMakeLists.txt:49-52` 把
  `ceyx_bundled_libraries` 設為單一 DLL，而 `ceyx/native/CMakeLists.txt:110-117` 預設動態
  連結 libheif/libde265——HEIF 開啟後（Step 2）同目錄少一個相依 DLL 就是載入期整體失敗。
  修法：清單由宣告端推導（08-28 教訓：手工重複清單改成同一變數同一檔案決定），Step 2 的
  「三個 DLL 一起進資產」即涵蓋。
  ※原 parking-lot 條目建議「靜態連結 HEIF 相依」——**已被本計畫的授權分析否決**（LGPL-3
  §4(d) 要求動態連結或提供可重連結目的檔，見「既有事實」節），正確方向是隨附 DLL＋載入閘門。
- **trust-on-first-use 的手工 DLL**：已提交的 `ceyx/plugin/windows/Libraries/dng_decoder_native.dll`
  是 2026-08-22 手動建置、未跑 S4 顏色閘門的產物，建置時被靜默優先於 pinned release。
  修法：以 pinned release 產物汰換之（或刪除讓 fetch 補位），並讓「本地已提交副本優先」
  變成 loud 行為而非靜默。
- **建置後載入閘門**：對實際建置出的 runner 目錄跑 `dumpbin /DEPENDENTS` 與 `/EXPORTS`
  （輸出**先存檔再比對**，見 08-28 pipefail 教訓），驗證全部相依 DLL 在場、必要符號已匯出；
  接上既有 `AC-W4`/`AC-L5` 閘門樣式。Step 3 的 heif 符號閘門與此同一機制。

- 驗收：乾淨 Windows 環境（無系統 heif/de265）安裝包可載入原生解碼；閘門對「缺相依 DLL」
  與「舊 TOFU DLL」兩種壞態均亮紅（負對照）。

## 風險與提醒

- 08-28 教訓直接適用：新平台首次接觸必然逐層剝洋蔥，判準是「每輪失敗點是否前移」；
  guard 要寫在真前提（runner 沒有系統 libheif）而非動機平台。
- 別接受「關掉功能就轉綠」的捷徑——那正是現狀，本計畫的目的就是移除它。
- Android/Linux 的 HEIF 同樣關閉；本計畫完成後它們是自然的下一步（同 dist 機制、不同工具鏈）。
