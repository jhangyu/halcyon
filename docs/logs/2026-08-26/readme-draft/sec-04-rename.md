## Renaming by EXIF

Photographers name files by shoot date, camera, lens, sequence number, or some mix of
those, and the format tends to be a house convention rather than whatever the camera
wrote to the SD card. Halcyon's rename feature is a small template engine over EXIF and
filesystem metadata: write a template once, apply it to a whole folder, and every RAW,
its JPG sibling, and any sidecar (`._DSC_0431.NEF`-style AppleDouble files) move together
under the same new base name.
<!-- evidence: lib/models/rename_rule.dart:30-35 -->

### The template model

A rule is a single string template such as `{YYYY}-{MM}-{DD}-{hh}-{mm}-{ss}`. Rendering a
template is pure — it never touches the filesystem — so the whole naming policy is
unit-testable without any photos on disk.
<!-- evidence: lib/models/rename_rule.dart:30-39 -->

Every `{token}` the renderer understands is grouped exactly as the rule editor's "Insert
variable" panel groups them:
<!-- evidence: lib/views/rename_dialog/rule_editor.dart:70-90 -->

| Group | Variable | Resolves to | Example |
|---|---|---|---|
| Date/time | `{YYYY}` | Capture year, 4 digits | `2026` |
| Date/time | `{MM}` | Capture month, 2 digits | `08` |
| Date/time | `{DD}` | Capture day, 2 digits | `26` |
| Date/time | `{hh}` | Capture hour, 2 digits | `14` |
| Date/time | `{mm}` | Capture minute, 2 digits | `07` |
| Date/time | `{ss}` | Capture second, 2 digits | `33` |
| Camera | `{camera}` | EXIF camera model, empty if absent | `Z 8` |
| Camera | `{lens}` | EXIF lens model, empty if absent | `NIKKOR Z 24-70mm f_2.8 S` |
| Camera | `{make}` | EXIF camera make, empty if absent | `NIKON CORPORATION` |
| Camera | `{artist}` | EXIF artist/copyright tag, empty if absent | `J. Chen` |
| Shooting | `{f}` | Aperture, formatted `f<value>`, empty if absent | `f2.8` |
| Shooting | `{focal}` | Focal length, formatted `<value>mm`, empty if absent | `35mm` |
| Shooting | `{iso}` | ISO, formatted `ISO<value>`, empty if absent | `ISO400` |
| Shooting | `{shutter}` | Shutter speed as EXIF prints it, empty if absent | `1/250` |
| Shooting | `{direction}` | GPS image direction, rounded to a whole degree, empty if absent | `187` |
| File | `{seq}` | 1-based sequence number among files that collide on the same rendered name before `{seq}` is applied; supports a zero-pad width, e.g. `{seq:3}` → `007` | `1` |
| File | `{orig}` | The original filename's base (no extension) | `DSC_0431` |
<!-- evidence: lib/models/rename_rule.dart:50-124 -->

The date/time fields fall back to the file's filesystem modification time when EXIF has
no capture date (or when EXIF could not be read at all) — the renderer always has *some*
date to render, it is just not necessarily the capture date in that case.
<!-- evidence: lib/models/rename_rule.dart:96 -->

Any field with no EXIF value renders as an empty string rather than a placeholder — the
dialog's preview list says this explicitly ("Missing metadata renders as an empty
string").
<!-- evidence: lib/models/rename_rule.dart:107-119 -->
<!-- evidence: lib/views/rename_dialog/preview_list.dart:87-92 -->

A template referencing any token outside this table is rejected before it can run: the
editor shows "Unknown variable {name}" and the Run button is disabled.
<!-- evidence: lib/models/rename_rule.dart:65-77 -->
<!-- evidence: lib/views/rename_dialog/actions.dart:52-53 -->

