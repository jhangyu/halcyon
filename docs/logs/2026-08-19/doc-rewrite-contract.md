---
date: 2026-08-19
title: "維護文件全面重寫 — 收斂契約"
---

## 終態（一句話）

根目錄 7 份維護文件的每一句話，都能對應到今天樹上的事實（HEAD = cd8af97）；對不上的內容直接刪除，不保留、不改寫成模糊敘述。

## In-scope 交付物

只有這 7 個檔案，全在 repo 根目錄：

`README.md`、`file_index.md`、`handover.md`、`memory.md`、`plan.md`、`task.md`、`unit_test.md`

允許整段刪除重寫。文件既有的 frontmatter（`date:`、`title:`）與「檔案維護政策」段落保留其角色，`date:` 更新為 2026-08-19。

## Out-of-scope（不得碰）

- `rule.md`、`AGENTS.md`：流程 SOP 與行為準則，不是現況紀錄。
- `docs/` 底下任何檔案（本契約檔除外）、`lib/`、`test/`、`macos/`、`ios/`、`android/`、`.claude/`、`.codex`。
- 任何 git 寫入操作：不 commit、不 add、不 stash/reset/checkout --/clean。
- 程式碼本身：發現 bug 只記錄，不修。

## 驗收條件（逐條機械可檢查）

1. 7 個檔案的 `date:` 皆為 2026-08-19。
2. `file_index.md` 列出的 `lib/` 與 `test/` 檔案清單，與 `git ls-files lib test` 完全一致（無多列、無漏列）。
3. `unit_test.md` 記載的測試檔清單與 `test/` 實際檔案一致，測試總數與一次真實 `flutter test` 的結果一致（附該次執行的輸出行）。
4. `task.md` 中的每一條任務狀態，都附上樹上證據（檔案:行號、commit hash 或測試名）；驗證不了的舊條目直接刪除，不得保留為「狀態不明」。
5. 全文不得再出現 2026-05-05 時期已不成立的敘述（例：SnackBar 回饋、未追蹤的 trash_service、Task 12 待自動化驗證）。
6. `git status --short` 中除了這 7 個 .md 與本契約檔外，沒有其他新的修改。

## 輪次預算

1 輪。驗收未全過即停下回報缺口，不自行開下一輪。

## 未來方向章節的處理

`plan.md` 的路線圖、`task.md` 的待辦、`handover.md` 的下一步，凡涉及「接下來要做什麼」而無法從樹上驗證者：不要自行猜測或刪除，整理成一份「待使用者裁決清單」回報給 lead，由 lead 轉呈使用者。這些章節在使用者裁決前維持原狀。

## Parking-lot

輪中一切新發現記在此節，不進本輪任務、不升級為驗收條件。
