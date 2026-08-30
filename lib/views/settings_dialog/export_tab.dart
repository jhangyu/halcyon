import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_state.dart';
import '../../services/library/photo_export_service.dart';
import '../theme_tokens.dart';
import 'settings_primitives.dart';
import 'settings_section_label.dart';

/// E1's "Export" tab (docs/logs/2026-08-30/mockups/E1.html): the round-2
/// tab restructure moves the export-quality slider out of the old
/// Performance tab and adds the new export-size slider alongside it, each
/// as its own full-width section (E1.html:130-158).
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
        _quality(context, t, state),
        const SizedBox(height: 18),
        _size(context, t, state),
      ],
    );
  }

  Widget _filetype(BuildContext context, HalcyonTokens t, AppState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        settingsSectionLabel(t, 'Export'),
        settingsBlock(
          t,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              settingsRowLabel(t, 'Export Filetype'),
              settingsCaption(t, state.exportFiletype.label),
              const SizedBox(height: 4),
              Row(
                children: [
                  for (var i = 0; i < ExportFiletype.values.length; i++) ...[
                    if (i > 0) const SizedBox(width: 6),
                    Expanded(
                      child: _filetypeSegment(
                        context,
                        t,
                        state,
                        ExportFiletype.values[i],
                      ),
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
    // Unavailable filetypes (round-2b feasibility gap: ceyx has no HEIF
    // encoder and no lossless WebP entry point) render disabled rather than
    // hidden -- a hidden control reads as a missing feature (matches the
    // decode-lane-width row's existing precedent, TC-460).
    return Tooltip(
      message: type.available
          ? ''
          : 'Not available in this build: no native encoder for '
              '${type.label}',
      child: Material(
        key: Key('exportFiletype.${type.name}'),
        color: selected ? t.accent.withValues(alpha: 0.18) : t.surface,
        borderRadius: BorderRadius.circular(5),
        child: InkWell(
          onTap: type.available
              ? () => context.read<AppState>().setExportFiletype(type)
              : null,
          borderRadius: BorderRadius.circular(5),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(
                color: selected ? t.accent : t.borderSoft,
              ),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              type.label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                color: type.available
                    ? (selected ? t.text : t.textDim)
                    : t.textFaint,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _quality(BuildContext context, HalcyonTokens t, AppState state) {
    // Quality only means something for lossy codecs; JPEG and WebP-lossy are
    // the two available filetypes today, and both are quality-driven, so
    // this is currently always enabled -- but written against `available &&
    // type != webpLossless` (rather than hardcoding "always on") so a future
    // lossless option disables it without another round of UI changes.
    final qualityApplies = state.exportFiletype != ExportFiletype.webpLossless;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        settingsBlock(
          t,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              settingsRowLabel(t, 'Export Quality'),
              settingsCaption(
                t,
                qualityApplies
                    ? '${state.exportJpegQuality}'
                    : 'Not applicable -- lossless encodes at fixed quality',
              ),
              Slider(
                key: const Key('exportQualitySlider'),
                min: 50,
                max: 100,
                divisions: 10,
                label: '${state.exportJpegQuality}',
                value: state.exportJpegQuality.toDouble(),
                activeColor: t.accent,
                inactiveColor: t.border,
                onChanged: qualityApplies
                    ? (double value) => context
                          .read<AppState>()
                          .setExportJpegQuality(value.round())
                    : null,
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
        settingsSectionLabel(t, 'Export Size'),
        settingsBlock(
          t,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              settingsRowLabel(t, 'Export Size'),
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
