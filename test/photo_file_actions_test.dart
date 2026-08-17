import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/photo_file_actions.dart';
import 'package:path/path.dart' as p;

void main() {
  group('PhotoFileActions.deleteTrashed', () {
    test(
      'moves trashed files and sidecars through the trash service',
      () async {
        final dir = await Directory.systemTemp.createTemp('halcyon_trash_');
        addTearDown(() => dir.delete(recursive: true));

        final photo = await _touch(dir, 'IMG_0001.jpg');
        final sidecar = await _touch(dir, '._IMG_0001.jpg');
        final untouched = await _touch(dir, 'IMG_0002.jpg');
        final trashedPaths = <String>[];

        final actions = PhotoFileActions(
          trashFile: (file) async {
            trashedPaths.add(file.path);
            await file.delete();
          },
        );

        await actions.deleteTrashed([
          PhotoItem(
            id: 'IMG_0001',
            files: [photo],
            status: PhotoStatus.trashed,
          ),
          PhotoItem(
            id: 'IMG_0002',
            files: [untouched],
            status: PhotoStatus.unmarked,
          ),
        ]);

        expect(trashedPaths, [photo.path, sidecar.path]);
        expect(await photo.exists(), isFalse);
        expect(await sidecar.exists(), isFalse);
        expect(await untouched.exists(), isTrue);
      },
    );

    test('keeps the source file when trash service fails', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_trash_fail_');
      addTearDown(() => dir.delete(recursive: true));

      final photo = await _touch(dir, 'IMG_0001.jpg');
      final actions = PhotoFileActions(
        trashFile: (file) async {
          throw const FileSystemException('trash failed');
        },
      );

      expect(
        actions.deleteTrashed([
          PhotoItem(
            id: 'IMG_0001',
            files: [photo],
            status: PhotoStatus.trashed,
          ),
        ]),
        throwsA(isA<FileSystemException>()),
      );
      expect(await photo.exists(), isTrue);
    });
  });

  group('PhotoFileActions.recycleTrashed', () {
    test('moves every sibling file and sidecar into .trash', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_recycle_');
      addTearDown(() => dir.delete(recursive: true));

      final jpg = await _touch(dir, 'IMG_0001.jpg');
      final dng = await _touch(dir, 'IMG_0001.dng');
      final sidecar = await _touch(dir, '._IMG_0001.jpg');
      final untouched = await _touch(dir, 'IMG_0002.jpg');

      final outcome = await PhotoFileActions().recycleTrashed([
        PhotoItem(
          id: 'IMG_0001',
          files: [jpg, dng],
          status: PhotoStatus.trashed,
        ),
        PhotoItem(
          id: 'IMG_0002',
          files: [untouched],
          status: PhotoStatus.unmarked,
        ),
      ], dir);

      final trashDir = Directory(p.join(dir.path, '.trash'));
      expect(outcome.movedCount, 3);
      expect(outcome.failures, isEmpty);
      expect(await File(p.join(trashDir.path, 'IMG_0001.jpg')).exists(), isTrue);
      expect(await File(p.join(trashDir.path, 'IMG_0001.dng')).exists(), isTrue);
      expect(
        await File(p.join(trashDir.path, '._IMG_0001.jpg')).exists(),
        isTrue,
      );
      expect(await jpg.exists(), isFalse);
      expect(await dng.exists(), isFalse);
      expect(await sidecar.exists(), isFalse);
      expect(await untouched.exists(), isTrue);
    });

    test('suffixes collisions instead of overwriting', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_recycle_dup_');
      addTearDown(() => dir.delete(recursive: true));

      final trashDir = Directory(p.join(dir.path, '.trash'));
      await trashDir.create(recursive: true);
      final existing = File(p.join(trashDir.path, 'IMG_0001.jpg'));
      await existing.writeAsString('OLD');

      final jpg = File(p.join(dir.path, 'IMG_0001.jpg'));
      await jpg.writeAsString('NEW');

      final outcome = await PhotoFileActions().recycleTrashed([
        PhotoItem(id: 'IMG_0001', files: [jpg], status: PhotoStatus.trashed),
      ], dir);

      expect(outcome.movedCount, 1);
      expect(await existing.readAsString(), 'OLD');
      expect(
        await File(p.join(trashDir.path, 'IMG_0001-1.jpg')).readAsString(),
        'NEW',
      );
    });

    test('records per-file failures and keeps processing the rest', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_recycle_err_');
      addTearDown(() => dir.delete(recursive: true));

      final bad = await _touch(dir, 'IMG_0001.jpg');
      final good = await _touch(dir, 'IMG_0002.jpg');

      final actions = PhotoFileActions(
        moveFile: (file, newPath) async {
          if (p.basename(file.path) == 'IMG_0001.jpg') {
            throw const FileSystemException('Read-only file system');
          }
          await file.rename(newPath);
        },
      );

      final outcome = await actions.recycleTrashed([
        PhotoItem(id: 'IMG_0001', files: [bad], status: PhotoStatus.trashed),
        PhotoItem(id: 'IMG_0002', files: [good], status: PhotoStatus.trashed),
      ], dir);

      expect(outcome.movedCount, 1);
      expect(outcome.failures, hasLength(1));
      expect(outcome.failures.single, contains('IMG_0001.jpg'));
      expect(outcome.failures.single, contains('Read-only file system'));
      expect(await bad.exists(), isTrue);
      expect(await good.exists(), isFalse);
    });
  });
}

Future<File> _touch(Directory dir, String name) {
  return File(p.join(dir.path, name)).writeAsBytes(<int>[1, 2, 3]);
}
