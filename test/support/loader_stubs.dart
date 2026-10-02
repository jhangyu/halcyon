import 'dart:io';

import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';

/// The ubiquitous "every load needs a RAW decode" stub, EXIF orientation 1.
/// Matches [NativeImageLoad] so it binds directly as `imageLoader:`.
Future<NativeImageResult> needsRawDecodeLoader(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => const NativeImageNeedsRawDecode(exifOrientation: 1);

/// The same stub declaring EXIF orientation 6 (rotated 90° CW).
Future<NativeImageResult> needsRawDecodeLoaderOrientation6(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => const NativeImageNeedsRawDecode(exifOrientation: 6);

/// The same stub declaring EXIF orientation 3 (rotated 180°).
Future<NativeImageResult> needsRawDecodeLoaderOrientation3(
  String path, {
  required ImageRequestPurpose purpose,
  int? targetLongEdge,
}) async => const NativeImageNeedsRawDecode(exifOrientation: 3);

/// One RAW [PhotoItem] per id, file `/tmp/<id>.dng`.
List<PhotoItem> rawItems(List<String> ids) => [
  for (final id in ids) PhotoItem(id: id, files: [File('/tmp/$id.dng')]),
];
