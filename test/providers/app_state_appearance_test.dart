// TC-800..TC-804 — appearance persistence, snapshot/revert and reset-all.
//
// Frozen spec: docs/logs/2026-09-02/theme-switcher-spec.md sections 7, 8, 10.
// State-level half of the acceptance checks; the widget-level half lives in
// test/views/settings_appearance_tab_test.dart.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/retention_policy.dart';
import 'package:halcyon_flutter/services/library/photo_export_service.dart';
import 'package:halcyon_flutter/views/layout/layout_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppState> hydrated({Map<String, Object> prefs = const {}}) async {
    SharedPreferences.setMockInitialValues(prefs);
    final state = AppState(retention: const RetentionPolicy.floor());
    addTearDown(state.dispose);
    // _initPrefs is async and fired from the constructor; let it settle.
    await Future<void>.delayed(Duration.zero);
    return state;
  }

  test('TC-800 appearance defaults are system / gallery on a virgin store',
      () async {
    final state = await hydrated();
    expect(state.themeMode, ThemeMode.system);
    expect(state.layoutThemeId, LayoutThemeId.gallery);
    expect(kDefaultThemeMode, ThemeMode.system);
    expect(kDefaultLayoutThemeId, LayoutThemeId.gallery);
  });

  test(
      'TC-801 each setter writes the documented key as an enum name, and a '
      'fresh AppState reads it back', () async {
    final state = await hydrated();
    state.setThemeMode(ThemeMode.dark);
    state.setLayoutThemeId(LayoutThemeId.darkroom);

    // The stored representation is asserted directly, not merely round-
    // tripped: a round trip through this same code would pass even if the
    // key or the encoding drifted from the spec.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('themeMode'), 'dark');
    expect(prefs.getString('layoutThemeId'), 'darkroom');

    final reopened = await hydrated(
      prefs: {'themeMode': 'dark', 'layoutThemeId': 'darkroom'},
    );
    expect(reopened.themeMode, ThemeMode.dark);
    expect(reopened.layoutThemeId, LayoutThemeId.darkroom);
  });

  test('TC-802 unknown or malformed stored appearance values fall back to the '
      'default without throwing', () async {
    final nonsense = await hydrated(
      prefs: {'themeMode': 'chartreuse', 'layoutThemeId': 'polaroid'},
    );
    expect(nonsense.themeMode, ThemeMode.system);
    expect(nonsense.layoutThemeId, LayoutThemeId.gallery);

    // Wrong stored TYPE is the harder case: getString throws a TypeError on a
    // store written by another version, which must not take startup down.
    final wrongType = await hydrated(
      prefs: {'themeMode': 7, 'layoutThemeId': true},
    );
    expect(wrongType.themeMode, ThemeMode.system);
    expect(wrongType.layoutThemeId, LayoutThemeId.gallery);
  });

  test('TC-803 the settings snapshot carries appearance, and restoring puts '
      'both the fields AND the prefs back', () async {
    final state = await hydrated();
    final snapshot = state.settingsSnapshot();
    expect(snapshot.themeMode, ThemeMode.system);
    expect(snapshot.layoutThemeId, LayoutThemeId.gallery);

    state.setThemeMode(ThemeMode.light);
    state.setLayoutThemeId(LayoutThemeId.paper);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('layoutThemeId'), 'paper');

    state.restoreSettings(snapshot);
    expect(state.themeMode, ThemeMode.system);
    expect(state.layoutThemeId, LayoutThemeId.gallery);
    // The persisted value must come back too: reverting memory while leaving
    // the store changed would resurrect the abandoned choice on next launch.
    expect(prefs.getString('themeMode'), 'system');
    expect(prefs.getString('layoutThemeId'), 'gallery');
  });

  test('TC-804 resetAllSettings empties the store and returns every field to '
      'its default', () async {
    final state = await hydrated(prefs: {
      'autoAdvance': true,
      'overwriteExisting': false,
      'decodeLaneWidth': 7,
      'exportJpegQuality': 55,
      'retentionTier': 'generous',
      'themeMode': 'dark',
      'layoutThemeId': 'paper',
    });
    // Guard: the values must really have been loaded, or "reset worked" is
    // indistinguishable from "nothing was ever set".
    expect(state.autoAdvance, isTrue);
    expect(state.layoutThemeId, LayoutThemeId.paper);
    expect(state.decodeLaneWidth, 7);

    await state.resetAllSettings();

    expect(state.themeMode, ThemeMode.system);
    expect(state.layoutThemeId, LayoutThemeId.gallery);
    expect(state.autoAdvance, isFalse);
    expect(state.overwriteExisting, isTrue);
    expect(state.decodeLaneWidth, kDefaultDecodeLaneWidth);
    expect(state.exportJpegQuality, kDefaultExportJpegQuality);
    expect(state.exportFiletype, kDefaultExportFiletype);
    expect(state.isRetentionTierOverridden, isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isEmpty,
        reason: 'reset must clear the store, not merely overwrite the keys '
            'this version happens to know about');
  });

  test('TC-805 resetAllSettings does not touch a photo folder status file',
      () async {
    final dir = await Directory.systemTemp.createTemp('halcyon-reset-test');
    addTearDown(() => dir.delete(recursive: true));
    final statusFile = File('${dir.path}/.halcyon_status.json');
    const contents = '{"marks":{"IMG_0001.jpg":"starred"}}';
    await statusFile.writeAsString(contents);
    final before = await statusFile.lastModified();

    final state = await hydrated(prefs: {'themeMode': 'dark'});
    await state.resetAllSettings();

    expect(await statusFile.exists(), isTrue,
        reason: 'star and trash marks live here and are explicitly out of '
            'reset scope');
    expect(await statusFile.readAsString(), contents);
    expect(await statusFile.lastModified(), before);
  });
}
