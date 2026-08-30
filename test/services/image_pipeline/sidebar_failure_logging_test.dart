import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

Future<NativeImageResult> _alwaysFailLoader(
  String path, {
  required ImageRequestPurpose purpose,
}) async =>
    const NativeImageFailure('NO_THUMBNAIL', 'no thumbnail for test');

/// Throws only for the sidebar-thumbnail purpose, so the unrelated preview
/// load AppState triggers on folder-load / selection is unaffected.
Future<NativeImageResult> _throwingLoader(
  String path, {
  required ImageRequestPurpose purpose,
}) async {
  if (purpose == ImageRequestPurpose.sidebarThumbnail) {
    throw StateError('simulated channel failure');
  }
  return const NativeImageFailure('NO_THUMBNAIL', 'no preview for test');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'TC-379 a swallowed sidebar decode failure now emits exactly one named '
    'log line per id per folder load',
    () async {
      final lines = <String>[];
      final previous = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) lines.add(message);
      };
      addTearDown(() => debugPrint = previous);

      final dir = await Directory.systemTemp.createTemp('halcyon_log_');
      await File(p.join(dir.path, 'a.dng')).writeAsBytes([1, 2, 3]);
      addTearDown(() => dir.delete(recursive: true));

      final controller = ImagePreloadController(
        imageLoader: _alwaysFailLoader,
        sidebarRawDecoder: (path, {required int maxDim}) async =>
            throw StateError('simulated decode failure'),
      );
      final state = AppState(preloadController: controller);
      await state.loadFolder(dir);
      await state.preloadThumbnails(0, 0);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final matcher = RegExp(
        r'^sidebar\.thumb\|id=.+\|stage=decode\|err=StateError\|msg=',
      );
      expect(lines.where(matcher.hasMatch).length, 1);

      // A second sweep must NOT re-log: the permanent-miss set short-circuits.
      await state.preloadThumbnails(0, 0);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(lines.where(matcher.hasMatch).length, 1);
    },
  );

  test(
    'TC-379b a loader that THROWS (not a NativeImageFailure) is logged with '
    "stage=loader, isolated from the encoded-leg's own catch",
    () async {
      final lines = <String>[];
      final previous = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) lines.add(message);
      };
      addTearDown(() => debugPrint = previous);

      final dir = await Directory.systemTemp.createTemp('halcyon_log_');
      await File(p.join(dir.path, 'a.jpg')).writeAsBytes([1, 2, 3]);
      addTearDown(() => dir.delete(recursive: true));

      final controller = ImagePreloadController(imageLoader: _throwingLoader);
      final state = AppState(preloadController: controller);
      await state.loadFolder(dir);
      await state.preloadThumbnails(0, 0);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final matcher = RegExp(
        r'^sidebar\.thumb\|id=.+\|stage=loader\|err=StateError\|msg=',
      );
      expect(lines.where(matcher.hasMatch).length, 1);
      // Never mislabelled as the generic sweep-level stage.
      expect(lines.any((l) => l.contains('|stage=sweep|')), isFalse);
    },
  );
}
