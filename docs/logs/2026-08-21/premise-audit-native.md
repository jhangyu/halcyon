# Premise Audit — macOS Native Layer & Cross-Platform Substitutes

Date: 2026-08-21. Scope: `macos/Runner/AppDelegate.swift`, `macos/Runner/DngPreviewExtractor.swift`,
`macos/Runner.xcodeproj/project.pbxproj`, `macos/Podfile`, vs claims in
`docs/logs/2026-08-20/cross-platform-port-inventory.md`. Read-only.

## 結論先行 (FALSE / UNVERIFIABLE / shipping defects only)

1. **FALSE (overstated) — row 19, "iOS 替代: 同 macOS（... Swift 碼可共用）"**. The
   RAW-decode fallback path in `getFastThumbnail` re-encodes the final `CGImage` via
   `NSBitmapImageRep` (`macos/Runner/AppDelegate.swift:501-502`), which is AppKit-only
   and has **no iOS equivalent** (iOS has no `NSBitmapImageRep`; would need `UIImage`/
   `CGImageDestination`). `ImageIO`/`CoreImage` calls in the same function genuinely are
   iOS-available, but "Swift 碼可共用" is not true end-to-end for this function — only
   for the parts that avoid AppKit. Contrast with the export path (line 254-300), which
   is deliberately AppKit-free (see finding 2) and where "同 macOS" really does hold.

2. **UNVERIFIABLE→resolved FALSE — task's own premise "UTType requires macOS 11 vs
   10.15 deployment target = shipping defect"**. This is not a live bug: the code never
   uses `UTType` at all. `AppDelegate.swift:256-258` explicitly avoids it and uses the
   literal string `"public.jpeg"` *because* `UniformTypeIdentifiers` needs macOS 11 and
   the deployment target is 10.15 — the comment documents the exact tradeoff. Deployment
   target confirmed 10.15 in three places: `macos/Runner.xcodeproj/project.pbxproj:575,
   657,707` (`MACOSX_DEPLOYMENT_TARGET = 10.15;`) and `macos/Podfile:1`
   (`platform :osx, '10.15'`). No minimum-OS conflict exists; this premise, if it was
   floating around as a claim to build on, is false.

3. **Naming imprecision, not a functional error** — document/table row 19 and code
   comments (`AppDelegate.swift:354,384,444`) call the RAW decode path "CIRAWFilter",
   but the actual API invoked is `CIFilter(imageURL: url, options: nil)`
   (`AppDelegate.swift:449`), the older/generic RAW-aware `CIFilter` initializer — not
   the explicit `CIRAWFilter` class (macOS 12+/iOS 15+, which the 10.15 deployment
   target could not use anyway). Does not change conclusions but the document's API
   name is not literally accurate.

No third *factual* error of the "hardcoded path" / "never bundled" severity was found.
Everything else checked below is TRUE, including the memory/targetSize claim and the
"pure byte parsing" claim.

---

## Claim-by-claim table

