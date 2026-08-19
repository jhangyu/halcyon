# EXIF Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Batch-rename every photo in the open folder from its EXIF metadata, driven by a preset or a user-composed rule, undoable, at 10,000-file scale.

**Architecture:** A pure template renderer (`RenameRule`) and a pure planner (`planRenames`) do all the thinking and are fully unit-testable; a thin applier does serial `File.rename` calls and appends to a JSON Lines undo log. EXIF comes from a new `halcyon/exif` MethodChannel on macOS (batch, native-parallel, header-only) with an `exif`-package fallback elsewhere, injected into `AppState` as a typedef so tests never touch a platform channel — the same seam pattern as `DngFullDecoder`.

**Tech Stack:** Flutter 3.35 / Dart 3.9, `provider`, `path`, new dep `exif`, Swift (macOS runner), `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-08-19-exif-rename-design.md` (approved). Chosen UI mockup: `docs/mockups/exif-rename/variant-2-twopane.html`.

## Global Constraints

- `flutter analyze` must report **0 issues** before any task is considered done.
- Every new test file goes in `test/`, named `<subject>_test.dart`, matching the style of `test/thumbnail_export_service_test.dart` (temp dir in `setUp`, deleted in `tearDown`).
- Commits follow Conventional Commits (`feat:`/`fix:`/`docs:`/`test:`/`refactor:`).
- No new dependency other than `exif` (Task 3).
- Never overwrite an existing file during rename. A collision that survives planning gets a `-1`/`-2` suffix.
- Reserved keys in `.halcyon_status.json` are `_last_viewed_id` and `_rename_rule`. Any code that rebuilds that map must carry both forward.
- Do not touch `lib/services/image_preload_controller.dart`, `lib/services/native_thumbnail_service.dart`, or `lib/views/zoom_controller.dart` — unrelated subsystems.
- All user-visible strings in the status line are Traditional Chinese with `*…*` marking the amber emphasis span (see `StatusMessage`); dialog labels are English, matching the mockup.

---

### Task 1: `RenameRule` — template parsing and rendering

**Files:**
- Create: `lib/services/rename_rule.dart`
- Create: `test/rename_rule_test.dart`

**Interfaces:**
- Consumes: nothing (leaf module).
- Produces:
  - `class ExifMetadata` with named-optional const constructor and fields `DateTime? captureDate`, `String? camera, lens, make, artist, shutter`, `double? aperture, focalLength, gpsImgDirection`, `int? iso`.
  - `class RenameRule` with `const RenameRule(String template)`, `String get template`, `String? get error`, and
    `String render({required ExifMetadata? meta, required DateTime fileModified, required String originalBase, required int seq})`.
  - `RenameRule.kDefaultTemplate`, `RenameRule.presets` (`List<({String label, String template})>`), `RenameRule.variableGroups` (`List<({String title, List<String> tokens})>`).

- [ ] **Step 1: Write the failing test**

Create `test/rename_rule_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/rename_rule.dart';

const _meta = ExifMetadata(
  captureDate: null,
  camera: 'ILCE-7M4',
  lens: 'FE 24-70mm F2.8 GM',
  make: 'SONY',
  artist: 'Jhang Yu',
  aperture: 2.8,
  focalLength: 35,
  iso: 400,
  shutter: '1/250',
  gpsImgDirection: 127.4,
);

void main() {
  final captured = DateTime(2026, 4, 7, 9, 3, 5);
  final mtime = DateTime(2020, 1, 2, 3, 4, 5);

  ExifMetadata metaWithDate(DateTime? d) => ExifMetadata(
    captureDate: d,
    camera: _meta.camera,
    lens: _meta.lens,
    make: _meta.make,
    artist: _meta.artist,
    aperture: _meta.aperture,
    focalLength: _meta.focalLength,
    iso: _meta.iso,
    shutter: _meta.shutter,
    gpsImgDirection: _meta.gpsImgDirection,
  );

  String render(String template, {ExifMetadata? meta, int seq = 1}) {
    return RenameRule(template).render(
      meta: meta ?? metaWithDate(captured),
      fileModified: mtime,
      originalBase: 'DSC_0431',
      seq: seq,
    );
  }

  test('TC-024 default template renders zero-padded date and time', () {
    expect(
      render(RenameRule.kDefaultTemplate),
      '2026-04-07-09-03-05',
    );
  });

  test('TC-025 {seq} defaults to one digit, {seq:3} zero-pads to three', () {
    expect(render('{YYYY}_{seq}', seq: 7), '2026_7');
    expect(render('{YYYY}_{seq:3}', seq: 7), '2026_007');
    expect(render('{YYYY}_{seq:3}', seq: 1234), '2026_1234');
  });

  test('TC-026 missing capture date falls back to file mtime', () {
    expect(
      render(RenameRule.kDefaultTemplate, meta: metaWithDate(null)),
      '2020-01-02-03-04-05',
    );
    expect(
      render(RenameRule.kDefaultTemplate, meta: null),
      '2020-01-02-03-04-05',
    );
  });

  test('TC-027 non-date variables render, missing ones render empty', () {
    expect(render('{camera}'), 'ILCE-7M4');
    expect(render('{lens}'), 'FE 24-70mm F2.8 GM');
    expect(render('{make}_{artist}'), 'SONY_Jhang Yu');
    expect(render('{f}'), 'f2.8');
    expect(render('{focal}'), '35mm');
    expect(render('{iso}'), 'ISO400');
    expect(render('{shutter}'), '1_250');
    expect(render('{direction}'), '127');
    expect(render('{orig}'), 'DSC_0431');
    expect(
      render('x{camera}y', meta: const ExifMetadata(captureDate: null)),
      'xy',
    );
  });

  test('TC-028 path-hostile characters are replaced, edges trimmed', () {
    expect(render(' a/b:c '), 'a_b_c');
    expect(render('..name..'), 'name');
  });

  test('TC-029 unknown variable and empty result are reported as errors', () {
    expect(const RenameRule('{fstop}').error, isNotNull);
    expect(const RenameRule('').error, isNotNull);
    expect(const RenameRule('{YYYY}-{seq:2}').error, isNull);
    expect(RenameRule(RenameRule.kDefaultTemplate).error, isNull);
  });

  test('TC-030 every preset is a valid template and the default is first', () {
    expect(RenameRule.presets.first.template, RenameRule.kDefaultTemplate);
    for (final preset in RenameRule.presets) {
      expect(RenameRule(preset.template).error, isNull, reason: preset.label);
    }
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/rename_rule_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:halcyon_flutter/services/rename_rule.dart'`.

- [ ] **Step 3: Write the implementation**

Create `lib/services/rename_rule.dart`:

