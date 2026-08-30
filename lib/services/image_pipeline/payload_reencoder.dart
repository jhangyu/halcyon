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

/// q70 -- what EVERY retained payload is encoded at, RAW and JPG alike.
///
/// USER RULING 2026-08-30 (contract D5), superseding the q80 default recorded
/// below: under the shared-payload design one q70 bitstream serves the main
/// preview, the tier-1 downscale AND the sidebar tile, and the sidebar tile is
/// a 200px resample where q70 vs q80 is invisible. The bytes are display-only
/// (export re-reads the original file, `photo_export_service.dart`), so the
/// extra q80 bytes buy detail nothing writes back to disk -- and they are
/// bytes the payload budget has to hold for every item a scroll touches.
///
/// Superseded history, kept because the reasoning still applies one step down:
/// q90 -> q80 (2026-08-30, same ruling family) for the same display-only
/// argument.
///
/// NOT the same number as `sidebar_thumbnail_codec.dart`'s `jpegQuality: 80`:
/// that one encodes a 200px tile and was only ever coincidentally equal.
const int kReencodeJpegQuality = 70;

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
/// Every failure degrades to [fallback] -- window-resolution pixels for the
/// RAW decode path, or the original encoded bytes for `normalizeEncodedPayload`
/// (Task 2), depending on the caller -- so the item renders exactly as it did
/// before this phase existed. Failure is never an error and never a permanent
/// miss.
///
/// This function's guards are not the only refusal in the pipeline: when the
/// caller is `normalizeEncodedPayload` (`payload_normalizer.dart`, amendment
/// E-M1), that caller applies one more, independent check AFTER this function
/// returns -- discarding a smaller-than-expected win by keeping the original
/// bytes if the re-encoded result is not actually smaller than the input, on
/// top of its own small-input passthrough before this function is ever
/// called. See `normalizeEncodedPayload`'s dartdoc for both.
Future<SourcePayload> reencodePayload({
  required PayloadEncoder encoder,
  required SourcePayload fallback,
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