| Claim | Verdict | Evidence | If FALSE, what's actually true |
|---|---|---|---|
| RAW/JPEG preview extraction (`getFastThumbnail`) spans `AppDelegate.swift:302-516`, uses `CGImageSource` + RAW-aware `CIFilter` | TRUE (name nuance) | `AppDelegate.swift:302` (`private func getFastThumbnail`) … `516` (closing brace); `CGImageSourceCreateWithURL` at 417, `CIFilter(imageURL:...)` at 449 | RAW decode API is `CIFilter(imageURL:options:)`, not the class literally named `CIRAWFilter` (see finding 3) |
| Thumbnail export / JPEG encoding at `AppDelegate.swift:254-300` via `CGImageDestination` | TRUE | `encodeExportJpeg` 254-285 uses `CGImageDestinationCreateWithData`/`CGImageDestinationAddImage`/`CGImageDestinationFinalize` (259,282,283); `makeExportJpeg` 291-299; `EXPORT-CORE-END` marker at 300 | — |
| `ImageRequestPurpose` has exactly two sizes: `sidebarThumbnail`@200, `preview`@2800 | **FALSE** | `lib/services/native_thumbnail_service.dart:5,12,18` — there is a third case, `export(targetSize: 2048, ...)`, handled by its own AppDelegate branch (`AppDelegate.swift:329-345`) | Three sizes exist: 200 / 2800 / 2048 |
| Preview size (2800px) is "an honest cap, not a sentinel override" | TRUE | `native_thumbnail_service.dart:6-7`: "Native RAW preview extraction honours this value as an honest cap (AppDelegate.swift no longer overrides it with an 8000px sentinel)" — code comment self-documents the historical bug and its fix | — |
| `TrashService` uses `FileManager.trashItem` | TRUE | `AppDelegate.swift:121` — `try FileManager.default.trashItem(at: url, resultingItemURL: nil)` | — |
| Open With uses `NSApplication.application(_:openFile:)`, is push-only (native → Dart) | TRUE | `AppDelegate.swift:91-94` (`openFile:`), `96-99` (`open urls:`); `openWithChannel` (line 80-82) has **no** `setMethodCallHandler` call anywhere in the file (verified via full-file grep) — only `invokeMethod` at 85/103, confirming push-only | — |
| `DngPreviewExtractor.swift` is "pure TIFF byte parsing", could be rewritten in Dart with no native dependency | TRUE | 348 lines total; imports `Foundation` + `ImageIO` (line 2) but the `ImageIO` import is **unused dead code** — no `CGImage*`/`CIImage`/`CIFilter` symbol appears anywhere in the file (verified by grep); all work is `Data` byte-offset math via the `TIFFReader` struct (lines 252-348) | A Dart rewrite would need to reimplement: big/little-endian TIFF header + IFD walking (`readIFD`, `values`, `u16`/`u32`), SubIFD (0x014A) traversal, DefaultCropSize (0xC620) matching logic, strip offset/bytecount bounds-checked slicing, and a hand-rolled JPEG APP1/Exif-orientation injector/scanner (`injectExifOrientation`, `jpegHasExifOrientation`, `tiffDataHasOrientation`, lines 157-247) — non-trivial but genuinely no ImageIO/CoreGraphics dependency to replace |
| Note: `CIRAWFilter`/RAW decode ignores `targetSize`, always decodes full resolution (~10x memory tradeoff) | TRUE | `AppDelegate.swift:449` — `CIFilter(imageURL: url, options: nil)`; `options` is `nil`, so no size-limiting key is passed. `targetSize` is only honored by the *embedded-thumbnail* path (`kCGImageSourceThumbnailMaxPixelSize` at lines 431/481), never by the CIFilter RAW decode itself | — |
| Note: thumbnail export needs `UTType`, which requires macOS 11, vs 10.15 deployment target — shipping defect | **FALSE as a live defect** | See finding 2 above: code deliberately avoids `UTType`, uses `"public.jpeg" as CFString` instead (`AppDelegate.swift:256-258`) precisely to stay 10.15-compatible; deployment target 10.15 confirmed in `project.pbxproj:575,657,707` and `Podfile:1` | No `UTType`/min-OS conflict exists in current code |
| Every macOS-only framework/API actually imported or called — enumerate, and which are iOS-portable | see below | — | — |
| No native capability in `AppDelegate.swift` exists that the document's table omits | TRUE | 4 channels registered: `halcyon/thumbnail` (25-49, method `getThumbnail`), `halcyon/trash` (27,51-65, method `trashFile`), `halcyon/exif` (67-78, method `readBatch`), `halcyon/open_with` (80-86, no incoming handler, push-only `invokeMethod("openFile", ...)`). All 4 appear in the document's table (rows 19,22,23,24); no extra channel/method found | — |

### Framework/API enumeration (Claim A requirement)

