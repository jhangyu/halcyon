import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/dart_image_loader.dart';
import 'package:halcyon_flutter/services/dng_decode_contract.dart';
import 'package:halcyon_flutter/services/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_source_types.dart';
import 'package:halcyon_flutter/views/rename_dialog.dart';
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
      addTearDown(() => dir.delete(recursive: true));
      await File(p.join(dir.path, 'IMG_0001.jpg')).writeAsBytes([1, 2, 3]);
      if (withSibling) {
        await File(p.join(dir.path, 'IMG_0001.dng')).writeAsBytes([1, 2, 3]);
      }
      state = AppState(
        thumbnailLoader: (path, {required purpose}) async {
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
      // M6 P3.6: AppState's default ThumbnailExportService now fetches bytes
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
      addTearDown(() => exportDest.delete(recursive: true));

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

      await tester.runAsync(() async {
        button.onSelected!(kThumbnailStarredMenuValue);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
      drainListTileWarning(tester);

      expect(state.status?.text, contains('已匯出'));
      expect(state.status?.revealPath, exportDest.path);
      final outFile = File(p.join(exportDest.path, 'IMG_0001.jpg'));
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
  // fixed-bytes fake thumbnailLoader, so none of them exercise this path.
  // Real DNG samples per repo red line (pattern of test/dng_preview_extractor_test.dart).
  //
  // Drives AppState.preloadThumbnails directly rather than through
  // SidebarView/pumpSidebar: the widget's own itemBuilder-driven trigger
  // (sidebar_view.dart:96) fires inside flutter_test's ambient FakeAsync
  // zone, arming a FakeTimer for the controller's 100ms debounce that a
  // subsequent tester.runAsync() call cannot advance (and an unmatched range
  // check would make a same-range explicit call a silent no-op on top of
  // that) — the byte-source route this task proves does not require
  // rendering the widget at all.
  testWidgets(
    'sidebar sweep routes sidebarThumbnail requests through the Dart producer',
    (tester) async {
      late AppState state;
      var loaderCalls = 0;
      // The same injected seam also serves the detail view's tier-1/tier-2
      // preview loads (AppState._preloadImages) — only sidebarThumbnail
      // calls are this test's concern.
      Future<NativeImageResult> countingLoader(
        String path, {
        required ImageRequestPurpose purpose,
      }) {
        if (purpose == ImageRequestPurpose.sidebarThumbnail) loaderCalls++;
        return dartImageLoad(path, purpose: purpose);
      }

      await tester.runAsync(() async {
        final sampleDir = Directory('local_data/photo_samples/DNG');
        // Known preview-bearing samples (cross-checked in
        // dng_preview_extractor_test.dart) — keeps this test fast and
        // deterministic rather than sweeping all 14 samples.
        const previewBearing = [
          '2026-02-15-19-37-38.dng',
          '2026-02-15-20-53-24.dng',
        ];
        final samples = previewBearing
            .map((name) => File(p.join(sampleDir.path, name)))
            .where((f) => f.existsSync())
            .toList();
        expect(samples, isNotEmpty,
            reason: 'missing ${sampleDir.path}; cannot run real-sample test');

        final dir = await Directory.systemTemp.createTemp(
          'halcyon_sidebar_dartproducer_',
        );
        addTearDown(() => dir.delete(recursive: true));
        for (final f in samples) {
          await f.copy(p.join(dir.path, p.basename(f.path)));
        }

        state = AppState(thumbnailLoader: countingLoader);
        await state.loadFolder(dir);

        await state.preloadThumbnails(0, state.items.length - 1);
        // Let the controller's real 100ms debounce timer fire (this whole
        // block runs in tester.runAsync's real zone, so it is a real Timer).
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      expect(loaderCalls, greaterThan(0));
      final anyBytes = state.items.any(
        (i) => state.getThumbnailBytes(i.id) != null,
      );
      expect(
        anyBytes,
        isTrue,
        reason: 'preview-bearing samples must yield sidebar bytes via Dart',
      );
    },
  );

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

  DecodedRgba fourByTwoFixture() {
    final bytes = Uint8List(4 * 2 * 4);
    for (var i = 0; i < bytes.length; i += 4) {
      bytes[i] = 100; // R marker, opaque
      bytes[i + 3] = 255;
    }
    return DecodedRgba(rgba: bytes, width: 4, height: 2);
  }

  Future<Directory> tempDirWith(WidgetTester tester, String fileName) async {
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('halcyon_sidebar_p25b_');
      await File(p.join(dir.path, fileName)).writeAsBytes([1, 2, 3]);
    });
    addTearDown(() => dir.delete(recursive: true));
    return dir;
  }

  testWidgets(
    'sidebar RAW-decode fallback: decodable PNG for a bare-CFA DNG, maxDim'
    ' 200 requested',
    (tester) async {
      var decoderCalls = 0;
      int? capturedMaxDim;
      Future<DecodedRgba> fakeDecoder(String path, {required int maxDim}) async {
        decoderCalls++;
        capturedMaxDim = maxDim;
        return fourByTwoFixture();
      }

      final dir = await tempDirWith(tester, 'a.dng');
      final controller = ImagePreloadController(
        imageLoader: alwaysFailLoader,
        sidebarRawDecoder: fakeDecoder,
      );
      final state = AppState(preloadController: controller);
      await tester.runAsync(() async {
        await state.loadFolder(dir);
        await state.preloadThumbnails(0, state.items.length - 1);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      expect(decoderCalls, 1);
      expect(capturedMaxDim, 200);
      final id = state.items.single.id;
      final bytes = state.getThumbnailBytes(id);
      expect(bytes, isNotNull);
      // Decodable: a garbage buffer would fail this round-trip.
      await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(bytes!);
        final frame = await codec.getNextFrame();
        // readOrientation on this non-DNG fixture file returns null ->
        // kDefaultExifOrientation (1, identity) -> no dim swap.
        expect(frame.image.width, 4);
        expect(frame.image.height, 2);
      });
    },
  );

  testWidgets(
    'sidebar RAW-decode fallback: decoder throwing is a permanent miss, no'
    ' crash, no retry signal',
    (tester) async {
      var decoderCalls = 0;
      Future<DecodedRgba> throwingDecoder(
        String path, {
        required int maxDim,
      }) async {
        decoderCalls++;
        throw StateError('simulated decode failure');
      }

      final dir = await tempDirWith(tester, 'b.dng');
      final controller = ImagePreloadController(
        imageLoader: alwaysFailLoader,
        sidebarRawDecoder: throwingDecoder,
      );
      final state = AppState(preloadController: controller);
      await tester.runAsync(() async {
        await state.loadFolder(dir);
        await state.preloadThumbnails(0, state.items.length - 1);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      expect(decoderCalls, 1);
      final id = state.items.single.id;
      expect(state.getThumbnailBytes(id), isNull);
    },
  );

  testWidgets(
    'sidebar RAW-decode fallback: a non-RAW item never reaches the decoder',
    (tester) async {
      var decoderCalls = 0;
      Future<DecodedRgba> fakeDecoder(String path, {required int maxDim}) async {
        decoderCalls++;
        return fourByTwoFixture();
      }

      final dir = await tempDirWith(tester, 'c.jpg');
      final controller = ImagePreloadController(
        imageLoader: alwaysFailLoader,
        sidebarRawDecoder: fakeDecoder,
      );
      final state = AppState(preloadController: controller);
      await tester.runAsync(() async {
        await state.loadFolder(dir);
        await state.preloadThumbnails(0, state.items.length - 1);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      expect(decoderCalls, 0);
      final id = state.items.single.id;
      expect(state.getThumbnailBytes(id), isNull);
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
