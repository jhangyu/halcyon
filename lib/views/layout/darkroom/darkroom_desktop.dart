import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/photo_item.dart';
import '../common/exif_caption.dart';
import '../common/photo_viewport.dart';
import '../main_surface.dart';
import 'darkroom_column.dart';
import 'darkroom_palette.dart';

/// How long after the last drag delta the decode target is allowed to move
/// again. Mirrors `kGalleryWidthBadgeDelay` (`gallery_desktop.dart:38`).
const Duration kDarkroomDragStallDelay = Duration(milliseconds: 400);

/// The desktop arrangement of the `darkroom` theme (round 2, task #13).
///
/// USER RULING R-2 (2026-09-03, `docs/logs/2026-09-03/theme-parity-contract.md`)
/// SUPERSEDES the mockup's R8 float-over model: the picture column and the
/// photo each own their width and PARTITION the window. Widening the column
/// shrinks the photo; the two never overlap at any width in the drag range.
/// Do not restore the old constant 90px inset from the mockup NOTES.
///
/// Because the viewport now reflows on every drag frame, its tier-1 decode
/// target would change every frame too. The viewport is therefore wrapped in
/// [DecodeSizeFreeze] carrying [_DarkroomDesktopSurfaceState._dragActive]:
/// layout reflows, but [PhotoViewport] keeps reporting and decoding at the last
/// settled size until the drag stalls, so the `ImageProvider` cache key is
/// identical for the whole gesture (AD-011). Same mechanism, same reason, as
/// `GalleryDesktopSurface` (`gallery_desktop.dart:70-85`).
class DarkroomDesktopSurface extends StatefulWidget {
  const DarkroomDesktopSurface({super.key, required this.surface});

  final MainSurface surface;

  @override
  State<DarkroomDesktopSurface> createState() =>
      _DarkroomDesktopSurfaceState();
}

class _DarkroomDesktopSurfaceState extends State<DarkroomDesktopSurface> {
  // Accumulate RAW (pointer deltas arrive fractional) and round only on read —
  // rounding the accumulator quantises each delta and the column either never
  // moves or moves at double speed (measured, `gallery_desktop.dart:100-106`).
  double _rawColumnWidth = kDarkroomColumnMinWidth;
  double get _columnWidth => _rawColumnWidth.roundToDouble();

  /// True from the first pointer delta until [kDarkroomDragStallDelay] after
  /// the last one.
  bool _dragActive = false;
  Timer? _dragStallTimer;

  @override
  void dispose() {
    _dragStallTimer?.cancel();
    super.dispose();
  }

  void _onWidthDelta(double dx) {
    _dragStallTimer?.cancel();
    setState(() {
      _rawColumnWidth = clampDarkroomColumnWidth(_rawColumnWidth + dx);
      _dragActive = true;
    });
    _dragStallTimer = Timer(kDarkroomDragStallDelay, () {
      if (mounted) setState(() => _dragActive = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final surface = widget.surface;
    final palette = DarkroomPalette.of(context);
    // R-2: the photo's left edge IS the column's right edge, at every width.
    final viewportLeft = _columnWidth;

    return Stack(
      children: [
        Positioned(
          left: viewportLeft,
          top: 0,
          right: 0,
          bottom: 0,
          child: DecodeSizeFreeze(
            frozen: _dragActive,
            child: surface.viewport,
          ),
        ),
        // R4 EXIF caption, floating over the photo — desktop: bottom-left.
        // TWO-OWNER REGION (finding F6): the CHILD of this Positioned is
        // "the caption call as written by plan-info-display Task 3"
        // (ExifCaption with variant: ExifCaptionVariant.joined, titleStyle,
        // detailStyle, detailGap). This task changes ONLY the `left:` inset so
        // the caption tracks _columnWidth. If the info plan has already landed,
        // paste its child verbatim here; the block below is today's on-disk
        // child, shown only so this step is runnable before that merge.
        Positioned(
          left: viewportLeft + 20,
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
        // The info plan's counter Positioned(right: 24, bottom: 20) is added
        // HERE by plan-info-display Task 3. Do not add, move or key it.
        // Transient status toast, floats over the photo.
        Positioned(
          left: viewportLeft + 16,
          top: 20,
          child: surface.statusOverlay,
        ),
        // The wordless picture column. It owns [0, _columnWidth]; the photo
        // owns the rest. Nothing is covered.
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
        // Star/trash verdict cluster — floating over the photo, right-anchored,
        // so it is unaffected by the column width.
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