Imports at top of file: `Cocoa` (line 1, brings in AppKit+Foundation), `CoreImage` (2),
`FlutterMacOS` (3), `ImageIO` (4).

| API | Where used | macOS-only or also on iOS |
|---|---|---|
| `NSApplication` + `application(_:openFile:)` / `application(_:open:)` | 91-99 | **macOS-only** (AppKit). iOS has no `NSApplication`; equivalent is `UIApplication`/`application(_:open:options:)` — different type, not shared code |
| `NSBitmapImageRep` | 501-502 (JPEG re-encode of decoded RAW/preview) | **macOS-only** (AppKit). No iOS equivalent (`UIImage`/`CGImageDestination` would be needed instead) |
| `FileManager.trashItem(at:resultingItemURL:)` | 121 | **macOS-only**. iOS `FileManager` has no system Trash API (no Trash concept in the sandbox) |
| `FlutterMacOS` framework / `FlutterMethodChannel`, `FlutterViewController`, `FlutterResult`, `FlutterError`, `FlutterStandardTypedData` | 21,25-86 throughout | **Package is macOS-only** (`FlutterMacOS.framework`); iOS uses the separate `Flutter.framework` with an analogous but not identical import. Channel *logic* ports near-verbatim, the *import line* does not |
| `CGImageSource*`, `CGImageDestination*` (ImageIO) | 165-166,237-244,254-300,417-485,518-541,567-568 | Available on iOS (ImageIO is cross-Apple-platform) |
| `CIFilter`, `CIImage`, `CIContext`, `CGColorSpace` (CoreImage/CoreGraphics) | 192-213,449-454,531 | Available on iOS |
| `DispatchQueue`, `NSLock`, `ProcessInfo`, `NSNumber`, `NSMutableData`, `NSLog` | throughout | Foundation/Dispatch — cross-platform, available on iOS |

Bottom line for the document's "iOS can reuse the macOS Swift code" premise: **true for
the ImageIO/CoreImage decode core and for the export path (which is explicitly written
AppKit-free, per the file's own `EXPORT-CORE-BEGIN/END` comment at lines 219-222)**, but
**not true as stated for**: Open With (`NSApplication` has no iOS analog — the document
already correctly lists a different iOS API for this row, so no error there), the
general preview/thumbnail JPEG re-encode step (`NSBitmapImageRep`, AppKit-only), and
Trash (`FileManager.trashItem`, macOS-only — again the document already lists a
different Android/iOS strategy for this row, so no error there either). The one row
that overclaims shared code is row 19 (thumbnail decode), addressed in finding 1 above.

---

## Counts

- Claims checked: 10 (table rows above) + framework enumeration cross-check.
- TRUE: 7 (getFastThumbnail line range/APIs with naming nuance counted as TRUE, export
  encode lines, TrashService, Open With push-only, DngPreviewExtractor purity,
  CIFilter/targetSize memory note, channel-completeness/no-omission).
- FALSE: 2 (`ImageRequestPurpose` two-sizes claim; UTType/macOS-11 shipping-defect
  premise) — plus 1 overstated/imprecise claim flagged as a nuance (row 19 "Swift 碼可
  共用" for the full thumbnail path; naming "CIRAWFilter" vs actual `CIFilter(imageURL:)`).
- UNVERIFIABLE: 0.

## Not verified / out of scope

- Did not re-check `dng_bindings.dart:339` / `DNG_DEV_FALLBACK` gating or the pbxproj
  "Embed DNG Native Dylib" phase's current state — both explicitly out of my assigned
  area and already covered/caveated by the task brief (a teammate is live-editing the
  pbxproj; at time of read the phase was still present at
  `macos/Runner.xcodeproj/project.pbxproj:249,417-429`, consistent with the document's
  prior correction, not re-litigated here).
- Did not check Windows/Android/iOS build artifacts for portability of ImageIO/CoreImage
  usage beyond static API-availability facts (no device/SDK testing performed, read-only
  static analysis only).
