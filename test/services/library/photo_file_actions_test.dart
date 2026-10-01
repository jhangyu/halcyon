import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../../support/temp_dirs.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/library/photo_file_actions.dart';
import 'package:path/path.dart' as p;
import '../../support/fixture_files.dart';

const _stubBytes = <int>[1, 2, 3];

void main() {
  group('PhotoFileActions.deleteTrashed', () {
    test(
      'moves trashed files and sidecars through the trash service',
      () async {
        final dir = await makeTempDir('halcyon_trash_');

        final photo = await writeFixtureBytes(dir, 'IMG_0001.jpg', _stubBytes);
        final sidecar = await writeFixtureBytes(dir, '._IMG_0001.jpg', _stubBytes);
        final untouched = await writeFixtureBytes(dir, 'IMG_0002.jpg', _stubBytes);
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
      final dir = await makeTempDir('halcyon_trash_fail_');

      final photo = await writeFixtureBytes(dir, 'IMG_0001.jpg', _stubBytes);
      final actions = PhotoFileActions(
        trashFile: (file) async {
          throw const FileSystemException('trash failed');
        },
      );

      final outcome = await actions.deleteTrashed([
        PhotoItem(
          id: 'IMG_0001',
          files: [photo],
          status: PhotoStatus.trashed,
        ),
      ]);

      expect(outcome.processedCount, 0);
      expect(outcome.failures, hasLength(1));
      expect(await photo.exists(), isTrue);
    });

    test('TC-207 deleteTrashed continues past a failing trash call', () async {
      final dir = await makeTempDir('halcyon_dt_');

      final bad = await writeFixtureBytes(dir, 'IMG_0001.jpg', _stubBytes);
      final good = await writeFixtureBytes(dir, 'IMG_0002.jpg', _stubBytes);

      final actions = PhotoFileActions(
        trashFile: (file) async {
          if (p.basename(file.path) == 'IMG_0001.jpg') {
            throw const FileSystemException('trash unavailable');
          }
          await file.delete();
        },
      );

      final outcome = await actions.deleteTrashed([
        PhotoItem(id: 'IMG_0001', files: [bad], status: PhotoStatus.trashed),
        PhotoItem(id: 'IMG_0002', files: [good], status: PhotoStatus.trashed),
      ]);

      expect(outcome.processedCount, 1);
      expect(outcome.failures, hasLength(1));
      expect(outcome.failures.single, startsWith('IMG_0001.jpg: '));
      expect(await bad.exists(), isTrue);
      expect(await good.exists(), isFalse);
    });
  });

  group('PhotoFileActions.processStarred', () {
    test(
      'copy mode copies starred items to the destination, leaves the source untouched, skips unstarred items',
      () async {
        final src = await makeTempDir('halcyon_star_src_');
        final dest = await makeTempDir('halcyon_star_dest_');

        final starred = await writeFixtureBytes(src, 'IMG_0001.jpg', _stubBytes);
        final unstarred = await writeFixtureBytes(src, 'IMG_0002.jpg', _stubBytes);

        await PhotoFileActions().processStarred([
          PhotoItem(
            id: 'IMG_0001',
            files: [starred],
            status: PhotoStatus.starred,
          ),
          PhotoItem(
            id: 'IMG_0002',
            files: [unstarred],
            status: PhotoStatus.unmarked,
          ),
        ], dest, move: false, overwriteExisting: false);

        expect(await File(p.join(dest.path, 'IMG_0001.jpg')).exists(), isTrue);
        expect(
          await File(p.join(dest.path, 'IMG_0002.jpg')).exists(),
          isFalse,
        );
        expect(
          await starred.exists(),
          isTrue,
          reason: 'copy must not remove the source',
        );
        expect(await unstarred.exists(), isTrue);
      },
    );

    test(
      'move mode moves starred items to the destination, removes the source, leaves unstarred untouched',
      () async {
        final src = await makeTempDir('halcyon_star_src_');
        final dest = await makeTempDir('halcyon_star_dest_');

        final starred = await writeFixtureBytes(src, 'IMG_0001.jpg', _stubBytes);
        final unstarred = await writeFixtureBytes(src, 'IMG_0002.jpg', _stubBytes);

        await PhotoFileActions().processStarred([
          PhotoItem(
            id: 'IMG_0001',
            files: [starred],
            status: PhotoStatus.starred,
          ),
          PhotoItem(
            id: 'IMG_0002',
            files: [unstarred],
            status: PhotoStatus.unmarked,
          ),
        ], dest, move: true, overwriteExisting: false);

        expect(await File(p.join(dest.path, 'IMG_0001.jpg')).exists(), isTrue);
        expect(
          await starred.exists(),
          isFalse,
          reason: 'move must remove the source',
        );
        expect(await unstarred.exists(), isTrue);
      },
    );

    test('move mode processes every sibling file in a RAW+JPG group', () async {
      final src = await makeTempDir('halcyon_star_sib_');
      final dest = await makeTempDir('halcyon_star_dest_');

      final jpg = await writeFixtureBytes(src, 'IMG_0001.jpg', _stubBytes);
      final dng = await writeFixtureBytes(src, 'IMG_0001.dng', _stubBytes);

      await PhotoFileActions().processStarred([
        PhotoItem(id: 'IMG_0001', files: [jpg, dng], status: PhotoStatus.starred),
      ], dest, move: true, overwriteExisting: false);

      expect(await File(p.join(dest.path, 'IMG_0001.jpg')).exists(), isTrue);
      expect(await File(p.join(dest.path, 'IMG_0001.dng')).exists(), isTrue);
      expect(await jpg.exists(), isFalse);
      expect(await dng.exists(), isFalse);
    });

    test(
      'overwriteExisting=false skips a starred file whose destination already exists, source is left alone',
      () async {
        final src = await makeTempDir('halcyon_star_skip_');
        final dest = await makeTempDir('halcyon_star_dest_');

        await File(p.join(dest.path, 'IMG_0001.jpg')).writeAsString('OLD');
        final source = File(p.join(src.path, 'IMG_0001.jpg'));
        await source.writeAsString('NEW');

        await PhotoFileActions().processStarred([
          PhotoItem(
            id: 'IMG_0001',
            files: [source],
            status: PhotoStatus.starred,
          ),
        ], dest, move: true, overwriteExisting: false);

        expect(
          await File(p.join(dest.path, 'IMG_0001.jpg')).readAsString(),
          'OLD',
        );
        expect(
          await source.exists(),
          isTrue,
          reason: 'skipped file must stay at the source, even in move mode',
        );
      },
    );

    test('overwriteExisting=true replaces an existing destination file', () async {
      final src = await makeTempDir('halcyon_star_over_');
      final dest = await makeTempDir('halcyon_star_dest_');

      await File(p.join(dest.path, 'IMG_0001.jpg')).writeAsString('OLD');
      final source = File(p.join(src.path, 'IMG_0001.jpg'));
      await source.writeAsString('NEW');

      await PhotoFileActions().processStarred([
        PhotoItem(id: 'IMG_0001', files: [source], status: PhotoStatus.starred),
      ], dest, move: false, overwriteExisting: true);

      expect(
        await File(p.join(dest.path, 'IMG_0001.jpg')).readAsString(),
        'NEW',
      );
      expect(
        await source.exists(),
        isTrue,
        reason: 'copy mode keeps the source even when overwriting',
      );
    });

    test(
      'copy mode discards a preexisting destination AppleDouble sidecar and keeps the source sidecar',
      () async {
        final src = await makeTempDir('halcyon_star_sc_copy_');
        final dest = await makeTempDir('halcyon_star_dest_');

        final photo = await writeFixtureBytes(src, 'IMG_0001.jpg', _stubBytes);
        final srcSidecar = await writeFixtureBytes(src, '._IMG_0001.jpg', _stubBytes);
        await writeFixtureBytes(dest, '._IMG_0001.jpg', _stubBytes);

        await PhotoFileActions().processStarred([
          PhotoItem(
            id: 'IMG_0001',
            files: [photo],
            status: PhotoStatus.starred,
          ),
        ], dest, move: false, overwriteExisting: true);

        expect(await File(p.join(dest.path, 'IMG_0001.jpg')).exists(), isTrue);
        expect(
          await File(p.join(dest.path, '._IMG_0001.jpg')).exists(),
          isFalse,
          reason: 'the sidecar is never copied, only cleaned up',
        );
        expect(
          await srcSidecar.exists(),
          isTrue,
          reason: 'copy mode must not touch the source sidecar',
        );
      },
    );

    test(
      'move mode discards the source AppleDouble sidecar instead of moving it',
      () async {
        final src = await makeTempDir('halcyon_star_sc_move_');
        final dest = await makeTempDir('halcyon_star_dest_');

        final photo = await writeFixtureBytes(src, 'IMG_0001.jpg', _stubBytes);
        final srcSidecar = await writeFixtureBytes(src, '._IMG_0001.jpg', _stubBytes);

        await PhotoFileActions().processStarred([
          PhotoItem(
            id: 'IMG_0001',
            files: [photo],
            status: PhotoStatus.starred,
          ),
        ], dest, move: true, overwriteExisting: false);

        expect(await File(p.join(dest.path, 'IMG_0001.jpg')).exists(), isTrue);
        expect(
          await File(p.join(dest.path, '._IMG_0001.jpg')).exists(),
          isFalse,
        );
        expect(
          await srcSidecar.exists(),
          isFalse,
          reason: 'move mode deletes rather than moves the sidecar',
        );
      },
    );

    test('does nothing when the destination folder does not exist', () async {
      final src = await makeTempDir('halcyon_star_nodest_');
      final missingDest = Directory(p.join(src.path, 'does_not_exist'));
      final photo = await writeFixtureBytes(src, 'IMG_0001.jpg', _stubBytes);

      await PhotoFileActions().processStarred([
        PhotoItem(id: 'IMG_0001', files: [photo], status: PhotoStatus.starred),
      ], missingDest, move: true, overwriteExisting: true);

      expect(await photo.exists(), isTrue);
    });

    test('TC-206 processStarred continues past a failing file', () async {
      final src = await makeTempDir('halcyon_ps_src_');
      final dest = await makeTempDir('halcyon_ps_dest_');

      final bad = await writeFixtureBytes(src, 'IMG_0001.jpg', _stubBytes);
      final good = await writeFixtureBytes(src, 'IMG_0002.jpg', _stubBytes);
      // Make the first destination path unwritable by putting a DIRECTORY there.
      await Directory(p.join(dest.path, 'IMG_0001.jpg')).create();

      final actions = PhotoFileActions();
      final outcome = await actions.processStarred(
        [
          PhotoItem(id: 'IMG_0001', files: [bad], status: PhotoStatus.starred),
          PhotoItem(id: 'IMG_0002', files: [good], status: PhotoStatus.starred),
        ],
        dest,
        move: false,
        overwriteExisting: true,
      );

      expect(outcome.processedCount, 1);
      expect(outcome.failures, hasLength(1));
      expect(outcome.failures.single, startsWith('IMG_0001.jpg: '));
      expect(await File(p.join(dest.path, 'IMG_0002.jpg')).exists(), isTrue);
    });
  });

  group('PhotoFileActions.recycleTrashed', () {
    test('moves every sibling file and sidecar into .trash', () async {
      final dir = await makeTempDir('halcyon_recycle_');

      final jpg = await writeFixtureBytes(dir, 'IMG_0001.jpg', _stubBytes);
      final dng = await writeFixtureBytes(dir, 'IMG_0001.dng', _stubBytes);
      final sidecar = await writeFixtureBytes(dir, '._IMG_0001.jpg', _stubBytes);
      final untouched = await writeFixtureBytes(dir, 'IMG_0002.jpg', _stubBytes);

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
      final dir = await makeTempDir('halcyon_recycle_dup_');

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
      final dir = await makeTempDir('halcyon_recycle_err_');

      final bad = await writeFixtureBytes(dir, 'IMG_0001.jpg', _stubBytes);
      final good = await writeFixtureBytes(dir, 'IMG_0002.jpg', _stubBytes);

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

  test('TC-212 sidecarPathFor prefixes the basename only', () {
    expect(
      sidecarPathFor(p.join('/card/DCIM', 'IMG_0001.JPG')),
      p.join('/card/DCIM', '._IMG_0001.JPG'),
    );
  });
}

