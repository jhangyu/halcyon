import 'dart:io';

import 'package:path/path.dart' as p;

import 'supported_photo_formats.dart';

enum PhotoStatus { unmarked, starred, trashed }

class PhotoItem {
  final String id;
  final List<File> files;
  PhotoStatus status;

  /// The sibling chosen by the I/O-aware ranking
  /// ([SupportedPhotoFormats.resolveBestFileToLoad]) at scan time, when it was
  /// computed. Carries the TIFF cheap/expensive probe result the synchronous
  /// [bestFileToLoad] getter cannot reach; `null` for items built without a
  /// scan (tests, or code paths that never had a probe), which then fall back
  /// to the pure-extension ranking.
  final File? resolvedBestFile;

  PhotoItem({
    required this.id,
    required this.files,
    this.status = PhotoStatus.unmarked,
    this.resolvedBestFile,
  });

  /// A RAW+JPG (or other multi-file) group has an ambiguous extension — which
  /// sibling's would we even show? — so the group displays [id] (the shared
  /// basename) with no extension. A single file has no such ambiguity and
  /// shows its actual extension.
  String get displayName =>
      files.length == 1 ? p.basename(files.single.path) : id;

  /// Prefer loading a cheap-to-display sibling (JPG → HEIC → WebP → PNG, then a
  /// TIFF with an embedded rendered image) over a RAW decode when available.
  /// Uses the scan-time resolved choice when one exists, otherwise the
  /// synchronous, I/O-free extension ranking.
  File? get bestFileToLoad {
    return resolvedBestFile ?? SupportedPhotoFormats.bestFileToLoad(files);
  }
}
