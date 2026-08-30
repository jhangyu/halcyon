# Settings Panel Redesign — Exploration Report

## 1. Current options UI

- File: `lib/views/settings_dialog.dart` (91 lines, `SettingsDialog extends StatelessWidget`).
- Opened from sidebar view via a bare `showDialog(context: context, builder: (ctx) => SettingsDialog())` — `lib/views/sidebar_view.dart:372`.
- Structure: plain `AlertDialog` (title `'Options'`, `settings_dialog.dart:12`), fixed `width: 360` (`:15`), a `SingleChildScrollView` > `Column` with no section headers, dividers, or grouping — just three controls stacked with `SizedBox(height: 8)` spacers:
  1. `CheckboxListTile` "Auto-advance on mark" (`:21-35`), bound to `state.autoAdvance` / `setAutoAdvance`.
  2. `CheckboxListTile` "Overwrite existing files on Copy/Move" (`:37-51`), bound to `state.overwriteExisting` / `setOverwriteExisting`.
  3. A bare `Text` label + `Slider` for "Parallel RAW decodes" (`:53-78`), bound to `state.decodeLaneWidth` / `setDecodeLaneWidth`, range `1..state.maxDecodeLaneWidth`.
- No `HalcyonTokens` theming, no icons, no visual sections — this is the "bare" panel the user wants redesigned.
- Single "Close" `TextButton` action (`:83-88`).

## 2. The "exif panel" (Rename-by-EXIF dialog) — the layout to imitate

This is `RenameDialog`, not a metadata-viewer widget (there is no dedicated EXIF-viewer panel in the codebase; "exif panel" = this dialog, opened from the sidebar menu item `'Rename by EXIF...'` at `lib/views/sidebar_view.dart:415`).

- File: `lib/views/rename_dialog/rename_dialog.dart`.
- Root is a `Dialog` (not `AlertDialog`), fixed size `880×540` (`:125-127`), `t.dialog` background, `borderRadius: 8`, `clipBehavior: Clip.antiAlias`.
- Vertical `Column`: **header** → **body** (`Expanded`) → 1px divider → **actions row**.
- **Header** (`_header`, `:177-221`): padded `Container` with a bottom border (`t.borderSoft`), a `Row` with a title/subtitle `Column` on the left ("Rename by EXIF" bold 15px + a dim 11.5px subtitle line) and a pill-shaped badge on the right (`Container` with `borderRadius: 20`, border, showing scope text e.g. "Whole folder").
- **Body**: `Row` split into two panes divided by a 1px `Container(width: 1, color: t.borderSoft)` vertical line:
  - **Left pane** = `RuleEditor` (`lib/views/rename_dialog/rule_editor.dart`), fixed `width: 360`, background `t.pane`, `SingleChildScrollView` with padding `(18,16,18,18)`. Internally organized into **labeled sections** via a shared `renameSectionLabel(t, 'Section Title')` helper (`section_label.dart`) — this is the section-header pattern to reuse for the settings redesign. Sections seen: "Preset" (radio rows), "Rule template" (bordered input block), "Insert variable" (grouped chip rows with uppercase 10.5px group titles).
    - Radio rows (`_presetRow`, `:97-167`): `Material`+`InkWell` row, selected state = accent-tinted background (`t.accent.withValues(alpha: 0.2)`) + accent border, `borderRadius: 5`, a small `Radio`, then a `Column` with a 12.5px label + 11px monospace dim subtitle.
    - Bordered input block (`_ruleEditorBlock`, `:169-226`): `Container` with `color: t.input`, `border: t.border`, `borderRadius: 5`, containing a `TextField` (underline border, monospace) plus a validation row below it (check/error icon + colored status text).
    - Chip rows (`_chip`, `:228-248`): small `Material`+`InkWell` pill, `borderRadius: 5`, border `t.borderSoft`, 11px monospace text, laid out in a `Wrap(spacing: 5, runSpacing: 5)` under an uppercase 10.5px faint group title.
  - **Right pane** = `RenamePreviewList` (`lib/views/rename_dialog/preview_list.dart`) — `Expanded`, shows live preview rows with a reroll button.
