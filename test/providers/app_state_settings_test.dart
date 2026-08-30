import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:halcyon_flutter/models/shortcut_bindings.dart';
import 'package:halcyon_flutter/providers/app_state.dart';
import 'package:halcyon_flutter/services/image_pipeline/retention_policy.dart';
import 'package:halcyon_flutter/services/library/photo_export_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppState> hydrated({
    Map<String, Object> prefs = const {},
    RetentionPolicy retention = const RetentionPolicy.floor(),
    int laneCeiling = 5,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    final state = AppState(retention: retention, laneCeiling: laneCeiling);
    addTearDown(state.dispose);
    // _initPrefs is async and fired from the constructor; let it settle.
    await Future<void>.delayed(Duration.zero);
    return state;
  }

  test('TC-449 hydrates every new setting, and falls back PER FIELD on garbage', () async {
    final good = await hydrated(prefs: {
      'exportJpegQuality': 75,
      'retentionTier': 'generous',
      'shortcut.starPhoto': LogicalKeyboardKey.keyF.keyId,
    });
    expect(good.exportJpegQuality, 75);
    expect(good.retentionTier, RetentionTier.generous);
    expect(good.shortcutBindings.keyFor(ShortcutAction.starPhoto), LogicalKeyboardKey.keyF);
    expect(good.shortcutBindings.keyFor(ShortcutAction.nextPhoto),
        LogicalKeyboardKey.arrowRight, reason: 'untouched actions keep defaults');

    final bad = await hydrated(prefs: {
      'exportJpegQuality': 'not an int',
      'retentionTier': 'nonsense',
      'shortcut.starPhoto': 'not an int',
    });
    expect(bad.exportJpegQuality, 90);
    expect(bad.retentionTier, RetentionTier.conservative, reason: 'unknown id = auto');
    expect(bad.isRetentionTierOverridden, isFalse);
    expect(bad.shortcutBindings.keyFor(ShortcutAction.starPhoto), LogicalKeyboardKey.keyS);
  });

  test('TC-450 export quality is normalised to a 5-step in 50..100 (round 2: '
      'floor dropped from 70) and persisted', () async {
    final state = await hydrated();
    state.setExportJpegQuality(73);
    expect(state.exportJpegQuality, 75);
    state.setExportJpegQuality(200);
    expect(state.exportJpegQuality, 100);
    state.setExportJpegQuality(12);
    expect(state.exportJpegQuality, 50);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('exportJpegQuality'), 50);
  });

  test('TC-468 export long edge hydrates, is set-membership normalised '
      '(not rounded to nearest), and persists', () async {
    final good = await hydrated(prefs: {'exportLongEdge': 1440});
    expect(good.exportLongEdge, 1440);

    final missing = await hydrated();
    expect(missing.exportLongEdge, 2048, reason: 'default stop');

    final garbageType = await hydrated(prefs: {'exportLongEdge': 'nope'});
    expect(garbageType.exportLongEdge, 2048);

    final notAStop = await hydrated(prefs: {'exportLongEdge': 1999});
    expect(notAStop.exportLongEdge, 2048,
        reason: 'unrecognised values fall back to the default, they do not '
            'snap to the nearest stop');

    final state = await hydrated();
    state.setExportLongEdge(480);
    expect(state.exportLongEdge, 480);
    state.setExportLongEdge(0);
    expect(state.exportLongEdge, 0, reason: 'Original sentinel round-trips');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('exportLongEdge'), 0);
  });

  // TC-476 (UPDATED 2026-08-30, codec expansion): availability is no longer
  // a compile-time `ExportFiletype.available` flag -- it is
  // `AppState.selectableExportFiletypes`, resolved once at startup by
  // [AppState.resolveExportCapabilities] probing the real native library
  // (ruling Q4). `flutter test` cannot resolve the ceyx dylib, so in THIS
  // suite every non-JPEG format resolves runtime-unavailable and hydration
  // always settles on the default -- deterministic once
  // `resolveExportCapabilities` is awaited explicitly rather than raced via
  // the bare `Future<void>.delayed(Duration.zero)` inside `hydrated()`. The
  // WITH-capability path (a persisted/selected non-default name actually
  // sticking) is covered by `AppState.forTesting` in
  // `settings_dialog_test.dart` TC-477 and
  // `photo_export_service_test.dart`'s "codec expansion" group.
  test('TC-476 export filetype hydrates by name, then falls back to the '
      'default once runtime capability resolves (no dylib in this test '
      'environment); persists by name', () async {
    final good = await hydrated(prefs: {'exportFiletype': 'webpLossy'});
    await good.resolveExportCapabilities();
    expect(good.exportFiletype, ExportFiletype.jpeg);

    final missing = await hydrated();
    await missing.resolveExportCapabilities();
    expect(missing.exportFiletype, ExportFiletype.jpeg);

    final garbage = await hydrated(prefs: {'exportFiletype': 'not-a-type'});
    await garbage.resolveExportCapabilities();
    expect(garbage.exportFiletype, ExportFiletype.jpeg);

    final unavailable = await hydrated(prefs: {'exportFiletype': 'heif'});
    await unavailable.resolveExportCapabilities();
    expect(unavailable.exportFiletype, ExportFiletype.jpeg,
        reason: 'a recognised-but-runtime-unavailable name must fall back '
            'too, not just an unrecognised one');

    final state = await hydrated();
    await state.resolveExportCapabilities();
    // setExportFiletype refuses a runtime-unavailable value -- defence in
    // depth alongside the hydration guard. JPEG is the only format this
    // dylib-less test run ever resolves as selectable, so it is the only
    // value that can round-trip through persistence here.
    state.setExportFiletype(ExportFiletype.jpeg);
    expect(state.exportFiletype, ExportFiletype.jpeg);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('exportFiletype'), 'jpeg');

    state.setExportFiletype(ExportFiletype.heif);
    expect(state.exportFiletype, ExportFiletype.jpeg);
  });

  test('TC-451 the tier reaches the pipeline, and reset returns to the auto tier', () async {
    final state = await hydrated(
      retention: retentionPolicyForTier(RetentionTier.balanced),
    );
    expect(state.retentionTier, RetentionTier.balanced);
    expect(state.isRetentionTierOverridden, isFalse);

    state.setRetentionTier(RetentionTier.generous);
    expect(state.retentionPolicy.after, 11);
    expect(state.retentionPolicy.payloadByteBudget, 512 * 1024 * 1024);
    expect(state.isRetentionTierOverridden, isTrue);

    state.resetRetentionTierToAuto();
    expect(state.retentionTier, RetentionTier.balanced);
    expect(state.retentionPolicy.after, 8);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('retentionTier'), isNull);
  });

  test('TC-452 restoreSettings reverts state AND prefs for every field', () async {
    final state = await hydrated();
    final before = state.settingsSnapshot();

    state.setAutoAdvance(true);
    state.setOverwriteExisting(false);
    state.setDecodeLaneWidth(5);
    state.setExportJpegQuality(70);
    state.setExportLongEdge(480);
    state.setExportFiletype(ExportFiletype.webpLossy);
    state.setRetentionTier(RetentionTier.generous);
    state.setShortcutBinding(ShortcutAction.starPhoto, LogicalKeyboardKey.keyF);

    state.restoreSettings(before);

    expect(state.autoAdvance, before.autoAdvance);
    expect(state.overwriteExisting, before.overwriteExisting);
    expect(state.decodeLaneWidth, before.decodeLaneWidth);
    expect(state.exportJpegQuality, before.exportJpegQuality);
    expect(state.exportLongEdge, before.exportLongEdge);
    expect(state.exportFiletype, before.exportFiletype);
    expect(state.isRetentionTierOverridden, isFalse);
    expect(state.shortcutBindings, ShortcutBindings.defaults());

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('retentionTier'), isNull);
    expect(prefs.getInt('shortcut.starPhoto'), isNull);
    expect(prefs.getInt('exportJpegQuality'), before.exportJpegQuality);
    expect(prefs.getInt('exportLongEdge'), before.exportLongEdge);
    expect(prefs.getString('exportFiletype'), before.exportFiletype.name);
  });
}
