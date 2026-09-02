import 'package:flutter/services.dart';

/// Every remappable action, in the order that is the app's canonical order.
///
/// DECLARATION ORDER IS LOAD-BEARING, twice over: it is the order the settings
/// panel lists rows in, and it is the tie-break when two actions share a key.
/// Conflicting bindings are ALLOWED (the panel warns, it does not block), so a
/// deterministic winner is a requirement, not a nicety.
enum ShortcutAction {
  previousPhoto,
  nextPhoto,
  starPhoto,
  trashMarkPhoto,
  zoomIn,
  zoomOut,
  toggleRecycleMode,
  openFolder,
}

extension ShortcutActionMeta on ShortcutAction {
  String get id => name; // enum name IS the persisted id

  String get label => switch (this) {
        ShortcutAction.previousPhoto => 'Previous photo',
        ShortcutAction.nextPhoto => 'Next photo',
        ShortcutAction.starPhoto => 'Star photo',
        ShortcutAction.trashMarkPhoto => 'Trash-mark photo',
        ShortcutAction.zoomIn => 'Zoom in',
        ShortcutAction.zoomOut => 'Zoom out',
        ShortcutAction.toggleRecycleMode => 'Toggle recycle mode',
        ShortcutAction.openFolder => 'Open folder',
      };

  /// Exactly the chain this replaced (main_screen.dart:104-128).
  LogicalKeyboardKey get defaultKey => switch (this) {
        ShortcutAction.previousPhoto => LogicalKeyboardKey.arrowLeft,
        ShortcutAction.nextPhoto => LogicalKeyboardKey.arrowRight,
        ShortcutAction.starPhoto => LogicalKeyboardKey.keyS,
        ShortcutAction.trashMarkPhoto => LogicalKeyboardKey.keyX,
        ShortcutAction.zoomIn => LogicalKeyboardKey.arrowUp,
        ShortcutAction.zoomOut => LogicalKeyboardKey.arrowDown,
        ShortcutAction.toggleRecycleMode => LogicalKeyboardKey.keyR,
        ShortcutAction.openFolder => LogicalKeyboardKey.keyO,
      };

  /// Whether this action only ever fires with a modifier held (Cmd on
  /// macOS, Ctrl elsewhere — both activators are always live, matching the
  /// two hard-coded `SingleActivator`s this replaced in gallery_desktop.dart;
  /// see [ShortcutBindings.actionForChord]). Every other action is the
  /// opposite: it must NOT fire while a modifier is held, so a user typing
  /// Cmd+O for the folder picker can never also fire e.g. `starPhoto` if it
  /// happened to share the bound key.
  bool get requiresModifier => this == ShortcutAction.openFolder;

  String get prefsKey => 'shortcut.$id';
}

ShortcutAction? shortcutActionFromId(String id) {
  for (final action in ShortcutAction.values) {
    if (action.id == id) return action;
  }
  return null;
}

/// Keys recording refuses, because the dialog itself needs them.
///
/// Escape cancels recording, Tab traverses, Enter activates the focused
/// button, and a bare modifier can never be a single-key trigger.
///
/// Not `const`: `LogicalKeyboardKey` overrides `==` without primitive
/// equality, which Dart refuses inside a constant set literal. An
/// unmodifiable `final` set is the closest equivalent.
final Set<LogicalKeyboardKey> kReservedShortcutKeys = Set.unmodifiable({
  LogicalKeyboardKey.escape,
  LogicalKeyboardKey.tab,
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.numpadEnter,
  LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftRight,
  LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlRight,
  LogicalKeyboardKey.altLeft, LogicalKeyboardKey.altRight,
  LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaRight,
});

/// The one key-label table, so the chip in the panel and any future surface
/// cannot render the same binding two ways.
String keyLabelFor(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.arrowLeft) return '←';
  if (key == LogicalKeyboardKey.arrowRight) return '→';
  if (key == LogicalKeyboardKey.arrowUp) return '↑';
  if (key == LogicalKeyboardKey.arrowDown) return '↓';
  if (key == LogicalKeyboardKey.space) return 'Space';
  final label = key.keyLabel.toUpperCase();
  return label.isEmpty ? '?' : label;
}

/// An immutable action -> key map. Duplicates are legal; see [conflicts].
class ShortcutBindings {
  const ShortcutBindings(this._map);

  factory ShortcutBindings.defaults() => ShortcutBindings({
        for (final action in ShortcutAction.values) action: action.defaultKey,
      });

  final Map<ShortcutAction, LogicalKeyboardKey> _map;

  LogicalKeyboardKey keyFor(ShortcutAction action) =>
      _map[action] ?? action.defaultKey;

  ShortcutBindings withBinding(ShortcutAction action, LogicalKeyboardKey key) =>
      ShortcutBindings({..._map, action: key});

  ShortcutBindings withDefault(ShortcutAction action) =>
      withBinding(action, action.defaultKey);

  bool isDefault(ShortcutAction action) => keyFor(action) == action.defaultKey;

  bool get hasAnyNonDefault => ShortcutAction.values.any((a) => !isDefault(a));

  /// Keys bound by TWO OR MORE actions, each list in declaration order.
  /// Empty when clean -- the panel renders its warning off this map.
  Map<LogicalKeyboardKey, List<ShortcutAction>> get conflicts {
    final byKey = <LogicalKeyboardKey, List<ShortcutAction>>{};
    for (final action in ShortcutAction.values) {
      byKey.putIfAbsent(keyFor(action), () => []).add(action);
    }
    byKey.removeWhere((_, actions) => actions.length < 2);
    return byKey;
  }

  /// The action a key press fires: the EARLIEST declared action bound to it.
  ShortcutAction? actionFor(LogicalKeyboardKey key) {
    for (final action in ShortcutAction.values) {
      if (keyFor(action) == key) return action;
    }
    return null;
  }

  /// Modifier-aware dispatch (main_screen.dart's real handler). [meta]/
  /// [control] report whether either modifier is currently held, from
  /// `HardwareKeyboard.instance`.
  ///
  /// Actions that [ShortcutActionMeta.requiresModifier] (today: only
  /// [ShortcutAction.openFolder]) fire on their bound key with EITHER meta OR
  /// control held — both chords are always live on every desktop platform,
  /// same as the wrapper this replaced. Every other action fires only when
  /// NEITHER modifier is held, so e.g. Cmd+S can never accidentally fire
  /// `starPhoto` just because its bound key happens to be S. Earliest
  /// declared action still wins a tie, matching [actionFor].
  ShortcutAction? actionForChord(
    LogicalKeyboardKey key, {
    required bool meta,
    required bool control,
  }) {
    for (final action in ShortcutAction.values) {
      if (keyFor(action) != key) continue;
      final modifierHeld = meta || control;
      if (action.requiresModifier == modifierHeld) return action;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is ShortcutBindings &&
      ShortcutAction.values.every((a) => keyFor(a) == other.keyFor(a));

  @override
  int get hashCode => Object.hashAll(ShortcutAction.values.map(keyFor));
}
