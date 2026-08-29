# Decode-lane SOP staging (apply at merge time)

Written by impl-3-sonnet (Task 7, decode-lane-team). `docs/sop/` is
gitignored, shared, live mutable state in the main `Halcyon` worktree,
possibly being edited concurrently by parallel sessions — it does not exist
in the `Halcyon-decode-lane` worktree at all, so these edits are staged here
instead of applied directly (team-lead ruling, 2026-08-30).

**AD number and all TC numbers below (TC-340..357) are PROVISIONAL.**
Re-take the next free AD number and check TC-340..357 for collisions against
the live register in `docs/sop/memory.md` / `docs/sop/unit_test.md` at merge
time; renumber if any collide, per the plan's Global Constraints.

Branch: `feat/parallel-decode-lane`. Delivered tip at time of writing:
`091a7b1` (Tasks 1-6) + this Task 7 commit.

---

## Section 1 — new AD entry for `docs/sop/memory.md`

Insert as a new entry (verbatim, copied from
`spec-parallel-decode-lane.md` §10, AD number to be resolved at merge):

> ### AD-0NN｜昂貴解碼車道寬度改為可設定（2026-08-30；推翻 AD-033 的「單飛行」條款）
>
> * **背景**：AD-033 的理由是「RAW 解碼會吃滿 CPU，所以 N 條並行只會更慢」。2026-08-30 的
>   headless 量測推翻這個前提：`docs/logs/2026-08-30/decode-cpu-parallelism.txt`，兩次執行
>   差分後的解碼專屬 CPU/wall 比為 **4.666**（同檔 108-121 行，判讀規則在數字存在之前就先
>   寫死）。一次 ceyx 解碼在 28 核（20P+8E）機器上只用到約 4.7 核，剩下的核心閒置。
> * **決策**：`SerialDecodeLane` 一般化為計數式車道（`DecodeLane`），寬度由使用者在設定頁
>   調整，範圍 `1..ceiling`。**AD-033 其餘條款完全不變**：視窗、保留、tier-1/tier-2 半徑、
>   近而遠順序、payload 優先於全解析度升級、pending 重新排序、成本只決定車道不決定視窗。
>   被推翻的只有「同時只能有一個」這一句。
> * **雙重上限**：記憶體階梯（floor 2 / mid 4 / high 5，門檻與 `retentionPolicyFor` 共用）
>   ∧ 核心數（`processors ~/ 5`，上限 5）。8 核機器算出 1，即維持原本的單飛行行為。
> * **width = 1 必須與本次修改前逐位元相同**，這是回歸錨（TC-098b，`image_preload_window_test.dart:315`）。
> * **實測結果**：見 `docs/logs/2026-08-30/decode-lane-width-sweep.txt`（§9 的判讀規則亦
>   先於數字寫定）。28 核 / 256 GiB 機器上 `Speedup(3) = 1.167 < 1.3`，依 §9.3 判讀規則，
>   **`kDefaultDecodeLaneWidth` 由 3 下修為 1**（`retention_policy.dart`）——設定仍然開放給
>   使用者調高（車道上限仍是 5），只是預設不再開啟平行解碼。
> * **關聯**：AD-033（本條只推翻其單飛行條款，其餘保留）、AD-018（早已被 AD-033 推翻）。

One-line status marker to add under the **AD-033** heading (following the
AD-018 precedent at `memory.md:157-158`, AD-033's own body is NOT rewritten):

> （2026-08-30 更新：「同時只能有一個」條款已被 AD-0NN 推翻，其餘條款仍然有效——見 AD-0NN。）

---

## Section 2 — `docs/sop/unit_test.md` matrix rows (TC-340..357)

All green under `flutter test -j 1` on `Halcyon-decode-lane` @ branch
`feat/parallel-decode-lane`; see test-runner-haiku's full-suite report for
this Task 7 delivery (declared count == executed count, `RC=0`,
"All tests passed!") for the aggregate evidence line.

| TC | File:line | Case | Evidence |
|---|---|---|---|
| TC-340 | `test/services/image_pipeline/decode_lane_test.dart:20` | width 1 runs one body at a time | green |
| TC-341 | `test/services/image_pipeline/decode_lane_test.dart:42` | width 3 runs up to three bodies at a time | green |
| TC-342 | `test/services/image_pipeline/decode_lane_test.dart:64` | start order is global priority order, whatever the width | green |
| TC-343 | `test/services/image_pipeline/decode_lane_test.dart:85` | no body starts synchronously inside enqueue | green |
| TC-344 | `test/services/image_pipeline/decode_lane_test.dart:98` | a re-enqueued pending key is reprioritised, not duplicated | green |
| TC-345 | `test/services/image_pipeline/decode_lane_test.dart:135` | a throwing body does not wedge any runner | green |
| TC-346 | `test/services/image_pipeline/decode_lane_test.dart:154` | widening starts pending work; narrowing never pre-empts an in-flight body | green |
| TC-347 | `test/services/image_pipeline/retention_policy_test.dart:74` | lane ceiling follows the memory rung | green |
| TC-348 | `test/services/image_pipeline/retention_policy_test.dart:81` | lane ceiling is also clamped by core count | green |
| TC-349 | `test/services/image_pipeline/retention_policy_test.dart:90` | default width is `kDefaultDecodeLaneWidth` capped by ceiling — expectation UPDATED in Task 7 from 3 to 1 (`defaultLaneWidthFor(5\|3\|2\|1) == 1`) per the §9.3 re-benchmark verdict | green |
| TC-350 | `test/services/image_pipeline/image_preload_controller_test.dart:1445` | controller lane width defaults to 1 and is settable | green |
| TC-351 | `test/providers/app_state_test.dart:614` | lane width defaults to 1 with no ceiling injected | green |
| TC-352 | `test/providers/app_state_test.dart:622` | a persisted width is read back and pushed to the controller | green |
| TC-353 | `test/providers/app_state_test.dart:638` | a persisted width above this machine's ceiling is clamped on read | green |
| TC-354 | `test/views/settings_dialog_test.dart:19` | width slider enabled and writes through when the machine allows parallel decodes | green |
| TC-355 | `test/views/settings_dialog_test.dart:37` | row shown but DISABLED on a machine whose ceiling is 1 (never hidden) | green |
| TC-356 | `test/services/image_pipeline/image_preload_window_test.dart:637` | width-3 controller runs more than one expensive decode at once, never more than three | green (mutation-checked: forcing `_width=1` in `DecodeLane` turns this red, TC-098b stays green; reverted, see Task 6 handoff) |
| TC-357 | `test/services/image_pipeline/image_preload_window_test.dart:673` | width 3 keeps the near-to-far START order: first three starts are distances 0, +1, -1 | green |

---

## Section 3 — `docs/sop/file_index.md` edit

Rename the `serial_decode_lane.dart` entry to `decode_lane.dart`:

- Old: `lib/services/image_pipeline/serial_decode_lane.dart` — the single-flight
  decode lane (at most one expensive RAW decode in flight at a time).
- New: `lib/services/image_pipeline/decode_lane.dart` — counted-slot decode
  lane (`DecodeLane`); up to a user-adjustable `width` expensive RAW decodes
  in flight at once (default 1, ceiling from `laneCeilingFor`), near-to-far
  priority order preserved from the single-flight predecessor
  (AD-0NN, 2026-08-30, supersedes AD-033's single-flight clause only).
