import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'photo_payload.dart';

/// An [ImageProvider] backed by retained RGBA8 pixels.
///
/// 1-for-1 replacement for the deleted `DecodedRgbaImageProvider`, and the
/// difference between them is the whole point of M3: that class wrapped a
/// ~50MB `ui.Image` OWNED BY THE PRELOAD CONTROLLER, so every [ImageInfo] it
/// handed out had to be a `clone()` and the controller had to evict before
/// disposing. This class owns nothing. It decodes a FRESH `ui.Image` per load
/// from a plain [Uint8List], so the [ImageCache] owns that image exactly like
/// it owns every `MemoryImage` result, and eviction is just eviction (design
/// §3.2; invariant I5 deliberately dissolved).
///
/// Rebuild cost is a memcpy plus a GPU upload -- measured 18-19.9ms -- not the
/// 61-406ms FFI call it replaces. That is what makes RAW items affordable to
/// keep under the same retention rule as everything else.
@immutable
class RawPixelsImage extends ImageProvider<RawPixelsImage> {
  const RawPixelsImage(this.payload, {this.scale = 1.0});

  final PixelPayload payload;
  final double scale;

  @override
  Future<RawPixelsImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<RawPixelsImage>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    RawPixelsImage key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(
      _decode(key.payload).then(
        (image) => ImageInfo(image: image, scale: key.scale),
      ),
    );
  }

  static Future<ui.Image> _decode(PixelPayload payload) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      payload.rgba,
      payload.width,
      payload.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  // IDENTITY on the pixel buffer, never value equality -- the same rule as
  // `MemoryImage`, and for the same reason (invariant I1). Two providers are
  // the same ImageCache entry exactly when they were built from the SAME
  // retained buffer. If an item leaves the retention window and is re-decoded,
  // it gets a new buffer and therefore a new key, so the stale entry cannot be
  // mistaken for the current one. Value equality here would silently resurrect
  // a cache entry for pixels that are no longer the item's own -- the pixel
  // twin of round-2's BLOCKER 1.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is RawPixelsImage &&
        identical(other.payload.rgba, payload.rgba) &&
        other.payload.width == payload.width &&
        other.payload.height == payload.height &&
        other.scale == scale;
  }

  @override
  int get hashCode => Object.hash(
    identityHashCode(payload.rgba),
    payload.width,
    payload.height,
    scale,
  );

  @override
  String toString() =>
      'RawPixelsImage(${payload.width}x${payload.height}, scale: $scale)';
}
