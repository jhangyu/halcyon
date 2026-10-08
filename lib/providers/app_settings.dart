import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/shortcut_bindings.dart';
import '../services/image_pipeline/retention_policy.dart';
import '../services/library/photo_export_service.dart';
// LAYERING NOTE: this is the one view-layer import in the settings model.
// `LayoutThemeId` is a plain enum with no widget dependencies, and it is
// declared beside the `LayoutTheme` contract it selects (deleting a theme =
// deleting its directory and its enum case, the deletion contract in
// layout_theme.dart). Persisting the id here is what the frozen appearance
// spec section 8 asks for; moving the enum into models/ purely to satisfy
// import direction would split that deletion contract across two directories
// for no behavioural gain. (This is also why this file lives in providers/,
// not models/.)
import '../views/layout/layout_theme.dart' show LayoutThemeId;

/// Appearance defaults (frozen spec section 8). Named constants rather than
/// literals because three places must agree: the hydration fallback, the
/// malformed-value fallback, and `AppState.resetAllSettings`.
const ThemeMode kDefaultThemeMode = ThemeMode.system;
const LayoutThemeId kDefaultLayoutThemeId = LayoutThemeId.gallery;
const MouseNavMapping kDefaultMouseNavMapping = MouseNavMapping.leftNext;

/// Which button goes to the next photo (spec §1.2).
enum MouseNavMapping { leftNext, leftPrevious }

/// copyWith sentinel: lets `copyWith(retentionTierOverride: null)` CLEAR the
/// override instead of meaning "keep".
const Object _unset = Object();

/// Every persisted, panel-changeable setting, as one immutable value.
///
/// It is also the settings dialog's revert snapshot: the panel applies live
/// (so lane width and retention are a real preview), which only works if
/// Cancel can put every field back -- including the persisted prefs.
///
/// [exportFiletype] is the EFFECTIVE (runtime-gated) value. The user's
/// pending intent is deliberately NOT a field here: it stays on AppState, so
/// a dialog revert keeps the pre-refactor intent semantics exactly.
@immutable
class AppSettings {
  const AppSettings({
    required this.themeMode,
    required this.layoutThemeId,
    required this.autoAdvance,
    required this.overwriteExisting,
    required this.decodeLaneWidth,
    required this.exportJpegQuality,
    required this.exportLongEdge,
    required this.exportFiletype,
    required this.retentionTierOverride,
    required this.shortcuts,
    required this.mouseNavEnabled,
    required this.mouseNavMapping,
  });

  factory AppSettings.defaults() => AppSettings(
        themeMode: kDefaultThemeMode,
        layoutThemeId: kDefaultLayoutThemeId,
        autoAdvance: false,
        overwriteExisting: true,
        decodeLaneWidth: kDefaultDecodeLaneWidth,
        exportJpegQuality: kDefaultExportJpegQuality,
        exportLongEdge: kDefaultExportLongEdge,
        exportFiletype: kDefaultExportFiletype,
        retentionTierOverride: null,
        shortcuts: ShortcutBindings.defaults(),
        mouseNavEnabled: false,
        mouseNavMapping: kDefaultMouseNavMapping,
      );

  /// Appearance applies live like every other setting, so Cancel has to be
  /// able to put both of these back (frozen spec section 7).
  final ThemeMode themeMode;
  final LayoutThemeId layoutThemeId;

  final bool autoAdvance;
  final bool overwriteExisting;
  final int decodeLaneWidth;
  final int exportJpegQuality;
  final int exportLongEdge;
  final ExportFiletype exportFiletype;

  /// Null means "no override, follow the machine-derived tier".
  final RetentionTier? retentionTierOverride;
  final ShortcutBindings shortcuts;
  final bool mouseNavEnabled;
  final MouseNavMapping mouseNavMapping;

