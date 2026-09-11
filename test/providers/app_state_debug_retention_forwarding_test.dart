import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/preload_fixtures.dart';
import '../support/temp_dirs.dart';

/// TC-1241 -- gpu-texture campaign AC-1: proves
/// `AppState.debugRetentionIds`/`debugPayloadFor` really FORWARD to the live
/// `ImagePreloadController` this `AppState` built, rather than being stubs
/// that happen to compile. A forwarding getter that silently returned an
/// empty set / null forever would pass a test that only checks the idle
/// state; this test drives a real selection through the real pipeline and
/// checks both accessors track it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'TC-1241 debugRetentionIds/debugPayloadFor report what the underlying '
    'ImagePreloadController actually retains',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'halcyon_debug_retention_',
      );
      addTempDirTeardown(dir);
      await File('${dir.path}/IMG_0001.jpg').writeAsBytes([0]);

      final state = AppState(
        imageLoader: (path, {required purpose, int? targetLongEdge}) async {
          return NativeImageBytes(Uint8List.fromList(tinyPngBytes));
        },
      );
      addTearDown(state.dispose);

      // Idle, before any folder is loaded: the real controller retains
      // nothing, and an unknown id has no payload -- the baseline a stub
      // returning constants could also satisfy, but establishes the
      // accessors are live (not throwing / not hardcoded to something else).
      expect(state.debugRetentionIds, isEmpty);
      expect(state.debugPayloadFor('nonexistent'), isNull);

      await state.loadFolder(dir);
      expect(state.selectedItemID, 'IMG_0001');

      // Wait for the selected item's payload to actually land -- this is the
      // real pipeline (preload controller, payload cache), not a fake.
      await until(
        () => state.debugPayloadFor('IMG_0001') != null,
        reason: 'the selected item to land in the retention cache',
      );

      // Forwarding is provably live: the id the pipeline just retained shows
      // up in the retention-id set the same accessor reports.
      expect(state.debugRetentionIds, contains('IMG_0001'));
      expect(state.debugPayloadFor('IMG_0001'), isNotNull);
    },
  );
}
