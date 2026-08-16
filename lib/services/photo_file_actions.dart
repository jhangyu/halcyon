import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/photo_item.dart';
import 'trash_service.dart';

typedef TrashFile = Future<void> Function(File file);

class PhotoFileActions {
  PhotoFileActions({TrashFile? trashFile})
    : _trashFile = trashFile ?? TrashService.trashFile;

  final TrashFile _trashFile;

  Future<void> processStarred(
    List<PhotoItem> items,
    Directory destination, {
    required bool move,
    required bool overwriteExisting,
  }) async {
    if (!await destination.exists()) return;

    final starredItems = items
        .where((item) => item.status == PhotoStatus.starred)
        .toList();

    for (final item in starredItems) {
      for (final file in item.files) {
        final newPath = p.join(destination.path, p.basename(file.path));
        final destSidecarPath = p.join(
          destination.path,
          '._${p.basename(file.path)}',
        );
        final srcSidecarPath = p.join(
          file.parent.path,
          '._${p.basename(file.path)}',
        );

        if (!overwriteExisting && await File(newPath).exists()) continue;

        if (move) {
          await file.rename(newPath);
          await _deleteIfExists(destSidecarPath);
          await _deleteIfExists(srcSidecarPath);
        } else {
          await file.copy(newPath);
          await _deleteIfExists(destSidecarPath);
        }
      }
    }
  }

  Future<void> deleteTrashed(List<PhotoItem> items) async {
    final trashedItems = items
        .where((item) => item.status == PhotoStatus.trashed)
        .toList();

    for (final item in trashedItems) {
      for (final file in item.files) {
        final srcSidecarPath = p.join(
          file.parent.path,
          '._${p.basename(file.path)}',
        );
        await _trashFile(file);
        await _trashIfExists(srcSidecarPath);
      }
    }
  }

  Future<void> _trashIfExists(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await _trashFile(file);
    }
  }

  Future<void> _deleteIfExists(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }
}
