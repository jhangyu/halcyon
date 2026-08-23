import 'dart:io';
import 'dart:typed_data';

import 'decoded_rgba_image_provider.dart';
import 'dng_decode_contract.dart';
import 'dng_preview_extractor.dart';
import 'native_thumbnail_service.dart';
import 'photo_payload.dart';

/// How expensive it is to produce this file's payload, MEASURED from content.
///
/// The scheduler is the only thing that reads it (design §3.3). It is declared
/// here rather than in `prefetch_scheduler.dart` because [PhotoSource.probe]
/// is what produces it and the scheduler imports this file -- the other
/// direction would be an import cycle. The scheduler re-exports it, so
/// `SourceCost` is still spelled the way the design doc spells it.
enum SourceCost {
  /// An encoded bitstream is already sitting in the file: the JPEG itself, or
  /// an embedded preview big enough for the window. Cheap enough to prefetch
  /// across the whole retention window with no debounce.
  cheap,

  /// No usable embedded JPEG -- producing pixels means a real RAW decode
  /// (measured 61-406ms, and it saturates cores). Confined to +/-1 behind the
  /// navigation debounce.
  expensive,
}

/// What one attempt to produce a payload actually observed.
typedef SourceOutcome = ({SourcePayload? payload, SourceCost? observedCost});

/// The seam through which the native (or faked) preview bridge is called.
/// Written structurally rather than importing `ImagePreloadController`'s
/// typedef, which would be an import cycle; Dart function types are
/// structural, so every existing test fake satisfies this unchanged.
typedef NativeImageLoad =
    Future<NativeImageResult> Function(
      String path, {
      required ImageRequestPurpose purpose,
    });

/// The ONE place in the Dart pipeline that knows about file types.
///
/// Everything above it -- the scheduler, the payload cache, the two tier
/// providers -- is type-blind by construction (user decision D3/D4). Design
/// authority: `docs/logs/2026-08-23/image-pipeline-redesign-handover.md` §3.1.
class PhotoSource {
  const PhotoSource({required this.loader, this.dngDecoder});

  final NativeImageLoad loader;

  /// Null when no RAW decoder is available. Every use is guarded by step 3b:
  /// no decoder (or a throwing one) re-requests through
  /// `NativeThumbnailService.getThumbnail`, which forces
  /// `allowRawDecodeSignal: false` and so reproduces the pre-round-3b
  /// CIRAWFilter path byte-for-byte. Degraded, never blank.
  final DngFullDecoder? dngDecoder;

  /// Produces the payload for [path] at [longEdge], plus what that attempt
  /// revealed about the file's cost.
  ///
  /// Steps, per §3.1:
  ///   1/2. the native bridge answers with an encoded bitstream (the file
  ///        itself for a JPEG, or the embedded preview it selected)
  ///   3.   no usable embedded JPEG -> RAW decode, immediately reduced to
  ///        window-resolution oriented pixels
  ///   3b.  no decoder, or the decoder threw -> legacy CIRAWFilter bytes
  ///   4.   nothing worked -> null payload, which the caller MUST record as a
  ///        permanent miss (see §3.4: this is the one path where a spinner
  ///        could otherwise strand forever)
  ///
  /// [allowExpensive] false stops at the discovery: the bridge is asked (which
  /// is how the cost is learned at all, and is the same single round trip the
  /// pre-M3 code made for every item in the window), but no RAW decode and no
  /// legacy fallback runs. The caller gets `observedCost: expensive` with a
  /// null payload and re-enters later from the debounced +/-1 pass. Without
  /// this split, discovering an item's cost would itself perform the work the
  /// cost gate exists to defer, and a 9-step navigation burst would fire nine
  /// FFI decodes -- the exact D2 violation.
  Future<SourceOutcome> load(
    String path, {
    required int longEdge,
    bool allowExpensive = true,
  }) async {
    final result = await loader(path, purpose: ImageRequestPurpose.preview);
    switch (result) {
      case NativeImageBytes(:final bytes):
        return (payload: EncodedPayload(bytes), observedCost: SourceCost.cheap);

      case NativeImageNeedsRawDecode(:final exifOrientation):
        if (!allowExpensive) {
          return (payload: null, observedCost: SourceCost.expensive);
        }
        final decoder = dngDecoder;
        if (decoder == null) {
          return (
            payload: await _legacyBytes(path),
            observedCost: SourceCost.expensive,
          );
        }
        try {
          final decoded = await decoder(path);
          final pixels = await decodedRgbaToPixelPayload(
            decoded,
            exifOrientation: exifOrientation,
            longEdge: longEdge,
          );
          return (payload: pixels, observedCost: SourceCost.expensive);
        } catch (_) {
          // Step 3b. A throwing decoder must degrade to the old slow path,
          // never to a blank screen (frozen design §2, oracle-protected at
          // test/image_preload_controller_test.dart:1118-1120).
          return (
            payload: await _legacyBytes(path),
            observedCost: SourceCost.expensive,
          );
        }

      case NativeImageFailure():
        // No native bridge succeeded (including MISSING_PLUGIN on a platform
        // with no bridge at all). The pure-Dart embedded-JPEG walker is the
        // last resort; a null here is a genuine "unreadable".
        final recovered = await fallbackAfterNativeFailure(path);
        return (
          payload: recovered == null ? null : EncodedPayload(recovered),
          observedCost: recovered == null ? null : SourceCost.cheap,
        );
    }
  }

