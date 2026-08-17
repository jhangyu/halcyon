# Recycle Mode (`.trash`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In folders containing same-basename JPG+RAW groups, batch delete defaults to moving the whole group into a `<folder>/.trash/` subdirectory instead of the system trash, with a right-click toggle on the detail-view delete button to switch back to direct delete.

**Architecture:** A per-folder boolean on `AppState` (`recycleMode`, detected at `loadFolder`, never persisted) selects between the existing `PhotoFileActions.deleteTrashed` (system trash) and a new `PhotoFileActions.recycleTrashed` (same-volume `File.rename` into `.trash/`). `AppState.deleteTrashed()` now returns a result object so the view layer — not the provider — owns all user feedback (SnackBar on success, AlertDialog on failure). The detail view's floating action bar is extracted into its own widget so its icons are widget-testable without decoding an image.

**Tech Stack:** Flutter/Dart, `provider` (`ChangeNotifier`), `path` package, `flutter_test`. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-17-recycle-mode-design.md`

## Global Constraints

- macOS-only app. `Process.run('open', [...])` for Finder is acceptable.
- `recycleMode` is **per-folder and never persisted** — no `SharedPreferences`, no `.halcyon_status.json` field. Recomputed on every `loadFolder`.
- Recycle mode reuses **`Colors.red`**. `Colors.amber` is reserved for the star button (`lib/views/main_detail_view.dart:145`); modes are distinguished by icon shape, not colour.
- Recycle-mode icons: `Icons.restore_from_trash_outlined` (unmarked) and `Icons.restore_from_trash` (marked). Direct-delete icons stay `Icons.delete_outline` / `Icons.delete`.
- Collision suffix format: `IMG_0001-1.jpg`, `IMG_0001-2.jpg` — the counter goes between basename and extension, starting at 1.
- `._<basename>` AppleDouble sidecars are moved alongside their photo, matching existing `deleteTrashed` behaviour (`lib/services/photo_file_actions.dart:61`).
- Batch failures must never be silent. The current `debugPrint`-only swallow at `lib/providers/app_state.dart:379` is a defect this plan fixes.
- No new keyboard shortcuts. `X` keeps meaning "toggle trashed mark" (`lib/views/main_screen.dart:85`).
- Every test in this plan must be **seen failing before it passes** (Step "run test to verify it fails" is not optional — a test never observed red is not evidence).
- Test command: `flutter test <path>`. Full suite: `flutter test`.

## File Structure

| File | Responsibility |
|---|---|
| `lib/models/supported_photo_formats.dart` (modify) | Add `.cr2/.nef/.orf` to `supportedExtensions` |
| `lib/services/photo_file_actions.dart` (modify) | Add `MoveFile` typedef, `RecycleOutcome`, `recycleTrashed` |
| `lib/providers/app_state.dart` (modify) | `recycleMode` state + detection + toggle; `deleteTrashed` returns `BatchDeleteResult` |
| `lib/views/photo_action_bar.dart` (create) | Extracted floating star/trash bar; owns recycle icon + right-click toggle |
| `lib/views/main_detail_view.dart` (modify) | Use `PhotoActionBar` instead of inline bar |
| `lib/views/sidebar_view.dart` (modify) | Status icon follows mode; menu label follows mode; awaits result and shows feedback |
| `lib/views/batch_delete_feedback.dart` (create) | `showBatchDeleteFeedback` — SnackBar on success, AlertDialog on failure |
| `test/photo_file_actions_test.dart` (modify) | `recycleTrashed`: sibling move, collision suffix, failure isolation |
| `test/app_state_test.dart` (modify) | `.cr2` scanning; `recycleMode` detection/toggle; dispatch |
| `test/photo_action_bar_test.dart` (create) | Icon-per-mode, right-click toggle |
| `test/batch_delete_feedback_test.dart` (create) | SnackBar text/duration, AlertDialog on failure |

---

### Task 1: Add missing RAW extensions to the scan set

`rawExtensions` already lists `.cr2/.nef/.orf` (`lib/models/supported_photo_formats.dart:23`) but `supportedExtensions` (same file, `:6`) does not — so Canon/Nikon/Olympus RAW files are never grouped into `PhotoItem.files` and get silently left on the card when their JPG sibling is deleted.

**Files:**
- Modify: `lib/models/supported_photo_formats.dart:6-14`
- Test: `test/app_state_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces: `SupportedPhotoFormats.supportedExtensions` now contains `.cr2`, `.nef`, `.orf`. Later tasks rely on scanner grouping being complete but call no new API.

- [ ] **Step 1: Write the failing test**

