---
date: 2026-08-19
title: "Doc rewrite round — user-decision list & parking-lot"
---

## Round 2 audit trail — 待使用者裁決清單逐條核實

裁決指示（team-lead 轉述使用者裁決）：對每一項對照今日樹上程式碼核實，分類為 ALREADY DONE / STILL VALID / PREMISE GONE / GENUINE PRODUCT DECISION，並依分類改寫或刪除。

### 1. task.md Task 16 / G-005 — auto-advance toggle-off 行為
- **分類**：**ALREADY DONE**（行為本身）+ **STILL VALID**（測試覆蓋缺口）——拆成兩個獨立結論。
- **證據**：`lib/providers/app_state.dart:337-351`。`markCurrent()` 的 toggle-off 分支（`item.status == status`，行 340-341）只執行 `item.status = PhotoStatus.unmarked;`，不呼叫 `nextPhoto()`；`_autoAdvance` 判斷式（行 344）只存在於「設定新狀態」的 else 分支內。原文所述「toggle off 時不論如何都會前進」的 bug **目前不成立**。
- **動作**：刪除「待使用者確認」框架；改寫 memory.md G-005、task.md Task 16、unit_test.md TC-014、handover.md 對應項為「行為已確認正確，僅缺 regression test」。未發明答案——這是從程式碼讀出的事實，不是我猜的產品決策。

### 2. task.md Task 19 / G-010 — Zoom 狀態下沉
- **分類**：**STILL VALID**，行號需更新（2026-05-04 審查後歷經多輪改動，原行號已全部位移）。
- **證據**：`app_state.dart:113-119`（`transformCtrl`/`pointerPosition`/`lastKnownCenter`/`targetMatrix`/`shouldAnimateZoom` 五個欄位仍在）、`app_state.dart:298-334`（`stepZoomIn`/`stepZoomOut`/`_zoomBy` 仍在，且 `main_screen.dart:99,102` 仍呼叫它們）、`main_detail_view.dart:99,220,282,285`（4 處反向 setter 仍在，行號已變）。**新發現**：`main_detail_view.dart:32` 的 `_animController` listener 每個動畫 tick 都寫入 `context.read<AppState>().transformCtrl.value`，這是原始 4 處清單沒記錄的第 5 處反向寫入，且頻率更高。
- **動作**：改寫 task.md Task 19、memory.md G-010 的行號與背景敘述，保留待辦狀態；新增第 5 處發現。

### 3. task.md Task 20 / TD-014 — sidebar iconColor 重複
- **分類**：**STILL VALID**，且重複處從 3 處增至 4 處（回收模式改動新增了 mode-aware 選單，帶入更多重複的顏色判斷）。
- **證據**：`sidebar_view.dart:150`（`32,32,32`，header title）、`:197`（`59,59,59`，選取列 title，內嵌於 itemBuilder）、`:266-268`（`_buildTopActions()` 的 `iconColor`）、`:287-289`（`_buildActionMenu()` 的 `iconColor`，與前者完全重複）、`:322-324`（`_buildActionMenu()` 的 itemBuilder 閉包內 `actionTextColor`，第四處重複）。
- **警示**：讀取時另一 session 正對本檔案做未提交的 flicker-fix（見既有 parking-lot 第 1 項），上列行號是本輪讀取當下的快照，不是最終落地版本——已在 task.md/memory.md 內註記「下一輪需重新核對」。
- **動作**：改寫 task.md Task 20、memory.md TD-014 的行號與重複處數量。

### 4. handover.md「待確認事項」三項
- **4a. PhotoFileActions 測試策略（temp dir vs FileSystem 抽象）**
  - **分類**：**ALREADY DONE**——這是「該怎麼做」的問題，但既成事實已經回答了它。
  - **證據**：`test/photo_file_actions_test.dart` 全檔（`grep dart:io` 命中於檔頭 import，且全部測試用 `Directory.systemTemp.createTemp()`）皆使用真實 temp 目錄，無 mock FileSystem 抽象；同一模式後續延伸到 `test/sidebar_view_test.dart` 等所有資料操作測試。
  - **動作**：從「待確認事項」移除（劃記已解決），不再是開放問題。
