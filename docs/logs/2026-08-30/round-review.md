---
date: 2026-08-30
title: "Settings Panel Redesign — Round Review (WP1..WP5)"
---

# Round Review — settings-panel redesign

Reviewed tree: `HEAD = e423aab` (verified `git rev-parse HEAD`). Scope: 7a1cf6d, ffa196b+6561dd8,
fda1fd8+6e13056+fd8fa85, 0404162+e30d928+56257d1, 4ba4d92+e423aab. 2afdf9c (budget raise) is
context only. Measured against the FROZEN spec `Task_settings_redesign_spec.md` + recorded
amendments; no new acceptance criteria added.

**VERDICT: APPROVE — 0 blockers.** 2 should-fix and 4 nits go to the parking lot.

## Evidence I produced in this session (not taken on faith)

| What | Command / artifact | Result |
|---|---|---|
| Static analysis | `flutter analyze` → `scripts/tmp/rev-analyze.txt` | `No issues found!`, `ANALYZE_RC=0` |
| Round test files | `flutter test -j 1 test/views/settings_dialog_test.dart test/views/main_screen_shortcuts_test.dart test/models/shortcut_bindings_test.dart test/providers/app_state_settings_test.dart` → `scripts/tmp/rev-targeted.txt` | 21 tests, `All tests passed!`, `RC=0` |
| Whole suite, by partition | `scripts/tmp/rev-services-ip.txt` (370), `rev-rest.txt` (202), `rev-rest2.txt` (7) | 579 tests, each `All tests passed!` + `RC=0` |
| Adversarial probes 1 | `scripts/tmp/probe_recording_test.dart` → `rev-probe.txt` | 3 probes, `RC=0` |
| Adversarial probes 2 | `scripts/tmp/probe2_test.dart` → `rev-probe2.txt` | 3 probes, `RC=0` |
| Slider theme measurement | `scripts/tmp/probe3_test.dart` → `rev-probe3.txt` | `TRACKHEIGHT=null THUMB=null TRACKSHAPE=null YEAR2023=null` |

A single-process `flutter test -j 1` cannot complete inside this session's foreground timeout;
the partition above is exhaustive over `test/` (`models`, `providers`, `views`, `services/*`,
`perf`, `support`, `main_test.dart`).

## 1. Shortcut recording state machine — attempted refutation, all attempts failed