Add this test to `test/app_state_test.dart`, immediately after the existing `'scans RW2 files into photo groups'` test (it follows that test's shape exactly):

```dart
    test('groups CR2/NEF/ORF raw files with their JPG sibling', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_raw_ext_');
      addTearDown(() => dir.delete(recursive: true));
      await _touch(dir, 'IMG_0001.jpg');
      await _touch(dir, 'IMG_0001.cr2');
      await _touch(dir, 'IMG_0002.jpg');
      await _touch(dir, 'IMG_0002.nef');
      await _touch(dir, 'IMG_0003.jpg');
      await _touch(dir, 'IMG_0003.orf');

      final state = _testState();
      await state.loadFolder(dir);

      expect(state.items.map((item) => item.id), [
        'IMG_0001',
        'IMG_0002',
        'IMG_0003',
      ]);
      for (final item in state.items) {
        expect(item.files, hasLength(2), reason: '${item.id} lost its raw');
      }
    });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/app_state_test.dart --plain-name 'groups CR2/NEF/ORF raw files with their JPG sibling'`
Expected: FAIL — `IMG_0001 lost its raw`, `Expected: an object with length of <2> Actual: [...] which has length of <1>`.

- [ ] **Step 3: Write minimal implementation**

In `lib/models/supported_photo_formats.dart`, replace the `supportedExtensions` set:

```dart
  static const supportedExtensions = <String>{
    '.jpg',
    '.jpeg',
    '.arw',
    '.rw2',
    '.dng',
    '.heic',
    '.png',
    '.cr2',
    '.nef',
    '.orf',
  };
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/app_state_test.dart`
Expected: PASS — all tests in the file, including the new one.

- [ ] **Step 5: Commit**

```bash
git add lib/models/supported_photo_formats.dart test/app_state_test.dart
git commit -m "fix(scan): group CR2/NEF/ORF raw files with their JPG sibling"
```

---

### Task 2: `PhotoFileActions.recycleTrashed`

**Files:**
- Modify: `lib/services/photo_file_actions.dart`
- Test: `test/photo_file_actions_test.dart`

**Interfaces:**
- Consumes: `PhotoItem` (`lib/models/photo_item.dart`), `PhotoStatus`.
- Produces (exact signatures later tasks depend on):
  ```dart
  typedef MoveFile = Future<void> Function(File file, String newPath);

  class RecycleOutcome {
    const RecycleOutcome({required this.movedCount, required this.failures});
    final int movedCount;
    final List<String> failures;   // "IMG_0001.jpg: <error message>"
  }

  // constructor gains an optional named param:
  PhotoFileActions({TrashFile? trashFile, MoveFile? moveFile});

  Future<RecycleOutcome> recycleTrashed(List<PhotoItem> items, Directory dir);
  ```

- [ ] **Step 1: Write the failing tests**

Add a new group to `test/photo_file_actions_test.dart`, after the existing `PhotoFileActions.deleteTrashed` group closes. The file already has a `_touch` helper at the bottom — reuse it.

```dart
  group('PhotoFileActions.recycleTrashed', () {
    test('moves every sibling file and sidecar into .trash', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_recycle_');
      addTearDown(() => dir.delete(recursive: true));

      final jpg = await _touch(dir, 'IMG_0001.jpg');
      final dng = await _touch(dir, 'IMG_0001.dng');
      final sidecar = await _touch(dir, '._IMG_0001.jpg');
      final untouched = await _touch(dir, 'IMG_0002.jpg');

      final outcome = await PhotoFileActions().recycleTrashed([
        PhotoItem(
          id: 'IMG_0001',
          files: [jpg, dng],
          status: PhotoStatus.trashed,
        ),
        PhotoItem(
          id: 'IMG_0002',
          files: [untouched],
          status: PhotoStatus.unmarked,
        ),
      ], dir);

      final trashDir = Directory(p.join(dir.path, '.trash'));
      expect(outcome.movedCount, 3);
      expect(outcome.failures, isEmpty);
      expect(await File(p.join(trashDir.path, 'IMG_0001.jpg')).exists(), isTrue);
      expect(await File(p.join(trashDir.path, 'IMG_0001.dng')).exists(), isTrue);
      expect(
        await File(p.join(trashDir.path, '._IMG_0001.jpg')).exists(),
        isTrue,
      );
      expect(await jpg.exists(), isFalse);
      expect(await dng.exists(), isFalse);
      expect(await sidecar.exists(), isFalse);
      expect(await untouched.exists(), isTrue);
    });

    test('suffixes collisions instead of overwriting', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_recycle_dup_');
      addTearDown(() => dir.delete(recursive: true));

      final trashDir = Directory(p.join(dir.path, '.trash'));
      await trashDir.create(recursive: true);
      final existing = File(p.join(trashDir.path, 'IMG_0001.jpg'));
      await existing.writeAsString('OLD');

      final jpg = File(p.join(dir.path, 'IMG_0001.jpg'));
      await jpg.writeAsString('NEW');

      final outcome = await PhotoFileActions().recycleTrashed([
        PhotoItem(id: 'IMG_0001', files: [jpg], status: PhotoStatus.trashed),
      ], dir);

      expect(outcome.movedCount, 1);
      expect(await existing.readAsString(), 'OLD');
      expect(
        await File(p.join(trashDir.path, 'IMG_0001-1.jpg')).readAsString(),
        'NEW',
      );
    });

    test('records per-file failures and keeps processing the rest', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_recycle_err_');
      addTearDown(() => dir.delete(recursive: true));

      final bad = await _touch(dir, 'IMG_0001.jpg');
      final good = await _touch(dir, 'IMG_0002.jpg');

      final actions = PhotoFileActions(
        moveFile: (file, newPath) async {
          if (p.basename(file.path) == 'IMG_0001.jpg') {
            throw const FileSystemException('Read-only file system');
          }
          await file.rename(newPath);
        },
      );

      final outcome = await actions.recycleTrashed([
        PhotoItem(id: 'IMG_0001', files: [bad], status: PhotoStatus.trashed),
        PhotoItem(id: 'IMG_0002', files: [good], status: PhotoStatus.trashed),
      ], dir);

      expect(outcome.movedCount, 1);
      expect(outcome.failures, hasLength(1));
      expect(outcome.failures.single, contains('IMG_0001.jpg'));
      expect(outcome.failures.single, contains('Read-only file system'));
      expect(await bad.exists(), isTrue);
      expect(await good.exists(), isFalse);
    });
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/photo_file_actions_test.dart`
Expected: FAIL at compile time — `The method 'recycleTrashed' isn't defined for the type 'PhotoFileActions'` and `No named parameter with the name 'moveFile'`.

- [ ] **Step 3: Write minimal implementation**

In `lib/services/photo_file_actions.dart`, add the typedef next to the existing one and extend the class. Full replacement for the top of the file through the constructor:

```dart
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/photo_item.dart';
import 'trash_service.dart';

typedef TrashFile = Future<void> Function(File file);
typedef MoveFile = Future<void> Function(File file, String newPath);

/// Result of a recycle batch. [failures] entries are
/// "<filename>: <error message>" and MUST be surfaced to the user — a
/// silently failed delete looks identical to a broken app.
class RecycleOutcome {
  const RecycleOutcome({required this.movedCount, required this.failures});

  final int movedCount;
  final List<String> failures;
}

class PhotoFileActions {
  PhotoFileActions({TrashFile? trashFile, MoveFile? moveFile})
    : _trashFile = trashFile ?? TrashService.trashFile,
      _moveFile = moveFile ?? _renameFile;

  final TrashFile _trashFile;
  final MoveFile _moveFile;

  static Future<void> _renameFile(File file, String newPath) async {
    await file.rename(newPath);
  }
```

Then add these methods to the same class (place them right after `deleteTrashed`, before `_trashIfExists`):

```dart
  /// Moves every file of each trashed item — plus its `._` AppleDouble
  /// sidecar — into `<dir>/.trash/`. Same-volume rename, so this is instant
  /// and works on cards where the system trash API is unavailable.
  Future<RecycleOutcome> recycleTrashed(
    List<PhotoItem> items,
    Directory dir,
  ) async {
    final trashDir = Directory(p.join(dir.path, '.trash'));
    if (!await trashDir.exists()) {
      await trashDir.create(recursive: true);
    }

    var movedCount = 0;
    final failures = <String>[];

    for (final item in items) {
      if (item.status != PhotoStatus.trashed) continue;

      for (final file in item.files) {
        final sidecar = File(
          p.join(file.parent.path, '._${p.basename(file.path)}'),
        );
        // The photo always moves; its AppleDouble sidecar only if present.
        final targets = <File>[
          file,
          if (await sidecar.exists()) sidecar,
        ];

        for (final target in targets) {
          try {
            await _moveFile(
              target,
              _availablePath(trashDir.path, p.basename(target.path)),
            );
            movedCount++;
          } catch (e) {
            failures.add('${p.basename(target.path)}: $e');
          }
        }
      }
    }

    return RecycleOutcome(movedCount: movedCount, failures: failures);
  }

  /// `IMG_0001.jpg` -> `IMG_0001-1.jpg` -> `IMG_0001-2.jpg` when taken.
  /// Never overwrites an earlier recycle batch.
  String _availablePath(String trashDirPath, String fileName) {
    var candidate = p.join(trashDirPath, fileName);
    if (!File(candidate).existsSync()) return candidate;

    final stem = p.basenameWithoutExtension(fileName);
    final ext = p.extension(fileName);
    var counter = 1;
    do {
      candidate = p.join(trashDirPath, '$stem-$counter$ext');
      counter++;
    } while (File(candidate).existsSync());
    return candidate;
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/photo_file_actions_test.dart`
Expected: PASS — the three new tests plus the pre-existing `deleteTrashed` tests.

- [ ] **Step 5: Commit**

```bash
git add lib/services/photo_file_actions.dart test/photo_file_actions_test.dart
git commit -m "feat(recycle): move trashed sibling groups into .trash with collision suffixes"
```

---

### Task 3: `AppState.recycleMode` and batch dispatch

**Files:**
- Modify: `lib/providers/app_state.dart` (add state near `:58-66`; extend `deleteTrashed` at `:372-389`)
- Test: `test/app_state_test.dart`

**Interfaces:**
- Consumes: `PhotoFileActions.recycleTrashed`, `RecycleOutcome` (Task 2).
- Produces (exact signatures Tasks 4–5 depend on):
  ```dart
  bool get recycleMode;
  void toggleRecycleMode();

  class BatchDeleteResult {
    const BatchDeleteResult({
      required this.recycled,
      required this.movedCount,
      required this.failures,
      this.trashDirPath,
    });
    final bool recycled;         // true when the recycle path ran
    final int movedCount;        // files moved into .trash (recycle path only)
    final List<String> failures; // "<filename>: <error>"
    final String? trashDirPath;  // non-null on the recycle path
  }

  Future<BatchDeleteResult> deleteTrashed();   // was Future<void>
  ```

- [ ] **Step 1: Write the failing tests**

Add this group to `test/app_state_test.dart`, before the final closing `}` of `main()`:

```dart
  group('AppState recycle mode', () {
    test('defaults on when a folder has same-name sibling groups', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_mode_on_');
      addTearDown(() => dir.delete(recursive: true));
      await _touch(dir, 'IMG_0001.jpg');
      await _touch(dir, 'IMG_0001.dng');

      final state = _testState();
      await state.loadFolder(dir);

      expect(state.recycleMode, isTrue);
    });

    test('defaults off when every photo has a single extension', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_mode_off_');
      addTearDown(() => dir.delete(recursive: true));
      await _touch(dir, 'IMG_0001.jpg');
      await _touch(dir, 'IMG_0002.jpg');

      final state = _testState();
      await state.loadFolder(dir);

      expect(state.recycleMode, isFalse);
    });

    test('toggles both ways and notifies listeners', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_mode_tog_');
      addTearDown(() => dir.delete(recursive: true));
      await _touch(dir, 'IMG_0001.jpg');

      final state = _testState();
      await state.loadFolder(dir);
      var notifications = 0;
      state.addListener(() => notifications++);

      expect(state.recycleMode, isFalse);
      state.toggleRecycleMode();
      expect(state.recycleMode, isTrue);
      state.toggleRecycleMode();
      expect(state.recycleMode, isFalse);
      expect(notifications, 2);
    });

    test('recycle mode moves files to .trash instead of the system trash',
        () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_mode_run_');
      addTearDown(() => dir.delete(recursive: true));
      await _touch(dir, 'IMG_0001.jpg');
      await _touch(dir, 'IMG_0001.dng');

      final trashed = <String>[];
      final state = AppState(
        fileActions: PhotoFileActions(trashFile: (file) async {
          trashed.add(file.path);
          await file.delete();
        }),
        thumbnailLoader: (path, {required purpose}) async {
          return NativeImageBytes(Uint8List.fromList([1, 2, 3]));
        },
      );
      await state.loadFolder(dir);
      state.markCurrent(PhotoStatus.trashed);

      final result = await state.deleteTrashed();

      expect(result.recycled, isTrue);
      expect(result.movedCount, 2);
      expect(result.failures, isEmpty);
      expect(result.trashDirPath, p.join(dir.path, '.trash'));
      expect(trashed, isEmpty, reason: 'system trash must not be used');
      expect(
        await File(p.join(dir.path, '.trash', 'IMG_0001.jpg')).exists(),
        isTrue,
      );
      expect(state.items, isEmpty, reason: 'folder reloaded after recycle');
    });

    test('direct mode still routes through the system trash', () async {
      final dir = await Directory.systemTemp.createTemp('halcyon_mode_dir_');
      addTearDown(() => dir.delete(recursive: true));
      await _touch(dir, 'IMG_0001.jpg');

      final trashed = <String>[];
      final state = AppState(
        fileActions: PhotoFileActions(trashFile: (file) async {
          trashed.add(file.path);
          await file.delete();
        }),
        thumbnailLoader: (path, {required purpose}) async {
          return NativeImageBytes(Uint8List.fromList([1, 2, 3]));
        },
      );
      await state.loadFolder(dir);
      expect(state.recycleMode, isFalse);
      state.markCurrent(PhotoStatus.trashed);

      final result = await state.deleteTrashed();

      expect(result.recycled, isFalse);
      expect(trashed, hasLength(1));
      expect(await Directory(p.join(dir.path, '.trash')).exists(), isFalse);
    });
  });
```

Add the import this group needs to the top of `test/app_state_test.dart`:

```dart
import 'package:halcyon_flutter/services/photo_file_actions.dart';
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/app_state_test.dart --plain-name 'AppState recycle mode'`
Expected: FAIL at compile time — `The getter 'recycleMode' isn't defined for the type 'AppState'`.

- [ ] **Step 3: Write minimal implementation**

In `lib/providers/app_state.dart`:

3a. Add the result type above `class AppState` (after the `ThumbnailLoader` typedef):

```dart
/// Outcome of a batch delete, returned to the view layer so feedback lives
/// in the widgets rather than the provider. Failures are never swallowed.
class BatchDeleteResult {
  const BatchDeleteResult({
    required this.recycled,
    required this.movedCount,
    required this.failures,
    this.trashDirPath,
  });

  final bool recycled;
  final int movedCount;
  final List<String> failures;
  final String? trashDirPath;
}
```

3b. Add the field and accessors next to the other settings (after `bool _overwriteExisting = true;`):

```dart
  // Per-folder, deliberately NOT persisted: every loadFolder re-detects, so
  // a new card always starts from the safe default.
  bool _recycleMode = false;
```

and next to the other getters (after `bool get overwriteExisting => _overwriteExisting;`):

```dart
  bool get recycleMode => _recycleMode;

  void toggleRecycleMode() {
    _recycleMode = !_recycleMode;
    notifyListeners();
  }
```

3c. In `loadFolder`, right after `_items = await _scanner.scan(dir);`, add:

```dart
      // A folder holding same-name sibling groups is a camera card being
      // culled: default to recycling so a mis-click can't take the RAW with it.
      _recycleMode = _items.any((item) => item.files.length > 1);
```

3d. Replace the whole `deleteTrashed` method:

```dart
  Future<BatchDeleteResult> deleteTrashed() async {
    final currentId = _selectedItemID;
    final currentIndex = _items.indexWhere((i) => i.id == currentId);
    final dir = _currentDir;
    final recycled = _recycleMode;

    var movedCount = 0;
    final failures = <String>[];
    String? trashDirPath;

    try {
      if (recycled && dir != null) {
        trashDirPath = p.join(dir.path, '.trash');
        final outcome = await _fileActions.recycleTrashed(_items, dir);
        movedCount = outcome.movedCount;
        failures.addAll(outcome.failures);
      } else {
        await _fileActions.deleteTrashed(_items);
      }
    } catch (e) {
      // Previously this only debugPrint()ed, so a card where the system trash
      // is unavailable looked like a broken app. Report it instead.
      failures.add('$e');
    }

    if (dir != null) {
      await loadFolder(
        dir,
        targetSelectionId: currentId,
        targetFallbackIndex: currentIndex,
      );
    }

    return BatchDeleteResult(
      recycled: recycled,
      movedCount: movedCount,
      failures: failures,
      trashDirPath: trashDirPath,
    );
  }
```

3e. Add the `path` import at the top of `lib/providers/app_state.dart` (it does not import it yet):

```dart
import 'package:path/path.dart' as p;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/app_state_test.dart`
Expected: PASS — whole file green, including the five new tests.

- [ ] **Step 5: Commit**

```bash
git add lib/providers/app_state.dart test/app_state_test.dart
git commit -m "feat(recycle): per-folder recycle mode with batch dispatch and reported failures"
```

---

### Task 4: Extract `PhotoActionBar` with recycle icon and right-click toggle

The floating star/trash bar is currently inline in `MainDetailView.build` (`lib/views/main_detail_view.dart:117-171`), which makes it untestable without a decodable image. Extract it, then add the mode behaviour.

**Files:**
- Create: `lib/views/photo_action_bar.dart`
- Modify: `lib/views/main_detail_view.dart:116-171`
- Test: `test/photo_action_bar_test.dart`

**Interfaces:**
- Consumes: `AppState.recycleMode`, `AppState.toggleRecycleMode`, `AppState.markCurrent` (Task 3).
- Produces: `PhotoActionBar({Key? key, required PhotoItem item})` — a `StatelessWidget` reading `AppState` from context.

- [ ] **Step 1: Write the failing test**

Create `test/photo_action_bar_test.dart`:

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/native_thumbnail_service.dart';
import 'package:halcyon_flutter/views/photo_action_bar.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<AppState> stateForFolder({required bool withSibling}) async {
    final dir = await Directory.systemTemp.createTemp('halcyon_bar_');
    addTearDown(() => dir.delete(recursive: true));
    await File(p.join(dir.path, 'IMG_0001.jpg')).writeAsBytes([1, 2, 3]);
    if (withSibling) {
      await File(p.join(dir.path, 'IMG_0001.dng')).writeAsBytes([1, 2, 3]);
    }
    final state = AppState(
      thumbnailLoader: (path, {required purpose}) async {
        return NativeImageBytes(Uint8List.fromList([1, 2, 3]));
      },
    );
    await state.loadFolder(dir);
    return state;
  }

  Future<void> pumpBar(WidgetTester tester, AppState state) {
    return tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(
            body: Consumer<AppState>(
              builder: (context, s, _) =>
                  PhotoActionBar(item: s.currentItem!),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('direct mode shows the trash can icons', (tester) async {
    final state = await stateForFolder(withSibling: false);
    await pumpBar(tester, state);

    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    expect(find.byIcon(Icons.restore_from_trash_outlined), findsNothing);

    state.markCurrent(PhotoStatus.trashed);
    await tester.pump();

    expect(find.byIcon(Icons.delete), findsOneWidget);
  });

  testWidgets('recycle mode shows the restore-from-trash icons',
      (tester) async {
    final state = await stateForFolder(withSibling: true);
    expect(state.recycleMode, isTrue);
    await pumpBar(tester, state);

    expect(find.byIcon(Icons.restore_from_trash_outlined), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsNothing);

    state.markCurrent(PhotoStatus.trashed);
    await tester.pump();

    expect(find.byIcon(Icons.restore_from_trash), findsOneWidget);
  });

  testWidgets('right-click toggles the mode without marking the photo',
      (tester) async {
    final state = await stateForFolder(withSibling: false);
    await pumpBar(tester, state);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byIcon(Icons.delete_outline)),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pump();

    expect(state.recycleMode, isTrue);
    expect(state.currentItem!.status, PhotoStatus.unmarked);
    expect(find.byIcon(Icons.restore_from_trash_outlined), findsOneWidget);
  });

  testWidgets('left-click still marks the photo as trashed', (tester) async {
    final state = await stateForFolder(withSibling: false);
    await pumpBar(tester, state);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();

    expect(state.currentItem!.status, PhotoStatus.trashed);
    expect(state.recycleMode, isFalse);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/photo_action_bar_test.dart`
Expected: FAIL at compile time — `Error when reading 'lib/views/photo_action_bar.dart': No such file or directory`.

- [ ] **Step 3: Write the implementation**

Create `lib/views/photo_action_bar.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/photo_item.dart';
import '../providers/app_state.dart';

/// Floating star/trash bar over the detail view.
///
/// The delete button doubles as the recycle-mode indicator: in recycle mode
/// it becomes a trash can with an up-arrow (files are retrievable from
/// `.trash`). Red is reused for both modes because amber belongs to the star
/// button — the modes differ by icon shape, not colour. Right-click toggles
/// the mode; left-click keeps its usual "mark this photo" meaning.
class PhotoActionBar extends StatelessWidget {
  const PhotoActionBar({super.key, required this.item});

  final PhotoItem item;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final isStarred = item.status == PhotoStatus.starred;
    final isTrashed = item.status == PhotoStatus.trashed;
    final recycle = state.recycleMode;

    final IconData deleteIcon = recycle
        ? (isTrashed
              ? Icons.restore_from_trash
              : Icons.restore_from_trash_outlined)
        : (isTrashed ? Icons.delete : Icons.delete_outline);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 10,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(
              isStarred ? Icons.star : Icons.star_border,
              color: isStarred ? Colors.amber : null,
            ),
            onPressed: () =>
                context.read<AppState>().markCurrent(PhotoStatus.starred),
            tooltip: 'Star (S)',
          ),
          const SizedBox(width: 20),
          GestureDetector(
            onSecondaryTap: () => context.read<AppState>().toggleRecycleMode(),
            child: IconButton(
              icon: Icon(deleteIcon, color: isTrashed ? Colors.red : null),
              onPressed: () =>
                  context.read<AppState>().markCurrent(PhotoStatus.trashed),
              tooltip: recycle
                  ? 'Recycle (X) — right-click: switch to direct delete'
                  : 'Trash (X) — right-click: switch to recycle mode',
            ),
          ),
        ],
      ),
    );
  }
}
```

Then in `lib/views/main_detail_view.dart`, replace the whole `Positioned` block that renders the inline bar (from `// Floating Action Bar (Bottom Center)` at `:116` through the `Positioned`'s closing `),` at `:171`) with:

