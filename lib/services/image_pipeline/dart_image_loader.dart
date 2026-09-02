import 'dart:io';

import '../../models/supported_photo_formats.dart';
import 'bitmap_container_probe.dart';
import 'dng_decode_contract.dart';
import 'dng_embedded_jpeg_extractor.dart';
import 'image_source_types.dart';

/// Pure-Dart production implementation of the `NativeImageLoad` seam
/// (photo_source.dart:76-80). Replaces the deleted native thumbnail
/// MethodChannel as the production byte producer (M6 C-1/C-2). Free of
/// Platform checks by construction (C-3).
///
/// Invariants:
/// - [NativeImageNeedsRawDecode] is emitted ONLY for
///   `purpose == ImageRequestPurpose.preview` on a path the engine can decode
///   (`SupportedPhotoFormats.isDecodablePath`, derived from the engine's own
///   `kSupportedDecodeExtensions`). It was `.dng`-only until the 2026-08-26
///   RAW-coverage contract generalised the route; the part the sidebar's
///   permanent-miss logic depends on — that it is NEVER emitted for
///   `sidebarThumbnail`, nor for `export` — is unchanged and must stay so.
///   Browse-only RAW (`.cr2`/`.iiq`/`.mrw`, contract decision D2) has no
///   decode route and therefore never yields this variant either.
///   CAVEAT (F4): "never emitted for `export`" is a statement about this
///   function's `export` ARGUMENT, not about the export feature. The export
///   service enters through `purpose: preview`
///   (`photo_export_service.dart:57-58`) precisely so that it DOES receive
///   this signal and can decode a preview-less RAW; nothing in `lib/` passes
///   `ImageRequestPurpose.export` to this loader at all.
/// - This file stays free of `Platform` checks by construction (C-3). "No
///   native decoder on this platform" (contract decision D3) is therefore NOT
///   decided here: the loader still reports [NativeImageNeedsRawDecode], and
///   the caller that owns the decoder seam converts an absent decoder into
///   [kNoNativeDecoderCode].
/// - Never throws: every failure is a [NativeImageFailure].
Future<NativeImageResult> dartImageLoad(
  String path, {
  required ImageRequestPurpose purpose,
  // F4/AC6: the LIVE viewport long edge, or null for "use purpose.targetSize".
  // See [NativeImageLoad]'s doc — this is the one number the preview floor and
  // the routing verdict must share. Only the PREVIEW floor consults it; the
  // sidebar branch keeps `purpose.targetSize` because AD-021's uneven floor
  // (strict preview, lenient sidebar) is deliberate and stays.
  int? targetLongEdge,
  // Injected so this file needs no format knowledge beyond the registry
  // predicate and stays free of Platform checks (contract C-3): HEIC's extent
  // and orientation live in ISO-BMFF boxes that the TIFF IFD0 walker cannot
  // read, and reaching them means an FFI call that must not exist in a unit
  // test.
  BitmapContainerProbe probe = probeBitmapContainer,
}) async {
  // Derived, never restated: the SAME set the folder-scan whitelist uses
  // (`SupportedPhotoFormats.engineBitstreamExtensions`), so a format added to
  // the scan cannot silently miss this branch and fall through to the RAW
  // path. `.webp` joins here in phase 1 — the Flutter engine's codec reads it
  // natively on every platform.
  final isEncodedBitstream = SupportedPhotoFormats.isEncodedBitstreamPath(path);
  try {
    if (!await File(path).exists()) {
      // Deviation from the plan's verbatim listing (reported to the lead):
      // the walker degrades a missing file to the same "no candidate" null
      // as a genuine no-preview DNG, which would otherwise misclassify a
      // missing file as NeedsRawDecode instead of an explicit failure — the
      // exact case test/dart_image_loader_test.dart's "missing file is a
      // failure, not a throw" pins. Checked before BOTH branches so a
      // missing .jpg reports NOT_FOUND too, not DART_LOADER_ERROR
      // (round-review nit, 2026-08-24).
      return const NativeImageFailure('NOT_FOUND', 'file does not exist');
    }
    if (isEncodedBitstream) {
      return NativeImageBytes(await File(path).readAsBytes());
    }
    // Already-rendered bitmap containers (phase 1: TIFF). No embedded-preview
    // walk runs for these at all: `DngEmbeddedJpegExtractor` is a RAW-preview
    // walker, and a scanner TIFF's IFD0 IS the image, so "extract the embedded
    // preview" is meaningless here. Placing the branch above the walk is what
    // makes that structural rather than a comment — and it is also why
    // `declaredPreviewsUnreadable` is always false for a TIFF, leaving
    // AD-022's two RAW-specific end states untouched.
    if (SupportedPhotoFormats.isBitmapDecodePath(path)) {
      if (purpose != ImageRequestPurpose.preview) {
        // The AD-010 invariant, preserved verbatim: NeedsRawDecode is emitted
        // for the preview purpose ONLY. The sidebar's own sized-decode
        // fallback (image_preload_controller.dart) is the only thumbnail
        // route for these files.
        return const NativeImageFailure(
          'NO_THUMBNAIL',
          'no embedded candidate',
        );
      }
      final extent = await probe(path);
      if (extent != null &&
          extent.width * extent.height * 4 > kDecodedPixelBudgetBytes) {
        // The budget moves WITH the escape hatch, so it covers TIFF and HEIC.
        // This is stricter than JPEG/WebP on purpose: these decodes happen on
        // the Dart heap or in the native decoder, where the failure mode is a
        // process OOM rather than an engine-side decode error. A null extent
        // (unreadable IFD0, or a HEIF probe that could not answer) waves
        // through, exactly as on the RAW path below.
        return const NativeImageFailure(
          'IMAGE_TOO_LARGE',
          'decode exceeds the decoded-pixel budget',
        );
      }
      return NativeImageNeedsRawDecode(
        exifOrientation: extent?.orientation ?? kDefaultExifOrientation,
        // Structurally false: no preview probe ran, so the container cannot
        // have "declared previews that were all unreadable" (AD-022).
      );
    }
    if (purpose == ImageRequestPurpose.sidebarThumbnail) {
      // Smallest embedded candidate reaching the sidebar edge (G3 finding:
      // the full-size entry point wrongly refuses small-thumbnail DNGs).
      final candidate = await DngEmbeddedJpegExtractor.extractEmbeddedJpeg(
        path,
        longEdge: purpose.targetSize,
      );
      return candidate == null
          ? const NativeImageFailure('NO_THUMBNAIL', 'no embedded candidate')
          : NativeImageBytes(candidate.bytes);
    }
    // M7 ruling G-2: when no embedded candidate reaches the requested long
    // edge, the file enters RAW decode instead of being served an undersized
    // rendition. `minLongEdge` is a post-selection REJECTION in the extractor,
    // not a different choice, so this branch still gets the largest qualifying
    // candidate when one exists.
    //
    // The guard's PRINCIPLE (M7 Decision Log A-6), not its old spelling: be
    // strict exactly where a rejection lands in a real RAW decode, and lenient
    // everywhere a rejection would instead delete an image the user can
    // currently see. The 2026-08-26 contract widened the escape hatch from
    // `.dng` to every engine-decodable extension, so re-deriving the same
    // principle over the new hatch gives:
    //  - `purpose == sidebarThumbnail` never reaches here; the sidebar branch
    //    above stays lenient under rulings P-11/P-13.
    //  - `purpose == export` is excluded HERE, but read the next paragraph
    //    before relying on that: the shipped export feature does not use it.
    //  - browse-only RAW (`.cr2`/`.iiq`/`.mrw`, contract decision D2) stays
    //    excluded for exactly the old reason: the engine cannot decode those
    //    containers, so a rejection would fall through to
    //    RAW_NO_EMBEDDED_PREVIEW rather than to a decode.
    //  - engine-decodable non-DNG RAW (`.arw`/`.nef`/`.rw2`/...) is now
    //    INCLUDED, because the premise that excluded it -- "that escape hatch
    //    is gated on `.dng`" -- is precisely what the contract removed.
    //
    // CORRECTION (round-1 reviewer finding F4). An earlier version of this
    // comment claimed the export FEATURE stays lenient. It does not, and never
    // did: `photo_export_service.dart:57-58` calls this loader with
    // `purpose: preview`, so the strict floor applies to exports too. Nothing
    // in `lib/` ever passes `ImageRequestPurpose.export` to the loader -- that
    // enum value is used only for its `targetSize`
    // (`photo_export_service.dart:82`). The false claim predates the RAW
    // generalisation: A-6's original "export is excluded because the escape
    // hatch is unreachable for it" was already wrong about the shipped path,
    // and this round faithfully carried the wrong premise forward.
    //
    // The BEHAVIOUR is deliberately left alone; only the claim is corrected.
    // Making export pass `ImageRequestPurpose.export` would look like it
    // restores leniency, but it would kill `photo_export_service.dart:68`'s
    // `NativeImageNeedsRawDecode` branch, and exporting a preview-less RAW
    // would start returning null. The export service documents its
    // preview-purpose choice as deliberate for exactly that reason
    // (`photo_export_service.dart:43-46`). Consequences of the floor applying
    // to export, stated rather than papered over:
    //  - with a decoder available, the result is BETTER: a real decode
    //    downsized to 2048 beats an undersized embedded preview.
    //  - with no decoder (contract decision D3), the export fails where it
    //    would previously have produced an undersized image. That window is
    //    narrow -- it needs a sensor long edge under roughly 3111px, since a
    //    full-size candidate must clear `0.90 * cropMax` to qualify -- but it
    //    is not empty. It is also not new: this exposure already existed for
    //    `.dng` before this round, because export has always entered through
    //    the preview purpose. This round widened an accepted condition; it did
    //    not invent one. Recorded as parking-lot, not silently accepted.
    // AD-021's uneven floor is preserved -- strict on preview, lenient on
    // sidebar -- and is not unified. The `export` ARM of this guard is
    // currently unreachable in production; the tests that pin it pin the
    // loader's purpose semantics, not the export feature's behaviour.
    final strictPreview =
        purpose == ImageRequestPurpose.preview &&
        SupportedPhotoFormats.isDecodablePath(path);
    // F4/AC6: ONE threshold. `targetLongEdge` is the same live viewport long
    // edge `PhotoSource.probeSource` compared against when it decided this
    // item's rung, so the floor enforced here can no longer contradict the
    // routing verdict. Null (a caller with no viewport) keeps the old constant.
    final previewFloor = targetLongEdge ?? purpose.targetSize;
    final embeddedProbe = await DngEmbeddedJpegExtractor.probeEmbeddedJpeg(
      path,
      longEdge: null,
      minLongEdge: strictPreview ? previewFloor : null,
    );
    final full = embeddedProbe.jpeg?.bytes;
    if (full != null) return NativeImageBytes(full);
    // DIAGNOSTIC (2026-09-02). THE decision point of the reported bug: from
    // here a decodable file routes to a full RAW decode, and the preload
    // controller memoises that verdict for the whole folder session. The
    // headless repro could never make this branch fire on the user's files
    // (docs/logs/2026-09-02/repro-experiment.md §4-5, page-cache-bound), so the
    // only remaining instrument is a real app run.
    //
    // One line per occurrence, off the hot path: a file with a usable preview
    // has already returned above. Pair it with any `halcyon.read.fault` line
    // for the same file -- fault present means the volume hiccuped (the
    // transient-read hypothesis), fault absent with `malformed=false` means the
    // container genuinely offered nothing and the cause is elsewhere. That
    // pairing is the discriminator the team currently lacks.
    if (strictPreview) {
      stderr.writeln(
        'halcyon.preview.miss|file=${path.split(Platform.pathSeparator).last}'
        '|malformed=${embeddedProbe.malformed}'
        '|floor=$previewFloor'
        '|len=${await File(path).length()}'
        '|-> RAW decode',
      );
    }
    // USER RULING 2026-08-26 — the malformed PRE-EMPT is gone.
    //
    // M7 Task 3 used to return a `DNG_PARSE_FAILED` failure right here when
    // `probe.malformed` was true on an engine-decodable path: a container that
    // PARSED but declares only unreadable candidates was called broken before
    // any decode was attempted. Measurement retired that: a container with
    // unreadable previews but intact sensor data was being reported broken
    // while the engine decodes the very same file in 383ms. The user therefore
    // overrode AD-022's pre-empt — unreadable previews route to the full
    // decoder FIRST, and the file is only reported broken if that decode ALSO
    // fails.
    //
    // What the override did NOT do: AD-022's requirement that the two "no
    // preview" end states stay TELLABLE APART still holds. What it removed is
    // the pre-empt, not the distinction. The distinction is carried forward on
    // [NativeImageNeedsRawDecode.declaredPreviewsUnreadable] and re-formed
    // after the decode by the layer that owns the decoder seam
    // (`photo_source.dart`) — which is the only layer that knows whether the
    // decode failed. This loader never performs a decode, so it cannot and
    // must not form that verdict itself.
    //
    // `probe.malformed` can only be true when the walker actually parsed the
    // container and found every DECLARED candidate unreadable (AD-022). Three
    // things are deliberately NOT malformed and therefore keep flowing through
    // with the flag false: a genuinely preview-less container, a G-2 undersized
    // but intact candidate, and a non-TIFF RAW (CR3/RAF/X3F) that bails before
    // IFD0 is readable.
    //
    // Browse-only RAW (D2: `.cr2`/`.iiq`/`.mrw`) is unaffected in both
    // directions: it never reached the pre-empt (that gate was already
    // `isDecodablePath`-gated) and it still falls through to the uniform
    // RAW_NO_EMBEDDED_PREVIEW state below, because there is no decode for it to
    // be routed to (matrix F-08).
    if (purpose == ImageRequestPurpose.preview &&
        SupportedPhotoFormats.isDecodablePath(path)) {
      final dims = await DngEmbeddedJpegExtractor.readImageDimensions(path);
      if (dims != null &&
          dims.width * dims.height * 4 > kDecodedPixelBudgetBytes) {
        // F-20: same budget the deleted native guard enforced
        // (formerly AppDelegate.swift renderCGImage). A header claiming an
        // absurd extent must be an error result, never an OOM.
        return const NativeImageFailure(
          'IMAGE_TOO_LARGE',
          'decode exceeds the decoded-pixel budget',
        );
      }
      // Ruling (b): the raw-decode signal is constructed in Dart from an
      // extraction miss + the walker's own orientation read.
      final orientation = await DngEmbeddedJpegExtractor.readOrientation(path);
      return NativeImageNeedsRawDecode(
        exifOrientation: orientation ?? kDefaultExifOrientation,
        // Carried, not acted on. False here is the ordinary miss ("this
        // container declares no preview"); true is "it declared previews and
        // none were readable". Both route to the decoder identically — the
        // only thing this changes is which failure code surfaces if that
        // decode fails.
        declaredPreviewsUnreadable: embeddedProbe.malformed,
      );
    }
    // Browse-only RAW (D2: `.cr2`/`.iiq`/`.mrw`) with no embedded preview, and
    // any non-preview purpose on a RAW: the explicit uniform unsupported state
    // (matrix F-08, accepted loss U-11). The engine has no decode route for
    // these containers, so there is nothing to fall through to.
    return const NativeImageFailure(
      'RAW_NO_EMBEDDED_PREVIEW',
      'no embedded preview and no decoder for this format',
    );
  } catch (e) {
    return NativeImageFailure('DART_LOADER_ERROR', '$e');
  }
}
