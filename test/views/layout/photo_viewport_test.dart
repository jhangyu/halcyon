import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/perf/perf_log.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/views/layout/common/app_actions_menu.dart'
    show openFolderShortcutLabel;
import 'package:halcyon_flutter/views/layout/common/photo_viewport.dart';
import 'package:halcyon_flutter/views/layout/gallery/gallery_palette.dart';
import 'package:halcyon_flutter/views/zoom_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../support/mouse_nav_fixtures.dart';
import '../../support/preload_fixtures.dart' show tinyPngBytes, until;
import '../../support/temp_dirs.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// Pumps a [PhotoViewport] with a real, DECODABLE 1x1 PNG and waits for
  /// its full-size entry: since 2026-10-04 (memory.md AD-072) the viewer
  /// leaves its spinner only for the full-size image or the sidebar
  /// thumbnail, never for an on-demand viewport-resolution decode.
  Future<AppState> pumpViewport(
    WidgetTester tester, {
    ZoomController? zoom,
    List<int>? decodablePng,
  }) async {
    final transparentPng = decodablePng ?? tinyPngBytes;

    late AppState state;
    await tester.runAsync(() async {
      final dir = await makeTempDir('halcyon_pvp_');
      await File('${dir.path}/IMG_0001.jpg').writeAsBytes(
        Uint8List.fromList(transparentPng),
      );
      state = AppState(imageLoader: (path, {required purpose, int? targetLongEdge}) async {
        return NativeImageBytes(Uint8List.fromList(transparentPng));
      });
      addTearDown(state.dispose);
      await state.loadFolder(dir);
      state.selectItem('IMG_0001');
      // Let the decode from selectItem's fire-and-forget fetch land so the
      // view has real bytes for the Image widget (dart:io future inside the
      // test body never resolves under FakeAsync).
      await until(() => state.currentItemHasFullSize,
          reason: 'the selected photo to reach full resolution');
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
        final dir = await makeTempDir('halcyon_pvp_');
        await File('${dir.path}/IMG_0001.jpg').writeAsBytes(
          Uint8List.fromList(transparentPng),
        );
        state = AppState(
          imageLoader: (path, {required purpose, int? targetLongEdge}) async {
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
      // displayName now shows the extension for a single-file item (R1-4).
      expect(find.text('無法讀取「IMG_0001.jpg」\n檔案可能已損毀或格式不支援'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );

  // TC-1408 (l1l2 R7): the perf-tracking listener disposes its clone. The
  // painted image's open-handle count is read with perf tracking OFF, then
  // tracking is switched ON and the viewport rebuilt so `_perfTrack` attaches
  // its listener; the count must not grow.
  testWidgets('TC-1408 (R7) the perf-tracking listener disposes its clone',
      (tester) async {
    final lines = <String>[];
    PerfLog.testSink = lines.add;
    addTearDown(() {
      PerfLog.testSink = null;
      PerfLog.enabled = false;
    });
    // The default fixture PNG has no IDAT chunk (it never decodes, the viewport
    // shows its broken-image icon), so this test supplies a decodable one.
    await pumpViewport(tester, decodablePng: tinyPngBytes);
    for (var i = 0; i < 20 && find.byType(RawImage).evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.byType(RawImage), findsOneWidget,
        reason: 'vacuity: the photo decoded and painted before the first read');
    int openHandles() => tester
        .widget<RawImage>(find.byType(RawImage))
        .image!
        .debugGetOpenHandleStackTraces()!
        .length;
    final before = openHandles();

    PerfLog.enabled = true;
    // Not awaited: under fake async the reassemble future only completes on a
    // pumped frame, so awaiting it before the pump below would hang the test.
    unawaited(tester.binding.reassembleApplication());
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(lines.any((l) => l.startsWith('image.resolved|')), isTrue,
        reason: 'vacuity: the perf listener attached and fired');
    expect(openHandles(), before,
        reason: "the perf listener's clone must have been disposed");
  });

  // Removed (T11): 'PhotoViewport has no floating action bar inside the
  // viewport', which asserted a floating-action-bar widget type findsNothing.
  // That old floating-bar class is deleted in this same task (retired in
  // favor of the gallery gutter's marks row), so there is no longer a class
  // this negative-space check could catch a regression of — a check against a
  // symbol that no longer exists can never fail, which is not evidence.

  // ---- mouse-click navigation (spec §1, §4; Round 2 T7 unskips) ----
  Future<AppState> pumpNavViewport(
    WidgetTester tester, {
    ZoomController? zoom,
    NativeImageLoad? imageLoader,
    bool waitForFullSize = true,
    bool enabled = true,
  }) async {
    final state = await loadMouseNavState(tester,
        imageLoader: imageLoader, waitForFullSize: waitForFullSize);
    if (enabled) state.setMouseNavEnabled(true);
    await tester.pumpWidget(MaterialApp(
      home: ChangeNotifierProvider<AppState>.value(
        value: state,
        child: PhotoViewport(zoom: zoom ?? ZoomController()),
      ),
    ));
    await tester.pump();
    return state;
  }
  Offset photoCentre(WidgetTester t) => t.getCenter(find.byType(PhotoViewport));

  testWidgets('TC-1510 a clean left click goes to the next photo', (tester) async {
    final state = await pumpNavViewport(tester);
    await mouseClick(tester, photoCentre(tester));
    expect(state.selectedItemID, 'IMG_0003');
    await tester.pump(const Duration(seconds: 6)); // flush nav timers (EXIF debounce, 5 s)
  },
  );

  testWidgets('TC-1511 a clean right click goes to the previous photo', (tester) async {
    final state = await pumpNavViewport(tester);
    await mouseClick(tester, photoCentre(tester), buttons: kSecondaryButton);
    expect(state.selectedItemID, 'IMG_0001');
    await tester.pump(const Duration(seconds: 6)); // flush nav timers (EXIF debounce, 5 s)
  },
  );

  testWidgets('TC-1512 a 10 px drag does not navigate', (tester) async {
    final state = await pumpNavViewport(tester);
    await mouseClick(tester, photoCentre(tester), travel: const Offset(10, 0));
    expect(state.selectedItemID, 'IMG_0002');
    await mouseClick(tester, photoCentre(tester));
    expect(state.selectedItemID, 'IMG_0003', reason: 'control');
    await tester.pump(const Duration(seconds: 6)); // flush nav timers (EXIF debounce, 5 s)
  },
  );

  testWidgets('TC-1513 a 10 px drag at 3x zoom pans and does not navigate',
      (tester) async {
    final zoom = ZoomController();
    final state = await pumpNavViewport(tester, zoom: zoom);
    zoom.transformCtrl.value = Matrix4.diagonal3Values(3, 3, 1);
    await tester.pump();
    final before = zoom.transformCtrl.value.getTranslation();
    await mouseClick(tester, photoCentre(tester),
        travel: const Offset(10, 0), hold: const Duration(milliseconds: 100));
    expect(zoom.transformCtrl.value.getTranslation() == before, isFalse,
        reason: 'precondition: the drag reached InteractiveViewer and panned');
    expect(state.selectedItemID, 'IMG_0002');
    await mouseClick(tester, photoCentre(tester));
    expect(state.selectedItemID, 'IMG_0003', reason: 'control: clicks work at 3x');
    await tester.pump(const Duration(seconds: 6)); // flush nav timers (EXIF debounce, 5 s)
  },
  );

  testWidgets('TC-1514 a long press does not navigate', (tester) async {
    final state = await pumpNavViewport(tester);
    await mouseClick(tester, photoCentre(tester),
        hold: const Duration(milliseconds: 600));
    expect(state.selectedItemID, 'IMG_0002');
    await mouseClick(tester, photoCentre(tester));
    expect(state.selectedItemID, 'IMG_0003', reason: 'control');
    await tester.pump(const Duration(seconds: 6)); // flush nav timers (EXIF debounce, 5 s)
  },
  );

  testWidgets('TC-1515 with the feature off a click does nothing', (tester) async {
    final state = await pumpNavViewport(tester, enabled: false);
    await mouseClick(tester, photoCentre(tester));
    expect(state.selectedItemID, 'IMG_0002');
    state.setMouseNavEnabled(true);
    await tester.pump();
    await mouseClick(tester, photoCentre(tester));
    expect(state.selectedItemID, 'IMG_0003', reason: 'control: on = navigates');
    await tester.pump(const Duration(seconds: 6)); // flush nav timers (EXIF debounce, 5 s)
  },
  );

  testWidgets('TC-1517 a click on an unreadable photo still navigates',
      (tester) async {
    final state = await pumpNavViewport(tester,
        waitForFullSize: false,
        imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
            const NativeImageFailure('MOCK_FAILURE', 'simulated'));
    await tester.runAsync(() => until(() => state.currentItemFailed,
        reason: 'the selected photo to fail'));
    await tester.pump();
    expect(find.textContaining('無法讀取'), findsOneWidget, reason: 'precondition');
    await mouseClick(tester, photoCentre(tester));
    expect(state.selectedItemID, 'IMG_0003');
    await tester.pump(const Duration(seconds: 6)); // flush nav timers (EXIF debounce, 5 s)
  },
  );

  testWidgets('TC-1518 a click on the loading spinner still navigates',
      (tester) async {
    final never = Completer<NativeImageResult>(); // no thumbnail, no full size
    final state = await pumpNavViewport(tester,
        waitForFullSize: false,
        imageLoader: (path, {required purpose, int? targetLongEdge}) =>
            never.future);
    expect(find.byType(CircularProgressIndicator), findsOneWidget,
        reason: 'precondition: interim spinner (photo_viewport.dart:252-254)');
    await mouseClick(tester, photoCentre(tester));
    expect(state.selectedItemID, 'IMG_0003');
    await tester.pump(const Duration(seconds: 6)); // flush nav timers (EXIF debounce, 5 s)
  },
  );

  testWidgets('TC-1519 a double click is two clicks: two photos forward',
      (tester) async {
    final state = await pumpNavViewport(tester);
    await mouseClick(tester, photoCentre(tester));
    await tester.pump(const Duration(milliseconds: 100));
    await mouseClick(tester, photoCentre(tester));
    expect(state.selectedItemID, 'IMG_0004');
    await tester.pump(const Duration(seconds: 6)); // flush nav timers (EXIF debounce, 5 s)
  },
  );
}
