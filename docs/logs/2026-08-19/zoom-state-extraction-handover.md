---
date: 2026-08-19
title: "Task 19 — Zoom 狀態下沉至 View 層 — Session Handover"
---

# Task 19｜Zoom 狀態下沉至 View 層 — Session Handover

> **建立時間**：2026-08-19（UTC+8）
> **交接目的**：讓下一個 session 執行 Task 19，終態是 `AppState` 不再持有任何 zoom/animation 欄位、`main_detail_view.dart` 不再對 `AppState` 做 setter 寫入，且縮放行為零回歸。
> **目前判定**：待執行（方案已由使用者拍板，尚未動工）
> **可信版本錨點**：branch `main`；HEAD `ecfdd93`；本檔所有行號取自該 commit 的工作樹（乾淨，無未提交改動）

## 0. 接手速讀（60 秒）

- **目標**：消除 view→provider 的反向資料流。縮放是純畫面狀態，卻住在資料層 `AppState`，導致 5 處 view 直接寫 provider。
- **現象**：功能目前**正常**，沒有使用者可見的 bug。這是預防性重構，不是修 bug。
- **目前位置**：已完成現況盤點與方案選定；**尚未寫任何程式碼**。
- **下一個動作**：新建 `lib/views/zoom_controller.dart`，把 `app_state.dart:306-334` 的 `_zoomBy()` 搬進去。
- **最大風險／紅線**：縮放是連續互動，**現有測試零覆蓋**。任何回歸只有手動操作才會發現——第 12 節的手動驗證清單必須逐項做完，不可略過。

## 1. 接手啟動序列

1. Read `lib/providers/app_state.dart:113-119` 與 `:298-334` — 要搬走的五個欄位與三個方法。
2. Read `lib/views/main_detail_view.dart:18-42`、`:75-102`、`:215-222`、`:275-292` — 五處反向寫入與動畫觸發機制的全貌。
3. Run `git status --short` — 預期乾淨；若有他人未提交改動，先讀第 3 節的共享樹規則。
4. Run `flutter test` — 預期 `95 tests, All tests passed!`（這是重構前的基準，重構後必須一致）。
5. Start at `lib/views/zoom_controller.dart`（新檔）。
6. Verify with 第 12 節的命令 + 手動清單。

## 2. 目的、現象與根因狀態

### 目的

`AppState` 是資料層（照片清單、標記狀態、預載）。zoom/animation 是純 View 狀態，放在那裡讓 view 必須反向寫 provider 才能運作。終態是兩者分離，且鍵盤縮放仍可用。

### 現象

- 條件：目前一切正常運作，無使用者可見症狀。
- 實際：五處 view→provider 寫入，其中 `main_detail_view.dart:220` **在 build 期間**寫 provider。
- 為何沒炸：那行故意不觸發 `notifyListeners()`（`app_state.dart:176-177` 註解寫明「Silent update」）。
- 證據：`app_state.dart:113-119`、`main_detail_view.dart:32,99,220,282,285`。

### 根因（已確認）

鍵盤 `↑`/`↓` 的處理在 `main_screen.dart:99,102`，而它是 `MainDetailView` 的**父層**。父層無法直接呼叫子層方法，當初以 provider 作為那條管道，zoom 狀態因此被放進 `AppState`。這是所有反向寫入的單一成因——不解決「父呼叫子」，搬欄位只會把問題換個位置。

## 3. 範圍與版本控制狀態

- In scope：`lib/providers/app_state.dart`、`lib/views/main_detail_view.dart`、`lib/views/main_screen.dart`、新檔 `lib/views/zoom_controller.dart`。
- Out of scope：`sidebar_view.dart`、`status_line.dart`、`image_preload_controller.dart`、任何 macOS 原生檔。
- Branch / HEAD：`main` / `ecfdd93`。
- Working tree：交接當下乾淨。**注意**：本 repo 常有多個 session 同時在同一棵樹上工作（本 session 期間 `sidebar_view.dart` 就曾帶著他人的未提交改動）。動工前先 `git status`，樹上有別人的檔案是常態，**禁止** `git stash / reset / checkout -- / clean` 求乾淨。
- 相關 commits：
  - `ecfdd93` — Task 15/16/17/18/20 技術債清償；`sidebar_view.dart` 的顏色去重在此，與 zoom 無關但同檔區域。
  - `1c808c3`、`d0eb855` — sidebar 縮圖可見範圍改用 viewport 幾何；示範了「view 自己算幾何」的作法，與本任務的 `lastKnownCenter` 處置同源。
