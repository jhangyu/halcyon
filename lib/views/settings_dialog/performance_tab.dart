import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_state.dart';
import '../theme_tokens.dart';
import 'settings_primitives.dart';
import 'settings_section_label.dart';

/// D1's Performance tab (§1.5.3): Parallelism + Export side by side, then a
/// full-width Workflow section holding the two carried-forward checkboxes.
class PerformanceTab extends StatelessWidget {
  const PerformanceTab({super.key});

  @override
  Widget build(BuildContext context) {
    final t = HalcyonTokens.of(context);
    final state = context.watch<AppState>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _parallelism(context, t, state)),
            const SizedBox(width: 16),
            Expanded(child: _export(context, t, state)),
          ],
        ),
        const SizedBox(height: 18),
        _workflow(context, t, state),
      ],
    );
  }

  Widget _parallelism(BuildContext context, HalcyonTokens t, AppState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        settingsSectionLabel(t, 'Parallelism'),
        settingsBlock(
          t,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              settingsRowLabel(t, 'Concurrent RAW decodes'),
              settingsCaption(
                t,
                state.maxDecodeLaneWidth > 1
                    ? '${state.decodeLaneWidth} of ${state.maxDecodeLaneWidth} max'
                    : 'This machine can only decode one RAW at a time',
              ),
              Slider(
                key: const Key('decodeLaneWidthSlider'),
                min: 1,
                max: state.maxDecodeLaneWidth.toDouble(),
                // Flutter asserts divisions > 0, so a ceiling of 1 passes null.
                divisions: state.maxDecodeLaneWidth > 1
                    ? state.maxDecodeLaneWidth - 1
                    : null,
                label: '${state.decodeLaneWidth}',
                value: state.decodeLaneWidth.toDouble(),
                activeColor: t.accent,
                inactiveColor: t.border,
                onChanged: state.maxDecodeLaneWidth > 1
                    ? (double value) =>
                          context.read<AppState>().setDecodeLaneWidth(value.round())
                    : null,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _export(BuildContext context, HalcyonTokens t, AppState state) {
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
                min: 70,
                max: 100,
                divisions: 6,
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

  Widget _workflow(BuildContext context, HalcyonTokens t, AppState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        settingsSectionLabel(t, 'Workflow'),
        settingsBlock(
          t,
          Row(
            children: [
              Expanded(
                child: Material(
                  type: MaterialType.transparency,
                  child: CheckboxListTile(
                    title: Text(
                      'Auto-advance on mark',
                      style: TextStyle(fontSize: 12.5, color: t.text),
                    ),
                    value: state.autoAdvance,
                    onChanged: (bool? value) {
                      if (value != null) {
                        context.read<AppState>().setAutoAdvance(value);
                      }
                    },
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    activeColor: t.accent,
                  ),
                ),
              ),
              Expanded(
                child: Material(
                  type: MaterialType.transparency,
                  child: CheckboxListTile(
                    title: Text(
                      'Overwrite existing files on Copy/Move',
                      style: TextStyle(fontSize: 12.5, color: t.text),
                    ),
                    value: state.overwriteExisting,
                    onChanged: (bool? value) {
                      if (value != null) {
                        context.read<AppState>().setOverwriteExisting(value);
                      }
                    },
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    activeColor: t.accent,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
