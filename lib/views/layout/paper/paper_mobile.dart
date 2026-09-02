import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/app_state.dart';
import '../common/exif_caption.dart';
import 'paper_palette.dart';
import '../main_surface.dart';

/// The `paper` theme's mobile arrangement (round 3, task #16).
///
/// Spec: `docs/logs/2026-09-01/mockup/paper/c1-mobile-{light,dark}.html`,
/// frame 1 ("Triage at rest") and frame 4 ("Welcome — no folder open").
///
/// IN SCOPE THIS ROUND, per the round-3 contract ("手機版初步建置"): the
/// resting triage screen and the welcome screen. OUT OF SCOPE, both
/// explicitly marked in the mockup itself:
/// - Frame 2 (chrome-on after a centre tap, the four R3 swipe/tap gesture
///   cues, the filmstrip and star/trash bar) — the mockup's own caption
///   reads "NOT BUILT IN ROUND 1 (R6)"; nothing in the round-3 contract lifts
///   that. `PaperMobileSurface` therefore draws the photo and its caption
///   only, with no tap-to-summon interaction.
/// - Frame 3 (Options sheet) — R1: dialogs keep today's colours/widget,
///   unrecoloured; the existing settings dialog is reused as-is, so there is
///   nothing mobile-specific to build here.
///
/// Geometry note: the mockup draws its own fake status bar and home
/// indicator (`.statusbar`, `.homebar`) to simulate a device frame for the
/// screenshot; those are chrome the OS itself draws in a real app and are
/// NOT reproduced here. [MediaQuery.of(context).padding] is used instead of
/// the mockup's literal `top:44` so the layout is correct on any device's
/// real safe-area inset.
class PaperMobileSurface extends StatelessWidget {
  const PaperMobileSurface({super.key, required this.surface});

  final MainSurface surface;

  static const ValueKey<String> stageKey = ValueKey<String>(
    'paper.mobile.stage',
  );
  static const ValueKey<String> labelKey = ValueKey<String>(
    'paper.mobile.label',
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final identity = surface.identity;

    // No folder loaded → mobile welcome frame, gated the same way as the
    // gallery and darkroom mobile surfaces (identity == null), so the
    // desktop-scaled PaperEmptyState inside PhotoViewport never shows on a
    // phone. (Lead wiring, round-3 close.)
    if (identity == null) {
      return const PaperMobileEmptyState();
    }

    return ColoredBox(
      color: colors.surface, // --app equivalent scaffold background
      child: SafeArea(
        child: Column(
          children: [
            // .mstage: the photo (or whatever empty/loading state
            // [MainSurface.viewport] already resolved to — this widget only
            // POSITIONS it, per the layout-theme seam contract; it does not
            // branch on folder-empty itself). Filled, not box-constrained to
            // the mockup's literal 354x472: that figure is the RESULT of
            // PhotoViewport's own BoxFit sizing against these constraints,
            // not an input this theme should impose (mirrors paper_desktop's
            // unconstrained `Positioned(child: surface.viewport)`).
            Expanded(
              child: Container(
                key: stageKey,
                width: double.infinity,
                color: colors.surfaceContainer, // --sunk
                child: surface.viewport,
              ),
            ),
            // .mlabel: filename + compact EXIF line + index, below the photo.
            Padding(
              key: labelKey,
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
              child: Column(
                children: [
                  Text(
                    identity.displayName,
                    style: TextStyle(
                      fontFamily: 'serif',
                      fontSize: 15,
                      color: colors.onSurface,
                    ),
                  ),
                  const SizedBox(height: 5),
                  ExifCaption(
                    fileName: null,
                    exif: identity.exif,
                    compact: true,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${identity.indexInFolder} / ${identity.folderCount}',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: PaperPalette.of(context).textFaint,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The `paper` theme's mobile welcome screen (mockup `.mwelcome`, frame 4).
/// Same structure as [PaperEmptyState] (desktop, `paper_welcome.dart`) but at
/// mobile scale, and with no keyboard-shortcut hint — mobile has no chord to
/// show (mockup: `.drop` reads "or drop a folder onto the window", no
/// leading `⌘O`).
class PaperMobileEmptyState extends StatelessWidget {
  const PaperMobileEmptyState({super.key});

  static const Key mountKey = Key('paperMobileEmptyMount');
  static const Key buttonKey = Key('paperMobileEmptyOpenFolder');
  static const Key hintKey = Key('paperMobileEmptyDropHint');

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = PaperPalette.of(context);

    return ColoredBox(
      color: colors.surface,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // .mwelcome .mount: 300x200, the photo's own 3:2.
                Container(
                  key: mountKey,
                  width: 300,
                  height: 200,
                  decoration: BoxDecoration(
                    color: colors.surface,
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x38000000),
                        blurRadius: 34,
                        offset: Offset(0, 12),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(9),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(color: colors.outlineVariant),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  'No folder open',
                  style: TextStyle(
                    fontFamily: 'serif',
                    fontSize: 19,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Open a folder of RAW or JPEG files to browse it, star the '
                  'keepers, mark the rejects, then copy or move what you '
                  'kept.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                Container(
                  width: 40,
                  height: 1,
                  margin: const EdgeInsets.symmetric(vertical: 16),
                  color: colors.outlineVariant,
                ),
                // Alone on its own row, same structural rule as desktop
                // (nothing shares a row with the button).
                FilledButton.icon(
                  key: buttonKey,
                  onPressed: () => context.read<AppState>().openFolder(),
                  style: FilledButton.styleFrom(
                    backgroundColor: colors.primary,
                    foregroundColor: palette.accentInk,
                    minimumSize: const Size(0, 44), // 44pt touch-target floor
                  ),
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: const Text('Open Folder'),
                ),
                const SizedBox(height: 14),
                // No keyboard-shortcut prefix on mobile (mockup: `.drop` has
                // no leading `⌘O` here, unlike the desktop welcome screen).
                Text(
                  'or drop a folder onto the window',
                  key: hintKey,
                  style: TextStyle(
                    fontSize: 10.5,
                    letterSpacing: 0.5,
                    color: palette.textFaint,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
