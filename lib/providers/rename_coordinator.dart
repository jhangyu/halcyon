import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../models/photo_item.dart';
import '../services/library/photo_status_store.dart';
import '../services/rename_rule.dart';
import '../services/rename_service.dart';
import 'app_state.dart' show StatusMessage;

/// Owns the rename domain that used to live directly on `AppState`: renaming
/// a folder's files from EXIF-derived names, the undo journal, and the
/// remembered rule. It reads the app's live item list/selection/directory
/// through supplier callbacks (never copies) because [renameByExif] triggers
/// a mid-flight [reloadFolder] that replaces the whole item list, and
/// [undoRename] must run against post-reload state. See memory.md AD entry
/// for this extraction.
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

  /// old id -> new id for the most recent batch, used to unwind marks on undo.
  Map<String, String> _lastRenameIdMap = const {};

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

      // Assigned only after the early return: an empty batch must not clobber
      // the previous batch's undo map.
      _lastRenameIdMap = {for (final plan in plans) plan.oldId: plan.newId};

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
      await _statusStore.remapKeys(dir, {
        for (final plan in plans) plan.oldId: plan.newId,
      });
      await _statusStore.saveRenameRule(dir, isCustom ? rule.template : null);

      final selectedId = _selectedIdOf();
      final currentPlan = plans.where((x) => x.oldId == selectedId);
      await _reloadFolder(
        dir,
        targetSelectionId: currentPlan.isEmpty
            ? selectedId
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

    // The journal is per FILE; the status file is keyed per ITEM (basename
    // without extension), so remap with the inverse of the batch's id map.
    await _statusStore.remapKeys(dir, {
      for (final entry in _lastRenameIdMap.entries) entry.value: entry.key,
    });
    _lastRenameIdMap = const {};

    await _reloadFolder(dir);
    _showStatus(StatusMessage('已還原 *${outcome.renamedCount}* 個檔案的原始檔名'));
  }
}
