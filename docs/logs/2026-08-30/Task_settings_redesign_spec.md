---
date: 2026-08-30
title: "Settings Panel Redesign — Spec + Implementation Plan"
---

# Settings Panel Redesign — Spec + Implementation Plan

Three parts: **Part 1 — Spec** (semantics, shortcut architecture, D1→Flutter translation,
shared-quality refactor), **Part 2 — Implementation Plan** (5 work packages, disjoint file
ownership, mechanical acceptance criteria), **Part 3 — Decision record & risks**.

**Status: FROZEN 2026-08-30.** The five original user directives plus the three rulings in §3.2
are settled. Nothing in this document is an open question.

Every code claim below carries `file:line` as read on 2026-08-30 at working-tree state
(uncommitted changes present; claims bound by content markers, not a commit hash).

---

# Part 1 — Spec

## 1.1 Frozen inputs (restated verbatim, not relitigated)

1. Visual design = `docs/logs/2026-08-30/mockups/D1.html` exactly (B3 shell: top segmented tabs +
   right-hand summary rail; B2-style section dividers + 2-col grid inside tabs; A1 typography).
   D1's "X bound twice" is a *state demo*, not a default.
2. Settings included: decode lane width slider, export JPEG quality slider (default 90), memory
   retention preset (Conservative/Balanced/Generous with concrete budgets), custom keyboard
   shortcuts (all 7 remappable, record UI, conflict detection).
3. Persistence: existing `SharedPreferences` pattern in `lib/providers/app_state.dart`. No new
   mechanism.
4. Non-UI: sidebar thumbnail JPEG quality (`sidebar_thumbnail_codec.dart:26,54`, currently 80)
   aligned to 70 by **sharing one constant** with the payload re-encoder
   (`payload_reencoder.dart:34`). Not user-exposed.
5. Out of scope: tier-2 debounce, payload quality setting, pixel targets, `kCoresPerDecode`.

## 1.2 Current-state facts this spec builds on

| Fact | Evidence |
|---|---|
| Dialog is a bare `AlertDialog`, 91 lines, no tokens | `lib/views/settings_dialog.dart:12-15` |
| Opened from the sidebar menu, non-const call | `lib/views/sidebar_view.dart:372` |
| Prefs handle + hydration | `lib/providers/app_state.dart:142` (`SharedPreferences? _prefs`), `:154` |
| Existing keys `autoAdvance` / `overwriteExisting` / `decodeLaneWidth` | `app_state.dart:155,156,161-172` (read), `:442-445,448-451,454-457` (write) |
| Lane width clamps on READ as well as write | `app_state.dart:161-172` |
| Retention rungs 224/304/384 MiB, `-3/+5`, `-3/+8`, `-3/+11` | `lib/services/image_pipeline/retention_policy.dart:63-82`; floor constants `photo_payload_cache.dart:6,10,35` |
| `ImagePreloadController.retention` is **final** | `lib/services/image_pipeline/image_preload_controller.dart:101,115` |
| `PhotoPayloadCache.byteBudget` is **final**, enforced in `_enforceBudget` | `photo_payload_cache.dart:54,56,140` |
| Cache is constructed from retention at controller construction time | `image_preload_controller.dart:109` |
| Export quality is the literal `90` at three sites | `lib/services/library/photo_export_service.dart:126,141,331` |
| Export service is built once inside `AppState`'s initializer list | `app_state.dart:70,84,119` |
| The fetch closure is `(path) => exportBytesFor(path, decoder: decoder)` | `photo_export_service.dart:38-39` |
| Payload re-encode quality constant | `payload_reencoder.dart:34` (`kReencodeJpegQuality = 70`) |
| Sidebar tile quality default param | `sidebar_thumbnail_codec.dart:26` (`int jpegQuality = 80`), used at `:54` |
| Both encode paths funnel through one encoder | `lib/services/image_pipeline/jpeg_encoder.dart:17-22` (`encodeJpegFromRgba`) |
| All 7 shortcuts live in one `if/else if` chain | `lib/views/main_screen.dart:93-135`, bindings at `:104,107,110,115,120,123,126` |
| Design tokens (13 fields, `HalcyonTokens.of(context)`) | `lib/views/theme_tokens.dart:35-52,88-89` |
| Rename dialog is the Flutter idiom to imitate | `lib/views/rename_dialog/rename_dialog.dart:125-127` (Dialog, fixed size), `:177-221` (header), `section_label.dart:7-19` |
| Existing dialog tests, TC-354/TC-355 | `test/views/settings_dialog_test.dart:19,36` |
| Highest allocated ids today | TC-437 (`docs/sop/unit_test.md`), AD-042 / G-027 (`docs/sop/memory.md`) |

## 1.3 Settings semantics

All settings are **app-wide** (`SharedPreferences`), **live-applied on change**, and
**reverted by Cancel** (§1.6). Every read is defensive: `getInt`/`getString` are wrapped in
`try/catch` exactly like the existing lane-width read (`app_state.dart:161-172`), because a
hand-edited or type-mismatched prefs store must not crash startup.

### S1 — Concurrent RAW decodes (existing, carried forward unchanged)

**USER DIRECTIVE 2026-08-30:** the visible label is **`Concurrent RAW decodes`**, not "Decode
lane width". "Lane width" is pipeline jargon that means nothing to a photographer. The rename is
**user-facing copy only** — every internal identifier keeps the lane terminology
(`decodeLaneWidth` pref key, `AppState.decodeLaneWidth` / `setDecodeLaneWidth`,
`maxDecodeLaneWidth`, `laneCeilingFor`, `defaultLaneWidthFor`, `kDefaultDecodeLaneWidth`,
`Key('decodeLaneWidthSlider')`). Renaming those would be a cross-cutting refactor with zero user
benefit, and the widget key in particular must stay byte-identical so the carried-forward tests
keep addressing the same slider.

| Field | Value |
|---|---|
| Visible label | `Concurrent RAW decodes` |
| Pref key | `decodeLaneWidth` (int) — internal name unchanged |
| Range | `1 .. AppState.maxDecodeLaneWidth` (machine ceiling, `laneCeilingFor`, `retention_policy.dart:118-127`) |
| Default | `defaultLaneWidthFor(ceiling)` = `min(3, ceiling)` (`retention_policy.dart:130-131`) |
| Clamp | on read AND write (`app_state.dart:161-172,454-457`) |
| Live effect | `_preloadController.setDecodeLaneWidth` (`image_preload_controller.dart:133`) |
| Disabled state | when `maxDecodeLaneWidth == 1`, the row is **shown but disabled** — existing behaviour, TC-355 |

No semantic change. Only the widget presentation moves (§1.5).

### S2 — Export JPEG quality (new)