```dart
        // Floating Action Bar (Bottom Center)
        Positioned(
          bottom: 30,
          left: 0,
          right: 0,
          child: Center(child: PhotoActionBar(item: item)),
        ),
```

and add the import next to the other view imports at the top of the file:

```dart
import 'photo_action_bar.dart';
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/photo_action_bar_test.dart`
Expected: PASS — all four tests.

Run: `flutter analyze lib/views/main_detail_view.dart lib/views/photo_action_bar.dart`
Expected: `No issues found!` (unused-import warnings here mean the extraction left dead imports in `main_detail_view.dart` — remove any it names).

- [ ] **Step 5: Commit**

```bash
git add lib/views/photo_action_bar.dart lib/views/main_detail_view.dart test/photo_action_bar_test.dart
git commit -m "feat(recycle): mode-aware delete button with right-click toggle"
```

---

### Task 5: Batch feedback — SnackBar on success, AlertDialog on failure

**Files:**
- Create: `lib/views/batch_delete_feedback.dart`
- Test: `test/batch_delete_feedback_test.dart`

**Interfaces:**
- Consumes: `BatchDeleteResult` (Task 3).
- Produces:
  ```dart
  void showBatchDeleteFeedback(
    BuildContext context,
    BatchDeleteResult result, {
    void Function(String path)? revealInFinder,
  });
  ```
  `revealInFinder` defaults to `Process.run('open', [path])`; the parameter exists so tests never shell out.

