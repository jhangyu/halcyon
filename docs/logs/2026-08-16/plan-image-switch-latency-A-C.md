# 收斂契約：圖片切換延遲優化（方案 A + C）

凍結時間：2026-08-16。凍結後只有使用者能修改本契約。

## 終態（一句話）
圖片切換時預載窗口並行載入且當前張優先，macOS 原生端對 JPEG 的 preview 請求不再做全幅解碼＋重編碼，兩者合併回 main 且測試與建置全綠。

## In-scope 交付物
1. **方案 A（Dart squad）**：`lib/services/image_preload_controller.dart` 的 `preloadImages` 改為——當前張先 await（維持現有優先行為），窗口內其餘項目以並行方式發出（`Future.wait`），移除逐張串行 await 迴圈。保留 `_loadingKeys` 去重與現有窗口淘汰邏輯。新增測試證明並行性與當前張優先。
   - 檔案：`lib/services/image_preload_controller.dart`、`test/image_preload_controller_test.dart`
2. **方案 C（Native squad）**：`macos/Runner/AppDelegate.swift` 的 `getFastThumbnail`，purpose == "preview" 且副檔名為 jpg/jpeg（非 RAW）時，直接讀原檔 bytes 回傳，跳過 `createFullSizeImage` 全幅解碼與 JPEG 重編碼（Flutter `Image.memory` 會處理 EXIF 方向）。HEIC/PNG/RAW 路徑本輪不動。
   - 檔案：`macos/Runner/AppDelegate.swift`

## Out-of-scope（parking-lot）
- 方案 B（低清 fallback / 消滅 spinner 閃白）——使用者明確排除
- 方案 D（bytes 上限 LRU 快取）
- HEIC/PNG 的 preview 降採樣優化
- RW2/RAW 完整解碼優化
- Android 端 MethodChannel handler（`MainActivity.kt` 目前為空殼，已回報使用者）
- preview targetSize=10000 的調整

## 驗收條件（逐條過才算完成）
1. `preloadImages` 中窗口項目載入為並行發出：存在一個測試，以可控 completer 的 fake loader 證明「當前張最先被請求，且其餘窗口項目在任何一張完成前即已全部發出請求」，該測試綠。
2. 既有測試全綠：worktree 內 `flutter test` 全部通過。
3. `AppDelegate.swift` 中存在 JPEG preview passthrough 分支：preview + jpg/jpeg 時回傳原檔 bytes，不經 `createFullSizeImage`；非 JPEG 與非 preview 路徑行為不變（reviewer 以 diff 負空間題確認）。
4. `flutter build macos --debug` 在 native squad worktree 成功完成。
5. 合併回 main 後，於 main 重跑 `flutter test` 與 `flutter build macos --debug` 皆綠（post-merge gate，驗證輸出附所驗 HEAD hash）。

## 輪次預算
3 輪（預期 1 輪完成）。預算用盡而驗收未全過 → 停止並回報失敗軌跡。

## 基線
main @ af2e73f（rename + trash channel checkpoint commit 之後）。

## Squad 配置
| Squad | 範圍 | 成員 | 工作樹 |
|---|---|---|---|
| preload（方案 A） | 上列 Dart 兩檔 | preload-lead-opus / preload-impl-1-sonnet / preload-test-haiku | 共用主樹 `/Users/jhangyu/project/Halcyon` @ main（使用者指示，單 session 動工） |
| native（方案 C） | AppDelegate.swift | native-lead-opus / native-impl-1-sonnet / native-test-haiku | 同上 |

兩 squad 檔案所有權完全互斥，無跨 squad 介面依賴。共用樹紅線：禁 stash/reset/checkout --/clean；commit 一律顯式 `git add <自己的檔>`；驗收條件 5 的「合併」改為「兩 squad commit 落 main 後」重跑驗證。

## 契約修訂（使用者批准）
- 2026-08-16 使用者新增：所有測試 timeout 不得超過 10 秒，超過即視為測試寫法或性能問題。已以根目錄 `dart_test.yaml`（`timeout: 10s`）落地，commit 7c33194。

## Parking-lot（輪中新發現一律記此，不插隊）
- [preload-review] 快速導航時原生併發峰值 10→14（非 JPEG 路徑仍全幅解碼，暫態記憶體壓力）；可用小型 semaphore 限流（3-4）
- [preload-review, pre-existing] `_loadPreview` 無 try/finally，loader 拋錯會讓該 id 永久卡在 `_loadingKeys`
- [preload-review, pre-existing] `_preloadImages()` un-awaited，錯誤成為 unhandled async error
- [preload-review, pre-existing] 重疊呼叫可復活已淘汰快取項，`_imageCache` 可暫超窗口
- [native-review lead 報告] 錯標/損壞 .jpg 改由 Flutter 端報解碼失敗（原生 ImageIO 原可按內容嗅探）
- [native-review lead 報告] 大 JPEG 全尺寸過 channel，無 bytes 上限（屬 out-of-scope 方案 D）
- [native lead] 原生路徑無自動測試，方向正確性依賴 EXIF 假設，需一次旋轉 JPEG 的人工目視
- [preload lead] `test/photo_file_actions_test.dart` 與 `lib/services/trash_service.dart` 為 untracked 但實際被使用/執行，需決定是否入版控
- [orchestrator] Android `MainActivity.kt` 無任何 MethodChannel handler（空殼），Android 上縮圖全部靜默失敗
- [preload lead] flutter test 即時輸出檔名列印非決定性——驗收標準應用 exit code＋總數，勿 grep 檔名
