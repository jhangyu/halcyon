import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/app_state.dart';
import 'paper_palette.dart';

/// The `paper` theme's welcome screen — the state the app opens in (mockup
/// frame 8, `docs/logs/2026-09-01/mockup/paper/c1-desktop-light.html:469-471`,
/// NOTES.md "Frame 8 — welcome, no folder open").
///
/// WIRED: `lib/views/layout/common/photo_viewport.dart` switches the empty
/// state on the selected layout theme and returns this widget for the `paper`
/// case. Round 4 changed that switch from the `activeLayoutTheme` constant to
/// `AppState.layoutThemeId`, so the welcome screen now follows the user's
/// persisted theme. The switch is exhaustive: a new theme cannot compile
/// until it declares a welcome screen.
///
/// Structural rule carried from the mockup verbatim: NOTHING shares a row
/// with the Open Folder button. A centred row centres the row, not the
/// button inside it, which would push the button off the axis by half the
/// width of whatever shares its line — the exact defect the mockup's own
/// NOTES.md records being caught and fixed in the `gallery` theme's first
/// version of this screen. The keyboard-shortcut hint therefore lives on its
/// own centred line below the button, not beside it.
class PaperEmptyState extends StatelessWidget {
  const PaperEmptyState({super.key});

  static const Key mountKey = Key('paperEmptyMount');
  static const Key buttonKey = Key('paperEmptyOpenFolder');
  static const Key hintKey = Key('paperEmptyDropHint');

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = PaperPalette.of(context);

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Empty mount at the photo's own 3:2 (mockup `.mount`, 432x288).
          Container(
            key: mountKey,
            width: 432,
            height: 288,
            decoration: BoxDecoration(
              color: colors.surface,
              boxShadow: const [
                BoxShadow(color: Color(0x38000000), blurRadius: 34, offset: Offset(0, 12)),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: colors.outlineVariant,
                    style: BorderStyle.solid,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 36),
          Text(
            'No folder open',
            style: TextStyle(
              fontFamily: 'serif',
              fontSize: 21,
              fontWeight: FontWeight.w600,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(height: 9),
          SizedBox(
            width: 392,
            child: Text(
              'Open a folder of RAW or JPEG files to browse it, star the '
              'keepers, mark the rejects, then copy or move what you kept.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, height: 1.65, color: colors.onSurfaceVariant),
            ),
          ),
          Container(
            width: 44,
            height: 1,
            margin: const EdgeInsets.symmetric(vertical: 20),
            color: colors.outlineVariant,
          ),
          // Alone on its own row — the structural rule above.
          FilledButton.icon(
            key: buttonKey,
            onPressed: () => context.read<AppState>().openFolder(),
            style: FilledButton.styleFrom(
              backgroundColor: colors.primary,
              foregroundColor: palette.accentInk,
            ),
            icon: const Icon(Icons.folder_open, size: 16),
            label: const Text('Open Folder'),
          ),
          const SizedBox(height: 14),
          // The keyboard shortcut, on its own centred line — never sharing a
          // row with the button (see class doc).
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '⌘O',
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
                TextSpan(
                  text: ' or drop a folder onto the window',
                  style: TextStyle(color: palette.textFaint),
                ),
              ],
            ),
            key: hintKey,
            style: const TextStyle(fontSize: 10.5, letterSpacing: 0.5),
          ),
        ],
      ),
    );
  }
}
