import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../providers/settings_snapshot.dart';
import '../services/image_pipeline/retention_policy.dart';
import 'settings_dialog/memory_tab.dart';
import 'settings_dialog/performance_tab.dart';
import 'settings_dialog/settings_primitives.dart';
import 'settings_dialog/settings_summary_rail.dart';
import 'settings_dialog/shortcuts_tab.dart';
import 'theme_tokens.dart';

/// D1's tabbed settings panel (docs/logs/2026-08-30/mockups/D1.html):
/// concurrent RAW decodes, export JPEG quality, memory retention tier and
/// keyboard shortcuts, with a live "at a glance" summary rail.
///
/// The panel applies every change live so the rail and the pipeline reflect
/// it immediately (§1.6); Cancel, the barrier tap and Escape all revert via
/// the snapshot captured in [initState] -- [dispose] is the single choke
/// point that guarantees every dismissal path reverts unless Done committed.
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key});

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late final AppState _state;
  late final SettingsSnapshot _snapshot;
  bool _committed = false;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    // Captured once, not re-read via context.read in dispose(): by the time
    // dispose() runs the element tree may already be inactive, and looking
    // up an InheritedWidget ancestor from a deactivated widget is unsafe.
    _state = context.read<AppState>();
    _snapshot = _state.settingsSnapshot();
  }

  @override
  void dispose() {
    if (!_committed) {
      // Deferred to the next frame: calling notifyListeners() synchronously
      // from dispose() can run while the element tree is still locked mid-
      // unmount (e.g. a Navigator.pop() during a widget-tree teardown pass),
      // which throws "setState() or markNeedsBuild() called when widget tree
      // was locked". By the next frame the tree is unlocked again.
      final state = _state;
      final snapshot = _snapshot;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          state.restoreSettings(snapshot);
        } catch (_) {
          // AppState was already disposed (e.g. host app shutting down, or a
          // test tearing it down before this deferred frame runs) -- there is
          // nothing left to revert.
        }
      });
    }
    super.dispose();
  }

  void _done() {
    _committed = true;
    Navigator.of(context).pop();
  }

  void _cancel() {
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = HalcyonTokens.of(context);
    final state = context.watch<AppState>();

    return Dialog(
      backgroundColor: t.dialog,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 920,
        height: 560,
        child: Column(
          children: [
            _header(t, state),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 18,
                      ),
                      child: switch (_tab) {
                        0 => const PerformanceTab(),
                        1 => const MemoryTab(),
                        _ => const ShortcutsTab(),
                      },
                    ),
                  ),
                  const SettingsSummaryRail(),
                ],
              ),
            ),
            settingsFooterButtons(t, onCancel: _cancel, onDone: _done),
          ],
        ),
      ),
    );
  }

  Widget _header(HalcyonTokens t, AppState state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Settings',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: t.text,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Tabbed sections with a live summary at a glance',
                      style: TextStyle(fontSize: 11.5, color: t.textDim),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  border: Border.all(color: t.border),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${state.retentionTier.label} tier',
                  style: TextStyle(fontSize: 10.5, color: t.textDim),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: t.borderSoft)),
            ),
            padding: const EdgeInsets.only(bottom: 14),
            child: SettingsTabBar(
              labels: const ['Performance', 'Memory', 'Shortcuts'],
              keys: const [
                Key('settingsTab.performance'),
                Key('settingsTab.memory'),
                Key('settingsTab.shortcuts'),
              ],
              selectedIndex: _tab,
              onSelect: (i) => setState(() => _tab = i),
            ),
          ),
        ],
      ),
    );
  }
}
