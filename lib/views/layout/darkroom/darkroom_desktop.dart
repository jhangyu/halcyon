import 'package:flutter/material.dart';

import '../../../models/photo_item.dart';
import '../common/exif_caption.dart';
import '../main_surface.dart';
import 'darkroom_column.dart';
import 'darkroom_palette.dart';

/// The desktop arrangement of the `darkroom` theme (round 2, task #13).
///
/// Unlike `gallery`, the picture column FLOATS OVER the photo rather than
/// pushing it (NOTES.md "R8 model" — "At 90px the column sits BESIDE the
/// photo at zero image cost. Above 90px it FLOATS OVER the photo rather than
/// pushing it."). The photo is therefore pinned at a CONSTANT 90px inset for
/// every column width in the drag range — the viewport's decode target never
/// changes while dragging, so no `DecodeSizeFreeze` is needed here (that
/// mechanism exists only because `gallery` reflows the viewport itself).
class DarkroomDesktopSurface extends StatefulWidget {
  const DarkroomDesktopSurface({super.key, required this.surface});

  final MainSurface surface;

  @override
  State<DarkroomDesktopSurface> createState() =>
      _DarkroomDesktopSurfaceState();
}

class _DarkroomDesktopSurfaceState extends State<DarkroomDesktopSurface> {
  double _rawColumnWidth = kDarkroomColumnMinWidth;
  double get _columnWidth => _rawColumnWidth.roundToDouble();

  void _onWidthDelta(double dx) {
    setState(() {
      _rawColumnWidth = clampDarkroomColumnWidth(_rawColumnWidth + dx);
    });
  }

  @override
  Widget build(BuildContext context) {
    final surface = widget.surface;
    final palette = DarkroomPalette.of(context);

    return Stack(
      children: [
        // The photo, pinned at the CONSTANT free-band inset (the column's
        // resting/minimum width) — never the live dragged width. This is
        // what keeps the photo 1350x900 at every column width, per NOTES.md.
        Positioned(
          left: kDarkroomColumnMinWidth,
          top: 0,
          right: 0,
          bottom: 0,
          child: surface.viewport,
        ),
        // R4 EXIF caption, floating over the photo — desktop: bottom-left,
        // type only, no panel (NOTES.md "R4 — EXIF caption").
        Positioned(
          left: kDarkroomColumnMinWidth + 20,
          bottom: 16,
          child: DefaultTextStyle(
            style: TextStyle(color: palette.photoInk),
            child: ExifCaption(
              fileName: surface.identity?.displayName,
              exif: surface.identity?.exif,
              alignment: CrossAxisAlignment.start,
            ),
          ),
        ),
        // Transient status toast, floats over the photo.
        Positioned(
          left: kDarkroomColumnMinWidth + 16,
          top: 20,
          child: surface.statusOverlay,
        ),
        // The wordless picture column. Its own Positioned width grows over
        // the photo (floats, never pushes) while the viewport inset above
        // stays pinned at the resting width.
        Positioned(
          key: const ValueKey<String>('darkroom.column.slot'),
          left: 0,
          top: 0,
          bottom: 0,
          width: _columnWidth,
          child: DarkroomColumn(
            surface: surface,
            width: _columnWidth,
            onWidthDelta: _onWidthDelta,
          ),
        ),
        // Star/trash marks + Open Folder + overflow menu — floating cluster
        // over the photo, bottom-right, so it never depends on column width.
        Positioned(
          right: 20,
          bottom: 16 + 40,
          child: _buildActionsCluster(context, surface, palette),
        ),
      ],
    );
  }

  Widget _buildActionsCluster(
    BuildContext context,
    MainSurface surface,
    DarkroomPalette palette,
  ) {
    final actions = surface.actions;
    final status = surface.identity?.status;
    final isStarred = status == PhotoStatus.starred;
    final isTrashed = status == PhotoStatus.trashed;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _clusterButton(
            context,
            icon: isStarred ? Icons.star : Icons.star_border,
            iconColor: isStarred ? palette.star : null,
            tooltip: 'Star (S)',
            onPressed: actions.onStar,
          ),
          GestureDetector(
            key: const ValueKey<String>('darkroom-trash'),
            onSecondaryTap: actions.onToggleRecycleMode,
            child: _clusterButton(
              context,
              icon: actions.recycleMode
                  ? (isTrashed
                        ? Icons.restore_from_trash
                        : Icons.restore_from_trash_outlined)
                  : (isTrashed ? Icons.delete : Icons.delete_outline),
              iconColor: isTrashed ? Colors.red : null,
              tooltip: actions.recycleMode
                  ? 'Recycle (X) — right-click or R: switch to direct delete'
                  : 'Trash (X) — right-click or R: switch to recycle mode',
              onPressed: actions.onTrash,
            ),
          ),
          _clusterButton(
            context,
            icon: Icons.folder_open,
            tooltip: 'Open Folder',
            onPressed: actions.onOpenFolder,
          ),
          actions.menu,
        ],
      ),
    );
  }

  Widget _clusterButton(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    Color? iconColor,
  }) {
    final palette = DarkroomPalette.of(context);
    return Tooltip(
      message: tooltip,
      child: IconButton(
        icon: Icon(icon, size: 17, color: iconColor ?? palette.photoInkDim),
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        style: ButtonStyle(
          fixedSize: const WidgetStatePropertyAll(Size(34, 34)),
        ),
      ),
    );
  }
}
