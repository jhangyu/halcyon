import 'dart:io';

import '../models/photo_item.dart';
import '../models/supported_photo_formats.dart';

class PhotoLibraryScanner {
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

    final items = grouped.entries
        .map((entry) => PhotoItem(id: entry.key, files: entry.value))
        .toList();
    items.sort((a, b) => a.id.toLowerCase().compareTo(b.id.toLowerCase()));
    return items;
  }
}
