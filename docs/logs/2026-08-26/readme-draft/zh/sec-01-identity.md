## Halcyon

Halcyon 是一款 Flutter 桌面應用程式，供攝影師整理 RAW 與 JPG 照片資料夾：以鍵盤瀏覽，
為照片標記星號或垃圾桶，再批次複製或搬移已加星號的檔案。
<!-- evidence: lib/views/main_screen.dart:104-129 keyboard shortcut handler; lib/services/library/photo_file_actions.dart batch copy/move -->

![Halcyon main triage view](docs/images/halcyon_main_triage_view.png)

*主挑選畫面，macOS 15.6.1：側邊欄列出該資料夾的 628 張照片，檢視區佔滿視窗其餘部分，
沒有應用程式標題列，只有星標與垃圾桶按鈕浮在影像上方。方向鍵切換照片，`S` 與 `X` 標記。*

![依 EXIF 重新命名對話框](docs/images/halcyon_exif_rename_dialog.png)

*同一個資料夾上的「Rename by EXIF」對話框。左半部是預設集與可編輯的規則樣板（附即時
驗證），右半部隨機抽樣五個檔案預覽，每一列上方是目前檔名、下方是套用規則後的新檔名。*

### 名稱由來

Halcyon 與 Ceyx 都是翠鳥屬名。在希臘神話中，阿爾庫俄涅（Alcyone）與刻宇克斯（Ceyx）
化為翠鳥——這兩個儲存庫因此以一對的形式命名：Ceyx 是解碼引擎，Halcyon 是建構於其上
的應用程式。
<!-- evidence: docs/logs/2026-08-26/readme-draft/BRIEFING.md:46-49 (shared framing agreed for both READMEs); ../ceyx/README.md:56-65 "Sister project: Halcyon" section states the same pairing and dependency direction -->

### 為什麼是 Halcyon

- **篩選是吞吐量問題，不是檢視問題。** 攝影師的操作迴圈是「看、判斷、前進」——方向鍵
  在照片間移動，`S` 加星號，`X` 標記垃圾桶，這個迴圈中沒有任何一步需要對話框或滑鼠點
  擊。任何拖慢這個迴圈的東西，就是這個工具的全部成本所在。
  <!-- evidence: lib/views/main_screen.dart:104-129 arrowLeft/arrowRight/keyS/keyX bound directly to previousPhoto/nextPhoto/markCurrent -->
- **淵源：FastPictureViewer。** 這種「不離開鍵盤即可瀏覽與標記」的鍵盤驅動標記模型，
  直接受 FastPictureViewer 啟發——那是上一個時代一款付費的 Windows 工具，至今仍有攝影
  師懷念它。
- **最大化預覽區域、最小化介面裝飾。** 主畫面沒有 app bar：`Scaffold` 的 body 是一個
  `Stack`，圖片檢視器被定位為填滿整個畫面，只在其上疊加一個浮動動作列與狀態列。
  <!-- evidence: lib/views/main_screen.dart:48-59 Scaffold with no appBar, body is Stack(children: [_buildKeyboardShortcutHandler(...), StatusLine()]); lib/views/main_detail_view.dart:113-135 Stack with Positioned.fill viewer and a bottom-centered floating action bar -->
  macOS 視窗的預設尺寸直接由 3:2 預覽區域加上 270px 側欄計算而來（`previewWidth =
  defaultHeight * 1.5`、`defaultWidth = 270.0 + previewWidth`），目標是寬螢幕桌面視
  窗，而非窄視窗。
  <!-- evidence: macos/Runner/MainFlutterWindow.swift:9-19 -->
  側欄本身可由使用者拖曳把手，在 180px 到 600px 之間自由調整寬度。
  <!-- evidence: lib/views/main_screen.dart:71-78 -->
- **解碼是委託出去的，而非重新實作。** RAW 解碼屬於姊妹專案 Ceyx；Halcyon 是在真實產
  品條件下——UI 執行緒的即時反應、分層預覽／完整尺寸載入、資料夾規模的批次工作流程——
  使用該解碼引擎的應用程式。
- **對範圍誠實以對。** 桌面是目標平台。行動裝置與網頁建置目標存在且可編譯，但介面本身
  並未針對觸控操作調整。
  <!-- evidence: pubspec.yaml has no platform restriction, standard Flutter multi-platform project; this claim is scope framing, not a measured behaviour -->

### 姊妹專案：Ceyx

Halcyon 以一般的 Dart path 相依方式，依賴 Ceyx 的 `plugin/` 目錄：

```yaml
ceyx:
  path: ../ceyx/plugin
```
<!-- evidence: pubspec.yaml:46-47 -->

這是單純的相依關係，不是分支（fork）也不是子專案：Ceyx 必須以並排（sibling）簽出的
形式存在於本儲存庫旁邊，`flutter pub get` 才能成功執行；Halcyon 自己在該相依項旁的
註解也記錄了它刻意依賴 `plugin/` 套件、而非 Ceyx 自己的 `app/`，以避免把該 app 的測試
輔助相依項一併拖進 Halcyon 的建置流程。
<!-- evidence: pubspec.yaml:42-47 -->
