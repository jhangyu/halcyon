---
date: 2026-08-28
title: "Design spec — display support for already-rendered bitmap formats (WebP, TIFF, HEIC/HEIF)"
status: DESIGN (decisions 1–4 frozen by the user; everything else is engineering detail)
branch: feature/bitmap-decoders
---

## 1. Terminal state (one sentence)

A folder containing `.webp`, `.tif`/`.tiff` and `.heic`/`.heif` files shows those files in
the sidebar and the detail view through Halcyon's existing image pipeline — same star/trash
marks, same preload window, same export path — instead of having them filtered out at
folder scan.

## 2. Decisions already frozen by the user (recorded, not reopened)

1. **WebP** — the Flutter engine decodes WebP natively on all platforms. The change is
   registry-only: add `.webp` to `SupportedPhotoFormats.supportedExtensions` and to the
   encoded-bitstream branch in `lib/services/image_pipeline/dart_image_loader.dart`
   (`isEncodedBitstream`, line 39). No new dependency.
2. **TIFF** — decode with the already-present `image: ^4.9.2` pub package (already used by
   `lib/services/library/photo_export_service.dart` and
   `lib/services/image_pipeline/sidebar_thumbnail_codec.dart`). Display via the existing
   decoded-RGBA path (`lib/services/image_pipeline/decoded_rgba_image_provider.dart`, the
   same path RAW decode results take). No new dependency.
3. **HEIC/HEIF** — must decode identically on ALL platforms (user requirement; OS decoders
   were rejected). Route: libheif + libde265 native libraries, integrated into the existing
   sibling native package (extend it, do not create a new package), built through
   `scripts/build_apps.py`, exposed to Dart via FFI following the existing DNG decode
   pattern. Known risk to be stated: `build_apps.py`'s Windows native path has never run
   end to end; Windows/Linux builds must be verified on their own OS later — this spec
   plans code + build-script readiness from macOS only.
4. **Phasing** — WebP + TIFF are phase 1 (implementable immediately); HEIC is phase 2
   (build engineering).

### 2.1 One factual correction to the framing of decision 3 (path only, not the decision)

Decision 3 says "the existing sibling native package `../flutter_dng_decoder/dng_processor`".
That path no longer exists on this machine. The sibling native package is now
`/Users/jhangyu/project/ceyx`, exposed to Halcyon as the Dart package `ceyx` via
`pubspec.yaml:46-47` (`path: ../ceyx/plugin`); the native C++/Halide sources are under
`/Users/jhangyu/project/ceyx/native/`, and the Dart FFI surface is
`ceyx/plugin/lib/src/{dng_decoder_service,raw_bindings,raw_route}.dart`. The *decision*
— extend the existing sibling native package rather than create a new one — is unchanged
and is applied to `ceyx`. Everywhere below, "the native package" means `ceyx`.

## 3. Constraints inherited from the existing pipeline

Read before changing anything: `memory.md` AD-010/AD-011 (three frozen `NativeImageResult`
variants), AD-021 (uneven `minLongEdge` floor: strict on preview, lenient on sidebar),
AD-022 (the two "no preview" terminal states stay distinguishable), AD-024 (one EXIF
orientation table), and `docs/logs/2026-08-26/raw-support-contract.md` (D2 browse-only RAW,
D3 no-native-decoder state, and the rule that the format list is *derived*, never restated).

Hard constraints this design must not break:

- `NativeImageResult` keeps **exactly three** variants: `NativeImageBytes`,
  `NativeImageNeedsRawDecode`, `NativeImageFailure`
  (`lib/services/image_pipeline/image_source_types.dart:48-114`).
- `NativeImageNeedsRawDecode` is emitted **only** for `purpose == preview`, never for
  `sidebarThumbnail` and never for `export` — the sidebar's permanent-miss logic depends on
  it (`dart_image_loader.dart:14-27`, `image_preload_controller.dart:1030-1032`).
- `dart_image_loader.dart` stays free of `dart:io` `Platform` checks (contract C-3). "No
  decoder on this platform" is decided by the layer that owns the decoder seam
  (`photo_source.dart:151-166`, `kNoNativeDecoderCode`).
- The decoded-pixel budget in `dart_image_loader.dart:174` (`w * h * 4 > 1_500_000_000`)
  is the app's only defence against an OOM from a header that claims an absurd extent.
- Static analysis covers `lib/`, `test/` **and** `tool/`.

## 4. Routing decision: how TIFF and HEIC reach pixels without a fourth variant

