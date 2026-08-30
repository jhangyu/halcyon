import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_state.dart';
import '../../services/image_pipeline/retention_policy.dart';
import '../theme_tokens.dart';
import 'settings_primitives.dart';
import 'settings_section_label.dart';

/// E1's merged "Performance & Memory" tab (docs/logs/2026-08-30/mockups/
/// E1.html), with the round-3 layout tweak from F1.html
/// (docs/logs/2026-08-30/mockups/F1.html): Parallelism and Memory Retention
/// now sit side by side, each 50% width, using the same 2-column grid
/// pattern the mockups already establish (D1.html/E1.html `.grid`). Workflow
/// (unaffected by this round's request) stays full-width, placed after the
/// paired row so the two named sections are visually adjacent.
class PerformanceMemoryTab extends StatelessWidget {
  const PerformanceMemoryTab({super.key});

  @override
  Widget build(BuildContext context) {
    final t = HalcyonTokens.of(context);
    final state = context.watch<AppState>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _parallelism(context, t, state)),
              const SizedBox(width: 16),
              Expanded(child: _memoryRetention(context, t, state)),
            ],
          ),
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

  Widget _memoryRetention(BuildContext context, HalcyonTokens t, AppState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        settingsSectionLabel(t, 'Memory Retention'),
        settingsBlock(
          t,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  for (var i = 0; i < RetentionTier.values.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(
                      child: _tierCard(
                        context,
                        t,
                        state,
                        RetentionTier.values[i],
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 10),
              // A Row here would overflow once the column is half-width
              // (this round's layout change): the caption text plus the
              // reset button no longer both fit on one line at half the
              // dialog's content width. Wrap lets the button drop to its
              // own line instead of clipping/overflowing.
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                runSpacing: 4,
                children: [
                  settingsCaption(
                    t,
                    state.isRetentionTierOverridden
                        ? 'Overriding the detected default '
                              '(${state.autoRetentionTier.label}).'
                        : 'Auto-picked from detected RAM; override anytime.',
                  ),
                  if (state.isRetentionTierOverridden)
                    settingsSmallButton(
                      t,
                      'Use detected default',
                      () => context.read<AppState>().resetRetentionTierToAuto(),
                      key: const Key('retentionResetToAuto'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _tierCard(
    BuildContext context,
    HalcyonTokens t,
    AppState state,
    RetentionTier tier,
  ) {
    final policy = retentionPolicyForTier(tier);
    final selected = state.retentionTier == tier;
    return Material(
      key: Key('retentionTier.${tier.id}'),
      color: selected ? t.accent.withValues(alpha: 0.18) : t.surface,
      borderRadius: BorderRadius.circular(5),
      child: InkWell(
        onTap: () => context.read<AppState>().setRetentionTier(tier),
        borderRadius: BorderRadius.circular(5),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(color: selected ? t.accent : t.borderSoft),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tier.label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: t.text,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${policy.payloadByteBudget ~/ (1024 * 1024)} MiB',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'monospace',
                  color: t.accent,
                ),
              ),
              const SizedBox(height: 2), // D1.html:79 .tier .formula margin
              Text(
                '−${policy.before} / +${policy.after} photos',
                style: TextStyle(fontSize: 10, color: t.textFaint),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
