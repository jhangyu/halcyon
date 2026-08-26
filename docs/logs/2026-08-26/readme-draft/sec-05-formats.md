## RAW format support and decode routing

Two separate questions determine whether a photo shows up and how it gets turned into
pixels: which files Halcyon's folder scanner lists at all, and which of those Ceyx, the
sister decoding engine, actually knows how to decode. The two sets are not the same, and
the gap between them matters to anyone pointing Halcyon at a folder of camera originals.

### What Halcyon scans and lists

The sidebar only ever shows a file whose extension is in `SupportedPhotoFormats
.supportedExtensions`, checked once per directory entry during the folder scan:

| Extension | Category |
|---|---|
| `.jpg`, `.jpeg` | Encoded bitstream |
| `.png` | Encoded bitstream |
| `.dng` | RAW |
| `.cr2` | RAW |
| `.nef` | RAW |
| `.arw` | RAW |
| `.rw2` | RAW |
| `.orf` | RAW |

<!-- evidence: lib/models/supported_photo_formats.dart:6-16 -->

`PhotoLibraryScanner.scan` drops any directory entry that fails
`SupportedPhotoFormats.isSupportedPath` before it is even grouped into a `PhotoItem`, so an
unlisted extension never reaches any later stage of the app, decode or otherwise.
<!-- evidence: lib/services/library/photo_library_scanner.dart:11-16 -->

Within a sibling group that shares a basename (e.g. a JPG and a RAW written by the same
shutter press), `SupportedPhotoFormats.preferredLoadExtensions` (`.jpg`, `.jpeg`, `.png`,
in that order) decides which file loads first; a RAW-only group falls back to the first
supported file present.
<!-- evidence: lib/models/supported_photo_formats.dart:18-22,45-61 -->

Historical note: Panasonic `.rw2` was once missing from this whitelist and silently
excluded from the scan; that gap was closed and `.rw2` is present in the current list
above.
<!-- evidence: memory.md G-007 -->

### What Ceyx can decode

Ceyx, not Halcyon, owns RAW decode capability. It routes each file to one of two frontends
by probing the file header — never by matching the extension:

| Route | Container | Frontend |
|---|---|---|
| DNG | TIFF-based, `DNGVersion` tag present in IFD0 | Adobe DNG SDK |
| Generic RAW | CR2, CR3, NEF, ARW, RAF, ORF, RW2, PEF, IIQ, MRW, X3F and other vendor containers | LibRaw, with RawSpeed3 as its preferred backend |

<!-- evidence: ceyx README.md:69-76 -->

Non-TIFF containers are matched on magic bytes (Fujifilm RAF, Minolta MRW, Canon CR3,
Phase One IIQ, Foveon X3F); TIFF-based containers route to the DNG frontend only when
IFD0 carries the `DNGVersion` tag inside the probe window, otherwise they route generic.
<!-- evidence: ceyx README.md:95-105 -->

Once a file is unpacked, Ceyx's GPU dispatch keys on sensor layout, not vendor or
container:

| Layout | Example sensors |
|---|---|
| Bayer 2×2 | the RGGB-family majority |
| X-Trans 6×6 | Fujifilm X-Trans |
| Linear RGB / no CFA | Foveon X3F |

<!-- evidence: ceyx README.md:107-117 -->

### The gap between what's listed and what's decodable

Every RAW extension Halcyon lists (`.dng`, `.cr2`, `.nef`, `.arw`, `.rw2`, `.orf`) is
within Ceyx's documented coverage, but Ceyx documents decoding a substantially larger set
— including Fujifilm RAF (X-Trans sensors), Canon CR3, Pentax PEF, Phase One IIQ, Minolta
MRW and Sigma's Foveon X3F — none of which appear in Halcyon's scan whitelist, so files in
those formats never reach the sidebar at all regardless of Ceyx's capability.
<!-- evidence: lib/models/supported_photo_formats.dart:6-16; ceyx README.md:73-76 -->

A second, more consequential gap sits inside the formats Halcyon *does* list. The only
Ceyx entry point wired into Halcyon's Dart code is the DNG full decoder
(`DngDecoderService.decodeOnWorker`, wrapped as `halcyonDngFullDecoder`); no call site in
`lib/` invokes Ceyx's generic-RAW entry point. The RAW-decode fallback in
`dart_image_loader.dart` is emitted only for `.dng`; a `.cr2`, `.nef`, `.arw`, `.rw2` or
`.orf` file with no usable embedded preview returns a `RAW_NO_EMBEDDED_PREVIEW` failure
instead of reaching a decoder — so today, non-DNG RAW files display only when their
embedded preview is usable, never through a full RAW decode.
<!-- evidence: lib/services/image_pipeline/dng_decode_service.dart:5-34; lib/services/image_pipeline/dart_image_loader.dart:12-15,114-119 -->

