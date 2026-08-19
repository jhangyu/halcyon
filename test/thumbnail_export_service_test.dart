import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/thumbnail_export_service.dart';
import 'package:path/path.dart' as p;

Uint8List _fakeJpeg(String tag) => Uint8List.fromList('jpeg:$tag'.codeUnits);

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('halcyon_export_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  PhotoItem starred(String id, List<String> filenames) {
    return PhotoItem(
      id: id,
      status: PhotoStatus.starred,
      files: filenames.map((name) => File(p.join(tempDir.path, name))).toList(),
    );
  }

  PhotoItem unstarred(String id, List<String> filenames, PhotoStatus status) {
    return PhotoItem(
      id: id,
      status: status,
      files: filenames.map((name) => File(p.join(tempDir.path, name))).toList(),
    );
  }

  test('only starred items are exported; unmarked/trashed are not', () async {
    final destDir = Directory(p.join(tempDir.path, 'out'));
    await destDir.create();

    final items = [
      starred('a', ['a.jpg']),
      unstarred('b', ['b.jpg'], PhotoStatus.unmarked),
      unstarred('c', ['c.jpg'], PhotoStatus.trashed),
    ];

    final service = ThumbnailExportService(
      fetchBytes: (path) async => _fakeJpeg(p.basename(path)),
    );

    final outcome = await service.exportStarred(items, destDir);

    expect(outcome.exportedCount, 1);
    expect(outcome.failures, isEmpty);
    expect(await File(p.join(destDir.path, 'a.jpg')).exists(), isTrue);
    expect(await File(p.join(destDir.path, 'b.jpg')).exists(), isFalse);
    expect(await File(p.join(destDir.path, 'c.jpg')).exists(), isFalse);
  });

  test(
    'an item with .dng + .jpg siblings produces exactly one output file, '
    'from the JPEG source',
    () async {
      final destDir = Directory(p.join(tempDir.path, 'out'));
      await destDir.create();

      final requestedPaths = <String>[];
      final items = [
        starred('IMG_0001', ['IMG_0001.dng', 'IMG_0001.jpg']),
      ];

      final service = ThumbnailExportService(
        fetchBytes: (path) async {
          requestedPaths.add(path);
          return _fakeJpeg(p.basename(path));
        },
      );

      final outcome = await service.exportStarred(items, destDir);

      expect(outcome.exportedCount, 1);
      expect(requestedPaths, hasLength(1));
      expect(requestedPaths.single, endsWith('IMG_0001.jpg'));
      final outFiles = destDir.listSync();
      expect(outFiles, hasLength(1));
      expect(p.basename(outFiles.single.path), 'IMG_0001.jpg');
    },
  );

  test('an existing destination file is overwritten', () async {
    final destDir = Directory(p.join(tempDir.path, 'out'));
    await destDir.create();
    final outFile = File(p.join(destDir.path, 'a.jpg'));
    await outFile.writeAsBytes([0, 0, 0]);

    final items = [
      starred('a', ['a.jpg']),
    ];
    final service = ThumbnailExportService(
      fetchBytes: (path) async => _fakeJpeg('new'),
    );

    final outcome = await service.exportStarred(items, destDir);

    expect(outcome.exportedCount, 1);
    expect(await outFile.readAsBytes(), _fakeJpeg('new'));
  });

  test(
    'a fetch that returns null or throws lands in failures and the '
    'remaining items still export',
    () async {
      final destDir = Directory(p.join(tempDir.path, 'out'));
      await destDir.create();

      final items = [
        starred('a', ['a.jpg']),
        starred('b', ['b.jpg']),
        starred('c', ['c.jpg']),
      ];

      final service = ThumbnailExportService(
        fetchBytes: (path) async {
          if (path.endsWith('a.jpg')) return null;
          if (path.endsWith('b.jpg')) {
            throw Exception('native decode failed');
          }
          return _fakeJpeg('c');
        },
      );

      final outcome = await service.exportStarred(items, destDir);

      expect(outcome.exportedCount, 1);
      expect(outcome.failures, hasLength(2));
      expect(outcome.failures.any((f) => f.startsWith('a.jpg:')), isTrue);
      expect(outcome.failures.any((f) => f.startsWith('b.jpg:')), isTrue);
      expect(await File(p.join(destDir.path, 'c.jpg')).exists(), isTrue);
    },
  );

  test(
    'onProgress is called once per item with a monotonically increasing '
    'done and the correct total',
    () async {
      final destDir = Directory(p.join(tempDir.path, 'out'));
      await destDir.create();

      final items = List.generate(
        6,
        (i) => starred('item$i', ['item$i.jpg']),
      );

      final service = ThumbnailExportService(
        fetchBytes: (path) async => _fakeJpeg(path),
      );

      final progressCalls = <List<int>>[];
      final outcome = await service.exportStarred(
        items,
        destDir,
        onProgress: (done, total) => progressCalls.add([done, total]),
      );

      expect(outcome.exportedCount, 6);
      expect(progressCalls, hasLength(6));
      expect(progressCalls.every((c) => c[1] == 6), isTrue);
      final doneValues = progressCalls.map((c) => c[0]).toList();
      final sortedDoneValues = [...doneValues]..sort();
      expect(
        doneValues,
        sortedDoneValues,
        reason: 'done must be monotonically increasing',
      );
      expect(doneValues, [1, 2, 3, 4, 5, 6]);
    },
  );

  test('a destination that does not exist returns an empty outcome without throwing', () async {
    final destDir = Directory(p.join(tempDir.path, 'does_not_exist'));

    final items = [
      starred('a', ['a.jpg']),
    ];
    final service = ThumbnailExportService(
      fetchBytes: (path) async => _fakeJpeg('x'),
    );

    final outcome = await service.exportStarred(items, destDir);

    expect(outcome.exportedCount, 0);
    expect(outcome.failures, isEmpty);
  });
}