- 背景狀態：無 team、無 tmux session、無背景程序（本 session 的兩個 team 均已關閉並驗證無殘留）。

## 4. 目前邏輯架構（zoom 切面）

| 節點 | 責任 | 關鍵符號 | 上游 | 下游 | 不變式／失敗語意 |
|---|---|---|---|---|---|
| 鍵盤入口 | `↑`/`↓` 觸發縮放 | `main_screen.dart:99,102` | `Focus.onKeyEvent` | `AppState.stepZoomIn/Out` | 焦點在 `MainScreen` 的 `FocusNode`，子層不持有焦點 |
| 縮放計算 | 算出目標矩陣 | `app_state.dart:306-334` `_zoomBy()` | 鍵盤入口 | 設 `targetMatrix` + `shouldAnimateZoom` | scale ≤1.05 直接歸零回中心；上限 5.0 |
| 焦點選擇 | 決定縮放圍繞哪一點 | `app_state.dart:324` | `pointerPosition` ?? `lastKnownCenter` | `_zoomBy` 的矩陣運算 | 滑鼠在畫面上時以游標為焦點，否則以畫面中心 |
| 動畫觸發 | 讀旗標起動畫 | `main_detail_view.dart:82-100` | `build()` | `_animController.forward` | 旗標必須在 post-frame 清掉，否則每幀重觸發 |
| 動畫輸出 | 每 tick 寫矩陣 | `main_detail_view.dart:32` | `_animController` listener | `transformCtrl.value` | 200ms / 約 12 次寫入 |
| 手勢輸入 | 使用者拖曳縮放 | `main_detail_view.dart:288` | `InteractiveViewer` | `transformCtrl` | min 1.0 / max 5.0；trackpad 捲動即縮放 |
| 幾何回報 | 提供畫面中心 | `main_detail_view.dart:215-221` | `LayoutBuilder` | `AppState.lastKnownCenter` | **在 build 期間寫入**，靠不 notify 才沒有無窮迴圈 |

## 5. 資料生產消費鏈

### Happy path（鍵盤縮放）

`鍵盤 → MainScreen → AppState._zoomBy → targetMatrix/shouldAnimateZoom → MainDetailView.build → AnimationController → transformCtrl → InteractiveViewer`

| Hop | 輸入 | 輸出 | 驗證／正規化 | 失敗處理 | 證據 |
|---|---|---|---|---|---|
| 鍵盤 → AppState | `LogicalKeyboardKey` | 呼叫 `stepZoomIn/Out` | 無 | 無 | `main_screen.dart:99,102` |
| AppState 內部 | 目前矩陣 + 焦點 | `Matrix4` + bool 旗標 | scale ≤1.05 歸零、>5.0 夾住 | `scaleFactor==1.0` 直接 return | `app_state.dart:306-334` |
| AppState → View | 旗標 + 目標矩陣 | `Matrix4Tween` | 讀取後 post-frame 清旗標 | 旗標未清會每幀重觸發動畫 | `main_detail_view.dart:82-100` |
| View → 矩陣 | 動畫值 | `transformCtrl.value` | 無 | 無 | `main_detail_view.dart:32` |

### Failure path

- 旗標在同一幀內被設兩次（連按兩下 `↑`）：第二次的 `targetMatrix` 覆蓋第一次，動畫從新起點重跑；**不會**累加兩段縮放。這是現行行為，重構後應保持一致或明確改善並記錄。
- `MainDetailView` 未 mount 時 post-frame callback 以 `if (mounted)` 保護（`:98`），旗標會留在 true，下次 build 再消費。