  AppSettings copyWith({
    ThemeMode? themeMode,
    LayoutThemeId? layoutThemeId,
    bool? autoAdvance,
    bool? overwriteExisting,
    int? decodeLaneWidth,
    int? exportJpegQuality,
    int? exportLongEdge,
    ExportFiletype? exportFiletype,
    Object? retentionTierOverride = _unset,
    ShortcutBindings? shortcuts,
    bool? mouseNavEnabled,
    MouseNavMapping? mouseNavMapping,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        layoutThemeId: layoutThemeId ?? this.layoutThemeId,
        autoAdvance: autoAdvance ?? this.autoAdvance,
        overwriteExisting: overwriteExisting ?? this.overwriteExisting,
        decodeLaneWidth: decodeLaneWidth ?? this.decodeLaneWidth,
        exportJpegQuality: exportJpegQuality ?? this.exportJpegQuality,
        exportLongEdge: exportLongEdge ?? this.exportLongEdge,
        exportFiletype: exportFiletype ?? this.exportFiletype,
        retentionTierOverride: identical(retentionTierOverride, _unset)
            ? this.retentionTierOverride
            : retentionTierOverride as RetentionTier?,
        shortcuts: shortcuts ?? this.shortcuts,
        mouseNavEnabled: mouseNavEnabled ?? this.mouseNavEnabled,
        mouseNavMapping: mouseNavMapping ?? this.mouseNavMapping,
      );

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.themeMode == themeMode &&
      other.layoutThemeId == layoutThemeId &&
      other.autoAdvance == autoAdvance &&
      other.overwriteExisting == overwriteExisting &&
      other.decodeLaneWidth == decodeLaneWidth &&
      other.exportJpegQuality == exportJpegQuality &&
      other.exportLongEdge == exportLongEdge &&
      other.exportFiletype == exportFiletype &&
      other.retentionTierOverride == retentionTierOverride &&
      other.shortcuts == shortcuts &&
      other.mouseNavEnabled == mouseNavEnabled &&
      other.mouseNavMapping == mouseNavMapping;

  @override
  int get hashCode => Object.hash(
        themeMode,
        layoutThemeId,
        autoAdvance,
        overwriteExisting,
        decodeLaneWidth,
        exportJpegQuality,
        exportLongEdge,
        exportFiletype,
        retentionTierOverride,
        shortcuts,
        mouseNavEnabled,
        mouseNavMapping,
      );
}

/// THE prefs key table and the read/write rules for [AppSettings]. String
/// literals for these keys exist nowhere else. Shortcut keys stay
/// [ShortcutAction.prefsKey] (one key per action).
abstract final class SettingsCodec {
  static const kAutoAdvance = 'autoAdvance';
  static const kOverwriteExisting = 'overwriteExisting';
  static const kDecodeLaneWidth = 'decodeLaneWidth';
  static const kExportJpegQuality = 'exportJpegQuality';
  static const kExportLongEdge = 'exportLongEdge';
  static const kExportFiletype = 'exportFiletype';
  static const kThemeMode = 'themeMode';
  static const kLayoutThemeId = 'layoutThemeId';
  static const kRetentionTier = 'retentionTier';
  static const kMouseNavEnabled = 'mouseNavEnabled';
  static const kMouseNavMapping = 'mouseNavMapping';

