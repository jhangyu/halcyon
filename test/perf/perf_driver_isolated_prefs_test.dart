import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/perf/perf_driver.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Transitive of shared_preferences; the store type is the only observable proof
// of isolation, and the public API does not re-export it.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

/// file list + sizes + mtimes of the user's real store directory (null env or
/// missing dir -> empty), so "nothing written" is an observed fact.
Map<String, String> _realStoreSnapshot() {
  final appData = Platform.environment['APPDATA'];
  if (appData == null) return const {};
  final dir = Directory('$appData/jhangy.us/Halcyon');
  if (!dir.existsSync()) return const {};
  return {
    for (final f in dir.listSync(recursive: true).whereType<File>())
      f.path: '${f.lengthSync()}|${f.lastModifiedSync().microsecondsSinceEpoch}',
  };
}

void main() {
  test('TC-1454 a measurement run hydrates from HALCYON_PERF_PREFS in memory '
      'and rejects value types it cannot pin', () async {
    PerfDriver.installIsolatedPrefs('{"decodeLaneWidth":5,"autoAdvance":true}');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('decodeLaneWidth'), 5);
    expect(prefs.getBool('autoAdvance'), isTrue);

    expect(() => PerfDriver.installIsolatedPrefs('{"decodeLaneWidth":[5]}'),
        throwsArgumentError);
  });

  test('TC-1454 isolation: the store is in-memory, writes never reach the '
      'real shared_preferences location', () async {
    final before = _realStoreSnapshot();
    PerfDriver.installIsolatedPrefs('{}');
    expect(SharedPreferencesStorePlatform.instance,
        isA<InMemorySharedPreferencesStore>());

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('decodeLaneWidth', 9);
    await prefs.setString('probe', 'x');
    expect(prefs.getInt('decodeLaneWidth'), 9);
    expect(SharedPreferencesStorePlatform.instance,
        isA<InMemorySharedPreferencesStore>());
    expect(await SharedPreferencesStorePlatform.instance.getAll(),
        containsPair('flutter.decodeLaneWidth', 9));

    expect(_realStoreSnapshot(), before);
  });
}
