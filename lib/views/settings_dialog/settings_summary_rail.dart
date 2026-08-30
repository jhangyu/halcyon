import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/shortcut_bindings.dart';
import '../../providers/app_state.dart';
import '../../services/image_pipeline/retention_policy.dart';
import '../theme_tokens.dart';

/// D1's `.summary-rail` (D1.html:48), visible on every tab (§1.5.4).
class SettingsSummaryRail extends StatelessWidget {
  const SettingsSummaryRail({super.key});

  @override
  Widget build(BuildContext context) {
    final t = HalcyonTokens.of(context);
    final state = context.watch<AppState>();
    final conflicts = state.shortcutBindings.conflicts;
    final conflictCount = conflicts.length;
    final conflictText = conflictCount == 0
        ? 'None'
        : '$conflictCount conflict${conflictCount == 1 ? '' : 's'} '
              '(${conflicts.keys.map(keyLabelFor).join(', ')})';

    return Container(
      width: 224,
      decoration: BoxDecoration(
        color: t.pane,
        border: Border(left: BorderSide(color: t.borderSoft)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'AT A GLANCE',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.63,
                color: t.textFaint,
              ),
            ),
            const SizedBox(height: 12), // D1.html:49 h2 margin-bottom
            _item(
              t,
              'Concurrent decodes',
              Text(
                '${state.decodeLaneWidth} / ${state.maxDecodeLaneWidth}',
                style: TextStyle(
                  fontSize: 13,
                  fontFamily: 'monospace',
                  color: t.text,
                ),
              ),
            ),
            const SizedBox(height: 14),
            _item(
              t,
              'Export quality',
              Text(
                '${state.exportJpegQuality}',
                style: TextStyle(
                  fontSize: 13,
                  fontFamily: 'monospace',
                  color: t.text,
                ),
              ),
            ),
            const SizedBox(height: 14),
            _item(
              t,
              'Retention tier',
              Text(
                '${state.retentionTier.label} · '
                '${retentionPolicyForTier(state.retentionTier).payloadByteBudget ~/ (1024 * 1024)} MiB',
                style: TextStyle(
                  fontSize: 13,
                  fontFamily: 'monospace',
                  color: t.text,
                ),
              ),
            ),
            const SizedBox(height: 14),
            _item(
              t,
              'Shortcut conflicts',
              Text(
                conflictText,
                key: const Key('summaryRail.conflicts'),
                style: TextStyle(
                  fontSize: 13,
                  fontFamily: 'monospace',
                  color: conflictCount > 0 ? t.danger : t.text,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _item(HalcyonTokens t, String label, Widget value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 10.5, color: t.textFaint)),
        const SizedBox(height: 2), // D1.html:51 .summary-item .label margin
        value,
      ],
    );
  }
}
