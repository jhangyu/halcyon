## 實測效能

照片篩選的迴圈是「看、判斷、按下一張」：真正重要的數字是從按鍵到畫面上出現可用全解析度影像的時間，而不是抽象的解碼吞吐量。這一個數字背後藏著兩種完全不同的成本。含內嵌 JPEG 預覽的照片走便宜路徑——直接擷取並顯示預覽位元組，完全不做 RAW 解碼。沒有可用內嵌預覽的照片（多半來自手機的 bare-CFA DNG）則會落入透過姊妹專案 Ceyx 的完整 RAW 解碼，經由
`DngFullDecoder` 縫合處
（`lib/services/image_pipeline/dng_decode_contract.dart`）
<!-- evidence: lib/services/image_pipeline/dng_decode_contract.dart -->。第一層（tier-1，供即時顯示用的視窗解析度解碼）與第二層（tier-2，全尺寸解碼，於導覽靜止 250 毫秒後觸發，
`lib/services/image_pipeline/image_preload_controller.dart:49`
<!-- evidence: lib/services/image_pipeline/image_preload_controller.dart:49 -->）的成本也不同，所以一個沒有說明是哪一層、哪一條路徑、以及是冷啟動還是暖啟動量測出來的數字，是無法互相比較的數字。

### 已記錄的量測結果

| 路徑／階段 | 數值 | 條件 | 來源 |
|---|---|---|---|
| 完整 RAW 解碼，端到端，第二層（tier-2）上屏（4080×3056 bare-CFA DNG，6 檔沙箱化執行） | 冷啟動 491–601 毫秒；暖啟動 150–159 毫秒 | macOS，**release** `.app` 建置，沙箱化，2026-08-17，未記錄機型 | `docs/logs/2026-08-17/round-3b-reintegration-handover.md:27` <!-- evidence: docs/logs/2026-08-17/round-3b-reintegration-handover.md:27 --> |
| 同一次執行，`rawDecode.ready` 區間，9 個事件 | 61–406 毫秒 | 條件同上 | `docs/logs/2026-08-17/round-3b-reintegration-handover.md:72` <!-- evidence: docs/logs/2026-08-17/round-3b-reintegration-handover.md:72 --> |
| 側欄縮圖用途（200 px）解碼，bare-CFA DNG，無內嵌預覽的回退路徑，13 個樣本 | 暖啟動中位數每樣本 55.6–100.2 毫秒 | 在 `flutter test`（`flutter_tester`，非 release app 建置）下執行，多次程序內重跑的暖啟動中位數，目標長邊 200 px | `tool/m6_dng_gate/verdict_dng_extract.py:41-73` <!-- evidence: tool/m6_dng_gate/verdict_dng_extract.py:41 -->，方法見 `tool/m6_dng_gate/g3_sidebar_bench.dart:42` <!-- evidence: tool/m6_dng_gate/g3_sidebar_bench.dart:42 --> |
| 同一閘門，含可用內嵌預覽的 DNG（快速路徑，無 RAW 解碼），12 個樣本 | 暖啟動中位數 0.30–0.40 毫秒 | 沿用上列同一套量測工具 | `tool/m6_dng_gate/verdict_dng_extract.py:41-73` <!-- evidence: tool/m6_dng_gate/verdict_dng_extract.py:41 --> |
| 同一閘門，JPEG 樣本，7 個檔案 | 暖啟動中位數 22.4–25.9 毫秒 | 沿用上列同一套量測工具 | `tool/m6_dng_gate/verdict_dng_extract.py:41-73` <!-- evidence: tool/m6_dng_gate/verdict_dng_extract.py:41 --> |
| Ceyx：端到端 24 MP DNG，無損 | ~177 毫秒 | macOS（Metal），2026-07-05，未記錄機型 | ceyx `README.md:403` <!-- evidence: /Users/jhangyu/project/ceyx/README.md:403 --> |
| Ceyx：端到端 24 MP DNG，有損 | ~105 毫秒 | macOS（Metal），2026-07-05，未記錄機型 | ceyx `README.md:404` <!-- evidence: /Users/jhangyu/project/ceyx/README.md:404 --> |
| Ceyx：GUI app 內的冷啟動首次解碼，6000×4000 無損 DNG | 291 毫秒 | Apple M3 Ultra，macOS 15.6.1，release 建置，2026-08-26，明確為**冷啟動**，與上列暖啟動數字不可比較 | ceyx `README.md:410-413` <!-- evidence: /Users/jhangyu/project/ceyx/README.md:410 --> |
| Halcyon JPEG 預覽切換延遲（無 RAW 解碼） | 2.8 毫秒（優化前為 127.5 毫秒） | 歷史基準值，memory 標記 `image-switch-latency-round2-shipped`；架構已被取代，保留僅為呈現優化幅度的參考 | `docs/logs/2026-08-22/thumbnail-dart-first-plan.md:229` <!-- evidence: docs/logs/2026-08-22/thumbnail-dart-first-plan.md:229 --> |

上表中的 4080×3056 樣本是來自本專案自有樣本庫（`local_data/photo_samples/`）的手機相機
bare-CFA DNG，並非棚拍／全片幅 RAW；找到的所有記錄中，沒有任何一筆是在 Halcyon 自身的
app 殼層內量測解析度高於 24 MP 的樣本（Ceyx 自己的量測用了 24 MP 與 6000×4000 的樣本，
但那些數字只是 Ceyx 自身的執行結果，不是 Halcyon 的 app 管線）。

### 未測量的項目

