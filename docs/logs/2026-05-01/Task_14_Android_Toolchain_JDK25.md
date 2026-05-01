---
date: 2026-05-01T00:00:00
task: "14 — Android Toolchain JDK 25 Upgrade"
status: success
---

## 🧭 檔案維護政策

**用途**：Unified Task Log，記錄 Android build toolchain 升級與 JDK 25 驗證過程。

**更新時機**：調整 Gradle / AGP / Kotlin / JDK / Android SDK 版本，或 Android build 腳本相容性變更時更新。

**必填欄位**：`date`、`task`、`status`、Summary、Implementation Plan、Execution Log、Walkthrough。

---

## 1. Summary

使用者希望確認是否能升級 Gradle / Android Gradle Plugin / Kotlin，使 Android build 可使用 Temurin JDK 25。原先組合為 Gradle 8.12、AGP 8.9.1、Kotlin 2.1.0；在 JDK 25 下會於 Gradle Kotlin DSL 階段失敗並顯示 `IllegalArgumentException: 25.0.2`。

## 2. Implementation Plan

1. 嘗試升級到支援 Java 25 的 Gradle 9.1.0。
2. 嘗試 AGP 9.0.1 與 AGP 9 built-in Kotlin。
3. 若 Flutter Gradle Plugin 不相容，改用 AGP 9 相容模式：`android.newDsl=false`、`android.builtInKotlin=false`，並搭配 Kotlin Gradle Plugin 2.3.21。
4. 以 Temurin JDK 25 執行 Android release build。
5. 更新 `scripts/build.sh`、`unit_test.md`、`README.md`、`docs/flutter_app_README.md` 與核心狀態文件。

## 3. Execution Log

### ⏹️ 中斷點快照 (Breakpoint Snapshot)
- **已完成**: Android toolchain 已升級並通過 JDK 25 build；核心文件已依 `rule.md` 同步。
- **下一步**: 回到 Task 12，實作 Trash MethodChannel。
- **待確認**: 未來 Flutter 升級後，是否移除 AGP 9 相容模式並遷移到 built-in Kotlin / new DSL。

### 2026-05-01 — 嘗試 AGP 9 built-in Kotlin

- 升級 `android/gradle/wrapper/gradle-wrapper.properties` 到 Gradle 9.1.0。
- 升級 `android/settings.gradle.kts` 的 AGP 到 9.0.1。
- 移除 app module 的 `org.jetbrains.kotlin.android` plugin，改測 AGP 9 built-in Kotlin。
- 結果：失敗。Flutter 3.35.1 內建的 `dev.flutter.flutter-gradle-plugin` 在 AGP 9 new DSL 下取得 Android extension 時觸發 NullPointerException。

### 2026-05-01 — AGP 9 相容模式

- 恢復外部 Kotlin plugin，升級到 Kotlin Gradle Plugin 2.3.21。
- 啟用 AGP 9 相容旗標：
  - `android.newDsl=false`
  - `android.builtInKotlin=false`
- 將 Kotlin JVM target 改為 `compilerOptions` DSL。
- 補上 `android/app/proguard-rules.pro`，避免 AGP 9 / R8 release shrinker 找不到專案規則檔。
- 指定 `ndkVersion = "28.2.13676358"`，對齊 Android plugin dependencies 要求。

## 4. Walkthrough

驗證命令：

```bash
./scripts/build.sh android
flutter test
```

驗證結果：

- `./scripts/build.sh android`：成功，使用 Temurin JDK 25，產出 `build/app/outputs/flutter-apk/app-release.apk`。
- `flutter test`：成功，11 tests passed。

已知警告：

- Gradle 9.1.0 在 JDK 25 下會顯示 native access warning；目前不影響 build。
- AGP 9 相容模式會顯示 `android.newDsl=false`、`android.builtInKotlin=false`、`org.jetbrains.kotlin.android` plugin deprecated 警告；這是為了維持 Flutter 3.35.1 Gradle plugin 相容性。
