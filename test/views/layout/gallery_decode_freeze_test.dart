// TC-541: the decode target is held still while the gutter is being dragged.
//
// Background: the user's 2026-09-02 ruling made the gallery viewport REFLOW as
// the gutter widens (TC-540), which is a layout change on every drag frame.
// Layout is cheap; a changed decode target is not — it is a new ImageProvider
// cache key and therefore a fresh tier-1 decode per frame, which is exactly
// what AD-011's frozen identity rule exists to prevent. GalleryDesktopSurface
// wraps the viewport in a DecodeSizeFreeze carrying its drag flag, so
// PhotoViewport keeps reporting the last settled size until the drag stalls.
//
// This test therefore asserts a NEGATIVE during the gesture (the reported size
// does not move) and a POSITIVE after it (it does move, to the reflowed size).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/views/layout/common/photo_viewport.dart';
import 'package:halcyon_flutter/views/layout/gallery/gallery_column.dart';
import 'package:halcyon_flutter/views/layout/gallery/gallery_desktop.dart';
import 'package:halcyon_flutter/views/layout/main_surface.dart';
import 'package:halcyon_flutter/views/zoom_controller.dart';

import '../../support/temp_dirs.dart';

const List<int> _transparentPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, //
  0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, //
  0xAE, 0x42, 0x60, 0x82,
];

/// Records every decode target the viewport reports, in order.
class _RecordingAppState extends AppState {
  _RecordingAppState()
      : super(
          imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
              NativeImageBytes(Uint8List.fromList(_transparentPng)),
        );

  final List<(int, int)> reported = <(int, int)>[];

  @override
  void setViewportSize(int width, int height) {
    reported.add((width, height));
    super.setViewportSize(width, height);
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<_RecordingAppState> pumpSurface(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    late _RecordingAppState state;
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('halcyon_freeze_');
      addTempDirTeardown(dir);
      await File('${dir.path}/IMG_0001.jpg')
          .writeAsBytes(Uint8List.fromList(_transparentPng));
      state = _RecordingAppState();
      addTearDown(state.dispose);
      await state.loadFolder(dir);
      state.selectItem('IMG_0001');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AppState>.value(
          value: state,
          child: Scaffold(
            body: GalleryDesktopSurface(
              surface: MainSurface(
                viewport: PhotoViewport(key: kViewportKey, zoom: ZoomController()),
                statusOverlay: const SizedBox.shrink(),
                strip: PhotoStripModel(
                  revision: ValueNotifier<int>(0),
                  // Empty strip on purpose: this test's subject is the decode
                  // target, and real chips only add layout noise here.
                  items: const [],
                  selectedId: null,
                  recycleMode: false,
                  onSelect: (_) {},
                  payloadFor: (_) => null,
                  onVisibleRange: (_, __) {},
                ),
                identity: null,
                actions: PhotoActions(
                  recycleMode: false,
                  onStar: () {},
                  onTrash: () {},
                  onToggleRecycleMode: () {},
                  onOpenFolder: () {},
                  menu: const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return state;
  }

  testWidgets(
    'TC-541 the decode target holds still mid-drag and lands after it stalls',
    (tester) async {
      final state = await pumpSurface(tester);
      expect(state.reported, isNotEmpty, reason: 'no baseline decode target');
      final settled = state.reported.last;

      // Drive a real multi-step drag WITHOUT lifting the pointer, so the
      // surface's drag flag is true for every frame in between.
      final handleX =
          tester.getRect(find.byType(GalleryColumn)).right - 2.5;
      final gesture = await tester.startGesture(Offset(handleX, 400));
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(7, 0));
        await tester.pump();
      }

      // The layout DID reflow — this is the user-mandated behaviour, and it is
      // what makes the frozen decode target meaningful rather than vacuous.
      final width = tester.getSize(find.byType(GalleryColumn)).width;
      expect(width, greaterThan(kGalleryColumnMinWidth));
      expect(
        tester.getRect(find.byKey(kViewportKey)).left,
        closeTo(width, 0.5),
      );

      // ...but every target reported during the gesture is the settled one.
      expect(
        state.reported.every((r) => r == settled),
        isTrue,
        reason: 'decode target changed mid-drag: ${state.reported}',
      );

      await gesture.up();
      // Past the stall delay: the freeze lifts and the real target lands once.
      await tester.pump(kGalleryWidthBadgeDelay + const Duration(milliseconds: 50));
      await tester.pump();

      expect(state.reported.last, isNot(settled));
      expect(
        state.reported.last.$1,
        lessThan(settled.$1),
        reason: 'the photo is narrower now, so the target must have shrunk',
      );
    },
  );
}
