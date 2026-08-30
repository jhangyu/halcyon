import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_state.dart';
import '../../services/library/photo_export_service.dart';
import '../theme_tokens.dart';
import 'settings_primitives.dart';
import 'settings_section_label.dart';

/// E1's "Export" tab (docs/logs/2026-08-30/mockups/E1.html), with the
/// round-3 layout tweak from F1.html (docs/logs/2026-08-30/mockups/F1.html):
/// Export Quality and Export Size now sit side by side, each 50% width,
/// using the same 2-column grid pattern the mockups already establish
/// (D1.html/E1.html `.grid`). Export Filetype (unaffected by this round's
/// request) stays full-width above the paired row.
class ExportTab extends StatelessWidget {
  const ExportTab({super.key});

  @override
  Widget build(BuildContext context) {
    final t = HalcyonTokens.of(context);
    final state = context.watch<AppState>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _filetype(context, t, state),
        const SizedBox(height: 10),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _quality(context, t, state)),
              const SizedBox(width: 16),
              Expanded(child: _size(context, t, state)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _filetype(BuildContext context, HalcyonTokens t, AppState state) {
    // Round 2c (user ruling): only the two ACTUALLY encodable filetypes are
    // shown. HEIF and WebP-lossless are dropped from the UI entirely rather
    // than shown disabled -- see docs/logs/2026-08-30/ceyx-encode-handoff.md
    // for what ceyx needs to grow before a future round can add them back.
    // Filtering on [ExportFiletype.available] means the day they become
    // available this loop needs no change.
    final available = ExportFiletype.values.where((f) => f.available).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        settingsSectionLabel(t, 'File Type'),
        settingsBlock(
          t,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              settingsRowLabel(t, 'Filetype of the export image'),
              settingsCaption(t, state.exportFiletype.label),
              const SizedBox(height: 4),
              Row(
                children: [
                  for (var i = 0; i < available.length; i++) ...[
                    if (i > 0) const SizedBox(width: 6),
                    Expanded(
                      child: _filetypeSegment(context, t, state, available[i]),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _filetypeSegment(
    BuildContext context,
    HalcyonTokens t,
    AppState state,
    ExportFiletype type,
  ) {
    final selected = state.exportFiletype == type;
    return Material(
      key: Key('exportFiletype.${type.name}'),
      color: selected ? t.accent.withValues(alpha: 0.18) : t.surface,
      borderRadius: BorderRadius.circular(5),
      child: InkWell(
        onTap: () => context.read<AppState>().setExportFiletype(type),
        borderRadius: BorderRadius.circular(5),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: selected ? t.accent : t.borderSoft),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            type.label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11.5,
              color: selected ? t.text : t.textDim,
            ),
          ),
        ),
      ),
    );
  }

  Widget _quality(BuildContext context, HalcyonTokens t, AppState state) {
    // Both available filetypes (JPEG, WebP-lossy) are quality-driven, so
    // this round the slider is unconditionally enabled -- no disabled state
    // needed (user ruling, round 2c).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        settingsSectionLabel(t, 'Quality'),
        settingsBlock(
          t,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              settingsRowLabel(t, 'Quality setting of the encoder'),
              settingsCaption(t, '${state.exportJpegQuality}'),
              Slider(
                key: const Key('exportQualitySlider'),
                min: 50,
                max: 100,
                divisions: 10,
                label: '${state.exportJpegQuality}',
                value: state.exportJpegQuality.toDouble(),
                activeColor: t.accent,
                inactiveColor: t.border,
                onChanged: (double value) => context
                    .read<AppState>()
                    .setExportJpegQuality(value.round()),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _size(BuildContext context, HalcyonTokens t, AppState state) {
    final index = kExportLongEdgeStops.indexOf(state.exportLongEdge);
    // A persisted value outside the stop list is already normalised back to
    // the default by AppState before it ever reaches this getter, so index
    // is always found -- but a -1 fallback avoids a crashing slider if that
    // invariant is ever broken.
    final safeIndex = index < 0 ? kExportLongEdgeStops.indexOf(kDefaultExportLongEdge) : index;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        settingsSectionLabel(t, 'Size'),
        settingsBlock(
          t,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              settingsRowLabel(t, 'Size of the export image'),
              settingsCaption(
                t,
                state.exportLongEdge == kDefaultExportLongEdge
                    ? '${exportLongEdgeLabel(state.exportLongEdge)} (long edge)'
                    : exportLongEdgeLabel(state.exportLongEdge),
              ),
              Slider(
                key: const Key('exportSizeSlider'),
                min: 0,
                max: (kExportLongEdgeStops.length - 1).toDouble(),
                divisions: kExportLongEdgeStops.length - 1,
                label: exportLongEdgeLabel(state.exportLongEdge),
                value: safeIndex.toDouble(),
                activeColor: t.accent,
                inactiveColor: t.border,
                onChanged: (double value) => context
                    .read<AppState>()
                    .setExportLongEdge(kExportLongEdgeStops[value.round()]),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