- [ ] **Step 1: Write the failing test**

Create `test/batch_delete_feedback_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/views/batch_delete_feedback.dart';

void main() {
  Future<void> pumpTrigger(
    WidgetTester tester,
    BatchDeleteResult result, {
    void Function(String path)? revealInFinder,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showBatchDeleteFeedback(
                context,
                result,
                revealInFinder: revealInFinder,
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('recycle success shows a 2.5s snackbar with a reveal action',
      (tester) async {
    await pumpTrigger(
      tester,
      const BatchDeleteResult(
        recycled: true,
        movedCount: 4,
        failures: [],
        trashDirPath: '/cards/DCIM/.trash',
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump();

    expect(
      find.text('已回收 4 個檔案到 .trash（未直接刪除，請自行清理）'),
      findsOneWidget,
    );
    expect(find.text('顯示'), findsOneWidget);
    expect(
      tester.widget<SnackBar>(find.byType(SnackBar)).duration,
      const Duration(milliseconds: 2500),
    );
  });

  testWidgets('reveal action calls the injected opener with the trash path',
      (tester) async {
    final opened = <String>[];
    await pumpTrigger(
      tester,
      const BatchDeleteResult(
        recycled: true,
        movedCount: 1,
        failures: [],
        trashDirPath: '/cards/DCIM/.trash',
      ),
      revealInFinder: opened.add,
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.tap(find.text('顯示'));
    await tester.pump();

    expect(opened, ['/cards/DCIM/.trash']);
  });

  testWidgets('failures show a blocking dialog listing each file',
      (tester) async {
    await pumpTrigger(
      tester,
      const BatchDeleteResult(
        recycled: true,
        movedCount: 1,
        failures: ['IMG_0001.jpg: Read-only file system'],
        trashDirPath: '/cards/DCIM/.trash',
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('IMG_0001.jpg'), findsOneWidget);
    expect(find.textContaining('Read-only file system'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('direct-delete success stays silent', (tester) async {
    await pumpTrigger(
      tester,
      const BatchDeleteResult(recycled: false, movedCount: 0, failures: []),
    );
    await tester.tap(find.text('go'));
    await tester.pump();

    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/batch_delete_feedback_test.dart`
