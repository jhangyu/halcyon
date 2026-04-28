import 'dart:io';

import 'supported_photo_formats.dart';

enum PhotoStatus { unmarked, starred, trashed }

class PhotoItem {
  final String id;
  final List<File> files;
  PhotoStatus status;

  PhotoItem({
    required this.id,
    required this.files,
    this.status = PhotoStatus.unmarked,
  });

  String get displayName => id;

  /// Prefer loading JPG/PNG versions of the file over RAW if available,
  /// as they are smaller and faster to extract thumbnails from or decode.
  File? get bestFileToLoad {
    return SupportedPhotoFormats.bestFileToLoad(files);
  }
}
