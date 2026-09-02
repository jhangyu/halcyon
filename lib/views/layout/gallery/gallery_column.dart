import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../models/photo_item.dart';
import '../common/photo_thumbnail.dart';
import '../gallery/gallery_palette.dart';
import '../main_surface.dart';

// USER RULING 2026-09-02, superseding the constant-chip / two-column rule:
// the chip SCALES with the gutter across the whole 90-200 range, the strip is
// ALWAYS one column, and the chips are centred. Extra width now buys a bigger
// picture rather than more of them.
//
// What the old rule bought, recorded so the cost is visible rather than
// rediscovered: a constant chip meant the strip could only ever show MORE
// frames as it widened, and it kept the chip inside what the thumbnail source
// supplies (200 physical px on the long edge). Scaling breaks the second
// property — see [kChipDecodeWidth].
const double kChipWidth = 74; // the resting chip, at the 90px gutter
const double kChipAspect = 3 / 2; // 3:2, matching the photos
const double kChipHeight = kChipWidth / kChipAspect; // 49.33 at rest

/// The size the chip's BITMAP is requested at, regardless of how large the
/// chip is drawn.
///
/// USER CLARIFICATION 2026-09-02: sidebar thumbnails are ALREADY produced at a
/// 200px long edge (`ImageRequestPurpose.sidebarThumbnail`), and 200 is also
/// the gutter's maximum width — so a chip can never be drawn larger than the
/// bitmap it already has. This is therefore a pure layout change: the existing
/// decode is kept and the widget scales it DOWN at narrower widths. No
/// re-decode, and no freeze mechanism (unlike the tier-1 viewport, which needs
/// [DecodeSizeFreeze] because its target genuinely changes).
///
/// Requesting at this constant rather than at the live chip width is what
/// makes that true: a `ResizeImage` key derives from the requested size, so a
/// chip that scaled its REQUEST would mint a new key — and a new decode — on
/// every drag frame. One constant request, one bitmap, scaled by the layout.
const double kChipDecodeWidth = 200;

/// The height at which the gutter's fixed sections (cap + identity plate +
/// the vertical marks stack) exactly fill the column, leaving the filmstrip at
/// zero. Measured, not guessed: at 300px the `Column` overflowed by 5px and at
/// 340px it did not. Below this the column scrolls rather than overflowing.
const double kGalleryColumnMinContentHeight = 320;

/// The width of the resize handle's hit region at the gutter's right edge.
/// The painted grip is still 1px (see `_buildGrip`); this is the pointer
/// target only. 5px was too narrow to reliably grab — pointer-downs a pixel or
/// two off landed in the photo `InteractiveViewer` and became image pans.
const double kGalleryHandleHitWidth = 12;