**Chosen route: both TIFF and HEIC enter through the existing
`NativeImageNeedsRawDecode` → `DngFullDecoder` seam, with the decoder implementation
dispatching on file type. No new `NativeImageResult` variant, no new seam typedef.**

### 4.1 Why this route

`NativeImageNeedsRawDecode` no longer means "this is an Adobe DNG". AD-010's 2026-08-22
revision restates its semantics explicitly: *"cannot get cheap bytes, and this is a file the
decoder can handle"* — deliberately independent of who produced the signal and of the
container family. The 2026-08-26 contract then widened its gate from `.dng` to every
engine-decodable extension for exactly the same reason. TIFF and HEIC are the same shape of
fact: no cheap encoded bitstream the Flutter engine can hand to `ImageProvider`, but a
decoder exists that yields RGBA8. Routing them here reuses:

- `DecodedRgba` and `DngFullDecoder` (`dng_decode_contract.dart:12-30`) unchanged;
- `decodedRgbaToPixelPayload` (`decoded_rgba_image_provider.dart:92`) for the
  orientation + downscale GPU pass and the tier-1/tier-2 payload economics of AD-011;
- `PhotoSource.load`'s existing `NativeImageNeedsRawDecode` arm
  (`photo_source.dart:148-224`), including the D3 `kNoNativeDecoderCode` behaviour, the
  `allowExpensive` deferral onto the serial decode lane, and step-3b permanent-miss;
- `PhotoExportService.exportBytesFor`'s existing RGBA arm
  (`photo_export_service.dart:68-79`).

### 4.2 Alternatives rejected

- **A fourth variant (e.g. `NativeImageNeedsBitmapDecode`)** — forbidden by AD-010/AD-011
  and re-frozen by the 2026-08-26 contract's constraint list. Every `switch` over the sealed
  class (`photo_source.dart:135`) would need a new arm, and the D3/AD-022 reasoning would
  have to be duplicated per arm. Rejected.
- **Transcode inside the loader and return `NativeImageBytes`** (decode TIFF/HEIC, re-encode
  JPEG, hand back bytes). Stays at three variants, but: it makes `dart_image_loader.dart`
  perform decodes — the file is documented as never decoding (`dart_image_loader.dart:154-157`)
  and that property is what lets AD-022's verdict be formed later by `photo_source.dart`;
  it costs a full encode+decode round trip on the hot preview path; it loses the
  `fullRes` piggyback that tier-2 upload uses (`photo_source.dart:180-189`); and it
  degrades a 16-bit TIFF to 8-bit JPEG twice. Rejected for the preview path.
  It *is* still the mechanism on the sidebar path — see §6.2 — because the sidebar cache
  stores encoded bytes by design (`sidebar_thumbnail_codec.dart`), and that is pre-existing
  behaviour for RAW too (`image_preload_controller.dart:1063-1080`).
- **A second decoder typedef** (`BitmapFullDecoder`) alongside `DngFullDecoder`. Doubles the
  injection surface of `AppState`/`PhotoSource`/`ImagePreloadController` for zero behaviour
  difference: the signature `Future<DecodedRgba> Function(String path)` is already
  format-neutral. Renaming `DngFullDecoder` to a format-neutral name is explicitly parked by
  the 2026-08-26 contract; this spec keeps it parked. Rejected.

### 4.3 The predicate change (the one structural edit)

`dart_image_loader.dart` gates the raw-decode escape hatch on
`SupportedPhotoFormats.isDecodablePath` (line 128, 172). That predicate means "the Ceyx
engine can decode this RAW" and is *derived* from `kSupportedDecodeExtensions` — it must
stay derived and must not gain hand-written entries.

Add a second, additive predicate in `lib/models/supported_photo_formats.dart`:

```dart
/// Formats with no cheap encoded bitstream that a full decoder can still turn
/// into RGBA: engine-decodable RAW, plus the bitmap containers Flutter's own
/// codec cannot read (TIFF via package:image, HEIC via the native library).
static const Set<String> bitmapDecodeExtensions = {'.tif', '.tiff', '.heic', '.heif'};
static final Set<String> fullDecodeExtensions =
    Set.unmodifiable(decodableExtensions.union(bitmapDecodeExtensions));
static bool hasFullDecodeRoute(String path) => ...;
```

Then, in `dart_image_loader.dart`:

- The **RAW-specific** logic keeps `isDecodablePath`: the AD-021 `minLongEdge` strict floor
  (line 126-135) and the AD-022 `declaredPreviewsUnreadable` finding (line 171-193) are
  statements about *embedded previews in a TIFF-structured RAW container*. TIFF/HEIC files
  are not probed for embedded previews at all (see §6.1/§7.1), so neither concept applies
  and neither gate changes meaning.
