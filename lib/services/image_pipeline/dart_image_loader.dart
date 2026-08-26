import 'dart:io';

import '../../models/supported_photo_formats.dart';
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
/// - This file stays free of `Platform` checks by construction (C-3). "No
///   native decoder on this platform" (contract decision D3) is therefore NOT
///   decided here: the loader still reports [NativeImageNeedsRawDecode], and
///   the caller that owns the decoder seam converts an absent decoder into
///   [kNoNativeDecoderCode].
/// - Never throws: every failure is a [NativeImageFailure].
Future<NativeImageResult> dartImageLoad(
  String path, {
  required ImageRequestPurpose purpose,
}) async {
  final lower = path.toLowerCase();
  final isEncodedBitstream =
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.png');
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
    //  - `purpose == export` stays excluded: the escape hatch below is
    //    preview-only, so strictness would turn "export a smaller-than-ideal
    //    image" into "export fails" -- a capability loss G-2 did not ask for.
    //  - browse-only RAW (`.cr2`/`.iiq`/`.mrw`, contract decision D2) stays
    //    excluded for exactly the old reason: the engine cannot decode those
    //    containers, so a rejection would fall through to
    //    RAW_NO_EMBEDDED_PREVIEW rather than to a decode.
    //  - engine-decodable non-DNG RAW (`.arw`/`.nef`/`.rw2`/...) is now
    //    INCLUDED, because the premise that excluded it -- "that escape hatch
    //    is gated on `.dng`" -- is precisely what the contract removed.
    // AD-021's uneven floor is preserved: strict on preview, lenient on
    // sidebar and export. It is not unified.
    final strictPreview =
        purpose == ImageRequestPurpose.preview &&
        SupportedPhotoFormats.isDecodablePath(path);
    final probe = await DngEmbeddedJpegExtractor.probeEmbeddedJpeg(
      path,
      longEdge: null,
      minLongEdge: strictPreview
          ? ImageRequestPurpose.preview.targetSize
          : null,
    );
    final full = probe.jpeg?.bytes;
    if (full != null) return NativeImageBytes(full);
    // M7 Task 3 (audit gaps 2+3): a container that PARSED but declares only
    // unreadable candidates is broken, not preview-less. Before this it fell
    // through to NeedsRawDecode below and failed slowly inside the RAW decoder
    // with a generic error. The valid-miss path — a genuinely preview-less DNG,
    // and an undersized-candidate rejection under G-2 — reports
    // `malformed == false` and is deliberately untouched.
    //
    // Kept in lock-step with the RAW-decode escape hatch below, which is the
    // reason the old gate said `.dng`: this branch exists to stop a
    // structurally damaged container from being handed to the decoder to fail
    // slowly, so it is only meaningful where a decode would otherwise happen.
    // Widened with the hatch to every engine-decodable extension; browse-only
    // RAW (D2) has no decode to pre-empt and keeps its uniform
    // RAW_NO_EMBEDDED_PREVIEW state (matrix F-08).
    //
    // Note `probe.malformed` can only be true when the walker actually parsed
    // the container and found every DECLARED candidate unreadable (AD-022); a
    // non-TIFF RAW (CR3/RAF/X3F) bails before IFD0 and reports
    // `malformed == false`, so widening the gate cannot misclassify those as
    // broken. The code string stays `DNG_PARSE_FAILED` because it is consumed
    // outside this file; renaming the seam vocabulary is contract parking-lot.
    if (probe.malformed && SupportedPhotoFormats.isDecodablePath(path)) {
      return const NativeImageFailure(
        'DNG_PARSE_FAILED',
        'every embedded preview the container declares is unreadable',
      );
    }
    if (purpose == ImageRequestPurpose.preview &&
        SupportedPhotoFormats.isDecodablePath(path)) {
      final dims = await DngEmbeddedJpegExtractor.readImageDimensions(path);
      if (dims != null && dims.width * dims.height * 4 > 1500000000) {
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
