import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../models/photo_item.dart';
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

/// The pinned resting chip size (mockup: "From 90 upward the chip is pinned
/// at 74x49").
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

const Duration kPaperWidthBadgeDelay = Duration(milliseconds: 400);

/// Chip width for a given gutter width (mockup NOTES.md sweep, drawn points
/// 40/90/140/200): scales linearly from [kPaperChipFloorWidth] at
/// [kPaperColumnMinWidth] up to [kPaperChipRestWidth] at
/// [kPaperColumnRestWidth], then stays pinned through [kPaperColumnMaxWidth].
double paperChipWidthFor(double width) {
  if (width >= kPaperColumnRestWidth) return kPaperChipRestWidth;
  final t = ((width - kPaperColumnMinWidth) /
          (kPaperColumnRestWidth - kPaperColumnMinWidth))
      .clamp(0.0, 1.0);
  return kPaperChipFloorWidth + t * (kPaperChipRestWidth - kPaperChipFloorWidth);
}

double paperChipHeightFor(double width) {
  if (width >= kPaperColumnRestWidth) {
    return kPaperChipRestWidth / kPaperChipAspect;
  }
  final t = ((width - kPaperColumnMinWidth) /
          (kPaperColumnRestWidth - kPaperColumnMinWidth))
      .clamp(0.0, 1.0);
  final restHeight = kPaperChipRestWidth / kPaperChipAspect;
  return kPaperChipFloorHeight + t * (restHeight - kPaperChipFloorHeight);
}

/// One column at or below [kPaperTwoColumnWidth], two above it — the strip
/// never grows past two (mockup NOTES.md sweep).
int paperColumnsFor(double width) => width >= kPaperTwoColumnWidth ? 2 : 1;

