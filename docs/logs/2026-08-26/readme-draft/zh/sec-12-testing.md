## 測試與品質閘門

```bash
flutter analyze                                   # must report 0 issues
flutter test                                      # full suite
flutter test test/providers/app_state_test.dart   # a single file
flutter test --coverage
```

測試套件在 `test/` 下共有 45 個測試檔案，結構鏡射 `lib/`：`models/`、`providers/`、`services/`、`views/`、`perf/`，另外還有 `test/support/` 下共用的假物件（fake）。每個測試都有 10 秒的逾時限制。

<!-- evidence: dart_test.yaml:1, test/ directory listing 2026-08-26 -->

`flutter analyze` 回報零問題是一道硬性閘門，不是偏好——只要它回報任何問題,工作就不算完成。注意靜態分析涵蓋的範圍是 `lib/`、`test/` **以及** `tool/`，因此只掃過 `lib/` 與 `test/` 的符號重新命名仍然會讓這道閘門失敗。

<!-- evidence: CLAUDE.md Commands section; memory.md 2026-08-25 naming-refactor entry -->

### 是什麼讓這套測試成為可能

`AppState` 透過建構子接收每一個協作物件——資料庫掃描器、狀態儲存區、檔案操作、預先載入控制器、影像載入函式，以及可選的完整解碼器。測試對這些全部替換成假物件,因此應用程式邏輯的執行不需要碰觸檔案系統或平台通道。解碼器介面同樣如此：這條管線是針對一個假解碼器測試的,而不是載入真正的原生函式庫。

<!-- evidence: lib/providers/app_state.dart constructor; lib/services/image_pipeline/dng_decode_contract.dart -->

### 測試策略文件

`unit_test.md` 保存測試策略、以 TC-NNN 編號的測試案例矩陣及其各案例的通過/失敗歷史，以及涵蓋範圍的優先順序。本儲存庫新增的任何測試都應該在該矩陣中對應一筆條目。它同時記錄了曾經嘗試但刻意放棄的案例——例如一個會讓測試執行器的計時器掛住的完整鍵盤元件測試——這在重新嘗試同類測試之前值得先讀一讀。

<!-- evidence: unit_test.md:1-3, unit_test.md:197 -->

### 已知的測試陷阱

本程式碼庫中有兩個已被記錄在 `memory.md` 裡、曾經耗費實際時間的陷阱：

- 執行真實 `dart:io` 工作的 `testWidgets` 主體必須包在 `tester.runAsync` 裡；在 `FakeAsync` 內等待真實引擎的 future 會永遠掛住。
- 在 `testWidgets` 內點擊 `PopupMenuItem` 在 `FakeAsync` 底下會掛住。

<!-- evidence: memory.md G-020, memory.md G-013 -->
