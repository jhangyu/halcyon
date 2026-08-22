import 'dart:io';
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

const String _kMono = 'monospace';

/// The mockup's palette (docs/mockups/exif-rename/variant-2-twopane.html) plus
/// a light-mode counterpart, because the app follows the system theme.
class _Tokens {
  const _Tokens({
    required this.pane,
    required this.dialog,
    required this.surface,
    required this.input,
    required this.border,
    required this.borderSoft,
    required this.text,
    required this.textDim,
    required this.textFaint,
    required this.accent,
    required this.success,
    required this.danger,
  });

  final Color pane;
  final Color dialog;
  final Color surface;
  final Color input;
  final Color border;
  final Color borderSoft;
  final Color text;
  final Color textDim;
  final Color textFaint;
  final Color accent;
  final Color success;
  final Color danger;

  static const _Tokens dark = _Tokens(
    pane: Color(0xFF333333),
    dialog: Color(0xFF383838),
    surface: Color(0xFF414141),
    input: Color(0xFF262626),
    border: Color(0xFF515151),
    borderSoft: Color(0xFF454545),
    text: Color(0xFFE0E0E0),
    textDim: Color(0xFF9A9A9A),
    textFaint: Color(0xFF6F6F6F),
    accent: Color(0xFF0A84FF),
    success: Color(0xFF32D74B),
    danger: Color(0xFFFF453A),
  );

  static const _Tokens light = _Tokens(
    pane: Color(0xFFF2F2F2),
    dialog: Color(0xFFFBFBFB),
    surface: Color(0xFFE9E9E9),
    input: Color(0xFFFFFFFF),
    border: Color(0xFFC9C9C9),
    borderSoft: Color(0xFFDCDCDC),
    text: Color(0xFF1E1E1E),
    textDim: Color(0xFF6B6B6B),
    textFaint: Color(0xFF9A9A9A),
    accent: Color(0xFF0066CC),
    success: Color(0xFF1B873F),
    danger: Color(0xFFC7362B),
  );

  static _Tokens of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

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
    final t = _Tokens.of(context);
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
                  SizedBox(width: 360, child: _buildEditor(t, error)),
                  Container(width: 1, color: t.borderSoft),
                  Expanded(child: _buildPreview(t)),
                ],
              ),
            ),
            Container(height: 1, color: t.borderSoft),
            _footer(t, itemCount, error),
          ],
        ),
      ),
    );
  }

  Widget _header(_Tokens t, int itemCount) {
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

  Widget _sectionLabel(_Tokens t, String text) {
    return Text(
      text.toUpperCase(),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        color: t.textDim,
      ),
    );
  }

  Widget _buildEditor(_Tokens t, String? error) {
    return Container(
      color: t.pane,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionLabel(t, 'Preset'),
            const SizedBox(height: 8),
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
                    _presetRow(t, preset.label, preset.template),
                  _presetRow(
                    t,
                    kCustomPresetLabel,
                    'build your own rule below',
                    isCustom: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _sectionLabel(t, 'Rule template'),
            const SizedBox(height: 8),
            _ruleEditorBlock(t, error),
            const SizedBox(height: 20),
            _sectionLabel(t, 'Insert variable'),
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
    _Tokens t,
    String label,
    String pattern, {
    bool isCustom = false,
  }) {
    final selected = _selectedLabel == label;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? t.accent.withValues(alpha: 0.2) : Colors.transparent,
        borderRadius: BorderRadius.circular(5),
        child: InkWell(
          borderRadius: BorderRadius.circular(5),
          onTap: () => _selectLabel(label),
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

  Widget _ruleEditorBlock(_Tokens t, String? error) {
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
            controller: _controller,
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

  Widget _chip(_Tokens t, String token) {
    return Material(
      color: t.surface,
      borderRadius: BorderRadius.circular(5),
      child: InkWell(
        borderRadius: BorderRadius.circular(5),
        onTap: () => _insertToken(token),
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

  Widget _buildPreview(_Tokens t) {
    final rule = _rule;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: _sectionLabel(
                  t,
                  'Preview · ${_sample.length} random files',
                ),
              ),
              const SizedBox(width: 8),
              const Spacer(),
              Material(
                color: t.surface,
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: _reroll,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: t.borderSoft),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.shuffle, size: 12, color: t.textDim),
                        const SizedBox(width: 5),
                        Text(
                          'Re-roll',
                          style: TextStyle(fontSize: 11, color: t.textDim),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: ListView.separated(
              itemCount: _sample.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) =>
                  _previewCard(t, rule, _sample[index], index),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Missing metadata renders as an empty string. Recomputed on every '
            'keystroke in the rule template. RAW + JPG + sidecar of the same '
            'shot always share the new base name.',
            style: TextStyle(fontSize: 11, height: 1.5, color: t.textFaint),
          ),
        ],
      ),
    );
  }

  Widget _previewCard(_Tokens t, RenameRule rule, PhotoItem item, int index) {
    final file = item.bestFileToLoad;
    final newBase = rule.error != null
        ? '—'
        : rule.render(
            meta: _sampleMeta[item.id],
            fileModified: file?.statSync().modified ?? DateTime(1970),
            originalBase: item.id,
            seq: index + 1,
          );
    final primary = file ?? (item.files.isEmpty ? null : item.files.first);
    final ext = primary == null ? '' : _extensionOf(primary);
    final badges = [
      for (final f in item.files)
        if (f != primary) '+ ${_extensionOf(f)}',
      if (rule.template.contains('{camera}') &&
          _sampleMeta[item.id]?.camera == null)
        'no camera tag',
    ];

    return Container(
      decoration: BoxDecoration(
        color: t.input,
        border: Border.all(color: t.borderSoft),
        borderRadius: BorderRadius.circular(5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            primary == null ? item.id : primary.uri.pathSegments.last,
            style: TextStyle(
              fontFamily: _kMono,
              fontSize: 11.5,
              color: t.textFaint,
              decoration: TextDecoration.lineThrough,
              decorationColor: t.danger.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text('→', style: TextStyle(fontSize: 11, color: t.textFaint)),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  newBase,
                  style: TextStyle(
                    fontFamily: _kMono,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: t.success,
                  ),
                ),
              ),
              Text(
                ext,
                style: TextStyle(
                  fontFamily: _kMono,
                  fontSize: 12.5,
                  color: t.textDim,
                ),
              ),
              const Spacer(),
              for (final badge in badges)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: t.surface,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      badge,
                      style: TextStyle(fontSize: 9.5, color: t.textFaint),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static String _extensionOf(File file) {
    final name = file.uri.pathSegments.last;
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? '' : name.substring(dot);
  }

  Widget _footer(_Tokens t, int itemCount, String? error) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
      child: Row(
        children: [
          Flexible(
            child: Text(
              '$itemCount files · non-writable folders cannot reach this dialog',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: t.textFaint),
            ),
          ),
          const SizedBox(width: 12),
          const Spacer(),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(
              foregroundColor: t.text,
              backgroundColor: t.surface,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
                side: BorderSide(color: t.border),
              ),
            ),
            child: const Text('Cancel', style: TextStyle(fontSize: 12.5)),
          ),
          const SizedBox(width: 8),
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
            style: FilledButton.styleFrom(
              backgroundColor: t.accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            child: const Text(
              'Run Rename',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
