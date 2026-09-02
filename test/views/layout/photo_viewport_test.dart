import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/views/layout/common/app_actions_menu.dart'
    show openFolderShortcutLabel;
import 'package:halcyon_flutter/views/layout/common/photo_viewport.dart';
import 'package:halcyon_flutter/views/layout/gallery/gallery_palette.dart';
import 'package:halcyon_flutter/views/zoom_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../support/temp_dirs.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// Pumps a [PhotoViewport] with a real 1x1 transparent PNG so the Image
  /// widget can actually decode (a real decode must land for the viewer to
  /// leave its spinner branch) and the single setViewportSize call is made.
  Future<AppState> pumpViewport(WidgetTester tester, {ZoomController? zoom}) async {
    const transparentPng = <int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
      0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1x1
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, // RGBA
      0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, // IEND
      0xAE, 0x42, 0x60, 0x82,
    ];

    late AppState state;
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('halcyon_pvp_');
      addTempDirTeardown(dir);
      await File('${dir.path}/IMG_0001.jpg').writeAsBytes(
        Uint8List.fromList(transparentPng),
      );
      state = AppState(imageLoader: (path, {required purpose}) async {
        return NativeImageBytes(Uint8List.fromList(transparentPng));
      });
      addTearDown(state.dispose);
      await state.loadFolder(dir);
      state.selectItem('IMG_0001');
      // Let the decode from selectItem's fire-and-forget fetch land so the
      // view has real bytes for the Image widget (dart:io future inside the
      // test body never resolves under FakeAsync).
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AppState>.value(
          value: state,
          child: PhotoViewport(zoom: zoom ?? ZoomController()),
        ),
      ),
    );
    await tester.pump();
    return state;
  }

  testWidgets(
    'PhotoViewport renders a real decoded photo inside InteractiveViewer, '
    'not a spinner',
    (tester) async {
      final state = await pumpViewport(tester);

      expect(state.currentItemFailed, isFalse);
      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer)).maxScale,
        5.0,
      );
      expect(
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer)).minScale,
        1.0,
      );
      expect(
        tester
            .widget<InteractiveViewer>(find.byType(InteractiveViewer))
            .trackpadScrollCausesScale,
        isTrue,
      );
    },
  );

  testWidgets(
    'TC-537 the gallery welcome state replaces the stock Material screen',
    (tester) async {
      // The active layout theme is `gallery` (layout_registry.dart), so the
      // empty branch must draw mockup frame 7 rather than the grey-icon
      // Material screen that used to be the app's first surface.
      final state = AppState();
      addTearDown(state.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: galleryThemeData(Brightness.light),
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: PhotoViewport(zoom: ZoomController()),
          ),
        ),
      );

      // Every element the mockup's `.empty` block carries.
      expect(find.byKey(const Key('galleryEmptyMount')), findsOneWidget);
      // `.empty .kicker` is uppercased by the spec.
      expect(find.text('HALCYON'), findsOneWidget);
      expect(find.text('Halcyon'), findsNothing);
      expect(find.text('No folder open'), findsOneWidget);
      expect(
        find.textContaining('Open a folder of RAW or JPEG files'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('galleryEmptyOpenFolder')), findsOneWidget);
      expect(find.text('Open Folder'), findsOneWidget);
      expect(
        find.textContaining('drop a folder onto the window', findRichText: true),
        findsOneWidget,
      );
      // The hint advertises the chord that TC-542 proves is real, in this
      // platform's spelling.
      expect(
        find.textContaining(openFolderShortcutLabel(), findRichText: true),
        findsOneWidget,
      );

      // The mount is the photo's own 3:2.
      final mount = tester.getSize(find.byKey(const Key('galleryEmptyMount')));
      expect(mount, const Size(432, 288));

      // The stock screen is gone.
      expect(find.text('Select a folder to begin'), findsNothing);
      expect(find.byType(ElevatedButton), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(Image), findsNothing);
    },
  );

  testWidgets(
    'TC-538 every welcome element sits on one centred axis',
    (tester) async {
      // The user-caught defect in the mockup round: the button shared a flex
      // row with the shortcut hint, so centring the ROW pushed the button off
      // the axis by half the hint's width. Nothing may hang off either side.
      final state = AppState();
      addTearDown(state.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: galleryThemeData(Brightness.light),
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: PhotoViewport(zoom: ZoomController()),
          ),
        ),
      );

      double centreOf(Finder f) {
        final rect = tester.getRect(f);
        return rect.left + rect.width / 2;
      }

      final axis = centreOf(find.byKey(const Key('galleryEmptyMount')));
      for (final f in <Finder>[
        find.byKey(const Key('galleryEmptyOpenFolder')),
        find.byKey(const Key('galleryEmptyDropHint')),
        find.text('No folder open'),
        find.text('HALCYON'),
      ]) {
        expect(centreOf(f), moreOrLessEquals(axis, epsilon: 0.5));
      }
    },
  );

  testWidgets(
    'PhotoViewport shows the unreadable message for a failed item',
    (tester) async {
      const transparentPng = <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89,
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
        0xAE, 0x42, 0x60, 0x82,
      ];

      late AppState state;
      await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('halcyon_pvp_');
        addTempDirTeardown(dir);
        await File('${dir.path}/IMG_0001.jpg').writeAsBytes(
          Uint8List.fromList(transparentPng),
        );
        state = AppState(
          imageLoader: (path, {required purpose}) async {
            return const NativeImageFailure('MOCK_FAILURE', 'simulated');
          },
        );
        addTearDown(state.dispose);
        await state.loadFolder(dir);
        state.selectItem('IMG_0001');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: PhotoViewport(zoom: ZoomController()),
          ),
        ),
      );
      await tester.pump();

      expect(state.currentItemFailed, isTrue);
      expect(find.text('無法讀取「IMG_0001」\n檔案可能已損毀或格式不支援'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );

  // Removed (T11): 'PhotoViewport has no floating action bar inside the
  // viewport', which asserted a floating-action-bar widget type findsNothing.
  // That old floating-bar class is deleted in this same task (retired in
  // favor of the gallery gutter's marks row), so there is no longer a class
  // this negative-space check could catch a regression of — a check against a
  // symbol that no longer exists can never fail, which is not evidence.
}