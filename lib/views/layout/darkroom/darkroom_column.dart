import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../models/photo_item.dart';
import '../common/anchored_scroll.dart';
import '../common/photo_thumbnail.dart';
import '../common/visible_range_reporter.dart';
import '../main_surface.dart';
import 'darkroom_palette.dart';

/// Drag range, ruled R9 in `docs/logs/2026-09-01/mockup/darkroom/NOTES.md`:
/// range 40-200, default/resting 90. The 40px form is specified in words only
/// (NOTES.md "R9") and is NOT drawn in the mockup — reproducing its exact
/// below-90 chip scaling would be invention, not reproduction, so this build
/// clamps the practical floor at 90 (the drawn range) and flags the 40-89
/// band as a known gap in the round report rather than guessing its shape.
const double kDarkroomColumnMinWidth = 90.0;
const double kDarkroomColumnMaxWidth = 200.0;

/// The column boundary where a second chip column becomes possible (NOTES.md
/// "Swept across every width in the range" table): 180 = 6 + 78 + 12 + 78 + 6.
const double kDarkroomTwoColumnWidth = 180.0;

/// The width at which the chip steps from 78x52 to 84x56 without losing a row
/// (NOTES.md: "84 is the boundary of the safe region"): 192 = 6+84+12+84+6.
const double kDarkroomChipStepWidth = 192.0;

const double kDarkroomChipAspect = 3 / 2;
const double kDarkroomFloorChipWidth = 78.0;
const double kDarkroomCeilingChipWidth = 84.0;

/// The chip width at a given (clamped) column width, per the derived table in
/// NOTES.md ("Swept across every width in the range").
double darkroomChipWidthForColumnWidth(double width) {
  if (width < kDarkroomChipStepWidth) return kDarkroomFloorChipWidth;
  return kDarkroomCeilingChipWidth;
}

/// The chip grid's column count at a given (clamped) column width.
int darkroomGridColumnsForWidth(double width) {
  return width < kDarkroomTwoColumnWidth ? 1 : 2;
}

/// The grid's outer padding (all four sides) and the spacing between cells.
const double kDarkroomGridPadding = 6.0;
const double kDarkroomGridSpacing = 12.0;

/// The pixel height of one grid ROW at a given column width, including the
/// spacing that follows it. Derived from exactly the numbers the
/// `SliverGridDelegateWithFixedCrossAxisCount` below is built with, so the
/// anchoring arithmetic cannot drift from the layout it is anchoring.
double darkroomRowExtentForWidth(double width) {
  final columns = darkroomGridColumnsForWidth(width);
  final cross =
      width - 2 * kDarkroomGridPadding - kDarkroomGridSpacing * (columns - 1);
  final cell = math.max(1.0, cross) / columns;
  return cell / kDarkroomChipAspect + kDarkroomGridSpacing;
}

/// Hit width of the resize handle at the column's right edge (mockup: a 5px
/// painted grip; the hit region is widened here, mirroring gallery's
/// AD-established 12px target, to keep the handle reliably grabbable).
const double kDarkroomHandleHitWidth = 12;

/// The `darkroom` theme's wordless picture column (round 2 T13).
///
/// Per the mockup thesis (NOTES.md): "the column carries pictures and nothing
/// else — no filename, no counter, no labels, no readouts." This widget
/// therefore renders ONLY thumbnail chips with a corner star/trash mark; it
/// must never grow a text label, cap or identity plate (that is what
/// distinguishes it from `gallery`'s column).
///
/// Presentational only — every behaviour arrives resolved through
/// [MainSurface] (the layout-seam AD contract).
class DarkroomColumn extends StatefulWidget {
  const DarkroomColumn({
    super.key,
    required this.surface,
    required this.width,
    required this.onWidthDelta,
  });

  final MainSurface surface;
  final double width;
  final void Function(double dx) onWidthDelta;

  @override
  State<DarkroomColumn> createState() => _DarkroomColumnState();
}

