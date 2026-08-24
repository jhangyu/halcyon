import 'dart:io';

import 'dng_preview_extractor.dart';
import 'image_source_types.dart';

/// Pure-Dart production implementation of the `NativeImageLoad` seam
/// (photo_source.dart:76-80). Replaces the deleted native thumbnail
/// MethodChannel as the production byte producer (M6 C-1/C-2). Free of
/// Platform checks by construction (C-3).
///
/// Invariants carried over from the native producer:
/// - [NativeImageNeedsRawDecode] is emitted ONLY for
///   `purpose == ImageRequestPurpose.preview` on a `.dng`; the sidebar's
///   permanent-miss logic (image_preload_controller.dart:1179-1196) depends
///   on never seeing it for sidebarThumbnail.
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
      final candidate = await DngPreviewExtractor.extractEmbeddedJpeg(
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
    // The guard is deliberately narrower than "the preview purpose":
    //  - `purpose == sidebarThumbnail` never reaches here; the sidebar branch
    //    above stays lenient under rulings P-11/P-13.
    //  - `purpose == export` is excluded because the RAW-decode escape hatch
    //    below is unreachable for it, so strictness would turn "export a
    //    smaller-than-ideal image" into "export fails" -- a capability loss
    //    G-2 did not ask for.
    //  - non-DNG RAW (`.cr2`/`.nef`/`.arw`) is excluded for exactly the same
    //    reason: that escape hatch is gated on `.dng`, so a rejection there
    //    would fall through to RAW_NO_EMBEDDED_PREVIEW rather than to a decode
    //    (M7 Decision Log A-6). G-2 is a DNG ruling and stays one.
    final strictPreview =
        purpose == ImageRequestPurpose.preview && lower.endsWith('.dng');
    final probe = await DngPreviewExtractor.probeEmbeddedJpeg(
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
    // Gated on `.dng` for the same reason the RAW-decode escape hatch below is:
    // this is a DNG-container verdict, and a non-DNG RAW keeps its uniform
    // RAW_NO_EMBEDDED_PREVIEW state (matrix F-08).
    if (probe.malformed && lower.endsWith('.dng')) {
      return const NativeImageFailure(
        'DNG_PARSE_FAILED',
        'every embedded preview the container declares is unreadable',
      );
    }
    if (purpose == ImageRequestPurpose.preview && lower.endsWith('.dng')) {
      final dims = await DngPreviewExtractor.readImageDimensions(path);
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
      final orientation = await DngPreviewExtractor.readOrientation(path);
      return NativeImageNeedsRawDecode(
        exifOrientation: orientation ?? kDefaultExifOrientation,
      );
    }
    // Non-DNG RAW (or any non-TIFF) with no embedded preview: the explicit
    // uniform unsupported state (matrix F-08, accepted loss U-11).
    return const NativeImageFailure(
      'RAW_NO_EMBEDDED_PREVIEW',
      'no embedded preview and no decoder for this format',
    );
  } catch (e) {
    return NativeImageFailure('DART_LOADER_ERROR', '$e');
  }
}
