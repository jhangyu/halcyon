import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../models/photo_item.dart';
import '../common/photo_thumbnail.dart';
import '../gallery/gallery_palette.dart';
import '../main_surface.dart';

// Chip size is CONSTANT across the whole 90-200 range. Extra width buys
// COLUMNS, never a bigger chip: bigger is capped by what the thumbnail
// source can supply (200 physical px on the long edge), so growing the chip
// can only ever show FEWER frames. Width that does not complete a column is
// deliberately left unused. Contract: c1-desktop-light.html .w90/.w140/.w200.
const double kChipWidth = 74;
const double kChipHeight = 49; // 3:2, matching the photos

/// The `gallery` theme's filmstrip gutter (T7 of the gallery layout plan).
///
/// Presentational only: every behaviour arrives as a [MainSurface] with its
/// behaviours already resolved (the layout-seam AD contract — this widget
/// never reads the app-state singleton; enforced structurally).
///
/// Contents, top to bottom (mockup `.gutter` block): the `FOLDER` cap, the
/// filmstrip, the identity plate, and the marks + entry-points row.
///
/// ## The one hard structural requirement (plan T7)
///
/// The filmstrip is a `ListView.builder` with a [ScrollController], whose
/// visible-range reporter is driven by the itemBuilder and computes the range
/// from viewport geometry (`offset / itemExtent`), NOT from the built indices
/// — so every path that resets the thumbnail cache re-reports without its own
/// call site (the AD-014 / G-001 regression that a `Column` in a
/// `SingleChildScrollView` would silently reintroduce). Selected-visible
/// autoscroll is the same 200ms `Curves.easeInOut` scroll from sidebar_view.
class GalleryColumn extends StatefulWidget {
  const GalleryColumn({
    super.key,
    required this.surface,
    required this.width,
    required this.onWidthDelta,
  });

  final MainSurface surface;
  final double width;

  /// A horizontal drag reports the raw pointer delta; the parent owns the
  /// clamping arithmetic and the width state (T6).
  final void Function(double dx) onWidthDelta;

  // Test-only mutation hook (TC-508c, AC6). When null (the production
  // default) the chip width is the constant `kChipWidth` at every dragged
  // width, byte-equivalent to before this hook existed. Tests may set this
  // to a width-scaled function to prove the "never decreases" sweep in
  // TC-508b actually detects the regression it claims to guard against; it
  // must always be cleared (`addTearDown`) after use.
  @visibleForTesting
  static double Function(double width)? debugChipWidthForWidth;

  @override
  State<GalleryColumn> createState() => _GalleryColumnState();
}

class _GalleryColumnState extends State<GalleryColumn> {
  final ScrollController _scrollController = ScrollController();
  String? _lastSelectedId;

  double get _chipWidth =>
      GalleryColumn.debugChipWidthForWidth?.call(widget.width) ?? kChipWidth;

  // Visible-range reporting, ported from sidebar_view.dart:76-108.
  bool _sweepScheduled = false;
  int _fallbackFirstIndex = -1;
  int _fallbackLastIndex = -1;