### Platform availability of the native decoder

Full RAW decode is not available on every platform Halcyon targets. The build script's
native-library table only builds and packages a Ceyx decoder library for macOS, Windows
and Android; a target absent from that table has no native decoder, and the table
explicitly names iOS, Linux and web as such targets today. On those three platforms, path
two below cannot run — a RAW file with no usable embedded preview has no full-decode
fallback, and only the embedded-preview path (path one) can produce pixels.
<!-- evidence: scripts/build_apps.py:265-290 -->

### The two read paths

Halcyon shows a RAW file's pixels one of two ways, and which one runs is decided before
any GPU work happens. Path two, below, depends on a native Ceyx library that only ships on
macOS, Windows and Android (see "Platform availability of the native decoder" above); on
iOS, Linux and web, path one is the only path that can produce pixels for a RAW file.

**Path one — embedded preview.** Many RAW containers (DNGs from Lightroom Classic or DxO
PureRAW in particular) carry one or more JPEG renditions alongside the actual sensor data.
When a candidate large enough to serve the request is found, Halcyon reads that JPEG
directly — a bounds-checked seek and slice, no image decode of the RAW mosaic at all — and
skips RAW decode entirely.
<!-- evidence: lib/services/image_pipeline/dng_embedded_jpeg_extractor.dart:6-13 -->

**Path two — full RAW decode.** When no preview candidate qualifies, the file is handed to
Ceyx's DNG full decoder instead.
<!-- evidence: lib/services/image_pipeline/dart_image_loader.dart:107-112; lib/services/image_pipeline/dng_decode_service.dart:5-14 -->

The rule that decides between the two paths is a minimum long-edge requirement, and it is
applied unevenly on purpose. The `preview` request purpose (long edge 2800px) on a `.dng`
passes that value as `minLongEdge`: a selected candidate smaller than 2800px on its long
edge is rejected outright, sending the file to path two rather than serving an undersized
image.
<!-- evidence: lib/services/image_pipeline/image_source_types.dart:19; lib/services/image_pipeline/dart_image_loader.dart:69-77 -->

The sidebar-thumbnail path and the export path do not apply this floor. The sidebar
deliberately keeps its lenient smallest-then-largest candidate selection so thumbnails
never fall through to a full RAW decode; export stays lenient because there is no RAW
decode fallback on that path at all — rejecting an undersized candidate there would turn
"export a slightly smaller image" into "export fails," which is a capability loss, not a
correctness fix.
<!-- evidence: lib/services/image_pipeline/dng_embedded_jpeg_extractor.dart:86-93; lib/services/image_pipeline/dart_image_loader.dart:41-51,58-68; memory.md AD-021 -->

One rejection threshold applies independently of the size floor: a DNG whose declared
crop extent implies a decoded RGBA buffer over roughly 1.5 GB is refused outright rather
than decoded, to bound worst-case memory use.
<!-- evidence: lib/services/image_pipeline/dart_image_loader.dart:96-105 -->

### Two distinct "no preview" outcomes

A DNG that fails to yield a usable embedded preview lands in one of two states, and
Halcyon's loader tells them apart rather than collapsing them into one generic failure:

- **The container declares no preview at all** (a bare-CFA capture, or every candidate is
  either absent or rejected as undersized). This is not an error: the file proceeds to
  path two, full RAW decode, carrying forward whatever EXIF orientation the same walk
  already read.
- **The container declares one or more preview candidates, but every one of them is
  unreadable** — a strip offset or byte count that falls outside the file. This is treated
  as a structurally broken file: Halcyon reports it as a decode failure
  (`DNG_PARSE_FAILED`) rather than silently trying — and failing — a RAW decode on data
  that already proved inconsistent.

<!-- evidence: memory.md AD-022; lib/services/image_pipeline/dart_image_loader.dart:80-95 -->

A single unreadable candidate sitting next to a good one does not trigger the broken-file
state — only the case where *no* declared candidate is readable counts as malformed.
<!-- evidence: memory.md AD-022; lib/services/image_pipeline/dng_embedded_jpeg_extractor.dart:44-55 -->
