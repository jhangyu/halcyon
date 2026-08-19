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
