import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/providers/rename_coordinator.dart';
import 'package:halcyon_flutter/services/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_source_types.dart';
import 'package:halcyon_flutter/services/photo_status_store.dart';
import 'package:halcyon_flutter/services/rename_rule.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('RenameCoordinator', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'halcyon_rename_coordinator_',
      );
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('TC-227 an empty rename plan does not clobber the previous batch\'s '
        'undo map', () async {
      await File(p.join(tempDir.path, 'A.JPG')).writeAsBytes(<int>[1, 2, 3]);

      var items = [
        PhotoItem(id: 'A', files: [File(p.join(tempDir.path, 'A.JPG'))]),
      ];

      final statusStore = PhotoStatusStore();
      Directory? dir = tempDir;
      String? selectedId = 'A';

      final coordinator = RenameCoordinator(
        statusStore: statusStore,
        itemsOf: () => items,
        dirOf: () => dir,
        selectedIdOf: () => selectedId,
        readMetadata: (its, {onProgress}) async => {
          for (final item in its)
            item.id: ExifMetadata(captureDate: DateTime(2026, 4, 7, 9, 3, 5)),
        },
        showStatus: (_) {},
        reloadFolder: (d, {targetSelectionId}) async {
          dir = d;
          selectedId = targetSelectionId;
        },
        notify: () {},
      );

      // First batch: a real rename, populating the undo map.
      await coordinator.renameByExif(
        const RenameRule(RenameRule.kDefaultTemplate),
        isCustom: false,
      );

      final renamedNames = tempDir
          .listSync()
          .map((e) => p.basename(e.path))
          .where((n) => !n.startsWith('.'))
          .toList();
      expect(renamedNames, ['2026-04-07-09-03-05.JPG']);
      items = [
        PhotoItem(
          id: '2026-04-07-09-03-05',
          files: [File(p.join(tempDir.path, '2026-04-07-09-03-05.JPG'))],
        ),
      ];
      selectedId = '2026-04-07-09-03-05';

      // Second batch: the rule produces no plans (every name already
      // matches), so the early return must fire BEFORE touching the undo
      // map -- the first batch's map must survive intact.
      await coordinator.renameByExif(
        const RenameRule(RenameRule.kDefaultTemplate),
        isCustom: false,
      );

      // Prove the map from batch 1 is still the one undo consumes: undo
      // now must restore 'A.JPG', not no-op on an empty map.
      await coordinator.undoRename();

      expect(File(p.join(tempDir.path, 'A.JPG')).existsSync(), isTrue);
      expect(
        File(p.join(tempDir.path, '2026-04-07-09-03-05.JPG')).existsSync(),
        isFalse,
      );
    });
  });

  testWidgets('TC-228 displayProvider returns the identical object '
      'currentFullResProvider returns once the full-size decode is ready', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp(
        'halcyon_display_provider_',
      );
      addTearDown(() => dir.delete(recursive: true));
      // A DNG with no embedded preview: the loader reports
      // NativeImageNeedsRawDecode and the fake dngDecoder hands back pixels,
      // so this item is pixel-backed (currentDecodedProvider is the
      // provider that later gets promoted to tier-2 as a RawFullResImage --
      // fullResProviderFor only ever returns non-null for that kind).
      await File(p.join(dir.path, 'IMG_0001.dng')).writeAsBytes(<int>[1, 2, 3]);

      final state = AppState(
        imageLoader: (path, {required purpose}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        dngDecoder: (path) async => DecodedRgba(
          rgba: Uint8List.fromList(List<int>.generate(2 * 2 * 4, (i) => i)),
          width: 2,
          height: 2,
        ),
      );
      addTearDown(state.dispose);

      state.setViewportSize(10, 10);
      await state.loadFolder(dir);

      // Before the tier-2 debounce elapses there is no full-size decode
      // to be identical with -- displayProvider must fall back to the
      // decoded-pixels provider (null here, since this item has preview
      // bytes rather than raw pixels), not construct anything of its own.
      expect(state.currentItemHasFullSize, isFalse);
      expect(state.displayProvider, state.currentDecodedProvider);

      // After the debounce, tier-2 has landed in ImageCache. Poll instead
      // of a fixed sleep: the pipeline crosses a 250ms debounce plus a
      // real engine decode future.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!state.currentItemHasFullSize) {
        if (DateTime.now().isAfter(deadline)) {
          fail('timed out waiting for the tier-2 decode to land');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(state.currentItemHasFullSize, isTrue);
      expect(state.currentFullResProvider, isNotNull);
      expect(
        identical(state.displayProvider, state.currentFullResProvider),
        isTrue,
      );
    });
  });
}
