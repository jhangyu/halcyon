import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../../models/photo_item.dart';
import '../library/photo_status_store.dart';
import '../../models/rename_rule.dart';
import 'rename_service.dart';
import '../../providers/app_state.dart' show StatusMessage;

/// Owns the rename domain that used to live directly on `AppState`: renaming
/// a folder's files from EXIF-derived names, the undo journal, and the
/// remembered rule. It reads the app's live item list/selection/directory
/// through supplier callbacks (never copies) because [renameByExif] triggers
/// a mid-flight [reloadFolder] that replaces the whole item list, and
/// [undoRename] must run against post-reload state. See the architecture
/// decision entry for this extraction.
class RenameCoordinator {
  RenameCoordinator({
    required PhotoStatusStore statusStore,
    required List<PhotoItem> Function() itemsOf,
    required Directory? Function() dirOf,
    required String? Function() selectedIdOf,
    required Future<Map<String, ExifMetadata?>> Function(
      List<PhotoItem> items, {
      void Function(int done, int total)? onProgress,
    })
    readMetadata,
    required void Function(StatusMessage message) showStatus,
    required Future<void> Function(Directory dir, {String? targetSelectionId})
    reloadFolder,
    required VoidCallback notify,
  }) : _statusStore = statusStore,
       _itemsOf = itemsOf,
       _dirOf = dirOf,
       _selectedIdOf = selectedIdOf,
       _readMetadata = readMetadata,
       _showStatus = showStatus,
       _reloadFolder = reloadFolder,
       _notify = notify;

  final PhotoStatusStore _statusStore;
  final List<PhotoItem> Function() _itemsOf;
  final Directory? Function() _dirOf;
  final String? Function() _selectedIdOf;
  final Future<Map<String, ExifMetadata?>> Function(
    List<PhotoItem> items, {
    void Function(int done, int total)? onProgress,
  })
  _readMetadata;
  final void Function(StatusMessage message) _showStatus;
  final Future<void> Function(Directory dir, {String? targetSelectionId})
  _reloadFolder;
  final VoidCallback _notify;

  bool _isRenaming = false;
  bool _renameCancelled = false;

  bool get isRenaming => _isRenaming;

  void cancelRename() {
    _renameCancelled = true;
  }

  Future<String?> loadSavedRenameRule() async {
    final dir = _dirOf();
    if (dir == null) return null;
    return _statusStore.loadRenameRule(dir);
  }

  /// Renames every photo in the current folder from [rule]. [isCustom] is
  /// true when the rule came from the editor rather than a built-in preset;
  /// only custom rules are remembered for the folder.
  Future<void> renameByExif(RenameRule rule, {required bool isCustom}) async {
    final dir = _dirOf();
    final items = _itemsOf();
    if (dir == null || items.isEmpty || _isRenaming) return;

    _isRenaming = true;
    _renameCancelled = false;
    _notify();

    try {
      final metadata = await _readMetadata(
        items,
        onProgress: (done, total) {
          _showStatus(StatusMessage('讀取 EXIF *$done/$total*…'));
        },
      );

      final fileModified = <String, DateTime>{};
      final existingNames = <String>{};
      for (final entity in dir.listSync()) {
        existingNames.add(p.basename(entity.path));
      }
      for (final item in items) {
        final file = item.bestFileToLoad;
        if (file == null) continue;
        fileModified[item.id] = file.statSync().modified;
      }

      final plans = planRenames(
        items: items,
        metadata: metadata,
        fileModified: fileModified,
        rule: rule,
        existingNames: existingNames,
      );

      if (plans.isEmpty) {
        _showStatus(const StatusMessage('沒有檔案需要重新命名'));
        return;
      }

      final outcome = await applyRenames(
        plans,
        dir,
        onProgress: (done, total) {
          _showStatus(
            StatusMessage(
              '重新命名 *$done/$total*…',
              actionLabel: '取消',
              onAction: cancelRename,
            ),
          );
        },
        isCancelled: () => _renameCancelled,
      );

      // The status file is keyed by item id (the basename), so without this
      // every star, trash mark and the last-viewed pointer would be orphaned.
      //
      // Driven by the OUTCOME, never by `plans`: a cancelled batch, or one
      // where some renames threw, leaves those files under their original
      // names, and remapping their marks to a name that does not exist
      // orphans them -- after which the next scan's stale-key cleanup deletes
      // them. Half-applied plans exist under BOTH names, so they keep both
      // keys rather than betting on either (F1).
      await _statusStore.remapKeys(
        dir,
        {...outcome.idMap, ...outcome.partialIdMap},
        keepOriginal: outcome.partialIdMap.keys.toSet(),
      );
      await _statusStore.saveRenameRule(dir, isCustom ? rule.template : null);

      final selectedId = _selectedIdOf();
      await _reloadFolder(
        dir,
        targetSelectionId: outcome.idMap[selectedId] ?? selectedId,
      );

      var message = '已重新命名 *${outcome.renamedCount}* 個項目';
      if (outcome.cancelled) message += '（已取消）';
      if (outcome.failures.isNotEmpty) {
        // Named, not just counted. A bare count leaves the user unable to
        // tell WHICH photos kept their old names, which is the whole
        // complaint behind the "second rename pass fixes it" report.
        final named = outcome.failures
            .take(3)
            .map((failure) => failure.split(':').first)
            .join('、');
        message += '，*${outcome.failures.length}* 個失敗：$named';
        if (outcome.failures.length > 3) message += ' …';
        for (final failure in outcome.failures) {
          debugPrint('Rename failure: $failure');
        }
      }
      _showStatus(
        StatusMessage(message, actionLabel: '還原', onAction: undoRename),
      );
    } catch (e) {
      _showStatus(StatusMessage('重新命名失敗：$e'));
    } finally {
      _isRenaming = false;
      _notify();
    }
  }

  /// Replays the folder's rename journal backwards. No-op when there is none.
  Future<void> undoRename() async {
    final dir = _dirOf();
    if (dir == null || _isRenaming) return;

    final logExists = File(p.join(dir.path, kRenameLogName)).existsSync();
    if (!logExists) {
      _showStatus(const StatusMessage('沒有可還原的重新命名紀錄'));
      return;
    }

    final outcome = await undoLastRename(dir);

    // Sourced from the on-disk journal that `undoLastRename` just replayed,
    // NOT from anything this object remembered: undo's whole point is to be
    // available after the app has been closed and reopened, and an in-memory
    // map is empty then -- the files went back to their old names while every
    // mark stayed keyed to the abandoned new ones (F2).
    await _statusStore.remapKeys(dir, outcome.idMap);

    await _reloadFolder(dir);
    _showStatus(StatusMessage('已還原 *${outcome.renamedCount}* 個檔案的原始檔名'));
  }
}
