import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where earlier releases kept the shared_preferences store, as path segments
/// relative to the CURRENT application-support directory. ONE list, tried in
/// order on every platform; a location that does not exist on a platform is
/// simply absent there, so there is no platform branch.
///
/// halcyon 12f5c06 (2026-09-12, first shipped in v1.0.10) moved two stores:
///  - Windows: CompanyName com.example -> jhangy.us. The support directory is
///    %APPDATA%\<CompanyName>\<ProductName> (path_provider_windows), so the
///    old store is two levels up, under com.example\Halcyon.
///  - Linux: APPLICATION_ID com.example.photo_selector_flutter ->
///    us.jhangy.halcyon. The support directory is `$XDG_DATA_HOME/<id>`
///    (path_provider_linux), so the old store is one level up.
/// macOS needs no entry: its bundle id has not changed since before v1.0.0,
/// and its store is NSUserDefaults rather than a file.
const List<List<String>> kLegacyPrefsStoreLocations = [
  ['..', '..', 'com.example', 'Halcyon', 'shared_preferences.json'],
  ['..', 'com.example.photo_selector_flutter', 'shared_preferences.json'],
];

/// Written next to the store once the migration has reached a decision. A
/// FILE rather than a prefs key: "reset all settings" clears the store, and a
/// key marker would let the next launch import the legacy settings over the
/// user's reset.
const String kLegacyPrefsMigrationMarker = 'legacy_prefs_migration.done';

enum LegacyPrefsMigrationOutcome {
  alreadyDone,
  storeNotEmpty,
  noLegacyStore,
  corruptLegacyStore,
  migrated,
  failed,
}

typedef LegacyPrefsMigrationResult = ({
  LegacyPrefsMigrationOutcome outcome,
  String? source,
  int keys,
});

const String _flutterKeyPrefix = 'flutter.';

/// One-time import of a legacy store into an EMPTY current store, through the
/// typed setters of [prefs] (the singleton AppState hydrates from), so the
/// values are visible without a restart. Never modifies the legacy file.
/// Never throws: an unexpected error returns
/// [LegacyPrefsMigrationOutcome.failed] WITHOUT the marker, so the next launch
/// retries.
Future<LegacyPrefsMigrationResult> migrateLegacyPrefsStore({
  required SharedPreferences prefs,
  required Directory supportDirectory,
  List<List<String>> legacyLocations = kLegacyPrefsStoreLocations,
}) async {
  final marker = File(
    p.join(supportDirectory.path, kLegacyPrefsMigrationMarker),
  );
  try {
    if (marker.existsSync()) {
      return (
        outcome: LegacyPrefsMigrationOutcome.alreadyDone,
        source: null,
        keys: 0,
      );
    }
    if (prefs.getKeys().isNotEmpty) {
      await marker.writeAsString('');
      return (
        outcome: LegacyPrefsMigrationOutcome.storeNotEmpty,
        source: null,
        keys: 0,
      );
    }
    for (final segments in legacyLocations) {
      final path = p.normalize(p.joinAll([supportDirectory.path, ...segments]));
      final file = File(path);
      if (!file.existsSync()) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(await file.readAsString());
      } on FormatException {
        decoded = null;
      }
      if (decoded is! Map<String, dynamic>) {
        await marker.writeAsString('');
        return (
          outcome: LegacyPrefsMigrationOutcome.corruptLegacyStore,
          source: path,
          keys: 0,
        );
      }
      final keys = await _copyInto(prefs, decoded);
      await marker.writeAsString('');
      return (
        outcome: LegacyPrefsMigrationOutcome.migrated,
        source: path,
        keys: keys,
      );
    }
    await marker.writeAsString('');
    return (
      outcome: LegacyPrefsMigrationOutcome.noLegacyStore,
      source: null,
      keys: 0,
    );
  } catch (_) {
    return (outcome: LegacyPrefsMigrationOutcome.failed, source: null, keys: 0);
  }
}

Future<int> _copyInto(
  SharedPreferences prefs,
  Map<String, dynamic> legacy,
) async {
  var copied = 0;
  for (final MapEntry(:key, :value) in legacy.entries) {
    if (!key.startsWith(_flutterKeyPrefix)) continue;
    final name = key.substring(_flutterKeyPrefix.length);
    final written = switch (value) {
      bool v => await prefs.setBool(name, v),
      int v => await prefs.setInt(name, v),
      double v => await prefs.setDouble(name, v),
      String v => await prefs.setString(name, v),
      List<dynamic> v when v.every((e) => e is String) =>
        await prefs.setStringList(name, v.cast<String>()),
      _ => false,
    };
    if (written) copied++;
  }
  return copied;
}

/// Production entry, called once from `main()` before AppState exists. Prints
/// exactly one line, which release acceptance reads.
Future<void> runLegacyPrefsMigration() async {
  try {
    final r = await migrateLegacyPrefsStore(
      prefs: await SharedPreferences.getInstance(),
      supportDirectory: await getApplicationSupportDirectory(),
    );
    debugPrint(
      'prefs.migration|outcome=${r.outcome.name}'
      '|source=${r.source}|keys=${r.keys}',
    );
  } catch (error) {
    debugPrint('prefs.migration|outcome=failed|error=$error');
  }
}
