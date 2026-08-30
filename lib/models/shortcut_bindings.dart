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
      };

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

  @override
  bool operator ==(Object other) =>
      other is ShortcutBindings &&
      ShortcutAction.values.every((a) => keyFor(a) == other.keyFor(a));

  @override
  int get hashCode => Object.hashAll(ShortcutAction.values.map(keyFor));
}
