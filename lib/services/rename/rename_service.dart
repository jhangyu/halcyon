import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../models/photo_item.dart';
import '../library/photo_file_actions.dart';
import '../platform/file_retry.dart';
import '../../models/rename_rule.dart';

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

  // Case-FOLDED, because the volumes this app runs on are case-insensitive:
  // APFS by default and exFAT always (the user's photo drives). `File.rename`
  // silently REPLACES its destination, so planning `a1 -> target` while
  // `TARGET.JPG` exists destroys a photograph with no error to report. A
  // case-only difference must therefore count as a collision and take the
  // `-1` suffix. Evidence: scripts/tmp/rename_probe_fs.dart, run against
  // /Volumes/EVO_4T (exfat/fskit) -- "C case-collision rename: SUCCEEDED".
  final taken = <String>{...existingNames.map((n) => _baseOf(n).toLowerCase())};
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
    // A candidate that case-folds onto the item's OWN current name is not a
    // collision: it is a case-only rename of the file with itself, which
    // `File.rename` performs in place on every filesystem we ship on. The
    // fold below would otherwise report a clash, because `existingNames`
    // (rename_coordinator.dart, `dir.listSync()`) seeds `taken` with the
    // item's own basename -- so a rule that merely lower-cases would append
    // `-1` to every single file in the folder.
    //
    // Safe under the same case-insensitivity assumption the fold itself
    // rests on: on such a volume no OTHER file can occupy this folded name,
    // so the only contributor to the clash is the item itself.
    final folded = candidate.toLowerCase();
    final ownFold = item.id.toLowerCase();
    if (folded != ownFold && taken.contains(folded)) {
      var suffix = 1;
      while (taken.contains('$candidate-$suffix'.toLowerCase())) {
        suffix++;
      }
      candidate = '$candidate-$suffix';
    }
    taken.add(candidate.toLowerCase());

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
            from: sidecarPathFor(file.path),
            to: sidecarPathFor(p.join(file.parent.path, '$candidate$ext')),
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
    this.idMap = const {},
    this.partialIdMap = const {},
  });

  final int renamedCount;
  final List<String> failures;
  final bool cancelled;

  /// `oldId -> newId` for the plans that landed COMPLETELY, and for undo the
  /// inverse for the journal entries that were actually reversed.
  ///
  /// This is the OUTCOME, not the intent. Callers that rewrite persisted
  /// per-photo state (stars, trash marks, the last-viewed pointer) must key
  /// off this and never off the plan list: a cancelled or partly failed batch
  /// leaves files under their original names, and remapping their marks to a
  /// name that does not exist orphans them, after which the next scan's
  /// stale-key cleanup deletes them outright. See F1 in
  /// docs/logs/2026-09-02/arch-review-defect-family.md.
  final Map<String, String> idMap;

  /// `oldId -> newId` for plans where SOME moves landed and a later one
  /// failed, so the group is now split across both names on disk. Both keys
  /// must keep the mark; neither name alone is the truth.
  final Map<String, String> partialIdMap;
}

/// POSIX errno values that a rename can return transiently, where trying
/// again a moment later is the correct response rather than reporting the
/// item as failed.
///
/// Deliberately narrow, and deliberately NOT the same list as
/// [isSharingViolation] (which is the Windows story). `ENOENT` is absent on
/// purpose: a source that is gone stays gone, and retrying it would only slow
/// the batch down. `EBUSY`/`EIO` are here because the user's photos live on
/// exFAT volumes served by fskit, a userspace filesystem that -- unlike APFS
/// -- can and does return transient I/O errors under load; the same family
/// produced the transient read faults the image pipeline already retries.
const Set<int> _kTransientRenameErrno = {
  5, // EIO
  16, // EBUSY
  35, // EAGAIN / EWOULDBLOCK
  60, // ETIMEDOUT (network/userspace volumes)
};