  // Width-derived geometry. Ruled at the source (plan §T7): the ruling's
  // `floor((strip - 24 + 8) / 82)` form assumes the dragged 12px padding at
  // every width; the resting strip uses 8, and at the rest width that form
  // returns 0 columns — a zero column count is a division-by-zero or an empty
  // strip rather than a cosmetic error. The form below uses width-dependent
  // padding and a `max(1, ...)` floor, and reproduces every drawn point:
  // 90->1, 140->1, 179->1, 180->2, 200->2.
  double get _pad => widget.width <= 90 ? 8.0 : 12.0; // .filmstrip
  double get _gap => widget.width <= 90 ? 6.0 : 8.0; // vs .dragged .filmstrip
  double get _rowExtent => kChipHeight + _gap; // per ROW
  int get _columns =>
      math.max(1, (widget.width - 2 * _pad + _gap) ~/ (_chipWidth + _gap));
  bool get _dragged => widget.width > 90;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureSelectedVisible();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 200ms `easeInOut` autoscroll keeping the selected chip's row visible,
  /// ported from sidebar_view.dart:110-137. Row positions are computed from
  /// the uniform [_rowExtent].
  void _ensureSelectedVisible() {
    final strip = widget.surface.strip;
    final selectedId = strip.selectedId;
    final items = strip.items;
    if (selectedId == null || items.isEmpty) return;
    if (!_scrollController.hasClients) return;

    final idx = items.indexWhere((i) => i.id == selectedId);
    if (idx == -1) return;

    final row = idx ~/ _columns;
    final itemTop = row * _rowExtent;
    final itemBottom = itemTop + _rowExtent;
    final viewportOffset = _scrollController.offset;
    final viewportHeight = _scrollController.position.viewportDimension;

    if (itemTop < viewportOffset) {
      // Item is above the viewport, scroll up.
      _scrollController.animateTo(
        itemTop,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
      );
    } else if (itemBottom > viewportOffset + viewportHeight) {
      // Item is below the viewport, scroll down.
      _scrollController.animateTo(
        itemBottom - viewportHeight,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
      );
    }
  }

  void _noteBuiltIndex(int index) {
    // Only used before the list has a scroll position (first frame).
    if (_fallbackFirstIndex == -1 || index < _fallbackFirstIndex) {
      _fallbackFirstIndex = index;
    }
    if (index > _fallbackLastIndex) _fallbackLastIndex = index;
    if (_sweepScheduled) return;
    _sweepScheduled = true;
    // Requesting during build would notifyListeners mid-build; defer to the
    // end of the frame, where layout is also settled.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sweepScheduled = false;
      final first = _fallbackFirstIndex;
      final last = _fallbackLastIndex;
      _fallbackFirstIndex = -1;
      _fallbackLastIndex = -1;
      if (!mounted) return;
      final strip = widget.surface.strip;
      final onVisibleRange = strip.onVisibleRange;
      if (!_scrollController.hasClients) {
        if (first != -1) onVisibleRange(first, last);
        return;
      }
      // Range report, from viewport geometry exactly as sidebar_view.dart:100-106.
      final offset = _scrollController.offset;
      final viewportHeight = _scrollController.position.viewportDimension;
      final columns = _columns;
      final extent = _rowExtent;
      final firstRow = (offset / extent).floor();
      final lastRow = ((offset + viewportHeight) / extent).ceil();
      onVisibleRange(
        firstRow * columns,
        math.min(lastRow * columns + (columns - 1), strip.items.length - 1),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final strip = widget.surface.strip;
    if (strip.selectedId != _lastSelectedId) {
      _lastSelectedId = strip.selectedId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureSelectedVisible();
      });
    }

