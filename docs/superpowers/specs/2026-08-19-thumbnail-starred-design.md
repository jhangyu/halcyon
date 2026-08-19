# Thumbnail Starred — Design Spec

Date: 2026-08-19
Status: approved by user, ready for implementation

## Goal (end state, one sentence)

A `Thumbnail Starred...` entry in the sidebar's popup menu exports every starred
photo as a JPEG whose long edge is at most 2048px, preserving aspect ratio and
all EXIF metadata, into a user-chosen folder, with progress shown in the status
line.

## Decisions (frozen — only the user may change these)

| Decision | Choice | Rationale |
|---|---|---|
| Resampling + encoding | Platform-native ImageIO (`CGImageSourceCreateThumbnailAtIndex`) + JPEG q0.85 | Reuses the pipeline the app already ships; handles RAW/HEIC/JPEG and EXIF orientation in one call; zero new dependencies |
| Cross-platform strategy | Extend the existing `halcyon/thumbnail` platform channel with a new `export` purpose | Dart side stays platform-agnostic; future Android (`BitmapFactory`) / Windows (WIC `IWICBitmapScaler`) branches are one native `case` each, no Dart or UI change |
| Files per starred item | One — source file picked by the existing `SupportedPhotoFormats.bestFileToLoad` (prefers JPEG/HEIC over RAW) | An item with `.dng` + `.jpg` siblings is one photo, so it gets one upload-ready thumbnail |
| Source long edge already < 2048 | Keep original dimensions, re-encode | `kCGImageSourceThumbnailMaxPixelSize` caps but never upscales, so this needs no extra code; upscaling adds no detail |
| Output filename collision | Overwrite | Re-running the export refreshes the destination folder |
| EXIF | Preserve everything (Exif/GPS/TIFF/IPTC), with `Orientation` forced to 1 | User requirement |
| Progress UI | Existing status line (`lib/views/status_line.dart`) | No new widget |
| Concurrency | Bounded worker pool, 4 in flight | Native handler already dispatches to a concurrent queue, so parallel `invokeMethod` calls genuinely run in parallel |

## Architecture

### 1. Native — `macos/Runner/AppDelegate.swift`

Add purpose `"export"`. It branches **before** the JPEG raw-bytes passthrough and
before the DNG embedded-preview passthrough (both are gated on
`purpose == "preview"`, so the new purpose bypasses them by construction — but
the implementer must verify that, not assume it).

```swift
let thumbOptions: [CFString: Any] = [
  kCGImageSourceCreateThumbnailFromImageAlways: true,   // NOT ...IfAbsent
  kCGImageSourceThumbnailMaxPixelSize: targetSize,      // 2048, caps only
  kCGImageSourceCreateThumbnailWithTransform: true,     // bakes EXIF rotation into pixels
  kCGImageSourceShouldCacheImmediately: true,
]
```

`FromImageAlways` is required: with `IfAbsent`, ImageIO returns a file's small
embedded thumbnail (often 160px) instead of a 2048px downscale.

Encoding must switch from `NSBitmapImageRep.representation(using: .jpeg)` to
`CGImageDestination`, because the former cannot carry metadata:

```swift
let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
var out = props
out[kCGImagePropertyOrientation]  = 1                  // pixels already rotated
out[kCGImagePropertyPixelWidth]   = cgImage.width
out[kCGImagePropertyPixelHeight]  = cgImage.height
out[kCGImageDestinationLossyCompressionQuality] = 0.85
CGImageDestinationAddImage(dest, cgImage, out as CFDictionary)
```

Forcing `Orientation = 1` is not optional: leaving the source's tag (e.g. 6) on
already-rotated pixels makes every viewer rotate a second time.

The existing `preview` and `sidebarThumbnail` behaviour must not change.

### 2. Dart channel — `lib/services/native_thumbnail_service.dart`

Add `ImageRequestPurpose.export(targetSize: 2048, platformValue: 'export')`.
No other change; `getThumbnail` already accepts a purpose and returns
`Uint8List?`.

### 3. New service — `lib/services/thumbnail_export_service.dart`

```dart
class ThumbnailExportOutcome {
  const ThumbnailExportOutcome({required this.exportedCount, required this.failures});
  final int exportedCount;
  final List<String> failures;   // "<filename>: <error>", same shape as RecycleOutcome
}

typedef ExportBytesFetch = Future<Uint8List?> Function(String path);

class ThumbnailExportService {
  ThumbnailExportService({ExportBytesFetch? fetchBytes});

  Future<ThumbnailExportOutcome> exportStarred(
    List<PhotoItem> items,
    Directory dest, {
    void Function(int done, int total)? onProgress,
  });
}
```

