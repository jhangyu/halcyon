import 'dart:async';
import 'dart:io';

import 'package:ceyx/ceyx.dart' show CeyxEncodeService;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/temp_dirs.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/models/rename_rule.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_preload_controller.dart';
import 'package:halcyon_flutter/services/image_pipeline/image_source_types.dart';
import 'package:halcyon_flutter/services/library/photo_library_scanner.dart';
import 'package:halcyon_flutter/services/platform/working_set_trim.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// T13 — per-selection EXIF read + cache (round1-plan T13, TC-494..497).
///
/// All tests inject the FAKE reader through the EXISTING `exifReader`
/// constructor parameter — there is deliberately no second reader seam — and a
/// preload controller whose navigational work is a no-op, so the notify counts
/// below are the EXIF feature's own and not the preload pipeline's.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // `resolveExportCapabilities` (fired from `_initPrefs`) probes the native
    // encode library; in this test environment that spawns worker isolates.
    // Seeding the unavailability cache makes `supports` fail fast in a
    // microtask, so its one `notifyListeners` lands deterministically inside
    // the construction settle and never leaks into the counts below.
    CeyxEncodeService.debugMarkUnavailableForTesting(null);
    // `selectItem` arms a static working-set timer; keep it far out of the
    // debounce window so it cannot fire mid-test.
    WorkingSetTrim.debugReset();
    WorkingSetTrim.idleDelay = const Duration(minutes: 5);
  });

  tearDown(() {
    CeyxEncodeService.resetAvailabilityCacheForTesting();
    WorkingSetTrim.debugReset();
  });

  group('AppState selection EXIF cache', () {
    test('TC-494 selecting and going quiet past 250ms reads once and '
        'notifies listeners once on landing', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_exif494_');
      addTempDirTeardown(dir);
      await _touch(dir, 'P1.jpg');
      await _touch(dir, 'P2.jpg');

      final callPaths = <String>[];
      final gate = Completer<List<ExifMetadata?>>();
      final state = _state(
        dir: dir,
        ids: const ['P1', 'P2'],
        exifReader: (paths, {onProgress}) {
          callPaths.addAll(paths);
          return gate.future;
        },
      );
      addTearDown(state.dispose);

      // Settle `_initPrefs` (prefs hydration + capability notification) before
      // any counting.
      await pumpEventQueue();
      await state.loadFolder(dir); // auto-selects P1 and schedules its read
      expect(state.selectedItemID, 'P1');
      expect(state.currentExif, isNull, reason: 'nothing has landed yet');

      // Quiet for past the debounce: the reader is invoked for P1 and parks
      // on the gate.
      await Future<void>.delayed(
        kSelectionExifDebounce + const Duration(milliseconds: 20),
      );
      expect(callPaths, [p.join(dir.path, 'P1.jpg')]);
      expect(state.currentExif, isNull, reason: 'reader result still in flight');

      // Landing: one write, one notify.
      var notifies = 0;
      state.addListener(() => notifies++);
      gate.complete([ExifMetadata(captureDate: DateTime(2026, 1, 1))]);
      await pumpEventQueue();

      expect(state.currentExif, isNotNull);
      expect(state.currentExif!.captureDate, DateTime(2026, 1, 1));
      expect(notifies, 1, reason: 'exactly one notify once the read lands');
    });

    test('TC-495 stepping through five photos inside the window fires '
        'exactly one read, for the photo the user stopped on', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_exif495_');
      addTempDirTeardown(dir);
      for (final id in ['P1', 'P2', 'P3', 'P4', 'P5']) {
        await _touch(dir, '$id.jpg');
      }

      final callPaths = <String>[];
      final state = _state(
        dir: dir,
        ids: const ['P1', 'P2', 'P3', 'P4', 'P5'],
        exifReader: (paths, {onProgress}) async {
          callPaths.addAll(paths);
          return [ExifMetadata(captureDate: DateTime(2026, 1, 2))];
        },
      );
      addTearDown(state.dispose);

      await pumpEventQueue();
      await state.loadFolder(dir); // auto-selects P1, schedules P1 read

      // A navigation burst inside the debounce window: every schedule cancels
      // the previous timer, so none of P1..P4 is ever read.
      state.selectItem('P2');
      state.selectItem('P3');
      state.selectItem('P4');
      state.selectItem('P5');

      await Future<void>.delayed(
        kSelectionExifDebounce + const Duration(milliseconds: 20),
      );

      expect(callPaths, hasLength(1), reason: 'passed-through photos are not read');
      expect(callPaths, [p.join(dir.path, 'P5.jpg')]);
      expect(state.selectedItemID, 'P5');
      expect(state.currentExif, isNotNull);
    });

    test('TC-496 a reader result that arrives after the selection changed is '
        'discarded', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_exif496_');
      addTempDirTeardown(dir);
      await _touch(dir, 'P1.jpg');
      await _touch(dir, 'P2.jpg');

      // Gated reader: each path's first read parks until the test completes it.
      final gates = <String, Completer<List<ExifMetadata?>>>{};
      final callPaths = <String>[];
      final state = _state(
        dir: dir,
        ids: const ['P1', 'P2'],
        exifReader: (paths, {onProgress}) {
          callPaths.addAll(paths);
          return (gates[paths.single] ??= Completer()).future;
        },
      );
      addTearDown(state.dispose);

      final p1Meta = ExifMetadata(captureDate: DateTime(2026, 1, 3));
      final p2Meta = ExifMetadata(captureDate: DateTime(2026, 1, 4));

      await pumpEventQueue();
      await state.loadFolder(dir); // selects P1, schedules P1 read
      await Future<void>.delayed(
        kSelectionExifDebounce + const Duration(milliseconds: 20),
      );
      expect(callPaths, [p.join(dir.path, 'P1.jpg')]);

      // Move on to P2: bumps the generation and reschedules; P1's parked read
      // is now stale.
      state.selectItem('P2');

      // Let P1's stale result land. It must be discarded — neither written to
      // the cache nor surfaced — so currentExif stays null (P2's own read has
      // not been armed long enough to fire).
      gates[p.join(dir.path, 'P1.jpg')]!.complete([p1Meta]);
      await pumpEventQueue();

      expect(state.selectedItemID, 'P2');
      expect(state.currentExif, isNull,
          reason: 'stale result for P1 must not surface for P2');

      // P2's own read then lands normally and is the only thing currentExif
      // reflects.
      await Future<void>.delayed(
        kSelectionExifDebounce + const Duration(milliseconds: 20),
      );
      expect(callPaths, hasLength(2));
      gates[p.join(dir.path, 'P2.jpg')]!.complete([p2Meta]);
      await pumpEventQueue();

      expect(identical(state.currentExif, p2Meta), isTrue);
    });

    test('TC-497 re-selecting an already-read photo reads zero times',
        () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_exif497_');
      addTempDirTeardown(dir);
      await _touch(dir, 'A.jpg');
      await _touch(dir, 'B.jpg');

      final callPaths = <String>[];
      final state = _state(
        dir: dir,
        ids: const ['A', 'B'],
        exifReader: (paths, {onProgress}) async {
          callPaths.addAll(paths);
          final day = paths.single.endsWith('A.jpg') ? 1 : 2;
          return [ExifMetadata(captureDate: DateTime(2026, 1, day))];
        },
      );
      addTearDown(state.dispose);

      await pumpEventQueue();
      await state.loadFolder(dir); // selects A, reads it after quiet
      await Future<void>.delayed(
        kSelectionExifDebounce + const Duration(milliseconds: 20),
      );
      expect(callPaths, hasLength(1));
      expect(state.currentExif!.captureDate, DateTime(2026, 1, 1));

      state.selectItem('B');
      await Future<void>.delayed(
        kSelectionExifDebounce + const Duration(milliseconds: 20),
      );
      expect(callPaths, hasLength(2), reason: 'B is a first visit');
      expect(state.currentExif!.captureDate, DateTime(2026, 1, 2));

      // Back to A: cached, so no new read, and the cache answers immediately.
      state.selectItem('A');
      await Future<void>.delayed(
        kSelectionExifDebounce + const Duration(milliseconds: 20),
      );
      expect(callPaths, hasLength(2),
          reason: 'revisiting an already-read photo must not re-read');
      expect(state.selectedItemID, 'A');
      expect(state.currentExif!.captureDate, DateTime(2026, 1, 1));
    });
  });
}

