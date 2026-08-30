---
date: 2026-08-30
title: "F1 Fidelity Audit — Settings Dialog vs docs/logs/2026-08-30/mockups/F1.html"
---

# F1 Fidelity Audit

Element-by-element comparison of `lib/views/settings_dialog.dart` + `lib/views/settings_dialog/**`
against `docs/logs/2026-08-30/mockups/F1.html` (both dialog states) plus D1/E1 lineage for
elements F1 doesn't touch (Shortcuts tab). Base commit: `9394a9e` (main). Raw CSS in F1.html is
treated as ground truth over the older prose spec table
(`docs/logs/2026-08-30/Task_settings_redesign_spec.md` §1.5.2) wherever the two disagree — that
table pre-dates round 4 and several of its numbers (tier card font sizes) do not match F1's own
`<style>` block.

Verdict legend: **MATCH** = already correct. **DIVERGE→FIXED** = was wrong, corrected in this
pass. **SANCTIONED** = listed in the task's sanctioned-deviation list. **JUSTIFIED** = a new
deviation this pass found and could not close (Flutter framework constraint), documented instead
of silently skipped.

## Header (F1.html:123-138, both dialog states identical)

| Element | F1 CSS | Flutter | file:line | Verdict |
|---|---|---|---|---|
| `.header` padding | `16px 20px 0 20px` | `EdgeInsets.fromLTRB(20,16,20,0)` | settings_dialog.dart:126 | MATCH |
| `.header h1` | 15px, w600 | 15, w600, t.text | settings_dialog.dart:139-144 | MATCH |
| `.header p` | 11.5px, `--text-dim`, margin-top 3px | 11.5, t.textDim, `SizedBox(3)` | settings_dialog.dart:145-149 | MATCH |
| `.badge` | padding `3px 10px`, radius 20, border `--border`, 10.5px `--text-dim` | `EdgeInsets.symmetric(h:10,v:3)`, radius 20, border t.border, 10.5 t.textDim | settings_dialog.dart:153-163 | MATCH |
| titles row | `justify-content: space-between; align-items: flex-start` | `Row(crossAxisAlignment: start)` with `Expanded` title + badge | settings_dialog.dart:130-165 | MATCH (2-child Expanded+trailing achieves the same visual result as space-between) |
| `.tabbar` | padding 3, `--input` bg, radius 6, gap 4 | `EdgeInsets.all(3)`, t.input, radius 6, `SizedBox(4)` gaps | settings_primitives.dart:104-113 | MATCH |
| `.tab` idle/active | padding `6px 16px`, radius 4, 12px; active bg `--border` + `--text`; idle transparent + `--text-dim` | `EdgeInsets.symmetric(h:16,v:6)`, radius 4, 12; active t.border+t.text; idle null+t.textDim | settings_primitives.dart:120-137 | MATCH |
| `.tabbar` width | `fit-content` | `Row(mainAxisSize: MainAxisSize.min)` | settings_primitives.dart:109-110 | MATCH |
| `.tabbar-wrap` | border-bottom `--border-soft`, padding-bottom 14 | `Border(bottom: t.borderSoft)`, `padding: EdgeInsets.only(bottom:14)` | settings_dialog.dart:167-171 | MATCH |
| Tab labels | `Performance & Memory` / `Export` / `Shortcuts` | same three strings | settings_dialog.dart:173 | MATCH |
| Dialog size | `920×560` | `SizedBox(width:920, height:560)` | settings_dialog.dart:90-92 | MATCH |
| `.dialog` shell | radius 8, border `--border-soft`, bg `--dialog` | `BorderRadius.circular(8)`, `BorderSide(t.borderSoft)`, `t.dialog` | settings_dialog.dart:83-89 | MATCH |
| `.dialog` box-shadow | `0 20px 60px rgba(0,0,0,.5)` | Flutter `Dialog`'s built-in Material elevation shadow (not a literal box-shadow) | settings_dialog.dart:83 | **JUSTIFIED** — `Dialog` has no CSS-style box-shadow API; reproducing the exact blur/spread would require a bespoke `Material`+`CustomPaint` shadow, out of proportion to a barely-visible dialog-on-scrim effect. No prior round flagged or fixed this; left as a framework-imposed shadow. |

## Body shell (F1.html:44-48)

