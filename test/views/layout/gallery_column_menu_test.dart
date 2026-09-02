// T11: catch-all new home for `test/views/sidebar_view_test.dart` (baton
// mapping) assertions that are not individually named in round1-plan.md's
// T11 table. The table-named assertions live in their own new homes:
// TC-511 (+ the strip dot test) in gallery_column_test.dart, TC-055 and the
// updated TC-226 in app_actions_menu_test.dart, TC-230 in photo_viewport_test.dart,
// decode-cap equality in photo_thumbnail_test.dart (TC-494).
//
// This file carries the three remaining sidebar_view_test.dart assertions:
// the export-path integration test, and TC-376/TC-377 — both of which are
// re-expressed against PhotoThumbnail directly (the extracted widget that
// replaced the old sidebar's inline thumbnail rendering), since TC-494/495
// already pin the decode-cap/provider-family properties those two used to
// guard and this file's job is to keep their remaining, non-duplicate
// coverage (the ResizeImage+MemoryImage provider-FAMILY check for an
// encoded payload, and the null-payload placeholder-box render) alive under
// a name that still says what regression it catches.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/image_pipeline/photo_payload.dart';
import 'package:halcyon_flutter/views/layout/common/app_actions_menu.dart';
import 'package:halcyon_flutter/views/layout/common/photo_thumbnail.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/temp_dirs.dart';

final _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAA'
  'AAYAAjCB0C8AAAAASUVORK5CYII=',
);

/// Polls [condition] to a deadline instead of a fixed wall-clock sleep —
/// same remedy as `sidebar_view_test.dart`'s `_until`.
Future<void> _until(bool Function() condition, {String? reason}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for: ${reason ?? 'condition'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<AppState> stateForFolder(
    WidgetTester tester, {
    required bool withSibling,
  }) async {
    late AppState state;
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp(
        'halcyon_gallery_menu_',
      );
      addTempDirTeardown(dir);
      await File(p.join(dir.path, 'IMG_0001.jpg')).writeAsBytes([1, 2, 3]);
      if (withSibling) {
        await File(p.join(dir.path, 'IMG_0001.dng')).writeAsBytes([1, 2, 3]);
      }
      state = AppState(
        imageLoader: (path, {required purpose}) async {
          return NativeImageBytes(Uint8List.fromList(_tinyPngBytes));
        },
      );
      await state.loadFolder(dir);
    });
    return state;
  }

  Future<void> pumpMenu(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(
          home: Scaffold(body: AppActionsMenu(iconColor: Colors.black)),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'invoking onSelected with the shared thumbnail-starred constant reaches '
    'the export path (ported from sidebar_view_test.dart)',
    (tester) async {
      late Directory exportDest;
      const channel = MethodChannel('plugins.flutter.io/file_selector');
      // M6 P3.6: the default PhotoExportService fetches bytes via the pure
      // -Dart exportBytesFor pipeline, not the 'halcyon/thumbnail' channel.
      // Mock the channel to THROW so a regression back onto it fails loudly.
      const thumbnailChannel = MethodChannel('halcyon/thumbnail');
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(thumbnailChannel, null);
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(thumbnailChannel, (call) async {
        throw MissingPluginException(
          'export must not reach halcyon/thumbnail (M6 P3.6)',
        );
      });

      final state = await stateForFolder(tester, withSibling: false);
      await tester.runAsync(() async {
        await File(
          p.join(state.currentDir!.path, 'IMG_0001.jpg'),
        ).writeAsBytes(_tinyPngBytes);
      });
      state.markCurrent(PhotoStatus.starred);
      await pumpMenu(tester, state);

      await tester.runAsync(() async {
        exportDest = await Directory.systemTemp.createTemp(
          'halcyon_gallery_menu_export_',
        );
      });
      addTempDirTeardown(exportDest);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getDirectoryPath') return exportDest.path;
        return null;
      });

      final button = tester.widget<PopupMenuButton<String>>(
        find.byType(PopupMenuButton<String>),
      );

      final outFile = File(p.join(exportDest.path, 'IMG_0001.jpg'));
      await tester.runAsync(() async {
        button.onSelected!(kThumbnailStarredMenuValue);
        await _until(
          () => state.status?.text.contains('已匯出') ?? false,
          reason: 'the export to finish and set the "已匯出" status message',
        );
      });
      await tester.pump();

      expect(state.status?.text, contains('已匯出'));
      expect(state.status?.revealPath, exportDest.path);
      expect(outFile.existsSync(), isTrue);
    },
  );

  testWidgets(
    'TC-376 (re-expressed) an encoded payload still renders through '
    'ResizeImage + MemoryImage (scope-limit regression guard)',
    (tester) async {
      // TC-494 (photo_thumbnail_test.dart) already pins the decode-cap
      // EQUALITY for this same path; this test keeps the narrower
      // provider-FAMILY guard the original TC-376 existed for, so a future
      // change that swaps the provider family entirely (not just the cap
      // math) still fails here even if TC-494's numeric equality happens to
      // still hold by coincidence.
      await tester.pumpWidget(
        MaterialApp(
          home: PhotoThumbnail(
            payload: EncodedPayload(Uint8List.fromList(_tinyPngBytes)),
            width: 74,
            height: 49,
          ),
        ),
      );
      await tester.pump();

      final image = tester.widget<Image>(find.byType(Image).first);
      expect(image.image, isA<ResizeImage>());
      expect((image.image as ResizeImage).imageProvider, isA<MemoryImage>());
    },
  );

  testWidgets(
    'TC-377 (re-expressed) a null payload renders exactly the existing grey '
    'placeholder box and no Image widget',
    (tester) async {
      // The original TC-377 also asserted a RawPixelsImage tile for a
      // preview-less RAW; RETIRED 2026-08-30 (plan Task 6, noted already at
      // main_detail_view_test.dart deletion time): thumbnails derive from the
      // shared payload now, so a tile's provider family follows the
      // payload's kind rather than a sidebar-only decode. The failure half
      // (null payload -> grey box, nothing else) is premise-independent and
      // stays, now against PhotoThumbnail directly.
      await tester.pumpWidget(
        const MaterialApp(
          home: PhotoThumbnail(payload: null, width: 74, height: 49),
        ),
      );
      await tester.pump();

      expect(find.byType(Image), findsNothing);
      expect(find.byType(Container), findsWidgets); // today's grey box
    },
  );
}
