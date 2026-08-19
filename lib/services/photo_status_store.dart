import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/photo_item.dart';

class PhotoStatusSnapshot {
  const PhotoStatusSnapshot({this.lastViewedId});

  final String? lastViewedId;
}

class PhotoStatusStore {
  /// Keys in `.halcyon_status.json` that are NOT photo ids. Anything that
  /// rebuilds the map must carry all of them forward, or a later star silently
  /// drops the saved rename rule.
  static const Set<String> reservedKeys = {'_last_viewed_id', '_rename_rule'};

  static const String _renameRuleKey = '_rename_rule';

  File statusFileFor(Directory dir) {
    return File(p.join(dir.path, '.halcyon_status.json'));
  }

  /// A locked SD card mounts read-only, so every status write throws and the
  /// marks vanish on reload. Directory permission bits lie here (exFAT mounts
  /// `noowners`, so the folder still looks like drwx------), so the only
  /// reliable probe is an actual create.
  Future<bool> isWritable(Directory dir) async {
    final probe = File(p.join(dir.path, '.halcyon_write_probe'));
    try {
      await probe.create();
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<PhotoStatusSnapshot> applySavedStatuses(
    Directory dir,
    List<PhotoItem> items,
  ) async {
    final file = statusFileFor(dir);
    if (!await file.exists()) return const PhotoStatusSnapshot();

    final content = await file.readAsString();
    final jsonMap = json.decode(content) as Map<String, dynamic>;
    final validKeys = items.map((item) => item.id).toSet();
    var needsCleanup = false;

    for (final item in items) {
      final savedStatus = jsonMap[item.id] as String?;
      if (savedStatus == null || savedStatus == PhotoStatus.unmarked.name) {
        continue;
      }

      item.status = PhotoStatus.values.firstWhere(
        (status) => status.name == savedStatus,
        orElse: () => PhotoStatus.unmarked,
      );
    }

    for (final key in jsonMap.keys) {
      if (!reservedKeys.contains(key) && !validKeys.contains(key)) {
        needsCleanup = true;
        break;
      }
    }

    if (needsCleanup) {
      await saveStatuses(dir, items);
    }

    return PhotoStatusSnapshot(
      lastViewedId: jsonMap['_last_viewed_id'] as String?,
    );
  }

  Future<void> saveStatuses(Directory dir, List<PhotoItem> items) async {
    final file = statusFileFor(dir);
    final statusMap = <String, String>{};

    if (await file.exists()) {
      final existingContent = await file.readAsString();
      final existingJson = json.decode(existingContent) as Map<String, dynamic>;
      for (final key in reservedKeys) {
        final value = existingJson[key];
        if (value is String) statusMap[key] = value;
      }
    }

    for (final item in items) {
      if (item.status != PhotoStatus.unmarked) {
        statusMap[item.id] = item.status.name;
      }
    }

    await file.writeAsString(json.encode(statusMap));
  }

  Future<void> saveLastViewedId(Directory dir, String selectedItemId) async {
    final file = statusFileFor(dir);
    var jsonMap = <String, dynamic>{};

    if (await file.exists()) {
      final content = await file.readAsString();
      jsonMap = json.decode(content) as Map<String, dynamic>;
    }

    if (jsonMap['_last_viewed_id'] != selectedItemId) {
      jsonMap['_last_viewed_id'] = selectedItemId;
      await file.writeAsString(json.encode(jsonMap));
    }
  }

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
}