- The **escape hatch** — "return `NeedsRawDecode` instead of `RAW_NO_EMBEDDED_PREVIEW`" —
  is what widens to `hasFullDecodeRoute`, together with the decoded-pixel budget check that
  precedes it.

Net effect on the sealed class: unchanged. Net effect on AD-021/AD-022: unchanged, because
both remain gated on `isDecodablePath`.

### 4.4 The dispatching decoder

One production implementation satisfies `DngFullDecoder` and `DngSizedDecoder` for every
format, replacing today's engine-only wiring in `lib/providers/app_state.dart:91`:

```
halcyonFullDecoder(path):
  ext == heic/heif      -> ceyx FFI heif_decode_and_process  (phase 2)
  ext == tif/tiff       -> package:image decodeTiff on a worker isolate
  otherwise             -> existing Ceyx RAW decode (unchanged)
```

It lives in `lib/services/image_pipeline/full_decoder_dispatch.dart` (new file, phase 1) so
that `dart_image_loader.dart` and `photo_source.dart` need no format knowledge beyond the
predicate. A dispatcher arm whose backing library is absent throws `UnsupportedError`, which
`photo_source.dart:196-224` already converts into the uniform permanent miss; the D3
"no decoder at all" state stays reserved for `dngDecoder == null`.

## 5. Format 1 — WebP (phase 1)

### 5.1 Scan / registry

`supportedExtensions` currently derives from `rawExtensions` plus a literal
`{'.jpg', '.jpeg', '.png'}` (`supported_photo_formats.dart:30-32`). Introduce
`engineBitstreamExtensions = {'.jpg', '.jpeg', '.png', '.webp'}`, use it for
`supportedExtensions`, and let `dart_image_loader.dart:39-42`'s `isEncodedBitstream` test
membership of that same set instead of three hard-coded `endsWith` calls — one definition,
so the scan whitelist and the loader branch cannot desync (the same "derive, don't restate"
rule the 2026-08-26 contract imposed on the RAW list).

`preferredLoadExtensions` (`supported_photo_formats.dart:34-38`) is the sibling-group
preference order for `bestFileToLoad`. WebP is appended **after** `.png`: a WebP sibling of
a RAW should be preferred over the RAW (it is a rendered bitstream), but a JPEG or PNG
sibling stays preferred over WebP because those are what cameras and prior exports produce.

### 5.2 Decode route

`NativeImageBytes(await File(path).readAsBytes())` — the file's own bytes, straight into
`ImageProvider`. The Flutter engine's codec (Skia/Impeller `SkCodec`) handles WebP,
including animated WebP, on macOS/iOS/Android/Windows/Linux/web. Only the first frame is
displayed; Halcyon is a still-photo triage tool and no animation control is in scope.

### 5.3 Sidebar / preview / export

- **Sidebar**: `sidebarCacheBytes` (`sidebar_thumbnail_codec.dart:26`) passes payloads
  ≤512 KB through untouched and otherwise re-decodes via
  `ui.instantiateImageCodecWithSize` and re-encodes JPEG q80. Both paths work for WebP
  with no change.
- **Preview**: `EncodedPayload` + tier-1/tier-2 providers, identical to JPEG. `SourceCost`
  is `cheap` (`photo_source.dart:137-146`), so WebP participates in the whole -3..+5
  retention window with no debounce — correct, since decode is engine-side and fast.
- **Export**: `PhotoExportService.exportBytesFor` takes the `NativeImageBytes` arm and calls
  `img.decodeImage` (`photo_export_service.dart:92`). `package:image` 4.9.2 decodes WebP
  (lossy and lossless), so export produces a 2048px JPEG as for any other bitstream.

### 5.4 Failure modes

- Corrupt/truncated WebP: engine codec fails → `ImageStream` error → the existing
  `_registerDecode` error path marks the item a miss (`image_preload_controller.dart:851`).
  On export, `img.decodeImage` returns null → `exportBytesFor` returns null → the item lands
  in `PhotoExportOutcome.failures` and is shown to the user.
- Oversized: the 1.5 GB decoded-pixel budget in `dart_image_loader.dart:174` is inside the
  `isDecodablePath` preview branch and therefore does **not** cover the encoded-bitstream
  branch — that is pre-existing for JPEG/PNG and this spec does not change it. WebP's
  format-level ceiling is 16383×16383 (~1.07 GB RGBA), below the budget, so WebP cannot
  exceed a limit that JPEG already can. Recorded as an accepted, unchanged exposure.

### 5.5 EXIF orientation