- **4b. Task 19 鍵盤縮放銜接（callback vs GlobalKey）**
  - **分類**：**GENUINE PRODUCT DECISION**——現況（`main_screen.dart:99,102` 呼叫 `state.stepZoomIn()/stepZoomOut()`）已寫入 task.md Task 19 作為事實描述，但「移出 AppState 後要用什麼機制銜接」是架構取捨，不是樹上能查到的答案。
  - **動作**：保留為開放問題，補充現況事實（呼叫點與行號），未替使用者選邊。
- **4c. Task 20 色值統一（32,32,32 vs 59,59,59）**
  - **分類**：**GENUINE PRODUCT DECISION**——現況已核實兩個色值確實不同且各自穩定存在（見項目 3 證據），但「是否應該一致」是視覺設計意圖判斷。
  - **動作**：保留為開放問題，補充現況行號，未替使用者選邊。

### 總結
- 4 項 ALREADY DONE（G-005 行為本身、PhotoFileActions 測試策略）— 對應文件已刪除「待確認」框架，改寫為事實敘述。
- 2 項 STILL VALID（Task 19、Task 20 的程式碼缺口本身）— 保留待辦，行號更新為現況。
- 2 項 GENUINE PRODUCT DECISION（Task 19 銜接機制、Task 20 色值統一）— 保留為開放問題，未發明答案。
- 0 項 PREMISE GONE（沒有發現「所指程式碼已不存在」的情況）。
- 新增 2 項未在原始清單中的發現：G-010 的第 5 處反向寫入（`main_detail_view.dart:32`）、TD-014 從 3 處增至 4 處重複。

## 待使用者裁決清單

### 1. G-005 — Auto-advance Toggle off 行為
- **文件:行號**：`memory.md` G-005 節；`handover.md`「待確認事項」；`task.md` Task 16；`unit_test.md` TC-014
- **原文摘要**：`markCurrent()` 標記與現有狀態相同時會 toggle 回 `unmarked`；若 `autoAdvance=true`，目前實作不論是否 toggle 都會前進，但預期行為應是 toggle off 時不前進。
- **為何無法驗證**：這是「應該怎樣」的產品行為決策，不是程式碼現況查證問題——樹上事實只能證明「目前程式碼會前進」，無法證明這是不是 bug。
- **建議**：保留（keep），維持待確認狀態；不要自行判定並修正程式碼。

### 2. Task 19 — Zoom 狀態下沉至 View 層（G-010 / TD-011）
- **文件:行號**：`task.md` Task 19；`memory.md` G-010、TD-011
- **原文摘要**：`app_state.dart:67-73` 的 `transformCtrl`/`pointerPosition`/`lastKnownCenter`/`targetMatrix`/`shouldAnimateZoom` 屬於純 View 層狀態，`main_detail_view.dart` 有 4 處反向寫入這些欄位，計畫將其搬到 `_MainDetailViewState`。
- **為何無法驗證**：本輪時間預算內我沒有重新逐行核對 `main_detail_view.dart` 目前是否仍是 4 處反向寫入（原始行號記載於 2026-05-04 架構審查，之後歷經多輪改動未重新核實）。
- **建議**：下一輪派工重新讀 `main_detail_view.dart` 全文核對行號與反向寫入處是否仍然一致，再決定是否照原計畫排入；本輪先維持原文不動（rewrite as 待重新核實，不是直接刪除或直接排入）。

### 3. Task 20 — sidebar iconColor 重複邏輯（TD-014）
- **文件:行號**：`task.md` Task 20；`memory.md` TD-014；`handover.md`「待確認事項」
- **原文摘要**：`sidebar_view.dart:114-117`（title color `32,32,32`）與 `sidebar_view.dart:229-231`、`250-252`（icon color `59,59,59`）三處重複且色值不一致，計畫抽成 `_iconColor()` helper。
- **為何無法驗證**：原始行號記載於 2026-05-04，之後回收模式（Task 25）大幅改動了 `sidebar_view.dart` 的按鈕與選單區塊（新增 mode-aware 圖示/選單標籤），加上目前又有另一 session 正在對此檔案做未提交的 flicker-fix（見 parking-lot），此刻讀取行號會讀到不穩定的中間狀態，不適合現在核實。
- **建議**：rewrite as「需重新核實現狀再排入」——待另一 session 的 sidebar 修改落地並 commit 後，下一輪重新讀取現在的行號再判斷是否仍有重複邏輯與色值不一致。

