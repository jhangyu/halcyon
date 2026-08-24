import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/photo_item.dart';
import '../../services/rename_rule.dart';
import '../theme_tokens.dart';
import 'section_label.dart';

const String _kMono = 'monospace';

/// Right pane of the rename dialog: the "re-roll" control and the live
/// 5-file preview list of old name -> new name.
class RenamePreviewList extends StatelessWidget {
  const RenamePreviewList({
    super.key,
    required this.rule,
    required this.sample,
    required this.sampleMeta,
    required this.onReroll,
  });

  final RenameRule rule;
  final List<PhotoItem> sample;
  final Map<String, ExifMetadata?> sampleMeta;
  final VoidCallback onReroll;

  @override
  Widget build(BuildContext context) {
    final t = HalcyonTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: renameSectionLabel(
                  t,
                  'Preview · ${sample.length} random files',
                ),
              ),
              const SizedBox(width: 8),
              const Spacer(),
              Material(
                color: t.surface,
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: onReroll,
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
              itemCount: sample.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) =>
                  _previewCard(t, rule, sample[index], index),
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

  Widget _previewCard(HalcyonTokens t, RenameRule rule, PhotoItem item, int index) {
    final file = item.bestFileToLoad;
    final newBase = rule.error != null
        ? '—'
        : rule.render(
            meta: sampleMeta[item.id],
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
          sampleMeta[item.id]?.camera == null)
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
}
