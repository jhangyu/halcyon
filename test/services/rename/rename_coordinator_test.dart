import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import '../../support/temp_dirs.dart';
import 'package:path/path.dart' as p;
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/rename/rename_coordinator.dart';
import 'package:halcyon_flutter/services/image_pipeline/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/library/photo_status_store.dart';
import 'package:halcyon_flutter/models/rename_rule.dart';
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

    // -----------------------------------------------------------------
    // F1 / AC2: the status remap used to be driven by the PLANS (the
    // intent). Any plan that did not land left its star keyed to a name
    // that does not exist, and the next scan's stale-key cleanup deleted
    // it -- silent loss of the user's marks.
    // -----------------------------------------------------------------

    /// A coordinator over [tempDir] that re-reads its item list on every
    /// call, the way AppState's supplier callbacks do.
    ({RenameCoordinator coordinator, List<StatusMessage> messages})
    buildCoordinator({
      required PhotoStatusStore statusStore,
      required List<PhotoItem> Function() itemsOf,
      required String? Function() selectedIdOf,
    }) {
      final messages = <StatusMessage>[];
      final coordinator = RenameCoordinator(
        statusStore: statusStore,
        itemsOf: itemsOf,
        dirOf: () => tempDir,
        selectedIdOf: selectedIdOf,
        readMetadata: (its, {onProgress}) async => {
          for (final item in its)
            item.id: ExifMetadata(captureDate: DateTime(2026, 4, 7, 9, 3, 5)),
        },
        showStatus: messages.add,
        reloadFolder: (d, {targetSelectionId}) async {},
        notify: () {},
      );
      return (coordinator: coordinator, messages: messages);
    }

    Future<Map<String, dynamic>> readStatusJson() async {
      final file = PhotoStatusStore().statusFileFor(tempDir);
      return json.decode(await file.readAsString()) as Map<String, dynamic>;
    }

    test('TC-709 a failed rename keeps its mark under the ORIGINAL id',
        () async {
      await File(p.join(tempDir.path, 'A.JPG')).writeAsBytes(<int>[1]);
      await File(p.join(tempDir.path, 'B.JPG')).writeAsBytes(<int>[1]);

      final statusStore = PhotoStatusStore();
      final items = [
        PhotoItem(
          id: 'A',
          files: [File(p.join(tempDir.path, 'A.JPG'))],
          status: PhotoStatus.starred,
        ),
        PhotoItem(
          id: 'B',
          files: [File(p.join(tempDir.path, 'B.JPG'))],
          status: PhotoStatus.trashed,
        ),
      ];
      await statusStore.saveStatuses(tempDir, items);

      // Both items render the same name, so A takes it and B is planned onto
      // '<name>-1.JPG'. The blocker has to appear AFTER planning (planning
      // reads the directory and would simply route B around anything already
      // there), so it is created from the first progress callback -- i.e.
      // once A has landed and B has not yet been attempted. A non-empty
      // directory at B's destination makes B's rename, and only B's, throw.
      final messages = <StatusMessage>[];
      final coordinator = RenameCoordinator(
        statusStore: statusStore,
        itemsOf: () => items,
        dirOf: () => tempDir,
        selectedIdOf: () => 'A',
        readMetadata: (its, {onProgress}) async => {
          for (final item in its)
            item.id: ExifMetadata(captureDate: DateTime(2026, 4, 7, 9, 3, 5)),
        },
        showStatus: (message) {
          messages.add(message);
          if (message.actionLabel == '取消') {
            final blocked = Directory(
              p.join(tempDir.path, '2026-04-07-09-03-05-1.JPG'),
            );
            if (!blocked.existsSync()) {
              blocked.createSync();
              File(p.join(blocked.path, 'x')).writeAsStringSync('x');
            }
          }
        },
        reloadFolder: (d, {targetSelectionId}) async {},
        notify: () {},
      );
      await coordinator.renameByExif(
        const RenameRule(RenameRule.kDefaultTemplate),
        isCustom: false,
      );

      final map = await readStatusJson();
      // B is still called B on disk; its trash mark must still be keyed 'B'.
      expect(File(p.join(tempDir.path, 'B.JPG')).existsSync(), isTrue);
      expect(map['B'], 'trashed',
          reason: 'a mark was remapped to a name that never landed: $map');

      // ...and the user is told WHICH file failed, not just a count.
      expect(messages.last.text, contains('失敗'));
      expect(messages.last.text, contains('B'));
    });

    test('TC-710 cancelling mid-batch leaves the untouched items\' marks '
        'under their original ids', () async {
      for (final name in ['A', 'B']) {
        await File(p.join(tempDir.path, '$name.JPG')).writeAsBytes(<int>[1]);
      }

      final statusStore = PhotoStatusStore();
      final items = [
        PhotoItem(
          id: 'A',
          files: [File(p.join(tempDir.path, 'A.JPG'))],
          status: PhotoStatus.starred,
        ),
        PhotoItem(
          id: 'B',
          files: [File(p.join(tempDir.path, 'B.JPG'))],
          status: PhotoStatus.starred,
        ),
      ];
      await statusStore.saveStatuses(tempDir, items);

      late final RenameCoordinator coordinator;
      coordinator = RenameCoordinator(
        statusStore: statusStore,
        itemsOf: () => items,
        dirOf: () => tempDir,
        selectedIdOf: () => 'A',
        readMetadata: (its, {onProgress}) async => {
          for (final item in its)
            item.id: ExifMetadata(captureDate: DateTime(2026, 4, 7, 9, 3, 5)),
        },
        // The real cancel button fires from the progress status message.
        showStatus: (message) {
          if (message.actionLabel == '取消') coordinator.cancelRename();
        },
        reloadFolder: (d, {targetSelectionId}) async {},
        notify: () {},
      );

      await coordinator.renameByExif(
        const RenameRule(RenameRule.kDefaultTemplate),
        isCustom: false,
      );

      final map = await readStatusJson();
      final onDisk = tempDir
          .listSync()
          .map((e) => p.basenameWithoutExtension(e.path))
          .where((n) => !n.startsWith('.'))
          .toSet();
      // Every id that still exists on disk must still carry its mark.
      for (final id in onDisk) {
        expect(map[id], 'starred',
            reason: 'mark lost for $id after cancel; status=$map disk=$onDisk');
      }
    });

    // -----------------------------------------------------------------
    // F2 / AC3: undo remapped marks from an IN-MEMORY map, so after a
    // restart (fresh coordinator) undo renamed the files back but left
    // every mark keyed to the abandoned new names.
    // -----------------------------------------------------------------
    test('TC-711 undo after a restart remaps marks from the journal',
        () async {
      await File(p.join(tempDir.path, 'A.JPG')).writeAsBytes(<int>[1]);

      final statusStore = PhotoStatusStore();
      var items = [
        PhotoItem(
          id: 'A',
          files: [File(p.join(tempDir.path, 'A.JPG'))],
          status: PhotoStatus.starred,
        ),
      ];
      await statusStore.saveStatuses(tempDir, items);

      final first = buildCoordinator(
        statusStore: statusStore,
        itemsOf: () => items,
        selectedIdOf: () => 'A',
      );
      await first.coordinator.renameByExif(
        const RenameRule(RenameRule.kDefaultTemplate),
        isCustom: false,
      );
      expect((await readStatusJson())['2026-04-07-09-03-05'], 'starred');

      // Simulate a restart: a brand new coordinator AND store, with no
      // memory of the batch -- exactly what the user gets after quitting.
      items = [
        PhotoItem(
          id: '2026-04-07-09-03-05',
          files: [File(p.join(tempDir.path, '2026-04-07-09-03-05.JPG'))],
          status: PhotoStatus.starred,
        ),
      ];
      final restarted = buildCoordinator(
        statusStore: PhotoStatusStore(),
        itemsOf: () => items,
        selectedIdOf: () => '2026-04-07-09-03-05',
      );

      await restarted.coordinator.undoRename();

      expect(File(p.join(tempDir.path, 'A.JPG')).existsSync(), isTrue);
      final map = await readStatusJson();
      expect(map['A'], 'starred',
          reason: 'undo restored the filename but not the mark key: $map');
      expect(map.containsKey('2026-04-07-09-03-05'), isFalse);
    });

    // -----------------------------------------------------------------
    // SF-2: a partially-refused undo (commit 26db896's refusal branch) used
    // to be reported as plain success. Must name the failed entry the same
    // way the apply path does.
    // -----------------------------------------------------------------
    test('TC-728 a refused undo entry is named in the status message, not '
        'reported as plain success', () async {
      for (final name in ['A', 'B']) {
        await File(p.join(tempDir.path, '$name.JPG')).writeAsBytes(<int>[1]);
      }

      final statusStore = PhotoStatusStore();
      var items = [
        PhotoItem(id: 'A', files: [File(p.join(tempDir.path, 'A.JPG'))]),
        PhotoItem(id: 'B', files: [File(p.join(tempDir.path, 'B.JPG'))]),
      ];

      // Distinct capture times so the two items don't collide onto the
      // same rendered name and one doesn't get a '-1' suffix.
      final firstCoordinator = RenameCoordinator(
        statusStore: statusStore,
        itemsOf: () => items,
        dirOf: () => tempDir,
        selectedIdOf: () => 'A',
        readMetadata: (its, {onProgress}) async => {
          for (final item in its)
            item.id: ExifMetadata(
              captureDate: item.id == 'A'
                  ? DateTime(2026, 4, 7, 9, 3, 5)
                  : DateTime(2026, 4, 7, 9, 3, 6),
            ),
        },
        showStatus: (_) {},
        reloadFolder: (d, {targetSelectionId}) async {},
        notify: () {},
      );
      await firstCoordinator.renameByExif(
        const RenameRule(RenameRule.kDefaultTemplate),
        isCustom: false,
      );

      final renamedNames = tempDir
          .listSync()
          .map((e) => p.basename(e.path))
          .where((n) => !n.startsWith('.'))
          .toSet();
      expect(renamedNames, {
        '2026-04-07-09-03-05.JPG',
        '2026-04-07-09-03-06.JPG',
      });

      // Occupy A's ORIGINAL name with an unrelated file before undo -- the
      // refusal scenario introduced by 26db896.
      await File(p.join(tempDir.path, 'A.JPG')).writeAsBytes(<int>[9, 9, 9]);

      items = [
        PhotoItem(
          id: '2026-04-07-09-03-05',
          files: [File(p.join(tempDir.path, '2026-04-07-09-03-05.JPG'))],
        ),
        PhotoItem(
          id: '2026-04-07-09-03-06',
          files: [File(p.join(tempDir.path, '2026-04-07-09-03-06.JPG'))],
        ),
      ];
      final second = buildCoordinator(
        statusStore: statusStore,
        itemsOf: () => items,
        selectedIdOf: () => null,
      );

      await second.coordinator.undoRename();

      // The refused entry's original file must be untouched, and B must
      // still have been restored.
      expect(
        await File(p.join(tempDir.path, 'A.JPG')).readAsBytes(),
        [9, 9, 9],
        reason: 'the occupying file must not be overwritten by undo',
      );
      expect(File(p.join(tempDir.path, 'B.JPG')).existsSync(), isTrue);

      final lastMessage = second.messages.last;
      expect(lastMessage.text, contains('失敗'));
      expect(lastMessage.text, contains('2026-04-07-09-03-05'));
    });

    // -----------------------------------------------------------------
    // SF-3: real-filesystem exercise of the refusal logic (26db896,
    // rename_service.dart:238-255) through `undoLastRename`, driven via the
    // coordinator's public undoRename() so the whole seam -- journal replay,
    // refusal, status remap and message -- is proven end to end.
    // -----------------------------------------------------------------
    test('TC-729 real filesystem: undo refuses to overwrite an unrelated '
        'file occupying an original name; other entries still undo',
        () async {
      for (final name in ['A', 'B', 'C']) {
        await File(p.join(tempDir.path, '$name.JPG')).writeAsBytes(<int>[1]);
      }

      final statusStore = PhotoStatusStore();
      var items = [
        PhotoItem(id: 'A', files: [File(p.join(tempDir.path, 'A.JPG'))]),
        PhotoItem(id: 'B', files: [File(p.join(tempDir.path, 'B.JPG'))]),
        PhotoItem(id: 'C', files: [File(p.join(tempDir.path, 'C.JPG'))]),
      ];

      final dates = {
        'A': DateTime(2026, 4, 7, 9, 3, 5),
        'B': DateTime(2026, 4, 7, 9, 3, 6),
        'C': DateTime(2026, 4, 7, 9, 3, 7),
      };
      final firstCoordinator = RenameCoordinator(
        statusStore: statusStore,
        itemsOf: () => items,
        dirOf: () => tempDir,
        selectedIdOf: () => 'A',
        readMetadata: (its, {onProgress}) async => {
          for (final item in its) item.id: ExifMetadata(captureDate: dates[item.id]!),
        },
        showStatus: (_) {},
        reloadFolder: (d, {targetSelectionId}) async {},
        notify: () {},
      );
      await firstCoordinator.renameByExif(
        const RenameRule(RenameRule.kDefaultTemplate),
        isCustom: false,
      );

      final renamedNames = tempDir
          .listSync()
          .map((e) => p.basename(e.path))
          .where((n) => !n.startsWith('.'))
          .toSet();
      expect(renamedNames, {
        '2026-04-07-09-03-05.JPG',
        '2026-04-07-09-03-06.JPG',
        '2026-04-07-09-03-07.JPG',
      });

      // Occupy B's original name with an unrelated file's content -- this is
      // the real-filesystem trigger for the refusal branch in
      // `_refuseIfOverwritingOtherFile` (rename_service.dart:306-...): `to`
      // (B.JPG) now resolves to a canonical path different from `from`
      // (2026-04-07-09-03-06.JPG).
      final occupyingContent = <int>[42, 42, 42, 42];
      await File(p.join(tempDir.path, 'B.JPG')).writeAsBytes(occupyingContent);

      items = [
        PhotoItem(
          id: '2026-04-07-09-03-05',
          files: [File(p.join(tempDir.path, '2026-04-07-09-03-05.JPG'))],
        ),
        PhotoItem(
          id: '2026-04-07-09-03-06',
          files: [File(p.join(tempDir.path, '2026-04-07-09-03-06.JPG'))],
        ),
        PhotoItem(
          id: '2026-04-07-09-03-07',
          files: [File(p.join(tempDir.path, '2026-04-07-09-03-07.JPG'))],
        ),
      ];
      final second = buildCoordinator(
        statusStore: statusStore,
        itemsOf: () => items,
        selectedIdOf: () => null,
      );

      await second.coordinator.undoRename();

      // (a) the refused entry is reported as a failure, not silently
      // overwritten -- its message names the entry.
      final lastMessage = second.messages.last;
      expect(lastMessage.text, contains('失敗'));
      expect(lastMessage.text, contains('2026-04-07-09-03-06'));

      // (b) the occupying file's content is intact -- refusal, not overwrite.
      expect(
        await File(p.join(tempDir.path, 'B.JPG')).readAsBytes(),
        occupyingContent,
      );
      // The renamed file that WOULD have been moved onto B.JPG is still
      // there under its post-rename name, since the move never happened.
      expect(
        File(p.join(tempDir.path, '2026-04-07-09-03-06.JPG')).existsSync(),
        isTrue,
      );

      // (c) the other two entries undid successfully.
      expect(File(p.join(tempDir.path, 'A.JPG')).existsSync(), isTrue);
      expect(File(p.join(tempDir.path, 'C.JPG')).existsSync(), isTrue);
      expect(
        File(p.join(tempDir.path, '2026-04-07-09-03-05.JPG')).existsSync(),
        isFalse,
      );
      expect(
        File(p.join(tempDir.path, '2026-04-07-09-03-07.JPG')).existsSync(),
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
      addTempDirTeardown(dir);
      // A DNG with no embedded preview: the loader reports
      // NativeImageNeedsRawDecode and the fake dngDecoder hands back pixels,
      // so this item is pixel-backed (currentDecodedProvider is the
      // provider that later gets promoted to tier-2 as a RawFullResImage --
      // fullResProviderFor only ever returns non-null for that kind).
      await File(p.join(dir.path, 'IMG_0001.dng')).writeAsBytes(<int>[1, 2, 3]);

      final state = AppState(
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            const NativeImageNeedsRawDecode(exifOrientation: 1),
        // OPAQUE pixels. The identity short-circuit in
        // decoded_rgba_image_provider.dart asserts (debug-only) that sampled
        // alpha is 0xFF, because it hands back the decoder's STRAIGHT RGBA
        // where the old readback path returned PREMULTIPLIED. A ramp-filled
        // buffer (alpha bytes 3/7/11/15) trips that assert, the decode is
        // caught as a failure, and the item latches as a permanent miss --
        // so tier-2 never lands and this test times out for a reason it
        // asserts nothing about. Same repair as 253b89f / d43c2a1 / 5629e25.
        dngDecoder: (path) async {
          final rgba = Uint8List.fromList(
            List<int>.generate(2 * 2 * 4, (i) => i % 4 == 3 ? 0xFF : i),
          );
          return DecodedRgba(rgba: rgba, width: 2, height: 2);
        },
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
