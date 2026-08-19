---
date: 2026-08-19
title: "Task 17 — AppDelegate.swift error hardening: evidence notes"
---

Owner: native (team halcyon-techdebt). File touched: `macos/Runner/AppDelegate.swift` only.

## What changed

| Site | Before | After |
|---|---|---|
| `applicationDidFinishLaunching` | `as! FlutterViewController` | `guard let ... as?` + `NSLog`, app stays alive |
| RAW CIRAWFilter path (`getFastThumbnail`) | `createCGImage(from: ciImage.extent)` unchecked | `AppDelegate.renderCGImage` with extent validation + decoded-byte budget; `.tooLarge` → `FlutterError("IMAGE_TOO_LARGE")`, `.invalid` → falls through to ImageIO, ending in the existing `LOAD_FAILED` |
| `createFullSizeImage` | same unchecked render | same helper; on failure returns the *unrotated* original instead of nil (mis-rotated preview beats no preview) |
| EXIF orientation | `properties[kCGImagePropertyOrientation] as? Int32`, passed straight to CoreImage | `AppDelegate.exifOrientation(from:)` → `sanitizedExifOrientation` clamps to 1...8, else 1 |
| `NO_EMBEDDED_PREVIEW` details | `Int(readDngOrientation(url:))` raw UInt32 | clamped through `sanitizedExifOrientation` before crossing the channel |

## Evidence

### 1. Release build (AC 3)

```
$ flutter build macos --release      # exit 0
✓ Built build/macos/Build/Products/Release/Halcyon.app (44.3MB)
```

### 2. Live error-path run of the hardened build (AC 4)

Folder `scripts/tmp/t17` (deleted after the run) held: `bad.arw` (3 MB /dev/urandom),
`bad2.arw` (200 KB /dev/urandom), `bad.dng` (8-byte TIFF header only), `zero.jpg`
(0 bytes), `trunc.jpg` (first 120 bytes of a real JPEG), `good.jpg` (valid).
Run twice; the second (re-)run drove the release binary directly for 25 s with its
perf driver pointed at that folder:

```
$ HALCYON_PERF_DIR=.../t17c perl -e 'alarm 25; exec @ARGV' .../Halcyon.app/Contents/MacOS/Halcyon
EXIT=142     # SIGALRM at 25 s -> survived; a crash would exit 133/134/139
```

(Note: `timeout(1)` does not exist on this machine — an earlier attempt exited 127
and produced empty logs. `perl -e 'alarm N'` is the working substitute.)

Result: **process alive until the alarm, zero entries in `~/Library/Logs/DiagnosticReports`**.
Native log shows every bad file taking an explicit error path:

```
PERFNATIVE|...|dngPassthrough.miss|bad.dng|dur=41
PERFNATIVE|...|result.dispatch|bad.dng|nativeTotal=150|noEmbeddedPreview
PERFNATIVE|...|handler.enter|bad2.arw|preview          # -> CIFilter/CIRAWFilter path
flutter: Failed to get native thumbnail: 'Cannot read image'.   # LOAD_FAILED, graceful
flutter: PERF|...|rawDecode.fail|bad|dur=27381|DngDecodeException(100011)
flutter: PERF|...|channel.preview|trunc|bytes=120 ...   # truncated/zero JPEG passthrough, no crash
```

### 3. Guard-fires probe (`swiftc`, replicas of the new predicates)

```
A. orientation clamp: 0->1  9->1  4294967295->1  nil->1  6->6
B. infinite-extent image: extent=(-8.98e+307, ..., 1.79e+308, 1.79e+308) guard=invalid
C. 400000x400000 (640GB RGBA8):                            guard=tooLarge
```

### 4. Honest negative results (do not overclaim)

- Calling `createCGImage` on an **infinite** extent *without* the guard returned `nil`
  on this macOS build — it did **not** trap. The extent guard is therefore
  defence-in-depth plus an allocation bound, not a demonstrated crash fix.
- `oriented(forExifOrientation: 9999)` also survived (extent unchanged). The clamp is
  correctness/contract alignment with the Dart side, not a demonstrated crash fix.
- The genuine failure mode the budget stops (multi-GB allocation from a corrupt
  header) was **not** demonstrated by actually attempting it: doing so on the shared
  machine would swap/OOM while two other team members are working. Reasoned bound only.
- `as? Int32` vs `as? NSNumber` on a CFNumber: both resolve to 6 (probe 2), so the
  cast change is behaviour-preserving for valid values, not a latent-bug fix.

## Memory-cap evaluation (>100 MB RAW)

A **file-size** cap at 100 MB was rejected: current medium-format and high-MP bodies
(GFX100, A7RV lossless, IQ4) routinely produce 100–250 MB RAWs, so the cap would reject
files the app exists to triage — a functional regression dressed as a safety fix.

What was implemented instead is a **decoded-pixel budget**: `maxDecodedPixelBytes =
1.5e9` (≈375 MP as RGBA8). It bounds the thing that actually allocates (the CIContext
render target) rather than the thing that does not (file size on disk — an 8 MB corrupt
header can claim a 640 GB extent, as probe C shows). No shipping camera comes near the
bound, so no legitimate file is affected.

Parking-lot (not done, needs a product call): the CIRAWFilter path renders at **full
sensor resolution and ignores `targetSize`**, unlike every other branch in
`getFastThumbnail`. Downscaling it to `targetSize` before `createCGImage` would cut
peak RAW-preview memory by ~10x, but it changes the resolution the viewer receives —
a visual/quality trade-off that is the user's to make, so it was left alone.