Expected: FAIL at compile time — `Error when reading 'lib/views/batch_delete_feedback.dart': No such file or directory`.

- [ ] **Step 3: Write the implementation**

Create `lib/views/batch_delete_feedback.dart`:

```dart
import 'dart:io';

import 'package:flutter/material.dart';

import '../providers/app_state.dart';

/// Feedback for a finished batch delete.
///
/// Failures win: they get a blocking dialog, because a delete that silently
/// did nothing is indistinguishable from a broken app. Recycle success gets a
/// non-blocking 2.5s SnackBar reminding the user the files are still on disk.
/// Direct-delete success stays silent, as it always has.
void showBatchDeleteFeedback(
  BuildContext context,
  BatchDeleteResult result, {
  void Function(String path)? revealInFinder,
}) {
  if (result.failures.isNotEmpty) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('部分檔案未能處理'),
        content: SingleChildScrollView(
          child: Text(result.failures.join('\n')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('好'),
          ),
        ],
      ),
    );
    return;
  }

  if (!result.recycled) return;

  final trashDirPath = result.trashDirPath;
  final reveal = revealInFinder ?? _openInFinder;

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      duration: const Duration(milliseconds: 2500),
      content: Text('已回收 ${result.movedCount} 個檔案到 .trash（未直接刪除，請自行清理）'),
      action: trashDirPath == null
          ? null
          : SnackBarAction(label: '顯示', onPressed: () => reveal(trashDirPath)),
    ),
  );
}

// macOS-only app; `open` on a directory reveals it in Finder.
void _openInFinder(String path) {
  Process.run('open', [path]);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/batch_delete_feedback_test.dart`
