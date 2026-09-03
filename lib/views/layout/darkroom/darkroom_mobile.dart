import 'package:flutter/material.dart';

import '../../../models/photo_item.dart';
import '../common/exif_caption.dart';
import '../common/photo_thumbnail.dart';
import '../main_surface.dart';
import 'darkroom_mobile_empty_state.dart';
import 'darkroom_palette.dart';

/// The `darkroom` theme's mobile (Android/iOS) arrangement (round 3, task
/// #17), per `docs/logs/2026-09-01/mockup/darkroom/c2-mobile-{light,dark}.html`.
///
/// Round-3 scope (contract, verbatim): mobile is used ONLY on Android/iOS;
/// spec is the mobile mockup including the round-1 welcome frame; desktop
/// behavior (task #13) is unaffected — this file is additive, wired only
/// through [DarkroomLayout.buildMobileSurface].
///
/// Frame 1 (mockup line 334): "photo 390 x 260, persistent picture row, no
/// gesture cues" — gesture cues (`.gestures`, `.tapring`, `.cue-*`) appear
/// only once chrome is toggled on by a centre tap, which is explicitly out of
/// round-3 scope (initial build only); the strip and the EXIF caption are
/// always visible, matching frame 1 exactly.
class DarkroomMobileSurface extends StatelessWidget {
  const DarkroomMobileSurface({super.key, required this.surface});

  final MainSurface surface;

  @override
  Widget build(BuildContext context) {
    if (surface.strip.items.isEmpty) {
      return const DarkroomMobileEmptyState();
    }
    final palette = DarkroomPalette.of(context);
    final colors = Theme.of(context).colorScheme;

    return Column(
      children: [
        // The photo, width-limited on a portrait phone (mockup: 390x260 on a
        // 390-wide phone, i.e. the full available width at 3:2).
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: palette.stage, child: surface.viewport),
              // EXIF caption, compact path (mockup `.label .exif`): under the
              // photo in dead space is the mobile placement, but since the
              // photo fills the Expanded region here, this floats bottom-left
              // over it, matching desktop's over-the-photo convention with
              // compact:true collapsing it to one line.
              Positioned(
                left: 12,
                bottom: 8,
                right: 12,
                child: DefaultTextStyle(
                  style: TextStyle(color: palette.photoInkDim),
                  child: ExifCaption(
                    fileName: surface.identity?.displayName,
                    exif: surface.identity?.exif,
                    compact: true,
                  ),
                ),
              ),
              Positioned(left: 12, top: 12, child: surface.statusOverlay),
            ],
          ),
        ),
        // The persistent picture row — "the darkroom identity on mobile"
        // (mockup comment). 150px, wordless (no filename/counter), a
        // horizontal strip of chips with star/trash toggles at the top.
        _buildStrip(context, palette, colors),
      ],
    );
  }

  Widget _buildStrip(
    BuildContext context,
    DarkroomPalette palette,
    ColorScheme colors,
  ) {
    final strip = surface.strip;
    final actions = surface.actions;
    final status = surface.identity?.status;
    final isStarred = status == PhotoStatus.starred;
    final isTrashed = status == PhotoStatus.trashed;

    return Container(
      key: const ValueKey<String>('darkroom-mobile-strip'),
      height: 150,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.outlineVariant)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                icon: Icon(
                  isStarred ? Icons.star : Icons.star_border,
                  size: 15,
                  color: isStarred ? palette.star : palette.textFaint,
                ),
                onPressed: actions.onStar,
                tooltip: 'Star',
                padding: EdgeInsets.zero,
                style: const ButtonStyle(
                  fixedSize: WidgetStatePropertyAll(Size(30, 30)),
                ),
              ),
              GestureDetector(
                key: const ValueKey<String>('darkroom-mobile-trash'),
                onSecondaryTap: actions.onToggleRecycleMode,
                onLongPress: actions.onToggleRecycleMode,
                child: IconButton(
                  icon: Icon(
                    isTrashed ? Icons.delete : Icons.delete_outline,
                    size: 15,
                    color: isTrashed ? colors.error : palette.textFaint,
                  ),
                  onPressed: actions.onTrash,
                  tooltip: 'Trash',
                  padding: EdgeInsets.zero,
                  style: const ButtonStyle(
                    fixedSize: WidgetStatePropertyAll(Size(30, 30)),
                  ),
                ),
              ),
              const Spacer(),
              actions.menu,
            ],
          ),
          const SizedBox(height: 9),
          Expanded(
            child: RepaintBoundary(
              child: ListenableBuilder(
                listenable: strip.revision,
                builder: (context, _) => ListView.builder(
                  key: const ValueKey<String>('darkroom-mobile-tiles'),
                  scrollDirection: Axis.horizontal,
                  itemCount: strip.items.length,
                  itemBuilder: (context, index) {
                final item = strip.items[index];
                final isSelected = item.id == strip.selectedId;
                final width = isSelected ? 78.0 : 66.0;
                final height = isSelected ? 52.0 : 44.0;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  // A horizontal ListView tightens its cross-axis (height)
                  // constraint to the viewport's full cross extent — so the
                  // tile's explicit height would silently be overridden to
                  // fill the strip instead of drawing at 44/52px. `Align`
                  // is what lets a child size itself BELOW a tight incoming
                  // constraint (it centers its child at the child's own
                  // requested size rather than forcing the child to fill).
                  child: Align(
                    alignment: Alignment.center,
                    child: GestureDetector(
                      key: ValueKey<String>(
                        'darkroom-mobile-tile-tap-${item.id}',
                      ),
                      onTap: () => strip.onSelect(item.id),
                      child: Container(
                        key: ValueKey<String>(
                          'darkroom-mobile-tile-${item.id}',
                        ),
                        width: width,
                        height: height,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(3),
                          border: isSelected
                              ? Border.all(color: colors.primary, width: 1)
                              : null,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ColorFiltered(
                              colorFilter: isSelected
                                  ? const ColorFilter.mode(
                                      Colors.transparent,
                                      BlendMode.multiply,
                                    )
                                  : ColorFilter.matrix(_desaturateDim),
                              child: PhotoThumbnail(
                                payload: strip.payloadFor(item.id),
                                width: 200,
                                height: 200 / (3 / 2),
                                borderRadius: 0,
                              ),
                            ),
                            if (item.status != PhotoStatus.unmarked)
                              Positioned(
                                right: 3,
                                top: 3,
                                child: Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: item.status == PhotoStatus.starred
                                        ? palette.star
                                        : colors.error,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// A saturate(.68) brightness(.78) approximation for the unselected tiles
// (mockup `.th{filter:saturate(.68) brightness(.78)}`), as a 4x5 color matrix.
const List<double> _desaturateDim = <double>[
  0.62,
  0.24,
  0.10,
  0,
  0,
  0.17,
  0.68,
  0.10,
  0,
  0,
  0.17,
  0.24,
  0.55,
  0,
  0,
  0,
  0,
  0,
  1,
  0,
];
