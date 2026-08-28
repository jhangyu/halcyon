import 'dart:io';

import '../../models/photo_item.dart';
import '../../models/supported_photo_formats.dart';
import '../image_pipeline/dng_embedded_jpeg_extractor.dart';

class PhotoLibraryScanner {
  /// Injectable so the sibling-ranking decision can be tested without a real
  /// TIFF on disk. Answers "does this TIFF carry an embedded already-rendered
  /// image?" by reusing the same bounded IFD0 walk DNG/RAW previews use — a TIFF
  /// with an embedded JPEG rendition (`largestLongEdge > 0`) is cheap to
  /// display; one without is a RAW carrier (D2 ruling).
  final Future<bool> Function(String path) tiffEmbeddedPreviewProbe;

  PhotoLibraryScanner({
    Future<bool> Function(String path)? tiffEmbeddedPreviewProbe,
  }) : tiffEmbeddedPreviewProbe =
           tiffEmbeddedPreviewProbe ?? _defaultTiffEmbeddedPreviewProbe;

  static Future<bool> _defaultTiffEmbeddedPreviewProbe(String path) async {
    final probe = await DngEmbeddedJpegExtractor.probeContent(path);
    return probe != null && probe.largestLongEdge > 0;
  }

  Future<List<PhotoItem>> scan(Directory dir) async {
    final entities = await dir.list(followLinks: false).toList();
    final grouped = <String, List<File>>{};

    for (final entity in entities) {
      if (entity is! File) continue;

      final name = entity.uri.pathSegments.last;
      if (name.startsWith('.')) continue;
      if (!SupportedPhotoFormats.isSupportedPath(entity.path)) continue;

      final id = SupportedPhotoFormats.photoIdFor(entity);
      grouped.putIfAbsent(id, () => <File>[]).add(entity);
    }

    final items = <PhotoItem>[];
    for (final entry in grouped.entries) {
      final resolved = await SupportedPhotoFormats.resolveBestFileToLoad(
        entry.value,
        probe: tiffEmbeddedPreviewProbe,
      );
      items.add(
        PhotoItem(
          id: entry.key,
          files: entry.value,
          resolvedBestFile: resolved,
        ),
      );
    }
    items.sort((a, b) => a.id.toLowerCase().compareTo(b.id.toLowerCase()));
    return items;
  }
}