class _DarkroomColumnState extends State<DarkroomColumn>
    with VisibleRangeReporter<DarkroomColumn> {
  /// Round 4: the darkroom grid gets the same in-layout re-anchoring the
  /// gallery strip got for TC-556. Both of its width-driven geometry changes
  /// (the 78->84 chip step at 192, and the 1->2 column step at 180) re-map
  /// every row's pixel position under a fixed scroll offset, which is the
  /// stale-offset flicker.
  final AnchoredScrollController _scrollController = AnchoredScrollController();

  int get _columns => darkroomGridColumnsForWidth(widget.width);

  @override
  ScrollController? get rangeScrollController => _scrollController;

  @override
  PhotoStripModel get rangeStrip => widget.surface.strip;

  @override
  int get rangeColumns => _columns;

  @override
  double? get rangeRowExtent => darkroomRowExtentForWidth(widget.width);

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant DarkroomColumn oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.width == widget.width) return;
    anchorSelectedRowOnWidthChange(
      controller: _scrollController,
      strip: widget.surface.strip,
      columnsFor: darkroomGridColumnsForWidth,
      rowExtentFor: darkroomRowExtentForWidth,
      oldWidth: oldWidget.width,
      newWidth: widget.width,
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = DarkroomPalette.of(context);
    final strip = widget.surface.strip;
    final items = strip.items;

    return Stack(
      key: const ValueKey<String>('darkroom-column'),
      children: [
        Material(
          color: Theme.of(context).colorScheme.surface,
          elevation: widget.width > kDarkroomColumnMinWidth ? 8 : 0,
          child: Padding(
            padding: const EdgeInsets.all(kDarkroomGridPadding),
            child: RepaintBoundary(
              child: ListenableBuilder(
                listenable: strip.revision,
                builder: (context, _) => GridView.builder(
                  key: const ValueKey<String>('darkroom-grid'),
                  controller: _scrollController,
                  itemCount: items.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: _columns,
                    mainAxisSpacing: kDarkroomGridSpacing,
                    crossAxisSpacing: kDarkroomGridSpacing,
                    childAspectRatio: kDarkroomChipAspect,
                  ),
                  itemBuilder: (context, index) {
                    noteBuiltIndex(index);
                    return _buildChip(context, items[index], strip, palette);
                  },
                ),
              ),
            ),
          ),
        ),
        // 5px painted drag handle, wider hit region for reliability.
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: kDarkroomHandleHitWidth,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanUpdate: (details) =>
                  widget.onWidthDelta(details.delta.dx),
              child: Align(
                alignment: Alignment.centerRight,
                child: Container(
                  key: const ValueKey<String>('darkroom-grip'),
                  width: 5,
                  height: double.infinity,
                  color: Theme.of(context).colorScheme.outline.withValues(
                    alpha: 0.0,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildChip(
    BuildContext context,
    PhotoItem item,
    PhotoStripModel strip,
    DarkroomPalette palette,
  ) {
    final colors = Theme.of(context).colorScheme;
    final isSelected = item.id == strip.selectedId;
    return GestureDetector(
      key: ValueKey<String>('darkroom-chip-tap-${item.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => strip.onSelect(item.id),
      child: Container(
        key: ValueKey<String>('darkroom-chip-${item.id}'),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(2),
          border: Border.all(
            color: isSelected ? colors.primary : colors.outlineVariant,
            width: isSelected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Constant decode request regardless of chip paint size — the
            // sidebar thumbnail source is already capped at 200px long edge
            // (AD-011 red line: same bytes/size identity, no scaling
            // re-decode).
            FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: 200,
                height: 200 / kDarkroomChipAspect,
                child: PhotoThumbnail(
                  payload: strip.payloadFor(item.id),
                  width: 200,
                  height: 200 / kDarkroomChipAspect,
                  borderRadius: 0,
                ),
              ),
            ),
            if (item.status != PhotoStatus.unmarked)
              Positioned(
                right: 4,
                top: 4,
                child: _statusDot(item, colors, palette),
              ),
          ],
        ),
      ),
    );
  }

  Widget _statusDot(
    PhotoItem item,
    ColorScheme colors,
    DarkroomPalette palette,
  ) {
    final color = switch (item.status) {
      PhotoStatus.starred => palette.star,
      PhotoStatus.trashed => colors.error,
      PhotoStatus.unmarked => colors.outlineVariant,
    };
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// Clamp helper shared by the desktop surface's drag handler.
double clampDarkroomColumnWidth(double raw) => math.max(
  kDarkroomColumnMinWidth,
  math.min(kDarkroomColumnMaxWidth, raw),
);