## 6. 型別與介面契約

| 契約 | Producer 定義 | Consumer 假設 | 不變式 | 證據 |
|---|---|---|---|---|
| `transformCtrl` | `AppState` 建立並於 `dispose()` 釋放 | `InteractiveViewer` 全程持有同一實例 | 實例身分不可在 widget 生命週期中更換 | `app_state.dart:113`、`:482`、`main_detail_view.dart:288` |
| `shouldAnimateZoom` | `_zoomBy()` 設 true | `build()` 讀取後負責清除 | one-shot，讀者即清除者 | `app_state.dart:313,333`、`main_detail_view.dart:99` |
| `lastKnownCenter` | `LayoutBuilder` 每次 rebuild 寫入 | `_zoomBy()` 於無游標時讀取 | **寫入時不得 notifyListeners** | `main_detail_view.dart:220`、`app_state.dart:324` |
| `pointerPosition` | `MouseRegion` onHover/onExit | `_zoomBy()` 優先讀取 | null 表示游標不在畫面上 | `main_detail_view.dart:282,285` |

## 7. 已完成事項

| 結果 | 改動／產物 | 驗證 | 版本錨點 |
|---|---|---|---|
| [C] 現況盤點：5 欄位、3 方法、5 處反向寫入全部定位 | 本檔第 4–6 節 | 逐條 grep 對照原始碼 | `ecfdd93` |
| [C] 方案由使用者拍板為 B（獨立 ZoomController） | 本檔第 8 節 | 使用者 2026-08-19 明確選擇 | — |
| [C] 重構前基準：`flutter test` 95 綠、`flutter analyze` 0 issues | — | 本 session 實跑 | `ecfdd93` |

**尚未開始寫任何程式碼**。

## 8. 待解議題（依賴順序）

| 優先 | 狀態 | 議題 | 下一動作 | 完成條件 |
|---|---|---|---|---|
| P0 | [D→已決] | 父層如何呼叫子層縮放 | 使用者已選**方案 B**：獨立 `ZoomController extends ChangeNotifier`，由 `MainScreen` 建立並以參數傳給 `MainDetailView`。**不要**改用 GlobalKey，也不要只搬一半（方案 A/C 已被否決，見第 9 節） | — |
| P1 | [U] | 建立 `lib/views/zoom_controller.dart` | 把 `app_state.dart:306-334` 的 `_zoomBy/stepZoomIn/stepZoomOut` 與五個欄位搬入；`transformCtrl` 由它建立並 `dispose()` | 檔案存在且可獨立建構（不需要 `AppState`） |
| P2 | [U] | `MainScreen` 建立 controller 並傳下去 | `_MainScreenState` 持有 `late final ZoomController _zoom`，在 `dispose()` 釋放；`:99,102` 改呼叫 `_zoom.stepIn()/stepOut()`；`MainDetailView(zoom: _zoom)` | 鍵盤縮放不再經過 `AppState` |
| P3 | [U] | `MainDetailView` 改用傳入的 controller | 五處 `context.read<AppState>().X = Y` 全部改寫為對 controller 的操作；`lastKnownCenter` 建議直接改為 view 的本地欄位（它的 producer 與 consumer 屆時都在 view 側，不必再跨物件） | `grep -n "read<AppState>()\." lib/views/main_detail_view.dart` 只剩非 zoom 用途 |
| P4 | [U] | 從 `AppState` 移除 | 刪 `:113-119` 五欄位、`:298-334` 三方法、`:482` 的 `transformCtrl.dispose()` | `grep -n "transformCtrl\|targetMatrix\|shouldAnimateZoom\|pointerPosition\|lastKnownCenter" lib/providers/app_state.dart` 無輸出 |
| P5 | [U] | 補測試（現況零覆蓋） | 為 `ZoomController` 寫純 `test()`（不需 widget）：縮放上下限、≤1.05 歸零、焦點選擇 `pointerPosition ?? lastKnownCenter` | 新測試存在且**被親眼看過失敗**後才綠 |

