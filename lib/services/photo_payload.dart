import 'package:flutter/foundation.dart';

/// What the pipeline retains for one photo: the cheapest form from which the
/// displayed image can be rebuilt.
///
/// The organising principle (design §2.3): a cache may only hold things that
/// are cheap to regenerate. Before M3 the RAW path violated it -- its only
/// form was a ~50MB decoded `ui.Image` whose rebuild cost a 61-406ms FFI call,
/// so it needed its own narrow window, its own eviction, an ownership contract
/// and an in-flight set. Reducing RAW to window-resolution pixels makes both
/// kinds rebuildable from plain bytes, which is what lets ONE policy serve
/// both (user decision D4).
///
/// [byteCost] is the ONLY thing the cache is allowed to know about a payload.
/// It is deliberately the whole interface: see `photo_payload_cache.dart`,
/// where `grep -c "EncodedPayload\|PixelPayload"` == 0 is an acceptance
/// criterion. These two subclasses live in this file, not that one, so that
/// criterion is structural rather than a matter of discipline.
@immutable
sealed class SourcePayload {
  const SourcePayload();

  /// Resident size in bytes. Retention is decided on this number alone.
  int get byteCost;
}

/// An encoded bitstream (JPEG, PNG, ...) ready for `MemoryImage`/`ResizeImage`.
///
/// This is what a JPEG file, an embedded DNG preview and the legacy CIRAWFilter
/// fallback all reduce to, so all three are literally the same cache citizen.
@immutable
class EncodedPayload extends SourcePayload {
  const EncodedPayload(this.bytes);

  final Uint8List bytes;

  @override
  int get byteCost => bytes.lengthInBytes;
}

/// Already-decoded RGBA8 pixels, downscaled to the display window at decode
/// time and orientation-corrected in that same pass.
///
/// Produced only by `PhotoSource` step 3 (native RAW decode), for the ~1-in-14
/// DNGs that carry no usable embedded JPEG. Rebuilding an image from it is a
/// memcpy plus a GPU upload (measured 18-19.9ms), not an FFI decode -- which
/// is precisely what makes it eligible to live under the same retention rule
/// as [EncodedPayload].
@immutable
class PixelPayload extends SourcePayload {
  PixelPayload({
    required this.rgba,
    required this.width,
    required this.height,
  }) : assert(
         rgba.lengthInBytes == width * height * 4,
         'RGBA8 buffer disagrees with its dimensions',
       );

  /// RGBA8 interleaved, length == width * height * 4.
  final Uint8List rgba;
  final int width;
  final int height;

  @override
  int get byteCost => rgba.lengthInBytes;
}
