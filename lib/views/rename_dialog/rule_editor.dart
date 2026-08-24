import 'package:flutter/material.dart';

import '../../services/rename_rule.dart';
import '../theme_tokens.dart';
import 'section_label.dart';

const String _kMono = 'monospace';

/// Left pane of the rename dialog: preset picker, the rule template field,
/// and the "insert variable" chip groups.
///
/// Takes only the data it renders plus callbacks -- it does not read
/// [AppState] directly, mirroring the constraint on the other split-out
/// sub-widgets.
class RuleEditor extends StatelessWidget {
  const RuleEditor({
    super.key,
    required this.selectedLabel,
    required this.customLabel,
    required this.controller,
    required this.error,
    required this.onSelectLabel,
    required this.onInsertToken,
  });

  final String selectedLabel;
  final String customLabel;
  final TextEditingController controller;
  final String? error;
  final ValueChanged<String?> onSelectLabel;
  final ValueChanged<String> onInsertToken;

  @override
  Widget build(BuildContext context) {
    final t = HalcyonTokens.of(context);
    return Container(
      color: t.pane,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            renameSectionLabel(t, 'Preset'),
            const SizedBox(height: 8),
            // RadioGroup, not RadioListTile.groupValue/onChanged: those two
            // parameters are deprecated since Flutter 3.32 and this repo's
            // analyze gate is zero issues.
            RadioGroup<String>(
              groupValue: selectedLabel,
              onChanged: onSelectLabel,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final preset in RenameRule.presets)
                    _presetRow(t, preset.label, preset.template),
                  _presetRow(
                    t,
                    customLabel,
                    'build your own rule below',
                    isCustom: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            renameSectionLabel(t, 'Rule template'),
            const SizedBox(height: 8),
            _ruleEditorBlock(t, error),
            const SizedBox(height: 20),
            renameSectionLabel(t, 'Insert variable'),
            const SizedBox(height: 10),
            for (final group in RenameRule.variableGroups) ...[
              Text(
                group.title.toUpperCase(),
                style: TextStyle(
                  fontSize: 10.5,
                  letterSpacing: 0.3,
                  color: t.textFaint,
                ),
              ),
              const SizedBox(height: 5),
              Wrap(
                spacing: 5,
                runSpacing: 5,
                children: [
                  for (final token in group.tokens) _chip(t, token),
                ],
              ),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }

  Widget _presetRow(
    HalcyonTokens t,
    String label,
    String pattern, {
    bool isCustom = false,
  }) {
    final selected = selectedLabel == label;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? t.accent.withValues(alpha: 0.2) : Colors.transparent,
        borderRadius: BorderRadius.circular(5),
        child: InkWell(
          borderRadius: BorderRadius.circular(5),
          onTap: () => onSelectLabel(label),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(5),
              border: Border.all(
                color: selected ? t.accent : Colors.transparent,
              ),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: Radio<String>(
                    value: label,
                    activeColor: t.accent,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: isCustom ? t.accent : t.text,
                          fontWeight: isCustom
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        pattern,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: _kMono,
                          fontSize: 11,
                          color: t.textDim,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _ruleEditorBlock(HalcyonTokens t, String? error) {
    return Container(
      decoration: BoxDecoration(
        color: t.input,
        border: Border.all(color: t.border),
        borderRadius: BorderRadius.circular(5),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            cursorColor: t.accent,
            style: TextStyle(
              fontFamily: _kMono,
              fontSize: 12.5,
              color: t.text,
            ),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.only(bottom: 8),
              border: UnderlineInputBorder(
                borderSide: BorderSide(color: t.borderSoft),
              ),
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: t.borderSoft),
              ),
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: t.accent),
              ),
            ),
          ),
          const SizedBox(height: 7),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                error == null ? Icons.check : Icons.error_outline,
                size: 13,
                color: error == null ? t.success : t.danger,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  error ?? 'Valid — resolves to a non-empty, unique-safe name',
                  style: TextStyle(
                    fontSize: 11,
                    color: error == null ? t.success : t.danger,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(HalcyonTokens t, String token) {
    return Material(
      color: t.surface,
      borderRadius: BorderRadius.circular(5),
      child: InkWell(
        borderRadius: BorderRadius.circular(5),
        onTap: () => onInsertToken(token),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            border: Border.all(color: t.borderSoft),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            token,
            style: TextStyle(fontFamily: _kMono, fontSize: 11, color: t.text),
          ),
        ),
      ),
    );
  }
}
