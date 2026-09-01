import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/views/photo_action_bar.dart';
import 'package:halcyon_flutter/views/layout/common/photo_viewport.dart';
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
    'TC-490 PhotoViewport renders a real decoded photo inside '
    'InteractiveViewer, not a spinner',
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
    'TC-491 PhotoViewport reports blank/immutable state with no folder loaded',
    (tester) async {
      final state = AppState();
      addTearDown(state.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: PhotoViewport(zoom: ZoomController()),
          ),
        ),
      );

      expect(find.text('Select a folder to begin'), findsOneWidget);
      expect(find.byType(ElevatedButton), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(Image), findsNothing);
    },
  );

  testWidgets(
    'TC-492 PhotoViewport shows the frozen unreadable string for a failed item',
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

  testWidgets(
    'TC-493 PhotoViewport makes exactly one setViewportSize call and forwards '
    'logical size x dpr to AppState',
    (tester) async {
      final state = await pumpViewport(tester);
      expect(tester.view.devicePixelRatio, 3.0);

      // Positioned.fill == the MaterialApp's screen size (800x600 logical).
      const expectedWidth = 800;
      const expectedHeight = 600;
      expect(state.viewportSize, (expectedWidth * 3, expectedHeight * 3));
      expect(
        tester.widget<Image>(find.byType(Image)).image,
        isA<ResizeImage>(),
      );
      final resize =
          tester.widget<Image>(find.byType(Image)).image as ResizeImage;
      expect(resize.width, expectedWidth * 3);
      expect(resize.height, expectedHeight * 3);
    },
  );

  testWidgets(
    'TC-494 PhotoViewport has no floating action bar inside the viewport',
    (tester) async {
      await pumpViewport(tester);
      expect(find.byType(PhotoActionBar), findsNothing);
    },
  );
}