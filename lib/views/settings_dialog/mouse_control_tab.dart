import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_settings.dart';
import '../../providers/app_state.dart';
import '../theme_tokens.dart';
import 'settings_primitives.dart';
import 'settings_section_label.dart';

/// "Mouse Control" tab (spec §3.2; user-picked mockup-a, toggle-switch
/// variant, contract addendum 2026-10-08). Stateless: every write goes
/// straight to AppState, so Cancel/Done/Reset need nothing tab-local.
class MouseControlTab extends StatelessWidget {
  const MouseControlTab({super.key});

  @override
  Widget build(BuildContext context) {
    final t = HalcyonTokens.of(context);
    final state = context.watch<AppState>();
    final enabled = state.mouseNavEnabled;
    void setEnabled(bool v) => context.read<AppState>().setMouseNavEnabled(v);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        settingsSectionLabel(t, 'Mouse navigation'),
        settingsBlock(
          t,
          Row(
            children: [
              Expanded(
                // Spec §3.2: tapping the row title also toggles.
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setEnabled(!enabled),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      settingsRowLabel(t, 'Navigate photos with mouse clicks'),
                      // Spec §3.2 exact strings (mockup-a :247-248).
                      KeyedSubtree(
                        key: const Key('mouseControl.enabledCaption'),
                        child: settingsCaption(
                          t,
                          enabled
                              ? 'On · applies in the photo viewer only'
                              : 'Off · clicks in the photo viewer do not change the photo',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 16), // mockup-a `.sw-row { gap:16px }`
              settingsSwitch(
                t,
                key: const Key('mouseControl.enabled'),
                value: enabled,
                onChanged: setEnabled,
              ),
            ],
          ),
        ),
        const SizedBox(height: 18), // section gap, guidelines §3
        settingsSectionLabel(t, 'Click direction'),
        settingsBlock(
          t,
          // Disabled look = export quality slider pattern
          // (export_tab.dart:138-141). The stored mapping stays visible.
          IgnorePointer(
            ignoring: !enabled,
            child: Opacity(
              key: const Key('mouseControl.mappingRow'), // TC-1507/1508 read this
              opacity: enabled ? 1.0 : 0.4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  settingsRowLabel(t, 'Which button goes to the next photo'),
                  // Spec §3.2 exact strings (mockup-a :251-253).
                  KeyedSubtree(
                    key: const Key('mouseControl.mappingCaption'),
                    child: settingsCaption(
                      t,
                      state.mouseNavMapping == MouseNavMapping.leftNext
                          ? 'Left click → next · Right click → previous'
                          : 'Left click → previous · Right click → next',
                    ),
                  ),
                  const SizedBox(height: 10), // mockup-a fieldset margin-top
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _mappingCard(
                          context,
                          t,
                          key: const Key('mouseControl.mapping.leftNext'),
                          value: MouseNavMapping.leftNext,
                          current: state.mouseNavMapping,
                          name: 'Left click = Next, Right click = Previous',
                          leftAction: 'Next',
                          rightAction: 'Previous',
                          sub: 'Default',
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: _mappingCard(
                          context,
                          t,
                          key: const Key('mouseControl.mapping.leftPrevious'),
                          value: MouseNavMapping.leftPrevious,
                          current: state.mouseNavMapping,
                          name: 'Left click = Previous, Right click = Next',
                          leftAction: 'Previous',
                          rightAction: 'Next',
                          sub: 'Reversed',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Choice card in the tier-card layout (performance_memory_tab.dart:260-300,
  /// padding 8x6), content per spec §3.2 / mockup-a :174-191.
  Widget _mappingCard(
    BuildContext context,
    HalcyonTokens t, {
    required Key key,
    required MouseNavMapping value,
    required MouseNavMapping current,
    required String name,
    required String leftAction,
    required String rightAction,
    required String sub,
  }) {
    return settingsSelectable(
      t,
      key: key,
      selected: value == current,
      onTap: () => context.read<AppState>().setMouseNavMapping(value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: t.text,
              ),
            ),
            const SizedBox(height: 6), // mockup-a `.card .map { margin-top:6px }`
            Row(
              children: [
                _pair(t, 'L', leftAction),
                const SizedBox(width: 12), // `.card .map { gap:12px }`
                _pair(t, 'R', rightAction),
              ],
            ),
            const SizedBox(height: 4), // `.card .sub { margin-top:4px }`
            Text(sub, style: TextStyle(fontSize: 8.5, color: t.textFaint)),
          ],
        ),
      ),
    );
  }

  /// `settingsKeyChip` (existing, unchanged) + 6 px + action word.
  Widget _pair(HalcyonTokens t, String chip, String action) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        settingsKeyChip(t, chip),
        const SizedBox(width: 6),
        Text(
          action,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            fontFamily: 'monospace',
            color: t.accent,
          ),
        ),
      ],
    );
  }
}
