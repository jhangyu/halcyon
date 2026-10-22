import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../../support/temp_dirs.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/library/photo_file_actions.dart';
import 'package:halcyon_flutter/services/platform/trash_service.dart';

void main() {
  group('PhotoFileActions.deleteTrashed bridge-absent reroute', () {
    test('aborts the whole batch on the first bridge-absent exception',
        () async {
      final dir = await makeTempDir('halcyon_bridge_');

      final files = <File>[];
      for (var i = 1; i <= 3; i++) {
        final f = File('${dir.path}/IMG_000$i.jpg');
        await f.writeAsBytes([0]);
        files.add(f);
      }

      final actions = PhotoFileActions(
        trashFile: (file) async {
          throw const TrashException('unavailable', bridgeUnavailable: true);
        },
      );

      final outcome = await actions.deleteTrashed([
        for (var i = 0; i < files.length; i++)
          PhotoItem(
            id: 'IMG_000${i + 1}',
            files: [files[i]],
            status: PhotoStatus.trashed,
          ),
      ]);

      expect(outcome.bridgeUnavailable, isTrue);
      expect(outcome.failures, isEmpty);
      expect(outcome.processedCount, 0);
    });

    test('continues the batch on a plain per-file TrashException', () async {
      final dir = await makeTempDir('halcyon_perfile_');

      final files = <File>[];
      for (var i = 1; i <= 3; i++) {
        final f = File('${dir.path}/IMG_000$i.jpg');
        await f.writeAsBytes([0]);
        files.add(f);
      }

      var call = 0;
      final actions = PhotoFileActions(
        trashFile: (file) async {
          call++;
          if (call == 2) {
            throw const TrashException('denied');
          }
        },
      );

      final outcome = await actions.deleteTrashed([
        for (var i = 0; i < files.length; i++)
          PhotoItem(
            id: 'IMG_000${i + 1}',
            files: [files[i]],
            status: PhotoStatus.trashed,
          ),
      ]);

      expect(outcome.bridgeUnavailable, isFalse);
      expect(outcome.failures.length, 1);
      expect(outcome.processedCount, 2);
    });
  });

  group('PhotoFileActions.deleteBatch bridge vanishes mid-batch', () {
    test('already-trashed files are not recycled nor reported as failures',
        () async {
      final dir = await makeTempDir('halcyon_midbatch_');
      final files = [
        for (var i = 1; i <= 3; i++) File('${dir.path}/IMG_000$i.jpg'),
      ];
      for (final f in files) {
        await f.writeAsBytes([0]);
      }

      var call = 0;
      final actions = PhotoFileActions(
        trashFile: (file) async {
          call++;
          if (call == 1) {
            await file.delete(); // really moved to the system trash
            return;
          }
          throw const TrashException('unavailable', bridgeUnavailable: true);
        },
      );

      final r = await actions.deleteBatch([
        for (var i = 0; i < files.length; i++)
          PhotoItem(
            id: 'IMG_000${i + 1}',
            files: [files[i]],
            status: PhotoStatus.trashed,
          ),
      ], dir, recycleMode: false);

      expect(r.result.failures, isEmpty);
      expect(r.result.movedCount, 2);
      expect(r.result.mixedDestination, isTrue);
    });
  });
}
