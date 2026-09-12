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
      final dir = await Directory.systemTemp.createTemp('halcyon_bridge_');
      addTempDirTeardown(dir);

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
      final dir = await Directory.systemTemp.createTemp('halcyon_perfile_');
      addTempDirTeardown(dir);

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
}
