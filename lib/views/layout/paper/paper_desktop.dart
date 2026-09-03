import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../models/photo_item.dart';
import '../common/anchored_scroll.dart';
import '../common/exif_caption.dart';
import '../common/photo_thumbnail.dart';
import 'paper_palette.dart';
import '../main_surface.dart';

/// Drag range for the `paper` gutter (R9): 40 floor, 90 default/rest, 200
/// ceiling — `docs/logs/2026-09-01/mockup/paper/NOTES.md` "The drag range is
/// 40-200, default 90".
const double kPaperColumnMinWidth = 40.0;
const double kPaperColumnRestWidth = 90.0;
const double kPaperColumnMaxWidth = 200.0;

/// The chip size at the 90px RESTING width. USER RULING R-1
/// (`docs/logs/2026-09-03/theme-parity-contract.md`) OVERRIDES the paper
/// mockup's "From 90 upward the chip is pinned at 74x49. It never grows with
/// the strip." (`docs/logs/2026-09-01/mockup/paper/NOTES.md:183-184`): 74 is
/// the chip size AT 90, not a ceiling. Above 90 the chip grows with the
/// column, the way `darkroom` already does. Do not "restore" the pin.
const double kPaperChipRestWidth = 74.0;
const double kPaperChipAspect = 74 / 49;

/// The chip size at the R9 floor (mockup frame 3: "chip scales down to
/// 31x21").
const double kPaperChipFloorWidth = 31.0;
const double kPaperChipFloorHeight = 21.0;

/// The width at which a second column appears (NOTES.md sweep table:
/// "Column count changes exactly once, at w=171").
const double kPaperTwoColumnWidth = 171.0;

/// Test key on the width-readout badge shown while a drag is in flight
/// (mockup `.widthbadge`).
const ValueKey<String> kPaperWidthBadgeKey = ValueKey<String>(
  'paper.width.badge',
);

/// Key on the gutter's `Positioned` slot, mirroring the gallery theme's
/// slot-stability fix (unkeyed `Positioned` siblings can be reconciled
/// against each other and silently destroy the live pan recognizer).
const ValueKey<String> kPaperColumnSlotKey = ValueKey<String>(
  'paper.column.slot',
);

/// The `.overcount` readout (progress + starred) drawn bottom-right over the
/// photo. Declared here so tests can locate it by key.
const ValueKey<String> kPaperOverCountKey = ValueKey<String>(
  'paper.overcount',
);

/// Mockup `text-shadow:0 1px 4px rgba(0,0,0,.5)` — carried by both the caption
/// and the over-count, which float directly on the photograph.
const List<Shadow> _overShadows = <Shadow>[
  Shadow(color: Color(0x80000000), blurRadius: 4, offset: Offset(0, 1)),
];

const Duration kPaperWidthBadgeDelay = Duration(milliseconds: 400);

/// Vertical gap between filmstrip rows, in both the in-gutter strip and the
/// floating overlay strip (mockup `.stripbody` / `.floatstrip`).
const double kPaperStripGap = 7.0;

/// Outer padding of the chip grid on all four sides at and above the resting
/// width. Chosen so the derived ONE-column cell width is exactly
/// [kPaperChipRestWidth] at [kPaperColumnRestWidth] (90 - 2*8 = 74) and
/// exactly [kPaperChipRestWidth] again on entering the two-column band
/// ((171 - 2*8 - 7) / 2 = 74): the scaling curve is therefore continuous at 90
/// and never shrinks a chip below its resting size when the second column
/// appears.
const double kPaperGridPadding = 8.0;