/// [retryOnSharingViolation] plus the transient POSIX errno set above.
///
/// Kept here rather than widened inside `file_retry.dart` on purpose: that
/// helper also guards copy and delete on the starred-file batch path, where
/// its narrowness is a deliberate contract ("do not weaken"). Rename is the
/// one operation we have field evidence of failing transiently, so the wider
/// policy stays scoped to it.
Future<void> _renameWithRetry(
  String from,
  String to, {
  RenameFileOp renameFile = _defaultRenameFile,
  CanonicalPathProbe canonicalPath = _canonicalPath,
  List<int> delaysMs = const <int>[20, 40, 80, 160],
}) async {
  // Sampled BEFORE the first attempt, and canonical rather than a bare
  // exists() check, because it answers TWO questions at once.
  //
  // First, the overwrite guard below: the planner's collision fold is a
  // string comparison, and no string comparison can be right on every volume
  // we ship on. APFS is case-insensitive AND normalization-insensitive,
  // exFAT is case-insensitive only, ext4 is neither. The fold case-folds, so
  // an NFD spelling of a name already on disk in NFC compares UNEQUAL in the
  // planner and EQUAL on the volume -- and `File.rename` replaces its
  // destination silently. Measured on this machine, APFS:
  // writing `café.JPG` (NFC, U+00E9) and then renaming an unrelated file
  // onto `café.JPG` (NFD, U+0065 U+0301) leaves ONE file, holding the wrong
  // photo. Evidence: docs/logs/2026-09-03/r2/nfd-realfs-probe.txt.
  // `resolveSymbolicLinks` is realpath(3), so the KERNEL answers the
  // equivalence question for whatever volume this actually is, and no
  // Unicode table has to be shipped or kept up to date.
  //
  // Second, the verify-on-error check further down is only sound if "a file
  // is sitting at the destination" is news. Undo (`undoLastRename`) renames
  // back onto the ORIGINAL names, which no collision check ever cleared, so
  // without this sample an unrelated file occupying an original name would
  // make a genuinely failed undo report success.
  final destinationBefore = await _refuseIfOverwritingOtherFile(
    from,
    to,
    canonicalPath,
  );
  final destinationExistedBefore = destinationBefore != null;
  for (var attempt = 0; ; attempt++) {
    try {
      await retryOnSharingViolation(() => renameFile(from, to));
      return;
    } catch (e) {
      // Verify-on-error. The user's photos live on exFAT served by fskit,
      // which can COMPLETE the metadata operation and still surface EIO. The
      // retry above then finds the source gone and throws ENOENT, which is
      // deliberately not transient, so the plan was recorded as a failure
      // even though the file had in fact moved. Its marks then appeared in
      // neither `idMap` nor `partialIdMap`, were orphaned, and were deleted
      // outright by the next scan's stale-key cleanup
      // (photo_status_store.dart) -- the F1 data-loss shape, re-entered
      // through the retry itself.
      //
      // So: if the source is gone and a destination that was NOT there
      // beforehand now is, the rename landed. Report success and let the
      // caller journal it and remap the marks.
      //
      // A case-only rename on a case-insensitive volume has
      // `destinationExistedBefore == true` (source and destination are the
      // same file), which disables this check. That is the fail-safe
      // direction: such a failure is reported as a failure rather than
      // claimed as a success.
      if (!destinationExistedBefore &&
          await canonicalPath(from) == null &&
          await canonicalPath(to) != null) {
        return;
      }
      final transient =
          e is FileSystemException &&
          _kTransientRenameErrno.contains(e.osError?.errorCode);
      if (!transient || attempt >= delaysMs.length) rethrow;
      await Future<void>.delayed(Duration(milliseconds: delaysMs[attempt]));
      // Re-sample the overwrite guard before retrying. The delay above is
      // exactly the window in which an external process (Finder, an indexer,
      // a second app instance) can create a file at `to` between our first
      // attempt and this retry -- up to ~300ms across the full backoff
      // schedule. Without re-checking here, that external file would be
      // silently destroyed by the retried rename, which is the same
      // data-loss shape the guard above exists to prevent, just reachable
      // through the retry path instead of the first attempt.
      //
      // Deliberately NOT reassigned to `destinationExistedBefore`: that value
      // must keep meaning "was a destination there before we started trying
      // at all", because the verify-on-error success check below relies on
      // that original sample to decide whether a NEW destination appearing
      // means our own rename landed. Only the refusal check is re-armed here.
      await _refuseIfOverwritingOtherFile(from, to, canonicalPath);
    }
  }
}

/// Throws if `to` exists and resolves to a file other than `from`; returns
/// the canonical path of `to` (or null if nothing is there) otherwise.
///
/// Canonical, because the KERNEL is the only correct authority on whether two
/// spellings name the same file: case on APFS and exFAT, Unicode
/// normalization on APFS. Comparing the strings ourselves would need a
/// Unicode table baked into a planner that is deliberately pure and cannot
/// know which volume it is planning for. See the full rationale on the first
/// call site in `_renameWithRetry`.
Future<String?> _refuseIfOverwritingOtherFile(
  String from,
  String to,
  CanonicalPathProbe canonicalPath,
) async {
  final destinationBefore = await canonicalPath(to);
  if (destinationBefore != null) {
    final sourceBefore = await canonicalPath(from);
    // A source that is already gone is ENOENT's business, not ours -- fall
    // through and let the rename report it.
    //
    // `sourceBefore == destinationBefore` means the two paths are the SAME
    // file: a case-only or normalization-only rename, which is legal and
    // which `File.rename` performs in place. That must not be refused.
    if (sourceBefore != null && sourceBefore != destinationBefore) {
      throw FileSystemException(
        'refusing to rename "$from" onto "$to": the destination already '
        'exists and resolves to "$destinationBefore", which is a different '
        'file. Renaming would destroy it.',
        to,
      );
    }
  }
  return destinationBefore;
}

