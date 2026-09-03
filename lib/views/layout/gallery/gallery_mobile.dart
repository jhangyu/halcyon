import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/app_state.dart';
import '../common/exif_caption.dart';
import '../common/photo_thumbnail.dart';
import '../common/visible_range_reporter.dart';
import '../gallery/gallery_palette.dart';
import '../main_surface.dart';

/// The `gallery` theme's mobile arrangement (round 3), from
/// `docs/logs/2026-09-01/mockup/gallery/c3-mobile-{light,dark}.html`.
///
/// Presentational only, like [GalleryDesktopSurface]: everything this needs
/// arrives already resolved inside [MainSurface]. Stateful only for the one
/// piece of UI state the mockup itself introduces — whether the "chrome"
/// (filmstrip + gesture cues) is summoned (R3: tap centre toggles it).
///
/// Reproduced from the mockup (frames 1/2/4):
/// - Frame 1/2 (triage, rest / chrome-on): the photo unaccompanied at rest;
///   a centre tap reveals a top-edge filmstrip and the wall label always
///   shown (the mockup's `.label` is NOT gated by chrome — only `.strip`
///   and `.gestures` are, via `.phone.resting .contact,.strip{display:none}`
///   and `.phone.resting .gestures{display:none}`).
/// - Frame 4 (welcome): reproduced separately as [_GalleryMobileWelcome],
///   gated on `surface.identity == null` (no folder loaded) rather than by
///   reading `AppState` directly — [MainSurface] already carries that signal.
///
/// NOT reproduced this round (see the task report for the full list):
/// swipe-to-navigate/star/trash gestures, the four gesture gesture-cue
/// glyphs + centre tap ring, and the Settings "unfold from the wall label"
/// sheet (frame 3) — Settings stays reachable via the existing `Options`
/// entry in [PhotoActions.menu] for this round.
class GalleryMobileSurface extends StatefulWidget {
  const GalleryMobileSurface({super.key, required this.surface});

  final MainSurface surface;

  @override
  State<GalleryMobileSurface> createState() => _GalleryMobileSurfaceState();
}

/// Chip geometry off the mockup (`.fr{width:60px;height:46px}`,
/// `.fr.here{width:78px;height:62px}`).
const double kGalleryMobileChipWidth = 60;
const double kGalleryMobileChipHeight = 46;
const double kGalleryMobileChipWidthSelected = 78;
const double kGalleryMobileChipHeightSelected = 62;

/// Same constant decode request as the desktop chip (AD-011 red line): the
/// bitmap is requested once at 200px long edge and scaled down by layout,
/// never re-requested at the live chip size.
const double kGalleryMobileChipDecodeWidth = 200;

/// Test key on the summoned filmstrip (`.strip`, only present while the
/// chrome is on).
const ValueKey<String> kGalleryMobileStripKey =
    ValueKey<String>('gallery.mobile.strip');

/// Test key on the wall label (`.label`).
const ValueKey<String> kGalleryMobileLabelKey =
    ValueKey<String>('gallery.mobile.label');

/// Test key on the centre-tap target that toggles the chrome.
const ValueKey<String> kGalleryMobileTapZoneKey =
    ValueKey<String>('gallery.mobile.tapzone');

