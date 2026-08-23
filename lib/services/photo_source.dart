import 'dart:typed_data';

import 'dng_preview_extractor.dart';

/// M2: behavior-preserving extraction. This is the ONE place in the Dart
/// pipeline that still branches on file type — everything else routes
/// through the native `ImageBytesLoader` seam and the `DngFullDecoder` seam,
/// neither of which cares about the extension.
///
/// Design authority: `docs/logs/2026-08-23/image-pipeline-redesign-handover.md`
/// §3.1 (`PhotoSource`) / §6 (M2). M2 only relocates the existing branch out
/// of `image_preload_controller.dart` behind the seam it already used
/// (`DngPreviewExtractor`); it does not change what the branch decides or
/// when it runs. M3 is where this grows into the full `(path, longEdge) ->
/// SourcePayload?` content-sniffing selector described in the design doc.
class PhotoSource {
  const PhotoSource._();

  /// Last-resort preview recovery after the native preview channel has
  /// already failed entirely (`NativeImageFailure`). Only a `.dng` gets a
  /// second try, via the pure-Dart embedded-JPEG extractor — additive, and
  /// only reachable when native extraction already failed, so it never
  /// fires on a platform where native extraction succeeded (macOS
  /// unaffected).
  ///
  /// Returns the extracted bytes, or null if [path] is not a `.dng` (or
  /// extraction found nothing). Mirrors the pre-M2 inline check in
  /// `image_preload_controller.dart` byte-for-byte: same extension test,
  /// same extractor call, same null-propagation on failure.
  static Future<Uint8List?> fallbackAfterNativeFailure(String path) async {
    if (!path.toLowerCase().endsWith('.dng')) return null;
    return DngPreviewExtractor.extractFullSizeEmbeddedJpegFromFile(path);
  }
}
