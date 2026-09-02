import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon_flutter/models/shortcut_bindings.dart';

void main() {
  test('TC-445 the eight actions carry today\'s eight default keys, in order', () {
    expect(ShortcutAction.values.map((a) => a.defaultKey).toList(), [
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.keyS,
      LogicalKeyboardKey.keyX,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.keyR,
      LogicalKeyboardKey.keyO,
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

  test('TC-550 actionForChord: openFolder fires on either modifier, never '
      'unmodified; other actions fire only unmodified', () {
    final defaults = ShortcutBindings.defaults();

    // openFolder (bound to O by default) requires a modifier.
    expect(
      defaults.actionForChord(LogicalKeyboardKey.keyO, meta: true, control: false),
      ShortcutAction.openFolder,
    );
    expect(
      defaults.actionForChord(LogicalKeyboardKey.keyO, meta: false, control: true),
      ShortcutAction.openFolder,
    );
    expect(
      defaults.actionForChord(LogicalKeyboardKey.keyO, meta: false, control: false),
      isNull,
      reason: 'a bare O must not open a folder',
    );

    // Every other action must NOT fire while a modifier is held, even though
    // dispatch is checking the same bound key it always did.
    expect(
      defaults.actionForChord(LogicalKeyboardKey.keyS, meta: false, control: false),
      ShortcutAction.starPhoto,
    );
    expect(
      defaults.actionForChord(LogicalKeyboardKey.keyS, meta: true, control: false),
      isNull,
      reason: 'Cmd+S must not fire starPhoto just because S is its bound key',
    );
    expect(
      defaults.actionForChord(LogicalKeyboardKey.keyS, meta: false, control: true),
      isNull,
    );
    expect(
      defaults.actionForChord(LogicalKeyboardKey.arrowLeft, meta: false, control: false),
      ShortcutAction.previousPhoto,
    );
    expect(
      defaults.actionForChord(LogicalKeyboardKey.arrowLeft, meta: true, control: false),
      isNull,
    );
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