WebP carries orientation in an optional `EXIF` chunk. The Flutter engine does **not** apply
it; neither does Halcyon for JPEG/PNG today, because `package:image`'s and the engine's JPEG
paths bake it (`photo_export_service.dart:96-101`). Consequence: a WebP written by a phone
with a non-1 Orientation tag may display rotated. Position: **accepted for phase 1 and
stated, not silently shipped** — WebP files in a triage workflow are overwhelmingly derived
exports with Orientation already baked to 1. If a real sample proves otherwise, the fix is
to read the EXIF chunk in the loader and route the file through the decoded-RGBA path like
TIFF; that is a phase-3 item, not a phase-1 blocker.

## 6. Format 2 — TIFF (phase 1)

### 6.1 Scan / registry and decode route

`.tif`/`.tiff` join `bitmapDecodeExtensions` (§4.3), hence `supportedExtensions`. They are
**not** in `preferredLoadExtensions`: a TIFF sibling must not outrank a JPEG sibling, and
the `bestFileToLoad` fallback already prefers any supported file
(`supported_photo_formats.dart:64-71`).

In `dart_image_loader.dart`, TIFF takes the widened escape hatch: no embedded-preview walk
(`DngEmbeddedJpegExtractor` is a RAW-preview walker; a scanner TIFF's IFD0 *is* the image,
so "extract the embedded preview" is meaningless there), budget check, then
`NativeImageNeedsRawDecode(exifOrientation: <read from IFD0>)`.
`DngEmbeddedJpegExtractor.readImageDimensions` and `readOrientation` already perform a
bounded IFD0 walk on TIFF-structured files and work on a plain TIFF unchanged — no new
parser.

The dispatcher arm decodes with `img.decodeTiff` inside `Isolate.run` (the pattern
`photo_export_service.dart:90` already uses), converts to RGBA8 via `img.Image.getBytes(
order: ChannelOrder.rgba)`, and returns `DecodedRgba`. `package:image` handles stripped and
tiled TIFF, 8/16/32-bit samples, LZW/PackBits/Deflate and uncompressed; 16-bit is
down-converted to 8-bit here, which is what the display path takes anyway.

### 6.2 Sidebar / preview / export

- **Sidebar**: the loader returns `NativeImageFailure('NO_THUMBNAIL', …)` for
  `purpose == sidebarThumbnail` (the invariant that `NeedsRawDecode` is never emitted for
  the sidebar is preserved verbatim). The controller's existing else-if branch
  (`image_preload_controller.dart:1048-1049`) then runs the **sized** decoder — its gate
  widens from `isDecodablePath` to `hasFullDecodeRoute`, and `DngSizedDecoder`'s `maxDim`
  is honoured by decoding then `img.copyResize`. The result is oriented and JPEG-encoded by
  the existing `jpegFromOrientedPixels`, so the sidebar cache keeps storing encoded bytes.
