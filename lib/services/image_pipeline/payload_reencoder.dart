import 'package:flutter/foundation.dart';

import 'photo_payload.dart';

/// The seam through which decoded RAW pixels become an encoded bitstream.
///
/// Injected rather than called directly so the pipeline can be unit-tested
/// without spawning an isolate, mirroring the `DngFullDecoder` seam. The
/// production binding is `encodeJpegFromRgba` (`jpeg_encoder.dart`).
typedef PayloadEncoder =
    Future<Uint8List> Function(
      Uint8List rgba, {
      required int width,
      required int height,
      required int quality,
    });

/// q80 -- the same quality the sidebar codec uses (`sidebar_thumbnail_codec.dart`).
///
/// USER RULING 2026-08-30, superseding an earlier q90 default: these bytes are
/// display-only (export re-reads the original file), so the extra q90 bytes buy
/// detail nothing writes back to disk. Under the one-buffer design this SAME
/// bitstream serves both the 100%-zoom view and the downscaled tier-1 view, so
/// there is no higher-fidelity copy anywhere -- which is exactly why the
/// quality is a user decision and not an implementer's default.
const int kReencodeJpegQuality = 80;

/// How many times re-encoding degraded to the retained-pixels fallback.
///
/// Observability, not policy: a re-encode that silently failed on every item
/// would look exactly like the pre-Phase-13 behaviour, and the whole phase
/// would be a no-op nobody noticed.
@visibleForTesting
int reencodeFallbacks = 0;

@visibleForTesting
void resetReencodeCounters() {
  reencodeFallbacks = 0;
}

/// Turns the FULL-RESOLUTION pixels produced by ONE RAW decode into the single
/// bitstream this item will retain -- once, in final form.
///
/// One buffer, by user ruling (2026-08-30): the retained `EncodedPayload.bytes`
/// IS the full-resolution JPEG, exactly as a JPG file's bytes are, so both
/// tiers read one buffer and a RAW item stops being a special cache citizen.
///
/// The result is written to the payload cache unchanged and NEVER swapped
/// afterwards: payload object identity is the tier-1 ImageCache key and the
/// tier-2 registry's readiness anchor, so a later swap orphans both.
///
/// Every failure degrades to [fallback] -- the window-resolution pixels the
/// decode already produced -- so the item renders exactly as it did before this
/// phase existed. Failure is never an error and never a permanent miss.
Future<SourcePayload> reencodePayload({
  required PayloadEncoder encoder,
  required PixelPayload fallback,
  required ({Uint8List rgba, int width, int height})? fullRes,
  int quality = kReencodeJpegQuality,
}) async {
  if (fullRes == null) {
    // Nothing to encode. Deliberately NOT falling back to encoding the
    // window-resolution pixels: those would land in the full-size tier and
    // silently show a low-resolution frame at 100% zoom.
    reencodeFallbacks++;
    return fallback;
  }

  // The native encoder trusts width*height to bound its scanline reads
  // (encode_ffi_api.cpp cannot itself validate the buffer's real length --
  // it only has the pointer and the claimed dimensions). A short buffer
  // would be a heap OOB read in release. Every other consumer of a decoded
  // RGBA record either asserts this invariant (debug-only) or bails on
  // mismatch (tier_two_scheduler.dart); this is the only unguarded one.
  if (fullRes.rgba.lengthInBytes != fullRes.width * fullRes.height * 4) {
    reencodeFallbacks++;
    return fallback;
  }

  Uint8List jpeg;
  try {
    jpeg = await encoder(
      fullRes.rgba,
      width: fullRes.width,
      height: fullRes.height,
      quality: quality,
    );
  } catch (_) {
    reencodeFallbacks++;
    return fallback;
  }
  if (jpeg.isEmpty) {
    reencodeFallbacks++;
    return fallback;
  }

  return EncodedPayload(jpeg);
}
