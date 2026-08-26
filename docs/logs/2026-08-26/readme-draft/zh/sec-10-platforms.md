## 平台支援

Halcyon 首先是一個桌面應用程式。六個 Flutter 目標平台都能編譯，但它們並不對等：桌面目標是介面設計時鎖定的對象，行動目標能建置並執行但沒有觸控適配的版面，另外有三個目標完全沒有原生 RAW 解碼器。

### 支援矩陣

| 目標平台 | 可建置 | 介面 | 原生 RAW 解碼 | 系統資源回收筒 | 從檔案管理員「開啟方式」 |
|---|---|---|---|---|---|
| macOS | 可以，僅限 arm64 | 為此平台設計 | 有 | 有 | 有 |
| Windows | 可以，需在 Windows 主機上 | 桌面版面，測試較少 | 有 | 有，透過 `IFileOperation` | 無 |
| Linux | 可以，需在 Linux 主機上 | 桌面版面，測試較少 | 無 | 無 — 退回資料夾內回收模式 | 無 |
| Android | 可以 | 可編譯；未針對觸控適配 | 有 | 無 | 無 |
| iOS | 可以，預設未簽署 | 可編譯；未針對觸控適配 | 無 | 無 | 無 |
| Web | 可以 | 可編譯；未適配 | 無 | 無 | 無 |

<!-- evidence: scripts/build_apps.py:249-266 (TARGET_HELP / ALL_TARGETS) -->
<!-- evidence: scripts/build_apps.py:265-270 (NATIVE_SPECS covers macos, windows, android only; the comment names web, ios and linux as having no native decoder) -->
<!-- evidence: macos/Runner/AppDelegate.swift:23,42 (exactly two channels: halcyon/trash, halcyon/open_with) -->

### 這些缺口在實務上代表什麼

**Linux、iOS 與 web 沒有原生解碼器。** Ceyx 解碼函式庫只針對 macOS、Windows 與 Android 建置。在另外三個目標平台上，完整 RAW 解碼路徑並不存在，因此 RAW 檔案只有在其容器內含有夠大的內嵌 JPEG 預覽時才能顯示。多數現代相機都會寫入這類預覽，所以瀏覽通常仍然可行——但沒有內嵌預覽的檔案在這些平台上就是無法顯示。

<!-- evidence: scripts/build_apps.py:265-270 -->

**兩座原生橋接，實作程度不一。** macOS 在 `macos/Runner/AppDelegate.swift` 中註冊了兩座 `MethodChannel` 橋接：`halcyon/trash` 用於將檔案移到系統垃圾桶，`halcyon/open_with` 用於接收透過 Finder 開啟照片時傳入的檔案路徑。Windows 在 Win32 的 `IFileOperation` API 之上實作了 `halcyon/trash`，因此系統資源回收筒在該平台上也能運作。Android、iOS、Linux 與 web 兩座橋接都沒有，這些平台上的刪除一律走資料夾內回收模式——這是一項完整的功能，不是被閹割的替代方案。

<!-- evidence: macos/Runner/AppDelegate.swift:12,23,42 -->
<!-- evidence: windows/runner/halcyon_channels.cpp:51, windows/runner/halcyon_trash.cpp:1, windows/runner/halcyon_native.h:53 -->

**macOS 建置僅限 arm64，** 因為隨附的解碼器函式庫僅支援 arm64。若要建置 Intel Mac 版本，得先取得 x86_64 或通用架構的解碼器函式庫。

<!-- evidence: CLAUDE.md, scripts/build_apps.py --macos-arch option at scripts/build_apps.py:1636 -->

**影像載入在所有平台上都是純 Dart 實作。** 沒有原生縮圖通道；單一 Dart 進入點在每個平台上都會產出影像位元組。平台差異僅侷限於上述兩座 macOS 橋接。

<!-- evidence: lib/services/image_pipeline/dart_image_loader.dart, memory.md AD-020 -->
