import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/photo_item.dart';
import '../providers/app_state.dart';
import '../models/rename_rule.dart';
import 'rename_dialog/actions.dart';
import 'rename_dialog/preview_list.dart';
import 'rename_dialog/rule_editor.dart';
import 'theme_tokens.dart';

/// Menu value for the sidebar action menu. Shared by the widget and its test
/// so a typo cannot make the entry silently dead (memory.md: menu value /
/// onSelected string mismatch class of bug).
const String kRenameMenuValue = 'rename';

/// Label of the pseudo-preset that means "the rule below is hand-written".
/// Exported so the test cannot drift from the widget.
const String kCustomPresetLabel = 'Custom...';

/// Two-pane rename dialog: presets + rule editor on the left, live preview on
/// the right (docs/mockups/exif-rename/variant-2-twopane.html).
class RenameDialog extends StatefulWidget {
  const RenameDialog({super.key});

  @override
  State<RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<RenameDialog> {
  final TextEditingController _controller = TextEditingController(
    text: RenameRule.kDefaultTemplate,
  );
  String _selectedLabel = RenameRule.presets.first.label;
  List<PhotoItem> _sample = const [];
  Map<String, ExifMetadata?> _sampleMeta = const {};

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onRuleChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreSavedRule();
      _reroll();
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_onRuleChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onRuleChanged() {
    if (mounted) setState(() {});
  }

  /// A folder that was renamed with a hand-written rule reopens on that rule,
  /// which is the only way the "Custom..." row can start selected.
  Future<void> _restoreSavedRule() async {
    final saved = await context.read<AppState>().loadSavedRenameRule();
    if (!mounted || saved == null) return;
    setState(() {
      _controller.text = saved;
      _selectedLabel = kCustomPresetLabel;
    });
  }

  /// Five random items, with their EXIF read once so the preview shows real
  /// values rather than a guess.
  Future<void> _reroll() async {
    final state = context.read<AppState>();
    final items = [...state.items]..shuffle(Random());
    final sample = items.take(5).toList();
    final meta = await state.readMetadataFor(sample);
    if (!mounted) return;
    setState(() {
      _sample = sample;
      _sampleMeta = meta;
    });
  }

  RenameRule get _rule => RenameRule(_controller.text);

  bool get _isCustom => _selectedLabel == kCustomPresetLabel;

  void _selectLabel(String? label) {
    if (label == null) return;
    final preset = RenameRule.presets
        .where((p) => p.label == label)
        .firstOrNull;
    setState(() {
      _selectedLabel = label;
      if (preset != null) _controller.text = preset.template;
    });
  }

  void _insertToken(String token) {
    final selection = _controller.selection;
    final text = _controller.text;
    final at = selection.isValid ? selection.baseOffset : text.length;
    final end = selection.isValid ? selection.extentOffset : at;
    setState(() {
      _selectedLabel = kCustomPresetLabel;
      _controller.value = TextEditingValue(
        text: text.replaceRange(at, end, token),
        selection: TextSelection.collapsed(offset: at + token.length),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = HalcyonTokens.of(context);
    final error = _rule.error;
    final itemCount = context.watch<AppState>().items.length;

    return Dialog(
      backgroundColor: t.dialog,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 880,
        height: 540,
        child: Column(
          children: [
            _header(t, itemCount),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 360,
                    child: RuleEditor(
                      selectedLabel: _selectedLabel,
                      customLabel: kCustomPresetLabel,
                      controller: _controller,
                      error: error,
                      onSelectLabel: _selectLabel,
                      onInsertToken: _insertToken,
                    ),
                  ),
                  Container(width: 1, color: t.borderSoft),
                  Expanded(
                    child: RenamePreviewList(
                      rule: _rule,
                      sample: _sample,
                      sampleMeta: _sampleMeta,
                      onReroll: _reroll,
                    ),
                  ),
                ],
              ),
            ),
            Container(height: 1, color: t.borderSoft),
            RenameActions(
              itemCount: itemCount,
              error: error,
              onCancel: () => Navigator.of(context).pop(),
              onRun: () {
                final state = context.read<AppState>();
                final rule = _rule;
                final isCustom = _isCustom;
                Navigator.of(context).pop();
                state.renameByExif(rule, isCustom: isCustom);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(HalcyonTokens t, int itemCount) {
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 16, 22, 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.borderSoft)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Rename by EXIF',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: t.text,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Applies to all $itemCount photos in this folder · reversible via Undo',
                  style: TextStyle(fontSize: 11.5, color: t.textDim),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: t.surface,
              border: Border.all(color: t.borderSoft),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              'Whole folder',
              style: TextStyle(fontSize: 11, color: t.textDim),
            ),
          ),
        ],
      ),
    );
  }
}