| Field | Value |
|---|---|
| Pref key | `exportJpegQuality` (int) |
| Range | 70..100, **step 5** → 7 stops: 70, 75, 80, 85, 90, 95, 100 |
| Default | 90 (matches today's three literals, `photo_export_service.dart:126,141,331`) |
| Normalisation | on read AND write: `((v / 5).round() * 5).clamp(70, 100)`; unreadable/absent → 90 |
| Live effect | `_exportService.jpegQuality = value` — the fetch closure reads the field at call time |
| Scope | applies to `PhotoExportService.exportBytesFor` and `exportJpegForTest`; the EXIF re-encode at `:141` uses the same value as the first encode at `:126` |

Rationale for step 5 rather than a free 1..100 slider: D1 renders `step="5"`
(`D1.html:140`), and quality below 70 is not a use case for an export the user shares.

### S3 — Memory retention tier (new)

Three named tiers mapping onto the **existing** rungs — no new byte arithmetic, no
re-derivation (`retention_policy.dart:63-82`):

| Tier | `before` | `after` | `payloadByteBudget` | Auto-selected when |
|---|---|---|---|---|
| Conservative | 3 | 5 | 224 MiB | RAM < 12 GiB, or RAM unknown (every non-macOS platform today) |
| Balanced | 3 | 8 | 304 MiB | 12 GiB ≤ RAM < 32 GiB |
| Generous | 3 | 11 | 384 MiB | RAM ≥ 32 GiB |

| Field | Value |
|---|---|
| Pref key | `retentionTier` (String: `conservative` \| `balanced` \| `generous`) |
| Default | **key absent = auto**: the tier whose policy equals the one `main.dart:65` already passed into `AppState` (derived from `retentionPolicyFor`) |
| Unknown/garbage stored value | treated as absent (auto) |
| Reset affordance | "Use detected default" text button removes the key (`_prefs?.remove('retentionTier')`) and re-applies the auto policy |
| Live effect | `_preloadController.setRetention(policy)`, which resizes the payload cache budget and immediately runs an eviction sweep (§1.7) |

**The tier does NOT change the decode lane ceiling.** `laneCeilingFor`
(`retention_policy.dart:118-127`) stays a pure RAM+CPU function. A user who selects
"Generous" on an 8 GiB machine widens retention only; the transient-peak memory ceiling on
concurrent decodes is untouched. This is the deliberate boundary that keeps frozen decision 5
intact.

### S4 — Keyboard shortcuts (new; architecture in §1.4)

| Field | Value |
|---|---|
| Pref keys | one per action: `shortcut.previousPhoto`, `shortcut.nextPhoto`, `shortcut.starPhoto`, `shortcut.trashMarkPhoto`, `shortcut.zoomIn`, `shortcut.zoomOut`, `shortcut.toggleRecycleMode` (int = `LogicalKeyboardKey.keyId`) |
| Defaults | exactly today's chain (`main_screen.dart:104-128`): `arrowLeft`, `arrowRight`, `keyS`, `keyX`, `arrowUp`, `arrowDown`, `keyR` |
| Absent / unreadable key | falls back to that action's default, per action independently |
| Reset affordances | per-row "Reset" (shown only when the binding differs from default) and "Reset all shortcuts" at the bottom of the Shortcuts tab |

### S5 — Existing booleans (carried forward, restyled only)

`autoAdvance` (default `false`, `app_state.dart:138,442-445`) and `overwriteExisting`
(default `true`, `app_state.dart:139,448-451`) keep their keys, defaults and setters. They are
placed in a **"Workflow"** section on the Performance tab (§1.5.3; user ruling D-2026-08-30, §3.2 D-1).

## 1.4 Shortcut remap architecture

### 1.4.1 The action set

A new file `lib/models/shortcut_bindings.dart` owns the whole model — it is deliberately in
`models/`, not `views/`, because both `AppState` (persistence) and `MainScreen` (dispatch) read
it, and neither should depend on the other.

```dart
enum ShortcutAction {
  previousPhoto('previousPhoto', 'Previous photo', LogicalKeyboardKey.arrowLeft),
  nextPhoto('nextPhoto', 'Next photo', LogicalKeyboardKey.arrowRight),
  starPhoto('starPhoto', 'Star photo', LogicalKeyboardKey.keyS),
  trashMarkPhoto('trashMarkPhoto', 'Trash-mark photo', LogicalKeyboardKey.keyX),
  zoomIn('zoomIn', 'Zoom in', LogicalKeyboardKey.arrowUp),
  zoomOut('zoomOut', 'Zoom out', LogicalKeyboardKey.arrowDown),
  toggleRecycleMode('toggleRecycleMode', 'Toggle recycle mode', LogicalKeyboardKey.keyR);
  ...
  String get prefsKey => 'shortcut.$id';
}
```

**Declaration order is load-bearing** — it is the canonical order used for (a) the row order in
the UI, exactly matching D1's list order (`D1.html:172-178`), and (b) duplicate-binding
resolution at dispatch time (§1.4.3).

### 1.4.2 The binding map

`ShortcutBindings` is an immutable `Map<ShortcutAction, LogicalKeyboardKey>` wrapper:

- `ShortcutBindings.defaults()` — every action at its declared default.
- `keyFor(action)` — never null (falls back to the action's default).
- `withBinding(action, key)` — returns a new instance.
- `conflicts` — `Map<LogicalKeyboardKey, List<ShortcutAction>>` containing only keys bound by
  **two or more** actions, each list in canonical order. Empty map = no conflicts.
- `actionFor(key)` — the **first** action in canonical order bound to `key`, or `null`.
- `isDefault(action)` / `hasAnyNonDefault`.

Serialisation is per-action, not one blob: one `int` pref per action (`keyId`). Rationale:
a single corrupt entry degrades one binding to its default instead of resetting all seven, and
it matches the existing flat key/value style (`app_state.dart:155-172`).

### 1.4.3 Conflict rules — **warn, never block**

This is the decisive semantic choice, and it is forced by the frozen visual: D1 renders a
persistent two-chip conflict state plus a conflict note (`D1.html:175,178,179`) and a rail
counter (`D1.html:190`). A blocking validator would make that state unreachable, so recording
must accept conflicting keys.

| Situation | Behaviour |
|---|---|
| User records a key already bound to another action | **Accepted and persisted.** Both chips render in danger style; a conflict note lists the key and every conflicting action name; the rail's "Shortcut conflicts" value turns danger-coloured and reads `N conflict(s) (K1, K2)`. |
| User records a *reserved* key | **Rejected.** The row stays in recording mode and shows inline danger text naming the key, e.g. `Tab can't be used as a shortcut.` The previous binding is untouched. |
| User presses Escape while recording | **Cancels** recording; previous binding untouched. Escape is therefore never bindable. |
| Two actions share a key at runtime | The action **earliest in `ShortcutAction` declaration order** fires; the handler returns `KeyEventResult.handled` and no second action runs. Deterministic and documented in the note text. |
| Modifiers held while a bound key is pressed | The shortcut still fires. This preserves today's behaviour exactly — `main_screen.dart:100-132` inspects only `event.logicalKey`. Recording likewise captures only `logicalKey`; there are no chords. |

**Reserved keys** (`kReservedShortcutKeys`, rejected on record):
`escape`, `tab`, `enter`, `numpadEnter`, and every modifier pressed alone
(`shiftLeft/Right`, `controlLeft/Right`, `altLeft/Right`, `metaLeft/Right`).
Reason: Escape and Tab are the dialog's own dismissal/traversal keys, Enter activates the
focused button, and a bare modifier can never be a usable single-key trigger.

There is **no** "block save" state and no disabled Done button: everything is live-applied, so
there is nothing to gate.

### 1.4.4 Record-a-key UI flow (complete — no TBD)

State lives in the Shortcuts tab widget: `ShortcutAction? _recording` and
`String? _recordError`.

1. **Idle row** — `[action name] .... [key chip] [Record] ([Reset] if non-default)`.
2. **Click Record** → `_recording = action`, `_recordError = null`. Any other row already
   recording is cancelled first (only one recorder at a time). The chip is replaced by an
   accent-bordered chip reading `Press a key…`; the button label becomes `Cancel`.
3. A `Focus` node inside the Shortcuts tab takes focus and returns
   `KeyEventResult.handled` for **every** `KeyDownEvent` while `_recording != null`, so nothing
   leaks to the dialog or to `MainScreen` behind it.
4. On the first `KeyDownEvent`:
   - `logicalKey == escape` → exit recording, no change.
   - `kReservedShortcutKeys.contains(logicalKey)` → stay recording, set `_recordError` to
     `'${keyLabelFor(key)} can\'t be used as a shortcut.'` (rendered under the row in
     `t.danger`, 10.5px).
   - otherwise → `context.read<AppState>().setShortcutBinding(action, key)`, exit recording,
     recompute conflicts (derived, not stored).
5. **Cancelled automatically** by: clicking `Cancel`, clicking `Record` on another row,
   switching tabs, or the dialog closing.
6. Repeats are ignored: only `KeyDownEvent` is consumed (`KeyRepeatEvent`/`KeyUpEvent` return
   `KeyEventResult.ignored` while recording is active for the key that started it — practically,
   the handler exits recording on the first `KeyDownEvent`, so no repeat can arrive).

### 1.4.5 Key labels

`keyLabelFor(LogicalKeyboardKey)` (in `shortcut_bindings.dart`, so the dialog and any future
surface share one table):

| Key | Label |
|---|---|
| `arrowLeft` / `arrowRight` / `arrowUp` / `arrowDown` | `←` / `→` / `↑` / `↓` |
| `space` | `Space` |
| letters/digits | `keyLabel` upper-cased (`S`, `X`, `R`) |
| anything else | `keyLabel` upper-cased; if empty → `?` |

These four arrow glyphs are exactly what D1 shows (`D1.html:172,173,176,177`).

### 1.4.6 Dispatch refactor in `MainScreen`

`_buildKeyboardShortcutHandler` (`main_screen.dart:93-135`) loses its `if/else if` chain. The
`Focus`/`autofocus`/`onKeyEvent` shape and the `KeyDownEvent` guard (`:97-101`) are **kept** —
migrating to `Shortcuts`/`Actions` is a bigger refactor with no requirement behind it (YAGNI).
New body:

```dart
onKeyEvent: (node, event) {
  if (event is! KeyDownEvent) return KeyEventResult.ignored;
  final state = context.read<AppState>();
  final action = state.shortcutBindings.actionFor(event.logicalKey);
  if (action == null) return KeyEventResult.ignored;
  switch (action) {
    case ShortcutAction.previousPhoto: state.previousPhoto();
    case ShortcutAction.nextPhoto: state.nextPhoto();
    case ShortcutAction.starPhoto:
      if (state.selectedItemID != null) state.markCurrent(PhotoStatus.starred);
    case ShortcutAction.trashMarkPhoto:
      if (state.selectedItemID != null) state.markCurrent(PhotoStatus.trashed);
    case ShortcutAction.zoomIn: _zoom.stepZoomIn();
    case ShortcutAction.zoomOut: _zoom.stepZoomOut();
    case ShortcutAction.toggleRecycleMode: state.toggleRecycleMode();
  }
  return KeyEventResult.handled;
},
```

Behaviour preserved exactly: the `selectedItemID != null` guards still only wrap the two mark
actions and the event is still reported handled even when the guard skips the call
(`main_screen.dart:110-119`). An exhaustive `switch` over the enum means adding an action is a
compile error here, not a silent no-op.

## 1.5 D1 → Flutter translation

Root is `Dialog` (not `AlertDialog`), mirroring `rename_dialog.dart:125-127`. All colours come
from `HalcyonTokens.of(context)` (`theme_tokens.dart:88-89`); **no `Colors.*` literals and no
hex literals** are permitted in the new widgets — D1's CSS variables map 1:1 onto the dark
token set (`theme_tokens.dart:54-68`), which is how the mockup was authored.

### 1.5.1 CSS variable → token map

| D1 CSS var | Token | Check |
|---|---|---|
| `--pane #333333` | `t.pane` | `theme_tokens.dart:55` |
| `--dialog #383838` | `t.dialog` | `:56` |
| `--surface #414141` | `t.surface` | `:57` |
| `--input #262626` | `t.input` | `:58` |
| `--border #515151` | `t.border` | `:59` |
| `--border-soft #454545` | `t.borderSoft` | `:60` |
| `--text #e0e0e0` | `t.text` | `:61` |
| `--text-dim #9a9a9a` | `t.textDim` | `:62` |
| `--text-faint #6f6f6f` | `t.textFaint` | `:63` |
| `--accent #0a84ff` | `t.accent` | `:64` |
| `--danger #ff453a` | `t.danger` | `:66` |

Every D1 variable has an exact token counterpart; light mode follows for free
(`theme_tokens.dart:70-84`).

### 1.5.2 Structure → widget map

| D1 element | Flutter | Metrics (from D1) |
|---|---|---|
| `.dialog` (`:25-33`) | `Dialog` → `Container(width: 920, height: 560)` | `t.dialog` bg, `BorderRadius.circular(8)`, `Border.all(color: t.borderSoft)`, `clipBehavior: Clip.antiAlias` |
| `.header` (`:34`) | `Padding(EdgeInsets.fromLTRB(20,16,20,0))` | — |
| `.header h1` (`:36`) | `Text('Settings')` | 15px, `FontWeight.w600`, `t.text` |
| `.header p` (`:37`) | `Text('Tabbed sections with a live summary at a glance')` | 11.5px, `t.textDim`, 3px top gap |
| `.badge` (`:38`) | `Container` | padding `(h:10, v:3)`, `BorderRadius.circular(20)`, `Border.all(t.border)`, 10.5px `t.textDim`, text `'<Tier> tier'` |
| `.tabbar` (`:40`) | `Container` + `Row` | padding 3, `t.input`, radius 6, `mainAxisSize: MainAxisSize.min`, 4px gaps |
| `.tab` / `.tab.active` (`:41-42`) | `Material`+`InkWell` per tab | padding `(h:16, v:6)`, radius 4, 12px; active: `t.border` bg + `t.text`; idle: transparent + `t.textDim` |
| `.tabbar-wrap` (`:43`) | `Container(decoration: Border(bottom: BorderSide(color: t.borderSoft)))` + 14px bottom padding | — |
| `.body` (`:45`) | `Expanded(child: Row(...))` | — |
| `.tabcontent` (`:46`) | `Expanded(child: SingleChildScrollView(padding: EdgeInsets.symmetric(h:20, v:18)))` | — |
| `.summary-rail` (`:48)` | `Container(width: 224)` | `t.pane`, left `BorderSide(t.borderSoft)`, padding 16, own `SingleChildScrollView` |
| `.section-label` + `::after` (`:56-60`) | `Row[Text, SizedBox(8), Expanded(Container(height:1, color: t.borderSoft))]` | 10.5px, `w600`, `letterSpacing: 0.63` (= 0.06em × 10.5), `t.textFaint`, upper-cased, 8px bottom gap |
| `.grid` 2 cols, gap 16 (`:62`) | `Row[Expanded(a), SizedBox(16), Expanded(b)]`; `.full` = its own full-width `Row` | 18px bottom gap per `.section` (`:64`) |
| `.block` (`:65`) | `Container` | `t.pane`, `Border.all(t.borderSoft)`, radius 5, padding `(h:16, v:14)` |
| `.row-label` (`:68`) | `Text` | 12.5px `t.text`. **Copy is NOT taken from D1** — use §1.5.6. D1's first row label reads `Decode lane width` (`D1.html:123`); the shipped string is **`Concurrent RAW decodes`** |
| `.row-caption` (`:69`) | `Text` | 11px `t.textDim`, `fontFamily: 'monospace'`, 6px top gap |
| `input[type=range]` (`:71-72`) | `SliderTheme` + `Slider` | `trackHeight: 4`, active `t.accent`, inactive `t.border`, `RoundSliderThumbShape(enabledThumbRadius: 7)`, thumb `t.accent`, 10px top gap |
| `.tier` / `.tier.selected` (`:75-79`) | `Material`+`InkWell` card in a 3-column `Row` with 8px gaps | radius 5, `t.surface` bg, `Border.all(t.borderSoft)`; selected: `t.accent.withValues(alpha: 0.18)` bg + `t.accent` border. Name 12.5 `w600` `t.text`; budget 14 `w700` `t.accent` monospace; formula 10 `t.textFaint` |
| `.shortcuts-list` 2 cols (`:81`) | `Row[Expanded(Column of rows 0..3), SizedBox(20), Expanded(Column of rows 4..6)]` | row padding `v:8`, bottom `BorderSide(t.borderSoft)` except the last row of each column (`D1.html:83`) |
| `.key-chip` / `.conflict` (`:85-86`) | `Container` | monospace 11.5 `t.text`, `t.input` bg, `Border.all(t.border)`, radius 5, padding `(h:10, v:4)`, `minWidth: 40`, centred; conflict: `t.danger` text+border, `t.danger.withValues(alpha: 0.12)` bg |
| `.record-btn` (`:87`) | `Material`+`InkWell` | 11px `t.textDim`, transparent, `Border.all(t.borderSoft)`, radius 5, padding `(h:8, v:4)`, 8px left gap |
| `.conflict-note` (`:88`) | `Row[Icon(Icons.warning_amber_rounded, size:12, color: t.danger), SizedBox(4), Expanded(Text)]` | 10.5px `t.danger`, 8px top gap, full width |
| `.actions` (`:90-93`) | `Container(top BorderSide(t.borderSoft))` + `Row(MainAxisAlignment.end)` | padding `(h:20, v:12)`, 10px gap; secondary: `t.surface` bg, `Border.all(t.border)`, radius 5, padding `(h:16,v:7)`, 12.5px `t.text`; primary: `t.accent` bg, `Colors.white` text |

`Material`+`InkWell` for every clickable surface is the established idiom in this repo
(`rename_dialog/rule_editor.dart:97-167,228-248`).

### 1.5.3 Tab → content assignment

D1 renders one page containing all four sections; the tab bar names three tabs
(`D1.html:109-111`). Assignment:

| Tab | Sections (in order) |
|---|---|
| **Performance** | `Parallelism` (half width — concurrent-decodes slider + `N of M max` caption), `Export` (half width — quality slider + numeric caption), `Workflow` (full width — Auto-advance and Overwrite checkboxes side by side) |
| **Memory** | `Memory Retention` (full width — three tier cards + auto caption + "Use detected default") |
| **Shortcuts** | `Keyboard Shortcuts` (full width — 7 rows in 2 columns, conflict note, "Reset all shortcuts") |

The Workflow section is the one placement D1 does not dictate (it predates those two checkboxes
existing in the mockup). **Ruled by the user on 2026-08-30** (§3.2 D-1): Workflow section on the
Performance tab, no fourth tab. D1's three-tab bar is unchanged.

### 1.5.4 Summary rail contents (visible on all three tabs)

Heading `AT A GLANCE` (10.5px, uppercase, `letterSpacing: 0.63`, `t.textFaint`, `w600`), then
four items, each `label` 10.5px `t.textFaint` over `value` 13px monospace `t.text`, 14px apart
(`D1.html:186-190`):

| Label | Value | Danger state |
|---|---|---|
| `Concurrent decodes` | `<width> / <ceiling>` | never |
| `Export quality` | `<quality>` | never |
| `Retention tier` | `<Tier> · <N> MiB` | never |
| `Shortcut conflicts` | `None` when clean; `1 conflict (X)` / `2 conflicts (X, S)` | `t.danger` when non-zero |

### 1.5.5 Caption strings (exact, so tests can `find.text` them)

- Concurrent RAW decodes: `'$decodeLaneWidth of $maxDecodeLaneWidth max'` (D1: `3 of 5 max`),
  or, when `maxDecodeLaneWidth == 1`,
  `'This machine can only decode one RAW at a time'` and the slider is disabled (TC-355
  behaviour retained). The word "lane" appears in no user-visible string.
- Export quality: `'$exportJpegQuality'`.
- Retention: `'Auto-picked from detected RAM; override anytime.'` when the tier is auto, and
  `'Overriding the detected default (<Auto tier>).'` when overridden.
- Conflict note (one line per conflicting key):
  `'"X" is bound twice — Trash-mark photo and Toggle recycle mode conflict. The first listed action wins.'`
  For >2 actions on one key the names are comma-joined in canonical order with `and` before
  the last.

### 1.5.6 User-facing copy inventory (the only strings the user reads)

One table, so the jargon question is settled in one place instead of per-widget. Everything
here is a literal string in the widget tree; nothing here is an identifier.

| Where | String |
|---|---|
| Dialog title | `Settings` |
| Dialog subtitle | `Tabbed sections with a live summary at a glance` |
| Header badge | `<Tier> tier` (e.g. `Balanced tier`) |
| Tabs | `Performance` / `Memory` / `Shortcuts` |
| Section labels | `PARALLELISM` / `EXPORT` / `WORKFLOW` / `MEMORY RETENTION` / `KEYBOARD SHORTCUTS` |
| Row label (S1) | **`Concurrent RAW decodes`** |
| Row label (S2) | `Export JPEG quality` |
| Row labels (S5) | `Auto-advance on mark` / `Overwrite existing files on Copy/Move` |
| Tier names | `Conservative` / `Balanced` / `Generous` |
| Tier reset button | `Use detected default` |
| Shortcut action names | the seven `ShortcutAction.label` values (§1.4.1) |
| Shortcut buttons | `Record` / `Cancel` / `Reset` / `Reset all shortcuts` |
| Rail heading | `AT A GLANCE` |
| Rail labels | `Concurrent decodes` / `Export quality` / `Retention tier` / `Shortcut conflicts` |
| Footer buttons | `Cancel` / `Done` |

The word **"lane"** must not appear in any of these. D1's `.row-label` reads
`Decode lane width` (`D1.html:123`) and its rail reads `Decode lanes` (`D1.html:187`); both are
superseded by the 2026-08-30 user directive. This is the one deliberate deviation from
"D1 exactly" — it is copy, not layout, and every metric, colour and position is unchanged.

## 1.6 Dialog lifecycle: live-apply with a real Cancel

D1's footer has both `Cancel` and `Done` (`D1.html:194-195`), while every existing setting
writes through immediately (`app_state.dart:442-457`). Both are honoured by making Cancel a
real revert rather than a no-op button:

1. `SettingsDialog` becomes a `StatefulWidget`; in `initState` it captures
   `final _snapshot = state.settingsSnapshot();`.
2. All controls keep writing through live — so lane width, retention tier and shortcuts take
   effect while the dialog is open (a genuine preview).
3. `Done` → `Navigator.pop()`. Snapshot discarded.
4. `Cancel`, barrier tap, and Escape → `state.restoreSettings(_snapshot)` then
   `Navigator.pop()`. `barrierDismissible` stays default-true and the pop route's result is
   irrelevant: the restore happens in the dialog's `dispose()` unless `Done` set
   `_committed = true`. This single choke point guarantees every dismissal path reverts.

`SettingsSnapshot` is an immutable record of the six revertible values
(`autoAdvance`, `overwriteExisting`, `decodeLaneWidth`, `exportJpegQuality`,
`retentionTierOverride` (nullable), `shortcutBindings`). `restoreSettings` re-applies each via
the ordinary setter, so persistence and live push happen exactly once per field and no code
path can revert state without also reverting prefs.

## 1.7 Live retention re-application

**USER RULING 2026-08-30 (§3.2 D-2):** the tier applies **live**. The cheaper
"persist now, apply at next launch" variant is rejected; the mutable byte budget and the
eviction sweep below are in scope and must not be dropped as a simplification.

`ImagePreloadController.retention` is final (`image_preload_controller.dart:101,115`) and the
cache budget is fixed at construction (`:109`, `photo_payload_cache.dart:54,56`). Applying a
tier at runtime therefore needs two small mechanical changes:

- `PhotoPayloadCache.byteBudget` becomes a private mutable field with a getter plus
  `void setByteBudget(int bytes)`, which assigns and then runs the existing
  `_enforceBudget()` (`photo_payload_cache.dart:136-146`). Lowering the budget therefore
  evicts immediately instead of waiting for the next `put`. `_enforceBudget` already refuses to
  evict the just-written entry and stops at `_entries.length > 1` (`:140`), so a budget smaller
  than a single payload degrades to "keep exactly one", never to "spinner forever".
- `ImagePreloadController.retention` becomes a mutable field with
  `void setRetention(RetentionPolicy policy)` that assigns it and forwards
  `_cache.setByteBudget(policy.payloadByteBudget)`. The window `before`/`after` values are read
  fresh on every `preloadImages` pass (`image_preload_controller.dart:562-572,609-613,1242-1261`),
  so widening or narrowing takes effect on the next navigation with no extra plumbing.

`AppState.retentionPolicy` already delegates to the controller (`app_state.dart:126`), so the
UI and the pipeline still cannot disagree — the property that comment guards is preserved.

An **eviction sweep on shrink is mandatory**, not optional: without it, dropping from Generous
to Conservative would leave up to 384 MiB resident until the user navigated, which is precisely
the memory the setting exists to reclaim.

## 1.8 Shared display-quality constant

**USER RULING 2026-08-30 (§3.2 D-3):** land the constant **directly at 70**. No 80-first
staging and no follow-up flip — WP1's single commit introduces `kDisplayJpegQuality = 70` and
drops the sidebar tile from q80 to q70 in the same change.

Today two literals coincidentally differ: `kReencodeJpegQuality = 70`
(`payload_reencoder.dart:34`) and `jpegQuality = 80` (`sidebar_thumbnail_codec.dart:26`, used
at `:54`). The doc comment at `payload_reencoder.dart:31-33` explicitly says they are *not* the
same number. Frozen decision 4 changes that: they become one number, by construction.

Home for the constant: `lib/services/image_pipeline/jpeg_encoder.dart`. That file already
documents itself as "the ONE encoder in the pipeline: the sidebar thumbnail codec and the
Phase 13 payload re-encoder both call it, so their channel-order and isolate decisions cannot
drift apart" (`jpeg_encoder.dart:11-13`) — the quality decision now joins the decisions it
owns. Neither consumer imports the other, so no cycle.

```dart
/// The ONE quality every DISPLAY-ONLY JPEG in the pipeline is encoded at.
///
/// Display-only means: never written back to disk. Both consumers -- the
/// retained full-resolution payload (`payload_reencoder.dart`) and the 200px
/// sidebar tile (`sidebar_thumbnail_codec.dart`) -- feed pixels the user looks
/// at and nothing else; export re-reads the ORIGINAL file
/// (`photo_export_service.dart`) at its own, user-chosen quality.
///
/// USER RULING 2026-08-30: one constant, not two literals that happen to
/// match. The sidebar tile was 80 and is now 70; at a 200px resample the
/// difference is invisible, and the payload budget has to hold these bytes.
const int kDisplayJpegQuality = 70;
```

Wiring, chosen to keep every existing call site compiling:

- `payload_reencoder.dart:34` → `const int kReencodeJpegQuality = kDisplayJpegQuality;`
  (kept as a named alias because the Phase-13 doc comment above it is the historical record
  and existing references keep resolving), with the "NOT the same number as
  `sidebar_thumbnail_codec.dart`" paragraph (`:31-33`) replaced by a pointer to the shared
  constant — leaving it would be an actively false comment.
- `sidebar_thumbnail_codec.dart:26` → `int jpegQuality = kDisplayJpegQuality`.

The single-source-of-truth property is then mechanically checkable: `70` appears as a literal
exactly once under `lib/services/image_pipeline/` in a quality position.

## 1.9 New `AppState` surface (frozen interface — every package codes against this)

```dart
// getters
int get exportJpegQuality;
RetentionTier get retentionTier;          // effective tier (override ?? auto)
RetentionTier get autoRetentionTier;      // machine-derived tier
bool get isRetentionTierOverridden;
ShortcutBindings get shortcutBindings;

// setters (each: normalise -> assign -> persist -> live-push -> notifyListeners)
void setExportJpegQuality(int quality);
void setRetentionTier(RetentionTier tier);
void resetRetentionTierToAuto();
void setShortcutBinding(ShortcutAction action, LogicalKeyboardKey key);
void resetShortcutBinding(ShortcutAction action);
void resetAllShortcutBindings();

// dialog lifecycle
SettingsSnapshot settingsSnapshot();
void restoreSettings(SettingsSnapshot snapshot);
```

and, in `lib/services/image_pipeline/retention_policy.dart`:

```dart
enum RetentionTier { conservative, balanced, generous }
RetentionPolicy retentionPolicyForTier(RetentionTier tier);
RetentionTier tierForPolicy(RetentionPolicy policy);   // exact match; falls back to conservative
```

`tierForPolicy` exists so `AppState` can name the policy `main.dart:65` already handed it
without re-reading physical memory — one RAM probe per launch stays one RAM probe per launch.

---

# Part 2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use podium:team-spawn (recommended) or
> podium:team-fable to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax
> for tracking.

**Goal:** Replace Halcyon's bare `Options` dialog with the D1 tabbed settings panel — concurrent
RAW decodes, export JPEG quality, a named memory-retention tier, and seven remappable keyboard
shortcuts — all persisted through the existing `SharedPreferences` pattern, plus a non-UI
refactor that gives the two display-only JPEG encoders one shared quality constant.

**Architecture:** Five work packages with **disjoint file ownership**. Two are pure
infrastructure and depend on nothing (WP1 shared constant, WP2 retention plumbing); WP3 is the
`AppState` hub that owns every new pref; WP4 and WP5 are consumers (export service +
`MainScreen` dispatch, and the dialog UI). All cross-package interfaces are frozen in §1.9 and
in each task's **Interfaces** block, so packages can be written concurrently against
signatures that do not exist yet in the tree.

**Tech Stack:** Flutter 3.35.1 / Dart, `provider` (`ChangeNotifier`), `shared_preferences`,
`flutter_test` widget tests, `package:image` for JPEG encode.

## Global Constraints

- `flutter analyze` must report **0 issues** before any package is considered done — repo rule,
  `CLAUDE.md` "must be 0 issues before considering work done". Analyze covers `lib/`, `test/`,
  `tool/` and `bin/`, not just `lib/`.
- `flutter test` must actually run green; a compiling tree is not evidence. Run with `-j 1` and
  confirm `All tests passed!` plus the declared test count equals the executed count.
- No new dependency in `pubspec.yaml`. No new persistence mechanism — `SharedPreferences` only.
- No `Colors.*` or hex colour literals in new view code; every colour comes from
  `HalcyonTokens.of(context)` (`lib/views/theme_tokens.dart:88-89`).
- **User-facing copy is fixed by §1.5.6 and is not the implementer's to reword.** In particular
  the S1 control is labelled `Concurrent RAW decodes` (user directive, 2026-08-30), not D1's
  `Decode lane width`, and the word "lane" appears in **no** visible string. Internal
  identifiers keep the lane terminology unchanged — including `Key('decodeLaneWidthSlider')`,
  the `decodeLaneWidth` pref key and every `AppState` / `retention_policy.dart` symbol.
- Do not touch `kCoresPerDecode`, `kMaxDecodeLaneWidth`, `laneCeilingFor`, the
  `ImageRequestPurpose` pixel targets, or `tierTwoNavigationDebounce` (frozen decision 5).
- The three retention rung values (224/304/384 MiB, `-3/+5`, `-3/+8`, `-3/+11`) are referenced,
  never re-typed: `retentionPolicyForTier` must be the only place they appear after WP2.
- Shared tree: `git add` only your own files and `git commit -- <your paths>` with an explicit
  pathspec. Never `git stash` / `reset` / `checkout --` / `clean`.
- Every new test gets a `TC-NNN` id in its test name **and** a matching row in
  `docs/sop/unit_test.md`. Ids are pre-allocated per package below; do not take ids outside
  your range (highest existing id is TC-437).
- Architecture decisions land in `docs/sop/memory.md` as AD-043 / AD-044 and G-028 (next free
  ids; highest existing are AD-042 and G-027).

## Documentation file ownership (shared files, sequenced not parallel)

`docs/sop/unit_test.md` and `docs/sop/memory.md` are touched by several packages. To keep the
"no two packages touch the same file" rule intact, **no implementer edits them**: each package
reports its TC rows and AD/G text in its sign-off, and the lead applies them in one commit at
the end. This is the single deliberate exception and it is resolved by sequencing, not by
sharing.

## File structure

| File | Package | Fate |
|---|---|---|
| `lib/services/image_pipeline/jpeg_encoder.dart` | WP1 | modify — gains `kDisplayJpegQuality` |
| `lib/services/image_pipeline/payload_reencoder.dart` | WP1 | modify — `:31-34` alias + comment fix |
| `lib/services/image_pipeline/sidebar_thumbnail_codec.dart` | WP1 | modify — `:26` default param |
| `test/services/image_pipeline/shared_display_quality_test.dart` | WP1 | create |
| `lib/services/image_pipeline/retention_policy.dart` | WP2 | modify — `RetentionTier` + mappers |
| `lib/services/image_pipeline/photo_payload_cache.dart` | WP2 | modify — mutable budget + sweep |
| `lib/services/image_pipeline/image_preload_controller.dart` | WP2 | modify — mutable retention + `setRetention` |
| `test/services/image_pipeline/retention_tier_test.dart` | WP2 | create |
| `lib/models/shortcut_bindings.dart` | WP3 | create |
| `lib/providers/settings_snapshot.dart` | WP3 | create |
| `lib/providers/app_state.dart` | WP3 | modify — new prefs, getters, setters, snapshot |
| `test/models/shortcut_bindings_test.dart` | WP3 | create |
| `test/providers/app_state_settings_test.dart` | WP3 | create |
| `lib/services/library/photo_export_service.dart` | WP4 | modify — `jpegQuality` field + param |
| `lib/views/main_screen.dart` | WP4 | modify — table-driven dispatch |
| `test/services/library/photo_export_quality_test.dart` | WP4 | create |
| `test/views/main_screen_shortcuts_test.dart` | WP4 | create |
| `lib/views/settings_dialog.dart` | WP5 | rewrite in place (path and class name unchanged, so `lib/views/sidebar_view.dart:372` needs no edit) |
| `lib/views/settings_dialog/settings_section_label.dart` | WP5 | create |
| `lib/views/settings_dialog/settings_summary_rail.dart` | WP5 | create |
| `lib/views/settings_dialog/settings_primitives.dart` | WP5 | create (block, caption, chip, tab bar, buttons) |
| `lib/views/settings_dialog/performance_tab.dart` | WP5 | create |
| `lib/views/settings_dialog/memory_tab.dart` | WP5 | create |
| `lib/views/settings_dialog/shortcuts_tab.dart` | WP5 | create |
| `test/views/settings_dialog_test.dart` | WP5 | rewrite (TC-354/TC-355 preserved by intent, renumbered rows noted) |

`lib/views/settings_dialog.dart` stays a file *and* becomes a directory sibling — that is legal
in Dart and is exactly the `rename_dialog.dart` + `rename_dialog/` shape already in the repo.

## Dependency graph

```
WP1  (independent)  ──────────────────────────────────────────┐
WP2  (independent) ──► WP3 ──► WP4                            ├──► lead: docs + full-suite gate
                          └──► WP5                            ┘
```

- **WP1** blocks nothing and is blocked by nothing. Start immediately.
- **WP2** blocks nothing and is blocked by nothing, but WP3 cannot *analyze clean* until WP2's
  `RetentionTier` / `retentionPolicyForTier` / `setRetention` exist. WP2 therefore lands those
  three API surfaces in its **first commit** (Steps 1-5 below), then continues. Unblock signal
  for WP3: `grep -n "RetentionTier" lib/services/image_pipeline/retention_policy.dart` returns a
  hit on the committed tree.
- **WP3** blocks WP4 and WP5 the same way: its Step-5 commit lands the full `AppState` surface
  from §1.9. Unblock signal: `grep -n "setShortcutBinding" lib/providers/app_state.dart` hits.
- **WP4** and **WP5** run concurrently after WP3's first commit.

Practical staffing for a 3-5 member team: start WP1 + WP2 + WP3 together (WP3 writes its model
file and tests first, which need nothing from WP2), then WP4 + WP5 together. WP1's member is
free after roughly one commit and is the natural second body on WP5, which is the largest
package.

## Verification strategy

1. **Per package, red→green with evidence.** Every task writes the failing test first and the
   implementer must *see it fail* with the expected message before implementing. The failure
   output goes into the package's sign-off report — a test never observed red is not evidence
   (lessons-learned 2026-08-17c).
2. **Per package gate:** `flutter analyze` (0 issues) + `flutter test <own test files> -j 1`,
   with the exit code self-captured in the artifact (`RC=$?` on the line immediately after the
   command, never `${PIPESTATUS[0]}`, never the harness's reported code).
3. **Integration gate, run by the lead after all five packages land:** full `flutter test -j 1`
   with `All tests passed!` and declared-count == executed-count, plus `flutter analyze` on the
   merged tree. In-package green does not transfer to the combined tree
   (lessons-learned 2026-08-16).
4. **Anti-regression sweep unrelated to the ACs:** the pre-existing suites
   `test/providers/app_state_test.dart`, `test/services/image_pipeline/` and
   `test/views/sidebar_view_test.dart` must still pass unchanged. Any edit to an existing test
   other than `test/views/settings_dialog_test.dart` must be justified in the sign-off, not
   made silently.
5. **Negative-space check at review:** for each package the reviewer asks "what existing
   behaviour did this diff remove, and who depended on it?" — in particular the TC-354/TC-355
   lane-width behaviours and the `selectedItemID != null` guards.
6. **Artifact provenance:** work is uncommitted for most of the run, so evidence files bind by
   **content marker** (the full new test name, e.g. `TC-445`), not by commit hash — the rule
   `docs/sop/unit_test.md` already states.

---

### WP1 — Shared display-JPEG-quality constant

**Model recommendation:** `sonnet` (mechanical, but the comment surgery needs judgement).
**TC range:** TC-438 .. TC-440. **AD:** AD-044.

**Files:**
- Modify: `lib/services/image_pipeline/jpeg_encoder.dart` (add constant above `encodeJpegFromRgba`, currently `:17-22`)
- Modify: `lib/services/image_pipeline/payload_reencoder.dart:31-34`
- Modify: `lib/services/image_pipeline/sidebar_thumbnail_codec.dart:26`
- Create: `test/services/image_pipeline/shared_display_quality_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces: `const int kDisplayJpegQuality` in `jpeg_encoder.dart` (value 70).
  `kReencodeJpegQuality` keeps its name and type (`const int`) and keeps its value 70, but is
  now defined as `= kDisplayJpegQuality`. `sidebarCacheBytes`'s signature is unchanged except
  the default of `jpegQuality`, which becomes `kDisplayJpegQuality`.

**Behavior:**
One number governs both display-only JPEG encodes. The sidebar tile drops from q80 to q70,
which is invisible at a 200px resample and removes bytes the payload budget has to hold.
Export is unaffected — it re-reads the original file at its own user-chosen quality (WP4).
The `payload_reencoder.dart:31-33` paragraph that currently asserts the two numbers are "NOT
the same number ... only ever coincidentally equal" becomes false the moment this lands and
must be replaced, not left in place.

**Constraints:**
- The literal `70` must appear exactly **once** as a quality value under
  `lib/services/image_pipeline/` after this task — in `kDisplayJpegQuality`'s definition.
- `kReencodeJpegQuality` is **kept**, not deleted: it carries the Phase-13 historical comment
  (`payload_reencoder.dart:18-32`) and existing references must keep resolving.
- No behaviour change to `encodeJpegFromRgba` itself; its `quality` parameter stays required.

**Acceptance criteria:**
- [ ] `grep -n "kDisplayJpegQuality" lib/services/image_pipeline/jpeg_encoder.dart` prints the
      `const int kDisplayJpegQuality = 70;` line.
- [ ] `grep -c "jpegQuality = 80" lib/services/image_pipeline/sidebar_thumbnail_codec.dart`
      prints `0`.
- [ ] `grep -rn "= 70;" lib/services/image_pipeline/ | grep -i quality` returns exactly one
      line, in `jpeg_encoder.dart`.
- [ ] `grep -n "coincidentally equal" lib/services/image_pipeline/payload_reencoder.dart`
      returns nothing.
- [ ] Tests `TC-438`, `TC-439`, `TC-440` exist in
      `test/services/image_pipeline/shared_display_quality_test.dart` and pass.
- [ ] `flutter analyze` → 0 issues.

**Steps:**

- [ ] **Step 1: Write the failing test**

```dart
// test/services/image_pipeline/shared_display_quality_test.dart
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/jpeg_encoder.dart';
import 'package:halcyon_flutter/services/image_pipeline/payload_reencoder.dart';
import 'package:halcyon_flutter/services/image_pipeline/sidebar_thumbnail_codec.dart';

void main() {
  test('TC-438 the shared display quality constant is q70', () {
    expect(kDisplayJpegQuality, 70);
  });

  test('TC-439 the payload re-encoder quality IS the shared constant', () {
    expect(kReencodeJpegQuality, same(kDisplayJpegQuality));
    expect(kReencodeJpegQuality, kDisplayJpegQuality);
  });

  test('TC-440 the sidebar tile encodes at the shared quality, not q80', () async {
    // A payload above the re-encode threshold is re-encoded; below it passes
    // through untouched. Assert the DEFAULT parameter, which is the contract
    // the codec exposes, by comparing an explicit-q70 call with a default call.
    final big = Uint8List(600 * 1024); // undecodable -> both paths return input
    final viaDefault = await sidebarCacheBytes(big);
    final viaExplicit = await sidebarCacheBytes(big, jpegQuality: kDisplayJpegQuality);
    expect(viaDefault.length, viaExplicit.length);
    expect(defaultSidebarJpegQuality, kDisplayJpegQuality);
  });
}
```

Note: `defaultSidebarJpegQuality` is a one-line `@visibleForTesting` getter added in Step 3 —
a default parameter value is not otherwise reachable from a test, and asserting it directly is
the only mechanical way to prove the 80→70 change landed.

- [ ] **Step 2: Run it and confirm it fails**

Run: `flutter test test/services/image_pipeline/shared_display_quality_test.dart -j 1`
Expected: compile failure — `Undefined name 'kDisplayJpegQuality'` and
`Undefined name 'defaultSidebarJpegQuality'`. Record the output.

- [ ] **Step 3: Implement**

In `lib/services/image_pipeline/jpeg_encoder.dart`, above `encodeJpegFromRgba` (`:17`), add the
constant with the doc comment given verbatim in §1.8 of this document.

In `lib/services/image_pipeline/payload_reencoder.dart`, replace lines 31-34 (the
"NOT the same number as `sidebar_thumbnail_codec.dart`'s `jpegQuality: 80`" paragraph and the
constant) with:

```dart
/// The SAME number as `sidebar_thumbnail_codec.dart`'s tile quality, by
/// construction rather than by coincidence: both are display-only encodes and
/// both read [kDisplayJpegQuality] (`jpeg_encoder.dart`), the single source of
/// truth introduced on 2026-08-30. The historical note above records why the
/// value walked 90 -> 80 -> 70; the value itself now lives in one place.
const int kReencodeJpegQuality = kDisplayJpegQuality;
```

and add `import 'jpeg_encoder.dart';` to that file's imports.

In `lib/services/image_pipeline/sidebar_thumbnail_codec.dart`, change `:26` to
`int jpegQuality = kDisplayJpegQuality,`, update the doc comment's two `q80` references
(`:19-20`) to `q70`, and append:

```dart
/// The default [sidebarCacheBytes] uses, exposed so a test can assert the
/// shared-constant wiring: a default parameter value is not otherwise
/// reachable from outside the function.
@visibleForTesting
const int defaultSidebarJpegQuality = kDisplayJpegQuality;
```

(`jpeg_encoder.dart` is already imported at `:5`; add
`import 'package:flutter/foundation.dart';` for `@visibleForTesting`.)

- [ ] **Step 4: Run the tests and the analyzer**

```bash
flutter analyze; RC=$?; echo "ANALYZE_RC=$RC"
flutter test test/services/image_pipeline/ -j 1; RC=$?; echo "TEST_RC=$RC"
```
Expected: `ANALYZE_RC=0`, `No issues found!`, `TEST_RC=0`, `All tests passed!`, and the three
new TC ids present in the run.

- [ ] **Step 5: Commit**

```bash
git add lib/services/image_pipeline/jpeg_encoder.dart \
        lib/services/image_pipeline/payload_reencoder.dart \
        lib/services/image_pipeline/sidebar_thumbnail_codec.dart \
        test/services/image_pipeline/shared_display_quality_test.dart
git commit -- lib/services/image_pipeline/jpeg_encoder.dart \
              lib/services/image_pipeline/payload_reencoder.dart \
              lib/services/image_pipeline/sidebar_thumbnail_codec.dart \
              test/services/image_pipeline/shared_display_quality_test.dart \
  -m "refactor(image-pipeline): one display JPEG quality constant, sidebar tiles to q70 (TC-438..440)"
```

- [ ] **Step 6: Report** the AD-044 text (one paragraph: what the constant is, why
      `jpeg_encoder.dart` owns it, that the sidebar dropped 80→70) and the three TC rows to the
      lead. Do **not** edit `docs/sop/`.

---

### WP2 — Retention tiers + live re-application

**Model recommendation:** `opus` (touches the memory-safety envelope and the eviction path).
**TC range:** TC-441 .. TC-444. **G:** G-028.

**Files:**
- Modify: `lib/services/image_pipeline/retention_policy.dart` (append after `retentionPolicyFor`, `:63-82`)
- Modify: `lib/services/image_pipeline/photo_payload_cache.dart:54,56,140`
- Modify: `lib/services/image_pipeline/image_preload_controller.dart:101,109,115`
- Create: `test/services/image_pipeline/retention_tier_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces:
  ```dart
  // retention_policy.dart
  enum RetentionTier { conservative, balanced, generous }
  RetentionPolicy retentionPolicyForTier(RetentionTier tier);
  RetentionTier tierForPolicy(RetentionPolicy policy);
  extension RetentionTierLabel on RetentionTier {
    String get id;          // 'conservative' | 'balanced' | 'generous'
    String get label;       // 'Conservative' | 'Balanced' | 'Generous'
  }
  RetentionTier? retentionTierFromId(String id);   // null on unknown

  // photo_payload_cache.dart
  int get byteBudget;
  void setByteBudget(int bytes);

  // image_preload_controller.dart
  RetentionPolicy get retention;
  void setRetention(RetentionPolicy policy);
  ```

**Behavior:**
`retentionPolicyForTier` becomes the single place the three rung triplets are written; the
existing `retentionPolicyFor(physicalMemoryBytes:)` (`retention_policy.dart:63-82`) is rewritten
to pick a tier from RAM and delegate, so the RAM thresholds and the tier values cannot drift.
`tierForPolicy` compares by value (`RetentionPolicy` already implements `==`,
`retention_policy.dart:33-40`) and returns `conservative` for any policy that matches no rung —
that fallback is only reachable from a hand-constructed policy in a test.

`setByteBudget` assigns and then calls the existing `_enforceBudget()`
(`photo_payload_cache.dart:136-146`), so **shrinking evicts immediately**. Without the sweep,
stepping Generous→Conservative would hold up to 384 MiB until the next navigation, which is the
memory this setting exists to release. `_enforceBudget`'s existing guards are relied on and not
changed: it never evicts the just-written entry and stops while `_entries.length > 1` (`:140`),
so even an absurdly small budget degrades to "keep exactly one entry", never to a permanent
spinner.

`setRetention` assigns the policy and forwards the budget. `before`/`after` need no push: every
consumer reads `retention.before` / `retention.after` fresh on each pass
(`image_preload_controller.dart:562-572,609-613,1242-1261`), so a widened window is honoured on
the next navigation and a narrowed one on the next retention sweep.

Edge cases: `setByteBudget` with a value ≤ 0 is clamped to 1 byte (a zero budget would make the
`while` condition vacuously true forever if the guard were ever relaxed); `setRetention` with a
policy equal to the current one is a no-op fast path that still runs no eviction.

**Constraints:**
- The `224 * 1024 * 1024` / `304 * 1024 * 1024` / `384 * 1024 * 1024` and `3/5`, `3/8`, `3/11`
  values appear in `retentionPolicyForTier` only. `RetentionPolicy.floor()`
  (`retention_policy.dart:23-26`) stays as-is — it references the shipped constants and is what
  `conservative` returns.
- `kMidRungTriggerBytes` / `kHighRungTriggerBytes` (`:4,7`) and `laneCeilingFor` (`:118-127`)
  are **not** touched. The tier must not influence the lane ceiling.
- `byteBudget` stays publicly read-only (getter), mutated only through `setByteBudget`.
- `ImagePreloadController.retention` stops being `final` but stays publicly read-only.

**Acceptance criteria:**
- [ ] `TC-441` asserts `retentionPolicyForTier` returns `-3/+5 @224MiB`, `-3/+8 @304MiB`,
      `-3/+11 @384MiB` and that `retentionPolicyFor(physicalMemoryBytes: …)` agrees with
      `retentionPolicyForTier(tier)` at 8/16/64 GiB and at `null`.
- [ ] `TC-442` asserts `tierForPolicy` round-trips all three tiers and falls back to
      `conservative` for an unknown policy.
- [ ] `TC-443` asserts `PhotoPayloadCache.setByteBudget` **evicts on shrink**: fill past the new
      budget, shrink, assert `totalByteCost <= byteBudget` (or `length == 1`) without any
      further `put`.
- [ ] `TC-444` asserts `ImagePreloadController.setRetention` updates `retention` and pushes the
      budget into the cache.
- [ ] `grep -c "384 \* 1024 \* 1024" lib/services/image_pipeline/retention_policy.dart` prints
      `1`.
- [ ] `flutter analyze` → 0 issues; `flutter test test/services/image_pipeline/ -j 1` green.

**Steps:**

- [ ] **Step 1: Write the failing tests for the pure mapping (TC-441, TC-442)**

```dart
// test/services/image_pipeline/retention_tier_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/image_pipeline/retention_policy.dart';

const int _gib = 1024 * 1024 * 1024;

void main() {
  test('TC-441 each tier maps to its shipped rung, and RAM selection agrees', () {
    expect(retentionPolicyForTier(RetentionTier.conservative),
        const RetentionPolicy(before: 3, after: 5, payloadByteBudget: 224 * 1024 * 1024));
    expect(retentionPolicyForTier(RetentionTier.balanced),
        const RetentionPolicy(before: 3, after: 8, payloadByteBudget: 304 * 1024 * 1024));
    expect(retentionPolicyForTier(RetentionTier.generous),
        const RetentionPolicy(before: 3, after: 11, payloadByteBudget: 384 * 1024 * 1024));

    expect(retentionPolicyFor(physicalMemoryBytes: null),
        retentionPolicyForTier(RetentionTier.conservative));
    expect(retentionPolicyFor(physicalMemoryBytes: 8 * _gib),
        retentionPolicyForTier(RetentionTier.conservative));
    expect(retentionPolicyFor(physicalMemoryBytes: 16 * _gib),
        retentionPolicyForTier(RetentionTier.balanced));
    expect(retentionPolicyFor(physicalMemoryBytes: 64 * _gib),
        retentionPolicyForTier(RetentionTier.generous));
  });

  test('TC-442 tierForPolicy round-trips, and unknown policies fall back', () {
    for (final tier in RetentionTier.values) {
      expect(tierForPolicy(retentionPolicyForTier(tier)), tier);
    }
    expect(
      tierForPolicy(const RetentionPolicy(before: 1, after: 1, payloadByteBudget: 1)),
      RetentionTier.conservative,
    );
    expect(retentionTierFromId('balanced'), RetentionTier.balanced);
    expect(retentionTierFromId('nonsense'), isNull);
    expect(RetentionTier.generous.id, 'generous');
    expect(RetentionTier.generous.label, 'Generous');
  });
}
```

- [ ] **Step 2: Run and confirm red**

Run: `flutter test test/services/image_pipeline/retention_tier_test.dart -j 1`
Expected: compile failure — `Undefined name 'RetentionTier'`.

- [ ] **Step 3: Implement the mapping in `retention_policy.dart`**

```dart
/// The three shipped retention rungs, as user-selectable named tiers.
///
/// This enum, not [retentionPolicyFor], is where the rung values live: RAM
/// selection now picks a TIER and delegates, so the auto-selected policy and a
/// user override can never be two different tables.
enum RetentionTier { conservative, balanced, generous }

extension RetentionTierLabel on RetentionTier {
  String get id => switch (this) {
        RetentionTier.conservative => 'conservative',
        RetentionTier.balanced => 'balanced',
        RetentionTier.generous => 'generous',
      };

  String get label => switch (this) {
        RetentionTier.conservative => 'Conservative',
        RetentionTier.balanced => 'Balanced',
        RetentionTier.generous => 'Generous',
      };
}

RetentionTier? retentionTierFromId(String id) {
  for (final tier in RetentionTier.values) {
    if (tier.id == id) return tier;
  }
  return null;
}

/// The ONE table of rung values. Derivations for each budget are in the
/// [retentionPolicyFor] doc comment above; they are unchanged.
RetentionPolicy retentionPolicyForTier(RetentionTier tier) => switch (tier) {
      // Exactly the shipped floor, by reference so the two cannot drift.
      RetentionTier.conservative => const RetentionPolicy.floor(),
      // 12 slots -> 268.80 MiB required, 304 MiB budgeted.
      RetentionTier.balanced =>
        const RetentionPolicy(before: 3, after: 8, payloadByteBudget: 304 * 1024 * 1024),
      // 15 slots -> 336.00 MiB required, 384 MiB budgeted.
      RetentionTier.generous =>
        const RetentionPolicy(before: 3, after: 11, payloadByteBudget: 384 * 1024 * 1024),
    };

/// Names a policy. Exact value match; anything unrecognised is treated as the
/// most conservative option, which is the only safe direction to guess.
RetentionTier tierForPolicy(RetentionPolicy policy) {
  for (final tier in RetentionTier.values) {
    if (retentionPolicyForTier(tier) == policy) return tier;
  }
  return RetentionTier.conservative;
}

/// Which tier this machine gets before the user touches the setting.
RetentionTier retentionTierFor({int? physicalMemoryBytes}) {
  if (physicalMemoryBytes == null || physicalMemoryBytes < kMidRungTriggerBytes) {
    return RetentionTier.conservative;
  }
  if (physicalMemoryBytes < kHighRungTriggerBytes) return RetentionTier.balanced;
  return RetentionTier.generous;
}
```

and rewrite the body of `retentionPolicyFor` (`:63-82`) to
`=> retentionPolicyForTier(retentionTierFor(physicalMemoryBytes: physicalMemoryBytes));`,
keeping its whole doc comment (`:47-62`) intact — the derivations and the Phase-13 amendment
are the record of how these budgets were computed.

**Note:** `retentionTierFor` is an extra name not listed in §1.9; it is WP2-internal plus one
WP3 consumer (`AppState` uses it only if it ever needs to re-derive from RAM, which it does
not — it calls `tierForPolicy` on the policy `main.dart:65` already handed it). Export it
anyway; it costs nothing and keeps the RAM thresholds in one file.

- [ ] **Step 4: Run — TC-441/442 green, everything else still green**

```bash
flutter test test/services/image_pipeline/ -j 1; RC=$?; echo "TEST_RC=$RC"
flutter analyze; RC=$?; echo "ANALYZE_RC=$RC"
```
Expected: `TEST_RC=0`, `ANALYZE_RC=0`.

- [ ] **Step 5: Commit the API-only slice (this unblocks WP3)**

```bash
git add lib/services/image_pipeline/retention_policy.dart \
        test/services/image_pipeline/retention_tier_test.dart
git commit -- lib/services/image_pipeline/retention_policy.dart \
              test/services/image_pipeline/retention_tier_test.dart \
  -m "feat(image-pipeline): name the retention rungs as user-selectable tiers (TC-441,442)"
```

Then tell the lead: **WP3 unblocked** (`grep -n "RetentionTier"
lib/services/image_pipeline/retention_policy.dart` now hits on the committed tree).

- [ ] **Step 6: Write the failing tests for live re-application (TC-443, TC-444)**

Append to the same test file (add the imports for `photo_payload_cache.dart`,
`image_preload_controller.dart` and whatever `SourcePayload` fake the existing payload-cache
tests already use — reuse that helper rather than writing a second one):

```dart
  test('TC-443 shrinking the byte budget evicts immediately, without a put', () {
    final cache = PhotoPayloadCache(byteBudget: 300);
    cache.put('a', fakePayload(bytes: 100));
    cache.put('b', fakePayload(bytes: 100));
    cache.put('c', fakePayload(bytes: 100));
    cache.setEvictionPriority(['c', 'b', 'a']); // c nearest, a farthest
    expect(cache.length, 3);

    cache.setByteBudget(150);

    expect(cache.byteBudget, 150);
    expect(cache.totalByteCost, lessThanOrEqualTo(150));
    expect(cache.contains('c'), isTrue, reason: 'nearest survives');
  });

  test('TC-444 setRetention updates the window and the cache budget', () {
    final controller = ImagePreloadController(/* existing test construction */);
    expect(controller.retention, const RetentionPolicy.floor());

    controller.setRetention(retentionPolicyForTier(RetentionTier.generous));

    expect(controller.retention.after, 11);
    expect(controller.debugPayloadCacheByteBudget, 384 * 1024 * 1024);
  });
```

`debugPayloadCacheByteBudget` is a one-line `@visibleForTesting` getter on the controller
(`=> _cache.byteBudget`) added in Step 7, following the existing `debugRetentionIds` /
`debugTierTwoKeyIds` precedent (`image_preload_controller.dart:207,414`). Construct the
controller exactly the way the existing controller tests do; do not invent a new fake set.

- [ ] **Step 7: Run and confirm red, then implement**

Run: `flutter test test/services/image_pipeline/retention_tier_test.dart -j 1`
Expected: `The method 'setByteBudget' isn't defined` / `'setRetention' isn't defined`.

In `photo_payload_cache.dart`, replace `:54,56`:

```dart
  PhotoPayloadCache({int byteBudget = kPayloadByteBudget})
      : _byteBudget = byteBudget < 1 ? 1 : byteBudget;

  int _byteBudget;

  /// The hard cap on retained payload bytes. Read-only; see [setByteBudget].
  int get byteBudget => _byteBudget;

  /// Re-sizes the budget and sweeps IMMEDIATELY.
  ///
  /// The sweep is the point: a user stepping the retention tier down expects
  /// the memory back now, not at the next navigation. Shrinking without
  /// sweeping would hold up to the OLD budget indefinitely on a folder the
  /// user has stopped scrolling.
  void setByteBudget(int bytes) {
    _byteBudget = bytes < 1 ? 1 : bytes;
    if (_entries.isNotEmpty) _enforceBudget();
  }
```

`_enforceBudget` (`:136-146`) is unchanged: it already reads `byteBudget` and already refuses to
drop the newest entry. Guard the call with `_entries.isNotEmpty` because `_enforceBudget` reads
`_entries.keys.last` unconditionally (`:140`), which throws on an empty map — that path was
previously unreachable because only `put` called it.

In `image_preload_controller.dart`, change `:101` to a plain parameter and `:115` to a mutable
field:

```dart
  RetentionPolicy _retention;
  RetentionPolicy get retention => _retention;

  /// Re-tunes retention at runtime (the user's memory-tier setting).
  ///
  /// `before`/`after` need no push: every pass reads them fresh, so the new
  /// window applies on the next navigation. The byte budget does need a push,
  /// and shrinking it sweeps immediately.
  void setRetention(RetentionPolicy policy) {
    if (policy == _retention) return;
    _retention = policy;
    _cache.setByteBudget(policy.payloadByteBudget);
  }

  @visibleForTesting
  int get debugPayloadCacheByteBudget => _cache.byteBudget;
```

Then replace every internal `retention.` read with `_retention.` **or** leave them reading the
getter — either compiles; prefer the getter so the diff stays small. Verify with
`grep -c "retention\." lib/services/image_pipeline/image_preload_controller.dart` that the
count is unchanged from before the edit apart from the new lines.

- [ ] **Step 8: Run the full image-pipeline suite and the analyzer**

```bash
flutter analyze; RC=$?; echo "ANALYZE_RC=$RC"
flutter test test/services/image_pipeline/ -j 1; RC=$?; echo "TEST_RC=$RC"
```
Expected both 0, `All tests passed!`. The pre-existing retention/eviction tests must pass
**unchanged** — if any needed editing, stop and report rather than adjusting them.

- [ ] **Step 9: Commit**

```bash
git add lib/services/image_pipeline/photo_payload_cache.dart \
        lib/services/image_pipeline/image_preload_controller.dart \
        test/services/image_pipeline/retention_tier_test.dart
git commit -- lib/services/image_pipeline/photo_payload_cache.dart \
              lib/services/image_pipeline/image_preload_controller.dart \
              test/services/image_pipeline/retention_tier_test.dart \
  -m "feat(image-pipeline): re-tune retention at runtime, sweeping on shrink (TC-443,444)"
```

- [ ] **Step 10: Report** the G-028 text (budget is now mutable; shrinking MUST sweep or the
      memory is not released; `_enforceBudget` throws on an empty map, hence the guard) and the
      four TC rows to the lead.

---

### WP3 — Shortcut model + `AppState` settings hub

**Model recommendation:** `opus` (this package freezes the interface every other package codes
against, and it owns the app's single coordination point).
**TC range:** TC-445 .. TC-452. **AD:** AD-043.

**Files:**
- Create: `lib/models/shortcut_bindings.dart`
- Create: `lib/providers/settings_snapshot.dart`
- Modify: `lib/providers/app_state.dart` (`:70,84,119,138-142,154-172,442-457`)
- Create: `test/models/shortcut_bindings_test.dart`
- Create: `test/providers/app_state_settings_test.dart`

**Interfaces:**
- Consumes (from WP2, already committed): `RetentionTier`, `retentionPolicyForTier`,
  `tierForPolicy`, `retentionTierFromId`, `ImagePreloadController.setRetention`.
- Produces: the whole §1.9 surface, plus
  ```dart
  // lib/models/shortcut_bindings.dart
  enum ShortcutAction { previousPhoto, nextPhoto, starPhoto, trashMarkPhoto,
                        zoomIn, zoomOut, toggleRecycleMode }
  extension ShortcutActionMeta on ShortcutAction {
    String get id;                       // 'previousPhoto' ...
    String get label;                    // 'Previous photo' ...
    LogicalKeyboardKey get defaultKey;
    String get prefsKey;                 // 'shortcut.<id>'
  }
  ShortcutAction? shortcutActionFromId(String id);

  const Set<LogicalKeyboardKey> kReservedShortcutKeys;
  String keyLabelFor(LogicalKeyboardKey key);

  class ShortcutBindings {
    const ShortcutBindings(Map<ShortcutAction, LogicalKeyboardKey> map);
    factory ShortcutBindings.defaults();
    LogicalKeyboardKey keyFor(ShortcutAction action);
    ShortcutBindings withBinding(ShortcutAction action, LogicalKeyboardKey key);
    ShortcutBindings withDefault(ShortcutAction action);
    Map<LogicalKeyboardKey, List<ShortcutAction>> get conflicts;
    ShortcutAction? actionFor(LogicalKeyboardKey key);
    bool isDefault(ShortcutAction action);
    bool operator ==(Object other);      // value equality, for snapshot restore
  }

  // lib/providers/settings_snapshot.dart
  class SettingsSnapshot {
    const SettingsSnapshot({required bool autoAdvance, required bool overwriteExisting,
      required int decodeLaneWidth, required int exportJpegQuality,
      required RetentionTier? retentionTierOverride, required ShortcutBindings shortcuts});
    // all six as final fields with the same names
  }
  ```

**Behavior:**
Exactly §1.3, §1.4.1-1.4.2, §1.6 and §1.9. Specifically:

- `_initPrefs` (`app_state.dart:154-172`) gains three reads, each independently guarded by
  `try/catch` in the same style as the existing lane-width read (`:163-168`): a corrupt
  `exportJpegQuality` must not take down `retentionTier`, and one corrupt shortcut entry must
  not reset the other six.
- `_autoRetentionTier` is computed **once**, in the constructor, as
  `tierForPolicy(retention)` where `retention` is the constructor parameter `main.dart:65`
  already supplies. No second RAM probe.
- `setRetentionTier(tier)` persists `tier.id`, stores it as the override, calls
  `_preloadController.setRetention(retentionPolicyForTier(tier))`, then `notifyListeners()`.
- `resetRetentionTierToAuto()` calls `_prefs?.remove('retentionTier')`, clears the override and
  re-applies `retentionPolicyForTier(_autoRetentionTier)`.
- `setExportJpegQuality(q)` normalises (`((q / 5).round() * 5).clamp(70, 100)`), persists,
  assigns `_exportService.jpegQuality` (WP4's field), notifies.
- `setShortcutBinding` persists `key.keyId` under `action.prefsKey`. Conflicting keys are
  **accepted** (§1.4.3). `resetShortcutBinding` removes the pref and restores the default;
  `resetAllShortcutBindings` does all seven.
- `settingsSnapshot()` / `restoreSettings()`: restore re-applies each field through the ordinary
  setter so persistence and live push happen exactly once per field; fields that did not change
  are skipped (each setter is cheap, but `setRetention` short-circuits on equality anyway).
  `restoreSettings` calls `notifyListeners()` once at the end.

Every setter calls `notifyListeners()` explicitly — note that the existing `setDecodeLaneWidth`
(`app_state.dart:454-457`) does, so this matches, and the exploration note's uncertainty about
it (`settings-exploration.md:39`) is resolved: it does.

**Constraints:**
- No behaviour change to `autoAdvance` / `overwriteExisting` / `decodeLaneWidth` semantics,
  keys or defaults.
- `AppState` must still construct with zero arguments in tests
  (`AppState(laneCeiling: 5)` is used at `test/views/settings_dialog_test.dart:23`), so every
  new constructor parameter needs a default.
- `shortcut_bindings.dart` may import `package:flutter/services.dart` (for
  `LogicalKeyboardKey`) but **must not** import anything from `views/` or `providers/`.
- `ShortcutBindings` is immutable; `withBinding` returns a new instance.

**Acceptance criteria:**
- [ ] `TC-445` seven actions, in the declared order, with today's seven default keys.
- [ ] `TC-446` `conflicts` is empty for defaults, and reports `{keyX: [trashMarkPhoto,
      toggleRecycleMode]}` in canonical order after rebinding recycle-mode to `X`.
- [ ] `TC-447` `actionFor` returns the earliest action in declaration order for a duplicated key.
- [ ] `TC-448` `keyLabelFor` returns `←/→/↑/↓` for the four arrows and `S`/`X`/`R` for letters.
- [ ] `TC-449` `AppState` hydrates all four new settings from `SharedPreferences.setMockInitialValues`
      and falls back per-field on corrupt values.
- [ ] `TC-450` `setExportJpegQuality` normalises 73→75, 200→100, 12→70 and persists.
- [ ] `TC-451` `setRetentionTier` pushes the policy into the controller
      (`state.retentionPolicy.after == 11` for Generous) and `resetRetentionTierToAuto`
      restores the constructor-supplied tier.
- [ ] `TC-452` `settingsSnapshot` + mutate-everything + `restoreSettings` returns all six fields
      **and** the persisted prefs to their pre-mutation values.
- [ ] `flutter analyze` → 0 issues; `flutter test test/models/ test/providers/ -j 1` green,
      including the pre-existing `app_state_test.dart` unchanged.

**Steps:**

- [ ] **Step 1: Write the failing model tests (TC-445..448)**

```dart
// test/models/shortcut_bindings_test.dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/shortcut_bindings.dart';

void main() {
  test('TC-445 the seven actions carry today\'s seven default keys, in order', () {
    expect(ShortcutAction.values.map((a) => a.defaultKey).toList(), [
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.keyS,
      LogicalKeyboardKey.keyX,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.keyR,
    ]);
    expect(ShortcutAction.trashMarkPhoto.prefsKey, 'shortcut.trashMarkPhoto');
    expect(shortcutActionFromId('zoomIn'), ShortcutAction.zoomIn);
    expect(shortcutActionFromId('nope'), isNull);
  });

  test('TC-446 defaults have no conflicts; a duplicate key is reported once', () {
    final defaults = ShortcutBindings.defaults();
    expect(defaults.conflicts, isEmpty);

    final clashing = defaults.withBinding(
        ShortcutAction.toggleRecycleMode, LogicalKeyboardKey.keyX);
    expect(clashing.conflicts.keys.single, LogicalKeyboardKey.keyX);
    expect(clashing.conflicts[LogicalKeyboardKey.keyX],
        [ShortcutAction.trashMarkPhoto, ShortcutAction.toggleRecycleMode]);
  });

  test('TC-447 a duplicated key dispatches to the earliest action declared', () {
    final clashing = ShortcutBindings.defaults()
        .withBinding(ShortcutAction.toggleRecycleMode, LogicalKeyboardKey.keyX);
    expect(clashing.actionFor(LogicalKeyboardKey.keyX), ShortcutAction.trashMarkPhoto);
    expect(clashing.actionFor(LogicalKeyboardKey.keyQ), isNull);
    expect(clashing.isDefault(ShortcutAction.toggleRecycleMode), isFalse);
    expect(clashing.withDefault(ShortcutAction.toggleRecycleMode), ShortcutBindings.defaults());
  });

  test('TC-448 key labels use arrow glyphs and upper-case letters', () {
    expect(keyLabelFor(LogicalKeyboardKey.arrowLeft), '←');
    expect(keyLabelFor(LogicalKeyboardKey.arrowRight), '→');
    expect(keyLabelFor(LogicalKeyboardKey.arrowUp), '↑');
    expect(keyLabelFor(LogicalKeyboardKey.arrowDown), '↓');
    expect(keyLabelFor(LogicalKeyboardKey.keyS), 'S');
    expect(keyLabelFor(LogicalKeyboardKey.space), 'Space');
    expect(kReservedShortcutKeys, contains(LogicalKeyboardKey.escape));
    expect(kReservedShortcutKeys, contains(LogicalKeyboardKey.tab));
    expect(kReservedShortcutKeys, isNot(contains(LogicalKeyboardKey.keyS)));
  });
}
```

- [ ] **Step 2: Run and confirm red**

Run: `flutter test test/models/shortcut_bindings_test.dart -j 1`
Expected: `Error: Not found: 'package:halcyon_flutter/models/shortcut_bindings.dart'`.

- [ ] **Step 3: Implement `lib/models/shortcut_bindings.dart`**

```dart
import 'package:flutter/services.dart';

/// Every remappable action, in the order that is the app's canonical order.
///
/// DECLARATION ORDER IS LOAD-BEARING, twice over: it is the order the settings
/// panel lists rows in, and it is the tie-break when two actions share a key.
/// Conflicting bindings are ALLOWED (the panel warns, it does not block), so a
/// deterministic winner is a requirement, not a nicety.
enum ShortcutAction {
  previousPhoto,
  nextPhoto,
  starPhoto,
  trashMarkPhoto,
  zoomIn,
  zoomOut,
  toggleRecycleMode,
}

extension ShortcutActionMeta on ShortcutAction {
  String get id => name; // enum name IS the persisted id

  String get label => switch (this) {
        ShortcutAction.previousPhoto => 'Previous photo',
        ShortcutAction.nextPhoto => 'Next photo',
        ShortcutAction.starPhoto => 'Star photo',
        ShortcutAction.trashMarkPhoto => 'Trash-mark photo',
        ShortcutAction.zoomIn => 'Zoom in',
        ShortcutAction.zoomOut => 'Zoom out',
        ShortcutAction.toggleRecycleMode => 'Toggle recycle mode',
      };

  /// Exactly the chain this replaced (main_screen.dart:104-128).
  LogicalKeyboardKey get defaultKey => switch (this) {
        ShortcutAction.previousPhoto => LogicalKeyboardKey.arrowLeft,
        ShortcutAction.nextPhoto => LogicalKeyboardKey.arrowRight,
        ShortcutAction.starPhoto => LogicalKeyboardKey.keyS,
        ShortcutAction.trashMarkPhoto => LogicalKeyboardKey.keyX,
        ShortcutAction.zoomIn => LogicalKeyboardKey.arrowUp,
        ShortcutAction.zoomOut => LogicalKeyboardKey.arrowDown,
        ShortcutAction.toggleRecycleMode => LogicalKeyboardKey.keyR,
      };

  String get prefsKey => 'shortcut.$id';
}

ShortcutAction? shortcutActionFromId(String id) {
  for (final action in ShortcutAction.values) {
    if (action.id == id) return action;
  }
  return null;
}

/// Keys recording refuses, because the dialog itself needs them.
///
/// Escape cancels recording, Tab traverses, Enter activates the focused
/// button, and a bare modifier can never be a single-key trigger.
const Set<LogicalKeyboardKey> kReservedShortcutKeys = {
  LogicalKeyboardKey.escape,
  LogicalKeyboardKey.tab,
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.numpadEnter,
  LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftRight,
  LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlRight,
  LogicalKeyboardKey.altLeft, LogicalKeyboardKey.altRight,
  LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaRight,
};

/// The one key-label table, so the chip in the panel and any future surface
/// cannot render the same binding two ways.
String keyLabelFor(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.arrowLeft) return '←';
  if (key == LogicalKeyboardKey.arrowRight) return '→';
  if (key == LogicalKeyboardKey.arrowUp) return '↑';
  if (key == LogicalKeyboardKey.arrowDown) return '↓';
  if (key == LogicalKeyboardKey.space) return 'Space';
  final label = key.keyLabel.toUpperCase();
  return label.isEmpty ? '?' : label;
}

/// An immutable action -> key map. Duplicates are legal; see [conflicts].
class ShortcutBindings {
  const ShortcutBindings(this._map);

  factory ShortcutBindings.defaults() => ShortcutBindings({
        for (final action in ShortcutAction.values) action: action.defaultKey,
      });

  final Map<ShortcutAction, LogicalKeyboardKey> _map;

  LogicalKeyboardKey keyFor(ShortcutAction action) =>
      _map[action] ?? action.defaultKey;

  ShortcutBindings withBinding(ShortcutAction action, LogicalKeyboardKey key) =>
      ShortcutBindings({..._map, action: key});

  ShortcutBindings withDefault(ShortcutAction action) =>
      withBinding(action, action.defaultKey);

  bool isDefault(ShortcutAction action) => keyFor(action) == action.defaultKey;

  bool get hasAnyNonDefault =>
      ShortcutAction.values.any((a) => !isDefault(a));

  /// Keys bound by TWO OR MORE actions, each list in declaration order.
  /// Empty when clean -- the panel renders its warning off this map.
  Map<LogicalKeyboardKey, List<ShortcutAction>> get conflicts {
    final byKey = <LogicalKeyboardKey, List<ShortcutAction>>{};
    for (final action in ShortcutAction.values) {
      byKey.putIfAbsent(keyFor(action), () => []).add(action);
    }
    byKey.removeWhere((_, actions) => actions.length < 2);
    return byKey;
  }

  /// The action a key press fires: the EARLIEST declared action bound to it.
  ShortcutAction? actionFor(LogicalKeyboardKey key) {
    for (final action in ShortcutAction.values) {
      if (keyFor(action) == key) return action;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is ShortcutBindings &&
      ShortcutAction.values.every((a) => keyFor(a) == other.keyFor(a));

  @override
  int get hashCode =>
      Object.hashAll(ShortcutAction.values.map(keyFor));
}
```

- [ ] **Step 4: Run — TC-445..448 green**

Run: `flutter test test/models/shortcut_bindings_test.dart -j 1`
Expected: `All tests passed!`, 4 tests.

- [ ] **Step 5: Implement the `AppState` surface and commit (this unblocks WP4 and WP5)**

Create `lib/providers/settings_snapshot.dart`:

```dart
import '../models/shortcut_bindings.dart';
import '../services/image_pipeline/retention_policy.dart';

/// Everything the settings panel can change, captured when it opens.
///
/// The panel applies live (so lane width and retention are a real preview),
/// which only works if Cancel can put every field back -- including the
/// persisted prefs, since every setter writes through.
class SettingsSnapshot {
  const SettingsSnapshot({
    required this.autoAdvance,
    required this.overwriteExisting,
    required this.decodeLaneWidth,
    required this.exportJpegQuality,
    required this.retentionTierOverride,
    required this.shortcuts,
  });

  final bool autoAdvance;
  final bool overwriteExisting;
  final int decodeLaneWidth;
  final int exportJpegQuality;

  /// Null means "no override, follow the machine-derived tier".
  final RetentionTier? retentionTierOverride;
  final ShortcutBindings shortcuts;
}
```

In `lib/providers/app_state.dart`:

1. Fields, next to the existing settings block (`:137-142`):

```dart
  int _exportJpegQuality = kDefaultExportJpegQuality;
  RetentionTier? _retentionTierOverride;
  late final RetentionTier _autoRetentionTier;
  ShortcutBindings _shortcuts = ShortcutBindings.defaults();
```

with `const int kDefaultExportJpegQuality = 90;` declared in
`lib/services/library/photo_export_service.dart` by WP4 and imported here.

2. In the constructor body (after the initializer list, alongside `:77-100`):
   `_autoRetentionTier = tierForPolicy(retention);`

3. In `_initPrefs` (`:154`), after the existing three reads:

```dart
    _exportJpegQuality = _normaliseExportQuality(_readIntPref('exportJpegQuality'));
    _exportService.jpegQuality = _exportJpegQuality;

    final tierId = _readStringPref('retentionTier');
    _retentionTierOverride = tierId == null ? null : retentionTierFromId(tierId);
    _preloadController.setRetention(retentionPolicyForTier(retentionTier));

    var bindings = ShortcutBindings.defaults();
    for (final action in ShortcutAction.values) {
      final keyId = _readIntPref(action.prefsKey);
      if (keyId != null) {
        // An unknown keyId yields a synthetic key that matches nothing; that
        // is strictly better than dropping the other six bindings.
        bindings = bindings.withBinding(action, LogicalKeyboardKey(keyId));
      }
    }
    _shortcuts = bindings;
```

with two small private helpers that wrap the existing `try/catch` idiom (`:163-168`) once each
instead of six times:

```dart
  int? _readIntPref(String key) {
    try {
      return _prefs?.getInt(key);
    } catch (_) {
      return null; // wrong stored type; fall back to the default
    }
  }

  String? _readStringPref(String key) {
    try {
      return _prefs?.getString(key);
    } catch (_) {
      return null;
    }
  }

  int _normaliseExportQuality(int? raw) =>
      raw == null ? kDefaultExportJpegQuality : ((raw / 5).round() * 5).clamp(70, 100);
```

Refactor the existing lane-width read (`:161-172`) to use `_readIntPref` so there is one
guarded-read idiom, not two. The clamp and the fallback stay exactly as they are.

4. Getters and setters, next to the existing ones (`:180-190`, `:442-457`):

```dart
  int get exportJpegQuality => _exportJpegQuality;
  RetentionTier get autoRetentionTier => _autoRetentionTier;
  RetentionTier get retentionTier => _retentionTierOverride ?? _autoRetentionTier;
  bool get isRetentionTierOverridden => _retentionTierOverride != null;
  ShortcutBindings get shortcutBindings => _shortcuts;

  void setExportJpegQuality(int quality) {
    _exportJpegQuality = _normaliseExportQuality(quality);
    _prefs?.setInt('exportJpegQuality', _exportJpegQuality);
    _exportService.jpegQuality = _exportJpegQuality;
    notifyListeners();
  }

  void setRetentionTier(RetentionTier tier) {
    _retentionTierOverride = tier;
    _prefs?.setString('retentionTier', tier.id);
    _preloadController.setRetention(retentionPolicyForTier(tier));
    notifyListeners();
  }

  void resetRetentionTierToAuto() {
    _retentionTierOverride = null;
    _prefs?.remove('retentionTier');
    _preloadController.setRetention(retentionPolicyForTier(_autoRetentionTier));
    notifyListeners();
  }

  void setShortcutBinding(ShortcutAction action, LogicalKeyboardKey key) {
    // Conflicts are ACCEPTED here by design: the panel warns and dispatch has
    // a deterministic winner (ShortcutBindings.actionFor). Blocking would make
    // the mockup's warning state unreachable.
    _shortcuts = _shortcuts.withBinding(action, key);
    _prefs?.setInt(action.prefsKey, key.keyId);
    notifyListeners();
  }

  void resetShortcutBinding(ShortcutAction action) {
    _shortcuts = _shortcuts.withDefault(action);
    _prefs?.remove(action.prefsKey);
    notifyListeners();
  }

  void resetAllShortcutBindings() {
    _shortcuts = ShortcutBindings.defaults();
    for (final action in ShortcutAction.values) {
      _prefs?.remove(action.prefsKey);
    }
    notifyListeners();
  }

  SettingsSnapshot settingsSnapshot() => SettingsSnapshot(
        autoAdvance: _autoAdvance,
        overwriteExisting: _overwriteExisting,
        decodeLaneWidth: _decodeLaneWidth,
        exportJpegQuality: _exportJpegQuality,
        retentionTierOverride: _retentionTierOverride,
        shortcuts: _shortcuts,
      );

  /// Puts every panel-changeable field back, prefs included.
  ///
  /// Each field goes back through its ordinary setter, so no path can revert
  /// in-memory state while leaving the persisted value changed.
  void restoreSettings(SettingsSnapshot snapshot) {
    if (snapshot.autoAdvance != _autoAdvance) setAutoAdvance(snapshot.autoAdvance);
    if (snapshot.overwriteExisting != _overwriteExisting) {
      setOverwriteExisting(snapshot.overwriteExisting);
    }
    if (snapshot.decodeLaneWidth != _decodeLaneWidth) {
      setDecodeLaneWidth(snapshot.decodeLaneWidth);
    }
    if (snapshot.exportJpegQuality != _exportJpegQuality) {
      setExportJpegQuality(snapshot.exportJpegQuality);
    }
    if (snapshot.retentionTierOverride != _retentionTierOverride) {
      final tier = snapshot.retentionTierOverride;
      if (tier == null) {
        resetRetentionTierToAuto();
      } else {
        setRetentionTier(tier);
      }
    }
    if (snapshot.shortcuts != _shortcuts) {
      for (final action in ShortcutAction.values) {
        final key = snapshot.shortcuts.keyFor(action);
        if (_shortcuts.keyFor(action) == key) continue;
        if (key == action.defaultKey) {
          resetShortcutBinding(action);
        } else {
          setShortcutBinding(action, key);
        }
      }
    }
    notifyListeners();
  }
```

Then run `flutter analyze` (expect 0 issues — `_exportService.jpegQuality` will fail until WP4
lands; if so, add the field to `PhotoExportService` **only if WP4 has not started**, otherwise
coordinate with WP4's owner rather than both editing the file) and commit:

```bash
git add lib/models/shortcut_bindings.dart lib/providers/settings_snapshot.dart \
        lib/providers/app_state.dart test/models/shortcut_bindings_test.dart
git commit -- lib/models/shortcut_bindings.dart lib/providers/settings_snapshot.dart \
              lib/providers/app_state.dart test/models/shortcut_bindings_test.dart \
  -m "feat(settings): app-wide export quality, retention tier and shortcut bindings (TC-445..448)"
```

Then tell the lead: **WP4 and WP5 unblocked**.

**Ordering note:** `kDefaultExportJpegQuality` and `PhotoExportService.jpegQuality` are WP4's
to write. Until WP4's first commit, WP3 declares the constant locally in `app_state.dart` as a
temporary and deletes it in Step 8 — or, preferably, the lead starts WP4 with the instruction
to land the export-service field first (it is a 4-line change). Prefer the latter; a temporary
duplicate constant is exactly the thing this plan is trying to remove elsewhere.

- [ ] **Step 6: Write the failing `AppState` tests (TC-449..452)**

```dart
// test/providers/app_state_settings_test.dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:halcyon_flutter/models/shortcut_bindings.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/retention_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppState> hydrated({
    Map<String, Object> prefs = const {},
    RetentionPolicy retention = const RetentionPolicy.floor(),
    int laneCeiling = 5,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    final state = AppState(retention: retention, laneCeiling: laneCeiling);
    addTearDown(state.dispose);
    // _initPrefs is async and fired from the constructor; let it settle.
    await Future<void>.delayed(Duration.zero);
    return state;
  }

  test('TC-449 hydrates every new setting, and falls back PER FIELD on garbage', () async {
    final good = await hydrated(prefs: {
      'exportJpegQuality': 75,
      'retentionTier': 'generous',
      'shortcut.starPhoto': LogicalKeyboardKey.keyF.keyId,
    });
    expect(good.exportJpegQuality, 75);
    expect(good.retentionTier, RetentionTier.generous);
    expect(good.shortcutBindings.keyFor(ShortcutAction.starPhoto), LogicalKeyboardKey.keyF);
    expect(good.shortcutBindings.keyFor(ShortcutAction.nextPhoto),
        LogicalKeyboardKey.arrowRight, reason: 'untouched actions keep defaults');

    final bad = await hydrated(prefs: {
      'exportJpegQuality': 'not an int',
      'retentionTier': 'nonsense',
      'shortcut.starPhoto': 'not an int',
    });
    expect(bad.exportJpegQuality, 90);
    expect(bad.retentionTier, RetentionTier.conservative, reason: 'unknown id = auto');
    expect(bad.isRetentionTierOverridden, isFalse);
    expect(bad.shortcutBindings.keyFor(ShortcutAction.starPhoto), LogicalKeyboardKey.keyS);
  });

  test('TC-450 export quality is normalised to a 5-step in 70..100 and persisted', () async {
    final state = await hydrated();
    state.setExportJpegQuality(73);
    expect(state.exportJpegQuality, 75);
    state.setExportJpegQuality(200);
    expect(state.exportJpegQuality, 100);
    state.setExportJpegQuality(12);
    expect(state.exportJpegQuality, 70);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('exportJpegQuality'), 70);
  });

  test('TC-451 the tier reaches the pipeline, and reset returns to the auto tier', () async {
    final state = await hydrated(
      retention: retentionPolicyForTier(RetentionTier.balanced),
    );
    expect(state.retentionTier, RetentionTier.balanced);
    expect(state.isRetentionTierOverridden, isFalse);

    state.setRetentionTier(RetentionTier.generous);
    expect(state.retentionPolicy.after, 11);
    expect(state.retentionPolicy.payloadByteBudget, 384 * 1024 * 1024);
    expect(state.isRetentionTierOverridden, isTrue);

    state.resetRetentionTierToAuto();
    expect(state.retentionTier, RetentionTier.balanced);
    expect(state.retentionPolicy.after, 8);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('retentionTier'), isNull);
  });

  test('TC-452 restoreSettings reverts state AND prefs for every field', () async {
    final state = await hydrated();
    final before = state.settingsSnapshot();

    state.setAutoAdvance(true);
    state.setOverwriteExisting(false);
    state.setDecodeLaneWidth(5);
    state.setExportJpegQuality(70);
    state.setRetentionTier(RetentionTier.generous);
    state.setShortcutBinding(ShortcutAction.starPhoto, LogicalKeyboardKey.keyF);

    state.restoreSettings(before);

    expect(state.autoAdvance, before.autoAdvance);
    expect(state.overwriteExisting, before.overwriteExisting);
    expect(state.decodeLaneWidth, before.decodeLaneWidth);
    expect(state.exportJpegQuality, before.exportJpegQuality);
    expect(state.isRetentionTierOverridden, isFalse);
    expect(state.shortcutBindings, ShortcutBindings.defaults());

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('retentionTier'), isNull);
    expect(prefs.getInt('shortcut.starPhoto'), isNull);
    expect(prefs.getInt('exportJpegQuality'), before.exportJpegQuality);
  });
}
```

- [ ] **Step 7: Run and confirm red, then green**

```bash
flutter test test/providers/app_state_settings_test.dart -j 1; RC=$?; echo "TEST_RC=$RC"
```
Red first (missing getters), then after Step 5's code is in place, expect `TEST_RC=0` and 4
tests. Also run the untouched `test/providers/app_state_test.dart` — it must stay green
without edits.

- [ ] **Step 8: Analyzer + commit**

```bash
flutter analyze; RC=$?; echo "ANALYZE_RC=$RC"
git add test/providers/app_state_settings_test.dart lib/providers/app_state.dart
git commit -- test/providers/app_state_settings_test.dart lib/providers/app_state.dart \
  -m "test(settings): hydration, normalisation, tier push and snapshot restore (TC-449..452)"
```

- [ ] **Step 9: Report** AD-043 (live-apply + snapshot-revert Cancel; conflicts warn rather than
      block; declaration order is the dispatch tie-break; per-action pref keys so one corrupt
      entry costs one binding) and the eight TC rows to the lead.

---

### WP4 — Export quality plumbing + `MainScreen` dispatch refactor

**Model recommendation:** `sonnet` (two small, well-bounded consumer changes; the risk is
behaviour drift in the key handler, which the tests pin).
**TC range:** TC-453 .. TC-457.

**Files:**
- Modify: `lib/services/library/photo_export_service.dart:37-39,126,141,321-333`
- Modify: `lib/views/main_screen.dart:93-135`
- Create: `test/services/library/photo_export_quality_test.dart`
- Create: `test/views/main_screen_shortcuts_test.dart`

**Interfaces:**
- Consumes (WP3): `AppState.shortcutBindings`, `ShortcutAction`, `ShortcutBindings.actionFor`.
- Produces:
  ```dart
  // photo_export_service.dart
  const int kDefaultExportJpegQuality = 90;
  class PhotoExportService {
    int jpegQuality;                       // mutable, default kDefaultExportJpegQuality
    static Future<Uint8List?> exportBytesFor(String path,
        {DngFullDecoder? decoder, int quality = kDefaultExportJpegQuality});
  }
  Future<Uint8List?> exportJpegForTest(DecodedRgba decoded,
      {int exifOrientation = 1, int quality = kDefaultExportJpegQuality});
  ```

**Behavior:**

*Export.* `PhotoExportService` is constructed once inside `AppState`'s initializer list
(`app_state.dart:84`), so the quality cannot be a constructor argument — it would freeze at
construction, before prefs are read. Instead it is a mutable public field that the default
fetch closure reads **at call time**. The closure currently lives in the initializer list
(`photo_export_service.dart:38-39`), which cannot reference `this`; move it into the
constructor body with a `late final` field:

```dart
class PhotoExportService {
  PhotoExportService({ExportBytesFetch? fetchBytes, DngFullDecoder? decoder}) {
    _fetchBytes = fetchBytes ??
        ((path) => exportBytesFor(path, decoder: decoder, quality: jpegQuality));
  }

  late final ExportBytesFetch _fetchBytes;

  /// Quality of the JPEG the user EXPORTS. Set from the app-wide setting
  /// (`AppState.setExportJpegQuality`); read at call time, not at
  /// construction, because this service is built before prefs are hydrated.
  ///
  /// Unrelated to [kDisplayJpegQuality] (`jpeg_encoder.dart`), which governs
  /// display-only bytes that never reach disk.
  int jpegQuality = kDefaultExportJpegQuality;
```

Both `img.encodeJpg` calls in the export path (`:126` and the post-EXIF re-encode at `:141`)
take the same `quality` value — re-encoding the already-q90 intermediate at a *different*
quality would be a second, pointless generation loss. `exportJpegForTest` (`:321-333`) gains the
same optional parameter so the test seam mirrors the real path.

*Shortcuts.* Replace the `if/else if` chain (`main_screen.dart:104-128`) with the table-driven
body given verbatim in §1.4.6. Preserved exactly: the `Focus`/`autofocus: true`/`_focusNode`
wrapper (`:97-99`), the `KeyDownEvent` guard (`:101`), `context.read<AppState>()` (`:102`), the
`selectedItemID != null` guards on the two mark actions only (`:111,116`), and the fact that a
guarded-out mark still returns `KeyEventResult.handled` (`:114,119`). Unbound keys still return
`KeyEventResult.ignored` (`:131`).

**Constraints:**
- No change to which keys do what **by default** — TC-453 pins all seven against the old table.
- `exportBytesFor`'s `quality` parameter is optional with the 90 default, so any caller not yet
  updated keeps today's behaviour.
- Do not migrate to `Shortcuts`/`Actions`; keep the `Focus` + `onKeyEvent` shape.
- Do not touch `app_state.dart` (WP3 owns it) or `photo_export_service.dart`'s EXIF logic
  (`:143+`).

**Acceptance criteria:**
- [ ] `TC-453` widget test: with default bindings, ←/→/S/X/↑/↓/R each drive the same AppState
      call they drive today (fake AppState or a real one with a fake scanner — mirror whatever
      `test/views/main_detail_view_test.dart` already does).
- [ ] `TC-454` widget test: rebinding `nextPhoto` to `keyD` makes `D` advance and `→` do
      nothing.
- [ ] `TC-455` widget test: with `trashMarkPhoto` and `toggleRecycleMode` both on `X`, pressing
      `X` fires **only** the trash-mark (earlier in declaration order) and recycle mode is
      unchanged.
- [ ] `TC-456` `PhotoExportService.jpegQuality` defaults to 90 and is read at call time (set it
      after construction, assert the injected fake `fetchBytes` is not consulted for quality but
      the default closure path passes the new value — assert via `exportJpegForTest(quality:)`
      producing different byte lengths for q70 vs q100 on the same input).
- [ ] `TC-457` `exportJpegForTest(decoded, quality: 70)` output is strictly smaller than
      `quality: 100` output for the same decoded input.
- [ ] `grep -c "quality: 90" lib/services/library/photo_export_service.dart` prints `0`.
- [ ] `flutter analyze` → 0 issues; `flutter test test/views/ test/services/library/ -j 1` green.

**Steps:**

- [ ] **Step 1: Land the export-service field FIRST (WP3 is waiting on it)**

Edit `photo_export_service.dart` exactly as shown in Behavior above: add
`const int kDefaultExportJpegQuality = 90;` at top level, convert the constructor, add the
`jpegQuality` field, thread `quality` through `exportBytesFor` and `exportJpegForTest`, and
replace the three `quality: 90` literals (`:126,141,331`) with the parameter.

```bash
flutter analyze; RC=$?; echo "ANALYZE_RC=$RC"
git add lib/services/library/photo_export_service.dart
git commit -- lib/services/library/photo_export_service.dart \
  -m "feat(export): export JPEG quality is a settable field, default 90"
```

- [ ] **Step 2: Write the failing export tests (TC-456, TC-457)**

```dart
// test/services/library/photo_export_quality_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/library/photo_export_service.dart';
// plus whatever DecodedRgba fixture helper the existing export tests use.

void main() {
  test('TC-456 the service defaults to q90 and the field is settable', () {
    final service = PhotoExportService();
    expect(service.jpegQuality, kDefaultExportJpegQuality);
    expect(kDefaultExportJpegQuality, 90);
    service.jpegQuality = 70;
    expect(service.jpegQuality, 70);
  });

  test('TC-457 quality actually reaches the encoder', () async {
    final decoded = smallDecodedRgbaFixture(); // reuse the existing fixture helper
    final low = await exportJpegForTest(decoded, quality: 70);
    final high = await exportJpegForTest(decoded, quality: 100);
    expect(low, isNotNull);
    expect(high, isNotNull);
    expect(low!.length, lessThan(high!.length));
  });
}
```

If no `DecodedRgba` fixture helper exists in the current export tests, build one inline
(a 64×64 noise buffer — flat colour compresses identically at both qualities and would make
TC-457 vacuous). Note this choice in the sign-off.

- [ ] **Step 3: Run red → green**

```bash
flutter test test/services/library/photo_export_quality_test.dart -j 1; RC=$?; echo "TEST_RC=$RC"
```
Red first if Step 1 were skipped; after Step 1, expect `TEST_RC=0`, 2 tests.

- [ ] **Step 4: Write the failing shortcut tests (TC-453..455)**

```dart
// test/views/main_screen_shortcuts_test.dart
// Pump MainScreen inside a ChangeNotifierProvider<AppState>, then drive keys with
// `await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight)`.

  testWidgets('TC-453 the seven default bindings drive the same actions as before',
      (tester) async { /* ← → S X ↑ ↓ R, one assertion each */ });

  testWidgets('TC-454 a rebound key wins and the old key goes dead', (tester) async {
    state.setShortcutBinding(ShortcutAction.nextPhoto, LogicalKeyboardKey.keyD);
    await tester.pump();
    final before = state.selectedItemID;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(state.selectedItemID, before, reason: 'old binding is dead');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    expect(state.selectedItemID, isNot(before));
  });

  testWidgets('TC-455 a duplicated key fires only the earlier-declared action',
      (tester) async {
    state.setShortcutBinding(ShortcutAction.toggleRecycleMode, LogicalKeyboardKey.keyX);
    await tester.pump();
    final recycleBefore = state.recycleMode;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    expect(state.currentItem?.status, PhotoStatus.trashed);
    expect(state.recycleMode, recycleBefore, reason: 'later action must not also fire');
  });
```

Seed the `AppState` with at least two fake items so navigation and marking are observable;
copy the seeding helper from `test/views/main_detail_view_test.dart` rather than inventing one.

- [ ] **Step 5: Run and confirm red**

Run: `flutter test test/views/main_screen_shortcuts_test.dart -j 1`
Expected: TC-454 and TC-455 fail (the old chain ignores bindings), TC-453 passes — that split is
itself the evidence that TC-453 pins pre-existing behaviour.

- [ ] **Step 6: Implement the dispatch refactor**

Replace `main_screen.dart:100-132` with the body in §1.4.6 and add
`import '../models/shortcut_bindings.dart';`. Delete nothing else from the method.

- [ ] **Step 7: Run — all five green, plus the existing view suite**

```bash
flutter analyze; RC=$?; echo "ANALYZE_RC=$RC"
flutter test test/views/ test/services/library/ -j 1; RC=$?; echo "TEST_RC=$RC"
```
Expected both 0, `All tests passed!`. `test/views/settings_dialog_test.dart` may be mid-rewrite
by WP5 at this moment — if it fails, confirm with the lead that the failure is WP5's in-progress
file and not yours before proceeding.

- [ ] **Step 8: Commit**

```bash
git add lib/views/main_screen.dart test/views/main_screen_shortcuts_test.dart \
        test/services/library/photo_export_quality_test.dart
git commit -- lib/views/main_screen.dart test/views/main_screen_shortcuts_test.dart \
              test/services/library/photo_export_quality_test.dart \
  -m "feat(shortcuts): dispatch keys through the user's bindings (TC-453..457)"
```

- [ ] **Step 9: Report** the five TC rows and an explicit negative-space statement: which of the
      seven default behaviours the diff could have silently dropped, and which test pins each.

---

### WP5 — The D1 settings dialog

**Model recommendation:** `sonnet` for the widget construction, with `opus` review of the
recording-state machine; this is the largest package and the natural place to put a second body
once WP1 finishes.
**TC range:** TC-458 .. TC-467.

**Files:**
- Rewrite: `lib/views/settings_dialog.dart` (path and public class name unchanged, so
  `lib/views/sidebar_view.dart:372` needs no edit)
- Create: `lib/views/settings_dialog/settings_section_label.dart`
- Create: `lib/views/settings_dialog/settings_primitives.dart`
- Create: `lib/views/settings_dialog/settings_summary_rail.dart`
- Create: `lib/views/settings_dialog/performance_tab.dart`
- Create: `lib/views/settings_dialog/memory_tab.dart`
- Create: `lib/views/settings_dialog/shortcuts_tab.dart`
- Rewrite: `test/views/settings_dialog_test.dart`

**Interfaces:**
- Consumes (WP3): every getter and setter in §1.9, `ShortcutAction`, `ShortcutBindings`,
  `keyLabelFor`, `kReservedShortcutKeys`, `SettingsSnapshot`. (WP2): `RetentionTier`,
  `retentionPolicyForTier`, `RetentionTierLabel.label`.
- Produces: `class SettingsDialog extends StatefulWidget` (unchanged constructor
  `const SettingsDialog({super.key})`) and these widget keys, which the tests address:
  `settingsTab.performance` / `.memory` / `.shortcuts`, `decodeLaneWidthSlider` (**kept from
  today**, `settings_dialog.dart:64`, so TC-354's addressing survives), `exportQualitySlider`,
  `retentionTier.<id>`, `retentionResetToAuto`, `shortcutRow.<actionId>`,
  `shortcutRecord.<actionId>`, `shortcutReset.<actionId>`, `shortcutResetAll`,
  `settingsConflictNote`, `summaryRail.conflicts`, `settingsDone`, `settingsCancel`.

**Behavior:**
§1.5 (visual translation, tab assignment, rail, caption strings), §1.4.4 (recording flow) and
§1.6 (lifecycle). Restated for the implementer as the non-derivable decisions:

- The dialog is `StatefulWidget`; `initState` captures
  `_snapshot = context.read<AppState>().settingsSnapshot()` (read, not watch) and
  `_committed = false`. `dispose()` calls `restoreSettings(_snapshot)` unless `_committed`.
  `Done` sets `_committed = true` then pops. `Cancel` pops directly. This makes barrier-tap and
  Escape revert for free, which is the only way to get all three dismissal paths right with one
  piece of code.
- Selected-tab state is a plain `int _tab = 0` in the dialog; the summary rail is outside the
  tab body and rebuilds on every `AppState` notification.
- The Shortcuts tab holds the recording state (`ShortcutAction? _recording`,
  `String? _recordError`) and a `Focus` node it requests focus on when recording starts. While
  `_recording != null` the node returns `KeyEventResult.handled` for every key event, so no
  keystroke escapes to `MainScreen` behind the dialog.
- Disabled lane-width slider when `maxDecodeLaneWidth == 1`: `Slider.onChanged` is `null`, the
  row still renders, caption reads `This machine allows 1 lane`. This is TC-355's behaviour and
  must not regress.
- The retention block's `Use detected default` button is hidden when
  `!state.isRetentionTierOverridden` — there is nothing to reset.
- Per-row `Reset` is shown only when `!bindings.isDefault(action)`; `Reset all shortcuts` only
  when `bindings.hasAnyNonDefault`.

**Constraints:**
- Every colour via `HalcyonTokens.of(context)`. `grep -nE "Colors\.|0xFF" lib/views/settings_dialog.dart lib/views/settings_dialog/` must return only `Colors.white` on the primary button's label (D1's `#fff`, `D1.html:93`) — declare that one exception in the sign-off.
- Metrics come from the §1.5.2 table. Do not re-measure from the HTML; the table is the frozen
  translation.
- No new dependency; no `GridView` (a two-`Expanded` `Row` is the whole 2-column grid).
- Keep the `Key('decodeLaneWidthSlider')` value byte-identical to today's
  (`settings_dialog.dart:64`).
- Do not edit any file outside this package — in particular `sidebar_view.dart` must stay
  untouched, which the unchanged path + class name guarantees.

**Acceptance criteria:**
- [ ] `TC-458` the dialog renders the three tab labels `Performance` / `Memory` / `Shortcuts`
      and the `At a glance` rail on every tab.
- [ ] `TC-459` (supersedes TC-354) the slider found by `Key('decodeLaneWidthSlider')` is
      enabled, `min` 1, `max` 5, and `onChanged(4)` writes through to `state.decodeLaneWidth`;
      its row label is `find.text('Concurrent RAW decodes')` and
      `find.textContaining('lane')` finds **nothing** anywhere in the dialog.
- [ ] `TC-460` (supersedes TC-355) with `laneCeiling: 1` the row is **rendered**, the slider's
      `onChanged` is `null`, and the caption reads
      `This machine can only decode one RAW at a time`.
- [ ] `TC-461` the export-quality slider has `min: 70, max: 100, divisions: 6` and
      `onChanged(73)` results in `state.exportJpegQuality == 75`.
- [ ] `TC-462` tapping the `retentionTier.generous` card sets `state.retentionTier` and
      `state.retentionPolicy.after == 11`; `retentionResetToAuto` appears only after an override
      and clears it.
- [ ] `TC-463` the rail shows `3 / 5`, the current quality, `<Tier> · <N> MiB`, and `None` for
      conflicts on a clean state.
- [ ] `TC-464` recording flow: tap `shortcutRecord.starPhoto`, send `keyF`, assert
      `state.shortcutBindings.keyFor(starPhoto) == keyF` and that the row left recording mode.
- [ ] `TC-465` recording rejects a reserved key: tap record, send `Tab`, assert the binding is
      unchanged and a danger message containing `can't be used as a shortcut` is on screen;
      then send `Escape` and assert recording ended with the binding still unchanged.
- [ ] `TC-466` conflict surfacing: bind recycle-mode to `X`, assert `settingsConflictNote` exists
      and its text names both `Trash-mark photo` and `Toggle recycle mode`, and
      `summaryRail.conflicts` reads `1 conflict (X)`.
- [ ] `TC-467` Cancel reverts: open, change lane width + quality + tier + one binding, tap
      `settingsCancel`, assert all four are back to their opening values; then repeat with
      `settingsDone` and assert they persist.
- [ ] `flutter analyze` → 0 issues; `flutter test test/views/settings_dialog_test.dart -j 1`
      green with 10 tests.

**Steps:**

- [ ] **Step 1: Write the shell + primitives with no behaviour, and the failing TC-458**

Create `settings_section_label.dart`:

```dart
import 'package:flutter/material.dart';
import '../theme_tokens.dart';

/// D1's `.section-label` (D1.html:56-60): uppercase caption plus a hairline
/// that fills the remaining width. Deliberately NOT `renameSectionLabel`
/// (rename_dialog/section_label.dart) -- that one has no trailing rule and
/// different metrics; sharing would force one of the two dialogs off-mockup.
Widget settingsSectionLabel(HalcyonTokens t, String text) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Text(
          text.toUpperCase(),
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.63, // 0.06em at 10.5px
            color: t.textFaint,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: Container(height: 1, color: t.borderSoft)),
      ],
    ),
  );
}
```

`settings_primitives.dart` holds `settingsBlock(t, child)`, `settingsRowLabel(t, text)`,
`settingsCaption(t, text)`, `settingsKeyChip(t, label, {bool conflict})`,
`settingsSmallButton(t, label, onTap)`, `settingsTabBar(...)`, `settingsFooterButtons(...)` —
each a direct transcription of the corresponding §1.5.2 table row. Then rewrite
`settings_dialog.dart` as the `Dialog` shell with the header, tab bar, empty tab bodies, rail
and footer.

- [ ] **Step 2: Run TC-458 red → green**

```bash
flutter test test/views/settings_dialog_test.dart -j 1; RC=$?; echo "TEST_RC=$RC"
```

- [ ] **Step 3: Performance tab (TC-459..461)**

Write TC-459/460/461 first (they are the two carried-forward lane-width tests plus the new
export slider), watch them fail, then build `performance_tab.dart`: `Parallelism` and `Export`
sections side by side in a two-`Expanded` `Row`, `Workflow` full-width below with the two
existing `CheckboxListTile`s restyled as token-coloured rows.

Concurrent-RAW-decodes row — note the label string is **not** D1's, per §1.5.6, while the
widget key **is** today's, so the carried-forward tests keep addressing the same slider:

```dart
settingsRowLabel(t, 'Concurrent RAW decodes'),
settingsCaption(
  t,
  state.maxDecodeLaneWidth > 1
      ? '${state.decodeLaneWidth} of ${state.maxDecodeLaneWidth} max'
      : 'This machine can only decode one RAW at a time',
),
Slider(
  key: const Key('decodeLaneWidthSlider'), // byte-identical to today's key
  min: 1,
  max: state.maxDecodeLaneWidth.toDouble(),
  // Flutter asserts divisions > 0, so a ceiling of 1 passes null.
  divisions: state.maxDecodeLaneWidth > 1 ? state.maxDecodeLaneWidth - 1 : null,
  label: '${state.decodeLaneWidth}',
  value: state.decodeLaneWidth.toDouble(),
  onChanged: state.maxDecodeLaneWidth > 1
      ? (v) => context.read<AppState>().setDecodeLaneWidth(v.round())
      : null,
),
```

Export slider: `Slider(key: const Key('exportQualitySlider'), min: 70, max: 100, divisions: 6,
value: state.exportJpegQuality.toDouble(), label: '${state.exportJpegQuality}',
onChanged: (v) => context.read<AppState>().setExportJpegQuality(v.round()))` — `divisions: 6`
gives exactly the seven 5-step stops of §1.3 S2.

- [ ] **Step 4: Memory tab (TC-462)**

Write TC-462, watch it fail, then build `memory_tab.dart`: three tier cards in a `Row` with 8px
gaps, each a `Material`+`InkWell` calling `setRetentionTier`, rendering
`tier.label`, `'${retentionPolicyForTier(tier).payloadByteBudget ~/ (1024 * 1024)} MiB'` and
`'−${policy.before} / +${policy.after} photos'`. Selected card = `state.retentionTier == tier`.
Below: the auto/override caption from §1.5.5 and, when overridden, the
`Key('retentionResetToAuto')` text button.

- [ ] **Step 5: Summary rail (TC-463)**

Write TC-463, watch it fail, then build `settings_summary_rail.dart` per §1.5.4. The conflicts
value is derived: `state.shortcutBindings.conflicts` → `None` or
`'${n} conflict${n == 1 ? '' : 's'} (${keys.map(keyLabelFor).join(', ')})'`, danger-coloured
when `n > 0`.

- [ ] **Step 6: Shortcuts tab and the recording state machine (TC-464..466)**

Write TC-464/465/466 first, watch them fail, then build `shortcuts_tab.dart`:

```dart
class ShortcutsTab extends StatefulWidget { const ShortcutsTab({super.key}); ... }

class _ShortcutsTabState extends State<ShortcutsTab> {
  final FocusNode _recordFocus = FocusNode();
  ShortcutAction? _recording;
  String? _recordError;

  @override
  void dispose() { _recordFocus.dispose(); super.dispose(); }

  void _startRecording(ShortcutAction action) {
    setState(() { _recording = action; _recordError = null; });
    _recordFocus.requestFocus();
  }

  void _stopRecording() => setState(() { _recording = null; _recordError = null; });

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final action = _recording;
    if (action == null) return KeyEventResult.ignored;
    // Swallow EVERYTHING while recording: nothing may reach MainScreen behind
    // the dialog, including the key we are about to bind.
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) { _stopRecording(); return KeyEventResult.handled; }
    if (kReservedShortcutKeys.contains(key)) {
      setState(() => _recordError = "${keyLabelFor(key)} can't be used as a shortcut.");
      return KeyEventResult.handled;
    }
    context.read<AppState>().setShortcutBinding(action, key);
    _stopRecording();
    return KeyEventResult.handled;
  }
  ...
}
```

Rows are laid out in two columns (actions 0-3 left, 4-6 right, 20px gutter), each row keyed
`Key('shortcutRow.${action.id}')`. The conflict note (`Key('settingsConflictNote')`) renders one
line per entry in `bindings.conflicts` using the §1.5.5 sentence. `Reset all shortcuts` sits
below, keyed `Key('shortcutResetAll')`.

Cancel-on-tab-switch: the dialog calls `_stopRecording` implicitly because switching tabs
disposes this subtree — assert nothing about it, but do not add a `keepAlive`.

- [ ] **Step 7: Lifecycle (TC-467)**

Write TC-467, watch it fail, then add `_committed` + `dispose`-time restore to
`settings_dialog.dart` per §1.6. Pump the dialog through a real `showDialog` in this test (not
as a bare body widget) so the pop path is exercised; the other tests may keep the simpler
`Scaffold(body: SettingsDialog())` pump helper that `settings_dialog_test.dart:8-16` already
uses.

- [ ] **Step 8: Full gate**

```bash
flutter analyze; RC=$?; echo "ANALYZE_RC=$RC"
flutter test test/views/ -j 1; RC=$?; echo "TEST_RC=$RC"
grep -nE "Colors\.|0xFF" lib/views/settings_dialog.dart lib/views/settings_dialog/
```
Expected: `ANALYZE_RC=0`, `TEST_RC=0`, `All tests passed!`, 10 tests in the settings file, and
the grep returning only the single `Colors.white` line.

- [ ] **Step 9: Commit**

```bash
git add lib/views/settings_dialog.dart lib/views/settings_dialog/ \
        test/views/settings_dialog_test.dart
git commit -- lib/views/settings_dialog.dart lib/views/settings_dialog/ \
              test/views/settings_dialog_test.dart \
  -m "feat(settings): D1 tabbed settings panel with summary rail and shortcut recording (TC-458..467)"
```

- [ ] **Step 10: Report** the ten TC rows, plus an explicit note that TC-354 and TC-355 are
      superseded by TC-459 and TC-460 (the matrix row for the old ids must say so, per
      `docs/sop/unit_test.md`'s "移除或改名需註記原因" rule).

---

### Lead's closing tasks (not a work package)

- [ ] Apply all TC rows (TC-438..467) to `docs/sop/unit_test.md`, including the
      TC-354/TC-355 supersession note.
- [ ] Apply AD-043, AD-044 and G-028 to `docs/sop/memory.md`.
- [ ] Update `docs/sop/file_index.md` with the new `lib/views/settings_dialog/`,
      `lib/models/shortcut_bindings.dart` and `lib/providers/settings_snapshot.dart`.
- [ ] Integration gate on the merged tree:
      `flutter analyze` (0 issues) and `flutter test -j 1` (`All tests passed!`,
      declared count == executed count), with the exit code self-captured in the artifact.
- [ ] Spot-check that the two frozen non-negotiables held:
      `grep -rn "kCoresPerDecode\|kMaxDecodeLaneWidth\|tierTwoNavigationDebounce" lib/` shows
      no value changes, and `git diff --stat` shows `lib/views/sidebar_view.dart` untouched.

---

# Part 3 — Decision record and risks

## 3.1 Decisions I made from code and convention (not questions)

Listed so the reviewer can overturn them deliberately rather than discover them.

| Decision | Basis |
|---|---|
| Conflicts **warn**, never block | D1 renders a persistent conflict state (`D1.html:175,178,179,190`); a blocking validator makes that state unreachable |
| Duplicate key → **earliest-declared action wins** | Something must win deterministically once duplicates are legal; declaration order is already the UI order |
| Cancel is a **real revert** via a snapshot | D1 has a Cancel button (`:194`) but every existing setter writes through immediately (`app_state.dart:442-457`); a no-op Cancel would be a lie, and the snapshot is six fields |
| Export quality slider is **70..100 step 5** | D1's `step="5"` (`D1.html:140`); below 70 is not a use case for a shared export |
| Retention tier default is **auto** (key absent), not a stored tier | D1's caption says "Auto-picked from detected RAM ... override anytime" (`:164`); storing the auto value would freeze a machine's tier across a RAM upgrade |
| Tier does **not** move the decode lane ceiling | keeps `laneCeilingFor`'s benchmarked envelope intact (frozen decision 5) |
| Shrinking the tier **sweeps the cache immediately** | otherwise the memory the setting exists to release is not released until the next navigation |
| `kDisplayJpegQuality` lives in `jpeg_encoder.dart` | that file already owns the decisions both consumers must share (`jpeg_encoder.dart:11-13`); neither consumer imports the other |
| `settings_dialog.dart` is rewritten **in place** | keeps `sidebar_view.dart:372` out of every package's file list |
| S1 is labelled `Concurrent RAW decodes`, rail `Concurrent decodes` | user directive 2026-08-30; the only deviation from "D1 exactly", and it is copy, not layout. Internal identifiers keep "lane" — see §1.5.6 |
| A new `settingsSectionLabel`, not a shared one with the rename dialog | different metrics and a trailing hairline; sharing would push one of the two dialogs off its mockup |
| No migration to `Shortcuts`/`Actions` | YAGNI — the `Focus`+`onKeyEvent` shape already supports everything asked for |

## 3.2 Decision record — the three questions, now ruled (2026-08-30)

**There are no open questions.** All three were put to the user and answered; the answers are
frozen alongside the original five directives and are not to be relitigated.

- **D-1 (was OQ-1) — the two existing checkboxes go in a `Workflow` section at the bottom of
  the Performance tab.** Ruled 2026-08-30, matching the recommendation. No fourth tab; D1's
  three-tab bar is unchanged. Specified in §1.5.3 and built in WP5 Step 3.
- **D-2 (was OQ-2) — the retention tier applies LIVE.** Ruled 2026-08-30, matching the
  recommendation. WP2 keeps its full scope: mutable `PhotoPayloadCache.byteBudget` plus an
  immediate eviction sweep on shrink, and `ImagePreloadController.setRetention`. The
  "persist now, apply at next launch" variant is rejected and must not be substituted as a
  simplification. Specified in §1.7 and built in WP2 Steps 6-9.
- **D-3 (was OQ-3) — the shared constant lands directly at 70.** Ruled 2026-08-30. No
  80-first staging, no follow-up flip: WP1 writes `kDisplayJpegQuality = 70` in its first and
  only commit and the sidebar tile drops from q80 to q70 in the same change. Specified in §1.8
  and built in WP1.

## 3.3 Risks

| Risk | Likelihood | Mitigation in the plan |
|---|---|---|
| The dispatch refactor silently drops one of the seven behaviours (e.g. the `handled` return when `selectedItemID` is null) | medium | TC-453 pins all seven against today's table and is written to pass **before** the refactor, so it is a genuine regression guard, not a post-hoc description |
| `restoreSettings` reverts in-memory state but leaves a pref written | medium | every field goes back through its ordinary setter; TC-452 asserts the prefs, not just the getters |
| `_enforceBudget` throws on an empty cache once `setByteBudget` can call it | medium | guarded with `_entries.isNotEmpty`; called out in the WP2 step text because it is the one place the existing invariant changes |
| Recording swallows a keystroke that then reaches `MainScreen` behind the dialog | low | the recording `Focus` returns `handled` for **every** event while active, not only the one it binds |
| WP3 blocked on WP4's `PhotoExportService.jpegQuality` (circular-looking) | high if unmanaged | WP4's Step 1 is a standalone 4-line commit that lands the field first; the alternative (a temporary duplicate constant) is written down and explicitly discouraged |
| Two packages both need `docs/sop/unit_test.md` | certain | no implementer edits it; the lead applies all rows in one commit |
| In-package green does not survive the merge | medium | the lead's integration gate re-runs the whole suite on the merged tree; in-branch evidence is explicitly declared non-transferable |
| The 2-column grid mis-measures on a narrow window | low | the dialog is a fixed 920×560 like `rename_dialog.dart:125-127`; there is no responsive case to get wrong |

## 3.4 Explicitly out of scope (unchanged from the frozen list)

Tier-2 navigation debounce (`image_preload_controller.dart:71`), payload re-encode quality as a
*user setting* (the constant itself is shared, per frozen decision 4), the
`ImageRequestPurpose` pixel targets (`image_source_types.dart:14,19,30`), `kCoresPerDecode` and
`kMaxDecodeLaneWidth` (`retention_policy.dart:89,92`), and any recycle/trash strategy toggle
(`settings-exploration.md:68`, still unexplored).

Checked against the "out-of-scope items on the critical path are unscheduled blockers, not
deferrals" rule: none of the five is required for the frozen end state — the panel is fully
functional without any of them.