- **Recorded key does NOT also fire its old action.** Probe binds `X` (which is
  `trashMarkPhoto`'s default) while `starPhoto` records, with a `MainScreen`-shaped
  `Focus` handler installed *behind* a real `showDialog` route: the handler recorded zero
  `KeyDownEvent`s. Mechanism: `shortcuts_tab.dart:62-82` returns `KeyEventResult.handled`
  for every event (not just KeyDown) while `_recording != null`, and the dialog route's focus
  scope is not a descendant of `MainScreen`'s `Focus` anyway.
- **Escape-cancel does not leak into dialog dismissal.** `shortcuts_tab.dart:69-72` handles it;
  probe asserts `find.byType(SettingsDialog)` still finds one widget afterwards, and
  `Press a key…` is gone.
- **Reserved keys** (`shortcut_bindings.dart:61-70`) are rejected with the row left recording and
  the previous binding untouched (`shortcuts_tab.dart:73-78`) — matches §1.4.3 exactly; TC-465
  covers Tab.
- **Conflict tie-break is declaration-order** and derived, not stored:
  `shortcut_bindings.dart:109-124` iterates `ShortcutAction.values`; `main_screen.dart`
  dispatch uses `actionFor` so the earliest-declared action wins and returns `handled`.
- **Cancel-revert vs in-progress recording**: probe records `F` onto `starPhoto`, starts a second
  recording on `zoomIn`, then hits Cancel — binding reverts to `S` **and** `prefs
  ('shortcut.starPhoto')` is back to `null`. No half-restore.
- **Tab switch mid-recording** cancels recording (state is disposed with the tab,
  `settings_dialog.dart:104-108`) and a key pressed afterwards is not captured.

## 2. D1 fidelity — independently re-checked against `mockups/D1.html`

Confirmed against §1.5.2 row by row: dialog 920×560 + radius 8 + `borderSoft` side
(`settings_dialog.dart:81-90`); header paddings/type (`:122-163`); tabbar padding 3 / radius 6 /
gap 4 / tab 6×16 (`settings_primitives.dart:103-140`); tabbar-wrap bottom border + 14px
(`settings_dialog.dart:165-169`); rail 224 + `pane` + left border + padding 16 + heading margin
12 + label→value 2 + item gap 14 (`settings_summary_rail.dart:23-108`); section label 10.5/w600/
0.63 + 8px rule gap (`settings_section_label.dart`); block padding 14×16 radius 5
(`settings_primitives.dart:5-15`); tier cards 12×10, name 12.5 w600, budget 14 w700 accent mono,
formula 10 faint with 2px margin (`memory_tab.dart:86-117`); key chip / record button / conflict
note / footer metrics all match. Only `Colors.white` appears as a colour literal
(`settings_primitives.dart:194`), which §1.5.2 explicitly prescribes for the primary button.
WP5's self-audit fixes in e423aab are real and correct.

Deviations found — see findings 2, 3, 4 below.

## 3. Negative space — what the diff removed

- `lib/views/settings_dialog.dart` keeps its path **and** class name; the only consumer is
  `sidebar_view.dart:372`, untouched. No other import of `views/settings_dialog.dart` exists
  outside the new subdirectory and its test.
- The removed `if/else if` chain (56257d1) had two implicit behaviours; both survive:
  unbound keys return `ignored`, and the two mark actions still report `handled` even when
  `selectedItemID == null` (`main_screen.dart` switch + trailing `return handled`).
- TC-354/TC-355 are superseded by TC-459/TC-460 against the **same** `Key('decodeLaneWidthSlider')`,
  including the ceiling-1 disabled-but-visible case.
- Sidebar q80→q70 (WP1) is a display-only encode; export re-reads the original file at the
  user-chosen quality (WP4), so no exported artefact changed.
- `AppState` gained fields/setters only; existing constructor injection is unchanged and the
  pre-existing suites pass unmodified (partition run above).
- Post-2afdf9c consistency: `retention_policy.dart:99-115` is still the single home of the rung
  triplets (256 via `RetentionPolicy.floor()`, 384, 512) and `app_state.dart:118` names the
  injected policy via `tierForPolicy`, so the header badge/rail cannot disagree with the pipeline.

## 4. Live-apply / Cancel semantics

`settings_dialog.dart:44-65` reverts in `dispose()` unless `_committed`, deferred one frame.
Probes confirm three dismissal paths all revert identically: **Cancel button**, **barrier tap**,
**Escape**. `restoreSettings` (`app_state.dart:575-605`) routes every field back through its
ordinary setter, so prefs and in-memory state cannot diverge; TC-452 asserts prefs too.
No partial-restore path found: the only `catch` is the already-disposed `AppState` case, where
there is nothing left to revert.

## 5. Gate-artifact audit

| Artifact | Bound | RC self-captured | Declared==executed | Verdict |
|---|---|---|---|---|
| `wp2-gate2.txt` | content markers (TC ids) | `TEST_RC=0` at `:522` | `+370` then `All tests passed!` | OK |
| `wp2-postraise.txt` | content markers | `TEST_RC=0` at `:433` | `+370` + pass line | OK |
| `wp3/gate-analyze.txt` | — | `ANALYZE_RC=0` | `No issues found!` | OK |
| `wp3/gate-models.txt` / `gate-providers.txt` | TC-445..452 present | `*_RC=0` | pass line present | OK |
| `tmp/verify/20260830-1644*-impl-wp5-*` | TC-458..467 present | `RC=0` (all three) | pass lines present | OK |
| `tmp/verify/20260830-16{4820,4958,5139}-teamlead-full-test.txt` | — | **absent** | **absent** | **FAILED RUNS** — all three end in `TestDeviceException(Shell subprocess crashed with SIGTERM (-15))`; no `All tests passed!`, no RC line. See should-fix #1. |

## Findings

### should-fix

1. **No successful whole-suite integration gate artifact for this round.**
   `tmp/verify/20260830-165139-teamlead-full-test.txt:595-597` (and the two earlier siblings)
   record a SIGTERM crash of the test shell, not a green run; the later per-directory gates
   (`165326/165332/165337`) do not cover `test/services/*`. Spec Part 2, Verification strategy
   item 3 requires one full `flutter test -j 1` on the merged tree. I closed the coverage gap by
   partition (579 tests green at `e423aab`), but the round's own evidence trail does not contain
   it. Fix: record the partitioned run (or a long-timeout single run) as the round artifact.

2. **Sliders are not wrapped in `SliderTheme`** — `performance_tab.dart:52-68` and `:88-99`.
   §1.5.2 prescribes `trackHeight: 4`, `RoundSliderThumbShape(enabledThumbRadius: 7)` and an
   accent thumb. Measured: `SliderTheme.of(context)` under the app's `useMaterial3: true` theme
   is all-null (`scripts/tmp/rev-probe3.txt`), so framework defaults apply
   (`_SliderDefaultsM3Year2023`, `slider.dart:2194-2195`): the 4px track happens to match, but
   the thumb radius, overlay and value indicator are Material defaults, not D1's 14px dot.

### nit

3. **Shortcut list flow order differs from the mockup.** `shortcuts_tab.dart:90-91` splits
   column-major (rows 0-3 left, 4-6 right), while D1's `.shortcuts-list`
   (`D1.html:81`, `grid-template-columns: 1fr 1fr`) flows row-major
   (Previous|Next, Star|Trash-mark, …). The implementation follows the **frozen spec** §1.5.2
   verbatim, so this is a spec-vs-mockup divergence, not an implementation defect — recorded so
   the user can rule if the visual order matters.

4. **Auto-caption top gap is 16px, not 10px.** `memory_tab.dart:43` adds `SizedBox(height: 10)`
   on top of `settingsCaption`'s built-in `top: 6` (`settings_primitives.dart:24-25`), against
   D1's explicit `style="margin-top:10px"` (`D1.html:161`).

5. **No focus-loss fallback while recording.** `_recording` is cleared only by Cancel, another
   row's Record, tab switch or dispose (`shortcuts_tab.dart:55-60`); there is no
   `onFocusChange` guard. If any focusable widget inside the dialog stole focus mid-recording,
   the row would sit at `Press a key…` and swallow nothing. Unreachable today — the Shortcuts
   tab contains no other focusable control — hence nit, not should-fix.

6. **Conflict note wording is fixed at "is bound twice"** even for 3+ actions on one key
   (`shortcuts_tab.dart:23`). §1.5.5 fixes that sentence, so this matches the frozen copy; noted
   only because the string reads oddly in the (reachable) 3-way conflict state.
