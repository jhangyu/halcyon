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
/// sit side by side in a 2:3 width ratio (round-4 user ruling; was 50/50),
/// using the same 2-column grid pattern the mockups already establish
/// (D1.html/E1.html `.grid`). Workflow (unaffected by this round's width
/// request) stays full-width, placed after the paired row so the two named
/// sections are visually adjacent. Round-5 (real-build review) ruling:
/// each block in the paired row is wrapped in `Expanded` so it stretches
/// to the shared `IntrinsicHeight` row's full height, keeping the two
/// blocks' top/bottom edges aligned even when their content heights
/// differ. Round-5 also reverted the Workflow section back to its
/// pre-round-4 (commit 297d6c3) look -- the user reviewed round-4's
/// IntrinsicWidth+Wrap attempt in a real build and preferred the original
/// two-Expanded-CheckboxListTile Row (see `_workflow` below).
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
              Expanded(flex: 2, child: _parallelism(context, t, state)),
              const SizedBox(width: 16),
              Expanded(flex: 3, child: _memoryRetention(context, t, state)),
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
        // Expanded (not a bare settingsBlock() call) so this block stretches
        // to fill the paired row's full IntrinsicHeight -- otherwise, since
        // Column doesn't vertically stretch its children by default, the
        // shorter block's Container stays at its own natural (content)
        // height and any leftover row height goes to blank space below it
        // instead of being absorbed by the block's border/background,
        // leaving the two blocks' top/bottom edges visibly misaligned.
        Expanded(
          child: settingsBlock(
            t,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                settingsRowLabel(t, 'Concurrent RAW decodes'),
                settingsCaption(
                  t,
                  '${state.decodeLaneWidth} of ${state.maxDecodeLaneWidth} max',
                ),
                settingsSlider(
                  key: const Key('decodeLaneWidthSlider'),
                  min: 1,
                  max: state.maxDecodeLaneWidth.toDouble(),
                  divisions: state.maxDecodeLaneWidth - 1,
                  label: '${state.decodeLaneWidth}',
                  value: state.decodeLaneWidth.toDouble(),
                  activeColor: t.accent,
                  inactiveColor: t.border,
                  onChanged: (double value) => context
                      .read<AppState>()
                      .setDecodeLaneWidth(value.round()),
                ),
              ],
            ),
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
          // Round-5 user ruling: reverted to the pre-round-4 (297d6c3)
          // structure -- two equal-width Expanded CheckboxListTiles in a
          // plain Row. Round 4's IntrinsicWidth+Wrap swap (9394a9e) was an
          // attempt to fix a perceived checkbox misalignment, but the user
          // reviewed a real build and preferred the original two-column
          // look; TC-484 (which pinned the round-4 single-line height
          // guard) is removed accordingly -- see settings_dialog_test.dart.
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
        // See the matching Expanded wrap in _parallelism above for why this
        // is needed to keep the two paired blocks' heights equal.
        Expanded(
          child: settingsBlock(
            t,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    for (var i = 0; i < RetentionTier.values.length; i++) ...[
                      if (i > 0) const SizedBox(width: 6),
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
                        () =>
                            context.read<AppState>().resetRetentionTierToAuto(),
                        key: const Key('retentionResetToAuto'),
                      ),
                  ],
                ),
              ],
            ),
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
      // F1.html:75-79 `.tier` sets no background of its own -- only
      // `.tier.selected` (:78) does, so the unselected card shows the
      // parent `.block`'s pane colour through, i.e. no fill here.
      color: selected ? t.accent.withValues(alpha: 0.18) : null,
      borderRadius: BorderRadius.circular(5),
      child: InkWell(
        onTap: () => context.read<AppState>().setRetentionTier(tier),
        borderRadius: BorderRadius.circular(5),
        child: Container(
          // F1.html:84 `.tier { padding: 8px 6px; }`.
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(color: selected ? t.accent : t.borderSoft),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tier.label,
                // F1.html:86 `.tier .name { font-size: 10.5px; font-weight: 600; }`.
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: t.text,
                ),
              ),
              const SizedBox(height: 2), // F1.html:87 .tier .val margin-top
              Text(
                '${policy.payloadByteBudget ~/ (1024 * 1024)} MiB',
                // F1.html:87 `.tier .val { font-size: 11px; font-weight: 700; }`.
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'monospace',
                  color: t.accent,
                ),
              ),
              const SizedBox(height: 1), // F1.html:88 .tier .formula margin-top
              Text(
                // F1.html:155-157 dropped D1's "photos" suffix (F1 overrides
                // D1's `.tier .formula` copy and font-size for this round).
                '−${policy.before} / +${policy.after}',
                // F1.html:88 `.tier .formula { font-size: 8.5px; }`.
                style: TextStyle(fontSize: 8.5, color: t.textFaint),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