- **Actions row** (`RenameActions`, `lib/views/rename_dialog/actions.dart`): below a 1px divider, Cancel + primary Run button.
- Theming: all colors come from `HalcyonTokens` (`lib/views/theme_tokens.dart`), a `ThemeExtension` with dark/light palettes (`pane`, `dialog`, `surface`, `input`, `border`, `borderSoft`, `text`, `textDim`, `textFaint`, `accent`, `success`, `danger`, `starred`). `SettingsDialog` currently uses none of this — it relies on default `AlertDialog`/Material theming only.
- Takeaway for redesign: reuse `Dialog` + `t.dialog` background + header-with-subtitle-and-badge pattern, `renameSectionLabel` section headers, `t.pane`/`t.surface` grouped blocks with `borderRadius: 5`, and monospace/dim-text captions under numeric controls (mirrors the existing "Parallel RAW decodes" caption style, just needs the section-label treatment).

## 3. Persistence mechanism (today, and for new settings)

- `AppState` owns a `SharedPreferences? _prefs` field (`lib/providers/app_state.dart:142`), initialized in an async init method (`:154`, `_prefs = await SharedPreferences.getInstance()`).
- Existing settings are plain key/value pairs, app-wide (not per-folder):
  - `autoAdvance` (bool) — read `:155`, write `:442-445`.
  - `overwriteExisting` (bool) — read `:156`, write `:448-451`.
  - `decodeLaneWidth` (int) — read `:161-172` (clamped to a machine-specific ceiling computed at startup, `_laneCeiling`), write `:454-457` (also pushes the new value live into `_preloadController.setDecodeLaneWidth`).
- This is already app-level, global persistence — **no new mechanism is needed** for additional app-level settings; new tunables (parallelism, memory) can follow the exact same `_prefs?.getX(key)` / `_prefs?.setX(key, value)` pattern, with a getter and a `setX` mutator on `AppState` calling `notifyListeners()` (implicit via `ChangeNotifier`, confirm each setter does this — `setDecodeLaneWidth` at `:454-457` does not call `notifyListeners()` directly but is a `ChangeNotifier` method context, verify at edit time) and, where relevant, pushing the value into the live collaborator (`_preloadController`) the way `decodeLaneWidth` does.
- Note: `.halcyon_status.json` (per-folder star/trash state, described in project `CLAUDE.md`) is a **separate**, per-folder persistence mechanism — not used for app options and not relevant to settings.

## 4. Candidate settings inventory

### Parallelism tunables

| Name | Current hardcoded value | File:line | Effect | Risk of exposing | Recommended control |
|---|---|---|---|---|---|
| Decode lane width | Already exposed. Default `kDefaultDecodeLaneWidth = 3`, hard ceiling `kMaxDecodeLaneWidth = 5`, machine ceiling via `laneCeilingFor()` | `lib/services/image_pipeline/retention_policy.dart:96,99,120-131` | How many concurrent expensive RAW decodes run | Low — already user-adjustable, already clamped to a machine-derived ceiling | Slider (already implemented — carry forward, restyle only) |
| `tierTwoNavigationDebounce` | `Duration(milliseconds: 250)` | `lib/services/image_pipeline/image_preload_controller.dart:71` | Delay after navigation-quiet before a full-size (tier-2) decode fires; lower = snappier full-res but more wasted decodes during fast arrow-key browsing | Medium — a top-level `const`, not threaded through `ImagePreloadController`'s constructor today; exposing it means adding a constructor param and confirming nothing else assumes the constant. Bad values (too low) could burn CPU during rapid navigation | Slider/number stepper, coarse steps (e.g. 100/250/500/1000 ms) |
| Cores-per-decode / lane-ceiling formula inputs | `kCoresPerDecode = 5`, `kMaxDecodeLaneWidth = 5` | `retention_policy.dart:87,90` | Determine the machine-derived ceiling the lane-width slider maxes out at | High — these are calibration constants derived from real benchmarks (see doc comments citing `docs/logs/2026-08-30/decode-cpu-parallelism.txt` and `decode-lane-width-sweep.txt`); exposing them risks users invalidating the CPU/memory safety envelope | **Not recommended** as a user setting — internal calibration only |

### Memory-usage tunables