/// At or below the 90px default the strip sits BESIDE the photo inside the
/// gutter; above it, it floats over the photo as an overlay (R5a/R9: "Layout
/// changes at w=91").
bool paperStripBeside(double width) => width <= kPaperColumnRestWidth;

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
    final palette = PaperPalette.of(context);
    // The photo never moves: the gutter always reserves 90px of layout
    // (mockup: "the gutter always reserves 90px of LAYOUT so the photo
    // starts at x=90 and stays 1350x900 at every drag width"). Widths above
    // 90 float the strip as an overlay instead of pushing this inset.
    const double viewportLeft = kPaperColumnRestWidth;
    final beside = paperStripBeside(_width);

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
          left: math.max(viewportLeft, _width) + 16,
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
        // The gutter: BESIDE the photo at rest, floating over it above 90.
        Positioned(
          key: kPaperColumnSlotKey,
          left: 0,
          top: 0,
          bottom: 0,
          width: beside ? _width : kPaperColumnRestWidth,
          child: beside
              ? _PaperColumn(
                  surface: surface,
                  width: _width,
                  narrow: _width < 60,
                  onWidthDelta: _onWidthDelta,
                )
              : _PaperColumn(
                  surface: surface,
                  width: kPaperColumnRestWidth,
                  narrow: false,
                  onWidthDelta: _onWidthDelta,
                ),
        ),
        // The floating strip (widths 91-200): a translucent glass panel over
        // the photo's left edge (mockup `.floatstrip`), never moving the
        // photo. Column count 1 below 171, 2 at/above it.
        if (!beside)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: _width,
            child: _PaperFloatStrip(
              surface: surface,
              width: _width,
              palette: palette,
              onWidthDelta: _onWidthDelta,
            ),
          ),
        // Outer half of the resize handle's hit region, so a pointer just
        // past the grip still grabs the drag instead of panning the photo.
        Positioned(
          left: beside ? _width : _width,
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

  Widget _buildOverCount(BuildContext context, MainSurface surface) {
    final identity = surface.identity;
    if (identity == null) return const SizedBox.shrink();
    return Text(
      '${identity.indexInFolder} / ${identity.folderCount}',
      style: const TextStyle(
        color: Colors.white,
        fontSize: 13,
        shadows: [Shadow(color: Colors.black45, blurRadius: 4)],
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
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final strip = widget.surface.strip;
    final chipW = paperChipWidthFor(widget.width);
    final chipH = paperChipHeightFor(widget.width);

    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: Stack(
        children: [
          Column(
            children: [
              _buildHead(context),
              Expanded(
                child: _buildFilmstrip(context, strip, chipW, chipH),
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

  Widget _buildFilmstrip(
    BuildContext context,
    PhotoStripModel strip,
    double chipW,
    double chipH,
  ) {
    final items = strip.items;
    final gap = 7.0;
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 2),
      itemExtent: chipH + gap,
      itemCount: items.length,
      itemBuilder: (context, index) {
        // itemBuilder-driven visibility (AD-011 red line): the visible range
        // is reported from viewport geometry, never a scroll listener.
        _reportVisibleRange();
        final item = items[index];
        return Center(
          child: _PaperChip(
            item: item,
            strip: strip,
            width: chipW,
            height: chipH,
          ),
        );
      },
    );
  }

  bool _sweepScheduled = false;

  void _reportVisibleRange() {
    if (_sweepScheduled) return;
    _sweepScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sweepScheduled = false;
      if (!mounted || !_scrollController.hasClients) return;
      final strip = widget.surface.strip;
      final chipH = paperChipHeightFor(widget.width);
      final extent = chipH + 7.0;
      final offset = _scrollController.offset;
      final viewportHeight = _scrollController.position.viewportDimension;
      final first = (offset / extent).floor();
      final last = ((offset + viewportHeight) / extent).ceil();
      strip.onVisibleRange(
        math.max(0, first),
        math.min(last, strip.items.length - 1),
      );
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

/// The overlay strip drawn above 90px (mockup `.floatstrip`): translucent
/// glass, one or two columns, chip pinned at [kPaperChipRestWidth].
class _PaperFloatStrip extends StatefulWidget {
  const _PaperFloatStrip({
    required this.surface,
    required this.width,
    required this.palette,
    required this.onWidthDelta,
  });

  final MainSurface surface;
  final double width;
  final PaperPalette palette;
  final void Function(double dx) onWidthDelta;

  @override
  State<_PaperFloatStrip> createState() => _PaperFloatStripState();
}

class _PaperFloatStripState extends State<_PaperFloatStrip> {
  final ScrollController _scrollController = ScrollController();
  bool _sweepScheduled = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strip = widget.surface.strip;
    final items = strip.items;
    final columns = paperColumnsFor(widget.width);
    final rowCount = (items.length + columns - 1) ~/ columns;
    final gap = 7.0;

    return Container(
      decoration: BoxDecoration(
        color: widget.palette.glassFloat,
        boxShadow: const [
          BoxShadow(color: Color(0x4D000000), blurRadius: 44, offset: Offset(14, 0)),
        ],
      ),
      child: Column(
        children: [
          SizedBox(
            height: 44,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.folder_open, size: 18),
                  tooltip: 'Open Folder',
                  onPressed: widget.surface.actions.onOpenFolder,
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: widget.surface.actions.menu,
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: ListView.builder(
                controller: _scrollController,
                itemExtent: kPaperChipRestWidth / kPaperChipAspect + gap,
                itemCount: rowCount,
                itemBuilder: (context, row) {
                  _reportVisibleRange(strip, columns);
                  final first = row * columns;
                  final last = math.min(first + columns - 1, items.length - 1);
                  return Wrap(
                    alignment: WrapAlignment.center,
                    spacing: gap,
                    children: [
                      for (var i = first; i <= last; i++)
                        _PaperChip(
                          item: items[i],
                          strip: strip,
                          width: kPaperChipRestWidth,
                          height: kPaperChipRestWidth / kPaperChipAspect,
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
          SizedBox(
            height: 60,
            child: Row(
              children: [
                Expanded(
                  child: IconButton(
                    icon: Icon(
                      Icons.star_border,
                      color: widget.palette.star,
                    ),
                    onPressed: widget.surface.actions.onStar,
                    tooltip: 'Star (S)',
                  ),
                ),
                Expanded(
                  child: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: widget.surface.actions.onTrash,
                    tooltip: 'Trash (X)',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _reportVisibleRange(PhotoStripModel strip, int columns) {
    if (_sweepScheduled) return;
    _sweepScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sweepScheduled = false;
      if (!mounted || !_scrollController.hasClients) return;
      final extent = kPaperChipRestWidth / kPaperChipAspect + 7.0;
      final offset = _scrollController.offset;
      final viewportHeight = _scrollController.position.viewportDimension;
      final firstRow = (offset / extent).floor();
      final lastRow = ((offset + viewportHeight) / extent).ceil();
      strip.onVisibleRange(
        math.max(0, firstRow * columns),
        math.min(lastRow * columns + (columns - 1), strip.items.length - 1),
      );
    });
  }
}

class _PaperChip extends StatelessWidget {
  const _PaperChip({
    required this.item,
    required this.strip,
    required this.width,
    required this.height,
  });

  final PhotoItem item;
  final PhotoStripModel strip;
  final double width;
  final double height;

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
        width: width,
        height: height,
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