Behaviour:
- Filter to `PhotoStatus.starred`; pick one source file per item via
  `SupportedPhotoFormats.bestFileToLoad(item.files)`.
- Fetch bytes through the injected `fetchBytes` (default:
  `NativeThumbnailService.getThumbnail(path, purpose: ImageRequestPurpose.export)`).
  The injection seam is what makes this unit-testable without a platform.
- Write to `<dest>/<basenameWithoutExtension>.jpg`, overwriting.
- Bounded concurrency of 4, marked with a `ponytail:` comment naming the
  ceiling (RAW full decode can cost hundreds of MB per image).
- A failure on one item is recorded in `failures` and does not abort the batch.
- `onProgress` fires on each completion; because work is concurrent, completion
  order is not source order, so callers must report counts, not filenames.
- If `dest` does not exist, return an empty outcome without throwing.

### 4. State — `lib/providers/app_state.dart`

```dart
Future<void> exportStarredThumbnails(String destPath);
```

- Calls the service, passing an `onProgress` that emits
  `showStatus(StatusMessage('縮圖中 *3/24*…'))`. `StatusLine._show` cancels and
  restarts its 2.5s timer on every new message, so the line stays visible for
  the whole run.
- On completion: `已匯出 *23* 張縮圖到 *<folder name>*` with
  `revealPath: destPath` (gives the existing 「顯示」 button). If `failures` is
  non-empty, append the failure count to the message — a silently failed export
  is indistinguishable from a broken app.
- Does not reload the current folder: source files are untouched.

### 5. UI — `lib/views/sidebar_view.dart`

Two edits to the existing popup menu, no new widget:

- `itemBuilder`: insert a `PopupMenuItem` between the `move` item and the
  `PopupMenuDivider` that precedes `delete`. Label `Thumbnail Starred...`,
  `enabled: hasStarred`, same `actionTextColor` styling as copy/move.
- `onSelected`: an `else if` alongside copy/move —
  `getDirectoryPath(confirmButtonText: 'Export Here')`, then
  `state.exportStarredThumbnails(dest)` when non-null.

The menu value MUST be a shared `const` referenced by both `itemBuilder` and
`onSelected` (and by the widget test). A hardcoded string mismatch between the
two silently disables the button and a test that also hardcodes the string
cannot catch it — this has happened in this codebase before.

## Testing

Unit — `test/thumbnail_export_service_test.dart` (fake `fetchBytes`, temp dir):
1. Only starred items are exported; unmarked/trashed are not.
2. An item with `.dng` + `.jpg` siblings produces exactly one output file, from
   the JPEG source.
3. An existing destination file is overwritten.
4. A fetch that returns null / throws lands in `failures` and the remaining
   items still export.
5. `onProgress` is called once per item with a monotonically increasing `done`
   and the correct `total`.

Widget — added to `test/sidebar_view_test.dart`:
6. The menu item exists with the expected label, and is disabled when no item is
   starred.
7. Routing: invoking `onSelected` with the shared constant reaches the export
   path. Call `onSelected` directly — tapping a `PopupMenuItem` hangs under
   `FakeAsync` in this codebase.

Native (no unit test) — live proof, required before sign-off:
8. Run the app, star a JPEG and a RAW, export to a temp folder, then verify with
   `sips -g pixelWidth -g pixelHeight <out>` that the long edge is exactly 2048
   (or unchanged if the source was smaller) and the aspect ratio matches the
   source, and with `exiftool` / `sips -g all` that EXIF (including camera make/
   model and GPS if present) survived and `Orientation` is 1 with the image
   visually upright.

## Out of scope

- Android / iOS / Windows native branches (the channel contract is designed for
  them; no implementation this round).
- A cancel button, or any dialog-based progress UI.
- Export quality / max-edge settings in the Options dialog.
- HEIC or WebP output.
- Stripping GPS for privacy (the user explicitly asked to keep all EXIF).

Check applied: for each out-of-scope item, "if it never ships, is the end state
still reachable?" — yes for all of them.

## Known risk

`processStarred` has an unrelated open bug (sidecar files are deleted at the
destination but never copied). This export path does not touch sidecars at all,
so it is unaffected; do not fix that bug in this round.