/// Rendered chip width at a given gutter width — a CONTINUOUS function of the
/// live drag width across the whole 40-200 range (R-1).
///
/// Three regimes, continuous at the 90 seam:
///  * two columns (>= [kPaperTwoColumnWidth]): the grid cell width,
///    `(w - 2*pad - gap) / 2`;
///  * one column at/above rest: the grid cell width, `w - 2*pad`;
///  * below rest: linear from [kPaperChipFloorWidth] at
///    [kPaperColumnMinWidth] to [kPaperChipRestWidth] at
///    [kPaperColumnRestWidth] (the two drawn mockup frames).
///
/// The single step down, at [kPaperTwoColumnWidth], is where the second column
/// appears — the same shape `darkroom` has at its own
/// `kDarkroomTwoColumnWidth` (see
/// `lib/views/layout/darkroom/darkroom_column.dart:52-58`, which derives the
/// same arithmetic for its grid; that file is deliberately NOT refactored into
/// a shared helper here, see docs/logs/2026-09-03/plan-paper.md Task 1).
double paperChipWidthFor(double width) {
  if (width >= kPaperTwoColumnWidth) {
    return (width - 2 * kPaperGridPadding - kPaperStripGap) / 2;
  }
  if (width >= kPaperColumnRestWidth) {
    return width - 2 * kPaperGridPadding;
  }
  final t = ((width - kPaperColumnMinWidth) /
          (kPaperColumnRestWidth - kPaperColumnMinWidth))
      .clamp(0.0, 1.0);
  return kPaperChipFloorWidth + t * (kPaperChipRestWidth - kPaperChipFloorWidth);
}

/// Rendered chip height. At and above rest it is derived from the width at the
/// resting aspect; below rest it interpolates to the drawn 21px floor, which
/// makes the aspect drift slightly (31/21 vs 74/49) — hence
/// [paperChipAspectFor] rather than one constant fed to the grid delegate.
double paperChipHeightFor(double width) {
  if (width >= kPaperColumnRestWidth) {
    return paperChipWidthFor(width) / kPaperChipAspect;
  }
  final t = ((width - kPaperColumnMinWidth) /
          (kPaperColumnRestWidth - kPaperColumnMinWidth))
      .clamp(0.0, 1.0);
  const restHeight = kPaperChipRestWidth / kPaperChipAspect;
  return kPaperChipFloorHeight + t * (restHeight - kPaperChipFloorHeight);
}

/// The `childAspectRatio` for the chip grid at a given gutter width.
double paperChipAspectFor(double width) =>
    paperChipWidthFor(width) / paperChipHeightFor(width);

/// The grid's `EdgeInsets.all` value, derived FROM the chip width so the
/// delegate's computed cell width is exactly [paperChipWidthFor]. Returns
/// exactly 8.0 for every width at or above [kPaperColumnRestWidth]; below it,
/// it narrows (4.5 at the 40px floor) so the interpolated floor chip still
/// fits its column.
double paperGridPaddingFor(double width) {
  final columns = paperColumnsFor(width);
  final content =
      columns * paperChipWidthFor(width) + kPaperStripGap * (columns - 1);
  return math.max(0.0, (width - content) / 2);
}

/// One grid ROW's pixel height including the spacing that follows it. Derived
/// from exactly the numbers the grid delegate is built with, so the anchoring
/// arithmetic in [_PaperColumnState.didUpdateWidget] cannot drift from the
/// layout it anchors.
double paperRowExtentFor(double width) =>
    paperChipHeightFor(width) + kPaperStripGap;

/// One column at or below [kPaperTwoColumnWidth], two above it — the strip
/// never grows past two (mockup NOTES.md sweep).
int paperColumnsFor(double width) => width >= kPaperTwoColumnWidth ? 2 : 1;

/// The desktop arrangement of the `paper` theme (round 2).
///
/// Layout invariant carried from the mockup (`NOTES.md` "Geometry — measured,
/// not asserted"): the photo is 1350x900 at x=90 at REST. Unlike `gallery`
/// (which pushes the photo as the gutter widens, per the 2026-09-02 reflow
/// ruling), `paper`'s own contract keeps the photo fixed and floats every
/// width above 90 as an overlay (R5a: "At 90 the strip lays out beside the
/// photo; above 90 it floats over it and never pushes it" — unlike gallery,
/// this ruling was NOT superseded for paper). The viewport's left inset is
/// therefore the constant resting gutter width, not the live drag width.
class PaperDesktopSurface extends StatefulWidget {
  const PaperDesktopSurface({super.key, required this.surface});

