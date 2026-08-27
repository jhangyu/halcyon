# SOP updates — machine-adaptive payload retention（2026-08-28，deferred apply）

`docs/sop/` 在本 worktree 為 gitignored 且不存在（正典副本只在主樹 `/Users/jhangyu/project/Halcyon/docs/sop/`）。依 lead 裁決（option c，deferred apply），本檔承載「準備好可貼上」的內容，由 lead 於 merge 時套入正典 `docs/sop/unit_test.md` 與 `docs/sop/memory.md`。本檔隨 Task 5 提交入版控，取代 plan Step 5.8 pathspec 中的 `docs/sop/*`。

---

## 一、貼入 `docs/sop/unit_test.md`（測試矩陣新列，沿用該檔 `欄位 | 內容` 區塊格式）

### TC-310…TC-314｜DeviceMemory 平台通道包裝：null / 正值 / 錯誤路徑（2026-08-28，adaptive-retention Task 1）

| 欄位 | 內容 |
|------|------|
| **測試檔** | `test/services/platform/device_memory_test.dart` |
| **測試 ID** | TC-310（無平台 handler → `null`，不 throw）／TC-311（正值 `17179869184` 原樣回傳）／TC-312（`null` 回覆 → `null`）／TC-313（非正值 `0` 視為缺席 → `null`）／TC-314（`PlatformException` → `null`，不 throw） |
| **背景** | `DeviceMemory.totalPhysicalBytes()` 經 `MethodChannel('halcyon/device_memory')` 讀機器總實體記憶體。C-3 禁止 `lib/` 出現 `Platform.isX`，`dart:io` 又無平台中立的總記憶體 API（`ProcessInfo` 只有 RSS），因此唯一 C-3 安全來源是通道；缺讀數（每個非 macOS 平台與所有未裝 handler 的單元測試）一律回 `null`，消費端讀作「用 floor 尺寸」＝今日行為。非正值視為壞平台而非小機器，不得餵給尺寸階梯。 |
| **測試類型** | `TestWidgetsFlutterBinding` + `setMockMethodCallHandler`，無真實平台 |
| **通過門檻** | 5/5 綠 |
| **狀態** | ✅ 已通過（Task 1，commit de917e8） |

### TC-315…TC-317｜retentionPolicyFor 尺寸階梯：三階與不變式（2026-08-28，adaptive-retention Task 3）

| 欄位 | 內容 |
|------|------|
| **測試檔** | `test/services/image_pipeline/retention_policy_test.dart` |
| **測試 ID** | TC-315（`null` / `1 GiB` / `11 GiB` 皆得 `RetentionPolicy.floor()`，且 floor 即出貨常數 `kRetentionBefore`/`kRetentionAfter`/`kPayloadByteBudget`，非第二份複本）／TC-316（mid 於 `>= 12 GiB` 觸發＝`(3, 8, 318767104)`；high 於 `>= 32 GiB` 觸發＝`(3, 11, 402653184)`）／TC-317（每階不變式：`payloadByteBudget >= (slots × 22.4 MiB).ceil()` 且 `<= trigger ~/ 32`；`after` 序列 `[5,8,11]`；預算隨 slots 成長） |
| **背景** | 純函式，無 I/O。`before` 每階恆為 3（回看是罕見方向，往後加寬每位元組買到最少）。各階預算＝`slots × 22.4 MiB × 1.11` 進位到整 MiB（`photo_payload_cache.dart:19-30` 既有推導）。 |
| **測試類型** | 純單元測試 `test()`，無 binding |
| **通過門檻** | 3/3 綠 |
| **狀態** | ✅ 已通過（Task 3，commit a39af4b） |

### TC-318、TC-319｜保留視窗改由注入 policy 決定（2026-08-28，adaptive-retention Task 4）

| 欄位 | 內容 |
|------|------|
| **測試檔** | `test/services/image_pipeline/image_preload_window_test.dart` |
| **測試 ID** | TC-318（以 mid-rung `(3, 8, 318767104)` 建構的控制器導航後填滿至 `+8` 並持有 payload，`+9` 永不保留）／TC-319（不帶 `retention` 參數的預設控制器 `retention == RetentionPolicy.floor()`，視窗仍為出貨 `-3..+5`，不越過 `+5`） |
| **背景** | `ImagePreloadController` 新增 `RetentionPolicy retention = const RetentionPolicy.floor()`，三個視窗點（保留掃描、near-to-far span、tier-1 precache span）改讀 `retention.before/after`，`_cache` 以 `retention.payloadByteBudget` 建構。預設 floor 使 ~20 個既有建構點與 `AppState` 行為不變。 |
| **測試類型** | 控制器整合測試，沿用檔內既有 helper（`rawItems`/`cheapController`/`fakeDecoded`/`_until`/`payloadFor`/`controllerWindowFilled`） |
| **通過門檻** | 該檔 11/11 綠 |
| **狀態** | ✅ 已通過（Task 4，commit 1011709）。`flutter test test/services/image_pipeline/ -j 1`：261 綠 RC=0 |

### TC-320｜configureImageCache 由讀數推導 ImageCache 預算（2026-08-28，adaptive-retention Task 5）