| Element | F1 CSS | Flutter | file:line | Verdict |
|---|---|---|---|---|
| `.body` | `flex:1; display:flex; min-height:0` | `Expanded(child: Row(...))` | settings_dialog.dart:96-116 | MATCH |
| `.tabcontent` | `flex:1; padding:18px 20px; overflow-y:auto` | `Expanded(child: SingleChildScrollView(padding: EdgeInsets.symmetric(h:20,v:18)))` | settings_dialog.dart:100-112 | MATCH |
| `.summary-rail` | width 224, border-left `--border-soft`, bg `--pane`, padding 16, own scroll | `Container(width:224)`, `Border(left: t.borderSoft)`, t.pane, `padding: EdgeInsets.all(16)`, own `SingleChildScrollView` | settings_summary_rail.dart:24-31 | MATCH |
| `.section-label` + `::after` | 10.5px uppercase, `letter-spacing:.06em` (=0.63px @10.5), w600, `--text-faint`, margin-bottom 8, trailing 1px rule | same values, `Row[Text, SizedBox(8), Expanded(Container(h:1))]` | settings_section_label.dart:8-27 | MATCH |
| `.actions` footer | padding `12px 20px`, top border `--border-soft`, gap 10 | `EdgeInsets.symmetric(h:20,v:12)`, `Border(top: t.borderSoft)`, `SizedBox(10)` | settings_primitives.dart:154-201 | MATCH |
| `.btn.secondary` | padding `7px 16px`, radius 5, 12.5px, `--surface` bg, `--border` border | same | settings_primitives.dart:162-181 | MATCH |
| `.btn.primary` | padding `7px 16px`, radius 5, `--accent` bg+border, white text | `t.accent` bg, no explicit border drawn (bg==border colour so visually identical), white text | settings_primitives.dart:183-198 | MATCH (border omission is visually inert: border-color equals background-color in the mockup) |

## Summary rail contents (F1.html:174-182 / :244-252, identical both states)

| Element | F1 order/copy | Flutter (before fix) | Flutter (after fix) | file:line | Verdict |
|---|---|---|---|---|---|
| Item order | Concurrent decodes, Export filetype, Export quality, Export size, Retention tier, Shortcut conflicts | **Export filetype, Concurrent decodes**, quality, size, tier, conflicts (swapped) | reordered to match F1 | settings_summary_rail.dart:44-70 | **DIVERGE→FIXED** |
| `.summary-item` spacing | margin-bottom 14px | `SizedBox(14)` | unchanged | settings_summary_rail.dart | MATCH |
| `.label` | 10.5px `--text-faint`, margin-bottom 2 | 10.5, t.textFaint, `SizedBox(2)` | unchanged | settings_summary_rail.dart:134-135 | MATCH |
| `.val` | 13px monospace `--text` | 13, monospace, t.text | unchanged | settings_summary_rail.dart | MATCH |
| `.val.warn` | `--danger` | t.danger when conflicts>0 | unchanged | settings_summary_rail.dart:120 | MATCH |
| Heading text | `At a glance` (rendered uppercase via `text-transform`) | literal `'AT A GLANCE'` | unchanged | settings_summary_rail.dart:36 | MATCH (same rendered output) |

## Performance & Memory tab (F1.html:140-172, round-4 state)