/// Fixed items backed by real (tiny) fixture files so `bestFileToLoad`
/// resolves to a real path the fake reader receives.
List<PhotoItem> _exifItems(Directory dir, List<String> ids) => [
      for (final id in ids)
        PhotoItem(id: id, files: [File(p.join(dir.path, '$id.jpg'))]),
    ];

/// A preload controller whose navigational work is a no-op. `loadFolder` and
/// `selectItem` poke the real `AppState` the same way, but no decode is
/// scheduled, so no preload `notifyListeners` can leak into the EXIF-feature
/// notify counts or arm pipelines timers mid-test. `reset`/`dispose` still
/// run for real (safe memory + ImageCache bookkeeping).
class _SilentPreload extends ImagePreloadController {
  _SilentPreload()
      : super(
          imageLoader: (path, {required purpose}) async =>
              NativeImageBytes(Uint8List.fromList(const [1, 2, 3])),
        );

  @override
  Future<void> preloadImages({
    required List<PhotoItem> items,
    required String selectedItemId,
    required VoidCallback notifyLoaded,
  }) async {}

  @override
  Future<void> preloadThumbnails({
    required List<PhotoItem> items,
    required int startIdx,
    required int endIdx,
    required VoidCallback notifyLoaded,
  }) async {}
}

class _FixedScanner extends PhotoLibraryScanner {
  _FixedScanner(this.result);
  final List<PhotoItem> result;
  @override
  Future<List<PhotoItem>> scan(Directory dir) async => result;
}

AppState _state({
  required Directory dir,
  required List<String> ids,
  required Future<List<ExifMetadata?>> Function(
    List<String> paths, {
    void Function(int done, int total)? onProgress,
  })
  exifReader,
}) {
  return AppState(
    scanner: _FixedScanner(_exifItems(dir, ids)),
    imageLoader: (path, {required purpose}) async =>
        NativeImageBytes(Uint8List.fromList(const [1, 2, 3])),
    preloadController: _SilentPreload(),
    exifReader: exifReader,
  );
}

Future<void> _touch(Directory dir, String name) async {
  await File(p.join(dir.path, name)).writeAsBytes(
    Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xE0]), // tiny fake JPEG magic
  );
}