```dart
/// EXIF fields this feature can put into a filename. Read once per
/// [PhotoItem] (from its JPG sibling when there is one) and shared by every
/// file in that group.
class ExifMetadata {
  const ExifMetadata({
    this.captureDate,
    this.camera,
    this.lens,
    this.make,
    this.artist,
    this.shutter,
    this.aperture,
    this.focalLength,
    this.gpsImgDirection,
    this.iso,
  });

  final DateTime? captureDate;
  final String? camera;
  final String? lens;
  final String? make;
  final String? artist;
  final String? shutter;
  final double? aperture;
  final double? focalLength;
  final double? gpsImgDirection;
  final int? iso;
}

/// A filename template such as `{YYYY}-{MM}-{DD}-{hh}-{mm}-{ss}`.
///
/// Pure: rendering never touches the filesystem, so the whole naming policy
/// is unit-testable without photos. `{seq}` is supplied by the caller
/// (`planRenames`), which is the only place that can know how many items
/// collide on the same rendered name.
class RenameRule {
  const RenameRule(this.template);

  final String template;

  static const String kDefaultTemplate = '{YYYY}-{MM}-{DD}-{hh}-{mm}-{ss}';

  static const List<({String label, String template})> presets = [
    (label: 'Date & time', template: kDefaultTemplate),
    (label: 'Compact', template: '{YYYY}{MM}{DD}_{hh}{mm}{ss}'),
    (label: 'Camera-style', template: 'IMG_{YYYY}{MM}{DD}_{hh}{mm}{ss}'),
    (label: 'Date + sequence', template: '{YYYY}-{MM}-{DD}_{seq}'),
  ];

  static const List<({String title, List<String> tokens})> variableGroups = [
    (
      title: 'Date/time',
      tokens: ['{YYYY}', '{MM}', '{DD}', '{hh}', '{mm}', '{ss}'],
    ),
    (title: 'Camera', tokens: ['{camera}', '{lens}', '{make}', '{artist}']),
    (
      title: 'Shooting',
      tokens: ['{f}', '{focal}', '{iso}', '{shutter}', '{direction}'],
    ),
    (title: 'File', tokens: ['{seq}', '{orig}']),
  ];

  static final RegExp _token = RegExp(r'\{(\w+)(?::(\d+))?\}');

  static const Set<String> _known = {
    'YYYY', 'MM', 'DD', 'hh', 'mm', 'ss',
    'camera', 'lens', 'make', 'artist',
    'f', 'focal', 'iso', 'shutter', 'direction',
    'seq', 'orig',
  };

  /// Null when the template is usable; otherwise a message for the dialog.
  String? get error {
    if (template.trim().isEmpty) return 'Rule is empty';
    for (final match in _token.allMatches(template)) {
      final name = match.group(1)!;
      if (!_known.contains(name)) return 'Unknown variable {$name}';
    }
    final probe = render(
      meta: null,
      fileModified: DateTime(2000),
      originalBase: 'x',
      seq: 1,
    );
    if (probe.isEmpty) return 'Rule produces an empty filename';
    return null;
  }

  /// Renders the new basename (no extension). [seq] is 1-based.
  String render({
    required ExifMetadata? meta,
    required DateTime fileModified,
    required String originalBase,
    required int seq,
  }) {
    final date = meta?.captureDate ?? fileModified;
    final out = template.replaceAllMapped(_token, (match) {
      final name = match.group(1)!;
      final width = int.tryParse(match.group(2) ?? '') ?? 1;
      return switch (name) {
        'YYYY' => _pad(date.year, 4),
        'MM' => _pad(date.month, 2),
        'DD' => _pad(date.day, 2),
        'hh' => _pad(date.hour, 2),
        'mm' => _pad(date.minute, 2),
        'ss' => _pad(date.second, 2),
        'camera' => meta?.camera ?? '',
        'lens' => meta?.lens ?? '',
        'make' => meta?.make ?? '',
        'artist' => meta?.artist ?? '',
        'f' => meta?.aperture == null ? '' : 'f${_trim(meta!.aperture!)}',
        'focal' => meta?.focalLength == null
            ? ''
            : '${_trim(meta!.focalLength!)}mm',
        'iso' => meta?.iso == null ? '' : 'ISO${meta!.iso}',
        'shutter' => meta?.shutter ?? '',
        'direction' => meta?.gpsImgDirection == null
            ? ''
            : meta!.gpsImgDirection!.round().toString(),
        'seq' => _pad(seq, width),
        'orig' => originalBase,
        _ => match.group(0)!,
      };
    });
    return sanitise(out);
  }

  /// Strips what a filename cannot carry. `:` is a path separator to the
  /// classic Mac OS layer and shows up as `/` in Finder, so it goes too, and
  /// `1/250` shutter speeds would otherwise create a subdirectory.
  static String sanitise(String value) {
    final replaced = value.replaceAll(RegExp(r'[/:\x00\\]'), '_');
    return replaced.replaceAll(RegExp(r'^[\s.]+|[\s.]+$'), '');
  }

  static String _pad(int value, int width) =>
      value.toString().padLeft(width, '0');

  /// 2.8 -> "2.8", 35.0 -> "35".
  static String _trim(double value) {
    return value == value.roundToDouble()
        ? value.round().toString()
        : value.toString();
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `flutter test test/rename_rule_test.dart`
Expected: PASS, `+7: All tests passed!`

- [ ] **Step 5: Analyze and commit**

```bash
flutter analyze
git add lib/services/rename_rule.dart test/rename_rule_test.dart
git commit -m "feat: add EXIF filename template renderer"
```

Expected: `flutter analyze` prints `No issues found!`

---

### Task 2: `planRenames` — collision-free rename planning

**Files:**
- Create: `lib/services/rename_service.dart`
- Create: `test/rename_service_test.dart`

**Interfaces:**
- Consumes: `RenameRule`, `ExifMetadata` from Task 1; `PhotoItem` from `lib/models/photo_item.dart` (fields: `String id`, `List<File> files`, `PhotoStatus status`).
- Produces:
  - `class RenameMove { const RenameMove({required this.from, required this.to}); final String from, to; }` (both are absolute paths)
  - `class RenamePlan { const RenamePlan({required this.oldId, required this.newId, required this.moves}); final String oldId, newId; final List<RenameMove> moves; }`
  - `List<RenamePlan> planRenames({required List<PhotoItem> items, required Map<String, ExifMetadata?> metadata, required Map<String, DateTime> fileModified, required RenameRule rule, required Set<String> existingNames})`
    — `metadata` and `fileModified` are keyed by `PhotoItem.id`; `existingNames` is every filename already in the folder (including `._` sidecars).

- [ ] **Step 1: Write the failing test**

Create `test/rename_service_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/rename_rule.dart';
import 'package:halcyon_flutter/services/rename_service.dart';
import 'package:path/path.dart' as p;