    return Stack(
      children: [
        Material(
          color: Theme.of(context).colorScheme.surface,
          child: Column(
            children: [
              _buildCap(context),
              Expanded(child: _buildFilmstrip(context)),
              _buildIdentityPlate(context),
              _buildMarks(context),
            ],
          ),
        ),
        // Drag handle: a 5px full-height hit area at the right edge
        // (mockup `.handle`), reporting raw horizontal deltas upward.
        // `MouseRegion(cursor: resizeColumn)` + `onPanUpdate` is the exact
        // mechanism MainScreen used for the old sidebar width drag.
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: 5,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanUpdate: (details) =>
                  widget.onWidthDelta(details.delta.dx),
              child: _buildGrip(context),
            ),
          ),
        ),
      ],
    );
  }

  // The 1x26 grip centred vertically, 1x44 in `primary` on hover
  // (`.handle`, mockup:188-193). The 5px handle is wider than the grip so
  // the hit area and the visual are separate concerns.
  Widget _buildGrip(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: Container(
          key: const ValueKey<String>('gallery-grip'),
          width: 1,
          height: 26,
          color: colors.outline,
        ),
      ),
    );
  }

  // --- Top: 'FOLDER' cap. 9px / 0.14em tracking at rest, 12px / 0.18em
  // while dragged (`.gutter.dragged .cap`). ---
  Widget _buildCap(BuildContext context) {
    return Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.only(top: 12, right: 10, bottom: 8, left: 10),
      child: Text(
        'FOLDER',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: _dragged ? 12 : 9,
          letterSpacing: _dragged ? 0.18 * 12 : 0.14 * 9,
          fontWeight: FontWeight.w500,
          color: GalleryPalette.of(context).textFaint,
        ),
      ),
    );
  }

  // --- Middle: the filmstrip (the one hard structural requirement). ---
  Widget _buildFilmstrip(BuildContext context) {
    final strip = widget.surface.strip;
    final items = strip.items;
    final rowCount = (items.length + _columns - 1) ~/ _columns;

    return Container(
      color: Theme.of(context).colorScheme.surfaceContainer,
      padding: EdgeInsets.symmetric(horizontal: _pad),
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              // Makes _rowExtent a fact rather than an approximation: both the
              // visible-range math above and _ensureSelectedVisible compute row
              // positions from it.
              itemExtent: _rowExtent,
              itemCount: rowCount,
              itemBuilder: (context, row) {
                _noteBuiltIndex(row);
                final first = row * _columns;
                final last = math.min(
                  first + _columns - 1,
                  items.length - 1,
                );
                return Row(
                  key: ValueKey<String>('gallery-row-$row'),
                  children: [
                    for (var i = first; i <= last; i++) ...[
                      if (i > first) SizedBox(width: _gap),
                      _buildChip(context, items[i], strip),
                    ],
                  ],
                );
              },
            ),
          ),
          // Bottom spacer so the last row never sits directly on the plate.
          SizedBox(height: _gap),
        ],
      ),
    );
  }

  Widget _buildChip(
    BuildContext context,
    PhotoItem item,
    PhotoStripModel strip,
  ) {
    final colors = Theme.of(context).colorScheme;
    final isSelected = item.id == strip.selectedId;
    return Container(
      key: ValueKey<String>('gallery-chip-${item.id}'),
      width: _chipWidth,
      height: kChipHeight,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(2),
        // Selected: 2px primary outline; unselected: 1px outlineVariant.
        border: Border.all(
          color: isSelected ? colors.primary : colors.outlineVariant,
          width: isSelected ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: PhotoThumbnail(
              payload: strip.payloadFor(item.id),
              width: _chipWidth,
              height: kChipHeight,
              borderRadius: 0,
            ),
          ),
          // Status dot 6x6 at left: 4, bottom: 4 (mockup `.dot`).
          if (item.status != PhotoStatus.unmarked)
            Positioned(
              left: 4,
              bottom: 4,
              child: _statusDot(context, item, colors),
            ),
        ],
      ),
    );
  }

  Widget _statusDot(
    BuildContext context,
    PhotoItem item,
    ColorScheme colors,
  ) {
    final color = switch (item.status) {
      PhotoStatus.starred => GalleryPalette.of(context).star,
      PhotoStatus.trashed => colors.error.withValues(alpha: 0.8),
      PhotoStatus.unmarked => colors.outlineVariant,
    };
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  // --- Identity plate: 1px top border, filename + "$index / $total". ---
  Widget _buildIdentityPlate(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final identity = widget.surface.identity;
    final name = identity?.displayName ?? '';
    final index = identity?.indexInFolder ?? 0;
    final total = identity?.folderCount ?? 0;
    final showsIndex = index != 0 || total != 0;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: colors.outlineVariant),
        ),
      ),
      padding: const EdgeInsets.only(top: 10, right: 8, bottom: 6, left: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: _dragged ? 12 : 10, // `.dragged .plate`
              color: colors.onSurface,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            showsIndex ? '$index / $total' : '',
            style: TextStyle(
              fontSize: _dragged ? 10 : 9,
              letterSpacing: 0.9,
              color: GalleryPalette.of(context).textFaint,
            ),
          ),
        ],
      ),
    );
  }

  // --- Marks + entry points. A Column at <=90px, a Row above it, 2px gaps,
  // five children in order: star, trash, separator, Open Folder, menu. ---
  Widget _buildMarks(BuildContext context) {
    final actions = widget.surface.actions;
    // Current-item status, per plan T7 lines 904-911: the star and trash
    // glyphs read the SAME `surface.identity?.status` the chip dot already
    // reads (gallery_column.dart's `_statusDot`) — null identity (no folder
    // loaded) idles both glyphs, matching photo_action_bar.dart's implicit
    // "no item" behavior (it is never built without a current item, but the
    // idle/outline glyph is the correct fallback here).
    final status = widget.surface.identity?.status;
    final isStarred = status == PhotoStatus.starred;
    final isTrashed = status == PhotoStatus.trashed;
    final children = <Widget>[
      _markButton(
        context: context,
        icon: isStarred ? Icons.star : Icons.star_border,
        iconColor: isStarred ? GalleryPalette.of(context).star : null,
        tooltip: 'Star (S)',
        onPressed: actions.onStar,
      ),
      // Right-click toggles recycle mode; left keeps its "mark this photo"
      // meaning (photo_action_bar.dart:59-69). The four-icon matrix and the
      // two tooltip strings are copied verbatim from
      // photo_action_bar.dart:26-30, 65-67 (plan T7 lines 909-911).
      GestureDetector(
        key: const ValueKey<String>('gallery-trash'),
        onSecondaryTap: actions.onToggleRecycleMode,
        child: _markButton(
          context: context,
          icon: actions.recycleMode
              ? (isTrashed
                    ? Icons.restore_from_trash
                    : Icons.restore_from_trash_outlined)
              : (isTrashed ? Icons.delete : Icons.delete_outline),
          iconColor: isTrashed ? Colors.red : null,
          // The two verbatim strings from photo_action_bar.dart:66-67 —
          // asserted byte-identical by TC-512.
          tooltip: actions.recycleMode
              ? 'Recycle (X) — right-click or R: switch to direct delete'
              : 'Trash (X) — right-click or R: switch to recycle mode',
          onPressed: actions.onTrash,
        ),
      ),
      _separator(context),
      _markButton(
        context: context,
        icon: Icons.folder_open,
        tooltip: 'Open Folder',
        onPressed: actions.onOpenFolder,
      ),
      actions.menu,
    ];

    if (_dragged) {
      // A 5-child row at 34px each plus 4x2px gaps is 178px — wider than the
      // gutter at 140/179. Keep the horizontal Row (`.dragged .marks
      // {flex-direction:row}`) but let it scroll horizontally instead of
      // overflowing off-screen into the photo.
      return Container(
        padding: const EdgeInsets.only(top: 6, bottom: 12),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: _withGaps(children),
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.only(top: 6, bottom: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: _withGaps(children),
      ),
    );
  }

  List<Widget> _withGaps(List<Widget> children) {
    return [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) const SizedBox(width: 2, height: 2),
        children[i],
      ],
    ];
  }

  Widget _separator(BuildContext context) {
    // 22x1 at <=90px, 1x20 above it (mockup `.marks .sep`).
    final dimensions = _dragged
        ? const Size(1, 20)
        : const Size(22, 1);
    return Container(
      width: dimensions.width,
      height: dimensions.height,
      color: Theme.of(context).colorScheme.outlineVariant,
    );
  }

  /// A 34x34 round-5 button with a 17px glyph: `onSurfaceVariant` idle,
  /// `onSurface` on hover over a `surfaceContainer` hover fill.
  Widget _markButton({
    required BuildContext context,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    Color? iconColor,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: IconButton(
        // `iconColor` (starred amber / trashed red, photo_action_bar.dart:
        // 51-52, 62) overrides the idle/hover foregroundColor below, exactly
        // as the old widget's explicit Icon `color:` parameter did.
        icon: Icon(icon, size: 17, color: iconColor),
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        style: ButtonStyle(
          fixedSize: const WidgetStatePropertyAll(Size(34, 34)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.hovered)
                ? colors.onSurface
                : colors.onSurfaceVariant,
          ),
          overlayColor: WidgetStatePropertyAll(colors.surfaceContainer),
        ),
      ),
    );
  }
}