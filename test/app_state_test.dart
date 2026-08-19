import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/native_thumbnail_service.dart';
import 'package:halcyon_flutter/services/photo_file_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('AppState.loadFolder', () {
    test(
      'scans supported files, ignores hidden files, and groups by photo id',
      () async {
        final dir = await Directory.systemTemp.createTemp('halcyon_scan_');
        addTearDown(() => dir.delete(recursive: true));
        await _touch(dir, 'IMG_0001.jpg');
        await _touch(dir, 'IMG_0001.arw');
        await _touch(dir, 'IMG_0002.dng');
        await _touch(dir, '._IMG_0002.dng');
        await _touch(dir, 'notes.txt');

        final state = _testState();
        await state.loadFolder(dir);

        expect(state.items.map((item) => item.id), ['IMG_0001', 'IMG_0002']);
        expect(state.items.first.files, hasLength(2));
        expect(state.selectedItemID, 'IMG_0001');
      },
    );

    test('warns on the status line when the folder is read-only', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_ro_');
      addTearDown(() async {
        await Process.run('chmod', ['u+w', dir.path]);
        await dir.delete(recursive: true);
      });
      await _touch(dir, 'IMG_0001.jpg');

      final state = _testState();
      await state.loadFolder(dir);
      expect(state.status, isNull, reason: 'writable folder stays quiet');

      await Process.run('chmod', ['a-w', dir.path]);
      await state.loadFolder(dir);
      expect(state.status?.text, contains('唯讀'));
      expect(
        File(p.join(dir.path, '.halcyon_write_probe')).existsSync(),
        isFalse,
        reason: 'probe must clean up after itself',
      );
    });

    test('restores saved statuses and last viewed id from JSON', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_status_');
      addTearDown(() => dir.delete(recursive: true));
      await _touch(dir, 'IMG_0001.jpg');
      await _touch(dir, 'IMG_0002.jpg');
      await File(p.join(dir.path, '.halcyon_status.json')).writeAsString(
        json.encode({
          '_last_viewed_id': 'IMG_0002',
          'IMG_0001': 'starred',
          'MISSING': 'trashed',
        }),
      );

      final state = _testState();
      await state.loadFolder(dir);

      expect(state.selectedItemID, 'IMG_0002');
      expect(state.items.first.status, PhotoStatus.starred);
      final jsonMap =
          json.decode(
                await File(
                  p.join(dir.path, '.halcyon_status.json'),
                ).readAsString(),
              )
              as Map<String, dynamic>;
      expect(jsonMap.containsKey('MISSING'), isFalse);
    });

    test('scans RW2 files into photo groups', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_rw2_');
      addTearDown(() => dir.delete(recursive: true));
      await _touch(dir, 'P1000001.rw2');

      final state = _testState();
      await state.loadFolder(dir);

      expect(state.items, hasLength(1));
      expect(state.items.single.files.single.path, endsWith('P1000001.rw2'));
    });

    test('groups CR2/NEF/ORF raw files with their JPG sibling', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_raw_ext_');
      addTearDown(() => dir.delete(recursive: true));
      await _touch(dir, 'IMG_0001.jpg');
      await _touch(dir, 'IMG_0001.cr2');
      await _touch(dir, 'IMG_0002.jpg');
      await _touch(dir, 'IMG_0002.nef');
      await _touch(dir, 'IMG_0003.jpg');
      await _touch(dir, 'IMG_0003.orf');

      final state = _testState();
      await state.loadFolder(dir);

      expect(state.items.map((item) => item.id), [
        'IMG_0001',
        'IMG_0002',
        'IMG_0003',
      ]);
      for (final item in state.items) {
        expect(item.files, hasLength(2), reason: '${item.id} lost its raw');
      }
    });
  });

  group('AppState selection and marking', () {
    test(
      'auto-advance moves to the next photo after applying a new status',
      () async {
        final dir = await Directory.systemTemp.createTemp('halcyon_mark_');
        addTearDown(() => dir.delete(recursive: true));
        await _touch(dir, 'IMG_0001.jpg');
        await _touch(dir, 'IMG_0002.jpg');

        final state = _testState();
        await state.loadFolder(dir);
        state.setAutoAdvance(true);
        state.markCurrent(PhotoStatus.starred);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(state.items.first.status, PhotoStatus.starred);
        expect(state.selectedItemID, 'IMG_0002');
      },
    );

    test(
      'uses semantic image request purposes for preview and sidebar thumbnail loading',
      () async {
        final dir = await Directory.systemTemp.createTemp('halcyon_request_');
        addTearDown(() => dir.delete(recursive: true));
        await _touch(dir, 'IMG_0001.jpg');

        final calls = <ImageRequestPurpose>[];
        final state = AppState(
          thumbnailLoader: (path, {required purpose}) async {
            calls.add(purpose);
            return NativeImageBytes(Uint8List.fromList([1, 2, 3]));
          },
        );

        await state.loadFolder(dir);
        await Future<void>.delayed(const Duration(milliseconds: 180));

        expect(calls, contains(ImageRequestPurpose.preview));
        expect(calls, contains(ImageRequestPurpose.sidebarThumbnail));
      },
    );

    test(
      'toggling a status off does not auto-advance even when auto-advance is on',
      () async {
        final dir = await Directory.systemTemp.createTemp('halcyon_toggle_');
        addTearDown(() => dir.delete(recursive: true));
        await _touch(dir, 'IMG_0001.jpg');
        await _touch(dir, 'IMG_0002.jpg');

        final state = _testState();
        await state.loadFolder(dir);
        state.setAutoAdvance(true);

        state.markCurrent(PhotoStatus.starred);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(state.items.first.status, PhotoStatus.starred);
        expect(state.selectedItemID, 'IMG_0002');

        state.previousPhoto();
        expect(state.selectedItemID, 'IMG_0001');

        // Toggling the same status off must not advance the selection.
        state.markCurrent(PhotoStatus.starred);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(state.items.first.status, PhotoStatus.unmarked);
        expect(state.selectedItemID, 'IMG_0001');
      },
    );

    test('nextPhoto and previousPhoto move selection within bounds', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_nav_');
      addTearDown(() => dir.delete(recursive: true));
      await _touch(dir, 'IMG_0001.jpg');
      await _touch(dir, 'IMG_0002.jpg');

      final state = _testState();
      await state.loadFolder(dir);

      state.nextPhoto();
      expect(state.selectedItemID, 'IMG_0002');

      state.nextPhoto();
      expect(state.selectedItemID, 'IMG_0002');

      state.previousPhoto();
      expect(state.selectedItemID, 'IMG_0001');
    });
  });

  group('AppState.openPhotoAtPath', () {
    test('loads the containing folder and selects the given file', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_openwith_');
      addTearDown(() => dir.delete(recursive: true));
      await _touch(dir, 'IMG_0001.jpg');
      await _touch(dir, 'IMG_0002.dng');

      final state = _testState();
      await state.openPhotoAtPath(p.join(dir.path, 'IMG_0002.dng'));

      expect(state.currentDir?.path, dir.path);
      expect(state.items.map((item) => item.id), ['IMG_0001', 'IMG_0002']);
      expect(state.selectedItemID, 'IMG_0002');
    });

    test('ignores unsupported files instead of clearing the folder', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_openwith_');
      addTearDown(() => dir.delete(recursive: true));
      await _touch(dir, 'IMG_0001.jpg');
      // Deliberately in a different folder: without the guard, currentDir
      // would move here and the folder in view would be lost.
      final other = await Directory.systemTemp.createTemp('halcyon_other_');
      addTearDown(() => other.delete(recursive: true));
      await _touch(other, 'notes.txt');

      final state = _testState();
      await state.loadFolder(dir);
      await state.openPhotoAtPath(p.join(other.path, 'notes.txt'));

      expect(state.currentDir?.path, dir.path);
      expect(state.selectedItemID, 'IMG_0001');
    });
  });

  group('AppState recycle mode', () {
    test('defaults on when a folder has same-name sibling groups', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_mode_on_');
      addTearDown(() => dir.delete(recursive: true));
      await _touch(dir, 'IMG_0001.jpg');
      await _touch(dir, 'IMG_0001.dng');

      final state = _testState();
      await state.loadFolder(dir);

      expect(state.recycleMode, isTrue);
    });

    test('defaults off when every photo has a single extension', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_mode_off_');
      addTearDown(() => dir.delete(recursive: true));
      await _touch(dir, 'IMG_0001.jpg');
      await _touch(dir, 'IMG_0002.jpg');

      final state = _testState();
      await state.loadFolder(dir);

      expect(state.recycleMode, isFalse);
    });

    test('toggles both ways and notifies listeners', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_mode_tog_');
      addTearDown(() => dir.delete(recursive: true));
      await _touch(dir, 'IMG_0001.jpg');

      final state = _testState();
      await state.loadFolder(dir);
      var notifications = 0;
      state.addListener(() => notifications++);

      expect(state.recycleMode, isFalse);
      state.toggleRecycleMode();
      expect(state.recycleMode, isTrue);
      state.toggleRecycleMode();
      expect(state.recycleMode, isFalse);
      expect(notifications, 2);
    });

    test('recycle mode moves files to .trash instead of the system trash',
        () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_mode_run_');
      addTearDown(() => dir.delete(recursive: true));
      await _touch(dir, 'IMG_0001.jpg');
      await _touch(dir, 'IMG_0001.dng');

      final trashed = <String>[];
      final state = AppState(
        fileActions: PhotoFileActions(trashFile: (file) async {
          trashed.add(file.path);
          await file.delete();
        }),
        thumbnailLoader: (path, {required purpose}) async {
          return NativeImageBytes(Uint8List.fromList([1, 2, 3]));
        },
      );
      await state.loadFolder(dir);
      state.markCurrent(PhotoStatus.trashed);

      final result = await state.deleteTrashed();

      expect(result.recycled, isTrue);
      expect(result.movedCount, 2);
      expect(result.failures, isEmpty);
      expect(result.trashDirPath, p.join(dir.path, '.trash'));
      expect(trashed, isEmpty, reason: 'system trash must not be used');
      expect(
        await File(p.join(dir.path, '.trash', 'IMG_0001.jpg')).exists(),
        isTrue,
      );
      expect(state.items, isEmpty, reason: 'folder reloaded after recycle');
    });

    test('direct mode still routes through the system trash', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_mode_dir_');
      addTearDown(() => dir.delete(recursive: true));
      await _touch(dir, 'IMG_0001.jpg');

      final trashed = <String>[];
      final state = AppState(
        fileActions: PhotoFileActions(trashFile: (file) async {
          trashed.add(file.path);
          await file.delete();
        }),
        thumbnailLoader: (path, {required purpose}) async {
          return NativeImageBytes(Uint8List.fromList([1, 2, 3]));
        },
      );
      await state.loadFolder(dir);
      expect(state.recycleMode, isFalse);
      state.markCurrent(PhotoStatus.trashed);

      final result = await state.deleteTrashed();

      expect(result.recycled, isFalse);
      expect(trashed, hasLength(1));
      expect(await Directory(p.join(dir.path, '.trash')).exists(), isFalse);
    });
  });
}

Future<void> _touch(Directory dir, String name) {
  return File(p.join(dir.path, name)).writeAsBytes(<int>[1, 2, 3]);
}

AppState _testState() {
  return AppState(
    thumbnailLoader: (path, {required purpose}) async {
      return NativeImageBytes(Uint8List.fromList([1, 2, 3]));
    },
  );
}
