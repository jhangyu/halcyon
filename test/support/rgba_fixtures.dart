import 'dart:typed_data';

import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';

/// A [width]×[height] decoded frame: zeroed RGB, alpha 0xFF (opaque — the
/// debug-only identity short-circuit in decoded_rgba_image_provider.dart
/// asserts sampled alpha is opaque).
///
/// Allocates a FRESH buffer on every call: buffer-release and residency tests
/// mutate/release the returned buffer, so a cached instance would leak state
/// across tests. Never memoize this.
DecodedRgba opaqueRgba(int width, int height) {
  final rgba = Uint8List(width * height * 4);
  for (var i = 3; i < rgba.length; i += 4) {
    rgba[i] = 0xFF;
  }
  return DecodedRgba(rgba: rgba, width: width, height: height);
}