/// Performs one rename. Injectable only so tests can reproduce the
/// "landed on disk but reported an error" fault above: no real filesystem can
/// be asked to produce it on demand, and it is the fault that costs the user
/// their stars and trash marks.
typedef RenameFileOp = Future<void> Function(String from, String to);

Future<void> _defaultRenameFile(String from, String to) async {
  await File(from).rename(to);
}

/// Resolves [path] to its canonical on-disk form, or null if nothing is there.
///
/// Canonical, because the KERNEL is the only correct authority on whether two
/// spellings name the same file: case on APFS and exFAT, Unicode
/// normalization on APFS. Comparing the strings ourselves would need a
/// Unicode table baked into a planner that is deliberately pure and cannot
/// know which volume it is planning for.
typedef CanonicalPathProbe = Future<String?> Function(String path);

Future<String?> _canonicalPath(String path) async {
  try {
    return await File(path).resolveSymbolicLinks();
  } on FileSystemException {
    return null;
  }
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
  @visibleForTesting RenameFileOp renameFile = _defaultRenameFile,
  @visibleForTesting CanonicalPathProbe canonicalPath = _canonicalPath,
}) async {
  final log = File(p.join(dir.path, kRenameLogName));
  final sink = log.openWrite(mode: FileMode.write);
  final failures = <String>[];
  final idMap = <String, String>{};
  final partialIdMap = <String, String>{};
  var renamed = 0;
  var cancelled = false;

  try {
    for (final plan in plans) {
      if (isCancelled?.call() ?? false) {
        cancelled = true;
        break;
      }
      // Counted per plan so a failure on the second file of a RAW+JPG group
      // is reported as PARTIAL rather than as "nothing happened" -- the item
      // now exists under both ids and its marks belong to both.
      var landed = 0;
      try {
        for (final move in plan.moves) {
          await _renameWithRetry(
            move.from,
            move.to,
            renameFile: renameFile,
            canonicalPath: canonicalPath,
          );
          landed++;
          sink.writeln(json.encode({'from': move.from, 'to': move.to}));
        }
        // The doc above promises the journal survives a crash mid-batch. An
        // IOSink buffers, so without this flush that promise was false.
        await sink.flush();
        renamed++;
        idMap[plan.oldId] = plan.newId;
      } catch (e) {
        failures.add('${p.basename(plan.moves.first.from)}: $e');
        if (landed > 0) partialIdMap[plan.oldId] = plan.newId;
        // Flush here too: the moves that DID land are already on disk, so
        // their journal lines must be durable even though the plan failed,
        // or undo cannot put them back.
        await sink.flush();
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
    idMap: idMap,
    partialIdMap: partialIdMap,
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
      .reversed
      .toList();
  final failures = <String>[];
  // newId -> oldId, built from the JOURNAL rather than from anything the
  // caller remembered. The caller's in-memory map is empty after a restart,
  // and undo is exactly the feature a user reaches for on the next launch
  // (F2). The journal is per FILE and the status file is keyed per ITEM, so
  // the several moves of one RAW+JPG group collapse onto one entry here.
  final idMap = <String, String>{};
  var restored = 0;

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    String from;
    String to;
    try {
      final entry = json.decode(line) as Map<String, dynamic>;
      from = entry['from'] as String;
      to = entry['to'] as String;
    } catch (e) {
      // A truncated or hand-edited journal line must not strand the entries
      // below it, and must not stop the log from being deleted -- otherwise
      // undo is wedged forever on a file the user can't see.
      failures.add('line ${lines.length - i}: malformed journal entry');
      continue;
    }
    try {
      await _renameWithRetry(to, from);
      restored++;
      idMap[_baseOf(p.basename(to))] = _baseOf(p.basename(from));
    } catch (e) {
      failures.add('${p.basename(to)}: $e');
    }
  }

  // Also retried: the journal lives in the user's photo folder, so an indexer
  // can hold it just like a photo, and an uncaught throw here would discard the
  // whole undo outcome after the renames already landed.
  await retryOnSharingViolation(() => log.delete());
  return RenameOutcome(
    renamedCount: restored,
    failures: failures,
    cancelled: false,
    idMap: idMap,
  );
}
