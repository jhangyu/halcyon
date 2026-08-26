## Halcyon

Halcyon is a Flutter desktop application for photographers to triage RAW and JPG photo
folders: browse with the keyboard, mark photos star/trash, then batch-copy or move the
starred files.
<!-- evidence: lib/views/main_screen.dart:104-129 keyboard shortcut handler; lib/services/library/photo_file_actions.dart batch copy/move -->

![Halcyon main triage view](docs/images/halcyon_main_triage_view.png)

*The main triage screen, macOS 15.6.1: the sidebar lists the folder's 628 photos, and
the viewer fills the rest of the window with no app bar — only the star and trash
buttons float over the image. Arrow keys move; `S` and `X` mark.*

![Rename by EXIF dialog](docs/images/halcyon_exif_rename_dialog.png)

*The Rename by EXIF dialog on the same folder. The left pane holds the presets and the
editable rule template with live validation; the right pane previews five randomly
sampled files, showing each current filename above the name it would be renamed to.*

### The name

*Halcyon* and *Ceyx* are both kingfisher genera. In Greek myth, Alcyone and Ceyx were
transformed into kingfishers — the two repositories are named as a pair: Ceyx the
decoding engine, Halcyon the application built on it.
<!-- evidence: docs/logs/2026-08-26/readme-draft/BRIEFING.md:46-49 (shared framing agreed for both READMEs); ../ceyx/README.md:56-65 "Sister project: Halcyon" section states the same pairing and dependency direction -->

### Why Halcyon

- **Culling is a throughput problem, not a viewing problem.** The photographer's loop is
  look, judge, advance — arrow keys move between photos, `S` stars, `X` trashes, and
  nothing in that loop asks for a dialog or a mouse click. Anything that stalls that loop
  is the whole cost of the tool.
  <!-- evidence: lib/views/main_screen.dart:104-129 arrowLeft/arrowRight/keyS/keyX bound directly to previousPhoto/nextPhoto/markCurrent -->
- **Lineage: FastPictureViewer.** The keyboard-driven marking model — browse and mark
  without leaving the keyboard — is directly inspired by FastPictureViewer, a paid
  Windows tool from an earlier era that photographers still miss.
- **Preview area maximized, chrome minimized.** The main screen has no app bar: the
  `Scaffold` body is a `Stack` with the image viewer positioned to fill the screen and
  only a floating action bar and status line overlaid on top of it.
  <!-- evidence: lib/views/main_screen.dart:48-59 Scaffold with no appBar, body is Stack(children: [_buildKeyboardShortcutHandler(...), StatusLine()]); lib/views/main_detail_view.dart:113-135 Stack with Positioned.fill viewer and a bottom-centered floating action bar -->
  The macOS window's default size is computed directly from a 3:2 preview area plus a
  270px sidebar (`previewWidth = defaultHeight * 1.5`, `defaultWidth = 270.0 +
  previewWidth`), targeting a wide desktop window rather than a narrow one.
  <!-- evidence: macos/Runner/MainFlutterWindow.swift:9-19 -->
  The sidebar itself is user-resizable between 180px and 600px by dragging a handle.
  <!-- evidence: lib/views/main_screen.dart:71-78 -->
- **Decoding is delegated, not reimplemented.** RAW decode belongs to the sister project
  Ceyx; Halcyon is the application that consumes it under real product constraints —
  UI thread responsiveness, tiered preview/full-size loading, and folder-scale batch
  workflows.
- **Honest about scope.** Desktop is the target platform. Mobile and web build targets
  exist and compile, but the interface itself is not adapted for touch.
  <!-- evidence: pubspec.yaml has no platform restriction, standard Flutter multi-platform project; this claim is scope framing, not a measured behaviour -->

### Sister project: Ceyx

Halcyon depends on Ceyx as an ordinary Dart path dependency on Ceyx's `plugin/`
directory:

```yaml
ceyx:
  path: ../ceyx/plugin
```
<!-- evidence: pubspec.yaml:46-47 -->

This is a plain dependency, not a fork or a subproject: Ceyx must exist as a sibling
checkout next to this repository for `flutter pub get` to succeed, and Halcyon's own
comment on the dependency records that it deliberately depends on the `plugin/` package
rather than Ceyx's own `app/`, to avoid dragging that app's harness dependencies into
Halcyon's build.
<!-- evidence: pubspec.yaml:42-47 -->
