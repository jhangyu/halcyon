## 從原始碼建置

### 先決條件

| 需求 | 本樹已驗證的版本 | 備註 |
|---|---|---|
| Flutter SDK | 3.44.6 | Dart 3.12.2；`pubspec.yaml` 宣告 `sdk: ^3.9.0` |
| Ceyx 簽出 | 相鄰目錄 | 必須位於相對於本儲存庫的 `../ceyx` |
| JDK（僅 Android 需要） | Temurin 25，或 Homebrew 的 `openjdk@21` / `openjdk@17` | 由建置腳本按此順序自動選擇 |
| Gradle（僅 Android 需要） | 9.1.0 | 由 wrapper 鎖定版本 |
| Android Gradle Plugin | 9.0.1 | Kotlin 2.3.21 |

<!-- evidence: pubspec.yaml:22 (sdk constraint), flutter --version output 2026-08-26 -->
<!-- evidence: pubspec.yaml:46-47 (ceyx path dependency) -->
<!-- evidence: scripts/build_apps.py:232-234 (JDK search order), scripts/build_apps.py:448 (PATH fallback warning) -->
<!-- evidence: android/gradle/wrapper/gradle-wrapper.properties:5, android/settings.gradle.kts:22-23 -->

**Ceyx 相鄰簽出不是可有可無的。** `pubspec.yaml` 將解碼器宣告為指向 `../ceyx/plugin` 的相對路徑相依套件，因此該目錄不存在時 `flutter pub get` 會直接失敗。請把 Ceyx 複製到 Halcyon 旁邊，而不是放進 Halcyon 裡面。

<!-- evidence: pubspec.yaml:46-47 -->

Android 建置另外要求保持相容模式開啟——在 `android/gradle.properties` 中的 `android.newDsl=false` 與 `android.builtInKotlin=false`——因為 Flutter 的 Gradle 外掛尚未支援 AGP 9 的新 DSL。移除這兩行會使 Android 建置失敗。

<!-- evidence: android/gradle.properties:4-5, memory.md G-009 -->

### 開發時執行

```bash
flutter pub get
flutter run -d macos     # also: -d chrome, or a connected device id
flutter analyze          # must report 0 issues
flutter test             # full suite
```

### 發行版建置

`scripts/build_apps.py` 是唯一的建置入口。它會為每個目標建置原生解碼器與 Flutter 應用程式，並且取代了先前各平台各自的 shell 與 PowerShell 腳本，那些腳本已被刪除。不要重新引入各平台獨立的腳本。

```bash
python3 scripts/build_apps.py              # macOS release, the default target
python3 scripts/build_apps.py android --release
python3 scripts/build_apps.py web
python3 scripts/build_apps.py all          # every target this host can build
python3 scripts/build_apps.py --check      # toolchain check only, builds nothing
```

<!-- evidence: scripts/build_apps.py:249-266 (target table), scripts/build_apps.py:1599 (target argument) -->

目標平台包括 `macos`、`ios`、`android` / `android-apk` / `android-aab`、`web`、`windows`、`linux`，以及 `all`。`all` 這個目標會依主機能力過濾，對這台主機無法建置的目標會跳過而不是失敗；`ios` 被刻意排除在 `all` 之外，這樣無人值守的執行就永遠不必做出程式碼簽署的決定。`windows` 與 `linux` 必須在各自的作業系統上建置。

<!-- evidence: scripts/build_apps.py:249-266 -->

### 色彩閘門

原生解碼器函式庫在通過 runbook S4 色彩閘門之前是不受信任的——這是一個藍天樣本檢查，斷言藍色通道的數值高於紅色通道,用來抓出色彩矩陣接錯的解碼器。建置流程的 Phase 0 會拒絕放置未經過閘門檢驗的函式庫。

- 每當有原生建置需要進行時，透過 `--cfa-sample-dng <file>` 傳入一張藍天 DNG 樣本。
- `--no-colour-gate` 是刻意張揚的跳過選項。使用它的執行**一律以 exit code 2 結束，絕不會是 0**，而且產出的函式庫會被標記為未經驗證。

<!-- evidence: scripts/build_apps.py:927-932 (Phase 0 refusal), scripts/build_apps.py:1220-1226 (skip warning), scripts/build_apps.py:1622-1624 (--no-colour-gate exits 2), scripts/build_apps.py:1721 -->

### 建置產出物與哪些屬於原始碼

建置產出物會落在根目錄的 `build/` 之下。`android/`、`ios/`、`macos/`、`web/`、`windows/` 與 `linux/` 這些目錄是原始碼與設定，不是建置產出物——它們會保留在版本控制中。

### 關於 Windows 路徑的說明

`scripts/build_apps.py` 從未實際端到端跑過 Windows 原生建置。請把該腳本第一次真正在 Windows 上執行視為初次接觸，而不是回歸測試。底層的 CMake/MSVC 路徑本身並非未經驗證——上游有一個 commit 加入了這條路徑,並在一台真實的 Windows 機器上手動建置出目前隨附的 `dng_decoder_native.dll`——但那次建置沒有留下 S4 色彩閘門的執行紀錄,因此這個 DLL 屬於「先用再驗」（trust-on-first-use）狀態。

<!-- evidence: CLAUDE.md, Commands section -->
