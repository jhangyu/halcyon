## 第三方歸屬

Halcyon 自己在這個 repository 裡的原始碼沒有宣告任何授權條款——repository 根目錄
沒有 `LICENSE` 檔案，`pubspec.yaml` 裡也沒有 `license:` 欄位。
<!-- evidence: pubspec.yaml:1-19 -->
Halcyon *實際*綑綁的，是一組在 `pubspec.yaml` 中宣告的 Dart 套件，再加上——透過
姊妹專案 Ceyx 間接引入的——原生 RAW/DNG 解碼堆疊，這個堆疊由 Ceyx 編譯，並由
Halcyon 在每個平台上一起打包進自己的 app 執行檔內。

| 元件 | 授權 | 備註 |
|---|---|---|
| 直接的 Dart 相依套件（`provider`、`path`、`image`、`exif`、`desktop_drop` 等） | 多為 MIT / BSD-3-Clause / Apache-2.0 | 逐套件的認定列在連結文件中；不是基於生態系的假設 |
| Adobe DNG SDK | Adobe DNG SDK License Agreement | 透過 `ceyx` 間接引入 |
| LibRaw, RawSpeed3 | LGPL-2.1（靜態連結） | 透過 `ceyx` 間接引入；帶有原始碼提供義務——見下方的未決問題 |
| Halide, pugixml, LibRaw-cmake | MIT | 透過 `ceyx` 間接引入 |
| libjpeg-turbo, zlib, x3f-tools | 寬鬆授權（IJG/BSD/zlib/BSD-3-Clause） | 透過 `ceyx` 間接引入 |

完整的清點——確切版本、各套件授權文字的來源，以及每一項歸屬背後的推理——收錄在
[`docs/legal/THIRD_PARTY_LICENSES.md`](docs/legal/THIRD_PARTY_LICENSES.md)。

其中有一項不是已定案的事實，在該文件中被明確標記為一個未解決的法律問題，而非在此
處被解決：LibRaw 與 RawSpeed3 是 LGPL-2.1 授權，並且被靜態連結進 Halcyon 打包出貨
的原生函式庫中，這使得 Halcyon 有義務向該執行檔的接收者提供原始碼或可重新連結的
目的檔（object）。Ceyx 自身的原始碼提供是否已經涵蓋了一個發行版 Halcyon 建置，
還是 Halcyon 的發行流程需要一份獨立的原始碼提供，這一點尚未確定，需要在 Halcyon
被散布到這個開發環境之外之前經過法律審查。
