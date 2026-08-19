import 'dart:convert';
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
