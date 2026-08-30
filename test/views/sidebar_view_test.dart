import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/temp_dirs.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/views/rename_dialog/rename_dialog.dart';
import 'package:halcyon_flutter/views/sidebar_view.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';


// A minimal valid 1x1 transparent PNG (same fixture as
// image_preload_controller_test.dart) — the sidebar renders thumbnail bytes
// through Image.memory, and this test's later assertion needs a real
// engine decode of the reloaded folder's items to actually resolve, unlike
// other widget tests here that never let a thumbnail decode complete.
final _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAA'
  'AAYAAjCB0C8AAAAASUVORK5CYII=',
);

/// Polls [condition] to a deadline instead of a fixed wall-clock sleep —
/// same remedy family as aacd973 (image_preload_window_test.dart's `_until`).
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

  // ponytail: sidebar_view.dart's pre-existing selected-row Container wraps
  // ListTile in a ColoredBox, which trips a Flutter-framework debug
  // assertion ("ListTile background color or ink splashes may be
  // invisible") — purely cosmetic, unrelated to recycle mode, and fires on
  // every frame a selected row paints. flutter_test fails a test that has
  // an un-acknowledged framework exception, so drain it via
  // tester.takeException() after each pump that could have triggered it.
  // One warning per painted row, so drain until empty rather than once.
  void drainListTileWarning(WidgetTester tester) {
    for (var exception = tester.takeException(); exception != null; ) {
      if (!exception.toString().contains(
        'ListTile background color or ink splashes may be invisible',
      )) {
        throw exception;
      }
      exception = tester.takeException();
    }
  }

  // ponytail: testWidgets bodies run inside a FakeAsync zone, so real
  // dart:io work (temp dir + file writes + AppState.loadFolder's real
  // Directory scan) never completes unless it runs via tester.runAsync —
  // otherwise the test hangs until the suite timeout. Matches the pattern
  // established in test/photo_action_bar_test.dart.
  Future<AppState> stateForFolder(
    WidgetTester tester, {
    required bool withSibling,
  }) async {
    late AppState state;
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('halcyon_sidebar_');
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

  Future<void> pumpSidebar(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(
          home: Scaffold(body: SizedBox(width: 320, child: SidebarView())),
        ),
      ),
    );
    await tester.pump();
    drainListTileWarning(tester);
  }

  testWidgets('trashed status icon follows the mode', (tester) async {
    final state = await stateForFolder(tester, withSibling: true);
    state.markCurrent(PhotoStatus.trashed);
    await pumpSidebar(tester, state);

    expect(find.byIcon(Icons.restore_from_trash), findsOneWidget);

    state.toggleRecycleMode();
    await tester.pump();
    drainListTileWarning(tester);

    expect(find.byIcon(Icons.delete), findsOneWidget);
    expect(find.byIcon(Icons.restore_from_trash), findsNothing);
  });

  testWidgets(
    'invoking onSelected with the shared constant reaches the export path',
    (tester) async {
      // getDirectoryPath (file_selector) goes through
      // 'plugins.flutter.io/file_selector' — mock it to return a real temp
      // dir so the whole onSelected -> exportStarredThumbnails routing runs
      // for real and is observable via the status line.
      late Directory exportDest;
      const channel = MethodChannel('plugins.flutter.io/file_selector');
      // M6 P3.6: AppState's default PhotoExportService now fetches bytes
      // via the pure-Dart exportBytesFor pipeline (decode -> resize ->
      // encode), not the 'halcyon/thumbnail' channel. Mock the channel to
      // THROW so a regression back onto it fails this test loudly instead of
      // silently passing.
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
      // stateForFolder writes a 3-byte placeholder for IMG_0001.jpg, which
      // is not a decodable image. exportBytesFor reads bytes fresh at export
      // time (not the cached sidebar thumbnail), so overwrite it here with a
      // real decodable image — this is the only file touch this test case
      // owns; the shared helper is untouched.
      await tester.runAsync(() async {
        await File(
          p.join(state.currentDir!.path, 'IMG_0001.jpg'),
        ).writeAsBytes(_tinyPngBytes);
      });
      state.markCurrent(PhotoStatus.starred);
      await pumpSidebar(tester, state);

      await tester.runAsync(() async {
        exportDest = await Directory.systemTemp.createTemp(
          'halcyon_sidebar_export_',
        );
      });
      addTempDirTeardown(exportDest);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getDirectoryPath') return exportDest.path;
            return null;
          });

      // ponytail: tapping the menu item hangs under FakeAsync in this
      // codebase (see the recycle test above) — invoke the real, already
      // wired-up onSelected callback directly instead.
      final button = tester.widget<PopupMenuButton<String>>(
        find.byType(PopupMenuButton<String>),
      );

      final outFile = File(p.join(exportDest.path, 'IMG_0001.jpg'));
      await tester.runAsync(() async {
        button.onSelected!(kThumbnailStarredMenuValue);
        // A fixed wall-clock sleep here is a load-dependent race (same
        // remedy family as aacd973): poll the actual completion signal.
        // exportStarredThumbnails writes the output file BEFORE setting the
        // "已匯出" status message (app_state.dart's exportStarredThumbnails),
        // so the poll condition must be the status text, not file existence
        // -- polling the file alone can observe it written while the status
        // assertion below still reads the pre-export null/progress value.
        await _until(
          () => state.status?.text.contains('已匯出') ?? false,
          reason: 'the export to finish and set the "已匯出" status message',
        );
      });
      await tester.pump();
      drainListTileWarning(tester);

      expect(state.status?.text, contains('已匯出'));
      expect(state.status?.revealPath, exportDest.path);
      expect(outFile.existsSync(), isTrue);
    },
  );

  testWidgets('TC-055 onSelected with the shared constant opens the dialog', (
    tester,
  ) async {
    final state = await stateForFolder(tester, withSibling: false);
    await pumpSidebar(tester, state);

    // ponytail: tapping the menu item hangs under FakeAsync in this codebase
    // (see the export test above) — invoke the real onSelected directly. Using
    // kRenameMenuValue on both sides is the point: a literal here would still
    // pass while the menu entry was silently dead.
    final button = tester.widget<PopupMenuButton<String>>(
      find.byType(PopupMenuButton<String>),
    );
    button.onSelected!(kRenameMenuValue);
    await tester.pump();
    drainListTileWarning(tester);

    expect(find.byType(RenameDialog), findsOneWidget);
  });

  // M6 P2.4 (F-10 half 1): proof that the sidebar sweep's byte source is the
  // pure-Dart producer under PRODUCTION defaults (composition root landed in
  // P2.3 — image_preload_controller.dart:1182 already calls the injected
  // seam; this test does not add wiring, only coverage). Every prior test in
  // this file bypasses both the channel and dartImageLoad by injecting a
  // fixed-bytes fake imageLoader, so none of them exercise this path.
  // Real DNG samples per repo red line (pattern of test/dng_embedded_jpeg_extractor_test.dart).
  //
  // Drives AppState.preloadThumbnails directly rather than through
  // SidebarView/pumpSidebar: the widget's own itemBuilder-driven trigger
  // (sidebar_view.dart:96) fires inside flutter_test's ambient FakeAsync
  // zone, arming a FakeTimer for the controller's 100ms debounce that a
  // subsequent tester.runAsync() call cannot advance (and an unmatched range
  // check would make a same-range explicit call a silent no-op on top of
  // that) — the byte-source route this task proves does not require
  // rendering the widget at all.
  // RETIRED (2026-08-30, plan Task 6 / amendment E-C2): 'sidebar sweep routes
  // sidebarThumbnail requests through the Dart producer'. It asserted that the
  // controller calls the loader with `ImageRequestPurpose.sidebarThumbnail`.
  // The controller no longer calls the loader for tiles at all -- it derives
  // them from the shared payload. `ImageRequestPurpose.sidebarThumbnail`
  // itself is NOT deleted and its semantics stay pinned by
  // test/services/image_pipeline/dart_image_loader_test.dart.

  // M6 P2.5b (matrix P-12): the sidebar RAW-decode fallback for bare-CFA
  // DNGs with no embedded JPEG at any size. Drives ImagePreloadController
  // directly (via AppState's preloadController override) with a loader
  // forced to NativeImageFailure, so the fallback branch is the only
  // possible source of bytes -- exactly isolates the branch under test from
  // P2.1's byte-source path. Same direct-AppState-call pattern as the test
  // above (no SidebarView pump), for the same FakeAsync-Timer reason.
  Future<NativeImageResult> alwaysFailLoader(
    String path, {
    required ImageRequestPurpose purpose,
  }) async => const NativeImageFailure('FORCED_FAIL_FOR_TEST', 'forced');

  Future<Directory> tempDirWith(WidgetTester tester, String fileName) async {
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('halcyon_sidebar_p25b_');
      await File(p.join(dir.path, fileName)).writeAsBytes([1, 2, 3]);
    });
    addTempDirTeardown(dir);
    return dir;
  }

  // RETIRED (2026-08-30, plan Task 6 / amendment E-C1): the three
  // 'sidebar RAW-decode fallback: ...' tests (maxDim 200 requested / a
  // throwing decoder is a permanent miss / a non-RAW item never reaches the
  // decoder). All three pinned the sidebar's OWN sized decoder, which is
  // deleted -- measured NOT FASTER than the full decode it duplicated
  // (ratio 0.916, payload-bench-report.md §4). Replacements:
  // sidebar_shared_payload_test.dart TC-430..433 and
  // sidebar_lane_production_test.dart TC-434..437.

  Future<void> pumpSidebarWithEncodedThumbnail(WidgetTester tester) async {
    final dir = await tempDirWith(tester, 'd.jpg');
    final state = AppState(
      imageLoader: (path, {required purpose}) async {
        return NativeImageBytes(Uint8List.fromList(_tinyPngBytes));
      },
    );
    await tester.runAsync(() async {
      await state.loadFolder(dir);
      await state.preloadThumbnails(0, state.items.length - 1);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await pumpSidebar(tester, state);
  }

  Future<void> pumpSidebarWithAllDecodersThrowing(WidgetTester tester) async {
    final dir = await tempDirWith(tester, 'f.dng');
    final controller = ImagePreloadController(
      imageLoader: alwaysFailLoader,
      dngDecoder: (path) async {
        throw StateError('simulated decode failure');
      },
      payloadEncoder: null,
    );
    final state = AppState(preloadController: controller);
    await tester.runAsync(() async {
      await state.loadFolder(dir);
      await state.preloadThumbnails(0, state.items.length - 1);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await pumpSidebar(tester, state);
  }

  testWidgets(
    'TC-376 the JPG / embedded-preview arm still renders through '
    'ResizeImage + MemoryImage (scope-limit regression guard)',
    (tester) async {
      await pumpSidebarWithEncodedThumbnail(tester);
      final image = tester.widget<Image>(find.byType(Image).first);
      expect(image.image, isA<ResizeImage>());
      expect((image.image as ResizeImage).imageProvider, isA<MemoryImage>());
    },
  );

  testWidgets(
    'TC-377 (narrowed) a fully failed item renders exactly the existing grey '
    'box and nothing new',
    (tester) async {
      // The original TC-377 also asserted that a preview-less RAW renders a
      // RawPixelsImage tile. RETIRED 2026-08-30 (plan Task 6): the sidebar
      // derives tiles from the shared payload now, so a tile's provider family
      // follows the payload's kind rather than a sidebar-only decode. The
      // failure half below is premise-independent and stays.
      await pumpSidebarWithAllDecodersThrowing(tester);
      expect(find.byType(Image), findsNothing);
      expect(find.byType(Container), findsWidgets); // today's grey box
    },
  );

  testWidgets('TC-226 the overflow menu exposes exactly the five actions',
      (tester) async {
    expect(
      {
        kCopyMenuValue,
        kMoveMenuValue,
        kThumbnailStarredMenuValue,
        kDeleteMenuValue,
        kSettingsMenuValue,
      },
      {'copy', 'move', 'thumbnailStarred', 'delete', 'settings'},
    );
  });
}