### 4. PhotoFileActions 測試策略（temp dir vs FileSystem 抽象）
- **文件:行號**：`handover.md`「待確認事項」
- **原文摘要**：`PhotoFileActions` 測試應使用 `dart:io` 操作真實 temp 目錄，還是需要抽象 `FileSystem` 介面？
- **為何無法驗證**：這是測試架構選型的品味/取捨決策，不是可從樹上驗證的事實——雖然目前 `test/photo_file_actions_test.dart` 已存在且用 `dart:io` temp 目錄實作（可視為既成事實/precedent），但文件本身記載這是「待確認」的選型問題，且已有精神一致的既有實作，不構成我單方面關閉此問題的理由。
- **建議**：keep，但補充事實註記——「現有 `test/photo_file_actions_test.dart` 已依 `dart:io` temp 目錄實作，若無異議可視為既定方向」；不強制關閉待確認狀態。

### 5. Task 19 鍵盤縮放銜接（callback / GlobalKey 選型）
- **文件:行號**：`handover.md`「待確認事項」
- **原文摘要**：zoom 邏輯移出 `AppState` 後，`main_screen.dart` 的 `↑`/`↓` 鍵盤縮放需要新的觸發路徑（callback 或 GlobalKey），實作前需確認偏好方式。
- **為何無法驗證**：這是 Task 19（尚未開始）的實作前置決策，屬於未來設計選型，不是現況查證問題；且 Task 19 本身狀態待重新核實（見上方項目 2）。
- **建議**：keep，維持原樣；待 Task 19 排入時再由執行者或使用者決定。

### 6. Task 20 色值統一（title color 是否應對齊 icon color）
- **文件:行號**：`handover.md`「待確認事項」；對應 `sidebar_view.dart:114-117` vs `229-231`/`250-252`
- **原文摘要**：`title color`（`32,32,32`）是否應與 `icon color`（`59,59,59`）一致，或兩者本應有差異需保留？
- **為何無法驗證**：這是視覺設計意圖的判斷（品味問題），且行號本身正處於不穩定狀態（見項目 3 的理由）。
- **建議**：keep，維持原樣；待項目 3 的行號核實完成後一併處理。

---

## Parking-lot

1. **另一 session 對 `lib/views/sidebar_view.dart` / `test/sidebar_view_test.dart` 的未提交編輯**：本輪工作期間偵測到這兩個檔案被另一 session 即時修改（在 Task 26／commit `d0eb855` 的 itemBuilder 預載機制之上做 flicker-fix，改用 viewport geometry 而非 built-index 範圍計算可視範圍）。我未觸碰、未還原、未記錄為已出貨行為。**影響**：待該編輯落地並 commit 後，`task.md` Task 26 與 `memory.md` AD-014 的描述（目前基於 `d0eb855` 的 built-index 觸發機制）需要下一輪補追一次修訂。

2. **收斂契約的 HEAD 凍結假設已在任務開始前失效**：`docs/logs/2026-08-19/doc-rewrite-contract.md` 開頭寫 HEAD = `cd8af97`，但我開始工作時實際 HEAD 已是 `d0eb855`（契約凍結後、我開工前，已有其他工作被提交）。已徵得你確認「用當下樹狀態是對的決定」，此處僅記錄供未來輪次契約撰寫參考：**多 agent 併行改動同一 repo 時，收斂契約若要 pin 一個 commit hash，應在契約凍結的同一時刻立刻分派給 worker，避免時間差讓 pin 失去意義**。

3. **`flutter build macos` 與所有真機/人工視覺覆核本輪未重跑**：包含 macOS Trash 移動、`.trash` 資料夾內容、Finder 開啟方式冷啟動、DNG 大圖顯示。文件中已逐處誠實標註「本輪未重跑」，不是隱瞞，但列在此處以防下一輪遺漏。

4. **`unit_test.md` 的 TC 矩陣仍是「一個測試檔一條摘要 TC」的粗粒度**：例如 TC-020 對應 `image_preload_controller_test.dart` 的 22 個案例，只有一條矩陣列。這是本輪就已存在的既有落差（見該檔「已知限制」節），非本輪新增，但值得記錄以免被誤認為已細顆粒度覆蓋。
