# Recycle Mode（`.trash` 非直接刪除模式）設計文件

日期：2026-08-17
狀態：待實作

## 一句話終態

在同時存有 JPG + RAW 同名檔的資料夾裡，批次刪除預設改為把整組同名檔搬到源資料夾的 `.trash/` 子目錄，而非丟系統回收桶；使用者可對預覽視窗底部的刪除按鈕按右鍵，隨時在兩種模式之間切換。

## 動機

1. 誤刪 RAW 不可回復的風險。
2. `TrashService` 走 macOS 系統回收桶（`lib/services/trash_service.dart:11`），在記憶卡 / exFAT 這類沒有 `.Trashes` 的卷宗上會丟 `PlatformException`；同卷宗 `rename` 到 `.trash/` 一定成功且是瞬間完成。

## 已存在、不需實作的部分

原始需求「預覽只看 JPG、複製/刪除時把同名不同副檔名的檔案一起處理」**目前已經是這樣運作**：

- `lib/services/photo_library_scanner.dart:18` 以 `basenameWithoutExtension` 分組，同名檔全部落入同一個 `PhotoItem.files`
- `lib/models/photo_item.dart:22` → `SupportedPhotoFormats.bestFileToLoad` 依 `.jpg/.jpeg/.png/.heic` 順序挑預覽來源
- `lib/services/photo_file_actions.dart:29`、`:60` 複製與刪除都是 `for (final file in item.files)`

因此本文件的實作範圍只有回收模式，外加下面 S1 的一個順修。

---

## S1. 順修：補齊 RAW 副檔名

`SupportedPhotoFormats.rawExtensions` 列了 `.cr2/.nef/.orf`（`lib/models/supported_photo_formats.dart:23`），但 `supportedExtensions`（同檔 `:6`）沒有。結果是 Canon/Nikon/Olympus 的 RAW 根本不會被 scanner 收進 `PhotoItem.files`，也就不會跟 JPG 一起被複製或刪除——RAW 會被靜默留在卡上。

修法：把 `.cr2/.nef/.orf` 加進 `supportedExtensions`。

## S2. 狀態模型

`AppState` 新增：

```dart
bool _recycleMode = false;
bool get recycleMode => _recycleMode;
void toggleRecycleMode();   // notifyListeners
```

- **初值**：`loadFolder` 掃描完成後計算 `_items.any((i) => i.files.length > 1)`。有任何同名多副檔名群組 → `true`。
- **生命週期**：per-folder，不持久化。每次 `loadFolder` 重新計算，因此換資料夾一律回到安全預設。`toggleRecycleMode` 是純粹的雙向開關——即使目錄只有單一副檔名，使用者也能手動切進回收模式。
- **不寫入** SharedPreferences，也不寫入 `.halcyon_status.json`。

## S3. 服務層

`PhotoFileActions` 新增：

```dart
Future<RecycleOutcome> recycleTrashed(List<PhotoItem> items, Directory dir);

class RecycleOutcome {
  final int movedCount;                  // 成功搬移的檔案數（含 sidecar）
  final List<String> failures;           // "檔名: 錯誤訊息"
}
```

行為：

1. 建立 `<dir>/.trash/`（`createSync(recursive: true)`，已存在則沿用）。
2. 對每個 `status == PhotoStatus.trashed` 的 item，逐一處理 `item.files` 以及各自的 `._<basename>` AppleDouble sidecar（與現有 `deleteTrashed` 一致，`photo_file_actions.dart:61`）。
3. 目標路徑衝突處理：若 `<dir>/.trash/IMG_0001.jpg` 已存在，改用 `IMG_0001-1.jpg`、`IMG_0001-2.jpg`……序號從 1 起遞增直到找到不存在的名字。序號插在 basename 與副檔名之間。
4. 搬移用 `File.rename`（同卷宗瞬間完成）。單一檔案失敗時記入 `failures` 並繼續處理其餘檔案，不中斷整批。

`AppState.deleteTrashed()` 依 `_recycleMode` 分派：`true` → `recycleTrashed`，`false` → 現有的 `_fileActions.deleteTrashed`。兩條路徑結束後都照現況 `loadFolder` 重載（保留選取位置）。

`.trash` 不會被重新掃進來：`PhotoLibraryScanner` 只處理 `entity is File`（`photo_library_scanner.dart:12`），目錄一律略過。

## S4. 錯誤處理（不可簡化）

現況 `AppState.deleteTrashed` 把所有例外吞掉只 `debugPrint`（`lib/providers/app_state.dart:379`）——在記憶卡上系統回收桶失敗時，使用者看到照片還在卻沒有任何錯誤提示，會以為是程式壞了。

改為：兩條路徑（回收 / 直接刪除）都收集失敗清單，非空時彈 `AlertDialog` 列出失敗的檔名與原因。這是唯一會阻斷的對話框；成功路徑不阻斷。

## S5. UI

### S5.1 圖標與配色

回收模式採 **`Icons.restore_from_trash`**（垃圾桶＋向上箭頭）。保留垃圾桶外形所以仍看得出是刪除鈕，箭頭表達「取得回來」，且有 outlined/filled 兩態，未標記時也分辨得出當前模式。