class _GalleryMobileSurfaceState extends State<GalleryMobileSurface>
    with VisibleRangeReporter<GalleryMobileSurface> {
  bool _chromeOn = false;

  // Visible-range reporting, itemBuilder-driven (AD-014 / G-001 red line —
  // no ScrollController listener), via the shared VisibleRangeReporter.
  final ScrollController _stripController = ScrollController();

  @override
  ScrollController? get rangeScrollController => _stripController;

  @override
  PhotoStripModel get rangeStrip => widget.surface.strip;

  // rangeColumns stays 1 and rangeRowExtent stays null: the mobile strip is a
  // horizontal single row with no uniform vertical pitch to divide by, so the
  // built-index path is the whole of its reporting.

  @override
  void dispose() {
    _stripController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final surface = widget.surface;
    if (surface.identity == null) {
      return const _GalleryMobileWelcome();
    }

    final palette = GalleryPalette.of(context);
    final colors = Theme.of(context).colorScheme;
    final identity = surface.identity;

    return Stack(
      children: [
        // The photo, unaccompanied. A centre tap toggles the chrome (R3).
        Positioned.fill(
          child: GestureDetector(
            key: kGalleryMobileTapZoneKey,
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _chromeOn = !_chromeOn),
            child: surface.viewport,
          ),
        ),
        // Filmstrip, summoned at the top edge only while the chrome is on
        // (`.phone.resting .strip{display:none}`).
        if (_chromeOn)
          Positioned(
            key: kGalleryMobileStripKey,
            left: 0,
            right: 0,
            top: 0,
            height: 92,
            child: _buildStrip(context, surface, colors),
          ),
        // Wall label — always shown (not chrome-gated in the mockup).
        Positioned(
          key: kGalleryMobileLabelKey,
          left: 22,
          bottom: 34,
          width: 250,
          child: Container(
            padding: const EdgeInsets.only(left: 11),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: colors.outline), // --hair-strong
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  identity?.displayName ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    letterSpacing: 0.02 * 12.5,
                    color: colors.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  identity == null
                      ? ''
                      : '${identity.indexInFolder} of ${identity.folderCount}',
                  style: TextStyle(
                    fontSize: 9.5,
                    letterSpacing: 0.1 * 9.5,
                    color: palette.textFaint,
                  ),
                ),
                const SizedBox(height: 4),
                // R4: EXIF caption, mobile compact path.
                ExifCaption(
                  exif: identity?.exif,
                  compact: true,
                ),
                const SizedBox(height: 3),
                _buildMarksRow(context, surface, palette, colors),
              ],
            ),
          ),
        ),
        // Transient status toast, unchanged position semantics (left-anchored
        // above the label).
        Positioned(
          left: 22,
          bottom: 12,
          right: 22,
          child: surface.statusOverlay,
        ),
      ],
    );
  }

  Widget _buildMarksRow(
    BuildContext context,
    MainSurface surface,
    GalleryPalette palette,
    ColorScheme colors,
  ) {
    final actions = surface.actions;
    final identity = surface.identity;
    final isStarred = identity?.status.name == 'starred';
    final isTrashed = identity?.status.name == 'trashed';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          key: const ValueKey<String>('gallery-mobile-star'),
          onTap: actions.onStar,
          child: Icon(
            isStarred ? Icons.star : Icons.star_border,
            size: 18,
            color: isStarred ? palette.star : palette.textFaint,
          ),
        ),
        const SizedBox(width: 10),
        GestureDetector(
          key: const ValueKey<String>('gallery-mobile-trash'),
          onTap: actions.onTrash,
          child: Icon(
            isTrashed ? Icons.delete : Icons.delete_outline,
            size: 18,
            color: isTrashed ? colors.error : palette.textFaint,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          'Options',
          style: TextStyle(
            fontSize: 9.5,
            letterSpacing: 0.1 * 9.5,
            color: palette.textFaint,
          ),
        ),
      ],
    );
  }

  Widget _buildStrip(
    BuildContext context,
    MainSurface surface,
    ColorScheme colors,
  ) {
    final strip = surface.strip;
    final items = strip.items;
    return Container(
      color: colors.surface.withValues(alpha: 0.92), // --edge-veil
      padding: const EdgeInsets.symmetric(horizontal: 14),
      alignment: Alignment.center,
      child: RepaintBoundary(
        child: ListenableBuilder(
          listenable: strip.revision,
          builder: (context, _) => ListView.builder(
            controller: _stripController,
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            itemBuilder: (context, index) {
          noteBuiltIndex(index);
          final item = items[index];
          final selected = item.id == strip.selectedId;
          final width = selected
              ? kGalleryMobileChipWidthSelected
              : kGalleryMobileChipWidth;
          final height = selected
              ? kGalleryMobileChipHeightSelected
              : kGalleryMobileChipHeight;
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            // Center: a horizontal ListView hands its children TIGHT cross-
            // axis constraints (the strip's own 92px height), which would
            // otherwise stretch the chip's Container past its own explicit
            // height (the "selected chip renders at 92 instead of 62" bug).
            // Center relaxes that to a loose upper bound, so the chip's own
            // height wins.
            child: Center(
              child: GestureDetector(
                key: ValueKey<String>('gallery-mobile-chip-tap-${item.id}'),
                onTap: () => strip.onSelect(item.id),
                child: Container(
                  key: ValueKey<String>('gallery-mobile-chip-${item.id}'),
                  width: width,
                  height: height,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: selected ? colors.primary : colors.outlineVariant,
                      width: selected ? 2 : 1,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: FittedBox(
                    fit: BoxFit.cover,
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(
                      width: kGalleryMobileChipDecodeWidth,
                      height: kGalleryMobileChipDecodeWidth * 2 / 3,
                      child: PhotoThumbnail(
                        payload: strip.payloadFor(item.id),
                        width: kGalleryMobileChipDecodeWidth,
                        height: kGalleryMobileChipDecodeWidth * 2 / 3,
                        borderRadius: 0,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
            },
          ),
        ),
      ),
    );
  }
}

/// The mockup's `.gwel` welcome frame (redrawn task #11), reproduced as its
/// own widget rather than by reusing [PhotoViewport]'s desktop
/// `_GalleryEmptyState` — the two are not the same drawing (300x200 mount vs
/// 432x288, no drop-hint line, no keyboard-shortcut hint: a phone has neither
/// a window to drop onto nor a chord).
///
/// Test handles mirror the desktop welcome's naming so a reviewer can find
/// them the same way.
class _GalleryMobileWelcome extends StatelessWidget {
  const _GalleryMobileWelcome();

  static const Key mountKey = Key('galleryMobileEmptyMount');
  static const Key buttonKey = Key('galleryMobileEmptyOpenFolder');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = GalleryPalette.of(context);

    return ColoredBox(
      color: palette.mat, // --mat
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // The empty mount, at the mobile mockup's own 300x200 (not the
              // desktop's 432x288 — the two frames are drawn at different
              // scales).
              Container(
                key: mountKey,
                width: 300,
                height: 200,
                decoration: BoxDecoration(
                  color: theme.scaffoldBackgroundColor,
                  border: Border.all(color: colors.outline),
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
                'Halcyon'.toUpperCase(),
                style: TextStyle(
                  fontSize: 9,
                  letterSpacing: 0.22 * 9,
                  color: palette.textFaint,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'No folder open',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.01 * 18,
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
                  letterSpacing: 0.02 * 12,
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              Container(width: 40, height: 1, color: colors.outline),
              const SizedBox(height: 18),
              // Alone on its row (same axis rule as the desktop welcome): no
              // drop-hint / keyboard-shortcut line follows it on mobile.
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ElevatedButton.icon(
                    key: buttonKey,
                    onPressed: () => context.read<AppState>().openFolder(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colors.primary,
                      foregroundColor: palette.onAccent,
                      minimumSize: const Size(0, 44),
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                    icon: const Icon(Icons.folder_open, size: 15),
                    label: const Text('Open Folder'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