Rendered names are sanitised for filesystem safety: `/`, `:`, `\` and NUL are replaced
with `_` (`:` matters because it is a path separator under the classic Mac OS layer and
still shows up as `/` in Finder, and a raw `1/250` shutter-speed rendering would otherwise
create a subdirectory), and leading/trailing whitespace and dots are stripped.
<!-- evidence: lib/models/rename_rule.dart:128-134 -->

### Presets

Four presets ship with the app, selectable from the dialog's preset list. Rendered
against a file shot 2026-08-26 14:07:33 with base name `DSC_0431` and no metadata
collision (`{seq}` = 1):

| Preset | Template | Example rendering |
|---|---|---|
| Date & time | `{YYYY}-{MM}-{DD}-{hh}-{mm}-{ss}` | `2026-08-26-14-07-33` |
| Compact | `{YYYY}{MM}{DD}_{hh}{mm}{ss}` | `20260826_140733` |
| Camera-style | `IMG_{YYYY}{MM}{DD}_{hh}{mm}{ss}` | `IMG_20260826_140733` |
| Date + sequence | `{YYYY}-{MM}-{DD}_{seq}` | `2026-08-26_1` |
<!-- evidence: lib/models/rename_rule.dart:43-48 -->

"Date & time" is also the default template a fresh dialog opens with.
<!-- evidence: lib/models/rename_rule.dart:41 -->
<!-- evidence: lib/views/rename_dialog/rename_dialog.dart:33-35 -->

Editing the template text (or inserting a variable chip) while a preset is selected
switches the selection to a pseudo-preset labelled `Custom...`; only a custom rule is
remembered per folder, and reopening the dialog on a folder that was last renamed with a
custom rule restores that exact template.
<!-- evidence: lib/views/rename_dialog/rename_dialog.dart:61-70 -->
<!-- evidence: lib/views/rename_dialog/rename_dialog.dart:101-113 -->

### Dialog and live preview

The dialog is two panes: preset picker, rule text field and variable chips on the left
(`RuleEditor`), a live preview list on the right (`RenamePreviewList`). Opening the dialog
draws five random items from the current folder and reads their EXIF once; every
keystroke in the rule field re-renders those five preview rows against the already-read
metadata, without re-reading EXIF.
<!-- evidence: lib/views/rename_dialog/rename_dialog.dart:72-84 -->
<!-- evidence: lib/views/rename_dialog/preview_list.dart:98-107 -->

A "Re-roll" control redraws a fresh set of five random items with a fresh metadata read.
Each preview row shows the current filename struck through, an arrow, the rendered new
base name plus extension, a badge for each sibling extension the item carries (so the
user can see that a RAW+JPG pair moves together before committing), and a "no camera tag"
badge when the template references `{camera}` and this particular item has none.
<!-- evidence: lib/views/rename_dialog/preview_list.dart:98-116 -->

The Run Rename button is disabled whenever the current template has a validation error
(unknown variable, empty template, or a template that renders to an empty string), so an
invalid rule cannot be applied.
<!-- evidence: lib/models/rename_rule.dart:73-87 -->
<!-- evidence: lib/views/rename_dialog/actions.dart:52-53 -->

The dialog only applies to the whole folder — there is no per-item selection, and the
footer states the item count applies to the whole folder.
<!-- evidence: lib/views/rename_dialog/rename_dialog.dart:200 -->
<!-- evidence: lib/views/rename_dialog/actions.dart:29-34 -->

### Where EXIF comes from, and its cost

EXIF is read once per photo item, not once per file: `PhotoItem.bestFileToLoad` picks the
file EXIF is read from, and that single reading is applied to every sibling file in the
group (RAW, JPG, sidecar) when the rename executes.
<!-- evidence: memory.md AD-017 -->
<!-- evidence: lib/providers/app_state.dart:547-564 -->

`bestFileToLoad` prefers a `.jpg`/`.jpeg`/`.png` sibling over the RAW file when one
exists, falling back to the first file this app can decode, and finally to the first file
in the group if nothing is decodable.
<!-- evidence: lib/models/supported_photo_formats.dart:18-22 -->
<!-- evidence: lib/models/supported_photo_formats.dart:45-61 -->

The user-visible consequence: for a RAW shot with no JPG sibling, EXIF is read straight
from the RAW file's own header via the `exif` package, run off the UI isolate since
parsing a RAW header means scanning megabytes. If that read fails or the RAW format's
header is not one the `exif` package parses, the item's metadata is `null` and every EXIF
token in the template renders empty for it — the date/time tokens alone still resolve,
falling back to the file's modification time.
<!-- evidence: lib/services/rename/exif_metadata_service.dart:66-75 -->
<!-- evidence: lib/models/rename_rule.dart:96 -->

EXIF is read in chunks of 500 paths so a large folder still reports incremental progress
rather than blocking on one giant batch; the dialog reports this as "讀取 EXIF
*done/total*…" in its status line.
<!-- evidence: lib/services/rename/exif_metadata_service.dart:18-42 -->
<!-- evidence: lib/services/rename/rename_coordinator.dart:86-91 -->

### Applying the rename

Naming policy and file I/O are two separate functions: `planRenames` computes every move
without touching disk, and only `applyRenames` performs the actual `File.rename` calls.
`planRenames` is pure, so the whole collision-avoidance policy is testable without photos
on disk.
<!-- evidence: memory.md AD-016 -->
<!-- evidence: lib/services/rename/rename_service.dart:32-41 -->

Renames execute serially, one plan at a time. `File.rename` is a same-volume metadata
operation, so parallelism buys nothing and would turn the planner's collision avoidance
into a race.
<!-- evidence: lib/services/rename/rename_service.dart:143-146 -->

**Collision rule, as implemented.** Items are grouped by what they would render to at
`{seq}` = 1; every item inside a group that collides on that rendered name gets a
deterministic 1-based sequence number, assigned by sorting the group's item ids and
taking each item's position — so the numbering does not depend on scan order. If the
resulting candidate name still collides with a name already in the folder (or a name
already claimed earlier in this same batch), a numeric suffix `-1`, `-2`, ... is appended
until the name is free. An item whose final rendered name is identical to its current
name is dropped from the plan — a no-op rename does not get an undo-log entry.
<!-- evidence: lib/services/rename/rename_service.dart:58-85 -->

All files belonging to one item — the RAW, a JPG sibling, and an AppleDouble sidecar
(`._<name>`) if one exists in the folder — are renamed to the same new base name with
their own original extensions preserved, so a RAW+JPG pair or a RAW+sidecar pair never
splits apart during a rename.
<!-- evidence: lib/services/rename/rename_service.dart:87-105 -->

Every move is appended to `.halcyon_rename_log.jsonl` in the folder as it lands (an
append-only, one-JSON-object-per-line journal rather than a rewritten array, so a crash
mid-batch does not corrupt or lose earlier moves), which is what backs the dialog's
"Undo" action — the log is replayed backwards and then deleted.
<!-- evidence: lib/services/rename/rename_service.dart:123-192 -->
<!-- evidence: lib/services/rename/rename_service.dart:194-244 -->

Because `.halcyon_status.json` (star/trash marks, last-viewed id) is keyed by filename,
the coordinator remaps every changed key in that store immediately after a rename batch
completes, and again (in reverse) after an undo — otherwise every mark would be silently
orphaned under a filename that no longer exists.
<!-- evidence: memory.md G-011 -->
<!-- evidence: lib/services/rename/rename_coordinator.dart:136-141 -->
<!-- evidence: lib/services/rename/rename_coordinator.dart:182-189 -->

The rename dialog itself is unreachable for a folder Halcyon has determined it cannot
write to — the dialog's own footer states this.
<!-- evidence: lib/views/rename_dialog/actions.dart:29-34 -->

### Limitations

- A field with no corresponding EXIF tag — or a photo whose EXIF could not be read at all
  — renders as an empty string in that position of the filename; the template does not
  fall back to a different field.
  <!-- evidence: lib/models/rename_rule.dart:107-119 -->
- EXIF for a RAW-only item (no JPG sibling) depends entirely on the `exif` package's
  ability to parse that RAW file's own header; there is no RAW-specific EXIF parser in
  this path, and a RAW format the package cannot parse yields no metadata for that item
  rather than a partial read.
  <!-- evidence: lib/services/rename/exif_metadata_service.dart:66-93 -->