| Name | Current hardcoded value | File:line | Effect | Risk of exposing | Recommended control |
|---|---|---|---|---|---|
| Retention window (before/after) + payload byte budget | Rung table: floor `before=3,after=5,budget=224MiB` (`photo_payload_cache.dart:6,10,35`); mid `before=3,after=8,budget=304MiB`; high `before=3,after=11,budget=384MiB` — selected by `retentionPolicyFor()` from physical RAM at startup | `lib/services/image_pipeline/retention_policy.dart:67-82` (rung selection), `:6,10,35` in `photo_payload_cache.dart` for floor constants | How many photos around the current one stay fully decoded in memory, and the hard byte cap on the payload cache | Medium-high — directly trades RAM usage for scroll/navigation smoothness; wrong values on low-RAM machines could cause swapping/jank. The rung system already auto-selects based on detected RAM, so this is a "user override" of an already-computed safe default | Dropdown/segmented control presenting named tiers (e.g. "Conservative / Balanced / Generous") mapped to the existing rung values, NOT a raw byte-count slider — keeps user choices inside benchmarked envelopes |
| Payload re-encode JPEG quality | `kReencodeJpegQuality = 70` | `lib/services/image_pipeline/payload_reencoder.dart:34` | Quality of the single q70 bitstream every retained payload is re-encoded to (feeds both main-view display and derived sidebar thumbnails per the Phase-13 shared-payload design, see doc comment `:18-32`) | Medium — lower quality trades visible fidelity for less memory per cached payload; this is a core Phase-13 architecture decision (shared-payload cache), not a simple display knob — comments say the current 70 value was itself already tuned down from 90→80 recently | Optional, if included: dropdown with a few fixed quality presets, not a free slider — avoid destabilizing the shared-payload design's assumptions |
| Sidebar thumbnail JPEG quality | `jpegQuality = 80` (default param) | `lib/services/image_pipeline/sidebar_thumbnail_codec.dart:26,54` | Quality of the 200px sidebar thumbnail encode | Low | Optional — dropdown/toggle if surfaced at all |
| Sidebar thumbnail / preview / export target sizes | `sidebarThumbnail: 200px`, `preview: 2800px`, `export: 2048px` | `lib/services/image_pipeline/image_source_types.dart:14,19,30` | Long-edge pixel targets for the three decode purposes | Medium — these are wired into cache-key derivation and byte-budget math (see `retention_policy.dart` comments referencing "22.4 MiB... one no-preview RAW item" sized off the window-resolution target); changing them without re-deriving the budget constants could blow past the intended memory envelope | **Not recommended** without a matching re-derivation of the retention byte budgets — out of scope for a simple settings toggle |
| Export JPEG quality | `quality: 90` (three call sites, all literal `90`) | `lib/services/library/photo_export_service.dart:126,141,331` | Quality of the JPEG the user explicitly exports/shares | Low — this is a final user-facing output, not an internal cache tradeoff; safe to expose | Slider or dropdown (e.g. 70/80/90/95/100) — good "reasonable other candidate" |

### Other reasonable candidates (not parallelism/memory)

| Name | Current value | File:line | Notes |
|---|---|---|---|
| Auto-advance on mark | Already exposed (bool, default `false`) | `settings_dialog.dart:21-35`, `app_state.dart:138,442-445` | Carry forward as-is, just restyle |
| Overwrite existing on Copy/Move | Already exposed (bool, default `true`) | `settings_dialog.dart:37-51`, `app_state.dart:139,448-451` | Carry forward as-is, just restyle |
| Recycle/trash collision suffixing | Hardcoded `-1`/`-2` suffix behavior, in-folder `.trash/` subfolder | `lib/services/library/photo_file_actions.dart:90-159` (see `deleteTrashed`/`recycleTrashed`), also described in project `CLAUDE.md` "Deletion has two paths" section | No existing toggle for trash-vs-recycle-mode strategy; would need to trace `PhotoFileActions` call sites in `AppState` to see if a mode switch even exists before proposing a UI control — **flagging as unexplored, not recommending inclusion in this round** |
| Keyboard/UX toggles | Not located | — | No dedicated keybinding-customization code found under `lib/`; out of scope unless the user specifically wants it — would need a separate exploration pass |

## 5. Custom keyboard shortcuts (scope addition)

### Where shortcuts live today

- Single handler, single file: `lib/views/main_screen.dart`, method `_buildKeyboardShortcutHandler` (`:93-135`).
- Mechanism: a `Focus` widget (`:97-134`) with `autofocus: true` and a raw `onKeyEvent` callback (`:100-132`) — NOT Flutter's `Shortcuts`/`Actions`/`CallbackAction` framework. Each key is checked with a chained `if/else if` on `event.logicalKey == LogicalKeyboardKey.X` inside a `KeyDownEvent` guard (`:101`).
- No other file in `lib/views/` defines any `LogicalKeyboardKey`, `Shortcuts(`, `CallbackAction`, or `KeyDownEvent` reference — confirmed via repo-wide grep. This is the only shortcut surface in the app.

### Current shortcut table