- **Preview**: `SourceCost.expensive` — the item runs on the shared serial decode lane
  exactly like a preview-less RAW, and `decodedRgbaToPixelPayload` reduces the frame to
  window resolution before it is retained. This is what keeps a 200 MB scanner TIFF from
  sitting in the payload cache at full size (AD-023's distance eviction applies unchanged).
- **Export**: the `NativeImageNeedsRawDecode` arm of `exportBytesFor`
  (`photo_export_service.dart:68-79`) already handles it, provided `PhotoExportService` is
  constructed with the dispatching decoder instead of the engine-only one. Orientation is
  baked from the signal's value by `bakeExifOnDecoded`; `_attachSourceExif` re-reads core
  EXIF from the original TIFF with `package:exif`, which is documented as proven on
  TIFF-structured files (`photo_export_service.dart:145-151`).

### 6.3 Failure modes

- **Corrupt TIFF**: `img.decodeTiff` returns null / throws → the dispatcher throws →
  `photo_source.dart`'s step-3b catch records the uniform permanent miss with
  `failureCode: null` (**not** `DNG_PARSE_FAILED`: `declaredPreviewsUnreadable` is false for
  every TIFF because no preview probe runs, so AD-022's two RAW-specific end states are
  untouched).
- **Oversized**: the 1.5 GB decoded-pixel budget check moves with the escape hatch and
  therefore *does* cover TIFF — a 30000×30000 scan (3.6 GB RGBA) returns
  `NativeImageFailure('IMAGE_TOO_LARGE', …)` before any allocation. This is stricter than
  WebP/JPEG on purpose: the TIFF decode happens on the Dart heap in an isolate, where the
  failure mode is a process OOM rather than an engine-side decode error.
  On the sidebar path the budget check is not reached (the sidebar branch returns
  `NO_THUMBNAIL` first), so the sized decoder must apply the same ceiling itself before
  decoding — an explicit requirement, not an accident.
- **Multi-page TIFF**: page 0 only. A multi-page fax TIFF shows its first page; not a
  failure, a stated limitation.
- **Exotic compression** (JPEG-in-TIFF old-style, CCITT G3/G4, JPEG2000-in-TIFF): whatever
  `package:image` refuses becomes an ordinary decode failure and a permanent miss. No
  fallback chain is added.

### 6.4 EXIF orientation

Read once from IFD0 by `DngEmbeddedJpegExtractor.readOrientation`, carried on
`NativeImageNeedsRawDecode.exifOrientation`, and applied by
`decodedRgbaToPixelPayload` / `bakeExifOnDecoded` — both of which go through
`exifTransformFor`, the single table AD-024 mandates. `img.decodeTiff` does **not** bake
orientation, so applying it here is required, not belt-and-braces. The sized sidebar decode
reads orientation the same way the RAW sidebar path already does
(`image_preload_controller.dart:1068-1070`).

## 7. Format 3 — HEIC/HEIF (phase 2)

### 7.1 Scan / registry and decode route

`.heic`/`.heif` join `bitmapDecodeExtensions`; everything in §6.1's routing applies, with
two differences:

- HEIC is ISO-BMFF, not TIFF, so `DngEmbeddedJpegExtractor.readImageDimensions` /
  `readOrientation` return null on it. Dimensions and orientation come from the native
  side: a cheap `heif_probe(path) -> {width, height, orientation}` FFI call that reads only
  the metadata boxes, used to satisfy the decoded-pixel budget check and to fill
  `exifOrientation` before any decode. HEIC's `irot`/`imir` transform properties and its
  EXIF item are normalised to a 1..8 EXIF value native-side, so the Dart layer keeps exactly
  one orientation vocabulary (AD-024).
- Multi-image HEIC (bursts, Live Photos, depth/auxiliary images): the **primary item**
  (`pitm` box) only. HDR gain maps and depth maps are ignored.

Sidebar/preview/export behaviour is identical to TIFF (§6.2) — same seam, same lane, same
export arm — because the dispatcher hides the difference.

### 7.2 Native library sourcing and licensing

| Library | Role | Version target | Licence |
|---|---|---|---|
| libheif | HEIF/AVIF container parsing, item/transform handling | 1.19.x | LGPL-3.0-or-later |
| libde265 | HEVC (H.265) intra decoding of the coded item | 1.0.15 | LGPL-3.0-or-later |

Encoders are **not** built: `x265` (GPL-2.0) and `libaom` are excluded from the build
configuration. Halcyon only ever reads HEIC. This keeps the whole HEIC path LGPL and clear
of GPL contamination.

**Static vs dynamic linking.** LGPL-3 §4 requires that a user be able to relink the
application against a modified version of the library. Position:

- **Chosen: dynamic linking**, with libheif and libde265 built as separate shared libraries
  (`libheif.dylib`/`.dll`/`.so`, `libde265.*`) shipped next to `libdng_decoder_native.*` in
  the same bundle location, and loaded by the OS loader. Dynamic linking satisfies §4(d)(1)
  outright — the user can replace the `.dylib` in `App.app/Contents/Frameworks/` — with no
  obligation to publish object files or Halcyon's own sources.
- **Rejected: static linking into `dng_decoder_native`.** It would trigger the §4(d)(0)
  duty to ship relinkable object files for Halcyon's native layer with every release, for a
  gain (one fewer bundled file) that is worthless here.
- Licence text obligations: add `LGPL-3.0.txt` plus per-library attribution under
  `docs/legal/` and surface the notice in the app's about/licence surface alongside the
  existing third-party notices. Source availability: pin the exact upstream commit/tarball
  SHA-256 in the build script so the corresponding source can be produced on request.

### 7.3 Build integration per platform

The native build is driven by `scripts/build_apps.py` Phase 1 (`build_native`), which
already builds `dng_decoder_native` per target from the table at `build_apps.py:267-290`.
Integration follows the existing shape rather than inventing one:

- **Source acquisition**: a `ceyx/native/scripts/fetch_heif_deps.sh` mirroring the existing
  `fetch_halide_v21_dist.sh` — download pinned tarballs, verify SHA-256, unpack under
  `ceyx/native/third_party/{libheif,libde265}/`. No git submodules (the repo already avoids
  them for Halide).
- **CMake**: add the two projects via `add_subdirectory` with
  `BUILD_SHARED_LIBS=ON`, encoders/examples/tests off (`WITH_X265=OFF`,
  `WITH_AOM_ENCODER=OFF`, `WITH_EXAMPLES=OFF`), and a new `heif_decode.cpp` translation unit
  in `dng_decoder_native` that links against them.
- **macOS** (the only platform verifiable in phase 2): install the two dylibs into the same
  `macos/Libraries/` staging directory the plugin's CocoaPods spec already embeds, with
  `@rpath` install names fixed by `install_name_tool` at build time; arm64 only, matching
  the existing arm64-only constraint (`build_apps.py:155-156, 223-225`).
- **Windows / Linux**: the CMake and placement rules are written and the target table rows
  added, but **not verified in phase 2**. Recording the risk verbatim: `build_apps.py`'s
  Windows native path has never run end to end; treat the first real Windows run of the
  script as first contact, not a regression test. Phase 2 acceptance is therefore explicitly
  scoped to macOS, with a Windows/Linux verification task filed as a follow-up. On any
  platform where the libraries are absent at runtime, the dispatcher's HEIC arm throws and
  the file degrades to the ordinary permanent-miss state — the app must not fail to start.
- **iOS / Android / web**: out of scope for phase 2. Android is mechanically the same
  jniLibs placement as the existing `.so` and can follow once macOS is green; web has no FFI
  and HEIC therefore stays undecodable there (the same shape as the D3 state for RAW).

### 7.4 FFI surface

Mirrors `raw_bindings.dart` / `dng_decoder_service.dart` in style: C ABI, caller-provided
path, decoder-owned buffer freed through an explicit release call bound to a
`NativeFinalizer`, and the work performed on the existing decode worker isolate
(`DngDecoderService.decodeOnWorker`) so the UI isolate never blocks.

```c
// ceyx/native/include/heif_api.h
typedef struct { int32_t error_code; uint32_t width, height;
                 int32_t orientation; uint8_t* rgba; int64_t rgba_len; } HeifResult;

int32_t heif_probe(const char* path, uint32_t* w, uint32_t* h, int32_t* orientation);
int32_t heif_decode_rgba(const char* path, int32_t max_dim, HeifResult* out);
void    heif_release(HeifResult* r);
```

Contract points: RGBA8 interleaved, `rgba_len == width * height * 4` (the invariant
`_imageFromPixels` asserts at `decoded_rgba_image_provider.dart:59-67`); `max_dim <= 0`
means full size, otherwise a request (not a guarantee), matching `DngSizedDecoder`'s
documented semantics; non-zero `error_code` values get a `HeifErrorCode` abstract-final
class alongside the existing `DngErrorCode`/`RawErrorCode`; orientation is already
normalised to 1..8. The Dart wrapper is exported from `ceyx/plugin/lib/ceyx.dart` so
Halcyon imports it through the package barrel like everything else.

### 7.5 The S4 colour-gate question

`scripts/build_apps.py` refuses to place a native library that has not passed the runbook S4
colour gate, and the gate's input is a CFA sample DNG (`build_apps.py:927-931`, `--cfa-sample-dng`).

**Position, stated rather than dodged, in two parts:**

1. **The S4 gate as specified does not test anything HEIC exercises.** It validates the RAW
   demosaic/white-balance/colour-transform pipeline from a Bayer CFA sample. HEIC decoding is
   YUV 4:2:0 → RGB with an NCLX/ICC colour description; it shares no code with the demosaic
   pipeline. Extending `--cfa-sample-dng` to HEIC would be theatre.
2. **The gate nevertheless still applies to every build of the artifact.** If `heif_decode.cpp`
   lands inside `libdng_decoder_native`, then every HEIC change rebuilds the library that
   carries the RAW pipeline, and S4 must pass for that rebuild exactly as today — no
   `--no-colour-gate` opt-out in phase 2, and no separate placement path for the HEIC work.
   Correspondingly, HEIC needs **its own** known-answer colour check: decode a fixed sample
   HEIC and compare against a checked-in reference PNG with a bounded per-channel tolerance
   (≤2/255 mean absolute error), run in the same Phase 1 position as S4. Call it the H1 gate;
   it fails the build the same way S4 does. Rationale: a YUV range or matrix-coefficient
   mistake (full vs limited range, BT.601 vs BT.709) produces an image that is obviously
   *there* and subtly wrong — precisely the class of defect a smoke test passes and a
   reference comparison catches.

## 8. Documentation updates required

Note: the SOP set (`memory.md`, `file_index.md`, `unit_test.md`, `task.md`, `plan.md`,
`handover.md`) is deliberately untracked — `.gitignore:49-53`, per
`docs/logs/2026-08-26/sop-relocation-contract.md` — and lives at
`/Users/jhangyu/project/Halcyon/docs/sop/`. It is edited in place there, not in this
worktree, and never appears in a commit.

- **`memory.md`** — one new AD entry (next free number is **AD-035**): "already-rendered
  bitmap formats route through the existing three-variant seam". It must record the §4
  routing argument, the `hasFullDecodeRoute` vs `isDecodablePath` split (and that AD-021 and
  AD-022 stay gated on `isDecodablePath`), and, for phase 2, the licensing and S4/H1
  positions from §7.2/§7.5.
- **`file_index.md`** — add `lib/services/image_pipeline/full_decoder_dispatch.dart` and, in
  phase 2, the `ceyx/native/src/heif_decode.cpp` + `ceyx/plugin/lib/src/heif_bindings.dart`
  rows.
- **`unit_test.md`** — TC-matrix entries for every case in §9 (next free number is
  **TC-302**; TC-249…TC-299 are unused, so the phase-1 block starts at TC-302).
- **`README.md` / `README.zh-TW.md`** — the "supported formats" section gains WebP/TIFF in
  phase 1 and HEIC in phase 2, with the platform caveat for HEIC. The Chinese file is
  rewritten as Chinese prose, not translated from the English (2026-08-27 precedent).
- **`docs/legal/`** — phase 2 only: LGPL-3 text and libheif/libde265 attribution.

## 9. Test strategy

Every case is a `flutter test` unit test with a fake decoder injected — no real dylib, no
real photo library, per the seam's whole purpose (`dng_decode_contract.dart:4-8`).

**Phase 1 (WebP + TIFF)** — `test/models/supported_photo_formats_test.dart`,
`test/dart_image_loader_test.dart`, `test/services/full_decoder_dispatch_test.dart`,
`test/image_preload_controller_test.dart`, `test/services/photo_export_service_test.dart`:

| TC | Case |
|---|---|
| TC-302 | A folder listing containing `a.webp`, `b.tif`, `c.tiff` surfaces all three via `isSupportedPath`; an `.xyz` file still does not. |
| TC-303 | `dartImageLoad('x.webp', purpose: preview)` returns `NativeImageBytes` with the file's own bytes (encoded-bitstream branch), for all three purposes. |
| TC-304 | `bestFileToLoad` prefers `.jpg` over `.webp`, and `.webp` over a `.dng` sibling. |
| TC-305 | `dartImageLoad('x.tif', purpose: preview)` returns `NativeImageNeedsRawDecode` with the IFD0 orientation and `declaredPreviewsUnreadable == false`. |
| TC-306 | `dartImageLoad('x.tif', purpose: sidebarThumbnail)` returns `NativeImageFailure` and **never** `NativeImageNeedsRawDecode` (the AD-010 invariant). |
| TC-307 | A TIFF header declaring 30000×30000 yields `NativeImageFailure('IMAGE_TOO_LARGE', …)` before any decode is attempted. |
| TC-308 | The sized sidebar path applies the same decoded-pixel ceiling and reports a permanent miss rather than decoding. |
| TC-309 | `full_decoder_dispatch` routes `.tif` to the TIFF arm, `.dng`/`.arw` to the engine arm, and throws `UnsupportedError` for an unroutable extension. |
| TC-310 | A corrupt TIFF makes `PhotoSource.load` return `payload: null, deferred: false, failureCode: null` — not `DNG_PARSE_FAILED`. |
| TC-311 | A TIFF with Orientation 6 renders through `decodedRgbaToPixelPayload` with width/height swapped (orientation applied exactly once). |
| TC-312 | `exportBytesFor` on a TIFF with an injected decoder produces a JPEG with long edge ≤2048 and `Orientation == 1`. |
| TC-313 | Exhaustive `switch` over `NativeImageResult` still compiles with exactly three arms (the AC3-style structural pin from the 2026-08-26 contract, re-run). |

**Phase 2 (HEIC)** — `test/services/heif_decoder_test.dart`, plus the native-side gate:

| TC | Case |
|---|---|
| TC-314 | `dartImageLoad('x.heic', purpose: preview)` returns `NativeImageNeedsRawDecode` carrying the orientation supplied by a fake probe. |
| TC-315 | `dartImageLoad('x.heic', purpose: sidebarThumbnail)` returns `NativeImageFailure`; the sized sidebar decoder is the only HEIC thumbnail route. |
| TC-316 | With the HEIC arm's library absent, the dispatcher throws and the item becomes a permanent miss — the app neither crashes nor reports the D3 `NO_NATIVE_DECODER` code (which stays reserved for a null decoder). |
| TC-317 | A `HeifResult` whose `rgba_len != width * height * 4` is rejected before `decodeImageFromPixels` sees it. |
| TC-318 | H1 colour gate: decoding the checked-in sample HEIC matches the reference PNG within 2/255 mean absolute error (native-side test, run in `build_apps.py` Phase 1). |

Instrument discipline for every gate run in either phase: capture the exit code inside the
artifact with `RC=$?` on the line immediately after the command, and require the declared
test count to equal the executed count (`flutter test -j 1`).

## 10. Phase acceptance criteria

### Phase 1 — WebP + TIFF

1. `flutter analyze` reports **0 issues** over `lib/`, `test/` and `tool/`; artifact contains
   the command output with `RC=$?` captured on the following line.
2. `flutter test -j 1` ends with `All tests passed!`, `RC=0`, and declared test count ==
   executed count.
3. `grep -c "class .* extends NativeImageResult" lib/services/image_pipeline/image_source_types.dart`
   returns **3**, and `git diff --stat` shows `image_source_types.dart` unchanged.
4. `grep -n "webp\|tiff" lib/models/supported_photo_formats.dart` shows `.webp` in the
   engine-bitstream set and `.tif`/`.tiff` in `bitmapDecodeExtensions`; no `.heic` yet.
5. `lib/services/image_pipeline/full_decoder_dispatch.dart` exists and is referenced from
   `lib/providers/app_state.dart`.
6. Test names **TC-302 … TC-313** all appear in `flutter test` output and are recorded in
   `unit_test.md`'s TC matrix.
7. `grep -n "isDecodablePath" lib/services/image_pipeline/dart_image_loader.dart` still shows
   the AD-021 `minLongEdge` guard and the AD-022 malformed branch gated on `isDecodablePath`
   (not on `hasFullDecodeRoute`).
8. `memory.md` contains an `### AD-035` heading and `file_index.md` lists
   `full_decoder_dispatch.dart`.
9. Manual, user-run only (per the standing rule that UI performance and visual checks belong
   to the user): a folder containing one WebP and one TIFF shows both in the sidebar and
   renders both in the detail view.

### Phase 2 — HEIC/HEIF

1. `python3 scripts/build_apps.py --check` exits 0 on macOS with the libheif/libde265 rows
   present in the toolchain report.
2. `python3 scripts/build_apps.py macos --cfa-sample-dng <sample>` completes with `RC=0`; the
   S4 gate runs (no `--no-colour-gate` anywhere in the invocation) and the new H1 gate prints
   a pass line.
3. `ls <build>/Halcyon.app/Contents/Frameworks/` lists `libheif.*.dylib` and
   `libde265.*.dylib` alongside `libdng_decoder_native.dylib`, and
   `otool -L .../libdng_decoder_native.dylib` shows both as `@rpath` dynamic dependencies —
   mechanically proving the §7.2 dynamic-linking decision.
4. `nm -gU <built libdng_decoder_native.dylib> | grep heif_decode_rgba` finds the symbol, and
   the dylib's build is newer than the commit under test (provenance per the 2026-08-23
   lesson — argued from an observed build event, not from mtime alone).
