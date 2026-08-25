import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../models/photo_item.dart';

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

  bool _loggedCorrupt = false;

  /// The ONE read path for `.halcyon_status.json`.
  ///
  /// A missing file, a `FormatException`, or a decoded value that is not a
  /// JSON object all degrade to an empty map: a corrupt status file must cost
  /// the user their marks, not their ability to open the folder. Logged at
  /// most once per store so a big folder cannot spam the console.
  Future<Map<String, dynamic>> _readJsonMap(File file) async {
    if (!await file.exists()) return <String, dynamic>{};
    try {
      final decoded = json.decode(await file.readAsString());
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (e) {
      if (!_loggedCorrupt) {
        _loggedCorrupt = true;
        // ignore: avoid_print
        print('Halcyon: unreadable ${p.basename(file.path)} ($e); ignoring it');
      }
      return <String, dynamic>{};
    }
    if (!_loggedCorrupt) {
      _loggedCorrupt = true;
      // ignore: avoid_print
      print('Halcyon: ${p.basename(file.path)} is not a JSON object; ignoring it');
    }
    return <String, dynamic>{};
  }

  /// Serialises every mutation on this store. Two independent debounce timers
  /// in AppState (`_saveStatusCache` and `_saveLastViewedId`) both
  /// read-modify-write this one file; without this chain a save that started
  /// earlier can finish later and write back a map that never saw the other's
  /// change.
  Future<void> _writeChain = Future<void>.value();

  Future<T> _serialise<T>(Future<T> Function() action) {
    final result = _writeChain.then((_) => action());
    _writeChain = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// tmp-file + rename, so a crash or a yanked card can never leave a
  /// half-written `.halcyon_status.json` behind. The tmp file sits in the same
  /// directory as the target, which keeps the rename a same-volume metadata
  /// operation.
  Future<void> _atomicWrite(File file, String contents) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(contents, flush: true);
    await tmp.rename(file.path);
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
    final jsonMap = await _readJsonMap(file);
    if (jsonMap.isEmpty) return const PhotoStatusSnapshot();

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

  Future<void> saveStatuses(Directory dir, List<PhotoItem> items) {
    return _serialise(() async {
      final file = statusFileFor(dir);
      final statusMap = <String, String>{};
      final existingJson = await _readJsonMap(file);
      for (final key in reservedKeys) {
        final value = existingJson[key];
        if (value is String) statusMap[key] = value;
      }
      for (final item in items) {
        if (item.status != PhotoStatus.unmarked) {
          statusMap[item.id] = item.status.name;
        }
      }
      await _atomicWrite(file, json.encode(statusMap));
    });
  }

  Future<void> saveLastViewedId(Directory dir, String selectedItemId) {
    return _serialise(() async {
      final file = statusFileFor(dir);
      final jsonMap = await _readJsonMap(file);
      if (jsonMap['_last_viewed_id'] != selectedItemId) {
        jsonMap['_last_viewed_id'] = selectedItemId;
        await _atomicWrite(file, json.encode(jsonMap));
      }
    });
  }

  Future<String?> loadRenameRule(Directory dir) async {
    final jsonMap = await _readJsonMap(statusFileFor(dir));
    final rule = jsonMap[_renameRuleKey];
    return rule is String ? rule : null;
  }

  /// Persists the folder's custom rename rule; [rule] == null removes it
  /// (which is what picking a built-in preset does).
  Future<void> saveRenameRule(Directory dir, String? rule) {
    return _serialise(() async {
      final file = statusFileFor(dir);
      final jsonMap = await _readJsonMap(file);
      if (rule == null) {
        jsonMap.remove(_renameRuleKey);
      } else {
        jsonMap[_renameRuleKey] = rule;
      }
      await _atomicWrite(file, json.encode(jsonMap));
    });
  }

  /// Rewrites photo keys after a rename batch. Without this, every star and
  /// the last-viewed pointer would be orphaned the moment files are renamed,
  /// because this file is keyed by [PhotoItem.id] (the basename).
  Future<void> remapKeys(Directory dir, Map<String, String> oldToNew) {
    return _serialise(() async {
      if (oldToNew.isEmpty) return;
      final file = statusFileFor(dir);
      final jsonMap = await _readJsonMap(file);
      if (jsonMap.isEmpty) return;
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
      await _atomicWrite(file, json.encode(remapped));
    });
  }
}
