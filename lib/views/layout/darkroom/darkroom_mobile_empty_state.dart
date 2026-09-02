import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/app_state.dart';
import 'darkroom_palette.dart';

/// The `darkroom` theme's mobile welcome frame (`.mwel`), the
/// user-approved-2026-09-02 redesign referenced in the round-3 contract —
/// NOT the earlier rejected `.mempty` solid-accent button.
///
/// Per `c2-mobile-{light,dark}.html:249-268` and its own changelog comment
/// (lines ~210-245): mount at the photo's 3:2 (300x200 on a 390 phone),
/// kicker / headline / sentence / hairline / button on one centred axis, and
/// the button takes its GEOMETRY from `.vb` (44px tall, 8px radius, 8px gap,
/// 18px icon) and its COLOUR from the "this one is live" idiom
/// (`--accent-wash` fill, 1px `--accent` border) — never a solid accent fill.
/// Copy drops the desktop's "or drop a folder onto the window" line: a phone
/// has no window and no folder drag-and-drop.
class DarkroomMobileEmptyState extends StatelessWidget {
  const DarkroomMobileEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = DarkroomPalette.of(context);
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          key: const ValueKey<String>('darkroom-mobile-welcome'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              key: const ValueKey<String>('darkroom-mobile-welcome-mount'),
              width: 300,
              height: 200,
              decoration: BoxDecoration(
                color: palette.stage,
                border: Border.all(color: colors.outline, width: 1),
              ),
            ),
            const SizedBox(height: 30),
            Text(
              'Halcyon',
              style: TextStyle(
                fontSize: 9,
                letterSpacing: 0.22 * 9,
                color: palette.textFaint,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'No folder open',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w500,
                color: colors.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Open a folder of RAW or JPEG files to browse it, star the '
              'keepers, mark the rejects, then copy or move what you kept.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(width: 40, child: Divider(color: colors.outlineVariant)),
            const SizedBox(height: 18),
            // Single-child act row — never shares a row with a shortcut hint.
            ElevatedButton(
              key: const ValueKey<String>('darkroom-mobile-welcome-open'),
              onPressed: () => context.read<AppState>().openFolder(),
              style: ElevatedButton.styleFrom(
                backgroundColor: palette.accentWash,
                foregroundColor: colors.onSurface,
                side: BorderSide(color: colors.primary),
                elevation: 0,
                minimumSize: const Size(0, 44),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Text(
                'Open Folder',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
