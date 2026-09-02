// R1-1 (parking-lot #P2, handover §8): the sidebar filmstrip declared
// `PhotoStripModel.onSelect` but nothing under lib/ ever called it — clicking
// a thumbnail did nothing. This file proves the wiring both in isolation
// (tapping a chip invokes `onSelect` with that item's id) and inside the
// real assembled app (tapping a chip actually changes `AppState.currentItem`
// through main_screen's `onSelect: state.selectItem` binding).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:halcyon_flutter/main.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/views/layout/gallery/gallery_column.dart';
import 'package:halcyon_flutter/views/layout/main_surface.dart';

import '../../support/temp_dirs.dart';

PixelPayload _payload() => PixelPayload(
  width: 4,
  height: 4,
  rgba: Uint8List(4 * 4 * 4),
);

PhotoItem _item(String id) => PhotoItem(id: id, files: [File('src/$id.jpg')]);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'TC-552 tapping a sidebar thumbnail invokes onSelect with that item id',
    (tester) async {
      final selected = <String>[];
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      final surface = MainSurface(
        viewport: const ColoredBox(
          key: ValueKey<String>('gallery-test-viewport'),
          color: Colors.red,
        ),
        statusOverlay: const SizedBox.shrink(),
        strip: PhotoStripModel(
          items: [for (final id in ['a0', 'a1', 'a2']) _item(id)],
          selectedId: 'a0',
          recycleMode: false,
          onSelect: selected.add,
          payloadFor: (_) => _payload(),
          onVisibleRange: (_, __) {},
        ),
        identity: const PhotoIdentity(
          displayName: 'IMG_0001.jpg',
          indexInFolder: 1,
          folderCount: 3,
          status: PhotoStatus.unmarked,
          exif: null,
        ),
        actions: PhotoActions(
          recycleMode: false,
          onStar: () {},
          onTrash: () {},
          onToggleRecycleMode: () {},
          onOpenFolder: () {},
          menu: const SizedBox.shrink(),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 200,
                height: 900,
                child: GalleryColumn(
                  surface: surface,
                  width: 200,
                  onWidthDelta: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Tap the SECOND chip (not the already-selected one), so a bug that
      // just always reports the currently-selected id would still be caught.
      await tester.tap(
        find.byKey(const ValueKey<String>('gallery-chip-tap-a1')),
      );
      await tester.pump();

      expect(selected, ['a1']);
      await tester.binding.setSurfaceSize(null);
    },
  );

  testWidgets(
    'TC-552 tapping a thumbnail inside the real app changes AppState.currentItem',
    (tester) async {
      late AppState state;
      late Directory dir;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('halcyon_thumbtap_');
        addTempDirTeardown(dir);
        await File('${dir.path}/IMG_0001.jpg').writeAsBytes(const [1, 2, 3]);
        await File('${dir.path}/IMG_0002.jpg').writeAsBytes(const [4, 5, 6]);
        state = AppState(
          imageLoader: (path, {required purpose}) async =>
              const NativeImageFailure('not-used', 'no-op'),
        );
        addTearDown(state.dispose);
        await state.loadFolder(dir);
      });

      expect(state.items.length, 2);
      final firstId = state.items[0].id;
      final secondId = state.items[1].id;
      state.selectItem(firstId);

      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const HalcyonApp(),
        ),
      );
      // TC-542's real-app case uses the same explicit-pump pattern rather
      // than pumpAndSettle: the app surface has an ongoing animation (the
      // welcome/gallery transitions) that never settles on its own. This
      // also drains the `selectItem` follow-up timers above (tier-2
      // preload/working-set-trim/status-line auto-hide, see the comment
      // below).
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));

      expect(state.selectedItemID, firstId);

      final secondChip = find.byKey(
        ValueKey<String>('gallery-chip-tap-$secondId'),
      );
      expect(secondChip, findsOneWidget);
      await tester.tap(secondChip);
      await tester.pump();
      expect(state.selectedItemID, secondId);

      // `selectItem` fans out into several debounced follow-up timers
      // (tier-2 preload at 250ms, a working-set-trim request at 2s, and a
      // status-line auto-hide at 5s) — none are this test's concern, but
      // all must be drained before teardown disposes the widget tree or the
      // pending-timer invariant trips.
      await tester.pump(const Duration(seconds: 6));
    },
  );
}