  final MainSurface surface;

  @override
  State<PaperDesktopSurface> createState() => _PaperDesktopSurfaceState();
}

class _PaperDesktopSurfaceState extends State<PaperDesktopSurface> {
  double _rawWidth = kPaperColumnRestWidth;
  double get _width => _rawWidth.roundToDouble();

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
      _rawWidth = (_rawWidth + dx)
          .clamp(kPaperColumnMinWidth, kPaperColumnMaxWidth)
          .toDouble();
      _dragActive = true;
    });
    _dragStallTimer = Timer(kPaperWidthBadgeDelay, () {
      if (mounted) setState(() => _dragActive = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final surface = widget.surface;
    final colors = Theme.of(context).colorScheme;
    // USER RULING R-2 (docs/logs/2026-09-03/theme-parity-contract.md): the
    // gutter and the preview each own their own width. Widening the gutter
    // SHRINKS the preview, so the photo starts where the gutter ends and they
    // never overlap. This overrides the mockup's R5a ("above 90 it floats over
    // it and never pushes it") for the Flutter port. Every `viewportLeft + N`
    // offset below — the viewport, the EXIF caption, the status toast —
    // re-bases on the live drag width with no edit of its own.
    final double viewportLeft = _width;

    return Stack(
      children: [
        Positioned(
          left: viewportLeft,
          top: 0,
          right: 0,
          bottom: 0,
          child: surface.viewport,
        ),
        // R4 EXIF caption, bottom-LEFT over a legibility scrim (mockup
        // `.overcap`, left:26 bottom:20) — unlike gallery's bottom-right.
        Positioned(
          left: viewportLeft + 26,
          bottom: 20,
          child: ExifCaption(
            fileName: surface.identity?.displayName,
            exif: surface.identity?.exif,
            alignment: CrossAxisAlignment.start,
            variant: ExifCaptionVariant.joined,
            // Mockup `.overcap .t`: var(--serif), 15px, letter-spacing .01em.
            titleStyle: const TextStyle(
              fontFamily: 'serif',
              fontSize: 15,
              letterSpacing: 0.01 * 15,
              color: Colors.white,
              shadows: _overShadows,
            ),
            // Mockup `.overcap .exif`: 11px, letter-spacing .05em, opacity .85.
            detailStyle: TextStyle(
              fontSize: 11,
              letterSpacing: 0.05 * 11,
              color: Colors.white.withValues(alpha: 0.85),
              shadows: _overShadows,
            ),
            detailGap: 5, // mockup margin-top:5px
          ),
        ),
        // Frame counter, bottom-right of the photo (mockup `.overcount`).
        Positioned(
          right: 26,
          bottom: 22,
          child: _buildOverCount(context, surface),
        ),
        // Transient status toast (mockup `.toast`, centred near the top).
        Positioned(
          left: viewportLeft + 16,
          bottom: 20,
          child: surface.statusOverlay,
        ),
        // Width readout while dragging (mockup `.widthbadge`).
        Positioned(
          top: 16,
          left: viewportLeft + 16,
          child: IgnorePointer(
            child: !_dragActive
                ? const SizedBox.shrink()
                : Container(
                    key: kPaperWidthBadgeKey,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: const [
                        BoxShadow(color: Color(0x33000000), blurRadius: 16),
                      ],
                    ),
                    child: Text(
                      '${_width.round()} px',
                      style: TextStyle(
                        fontSize: 14,
                        color: colors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
          ),
        ),
        // The gutter: always IN LAYOUT, never an overlay (R-2). Its width is
        // the live drag width, and the viewport above starts at exactly that
        // x, so the two regions are disjoint by construction at every width.
        Positioned(
          key: kPaperColumnSlotKey,
          left: 0,
          top: 0,
          bottom: 0,
          width: _width,
          child: _PaperColumn(
            surface: surface,
            width: _width,
            narrow: _width < 60,
            onWidthDelta: _onWidthDelta,
          ),
        ),
        // Outer half of the resize handle's hit region, so a pointer just
        // past the grip still grabs the drag instead of panning the photo.
        Positioned(
          left: _width,
          top: 0,
          bottom: 0,
          width: 6,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (details) => _onWidthDelta(details.delta.dx),
            ),
          ),
        ),
      ],
    );
  }

  /// Mockup `.overcount` (`c1-desktop-dark.html:250-251`, markup `:443`):
  /// `34 / 212 · 18 starred`, one serif line bottom-right over the photo. The
  /// starred segment is drawn unconditionally, including at 0, as the mockup
  /// draws it.
  Widget _buildOverCount(BuildContext context, MainSurface surface) {
    final identity = surface.identity;
    if (identity == null) return const SizedBox.shrink();
    return Text(
      '${identity.indexInFolder} / ${identity.folderCount}'
      ' · ${identity.starredCount} starred',
      key: kPaperOverCountKey,
      style: TextStyle(
        fontFamily: 'serif',
        fontSize: 13,
        color: Colors.white.withValues(alpha: 0.85),
        shadows: _overShadows,
      ),
    );
  }
}

/// The in-gutter strip (widths 40-90, sits BESIDE the photo, mockup
/// `.stripbody`).
class _PaperColumn extends StatefulWidget {
  const _PaperColumn({
    required this.surface,
    required this.width,
    required this.narrow,
    required this.onWidthDelta,
  });

  final MainSurface surface;
  final double width;
  final bool narrow;
  final void Function(double dx) onWidthDelta;

  @override
  State<_PaperColumn> createState() => _PaperColumnState();
}

class _PaperColumnState extends State<_PaperColumn> {
  /// Round 4: the paper strip now uses the same in-layout re-anchoring the
  /// gallery strip got for TC-556. Dragging 40->90 scales the chip (and so
  /// the row extent) continuously, which re-maps every row's pixel position
  /// under a fixed offset — the same stale-offset flicker, previously
  /// carried as a known limitation ("paper strip 未套 TC-556 錨定捲動").
  final AnchoredScrollController _scrollController = AnchoredScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _PaperColumn oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.width == widget.width) return;
    final strip = widget.surface.strip;
    final selectedId = strip.selectedId;
    if (selectedId == null) return;
    final idx = strip.items.indexWhere((i) => i.id == selectedId);
    if (idx == -1) return;
    // Both width-driven geometry changes now live in THIS widget: the chip
    // scales continuously (row extent moves) and the column count steps at
    // kPaperTwoColumnWidth (the selected item's row index moves).
    _scrollController.anchorRowByPixelOffset(
      oldRow: idx ~/ paperColumnsFor(oldWidget.width),
      oldRowExtent: paperRowExtentFor(oldWidget.width),
      newRow: () => idx ~/ paperColumnsFor(widget.width),
      newRowExtent: () => paperRowExtentFor(widget.width),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final strip = widget.surface.strip;

    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: Stack(
        children: [
          Column(
            children: [
              _buildHead(context),
              Expanded(
                child: _buildFilmstrip(context, strip),
              ),
              _buildTools(context, colors),
            ],
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: 5,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (details) =>
                    widget.onWidthDelta(details.delta.dx),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHead(BuildContext context) {
    final actions = widget.surface.actions;
    return SizedBox(
      height: 44,
      child: Row(
        mainAxisAlignment: widget.narrow
            ? MainAxisAlignment.center
            : MainAxisAlignment.spaceBetween,
        children: [
          if (!widget.narrow)
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: IconButton(
                icon: const Icon(Icons.folder_open, size: 18),
                tooltip: 'Open Folder',
                onPressed: actions.onOpenFolder,
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 11),
            child: actions.menu,
          ),
        ],
      ),
    );
  }

  Widget _buildFilmstrip(BuildContext context, PhotoStripModel strip) {
    final items = strip.items;
    return RepaintBoundary(
      child: ListenableBuilder(
        listenable: strip.revision,
        builder: (context, _) => GridView.builder(
          key: const ValueKey<String>('paper-grid'),
          controller: _scrollController,
          padding: EdgeInsets.all(paperGridPaddingFor(widget.width)),
          itemCount: items.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: paperColumnsFor(widget.width),
            mainAxisSpacing: kPaperStripGap,
            crossAxisSpacing: kPaperStripGap,
            childAspectRatio: paperChipAspectFor(widget.width),
          ),
          itemBuilder: (context, index) {
            // itemBuilder-driven visibility (AD-011/AD-014 red line): the
            // visible range is reported from what was actually built, never
            // from a scroll listener or offset arithmetic.
            _reportVisibleRange(index);
            return _PaperChip(item: items[index], strip: strip);
          },
        ),
      ),
    );
  }

  // Same form as darkroom_column.dart:196-210: accumulate the min/max index
  // built this frame, report once in a post-frame callback. The previous
  // offset-arithmetic version assumed one column and a constant row extent —
  // both false now.
  int _first = -1;
  int _last = -1;
  bool _scheduled = false;

  void _reportVisibleRange(int index) {
    if (_first == -1 || index < _first) _first = index;
    if (index > _last) _last = index;
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      final first = _first;
      final last = _last;
      _first = -1;
      _last = -1;
      if (!mounted || first == -1) return;
      widget.surface.strip.onVisibleRange(first, last);
    });
  }

  Widget _buildTools(BuildContext context, ColorScheme colors) {
    final actions = widget.surface.actions;
    final identity = widget.surface.identity;
    final palette = PaperPalette.of(context);
    final isStarred = identity?.status == PhotoStatus.starred;
    final isTrashed = identity?.status == PhotoStatus.trashed;

    return Container(
      padding: const EdgeInsets.only(top: 10, bottom: 12, left: 8, right: 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.outlineVariant)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(
              isStarred ? Icons.star : Icons.star_border,
              color: isStarred ? palette.star : null,
            ),
            onPressed: actions.onStar,
            tooltip: 'Star (S)',
          ),
          GestureDetector(
            onSecondaryTap: actions.onToggleRecycleMode,
            child: IconButton(
              icon: Icon(
                isTrashed ? Icons.delete : Icons.delete_outline,
                color: isTrashed ? Theme.of(context).colorScheme.error : null,
              ),
              onPressed: actions.onTrash,
              tooltip: actions.recycleMode
                  ? 'Recycle (X) — right-click or R: switch to direct delete'
                  : 'Trash (X) — right-click or R: switch to recycle mode',
            ),
          ),
          if (!widget.narrow)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                identity == null
                    ? ''
                    : '${identity.indexInFolder} / ${identity.folderCount}',
                style: TextStyle(
                  fontFamily: 'serif',
                  fontSize: 11,
                  color: palette.textFaint,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PaperChip extends StatelessWidget {
  const _PaperChip({required this.item, required this.strip});

  final PhotoItem item;
  final PhotoStripModel strip;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final palette = PaperPalette.of(context);
    final isSelected = item.id == strip.selectedId;
    return GestureDetector(
      key: ValueKey<String>('paper-chip-tap-${item.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => strip.onSelect(item.id),
      child: Container(
        key: ValueKey<String>('paper-chip-${item.id}'),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(3),
          border: isSelected
              ? Border.all(color: colors.primary, width: 2)
              : null,
          boxShadow: const [
            BoxShadow(color: Color(0x1A000000), blurRadius: 3, offset: Offset(0, 1)),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned.fill(
              // A constant 200px source request scaled to fill the chip, so
              // dragging re-lays-out but never re-decodes (AD-011 identity
              // rule, ported verbatim from gallery_column.dart).
              child: FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: 200,
                  height: 200 / kPaperChipAspect,
                  child: PhotoThumbnail(
                    payload: strip.payloadFor(item.id),
                    width: 200,
                    height: 200 / kPaperChipAspect,
                    borderRadius: 0,
                  ),
                ),
              ),
            ),
            if (item.status != PhotoStatus.unmarked)
              Positioned(
                right: -3,
                top: -3,
                child: Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: item.status == PhotoStatus.starred
                        ? palette.star
                        : colors.error,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
