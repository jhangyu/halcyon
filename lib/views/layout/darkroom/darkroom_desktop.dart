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

/// Key for the starred/trashed counter `Positioned(right: 24, bottom: 20)`
/// (finding F6 of `docs/logs/2026-09-03/plan-darkroom.md`). Declared here,
/// ahead of the info-display plan's Task 3, only so TC-883 can reference it
/// without a compile error; the info plan owns the actual counter widget and
/// must reuse this constant rather than redeclare it.
const ValueKey<String> kDarkroomCounterKey = ValueKey<String>(
  'darkroom.counter',
);

/// `.verdict{right:24px;top:24px}` — mockup `c2-desktop-dark.html:226-230`.
const double kDarkroomVerdictInset = 24.0;

/// `.vkey` — the keyboard hint drawn beside the marks (markup line 465).
const String kDarkroomVerdictKeyHint = 'S · X';

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
        Positioned(
          left: viewportLeft + 20,
          bottom: 16,
          child: DefaultTextStyle(
            style: TextStyle(color: palette.photoInk),
            child: ExifCaption(
              fileName: surface.identity?.displayName,
              exif: surface.identity?.exif,
              alignment: CrossAxisAlignment.start,
              variant: ExifCaptionVariant.joined,
              // Mockup `.caption .fn`: 13px, letter-spacing .005em.
              titleStyle: TextStyle(
                fontSize: 13,
                letterSpacing: 0.005 * 13,
                color: palette.photoInk,
              ),
              // Mockup `.exifcap`: 11px, letter-spacing .01em, --photo-ink-dim.
              detailStyle: TextStyle(
                fontSize: 11,
                letterSpacing: 0.01 * 11,
                color: palette.photoInkDim,
              ),
              detailGap: 4, // mockup padding-top:4px
            ),
          ),
        ),
        // Mockup `.counter`: right:24 bottom:20, progress over the tallies.
        Positioned(
          right: 24,
          bottom: 20,
          child: _buildCounter(surface, palette),
        ),
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
          right: kDarkroomVerdictInset,
          top: kDarkroomVerdictInset,
          child: _buildActionsCluster(context, surface, palette),
        ),
      ],
    );
  }

  /// Mockup `.counter` (`c2-desktop-dark.html:218-224`): `<b>37</b> / 412` at
  /// 13px over `61 starred · 18 marked` at 11px, right-aligned, both carrying
  /// the mockup's `text-shadow` so type stays legible on a bright photo.
  Widget _buildCounter(MainSurface surface, DarkroomPalette palette) {
    final identity = surface.identity;
    if (identity == null) return const SizedBox.shrink();
    const shadows = <Shadow>[
      Shadow(color: Color(0xCC000000), blurRadius: 4, offset: Offset(0, 1)),
    ];
    return Column(
      key: kDarkroomCounterKey,
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '${identity.indexInFolder}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              TextSpan(text: ' / ${identity.folderCount}'),
            ],
          ),
          style: TextStyle(
            fontSize: 13,
            letterSpacing: 0.04 * 13,
            color: palette.photoInk,
            shadows: shadows,
          ),
        ),
        const SizedBox(height: 3), // mockup padding-top:3px
        Text(
          '${identity.starredCount} starred · ${identity.trashedCount} marked',
          style: TextStyle(
            fontSize: 11,
            color: palette.photoInkDim,
            shadows: shadows,
          ),
        ),
      ],
    );
  }

  Widget _buildActionsCluster(
    BuildContext context,
    MainSurface surface,
    DarkroomPalette palette,
  ) {
    final colors = Theme.of(context).colorScheme;
    final actions = surface.actions;
    final status = surface.identity?.status;
    final isStarred = status == PhotoStatus.starred;
    final isTrashed = status == PhotoStatus.trashed;
    return DecoratedBox(
      key: const ValueKey<String>('darkroom-verdict'),
      decoration: BoxDecoration(
        // --veil
        color: colors.surface.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: colors.outlineVariant), // --line
      ),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: [
            _clusterButton(
              context,
              icon: isStarred ? Icons.star : Icons.star_border,
              iconColor: isStarred ? palette.star : null,
              // `.vb.starred{background:rgba(233,184,76,.14)}`
              background: isStarred
                  ? palette.star.withValues(alpha: 0.14)
                  : null,
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
            // `.vsep{width:1px;height:18px;margin:0 3px}`
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: SizedBox(
                width: 1,
                height: 18,
                child: ColoredBox(color: colors.outlineVariant),
              ),
            ),
            // `.vkey` — 9.5px, .08em tracking, --faint, padding 0 6px 0 2px.
            Padding(
              padding: const EdgeInsets.only(left: 2, right: 6),
              child: Text(
                kDarkroomVerdictKeyHint,
                key: const ValueKey<String>('darkroom-verdict-key-hint'),
                style: TextStyle(
                  fontSize: 9.5,
                  letterSpacing: 0.08 * 9.5,
                  color: palette.textFaint,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _clusterButton(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    Color? iconColor,
    Color? background,
  }) {
    final colors = Theme.of(context).colorScheme;
    // `.vb{width:34px;height:34px;border-radius:5px;color:var(--dim)}`
    return Tooltip(
      message: tooltip,
      child: IconButton(
        icon: Icon(icon, size: 17, color: iconColor ?? colors.onSurfaceVariant),
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        style: ButtonStyle(
          fixedSize: const WidgetStatePropertyAll<Size>(Size(34, 34)),
          backgroundColor: background == null
              ? null
              : WidgetStatePropertyAll<Color>(background),
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
          ),
        ),
      ),
    );
  }
}
