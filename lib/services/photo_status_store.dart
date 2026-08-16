import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/photo_item.dart';

class PhotoStatusSnapshot {
  const PhotoStatusSnapshot({this.lastViewedId});

  final String? lastViewedId;
}

class PhotoStatusStore {
  File statusFileFor(Directory dir) {
    return File(p.join(dir.path, '.halcyon_status.json'));
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
      if (key != '_last_viewed_id' && !validKeys.contains(key)) {
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
      final lastViewedId = existingJson['_last_viewed_id'];
      if (lastViewedId is String) {
        statusMap['_last_viewed_id'] = lastViewedId;
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
}
