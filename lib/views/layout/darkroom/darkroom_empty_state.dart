import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/app_state.dart';
import 'darkroom_palette.dart';

/// The `darkroom` theme's welcome screen (mockup frame 6, NOTES.md "Frame 6 —
/// welcome / no folder open"): an empty mount at the photo's own 3:2, kicker /
/// headline / sentence / hairline / Open Folder button / drop hint all on one
/// centred vertical axis.
///
/// NOT YET WIRED into `PhotoViewport`'s empty-state branch
/// (`lib/views/layout/common/photo_viewport.dart:87-89`), which currently
/// special-cases only `LayoutThemeId.gallery` — that file is shared and
/// outside this task's ownership. Per team-lead: the branch for
/// `LayoutThemeId.darkroom` is added during registry wiring (task #14).
class DarkroomEmptyState extends StatelessWidget {
  const DarkroomEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = DarkroomPalette.of(context);
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        key: const ValueKey<String>('darkroom-welcome'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Empty mount at the photo's own 3:2 (432x288 in the mockup).
          Container(
            key: const ValueKey<String>('darkroom-welcome-mount'),
            width: 288,
            height: 192,
            decoration: BoxDecoration(
              color: palette.stage,
              border: Border.all(color: colors.outline, width: 1),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'DARKROOM',
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 0.14 * 11,
              fontWeight: FontWeight.w600,
              color: palette.textFaint,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Open a folder to begin',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Your photos, one at a time, nothing else on screen.',
            style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 18),
          SizedBox(width: 44, child: Divider(color: colors.outlineVariant)),
          const SizedBox(height: 18),
          // Single-child row: the button must never share a Row with the
          // shortcut hint (the gallery off-axis defect NOTES.md warns
          // against — "centring a row centres the ROW").
          ElevatedButton(
            key: const ValueKey<String>('darkroom-welcome-open'),
            onPressed: () => context.read<AppState>().openFolder(),
            style: ElevatedButton.styleFrom(
              backgroundColor: colors.primary,
              foregroundColor: palette.onAccent,
            ),
            child: const Text('Open Folder'),
          ),
          const SizedBox(height: 10),
          Text(
            'or drop a folder onto the window',
            style: TextStyle(fontSize: 11, color: palette.textFaint),
          ),
        ],
      ),
    );
  }
}