| Element | F1 CSS | Flutter (before) | Flutter (after) | file:line | Verdict |
|---|---|---|---|---|---|
| `.grid.ratio-2-3` | `grid-template-columns: 2fr 3fr`, gap 16 | `Expanded(flex:2)` / `SizedBox(16)` / `Expanded(flex:3)` | unchanged | performance_memory_tab.dart:30-39 | MATCH |
| `.block` height | grid item stretches, `.block{height:100%}` | `IntrinsicHeight`+`CrossAxisAlignment.stretch` | unchanged | performance_memory_tab.dart:30-32 | MATCH |
| Parallelism row-label/caption | 12.5px / 11px monospace | same | unchanged | performance_memory_tab.dart:56-62 | MATCH |
| `input[type=range]` (decode slider) | track height 4, thumb 14px dia (radius 7) | plain `Slider` — Flutter default thumb radius 10, no explicit trackHeight | `settingsSlider()` wrapping `SliderTheme(trackHeight:4, RoundSliderThumbShape(enabledThumbRadius:7))` | performance_memory_tab.dart:63, settings_primitives.dart (new `settingsSlider`) | **DIVERGE→FIXED** (parked finding from prior round review) |
| Section gap (row → Workflow) | `.section{margin-bottom:18px}` | `SizedBox(18)` | unchanged | performance_memory_tab.dart:40 | MATCH (per translation-table §1.5.2 convention: 18px vertical gap represents the section's own margin, not stacked with grid row-gap) |
| Workflow checkboxes | `.row` space-between, natural width | `Wrap` (documented Flutter-only fix for `CheckboxListTile` touch-target overflow) | unchanged | performance_memory_tab.dart:87-160 | **SANCTIONED** (explicitly listed) |
| `.tier-row` gap | `gap: 6px` | `SizedBox(width: 8)` | `SizedBox(width: 6)` | performance_memory_tab.dart:174-175 | **DIVERGE→FIXED** |
| `.tier` padding | `padding: 8px 6px` | `EdgeInsets.symmetric(h:12,v:10)` | `EdgeInsets.symmetric(h:6,v:8)` | performance_memory_tab.dart:236 | **DIVERGE→FIXED** |
| `.tier` unselected background | none set (shows parent `.block`'s `--pane` through) | `t.surface` | `null` (transparent) | performance_memory_tab.dart:230 | **DIVERGE→FIXED** — D1's `.tier` did set `background:var(--surface)` (D1.html:75); F1 dropped it, an intentional F1 override |
| `.tier` selected | bg `rgba(accent,.18)`, border accent | same | unchanged | performance_memory_tab.dart:230,238 | MATCH |
| `.tier .name` | 10.5px w600 | 12.5px w600 | 10.5px w600 | performance_memory_tab.dart:244-251 | **DIVERGE→FIXED** (raw F1 CSS overrides the older prose-spec table's 12.5px) |
| `.tier .val` | 11px w700 monospace accent, margin-top 2 | 14px w700 | 11px w700, `SizedBox(2)` kept | performance_memory_tab.dart:252-261 | **DIVERGE→FIXED** |
| `.tier .formula` | 8.5px `--text-faint`, margin-top 1, copy `−N / +N` (no "photos" suffix, F1.html:155-157) | 10px, `SizedBox(2)`, text `'−N / +N photos'` | 8.5px, `SizedBox(1)`, text `'−N / +N'` | performance_memory_tab.dart:262-268 | **DIVERGE→FIXED** — F1 dropped D1's "photos" suffix and shrank the font in the same round-4 pass; no test asserted the old copy |
| Memory Retention caption + reset button | inline `margin-top:10px` override, "Auto-picked..." / "Use detected default" | `SizedBox(10)` then `Wrap` | unchanged | performance_memory_tab.dart:187-212 | MATCH |

## Export tab (F1.html:210-243, round-4 renamed labels)

| Element | F1 CSS/copy | Flutter (before) | Flutter (after) | file:line | Verdict |
|---|---|---|---|---|---|
| Section labels | `File Type` / `Quality` / `Size` | same | unchanged | export_tab.dart:53,120,158 | MATCH (TC-482 covers this) |
| Row labels | `Filetype of the export image` / `Quality setting of the encoder` / `Size of the export image` | same | unchanged | export_tab.dart:59,126,164 | MATCH |
| Gap: File Type section → Quality/Size row | `.section{margin-bottom:18px}` (consistent with Perf/Mem tab's row gap) | `SizedBox(10)` | `SizedBox(18)` | export_tab.dart:27 | **DIVERGE→FIXED** |
| `.segmented` margin-top | 10px | `SizedBox(4)` | `SizedBox(10)` | export_tab.dart:61 | **DIVERGE→FIXED** |
| `.segment` padding | `7px 10px` | `EdgeInsets.symmetric(h:8,v:7)` | `EdgeInsets.symmetric(h:10,v:7)` | export_tab.dart:94 | **DIVERGE→FIXED** |
| `.segment` gap | 6px | `SizedBox(width:6)` | unchanged | export_tab.dart:65 | MATCH |
| `.segment` selected/unselected colours | selected: `rgba(accent,.18)` bg + accent border + `--text`; unselected: `--surface` bg + `--border-soft` border + `--text-dim` | same | unchanged | export_tab.dart:88,97,103-106 | MATCH |
| Filetype list shown | JPEG, WebP (lossy) only | same (HEIF/WebP-lossless filtered out) | unchanged | export_tab.dart:49 | **SANCTIONED** (ceyx encode capability gap, documented) |
| Quality slider range | `min=50 max=100 step=5` | `min:50,max:100,divisions:10` | unchanged | export_tab.dart:130-132 | MATCH |
| Quality slider theme | trackHeight 4, radius-7 thumb | plain `Slider` | `settingsSlider()` | export_tab.dart:128 | **DIVERGE→FIXED** |
| Quality slider enabled state | slider always interactive (2 quality-driven filetypes) | unconditional `onChanged` | unchanged | export_tab.dart:137-139 | **SANCTIONED** (lossless not shipped) |
| Size slider range | `min=0 max=7 step=1` | data-driven from `kExportLongEdgeStops` (8 stops) | unchanged | export_tab.dart:173-175 | MATCH |
| Size slider theme | trackHeight 4, radius-7 thumb | plain `Slider` | `settingsSlider()` | export_tab.dart:171 | **DIVERGE→FIXED** |

## Shortcuts tab (not in F1.html; audited against D1.html lineage, unchanged by F1)

| Element | D1 CSS | Flutter | file:line | Verdict |
|---|---|---|---|---|
| `.shortcut-row` padding / border | `8px 0`, bottom `--border-soft` except last row | `EdgeInsets.symmetric(v:8)`, border on all but each column's last item | shortcuts_tab.dart:193-199 | MATCH (see note below) |
| `.key-chip` | monospace 11.5px, `--input` bg, `--border` border, radius 5, padding `4px 10px`, minWidth 40 | same | settings_primitives.dart:38-57 | MATCH |
| `.key-chip.conflict` | `--danger` text+border, `rgba(danger,.12)` bg | same | settings_primitives.dart:44-45,53 | MATCH |
| `.record-btn` | 11px `--text-dim`, transparent, `--border-soft` border, radius 5, padding `4px 8px`, margin-left 8 | same | settings_primitives.dart:60-83 | MATCH |
| `.conflict-note` | 10.5px `--danger`, margin-top 8, icon+gap 4 | `Icon(warning_amber_rounded, size:12, color:t.danger)`, `SizedBox(4)`, 10.5px text | shortcuts_tab.dart:141-155 | MATCH |
| 2-column row grouping | CSS grid `auto-flow: row` interleaves items 1,3,5,7 into col 1 and 2,4,6 into col 2 | Flutter groups actions 0-3 into left column, 4-6 into right column (column-major, not row-major) | shortcuts_tab.dart:90-91 | **SANCTIONED (pre-existing, out of scope)** — this exact split (`0..3` / `4..6`) is the frozen interface in the spec's translation table (§1.5.2) from an earlier round, predates this F1 fidelity task, and F1.html does not render the Shortcuts tab at all (no new visual authority to check it against). Reflowing to interleaved order would be a behavioural change to a tab this round's mockup doesn't touch; flagged here for the lead's awareness rather than changed unilaterally. |

## Sanctioned deviations confirmed present (per task prompt, not re-litigated)

- Runtime-derived numbers (256/384/512-style budgets, decode ceilings) — data-driven, correct by construction.
- Real shortcut defaults (arrow keys / S / X / R) vs mockup's demo double-binding on X — `shortcut_bindings.dart` defaults confirmed unchanged.
- §1.5.6 copy inventory strings — spot-checked against every string above; no drift found beyond the tier-formula "photos" wording (which F1's own CSS/markup, not the copy-inventory table, already dropped — treated as a fix, not a new deviation).
- Workflow `Wrap` fallback (performance_memory_tab.dart:84-149) — present, comment intact.
- Export quality slider always-enabled — present (export_tab.dart:114-116).

## Fix summary

9 DIVERGE rows fixed in `performance_memory_tab.dart`, `export_tab.dart`, and
`settings_summary_rail.dart`; 1 new shared helper (`settingsSlider` in `settings_primitives.dart`)
added and wired into all three sliders (decode lane width, export quality, export size) to close
the parked SliderTheme finding. 1 JUSTIFIED framework-constraint deviation documented (dialog
box-shadow). 1 pre-existing SANCTIONED-by-scope item flagged for lead awareness (Shortcuts tab
2-column grouping order) but left unchanged, since it predates this round and F1.html does not
render that tab.

## Verification

```
$ git rev-parse HEAD
9394a9e966052b8327463bdea11f4cca994d0a5b   # base, before this pass's uncommitted changes
$ flutter analyze; echo RC=$?
No issues found!
RC=0
$ flutter test test/views/ -j 1; echo RC=$?
...
+52: All tests passed!
RC=0
```

New test: `TC-485` in `test/views/settings_dialog_test.dart` asserts every settings `Slider` is
wrapped in a `SliderTheme` with `trackHeight: 4` and a `RoundSliderThumbShape` thumb.
