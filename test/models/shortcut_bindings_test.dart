import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/shortcut_bindings.dart';

void main() {
  test('TC-445 the seven actions carry today\'s seven default keys, in order', () {
    expect(ShortcutAction.values.map((a) => a.defaultKey).toList(), [
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.keyS,
      LogicalKeyboardKey.keyX,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.keyR,
    ]);
    expect(ShortcutAction.trashMarkPhoto.prefsKey, 'shortcut.trashMarkPhoto');
    expect(shortcutActionFromId('zoomIn'), ShortcutAction.zoomIn);
    expect(shortcutActionFromId('nope'), isNull);
  });

  test('TC-446 defaults have no conflicts; a duplicate key is reported once', () {
    final defaults = ShortcutBindings.defaults();
    expect(defaults.conflicts, isEmpty);

    final clashing = defaults.withBinding(
        ShortcutAction.toggleRecycleMode, LogicalKeyboardKey.keyX);
    expect(clashing.conflicts.keys.single, LogicalKeyboardKey.keyX);
    expect(clashing.conflicts[LogicalKeyboardKey.keyX],
        [ShortcutAction.trashMarkPhoto, ShortcutAction.toggleRecycleMode]);
  });

  test('TC-447 a duplicated key dispatches to the earliest action declared', () {
    final clashing = ShortcutBindings.defaults()
        .withBinding(ShortcutAction.toggleRecycleMode, LogicalKeyboardKey.keyX);
    expect(clashing.actionFor(LogicalKeyboardKey.keyX), ShortcutAction.trashMarkPhoto);
    expect(clashing.actionFor(LogicalKeyboardKey.keyQ), isNull);
    expect(clashing.isDefault(ShortcutAction.toggleRecycleMode), isFalse);
    expect(clashing.withDefault(ShortcutAction.toggleRecycleMode), ShortcutBindings.defaults());
  });

  test('TC-448 key labels use arrow glyphs and upper-case letters', () {
    expect(keyLabelFor(LogicalKeyboardKey.arrowLeft), '←');
    expect(keyLabelFor(LogicalKeyboardKey.arrowRight), '→');
    expect(keyLabelFor(LogicalKeyboardKey.arrowUp), '↑');
    expect(keyLabelFor(LogicalKeyboardKey.arrowDown), '↓');
    expect(keyLabelFor(LogicalKeyboardKey.keyS), 'S');
    expect(keyLabelFor(LogicalKeyboardKey.space), 'Space');
    expect(kReservedShortcutKeys, contains(LogicalKeyboardKey.escape));
    expect(kReservedShortcutKeys, contains(LogicalKeyboardKey.tab));
    expect(kReservedShortcutKeys, isNot(contains(LogicalKeyboardKey.keyS)));
  });
}
