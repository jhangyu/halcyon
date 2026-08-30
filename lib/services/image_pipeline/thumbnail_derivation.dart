import 'decoded_rgba_image_provider.dart';
import 'dng_decode_contract.dart';
import 'photo_payload.dart';
import 'sidebar_thumbnail_codec.dart';

/// The sidebar tile's long edge. Equal to
/// `ImageRequestPurpose.sidebarThumbnail.targetSize`, restated here because
/// this unit no longer participates in the loader's purpose vocabulary at all
/// -- nothing here requests anything from a loader.
const int kSidebarThumbnailLongEdge = 200;

/// Derives a sidebar tile from an ALREADY-PRODUCED payload.
///
/// USER RULING 2026-08-30 (contract D5): "側欄縮圖一律由共享 payload 派生".
/// This is the whole of that rule's implementation, and it is why the sidebar
/// stops being a producer: NO sensor decode runs here, NO file is opened, and
/// no orientation is looked up -- the payload's orientation was baked when it
/// was produced (`photo_source.dart` step 3), so the second orientation read
/// the old sidebar path performed has nothing left to do.
///
/// Returns null on failure. The caller MUST treat null as "not this sweep",
/// never as a permanent miss: the payload may be replaced later by a better
/// one, and a permanent miss is unrecoverable until the folder reloads.
Future<SourcePayload?> deriveThumbnailPayload(
  SourcePayload payload, {
  int longEdge = kSidebarThumbnailLongEdge,
}) async {
  try {
    switch (payload) {
      case EncodedPayload(:final bytes):
        // After the normalisation phase this is EVERY payload: a q70
        // full-resolution JPEG. `sidebarCacheBytes` is the same operation
        // already applied to embedded previews -- one sized engine decode and
        // a small JPEG out -- so there is no new codec and no new dependency.
        //
        // `reencodeThreshold: 0` (amendment E-C3, user ruling "不管多小都縮"):
        // EVERY payload is downscaled regardless of its byte size, so a small
        // already-thumbnail-sized bitstream doesn't slip past the resample
        // and inflate the sidebar's own byte bound (TC-374).
        final small = await sidebarCacheBytes(
          bytes,
          longEdge: longEdge,
          reencodeThreshold: 0,
        );
        return EncodedPayload(small);
      case PixelPayload(:final rgba, :final width, :final height):
        // Reachable only when re-encoding degraded to the pixel fallback.
        // Orientation 1, NOT the file's: these pixels are already oriented,
        // and re-applying the EXIF transform would rotate them twice.
        return await decodedRgbaToPixelPayload(
          DecodedRgba(rgba: rgba, width: width, height: height),
          exifOrientation: 1,
          longEdge: longEdge,
        );
    }
  } catch (_) {
    return null;
  }
}