| Key | Action | file:line |
|---|---|---|
| Arrow Left | `state.previousPhoto()` | `main_screen.dart:104-106` |
| Arrow Right | `state.nextPhoto()` | `main_screen.dart:107-109` |
| `S` | `state.markCurrent(PhotoStatus.starred)` (only if `state.selectedItemID != null`) | `main_screen.dart:110-114` |
| `X` | `state.markCurrent(PhotoStatus.trashed)` (only if `state.selectedItemID != null`) | `main_screen.dart:115-119` |
| Arrow Up | `_zoom.stepZoomIn()` | `main_screen.dart:120-122` |
| Arrow Down | `_zoom.stepZoomOut()` | `main_screen.dart:123-125` |
| `R` | `state.toggleRecycleMode()` | `main_screen.dart:126-128` |

7 shortcuts total, all single-key (no modifiers, no chords).

### What a remappable-shortcut setting would require

- **Architecture change, not just UI**: the current `if/else if` chain hardcodes both the trigger key and the target action together. Remapping requires decoupling them — e.g. a `Map<String, LogicalKeyboardKey>` (action-id → key) loaded from persistence, checked against `event.logicalKey` in the same handler, or a migration to Flutter's `Shortcuts`/`Actions` widgets with a dynamically-built `ShortcutMap`. This is a real refactor of `_buildKeyboardShortcutHandler`, not a config-value swap like the sliders above.
- **Conflict detection**: none exists today (nothing prevents two actions from sharing a key — moot now since keys are fixed and known-unique, but a remapping UI must check for collisions before accepting a new binding, both against the other 6 actions and reserved keys).
- **Persistence**: same `SharedPreferences` pattern as section 3 works fine — store each action's bound key (e.g. serialize `LogicalKeyboardKey.keyId` per action-id) and hydrate `AppState` (or a new small `KeyBindings` collaborator) at startup, same shape as `decodeLaneWidth`.
- **Which actions are remappable**: all 7 are plain single-key, no modifiers, and every one maps to an already-existing `AppState`/`_zoom` method — technically all 7 could be made remappable with equal effort. No hidden multi-key or context-dependent shortcuts were found (no per-view overrides, no modifier combos to account for).
- **Risk**: low-to-medium — isolated to one file/one widget, no interaction with the image pipeline or memory/parallelism settings. Main risk is scope creep in the settings UI (needs its own "record a key" capture widget, distinct from checkboxes/sliders) and the conflict-detection logic being an actual new piece of code, not a config value.
- **Recommended control type**: a dedicated "record shortcut" row per action (click a field, press a key, it captures `event.logicalKey` and shows the key name) — not a dropdown/slider. This is a different UI pattern from the rest of the panel and should get its own section (e.g. reusing the `renameSectionLabel`-style section header from section 2, with "Keyboard Shortcuts" as the section title and 7 rows below it).

## Summary for decision

**Recommended** (safe, already-scoped, clear value):
- Decode lane width (already exists — carry forward, restyle) — `retention_policy.dart:96,99,120-131`
- Export JPEG quality — `photo_export_service.dart:126,141,331`
- Retention tier as a named preset (Conservative/Balanced/Generous), not raw bytes — `retention_policy.dart:67-82`
- Custom keyboard shortcuts, 7 single-key bindings — `main_screen.dart:104-128` — value is clear and scope is bounded (only one file/handler owns shortcuts today), but it is a real code refactor (decouple key↔action, add conflict detection, new "record key" UI widget), not a config-value swap like the others in this bucket

**Optional** (worth asking the user about, moderate risk/complexity):
- Tier-2 navigation debounce (`image_preload_controller.dart:71`) — needs a constructor param added first
- Payload re-encode quality (`payload_reencoder.dart:34`) — touches Phase-13 shared-payload architecture, consider dropdown-only
- Sidebar thumbnail quality (`sidebar_thumbnail_codec.dart:26,54`) — low risk, low impact

**Not recommended** (internal calibration constants, exposing risks invalidating benchmarked safety envelopes):
- `kCoresPerDecode` / `kMaxDecodeLaneWidth` (`retention_policy.dart:87,90`)
- Raw target-size pixel values for thumbnail/preview/export purposes (`image_source_types.dart:14,19,30`) — would require re-deriving byte-budget math

Persistence: no new mechanism needed — `AppState`'s existing `SharedPreferences`-backed pattern (`app_state.dart:142,154-172,442-457`) is already app-level/global and directly reusable for every new setting.
