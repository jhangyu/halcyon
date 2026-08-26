## Architecture

Halcyon is layered `views/` → `providers/app_state.dart` → `services/` → `models/`,
with dependencies flowing one way only. This section describes how that layering holds
together in the code, the two seams a contributor must not break casually, and where
everything lives on disk.

### Layering and dependency direction

`views/` builds the UI and owns view-local state — keyboard shortcuts, the zoom
transform, dialog scaffolding. It reads `AppState` through the `provider` package and
calls its methods; it is not supposed to know how a photo gets scanned, decoded, or
deleted.

`providers/app_state.dart` defines `AppState extends ChangeNotifier`
(`lib/providers/app_state.dart:61`), the single coordination point for application
logic — folder loading, selection, star/trash marking, settings, and dispatch into the
service layer. It composes its collaborators through constructor injection rather than
constructing them as hardcoded fields:

<!-- evidence: lib/providers/app_state.dart:62-104 -->
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

Each parameter falls back to the real implementation when omitted (for example
`_scanner = scanner ?? PhotoLibraryScanner()`), so production code gets the real
collaborators for free while tests can substitute fakes for any of them.
<!-- evidence: lib/providers/app_state.dart:71-91 -->

This is what makes the coordination layer testable without touching a real filesystem
or a platform channel. `test/providers/app_state_test.dart` builds every `AppState`
under test through a `_testState()` helper that injects a stub `imageLoader` closure
returning fixed bytes instead of decoding a real file, and elsewhere in the same file
injects a `PhotoFileActions(trashFile: (file) async { ... })` that records calls instead
of touching the OS trash, and a `PhotoLibraryScanner` subclass (`_FixedScanner`,
`_ThrowingScanner`) that returns a fixed item list or throws on demand instead of
walking a directory.
<!-- evidence: test/providers/app_state_test.dart:577-597 -->
<!-- evidence: test/providers/app_state_test.dart:420 -->

`services/` implements the actual work — filesystem scanning, status persistence, image
decode/cache, file operations, EXIF/rename, and the two platform bridges — and is
forbidden from reaching back up into `views/` or `AppState` directly; it is called, it
does not call back except through the callback/supplier parameters `AppState` hands it
explicitly (see the `RenameCoordinator` note below). `models/` holds pure data shapes
and pure functions with no I/O — `PhotoItem`, the format registry, and `RenameRule`'s
template rendering — and is not supposed to import from `services/` or `views/`.

**The reverse-data-flow hazard.** `docs/sop/memory.md` G-010 records that `main_detail_view.dart`
once wrote directly into `AppState`'s public zoom fields from widget build/callback code
(`context.read<AppState>().pointerPosition = event.localPosition` and similar), breaking
the one-way flow — a view mutating provider state outside of a method call. The fix
extracted a dedicated `ZoomController extends ChangeNotifier`
(`lib/views/zoom_controller.dart`), owned and disposed by `MainScreen`, and `AppState`
now carries no zoom fields at all. The current rule: view-local, animation-driven state
(zoom, pointer position, transform matrices) belongs in a view-owned controller, not in
`AppState`; `AppState` holds only state that represents the application's photo-library
model.
<!-- evidence: docs/sop/memory.md G-010 -->

**The four service subfolders.** `services/` is split into four purpose-named
subfolders, not left as a flat directory:

| Folder | Owns |
|---|---|
| `image_pipeline/` | tier-1/tier-2 sliding-window preload, DNG decode integration, image cache bookkeeping (18 files) |
| `library/` | folder scanning, status persistence, file copy/move/trash, star-photo export |
| `rename/` | EXIF-driven rename planning, EXIF metadata reading, the rename coordinator |
| `platform/` | the two macOS `MethodChannel` bridges (Trash, Open With) |

`rename_rule.dart` was reclassified out of `services/` into `models/rename_rule.dart` in
the same reorganisation, because it is pure template-rendering with no I/O and therefore
fits the `models/` definition rather than `services/`.
<!-- evidence: docs/sop/memory.md AD-030 -->

### Seams and invariants

These are the load-bearing constraints in the image pipeline; changing them casually
breaks the tier-1/tier-2 contract described elsewhere in this README.

**The Ceyx integration seam.** DNG full-size decoding — for DNGs with no usable
embedded preview — is delegated to the sister project Ceyx through a typedef, not a
concrete class:

<!-- evidence: lib/services/image_pipeline/dng_decode_contract.dart:30 -->
```dart
typedef DngFullDecoder = Future<DecodedRgba> Function(String path);
```

This seam exists specifically so the image pipeline can be unit-tested against a fake
decoder instead of loading the real native dylib.
<!-- evidence: lib/services/image_pipeline/dng_decode_contract.dart:3-8 -->

Paired with it, `image_source_types.dart` declares a sealed class with exactly three
variants describing the outcome of any image-bytes request: `NativeImageBytes` (encoded
bytes, the happy path), `NativeImageNeedsRawDecode` (a DNG with no embedded preview —
not a failure, a signal to run the real RAW decoder), and `NativeImageFailure` (a
genuine failure). The type is documented as frozen: "Exactly three variants; do not add
a fourth without the squad lead's sign-off."
<!-- evidence: lib/services/image_pipeline/image_source_types.dart:41-87 -->

