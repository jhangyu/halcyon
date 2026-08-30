import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'jpeg_encoder.dart';

/// Bounds what the sidebar byte cache stores (M6 F-10 half 2).
///
/// The native 200px branch used to re-encode; the Dart producer returns
/// original bytes for encoded bitstreams. Payloads at or under
/// [reencodeThreshold] pass through untouched (embedded DNG candidates are
/// already thumbnail-sized). Larger ones are decoded ONCE with the long edge
/// capped at [longEdge] and re-encoded as JPEG at [jpegQuality].
///
/// JPEG, not PNG: this used to encode PNG because `dart:ui` is PNG-only, with
/// a note to switch once the `image` package landed for export. It has
/// (P3.6, `dd1edcb`), so M7 cashes that in -- PNG is lossless and several
/// times larger than q70 JPEG on photographic content, which is all the
/// sidebar ever holds. The generational loss is irrelevant: these bytes are
/// display-only thumbnails and are never written back to disk. JPEG cannot
/// carry alpha, which is likewise fine for photographic sources.
Future<Uint8List> sidebarCacheBytes(
  Uint8List encoded, {
  int longEdge = 200, // = ImageRequestPurpose.sidebarThumbnail.targetSize
  int reencodeThreshold = 512 * 1024,
  int jpegQuality = kDisplayJpegQuality,
}) async {
  if (encoded.length <= reencodeThreshold) return encoded;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(encoded);
    final codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (int width, int height) {
        if (width <= longEdge && height <= longEdge) {
          return ui.TargetImageSize(width: width, height: height);
        }
        return width >= height
            ? ui.TargetImageSize(width: longEdge)
            : ui.TargetImageSize(height: longEdge);
      },
    );
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    final width = frame.image.width;
    final height = frame.image.height;
    frame.image.dispose();
    if (data == null) return encoded;
    return encodeJpegFromRgba(
      data.buffer.asUint8List(),
      width: width,
      height: height,
      quality: jpegQuality,
    );
  } catch (_) {
    // Undecodable input: cache the original rather than dropping the row.
    return encoded;
  }
}

/// The default [sidebarCacheBytes] uses, exposed so a test can assert the
/// shared-constant wiring: a default parameter value is not otherwise
/// reachable from outside the function.
@visibleForTesting
const int defaultSidebarJpegQuality = kDisplayJpegQuality;
