// TC-860: folder-wide starred/trashed aggregates, and the PhotoIdentity
// fields that carry them to a layout theme. Data path only — no widget here.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/views/layout/main_surface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_state_fixtures.dart';
import '../support/temp_dirs.dart';

Future<void> _touch(Directory dir, String name) async {
  await File('${dir.path}${Platform.pathSeparator}$name').writeAsBytes([0]);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('TC-860 AppState aggregate starred/trashed counts', () {
    test('both counts are 0 before any folder is loaded', () {
      final state = testState();
      expect(state.starredCount, 0);
      expect(state.trashedCount, 0);
    });

    test('counts the marked items in the loaded folder', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_counts_');
      addTempDirTeardown(dir);
      await _touch(dir, 'IMG_0001.jpg');
      await _touch(dir, 'IMG_0002.jpg');
      await _touch(dir, 'IMG_0003.jpg');
      await _touch(dir, 'IMG_0004.jpg');

      final state = testState();
      await state.loadFolder(dir);
      expect(state.items, hasLength(4));
      expect(state.starredCount, 0, reason: 'a fresh scan marks nothing');
      expect(state.trashedCount, 0);

      state.items[0].status = PhotoStatus.starred;
      state.items[1].status = PhotoStatus.starred;
      state.items[2].status = PhotoStatus.trashed;

      expect(state.starredCount, 2);
      expect(state.trashedCount, 1);
    });
  });

  group('TC-860 PhotoIdentity carries the counts with a zero default', () {
    test('omitting both fields keeps existing constructions valid', () {
      const identity = PhotoIdentity(
        displayName: 'DSCF4417.RAF',
        indexInFolder: 34,
        folderCount: 212,
        status: PhotoStatus.unmarked,
        exif: null,
      );
      expect(identity.starredCount, 0);
      expect(identity.trashedCount, 0);
    });

    test('the fields round-trip when supplied', () {
      const identity = PhotoIdentity(
        displayName: 'DSCF4417.RAF',
        indexInFolder: 37,
        folderCount: 412,
        status: PhotoStatus.starred,
        exif: null,
        starredCount: 61,
        trashedCount: 18,
      );
      expect(identity.starredCount, 61);
      expect(identity.trashedCount, 18);
    });
  });
}