**Image loading is pure Dart on every platform.** `dartImageLoad`
(`lib/services/image_pipeline/dart_image_loader.dart:17`) is the sole producer of image
bytes; there is no native thumbnail channel on any platform. `docs/sop/memory.md` AD-020 records
the contract behind this: photo behaviour (which files load, what pixels appear, what
deletion does, what export produces) is implemented once in Dart and must produce the
same observable result on every supported platform, with exactly three closed,
non-extensible exceptions where a native bridge remains: system Trash (macOS/Windows
native), the Open With transport layer (macOS/Windows/Android/iOS, excluding Linux), and
file association registration (Windows/macOS). The document states this list is closed
— no new platform divergence may cite these three as precedent.
<!-- evidence: docs/sop/memory.md AD-020 -->

**Single-owner invariants.** Two classes each hold exactly one piece of tier-2 state so
that invariant can be reasoned about and tested in one place instead of drifting across
call sites:

- `TierTwoRegistry` (`lib/services/image_pipeline/tier_two_registry.dart:26`) is the
  single holder of tier-two *readiness* bookkeeping — which ids have a full-size cache
  entry, which payload object it was decoded for, and whether that decode has failed.
- `TierTwoScheduler` (`lib/services/image_pipeline/tier_two_scheduler.dart:58`) is the
  single holder of tier-two *scheduling* — the ±2 window, the 250ms navigation debounce,
  and the serialized decode queue.

`docs/sop/memory.md` AD-027 and AD-028 record why these were split into two classes rather than
one: before the split, two review-flagged bugs (a stale readiness flag, and a
`containsKey` check that returned true for still-pending entries) were guarded only by
comments; pulling the four readiness containers into their own class made them testable
in isolation, and keeping scheduling in a separate third class means merging the two
back together would silently re-couple state and timing again.
<!-- evidence: docs/sop/memory.md AD-027 -->
<!-- evidence: docs/sop/memory.md AD-028 -->

**Native bridges.** `macos/Runner/AppDelegate.swift` registers exactly two
`MethodChannel`s — verified by `grep -n "FlutterMethodChannel(name:" macos/Runner/AppDelegate.swift`,
which returns two matches, `halcyon/trash` (line 23) and `halcyon/open_with` (line 42):
<!-- evidence: macos/Runner/AppDelegate.swift:23,42 -->

```dart
FlutterMethodChannel(name: "halcyon/trash", ...)
FlutterMethodChannel(name: "halcyon/open_with", ...)
```

`halcyon/open_with` is push-only: native calls into Dart to deliver a file path, and
Dart has no method on this channel to ask native "is anything pending?". The reason is
cold-start timing — at the moment the file arrives, the Flutter engine may not yet have
a Dart handler registered on the channel; a Dart-initiated query in that window would
throw. Flutter's channel implementation buffers a message sent in the native→Dart
direction until the Dart handler registers, so push-only is the reliable direction at
startup. An event arriving before the channel object itself exists is held in a
`pendingOpenFile` variable and flushed the moment the channel is created.
<!-- evidence: macos/Runner/AppDelegate.swift:12-49 -->
<!-- evidence: docs/sop/memory.md AD-012 -->

This grep-verification step matters here specifically because of `docs/sop/memory.md` G-017:
this repository's own documentation once described an entire milestone's worth of a
`halcyon/thumbnail` channel and a `NativeThumbnailService` that had already been
deleted, including a stale line-number reference. The recorded rule is to check native
bridge claims against `AppDelegate.swift` with `grep -n "MethodChannel"`, not against
whether the claim reads plausibly.
<!-- evidence: docs/sop/memory.md G-017 -->

**One EXIF orientation table.** `exif_orientation.dart`'s `exifTransformFor` is the
project's only 8-case Orientation-tag lookup table; both the `package:image`-based
export path and the `dart:ui`-based full-size RGBA provider translate through this one
table rather than each encoding their own orientation logic, and both apply rotation
before mirroring, in that fixed order.
<!-- evidence: docs/sop/memory.md AD-024 -->

### Repository layout

An annotated top-level layout — verified against the current tree, not just the
internal directory-map document (see below), which can lag a same-day reorganisation:

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
│   ├── logs/YYYY-MM-DD/       # dated task logs; recorded measurements live here
│   └── sop/                   # untracked internal maintenance docs; absent from a fresh clone
└── README.md
```
<!-- evidence: docs/sop/file_index.md:44-102 -->

**Internal maintenance documents.** Halcyon maintains a set of internal process
documents — architecture decisions and gotchas, task tracking, phase milestones, a
handoff summary, and the test strategy and test-case matrix — under `docs/sop/` in a
working checkout. They are deliberately excluded from version control (git-ignored), so
a fresh clone of this repository will not contain them. Several claims in this README,
including in the sections on the image pipeline and native bridges, draw on them.

Licensing and third-party attribution are covered in [Third-party attribution](#third-party-attribution) at the end of this document.
