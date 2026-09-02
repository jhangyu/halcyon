import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/photo_item.dart';
import 'package:halcyon_flutter/models/rename_rule.dart';
import 'package:halcyon_flutter/services/rename/rename_service.dart';
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

    test('TC-211 a malformed journal line does not block the undo', () async {
      final renamed = File(p.join(tempDir.path, 'NEW_0001.jpg'));
      await renamed.writeAsString('x');

      await File(p.join(tempDir.path, kRenameLogName)).writeAsString(
        '${json.encode({'from': p.join(tempDir.path, 'OLD_0001.jpg'), 'to': renamed.path})}\n'
        'this is not json\n',
      );

      final outcome = await undoLastRename(tempDir);

      expect(outcome.renamedCount, 1);
      expect(outcome.failures, hasLength(1));
      expect(outcome.failures.single, contains('malformed'));
      expect(await File(p.join(tempDir.path, 'OLD_0001.jpg')).exists(), isTrue);
      expect(await File(p.join(tempDir.path, kRenameLogName)).exists(), isFalse);
    });

    // -------------------------------------------------------------------
    // F1 / AC2: the outcome must describe what LANDED, not what was
    // intended, so the caller can remap persisted marks off the outcome.
    // -------------------------------------------------------------------

    test('TC-560 idMap contains only the plans that actually landed',
        () async {
      await touch('B.JPG');

      final outcome = await applyRenames(
        [planFor('A', 'new-A', ['.NEF']), planFor('B', 'new-B', ['.JPG'])],
        tempDir,
      );

      expect(outcome.idMap, {'B': 'new-B'});
      expect(outcome.partialIdMap, isEmpty);
    });

    test('TC-561 a cancelled batch reports only the pre-cancel renames',
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
      expect(outcome.idMap, {'A': 'new-A'});
    });

    test('TC-562 a half-applied plan is reported as partial, not as applied',
        () async {
      // The .NEF moves; the .JPG cannot, because its destination is a
      // non-empty directory. The item therefore exists under BOTH ids.
      await touch('A.NEF');
      await touch('A.JPG');
      await Directory(p.join(tempDir.path, 'new-A.JPG')).create();
      await File(p.join(tempDir.path, 'new-A.JPG', 'blocker')).writeAsString('x');

      final outcome = await applyRenames(
        [planFor('A', 'new-A', ['.NEF', '.JPG'])],
        tempDir,
      );

      expect(outcome.renamedCount, 0);
      expect(outcome.failures, hasLength(1));
      expect(outcome.idMap, isEmpty);
      expect(outcome.partialIdMap, {'A': 'new-A'});
      expect(File(p.join(tempDir.path, 'new-A.NEF')).existsSync(), isTrue);
      expect(File(p.join(tempDir.path, 'A.JPG')).existsSync(), isTrue);
    });

    // -------------------------------------------------------------------
    // F2 / AC3: undo must be able to tell its caller which ids it reversed
    // WITHOUT the caller having kept in-memory state from the batch.
    // -------------------------------------------------------------------

    test('TC-563 undo derives its id map from the on-disk journal', () async {
      await touch('A.NEF');
      await touch('A.JPG');
      await touch('B.JPG');
      await applyRenames(
        [planFor('A', 'new-A', ['.NEF', '.JPG']), planFor('B', 'new-B', ['.JPG'])],
        tempDir,
      );

      final outcome = await undoLastRename(tempDir);

      expect(outcome.idMap, {'new-A': 'A', 'new-B': 'B'});
    });
  });

  // ---------------------------------------------------------------------
  // AC4: planRenames must not plan a rename onto a name that differs from
  // an existing one only in case. exFAT (the user's photo volume) and APFS
  // are both case-insensitive, and File.rename silently REPLACES the
  // destination -- that is unrecoverable photo loss, not a failed item.
  // Evidence: scripts/tmp/rename_probe_fs.dart, run on /Volumes/EVO_4T.
  // ---------------------------------------------------------------------
  test('TC-564 planRenames treats a case-only difference from an existing '
      'file as a collision', () {
    final plans = planRenames(
      items: [
        PhotoItem(id: 'a1', files: [File('/photos/a1.JPG')]),
      ],
      metadata: const {},
      fileModified: {'a1': DateTime(2026, 1, 2, 3, 4, 5)},
      rule: const RenameRule('target'),
      // TARGET.JPG is a DIFFERENT photo that is not being renamed.
      existingNames: {'a1.JPG', 'TARGET.JPG'},
    );

    // Planning a1 -> target.JPG would, on a case-insensitive volume,
    // silently overwrite TARGET.JPG.
    expect(plans.single.newId, isNot(equalsIgnoringCase('target')));
    expect(plans.single.newId, 'target-1');
  });

  test('TC-565 planRenames does not hand two items names differing only in '
      'case from EACH OTHER', () {
    // Distinct from TC-564: there the clash is with a file already in the
    // folder (the `existingNames` seed), here it is between two members of
    // this very batch (the `taken` accumulator). Two cameras reported with
    // different capitalisation is all it takes, and the second rename would
    // silently replace the first on a case-insensitive volume.
    final plans = planRenames(
      items: [
        PhotoItem(id: 'a1', files: [File('/photos/a1.JPG')]),
        PhotoItem(id: 'a2', files: [File('/photos/a2.JPG')]),
      ],
      metadata: {
        'a1': const ExifMetadata(camera: 'X-T5'),
        'a2': const ExifMetadata(camera: 'x-t5'),
      },
      fileModified: {
        'a1': DateTime(2026, 1, 2, 3, 4, 5),
        'a2': DateTime(2026, 1, 2, 3, 4, 5),
      },
      rule: const RenameRule('{camera}'),
      existingNames: {'a1.JPG', 'a2.JPG'},
    );

    expect(plans, hasLength(2));
    final targets = [for (final plan in plans) plan.newId.toLowerCase()];
    expect(targets.toSet(), hasLength(targets.length),
        reason: 'two plans land on the same name once case is folded: '
            '${plans.map((plan) => plan.newId).toList()}');
  });
}