`Colors.amber` 已被 star 按鈕佔用（`lib/views/main_detail_view.dart:145`），因此回收模式**沿用紅色**，靠圖形而非顏色區分模式。

| 位置 | 直接刪除模式 | 回收模式 |
|---|---|---|
| 控制列 · 未標記 | `Icons.delete_outline`（無色） | `Icons.restore_from_trash_outlined`（無色） |
| 控制列 · 已標記 | `Icons.delete`（紅） | `Icons.restore_from_trash`（紅） |
| Sidebar 狀態小圖示 | `Icons.delete`（紅，16px） | `Icons.restore_from_trash`（紅，16px） |

### S5.2 右鍵切換

`lib/views/main_detail_view.dart:154` 的 trash `IconButton` 外層包一層 `GestureDetector(onSecondaryTap: ...)` 呼叫 `toggleRecycleMode()`。

- 左鍵行為不變：`markCurrent(PhotoStatus.trashed)` 標記/取消標記單張。
- `X` 鍵行為不變（`lib/views/main_screen.dart:85`），不新增模式切換的鍵盤快捷鍵。
- tooltip 隨模式改：
  - 直接刪除：`Trash (X) — right-click: switch to recycle mode`
  - 回收：`Recycle (X) — right-click: switch to direct delete`
- 只有控制列這一顆按鈕接右鍵。sidebar 的狀態小圖示只跟著換圖形，不接右鍵。

### S5.3 無阻斷式的模式告知

不彈「偵測到在源資料夾篩選照片」的對話框。圖標形狀差異＋tooltip 就是模式指示。

### S5.4 批次動作入口

`⋯` 選單位置與結構不動（`lib/views/sidebar_view.dart:305`），僅文字隨模式改：

- 直接刪除模式：`Delete Trashed`（紅字，現況）
- 回收模式：`Recycle Trashed`（紅字）

### S5.5 完成提示

批次回收成功後顯示 `SnackBar`：

- 文案：`已回收 N 張照片到 .trash（未直接刪除，請自行清理）`
- 一個 `SnackBarAction`「顯示」→ `Process.run('open', ['<dir>/.trash'])` 在 Finder 中開啟該目錄（`dart:io`，macOS-only，本 app 已是 macOS 專用）
- `duration: Duration(milliseconds: 2500)`。退場 0.5 秒淡出：建立一個 `reverseDuration: Duration(milliseconds: 500)` 的 `AnimationController` 傳給 `SnackBar.animation`，並在退場後 dispose。若實作時發現預設退場已足夠接近，可省略 controller 並在 PR 說明中註明——這是可接受的簡化，不算未完成。

直接刪除模式的成功路徑沿用現況（無提示）。

---

## 驗收條件

1. `SupportedPhotoFormats.supportedExtensions` 含 `.cr2`、`.nef`、`.orf`；既有 `supported_photo_formats` 相關測試仍綠。
2. `PhotoFileActions.recycleTrashed` 測試：一個 item 含 `IMG_0001.jpg` + `IMG_0001.dng` + `._IMG_0001.jpg`，回收後三個檔案都在 `<dir>/.trash/`、源目錄不再有它們、未標記的 item 檔案完好無損。
3. 序號衝突測試：`.trash/IMG_0001.jpg` 預先存在，回收後產生 `.trash/IMG_0001-1.jpg`，且原本的 `.trash/IMG_0001.jpg` 內容未被覆寫。
4. 失敗不靜默測試：注入一個會丟例外的搬移函式，`RecycleOutcome.failures` 非空且其餘檔案仍被處理。
5. `AppState` 測試：載入含同名多副檔名群組的目錄後 `recycleMode == true`；載入只有單一副檔名的目錄後 `recycleMode == false`；`toggleRecycleMode()` 可雙向切換。
6. Widget 測試：`recycleMode == true` 時控制列出現 `Icons.restore_from_trash_outlined`（未標記）／`Icons.restore_from_trash`（已標記），`recycleMode == false` 時為 `Icons.delete_outline`／`Icons.delete`。註：`MainDetailView` 需要有選取項目才會畫出控制列，測試需注入 fake `AppState`（`test/app_state_test.dart` 已有既成的注入模式可循）。
7. 每條測試都必須被親眼看過失敗一次（先反向斷言確認紅燈，再改回正確斷言）才算證據。
8. `flutter test` 全綠，exit code 0 且輸出含 `All tests passed!`。
9. 實機跑一次：在含 JPG+RAW 的資料夾標記 2 張、執行 Recycle Trashed，確認 `.trash/` 內出現 4 個檔案、SnackBar 出現、右鍵切回直接刪除後圖標變回垃圾桶。

## 範圍外

- 從 `.trash` 還原照片的 UI
- `.trash` 的自動清理或容量管理
- 回收模式跨資料夾記憶（持久化）
- 系統回收桶失敗時自動 fallback 到 `.trash`（本設計用手動模式切換覆蓋此情境）
- 「直接刪除模式」改成真正的永久刪除（維持現況：丟系統回收桶）
- 複製/移動路徑（`processStarred`）的任何改動

## 檢查：範圍外項目是否阻斷終態

逐項問「若它永遠不落地，終態還可達嗎」——五項皆可達。`.trash` 由使用者自行用 Finder 清理，這正是 S5.5 提示的用意。
