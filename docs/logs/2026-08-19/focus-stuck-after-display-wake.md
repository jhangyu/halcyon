# 偶發：螢幕休眠喚醒後無法切換到其他 app

狀態：**未重現、未修**。使用者裁決先記錄，能穩定重現後再 debug。

## 症狀（使用者回報，2026-08-19）

- Halcyon 開著時，點其他 app 的 Dock 圖示切不走，**Cmd+Tab 也切不走**。
- 兩次都發生在**螢幕休眠後喚醒**。無法主動重現。
- 使用者印象中 8/16 的 build 沒有，`d0eb855` / `1c808c3` 這兩版才有。

## 已排除（有量測證據，非推論）

| 假設 | 方法 | 結果 |
|---|---|---|
| 無窮 frame loop（app 永不 idle，主執行緒被佔滿） | widget test 探針：載入 80 張、pump 到 settle 後連續 20 次檢查 `binding.hasScheduledFrame` | 0/20，無 loop |
| 冷啟動搶回前景 | pkill → 冷啟（0.18s 成為前景）→ 等 5s → 交焦點給 Finder → 每 0.5s 取樣前景 app ×30 | 30/30 都是 Finder |
| 有真實負載時搶回前景 | `HALCYON_PERF_DIR` 載入 150 張、paced 模式連續切換 → 交焦點給 Finder → 取樣 ×40 | 40/40 都是 Finder |

程式碼面：`macos/` 自 `123727b` 起零改動；全 repo 無 `NSApp.activate`、`makeKeyAndOrderFront`、window level 設定；`d0eb855`/`1c808c3` 全部是 Dart 端 sidebar 縮圖時序，沒有觸及視窗或焦點 API。**目前沒有任何機制可以解釋這兩個 commit 造成 OS 層焦點搶奪**，版本歸因僅來自使用者時間線，尚未經證據支持。

（探針腳本：`scripts/tmp/focus_probe*.py`，scratch，未 commit。）

## 下次發生時要做的事

**先跑取證，再點任何東西**（一旦恢復就取不到現場）：

```bash
bash scripts/focus_forensics.sh
```

輸出落在 `docs/logs/<date>/focus-stuck-<time>.txt`，含四項判別資料：

1. **secure input 持有者**（`kCGSSessionSecureInputPID`）——非 0 代表**有進程全域攔截鍵盤**，那就不是 Halcyon 的 bug，Cmd+Tab 對每個 app 都會死。這是最該先排除的一項。
2. Halcyon 的**主執行緒 stack sample**——若卡在 AppKit 的 tracking/modal loop（NSMenu tracking、modal session），就是「事件被 app 吃掉」型。
3. Halcyon **進程數量**——多重實例或 bundle 被就地覆蓋後的殘留進程。
4. WindowServer / activation 的近 60 秒 log。

同時請順手記錄兩個一句話的判別答案：

- 其他兩個 app 之間（例如 Finder ↔ Safari）能不能互相切換？**不能 → 系統層問題，與本 app 無關。**
- `pkill -f Halcyon` 之後切換是否立刻恢復？**恢復 → 確實是本 app 持有的狀態。**

## 目前的假設排序

1. **macOS 喚醒後的系統層輸入/啟用狀態異常**（secure input 殘留、WindowServer activation 卡住）——最符合「Dock 與 Cmd+Tab 同時死」，且與 app 是否為 Halcyon 無關。
2. **Flutter macOS 引擎在喚醒後的 key window / first responder 狀態**——上游已知有喚醒後鍵盤事件異常類問題；需 stack sample 佐證。
3. 這兩個 commit——**目前無機制、無量測支持**，僅有時間相關性。
