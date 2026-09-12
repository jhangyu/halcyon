import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import '../support/temp_dirs.dart';
import 'package:path/path.dart' as p;
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/library/photo_file_actions.dart';
import 'package:halcyon_flutter/services/platform/trash_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _touch(Directory dir, String name) async {
  await File(p.join(dir.path, name)).writeAsBytes([0]);
}

AppState _stateWithTrash(Future<void> Function(File file) trashFile) {
  return AppState(
    imageLoader: (path, {required purpose, int? targetLongEdge}) async {
      return NativeImageBytes(Uint8List.fromList([1, 2, 3]));
    },
    fileActions: PhotoFileActions(trashFile: trashFile),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('AppState.deleteTrashed bridge-absent reroute', () {
    test(
      'S2.4: mixed batch reports recycled=true, mixedDestination=true',
      () async {
        final dir = await Directory.systemTemp.createTemp('halcyon_mixed_');
        addTempDirTeardown(dir);
        await _touch(dir, 'IMG_0001.jpg');
        await _touch(dir, 'IMG_0002.jpg');

        var call = 0;
        final state = _stateWithTrash((file) async {
          call++;
          if (call == 1) {
            await file.delete();
            return;
          }
          throw const TrashException('unavailable', bridgeUnavailable: true);
        });

        await state.loadFolder(dir);
        state.selectItem('IMG_0001');
        state.markCurrent(PhotoStatus.trashed);
        state.selectItem('IMG_0002');
        state.markCurrent(PhotoStatus.trashed);

        final result = await state.deleteTrashed();

        expect(result.recycled, isTrue);
        expect(result.mixedDestination, isTrue);
        expect(
          await File(p.join(dir.path, '.trash', 'IMG_0002.jpg')).exists(),
          isTrue,
        );
      },
    );

    test(
      'S2.3: recycleMode latches true on the next loadFolder without a toggle',
      () async {
        final dir = await Directory.systemTemp.createTemp('halcyon_latch_');
        addTempDirTeardown(dir);
        await _touch(dir, 'IMG_0001.jpg');

        final state = _stateWithTrash((file) async {
          throw const TrashException('unavailable', bridgeUnavailable: true);
        });

        await state.loadFolder(dir);
        expect(state.recycleMode, isFalse,
            reason: 'single-file-per-item folder starts in direct-delete mode');
        state.markCurrent(PhotoStatus.trashed);
        await state.deleteTrashed();

        await state.loadFolder(dir);
        expect(state.recycleMode, isTrue);
      },
    );
  });
}