  /// Step 3b: re-request with `allowRawDecodeSignal` forced false, which is
  /// what `NativeThumbnailService.getThumbnail` always sends. Reproduces the
  /// pre-round-3b native behaviour byte-for-byte: CIRAWFilter, 2800px cap,
  /// slow -- but a picture.
  ///
  /// A null return means BOTH the decode and the legacy path failed. The
  /// caller must mark a permanent miss on it; that is the load-bearing edge
  /// §3.4 names as the only new stranding risk in M3.
  static Future<EncodedPayload?> _legacyBytes(String path) async {
    final bytes = await NativeThumbnailService.getThumbnail(
      path,
      purpose: ImageRequestPurpose.preview,
    );
    return bytes == null ? null : EncodedPayload(bytes);
  }

  /// Measures [path]'s cost from its CONTENT, reading at most a few tens of KB
  /// and never a JPEG strip.
  ///
  /// Returns null when the content cannot be measured (missing file,
  /// unreadable, not a TIFF/JPEG at all) -- deliberately distinct from
  /// [SourceCost.expensive], because the caller resolves the undetermined case
  /// from the first bridge answer instead of guessing (frozen contract A-§2).
  ///
  /// This replaces the `.dng` extension test that decided the rung before M3
  /// and was wrong 13 times in 14. It also gets non-DNG raw formats for free:
  /// the walker only checks the TIFF magic, never the extension.
  static Future<SourceCost?> probe(
    String path, {
    required int longEdge,
    void Function(int byteCount)? onDiskRead,
  }) async {
    // Step 1: the file IS a bitstream. Two bytes and out -- this is the JPEG
    // hot path and it must stay free (design §5).
    final head = await _readHead(path, onDiskRead: onDiskRead);
    if (head == null) return null;
    if (head.length >= 2 && head[0] == 0xFF && head[1] == 0xD8) {
      return SourceCost.cheap;
    }

    // Step 2: walk the IFDs for the biggest embedded JPEG, without reading it.
    final largest = await DngPreviewExtractor.largestCandidateLongEdge(
      path,
      onDiskRead: onDiskRead,
    );
    if (largest == null) return null;
    return largest >= longEdge ? SourceCost.cheap : SourceCost.expensive;
  }

  static Future<Uint8List?> _readHead(
    String path, {
    void Function(int byteCount)? onDiskRead,
  }) async {
    RandomAccessFile? raf;
    try {
      raf = await File(path).open();
      final head = await raf.read(2);
      onDiskRead?.call(head.length);
      return head;
    } catch (_) {
      return null;
    } finally {
      try {
        await raf?.close();
      } catch (_) {
        // Closing a handle we already failed on is not actionable.
      }
    }
  }

  /// Last-resort preview recovery after the native preview channel has already
  /// failed entirely (`NativeImageFailure`). Only a `.dng` gets a second try,
  /// via the pure-Dart embedded-JPEG extractor -- additive, and only reachable
  /// when native extraction already failed, so it never fires on a platform
  /// where native extraction succeeded (macOS unaffected).
  ///
  /// Returns the extracted bytes, or null if [path] is not a `.dng` (or
  /// extraction found nothing).
  static Future<Uint8List?> fallbackAfterNativeFailure(String path) async {
    if (!path.toLowerCase().endsWith('.dng')) return null;
    return DngPreviewExtractor.extractFullSizeEmbeddedJpegFromFile(path);
  }
}
