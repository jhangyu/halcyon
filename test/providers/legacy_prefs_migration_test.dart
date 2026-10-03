// Memory-reclamation campaign M3: one-time import of the shared_preferences
// store orphaned when halcyon 12f5c06 changed the Windows CompanyName and the
// Linux APPLICATION_ID. The layouts below are the real relative positions of
// the old and new stores on each platform (see kLegacyPrefsStoreLocations).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/providers/app_settings.dart';
import 'package:halcyon_flutter/providers/legacy_prefs_migration.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/temp_dirs.dart';

/// The shape of the user's 2026-09-08 store as shared_preferences_windows
/// writes it.
const Map<String, Object> _legacy = {
  'flutter.decodeLaneWidth': 5,
  'flutter.retentionTier': 'balanced',
  'flutter.exportLongEdge': 2048,
  'flutter.exportJpegQuality': 70,
  'flutter.autoAdvance': true,
  'other.notOurs': 'skipped',
};

Future<SharedPreferences> _prefs([Map<String, Object> values = const {}]) {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

Future<({Directory support, File legacy})> _windowsLayout(
    {String? legacyText}) async {
  final root = await makeTempDir('halcyon_m3_');
  final support = Directory(p.join(root.path, 'jhangy.us', 'Halcyon'))
    ..createSync(recursive: true);
  final legacy = File(
      p.join(root.path, 'com.example', 'Halcyon', 'shared_preferences.json'))
    ..createSync(recursive: true)
    ..writeAsStringSync(legacyText ?? jsonEncode(_legacy));
  return (support: support, legacy: legacy);
}

File _marker(Directory support) =>
    File(p.join(support.path, kLegacyPrefsMigrationMarker));

void main() {
  test('TC-1448 empty store + Windows legacy store: values imported through '
      'the setters, marker written, legacy file untouched', () async {
    final layout = await _windowsLayout();
    final before = layout.legacy.readAsBytesSync();
    final prefs = await _prefs();

    final r = await migrateLegacyPrefsStore(
        prefs: prefs, supportDirectory: layout.support);

    expect(r.outcome, LegacyPrefsMigrationOutcome.migrated);
    expect(r.keys, 5, reason: 'the non-flutter. key is not ours');
    expect(p.normalize(r.source!), p.normalize(layout.legacy.path));
    expect(prefs.getInt('decodeLaneWidth'), 5);
    expect(prefs.getString('retentionTier'), 'balanced');
    expect(prefs.getBool('autoAdvance'), isTrue);
    expect(prefs.containsKey('other.notOurs'), isFalse);
    expect(
        SettingsCodec.read(prefs, selectableFiletypes: const [])
            .settings
            .decodeLaneWidth,
        5,
        reason: 'the real hydration codec reads the imported value');
    expect(_marker(layout.support).existsSync(), isTrue);
    expect(layout.legacy.readAsBytesSync(), before,
        reason: 'the legacy file is never modified or deleted');
  });

  test('TC-1449 the SAME routine finds the Linux legacy store (one data list, '
      'no platform branch)', () async {
    final root = await makeTempDir('halcyon_m3_');
    final support = Directory(p.join(root.path, 'share', 'us.jhangy.halcyon'))
      ..createSync(recursive: true);
    File(p.join(root.path, 'share', 'com.example.photo_selector_flutter',
        'shared_preferences.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(_legacy));
    final prefs = await _prefs();

    final r =
        await migrateLegacyPrefsStore(prefs: prefs, supportDirectory: support);

    expect(r.outcome, LegacyPrefsMigrationOutcome.migrated);
    expect(prefs.getInt('decodeLaneWidth'), 5);
  });

  test('TC-1450 a non-empty store is never overwritten', () async {
    final layout = await _windowsLayout();
    final prefs = await _prefs({'decodeLaneWidth': 3});

    final r = await migrateLegacyPrefsStore(
        prefs: prefs, supportDirectory: layout.support);

    expect(r.outcome, LegacyPrefsMigrationOutcome.storeNotEmpty);
    expect(prefs.getInt('decodeLaneWidth'), 3);
    expect(prefs.getKeys(), {'decodeLaneWidth'});
    expect(_marker(layout.support).existsSync(), isTrue);
  });

  test('TC-1451 a corrupt legacy store keeps the defaults and does not throw',
      () async {
    final layout = await _windowsLayout(legacyText: '{not json');
    final prefs = await _prefs();

    final r = await migrateLegacyPrefsStore(
        prefs: prefs, supportDirectory: layout.support);

    expect(r.outcome, LegacyPrefsMigrationOutcome.corruptLegacyStore);
    expect(prefs.getKeys(), isEmpty);
    expect(_marker(layout.support).existsSync(), isTrue);
  });

  test('TC-1452 second launch is a no-op, even after the user resets every '
      'setting (TC-804 empties the store)', () async {
    final layout = await _windowsLayout();
    var prefs = await _prefs();
    await migrateLegacyPrefsStore(
        prefs: prefs, supportDirectory: layout.support);

    await prefs.clear(); // what AppState.resetAllSettings does
    prefs = await _prefs();
    final r = await migrateLegacyPrefsStore(
        prefs: prefs, supportDirectory: layout.support);

    expect(r.outcome, LegacyPrefsMigrationOutcome.alreadyDone);
    expect(prefs.getKeys(), isEmpty,
        reason: 'a reset must not resurrect the 2026-09-08 settings');
  });

  test('TC-1453 no legacy store anywhere: defaults kept, marker written',
      () async {
    final root = await makeTempDir('halcyon_m3_');
    final support =
        Directory(p.join(root.path, 'Library', 'com.jhangyu.halcyon'))
          ..createSync(recursive: true);
    final prefs = await _prefs();

    final r =
        await migrateLegacyPrefsStore(prefs: prefs, supportDirectory: support);

    expect(r.outcome, LegacyPrefsMigrationOutcome.noLegacyStore);
    expect(prefs.getKeys(), isEmpty);
    expect(_marker(support).existsSync(), isTrue);
  });
}