## 9. 嘗試、裁決與禁止重踩

| 方案 | 結果 | 裁決理由 | 是否可重試 |
|---|---|---|---|
| A. `GlobalKey<_MainDetailViewState>` | 未採用 | 程式碼最少，但把 State 私有實作暴露給父層，且無法為縮放邏輯寫不含 widget 的測試 | 否 |
| B. 獨立 `ZoomController` | **採用** | zoom 完全離開 `AppState`；controller 可獨立建構與測試；鍵盤呼叫變成普通方法呼叫 | — |
| C. 只搬部分欄位 | 未採用 | 反向寫入仍在，債沒清掉，還多一層不一致 | 否 |
| 直接刪掉 `lastKnownCenter` 改用 `MediaQuery` | 未嘗試 | 未驗證：畫面中心 ≠ 視窗中心（左側有可調寬度的 sidebar）。若要走這條，先確認 sidebar 寬度變化時焦點仍正確 | 可，但需先驗證 |

**禁止重踩**：不要在 `LayoutBuilder` 的 builder 內對任何 `ChangeNotifier` 呼叫 `notifyListeners()`（含新的 ZoomController）。現行程式碼靠「靜默寫入」避開 build 期間 rebuild，新架構若讓幾何回報觸發通知，會直接產生無窮 rebuild。

## 10. 未來方向（不阻塞）

- 雙擊縮放、縮放比例顯示、分割檢視：這些是「順手一起做」的觸發條件。本任務單獨執行的投報比低——若沒有這類需求出現，延後是合理的。

## 11. 已知限制與不確定性

- **已知限制**：縮放行為目前**零自動化測試**。重構的正確性主要靠手動驗證，第 12 節清單是唯一防線。
- **未驗證**：`lastKnownCenter` 在 sidebar 寬度被拖動後是否即時更新（`LayoutBuilder` 應會 rebuild，但未實測）。重構後請一併驗這條。
- **需注意**：`MainDetailView` 在照片切換時不會被 dispose，因此縮放狀態跨照片保留是現行行為（`app_state.dart:112` 註解「Zoom retention」）。改用 view 本地狀態後仍需保持——若把 controller 建在 `MainDetailView` 內部而非 `MainScreen`，這個行為會在 widget 被重建時遺失。**controller 必須由 `MainScreen` 持有**。

## 12. 驗收命令與手動清單

```bash
flutter analyze lib test            # 預期 No issues found!
flutter test                        # 預期 95+ tests, All tests passed!
grep -n "transformCtrl\|targetMatrix\|shouldAnimateZoom\|pointerPosition\|lastKnownCenter" lib/providers/app_state.dart   # 預期無輸出
flutter build macos --release       # 預期 ✓ Built ... Halcyon.app
```

手動驗證（逐項做，缺一不可——自動化測試涵蓋不到）：

1. `↑`/`↓` 鍵縮放，動畫平順、有上下限（放到最大再按無反應、縮到最小回正中心）。
2. 滑鼠停在畫面某處按 `↑`，縮放以**游標**為焦點。
3. 滑鼠移出畫面後按 `↑`，縮放以**畫面中心**為焦點。
4. trackpad 捏合／捲動縮放正常，拖曳平移正常。
5. 縮放後切換照片（`←`/`→`），縮放狀態保留。
6. 拖動 sidebar 寬度後再縮放，焦點仍正確。
7. 連按兩次 `↑`，不會卡住或跳動。

## 13. 參考入口

- 必讀：`lib/providers/app_state.dart:113-119`、`:298-334` — 要搬走的全部內容。
- 必讀：`lib/views/main_detail_view.dart:18-42`、`:75-102`、`:215-222`、`:275-292` — 五處反向寫入。
- 必讀：`lib/views/main_screen.dart:95-105` — 鍵盤入口。
- 相關：`task.md` Task 19 — 子任務拆解（19.1–19.5），與本檔第 8 節一致，本檔的行號較新。
- 相關：`memory.md` G-010 / TD-011 — 這條債的原始記錄。