Expected: PASS — all four tests.

- [ ] **Step 5: Commit**

```bash
git add lib/views/batch_delete_feedback.dart test/batch_delete_feedback_test.dart
git commit -m "feat(recycle): batch delete feedback — snackbar on success, dialog on failure"
```

---

### Task 6: Wire the sidebar — mode-aware status icon, menu label, and feedback

**Files:**
- Modify: `lib/views/sidebar_view.dart:173` (status icon call site), `:193-202` (`_buildStatusIcon`), `:259-273` (`onSelected`), `:305-312` (delete menu item)
- Test: `test/sidebar_view_test.dart` (create)

**Interfaces:**
- Consumes: `AppState.recycleMode`, `AppState.deleteTrashed() -> BatchDeleteResult` (Task 3), `showBatchDeleteFeedback` (Task 5).
- Produces: nothing new.

- [ ] **Step 1: Write the failing test**

Create `test/sidebar_view_test.dart`:

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/native_thumbnail_service.dart';
import 'package:halcyon_flutter/views/sidebar_view.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<AppState> stateForFolder({required bool withSibling}) async {
    final dir = await Directory.systemTemp.createTemp('halcyon_sidebar_');
    addTearDown(() => dir.delete(recursive: true));
    await File(p.join(dir.path, 'IMG_0001.jpg')).writeAsBytes([1, 2, 3]);
    if (withSibling) {
      await File(p.join(dir.path, 'IMG_0001.dng')).writeAsBytes([1, 2, 3]);
    }
    final state = AppState(
      thumbnailLoader: (path, {required purpose}) async {
        return NativeImageBytes(Uint8List.fromList([1, 2, 3]));
      },
    );
    await state.loadFolder(dir);
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
  }

  testWidgets('trashed status icon follows the mode', (tester) async {
    final state = await stateForFolder(withSibling: true);
    state.markCurrent(PhotoStatus.trashed);
    await pumpSidebar(tester, state);

    expect(find.byIcon(Icons.restore_from_trash), findsOneWidget);

    state.toggleRecycleMode();
    await tester.pump();

    expect(find.byIcon(Icons.delete), findsOneWidget);
    expect(find.byIcon(Icons.restore_from_trash), findsNothing);
  });

  testWidgets('batch menu label follows the mode', (tester) async {
    final state = await stateForFolder(withSibling: true);
    state.markCurrent(PhotoStatus.trashed);
    await pumpSidebar(tester, state);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    expect(find.text('Recycle Trashed'), findsOneWidget);
    expect(find.text('Delete Trashed'), findsNothing);

    await tester.tapAt(const Offset(5, 5)); // dismiss the menu
    await tester.pumpAndSettle();
    state.toggleRecycleMode();
    await tester.pump();

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    expect(find.text('Delete Trashed'), findsOneWidget);
  });

  testWidgets('recycling from the menu shows the snackbar', (tester) async {
    final state = await stateForFolder(withSibling: true);
    state.markCurrent(PhotoStatus.trashed);
    await pumpSidebar(tester, state);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recycle Trashed'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已回收'), findsOneWidget);
    expect(find.text('顯示'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/sidebar_view_test.dart`
Expected: FAIL — first test reports `Icons.restore_from_trash` not found (the sidebar still renders `Icons.delete` unconditionally).

- [ ] **Step 3: Write the implementation**

In `lib/views/sidebar_view.dart`:

3a. Add the import next to the other view imports:

```dart
import 'batch_delete_feedback.dart';
```

3b. Replace `_buildStatusIcon` (`:193-202`):

```dart
  Widget _buildStatusIcon(PhotoStatus status, bool recycleMode) {
    switch (status) {
      case PhotoStatus.starred:
        return const Icon(Icons.star, color: Colors.amber, size: 16);
      case PhotoStatus.trashed:
        return Icon(
          recycleMode ? Icons.restore_from_trash : Icons.delete,
          color: Colors.red,
          size: 16,
        );
      case PhotoStatus.unmarked:
        return const SizedBox.shrink();
    }
  }
```

3c. Update the call site at `:173` (the `state` local from `:87` is in scope there):

```dart
                          _buildStatusIcon(item.status, state.recycleMode),
```

3d. Replace the `delete` branch inside `onSelected` (`:268-269`):

```dart
        } else if (value == 'delete') {
          final result = await state.deleteTrashed();
          if (!context.mounted) return;
          showBatchDeleteFeedback(context, result);
        } else if (value == 'settings') {
```

3e. Replace the delete `PopupMenuItem` (`:305-312`) so its label follows the mode. The `state` local at `:275` is already in scope inside `itemBuilder`:

```dart
          PopupMenuItem(
            value: 'delete',
            enabled: hasTrashed,
            child: Text(
              state.recycleMode ? 'Recycle Trashed' : 'Delete Trashed',
              style: const TextStyle(color: Colors.red),
            ),
          ),
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/sidebar_view_test.dart`
Expected: PASS — all three tests.

Run: `flutter test`
Expected: PASS — exit code 0 and `All tests passed!` in the output. (Do not trust the per-file progress lines: they are an overwriting progress display and omit fast files. Exit code plus the `All tests passed!` line is the verdict.)

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add lib/views/sidebar_view.dart test/sidebar_view_test.dart
git commit -m "feat(recycle): mode-aware sidebar status icon, menu label, and batch feedback"
```

---

### Task 7: Live verification on a real folder

Tests prove the logic; only a real run proves the feature. Nothing here is optional — a mechanism claimed without a live run is not delivered.

**Files:**
- Create: `docs/logs/2026-08-17/recycle-mode-verification.md`

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: the verification record.

- [ ] **Step 1: Build and launch**

```bash
flutter run -d macos
```
Expected: app window opens.

- [ ] **Step 2: Prepare a scratch folder with sibling groups**

```bash
mkdir -p scripts/tmp/recycle-check
SRC=$(ls local_data/photo_samples/JPG/*.jpg | head -1)
for n in 1 2 3; do
  cp "$SRC" scripts/tmp/recycle-check/IMG_000$n.jpg
  cp "$SRC" scripts/tmp/recycle-check/IMG_000$n.dng
done
ls scripts/tmp/recycle-check
```
Expected: six files, three sibling pairs. The `.dng` copies are really JPEGs — that is fine here, the point is only that the sibling grouping and the move see two extensions. The `.jpg` is a real decodable photo so the preview renders.

- [ ] **Step 3: Verify the mode auto-detects**

Open that folder in the app. Check: the bottom bar's delete button is `restore_from_trash_outlined` (trash can with an up-arrow), and its tooltip reads `Recycle (X) — right-click: switch to direct delete`.

- [ ] **Step 4: Verify the batch recycle**

Mark `IMG_0001` and `IMG_0002` with `X`. The sidebar rows show the up-arrow trash icon in red. Open `⋯` — the item reads `Recycle Trashed`. Click it.

Expected: SnackBar `已回收 4 個檔案到 .trash（未直接刪除，請自行清理）` appears for ~2.5s with a `顯示` button; the two photos leave the list; `IMG_0003` remains.

- [ ] **Step 5: Verify on disk**

```bash
ls -a scripts/tmp/recycle-check scripts/tmp/recycle-check/.trash
```
Expected: `.trash` holds `IMG_0001.jpg IMG_0001.dng IMG_0002.jpg IMG_0002.dng`; the parent holds only `IMG_0003.*` plus `.halcyon_status.json`.

- [ ] **Step 6: Verify the reveal action and the toggle back**

Trigger another recycle and click `顯示` — Finder opens the `.trash` folder. Then right-click the bottom bar's delete button: the icon becomes `delete_outline`, tooltip becomes `Trash (X) — right-click: switch to recycle mode`, and `⋯` now reads `Delete Trashed`. Mark `IMG_0003`, run it, and confirm the file lands in the macOS Trash rather than `.trash`.

- [ ] **Step 7: Verify collision suffixing**

Copy a fresh `IMG_0001.jpg` + `IMG_0001.dng` into the folder, switch back to recycle mode (right-click), mark it, recycle it.

```bash
ls scripts/tmp/recycle-check/.trash
```
Expected: `IMG_0001-1.jpg` and `IMG_0001-1.dng` appear alongside the originals, which are unmodified.

- [ ] **Step 8: Record the evidence and clean up**

Write `docs/logs/2026-08-17/recycle-mode-verification.md` containing, for each of Steps 3–7: what was done, what was observed, and the actual `ls` output pasted verbatim. Note any deviation from expectations as a known limitation rather than omitting it.

```bash
rm -rf scripts/tmp/recycle-check
git add docs/logs/2026-08-17/recycle-mode-verification.md
git commit -m "docs(recycle): live verification record for recycle mode"
```

---

## Spec Coverage Check

| Spec section | Task |
|---|---|
| S1 missing RAW extensions | Task 1 |
| S2 state model (detection, per-folder, non-persisted, two-way toggle) | Task 3 |
| S3 `recycleTrashed`, `.trash` creation, collision suffix, sidecars, per-file failure isolation | Task 2 |
| S3 dispatch by mode, folder reload | Task 3 |
| S4 failures never silent, AlertDialog | Tasks 3 (collect) + 5 (present) |
| S5.1 icons and colours | Tasks 4 (action bar) + 6 (sidebar) |
| S5.2 right-click toggle, unchanged left-click and `X` key | Task 4 |
| S5.3 no mode dialog (tooltip only) | Task 4 (nothing to build) |
| S5.4 menu label follows mode, position unchanged | Task 6 |
| S5.5 SnackBar 2.5s + reveal in Finder | Task 5 |
| AC 1–6 | Tasks 1–6 |
| AC 7 red-before-green | every task's Step 2 |
| AC 8 `flutter test` green | Task 6 Step 4 |
| AC 9 live run | Task 7 |

**Out of scope, deliberately absent from every task:** restore-from-`.trash` UI, `.trash` auto-cleanup, mode persistence, automatic fallback when the system trash fails, permanent delete, and any change to `processStarred`.