void main() {
  const dir = '/photos';
  final mtime = DateTime(2020, 1, 2, 3, 4, 5);

  PhotoItem item(String id, List<String> names) => PhotoItem(
    id: id,
    files: names.map((n) => File(p.join(dir, n))).toList(),
  );

  ExifMetadata at(DateTime d) => ExifMetadata(captureDate: d, camera: 'X-T5');

  List<RenamePlan> plan(
    List<PhotoItem> items, {
    required Map<String, ExifMetadata?> metadata,
    String template = RenameRule.kDefaultTemplate,
    Set<String> existing = const {},
  }) {
    return planRenames(
      items: items,
      metadata: metadata,
      fileModified: {for (final i in items) i.id: mtime},
      rule: RenameRule(template),
      existingNames: existing,
    );
  }

  test('TC-031 sibling RAW + JPG + sidecar all get the same new base', () {
    final plans = plan(
      [item('DSC_0431', ['DSC_0431.NEF', 'DSC_0431.JPG'])],
      metadata: {'DSC_0431': at(DateTime(2026, 4, 7, 9, 3, 5))},
      existing: {'DSC_0431.NEF', 'DSC_0431.JPG', '._DSC_0431.NEF'},
    );

    expect(plans.single.newId, '2026-04-07-09-03-05');
    // Each file is followed by its own sidecar, so the NEF's `._` companion
    // sits between the NEF and the JPG.
    expect(plans.single.moves.map((m) => p.basename(m.to)), [
      '2026-04-07-09-03-05.NEF',
      '._2026-04-07-09-03-05.NEF',
      '2026-04-07-09-03-05.JPG',
    ]);
    expect(plans.single.moves.first.from, p.join(dir, 'DSC_0431.NEF'));
  });

  test('TC-032 same-second items with {seq} number in original-name order', () {
    final shot = DateTime(2026, 4, 7, 9, 3, 5);
    final plans = plan(
      [
        item('B', ['B.JPG']),
        item('A', ['A.JPG']),
      ],
      metadata: {'B': at(shot), 'A': at(shot)},
      template: '{YYYY}{MM}{DD}_{seq:3}',
    );

    expect(plans.map((x) => x.newId), ['20260407_002', '20260407_001']);
  });

  test('TC-033 collision without {seq} falls back to -1/-2', () {
    final shot = DateTime(2026, 4, 7, 9, 3, 5);
    final plans = plan(
      [
        item('A', ['A.JPG']),
        item('B', ['B.JPG']),
        item('C', ['C.JPG']),
      ],
      metadata: {'A': at(shot), 'B': at(shot), 'C': at(shot)},
    );

    expect(plans.map((x) => x.newId), [
      '2026-04-07-09-03-05',
      '2026-04-07-09-03-05-1',
      '2026-04-07-09-03-05-2',
    ]);
  });

  test('TC-034 a name already in the folder is never reused', () {
    final plans = plan(
      [item('A', ['A.JPG'])],
      metadata: {'A': at(DateTime(2026, 4, 7, 9, 3, 5))},
      existing: {'A.JPG', '2026-04-07-09-03-05.JPG'},
    );

    expect(plans.single.newId, '2026-04-07-09-03-05-1');
  });

  test('TC-035 an item already named correctly produces no moves', () {
    final plans = plan(
      [item('2026-04-07-09-03-05', ['2026-04-07-09-03-05.JPG'])],
      metadata: {'2026-04-07-09-03-05': at(DateTime(2026, 4, 7, 9, 3, 5))},
      existing: {'2026-04-07-09-03-05.JPG'},
    );

    expect(plans, isEmpty);
  });

  test('TC-036 missing metadata still renames, using file mtime', () {
    final plans = plan(
      [item('A', ['A.JPG'])],
      metadata: {'A': null},
    );

    expect(plans.single.newId, '2020-01-02-03-04-05');
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/rename_service_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:halcyon_flutter/services/rename_service.dart'`.

- [ ] **Step 3: Write the implementation**

Create `lib/services/rename_service.dart`:

```dart
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/photo_item.dart';
import 'rename_rule.dart';

/// One file to move. Both paths are absolute.
class RenameMove {
  const RenameMove({required this.from, required this.to});

  final String from;
  final String to;
}

/// Every move needed to rename one [PhotoItem] group, plus the id change so
/// the caller can remap persisted per-photo state.
class RenamePlan {
  const RenamePlan({
    required this.oldId,
    required this.newId,
    required this.moves,
  });

  final String oldId;
  final String newId;
  final List<RenameMove> moves;
}

/// Builds the full rename batch. Pure — no filesystem access, so the naming
/// policy is testable without photos on disk.
///
/// [metadata] and [fileModified] are keyed by [PhotoItem.id]. [existingNames]
/// is every filename currently in the folder, sidecars included; planned names
/// are checked against it AND against names claimed earlier in this batch, so
/// a rename can never land on a file that exists or is about to exist.
///
/// Items whose rendered name already equals their current id are dropped: a
/// no-op rename is not worth an entry in the undo log.
List<RenamePlan> planRenames({
  required List<PhotoItem> items,
  required Map<String, ExifMetadata?> metadata,
  required Map<String, DateTime> fileModified,
  required RenameRule rule,
  required Set<String> existingNames,
}) {
  final fallbackDate = DateTime.fromMillisecondsSinceEpoch(0);

  String renderFor(PhotoItem item, int seq) => rule.render(
    meta: metadata[item.id],
    fileModified: fileModified[item.id] ?? fallbackDate,
    originalBase: item.id,
    seq: seq,
  );

  // Group by the seq=1 rendering: items sharing that string are exactly the
  // ones that need distinct sequence numbers.
  final groups = <String, List<PhotoItem>>{};
  for (final item in items) {
    groups.putIfAbsent(renderFor(item, 1), () => []).add(item);
  }

  final taken = <String>{...existingNames.map(_baseOf)};
  final plans = <RenamePlan>[];

  for (final item in items) {
    final group = groups[renderFor(item, 1)]!;
    // Deterministic numbering regardless of scan order.
    final ordered = [...group]..sort((a, b) => a.id.compareTo(b.id));
    final seq = ordered.indexOf(item) + 1;

    var candidate = renderFor(item, seq);
    if (candidate == item.id) {
      continue;
    }
    if (taken.contains(candidate)) {
      var suffix = 1;
      while (taken.contains('$candidate-$suffix')) {
        suffix++;
      }
      candidate = '$candidate-$suffix';
    }
    taken.add(candidate);

    final moves = <RenameMove>[];
    for (final file in item.files) {
      final name = p.basename(file.path);
      final ext = p.extension(name);
      moves.add(
        RenameMove(
          from: file.path,
          to: p.join(file.parent.path, '$candidate$ext'),
        ),
      );
      if (existingNames.contains('._$name')) {
        moves.add(
          RenameMove(
            from: p.join(file.parent.path, '._$name'),
            to: p.join(file.parent.path, '._$candidate$ext'),
          ),
        );
      }
    }

    plans.add(
      RenamePlan(oldId: item.id, newId: candidate, moves: moves),
    );
  }

  return plans;
}

/// `._DSC_0431.NEF` and `DSC_0431.NEF` both occupy the base `DSC_0431`.
String _baseOf(String filename) {
  final withoutSidecar = filename.startsWith('._')
      ? filename.substring(2)
      : filename;
  return p.basenameWithoutExtension(withoutSidecar);
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `flutter test test/rename_service_test.dart`
Expected: PASS, `+6: All tests passed!`

- [ ] **Step 5: Analyze and commit**

```bash
flutter analyze
git add lib/services/rename_service.dart test/rename_service_test.dart
git commit -m "feat: plan collision-free EXIF renames"
```

Expected: `No issues found!`

---

### Task 3: `applyRenames` + undo log

**Files:**
- Modify: `lib/services/rename_service.dart` (append to the file from Task 2)
- Modify: `test/rename_service_test.dart` (append a new `group`)

**Interfaces:**
- Consumes: `RenamePlan`, `RenameMove` from Task 2.
- Produces:
  - `const String kRenameLogName = '.halcyon_rename_log.jsonl';`
  - `class RenameOutcome { const RenameOutcome({required this.renamedCount, required this.failures, required this.cancelled}); final int renamedCount; final List<String> failures; final bool cancelled; }`
  - `Future<RenameOutcome> applyRenames(List<RenamePlan> plans, Directory dir, {void Function(int done, int total)? onProgress, bool Function()? isCancelled})`
  - `Future<RenameOutcome> undoLastRename(Directory dir)`

- [ ] **Step 1: Write the failing test**

Append to `test/rename_service_test.dart` (inside `main()`, after the existing tests):

```dart
  group('apply + undo', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('halcyon_rename_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    Future<File> touch(String name) async {
      final f = File(p.join(tempDir.path, name));
      await f.writeAsString(name);
      return f;
    }

    RenamePlan planFor(String oldBase, String newBase, List<String> exts) {
      return RenamePlan(
        oldId: oldBase,
        newId: newBase,
        moves: [
          for (final ext in exts)
            RenameMove(
              from: p.join(tempDir.path, '$oldBase$ext'),
              to: p.join(tempDir.path, '$newBase$ext'),
            ),
        ],
      );
    }

    test('TC-037 renames every file and reports progress', () async {
      await touch('A.NEF');
      await touch('A.JPG');
      await touch('B.JPG');
      final progress = <int>[];

      final outcome = await applyRenames(
        [planFor('A', 'new-A', ['.NEF', '.JPG']), planFor('B', 'new-B', ['.JPG'])],
        tempDir,
        onProgress: (done, total) {
          expect(total, 2);
          progress.add(done);
        },
      );

      expect(outcome.renamedCount, 2);
      expect(outcome.failures, isEmpty);
      expect(outcome.cancelled, isFalse);
      expect(progress, [1, 2]);
      expect(File(p.join(tempDir.path, 'new-A.NEF')).existsSync(), isTrue);
      expect(File(p.join(tempDir.path, 'new-A.JPG')).existsSync(), isTrue);
      expect(File(p.join(tempDir.path, 'new-B.JPG')).existsSync(), isTrue);
      expect(File(p.join(tempDir.path, 'A.NEF')).existsSync(), isFalse);
    });

    test('TC-038 undo restores every original name and drops the log',
        () async {
      await touch('A.NEF');
      await touch('B.JPG');
      await applyRenames(
        [planFor('A', 'new-A', ['.NEF']), planFor('B', 'new-B', ['.JPG'])],
        tempDir,
      );

      final outcome = await undoLastRename(tempDir);

      expect(outcome.renamedCount, 2);
      expect(File(p.join(tempDir.path, 'A.NEF')).existsSync(), isTrue);
      expect(File(p.join(tempDir.path, 'B.JPG')).existsSync(), isTrue);
      expect(File(p.join(tempDir.path, 'new-A.NEF')).existsSync(), isFalse);
      expect(
        File(p.join(tempDir.path, kRenameLogName)).existsSync(),
        isFalse,
      );
    });

    test('TC-039 a missing source is a failure, not an aborted batch',
        () async {
      await touch('B.JPG');

      final outcome = await applyRenames(
        [planFor('A', 'new-A', ['.NEF']), planFor('B', 'new-B', ['.JPG'])],
        tempDir,
      );

      expect(outcome.renamedCount, 1);
      expect(outcome.failures, hasLength(1));
      expect(outcome.failures.single, contains('A.NEF'));
      expect(File(p.join(tempDir.path, 'new-B.JPG')).existsSync(), isTrue);
    });

    test('TC-040 cancel stops the batch and leaves a replayable log',
        () async {
      await touch('A.JPG');
      await touch('B.JPG');
      var seen = 0;

      final outcome = await applyRenames(
        [planFor('A', 'new-A', ['.JPG']), planFor('B', 'new-B', ['.JPG'])],
        tempDir,
        isCancelled: () => seen++ > 0,
      );

      expect(outcome.cancelled, isTrue);
      expect(outcome.renamedCount, 1);
      expect(File(p.join(tempDir.path, 'new-A.JPG')).existsSync(), isTrue);
      expect(File(p.join(tempDir.path, 'B.JPG')).existsSync(), isTrue);

      await undoLastRename(tempDir);
      expect(File(p.join(tempDir.path, 'A.JPG')).existsSync(), isTrue);
    });
  });
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/rename_service_test.dart`
Expected: FAIL — `Undefined name 'applyRenames'` / `'undoLastRename'` / `'kRenameLogName'`.

- [ ] **Step 3: Write the implementation**

Append to `lib/services/rename_service.dart` (and add `import 'dart:convert';` at the top):

```dart
/// Append-only undo journal, one JSON object per line. Deliberately NOT a
/// single JSON array: rewriting a growing array once per plan would be
/// O(n^2) at 10,000 photos, an append is O(n) and survives a crash mid-batch.
const String kRenameLogName = '.halcyon_rename_log.jsonl';

/// Result of a rename batch. [failures] entries are `"<filename>: <error>"`,
/// mirroring `RecycleOutcome` — a silently failed rename looks identical to a
/// broken app.
class RenameOutcome {
  const RenameOutcome({
    required this.renamedCount,
    required this.failures,
    required this.cancelled,
  });

  final int renamedCount;
  final List<String> failures;
  final bool cancelled;
}

/// Executes [plans] serially. Rename is a same-volume metadata operation, so
/// parallelism buys nothing here and would turn the planner's collision
/// avoidance into a race.
///
/// Each plan's moves are journalled to [kRenameLogName] as they land, so a
/// cancel or a crash still leaves an undoable record. [isCancelled] is polled
/// before each plan; a cancelled batch keeps everything already renamed.
Future<RenameOutcome> applyRenames(
  List<RenamePlan> plans,
  Directory dir, {
  void Function(int done, int total)? onProgress,
  bool Function()? isCancelled,
}) async {
  final log = File(p.join(dir.path, kRenameLogName));
  final sink = log.openWrite(mode: FileMode.write);
  final failures = <String>[];
  var renamed = 0;
  var cancelled = false;

  try {
    for (final plan in plans) {
      if (isCancelled?.call() ?? false) {
        cancelled = true;
        break;
      }
      try {
        for (final move in plan.moves) {
          await File(move.from).rename(move.to);
          sink.writeln(json.encode({'from': move.from, 'to': move.to}));
        }
        renamed++;
      } catch (e) {
        failures.add('${p.basename(plan.moves.first.from)}: $e');
      }
      onProgress?.call(renamed + failures.length, plans.length);
    }
  } finally {
    await sink.flush();
    await sink.close();
  }

  return RenameOutcome(
    renamedCount: renamed,
    failures: failures,
    cancelled: cancelled,
  );
}

/// Replays [kRenameLogName] backwards, then deletes it. Missing entries are
/// reported rather than thrown: a file the user moved away by hand should not
/// block the rest of the undo.
Future<RenameOutcome> undoLastRename(Directory dir) async {
  final log = File(p.join(dir.path, kRenameLogName));
  if (!await log.exists()) {
    return const RenameOutcome(
      renamedCount: 0,
      failures: [],
      cancelled: false,
    );
  }

  final lines = (await log.readAsLines())
      .where((line) => line.trim().isNotEmpty)
      .toList()
      .reversed;
  final failures = <String>[];
  var restored = 0;

  for (final line in lines) {
    final entry = json.decode(line) as Map<String, dynamic>;
    final from = entry['from'] as String;
    final to = entry['to'] as String;
    try {
      await File(to).rename(from);
      restored++;
    } catch (e) {
      failures.add('${p.basename(to)}: $e');
    }
  }

  await log.delete();
  return RenameOutcome(
    renamedCount: restored,
    failures: failures,
    cancelled: false,
  );
}
```

Note on TC-038: `renamedCount` counts restored **files**, not items — the test's two plans move one file each, so it is 2 either way.

- [ ] **Step 4: Run the test to verify it passes**

Run: `flutter test test/rename_service_test.dart`
Expected: PASS, `+10: All tests passed!`

- [ ] **Step 5: Analyze and commit**

```bash
flutter analyze
git add lib/services/rename_service.dart test/rename_service_test.dart
git commit -m "feat: apply renames with an append-only undo journal"
```

Expected: `No issues found!`

---

### Task 4: `PhotoStatusStore` — id remap and rule persistence

**Files:**
- Modify: `lib/services/photo_status_store.dart`
- Create: `test/photo_status_store_test.dart`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `Future<String?> loadRenameRule(Directory dir)`
  - `Future<void> saveRenameRule(Directory dir, String? rule)` — `null` deletes the key
  - `Future<void> remapKeys(Directory dir, Map<String, String> oldToNew)` — rewrites photo keys and `_last_viewed_id`
  - `PhotoStatusStore.reservedKeys` (`Set<String>`), containing `_last_viewed_id` and `_rename_rule`

- [ ] **Step 1: Write the failing test**

Create `test/photo_status_store_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/services/photo_status_store.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;
  final store = PhotoStatusStore();

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('halcyon_status_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<Map<String, dynamic>> readJson() async {
    final file = store.statusFileFor(tempDir);
    return json.decode(await file.readAsString()) as Map<String, dynamic>;
  }

  PhotoItem item(String id, PhotoStatus status) =>
      PhotoItem(id: id, files: [File(p.join(tempDir.path, '$id.JPG'))], status: status);

  test('TC-041 a custom rule survives a round trip', () async {
    await store.saveRenameRule(tempDir, '{YYYY}_{seq:3}');
    expect(await store.loadRenameRule(tempDir), '{YYYY}_{seq:3}');

    await store.saveRenameRule(tempDir, null);
    expect(await store.loadRenameRule(tempDir), isNull);
  });

  test('TC-042 saveStatuses preserves _last_viewed_id and _rename_rule',
      () async {
    await store.saveRenameRule(tempDir, '{YYYY}');
    await store.saveLastViewedId(tempDir, 'A');

    await store.saveStatuses(tempDir, [item('A', PhotoStatus.starred)]);

    final map = await readJson();
    expect(map['A'], 'starred');
    expect(map['_last_viewed_id'], 'A');
    expect(map['_rename_rule'], '{YYYY}');
  });

  test('TC-043 applySavedStatuses does not treat _rename_rule as a stale key',
      () async {
    await store.saveStatuses(tempDir, [item('A', PhotoStatus.starred)]);
    await store.saveRenameRule(tempDir, '{YYYY}');

    await store.applySavedStatuses(tempDir, [item('A', PhotoStatus.unmarked)]);

    expect((await readJson())['_rename_rule'], '{YYYY}');
  });

  test('TC-044 remapKeys moves marks and the last-viewed id to new ids',
      () async {
    await store.saveStatuses(tempDir, [
      item('A', PhotoStatus.starred),
      item('B', PhotoStatus.trashed),
    ]);
    await store.saveLastViewedId(tempDir, 'B');
    await store.saveRenameRule(tempDir, '{YYYY}');

    await store.remapKeys(tempDir, {'A': '2026-01-01', 'B': '2026-01-02'});

    final map = await readJson();
    expect(map['2026-01-01'], 'starred');
    expect(map['2026-01-02'], 'trashed');
    expect(map.containsKey('A'), isFalse);
    expect(map['_last_viewed_id'], '2026-01-02');
    expect(map['_rename_rule'], '{YYYY}');
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/photo_status_store_test.dart`
Expected: FAIL — `The method 'saveRenameRule' isn't defined for the type 'PhotoStatusStore'`.

- [ ] **Step 3: Write the implementation**

In `lib/services/photo_status_store.dart`, add the reserved-key set as a static member of `PhotoStatusStore` and use it everywhere the map is rebuilt:

```dart
  /// Keys in `.halcyon_status.json` that are NOT photo ids. Anything that
  /// rebuilds the map must carry all of them forward, or a later star silently
  /// drops the saved rename rule.
  static const Set<String> reservedKeys = {'_last_viewed_id', '_rename_rule'};

  static const String _renameRuleKey = '_rename_rule';
```

Replace the `_last_viewed_id`-only carry-forward inside `saveStatuses` with:

```dart
    if (await file.exists()) {
      final existingContent = await file.readAsString();
      final existingJson = json.decode(existingContent) as Map<String, dynamic>;
      for (final key in reservedKeys) {
        final value = existingJson[key];
        if (value is String) statusMap[key] = value;
      }
    }
```

Replace the stale-key scan inside `applySavedStatuses` with:

```dart
    for (final key in jsonMap.keys) {
      if (!reservedKeys.contains(key) && !validKeys.contains(key)) {
        needsCleanup = true;
        break;
      }
    }
```

Then append these three methods to the class:

```dart
  Future<String?> loadRenameRule(Directory dir) async {
    final file = statusFileFor(dir);
    if (!await file.exists()) return null;
    final jsonMap =
        json.decode(await file.readAsString()) as Map<String, dynamic>;
    final rule = jsonMap[_renameRuleKey];
    return rule is String ? rule : null;
  }

  /// Persists the folder's custom rename rule; [rule] == null removes it
  /// (which is what picking a built-in preset does).
  Future<void> saveRenameRule(Directory dir, String? rule) async {
    final file = statusFileFor(dir);
    final jsonMap = await _readMap(file);
    if (rule == null) {
      jsonMap.remove(_renameRuleKey);
    } else {
      jsonMap[_renameRuleKey] = rule;
    }
    await file.writeAsString(json.encode(jsonMap));
  }

  /// Rewrites photo keys after a rename batch. Without this, every star and
  /// the last-viewed pointer would be orphaned the moment files are renamed,
  /// because this file is keyed by [PhotoItem.id] (the basename).
  Future<void> remapKeys(Directory dir, Map<String, String> oldToNew) async {
    final file = statusFileFor(dir);
    if (!await file.exists() || oldToNew.isEmpty) return;

    final jsonMap = await _readMap(file);
    final remapped = <String, dynamic>{};
    for (final entry in jsonMap.entries) {
      if (reservedKeys.contains(entry.key)) {
        remapped[entry.key] = entry.key == '_last_viewed_id'
            ? (oldToNew[entry.value] ?? entry.value)
            : entry.value;
      } else {
        remapped[oldToNew[entry.key] ?? entry.key] = entry.value;
      }
    }
    await file.writeAsString(json.encode(remapped));
  }

  Future<Map<String, dynamic>> _readMap(File file) async {
    if (!await file.exists()) return <String, dynamic>{};
    return json.decode(await file.readAsString()) as Map<String, dynamic>;
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/photo_status_store_test.dart test/app_state_test.dart`
Expected: PASS for both files — `app_state_test.dart` is included because it exercises the status-file round trip and must not regress.

- [ ] **Step 5: Analyze and commit**

```bash
flutter analyze
git add lib/services/photo_status_store.dart test/photo_status_store_test.dart
git commit -m "feat: persist rename rule and remap status keys"
```

Expected: `No issues found!`

---

### Task 5: `ExifMetadataService` — batch read over the channel, with a Dart fallback

**Files:**
- Create: `lib/services/exif_metadata_service.dart`
- Create: `test/exif_metadata_service_test.dart`
- Modify: `pubspec.yaml` (add `exif: ^3.3.0` under `dependencies`, after `dng_processor`)

**Interfaces:**
- Consumes: `ExifMetadata` from Task 1 (`lib/services/rename_rule.dart`).
- Produces:
  - `typedef ExifBatchReader = Future<List<ExifMetadata?>> Function(List<String> paths);`
  - `class ExifMetadataService { static const MethodChannel channel = MethodChannel('halcyon/exif'); static Future<List<ExifMetadata?>> readBatch(List<String> paths); static ExifMetadata? metadataFromMap(Map<Object?, Object?>? map); static Future<ExifMetadata?> readWithPackage(String path); }`
  - `const int kExifChunkSize = 500;`

The channel returns, per path, either `null` or a map with the keys
`captureDate` (String, `yyyy:MM:dd HH:mm:ss`), `camera`, `lens`, `make`,
`artist`, `shutter` (String), `aperture`, `focalLength`, `direction` (double),
`iso` (int). `metadataFromMap` is the single place that shape is decoded, which
is why it is public and directly tested — a widget test cannot exercise the
real channel.

- [ ] **Step 1: Write the failing test**

Create `test/exif_metadata_service_test.dart`:

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/services/exif_metadata_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('TC-045 decodes a full native map', () {
    final meta = ExifMetadataService.metadataFromMap({
      'captureDate': '2026:04:07 09:03:05',
      'camera': 'ILCE-7M4',
      'lens': 'FE 24-70mm F2.8 GM',
      'make': 'SONY',
      'artist': 'Jhang Yu',
      'shutter': '1/250',
      'aperture': 2.8,
      'focalLength': 35.0,
      'direction': 127.4,
      'iso': 400,
    });

    expect(meta!.captureDate, DateTime(2026, 4, 7, 9, 3, 5));
    expect(meta.camera, 'ILCE-7M4');
    expect(meta.lens, 'FE 24-70mm F2.8 GM');
    expect(meta.make, 'SONY');
    expect(meta.artist, 'Jhang Yu');
    expect(meta.shutter, '1/250');
    expect(meta.aperture, 2.8);
    expect(meta.focalLength, 35.0);
    expect(meta.gpsImgDirection, 127.4);
    expect(meta.iso, 400);
  });

  test('TC-046 a null map, a missing date and a junk date all degrade', () {
    expect(ExifMetadataService.metadataFromMap(null), isNull);

    final empty = ExifMetadataService.metadataFromMap({});
    expect(empty, isNotNull);
    expect(empty!.captureDate, isNull);
    expect(empty.camera, isNull);

    final junk = ExifMetadataService.metadataFromMap({'captureDate': 'nope'});
    expect(junk!.captureDate, isNull);
  });

  test('TC-047 readBatch chunks the paths and preserves order', () async {
    final seenChunks = <int>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ExifMetadataService.channel, (call) async {
      final paths = (call.arguments as Map)['paths'] as List;
      seenChunks.add(paths.length);
      return [
        for (final path in paths) {'camera': path.toString().split('/').last},
      ];
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ExifMetadataService.channel, null);
    });

    final paths = [for (var i = 0; i < 1200; i++) '/photos/$i.JPG'];
    final result = await ExifMetadataService.readBatch(paths);

    expect(seenChunks, [kExifChunkSize, kExifChunkSize, 200]);
    expect(result, hasLength(1200));
    expect(result.first!.camera, '0.JPG');
    expect(result.last!.camera, '1199.JPG');
  });

  test('TC-048 a channel failure yields nulls rather than throwing', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ExifMetadataService.channel, (call) async {
      throw PlatformException(code: 'BOOM');
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ExifMetadataService.channel, null);
    });

    final result = await ExifMetadataService.readBatch(['/photos/a.JPG']);
    expect(result, [null]);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/exif_metadata_service_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:halcyon_flutter/services/exif_metadata_service.dart'`.

- [ ] **Step 3: Add the dependency**

In `pubspec.yaml`, under `dependencies:`, directly after the `dng_processor` entry:

```yaml
  # Fallback EXIF reader for platforms without the halcyon/exif native handler.
  exif: ^3.3.0
```

Run: `flutter pub get`
Expected: `Got dependencies!`

- [ ] **Step 4: Write the implementation**

Create `lib/services/exif_metadata_service.dart`:

```dart
import 'dart:io';

import 'package:exif/exif.dart' as pkg;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'rename_rule.dart';

/// Injection seam for reading EXIF for a batch of paths, mirroring the
/// `DngFullDecoder` typedef pattern so `AppState` can be tested without a
/// platform channel. Returned list is index-aligned with the input; an entry
/// is null when nothing could be read.
typedef ExifBatchReader = Future<List<ExifMetadata?>> Function(
  List<String> paths,
);

/// Paths per channel call. Large enough that 10,000 photos cost 20 calls, small
/// enough that progress updates stay smooth.
const int kExifChunkSize = 500;

class ExifMetadataService {
  static const MethodChannel channel = MethodChannel('halcyon/exif');

  /// Reads metadata for [paths], chunked, order preserved.
  ///
  /// On macOS the native handler reads all paths in a chunk in parallel
  /// (header only, no pixel decode). Everywhere else — and whenever the
  /// channel is missing — it falls back to parsing in a Dart isolate.
  static Future<List<ExifMetadata?>> readBatch(List<String> paths) async {
    final results = <ExifMetadata?>[];
    for (var start = 0; start < paths.length; start += kExifChunkSize) {
      final end = (start + kExifChunkSize).clamp(0, paths.length);
      final chunk = paths.sublist(start, end);
      results.addAll(await _readChunk(chunk));
    }
    return results;
  }

  static Future<List<ExifMetadata?>> _readChunk(List<String> chunk) async {
    try {
      final raw = await channel.invokeMethod<List<Object?>>('readBatch', {
        'paths': chunk,
      });
      if (raw == null) return List<ExifMetadata?>.filled(chunk.length, null);
      return [
        for (final entry in raw)
          metadataFromMap(entry is Map ? entry.cast<Object?, Object?>() : null),
      ];
    } on MissingPluginException {
      return Future.wait(chunk.map(readWithPackage));
    } on PlatformException catch (e) {
      debugPrint('EXIF batch read failed: ${e.code} ${e.message}');
      return List<ExifMetadata?>.filled(chunk.length, null);
    }
  }

  /// Decodes one native map. Public because this shape — not the channel — is
  /// what the tests can pin down.
  static ExifMetadata? metadataFromMap(Map<Object?, Object?>? map) {
    if (map == null) return null;
    return ExifMetadata(
      captureDate: _parseDate(map['captureDate']),
      camera: _string(map['camera']),
      lens: _string(map['lens']),
      make: _string(map['make']),
      artist: _string(map['artist']),
      shutter: _string(map['shutter']),
      aperture: _double(map['aperture']),
      focalLength: _double(map['focalLength']),
      gpsImgDirection: _double(map['direction']),
      iso: map['iso'] is int ? map['iso'] as int : null,
    );
  }

  /// Non-macOS fallback. Runs off the UI isolate because parsing a RAW header
  /// reads and scans megabytes.
  static Future<ExifMetadata?> readWithPackage(String path) async {
    try {
      return await Isolate.run(() => _parseWithPackage(path));
    } catch (e) {
      debugPrint('EXIF package read failed for $path: $e');
      return null;
    }
  }

  static Future<ExifMetadata?> _parseWithPackage(String path) async {
    final tags = await pkg.readExifFromFile(File(path));
    if (tags.isEmpty) return null;
    String? tag(String key) => tags[key]?.printable.trim();
    return ExifMetadata(
      captureDate: _parseDate(tag('EXIF DateTimeOriginal')),
      camera: _blankToNull(tag('Image Model')),
      lens: _blankToNull(tag('EXIF LensModel')),
      make: _blankToNull(tag('Image Make')),
      artist: _blankToNull(tag('Image Artist')),
      shutter: _blankToNull(tag('EXIF ExposureTime')),
      aperture: _ratio(tag('EXIF FNumber')),
      focalLength: _ratio(tag('EXIF FocalLength')),
      gpsImgDirection: _ratio(tag('GPS GPSImgDirection')),
      iso: int.tryParse(tag('EXIF ISOSpeedRatings') ?? ''),
    );
  }

  /// EXIF dates are `yyyy:MM:dd HH:mm:ss`, which `DateTime.parse` rejects.
  static DateTime? _parseDate(Object? value) {
    if (value is! String) return null;
    final match = RegExp(
      r'^(\d{4})\D(\d{2})\D(\d{2})\D(\d{2})\D(\d{2})\D(\d{2})',
    ).firstMatch(value.trim());
    if (match == null) return null;
    return DateTime(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
    );
  }

  static String? _string(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  static String? _blankToNull(String? value) =>
      value == null || value.isEmpty ? null : value;

  static double? _double(Object? value) {
    if (value is num) return value.toDouble();
    return null;
  }

  /// The package prints rationals as `28/10`; a plain number passes through.
  static double? _ratio(String? value) {
    if (value == null || value.isEmpty) return null;
    final parts = value.split('/');
    if (parts.length == 2) {
      final n = double.tryParse(parts[0]);
      final d = double.tryParse(parts[1]);
      if (n != null && d != null && d != 0) return n / d;
      return null;
    }
    return double.tryParse(value);
  }
}
```

Add `import 'dart:isolate';` to the imports (used by `Isolate.run`).

- [ ] **Step 5: Run the test to verify it passes**

Run: `flutter test test/exif_metadata_service_test.dart`
Expected: PASS, `+4: All tests passed!`

- [ ] **Step 6: Analyze and commit**

```bash
flutter analyze
git add pubspec.yaml pubspec.lock lib/services/exif_metadata_service.dart test/exif_metadata_service_test.dart
git commit -m "feat: add batched EXIF metadata reader"
```

Expected: `No issues found!`

---

### Task 6: macOS native `halcyon/exif` handler

**Files:**
- Modify: `macos/Runner/AppDelegate.swift`

**Interfaces:**
- Consumes: the channel contract defined in Task 5 — method `readBatch`, argument `{"paths": [String]}`, returns an array index-aligned with `paths` whose entries are `NSNull` or a dictionary with keys `captureDate`, `camera`, `lens`, `make`, `artist`, `shutter`, `aperture`, `focalLength`, `direction`, `iso`.
- Produces: nothing consumed by Dart beyond that contract.

There is no Dart-side test for this task; the Dart side is already covered by
the mock-channel tests in Task 5. Verification is a real run (Step 4).

- [ ] **Step 1: Register the channel**

In `AppDelegate.applicationDidFinishLaunching`, next to the existing
`thumbnailChannel` / `trashChannel` registrations:

```swift
    let exifChannel = FlutterMethodChannel(name: "halcyon/exif",
                                           binaryMessenger: controller.engine.binaryMessenger)

    exifChannel.setMethodCallHandler({ (call, result) -> Void in
      guard call.method == "readBatch",
            let args = call.arguments as? [String: Any],
            let paths = args["paths"] as? [String] else {
        result(FlutterMethodNotImplemented)
        return
      }
      AppDelegate.readExifBatch(paths: paths, result: result)
    })
```

- [ ] **Step 2: Implement the batch reader**

Add these methods to `AppDelegate` (alongside the existing static image
helpers):

```swift
  /// Reads EXIF for every path in parallel. Header only — no pixel decode —
  /// so 10,000 files cost seconds, not minutes. Order is preserved because
  /// each slot is written by index.
  static func readExifBatch(paths: [String], result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      var slots = [Any?](repeating: nil, count: paths.count)
      let lock = NSLock()

      DispatchQueue.concurrentPerform(iterations: paths.count) { index in
        let entry = AppDelegate.exifDictionary(path: paths[index])
        lock.lock()
        slots[index] = entry
        lock.unlock()
      }

      let payload: [Any] = slots.map { $0 ?? NSNull() }
      DispatchQueue.main.async { result(payload) }
    }
  }

  static func exifDictionary(path: String) -> [String: Any]? {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any] else {
      return nil
    }

    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    let aux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
    let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

    var out: [String: Any] = [:]
    out["captureDate"] = exif[kCGImagePropertyExifDateTimeOriginal] as? String
      ?? tiff[kCGImagePropertyTIFFDateTime] as? String
    out["camera"] = tiff[kCGImagePropertyTIFFModel] as? String
    out["make"] = tiff[kCGImagePropertyTIFFMake] as? String
    out["artist"] = tiff[kCGImagePropertyTIFFArtist] as? String
    // LensModel is the standard tag; LensModel in the Aux dictionary is where
    // several vendors (and Apple's own RAW pipeline) actually put it.
    out["lens"] = exif[kCGImagePropertyExifLensModel] as? String
      ?? aux[kCGImagePropertyExifAuxLensModel] as? String
    out["aperture"] = exif[kCGImagePropertyExifFNumber] as? Double
    out["focalLength"] = exif[kCGImagePropertyExifFocalLength] as? Double
    out["iso"] = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
    out["direction"] = gps[kCGImagePropertyGPSImgDirection] as? Double
    out["shutter"] = AppDelegate.shutterString(
      exif[kCGImagePropertyExifExposureTime] as? Double
    )

    // Drop nils so the Dart side sees "absent", not "present but null".
    return out.compactMapValues { $0 }
  }

  /// 0.004 -> "1/250", 2.0 -> "2s". Slashes are stripped on the Dart side by
  /// RenameRule.sanitise, so this stays human-readable here.
  static func shutterString(_ seconds: Double?) -> String? {
    guard let seconds = seconds, seconds > 0 else { return nil }
    if seconds >= 1 { return "\(Int(seconds.rounded()))s" }
    return "1/\(Int((1.0 / seconds).rounded()))"
  }
```

- [ ] **Step 3: Build**

Run: `flutter build macos --debug`
Expected: `Built build/macos/Build/Products/Debug/halcyon_flutter.app` with no Swift errors.

- [ ] **Step 4: Verify against real photos**

Run: `flutter run -d macos`, open a folder containing at least one JPG and one
RAW, then open the rename dialog once Task 8 lands. Until then, verify from a
throwaway `main()` probe or simply confirm the build succeeds and defer the
live check to Task 8's Step 6 — that step is the one that must show real
camera/lens values in the preview.

- [ ] **Step 5: Commit**

```bash
git add macos/Runner/AppDelegate.swift
git commit -m "feat(macos): add halcyon/exif batch metadata channel"
```

---

### Task 7: `AppState.renameByExif` — orchestration, key remap, undo

**Files:**
- Modify: `lib/providers/app_state.dart`
- Modify: `test/app_state_test.dart` (append a new `group`)

**Interfaces:**
- Consumes: `RenameRule`, `ExifMetadata` (Task 1), `planRenames`/`applyRenames`/`undoLastRename`/`RenameOutcome` (Tasks 2–3), `PhotoStatusStore.remapKeys`/`saveRenameRule`/`loadRenameRule` (Task 4), `ExifBatchReader` (Task 5).
- Produces:
  - `AppState({..., ExifBatchReader? exifReader})` — new optional constructor param, defaulting to `ExifMetadataService.readBatch`
  - `Future<void> renameByExif(RenameRule rule, {required bool isCustom})`
  - `Future<void> undoRename()`
  - `void cancelRename()`
  - `bool get isRenaming`
  - `Future<String?> loadSavedRenameRule()`
  - `Future<Map<String, ExifMetadata?>> readMetadataFor(List<PhotoItem> items)` — used by the dialog's preview

- [ ] **Step 1: Write the failing test**

Append to `test/app_state_test.dart` (inside `main()`):

```dart
  group('renameByExif', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('halcyon_rename_state_');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    Future<void> touch(String name) =>
        File(p.join(tempDir.path, name)).writeAsString(name);

    AppState buildState() {
      return AppState(
        exifReader: (paths) async => [
          for (final path in paths)
            ExifMetadata(
              captureDate: path.contains('A')
                  ? DateTime(2026, 4, 7, 9, 3, 5)
                  : DateTime(2026, 4, 7, 10, 0, 0),
            ),
        ],
      );
    }

    test('TC-049 renames files and moves the star to the new id', () async {
      await touch('A.NEF');
      await touch('A.JPG');
      await touch('B.JPG');

      final state = buildState();
      await state.loadFolder(tempDir);
      state.selectItem('A');
      state.markCurrent(PhotoStatus.starred);

      await state.renameByExif(
        const RenameRule(RenameRule.kDefaultTemplate),
        isCustom: false,
      );

      final names = tempDir
          .listSync()
          .map((e) => p.basename(e.path))
          .where((n) => !n.startsWith('.'))
          .toList()
        ..sort();
      expect(names, [
        '2026-04-07-09-03-05.JPG',
        '2026-04-07-09-03-05.NEF',
        '2026-04-07-10-00-00.JPG',
      ]);

      final renamed = state.items.firstWhere(
        (i) => i.id == '2026-04-07-09-03-05',
      );
      expect(renamed.status, PhotoStatus.starred);
      expect(state.selectedItemID, '2026-04-07-09-03-05');
    });

    test('TC-050 undo restores the original names and the star', () async {
      await touch('A.JPG');

      final state = buildState();
      await state.loadFolder(tempDir);
      state.selectItem('A');
      state.markCurrent(PhotoStatus.starred);
      await state.renameByExif(
        const RenameRule(RenameRule.kDefaultTemplate),
        isCustom: false,
      );

      await state.undoRename();

      expect(File(p.join(tempDir.path, 'A.JPG')).existsSync(), isTrue);
      expect(state.items.single.id, 'A');
      expect(state.items.single.status, PhotoStatus.starred);
    });

    test('TC-051 a custom rule is saved; a preset clears it', () async {
      await touch('A.JPG');
      final state = buildState();
      await state.loadFolder(tempDir);

      await state.renameByExif(const RenameRule('{YYYY}_{seq}'), isCustom: true);
      expect(await state.loadSavedRenameRule(), '{YYYY}_{seq}');

      await state.renameByExif(
        const RenameRule(RenameRule.kDefaultTemplate),
        isCustom: false,
      );
      expect(await state.loadSavedRenameRule(), isNull);
    });
  });
```

Ensure `test/app_state_test.dart` imports `package:halcyon_flutter/services/rename_rule.dart`, `package:halcyon_flutter/services/exif_metadata_service.dart`, `dart:io`, and `package:path/path.dart as p` (some are already there — do not duplicate).

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/app_state_test.dart`
Expected: FAIL — `No named parameter with the name 'exifReader'`.

- [ ] **Step 3: Wire the reader into the constructor**

In `lib/providers/app_state.dart`, add the imports:

```dart
import '../services/exif_metadata_service.dart';
import '../services/rename_rule.dart';
import '../services/rename_service.dart';
```

Add the constructor parameter and field:

```dart
    ExifBatchReader? exifReader,
```
```dart
       _exifReader = exifReader ?? ExifMetadataService.readBatch,
```
```dart
  final ExifBatchReader _exifReader;

  bool _isRenaming = false;
  bool _renameCancelled = false;

  bool get isRenaming => _isRenaming;

  void cancelRename() {
    _renameCancelled = true;
  }
```

- [ ] **Step 4: Implement the orchestration**

Append these methods to `AppState`:

```dart
  Future<String?> loadSavedRenameRule() async {
    final dir = _currentDir;
    if (dir == null) return null;
    return _statusStore.loadRenameRule(dir);
  }

  /// Reads EXIF for [items], one read per item (from the JPG sibling when
  /// there is one — see [PhotoItem.bestFileToLoad]) and keyed by item id.
  /// The dialog uses this for its 5-file preview; [renameByExif] uses it for
  /// the whole folder.
  Future<Map<String, ExifMetadata?>> readMetadataFor(
    List<PhotoItem> items, {
    void Function(int done, int total)? onProgress,
  }) async {
    final paths = <String>[];
    final ids = <String>[];
    for (final item in items) {
      final file = item.bestFileToLoad;
      if (file == null) continue;
      ids.add(item.id);
      paths.add(file.path);
    }

    final out = <String, ExifMetadata?>{};
    for (var start = 0; start < paths.length; start += kExifChunkSize) {
      final end = (start + kExifChunkSize).clamp(0, paths.length);
      final chunk = await _exifReader(paths.sublist(start, end));
      for (var i = 0; i < chunk.length; i++) {
        out[ids[start + i]] = chunk[i];
      }
      onProgress?.call(end, paths.length);
    }
    return out;
  }

  /// Renames every photo in the current folder from [rule]. [isCustom] is
  /// true when the rule came from the editor rather than a built-in preset;
  /// only custom rules are remembered for the folder.
  Future<void> renameByExif(RenameRule rule, {required bool isCustom}) async {
    final dir = _currentDir;
    if (dir == null || _items.isEmpty || _isRenaming) return;

    _isRenaming = true;
    _renameCancelled = false;
    notifyListeners();

    try {
      final metadata = await readMetadataFor(
        _items,
        onProgress: (done, total) {
          showStatus(StatusMessage('讀取 EXIF *$done/$total*…'));
        },
      );

      final fileModified = <String, DateTime>{};
      final existingNames = <String>{};
      for (final entity in dir.listSync()) {
        existingNames.add(p.basename(entity.path));
      }
      for (final item in _items) {
        final file = item.bestFileToLoad;
        if (file == null) continue;
        fileModified[item.id] = file.statSync().modified;
      }

      final plans = planRenames(
        items: _items,
        metadata: metadata,
        fileModified: fileModified,
        rule: rule,
        existingNames: existingNames,
      );

      if (plans.isEmpty) {
        showStatus(const StatusMessage('沒有檔案需要重新命名'));
        return;
      }

      final outcome = await applyRenames(
        plans,
        dir,
        onProgress: (done, total) {
          showStatus(StatusMessage('重新命名 *$done/$total*…'));
        },
        isCancelled: () => _renameCancelled,
      );

      // The status file is keyed by item id (the basename), so without this
      // every star, trash mark and the last-viewed pointer would be orphaned.
      await _statusStore.remapKeys(dir, {
        for (final plan in plans) plan.oldId: plan.newId,
      });
      await _statusStore.saveRenameRule(dir, isCustom ? rule.template : null);

      final currentPlan = plans.where((x) => x.oldId == _selectedItemID);
      await loadFolder(
        dir,
        targetSelectionId: currentPlan.isEmpty
            ? _selectedItemID
            : currentPlan.first.newId,
      );

      var message = '已重新命名 *${outcome.renamedCount}* 個項目';
      if (outcome.cancelled) message += '（已取消）';
      if (outcome.failures.isNotEmpty) {
        message += '，*${outcome.failures.length}* 個失敗';
        for (final failure in outcome.failures.take(3)) {
          debugPrint('Rename failure: $failure');
        }
      }
      showStatus(StatusMessage(message));
    } catch (e) {
      showStatus(StatusMessage('重新命名失敗：$e'));
    } finally {
      _isRenaming = false;
      notifyListeners();
    }
  }

  /// Replays the folder's rename journal backwards. No-op when there is none.
  Future<void> undoRename() async {
    final dir = _currentDir;
    if (dir == null || _isRenaming) return;

    final logExists = File(p.join(dir.path, kRenameLogName)).existsSync();
    if (!logExists) {
      showStatus(const StatusMessage('沒有可還原的重新命名紀錄'));
      return;
    }

    final outcome = await undoLastRename(dir);

    // The journal is per FILE; the status file is keyed per ITEM (basename
    // without extension), so remap with the inverse of the batch's id map.
    await _statusStore.remapKeys(dir, {
      for (final entry in _lastRenameIdMap.entries) entry.value: entry.key,
    });
    _lastRenameIdMap = const {};

    await loadFolder(dir);
    showStatus(
      StatusMessage('已還原 *${outcome.renamedCount}* 個檔案的原始檔名'),
    );
  }
```

Add the field next to `_isRenaming` (Step 3):

```dart
  /// old id -> new id for the most recent batch, used to unwind marks on undo.
  Map<String, String> _lastRenameIdMap = const {};
```

and populate it in `renameByExif`, immediately after `plans` is computed and
the `plans.isEmpty` early return:

```dart
      _lastRenameIdMap = {for (final plan in plans) plan.oldId: plan.newId};
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `flutter test test/app_state_test.dart`
Expected: PASS — all pre-existing tests plus TC-049…TC-051.

- [ ] **Step 6: Analyze and commit**

```bash
flutter analyze
git add lib/providers/app_state.dart test/app_state_test.dart
git commit -m "feat: orchestrate EXIF rename and undo in AppState"
```

Expected: `No issues found!`

---

### Task 8: Rename dialog (two-pane) + menu entry

**Files:**
- Create: `lib/views/rename_dialog.dart`
- Modify: `lib/views/sidebar_view.dart` (menu item + `onSelected` branch)
- Modify: `test/sidebar_view_test.dart` (append a test)
- Create: `test/rename_dialog_test.dart`

**Interfaces:**
- Consumes: `AppState.renameByExif`, `AppState.readMetadataFor`, `AppState.loadSavedRenameRule` (Task 7); `RenameRule.presets`, `RenameRule.variableGroups`, `RenameRule.kDefaultTemplate`, `RenameRule.render`, `RenameRule.error` (Task 1).
- Produces:
  - `const String kRenameMenuValue = 'rename';` (exported from `lib/views/rename_dialog.dart`, imported by `sidebar_view.dart` — the test must reference this constant, never a hardcoded `'rename'`)
  - `class RenameDialog extends StatefulWidget` with `const RenameDialog({super.key})`

Layout follows `docs/mockups/exif-rename/variant-2-twopane.html`: an
880x520 dialog, left column = preset radio rows then the rule field and the
chip groups, right column = the 5-row preview with a shuffle button, footer =
Cancel / Rename.

**Gotcha (memory.md G-005):** a `PopupMenuItem`'s `value` and the `onSelected`
branch are matched by string; a mismatch makes the entry silently dead, and a
test that hardcodes the literal will not catch it. Both sides use
`kRenameMenuValue`.

**Gotcha (memory.md G-009):** tapping a `PopupMenuItem` inside `testWidgets`
hangs under FakeAsync. The sidebar test calls the `onSelected` callback
directly instead of tapping.

- [ ] **Step 1: Write the failing tests**

Create `test/rename_dialog_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/rename_rule.dart';
import 'package:halcyon_flutter/views/rename_dialog.dart';
import 'package:provider/provider.dart';

void main() {
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState(exifReader: (paths) async => [
          for (final _ in paths) null,
        ]),
        child: const MaterialApp(
          home: Scaffold(body: RenameDialog()),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('TC-052 every preset and every variable chip is rendered',
      (tester) async {
    await pump(tester);

    for (final preset in RenameRule.presets) {
      expect(find.text(preset.label), findsOneWidget);
    }
    expect(find.text('Custom...'), findsOneWidget);

    for (final group in RenameRule.variableGroups) {
      for (final token in group.tokens) {
        expect(find.text(token), findsOneWidget, reason: token);
      }
    }
  });

  testWidgets('TC-053 an invalid rule disables Rename and shows the reason',
      (tester) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField), '{fstop}');
    await tester.pump();

    expect(find.textContaining('Unknown variable'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('TC-054 tapping a chip appends its token to the rule',
      (tester) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField), '{YYYY}');
    await tester.pump();
    await tester.tap(find.text('{camera}'));
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '{YYYY}{camera}');
  });
}
```

Append to `test/sidebar_view_test.dart`:

```dart
  testWidgets('TC-055 onSelected with the shared constant opens the dialog',
      (tester) async {
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

    expect(find.byType(RenameDialog), findsOneWidget);
  });
```

Import `package:halcyon_flutter/views/rename_dialog.dart` in that test file.
`stateForFolder` and `pumpSidebar` are that file's existing helpers.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/rename_dialog_test.dart test/sidebar_view_test.dart`
Expected: FAIL — `Target of URI doesn't exist: '.../views/rename_dialog.dart'`.

- [ ] **Step 3: Write the dialog**

Create `lib/views/rename_dialog.dart`:

```dart
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/photo_item.dart';
import '../providers/app_state.dart';
import '../services/rename_rule.dart';

/// Menu value for the sidebar action menu. Shared by the widget and its test
/// so a typo cannot make the entry silently dead (memory.md G-005).
const String kRenameMenuValue = 'rename';

const String kCustomPresetLabel = 'Custom...';

/// Two-pane rename dialog: presets + rule editor on the left, live preview on
/// the right (docs/mockups/exif-rename/variant-2-twopane.html).
class RenameDialog extends StatefulWidget {
  const RenameDialog({super.key});

  @override
  State<RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<RenameDialog> {
  final TextEditingController _controller = TextEditingController(
    text: RenameRule.kDefaultTemplate,
  );
  String _selectedLabel = RenameRule.presets.first.label;
  List<PhotoItem> _sample = const [];
  Map<String, ExifMetadata?> _sampleMeta = const {};

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreSavedRule();
      _reroll();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _restoreSavedRule() async {
    final saved = await context.read<AppState>().loadSavedRenameRule();
    if (!mounted || saved == null) return;
    setState(() {
      _controller.text = saved;
      _selectedLabel = kCustomPresetLabel;
    });
  }

  /// Five random items, with their EXIF read once so the preview shows real
  /// values rather than a guess.
  Future<void> _reroll() async {
    final state = context.read<AppState>();
    final items = [...state.items]..shuffle(Random());
    final sample = items.take(5).toList();
    final meta = await state.readMetadataFor(sample);
    if (!mounted) return;
    setState(() {
      _sample = sample;
      _sampleMeta = meta;
    });
  }

  RenameRule get _rule => RenameRule(_controller.text);

  bool get _isCustom => _selectedLabel == kCustomPresetLabel;

  void _selectPreset(String label, String template) {
    setState(() {
      _selectedLabel = label;
      _controller.text = template;
    });
  }

  void _insertToken(String token) {
    final selection = _controller.selection;
    final text = _controller.text;
    final at = selection.isValid ? selection.baseOffset : text.length;
    setState(() {
      _selectedLabel = kCustomPresetLabel;
      _controller.value = TextEditingValue(
        text: text.replaceRange(at, selection.isValid ? selection.extentOffset : at, token),
        selection: TextSelection.collapsed(offset: at + token.length),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final error = _rule.error;

    return Dialog(
      child: SizedBox(
        width: 880,
        height: 520,
        child: Column(
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 5, child: _buildEditor(error)),
                  const VerticalDivider(width: 1),
                  Expanded(flex: 4, child: _buildPreview()),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: error != null
                        ? null
                        : () {
                            final state = context.read<AppState>();
                            Navigator.of(context).pop();
                            state.renameByExif(_rule, isCustom: _isCustom);
                          },
                    child: Text('Rename ${context.read<AppState>().items.length} items'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditor(String? error) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Rename by EXIF', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          for (final preset in RenameRule.presets)
            RadioListTile<String>(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: preset.label,
              groupValue: _selectedLabel,
              onChanged: (_) => _selectPreset(preset.label, preset.template),
              title: Text(preset.label),
              subtitle: Text(preset.template, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
            ),
          RadioListTile<String>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: kCustomPresetLabel,
            groupValue: _selectedLabel,
            onChanged: (_) => setState(() => _selectedLabel = kCustomPresetLabel),
            title: const Text(kCustomPresetLabel),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            style: const TextStyle(fontFamily: 'monospace'),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              isDense: true,
              errorText: error,
            ),
          ),
          const SizedBox(height: 12),
          for (final group in RenameRule.variableGroups) ...[
            Text(group.title, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final token in group.tokens)
                  ActionChip(
                    label: Text(token, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                    onPressed: () => _insertToken(token),
                  ),
              ],
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }

  Widget _buildPreview() {
    final rule = _rule;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Preview', style: TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              IconButton(
                iconSize: 18,
                tooltip: 'Pick 5 other files',
                onPressed: _reroll,
                icon: const Icon(Icons.casino_outlined),
              ),
            ],
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _sample.length,
              itemBuilder: (context, index) {
                final item = _sample[index];
                final file = item.bestFileToLoad;
                final newBase = rule.error != null
                    ? '—'
                    : rule.render(
                        meta: _sampleMeta[item.id],
                        fileModified: file?.statSync().modified ?? DateTime(1970),
                        originalBase: item.id,
                        seq: index + 1,
                      );
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.id,
                        style: const TextStyle(fontSize: 11, decoration: TextDecoration.lineThrough),
                      ),
                      Text(newBase, style: const TextStyle(fontSize: 13)),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Wire the menu entry**

In `lib/views/sidebar_view.dart`, import `rename_dialog.dart`, then add to the
`itemBuilder` list immediately **before** the `PopupMenuDivider` that precedes
the `delete` item:

```dart
          PopupMenuItem(
            value: kRenameMenuValue,
            enabled: state.items.isNotEmpty,
            child: Text(
              'Rename by EXIF...',
              style: TextStyle(color: actionTextColor),
            ),
          ),
```

and add the branch in the same widget's `onSelected`, next to the existing
`'settings'` branch:

```dart
        } else if (value == kRenameMenuValue) {
          showDialog(context: context, builder: (ctx) => const RenameDialog());
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `flutter test test/rename_dialog_test.dart test/sidebar_view_test.dart`
Expected: PASS for both files.

- [ ] **Step 6: Verify against real photos (this is the live proof for Task 6)**

Run: `flutter run -d macos`, open a folder with JPG + RAW siblings, open
`Rename by EXIF...`, and confirm:
- the preview shows real dates, and `{camera}` / `{lens}` show real values;
- running the batch renames RAW and JPG of a pair to the same base name;
- the status line counts up and finishes with the renamed count;
- a starred photo is still starred after the rename;
- reopening the dialog pre-fills a custom rule that was used last time.

- [ ] **Step 7: Analyze and commit**

```bash
flutter analyze
git add lib/views/rename_dialog.dart lib/views/sidebar_view.dart test/rename_dialog_test.dart test/sidebar_view_test.dart
git commit -m "feat: add two-pane EXIF rename dialog"
```

Expected: `No issues found!`

---

### Task 9: Undo affordance on the status line

**Files:**
- Modify: `lib/providers/app_state.dart` (extend `StatusMessage`)
- Modify: `lib/views/status_line.dart`
- Modify: `test/status_line_test.dart`

**Interfaces:**
- Consumes: `AppState.undoRename` (Task 7).
- Produces: `StatusMessage({String text, String? revealPath, String? actionLabel, VoidCallback? onAction})` — the existing two params keep their positions and defaults, so no existing caller changes.

- [ ] **Step 1: Write the failing test**

Append to `test/status_line_test.dart`:

```dart
  testWidgets('TC-056 an action message renders a button that fires once',
      (tester) async {
    var taps = 0;
    final state = AppState();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: StatusLine())),
      ),
    );

    state.showStatus(
      StatusMessage('已重新命名 *3* 個項目',
          actionLabel: '還原', onAction: () => taps++),
    );
    await tester.pump();

    expect(find.text('還原'), findsOneWidget);
    await tester.tap(find.text('還原'));
    expect(taps, 1);
  });
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/status_line_test.dart`
Expected: FAIL — `No named parameter with the name 'actionLabel'`.

- [ ] **Step 3: Extend `StatusMessage`**

In `lib/providers/app_state.dart`:

```dart
class StatusMessage {
  const StatusMessage(
    this.text, {
    this.revealPath,
    this.actionLabel,
    this.onAction,
  });

  final String text;
  final String? revealPath;

  /// Optional trailing button (e.g. "還原" after a rename batch).
  final String? actionLabel;
  final VoidCallback? onAction;
}
```

- [ ] **Step 4: Render it**

In `lib/views/status_line.dart`, directly after the existing
`if (message.revealPath != null) ...[ … ]` block:

```dart
              if (message.actionLabel != null) ...[
                const SizedBox(width: 12),
                TextButton(
                  onPressed: message.onAction,
                  style: TextButton.styleFrom(
                    foregroundColor: accentColor,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(message.actionLabel!),
                ),
              ],
```

- [ ] **Step 5: Attach it to the rename progress and result**

In `AppState.renameByExif`, replace the final `showStatus(StatusMessage(message));`
with:

```dart
      showStatus(
        StatusMessage(message, actionLabel: '還原', onAction: undoRename),
      );
```

and give the in-flight progress message a cancel affordance — this is the only
thing that reaches `cancelRename()`, which `applyRenames` already polls:

```dart
        onProgress: (done, total) {
          showStatus(
            StatusMessage(
              '重新命名 *$done/$total*…',
              actionLabel: '取消',
              onAction: cancelRename,
            ),
          );
        },
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `flutter test test/status_line_test.dart test/app_state_test.dart`
Expected: PASS for both.

- [ ] **Step 7: Analyze and commit**

```bash
flutter analyze
git add lib/providers/app_state.dart lib/views/status_line.dart test/status_line_test.dart
git commit -m "feat: offer undo on the status line after a rename"
```

Expected: `No issues found!`

---

### Task 10: Project documentation

**Files:**
- Modify: `memory.md`, `unit_test.md`, `file_index.md`, `task.md`, `handover.md`

**Interfaces:** none — documentation only.

- [ ] **Step 1: Record the architecture decisions**

Append to `memory.md` (next free numbers are AD-016 and G-011):

```markdown
### AD-016 EXIF rename splits policy from I/O

`RenameRule.render` (template → name) and `planRenames` (names → collision-free
plan) are pure functions; only `applyRenames` touches the filesystem. The whole
naming policy is therefore testable without photos on disk, which is what makes
the 10,000-file path safe to change later.

Renames run serially: `File.rename` is a same-volume metadata operation, so
parallelism buys nothing and would turn the planner's collision avoidance into a
race. The cost at 10,000 photos is in reading EXIF, which IS parallel — on the
native side, header-only, one read per item rather than per file.

### AD-017 EXIF is read once per item, from the JPG sibling

A RAW+JPG pair shares one capture, so `PhotoItem.bestFileToLoad` picks the JPG
and its metadata is applied to every file in the group. Reading the RAW header
too would double the work for identical data.

### G-011 `.halcyon_status.json` is keyed by filename

Every star, trash mark and the last-viewed pointer is stored under
`PhotoItem.id`, i.e. the basename. Anything that renames files MUST call
`PhotoStatusStore.remapKeys`, or the marks are silently orphaned.

Related trap: `saveStatuses()` rebuilds the map from scratch and carries only
the keys in `PhotoStatusStore.reservedKeys` forward. Adding a new non-photo key
without adding it to that set means the next star wipes it.
```

- [ ] **Step 2: Record the test cases**

Add TC-024 … TC-056 to the test-case matrix in `unit_test.md`, one row each,
with the file they live in:
`test/rename_rule_test.dart` (TC-024…TC-030),
`test/rename_service_test.dart` (TC-031…TC-040),
`test/photo_status_store_test.dart` (TC-041…TC-044),
`test/exif_metadata_service_test.dart` (TC-045…TC-048),
`test/app_state_test.dart` (TC-049…TC-051),
`test/rename_dialog_test.dart` (TC-052…TC-054),
`test/sidebar_view_test.dart` (TC-055),
`test/status_line_test.dart` (TC-056).

- [ ] **Step 3: Update the file map**

Add to `file_index.md`: `lib/services/rename_rule.dart`,
`lib/services/rename_service.dart`, `lib/services/exif_metadata_service.dart`,
`lib/views/rename_dialog.dart`, and the `halcyon/exif` channel under the macOS
runner entry.

- [ ] **Step 4: Update task state**

Move the EXIF rename entry into the completed section of `task.md` and write
the handoff paragraph in `handover.md` (what shipped, what is deliberately not
covered: Windows/Android native EXIF, renaming subsets, moving files).

- [ ] **Step 5: Full suite and commit**

```bash
flutter test
flutter analyze
git add memory.md unit_test.md file_index.md task.md handover.md
git commit -m "docs: record EXIF rename decisions and test matrix"
```

Expected: `All tests passed!` and `No issues found!`

---

## Verification checklist (run before calling the feature done)

- [ ] `flutter test` — whole suite green, and the declared test count matches
      `grep -c "test(\|testWidgets(" test/*.dart` for the new files (a name
      missing from the streamed output proves nothing; the count does).
- [ ] `flutter analyze` — `No issues found!`
- [ ] Live run on a real folder: rename, check a starred photo keeps its star,
      undo, check the original names and the star come back.
- [ ] Live run on a folder of a few thousand files: the UI stays responsive and
      the status line counts up.
