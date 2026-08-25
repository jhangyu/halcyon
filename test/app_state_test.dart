import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_source_types.dart';
import 'package:halcyon_flutter/services/photo_file_actions.dart';
import 'package:halcyon_flutter/services/photo_library_scanner.dart';
import 'package:halcyon_flutter/services/rename_rule.dart';
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
          imageLoader: (path, {required purpose}) async {
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

    test('TC-222 currentItem returns null for a selection that is gone',
        () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_cur_gone_');
      addTearDown(() => dir.delete(recursive: true));
      await _touch(dir, 'IMG_0001.jpg');
      await _touch(dir, 'IMG_0002.jpg');

      final state = _testState();
      addTearDown(state.dispose);
      await state.loadFolder(dir);
      state.selectItem('IMG_0001');
      // Simulate the window where the selection points at a photo the last
      // scan no longer returned: previously this silently handed back
      // items.first.
      state.items.removeWhere((item) => item.id == 'IMG_0001');

      expect(state.currentItem, isNull);
    });

    test('TC-223 currentItem does not throw on an empty item list', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_cur_empty_');
      addTearDown(() => dir.delete(recursive: true));
      await _touch(dir, 'IMG_0001.jpg');

      final state = _testState();
      addTearDown(state.dispose);
      await state.loadFolder(dir);
      state.selectItem('IMG_0001');
      state.items.clear();

      expect(state.currentItem, isNull); // was: StateError from _items.first
    });

    test('TC-221 a failing copy surfaces a status message', () async {
      final src = await Directory.systemTemp.createTemp('halcyon_ps221_src_');
      addTearDown(() => src.delete(recursive: true));
      final dest = await Directory.systemTemp.createTemp(
        'halcyon_ps221_dest_',
      );
      addTearDown(() => dest.delete(recursive: true));
      await _touch(src, 'IMG_0001.jpg');
      // Block the destination path with a DIRECTORY so the copy throws.
      await Directory(p.join(dest.path, 'IMG_0001.jpg')).create();

      final state = _testState();
      addTearDown(state.dispose);
      await state.loadFolder(src);
      state.markCurrent(PhotoStatus.starred);

      await state.processStarred(dest.path, false);

      expect(state.status, isNotNull);
      expect(state.status!.text, contains('1'));
      expect(state.status!.text, contains('失敗'));
    });

    test('TC-224 a scan failure surfaces a status message', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_scanfail_');
      addTearDown(() => dir.delete(recursive: true));

      final state = AppState(
        scanner: _ThrowingScanner(const FileSystemException('unreadable')),
        imageLoader: (path, {required purpose}) async {
          return NativeImageBytes(Uint8List.fromList([1, 2, 3]));
        },
      );
      addTearDown(state.dispose);

      await state.loadFolder(dir);

      expect(state.status, isNotNull);
      expect(state.status!.text, contains('無法讀取'));
    });

    test('TC-225 readMetadataFor chunks once and reports progress', () async {
      final chunkSizes = <int>[];
      final progress = <int>[];

      // A fake scanner avoids creating 1200 real files: this test is about
      // AppState's chunking loop, not the filesystem scan.
      final state = AppState(
        scanner: _FixedScanner(
          List.generate(
            1200,
            (i) => PhotoItem(
              id: 'P$i',
              files: [File(p.join('/nonexistent', 'P$i.jpg'))],
            ),
          ),
        ),
        imageLoader: (path, {required purpose}) async {
          return NativeImageBytes(Uint8List.fromList([1, 2, 3]));
        },
        exifReader: (paths, {onProgress}) async {
          chunkSizes.add(paths.length);
          onProgress?.call(paths.length, paths.length);
          return List<ExifMetadata?>.filled(paths.length, null);
        },
      );
      addTearDown(state.dispose);

      await state.loadFolder(Directory.systemTemp);
      await state.readMetadataFor(state.items, onProgress: (done, total) {
        progress.add(done);
      });

      // ONE call into the reader with the whole list: the chunking lives in
      // ExifMetadataService, and AppState must not chunk a second time on
      // top (previously ran a 500-item loop inside ExifMetadataService's own
      // 500-item loop).
      expect(chunkSizes, [1200]);
      expect(progress, isNotEmpty);
      expect(progress.last, 1200);
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
        imageLoader: (path, {required purpose}) async {
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
        imageLoader: (path, {required purpose}) async {
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

  group('renameByExif', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('halcyon_rename_state_');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    Future<void> touch(String name) =>
        File(p.join(tempDir.path, name)).writeAsString(name);

    AppState buildState() {
      return AppState(
        imageLoader: (path, {required purpose}) async {
          return NativeImageBytes(Uint8List.fromList([1, 2, 3]));
        },
        exifReader: (paths, {onProgress}) async => [
          for (final path in paths)
            ExifMetadata(
              captureDate: p.basename(path).startsWith('A')
                  ? DateTime(2026, 4, 7, 9, 3, 5)
                  : DateTime(2026, 4, 7, 10, 0, 0),
            ),
        ],
      );
    }

    test('TC-049 renames files and moves the star to the new id', () async {
      await touch('A.NEF');
      await touch('A.JPG');
      await touch('B.JPG');

      final state = buildState();
      await state.loadFolder(tempDir);
      state.selectItem('A');
      state.markCurrent(PhotoStatus.starred);

      await state.renameByExif(
        const RenameRule(RenameRule.kDefaultTemplate),
        isCustom: false,
      );

      final names =
          tempDir
              .listSync()
              .map((e) => p.basename(e.path))
              .where((n) => !n.startsWith('.'))
              .toList()
            ..sort();
      expect(names, [
        '2026-04-07-09-03-05.JPG',
        '2026-04-07-09-03-05.NEF',
        '2026-04-07-10-00-00.JPG',
      ]);

      final renamed = state.items.firstWhere(
        (i) => i.id == '2026-04-07-09-03-05',
      );
      expect(renamed.status, PhotoStatus.starred);
      expect(state.selectedItemID, '2026-04-07-09-03-05');
    });

    test('TC-050 undo restores the original names and the star', () async {
      await touch('A.JPG');

      final state = buildState();
      await state.loadFolder(tempDir);
      state.selectItem('A');
      state.markCurrent(PhotoStatus.starred);
      await state.renameByExif(
        const RenameRule(RenameRule.kDefaultTemplate),
        isCustom: false,
      );

      await state.undoRename();

      expect(File(p.join(tempDir.path, 'A.JPG')).existsSync(), isTrue);
      expect(state.items.single.id, 'A');
      expect(state.items.single.status, PhotoStatus.starred);
    });

    test('TC-051 a custom rule is saved; a preset clears it', () async {
      await touch('A.JPG');
      final state = buildState();
      await state.loadFolder(tempDir);

      await state.renameByExif(const RenameRule('{YYYY}_{seq}'), isCustom: true);
      expect(await state.loadSavedRenameRule(), '{YYYY}_{seq}');

      await state.renameByExif(
        const RenameRule(RenameRule.kDefaultTemplate),
        isCustom: false,
      );
      expect(await state.loadSavedRenameRule(), isNull);
    });
  });
}

Future<void> _touch(Directory dir, String name) {
  return File(p.join(dir.path, name)).writeAsBytes(<int>[1, 2, 3]);
}

AppState _testState() {
  return AppState(
    imageLoader: (path, {required purpose}) async {
      return NativeImageBytes(Uint8List.fromList([1, 2, 3]));
    },
  );
}

class _ThrowingScanner extends PhotoLibraryScanner {
  _ThrowingScanner(this.error);
  final Object error;
  @override
  Future<List<PhotoItem>> scan(Directory dir) async => throw error;
}

class _FixedScanner extends PhotoLibraryScanner {
  _FixedScanner(this.result);
  final List<PhotoItem> result;
  @override
  Future<List<PhotoItem>> scan(Directory dir) async => result;
}
