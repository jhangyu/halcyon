import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/photo_item.dart';
import '../providers/app_state.dart';
import '../services/rename_rule.dart';

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
    final error = _rule.error;
    final itemCount = context.watch<AppState>().items.length;

    return Dialog(
      child: SizedBox(
        width: 880,
        height: 520,
        child: Column(
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 5, child: _buildEditor(error)),
                  const VerticalDivider(width: 1),
                  Expanded(flex: 4, child: _buildPreview()),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: error != null
                        ? null
                        : () {
                            final state = context.read<AppState>();
                            final rule = _rule;
                            final isCustom = _isCustom;
                            Navigator.of(context).pop();
                            state.renameByExif(rule, isCustom: isCustom);
                          },
                    child: Text('Rename $itemCount items'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditor(String? error) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Rename by EXIF',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          // RadioGroup, not RadioListTile.groupValue/onChanged: those two
          // parameters are deprecated since Flutter 3.32 and this repo's
          // analyze gate is zero issues.
          RadioGroup<String>(
            groupValue: _selectedLabel,
            onChanged: _selectLabel,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final preset in RenameRule.presets)
                  RadioListTile<String>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: preset.label,
                    title: Text(preset.label),
                    subtitle: Text(
                      preset.template,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                  ),
                const RadioListTile<String>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: kCustomPresetLabel,
                  title: Text(kCustomPresetLabel),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            style: const TextStyle(fontFamily: 'monospace'),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              isDense: true,
              errorText: error,
            ),
          ),
          const SizedBox(height: 12),
          for (final group in RenameRule.variableGroups) ...[
            Text(
              group.title,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final token in group.tokens)
                  ActionChip(
                    label: Text(
                      token,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                    onPressed: () => _insertToken(token),
                  ),
              ],
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }

  Widget _buildPreview() {
    final rule = _rule;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Preview',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              IconButton(
                iconSize: 18,
                tooltip: 'Pick 5 other files',
                onPressed: _reroll,
                icon: const Icon(Icons.casino_outlined),
              ),
            ],
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _sample.length,
              itemBuilder: (context, index) {
                final item = _sample[index];
                final file = item.bestFileToLoad;
                final newBase = rule.error != null
                    ? '—'
                    : rule.render(
                        meta: _sampleMeta[item.id],
                        fileModified:
                            file?.statSync().modified ?? DateTime(1970),
                        originalBase: item.id,
                        seq: index + 1,
                      );
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.id,
                        style: const TextStyle(
                          fontSize: 11,
                          decoration: TextDecoration.lineThrough,
                        ),
                      ),
                      Text(newBase, style: const TextStyle(fontSize: 13)),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
