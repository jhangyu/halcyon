import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_state.dart';
import '../../services/image_pipeline/retention_policy.dart';
import '../theme_tokens.dart';
import 'settings_primitives.dart';
import 'settings_section_label.dart';

/// D1's Memory tab (§1.5.3): three tier cards, an auto/override caption and
/// the "Use detected default" reset affordance.
class MemoryTab extends StatelessWidget {
  const MemoryTab({super.key});

  @override
  Widget build(BuildContext context) {
    final t = HalcyonTokens.of(context);
    final state = context.watch<AppState>();

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
              Row(
                children: [
                  Expanded(
                    child: settingsCaption(
                      t,
                      state.isRetentionTierOverridden
                          ? 'Overriding the detected default '
                                '(${state.autoRetentionTier.label}).'
                          : 'Auto-picked from detected RAM; override anytime.',
                    ),
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
              const SizedBox(height: 4),
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