  /// Hydration. Each read stands alone: a corrupt export quality must not take
  /// down the retention tier, and one bad shortcut entry costs one binding.
  ///
  /// The two `getBool` reads are deliberately UNGUARDED, exactly as before
  /// this codec existed: a wrong-typed bool key throws out of hydration.
  /// Wrapping them would be a behaviour change. New bool keys use `_readBool`
  /// (no legacy to preserve).
  ///
  /// Returns the stored export-filetype NAME separately as the user's intent:
  /// runtime capability is not known yet at hydration, so the effective value
  /// may be downgraded here and re-normalised from the intent later.
  static ({AppSettings settings, String? exportFiletypeIntentName}) read(
    SharedPreferences? prefs, {
    required List<ExportFiletype> selectableFiletypes,
  }) {
    final autoAdvance = prefs?.getBool(kAutoAdvance) ?? false;
    final overwriteExisting = prefs?.getBool(kOverwriteExisting) ?? true;
    // Clamp on READ, not only on write: a stored value outside the allowed
    // range (corrupt, or written by another build) must not be applied
    // verbatim.
    final decodeLaneWidth = clampLaneWidth(
      _readInt(prefs, kDecodeLaneWidth) ?? kDefaultDecodeLaneWidth,
    );
    final exportJpegQuality =
        normaliseQuality(_readInt(prefs, kExportJpegQuality));
    final exportLongEdge = normaliseLongEdge(_readInt(prefs, kExportLongEdge));
    final intentName = _readString(prefs, kExportFiletype);
    final exportFiletype = normaliseFiletype(intentName, selectableFiletypes);
    final themeMode = themeModeFromName(_readString(prefs, kThemeMode));
    final layoutThemeId =
        layoutThemeIdFromName(_readString(prefs, kLayoutThemeId));
    final tierId = _readString(prefs, kRetentionTier);
    final retentionTierOverride =
        tierId == null ? null : retentionTierFromId(tierId);
    final mouseNavEnabled = _readBool(prefs, kMouseNavEnabled) ?? false;
    final mouseNavMapping =
        mouseNavMappingFromName(_readString(prefs, kMouseNavMapping));

    var shortcuts = ShortcutBindings.defaults();
    for (final action in ShortcutAction.values) {
      final keyId = _readInt(prefs, action.prefsKey);
      if (keyId != null) {
        // An unknown keyId yields a synthetic key that matches nothing; that
        // is strictly better than dropping the other bindings.
        shortcuts = shortcuts.withBinding(action, LogicalKeyboardKey(keyId));
      }
    }

    return (
      settings: AppSettings(
        themeMode: themeMode,
        layoutThemeId: layoutThemeId,
        autoAdvance: autoAdvance,
        overwriteExisting: overwriteExisting,
        decodeLaneWidth: decodeLaneWidth,
        exportJpegQuality: exportJpegQuality,
        exportLongEdge: exportLongEdge,
        exportFiletype: exportFiletype,
        retentionTierOverride: retentionTierOverride,
        shortcuts: shortcuts,
        mouseNavEnabled: mouseNavEnabled,
        mouseNavMapping: mouseNavMapping,
      ),
      exportFiletypeIntentName: intentName,
    );
  }

  /// Writes exactly the fields that differ between [old] and [next]
  /// (fire-and-forget, as every setter always was).
  ///
  /// - exportFiletype persists the EFFECTIVE name, never the intent: a
  ///   pending intent is deliberately lost across restart.
  /// - A null retention override REMOVES the key (never a sentinel value).
  /// - A shortcut set back to its default REMOVES its key; any other binding
  ///   writes its keyId.
  static void persistDiff(
    SharedPreferences? prefs,
    AppSettings old,
    AppSettings next,
  ) {
    if (prefs == null) return;
    if (old.autoAdvance != next.autoAdvance) {
      prefs.setBool(kAutoAdvance, next.autoAdvance);
    }
    if (old.overwriteExisting != next.overwriteExisting) {
      prefs.setBool(kOverwriteExisting, next.overwriteExisting);
    }
    if (old.decodeLaneWidth != next.decodeLaneWidth) {
      prefs.setInt(kDecodeLaneWidth, next.decodeLaneWidth);
    }
    if (old.exportJpegQuality != next.exportJpegQuality) {
      prefs.setInt(kExportJpegQuality, next.exportJpegQuality);
    }
    if (old.exportLongEdge != next.exportLongEdge) {
      prefs.setInt(kExportLongEdge, next.exportLongEdge);
    }
    if (old.exportFiletype != next.exportFiletype) {
      prefs.setString(kExportFiletype, next.exportFiletype.name);
    }
    if (old.themeMode != next.themeMode) {
      prefs.setString(kThemeMode, next.themeMode.name);
    }
    if (old.layoutThemeId != next.layoutThemeId) {
      prefs.setString(kLayoutThemeId, next.layoutThemeId.name);
    }
    if (old.mouseNavEnabled != next.mouseNavEnabled) {
      prefs.setBool(kMouseNavEnabled, next.mouseNavEnabled);
    }
    if (old.mouseNavMapping != next.mouseNavMapping) {
      prefs.setString(kMouseNavMapping, next.mouseNavMapping.name);
    }
    if (old.retentionTierOverride != next.retentionTierOverride) {
      final tier = next.retentionTierOverride;
      if (tier == null) {
        prefs.remove(kRetentionTier);
      } else {
        prefs.setString(kRetentionTier, tier.id);
      }
    }
    for (final action in ShortcutAction.values) {
      final key = next.shortcuts.keyFor(action);
      if (old.shortcuts.keyFor(action) == key) continue;
      if (key == action.defaultKey) {
        prefs.remove(action.prefsKey);
      } else {
        prefs.setInt(action.prefsKey, key.keyId);
      }
    }
  }

