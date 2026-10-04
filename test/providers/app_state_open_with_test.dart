
import 'package:flutter_test/flutter_test.dart';
import '../support/app_state_fixtures.dart';
import '../support/temp_dirs.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../support/fixture_files.dart';

const _stubBytes = <int>[1, 2, 3];

/// F-16 "Open With" entry point coverage for [AppState.openPhotoAtPath].
///
/// The destructive case matters because Android's ACTION_VIEW hands the app a
/// `content://` URI whose opaque segment (e.g. `/document/image:1234.jpg`)
/// ends in a supported extension but is not a filesystem path. Without an
/// existence guard that string sends `loadFolder` at a directory that does not
/// exist, and `loadFolder` clears the current folder, items and selection
/// *before* it scans -- wiping the folder the user is culling.
void main() {
  // The controller's debounced full-size sweep can fire after a test body and
  // reach PaintingBinding.instance; without a binding that throws
  // "Binding has not yet been initialized" (prepush quarantine run0-red.log).
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('AppState.openPhotoAtPath', () {
    test('TC-160 keeps the loaded folder when the file does not exist', () async {
      final dir = await makeTempDir('halcyon_openwith_');
      await writeFixtureBytes(dir, 'IMG_0001.jpg', _stubBytes);
      await writeFixtureBytes(dir, 'IMG_0002.jpg', _stubBytes);

      final state = testState();
      await state.loadFolder(dir);
      final before = state.items.map((item) => item.id).toList();

      // Shaped like the opaque path segment of a content:// URI.
      await state.openPhotoAtPath('/nonexistent/dir/fake.jpg');

      expect(state.currentDir?.path, dir.path);
      expect(state.items.map((item) => item.id), before);
      expect(state.selectedItemID, 'IMG_0001');
    });

    test(
      'TC-161 keeps the loaded folder when the parent directory is missing',
      () async {
        final dir = await makeTempDir('halcyon_openwith_');
        await writeFixtureBytes(dir, 'IMG_0001.jpg', _stubBytes);

        final state = testState();
        await state.loadFolder(dir);

        await state.openPhotoAtPath(
          p.join(dir.path, 'no_such_subdir', 'IMG_9999.dng'),
        );

        expect(state.currentDir?.path, dir.path);
        expect(state.items.map((item) => item.id), ['IMG_0001']);
        expect(state.selectedItemID, 'IMG_0001');
      },
    );

    test('TC-162 still opens a real file and selects it', () async {
      final dir = await makeTempDir('halcyon_openwith_ok_');
      await writeFixtureBytes(dir, 'IMG_0001.jpg', _stubBytes);
      await writeFixtureBytes(dir, 'IMG_0002.dng', _stubBytes);

      final state = testState();
      await state.openPhotoAtPath(p.join(dir.path, 'IMG_0002.dng'));

      expect(state.currentDir?.path, dir.path);
      expect(state.items.map((item) => item.id), ['IMG_0001', 'IMG_0002']);
      expect(state.selectedItemID, 'IMG_0002');
    });

    test('TC-163 ignores unsupported extensions', () async {
      final dir = await makeTempDir('halcyon_openwith_');
      await writeFixtureBytes(dir, 'IMG_0001.jpg', _stubBytes);
      final other = await makeTempDir('halcyon_other_');
      await writeFixtureBytes(other, 'notes.txt', _stubBytes);

      final state = testState();
      await state.loadFolder(dir);
      await state.openPhotoAtPath(p.join(other.path, 'notes.txt'));

      expect(state.currentDir?.path, dir.path);
      expect(state.selectedItemID, 'IMG_0001');
    });
  });
}