| 欄位 | 內容 |
|------|------|
| **測試檔** | `test/main_test.dart` |
| **測試 ID** | TC-320（`configureImageCache(physicalMemoryBytes: 2 GiB)` → `maximumSizeBytes == 536870912`（2 GiB / 4 = 512 MiB，高於 256 MiB 下限）；`configureImageCache()` 無參數 → `805306368`（768 MiB 天花板不變）） |
| **背景** | `configureImageCache` 參數改為選用 `{int? physicalMemoryBytes}`，餵給既有 `imageCacheBudgetBytes` seam。既有無參呼叫（`test/main_test.dart` 原案）不變。行為變更：帶真實讀數的 `< 3 GiB` 小機器 ImageCache 由原本無條件 768 MiB 降為 512/256 MiB。 |
| **測試類型** | `testWidgets` |
| **通過門檻** | `test/main_test.dart` 6/6 綠 |
| **狀態** | ✅ 已通過（Task 5）。`flutter test -j 1` 全套 420 綠 RC=0 |

---

## 二、貼入 `docs/sop/memory.md`（新增一條 AD，接續 AD-034 之後，編號 AD-035）

### AD-035｜機器自適應保留：總實體記憶體經 `halcyon/device_memory` 通道讀入，三階位元組階梯設定保留視窗與 ImageCache（2026-08-28，adaptive-payload-retention 契約）

- **背景**：保留視窗（`-3..+5`）、payload 位元組預算（224 MiB）、Flutter `ImageCache` 天花板（768 MiB）過去皆為編譯期常數，不看機器實際 RAM。大機器留了餘裕沒用，`< 3 GiB` 小機器則被無條件 768 MiB 壓迫。
- **決策一：讀數走通道，Dart 端不命名平台**。新增 `DeviceMemory.totalPhysicalBytes()`（`lib/services/platform/device_memory.dart`）經 `MethodChannel('halcyon/device_memory')` 取機器總實體記憶體。理由：C-3 禁止 `lib/` 出現 `Platform.isX`/`kIsWeb`/`defaultTargetPlatform`，而 `dart:io` 沒有平台中立的總記憶體 API（`ProcessInfo.currentRss` 是本行程 RSS，不是機器 RAM）——唯一 C-3 安全來源就是通道：檔案本身不命名平台，「哪個平台回答」由哪個 runner 註冊了 handler 決定。macOS 端 handler 在 `AppDelegate.swift` 回 `Int(ProcessInfo.processInfo.physicalMemory)`（pull-only，通道物件只作區域變數）。
- **決策二：只有 macOS 有真實讀數，其餘一律落回 floor**。所有非 macOS 平台觸發 `MissingPluginException` → `null` → floor；`null` 回覆與非正值讀數（壞平台，非小機器）同樣視為缺席。因此每個沒有讀數的平台 byte-for-byte 維持本功能存在前的行為。永不偽造讀數。
- **決策三：階梯是位元組算術，不是 UI 量測**。`retentionPolicyFor`（`lib/services/image_pipeline/retention_policy.dart`）純函式三階：`null` 或 `< 12 GiB` → floor `(3, 5, 234881024)`；`>= 12 GiB` → mid `(3, 8, 318767104)`；`>= 32 GiB` → high `(3, 11, 402653184)`。`before` 每階恆為 3（回看罕見，往後加寬每位元組買到最少）。各階預算＝`slots × 22.4 MiB × 1.11` 進位整 MiB（沿 `photo_payload_cache.dart:19-30` 既有推導）。`RetentionPolicy.floor()` 引用既有常數而非重打數字，兩者不會漂移。**這些階深是位元組算術而非 UI 量測——本專案 UI 量測是使用者的事——刻意保守（最多常駐 384 MiB `Uint8List`），預期由使用者調校（直接改這些數字）。**
- **決策四：一次讀取，注入到底**。`main()` 改 async，`ensureInitialized()` 後 await 一次 `DeviceMemory.totalPhysicalBytes()`，把讀數同時餵給 `configureImageCache(physicalMemoryBytes:)` 與 `retentionPolicyFor(physicalMemoryBytes:)`，policy 沿 `AppState → ImagePreloadController → PhotoPayloadCache` 注入。await 必須在 `runApp` 之前——fire-and-forget 會與 `AppState` 建構競速而靜默出貨 floor policy。啟動印一行 `debugPrint('startup.memory|bytes=<n or null>|policy=<policy>')` 作機制自證（活體證明：`bytes=` 對得上 `sysctl -n hw.memsize`）。
- **代價（已接受）**：帶真實讀數的 `< 3 GiB` 機器，ImageCache 由原本無條件 768 MiB 降為 512/256 MiB。此為 spec risk 2 明列並接受的唯一行為變更。
- **perf 戳記校正**：`PerfLog.init` 新增 `payloadByteBudget` 參數，`PerfDriver` 傳 `state.retentionPolicy.payloadByteBudget`，使 build stamp 報告實際生效機器的預算而非編譯期常數；log 欄位名 `kPayloadByteBudget` 為下游解析器穩定契約故保留不改，只有其「值」變成生效值。
- **關聯**：AD-033/AD-034（保留與 tier-2 視窗政策，本條只是讓 `before`/`after`/預算由 policy 而非常數提供，視窗語意不變）；`NativeImageResult` 三變體（AD-010/AD-011）不動；macOS 原生僅新增第三個 channel，`halcyon/trash`/`halcyon/open_with` 不動。