- 沒有任何記錄顯示目前仍在出貨的完整 RAW 解碼路徑（Ceyx 的靜態連結建置，2026-08-17 之後）
  在解除 libjpeg 沙箱阻斷後有被重新量測過——上表的 61–406 毫秒／冷啟動 491–601、暖啟動
  150–159 毫秒那一列，本身就是修復驗證的執行結果，同一份文件也標記需要在解碼器端的樹不再
  變動後重新執行一次
  （`docs/logs/2026-08-17/round-3b-reintegration-handover.md:29`）
  <!-- evidence: docs/logs/2026-08-17/round-3b-reintegration-handover.md:29 -->；未找到後續
  重新執行的記錄。
- 上表 Halcyon 端的任何一列都沒有記錄機型（晶片、記憶體）。Ceyx 自己的 README 對其 macOS
  數字也有同樣的缺口，除了那一筆 M3 Ultra 的資料點。
- 沒有任何記錄量測大片幅（例如全片幅、40+ MP）RAW 檔案在 Halcyon 自身管線中的全尺寸解碼
  延遲；Ceyx 的 README 另外提到了特定格式的離群值（Fujifilm X-T5 40 MP RAF、Foveon X3F），
  但這些沒有在 Halcyon 內重新量測。
- 由 UI 驅動的切換延遲與記憶體（RSS）量測明確保留給專案擁有者親自執行，不開放給 agent
  （`lib/perf/perf_driver.dart:1-6`）
  <!-- evidence: lib/perf/perf_driver.dart:1 -->，所以本節即使該量測工具存在，也無法針對這項
  回報目前的數字。
- 匯出路徑的計時（解碼 → 縮放 → 重新編碼為 JPEG q90，
  `lib/services/library/photo_export_service.dart`）沒有任何記錄可查：**TBD（未量測）**。

### 該引用哪個數字

若只能給一個數字，答案是 **GPU 加速完整 RAW 解碼在冷啟動下約 300 毫秒**。這個數字來自
一次實際記錄的執行，而不是為了方便而挑選的範圍：Ceyx 在 GUI 應用程式內冷啟動首次解碼一張
6000×4000 無損 DNG，量得 291 毫秒，機器為 Apple M3 Ultra、macOS 15.6.1、release 建置、
2026-08-26。
<!-- evidence: /Users/jhangyu/project/ceyx/README.md:410 -->

上表其餘數字回答的是不同的問題，而這個區別值得記住：

- **暖啟動大約是它的一半。** 唯一一次完整到達第二層上屏、涵蓋 Halcyon 端到端流程的執行，
  暖啟動量得 150–159 毫秒；Ceyx 的暖啟動矩陣在 24 MP 下量得 105–177 毫秒。攝影師在少數
  幾張照片之間來回移動時，落在的是暖啟動這一區，不是冷啟動。
- **Halcyon 端的冷啟動量到比 300 毫秒更高**——2026-08-17 那次執行量得 491–601 毫秒，
  且未記錄機型。該次執行所屬的文件本身就註明需要在解碼端的樹穩定後重跑，而後續並不存在
  重跑紀錄，因此它是上表中證據力最弱的一列，而不是對 300 毫秒這個數字的反證。
- **大多數檔案根本不會進入解碼。** 帶有可用內嵌 JPEG 預覽的 RAW 完全跳過解碼器，落在
  個位數毫秒。300 毫秒描述的是昂貴路徑，而在一般資料夾裡那是少數檔案。

誠實的總結：把 300 毫秒當作指名機型下的冷啟動完整解碼數字來引用，暖啟動約 150 毫秒，
並且不要把任何一個當成通用基準——現有記錄都無法在跨機型、跨感光元件尺寸的條件下，
把冷啟動與暖啟動乾淨地分離開來。

### 如何重現這些數字

- `lib/perf/perf_driver.dart` 與 `lib/perf/perf_log.dart` 是 app 自身的量測工具：由
  `HALCYON_PERF_DIR` 環境變數啟用（未設定時在結構上是空操作，
  `lib/perf/perf_log.dart:38`）<!-- evidence: lib/perf/perf_log.dart:38 -->，它會驅動 app
  逐張切換照片，並寫下 `PERF|<us>|<name>|key=value` 格式的紀錄，其中包含完整 RAW 解碼的
  `rawDecode.ready|...|dur=` 事件
  （`lib/perf/perf_driver.dart:19-24`）<!-- evidence: lib/perf/perf_driver.dart:19 -->。
  依同一檔案標頭所述，此量測工具保留給專案擁有者親自執行，不開放給自動化或 agent 執行。
- `tool/m6_dng_gate/` 是一個已納入版本控管、可重複執行的閘門，用於側欄縮圖解碼路徑：
  `bash tool/m6_dng_gate/run_gate.sh <sample-dir> <out-file>`，接著執行
  `python3 tool/m6_dng_gate/verdict_dng_extract.py <out-file>`
  （`tool/m6_dng_gate/README.md:32-37`）<!-- evidence: tool/m6_dng_gate/README.md:32 -->。
  需要本地樣本庫（`local_data/photo_samples/`，未納入版本控管）與已 vendor 的 Ceyx 原生
  動態函式庫；它會在寫下任何數字之前，先記錄 git commit、工作樹狀態，並對該動態函式庫做
  符號檢查，目的正是為了避免量測到一個不含受測程式碼的二進位檔
  （`tool/m6_dng_gate/README.md:69-86`）
  <!-- evidence: tool/m6_dng_gate/README.md:69 -->。
- `python3 native/tests/run_decode_matrix.py --repeat 3` 可在 Ceyx 專案的儲存庫中重現 Ceyx
  自身的暖啟動量測矩陣數字
  （`/Users/jhangyu/project/ceyx/README.md:391-393`）
  <!-- evidence: /Users/jhangyu/project/ceyx/README.md:391 -->。
