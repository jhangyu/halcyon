import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/temp_dirs.dart';
import 'package:provider/provider.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/views/main_detail_view.dart';
import 'package:halcyon_flutter/views/zoom_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('TC-230 the detail view spins with no bytes and no provider', (
    tester,
  ) async {
    // testWidgets bodies run inside flutter_test's FakeAsync zone, where a
    // real dart:io future (temp dir creation, file writes, loadFolder's
    // directory scan) never completes -- the body blocks forever with no
    // pump to flush the fake zone, which is the FakeAsync + real future
    // deadlock in the repo's 2026-08-17 lessons-learned entry. Every piece
    // of real I/O therefore runs inside tester.runAsync, matching
    // test/photo_action_bar_test.dart and test/sidebar_view_test.dart.
    late AppState state;
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('halcyon_mdv_');
      addTempDirTeardown(dir);
      await File('${dir.path}/IMG_0001.jpg').writeAsBytes(<int>[1, 2, 3]);

      // A loader that never completes pins the item in the "loading" state
      // for the whole test, so the null/null case under test cannot be
      // raced away by a real decode landing mid-run.
      state = AppState(
        imageLoader: (path, {required purpose}) =>
            Completer<NativeImageResult>().future,
      );
      addTearDown(state.dispose);
      await state.loadFolder(dir);
    });

    // The thumbnail fetch kicked off by selectItem is fire-and-forget and
    // never delivers here, so currentImageBytes and displayProvider are both
    // null -- exactly the state _buildZoomableViewer's spinner branch covers.
    expect(state.displayProvider, isNull);
    expect(state.currentImageBytes, isNull);

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MainDetailView(zoom: ZoomController()),
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
