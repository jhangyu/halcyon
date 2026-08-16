import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/native_thumbnail_service.dart';
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
            return Uint8List.fromList([1, 2, 3]);
          },
        );

        await state.loadFolder(dir);
        await Future<void>.delayed(const Duration(milliseconds: 180));

        expect(calls, contains(ImageRequestPurpose.preview));
        expect(calls, contains(ImageRequestPurpose.sidebarThumbnail));
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
}

Future<void> _touch(Directory dir, String name) {
  return File(p.join(dir.path, name)).writeAsBytes(<int>[1, 2, 3]);
}

AppState _testState() {
  return AppState(
    thumbnailLoader: (path, {required purpose}) async {
      return Uint8List.fromList([1, 2, 3]);
    },
  );
}
