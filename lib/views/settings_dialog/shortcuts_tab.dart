import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../models/shortcut_bindings.dart';
import '../../providers/app_state.dart';
import '../theme_tokens.dart';
import 'settings_primitives.dart';
import 'settings_section_label.dart';

/// One line per conflicting key, per §1.5.5: `'"X" is bound twice — A and B
/// conflict. The first listed action wins.'`, comma-joined with `and` before
/// the last name when more than two actions share a key.
String _conflictSentence(LogicalKeyboardKey key, List<ShortcutAction> actions) {
  final names = actions.map((a) => a.label).toList();
  final String joined;
  if (names.length <= 1) {
    joined = names.join();
  } else if (names.length == 2) {
    joined = '${names[0]} and ${names[1]}';
  } else {
    joined = '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  }
  return '"${keyLabelFor(key)}" is bound twice — $joined conflict. '
      'The first listed action wins.';
}

/// [ShortcutAction.openFolder] always requires a modifier
/// ([ShortcutActionMeta.requiresModifier]) that the recording UI never lets
/// the user change (only the base key is recordable) — the chip must show
/// that modifier or the row would misleadingly read as a bare, unmodified
/// key. Cmd on macOS, Ctrl elsewhere, matching the two always-live chords in
/// [ShortcutBindings.actionForChord].
String _chipLabel(ShortcutAction action, ShortcutBindings bindings) {
  final key = keyLabelFor(bindings.keyFor(action));
  if (!action.requiresModifier) return key;
  return Platform.isMacOS ? '⌘$key' : 'Ctrl+$key';
}

/// D1's Shortcuts tab (§1.4.4): 7 remappable rows in 2 columns, a conflict
/// note, and the record-a-key state machine.
class ShortcutsTab extends StatefulWidget {
  const ShortcutsTab({super.key});

  @override
  State<ShortcutsTab> createState() => _ShortcutsTabState();
}

class _ShortcutsTabState extends State<ShortcutsTab> {
  final FocusNode _recordFocus = FocusNode();
  ShortcutAction? _recording;
  String? _recordError;

  @override
  void dispose() {
    _recordFocus.dispose();
    super.dispose();
  }

  void _startRecording(ShortcutAction action) {
    setState(() {
      _recording = action;
      _recordError = null;
    });
    _recordFocus.requestFocus();
  }

  void _stopRecording() {
    setState(() {
      _recording = null;
      _recordError = null;
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final action = _recording;
    if (action == null) return KeyEventResult.ignored;
    // Swallow EVERYTHING while recording: nothing may reach MainScreen behind
    // the dialog, including the key we are about to bind.
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _stopRecording();
      return KeyEventResult.handled;
    }
    if (kReservedShortcutKeys.contains(key)) {
      setState(() {
        _recordError = "${keyLabelFor(key)} can't be used as a shortcut.";
      });
      return KeyEventResult.handled;
    }
    context.read<AppState>().setShortcutBinding(action, key);
    _stopRecording();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final t = HalcyonTokens.of(context);
    final state = context.watch<AppState>();
    final bindings = state.shortcutBindings;
    final actions = ShortcutAction.values;
    final left = actions.sublist(0, 4);
    final right = actions.sublist(4);
    final conflicts = bindings.conflicts;

    return Focus(
      focusNode: _recordFocus,
      onKeyEvent: _onKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          settingsSectionLabel(t, 'Keyboard Shortcuts'),
          settingsBlock(
            t,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        children: [
                          for (var i = 0; i < left.length; i++)
                            _row(context, t, bindings, left[i], i == left.length - 1),
                        ],
                      ),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      child: Column(
                        children: [
                          for (var i = 0; i < right.length; i++)
                            _row(context, t, bindings, right[i], i == right.length - 1),
                        ],
                      ),
                    ),
                  ],
                ),
                if (conflicts.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      key: const Key('settingsConflictNote'),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final entry in conflicts.entries)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.warning_amber_rounded,
                                  size: 12,
                                  color: t.danger,
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    _conflictSentence(entry.key, entry.value),
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      color: t.danger,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                if (bindings.hasAnyNonDefault)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: settingsSmallButton(
                        t,
                        'Reset all shortcuts',
                        () => context.read<AppState>().resetAllShortcutBindings(),
                        key: const Key('shortcutResetAll'),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    HalcyonTokens t,
    ShortcutBindings bindings,
    ShortcutAction action,
    bool isLast,
  ) {
    final recording = _recording == action;
    final conflict = bindings.conflicts.containsKey(bindings.keyFor(action));

    return Container(
      key: Key('shortcutRow.${action.id}'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(bottom: BorderSide(color: t.borderSoft)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                flex: 3,
                child: Text(
                  action.label,
                  style: TextStyle(fontSize: 12.5, color: t.text),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Wrapped in its OWN Expanded (rather than left unconstrained
              // in the Row) so a narrow column reflows the chip/buttons onto
              // a second line via Wrap instead of overflowing the row.
              Expanded(
                flex: 4,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    recording
                        ? Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              border: Border.all(color: t.accent),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              'Press a key…',
                              style: TextStyle(fontSize: 11.5, color: t.accent),
                            ),
                          )
                        : settingsKeyChip(
                            t,
                            _chipLabel(action, bindings),
                            conflict: conflict,
                          ),
                    settingsSmallButton(
                      t,
                      recording ? 'Cancel' : 'Record',
                      recording ? _stopRecording : () => _startRecording(action),
                      key: Key('shortcutRecord.${action.id}'),
                    ),
                    if (!recording && !bindings.isDefault(action))
                      settingsSmallButton(
                        t,
                        'Reset',
                        () => context.read<AppState>().resetShortcutBinding(action),
                        key: Key('shortcutReset.${action.id}'),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (recording && _recordError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _recordError!,
                style: TextStyle(fontSize: 10.5, color: t.danger),
              ),
            ),
        ],
      ),
    );
  }
}
