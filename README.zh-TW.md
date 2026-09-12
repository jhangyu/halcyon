# Halcyon

*[English version](README.md)*

Halcyon 是一款支援 Windows、macOS、Linux 的 GPU 加速 RAW 照片挑選工具——全鍵盤操作，
以 JPG 等級的速度挑選、標記、重新命名全解析度 RAW 檔案。
<!-- evidence: lib/views/main_screen.dart:104-129 keyboard shortcut handler; lib/services/library/photo_file_actions.dart batch copy/move -->

![主頁面](docs/images/main_page.webp)

*主頁面瀏覽畫面*

![依 EXIF 重新命名對話框](docs/images/exif_rename.webp)

*EXIF 重新命名對話框*

![匯出設定](docs/images/export_settings.webp)

*匯出設定畫面*

![效能設定](docs/images/performance_settings.webp)

*效能設定畫面*

![主題設定](docs/images/theme_settings.webp)

*主題設定畫面*

![快捷鍵設定](docs/images/shortcut_settings.webp)

*快捷鍵設定畫面*

### 名稱由來

Halcyon 與 Ceyx 都是翠鳥屬名。希臘神話中，阿爾庫俄涅（Alcyone）與刻宇克斯（Ceyx）
化身翠鳥——這兩個儲存庫因此成對命名：Ceyx 是解碼引擎，Halcyon 則是建構於其上的應用程式。
<!-- evidence: docs/logs/2026-08-26/readme-draft/BRIEFING.md:46-49 (shared framing agreed for both READMEs); ../ceyx/README.md:56-65 "Sister project: Halcyon" section states the same pairing and dependency direction -->

### 核心特色

