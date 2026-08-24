import 'dart:io';

import 'dng_preview_extractor.dart';
import 'native_thumbnail_service.dart';

/// Pure-Dart production implementation of the `NativeImageLoad` seam
/// (photo_source.dart:76-80). Replaces the `halcyon/thumbnail` channel as the
/// production byte producer (M6 C-1/C-2); the channel service remains only
/// until P3 deletes it. Free of Platform checks by construction (C-3).
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
  final isEncodedBitstream = lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.png');
  try {
    if (isEncodedBitstream) {
      return NativeImageBytes(await File(path).readAsBytes());
    }
    if (!await File(path).exists()) {
      // Deviation from the plan's verbatim listing (reported to the lead):
      // the walker degrades a missing file to the same "no candidate" null
      // as a genuine no-preview DNG, which would otherwise misclassify a
      // missing file as NeedsRawDecode instead of an explicit failure — the
      // exact case test/dart_image_loader_test.dart's "missing file is a
      // failure, not a throw" pins.
      return const NativeImageFailure('NOT_FOUND', 'file does not exist');
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
    final full =
        await DngPreviewExtractor.extractFullSizeEmbeddedJpegFromFile(path);
    if (full != null) return NativeImageBytes(full);
    if (purpose == ImageRequestPurpose.preview && lower.endsWith('.dng')) {
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