  /// Snap to a 5-step, clamp to 50..100; null = default.
  static int normaliseQuality(int? raw) => raw == null
      ? kDefaultExportJpegQuality
      : ((raw / 5).round() * 5).clamp(50, 100);

  /// Unlike quality, the size stops are not evenly spaced (and 0 is a
  /// sentinel, not a size), so this is a set-membership check rather than a
  /// round-to-nearest -- an unrecognised value falls back to the default
  /// instead of snapping to a neighbour.
  static int normaliseLongEdge(int? raw) =>
      raw != null && kExportLongEdgeStops.contains(raw)
          ? raw
          : kDefaultExportLongEdge;

  /// Falls back to the default for a garbage/unknown name AND for a
  /// recognised-but-runtime-unavailable one (not in [selectable]): a value
  /// this build cannot encode must never be applied, whether it arrived from
  /// a corrupt pref or from a build whose capability set differs.
  static ExportFiletype normaliseFiletype(
    String? raw,
    List<ExportFiletype> selectable,
  ) {
    for (final type in ExportFiletype.values) {
      if (type.name == raw) {
        return selectable.contains(type) ? type : kDefaultExportFiletype;
      }
    }
    return kDefaultExportFiletype;
  }

  /// Unknown / malformed stored values fall back to the default rather than
  /// throwing.
  static ThemeMode themeModeFromName(String? raw) {
    for (final mode in ThemeMode.values) {
      if (mode.name == raw) return mode;
    }
    return kDefaultThemeMode;
  }

  static LayoutThemeId layoutThemeIdFromName(String? raw) {
    for (final id in LayoutThemeId.values) {
      if (id.name == raw) return id;
    }
    return kDefaultLayoutThemeId;
  }

  static MouseNavMapping mouseNavMappingFromName(String? raw) {
    for (final mapping in MouseNavMapping.values) {
      if (mapping.name == raw) return mapping;
    }
    return kDefaultMouseNavMapping;
  }

  static int clampLaneWidth(int raw) => raw.clamp(1, kMaxDecodeLaneWidth);

  /// getInt/getString throw a TypeError when the stored value was written
  /// under a different type (a corrupted or hand-edited prefs store); one
  /// guarded-read idiom instead of a try/catch per field.
  static int? _readInt(SharedPreferences? prefs, String key) {
    try {
      return prefs?.getInt(key);
    } catch (_) {
      return null; // wrong stored type; fall back to the default
    }
  }

  static bool? _readBool(SharedPreferences? prefs, String key) {
    try {
      return prefs?.getBool(key);
    } catch (_) {
      return null; // wrong stored type; fall back to the default
    }
  }

  static String? _readString(SharedPreferences? prefs, String key) {
    try {
      return prefs?.getString(key);
    } catch (_) {
      return null;
    }
  }
}