- **以 JPG 等級的速度解碼全解析度 RAW。** 解碼引擎以 Halide 從零重寫 libraw / Adobe DNG SDK
  的解碼邏輯，儘可能將高運算負載轉移到閒置的 GPU 上。在本機儲存裝置上實測：一張 24 MP RAW
  的解碼運算成本約 56 毫秒，批次模式下每秒可持續處理約 30–34 張——詳見
  [實測效能](#實測效能)。
- **真正的跨平台桌面應用。** 以 Flutter 開發，同時支援 Windows、macOS、Linux 三大平台；
  解碼核心以 C++ / Halide 撰寫，依平台使用 Metal 或 Vulkan 進行硬體加速。Android 已可編譯
  （手機版介面尚未設計），iOS 支援亦保留未來可能性。
- **廣泛的 RAW 格式支援。** 十種 RAW 容器格式皆可在 GPU 上完整解碼至全解析度，其中針對素以
  解碼緩慢著稱的 Fuji X-Trans 6x6 馬賽克與 Sigma Foveon 線性 RGB 排列，分別配有專屬的 Halide
  核心，而非退回 CPU 處理；另外三種較舊的容器格式（CR2、IIQ、MRW）目前僅能透過內嵌預覽圖瀏覽
  ——詳見 [RAW 格式支援與解碼路由](#raw-格式支援與解碼路由)。同時 Halcyon 也修正了 libraw
  預設偏灰、偏暗的色調曲線，讓 RAW 預覽的明暗更貼近相機自身的 JPEG 出圖。
- **依顯示需求選擇解碼路徑。** Halcyon 一律優先使用現成的 JPG，或 RAW/DNG 檔內嵌的全尺寸
  JPEG 預覽來顯示；只有在檔案未內嵌全尺寸預覽時，才會啟動完整的硬體加速 RAW 解碼路徑。
- **精心調校的預載策略，實現零延遲瀏覽。** 在 1:1 放大模式下於多張 RAW 檔間快速切換完全
  無感延遲，讓攝影師能一路看片不被讀檔打斷，迅速進入心流狀態。
- **只有兩種標記的高效挑選邏輯。** 保留或淘汰，僅此兩種，專為拍攝現場的快速挑片而設計。
  標記與瀏覽進度會直接寫入照片資料夾，即使關閉重開，甚至意外當機，也能從上次的位置繼續。
- **把垂直空間留給照片的介面設計。** 多數看圖軟體把縮圖列放在預覽下方，但照片多為 3:2 或
  4:3 比例，螢幕卻是 16:9——縮圖列因此擠佔了照片最需要的垂直空間。Halcyon 改將縮圖與控制項
  集中於側欄，把整個視窗高度都還給照片本身。
- **內建 EXIF 快速重新命名。** 各家相機預設的流水號檔名，在挑片時總是一團亂。Halcyon 內建
  完整的 EXIF 重新命名工具，可依自訂 EXIF 樣板直接為資料夾中的照片重新命名，混搭不同素材
  來源的過片流程不再是惡夢。

### 姊妹專案：Ceyx

Halcyon 用普通的 Dart path 相依方式，依賴 Ceyx 的 `plugin/` 目錄：

```yaml
ceyx:
  path: ../ceyx/plugin
```
<!-- evidence: pubspec.yaml:46-47 -->

這只是單純的相依關係，不是分支（fork），也不是子專案：Ceyx 必須以並排（sibling）簽出的
形式放在本儲存庫旁邊，`flutter pub get` 才跑得起來；Halcyon 在該相依項旁的註解也記下了原因——
刻意依賴 `plugin/` 套件而非 Ceyx 自己的 `app/`，避免把那個 app 的測試輔助相依項一併拖進
Halcyon 的建置流程。
<!-- evidence: pubspec.yaml:42-47 -->

---

## 目錄

- [挑選工作流程（triage workflow）](#挑選工作流程triage-workflow)
- [持久化、還原與批次操作](#持久化還原與批次操作)
- [依 EXIF 重新命名](#依-exif-重新命名)
- [RAW 格式支援與解碼路由](#raw-格式支援與解碼路由)
- [實測效能](#實測效能)
- [快取與記憶體管理](#快取與記憶體管理)
- [架構](#架構)
- [架構圖](#架構圖)
- [平台支援](#平台支援)
- [從原始碼建置](#從原始碼建置)
- [測試與品質閘門](#測試與品質閘門)
- [第三方歸屬](#第三方歸屬)
- [文件維護](#文件維護)

---

## 挑選工作流程（triage workflow）

核心迴圈很簡單：開啟一個資料夾、用鍵盤瀏覽、標記要留與要丟的照片、進下一張。以下就是你面對
一整張裝滿 RAW 與 JPG 檔案的記憶卡時，實際會發生的事。

```mermaid
flowchart TD
    A(["開啟照片資料夾"]) --> B["掃描資料夾<br/>把 RAW + JPG 姊妹檔分組"]
    B --> C(["用 ← / → 瀏覽"])
    C --> D{"這張照片<br/>看起來如何？"}
    D -- "想留" --> E["按 S 加星號<br/>啟用自動前進就跳下一張"]
    D -- "想丟" --> F["按 X 標記垃圾桶<br/>啟用自動前進就跳下一張"]
    D -- "還沒決定" --> C
    E --> C
    F --> C
    E --> G(["每個標記即時寫入磁碟"])
    F --> G

    classDef start fill:#a5f3fc,stroke:#22d3ee,stroke-width:2px,color:#0e2a33;
    classDef decision fill:#fde68a,stroke:#fbbf24,stroke-width:2px,color:#3a2a04;
    classDef fast fill:#86efac,stroke:#4ade80,stroke-width:2px,color:#0b3320;
    classDef slow fill:#c4b5fd,stroke:#a78bfa,stroke-width:2px,color:#2a1c4d;
    classDef done fill:#a5f3fc,stroke:#22d3ee,stroke-width:2px,color:#0e2a33;

    class A start;
    class B slow;
    class C start;
    class D decision;
    class E fast;
    class F slow;
    class G done;
```

### 開啟資料夾

把 Halcyon 指向一個資料夾，它會列出**直接放在裡面**的照片——不會遞迴進子資料夾。隱藏檔案
（任何以點開頭的名稱，包括 macOS 在某些記憶卡上散落的 AppleDouble 側車檔）一律跳過，只有
支援格式的檔案才會顯示。

支援的格式：

| 類別 | 格式 |
|---|---|
| 一般影像檔 | JPG、PNG、WebP、TIFF、HEIC／HEIF |
| RAW，完整解碼 | DNG、ARW、CR3、NEF、RAF、RW2、ORF、PEF、SRW、X3F |
| RAW，僅供瀏覽 | CR2、IIQ、MRW |

一般影像格式有幾個值得知道的細節：

- **WebP** 在所有平台都能顯示。動態 WebP 只顯示第一個影格。
- **TIFF** 支援常見的形式（分條式與分塊式、8／16／32 位元、LZW／PackBits／Deflate／未壓縮）；
  16 位元以 8 位元顯示，多頁檔只顯示第 1 頁。少數罕見壓縮（CCITT 傳真、TIFF 內嵌 JPEG）不支援，
  會顯示為無法讀取。
- **HEIC／HEIF** 使用內建打包的解碼器，因此一張 HEIC 在每個平台看起來都一樣，不必仰賴作業系統。
  含多張影像的檔案（連拍、Live Photo、深度圖）只顯示主影像；HDR 增益圖與深度圖一律忽略。
  AVIF 不支援。

RAW 格式，以及「完整解碼」與「僅供瀏覽」之間的差別，詳見下文「RAW 格式支援與解碼路由」。凡是
會被掃描列出的檔案——包括僅供瀏覽的 RAW 格式——都能像其他照片一樣加星號、標記垃圾桶、重新
命名與批次搬移。

### RAW 與 JPG 的姊妹檔分組

如果你以 RAW+JPG 拍攝，每按一次快門就會寫出兩個檔案，它們共用同一個檔名、只差在副檔名。
Halcyon 會把它們分組：一張 RAW 與其同名 JPG（以及任何隱藏側車檔）合成側邊欄裡的**一個項目**，
只有一個星號／垃圾桶標記、一列供你互動的資料，不管背後有幾個檔案。

顯示時，Halcyon 會優先選同名的 JPG 或 PNG（開啟最快），只在群組全是 RAW 時才退回 RAW。

分組也會改變預設的刪除行為：只要資料夾裡有任何 RAW+JPG 配對，就會自動以回收模式（資料夾內的
`.trash`，見下文）開始，而非永久刪除——正在挑選的記憶卡，不該因為一次誤點就連 RAW 一起丟。
每個標記或刪除都作用在整個群組上，因此 RAW 與其 JPG 姊妹檔永遠作為同一個單位一起移動。

### 標記、導覽與縮放

除了「未標記」，一張照片可以被**加星號**（要留）或**標記垃圾桶**（要丟）。標記是切換式的：
再按一次同一個標記會清除它；按另一個標記則切換過去。清除標記不會移動你的位置；設定新標記時，
若開啟了**自動前進**（預設關閉，會在不同工作階段間記住），就會前進到下一張。

左右鍵依順序在資料夾中移動，頭尾都不會循環。縮放每按一次以 ×1.25 放大或縮小，上限 5×，縮小
回來時會俐落地吸附回原尺寸，不會讓畫面停在偏移的位置。切換照片時縮放層級會維持不變——從一張
換到下一張不會把它重置。

### 鍵盤快捷鍵

整個挑選迴圈的設計，就是讓你不必離開鍵盤：

| 按鍵 | 動作 |
|---|---|
| `←` | 上一張照片 |
| `→` | 下一張照片 |
| `↑` | 放大（每次 ×1.25，最高 5×）|
| `↓` | 縮小（每次 ×1.25，接近 1× 會吸附回原尺寸）|
| `S` | 切換目前照片的星號標記 |
| `X` | 切換目前照片的垃圾桶標記 |
| `R` | 切換回收模式（資料夾內的 `.trash` vs. 系統／永久刪除）|

如果你偏好用滑鼠，星號與垃圾桶按鈕也會浮在影像上方。回收模式可以用鍵盤的 `R` 切換，或用右鍵
點擊垃圾桶按鈕——左鍵點它只是照常標記目前這張照片。

### 挑選過程中的畫面回饋

簡短的狀態訊息會出現在視窗底部，完整顯示幾秒後淡出，因此它們不會堆積或擋住畫面。其中兩則
直接來自挑選迴圈：

- 若你開啟的資料夾是**唯讀**的，會顯示一次性警告——在資料夾開啟時出現一次，不會每次標記都跳。
  Halcyon 的判斷方式是實際嘗試寫入一個小檔案再刪除，因為記憶卡的權限位元可能說謊（一張 exFAT
  記憶卡可能看起來可寫，實體防寫鎖卻擋下每一次寫入）。
- 若資料夾根本無法掃描（例如權限錯誤），會顯示錯誤訊息，說明哪裡出了問題。

---

## 持久化、還原與批次操作

### 一次篩選作業永遠不會遺失

在資料夾整理到一半時關閉 Halcyon，之後再重新開啟同一個資料夾，畫面會回到原本那張照片，所有
星號與垃圾桶標記都完好無缺。標記不是只存在記憶體裡——你一做出標記就會立刻寫入磁碟，你當時
所在的照片也會被記住。

```mermaid
flowchart TD
    A(["標記或導覽"]) --> B["更新資料夾的<br/>狀態檔到磁碟"]
    B --> C["先寫暫存檔，<br/>再更名就定位"]
    C --> D(["資料夾永遠只保有<br/>一份完整的狀態檔"])
    D -. "之後" .-> E(["重新開啟同一個資料夾"])
    E --> F{"上次那張照片<br/>還在資料夾裡嗎？"}
    F -- "在" --> G["回到那張照片<br/>所有標記都還原"]
    F -- "不在" --> H["從頭開啟<br/>標記仍會還原"]

    classDef start fill:#a5f3fc,stroke:#22d3ee,stroke-width:2px,color:#0e2a33;
    classDef decision fill:#fde68a,stroke:#fbbf24,stroke-width:2px,color:#3a2a04;
    classDef fast fill:#86efac,stroke:#4ade80,stroke-width:2px,color:#0b3320;
    classDef slow fill:#c4b5fd,stroke:#a78bfa,stroke-width:2px,color:#2a1c4d;
    classDef done fill:#a5f3fc,stroke:#22d3ee,stroke-width:2px,color:#0e2a33;

    class A,E start;
    class B,C slow;
    class D done;
    class F decision;
    class G fast;
    class H slow;
```

#### 狀態檔

Halcyon 開啟的每個資料夾都有自己專屬的小狀態檔（`.halcyon_status.json`），就寫在照片旁邊。
它是純粹、人類可讀的 JSON：每張被標記的照片對應到「starred」或「trashed」（未標記的照片單純
不列入），再加上一筆記錄你上次看到哪張照片，以及該資料夾儲存的重新命名規則。刻意選純 JSON
而非資料庫——這個檔案跟照片放在一起，因此當你把資料夾複製到別台機器或備份時，它會一併跟著走，
你也能在 diff 裡直接讀懂它。

因為標記存在每個資料夾內部，它們始終自成一體：開啟第二個資料夾，它會保有自己獨立的標記——
不同拍攝場次之間永不互相污染。而且萬一狀態檔損毀或無法讀取，資料夾仍能開啟（只是不還原標記）
——遺失標記可以復原，無法存取照片就不行了。

#### 重新開啟時還原

重新開啟資料夾時，只要你上次看到的那張照片還在，Halcyon 就會帶你回到它。它會在你停留在一張
照片幾秒後才記錄位置，因此快速用方向鍵瀏覽時不會每按一次就狂寫磁碟。

#### 耐用性：能扛住當機與拔卡

標記與瀏覽位置指標都透過單一有序佇列儲存，因此兩次儲存絕不會互相競爭而覆蓋彼此。每一次儲存
都先寫進暫存檔、再更名就定位，因此拔卡或寫到一半當機也絕不會留下寫到一半的檔案——資料夾裡
永遠只會是完整的舊檔，或完整的新檔，不會是撕裂中的半成品。

#### 重新命名與標記

標記是綁在檔名上的。如果你用**其他**工具改照片的名字，綁在舊檔名上的標記就會孤立——不再對應
資料夾裡任何東西。Halcyon 自己的重新命名功能會避免這件事：在重新命名的同時把每個標記（與瀏覽
位置指標）搬到新檔名上，因此星號與垃圾桶標記都能在 app 內完成的重新命名之後存活下來。

### 批次操作

一旦你把要留的照片加了星號，Halcyon 就會把它們當成一批來處理：

```mermaid
flowchart TD
    A(["已加星號的留存照片"]) --> B{"你想<br/>做什麼？"}
    B -- "複製／移動" --> C["複製或移動到<br/>目的地資料夾"]
    B -- "分享" --> D["匯出縮放後的 JPEG<br/>供社群媒體使用"]
    A2(["標記垃圾桶的照片"]) --> E{"用哪條<br/>刪除路徑？"}
    E -- "系統垃圾桶<br/>（macOS／Windows）" --> F["可從作業系統的<br/>垃圾桶救回"]
    E -- "回收模式<br/>（任何平台）" --> G["移到資料夾內的<br/>.trash 子資料夾"]

    classDef start fill:#a5f3fc,stroke:#22d3ee,stroke-width:2px,color:#0e2a33;
    classDef decision fill:#fde68a,stroke:#fbbf24,stroke-width:2px,color:#3a2a04;
    classDef fast fill:#86efac,stroke:#4ade80,stroke-width:2px,color:#0b3320;
    classDef slow fill:#c4b5fd,stroke:#a78bfa,stroke-width:2px,color:#2a1c4d;

    class A,A2 start;
    class B,E decision;
    class C,F fast;
    class D,G slow;
```

#### 複製與移動已加星號的照片

你加了星號的照片可以整批複製或移動到你選定的資料夾。一張 RAW 與其同名 JPG 會作為同一個單位
一起搬動（macOS 產生的任何隱藏側車檔也會一併清除，不會殘留在目的地）。若目的地已有同名檔案，
它會保留不動而非被覆蓋；一次失敗也不會中止整批——其餘每個檔案仍會嘗試，任何失敗都會收集起來
顯示給你，而不是被靜默吞掉。

#### 社群媒體匯出

已加星號的照片也可以匯出為適合社群媒體尺寸的 JPEG——一張照片一個檔案，長邊上限 2048px，維持
長寬比，以 JPEG 品質 90 編碼。重要的 EXIF 欄位（相機廠牌與型號、拍攝日期、作者、曝光、光圈、
焦距、鏡頭、ISO 與 GPS）會從原始檔重新讀出，附加回縮放後的副本。匯出一次只跑幾個，以在大批次
時控制記憶體用量。

#### 兩種刪除路徑

Halcyon 提供兩種截然不同的刪除方式：

| 路徑 | 作用 | 可救回？ | 平台 |
|---|---|---|---|
| 系統垃圾桶 | 把檔案移到作業系統的垃圾桶 | 可，從作業系統垃圾桶救回 | macOS、Windows |
| 資料夾內回收模式 | 把檔案移到照片旁的 `.trash` 子資料夾 | 可，仍在記憶卡上 | 任何平台 |

回收模式是最保險的選項：它把要丟照片的每一個檔案——包括其 RAW 姊妹檔與任何隱藏側車檔——移到
照片旁的 `.trash` 子資料夾。因為那是同一個磁碟內的移動，所以是即時的（不複製任何資料），即使
在系統垃圾桶不可用的記憶卡上也能運作。若檔名與先前的回收批次相撞，檔案絕不會被覆蓋——會依序
加上 `-1`、`-2` 後綴，直到找到可用的檔名。回收模式以資料夾為單位，對含有 RAW+JPG 配對的資料夾
會自動開啟；你隨時可以用 `R` 切換。

若刪除失敗，Halcyon 會停下來，清楚列出哪些檔案失敗及原因——一次靜默無效的刪除，看起來跟正常
運作的 app 沒有兩樣。成功的回收模式批次則會顯示一則簡短訊息，附上移動的檔案數，提醒你這些檔案
仍在磁碟上的 `.trash` 裡，並未被永久刪除。

---

## 依 EXIF 重新命名

攝影師習慣依拍攝日期、相機、鏡頭或序號為檔案命名，而且命名格式通常是自家慣例，不會是相機
寫入記憶卡的原始檔名。Halcyon 的重新命名功能讓你寫一次命名樣板，就能套用到整個資料夾。每個
RAW 檔、它的 JPG 對應檔，以及任何隱藏的側車檔，都會一起改成相同的新基底檔名，所以 RAW+JPG
配對絕不會被拆散。

### 樣板怎麼運作

樣板就是一段夾帶 `{佔位符}` 的文字，例如 `{YYYY}-{MM}-{DD}-{hh}-{mm}-{ss}`。Halcyon 會用
照片的 EXIF 中繼資料（日期則以檔案本身的時間戳作為後備）填入每個佔位符。以下是你可以使用的
所有佔位符，分組方式與「Insert variable」面板一致：

| 分組 | 佔位符 | 會變成什麼 | 範例 |
|---|---|---|---|
| 日期與時間 | `{YYYY}` | 拍攝年份，4 位數 | `2026` |
| 日期與時間 | `{MM}` | 拍攝月份，2 位數 | `08` |
| 日期與時間 | `{DD}` | 拍攝日期，2 位數 | `26` |
| 日期與時間 | `{hh}` | 拍攝小時，2 位數 | `14` |
| 日期與時間 | `{mm}` | 拍攝分鐘，2 位數 | `07` |
| 日期與時間 | `{ss}` | 拍攝秒數，2 位數 | `33` |
| 相機 | `{camera}` | 相機型號 | `Z 8` |
| 相機 | `{lens}` | 鏡頭型號 | `NIKKOR Z 24-70mm f_2.8 S` |
| 相機 | `{make}` | 相機製造商 | `NIKON CORPORATION` |
| 相機 | `{artist}` | 作者／版權標籤 | `J. Chen` |
| 拍攝參數 | `{f}` | 光圈，格式為 `f<數值>` | `f2.8` |
| 拍攝參數 | `{focal}` | 焦距，格式為 `<數值>mm` | `35mm` |
| 拍攝參數 | `{iso}` | ISO，格式為 `ISO<數值>` | `ISO400` |
| 拍攝參數 | `{shutter}` | 快門速度 | `1/250` |
| 拍攝參數 | `{direction}` | GPS 拍攝方向，取整數度 | `187` |
| 檔案 | `{seq}` | 會撞名的檔案之間的序號；可補零，如 `{seq:3}` → `007` | `1` |
| 檔案 | `{orig}` | 原始檔名（不含副檔名） | `DSC_0431` |

有幾點值得知道：

- **日期一定填得出來**——EXIF 沒有拍攝日期或讀不到時，日期與時間佔位符退回檔案的修改時間。
- **缺失的標籤會留白**，不會把 `{camera}` 原封不動留在檔名裡。
- **打錯字會在動手前被攔下**——用到未知佔位符的樣板會標示「Unknown variable {name}」，
  「Run」按鈕維持停用。
- **檔名一定合法**——會破壞檔名的字元（`/`、`:`、`\`、NUL）替換成 `_`，所以 `1/250` 這樣的
  快門速度不會不小心建出子資料夾。

### 內建預設樣板

應用程式內建四組現成的預設樣板。以一張 2026-08-26 14:07:33 拍攝、原始檔名為 `DSC_0431`
的照片為例，渲染結果如下：

| 預設 | 樣板 | 渲染範例 |
|---|---|---|
| Date & time | `{YYYY}-{MM}-{DD}-{hh}-{mm}-{ss}` | `2026-08-26-14-07-33` |
| Compact | `{YYYY}{MM}{DD}_{hh}{mm}{ss}` | `20260826_140733` |
| Camera-style | `IMG_{YYYY}{MM}{DD}_{hh}{mm}{ss}` | `IMG_20260826_140733` |
| Date + sequence | `{YYYY}-{MM}-{DD}_{seq}` | `2026-08-26_1` |

「Date & time」也是全新對話框開啟時的預設樣板。一旦你編輯了樣板文字（或點了變數 chip），
選取狀態就會切換到 `Custom...`。你的自訂規則會依資料夾記住——重新開啟一個上次以自訂規則
重新命名過的資料夾，那個確切的樣板就會回來。

### 對話框與即時預覽

重新命名對話框分為兩個窗格：左側是預設選擇器、樣板欄位與變數 chip，右側是即時預覽。

```mermaid
flowchart TD
    A(["開啟重新命名對話框"]) --> B["Halcyon 抽樣五張照片<br/>並讀取一次它們的 EXIF"]
    B --> C["選一個預設<br/>或自己輸入樣板"]
    C --> D{"樣板有效嗎？"}
    D -- "有效" --> E["即時預覽立刻更新<br/>逐張顯示 舊檔名 → 新檔名"]
    D -- "無效（打錯字／空白）" --> F["Run 按鈕停用<br/>編輯器顯示錯誤"]
    E --> G["按下 Run Rename<br/>套用到整個資料夾"]
    F --> C
    G --> H(["檔案已重新命名<br/>可還原（Undo）"])

    classDef start fill:#a5f3fc,stroke:#22d3ee,stroke-width:2px,color:#0e2a33;
    classDef decision fill:#fde68a,stroke:#fbbf24,stroke-width:2px,color:#3a2a04;
    classDef fast fill:#86efac,stroke:#4ade80,stroke-width:2px,color:#0b3320;
    classDef slow fill:#c4b5fd,stroke:#a78bfa,stroke-width:2px,color:#2a1c4d;
    classDef limited fill:#fda4af,stroke:#fb7185,stroke-width:2px,color:#40101a;
    classDef done fill:#a5f3fc,stroke:#22d3ee,stroke-width:2px,color:#0e2a33;

    class A start;
    class D decision;
    class B,C,E slow;
    class G fast;
    class F limited;
    class H done;
```

初次讀取後，樣板欄位每次按鍵都會立即重新渲染這五列預覽，不會重新讀取中繼資料，所以即使是
大型資料夾，打字也保持流暢。「Re-roll」按鈕會重新抽取五張隨機照片並重新讀取中繼資料。

每一列預覽顯示舊檔名 → 新檔名，加上附屬副檔名徽章（讓你在送出前看到 RAW+JPG 配對會一起
移動）與「no camera tag」徽章。重新命名一律套用到整個資料夾，沒有逐項選取。

### EXIF 從哪裡來

Halcyon 以「每張照片一次」讀取 EXIF，涵蓋 RAW、JPG 對應檔與側車檔整組；有 JPG 對應檔時優先
從它讀取，否則讀 RAW 檔頭。讀取 RAW 檔頭在背景分批執行、狀態列顯示進度，不會凍結介面。

若 RAW 格式的檔頭無法解析，該照片的 EXIF 佔位符留白，但日期與時間仍從檔案時間戳解出。

### 套用重新命名——以及還原

按下 Run 後，Halcyon 先算出每一步搬移，再逐一執行：

- 會撞名的照片以 `{seq}` 編號，順序穩定；仍衝突的附加 `-1`、`-2`…… 後綴。
- 新檔名與目前檔名相同的照片會整個略過。
- 屬於同一張照片的所有檔案都改成相同基底檔名並各自保留副檔名，配對不會被拆開。

每一步搬移都會寫入日誌，這正是**還原（Undo）**的機制（倒著重播日誌）。星號／垃圾桶標記與
最後檢視的照片會自動跟著移動。無法寫入的資料夾無法開啟重新命名對話框。

### 已知限制

- 沒有對應 EXIF 標籤的佔位符會留白，不會改用其他欄位替代。
- 沒有 JPG 對應檔且檔頭無法解析的 RAW，得不到任何相機中繼資料。

---

## RAW 格式支援與解碼路由

Halcyon 幾乎支援所有主流相機的 RAW 格式，也支援通用的 Adobe DNG：

| 相機品牌 | 格式 | 顯示方式 |
|---|---|---|
| Sony | ARW | 完整解碼 |
| Canon | CR3 | 完整解碼 |
| Nikon | NEF | 完整解碼 |
| Fujifilm | RAF | 完整解碼 |
| Panasonic | RW2 | 完整解碼 |
| Olympus | ORF | 完整解碼 |
| Pentax | PEF | 完整解碼 |
| Samsung | SRW | 完整解碼 |
| Sigma | X3F | 完整解碼 |
| Adobe（通用） | DNG | 完整解碼 |
| Canon（較舊） | CR2 | 僅縮圖瀏覽 |
| Phase One | IIQ | 僅縮圖瀏覽 |
| Minolta | MRW | 僅縮圖瀏覽 |

「僅縮圖瀏覽」的三種格式一樣可以打星、刪除、搬移，只是目前還看不到完整解碼後的畫質。

大部分情況下你不會感覺到差異：Halcyon 會自動判斷用哪種方式顯示照片。

```mermaid
flowchart TD
    A(["開啟一張 RAW 照片"]) --> B{"檔案裡有現成的<br/>預覽縮圖嗎？"}
    B -- "有，而且夠大張" --> C["直接讀取內建預覽<br/>速度快"]
    B -- "沒有，或太小張" --> D{"這個格式<br/>支援完整解碼嗎？"}
    D -- "支援" --> E["完整解碼 RAW 感光資料<br/>速度較慢、畫質完整"]
    D -- "不支援（CR2／IIQ／MRW）" --> F["顯示縮圖<br/>無法看到完整畫質"]
    C --> G(["照片顯示在畫面上"])
    E --> G
    F --> G

    classDef start fill:#a5f3fc,stroke:#22d3ee,stroke-width:2px,color:#0e2a33;
    classDef decision fill:#fde68a,stroke:#fbbf24,stroke-width:2px,color:#3a2a04;
    classDef fast fill:#86efac,stroke:#4ade80,stroke-width:2px,color:#0b3320;
    classDef slow fill:#c4b5fd,stroke:#a78bfa,stroke-width:2px,color:#2a1c4d;
    classDef limited fill:#fda4af,stroke:#fb7185,stroke-width:2px,color:#40101a;
    classDef done fill:#a5f3fc,stroke:#22d3ee,stroke-width:2px,color:#0e2a33;

    class A start;
    class B,D decision;
    class C fast;
    class E slow;
    class F limited;
    class G done;
```

簡單說：

- **有內建預覽 → 用預覽**：很多 RAW 檔（尤其是用 Lightroom 或 DxO PureRAW 處理過的 DNG，還有 Panasonic 的 RW2）裡面其實藏著一張現成的 JPEG 縮圖，Halcyon 找得到就直接用。
- **沒有內建預覽 → 完整解碼**：找不到夠大張的預覽，且格式支援完整解碼，就去解完整的 RAW 資料，畫質更完整但稍微慢一點。
- **格式不支援完整解碼 → 只能看縮圖**：CR2、IIQ、MRW 目前只能瀏覽，還沒辦法完整解碼。

平台支援現況：

| 平台 | 完整 RAW 解碼 |
|---|---|
| macOS | ✅ 支援 |
| Windows | ✅ 支援 |
| Android | ✅ 支援 |
| Linux | ✅ 支援 |
| iOS | ⏳ 尚未支援 |
| 網頁版 | ⏳ 尚未支援 |

在還沒支援完整解碼的平台上，如果一張 RAW 檔剛好沒有內建預覽，會暫時顯示成無法預覽，這是平台功能還沒補齊，不是照片壞了。

---

## 實測效能

篩選照片時的迴圈很單純：看、判斷、按下一張。真正重要的數字，是從按下方向鍵到畫面上出現
可用全解析度影像所花的時間——而不是抽象的解碼吞吐量。

這個數字背後藏著兩種完全不同的成本：

- **含內嵌 JPEG 預覽的照片走便宜路徑**——Halcyon 直接顯示預覽，完全不做 RAW 解碼。這在
  一般資料夾裡是大多數檔案，落在個位數毫秒。
- **沒有可用預覽的照片**（多半來自手機的裸感光元件 DNG）則會走姊妹解碼器 Ceyx 的完整 RAW
  解碼。這是昂貴路徑。

正因為有這個分岔，再加上**冷啟動**首次解碼與**暖啟動**重複解碼之間的差異，任何單一數字都
必須附上條件才有意義。以下是實際記錄下來的結果。

### 數字

| 量測的是什麼 | 時間 | 條件 |
|---|---|---|
| 原生解碼器單獨計時，24 MP Sony ARW，無並發競爭 | ~73 毫秒總時間（其中約 56 毫秒在解碼器內：約 19 毫秒 RAW 解壓縮＋約 37 毫秒 Halide 管線） | Mac Studio（28 核心），本機 SSD，headless 基準測試，2026-09-08 |
| 原生解碼器的並發吞吐上限 | 本機約每秒 30–34 張（並發數 4–16 之間出現高原，受限於原生 Halide 內部競爭） | Mac Studio，headless 基準測試，2026-09-08 |
| 第二階全解析度重新解碼，24 MP Sony ARW（正式路徑） | 中位數 171–173 毫秒，p95 約 208–285 毫秒（n=20） | macOS，外接硬碟，2026-09-03 |
| 完整 RAW 解碼，從按鍵到全解析度上屏（12 MP 手機 DNG） | 冷啟動 491–601 毫秒；暖啟動 150–159 毫秒 | macOS release 建置，2026-08-17，未記錄機型 |
| 側欄縮圖解碼，裸感光元件 DNG（無內嵌預覽） | 暖啟動每張約 56–100 毫秒 | 測試環境，目標長邊 200 px |
| 側欄縮圖，*含*內嵌預覽的 DNG（快速路徑） | 暖啟動約 0.3–0.4 毫秒 | 同一套量測工具 |
| 側欄縮圖，JPEG 檔案 | 暖啟動約 22–26 毫秒 | 同一套量測工具 |
| 在 JPEG 預覽照片之間切換（無 RAW 解碼） | 2.8 毫秒（優化前為 127.5 毫秒） | 歷史基準值，保留以呈現優化幅度 |

### 該記住哪個數字

解碼器本身很快：**24 MP RAW 檔案在本機儲存裝置上、無並發競爭時約 73 毫秒。** 其中約
56 毫秒花在解碼器內部——約 19 毫秒 RAW 解壓縮，加上約 37 毫秒的 Halide 處理管線——其餘則是
IPC 與緩衝區交還的開銷。這個單張成本隨並發數擴展得相當好：從 1 個並發解碼提升到 8 個，
輸送量成長 2.75 倍，在本機儲存裝置上可達每秒約 30–34 張。

完整端到端上屏的成本自然會比純解碼器數字更高，因為還包含了 Dart 端的縮放與編碼：上表中
的暖啟動數字落在 150–173 毫秒之間，而冷啟動首次解碼——什麼都還沒快取、核心也還沒暖機——
則要 491–601 毫秒。

### 尚未量測的項目

有幾件事目前根本沒有記錄下來的數字，與其猜測不如直說：

- 大片幅 RAW 檔案（全片幅、40+ MP）在 Halcyon 自身管線中的完整解碼計時。現有記錄的樣本
  大約止於 24 MP。
- 匯出計時（解碼 → 縮放 → 重新編碼為 JPEG）。
- 真實 UI 導覽下的切換延遲與記憶體用量——這些保留給專案擁有者親自量測，而非自動化執行。

---

## 快取與記憶體管理

### 為什麼這對挑選很重要

檢視一次拍攝，往往就是按住方向鍵、每秒飛掠數十張照片。要讓這件事順手，得同時
成立兩件事：每張照片在你停到它的瞬間就出現，而且不論資料夾多大，瀏覽都不會把
記憶體吃光。這兩個目標其實是互相拉扯的——現代 24 MP 感光元件的一張照片，全尺寸
解碼後大約要 90 MB，所以每按一次鍵就全品質解碼一次會卡頓，而把看過的每一張都
留著又終究會耗盡記憶體。

Halcyon 的做法是：只保留你目光附近的照片，依你當下的動作用「剛好合適」的清晰度
顯示每一張，並在你一停下來就悄悄升級成全品質。移動的時候，你永遠不會為「粗重」
的解碼工作等待。

### 主圖用兩種清晰度顯示

主要預覽分兩趟畫出來，但只針對你目前所在的照片，以及它前後緊鄰的各一張——
往前一步、往後一步。真正會被解碼成像素的只有這條窄帶；其餘你手上還留著的
照片（見下文「只留下附近的照片」）則以壓縮過的 JPEG 位元組形式存著，直到你
走到它旁邊為止。

- **第一層——即時。** 一張照片一進入這條窄帶——包括你剛停到的那張——Halcyon
  就會以你視窗的解析度顯示它。這一步很快，所以連續按方向鍵瀏覽依然順滑，
  附近的每張照片都立刻有畫面，不必等停頓。
- **第二層——全品質。** 如果你在某張照片上停留約四分之一秒，Halcyon 就解碼出
  全解析度版本並換上去。正因為它要等這個短暫的停頓，掃過上百張照片時，並不會
  為你只是瞥過的影像同時啟動上百次粗重的全畫面解碼。

```mermaid
flowchart TD
    A(["停到一張照片"]) --> B["立即顯示視窗解析度預覽<br/>（第一層）"]
    B --> C{"你在這裡<br/>停留約四分之一秒了嗎？"}
    C -- "沒有，還在瀏覽" --> D["維持快速預覽<br/>保持流暢"]
    C -- "有，你停下來了" --> E["解碼全解析度<br/>並換上去（第二層）"]
    D --> F(["下一張照片"])
    E --> G(["全品質影像顯示在畫面上"])

    classDef start fill:#a5f3fc,stroke:#22d3ee,stroke-width:2px,color:#0e2a33;
    classDef decision fill:#fde68a,stroke:#fbbf24,stroke-width:2px,color:#3a2a04;
    classDef fast fill:#86efac,stroke:#4ade80,stroke-width:2px,color:#0b3320;
    classDef slow fill:#c4b5fd,stroke:#a78bfa,stroke-width:2px,color:#2a1c4d;
    classDef done fill:#a5f3fc,stroke:#22d3ee,stroke-width:2px,color:#0e2a33;

    class A start;
    class C decision;
    class B,D fast;
    class E slow;
    class F,G done;
```

### 側邊欄縮圖

側邊那條縮圖膠捲是跟主圖分開載入的。Halcyon 只抓目前實際在畫面上的縮圖，外加
上下各一小段邊界，讓捲動時預載能跑在你前面；一旦縮圖捲離視野夠遠就把它丟掉。
只要做了會重新載入資料夾的動作——標星、丟垃圾桶、複製或搬移——縮圖都會自己
重新出現，所以側邊欄不會卡在空白。小張的內嵌預覽會直接沿用；較大的影像則只縮成
一張精簡縮圖並以這個輕量形式保存，因此即使是很大的資料夾，側邊欄也依然省資源。

### 只留下附近的照片

這裡其實有兩種視窗在同時運作，而且刻意設計成不同大小。

**保留視窗**是比較寬的那個：圍繞你當下這張照片、會移動的一個範圍——後面留幾張、
前面多留幾張，因為瀏覽絕大多數是往前走。在記憶體最小的機器上是後面 3 張、前面
5 張；記憶體較多的機器上會加寬（最多後面 3 張、前面 11 張），其位元組預算也會
跟著變大，因此配備較好的機器能在需要釋放任何東西之前，多保留一部分資料夾內容。
這個視窗裡的所有內容都是壓縮過的 JPEG（照片自己的檔案，或是 RAW 的重新編碼版本）
——保留成本低，但還沒解碼成像素。

**解碼帶**則窄得多，而且不論機器規格一律固定：只有目前選取的照片，以及它前後
緊鄰的各一張。一張照片一踏進這個「前後各一張」的帶狀範圍，就會立刻把它的壓縮
JPEG 解碼成像素——速度很快，因為 JPEG 解碼遠比 RAW 解碼便宜——而一旦它退出這個
帶狀範圍，就只會丟掉解碼後的副本，繼續保留壓縮版本。這正是讓記憶體帳單維持平坦
的關鍵：app 的規模是依照它實際要畫出像素的少數幾張照片來設計的，而不是依照它為
了避免重新從磁碟讀檔而多留在手邊的、大得多的那個數字。

當保留視窗的預算被用完時，會先釋放離你目前位置最遠的照片，因此你正在看的那張
永遠是最後才會被丟的——但「最遠」的判斷範圍會比解碼帶本身再寬一點（後面一張、
前面三張），所以緊貼在解碼帶外的幾張照片，仍會被視為「還算接近」而受到保護，
一併免於過早被淘汰。

如果 macOS 或 Windows 回報整個系統記憶體吃緊，Halcyon 不會等到自己的預算被用完
才反應，而是立刻行動：把手上保留的壓縮照片數量砍半，並丟掉那個即時帶狀範圍以外
的任何已解碼全解析度影格，等壓力解除後再恢復正常預算。

### 摘要

| 通道 | 保留什麼 | 保留多少 | 何時釋放 |
|---|---|---|---|
| 側邊欄縮圖 | 膠捲用的小張縮圖 | 畫面上的列，加上上下各一段邊界 | 每次更新都修剪成目前實際所需 |
| 主圖，保留視窗 | 你正在看的那張附近照片的壓縮 JPEG 位元組 | 一個會移動的視窗，大小依機器記憶體而定（後面 3 張／前面 5–11 張） | 超出預算時先釋放離選取位置最遠的照片 |
| 主圖，已解碼像素 | 實際正顯示在畫面上的視窗解析度與全解析度影像 | 只有目前選取的照片，以及它前後緊鄰的各一張 | 一旦照片離開那個即時帶狀範圍，或系統記憶體吃緊時立即丟棄 |

---

## 架構

Halcyon 是一個嚴格單向分層的應用程式——`views/` → `providers/app_state.dart` → `services/` → `models/`——並有少數幾道不宜隨意更動形狀的凍結介面。

### 分層與相依方向

`views/` 負責建構 UI，只持有 view 本地狀態（鍵盤快捷鍵、縮放變換、對話框骨架），透過 `provider` 套件讀取 `AppState` 並呼叫其方法，完全不知道照片是怎麼被掃描、解碼或刪除的。由動畫驅動的 view 本地狀態（縮放、指標位置）放在 view 持有的 controller（例如 `lib/views/zoom_controller.dart` 的 `ZoomController extends ChangeNotifier`，由 `MainScreen` 持有並負責釋放），而不是放進 `AppState`——`AppState` 只保存代表相簿模型的狀態。

`providers/app_state.dart` 定義了 `AppState extends ChangeNotifier`（`lib/providers/app_state.dart:61`），是應用程式邏輯的唯一協調點——資料夾載入、選取、星標/垃圾桶標記、設定，以及派送到服務層。它靠建構子注入取得協作者，而非寫死成欄位：

```dart
AppState({
  PhotoLibraryScanner? scanner,
  PhotoStatusStore? statusStore,
  PhotoFileActions? fileActions,
  ImagePreloadController? preloadController,
  NativeImageLoad? imageLoader,
  DngFullDecoder? dngDecoder,
  PhotoExportService? exportService,
  ExifBatchReader? exifReader,
})
```

每個參數省略時都退回真實實作（例如 `_scanner = scanner ?? PhotoLibraryScanner()`），正式環境因此免費取得真實協作者，測試則可把任一個換成假物件——這也是協調層能脫離真實檔案系統或平台通道獨立受測的原因。

`services/` 實作實際工作——檔案系統掃描、狀態持久化、影像解碼/快取、檔案操作、EXIF/重新命名、兩個平台橋接——並禁止回頭直接呼叫 `views/` 或 `AppState`；它只被呼叫，只透過 `AppState` 明確交付的 callback/supplier 參數回呼。`models/` 持有純粹資料形狀與無 I/O 的純函式——`PhotoItem`、格式註冊表、`RenameRule` 的樣板渲染——不從 `services/` 或 `views/` 匯入。

`services/` 拆成四個按用途命名的子資料夾：

| 資料夾 | 負責範圍 |
|---|---|
| `image_pipeline/` | 第一層/第二層滑動視窗預載、DNG 解碼整合、影像快取記帳 |
| `library/` | 資料夾掃描、狀態持久化、檔案複製/搬移/丟垃圾桶、星標照片匯出 |
| `rename/` | EXIF 驅動的重新命名規劃、EXIF 中繼資料讀取、重新命名協調器 |
| `platform/` | 兩個 macOS `MethodChannel` 橋接 |

### 縫與不變量

以下是影像管線中承重的限制條件；隨意更動會打破本 README 其他地方描述的第一層/第二層契約。

**Ceyx 整合縫。** DNG 全尺寸解碼（針對沒有可用內嵌預覽圖的 DNG）委派給姊妹專案 Ceyx，靠的是一個 typedef，而非具體類別：

```dart
typedef DngFullDecoder = Future<DecodedRgba> Function(String path);
```

這道縫讓影像管線能針對假解碼器做單元測試，不必載入真正的 native dylib。

與其搭配的 `image_source_types.dart` 宣告了一個恰好三個變體的 sealed class，描述任何影像位元組請求的結果：`NativeImageBytes`（已編碼位元組，正常路徑）、`NativeImageNeedsRawDecode`（無內嵌預覽圖的 DNG——非失敗，是要跑真正 RAW 解碼器的訊號）、`NativeImageFailure`（真正的失敗）。這個集合凍結在三個變體。

**影像載入在每個平台上都是純 Dart。** `dartImageLoad`（`lib/services/image_pipeline/dart_image_loader.dart:17`）是影像位元組的唯一產生來源；沒有任何平台存在原生縮圖通道。照片相關行為——哪些檔案會被載入、畫面上出現什麼像素、刪除做了什麼、匯出產出什麼——只在 Dart 中實作一次，並在每個支援平台產生相同結果，只有三個封閉的原生橋接例外：系統垃圾桶（macOS/Windows 原生）、Open With 傳輸層（macOS/Windows/Android/iOS，不含 Linux）、檔案關聯註冊（Windows/macOS）。

**單一持有者不變量。** 兩個類別各自持有恰好一份第二層狀態，讓不變量能在單一位置推理與測試，不至於散落到各個呼叫點：

- `TierTwoRegistry`（`lib/services/image_pipeline/tier_two_registry.dart:26`）是第二層*就緒狀態*記帳的唯一持有者——哪些 id 有全尺寸快取項目、它是針對哪個 payload 物件解碼的，以及該次解碼是否已失敗。
- `TierTwoScheduler`（`lib/services/image_pipeline/tier_two_scheduler.dart:115`）是第二層*排程*的唯一持有者——±1 全解析度解碼帶（`kFullResolutionBandRadius`，`prefetch_scheduler.dart:23`）、250ms 導覽 debounce，以及序列化的解碼佇列。

**原生橋接。** `macos/Runner/AppDelegate.swift` 恰好註冊兩個 `MethodChannel`：

```dart
FlutterMethodChannel(name: "halcyon/trash", ...)
FlutterMethodChannel(name: "halcyon/open_with", ...)
```

`halcyon/open_with` 是純推送式的：原生端呼叫進 Dart 端遞送檔案路徑，Dart 端在這個通道上無法主動詢問「有沒有東西還在等待」。Flutter 會緩衝原生→Dart 方向的訊息直到 Dart handler 註冊完成，這讓推送式即使在冷啟動時也可靠；通道物件建立前抵達的事件，暫存在 `pendingOpenFile` 變數中，於通道建立當下立即送出。

**唯一一份 EXIF 方向表。** `exif_orientation.dart` 的 `exifTransformFor` 是本專案唯一的 8 case Orientation 標籤對照表；`package:image` 匯出路徑與 `dart:ui` 全尺寸 RGBA provider 都透過這張表轉換，不各自實作方向邏輯，且都以固定順序先旋轉再鏡像。

### 目錄結構

```
Halcyon/
├── lib/
│   ├── main.dart              # ChangeNotifierProvider + MaterialApp setup
│   ├── models/                # PhotoItem, format registry, RenameRule (pure, no I/O)
│   ├── perf/                  # opt-in performance instrumentation
│   ├── providers/
│   │   └── app_state.dart     # AppState: the single coordination point
│   ├── services/
│   │   ├── image_pipeline/    # tier-1/tier-2 preload, DNG decode, cache bookkeeping
│   │   ├── library/           # folder scan, status persistence, file ops, export
│   │   ├── rename/            # EXIF-driven rename planning + coordinator
│   │   └── platform/          # the two macOS MethodChannel bridges
│   └── views/                 # UI, keyboard shortcuts, dialogs
├── test/                      # mirrors the lib/ tree above, plus test/support/
├── macos/ ios/ android/ web/ windows/ linux/   # per-platform runner shells
├── scripts/
│   └── build_apps.py          # the single build entry point for all six targets
├── docs/
│   ├── images/                 # README 截圖
│   ├── legal/                  # THIRD_PARTY_LICENSES.md
│   ├── logs/YYYY-MM-DD/       # dated task logs; recorded measurements live here
│   └── sop/                   # 未受版控追蹤的內部維護文件；全新 clone 不會包含
└── README.md
```

Halcyon 也在工作副本的 `docs/sop/` 目錄下維護一組內部流程文件——架構決策與踩坑經驗、任務追蹤、階段里程碑、短期交接摘要，以及測試策略與測試案例矩陣。這些文件已加入 `.gitignore`，全新 clone 不會包含它們。

授權與第三方歸屬說明收錄在本文件結尾的
[第三方歸屬](#第三方歸屬)一節。

---

## 架構圖

三張圖涵蓋整個系統：模組之間如何相依、一張照片的位元組如何從磁碟走到螢幕，以及一次按鍵如何變成標記、再驅動檔案系統上的批次操作。三張合起來看，應該能讓初次接觸的讀者在三十秒內，在 `lib/` 底下找到任何一個檔案的位置。

### 圖例

**形狀**（三張圖一致）：

| 形狀 | 意義 |
|---|---|
| 圓角矩形 `([ ])` | 進入點／使用者動作 |
| 矩形 `[ ]` | 模組、服務或類別 |
| 子程序框 `[[ ]]` | 記憶體內快取 |
| 圓柱 `[( )]` | 持久化儲存（磁碟上的檔案） |
| 菱形 `{ }` | 決策／路由節點 |
| 六邊形 `{{ }}` | 原生／FFI 邊界跨越 |

**顏色**（每個架構層對應一個色相，Tailwind 200 色階填色／400 色階邊框，文字強制設為 `#1e293b`，即 Tailwind slate-800）：

| 層級 | 填色 (200) | 邊框 (400) |
|---|---|---|
| Views／進入點 | `#bfdbfe`（blue-200） | `#60a5fa`（blue-400） |
| Providers（`AppState`） | `#e9d5ff`（purple-200） | `#c084fc`（purple-400） |
| Services — image pipeline | `#bbf7d0`（green-200） | `#4ade80`（green-400） |
| Services — library/platform/rename | `#fed7aa`（orange-200） | `#fb923c`（orange-400） |
| Models | `#fef08a`（yellow-200） | `#facc15`（yellow-400） |
| 原生／FFI 邊界（Ceyx、AppDelegate） | `#fecaca`（red-200） | `#f87171`（red-400） |
| 快取 | `#a5f3fc`（cyan-200） | `#22d3ee`（cyan-400） |
| 持久化儲存 | `#e2e8f0`（slate-200） | `#94a3b8`（slate-400） |

**邊線**：實線箭頭代表直接呼叫或匯入相依；虛線箭頭代表資料／檔案相依（從磁碟讀取或寫入某物），而非函式呼叫。

---

### 1. 模組相依與分層

```mermaid
flowchart TD
  classDef viewLayer fill:#bfdbfe,stroke:#60a5fa,color:#1e293b
  classDef providerLayer fill:#e9d5ff,stroke:#c084fc,color:#1e293b
  classDef pipelineLayer fill:#bbf7d0,stroke:#4ade80,color:#1e293b
  classDef serviceLayer fill:#fed7aa,stroke:#fb923c,color:#1e293b
  classDef modelLayer fill:#fef08a,stroke:#facc15,color:#1e293b
  classDef nativeLayer fill:#fecaca,stroke:#f87171,color:#1e293b

  Views["views/<br/>(MainScreen, SidebarView,<br/>PhotoActionBar, RenameDialog)"]:::viewLayer
  AppState["providers/app_state.dart<br/>AppState extends ChangeNotifier"]:::providerLayer

  subgraph Services["services/"]
    direction TB

    subgraph ImagePipeline["image_pipeline/"]
      Preload["ImagePreloadController"]:::pipelineLayer
      PhotoSourceSvc["PhotoSource"]:::pipelineLayer
      DngContract["DngFullDecoder<br/>(frozen seam)"]:::pipelineLayer
    end

    subgraph Library["library/"]
      Scanner["PhotoLibraryScanner"]:::serviceLayer
      StatusStore["PhotoStatusStore"]:::serviceLayer
      FileActions["PhotoFileActions"]:::serviceLayer
      ExportSvc["PhotoExportService"]:::serviceLayer
    end

    subgraph Rename["rename/"]
      RenameCoord["RenameCoordinator"]:::serviceLayer
      ExifSvc["ExifMetadataService"]:::serviceLayer
    end

    subgraph Platform["platform/"]
      TrashSvc["TrashService"]:::serviceLayer
      OpenWith["OpenWithChannel"]:::serviceLayer
    end
  end

  Models["models/<br/>(PhotoItem, SupportedPhotoFormats,<br/>RenameRule)"]:::modelLayer

  NativeBridge{{"macOS native bridges<br/>AppDelegate.swift<br/>(halcyon/trash, halcyon/open_with)"}}:::nativeLayer
  CeyxEngine{{"Ceyx (external package)<br/>GPU RAW decode engine"}}:::nativeLayer

  Views -->|reads/calls| AppState
  AppState -->|constructor-injects & calls| Preload
  AppState --> Scanner
  AppState --> StatusStore
  AppState --> FileActions
  AppState --> ExportSvc
  AppState --> RenameCoord

  Preload --> PhotoSourceSvc
  PhotoSourceSvc -.->|typedef DngFullDecoder| DngContract
  ExportSvc -.->|typedef DngFullDecoder| DngContract
  DngContract -.->|implemented by dng_decode_service.dart| CeyxEngine

  FileActions --> TrashSvc
  TrashSvc --> NativeBridge
  RenameCoord --> ExifSvc

  Preload --> Models
  Scanner --> Models
  FileActions --> Models
  ExportSvc --> Models
  RenameCoord --> Models

  Views -.->|receives pushed file path| OpenWith
  OpenWith --> NativeBridge
```

**圖說：** 相依關係單向流動，由上而下——`views` 呼叫 `AppState`，`AppState` 透過建構子注入組合每個 `services/` 協作物件，這些協作物件只相依於 `models/`。`services/` 或 `models/` 底下沒有任何東西會匯入 `views/` 或 `providers/`。唯二的原生邊界跨越，是通往外部 Ceyx 套件（RAW 解碼）的 `DngFullDecoder` 接縫，以及註冊在 `AppDelegate.swift` 裡的兩個 `MethodChannel`（系統垃圾桶與「以此開啟」檔案傳遞）。

**證據：**
- `AppState` 透過建構子注入組合它的協作物件 —
  `lib/providers/app_state.dart:61-104`。
- `ImagePreloadController` 相依於 `PhotoSource`，這是唯一具備型別知識的層 —
  `lib/services/image_pipeline/photo_source.dart:82-93`。
- `DngFullDecoder`／`DngSizedDecoder` 是管線與原生解碼器之間凍結的整合接縫 —
  `lib/services/image_pipeline/dng_decode_contract.dart:30,39`。
- 實作這個接縫的 Ceyx 轉接器匯入 `package:ceyx/ceyx.dart` —
  `lib/services/image_pipeline/dng_decode_service.dart:1,12-14`。
- `PhotoExportService` 也接受一個可選的 `DngFullDecoder`，用於自己的 RAW 匯出路徑 —
  `lib/services/library/photo_export_service.dart:38-39`。
- `PhotoFileActions` 預設使用 `TrashService.trashFile` —
  `lib/services/library/photo_file_actions.dart:40`。
- `AppDelegate.swift` 恰好註冊兩個 channel，`halcyon/trash` 與
  `halcyon/open_with` — `macos/Runner/AppDelegate.swift:23,42`。
- `RenameCoordinator` 由 `AppState` 建構，`readMetadata:
  readMetadataFor` 接到 `ExifMetadataService.readBatch` —
  `lib/providers/app_state.dart:71-102`。

---

### 2. 影像管線資料流——從磁碟上的檔案到螢幕上的像素

這是核心圖：一張照片的位元組從資料夾掃描到畫面繪製的完整路徑，涵蓋兩階解碼策略，以及在內嵌預覽圖與完整 RAW 解碼之間的路由決策。

```mermaid
flowchart TD
  classDef entry fill:#bfdbfe,stroke:#60a5fa,color:#1e293b
  classDef service fill:#bbf7d0,stroke:#4ade80,color:#1e293b
  classDef decision fill:#bbf7d0,stroke:#4ade80,color:#1e293b
  classDef native fill:#fecaca,stroke:#f87171,color:#1e293b
  classDef cache fill:#a5f3fc,stroke:#22d3ee,color:#1e293b
  classDef storage fill:#e2e8f0,stroke:#94a3b8,color:#1e293b
  classDef render fill:#bfdbfe,stroke:#60a5fa,color:#1e293b

  Open(["User opens a folder"]):::entry
  Scan["PhotoLibraryScanner.scan()<br/>lists files, groups siblings by<br/>basenameWithoutExtension"]:::service
  Disk1[("photo folder<br/>(RAW + JPG siblings)")]:::storage

  Open --> Scan
  Disk1 -.-> Scan

  Select(["User selects / navigates<br/>to a PhotoItem"]):::entry
  Ensure["ImagePreloadController._ensurePayload()"]:::service
  Probe{"DngEmbeddedJpegExtractor.probeContent()<br/>bounded IFD walk: cheap or expensive?"}
  class Probe decision

  Scan --> Select
  Select --> Ensure
  Ensure --> Probe

  Route{"PhotoSource.load()<br/>native loader result"}
  class Route decision
  Probe --> Route

  Bytes["NativeImageBytes<br/>(JPEG file itself, or<br/>largest embedded preview)"]:::service
  NeedsRaw{{"NativeImageNeedsRawDecode<br/>(no usable embedded JPEG)"}}
  class NeedsRaw native
  Failure["NativeImageFailure<br/>-> pure-Dart embedded-JPEG<br/>fallback, else permanent miss"]:::service

  Route -->|encoded bitstream found| Bytes
  Route -->|DNG with no preview| NeedsRaw
  Route -->|unreadable| Failure

  CeyxDecode{{"Ceyx DngDecoderService<br/>.decodeOnWorker()<br/>GPU RAW decode on worker isolate"}}
  class CeyxDecode native
  NeedsRaw --> CeyxDecode

  PixelPayloadNode["decodedRgbaToPixelPayload()<br/>orient + downscale to window size"]:::service
  CeyxDecode --> PixelPayloadNode

  PayloadCache[["PhotoPayloadCache<br/>retention window sized to RAM<br/>(-3..+5 floor, wider per tier),<br/>distance-priority eviction"]]:::cache
  Bytes --> PayloadCache
  PixelPayloadNode --> PayloadCache

  TierOne["Tier-1 decode<br/>tierOneProviderFor()<br/>ResizeImage @ window resolution,<br/>only for the +/-1 band"]:::service
  PayloadCache --> TierOne

  Debounce{"250ms navigation-quiet<br/>debounce elapsed?<br/>(band entrants decode immediately)"}
  class Debounce decision
  PayloadCache --> Debounce

  TierTwo["Tier-2 decode<br/>fullSizeProviderFor() / RawFullResImage<br/>full-size, -1..+1 window"]:::service
  Debounce -->|yes, TierTwoScheduler.schedule| TierTwo

  ImageCacheNode[["Flutter ImageCache<br/>(tier-1 + tier-2 keys,<br/>separate namespaces)"]]:::cache
  TierOne --> ImageCacheNode
  TierTwo --> ImageCacheNode

  ThumbCache[["_thumbCache<br/>sidebar thumbnail bytes"]]:::cache
  Ensure -.->|separate sweep,<br/>ImageRequestPurpose.sidebarThumbnail| ThumbCache

  Render(["MainDetailView paints<br/>AppState.displayProvider<br/>(tier-2 if ready, else tier-1)"]):::render
  ImageCacheNode --> Render
```

**圖說：** 掃描階段會把 RAW／JPG 的同名檔案併成一個 `PhotoItem`。選取某個項目時，會先做一次有邊界的內容探測，據此把檔案分成「便宜」或「昂貴」再決定怎麼解碼：便宜的檔案（JPEG，或內嵌預覽圖已經夠大的 DNG）完全不經過原生解碼器；沒有可用預覽圖的 DNG，則跨越邊界交給 Ceyx 在 worker isolate 上執行的 GPU 解碼器。每個結果都會以壓縮位元組形式落進同一個有位元組預算上限的保留快取；只有目前選取的項目，以及它前後緊鄰的各一張（即「前後各一張」帶狀範圍），才會額外解碼成像素——一進入這個帶狀範圍就立刻解碼出視窗解析度（第一階），等導覽靜止 250 毫秒後，再升級到完整解析度（第二階）。

**證據：**
- 依 `basenameWithoutExtension` 分組同名檔案 —
  `lib/services/library/photo_library_scanner.dart:14-19`，id 定義於
  `lib/models/supported_photo_formats.dart:44`。
- 先探測再分類的內容判斷邏輯，以及它同時輸出成本與方向的設計
  — `lib/services/image_pipeline/photo_source.dart:274-317`。
- 三分支的 `NativeImageResult` 路由（位元組／需要 RAW 解碼／
  失敗）— `lib/services/image_pipeline/image_source_types.dart:52-118`，以及
  據此執行動作的 switch — `lib/services/image_pipeline/photo_source.dart:116-201`。
- 跨越到 Ceyx 的邊界 — `lib/services/image_pipeline/dng_decode_service.dart:12-14`。
- 第一階／第二階的 provider 工廠函式，以及物件身分／快取鍵必須一致的要求 —
  `lib/services/image_pipeline/image_preload_controller.dart:28-49`。
- 250 毫秒導覽防抖動常數，以及一張照片新進入「前後各一張」帶狀範圍時的立即
  （不受 debounce 影響）解碼路徑 —
  `lib/services/image_pipeline/image_preload_controller.dart:115`（常數本身）與
  `lib/services/image_pipeline/tier_two_scheduler.dart:412-427,449-505`。
- 「前後各一張」全解析度帶狀範圍的半徑 —
  `lib/services/image_pipeline/prefetch_scheduler.dart:23`。
- 保留視窗（下限 -3..+5，記憶體較多的等級會更寬）與距離優先淘汰策略
  （離選取位置最遠者先被淘汰）—
  `lib/services/image_pipeline/photo_payload_cache.dart:6-10,99-108,226-251`，
  等級對照表見 `lib/services/image_pipeline/retention_policy.dart:73,99-116`。
- 淘汰時判斷「多遠算遠」用的是與上述解碼帶不同的第三個獨立帶狀範圍
  （後方 -1..前方 +3）——刻意凍結在 2026-08-30 前的解碼帶數值，
  這樣縮窄解碼帶時不會連帶縮窄「哪些鄰近 id 受保護、不會提早被淘汰」的範圍 —
  `lib/services/image_pipeline/prefetch_scheduler.dart:25-39`，
  排序邏輯見 `lib/services/image_pipeline/image_preload_controller.dart:1784-1797`。
- 「前後各一張」帶狀範圍以外保留的插槽只存壓縮後的 payload，不含任何已解碼
  像素（視窗解析度保留已被廢除）—
  `lib/services/image_pipeline/prefetch_scheduler.dart:41-52`。
- 影像快取自身的已解碼像素預算，是依「前後各一張」帶狀範圍的實際工作集推導，
  而非機器記憶體的固定百分比 —
  `lib/services/image_pipeline/cache_budget.dart:130-178`。
- 側欄縮圖使用與詳細檢視路徑各自獨立的快取／未命中集合 —
  `lib/services/image_pipeline/image_preload_controller.dart:91,173`。
- `displayProvider` 在第二階就緒時選用第二階，否則使用第一階 —
  `lib/providers/app_state.dart:214-215`。

---

### 3. 分類動作流程——按鍵到標記到批次動作

```mermaid
flowchart TD
  classDef entry fill:#bfdbfe,stroke:#60a5fa,color:#1e293b
  classDef provider fill:#e9d5ff,stroke:#c084fc,color:#1e293b
  classDef service fill:#fed7aa,stroke:#fb923c,color:#1e293b
  classDef storage fill:#e2e8f0,stroke:#94a3b8,color:#1e293b
  classDef decision fill:#fed7aa,stroke:#fb923c,color:#1e293b
  classDef native fill:#fecaca,stroke:#f87171,color:#1e293b

  KeyPress(["Keypress or PhotoActionBar click<br/>(star / trash)"]):::entry
  Mark["AppState.markCurrent(status)<br/>toggles PhotoItem.status in memory"]:::provider
  StatusFile[(".halcyon_status.json<br/>in the photo folder root")]:::storage

  KeyPress --> Mark
  Mark -->|_saveStatusCache -> PhotoStatusStore.saveStatuses<br/>tmp-file + atomic rename| StatusFile

  BatchTrigger(["User triggers a batch action<br/>(copy/move starred, delete trashed,<br/>export starred)"]):::entry

  RouteAction{"Which batch action?"}
  class RouteAction decision
  BatchTrigger --> RouteAction

  ProcessStarred["AppState.processStarred()<br/>-> PhotoFileActions.processStarred()"]:::service
  DeleteTrashed["AppState.deleteTrashed()<br/>-> PhotoFileActions.deleteTrashed() /<br/>recycleTrashed()"]:::service
  ExportStarred["AppState.exportStarredThumbnails()<br/>-> PhotoExportService.exportStarred()"]:::service

  RouteAction -->|copy/move| ProcessStarred
  RouteAction -->|trash| DeleteTrashed
  RouteAction -->|export| ExportStarred

  RouteAction -.->|reads PhotoItem.status<br/>filtered from _items| Mark

  DestDir[("Destination folder<br/>(copy/move/export target)")]:::storage
  TrashDir[(".trash/ subfolder<br/>(recycle mode)")]:::storage
  SystemTrash{{"System Trash / Recycle Bin<br/>via halcyon/trash channel<br/>(macOS and Windows only)"}}:::native

  ProcessStarred -->|file.copy / file.rename| DestDir
  DeleteTrashed -->|recycle mode: same-volume rename| TrashDir
  DeleteTrashed -->|system Trash mode| SystemTrash
  ExportStarred -->|decode -> resize -> JPEG q90| DestDir

  Reload["AppState.loadFolder() re-scans<br/>and re-applies .halcyon_status.json"]:::provider
  ProcessStarred --> Reload
  DeleteTrashed --> Reload
  StatusFile -.->|re-read on next loadFolder| Reload
```

**圖說：** 一次標記在 `PhotoItem` 上只是純粹的記憶體內狀態，直到 `_saveStatusCache` 透過暫存檔＋原子重新命名的寫入方式，把它持久化到 `.halcyon_status.json`。每個批次動作都直接讀取 `_items` 這個活動清單上的狀態，而非讀檔案，事後還會重新觸發一次資料夾重新載入，藉此把 JSON 重新讀回來。複製／搬移與匯出會寫入使用者選定的目的地；垃圾桶動作則要嘛把檔案搬進同一層的 `.trash/` 子資料夾（回收模式，同磁碟區重新命名），要嘛透過原生的 `halcyon/trash` channel 交給作業系統自己的垃圾桶，而這個 channel 只在 macOS 與 Windows 上有註冊。

**證據：**
- `markCurrent` 切換狀態並呼叫 `_saveStatusCache` —
  `lib/providers/app_state.dart:367-392`。
- 原子式暫存檔＋重新命名寫入 — `lib/services/library/photo_status_store.dart:68-76,132-148`。
- `processStarred` 篩選 `item.status != PhotoStatus.starred`，並複製或
  重新命名每個檔案 — `lib/services/library/photo_file_actions.dart:50-87`。
- `deleteTrashed` 依 `recycleMode` 在 `TrashService.trashFile`
  與 `recycleTrashed` 的同磁碟區重新命名（搬進 `.trash/`）之間擇一 —
  `lib/providers/app_state.dart:498-538`，
  `lib/services/library/photo_file_actions.dart:89-155`。
- `TrashService.trashFile` 是 `PhotoFileActions` 的預設實作，也是
  系統垃圾桶橋接，於 macOS 與 Windows 註冊 —
  `lib/services/library/photo_file_actions.dart:40`，
  channel 註冊於 `macos/Runner/AppDelegate.swift:23`。
- `exportStarred` 的解碼／縮放／編碼路徑 —
  `lib/services/library/photo_export_service.dart:53-142`。
- 批次動作事後會重新載入資料夾，進而重新套用已儲存的狀態
  — `lib/providers/app_state.dart:467-474,524-530`，重新套用邏輯位於
  `lib/services/library/photo_status_store.dart:93-130`。

---

## 平台支援

Halcyon 骨子裡是桌面應用程式，但能跑的平台不只桌面。完整 RAW 解碼目前在
macOS、Windows、Android **以及 Linux** 上都能用，只有 iOS 與網頁版還沒有原生
解碼器。介面是為桌面平台設計的；行動與網頁版雖然跑得起來，但還沒針對觸控調整過。

### 支援矩陣

| 平台 | 可執行 | 介面 | 完整 RAW 解碼 | 系統垃圾桶／資源回收筒 | 從檔案管理員「開啟方式」 |
|---|---|---|---|---|---|
| macOS | ✅（arm64） | 為此平台設計 | ✅ 支援 | ✅ 支援 | ✅ 支援 |
| Windows | ✅ | 桌面版面，測試較少 | ✅ 支援 | ✅ 支援 | ➖ 無 |
| Linux | ✅ | 桌面版面，測試較少 | ✅ 支援 | ➖ 資料夾內回收模式 | ➖ 無 |
| Android | ✅ | 可執行；未針對觸控適配 | ✅ 支援 | ➖ 資料夾內回收模式 | ➖ 無 |
| iOS | ✅ | 可執行；未針對觸控適配 | ⏳ 尚未支援 | ➖ 資料夾內回收模式 | ➖ 無 |
| Web | ✅ | 可執行；未適配 | ⏳ 尚未支援 | ➖ 資料夾內回收模式 | ➖ 無 |

### 這些缺口在實務上代表什麼

**完整 RAW 解碼在四個平台上都已就緒。** macOS、Windows、Android 與 Linux 都能把
RAW 檔案完整解碼。Linux 比較特別：解碼器不在你的機器上編譯，而是由建置工具自動
下載一份預先編好、版本鎖定的副本——但拿到的結果和其他三個平台一樣，都是全品質的完整解碼。

**目前只有 iOS 與網頁版還沒有原生解碼器。** 在這兩個平台上，RAW 檔案只有在本身
帶有夠大的內嵌 JPEG 預覽時才顯示得出來。多數現代相機都會寫入這類預覽，所以瀏覽
通常沒問題——但沒有內嵌預覽的 RAW 檔，目前在這兩個平台上就是看不了。

**系統垃圾桶只有 macOS 與 Windows；其餘平台一律走回收模式。** 在 macOS 與 Windows
上，刪除會把檔案送進真正的系統垃圾桶／資源回收筒。在 Linux、Android、iOS 與 web
上，刪除改用 Halcyon 的資料夾內回收模式——檔案會移到同一處的 `.trash` 子資料夾。
這是完整功能，不是打折的替代方案：什麼都不會遺失，你也能手動把檔案救回來。

**從檔案管理員「開啟方式」只有 macOS 支援。** 在 Finder 裡開啟一張照片就直接啟動
Halcyon，這條路只在 macOS 上接好了；其他平台請改從 app 裡開啟資料夾。

**macOS 建置只支援 arm64，** 原因是隨附的解碼器是為 Apple Silicon 建置的。要建置
Intel Mac 版本，得先備妥 x86_64 的解碼器。

### macOS 系統需求

**Halcyon 宣告支援的最低 macOS 版本是 11，但隨附的原生解碼器函式庫在 Apple Silicon
上實際需要 macOS 15、Intel 上需要 macOS 14。** 這是兩件分開的事實，不是誰修正誰：
應用程式本身宣告的最低版本沒有改變，較高的版本數字描述的只是隨附解碼器函式庫本身
載入時的需求。這個門檻是直接從各函式庫自己的版本 load command 量出來的，不是推測
出來的：在 Apple Silicon 上，真正卡住下限的是隨附 OpenMP runtime 要求的 macOS 15；
在 Intel 上，整組函式庫裡最高的需求則是 macOS 14。

---

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
<!-- evidence: scripts/build_apps.py:271-274 (JDK search order), scripts/build_apps.py:708 (PATH fallback warning) -->
<!-- evidence: android/gradle/wrapper/gradle-wrapper.properties:5, android/settings.gradle.kts:22-23 -->

**Ceyx 必須簽出在相鄰目錄，這不是可有可無的。** `pubspec.yaml` 把解碼器宣告成指向 `../ceyx/plugin` 的相對路徑相依套件，只要該目錄不存在，`flutter pub get` 就會直接失敗。請把 Ceyx 複製到 Halcyon 隔壁，而不是放進 Halcyon 裡面。

<!-- evidence: pubspec.yaml:46-47 -->

對 `linux` 與 `windows` 而言，原生解碼器預設不會在本機編譯：建置腳本會從一個釘定
版本的 Ceyx GitHub release 下載預先建好的函式庫（Windows 一次下載三個檔案——解碼器
本體加上 `heif.dll`/`libde265.dll`），並依 `scripts/ceyx_release_pin.json` 逐一驗證
每個檔案的 sha256。只要目的地函式庫不存在，**或它現存的 sha256 已經對不上釘定版
本**，就會自動觸發下載——這同時涵蓋了第一次簽出，以及本機函式庫被改過或快取過期
這兩種情況。`--fetch-native` 會強制重新下載並覆蓋任何已提交的副本；`--native
always` 則改成從原始碼編譯。如果某個平台的釘定項目沒有替每個檔案都附上雜湊值，
校驗和不符的檢查會退化成「只在檔案不存在時才下載＋印出警告」，而不是默默相信磁碟
上現有的檔案，這時印出的警告會指向 `--native always`，作為想保留本機編譯版本時的
逃生出口。若要把釘定版本本身移到較新的 Ceyx release，執行
`python3 scripts/build_apps.py --ceyx-release latest`：它會解析最新的 tag 並重寫
釘定檔裡的雜湊值，然後在建置前就停下來，讓這份 diff 可以先被審閱再提交。

<!-- evidence: scripts/build_apps.py:1642-1695 (fetch-due decision, checksum-mismatch re-fetch, degrade branches), scripts/build_apps.py:1884-1929 (--ceyx-release latest), scripts/ceyx_release_pin.json -->

Android 建置還要求保留相容模式——`android/gradle.properties` 中的 `android.newDsl=false` 與 `android.builtInKotlin=false`——因為 Flutter 的 Gradle 外掛還不支援 AGP 9 的新 DSL，拿掉這兩行 Android 就建置不起來。

<!-- evidence: android/gradle.properties:4-5, docs/sop/memory.md G-009 -->

### 開發時執行

```bash
flutter pub get
flutter run -d macos     # also: -d chrome, or a connected device id
flutter analyze          # must report 0 issues
flutter test             # full suite
```

### 發行版建置

`scripts/build_apps.py` 是唯一的建置入口，會為每個目標建置原生解碼器與 Flutter 應用程式，並取代了先前各平台各自的 shell 與 PowerShell 腳本——那些舊腳本已經刪除，不要再重新引入各平台獨立的腳本。

```bash
python3 scripts/build_apps.py              # macOS release, the default target
python3 scripts/build_apps.py android --release
python3 scripts/build_apps.py web
python3 scripts/build_apps.py all          # every target this host can build
python3 scripts/build_apps.py --check      # toolchain check only, builds nothing
```

<!-- evidence: scripts/build_apps.py:289-305 (target table), scripts/build_apps.py:3014 (target argument) -->

可用的目標平台有 `macos`、`ios`、`android` / `android-apk` / `android-aab`、`web`、`windows`、`linux`，以及 `all`。`all` 會依主機能力過濾，這台主機建置不出來的目標會跳過而不是報錯失敗；`ios` 被刻意排除在 `all` 之外，讓無人值守的執行永遠不必做程式碼簽署的決定。`windows` 與 `linux` 則必須在各自的作業系統上建置。

<!-- evidence: scripts/build_apps.py:289-305 -->

### 色彩閘門

原生解碼器函式庫在通過 runbook S4 色彩閘門之前一律不受信任——這是一項藍天樣本檢查，斷言藍色通道數值高於紅色通道，用來抓出色彩矩陣接錯的解碼器。建置流程的 Phase 0 會直接拒絕放入未過閘的函式庫。

- 每次需要跑原生建置，就透過 `--cfa-sample-dng <file>` 傳入一張藍天 DNG 樣本。
- `--no-colour-gate` 是刻意張揚的跳過選項：用了它的執行**一律以 exit code 2 結束、絕不會是 0**，產出的函式庫也會被標記為未經驗證。

<!-- evidence: scripts/build_apps.py:1223-1230 (Phase 0 refusal), scripts/build_apps.py:2330 (skip warning), scripts/build_apps.py:3037-3039 (--no-colour-gate exits 2) -->

### 建置產出物與哪些屬於原始碼

建置產出物一律落在根目錄的 `build/` 底下。`android/`、`ios/`、`macos/`、`web/`、`windows/` 與 `linux/` 是原始碼與設定，不是建置產出物——這些目錄會留在版本控制中。

### 關於 Windows 路徑的說明

在 Windows 上，`scripts/build_apps.py` 完全不會編譯解碼器。它會從
`scripts/ceyx_release_pin.json` 釘定的 Ceyx release 下載三個預先建好的 DLL——
`dng_decoder_native.dll`，以及它動態匯入的 `heif.dll` 與 `libde265.dll`——並拒絕
放入任何 SHA-256 對不上釘定值的檔案。這些 DLL 由 Ceyx 自己的 Windows CI 產生，
CI 會在發佈前斷言預期匯出的符號，並對建好的 DLL 跑一次功能性的 codec 能力探測。

但那條 CI 並不會跑色彩閘門。runbook S4 檢查（解碼一張 CFA 樣本，斷言藍天 B ≫ R）
只守護在本機編譯出來的函式庫；對於下載來的預建函式庫，完整性控管靠的是釘定的
雜湊值，不是渲染出來的影像。所以這個釘定的 Windows DLL 已驗證過是 release 發佈
的原始位元組、也匯出了 Halcyon 需要的能力，但它的色彩輸出並未在 Windows 上被
色彩閘門驗證過。

<!-- evidence: scripts/ceyx_release_pin.json (tag v0.1.23, "windows" atomic three-DLL group
     with per-member sha256); scripts/build_apps.py:1650-1653 ("The runbook S4 colour gate is
     NOT consulted here: it gates LOCALLY COMPILED libraries"); ../ceyx/.github/workflows/
     windows_build.yml:475-816 (symbol assertions, codec_capability_probe.py G1, functional
     probe_codecs CI-T3) — no S4/cfa-colour step exists in any ceyx workflow (grep "S4",
     "cfa_color" over .github/workflows returns nothing). -->

---

## 測試與品質閘門

```bash
flutter analyze                                   # must report 0 issues
flutter test                                      # full suite
flutter test test/providers/app_state_test.dart   # a single file
flutter test --coverage
```

測試套件在 `test/` 下共有 108 個測試檔案，結構對照 `lib/`：`models/`、`providers/`、`services/`、`views/`、`perf/`，另外 `test/support/` 下還有共用的假物件（fake）。每個測試都設有 10 秒逾時限制。

<!-- evidence: dart_test.yaml:1, test/ directory listing 2026-09-12 (108 *_test.dart files) -->

`flutter analyze` 回報零問題是硬性閘門，不是偏好——只要它報出任何問題，工作就還沒完成。注意靜態分析的範圍涵蓋 `lib/`、`test/` **以及** `tool/`，所以只掃過 `lib/` 與 `test/` 的符號重新命名，仍然會讓這道閘門過不了。

<!-- evidence: CLAUDE.md Commands section; docs/sop/memory.md 2026-08-25 naming-refactor entry -->

### 是什麼讓這套測試成為可能

`AppState` 透過建構子注入的協作物件（詳見[架構](#架構)），就是這套測試能用假物件
取代檔案系統或平台通道的原因；解碼器介面也是用同一套做法測試的。

<!-- evidence: lib/providers/app_state.dart constructor; lib/services/image_pipeline/dng_decode_contract.dart -->

### 測試策略文件

本專案在工作副本的 `docs/sop/` 目錄下維護一份內部測試策略文件：以 TC-NNN 編號的測試案例矩陣，記錄每個案例的通過/失敗歷史與涵蓋範圍的優先順序。這份文件不受版控追蹤，全新 clone 裡不會有。手上有這份文件時，本儲存庫新增的任何測試都應該在矩陣裡對應一筆條目。它也記下了試過卻刻意放棄的案例，例如某個把測試執行器計時器卡死的完整鍵盤元件測試——想重試同類測試前，值得先翻一翻。

<!-- evidence: docs/sop/unit_test.md:1-3, docs/sop/unit_test.md:197 -->

### 已知的測試陷阱

本程式碼庫有兩個曾經真正吃掉時間的陷阱，記錄在專案內部的架構筆記中
（工作副本裡的 `docs/sop/memory.md`；全新 clone 不會有）：

- 執行真實 `dart:io` 工作的 `testWidgets` 主體，必須包在 `tester.runAsync` 裡；在 `FakeAsync` 內等待真實引擎的 future 會永遠卡住。
- 在 `testWidgets` 裡點擊 `PopupMenuItem`，在 `FakeAsync` 底下會卡住不動。

<!-- evidence: docs/sop/memory.md G-020, docs/sop/memory.md G-013 -->

---

## 第三方歸屬

Halcyon 自己在這個 repository 裡的原始碼並未宣告任何授權條款——repository 根目錄
沒有 `LICENSE` 檔案，`pubspec.yaml` 裡也沒有 `license:` 欄位。
<!-- evidence: pubspec.yaml:1-19 -->
Halcyon *實際*綑綁的，是一組在 `pubspec.yaml` 中宣告的 Dart 套件，外加透過姊妹專案
Ceyx 間接引入的原生 RAW/DNG 解碼堆疊。這個堆疊由 Ceyx 編譯，而 Halcyon 在每個平台上
都把它一起打包進自己的 app 執行檔。

| 元件 | 授權 | 備註 |
|---|---|---|
| 直接的 Dart 相依套件（`provider`、`path`、`image`、`exif`、`desktop_drop` 等） | 多為 MIT / BSD-3-Clause / Apache-2.0 | 逐套件的判定列在連結文件中，不是憑生態系籠統推斷 |
| Adobe DNG SDK | Adobe DNG SDK License Agreement | 透過 `ceyx` 間接引入 |
| LibRaw, RawSpeed3 | LGPL-2.1（靜態連結） | 透過 `ceyx` 間接引入，附帶原始碼提供義務——詳見下方未決問題 |
| Halide, pugixml, LibRaw-cmake | MIT | 透過 `ceyx` 間接引入 |
| libjpeg-turbo, zlib, x3f-tools | 寬鬆授權（IJG/BSD/zlib/BSD-3-Clause） | 透過 `ceyx` 間接引入 |

完整清點——確切版本、各套件授權文字的來源，以及每項歸屬背後的推理——都收錄在
[`docs/legal/THIRD_PARTY_LICENSES.md`](docs/legal/THIRD_PARTY_LICENSES.md)。

其中有一項還沒有定案，該文件把它標記成未解決的法律問題，而不是在這裡直接下結論。
LibRaw 與 RawSpeed3 採 LGPL-2.1 授權，並靜態連結進 Halcyon 出貨的原生函式庫，這代表
Halcyon 有義務向拿到執行檔的人提供原始碼或可重新連結的目的檔（object）。目前還不清楚
Ceyx 自己的原始碼提供是否已經涵蓋 Halcyon 的發行版建置，還是 Halcyon 的發行流程需要
另外準備一份。這件事得在 Halcyon 散布到這個開發環境之外以前先經過法律審查。

---

## 文件維護

本專案在工作副本的 `docs/sop/` 目錄下維護一組內部的時間戳驅動流程文件；這些文件
刻意不受版本控制，全新 clone 裡不會有。本 README 負責的是專案的對外說明：
Halcyon 是什麼、能做什麼、怎麼建置、依賴什麼。

功能上線、架構型態改變，或內部進度文件（工作副本內的 `docs/sop/plan.md`）中某個
階段完成時，就更新本檔。在擁有該文件的工作副本中，記得與 `docs/sop/file_index.md`
（目錄地圖）和 `docs/sop/plan.md`（階段進度）保持同步。文中的行為性陳述都附有
`<!-- evidence: 路徑:行號 -->` 註解；修改任一陳述時請重新驗證其出處，不要沿用舊註解。

本檔為英文版 [`README.md`](README.md) 的繁體中文對照版本，兩份內容須同步更新。
