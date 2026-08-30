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
        _quality(context, t, state),
        const SizedBox(height: 18),
        _size(context, t, state),
      ],
    );
  }

  Widget _quality(BuildContext context, HalcyonTokens t, AppState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        settingsSectionLabel(t, 'Export'),
        settingsBlock(
          t,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              settingsRowLabel(t, 'Export JPEG quality'),
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
                onChanged: (double value) =>
                    context.read<AppState>().setExportJpegQuality(value.round()),
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
              settingsRowLabel(t, 'Export JPEG size'),
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