/// How far the handle's hit region extends PAST the gutter's right edge, over
/// the photo viewport, as a dead zone. Owned by the desktop surface (the
/// gutter's own `Stack` clips, so it cannot paint or hit-test outside itself).
const double kGalleryHandleOverhang = 4;

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

  /// The chip fills the strip's content width, so it grows continuously with
  /// the gutter and is centred by construction (there is exactly one column).
  double get _chipWidth =>
      GalleryColumn.debugChipWidthForWidth?.call(widget.width) ??
      math.max(1, widget.width - 2 * _pad);

  double get _chipHeight => _chipWidth / kChipAspect;

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
  /// The filmstrip's horizontal padding — CONSTANT, deliberately.
  ///
  /// It used to step 8 -> 12 as soon as the gutter passed 90 (the mockup's
  /// `.filmstrip` vs `.dragged .filmstrip`). Harmless while the chip was a
  /// fixed 74, but under the 2026-09-02 scaling rule the chip is
  /// `width - 2 * pad`, so that step made the FIRST pixel of every drag shrink
  /// the picture (w=90 -> chip 74; w=91 -> chip 67, not recovering until 98).
  /// "Drag wider, picture gets smaller" is exactly what the scaling rule
  /// exists to prevent, so the padding is now 8 at every width: the resting
  /// chip is unchanged at 74 and the ceiling rises to 184 at a 200px gutter.
  ///
  /// `_gap` keeps its step: it is vertical spacing BETWEEN rows and never
  /// enters the chip's width.
  static const double _pad = 8.0; // .filmstrip
  double get _gap => widget.width <= 90 ? 6.0 : 8.0; // vs .dragged .filmstrip
  double get _rowExtent => _chipHeight + _gap; // per ROW
  /// Always one. The strip never becomes a grid at any width (user ruling
  /// 2026-09-02); kept as a named constant so the range/scroll arithmetic
  /// below still reads as "rows of columns" rather than silently assuming 1.
  int get _columns => 1;
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
          child: LayoutBuilder(
            builder: (context, constraints) {
              final content = Column(
                children: [
                  _buildCap(context),
                  Expanded(child: _buildFilmstrip(context)),
                  _buildIdentityPlate(context),
                  _buildMarks(context),
                ],
              );
              // Only the filmstrip is flexible; the cap, the identity plate
              // and the marks are fixed and together need about
              // [kGalleryColumnMinContentHeight]. Below that the Column would
              // overflow and push the marks off the bottom edge — rendered
              // outside the parent's bounds, so invisible AND unhittable.
              // Under that height the whole gutter becomes a scroll view at
              // its minimum comfortable height instead, which keeps every
              // mark reachable at any window height.
              if (constraints.maxHeight >= kGalleryColumnMinContentHeight) {
                return content;
              }
              return SingleChildScrollView(
                child: SizedBox(
                  height: kGalleryColumnMinContentHeight,
                  child: content,
                ),
              );
            },
          ),
        ),
        // Drag handle: a [kGalleryHandleHitWidth] full-height hit area at the
        // right edge (mockup `.handle`), reporting raw horizontal deltas
        // upward. `MouseRegion(cursor: resizeColumn)` + `onPanUpdate` is the
        // exact mechanism MainScreen used for the old sidebar width drag.
        // The hit region grew from 5px to 12px; the painted grip did not move
        // (it is right-aligned below, at the same [w-3, w-2] it occupied when
        // it was centred in a 5px band).
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: kGalleryHandleHitWidth,
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
  // (`.handle`, mockup:188-193). The handle is wider than the grip so the hit
  // area and the visual are separate concerns — which is the whole point of
  // widening the hit area without touching this.
  //
  // Right-aligned with a 2px inset rather than centred, so that widening the
  // hit band from 5px to [kGalleryHandleHitWidth] leaves the painted grip at
  // exactly the columns it occupied before ([width-3, width-2]).
  Widget _buildGrip(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(right: 2),
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeColumn,
          child: Container(
            key: const ValueKey<String>('gallery-grip'),
            width: 1,
            height: 26,
            color: colors.outline,
          ),
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
                  // One column, centred (user ruling 2026-09-02).
                  mainAxisAlignment: MainAxisAlignment.center,
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
      height: _chipHeight,
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
          // One constant bitmap request ([kChipDecodeWidth]) scaled to fill
          // the chip: dragging the gutter re-lays-out but never re-decodes,
          // and since the chip can never exceed 200 the picture is only ever
          // scaled DOWN. `cover` keeps the 3:2 framing exact.
          Positioned.fill(
            child: FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: kChipDecodeWidth,
                height: kChipDecodeWidth / kChipAspect,
                child: PhotoThumbnail(
                  payload: strip.payloadFor(item.id),
                  width: kChipDecodeWidth,
                  height: kChipDecodeWidth / kChipAspect,
                  borderRadius: 0,
                ),
              ),
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

  // --- Identity plate: 1px top border and "$index / $total", nothing else.
  //
  // REVISION 2026-09-02 (mockup `.gutter .plate`): the filename has LEFT this
  // plate. It was 10px inside a 74px-wide well and truncated on almost every
  // real name; it is now the title line of the wall label at the photo's
  // bottom-right (see ExifCaption.fileName). What remains is the index
  // counter, the one piece of state that has to survive at 40px of strip
  // width, and it comes up from 9px/faint to 10px/mid ink now that it is
  // alone. ---
  Widget _buildIdentityPlate(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final identity = widget.surface.identity;
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
      padding: const EdgeInsets.only(top: 9, right: 8, bottom: 7, left: 8),
      child: Text(
        showsIndex ? '$index / $total' : '',
        textAlign: TextAlign.center,
        style: TextStyle(
          // 10px / 0.12em at rest, 11px / 0.14em dragged (`.dragged .plate
          // .count`); tabular figures so the counter does not jitter as the
          // digits change.
          fontSize: _dragged ? 11 : 10,
          letterSpacing: _dragged ? 0.14 * 11 : 0.12 * 10,
          fontFeatures: const [FontFeature.tabularFigures()],
          color: colors.onSurfaceVariant,
        ),
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
      // A 5-child row at 34px each plus 4x2px gaps measures ~187px — wider
      // than the gutter everywhere below 200. The previous formulation put
      // that Row in a horizontal SingleChildScrollView, which CLIPPED the
      // overflowing children: at width 100-120 both `Open Folder` and the
      // menu were invisible and unhittable, at 140-179 the menu was. That is
      // the "buttons disappear when I resize the sidebar" bug — it is a pure
      // function of the dragged width, which is why it read as intermittent.
      //
      // `Wrap` keeps the horizontal reading order of `.dragged .marks
      // {flex-direction:row}` but flows the remainder onto a second line
      // instead of off the edge, so every mark stays visible and clickable at
      // every width in the 90-200 range. It must NOT go back to a Row (in a
      // scroll view or otherwise): a Row cannot represent "does not fit".
      return Container(
        padding: const EdgeInsets.only(top: 6, bottom: 12),
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 2,
          runSpacing: 2,
          children: children,
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