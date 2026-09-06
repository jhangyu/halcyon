import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/preload_fixtures.dart';
import '../support/temp_dirs.dart';

/// TC-1058 — the selection-EXIF read must not notify a disposed AppState.
///
/// `selectItem` arms a [kSelectionExifDebounce] timer; when it fires,
/// `_readSelectionExif` awaits the EXIF reader and then calls
/// `notifyListeners()`. `dispose()` cancels that timer, but cancelling does
/// nothing once the timer has ALREADY fired and the method is suspended on the
/// reader await -- and `dispose()` does not bump `_exifGeneration` either, so
/// the generation guard does not cover this case. The landing therefore
/// notified a disposed ChangeNotifier, which throws
/// "A AppState was used after being disposed".
///
/// That is what made TC-542 (gallery_open_folder_shortcut_test.dart) flaky
/// under full-suite load: 2 throws in one full-suite run, 0 in the next, on an
/// identical tree (docs/logs/2026-09-06/tc1014-rootcause.txt section 9).
///
/// This test makes that race deterministic by holding the reader open until
/// after `dispose()`. Without the `_disposed` guard the throw arrives as an
/// uncaught async error and fails this test; with it, the read lands silently.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('TC-1058: a selection EXIF read landing after dispose does not notify',
      () async {
    final dir = await Directory.systemTemp.createTemp('halcyon_exif_dispose_');
    addTempDirTeardown(dir);
    await File('${dir.path}/IMG_0001.jpg').writeAsBytes([0]);

    // Held open so the read is guaranteed to still be in flight at dispose().
    final readGate = Completer<void>();
    var readEntered = false;

    final state = AppState(
      imageLoader: (path, {required purpose, int? targetLongEdge}) async =>
          NativeImageBytes(Uint8List.fromList(tinyPngBytes)),
      exifReader: (paths, {onProgress}) async {
        readEntered = true;
        await readGate.future;
        return const [null];
      },
    );

    await state.loadFolder(dir);
    expect(state.selectedItemID, 'IMG_0001');

    // The debounce timer fires 250ms after the selection loadFolder made.
    await until(
      () => readEntered,
      reason: 'the selection EXIF read to start',
    );

    // Dispose with the read still suspended -- cancelling the (already fired)
    // debounce timer cannot stop the continuation below.
    state.dispose();
    readGate.complete();

    // Let the continuation run. Without the guard this is where
    // notifyListeners() throws on the disposed notifier.
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
}
