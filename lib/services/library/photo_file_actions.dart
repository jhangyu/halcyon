import 'dart:io';

import 'package:path/path.dart' as p;

import '../../models/photo_item.dart';
import '../platform/file_retry.dart';
import '../platform/trash_service.dart';

typedef TrashFile = Future<void> Function(File file);
typedef MoveFile = Future<void> Function(File file, String newPath);

/// `/dir/IMG_0001.JPG` -> `/dir/._IMG_0001.JPG`.
///
/// The ONE place the AppleDouble sidecar prefix is built. It used to be
/// inlined at six call sites across this file and `rename_service.dart`.
String sidecarPathFor(String filePath) =>
    p.join(p.dirname(filePath), '._${p.basename(filePath)}');

/// Result of a recycle batch. [failures] entries are
/// `"<filename>: <error message>"` and MUST be surfaced to the user — a
/// silently failed delete looks identical to a broken app.
class RecycleOutcome {
  const RecycleOutcome({required this.movedCount, required this.failures});

  final int movedCount;
  final List<String> failures;
}

/// Result of a copy/move/delete batch. Mirrors [RecycleOutcome]: a batch NEVER
/// aborts on the first error, and [failures] entries are
/// `"<filename>: <error message>"` and MUST be surfaced to the user.
class BatchFileOutcome {
  const BatchFileOutcome({required this.processedCount, required this.failures});

  final int processedCount;
  final List<String> failures;
}

class PhotoFileActions {
  PhotoFileActions({TrashFile? trashFile, MoveFile? moveFile})
    : _trashFile = trashFile ?? TrashService.trashFile,
      _moveFile = moveFile ?? _renameFile;

  final TrashFile _trashFile;
  final MoveFile _moveFile;

  static Future<void> _renameFile(File file, String newPath) async {
    await retryOnSharingViolation(() => file.rename(newPath));
  }

  Future<BatchFileOutcome> processStarred(
    List<PhotoItem> items,
    Directory destination, {
    required bool move,
    required bool overwriteExisting,
  }) async {
    if (!await destination.exists()) {
      return const BatchFileOutcome(processedCount: 0, failures: []);
    }

    var processed = 0;
    final failures = <String>[];

    for (final item in items) {
      if (item.status != PhotoStatus.starred) continue;
      for (final file in item.files) {
        final newPath = p.join(destination.path, p.basename(file.path));
        final destSidecarPath = sidecarPathFor(newPath);
        final srcSidecarPath = sidecarPathFor(file.path);
        try {
          if (!overwriteExisting && await File(newPath).exists()) continue;
          if (move) {
            await retryOnSharingViolation(() => file.rename(newPath));
            await _deleteIfExists(destSidecarPath);
            await _deleteIfExists(srcSidecarPath);
          } else {
            await retryOnSharingViolation(() => file.copy(newPath));
            await _deleteIfExists(destSidecarPath);
          }
          processed++;
        } catch (e) {
          failures.add('${p.basename(file.path)}: $e');
        }
      }
    }

    return BatchFileOutcome(processedCount: processed, failures: failures);
  }

  Future<BatchFileOutcome> deleteTrashed(List<PhotoItem> items) async {
    var processed = 0;
    final failures = <String>[];

    for (final item in items) {
      if (item.status != PhotoStatus.trashed) continue;
      for (final file in item.files) {
        try {
          await _trashFile(file);
          processed++;
        } catch (e) {
          failures.add('${p.basename(file.path)}: $e');
        }
        final sidecarPath = sidecarPathFor(file.path);
        try {
          await _trashIfExists(sidecarPath);
        } catch (e) {
          failures.add('${p.basename(sidecarPath)}: $e');
        }
      }
    }

    return BatchFileOutcome(processedCount: processed, failures: failures);
  }

  /// Moves every file of each trashed item — plus its `._` AppleDouble
  /// sidecar — into `<dir>/.trash/`. Same-volume rename, so this is instant
  /// and works on cards where the system trash API is unavailable.
  Future<RecycleOutcome> recycleTrashed(
    List<PhotoItem> items,
    Directory dir,
  ) async {
    final trashDir = Directory(p.join(dir.path, '.trash'));
    if (!await trashDir.exists()) {
      await trashDir.create(recursive: true);
    }

    var movedCount = 0;
    final failures = <String>[];

    for (final item in items) {
      if (item.status != PhotoStatus.trashed) continue;

      for (final file in item.files) {
        final sidecar = File(sidecarPathFor(file.path));
        // The photo always moves; its AppleDouble sidecar only if present.
        final targets = <File>[
          file,
          if (await sidecar.exists()) sidecar,
        ];

        for (final target in targets) {
          try {
            await _moveFile(
              target,
              _availablePath(trashDir.path, p.basename(target.path)),
            );
            movedCount++;
          } catch (e) {
            failures.add('${p.basename(target.path)}: $e');
          }
        }
      }
    }

    return RecycleOutcome(movedCount: movedCount, failures: failures);
  }

  /// `IMG_0001.jpg` -> `IMG_0001-1.jpg` -> `IMG_0001-2.jpg` when taken.
  /// Never overwrites an earlier recycle batch.
  String _availablePath(String trashDirPath, String fileName) {
    var candidate = p.join(trashDirPath, fileName);
    if (!File(candidate).existsSync()) return candidate;

    final stem = p.basenameWithoutExtension(fileName);
    final ext = p.extension(fileName);
    var counter = 1;
    do {
      candidate = p.join(trashDirPath, '$stem-$counter$ext');
      counter++;
    } while (File(candidate).existsSync());
    return candidate;
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
      await retryOnSharingViolation(() => file.delete());
    }
  }
}
