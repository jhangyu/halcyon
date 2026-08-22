import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum ImageRequestPurpose {
  sidebarThumbnail(targetSize: 200, platformValue: 'sidebarThumbnail'),
  // Native RAW preview extraction honours this value as an honest cap
  // (AppDelegate.swift no longer overrides it with an 8000px sentinel).
  // 2800px approximates a typical retina window long edge x2; if a real
  // window-size channel becomes available (AppState-driven, out of this
  // file's ownership), this static default can be replaced with a
  // per-request value without changing the channel argument shape.
  preview(targetSize: 2800, platformValue: 'preview'),
  // Social-media export: long edge capped at 2048px, aspect ratio preserved,
  // all EXIF carried over with Orientation forced to 1 (pixels are already
  // rotated). Handled natively by its own branch in AppDelegate.swift, which
  // deliberately bypasses the JPEG / DNG raw-bytes passthroughs -- those return
  // the ORIGINAL file bytes, which would defeat the whole point of an export.
  export(targetSize: 2048, platformValue: 'export');

  const ImageRequestPurpose({
    required this.targetSize,
    required this.platformValue,
  });

  final int targetSize;
  final String platformValue;
}

/// Outcome of a native image-bytes request.
///
/// ROUND-3B FROZEN INTEGRATION TYPE (pipe squad). Written by the squad lead
/// before implementation started so the native-signal half and the decode/
/// display half program against the same shape without negotiating it
/// mid-flight. Exactly three variants; do not add a fourth without the
/// squad lead's sign-off.
sealed class NativeImageResult {
  const NativeImageResult();
}

/// The native side returned encoded image bytes (JPEG). The pre-existing
/// happy path; replaces the old non-null `Uint8List` return.
class NativeImageBytes extends NativeImageResult {
  const NativeImageBytes(this.bytes);

  final Uint8List bytes;
}

/// The file is a DNG that carries no embedded full-size JPEG preview, so the
/// caller must run a real RAW decode (see `DngFullDecoder` in
/// `dng_decode_contract.dart`). This is NOT a failure.
///
/// [exifOrientation] is the IFD0 Orientation tag value, in the range 1..8; it
/// is [kDefaultExifOrientation] when the tag is absent or unparseable. It may
/// be read natively (macOS, via the [kNoEmbeddedPreviewCode] channel error) or
/// in Dart (via `DngPreviewExtractor.readOrientationFromFile`, on platforms
/// whose native bridge does not emit that code). The decoder does not apply
/// EXIF orientation, so Halcyon must.
class NativeImageNeedsRawDecode extends NativeImageResult {
  const NativeImageNeedsRawDecode({required this.exifOrientation});

  final int exifOrientation;
}

/// A genuine failure (unreadable file, convert failure, native error).
/// Replaces the old `null` return; callers must treat this, and only this,
/// as "no image available".
class NativeImageFailure extends NativeImageResult {
  const NativeImageFailure(this.code, this.message);

  final String code;
  final String? message;
}

/// EXIF Orientation value meaning "no transform"; also the fallback used when
/// the tag is missing or outside the 1..8 range.
const int kDefaultExifOrientation = 1;

/// Native error code signalling [NativeImageNeedsRawDecode]. Emitted by
/// `macos/Runner/AppDelegate.swift` only for `purpose == "preview"` on a
/// `.dng` whose embedded-JPEG extraction returned nil. It is NOT the only
/// source of [NativeImageNeedsRawDecode]: `windows/runner/halcyon_image.cpp`
/// deliberately returns `RAW_UNSUPPORTED` instead, and the Dart pipeline
/// synthesises the variant itself in that case (see AD-010's 2026-08-22
/// amendment). Do not reintroduce an assumption that this code is the only
/// way the raw-decode path can be entered.
const String kNoEmbeddedPreviewCode = 'NO_EMBEDDED_PREVIEW';

/// Channel argument name for opting OUT of the [kNoEmbeddedPreviewCode]
/// signal. When `false`, the native side keeps the pre-round-3b behaviour:
/// a DNG with no embedded preview falls silently through to the CIRAWFilter
/// path. This is the safety fallback, used by [NativeThumbnailService.getThumbnail].
const String kAllowRawDecodeSignalArg = 'allowRawDecodeSignal';

class NativeThumbnailService {
  static const MethodChannel _channel = MethodChannel('halcyon/thumbnail');

  /// Requests image bytes from the native platform, distinguishing "this DNG
  /// needs a real RAW decode" ([NativeImageNeedsRawDecode]) from a genuine
  /// failure ([NativeImageFailure]).
  ///
  /// Set [allowRawDecodeSignal] to false to force the legacy behaviour, in
  /// which a DNG with no embedded preview is decoded natively via CIRAWFilter
  /// and returned as bytes (slow, capped at `targetSize`). That is the
  /// fallback used when no `DngFullDecoder` is available or when one throws.
  static Future<NativeImageResult> requestImage(
    String path, {
    ImageRequestPurpose purpose = ImageRequestPurpose.preview,
    int? targetSize,
    bool allowRawDecodeSignal = true,
  }) async {
    try {
      final Uint8List? bytes = await _channel.invokeMethod('getThumbnail', {
        'path': path,
        'purpose': purpose.platformValue,
        'targetSize': targetSize ?? purpose.targetSize,
        kAllowRawDecodeSignalArg: allowRawDecodeSignal,
      });
      if (bytes == null) {
        return const NativeImageFailure('NULL_RESULT', 'Native returned null');
      }
      return NativeImageBytes(bytes);
    } on PlatformException catch (e) {
      if (e.code == kNoEmbeddedPreviewCode) {
        return NativeImageNeedsRawDecode(
          exifOrientation: _parseOrientation(e.details),
        );
      }
      debugPrint("Failed to get native thumbnail: '${e.message}'.");
      return NativeImageFailure(e.code, e.message);
    } on MissingPluginException catch (e) {
      // No native handler registered for `halcyon/thumbnail` at all (e.g.
      // Windows/Android/iOS, which have no MethodChannel implementation --
      // see cross-platform-port-inventory.md P0 item 3). MissingPluginException
      // does NOT extend PlatformException, so it needs its own clause; without
      // it this throws out of requestImage, through `_loadPreview`'s
      // `catch (_) { rethrow; }` in image_preload_controller.dart, and crashes
      // the preload pipeline instead of degrading like TrashService does.
      debugPrint("Thumbnail service is unavailable: '${e.message}'.");
      return const NativeImageFailure(
        'MISSING_PLUGIN',
        'Thumbnail service is unavailable on this platform',
      );
    }
  }

  /// Legacy bytes-or-null entry point, preserved bit-for-bit for callers that
  /// cannot handle the round-3b result type (`lib/perf/perf_driver.dart`, and
  /// the raw-decode fallback path). Always sends
  /// [kAllowRawDecodeSignalArg] = false, so the native side behaves exactly as
  /// it did before round 3b.
  static Future<Uint8List?> getThumbnail(
    String path, {
    ImageRequestPurpose purpose = ImageRequestPurpose.preview,
    int? targetSize,
  }) async {
    final result = await requestImage(
      path,
      purpose: purpose,
      targetSize: targetSize,
      allowRawDecodeSignal: false,
    );
    return result is NativeImageBytes ? result.bytes : null;
  }

  /// EXIF Orientation is 1..8; anything else (absent, wrong type, out of
  /// range) degrades to [kDefaultExifOrientation] rather than throwing.
  static int _parseOrientation(Object? details) {
    if (details is int && details >= 1 && details <= 8) return details;
    return kDefaultExifOrientation;
  }
}
