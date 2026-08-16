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
  preview(targetSize: 2800, platformValue: 'preview');

  const ImageRequestPurpose({
    required this.targetSize,
    required this.platformValue,
  });

  final int targetSize;
  final String platformValue;
}

class NativeThumbnailService {
  static const MethodChannel _channel = MethodChannel('halcyon/thumbnail');

  /// Requests the native platform to extract a thumbnail from the given file path.
  static Future<Uint8List?> getThumbnail(
    String path, {
    ImageRequestPurpose purpose = ImageRequestPurpose.preview,
    int? targetSize,
  }) async {
    try {
      final Uint8List? bytes = await _channel.invokeMethod('getThumbnail', {
        'path': path,
        'purpose': purpose.platformValue,
        'targetSize': targetSize ?? purpose.targetSize,
      });
      return bytes;
    } on PlatformException catch (e) {
      debugPrint("Failed to get native thumbnail: '${e.message}'.");
      return null;
    }
  }
}
