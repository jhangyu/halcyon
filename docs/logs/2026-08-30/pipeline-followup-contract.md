# 收斂契約：影像管線三題（2026-08-30）

## 終態一句話
tier-2 全尺寸升級在停留 >250ms 後可觀察地生效；macOS 上 lane ceiling 依真實 RAM/CPU 算出（本機應為 5）；共享 encode payload 快取的架構規劃檔落地供使用者決策。

## In-scope 交付物
- D1（debug→fix 串行鏈）：找出「導覽停留 >1000ms 後主預覽仍是視窗解析度」的根因（opus debugger），修復（sonnet fixer），附紅→綠證據。
- D2（sonnet fixer）：（使用者 2026-08-30 修訂）改用跨平台方案取得實體記憶體（優先 pub 套件，否則單檔封裝的 FFI/條件式），取代 macOS-only channel；修後 `startup.memory` debug 行須顯示真實 bytes 與 laneCeiling=5（本機 28 核 / 256GiB）。Windows/Linux 實跑驗證因無主機列已知限制。
- D3（opus architect-reviewer）：規劃檔 `docs/logs/2026-08-30/shared-payload-cache-plan.md`——側欄縮圖與主預覽共用同一份全尺寸 decode→encode payload 的架構方案；內含 (a) agent 可執行的規格段、(b) ELI5 白話版前因後果、(c) mermaid 圖（現行雙解碼 vs 新架構）、(d) 需使用者決策的取捨清單。規劃檔只規劃，不動 lib/ 代碼。

## Out-of-scope
- 平行度上限「策略/數值」的變更（kCoresPerDecode、kDefaultDecodeLaneWidth、rung 門檻）——使用者保留決策權；D2 只修「讀不到記憶體」的 bug。
- D3 方案的實作。
- Windows 記憶體偵測（缺 handler，另案）。

## 驗收條件
1. D1：根因報告附 檔案:行號 與機械證據；修復後實跑 macOS app 或針對測試證明停留後 tier-2 provider 實際切換（紅→綠留證）。
2. D1：`flutter analyze` 0 issues；`flutter test` 全綠（exit code 於 artifact 內自捕 `RC=$?`）。
3. D2：修復後 macOS 實跑 `startup.memory|bytes=274877906944|...|laneCeiling=5`（活體證明，非推論）；analyze 0 issues、test 全綠。
4. D3：規劃檔存在且四節齊備（規格／ELI5／mermaid／決策清單）；mermaid 語法可渲染；不含對 lib/ 的任何 diff。
5. 新增測試登錄 unit_test.md；架構決策/gotcha 入 memory.md。

## 輪次預算
3 輪。用盡未過即停，回報失敗軌跡。

## 第二輪追加（使用者 2026-08-30 裁示）
- D4（sonnet fixer）：修復 `dng_embedded_jpeg_extractor.dart` 三缺陷（不走 nextIFD 鏈；只認 0x0111/0x0117 不認 0x0201/0x0202；Compression==7 過濾過嚴），使 Sony ARW 的 IFD2 全尺寸內嵌 JPEG 與 IFD0 PreviewImage 可被抽取。驗收：合成 TIFF fixture 紅→綠；真實 A7M5 ARW 讀取（唯讀）實抽成功；既有 DNG 測試不退化；analyze 0 issues、全套件綠；TC 入冊。
- D5（opus plan author，/writing-plans 兩階段格式）：全面改寫 `shared-payload-cache-plan.md`——新架構：所有項目全尺寸解碼→q70 重編碼→共享 payload 快取；側欄縮圖一律由共享 payload 派生；刪除 200px 專用解碼路（R2 實證無收益）；捲動亦填充 payload（實測 240-349 MiB @q80 在 384 MiB 內）。須處理「抽取器修復後內嵌 JPEG 當 payload 會達 402 MiB」的預算張力並給建議。

## 紅線
- 禁全樹 git 操作；commit 必帶 pathspec（git mv 列兩側）；不動在途隊友檔案。
- 不改 ~/.claude/ 制度檔、不改上限策略常數。
