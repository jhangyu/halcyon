import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'decoded_rgba_image_provider.dart';
import 'dng_decode_contract.dart';

/// Bounds what the sidebar byte cache stores (M6 F-10 half 2).
///
/// The native 200px branch used to re-encode; the Dart producer returns
/// original bytes for encoded bitstreams. Payloads at or under
/// [reencodeThreshold] pass through untouched (embedded DNG candidates are
/// already thumbnail-sized). Larger ones are decoded ONCE with the long edge
/// capped at [longEdge] and re-encoded as PNG through dart:ui — no external
/// codec dependency.
///
/// ponytail: PNG (not JPEG) because dart:ui only encodes PNG; P3.6 adopts the
/// `image` package for export — if sidebar memory ever matters more, switch
/// this to JPEG-q80 there.
Future<Uint8List> sidebarCacheBytes(
  Uint8List encoded, {
  int longEdge = 200,
  int reencodeThreshold = 512 * 1024,
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
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    if (data == null) return encoded;
    return data.buffer.asUint8List();
  } catch (_) {
    // Undecodable input: cache the original rather than dropping the row.
    return encoded;
  }
}

/// Turns a freshly-decoded RAW frame into sidebar-cache-ready PNG bytes (M6
/// P2.5b, the sidebar RAW-decode fallback for bare-CFA DNGs with no embedded
/// JPEG at any size). Reuses [decodedRgbaToPixelPayload] for the
/// orientation-bake + downscale (already exercised by the detail-view
/// pipeline; not reimplemented here), then encodes the resulting pixels as a
/// PNG via `dart:ui`'s pixel decoder -- the same primitive
/// `decoded_rgba_image_provider.dart` already uses to build a [ui.Image]
/// from raw RGBA8.
Future<Uint8List> pngFromOrientedPixels(
  DecodedRgba decoded, {
  required int exifOrientation,
  int longEdge = 200,
}) async {
  final payload = await decodedRgbaToPixelPayload(
    decoded,
    exifOrientation: exifOrientation,
    longEdge: longEdge,
  );
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    payload.rgba,
    payload.width,
    payload.height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  final image = await completer.future;
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      throw StateError('could not encode oriented RAW pixels to PNG');
    }
    return data.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}