5. `flutter analyze` 0 issues and `flutter test -j 1` green, with `RC=$?` captured, including
   test names **TC-314 … TC-318**.
6. `grep -rn "x265\|libaom" ceyx/native/CMakeLists.txt` returns no enabled encoder options.
7. `docs/legal/` contains the LGPL-3 text and per-library attribution files.
8. `README.md` and `README.zh-TW.md` state HEIC support and name the platforms where it is
   verified (macOS) versus written-but-unverified (Windows, Linux).
9. Manual, user-run only: an iPhone HEIC displays in both the sidebar and the detail view
   with correct orientation.

## 11. Out of scope (parking lot — report, do not do)

- Renaming `DngFullDecoder`/`DngSizedDecoder`/`DecodedRgba` to format-neutral names (already
  parked by the 2026-08-26 contract).
- AVIF. libheif can decode it with libaom or dav1d, but no decision has been taken and no
  user need was stated.
- Animated WebP playback, HEIC burst/Live-Photo secondary items, HDR gain maps, depth maps.
- 16-bit-through display precision. Everything downstream of `DecodedRgba` is RGBA8.
- Windows and Linux verification of the HEIC native build (explicitly deferred, §7.3).
- WebP EXIF orientation application (§5.5), unless a real sample proves it is needed.
